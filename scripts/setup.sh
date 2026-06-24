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

# ── Interactive list picker ────────────────────────────────────────────────

_PICK_OPTIONS=()
PICK_RESULT=""

_draw_pick() {
    local current=$1 i
    for i in "${!_PICK_OPTIONS[@]}"; do
        if (( i == current )); then
            printf "  \033[36m❯\033[0m \033[1m%s\033[0m\n" "${_PICK_OPTIONS[$i]}"
        else
            printf "    %s\n" "${_PICK_OPTIONS[$i]}"
        fi
    done
}

pick_from_list() {
    local sel=0 len=${#_PICK_OPTIONS[@]} key k2 k3 i

    # Non-interactive fallback (CI / piped input)
    if [[ ! -t 0 ]]; then
        PICK_RESULT="${_PICK_OPTIONS[0]}"
        return
    fi

    tput civis 2>/dev/null || true
    _draw_pick "$sel"

    while true; do
        IFS= read -rsn1 key
        if [[ "$key" == $'\x1b' ]]; then
            IFS= read -rsn1 -t 1 k2 || k2=""
            IFS= read -rsn1 -t 1 k3 || k3=""
            case "${k2}${k3}" in
                '[A') if [[ $sel -gt 0 ]]; then sel=$(( sel - 1 )); fi ;;
                '[B') if [[ $sel -lt $(( len - 1 )) ]]; then sel=$(( sel + 1 )); fi ;;
            esac
        elif [[ -z "$key" ]]; then
            break
        fi
        # Walk up one line and erase it for each menu item — no tput/TERM needed
        for (( i=0; i<len; i++ )); do
            printf '\033[A\033[2K'
        done
        _draw_pick "$sel"
    done

    tput cnorm 2>/dev/null || true
    PICK_RESULT="${_PICK_OPTIONS[$sel]}"
}

# ── Model selection ────────────────────────────────────────────────────────

MODEL=""

echo ""
if [[ "$PLATFORM" == "mac" ]]; then
    bold "Select a model to download (${TOTAL_RAM_GB}GB RAM Mac):"
else
    bold "Select a model to download (${VRAM_GB}GB VRAM):"
fi
if [[ "$PROVIDER" == "llamacpp" ]]; then
    info "Recommended: $(recommend_llamacpp_model "$VRAM_GB")"
else
    info "Recommended: $(recommend_model "$VRAM_GB")"
fi
info "Use ↑/↓ arrows and Enter to select"
echo ""

if [[ "$PROVIDER" == "ollama" ]]; then
    _PICK_OPTIONS=()
    if   (( VRAM_GB >= 12 )); then
        _PICK_OPTIONS=("gemma4:12b" "qwen3.5:9b" "qwen3.5:7b" "qwen3.5:4b")
    elif (( VRAM_GB >= 9 )); then
        _PICK_OPTIONS=("qwen3.5:9b" "gemma4:12b" "qwen3.5:7b" "qwen3.5:4b")
    elif (( VRAM_GB >= 6 )); then
        _PICK_OPTIONS=("qwen3.5:7b" "qwen3.5:9b" "qwen3.5:4b")
    else
        _PICK_OPTIONS=("qwen3.5:4b" "qwen3.5:7b")
    fi
    _PICK_OPTIONS+=("Enter model tag manually..." "Skip — I'll download a model later")

    pick_from_list

    case "$PICK_RESULT" in
        "Enter model tag manually...")
            MODEL=$(ask "Model tag (e.g. qwen3.5:9b):")
            ;;
        "Skip — I'll download a model later")
            MODEL=""
            ;;
        *)
            MODEL="$PICK_RESULT"
            ok "Selected: $MODEL"
            ;;
    esac
else
    # llamacpp: options are HuggingFace repos; download-model.sh handles the rest
    _PICK_OPTIONS=()
    if (( VRAM_GB >= 12 )); then
        _PICK_OPTIONS=(
            "unsloth/gemma-4-26B-A4B-it-qat-GGUF"
            "unsloth/gemma-4-12b-it-qat-GGUF"
        )
    elif (( VRAM_GB >= 8 )); then
        _PICK_OPTIONS=(
            "unsloth/gemma-4-12b-it-qat-GGUF"
            "Qwen/Qwen2.5-7B-Instruct-GGUF"
        )
    else
        _PICK_OPTIONS=(
            "Qwen/Qwen2.5-7B-Instruct-GGUF"
        )
    fi
    _PICK_OPTIONS+=(
        "Enter HuggingFace repo manually..."
        "Skip — I'll download a model later"
    )

    pick_from_list

    case "$PICK_RESULT" in
        "Enter HuggingFace repo manually...")
            MODEL=$(ask "HuggingFace repo (e.g. unsloth/gemma-4-26B-A4B-it-qat-GGUF):")
            ;;
        "Skip — I'll download a model later")
            MODEL=""
            ;;
        *)
            MODEL="$PICK_RESULT"
            ok "Selected: $MODEL"
            ;;
    esac
fi

# ── Local domains (optional) ───────────────────────────────────────────────

echo ""
bold "Local domains (optional):"
info "This generates SSL certs with mkcert and adds *.localai entries to your hosts file."
if [[ "$PLATFORM" == "wsl" ]]; then
    info "On WSL: a UAC prompt will import the CA into the Windows cert store and update"
    info "the Windows hosts file so your browser can reach https://*.localai."
fi
info "Gives you URLs like https://chat.localai instead of http://localhost:8086"
echo ""

SETUP_DOMAINS=$(ask "Set up local domains now? [y/N]:")
SETUP_DOMAINS=${SETUP_DOMAINS:-N}

if [[ "$SETUP_DOMAINS" =~ ^[Yy]$ ]]; then
    bash "$SCRIPT_DIR/setup-local-domains.sh"
fi

# ── Launch ─────────────────────────────────────────────────────────────────

echo ""
bold "Setup complete!"
echo ""

START_NOW=$(ask "Start the stack now? [Y/n]:")
START_NOW=${START_NOW:-Y}

if [[ "$START_NOW" =~ ^[Yy]$ ]]; then
    if [[ -n "$MODEL" && "$PROVIDER" == "llamacpp" ]]; then
        # llamacpp needs the model file present before the container will start
        info "Downloading model (this may take several minutes)..."
        (cd "$ROOT_DIR" && just download "$PROVIDER" model "$MODEL")
    fi

    info "Starting stack..."
    (cd "$ROOT_DIR" && just up "$PROVIDER")

    if [[ -n "$MODEL" && "$PROVIDER" == "ollama" ]]; then
        # ollama: service must be running before we can pull
        info "Downloading model..."
        (cd "$ROOT_DIR" && just download "$PROVIDER" model "$MODEL")
    fi

    echo ""
    ok "Stack is running!"
    info "Open chat UI: http://localhost:${OPENWEBUI_PORT:-8086}"
    [[ -n "$MODEL" ]] && info "Model: $MODEL"
else
    echo ""
    info "When you're ready:"
    if [[ -n "$MODEL" && "$PROVIDER" == "llamacpp" ]]; then
        info "  just download $PROVIDER model $MODEL"
    fi
    info "  just up $PROVIDER"
    if [[ -n "$MODEL" && "$PROVIDER" == "ollama" ]]; then
        info "  just download $PROVIDER model $MODEL"
    fi
    info "Open chat UI: http://localhost:${OPENWEBUI_PORT:-8086}"
fi
echo ""
