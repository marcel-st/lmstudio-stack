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

## Use Cases

| Use Case | Model | Notes |
|---|---|---|
| Coding assistance | `qwen3-14b` | Fast, no thinking overhead |
| Home Assistant control | `qwen3-14b` | Thinking off — speed critical for intent recognition |
| Document analysis | `qwen3-14b` | Standard mode; text-only (no images) |
| Financial / crypto analysis | `qwen3-14b-thinking` | Chain-of-thought for multi-step reasoning |
| Complex T&D reasoning | `qwen3-14b-thinking` | Use when accuracy matters more than speed |

---

## VRAM Budget

| Component | VRAM |
|---|---|
| Qwen3-14B (Q4_K_M) | ~8.3 GB |
| CUDA runtime | ~0.3 GB |
| KV cache @ 16384 ctx | ~2.0 GB |
| 2× 4K Plex transcode | ~4.0 GB |
| **Total** | **~14.6 GB** |
| **Headroom** | **~1.4 GB** |

Safe context range: 4096–16384. Above 16384 may OOM during concurrent Plex hardware transcoding.

---

## Model Selection

**Current: Qwen3-14B** — best dense model that fits the 16 GB budget with 2× 4K Plex reserved.
Strong coding, proven Home Assistant tool calling, configurable thinking mode for reasoning tasks.

> **Every time this codebase is revisited for improvements, re-evaluate whether Gemma 4 12B has overtaken Qwen3-14B.**

| Axis | Qwen3-14B | Gemma 4 12B |
|---|---|---|
| Coding (HumanEval / SWE-Bench / LiveCodeBench) | ★★★★★ | ★★★★☆ |
| Math / financial reasoning | ★★★★★ | ★★★★☆ |
| HA tool calling (community-validated) | ★★★★★ | ★★★☆☆ |
| Multimodal (images / audio / video) | ✗ text-only | ✓ native |
| VRAM with 16K ctx + 2× 4K Plex | ~14.6 GB (1.4 GB free) | ~13.0 GB (3.0 GB free) |
| Model maturity | Stable | Released June 2026 |

**Status as of June 2026:** Qwen3-14B is the better choice. Gemma 4 12B's native multimodal would
benefit document analysis with charts/images/crypto screenshots but requires LiteLLM + client-side
stack changes to use. HA tool calling community validation is still early.

**Switch to Gemma 4 12B when:**
- It matches or exceeds Qwen3-14B on coding benchmarks (HumanEval, SWE-Bench, LiveCodeBench), AND
- Home Assistant tool calling reliability is confirmed by the community, AND
- You want native image/chart/PDF input and are ready to update the LiteLLM + client stack

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
CONTEXT_LENGTH=16384
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
  - model_name: qwen3-14b           # default: thinking off, full 16K context
    litellm_params:
      model: openai/qwen3-14b
      api_base: os.environ/LMSTUDIO_API_BASE
      api_key: none
      extra_body:
        enable_thinking: false
      stream_options:
        include_usage: true
      input_cost_per_token: 0.000000058
      output_cost_per_token: 0.00000029
    model_info:
      mode: chat
      max_input_tokens: 16384
      context_window: 16384
      input_cost_per_token: 0.000000058
      output_cost_per_token: 0.00000029

  - model_name: qwen3-14b-thinking  # financial/complex tasks: thinking on, 12K input limit
    litellm_params:
      model: openai/qwen3-14b
      api_base: os.environ/LMSTUDIO_API_BASE
      api_key: none
      extra_body:
        enable_thinking: true
        thinking:
          type: enabled
          budget_tokens: 2048
      stream_options:
        include_usage: true
      input_cost_per_token: 0.000000058
      output_cost_per_token: 0.00000029
    model_info:
      mode: chat
      max_input_tokens: 12288       # leaves room for 2048 thinking + output within 16384 ctx
      context_window: 12288
      input_cost_per_token: 0.000000058
      output_cost_per_token: 0.00000029

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
- **Existing models:** config.yaml changes are ignored; use the admin UI to update params
- **New model aliases** (e.g. `qwen3-14b-thinking`): picked up on restart since they don't exist in DB yet

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

## Home Assistant Integration

LiteLLM's OpenAI-compatible endpoint at `http://<host>:4000/v1` connects directly to Home Assistant
via the [extended_openai_conversation](https://github.com/jekalmin/extended_openai_conversation)
HACS integration (recommended for full tool calling) or the built-in OpenAI integration.

**Setup:**

1. In the LiteLLM admin UI, create a dedicated API key for Home Assistant — restrict it to
   `qwen3-14b` only (not `qwen3-14b-thinking`; HA needs fast responses, not chain-of-thought)

2. Install `extended_openai_conversation` via HACS in Home Assistant

3. Settings → Devices & Services → Add Integration → Extended OpenAI Conversation:
   - **API Key:** the HA-specific LiteLLM key from step 1
   - **Base URL:** `http://<host>:4000/v1`
   - **Model:** `qwen3-14b`

4. Settings → Voice Assistants → Edit assistant → set Conversation agent to the new integration

**Notes:**
- Qwen3-14B uses Hermes-style tool calling; `extended_openai_conversation` uses this for service
  calls and entity control
- Keep thinking mode off for HA (the default `qwen3-14b` alias) — it adds 1–3 s latency that
  hurts intent recognition
- Test with a simple command ("turn off the living room light") before building automations

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
