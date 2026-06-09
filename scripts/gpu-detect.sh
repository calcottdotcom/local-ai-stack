#!/usr/bin/env bash
# Outputs two lines: GPU_TYPE and VRAM_GB
# Sourced by setup.sh; can also be run standalone.

detect_gpu() {
    if command -v nvidia-smi &>/dev/null; then
        local vram
        vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
        if [[ -n "$vram" ]]; then
            GPU_TYPE=nvidia
            VRAM_GB=$(( vram / 1024 ))
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
    elif (( vram_gb >= 15 )); then echo "gemma4:12b"
    elif (( vram_gb >= 12 )); then echo "qwen3.5:9b"
    elif (( vram_gb >=  8 )); then echo "qwen3.5:7b"
    elif (( vram_gb >=  6 )); then echo "qwen3.5:4b (limited context — consider a smaller model)"
    else                            echo "No GPU or too little VRAM — CPU inference only (very slow)"
    fi
}

recommend_ctx() {
    local vram_gb=$1 model_size_gb=${2:-5}
    local free=$(( vram_gb - model_size_gb ))
    if   (( free >= 6 )); then echo 131072
    elif (( free >= 3 )); then echo 65536
    elif (( free >= 2 )); then echo 32768
    elif (( free >= 1 )); then echo 16384
    else                       echo 8192
    fi
}

# Run standalone
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    detect_gpu
    echo "GPU type : $GPU_TYPE"
    echo "VRAM     : ${VRAM_GB}GB"
    echo "Suggested: $(recommend_model "$VRAM_GB")"
fi
