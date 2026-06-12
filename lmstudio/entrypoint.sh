#!/bin/bash
set -e

# Docker named volumes are mounted as root. Fix ownership then drop to uid 1000.
if [ "$(id -u)" = "0" ]; then
    chown -R lmstudio:lmstudio /home/lmstudio/.lmstudio
    exec gosu lmstudio "$0" "$@"
fi

# Map GPU_MODE to llama-server --n-gpu-layers value.
# GPU_MODE=max  → -1 (all layers on GPU; fastest)
# GPU_MODE=off  → 0  (CPU only)
# GPU_MODE=auto → -1 (llama-server default: tries to fit as many as possible)
n_gpu_layers() {
    case "${GPU_MODE:-max}" in
        max) echo "-1" ;;
        off) echo "0"  ;;
        *)   echo "-1" ;;
    esac
}

echo "[lmstudio] Starting llmster daemon (model downloads)..."
lms daemon up

echo "[lmstudio] Waiting for daemon socket..."
sleep 3

echo "[lmstudio] Downloading ${MODEL} (skipped if already cached)..."
lms get "${MODEL}" --yes

# Find the main GGUF for the requested model (e.g. google/gemma-4-12b → gemma-4-12b).
# Scope the search to directories matching the model basename to avoid picking up
# other cached models. Exclude vision projector files (mmproj / *proj*).
MODEL_SUBDIR=$(basename "${MODEL}")
MODEL_FILE=$(find "${HOME}/.lmstudio/models" -ipath "*${MODEL_SUBDIR}*" -name "*.gguf" \
    ! -iname "*mmproj*" ! -iname "*proj*" | sort | head -1)

if [ -z "${MODEL_FILE}" ]; then
    echo "[ERROR] No GGUF file found in ${HOME}/.lmstudio/models"
    exit 1
fi

# Derive alias from model path (e.g. google/gemma-4-12b → gemma-4-12b)
ALIAS="${MODEL_IDENTIFIER:-$(basename "${MODEL}")}"

echo "[llama-server] Model:   ${MODEL_FILE}"
echo "[llama-server] Alias:   ${ALIAS}"
echo "[llama-server] Context: ${CONTEXT_LENGTH:-16384} | GPU layers: $(n_gpu_layers) | Port: ${LMS_SERVER_PORT:-1234}"

exec llama-server \
    --model        "${MODEL_FILE}" \
    --alias        "${ALIAS}" \
    --host         "${LMS_SERVER_HOST:-0.0.0.0}" \
    --port         "${LMS_SERVER_PORT:-1234}" \
    --ctx-size     "${CONTEXT_LENGTH:-16384}" \
    --n-gpu-layers "$(n_gpu_layers)" \
    --flash-attn
