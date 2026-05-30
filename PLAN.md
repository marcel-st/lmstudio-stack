# Plan: LM Studio + LiteLLM Docker Stack

## Context

Build a production-ready Docker Compose stack that runs LM Studio headlessly with GPU acceleration,
fronted by LiteLLM as a secure API proxy. LiteLLM provides a web UI for user/key management with
model-level access control. Models hosted: Gemma-4-e4b and Qwen2.5-Coder-7B. Hardware target:
NVIDIA RTX 3060 12GB on CachyOS Linux.

---

## Architecture

```
Host (CachyOS, RTX 3060 12GB)
├── lmstudio  :1234   ← headless LM Studio daemon + API server (GPU)
├── litellm   :4000   ← LiteLLM proxy + admin UI
└── postgres  :5432   ← LiteLLM persistence (keys, users, spend)
```

No reverse proxy (HTTP-only, internal/local network use). No Redis (not needed at this scale).

---

## VRAM Budget

| Model              | Quant  | VRAM (model) | KV cache @8K | Total        |
|--------------------|--------|-------------|--------------|--------------|
| Gemma-4-e4b        | Q4_K_M | ~3.2 GB     | ~0.5 GB      |              |
| Qwen2.5-Coder-7B   | Q4_K_M | ~4.6 GB     | ~0.8 GB      |              |
| CUDA overhead      | —      | ~0.5 GB     | —            |              |
| **Total**          |        | **~9.6 GB** |              | ~2.4 GB free |

Both models at 8K context fit within 12GB. Raising both to 16K context (~+2.6 GB KV) would exceed
12GB. If 16K is needed: keep one model at 8K or load models one at a time.

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

**Base image:** `nvidia/cuda:12.4.1-runtime-ubuntu24.04`
- Requires host NVIDIA driver ≥550 (check with `nvidia-smi`; if lower, use `cuda:12.1.0-runtime-ubuntu22.04` for ≥530)

**Build process (Dockerfile):**
1. Install `curl`, `ca-certificates`
2. Create user `lmstudio` (uid 1000) — required; LM Studio refuses to run as root
3. Run `curl -fsSL https://lmstudio.ai/install.sh | bash` as uid 1000 → installs `lms` CLI and `llmster` daemon to `~/.lmstudio/bin/`
4. Copy `entrypoint.sh`, set `PATH` and `HOME`

**entrypoint.sh startup sequence:**
1. `lms daemon up` — start the local IPC daemon (prerequisite for all `lms` commands)
2. `sleep 3` — wait for daemon socket
3. `lms load $GEMMA_MODEL --context-length $GEMMA_CONTEXT_LENGTH --gpu max --identifier gemma-4-e4b --yes`
4. `lms load $QWEN_MODEL --context-length $QWEN_CONTEXT_LENGTH --gpu max --identifier qwen2.5-coder-7b --yes`
   - First run: downloads models automatically (20–60 min); cached on named volume for all subsequent runs
5. `exec lms server start --port 1234 --bind 0.0.0.0` — blocking; healthcheck hits `/v1/models`

**Key env vars:**
```
GEMMA_MODEL=google/gemma-4-e4b
GEMMA_CONTEXT_LENGTH=8192
QWEN_MODEL=qwen/qwen2.5-coder-7b
QWEN_CONTEXT_LENGTH=8192
LMS_SERVER_HOST=0.0.0.0
LMS_SERVER_PORT=1234
HOME=/home/lmstudio
```

**Volumes:**
- `lmstudio_models` → `~/.lmstudio/models` (model files; persists across recreates)
- `lmstudio_data` → `~/.lmstudio` (config/state; separate from models so config can be wiped independently)

**healthcheck:** `curl -sf http://localhost:1234/v1/models` with `start_period: 1800s`
(1800s to allow first-run model download; normal startups complete in ~60s)

---

### `litellm`

**Image:** `ghcr.io/berriai/litellm:main-stable` (pinned tag; `main-latest` is a rolling alias)

**config.yaml key settings:**
```yaml
model_list:
  - model_name: gemma-4-e4b
    litellm_params:
      model: openai/gemma-4-e4b        # 'openai/' prefix = OpenAI-compatible endpoint
      api_base: os.environ/LMSTUDIO_API_BASE
      api_key: none
    model_info:
      max_input_tokens: 8192
      context_window: 8192

  - model_name: qwen2.5-coder-7b
    litellm_params:
      model: openai/qwen2.5-coder-7b
      api_base: os.environ/LMSTUDIO_API_BASE
      api_key: none
    model_info:
      max_input_tokens: 8192
      context_window: 8192

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  salt_key: os.environ/LITELLM_SALT_KEY
  database_url: os.environ/DATABASE_URL
  store_model_in_db: true         # enables UI model editing + persistence
  ui_access_mode: all             # both admins and internal_users can access UI

router_settings:
  enable_pre_call_checks: true    # reject requests exceeding context_window
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
1. Edit `.env` — update `GEMMA_CONTEXT_LENGTH` or `QWEN_CONTEXT_LENGTH`
   - OR run `./scripts/reload-context.sh gemma 16384`
2. `docker compose restart lmstudio` (~30–60s downtime)
3. In LiteLLM admin UI → **Models + Endpoints → Edit model** → update `max_input_tokens` and `context_window` to match

The `reload-context.sh` script automates steps 1+2 and reminds the admin to do step 3.

---

## LiteLLM Admin Setup (Post-Startup)

1. Open `http://localhost:4000/ui`
2. Login: username `admin`, password = value of `LITELLM_MASTER_KEY` from `.env`
3. **Admin panel → Users → Create User**: set email, password, role `internal_user`
4. Users log in at the same UI URL, go to **My Keys → Create Key**, select models from dropdown

Model dropdown is populated from the model list (the two LM Studio models). Per-key model restriction
is built into LiteLLM's UI — no custom code needed.

---

## Host Prerequisites

Before first `docker compose up`:

```bash
# 1. NVIDIA Container Toolkit (CachyOS/Arch)
sudo pacman -S nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# 2. Verify GPU passthrough
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu24.04 nvidia-smi

# 3. Create .env
cp .env.example .env
# Edit .env: set LITELLM_MASTER_KEY (must start with "sk-"), LITELLM_SALT_KEY, POSTGRES_PASSWORD
# Generate keys: openssl rand -hex 32
```

---

## Known Pitfalls

| Pitfall | Mitigation |
|---|---|
| First-run model download takes 20–60 min | `start_period: 1800s` on healthcheck; litellm won't start until lmstudio is healthy |
| LM Studio refuses to run as root | `user: "1000:1000"` in compose + uid 1000 user in Dockerfile |
| `HOME` env var must be set correctly | Dockerfile sets `ENV HOME=/home/lmstudio`; compose re-declares it |
| LM Studio model identifier must match config.yaml | Use `--identifier gemma-4-e4b` and `--identifier qwen2.5-coder-7b` in entrypoint |
| `LITELLM_SALT_KEY` must never change after first run | Documented in `.env.example`; changing it breaks all existing virtual keys |
| NVIDIA driver version check | CUDA 12.4 requires driver ≥550; adjust base image if host has ≥530 driver |
| DB model config overrides config.yaml after first boot | Expected behavior; use admin UI to update model params after initial seed |
