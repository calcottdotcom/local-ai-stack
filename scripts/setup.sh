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

if [[ "$PLATFORM" == "wsl" ]]; then
    info "Detected: Windows (WSL2)"
elif [[ "$PLATFORM" == "mac" ]]; then
    info "Detected: macOS"
fi

missing=()
command -v docker &>/dev/null || missing+=("docker")
command -v just   &>/dev/null || missing+=("just")

if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Missing required tools: ${missing[*]}"
    echo ""
    for tool in "${missing[@]}"; do
        case "$tool" in
            docker)
                warn "docker — install Docker Desktop:"
                if [[ "$PLATFORM" == "wsl" ]]; then
                    info "https://docs.docker.com/desktop/setup/install/windows-install/"
                    info "Enable 'Use WSL 2 based engine' in Docker Desktop → Settings → General"
                    info "Then enable your WSL distro under Settings → Resources → WSL Integration"
                elif [[ "$PLATFORM" == "mac" ]]; then
                    info "https://docs.docker.com/desktop/setup/install/mac-install/"
                else
                    info "https://docs.docker.com/engine/install/"
                fi
                ;;
            just)
                warn "just — install the command runner:"
                if [[ "$PLATFORM" == "wsl" || "$PLATFORM" == "linux" ]]; then
                    info "Ubuntu/Debian:  sudo apt install just"
                    info "Universal:      curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to ~/.local/bin"
                    if [[ "$PLATFORM" == "wsl" ]]; then
                        info "(Run these commands inside your WSL terminal, not PowerShell)"
                    fi
                elif [[ "$PLATFORM" == "mac" ]]; then
                    info "Homebrew:  brew install just"
                fi
                ;;
        esac
    done
    echo ""
    warn "Re-run this script once the above are installed."
    exit 1
fi
ok "docker and just are installed"

# On macOS, Ollama runs on the host — check it is installed
if [[ "$PLATFORM" == "mac" ]]; then
    if ! command -v ollama &>/dev/null; then
        echo ""
        warn "Ollama is not installed on this Mac."
        info "On macOS, Ollama runs natively (not in Docker) so it can use Metal acceleration."
        info "Install it from:  https://ollama.com/download/mac"
        info "Or via Homebrew:  brew install ollama"
        echo ""
        warn "Install Ollama, start it (it lives in your menu bar), then re-run this setup."
        exit 1
    fi
    ok "Ollama installed on host"
fi

# ── GPU / RAM detection ────────────────────────────────────────────────────

echo ""
bold "Detecting hardware..."
detect_gpu || true

if [[ "$PLATFORM" == "mac" ]]; then
    TOTAL_RAM_GB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))
    ok "macOS — total RAM: ${TOTAL_RAM_GB}GB (Ollama uses ~40% after OS + Docker overhead)"
    info "Recommended model: $(recommend_model "$VRAM_GB")"
elif [[ "$GPU_TYPE" == "none" ]]; then
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
    sedi "s|^GPU_TYPE=.*|GPU_TYPE=${GPU_TYPE}|" "$ROOT_DIR/.env"

    # On macOS, wire Ollama to the host
    if [[ "$PLATFORM" == "mac" ]]; then
        sedi "s|^INFERENCE_BASE_URL=.*|INFERENCE_BASE_URL=http://host.docker.internal:11434/v1|" "$ROOT_DIR/.env"
        sedi "s|^OLLAMA_BASE_URL=.*|OLLAMA_BASE_URL=http://host.docker.internal:11434|" "$ROOT_DIR/.env"
        sedi "s|^INFERENCE_PROVIDER=.*|INFERENCE_PROVIDER=ollama|" "$ROOT_DIR/.env"
    fi

    # Stamp host UID/GID for hermes-webui volume permissions
    HOST_UID=$(id -u)
    HOST_GID=$(id -g)
    sedi "s|^HOST_UID=.*|HOST_UID=${HOST_UID}|" "$ROOT_DIR/.env"
    sedi "s|^HOST_GID=.*|HOST_GID=${HOST_GID}|" "$ROOT_DIR/.env"

    # Generate OD_API_TOKEN
    OD_TOKEN=$(openssl rand -hex 32)
    sedi "s|^OD_API_TOKEN=.*|OD_API_TOKEN=${OD_TOKEN}|" "$ROOT_DIR/.env"

    ok ".env created"
fi

# ── Searxng secret key ─────────────────────────────────────────────────────

SEARXNG_SETTINGS="$ROOT_DIR/config/searxng/settings.yml"
if grep -q "CHANGE_ME_TO_A_RANDOM_STRING" "$SEARXNG_SETTINGS" 2>/dev/null; then
    SEARXNG_SECRET=$(openssl rand -hex 32)
    sedi "s|CHANGE_ME_TO_A_RANDOM_STRING|${SEARXNG_SECRET}|" "$SEARXNG_SETTINGS"
    ok "Searxng secret key generated"
fi

# ── Inference provider ─────────────────────────────────────────────────────

echo ""
if [[ "$PLATFORM" == "mac" ]]; then
    # macOS: Ollama on host is the only supported option
    PROVIDER=ollama
    ok "Provider: ollama (running on Mac host via host.docker.internal)"
else
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
fi

# ── Model recommendation ───────────────────────────────────────────────────

echo ""
if [[ "$PLATFORM" == "mac" ]]; then
    bold "Model recommendation for ${TOTAL_RAM_GB}GB RAM Mac:"
else
    bold "Model recommendation for ${VRAM_GB}GB VRAM:"
fi
info "$(recommend_model "$VRAM_GB")"
echo ""

DOWNLOAD_NOW=$(ask "Download the recommended model now? [Y/n]:")
DOWNLOAD_NOW=${DOWNLOAD_NOW:-Y}

if [[ "$DOWNLOAD_NOW" =~ ^[Yy]$ ]]; then
    if [[ "$PROVIDER" == "ollama" ]]; then
        if   (( VRAM_GB >= 15 )); then DEFAULT_MODEL="gemma4:12b"
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
