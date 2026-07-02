set shell := ["bash", "-euo", "pipefail", "-c"]

# Base docker compose command — sets project root so bind-mount paths in
# compose files resolve relative to the repo root, not docker/.
dc := "docker compose --project-directory ."

# Directory prefix for compose files
cf := "docker/"

# Show available commands
default:
    @just --list

# ── Stack management ───────────────────────────────────────────────────────

# Start the stack: just up ollama | llamacpp | comfy
up provider:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ -f .env ]] || { echo "Run 'just setup' first to initialise .env"; exit 1; }
    source .env
    source scripts/gpu-detect.sh
    GPU="${GPU_TYPE:-nvidia}"

    case "{{provider}}" in
    ollama)
        if [[ -n "$(docker ps -q --filter name=llamacpp 2>/dev/null)" ]]; then
            echo "Stopping llamacpp before starting ollama..."
            if [[ "$PLATFORM" != "mac" ]]; then
                {{dc}} -f {{cf}}docker-compose.yml -f {{cf}}docker-compose.llamacpp.yml \
                    -f "{{cf}}docker-compose.gpu-${GPU}-llamacpp.yml" down llamacpp 2>/dev/null || true
            fi
        fi
        if [[ "$PLATFORM" == "mac" ]]; then
            # Ollama runs on the Mac host — no ollama container or GPU overlay
            sedi "s|^INFERENCE_PROVIDER=.*|INFERENCE_PROVIDER=ollama|"                                .env
            sedi "s|^INFERENCE_BASE_URL=.*|INFERENCE_BASE_URL=http://host.docker.internal:11434/v1|" .env
            sedi "s|^OLLAMA_BASE_URL=.*|OLLAMA_BASE_URL=http://host.docker.internal:11434|"          .env
            [[ -n "${OLLAMA_MODEL:-}" ]] && \
                sedi "s|^INFERENCE_MODEL=.*|INFERENCE_MODEL=${OLLAMA_MODEL}|" .env || true
            {{dc}} -f {{cf}}docker-compose.yml up -d
            echo "Waiting for Ollama to be ready (host port 11434)..."
            for i in $(seq 1 45); do
                if curl -sf "http://localhost:11434/api/tags" > /dev/null 2>&1; then
                    echo "✓ Ollama ready — http://localhost:11434"
                    break
                fi
                if [[ $i -eq 45 ]]; then
                    echo "! Ollama is not responding on localhost:11434"
                    echo "  Make sure Ollama is installed and running: https://ollama.com/download/mac"
                fi
                sleep 2
            done
        else
            sedi "s|^INFERENCE_PROVIDER=.*|INFERENCE_PROVIDER=ollama|"              .env
            sedi "s|^INFERENCE_BASE_URL=.*|INFERENCE_BASE_URL=http://ollama:11434/v1|" .env
            sedi "s|^OLLAMA_BASE_URL=.*|OLLAMA_BASE_URL=http://ollama:11434|"        .env
            sedi "s|^OPENAI_API_BASE_URL=.*|OPENAI_API_BASE_URL=|"                  .env
            [[ -n "${OLLAMA_MODEL:-}" ]] && \
                sedi "s|^INFERENCE_MODEL=.*|INFERENCE_MODEL=${OLLAMA_MODEL}|" .env || true
            {{dc}} \
                -f {{cf}}docker-compose.yml \
                -f {{cf}}docker-compose.ollama.yml \
                -f "{{cf}}docker-compose.gpu-${GPU}-ollama.yml" \
                up -d
            PORT="${OLLAMA_PORT:-11435}"
            echo "Waiting for Ollama to be ready..."
            for i in $(seq 1 45); do
                if curl -sf "http://localhost:${PORT}/api/tags" > /dev/null 2>&1; then
                    echo "✓ Ollama ready — http://localhost:${PORT}"
                    break
                fi
                [[ $i -lt 45 ]] && sleep 2 || echo "! Ollama still starting — check: just logs ollama"
            done
        fi
        ;;
    llamacpp)
        if [[ "$PLATFORM" == "mac" ]]; then
            echo "Llama.cpp is not supported on macOS. Use 'just up ollama' instead."
            exit 1
        fi
        [[ -n "${LLAMACPP_MODEL:-}" ]] || {
            echo "No model set. Run: just download llamacpp model <huggingface-repo>"
            exit 1
        }
        if [[ -n "$(docker ps -q --filter name=ollama 2>/dev/null)" ]]; then
            echo "Stopping ollama before starting llamacpp..."
            {{dc}} -f {{cf}}docker-compose.yml -f {{cf}}docker-compose.ollama.yml \
                -f "{{cf}}docker-compose.gpu-${GPU}-ollama.yml" down ollama 2>/dev/null || true
        fi
        sedi "s|^INFERENCE_PROVIDER=.*|INFERENCE_PROVIDER=llamacpp|"                .env
        sedi "s|^INFERENCE_BASE_URL=.*|INFERENCE_BASE_URL=http://llamacpp:8080/v1|" .env
        sedi "s|^OLLAMA_BASE_URL=.*|OLLAMA_BASE_URL=|"                              .env
        sedi "s|^OPENAI_API_BASE_URL=.*|OPENAI_API_BASE_URL=http://llamacpp:8080/v1|" .env
        [[ -n "${LLAMACPP_MODEL:-}" ]] && \
            sedi "s|^INFERENCE_MODEL=.*|INFERENCE_MODEL=${LLAMACPP_MODEL}|" .env || true
        {{dc}} \
            -f {{cf}}docker-compose.yml \
            -f {{cf}}docker-compose.llamacpp.yml \
            -f "{{cf}}docker-compose.gpu-${GPU}-llamacpp.yml" \
            up -d
        PORT="${LLAMACPP_PORT:-8089}"
        echo "Waiting for Llama.cpp to load model (this can take several minutes)..."
        for i in $(seq 1 150); do
            HTTP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${PORT}/health" 2>/dev/null || echo "000")
            if [[ "$HTTP_STATUS" == "200" ]]; then
                echo "✓ Llama.cpp ready — http://localhost:${PORT}"
                break
            fi
            [[ $i -lt 150 ]] && sleep 2 || echo "! Llama.cpp still loading after 5m — check: just logs llamacpp"
        done
        ;;
    llamacpp-tq)
        if [[ "$PLATFORM" == "mac" ]]; then
            echo "Llama.cpp TurboQuant is not supported on macOS."
            exit 1
        fi
        [[ -n "${LLAMACPP_MODEL:-}" ]] || {
            echo "No model set. Run: just download llamacpp model <huggingface-repo>"
            exit 1
        }
        if [[ -n "$(docker ps -q --filter name=llamacpp 2>/dev/null)" ]]; then
            echo "Stopping llamacpp before starting llamacpp-tq..."
            {{dc}} -f {{cf}}docker-compose.llamacpp.yml \
                -f "{{cf}}docker-compose.gpu-${GPU}-llamacpp.yml" down llamacpp 2>/dev/null || true
        fi
        if [[ -n "$(docker ps -q --filter name=ollama 2>/dev/null)" ]]; then
            echo "Stopping ollama before starting llamacpp-tq..."
            {{dc}} -f {{cf}}docker-compose.yml -f {{cf}}docker-compose.ollama.yml \
                -f "{{cf}}docker-compose.gpu-${GPU}-ollama.yml" down ollama 2>/dev/null || true
        fi
        sedi "s|^INFERENCE_PROVIDER=.*|INFERENCE_PROVIDER=llamacpp-tq|"                .env
        sedi "s|^INFERENCE_BASE_URL=.*|INFERENCE_BASE_URL=http://llamacpp:8080/v1|" .env
        sedi "s|^OLLAMA_BASE_URL=.*|OLLAMA_BASE_URL=|"                              .env
        sedi "s|^OPENAI_API_BASE_URL=.*|OPENAI_API_BASE_URL=http://llamacpp:8080/v1|" .env
        [[ -n "${LLAMACPP_MODEL:-}" ]] && \
            sedi "s|^INFERENCE_MODEL=.*|INFERENCE_MODEL=${LLAMACPP_MODEL}|" .env || true
        echo "Starting Llama.cpp TurboQuant (first run builds from source — allow ~30 min)..."
        {{dc}} \
            -f {{cf}}docker-compose.yml \
            -f {{cf}}docker-compose.llamacpp-tq.yml \
            -f "{{cf}}docker-compose.gpu-${GPU}-llamacpp-tq.yml" \
            up -d
        PORT="${LLAMACPP_PORT:-8089}"
        echo "Waiting for Llama.cpp TurboQuant to load model..."
        for i in $(seq 1 150); do
            HTTP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${PORT}/health" 2>/dev/null || echo "000")
            if [[ "$HTTP_STATUS" == "200" ]]; then
                echo "✓ Llama.cpp TurboQuant ready — http://localhost:${PORT}"
                break
            fi
            [[ $i -lt 150 ]] && sleep 2 || echo "! Llama.cpp TurboQuant still loading — check: just logs llamacpp"
        done
        ;;
    comfy)
        if [[ "$PLATFORM" == "mac" ]]; then
            echo "ComfyUI GPU passthrough is not supported on macOS."
            exit 1
        fi
        echo "Note: ComfyUI uses the GPU. If running alongside llamacpp on a single GPU, VRAM will be shared."
        {{dc}} \
            -f {{cf}}docker-compose.yml \
            -f {{cf}}docker-compose.comfy.yml \
            -f "{{cf}}docker-compose.gpu-${GPU}-comfy.yml" \
            up -d comfyui
        ;;
    *)
        echo "Usage: just up [ollama|llamacpp|llamacpp-tq|comfy]"
        exit 1
        ;;
    esac

# Stop all running services
down:
    #!/usr/bin/env bash
    source .env 2>/dev/null || true
    source scripts/gpu-detect.sh
    GPU="${GPU_TYPE:-nvidia}"
    PROVIDER="${INFERENCE_PROVIDER:-ollama}"
    compose_args=(-f {{cf}}docker-compose.yml)
    if [[ "$PLATFORM" != "mac" || "$PROVIDER" != "ollama" ]]; then
        compose_args+=(-f "{{cf}}docker-compose.${PROVIDER}.yml" -f "{{cf}}docker-compose.gpu-${GPU}-${PROVIDER}.yml")
    fi
    {{dc}} "${compose_args[@]}" down

# Restart a service (e.g. just restart openwebui) or all services (just restart all)
restart service="all":
    #!/usr/bin/env bash
    source .env 2>/dev/null || true
    source scripts/gpu-detect.sh
    GPU="${GPU_TYPE:-nvidia}"
    PROVIDER="${INFERENCE_PROVIDER:-ollama}"
    compose_args=(-f {{cf}}docker-compose.yml)
    if [[ "$PLATFORM" != "mac" || "$PROVIDER" != "ollama" ]]; then
        compose_args+=(-f "{{cf}}docker-compose.${PROVIDER}.yml" -f "{{cf}}docker-compose.gpu-${GPU}-${PROVIDER}.yml")
    fi
    target="{{service}}"
    [[ "$target" == "all" ]] && target=""
    restart_args=()
    [[ -n "$target" ]] && restart_args+=("$target")
    {{dc}} "${compose_args[@]}" restart "${restart_args[@]}"

# Show status of all local-ai-stack containers
status:
    docker ps --filter label=com.docker.compose.project=local-ai-stack

# Follow logs (optionally for a single service)
logs service="":
    #!/usr/bin/env bash
    source .env 2>/dev/null || true
    source scripts/gpu-detect.sh
    GPU="${GPU_TYPE:-nvidia}"
    PROVIDER="${INFERENCE_PROVIDER:-ollama}"
    compose_args=(-f {{cf}}docker-compose.yml)
    if [[ "$PLATFORM" != "mac" || "$PROVIDER" != "ollama" ]]; then
        compose_args+=(-f "{{cf}}docker-compose.${PROVIDER}.yml" -f "{{cf}}docker-compose.gpu-${GPU}-${PROVIDER}.yml")
    fi
    if [[ -z "{{service}}" ]]; then
        {{dc}} "${compose_args[@]}" logs -f
    else
        {{dc}} "${compose_args[@]}" logs -f {{service}}
    fi

# Rebuild one or all custom images: just build | just build hermes
build service="":
    #!/usr/bin/env bash
    set -euo pipefail
    source .env 2>/dev/null || true
    source scripts/gpu-detect.sh
    GPU="${GPU_TYPE:-nvidia}"
    PROVIDER="${INFERENCE_PROVIDER:-ollama}"
    compose_args=(-f {{cf}}docker-compose.yml)
    if [[ "$PLATFORM" != "mac" || "$PROVIDER" != "ollama" ]]; then
        compose_args+=(-f "{{cf}}docker-compose.${PROVIDER}.yml" -f "{{cf}}docker-compose.gpu-${GPU}-${PROVIDER}.yml")
    fi
    if [[ -n "{{service}}" ]]; then
        echo "Building {{service}}..."
        {{dc}} "${compose_args[@]}" build {{service}}
    else
        echo "Building all custom images..."
        {{dc}} "${compose_args[@]}" build
    fi

# Pull latest code, rebuild images, and restart the running stack
update:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ -f .env ]] || { echo "Run 'just setup' first"; exit 1; }
    source .env
    source scripts/gpu-detect.sh
    GPU="${GPU_TYPE:-nvidia}"
    PROVIDER="${INFERENCE_PROVIDER:-ollama}"
    compose_args=(-f {{cf}}docker-compose.yml)
    if [[ "$PLATFORM" != "mac" || "$PROVIDER" != "ollama" ]]; then
        compose_args+=(-f "{{cf}}docker-compose.${PROVIDER}.yml" -f "{{cf}}docker-compose.gpu-${GPU}-${PROVIDER}.yml")
    fi
    echo "Pulling latest code..."
    git pull
    echo "Rebuilding images..."
    {{dc}} "${compose_args[@]}" build
    echo "Restarting stack..."
    {{dc}} "${compose_args[@]}" up -d --remove-orphans
    echo "Done — stack updated and restarted."

# ── Model management ───────────────────────────────────────────────────────

# Download a model: just download ollama model qwen3.5:9b
# Download a model: just download llamacpp model google/gemma-4-12B-it-qat-q4_0-gguf
download provider type model:
    @bash scripts/download-model.sh "{{provider}}" "{{model}}"

# Set the active llamacpp model by filename (called automatically by download)
set provider model:
    #!/usr/bin/env bash
    source scripts/gpu-detect.sh
    if [[ "{{provider}}" == "llamacpp" ]]; then
        sedi "s|^LLAMACPP_MODEL=.*|LLAMACPP_MODEL={{model}}|" .env
        echo "Active llamacpp model: {{model}}"
        echo "Start the stack with: just up llamacpp"
    else
        echo "Usage: just set llamacpp <model-filename>"
        exit 1
    fi

# ── Agents ─────────────────────────────────────────────────────────────────

# Open a shell in the hermes container: just hermes ssh
hermes action="ssh":
    #!/usr/bin/env bash
    case "{{action}}" in
        ssh) docker exec -it -u hermes hermes bash ;;
        *)   docker exec -it -u hermes hermes {{action}} ;;
    esac

# Open a shell in the pi container: just pi ssh
pi action="ssh":
    #!/usr/bin/env bash
    case "{{action}}" in
        ssh) docker exec -it -u pi pi bash ;;
        *)   docker exec -it -u pi pi {{action}} ;;
    esac

# ── Setup ──────────────────────────────────────────────────────────────────

# Interactive setup wizard (or: just setup local-domains)
setup target="":
    #!/usr/bin/env bash
    case "{{target}}" in
        local-domains) bash scripts/setup-local-domains.sh ;;
        *)             bash scripts/setup.sh ;;
    esac

# ── Tests (mirrors CI) ────────────────────────────────────────────────────

# Run all tests — same checks as the CI workflow (lint only; for live inference test: just test-inference)
test: test-compose test-dockerfiles test-scripts test-nginx test-justfile test-vram
    @echo ""
    @echo "All tests passed."

# Validate every compose file combination
test-compose:
    #!/usr/bin/env bash
    set -euo pipefail
    # Use a temp env so we never clobber the real .env
    TMPENV=$(mktemp)
    trap 'rm -f "$TMPENV"' EXIT
    # Strip OD_API_TOKEN from example and append a non-empty value.
    # Avoids sed -i portability differences between macOS and Linux.
    grep -v '^OD_API_TOKEN=' .env.example > "$TMPENV"
    echo "OD_API_TOKEN=ci-test-$(openssl rand -hex 8)" >> "$TMPENV"

    check() {
        echo "  → $*"
        {{dc}} --env-file "$TMPENV" "$@" config --quiet
    }

    echo "Validating compose files..."
    check -f {{cf}}docker-compose.yml -f {{cf}}docker-compose.ollama.yml   -f {{cf}}docker-compose.gpu-nvidia-ollama.yml
    check -f {{cf}}docker-compose.yml -f {{cf}}docker-compose.ollama.yml   -f {{cf}}docker-compose.gpu-amd-ollama.yml
    check -f {{cf}}docker-compose.yml -f {{cf}}docker-compose.llamacpp.yml -f {{cf}}docker-compose.gpu-nvidia-llamacpp.yml
    check -f {{cf}}docker-compose.yml -f {{cf}}docker-compose.llamacpp.yml -f {{cf}}docker-compose.gpu-amd-llamacpp.yml
    check -f {{cf}}docker-compose.yml -f {{cf}}docker-compose.comfy.yml    -f {{cf}}docker-compose.gpu-nvidia-comfy.yml
    check -f {{cf}}docker-compose.yml -f {{cf}}docker-compose.comfy.yml    -f {{cf}}docker-compose.gpu-amd-comfy.yml
    # macOS: base compose only (no ollama container or GPU overlay)
    check -f {{cf}}docker-compose.yml
    echo "✓ All compose files valid"

# Lint all Dockerfiles with hadolint (runs via Docker — no local install needed)
test-dockerfiles:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Linting Dockerfiles..."
    for df in docker/*/Dockerfile; do
        echo "  → $df"
        docker run --rm -i \
            -v "$PWD/.hadolint.yaml:/.config/hadolint.yaml:ro" \
            hadolint/hadolint hadolint \
            --config /.config/hadolint.yaml \
            - < "$df"
    done
    echo "✓ All Dockerfiles pass hadolint"

# Lint all shell scripts with shellcheck (runs via Docker — no local install needed)
test-scripts:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Linting shell scripts..."
    # Expand globs on the host side and map to container /mnt paths.
    # (mapfile is bash 4+, unavailable on macOS's bash 3.2 — use while read)
    scripts=()
    while IFS= read -r f; do
        scripts+=("/mnt/$f")
    done < <(find scripts/ docker/ubuntu-server/ -name '*.sh' | sort)
    docker run --rm \
        -v "$PWD:/mnt:ro" \
        koalaman/shellcheck:stable \
        --rcfile /mnt/.shellcheckrc \
        "${scripts[@]}"
    echo "✓ All scripts pass shellcheck"

# Test nginx config syntax
test-nginx:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Testing nginx config syntax..."
    # ssl.conf is gitignored and only present after 'just setup local-domains',
    # which also writes the real certs. If ssl.conf is present but certs aren't
    # (e.g. after --conf-only in CI or a partial local run), generate throw-away
    # certs for the duration of the syntax check and clean them up after.
    DUMMY_CERTS=false
    cleanup() { [[ "$DUMMY_CERTS" == "true" ]] && rm -f config/nginx/certs/localai{,-key}.pem || true; }
    trap cleanup EXIT
    if [[ -f config/nginx/conf.d/ssl.conf && ! -f config/nginx/certs/localai.pem ]]; then
        echo "  → ssl.conf present but no certs — generating dummy certs for syntax check"
        mkdir -p config/nginx/certs
        openssl req -x509 -newkey rsa:2048 -days 1 -nodes \
            -keyout config/nginx/certs/localai-key.pem \
            -out    config/nginx/certs/localai.pem \
            -subj   "/CN=localai" 2>/dev/null
        DUMMY_CERTS=true
    fi
    docker run --rm \
        -v "$PWD/config/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
        -v "$PWD/config/nginx/conf.d:/etc/nginx/conf.d:ro" \
        -v "$PWD/config/nginx/certs:/etc/nginx/certs:ro" \
        nginx:alpine nginx -t
    echo "✓ nginx config valid"

# Unit-test VRAM recommendation functions (recommend_model and recommend_ctx)
test-vram:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/gpu-detect.sh
    fail=0
    assert_eq() {
        local desc="$1" got="$2" want="$3"
        if [[ "$got" == "$want" ]]; then
            echo "  ✓ $desc"
        else
            echo "  ✗ $desc"
            echo "      got : $got"
            echo "      want: $want"
            fail=1
        fi
    }
    echo "Testing recommend_model..."
    assert_eq "24GB → gemma4:12b 128K"  "$(recommend_model 24)" "gemma4:12b (128K context with room to spare)"
    assert_eq "15GB → gemma4:12b"        "$(recommend_model 15)" "gemma4:12b"
    assert_eq "12GB → gemma4:12b"        "$(recommend_model 12)" "gemma4:12b"
    assert_eq "9GB  → qwen3.5:9b"        "$(recommend_model  9)" "qwen3.5:9b"
    assert_eq "8GB  → qwen3.5:7b"        "$(recommend_model  8)" "qwen3.5:7b"
    assert_eq "6GB  → qwen3.5:7b"        "$(recommend_model  6)" "qwen3.5:7b"
    assert_eq "4GB  → qwen3.5:4b"        "$(recommend_model  4)" "qwen3.5:4b (limited context — consider a smaller model)"
    assert_eq "3GB  → CPU only"           "$(recommend_model  3)" "No GPU or too little VRAM — CPU inference only (very slow)"
    echo "Testing recommend_ctx..."
    assert_eq "15GB + 7GB model  → 131072" "$(recommend_ctx 15 7)"  "131072"
    assert_eq "12GB + 5GB model  → 131072" "$(recommend_ctx 12 5)"  "131072"
    assert_eq "12GB + 7GB model  → 131072" "$(recommend_ctx 12 7)"  "131072"
    assert_eq "8GB  + 4GB model  → 65536"  "$(recommend_ctx  8 4)"  "65536"
    assert_eq "6GB  + 2GB model  → 65536"  "$(recommend_ctx  6 2)"  "65536"
    assert_eq "4GB  + 3GB model  → 16384"  "$(recommend_ctx  4 3)"  "16384"
    echo "Testing recommend_llamacpp_model..."
    assert_eq "24GB → 26B repo"  "$(recommend_llamacpp_model 24)" "unsloth/gemma-4-26B-A4B-it-qat-GGUF"
    assert_eq "12GB → 26B repo"  "$(recommend_llamacpp_model 12)" "unsloth/gemma-4-26B-A4B-it-qat-GGUF"
    assert_eq "8GB  → 7B repo"   "$(recommend_llamacpp_model  8)" "Qwen/Qwen2.5-7B-Instruct-GGUF"
    assert_eq "3GB  → none"      "$(recommend_llamacpp_model  3)" "none"
    echo "Testing recommend_llamacpp_gpu_layers..."
    assert_eq "12GB + 26B → 23"  "$(recommend_llamacpp_gpu_layers 12 'gemma-4-26B-A4B-foo.gguf')" "23"
    assert_eq "8GB  + 26B → 16"  "$(recommend_llamacpp_gpu_layers  8 'gemma-4-26B-A4B-foo.gguf')" "16"
    assert_eq "12GB + 12B → 99"  "$(recommend_llamacpp_gpu_layers 12 'gemma-4-12B-foo.gguf')"     "99"
    assert_eq "8GB  + 9B  → 99"  "$(recommend_llamacpp_gpu_layers  8 'Qwen3.5-9B-Q4_K_M.gguf')"  "99"
    echo "Testing recommend_llamacpp_ctx..."
    assert_eq "12GB + 26B → 98304"   "$(recommend_llamacpp_ctx 12 'gemma-4-26B-A4B-foo.gguf')"   "98304"
    assert_eq "8GB  + 26B → 65536"   "$(recommend_llamacpp_ctx  8 'gemma-4-26B-A4B-foo.gguf')"   "65536"
    assert_eq "12GB + 12B → 196608"  "$(recommend_llamacpp_ctx 12 'gemma-4-12B-foo.gguf')"        "196608"
    assert_eq "8GB  + 9B  → 65536"   "$(recommend_llamacpp_ctx  8 'Qwen3.5-9B-Q4_K_M.gguf')"    "65536"
    [[ $fail -eq 0 ]] && echo "✓ All VRAM tests passed" || exit 1

# Check the justfile parses correctly
test-justfile:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Checking justfile..."
    just --list > /dev/null
    echo "✓ justfile parses correctly"

# Live smoke test: starts Ollama (CPU mode), verifies the health endpoint, stops it.
# Safe to run when a stack is already up — reuses the existing container if running.
test-inference:
    #!/usr/bin/env bash
    set -euo pipefail
    PORT=11435
    STARTED=false
    TMPENV=$(mktemp)
    trap 'rm -f "$TMPENV"; if [[ "$STARTED" == "true" ]]; then docker stop ollama 2>/dev/null || true; docker rm ollama 2>/dev/null || true; fi' EXIT

    if docker ps -q --filter name=ollama | grep -q .; then
        echo "Using running Ollama container..."
    else
        echo "Starting Ollama (CPU mode — no GPU overlay)..."
        grep -v '^OD_API_TOKEN=' .env.example > "$TMPENV"
        echo "OD_API_TOKEN=ci-test-$(openssl rand -hex 8)" >> "$TMPENV"
        {{dc}} --env-file "$TMPENV" \
            -f {{cf}}docker-compose.yml \
            -f {{cf}}docker-compose.ollama.yml \
            up -d ollama
        STARTED=true
    fi

    echo "Waiting for Ollama health endpoint..."
    for i in $(seq 1 60); do
        if curl -sf "http://localhost:${PORT}/api/tags" > /dev/null 2>&1; then
            echo "  Ollama ready (${i}s)"
            break
        fi
        if [[ $i -eq 60 ]]; then
            echo "  Ollama did not respond within 120s"
            docker logs ollama 2>&1 | tail -20
            exit 1
        fi
        sleep 2
    done

    echo "Checking API response..."
    curl -sf "http://localhost:${PORT}/api/tags" | python3 -m json.tool
    echo "✓ Inference smoke test passed"

# ── GPU utilities ──────────────────────────────────────────────────────────

# R&D context benchmark — tests a ladder of context sizes and reports VRAM, PP and TG tok/s.
# just bench                         → TurboQuant fork, default ladder
# just bench llamacpp                → standard image, narrower ladder
# just bench llamacpp-tq 32768 65536 131072  → custom sizes
bench variant="llamacpp-tq" *sizes="":
    @bash scripts/bench-context.sh "{{variant}}" {{sizes}}

# Check GPU status
gpucheck:
    #!/usr/bin/env bash
    source .env 2>/dev/null || true
    GPU="${GPU_TYPE:-nvidia}"
    if [[ "$GPU" == "nvidia" ]]; then
        docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu24.04 nvidia-smi
    else
        docker run --rm \
            --device /dev/dri --device /dev/kfd \
            --group-add video \
            rocm/rocm-terminal rocm-smi
    fi
