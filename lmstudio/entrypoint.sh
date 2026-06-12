#!/bin/bash
set -e

# Docker named volumes are mounted as root. Fix ownership then drop to uid 1000.
if [ "$(id -u)" = "0" ]; then
    chown -R lmstudio:lmstudio /home/lmstudio/.lmstudio
    exec gosu lmstudio "$0" "$@"
fi

# Build the --gpu flag for lms load.
# GPU_MODE=max  → --gpu max (all layers on GPU; fastest, requires enough VRAM)
# GPU_MODE=off  → --gpu off (CPU-only)
# GPU_MODE=auto → no flag (LM Studio auto-fits layers into available VRAM)
gpu_flag() {
    case "${GPU_MODE:-max}" in
        max) echo "--gpu max" ;;
        off) echo "--gpu off" ;;
        *)   echo "" ;;
    esac
}

echo "[lmstudio] Starting llmster daemon..."
lms daemon up

echo "[lmstudio] Waiting for daemon socket..."
sleep 3

if [ -n "${MODEL}" ]; then
    echo "[lmstudio] Downloading ${MODEL} (skipped if already cached)..."
    lms get "${MODEL}" --yes
    echo "[lmstudio] Loading ${MODEL} (context-length=${CONTEXT_LENGTH:-16384}, gpu=${GPU_MODE:-max})..."
    # shellcheck disable=SC2046
    lms load "${MODEL}" \
        --context-length "${CONTEXT_LENGTH:-16384}" \
        --identifier "gemma-4-12b" \
        $(gpu_flag) \
        --yes
    echo "[lmstudio] ${MODEL} ready."
fi

echo "[lmstudio] Starting API server on 0.0.0.0:${LMS_SERVER_PORT:-1234}..."
# lms server start is non-blocking: it signals the llmster daemon to accept
# HTTP connections and then returns. Keep the container alive by waiting on
# the daemon process itself.
lms server start \
    --port "${LMS_SERVER_PORT:-1234}" \
    --bind "${LMS_SERVER_HOST:-0.0.0.0}"

DAEMON_PID=$(pgrep -x llmster 2>/dev/null || true)
if [ -n "$DAEMON_PID" ]; then
    echo "[lmstudio] Server running (daemon PID $DAEMON_PID)."
    exec tail --pid="$DAEMON_PID" -f /dev/null
else
    echo "[lmstudio] Warning: llmster PID not found, falling back to sleep."
    exec sleep infinity
fi
