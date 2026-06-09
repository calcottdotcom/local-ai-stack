#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/gpu-detect.sh"

PROVIDER="${1:-}"
MODEL="${2:-}"

bold() { echo -e "\033[1m$*\033[0m"; }
info() { echo -e "  \033[36m→\033[0m $*"; }
ok()   { echo -e "  \033[32m✓\033[0m $*"; }
die()  { echo -e "  \033[31m✗\033[0m $*" >&2; exit 1; }

[[ -n "$PROVIDER" ]] || die "Usage: $0 <ollama|llamacpp> <model>"
[[ -n "$MODEL"    ]] || die "Usage: $0 <ollama|llamacpp> <model>"

source "$ROOT_DIR/.env" 2>/dev/null || die "Run 'just setup' first"

# ── Detect VRAM for context sizing ────────────────────────────────────────

detect_gpu || true

# ─────────────────────────────────────────────────────────────────────────
# OLLAMA
# ─────────────────────────────────────────────────────────────────────────
if [[ "$PROVIDER" == "ollama" ]]; then
    # Ensure ollama is running
    docker ps -q --filter name=ollama | grep -q . || \
        die "Ollama container is not running. Start with: just up ollama"

    # Check if the localai-tuned variant already exists to avoid unnecessary re-pulls
    TAGGED_MODEL="${MODEL%:*}:localai"
    if docker exec ollama ollama list 2>/dev/null | grep -qF "${TAGGED_MODEL}"; then
        ok "Model '$TAGGED_MODEL' already exists"
        info "To re-download, first run: docker exec ollama ollama rm ${TAGGED_MODEL}"
        exit 0
    fi

    bold "Pulling model: $MODEL"
    if ! docker exec ollama ollama pull "$MODEL"; then
        die "Pull failed — check network connectivity and that '$MODEL' is a valid Ollama model tag"
    fi
    ok "Model pulled"

    # Estimate model size from name to calculate available VRAM for context
    if   echo "$MODEL" | grep -qi '70b\|72b'; then MODEL_SIZE_GB=40
    elif echo "$MODEL" | grep -qi '30b\|32b\|34b'; then MODEL_SIZE_GB=19
    elif echo "$MODEL" | grep -qi '13b\|14b'; then MODEL_SIZE_GB=8
    elif echo "$MODEL" | grep -qi '12b'; then MODEL_SIZE_GB=7
    elif echo "$MODEL" | grep -qi '9b'; then MODEL_SIZE_GB=5
    elif echo "$MODEL" | grep -qi '7b\|8b'; then MODEL_SIZE_GB=4
    elif echo "$MODEL" | grep -qi '4b\|3b'; then MODEL_SIZE_GB=2
    else MODEL_SIZE_GB=4
    fi

    CTX=$(recommend_ctx "$VRAM_GB" "$MODEL_SIZE_GB")
    info "VRAM: ${VRAM_GB}GB, model ~${MODEL_SIZE_GB}GB → setting context to $CTX tokens"

    # Write Modelfile and create a tuned version of the model
    MODELFILE_CONTENT="FROM ${MODEL}
PARAMETER num_ctx ${CTX}"

    TAGGED_MODEL="${MODEL%:*}:localai"
    info "Creating tuned model: $TAGGED_MODEL"

    # Write Modelfile into the container and create the model
    docker exec ollama bash -c "
        echo '${MODELFILE_CONTENT}' > /tmp/Modelfile
        ollama create '${TAGGED_MODEL}' -f /tmp/Modelfile
        rm /tmp/Modelfile
    "
    ok "Model ready: $TAGGED_MODEL (context: $CTX tokens)"
    info "Storage: docker volume 'local-ai-stack_ollama-models'"

    # Track the active model in .env so agents pick it up on next start
    sed -i "s|^OLLAMA_MODEL=.*|OLLAMA_MODEL=${TAGGED_MODEL}|" "$ROOT_DIR/.env"
    sed -i "s|^INFERENCE_MODEL=.*|INFERENCE_MODEL=${TAGGED_MODEL}|" "$ROOT_DIR/.env"

# ─────────────────────────────────────────────────────────────────────────
# LLAMA.CPP
# ─────────────────────────────────────────────────────────────────────────
elif [[ "$PROVIDER" == "llamacpp" ]]; then
    # Check if a GGUF already exists in the volume to avoid re-downloading
    existing_gguf=$(docker run --rm \
        -v local-ai-stack_llamacpp-models:/models \
        alpine sh -c "ls /models/*.gguf 2>/dev/null | head -1" 2>/dev/null || true)
    if [[ -n "$existing_gguf" ]]; then
        existing_name=$(basename "$existing_gguf")
        warn "Found existing model in volume: $existing_name"
        read -rp "  Re-download and replace? [y/N]: " OVERWRITE
        OVERWRITE=${OVERWRITE:-N}
        if [[ ! "$OVERWRITE" =~ ^[Yy]$ ]]; then
            ok "Keeping existing model: $existing_name"
            info "If you need a different context size, update LLAMACPP_CTX in .env manually."
            exit 0
        fi
    fi

    bold "Downloading model from HuggingFace: $MODEL"
    info "This may take a while depending on model size and internet speed..."

    # Download into the llamacpp-models volume via a temporary container
    docker run --rm \
        -v local-ai-stack_llamacpp-models:/models \
        python:3.12-slim \
        bash -c "
            pip install -q huggingface_hub
            python3 -c \"
from huggingface_hub import snapshot_download
import os, glob

repo_id = '${MODEL}'
print(f'Downloading {repo_id}...')
local_dir = snapshot_download(
    repo_id=repo_id,
    local_dir='/models/downloads/${MODEL}',
    allow_patterns=['*.gguf', '*.json'],
    ignore_patterns=['*shard*']
)
print(f'Downloaded to: {local_dir}')

# Find the primary GGUF file (largest one, usually the full model)
gguf_files = sorted(glob.glob(f'{local_dir}/*.gguf'), key=os.path.getsize, reverse=True)
if gguf_files:
    primary = gguf_files[0]
    filename = os.path.basename(primary)
    # Symlink at /models/<filename> for easy reference
    link = f'/models/{filename}'
    if not os.path.exists(link):
        os.symlink(primary, link)
    print(f'PRIMARY_GGUF={filename}')
else:
    print('ERROR: No GGUF files found in download')
    exit(1)
\"
        "

    # Get the filename from the downloaded content
    GGUF_FILENAME=$(docker run --rm \
        -v local-ai-stack_llamacpp-models:/models \
        alpine \
        sh -c "ls /models/*.gguf 2>/dev/null | head -1 | xargs basename" 2>/dev/null || true)

    if [[ -z "$GGUF_FILENAME" ]]; then
        die "Could not find downloaded GGUF file. Check the model repo: $MODEL"
    fi

    ok "Downloaded: $GGUF_FILENAME"
    info "Storage: docker volume 'local-ai-stack_llamacpp-models'"

    # Calculate context window
    if   echo "$GGUF_FILENAME" | grep -qi '70b\|72b'; then MODEL_SIZE_GB=40
    elif echo "$GGUF_FILENAME" | grep -qi '30b\|32b\|34b'; then MODEL_SIZE_GB=19
    elif echo "$GGUF_FILENAME" | grep -qi '12b\|13b\|14b'; then MODEL_SIZE_GB=7
    elif echo "$GGUF_FILENAME" | grep -qi '9b'; then MODEL_SIZE_GB=5
    elif echo "$GGUF_FILENAME" | grep -qi '7b\|8b'; then MODEL_SIZE_GB=4
    elif echo "$GGUF_FILENAME" | grep -qi '4b\|3b'; then MODEL_SIZE_GB=2
    else MODEL_SIZE_GB=4
    fi

    CTX=$(recommend_ctx "$VRAM_GB" "$MODEL_SIZE_GB")
    info "VRAM: ${VRAM_GB}GB, model ~${MODEL_SIZE_GB}GB → recommended context: $CTX tokens"

    # Update .env
    sed -i "s|^LLAMACPP_MODEL=.*|LLAMACPP_MODEL=${GGUF_FILENAME}|" "$ROOT_DIR/.env"
    sed -i "s|^LLAMACPP_CTX=.*|LLAMACPP_CTX=${CTX}|" "$ROOT_DIR/.env"

    ok "Set LLAMACPP_MODEL=$GGUF_FILENAME, LLAMACPP_CTX=$CTX in .env"
    info "Start the stack with: just up llamacpp"

else
    die "Unknown provider: $PROVIDER. Use 'ollama' or 'llamacpp'"
fi
