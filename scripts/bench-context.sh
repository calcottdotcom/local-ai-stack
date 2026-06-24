#!/usr/bin/env bash
# Context window benchmark for llama.cpp.
# Spins up llamacpp at each context size, fills the KV cache, and reports
# prompt-processing speed, generation speed, and VRAM usage.
#
# Usage:
#   bash scripts/bench-context.sh                              # TQ fork, default ladder
#   bash scripts/bench-context.sh llamacpp                    # standard image
#   bash scripts/bench-context.sh llamacpp-tq 32768 65536 131072
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

source "$ROOT_DIR/.env" 2>/dev/null || { echo "Run 'just setup' first"; exit 1; }
source "$SCRIPT_DIR/gpu-detect.sh"

VARIANT="${1:-llamacpp-tq}"
shift || true

[[ -f "$ROOT_DIR/docker/docker-compose.${VARIANT}.yml" ]] || {
    echo "Unknown variant: $VARIANT (docker/docker-compose.${VARIANT}.yml not found)"
    exit 1
}
[[ -n "${LLAMACPP_MODEL:-}" ]] || {
    echo "No model set. Run: just download llamacpp model <hf-repo>"
    exit 1
}

# Default ladders differ: standard image runs OOM around 32K, TQ can reach 128K+
if [[ "$VARIANT" == "llamacpp-tq" ]]; then
    DEFAULT_SIZES="8192 16384 32768 65536 98304 131072"
else
    DEFAULT_SIZES="8192 16384 24576 32768 40960"
fi
CTX_SIZES="${*:-$DEFAULT_SIZES}"

BENCH_PORT=18089
GPU="${GPU_TYPE:-nvidia}"

# ── Helpers ───────────────────────────────────────────────────────────────────

bold()  { printf "\033[1m%s\033[0m" "$*"; }
green() { printf "\033[32m%s\033[0m" "$*"; }
red()   { printf "\033[31m%s\033[0m" "$*"; }

get_vram_gb() {
    local mib
    mib=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null \
          | head -1 | tr -d ' ') || { echo "N/A"; return; }
    python3 -c "print(f'{int(\"${mib}\")/1024:.1f} GB')"
}

# Write Python benchmark helper to a temp file (avoids heredoc quoting issues)
PY_BENCH=$(mktemp /tmp/bench_req.XXXXXX.py)
trap 'rm -f "$PY_BENCH"' EXIT
cat > "$PY_BENCH" << 'PYEOF'
import json, sys, urllib.request

port      = sys.argv[1]
fill_tok  = int(sys.argv[2])

# Rough estimate: 1 token ≈ 4 chars for English text
chunk  = "The quick brown fox jumps over the lazy dog. " * 20
target = fill_tok * 4
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
    with urllib.request.urlopen(req, timeout=300) as r:
        print(r.read().decode())
except Exception as e:
    print("{}", file=sys.stderr)
PYEOF

parse_timings() {
    local field="$1"
    python3 - "$field" << 'PYEOF'
import json, sys
data = json.load(sys.stdin)
field = sys.argv[1]
v = data.get("timings", {}).get(field, 0)
print(f"{v:.0f}" if field == "prompt_per_second" else f"{v:.1f}") if v else print("—")
PYEOF
}

# ── Compose args for this variant (project name = local-ai-stack via --project-directory) ──
dc_args=(
    --project-directory "$ROOT_DIR"
    -f "$ROOT_DIR/docker/docker-compose.${VARIANT}.yml"
    -f "$ROOT_DIR/docker/docker-compose.gpu-${GPU}-${VARIANT}.yml"
)

# ── Header ────────────────────────────────────────────────────────────────────
echo ""
bold "Context benchmark: $VARIANT  |  model: $LLAMACPP_MODEL  |  GPU: ${GPU}"
echo ""
printf "%-10s  %-10s  %-7s  %-12s  %-12s  %s\n" \
    "CTX" "VRAM" "Load" "PP tok/s" "TG tok/s" "Status"
printf "%-10s  %-10s  %-7s  %-12s  %-12s  %s\n" \
    "----------" "----------" "-------" "------------" "------------" "--------"

# ── Main loop ─────────────────────────────────────────────────────────────────
for CTX in $CTX_SIZES; do
    STATUS=""
    PP="—"
    TG="—"
    VRAM="—"
    LOAD_S="—"

    LOAD_START=$(date +%s)

    # Start just the llamacpp service with this context size and a dedicated port
    LLAMACPP_CTX="$CTX" LLAMACPP_PORT="$BENCH_PORT" \
        docker compose "${dc_args[@]}" up -d llamacpp 2>/dev/null

    # Wait up to 3 minutes for the health endpoint
    READY=false
    for _ in $(seq 1 90); do
        code=$(curl -s -o /dev/null -w '%{http_code}' \
            "http://localhost:${BENCH_PORT}/health" 2>/dev/null || echo 000)
        if [[ "$code" == "200" ]]; then READY=true; break; fi
        sleep 2
    done

    LOAD_S="$(( $(date +%s) - LOAD_START ))s"

    if [[ "$READY" == "true" ]]; then
        VRAM=$(get_vram_gb)

        # Fill 60% of the context window, generate 64 tokens
        FILL=$(( CTX * 60 / 100 ))
        RESULT=$(python3 "$PY_BENCH" "$BENCH_PORT" "$FILL" 2>/dev/null || echo "{}")

        PP=$(echo "$RESULT" | parse_timings prompt_per_second 2>/dev/null || echo "—")
        TG=$(echo "$RESULT" | parse_timings predicted_per_second 2>/dev/null || echo "—")
        STATUS=$(green "✓")
    else
        STATUS=$(red "✗ OOM / timeout")
        VRAM="—"
        LOAD_S="—"
    fi

    printf "%-10s  %-10s  %-7s  %-12s  %-12s  %b\n" \
        "$CTX" "$VRAM" "$LOAD_S" "$PP" "$TG" "$STATUS"

    # Tear down before the next context size
    LLAMACPP_CTX="$CTX" LLAMACPP_PORT="$BENCH_PORT" \
        docker compose "${dc_args[@]}" down llamacpp 2>/dev/null
    sleep 2
done

echo ""
