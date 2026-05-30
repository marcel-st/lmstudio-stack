# lmstudio-stack

Headless LM Studio with LiteLLM as a secure API proxy. Runs on Docker with NVIDIA GPU support.

- **LM Studio** (`localhost:1234`) — headless model server, OpenAI-compatible API
- **LiteLLM** (`localhost:4000`) — proxy with web UI, user management, API key creation
- **Models** — Gemma-4-e4b and Qwen2.5-Coder-7B

## Requirements

- Docker + Docker Compose
- NVIDIA Container Toolkit (`nvidia-container-toolkit` on Arch/CachyOS)
- NVIDIA driver ≥ 550 (for CUDA 12.4; see `lmstudio/Dockerfile` to adjust)

## Setup

### 1. Install NVIDIA Container Toolkit

```bash
sudo pacman -S nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# Verify GPU passthrough works
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu24.04 nvidia-smi
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

On first run, LM Studio will download both models (~8 GB total). This can take 20–60 minutes
depending on your connection. LiteLLM will start automatically once LM Studio is healthy.

Watch progress:

```bash
docker compose logs -f lmstudio
```

### 4. Admin setup

Once the stack is up, open the LiteLLM admin UI:

```
http://localhost:4000/ui
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

# LM Studio: confirm both models are loaded
curl http://localhost:1234/v1/models | jq '.data[].id'

# LiteLLM: test inference (replace KEY with your LITELLM_MASTER_KEY)
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5-coder-7b","messages":[{"role":"user","content":"Write hello world in Python"}],"max_tokens":100}'
```

## Change context size

Context size is set when models load. To change it:

```bash
# Using the helper script (updates .env and restarts lmstudio)
./scripts/reload-context.sh gemma 16384
./scripts/reload-context.sh qwen 16384

# Or manually: edit .env, then restart
docker compose restart lmstudio
```

After restarting, update `max_input_tokens` and `context_window` in the LiteLLM admin UI under
**Models + Endpoints → Edit model**.

**VRAM note:** RTX 3060 (12GB) fits both models at 8192 context (~9.6 GB total). Both at 16K exceeds
12 GB — if you need 16K, keep one model at 8K.

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
