#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/gpu-detect.sh"

# ── Helpers ────────────────────────────────────────────────────────────────

bold()  { echo -e "\033[1m$*\033[0m"; }
info()  { echo -e "  \033[36m→\033[0m $*"; }
ok()    { echo -e "  \033[32m✓\033[0m $*"; }
warn()  { echo -e "  \033[33m!\033[0m $*"; }
ask()   { read -rp "  $1 " REPLY; echo "$REPLY"; }

# ── Check prerequisites ────────────────────────────────────────────────────

echo ""
bold "Local AI Stack — Setup"
echo "────────────────────────────────────────"

missing=()
command -v docker &>/dev/null || missing+=("docker")
command -v just   &>/dev/null || missing+=("just")

if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Missing required tools: ${missing[*]}"
    warn "Install them then re-run this setup."
    exit 1
fi
ok "docker and just are installed"

# ── GPU detection ──────────────────────────────────────────────────────────

echo ""
bold "Detecting GPU..."
detect_gpu || true

if [[ "$GPU_TYPE" == "none" ]]; then
    warn "No GPU detected. CPU-only inference will be very slow."
    warn "Ensure your drivers are installed and try again if this is wrong."
else
    ok "GPU: $GPU_TYPE, VRAM: ${VRAM_GB}GB"
    info "Recommended model: $(recommend_model "$VRAM_GB")"
fi

# ── Create .env ────────────────────────────────────────────────────────────

echo ""
bold "Creating .env..."

if [[ -f "$ROOT_DIR/.env" ]]; then
    warn ".env already exists — skipping (delete it to regenerate)"
else
    cp "$ROOT_DIR/.env.example" "$ROOT_DIR/.env"

    # Stamp GPU type
    sed -i "s|^GPU_TYPE=.*|GPU_TYPE=${GPU_TYPE}|" "$ROOT_DIR/.env"

    # Stamp host UID/GID for hermes-webui volume permissions
    HOST_UID=$(id -u)
    HOST_GID=$(id -g)
    sed -i "s|^HOST_UID=.*|HOST_UID=${HOST_UID}|" "$ROOT_DIR/.env"
    sed -i "s|^HOST_GID=.*|HOST_GID=${HOST_GID}|" "$ROOT_DIR/.env"

    # Generate OD_API_TOKEN
    OD_TOKEN=$(openssl rand -hex 32)
    sed -i "s|^OD_API_TOKEN=.*|OD_API_TOKEN=${OD_TOKEN}|" "$ROOT_DIR/.env"

    ok ".env created"
fi

# ── Searxng secret key ─────────────────────────────────────────────────────

SEARXNG_SETTINGS="$ROOT_DIR/config/searxng/settings.yml"
if grep -q "CHANGE_ME_TO_A_RANDOM_STRING" "$SEARXNG_SETTINGS" 2>/dev/null; then
    SEARXNG_SECRET=$(openssl rand -hex 32)
    sed -i "s|CHANGE_ME_TO_A_RANDOM_STRING|${SEARXNG_SECRET}|" "$SEARXNG_SETTINGS"
    ok "Searxng secret key generated"
fi

# ── Inference provider ─────────────────────────────────────────────────────

echo ""
bold "Choose an inference provider:"
echo "  1) Ollama   — easiest to use, manages multiple models, frees VRAM when idle"
echo "  2) Llama.cpp — maximum performance, MTP support, holds VRAM until stopped"
echo ""
PROVIDER_CHOICE=$(ask "Enter 1 or 2 [default: 1]:")
PROVIDER_CHOICE=${PROVIDER_CHOICE:-1}

case "$PROVIDER_CHOICE" in
    2) PROVIDER=llamacpp ;;
    *) PROVIDER=ollama ;;
esac
ok "Provider: $PROVIDER"

# ── Model recommendation ───────────────────────────────────────────────────

echo ""
bold "Model recommendation for ${VRAM_GB}GB VRAM:"
info "$(recommend_model "$VRAM_GB")"
echo ""

DOWNLOAD_NOW=$(ask "Download the recommended model now? [Y/n]:")
DOWNLOAD_NOW=${DOWNLOAD_NOW:-Y}

if [[ "$DOWNLOAD_NOW" =~ ^[Yy]$ ]]; then
    if [[ "$PROVIDER" == "ollama" ]]; then
        if   (( VRAM_GB >= 16 )); then DEFAULT_MODEL="gemma4:12b"
        elif (( VRAM_GB >= 12 )); then DEFAULT_MODEL="qwen3.5:9b"
        elif (( VRAM_GB >=  8 )); then DEFAULT_MODEL="qwen3.5:7b"
        else                           DEFAULT_MODEL="qwen3.5:4b"
        fi
        MODEL=$(ask "Model tag [default: $DEFAULT_MODEL]:")
        MODEL=${MODEL:-$DEFAULT_MODEL}
        info "Will download after stack starts."
        info "Run: just download ollama model $MODEL"
    else
        if   (( VRAM_GB >= 12 )); then DEFAULT_MODEL="google/gemma-4-12B-it-qat-q4_0-gguf"
        else                           DEFAULT_MODEL="Qwen/Qwen2.5-7B-Instruct-GGUF"
        fi
        MODEL=$(ask "HuggingFace repo [default: $DEFAULT_MODEL]:")
        MODEL=${MODEL:-$DEFAULT_MODEL}
        info "Will download after stack starts."
        info "Run: just download llamacpp model $MODEL"
    fi
fi

# ── Local domains (optional) ───────────────────────────────────────────────

echo ""
bold "Local domains (optional):"
info "This adds *.localai entries to /etc/hosts and generates SSL certs with mkcert."
info "Gives you URLs like https://chat.localai instead of http://localhost:8086"
echo ""

SETUP_DOMAINS=$(ask "Set up local domains now? [y/N]:")
SETUP_DOMAINS=${SETUP_DOMAINS:-N}

if [[ "$SETUP_DOMAINS" =~ ^[Yy]$ ]]; then
    bash "$SCRIPT_DIR/setup-local-domains.sh"
fi

# ── Done ───────────────────────────────────────────────────────────────────

echo ""
bold "Setup complete!"
echo ""
info "Start the stack:     just up $PROVIDER"
if [[ "${MODEL:-}" != "" ]]; then
info "Then download model: just download $PROVIDER model $MODEL"
fi
info "Open chat UI:        http://localhost:${OPENWEBUI_PORT:-8086}"
echo ""
