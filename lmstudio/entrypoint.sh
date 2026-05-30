#!/bin/bash
set -e

# Docker named volumes are mounted as root. Fix ownership then drop to uid 1000.
if [ "$(id -u)" = "0" ]; then
    chown -R lmstudio:lmstudio /home/lmstudio/.lmstudio
    exec gosu lmstudio "$0" "$@"
fi

echo "[lmstudio] Starting llmster daemon..."
lms daemon up

echo "[lmstudio] Waiting for daemon socket..."
sleep 3

# Download + load Gemma model
if [ -n "${GEMMA_MODEL}" ]; then
    echo "[lmstudio] Downloading ${GEMMA_MODEL} (skipped if already cached)..."
    lms get "${GEMMA_MODEL}" --yes
    echo "[lmstudio] Loading ${GEMMA_MODEL} (context-length=${GEMMA_CONTEXT_LENGTH:-8192})..."
    lms load "${GEMMA_MODEL}" \
        --context-length "${GEMMA_CONTEXT_LENGTH:-8192}" \
        --gpu max \
        --identifier "gemma-4-e4b" \
        --yes
    echo "[lmstudio] ${GEMMA_MODEL} ready."
fi

# Download + load Qwen model
if [ -n "${QWEN_MODEL}" ]; then
    echo "[lmstudio] Downloading ${QWEN_MODEL} (skipped if already cached)..."
    lms get "${QWEN_MODEL}" --yes
    echo "[lmstudio] Loading ${QWEN_MODEL} (context-length=${QWEN_CONTEXT_LENGTH:-8192})..."
    lms load "${QWEN_MODEL}" \
        --context-length "${QWEN_CONTEXT_LENGTH:-8192}" \
        --gpu max \
        --identifier "qwen2.5-coder-7b" \
        --yes
    echo "[lmstudio] ${QWEN_MODEL} ready."
fi

echo "[lmstudio] Starting API server on 0.0.0.0:${LMS_SERVER_PORT:-1234}..."
# lms server start is non-blocking: it instructs the llmster daemon to start
# accepting HTTP connections and then returns. Keep the container alive by
# waiting on the daemon process itself.
lms server start \
    --port "${LMS_SERVER_PORT:-1234}" \
    --bind "${LMS_SERVER_HOST:-0.0.0.0}"

DAEMON_PID=$(pgrep -x llmster 2>/dev/null || true)
if [ -n "$DAEMON_PID" ]; then
    echo "[lmstudio] Server running (daemon PID $DAEMON_PID)."
    # tail --pid blocks until the process exits, without consuming resources
    exec tail --pid="$DAEMON_PID" -f /dev/null
else
    echo "[lmstudio] Warning: llmster PID not found, falling back to sleep."
    exec sleep infinity
fi
