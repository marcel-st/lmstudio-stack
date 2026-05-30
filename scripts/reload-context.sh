#!/bin/bash
# Reload a model in LM Studio with a new context length.
# Usage: ./scripts/reload-context.sh <gemma|qwen> <context_length>
# Example: ./scripts/reload-context.sh gemma 16384

set -e

MODEL_NAME=${1:-}
NEW_CONTEXT=${2:-}

if [ -z "$MODEL_NAME" ] || [ -z "$NEW_CONTEXT" ]; then
    echo "Usage: $0 <gemma|qwen> <context_length>"
    echo "  e.g. $0 gemma 16384"
    exit 1
fi

ENV_FILE="$(dirname "$0")/../.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "Error: .env file not found at $ENV_FILE"
    exit 1
fi

case "$MODEL_NAME" in
    gemma)
        ENV_KEY="GEMMA_CONTEXT_LENGTH"
        ;;
    qwen)
        ENV_KEY="QWEN_CONTEXT_LENGTH"
        ;;
    *)
        echo "Unknown model '$MODEL_NAME'. Use 'gemma' or 'qwen'."
        exit 1
        ;;
esac

echo "Updating $ENV_KEY to $NEW_CONTEXT in .env..."
sed -i "s/^${ENV_KEY}=.*/${ENV_KEY}=${NEW_CONTEXT}/" "$ENV_FILE"

echo "Restarting lmstudio service..."
docker compose --env-file "$ENV_FILE" -f "$(dirname "$0")/../docker-compose.yml" restart lmstudio

echo ""
echo "Waiting for lmstudio to become healthy..."
until docker compose -f "$(dirname "$0")/../docker-compose.yml" ps lmstudio | grep -q "(healthy)"; do
    printf "."
    sleep 5
done
echo ""

echo "Done. Model reloaded with context length $NEW_CONTEXT."
echo ""
echo "Next step — sync the LiteLLM admin UI:"
echo "  1. Open http://localhost:4000/ui"
echo "  2. Go to Models + Endpoints"
echo "  3. Edit '$MODEL_NAME' model"
echo "  4. Set max_input_tokens and context_window to $NEW_CONTEXT"
