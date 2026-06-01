# lmstudio-stack

Headless LM Studio with LiteLLM as a secure API proxy. Runs on Docker with NVIDIA GPU support.

- **LM Studio** (`:1234`) — headless model server, OpenAI-compatible API
- **LiteLLM** (`:4000`) — proxy with web UI, user management, API key creation
- **Model** — Qwen3-14B (reasoning, coding, document analytics; 128K context)

## Requirements

- Docker + Docker Compose
- NVIDIA Container Toolkit (`nvidia-container-toolkit` on Arch/CachyOS)
- NVIDIA driver ≥ 550 (for CUDA 12.4; see `lmstudio/Dockerfile` to adjust)
- GPU with ≥ 16 GB VRAM recommended (see [VRAM budget](#vram-budget))

## Setup

### 1. Install NVIDIA Container Toolkit

```bash
sudo pacman -S nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# Verify GPU passthrough works
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
```

### 2. Configure secrets

```bash
cp .env.example .env
```

Edit `.env` and replace the placeholder values:
- `LITELLM_MASTER_KEY` — must start with `sk-`. Use `openssl rand -hex 32` prepended with `sk-`.
- `LITELLM_SALT_KEY` — generate with `openssl rand -hex 32`. **Never change this after first run.**
- `POSTGRES_PASSWORD` — any strong password.

### 3. Start the stack

```bash
docker compose up -d
```

On first run, LM Studio will download Qwen3-14B (~8.3 GB). This can take 10–30 minutes
depending on your connection. LiteLLM will start automatically once LM Studio is healthy.

Watch progress:

```bash
docker compose logs -f lmstudio
```

### 4. Admin setup

Once the stack is up, open the LiteLLM admin UI:

```
http://<host>:4000/ui
```

Login with:
- Username: `admin`
- Password: the value of `LITELLM_MASTER_KEY` from `.env`

From there you can:
- Create users: **Admin panel → Users → Create User** (role: `internal_user`)
- Users can then log in, go to **My Keys → Create Key**, and select which models their key can access

## Verify

```bash
# Check all services are healthy
docker compose ps

# LM Studio: confirm the model is loaded
curl http://localhost:1234/v1/models | jq '.data[].id'

# LiteLLM: test inference (replace KEY with your LITELLM_MASTER_KEY)
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-14b","messages":[{"role":"user","content":"Write hello world in Python"}],"max_tokens":100}'
```

### Using Qwen3 thinking mode

Qwen3-14B supports an extended reasoning mode. Enable it per-request with the `thinking` parameter:

```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3-14b",
    "thinking": {"type": "enabled", "budget_tokens": 2048},
    "messages": [{"role": "user", "content": "Explain the tradeoffs of B-trees vs LSM-trees"}],
    "max_tokens": 1000
  }'
```

## VRAM budget

Target hardware: **NVIDIA RTX 5060 Ti 16 GB**

| Component | VRAM |
|---|---|
| Qwen3-14B (Q4_K_M) | ~8.3 GB |
| CUDA runtime | ~0.3 GB |
| KV cache @ 8192 ctx | ~1.0 GB |
| 2× 4K Plex transcode | ~4.0 GB |
| **Total** | **~13.6 GB** |
| **Headroom** | **~2.4 GB** |

Safe context range: **4096–16384**. Above 16384 may OOM during concurrent Plex hardware transcoding.
To change the context length at runtime, see [Change context size](#change-context-size) below.

## Change context size

Context size is set when the model loads. To change it:

```bash
# Using the helper script (updates .env and restarts lmstudio)
./scripts/reload-context.sh 16384

# Or manually: edit CONTEXT_LENGTH in .env, then restart
docker compose restart lmstudio
```

After restarting, update `max_input_tokens` and `context_window` in the LiteLLM admin UI under
**Models + Endpoints → Edit model**.

## GPU mode

The `GPU_MODE` env var (in `.env`) controls how model layers are placed:

| Value | Behaviour |
|---|---|
| `max` (default) | All layers on GPU — fastest; safe on 16 GB with this single model |
| `auto` | LM Studio auto-fits layers; use when the GPU is shared with heavy concurrent workloads |
| `off` | CPU only |

## File layout

```
lmstudio-stack/
├── PLAN.md                  ← architecture decisions and design notes
├── docker-compose.yml
├── .env.example
├── lmstudio/
│   ├── Dockerfile
│   └── entrypoint.sh
├── litellm/
│   └── config.yaml
└── scripts/
    └── reload-context.sh
```
