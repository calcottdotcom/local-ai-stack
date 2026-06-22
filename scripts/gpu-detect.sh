#!/usr/bin/env bash
# Outputs two lines: GPU_TYPE and VRAM_GB
# Sourced by setup.sh; can also be run standalone.

# Returns: linux | wsl | mac
detect_platform() {
    case "$(uname -s)" in
        Darwin) echo "mac" ;;
        Linux)
            if grep -qi "microsoft\|wsl" /proc/version 2>/dev/null; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        *) echo "linux" ;;
    esac
}

PLATFORM="$(detect_platform)"

# Cross-platform in-place sed: BSD sed (macOS) needs an explicit backup extension.
sedi() {
    if [[ "$PLATFORM" == "mac" ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

detect_gpu() {
    # macOS: Ollama runs on the host and uses Metal / unified memory.
    # We estimate usable RAM as 40% of total (OS + Docker take the rest).
    if [[ "$PLATFORM" == "mac" ]]; then
        local total_bytes
        total_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
        local total_gb=$(( total_bytes / 1024 / 1024 / 1024 ))
        GPU_TYPE=apple
        VRAM_GB=$(( total_gb * 2 / 5 ))   # ~40 % — conservative for shared RAM
        return 0
    fi

    if command -v nvidia-smi &>/dev/null; then
        local vram
        vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
        if [[ -n "$vram" ]]; then
            GPU_TYPE=nvidia
            VRAM_GB=$(( (vram + 512) / 1024 ))
            return 0
        fi
    fi

    if command -v rocm-smi &>/dev/null; then
        local vram_bytes
        vram_bytes=$(rocm-smi --showmeminfo vram --csv 2>/dev/null | awk -F',' 'NR==2{print $2}' | tr -d '[:space:]')
        if [[ -n "$vram_bytes" && "$vram_bytes" -gt 0 ]]; then
            GPU_TYPE=amd
            VRAM_GB=$(( vram_bytes / 1024 / 1024 / 1024 ))
            return 0
        fi
    fi

    GPU_TYPE=none
    VRAM_GB=0
    return 1
}

recommend_model() {
    local vram_gb=$1
    if   (( vram_gb >= 24 )); then echo "gemma4:12b (128K context with room to spare)"
    elif (( vram_gb >= 12 )); then echo "gemma4:12b"
    elif (( vram_gb >=  9 )); then echo "qwen3.5:9b"
    elif (( vram_gb >=  6 )); then echo "qwen3.5:7b"
    elif (( vram_gb >=  4 )); then echo "qwen3.5:4b (limited context — consider a smaller model)"
    else                            echo "No GPU or too little VRAM — CPU inference only (very slow)"
    fi
}

recommend_ctx() {
    local vram_gb=$1 model_size_gb=${2:-5}
    local free=$(( vram_gb - model_size_gb ))
    if   (( free >= 5 )); then echo 131072
    elif (( free >= 3 )); then echo 65536
    elif (( free >= 2 )); then echo 32768
    elif (( free >= 1 )); then echo 16384
    else                       echo 8192
    fi
}

# Run standalone
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    detect_gpu
    echo "Platform : $PLATFORM"
    echo "GPU type : $GPU_TYPE"
    echo "VRAM     : ${VRAM_GB}GB"
    echo "Suggested: $(recommend_model "$VRAM_GB")"
fi
