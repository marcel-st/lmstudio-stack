# Plan: LM Studio + LiteLLM Docker Stack

## Context

Production-ready Docker Compose stack that runs LM Studio headlessly with GPU acceleration,
fronted by LiteLLM as a secure API proxy. LiteLLM provides a web UI for user/key management with
model-level access control. Model: Qwen3-14B. Hardware target: NVIDIA RTX 5060 Ti 16 GB on
CachyOS Linux.

---

## Architecture

```
Host (CachyOS, RTX 5060 Ti 16 GB)
├── lmstudio  :1234   ← headless LM Studio daemon + API server (GPU)
├── litellm   :4000   ← LiteLLM proxy + admin UI
└── postgres  :5432   ← LiteLLM persistence (keys, users, spend)
```

No reverse proxy (HTTP-only, internal/local network use). No Redis (not needed at this scale).

---

## VRAM Budget

| Component | VRAM |
|---|---|
| Qwen3-14B (Q4_K_M) | ~8.3 GB |
| CUDA runtime | ~0.3 GB |
| KV cache @ 8192 ctx | ~1.0 GB |
| 2× 4K Plex transcode | ~4.0 GB |
| **Total** | **~13.6 GB** |
| **Headroom** | **~2.4 GB** |

Safe context range: 4096–16384. Above 16384 may OOM during concurrent Plex hardware transcoding.

---

## File Structure

```
lmstudio-stack/
├── PLAN.md                        ← this document (committed)
├── docker-compose.yml
├── .env.example                   ← committed template
├── .env                           ← git-ignored, actual secrets
├── lmstudio/
│   ├── Dockerfile
│   └── entrypoint.sh
├── litellm/
│   └── config.yaml
└── scripts/
    └── reload-context.sh          ← helper for context-size changes
```

---

## Services

### `lmstudio` (custom build)

**Base image:** `nvidia/cuda:12.4.1-runtime-ubuntu22.04`
- Requires host NVIDIA driver ≥550 (check with `nvidia-smi`)
- ubuntu24.04 variant of this CUDA tag does not exist; ubuntu22.04 is correct

**Build process (Dockerfile):**
1. Install `curl`, `ca-certificates`, `libatomic1`, `libgomp1`, `gosu`
2. Create user `lmstudio` (uid 1000) — required; LM Studio refuses to run as root
3. Run `curl -fsSL https://lmstudio.ai/install.sh | bash` as uid 1000 → installs `lms` CLI and `llmster` daemon to `~/.lmstudio/bin/`
4. Return to root; copy `entrypoint.sh`

**entrypoint.sh startup sequence:**
1. If running as root: `chown -R lmstudio .lmstudio` then `exec gosu lmstudio` (volume ownership fix)
2. `lms daemon up` — start the local IPC daemon (prerequisite for all `lms` commands)
3. `sleep 3` — wait for daemon socket
4. `lms get $MODEL --yes` — download model (skipped if already cached in named volume)
5. `lms load $MODEL --context-length $CONTEXT_LENGTH --identifier qwen3-14b --gpu max --yes`
6. `lms server start --port 1234 --bind 0.0.0.0` — non-blocking; daemon keeps running
7. `tail --pid=$DAEMON_PID -f /dev/null` — keeps container alive until llmster exits

**Key env vars:**
```
MODEL=qwen/qwen3-14b
CONTEXT_LENGTH=8192
GPU_MODE=max
LMS_SERVER_HOST=0.0.0.0
LMS_SERVER_PORT=1234
HOME=/home/lmstudio
```

**GPU_MODE values:**
- `max` — all layers on GPU (default; optimal for single model on 16 GB)
- `auto` — LM Studio auto-fits layers into available VRAM
- `off` — CPU only

**Volumes:**
- `lmstudio_models` → `~/.lmstudio/models` (model files; persists across recreates)
- `lmstudio_data` → `~/.lmstudio` (config/state; separate from models so config can be wiped independently)

**healthcheck:** `curl -sf http://localhost:1234/v1/models` with `start_period: 1800s`
(1800s to allow first-run model download; normal startups complete in ~60–120s)

---

### `litellm`

**Image:** `ghcr.io/berriai/litellm:main-stable` (pinned tag; `main-latest` is a rolling alias)

**Dockerfile:** COPYs `config.yaml` into the image to avoid bind-mount issues on remote Docker hosts.

**config.yaml key settings:**
```yaml
model_list:
  - model_name: qwen3-14b
    litellm_params:
      model: openai/qwen3-14b       # 'openai/' prefix = OpenAI-compatible endpoint
      api_base: os.environ/LMSTUDIO_API_BASE
      api_key: none
    model_info:
      max_input_tokens: 8192
      context_window: 8192

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  salt_key: os.environ/LITELLM_SALT_KEY
  database_url: os.environ/DATABASE_URL
  store_model_in_db: true           # enables UI model editing + persistence
  ui_access_mode: all               # both admins and internal_users can access UI

litellm_settings:
  stream: true                      # stream tokens as generated
  request_timeout: 300
```

**Note on `store_model_in_db: true`:** Once enabled, the DB version of model config wins on restart.
The `config.yaml` `model_list` seeds defaults on the very first startup only. After that, use the
admin UI to update `max_input_tokens` / `context_window` when the LM Studio context size changes.

**Startup dependency:** `depends_on: postgres (healthy) AND lmstudio (healthy)`

---

### `postgres`

**Image:** `postgres:16-alpine`
**healthcheck:** `pg_isready -U litellm`

---

## Context Size Change Workflow

Context size changes require a model reload in LM Studio (can't change on a live model).

**Procedure (admin):**
1. Run `./scripts/reload-context.sh 16384`
   - This updates `CONTEXT_LENGTH` in `.env` and restarts the lmstudio service
2. In LiteLLM admin UI → **Models + Endpoints → Edit model** → update `max_input_tokens` and `context_window` to match

---

## LiteLLM Admin Setup (Post-Startup)

1. Open `http://<host>:4000/ui`
2. Login: username `admin`, password = value of `LITELLM_MASTER_KEY` from `.env`
3. **Admin panel → Users → Create User**: set email, password, role `internal_user`
4. Users log in at the same UI URL, go to **My Keys → Create Key**, select models from dropdown

---

## Host Prerequisites

Before first `docker compose up`:

```bash
# 1. NVIDIA Container Toolkit (CachyOS/Arch)
sudo pacman -S nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# 2. Verify GPU passthrough
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi

# 3. Create .env
cp .env.example .env
# Edit .env: set LITELLM_MASTER_KEY (must start with "sk-"), LITELLM_SALT_KEY, POSTGRES_PASSWORD
# Generate keys: openssl rand -hex 32
```

---

## Verification Steps

```bash
# Stack health
docker compose ps

# LM Studio: model loaded
curl http://localhost:1234/v1/models | jq '.data[].id'
# Expected: "qwen3-14b"

# LM Studio: direct inference
curl http://localhost:1234/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-14b","messages":[{"role":"user","content":"Say hello"}],"max_tokens":50}'

# LiteLLM: health
curl http://localhost:4000/health/liveliness

# LiteLLM: model list
curl -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  http://localhost:4000/v1/models | jq '.data[].id'

# LiteLLM: proxied inference
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-14b","messages":[{"role":"user","content":"Write hello world in Python"}],"max_tokens":100}'

# GPU usage (run during inference)
nvidia-smi dmon -s u -d 2
```

---

## Known Pitfalls

| Pitfall | Mitigation |
|---|---|
| First-run model download takes 10–30 min | `start_period: 1800s` on healthcheck; litellm won't start until lmstudio is healthy |
| LM Studio refuses to run as root | gosu pattern: container starts as root, fixes volume ownership, drops to uid 1000 |
| Docker named volumes mounted as root | `chown -R lmstudio .lmstudio` on startup before `gosu` drops privileges |
| `HOME` env var must be set correctly | Dockerfile sets `ENV HOME=/home/lmstudio`; compose re-declares it |
| LM Studio model identifier must match config.yaml | `--identifier qwen3-14b` in entrypoint must equal `openai/qwen3-14b` suffix in config.yaml |
| `LITELLM_SALT_KEY` must never change after first run | Documented in `.env.example`; changing it breaks all existing virtual keys |
| NVIDIA driver version check | CUDA 12.4 requires driver ≥550; adjust base image tag if host has an older driver |
| DB model config overrides config.yaml after first boot | Expected; use admin UI to update model params after initial seed |
| config.yaml must be baked into the LiteLLM image | Bind mounts fail on remote Docker hosts; `litellm/Dockerfile` COPYs it in |
| `lms server start` is non-blocking | Container kept alive via `tail --pid=$DAEMON_PID -f /dev/null` |
