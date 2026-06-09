set shell := ["bash", "-euo", "pipefail", "-c"]

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
    GPU="${GPU_TYPE:-nvidia}"

    case "{{provider}}" in
    ollama)
        if [[ -n "$(docker ps -q --filter name=llamacpp 2>/dev/null)" ]]; then
            echo "Stopping llamacpp before starting ollama..."
            docker compose -f docker-compose.yml -f docker-compose.llamacpp.yml \
                -f "docker-compose.gpu-${GPU}-llamacpp.yml" down llamacpp 2>/dev/null || true
        fi
        sed -i "s|^INFERENCE_PROVIDER=.*|INFERENCE_PROVIDER=ollama|"       .env
        sed -i "s|^INFERENCE_BASE_URL=.*|INFERENCE_BASE_URL=http://ollama:11434/v1|" .env
        sed -i "s|^OLLAMA_BASE_URL=.*|OLLAMA_BASE_URL=http://ollama:11434|" .env
        sed -i "s|^OPENAI_API_BASE_URL=.*|OPENAI_API_BASE_URL=|"           .env
        docker compose \
            -f docker-compose.yml \
            -f docker-compose.ollama.yml \
            -f "docker-compose.gpu-${GPU}-ollama.yml" \
            up -d
        ;;
    llamacpp)
        [[ -n "${LLAMACPP_MODEL:-}" ]] || {
            echo "No model set. Run: just download llamacpp model <huggingface-repo>"
            exit 1
        }
        if [[ -n "$(docker ps -q --filter name=ollama 2>/dev/null)" ]]; then
            echo "Stopping ollama before starting llamacpp..."
            docker compose -f docker-compose.yml -f docker-compose.ollama.yml \
                -f "docker-compose.gpu-${GPU}-ollama.yml" down ollama 2>/dev/null || true
        fi
        sed -i "s|^INFERENCE_PROVIDER=.*|INFERENCE_PROVIDER=llamacpp|"        .env
        sed -i "s|^INFERENCE_BASE_URL=.*|INFERENCE_BASE_URL=http://llamacpp:8080/v1|" .env
        sed -i "s|^OLLAMA_BASE_URL=.*|OLLAMA_BASE_URL=|"                       .env
        sed -i "s|^OPENAI_API_BASE_URL=.*|OPENAI_API_BASE_URL=http://llamacpp:8080/v1|" .env
        docker compose \
            -f docker-compose.yml \
            -f docker-compose.llamacpp.yml \
            -f "docker-compose.gpu-${GPU}-llamacpp.yml" \
            up -d
        ;;
    comfy)
        source .env
        GPU="${GPU_TYPE:-nvidia}"
        PROVIDER="${INFERENCE_PROVIDER:-ollama}"
        echo "Note: ComfyUI uses the GPU. If running alongside llamacpp on a single GPU, VRAM will be shared."
        docker compose \
            -f docker-compose.yml \
            -f docker-compose.comfy.yml \
            -f "docker-compose.gpu-${GPU}-comfy.yml" \
            up -d comfyui
        ;;
    *)
        echo "Usage: just up [ollama|llamacpp|comfy]"
        exit 1
        ;;
    esac

# Stop all running services
down:
    #!/usr/bin/env bash
    source .env 2>/dev/null || true
    GPU="${GPU_TYPE:-nvidia}"
    PROVIDER="${INFERENCE_PROVIDER:-ollama}"
    docker compose \
        -f docker-compose.yml \
        -f "docker-compose.${PROVIDER}.yml" \
        -f "docker-compose.gpu-${GPU}-${PROVIDER}.yml" \
        down

# Restart a single service (e.g. just restart openwebui)
restart service:
    #!/usr/bin/env bash
    source .env 2>/dev/null || true
    GPU="${GPU_TYPE:-nvidia}"
    PROVIDER="${INFERENCE_PROVIDER:-ollama}"
    docker compose \
        -f docker-compose.yml \
        -f "docker-compose.${PROVIDER}.yml" \
        -f "docker-compose.gpu-${GPU}-${PROVIDER}.yml" \
        restart {{service}}

# Show status of all local-ai-stack containers
status:
    docker ps --filter label=com.docker.compose.project=local-ai-stack

# Follow logs (optionally for a single service)
logs service="":
    #!/usr/bin/env bash
    source .env 2>/dev/null || true
    GPU="${GPU_TYPE:-nvidia}"
    PROVIDER="${INFERENCE_PROVIDER:-ollama}"
    if [[ -z "{{service}}" ]]; then
        docker compose \
            -f docker-compose.yml \
            -f "docker-compose.${PROVIDER}.yml" \
            -f "docker-compose.gpu-${GPU}-${PROVIDER}.yml" \
            logs -f
    else
        docker compose \
            -f docker-compose.yml \
            -f "docker-compose.${PROVIDER}.yml" \
            -f "docker-compose.gpu-${GPU}-${PROVIDER}.yml" \
            logs -f {{service}}
    fi

# ── Model management ───────────────────────────────────────────────────────

# Download a model: just download ollama model qwen3.5:9b
# Download a model: just download llamacpp model google/gemma-4-12B-it-qat-q4_0-gguf
download provider type model:
    @bash scripts/download-model.sh "{{provider}}" "{{model}}"

# Set the active llamacpp model by filename (called automatically by download)
set provider model:
    #!/usr/bin/env bash
    if [[ "{{provider}}" == "llamacpp" ]]; then
        sed -i "s|^LLAMACPP_MODEL=.*|LLAMACPP_MODEL={{model}}|" .env
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
        ssh) docker exec -it hermes bash ;;
        *)   docker exec -it hermes {{action}} ;;
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

# Run all tests — same checks as the CI workflow
test: test-compose test-dockerfiles test-scripts test-nginx test-justfile
    @echo ""
    @echo "All tests passed."

# Validate every compose file combination
test-compose:
    #!/usr/bin/env bash
    set -euo pipefail
    # Use a temp env so we never clobber the real .env
    TMPENV=$(mktemp)
    trap 'rm -f "$TMPENV"' EXIT
    cp .env.example "$TMPENV"
    sed -i "s|^OD_API_TOKEN=.*|OD_API_TOKEN=ci-test-$(openssl rand -hex 8)|" "$TMPENV"

    check() {
        echo "  → $*"
        docker compose --env-file "$TMPENV" "$@" config --quiet
    }

    echo "Validating compose files..."
    check -f docker-compose.yml -f docker-compose.ollama.yml   -f docker-compose.gpu-nvidia-ollama.yml
    check -f docker-compose.yml -f docker-compose.ollama.yml   -f docker-compose.gpu-amd-ollama.yml
    check -f docker-compose.yml -f docker-compose.llamacpp.yml -f docker-compose.gpu-nvidia-llamacpp.yml
    check -f docker-compose.yml -f docker-compose.llamacpp.yml -f docker-compose.gpu-amd-llamacpp.yml
    check -f docker-compose.yml -f docker-compose.comfy.yml    -f docker-compose.gpu-nvidia-comfy.yml
    check -f docker-compose.yml -f docker-compose.comfy.yml    -f docker-compose.gpu-amd-comfy.yml
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
    docker run --rm \
        -v "$PWD:/mnt:ro" \
        koalaman/shellcheck:stable \
        --rcfile /mnt/.shellcheckrc \
        /mnt/scripts/*.sh \
        /mnt/docker/ubuntu-server/entrypoint.sh
    echo "✓ All scripts pass shellcheck"

# Test nginx config syntax
test-nginx:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Testing nginx config syntax..."
    docker run --rm \
        -v "$PWD/config/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
        -v "$PWD/config/nginx/conf.d:/etc/nginx/conf.d:ro" \
        nginx:alpine nginx -t
    echo "✓ nginx config valid"

# Check the justfile parses correctly
test-justfile:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Checking justfile..."
    just --list > /dev/null
    echo "✓ justfile parses correctly"

# ── GPU utilities ──────────────────────────────────────────────────────────

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
