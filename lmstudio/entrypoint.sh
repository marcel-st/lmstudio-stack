#!/bin/bash
set -e

echo "[lmstudio] Starting llmster daemon..."
lms daemon up

echo "[lmstudio] Waiting for daemon socket..."
sleep 3

# Load Gemma model
if [ -n "${GEMMA_MODEL}" ]; then
    echo "[lmstudio] Loading ${GEMMA_MODEL} (context-length=${GEMMA_CONTEXT_LENGTH:-8192})..."
    lms load "${GEMMA_MODEL}" \
        --context-length "${GEMMA_CONTEXT_LENGTH:-8192}" \
        --gpu max \
        --identifier "gemma-4-e4b" \
        --yes
    echo "[lmstudio] ${GEMMA_MODEL} ready."
fi

# Load Qwen model
if [ -n "${QWEN_MODEL}" ]; then
    echo "[lmstudio] Loading ${QWEN_MODEL} (context-length=${QWEN_CONTEXT_LENGTH:-8192})..."
    lms load "${QWEN_MODEL}" \
        --context-length "${QWEN_CONTEXT_LENGTH:-8192}" \
        --gpu max \
        --identifier "qwen2.5-coder-7b" \
        --yes
    echo "[lmstudio] ${QWEN_MODEL} ready."
fi

echo "[lmstudio] Starting API server on 0.0.0.0:${LMS_SERVER_PORT:-1234}..."
# exec replaces the shell so Docker SIGTERM reaches lms directly
exec lms server start \
    --port "${LMS_SERVER_PORT:-1234}" \
    --bind "${LMS_SERVER_HOST:-0.0.0.0}"
