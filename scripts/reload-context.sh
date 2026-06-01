#!/bin/bash
# Reload the model in LM Studio with a new context length.
# Usage: ./scripts/reload-context.sh <context_length>
# Example: ./scripts/reload-context.sh 16384

set -e

NEW_CONTEXT=${1:-}

if [ -z "$NEW_CONTEXT" ]; then
    echo "Usage: $0 <context_length>"
    echo "  e.g. $0 16384"
    exit 1
fi

ENV_FILE="$(dirname "$0")/../.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "Error: .env file not found at $ENV_FILE"
    exit 1
fi

echo "Updating CONTEXT_LENGTH to $NEW_CONTEXT in .env..."
sed -i "s/^CONTEXT_LENGTH=.*/CONTEXT_LENGTH=${NEW_CONTEXT}/" "$ENV_FILE"

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
echo "  1. Open http://<host>:4000/ui"
echo "  2. Go to Models + Endpoints"
echo "  3. Edit 'qwen3-14b' model"
echo "  4. Set max_input_tokens and context_window to $NEW_CONTEXT"
