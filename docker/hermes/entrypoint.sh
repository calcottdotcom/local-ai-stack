#!/usr/bin/env bash
# Configures hermes via `hermes config set` on every container start using the
# active inference provider from env vars, then keeps the container alive.
set -euo pipefail

BASE_URL="${INFERENCE_BASE_URL:-http://ollama:11434/v1}"
PROVIDER="${INFERENCE_PROVIDER:-ollama}"
MODEL="${INFERENCE_MODEL:-}"
OLLAMA_MDL="${OLLAMA_MODEL:-$MODEL}"
LLAMACPP_MDL="${LLAMACPP_MODEL:-}"
CTX="${LLAMACPP_CTX:-65536}"

# Map our provider names to hermes provider names
[[ "$PROVIDER" == "llamacpp" ]] && HERMES_PROVIDER="custom" || HERMES_PROVIDER="ollama"

cfg() { hermes config set "$1" "$2"; }

# Active provider
cfg model.default  "$MODEL"
cfg model.provider "$HERMES_PROVIDER"
cfg model.base_url "$BASE_URL"
cfg model.api_key  ""
[[ "$PROVIDER" == "llamacpp" ]] && cfg model.context_length "$CTX"

# Ollama alias — always present so `hermes /model ollama` works even when
# llamacpp is the active provider
if [[ -n "$OLLAMA_MDL" ]]; then
    cfg model_aliases.ollama.model    "$OLLAMA_MDL"
    cfg model_aliases.ollama.provider "ollama"
    cfg model_aliases.ollama.base_url "http://ollama:11434/v1"
fi

# Llamacpp alias — only written when a model has been downloaded
if [[ -n "$LLAMACPP_MDL" ]]; then
    cfg model_aliases.llamacpp.model           "$LLAMACPP_MDL"
    cfg model_aliases.llamacpp.provider        "custom"
    cfg model_aliases.llamacpp.base_url        "http://llamacpp:8080/v1"
    cfg model_aliases.llamacpp.context_length  "$CTX"
fi

exec sleep infinity
