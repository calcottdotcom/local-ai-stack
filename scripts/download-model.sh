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
warn() { echo -e "  \033[33m!\033[0m $*"; }
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
    # ── Helpers: abstract host-ollama vs container-ollama ──────────────────
    if [[ "$PLATFORM" == "mac" ]]; then
        # Ollama runs on the Mac host — use the CLI directly
        command -v ollama &>/dev/null || \
            die "Ollama is not installed on this Mac. Install from https://ollama.com/download/mac"
        ollama_list()   { ollama list; }
        ollama_pull()   { ollama pull "$1"; }
        ollama_rm()     { ollama rm "$1"; }
        ollama_create() { ollama create "$1" -f "$2"; }
    else
        # Linux / WSL2 — use the ollama container
        docker ps -q --filter name=ollama | grep -q . || \
            die "Ollama container is not running. Start with: just up ollama"
        ollama_list()   { docker exec ollama ollama list; }
        ollama_pull()   { docker exec ollama ollama pull "$1"; }
        ollama_rm()     { docker exec ollama ollama rm "$1"; }
        ollama_create() { docker exec ollama ollama create "$1" -f "$2"; }
    fi

    # Check if the localai-tuned variant already exists to avoid unnecessary re-pulls
    # Preserve the param-count tag: qwen3.5:9b → qwen3.5:9b-localai
    if [[ "$MODEL" == *:* ]]; then
        TAGGED_MODEL="${MODEL}-localai"
    else
        TAGGED_MODEL="${MODEL}:localai"
    fi
    if ollama_list 2>/dev/null | grep -qF "${TAGGED_MODEL}"; then
        ok "Model '$TAGGED_MODEL' already exists"
        if [[ "$PLATFORM" == "mac" ]]; then
            info "To re-download, first run: ollama rm ${TAGGED_MODEL}"
        else
            info "To re-download, first run: docker exec ollama ollama rm ${TAGGED_MODEL}"
        fi
        exit 0
    fi

    bold "Pulling model: $MODEL"
    if ! ollama_pull "$MODEL"; then
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

    info "Creating tuned model: $TAGGED_MODEL"

    MODELFILE_PATH=$(mktemp /tmp/Modelfile.XXXXXX)
    printf 'FROM %s\nPARAMETER num_ctx %s\n' "$MODEL" "$CTX" > "$MODELFILE_PATH"
    if [[ "$PLATFORM" == "mac" ]]; then
        ollama_create "$TAGGED_MODEL" "$MODELFILE_PATH"
    else
        docker cp "$MODELFILE_PATH" ollama:/tmp/Modelfile
        docker exec ollama ollama create "$TAGGED_MODEL" -f /tmp/Modelfile
        docker exec ollama rm -f /tmp/Modelfile
    fi
    rm -f "$MODELFILE_PATH"
    ok "Model ready: $TAGGED_MODEL (context: $CTX tokens)"
    if [[ "$PLATFORM" == "mac" ]]; then
        info "Storage: ~/.ollama/models"
    else
        info "Storage: docker volume 'local-ai-stack_ollama-models'"
    fi

    # Track the active model and its context window in .env so agents pick them up on next start
    sedi "s|^OLLAMA_MODEL=.*|OLLAMA_MODEL=${TAGGED_MODEL}|" "$ROOT_DIR/.env"
    sedi "s|^INFERENCE_MODEL=.*|INFERENCE_MODEL=${TAGGED_MODEL}|" "$ROOT_DIR/.env"
    sedi "s|^OLLAMA_CTX=.*|OLLAMA_CTX=${CTX}|" "$ROOT_DIR/.env"

    # Restart running agent containers so they pick up the new model immediately
    for agent in hermes pi; do
        if docker ps -q --filter name="^${agent}$" | grep -q .; then
            info "Restarting ${agent} to pick up new model..."
            docker restart "$agent" > /dev/null
        fi
    done

# ─────────────────────────────────────────────────────────────────────────
# LLAMA.CPP
# ─────────────────────────────────────────────────────────────────────────
elif [[ "$PROVIDER" == "llamacpp" ]]; then
    # Check if the target GGUF already exists in the volume to avoid re-downloading.
    # Extract a size token (e.g. "26b", "9b") from the repo name to match against volume files.
    repo_size_token=$(basename "$MODEL" | tr '[:upper:]' '[:lower:]' | grep -oE '[0-9]+b' | head -1)
    all_ggufs=$(docker run --rm \
        -v local-ai-stack_llamacpp-models:/models \
        alpine sh -c "find /models -maxdepth 1 -name '*.gguf' ! -name 'mtp-*' 2>/dev/null" \
        2>/dev/null || true)

    matched_gguf=""
    if [[ -n "$all_ggufs" && -n "$repo_size_token" ]]; then
        while IFS= read -r f; do
            if echo "$f" | tr '[:upper:]' '[:lower:]' | grep -qE "(^|/)${repo_size_token}([^0-9]|$)|[^0-9]${repo_size_token}([^0-9]|$)"; then
                matched_gguf="$f"
                break
            fi
        done <<< "$all_ggufs"
    fi
    # Fallback: if no size match (or no size token), take the first GGUF found
    [[ -z "$matched_gguf" && -n "$all_ggufs" ]] && matched_gguf=$(echo "$all_ggufs" | head -1)

    if [[ -n "$matched_gguf" ]]; then
        existing_name=$(basename "$matched_gguf")
        warn "Found existing model in volume: $existing_name"
        read -rp "  Re-download and replace? [y/N]: " OVERWRITE
        OVERWRITE=${OVERWRITE:-N}
        if [[ ! "$OVERWRITE" =~ ^[Yy]$ ]]; then
            ok "Keeping existing model: $existing_name"
            GGUF_FILENAME="$existing_name"
            GPU_LAYERS=$(recommend_llamacpp_gpu_layers "$VRAM_GB" "$GGUF_FILENAME")
            CTX=$(recommend_llamacpp_ctx "$VRAM_GB" "$GGUF_FILENAME")
            if echo "$GGUF_FILENAME" | grep -qiE '26b|A4B'; then KV_TYPE="q4_0"; else KV_TYPE="f16"; fi
            info "VRAM: ${VRAM_GB}GB → GPU layers: ${GPU_LAYERS}, context: ${CTX}, KV type: ${KV_TYPE}"
            grep -q '^LLAMACPP_KV_TYPE=' "$ROOT_DIR/.env" || echo "LLAMACPP_KV_TYPE=" >> "$ROOT_DIR/.env"
            sedi "s|^LLAMACPP_MODEL=.*|LLAMACPP_MODEL=${GGUF_FILENAME}|"         "$ROOT_DIR/.env"
            sedi "s|^LLAMACPP_CTX=.*|LLAMACPP_CTX=${CTX}|"                      "$ROOT_DIR/.env"
            sedi "s|^LLAMACPP_GPU_LAYERS=.*|LLAMACPP_GPU_LAYERS=${GPU_LAYERS}|" "$ROOT_DIR/.env"
            sedi "s|^LLAMACPP_KV_TYPE=.*|LLAMACPP_KV_TYPE=${KV_TYPE}|"          "$ROOT_DIR/.env"
            sedi "s|^LLAMACPP_EXTRA_ARGS=.*|LLAMACPP_EXTRA_ARGS=|"              "$ROOT_DIR/.env"
            ok "Set LLAMACPP_MODEL=$GGUF_FILENAME, LLAMACPP_GPU_LAYERS=$GPU_LAYERS, LLAMACPP_CTX=$CTX, LLAMACPP_KV_TYPE=$KV_TYPE in .env"
            for agent in hermes pi; do
                if docker ps -q --filter name="^${agent}$" | grep -q .; then
                    info "Restarting ${agent} to pick up new model..."
                    docker restart "$agent" > /dev/null
                fi
            done
            info "Start the stack with: just up llamacpp"
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

    # Derive GPU layers, context, and KV type from model filename + measured VRAM data
    GPU_LAYERS=$(recommend_llamacpp_gpu_layers "$VRAM_GB" "$GGUF_FILENAME")
    CTX=$(recommend_llamacpp_ctx "$VRAM_GB" "$GGUF_FILENAME")
    # MoE models (26B A4B): q4_0 KV saves ~1 GB VRAM at large context; dense models: f16
    if echo "$GGUF_FILENAME" | grep -qiE '26b|A4B'; then
        KV_TYPE="q4_0"
    else
        KV_TYPE="f16"
    fi
    info "VRAM: ${VRAM_GB}GB → GPU layers: ${GPU_LAYERS}, context: ${CTX}, KV type: ${KV_TYPE}"

    # Update .env — add LLAMACPP_KV_TYPE line if missing (upgrading from older .env)
    grep -q '^LLAMACPP_KV_TYPE=' "$ROOT_DIR/.env" || echo "LLAMACPP_KV_TYPE=" >> "$ROOT_DIR/.env"
    sedi "s|^LLAMACPP_MODEL=.*|LLAMACPP_MODEL=${GGUF_FILENAME}|"           "$ROOT_DIR/.env"
    sedi "s|^LLAMACPP_CTX=.*|LLAMACPP_CTX=${CTX}|"                        "$ROOT_DIR/.env"
    sedi "s|^LLAMACPP_GPU_LAYERS=.*|LLAMACPP_GPU_LAYERS=${GPU_LAYERS}|"   "$ROOT_DIR/.env"
    sedi "s|^LLAMACPP_KV_TYPE=.*|LLAMACPP_KV_TYPE=${KV_TYPE}|"            "$ROOT_DIR/.env"
    sedi "s|^LLAMACPP_EXTRA_ARGS=.*|LLAMACPP_EXTRA_ARGS=|"                "$ROOT_DIR/.env"

    ok "Set LLAMACPP_MODEL=$GGUF_FILENAME, LLAMACPP_GPU_LAYERS=$GPU_LAYERS, LLAMACPP_CTX=$CTX, LLAMACPP_KV_TYPE=$KV_TYPE in .env"
    info "Start the stack with: just up llamacpp"

    # Restart running agent containers so they pick up the new model immediately
    for agent in hermes pi; do
        if docker ps -q --filter name="^${agent}$" | grep -q .; then
            info "Restarting ${agent} to pick up new model..."
            docker restart "$agent" > /dev/null
        fi
    done

else
    die "Unknown provider: $PROVIDER. Use 'ollama' or 'llamacpp'"
fi
