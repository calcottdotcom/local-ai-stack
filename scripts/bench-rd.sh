#!/usr/bin/env bash
# R&D context benchmark — direct docker run, no project infrastructure.
# Usage:
#   bash scripts/bench-rd.sh f16      # standard image, f16 KV (default)
#   bash scripts/bench-rd.sh q4_0     # standard image, Q4_0 KV
#   bash scripts/bench-rd.sh turbo3   # TQ image, turbo3 KV (requires built image)
#   bash scripts/bench-rd.sh mtp      # TQ image, turbo3 + MTP head
# Custom sizes: bash scripts/bench-rd.sh f16 4096 8192 16384
set -euo pipefail

MODEL_12B="gemma-4-12B-it-qat-UD-Q4_K_XL.gguf"
MODEL_26B="gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf"
MTP_HEAD_12B="mtp-gemma-4-12B-it.gguf"
MODEL_QWEN35_9B="Qwen3.5-9B-Q4_K_M.gguf"
STD_IMAGE="ghcr.io/ggml-org/llama.cpp:server-cuda"
TQ_IMAGE="local-ai-stack/llamacpp-tq"
VOLUME="local-ai-stack_llamacpp-models"
PORT=18089
CONTAINER="bench-rd"

PHASE="${1:-f16}"
shift 2>/dev/null || true

# 26B: 14.25 GB model on 12 GB VRAM — need partial CPU offload.
# Gemma 4 26B A4B has 30 transformer layers, each with 128 MoE experts.
# At ~0.475 GB/layer: 20 layers = ~9.5 GB on GPU, leaving ~2.5 GB for KV + overhead.
# Override: GPU_LAYERS_26B=25 bash scripts/bench-rd.sh 26b
GPU_LAYERS_26B="${GPU_LAYERS_26B:-20}"

case "$PHASE" in
    f16)
        MODEL="$MODEL_12B"
        IMAGE="$STD_IMAGE"
        KV_TYPE="f16"
        GPU_LAYERS=99
        DEFAULT_SIZES="4096 8192 12288 16384 20480"
        EXTRA_ARGS=()
        ;;
    q4_0)
        MODEL="$MODEL_12B"
        IMAGE="$STD_IMAGE"
        KV_TYPE="q4_0"
        GPU_LAYERS=99
        DEFAULT_SIZES="16384 32768 49152 65536"
        EXTRA_ARGS=()
        ;;
    turbo3)
        MODEL="$MODEL_12B"
        IMAGE="$TQ_IMAGE"
        KV_TYPE="turbo3"
        GPU_LAYERS=99
        DEFAULT_SIZES="32768 65536 98304 131072"
        EXTRA_ARGS=(--flash-attn on)
        ;;
    26b)
        MODEL="$MODEL_26B"
        IMAGE="$STD_IMAGE"
        KV_TYPE="q4_0"
        GPU_LAYERS="$GPU_LAYERS_26B"
        DEFAULT_SIZES="4096 8192 16384 32768 65536"
        EXTRA_ARGS=()
        ;;
    26b-f16kv)
        MODEL="$MODEL_26B"
        IMAGE="$STD_IMAGE"
        KV_TYPE="f16"
        GPU_LAYERS="$GPU_LAYERS_26B"
        DEFAULT_SIZES="4096 8192 16384 32768"
        EXTRA_ARGS=()
        ;;
    mtp)
        MODEL="$MODEL_12B"
        IMAGE="$TQ_IMAGE"
        KV_TYPE="turbo3"
        GPU_LAYERS=99
        DEFAULT_SIZES="32768 65536 98304"
        EXTRA_ARGS=(--flash-attn on
            --spec-type draft-mtp
            --spec-draft-model "/models/$MTP_HEAD_12B"
            --spec-draft-ngl 99
            --spec-draft-n-max 3)
        ;;
    qwen35-9b)
        MODEL="$MODEL_QWEN35_9B"
        IMAGE="$STD_IMAGE"
        KV_TYPE="f16"
        GPU_LAYERS=99
        DEFAULT_SIZES="4096 8192 16384 32768 65536 131072 262144"
        EXTRA_ARGS=()
        ;;
    *)
        echo "Usage: bench-rd.sh [f16|q4_0|turbo3|26b|26b-f16kv|mtp|qwen35-9b] [sizes...]"
        exit 1
        ;;
esac

CTX_SIZES="${*:-$DEFAULT_SIZES}"

cleanup() {
    docker stop "$CONTAINER" 2>/dev/null || true
    docker rm "$CONTAINER" 2>/dev/null || true
}
trap cleanup EXIT

get_vram_gb() {
    local mib
    mib=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null \
          | head -1 | tr -d ' ') || { echo "N/A"; return; }
    python3 -c "print(f'{${mib}/1024:.1f} GB')"
}

bench_completion() {
    local port="$1" ctx="$2"
    local fill=$(( ctx * 60 / 100 ))
    python3 - "$port" "$fill" << 'PY'
import json, sys, urllib.request

port = sys.argv[1]
fill = int(sys.argv[2])
chunk = "The quick brown fox jumps over the lazy dog. " * 20
target = fill * 4
prompt = (chunk * (target // len(chunk) + 1))[:target]

body = json.dumps({
    "prompt":      prompt,
    "n_predict":   64,
    "temperature": 0,
}).encode()

req = urllib.request.Request(
    f"http://localhost:{port}/completion",
    data=body,
    headers={"Content-Type": "application/json"},
)
try:
    with urllib.request.urlopen(req, timeout=600) as r:
        data = json.loads(r.read())
        t = data.get("timings", {})
        pp = t.get("prompt_per_second", 0)
        tg = t.get("predicted_per_second", 0)
        print(f"{pp:.0f} {tg:.1f}")
except Exception as e:
    print(f"ERR: {e}", file=sys.stderr)
    print("0 0")
PY
}

printf "\nGemma 4 QAT — model: %s  phase: %s  gpu-layers: %s\n" "$MODEL" "$PHASE" "$GPU_LAYERS"
printf "%-10s  %-10s  %-8s  %-12s  %-12s  %s\n" \
    "CTX" "VRAM" "Load" "PP tok/s" "TG tok/s" "Status"
printf "%s\n" "----------  ----------  --------  ------------  ------------  --------"

for CTX in $CTX_SIZES; do
    # Ensure container from previous run is gone
    docker stop "$CONTAINER" 2>/dev/null || true
    docker rm   "$CONTAINER" 2>/dev/null || true

    LOAD_START=$(date +%s)

    docker run -d \
        --name "$CONTAINER" \
        --gpus all \
        -v "${VOLUME}:/models" \
        -p "${PORT}:8080" \
        "$IMAGE" \
        --model "/models/$MODEL" \
        --host 0.0.0.0 \
        --port 8080 \
        --ctx-size "$CTX" \
        --n-gpu-layers "$GPU_LAYERS" \
        -ctk "$KV_TYPE" \
        -ctv "$KV_TYPE" \
        "${EXTRA_ARGS[@]}" \
        2>/dev/null

    # Wait up to 3 min for health endpoint
    READY=false
    for _ in $(seq 1 90); do
        code=$(curl -sf -o /dev/null -w '%{http_code}' \
            "http://localhost:${PORT}/health" 2>/dev/null) || code=000
        [[ "$code" == "200" ]] && { READY=true; break; }
        sleep 2
    done

    LOAD_S="$(( $(date +%s) - LOAD_START ))s"

    if [[ "$READY" == "true" ]]; then
        VRAM=$(get_vram_gb)
        RESULT=$(bench_completion "$PORT" "$CTX" 2>/dev/null)
        PP=$(echo "$RESULT" | awk '{print $1}')
        TG=$(echo "$RESULT" | awk '{print $2}')
        [[ "$PP" == "0" ]] && STATUS="bench-err" || STATUS="OK"
    else
        VRAM="—"
        PP="—"
        TG="—"
        LOAD_S="—"
        STATUS="OOM/timeout"
    fi

    printf "%-10s  %-10s  %-8s  %-12s  %-12s  %s\n" \
        "$CTX" "$VRAM" "$LOAD_S" "$PP" "$TG" "$STATUS"

    docker stop "$CONTAINER" 2>/dev/null || true
    docker rm   "$CONTAINER" 2>/dev/null || true
    sleep 2
done

echo ""
