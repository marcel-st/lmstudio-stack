# Plan: LM Studio + LiteLLM Docker Stack

## Context

Production-ready Docker Compose stack that runs LM Studio headlessly with GPU acceleration,
fronted by LiteLLM as a secure API proxy. LiteLLM provides a web UI for user/key management with
model-level access control. Model: Gemma 4 12B. Hardware target: NVIDIA RTX 5060 Ti 16 GB on
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
| Coding assistance | `gemma-4-12b` | |
| Home Assistant control | `gemma-4-12b` | Fast responses; no thinking overhead |
| Document analysis | `gemma-4-12b` | Native multimodal: pass images/charts directly |
| Financial / crypto analysis | `gemma-4-12b` | Native multimodal: send chart screenshots for analysis |
| Trading bot integration | `gemma-4-12b` | Legit trading not blocked; official model preferred |
| Complex T&D reasoning | `gemma-4-12b` | |

---

## VRAM Budget

| Component | VRAM |
|---|---|
| Gemma 4 12B (Q4_K_M) | ~7.4 GB |
| CUDA runtime | ~0.3 GB |
| KV cache @ 16384 ctx | ~1.5 GB |
| 2× 4K Plex transcode | ~4.0 GB |
| **Total** | **~13.2 GB** |
| **Headroom** | **~2.8 GB** |

Safe context range: 4096–16384. With Plex idle, 24576 is viable (~2.0 GB KV, ~14.0 GB total).

---

## Model Selection

**Current: Gemma 4 12B** — switched June 2026 for native multimodal (crypto charts, PDF images,
trading data screenshots), more VRAM headroom, and suitability for trading bot integration.

> **Every time this codebase is revisited for improvements, re-evaluate whether a better model has emerged.**

| Axis | Gemma 4 12B | Qwen3-14B |
|---|---|---|
| Coding (HumanEval / SWE-Bench / LiveCodeBench) | ★★★★☆ | ★★★★★ |
| Math / financial reasoning | ★★★★☆ | ★★★★★ |
| HA tool calling | ★★★★☆ | ★★★★★ (community-proven) |
| Multimodal (images / audio / video) | ✓ native | ✗ text-only |
| VRAM with 16K ctx + 2× 4K Plex | ~13.2 GB (2.8 GB free) | ~14.6 GB (1.4 GB free) |
| Model maturity | Released June 2026 | Stable |

**Switch back to Qwen3-14B (or Qwen3.5-14B when released) when:**
- Coding benchmark gap matters more than multimodal, AND
- HA tool calling on Gemma proves unreliable in practice

**Switch to a different model when:**
- Qwen3.5/3.6 releases a dense 14B variant that fits the VRAM budget, OR
- A better model emerges — check HumanEval, SWE-Bench, MMLU, HA community reports

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
5. `lms load $MODEL --context-length $CONTEXT_LENGTH --identifier gemma-4-12b --gpu max --yes`
6. `lms server start --port 1234 --bind 0.0.0.0` — non-blocking; daemon keeps running
7. `tail --pid=$DAEMON_PID -f /dev/null` — keeps container alive until llmster exits

**Key env vars:**
```
MODEL=google/gemma-4-12b
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
  - model_name: gemma-4-12b
    litellm_params:
      model: openai/gemma-4-12b
      api_base: os.environ/LMSTUDIO_API_BASE
      api_key: none
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
- **New model aliases:** picked up on restart since they don't exist in DB yet

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
   `gemma-4-12b` only (not `gemma-4-12b-thinking`; HA needs fast responses, not chain-of-thought)

2. Install `extended_openai_conversation` via HACS in Home Assistant

3. Settings → Devices & Services → Add Integration → Extended OpenAI Conversation:
   - **API Key:** the HA-specific LiteLLM key from step 1
   - **Base URL:** `http://<host>:4000/v1`
   - **Model:** `gemma-4-12b`

4. Settings → Voice Assistants → Edit assistant → set Conversation agent to the new integration

**Notes:**
- Qwen3-14B uses Hermes-style tool calling; `extended_openai_conversation` uses this for service
  calls and entity control
- Keep thinking mode off for HA (the default `gemma-4-12b` alias) — it adds 1–3 s latency that
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
# Expected: "gemma-4-12b"

# LM Studio: direct inference
curl http://localhost:1234/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma-4-12b","messages":[{"role":"user","content":"Say hello"}],"max_tokens":50}'

# LiteLLM: health
curl http://localhost:4000/health/liveliness

# LiteLLM: model list
curl -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  http://localhost:4000/v1/models | jq '.data[].id'

# LiteLLM: proxied inference
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma-4-12b","messages":[{"role":"user","content":"Write hello world in Python"}],"max_tokens":100}'

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
| LM Studio model identifier must match config.yaml | `--identifier gemma-4-12b` in entrypoint must equal `openai/gemma-4-12b` suffix in config.yaml |
| `LITELLM_SALT_KEY` must never change after first run | Documented in `.env.example`; changing it breaks all existing virtual keys |
| NVIDIA driver version check | CUDA 12.4 requires driver ≥550; adjust base image tag if host has an older driver |
| DB model config overrides config.yaml after first boot | Expected; use admin UI to update model params after initial seed |
| config.yaml must be baked into the LiteLLM image | Bind mounts fail on remote Docker hosts; `litellm/Dockerfile` COPYs it in |
| `lms server start` is non-blocking | Container kept alive via `tail --pid=$DAEMON_PID -f /dev/null` |
| Gemma 4 12B vision fails in LM Studio | Open bug: `unknown projector type: gemma4uv` (lmstudio-ai/lmstudio-bug-tracker#2021). Text inference works. Check issue for fix status before sending image inputs. |
