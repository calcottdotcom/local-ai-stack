#!/usr/bin/env bash
# Configures hermes via `hermes config set` on every container start using the
# active inference provider from env vars, then starts hermes-webui.
set -euo pipefail

BASE_URL="${INFERENCE_BASE_URL:-http://ollama:11434/v1}"
PROVIDER="${INFERENCE_PROVIDER:-ollama}"
MODEL="${INFERENCE_MODEL:-}"
OLLAMA_MDL="${OLLAMA_MODEL:-$MODEL}"
OLLAMA_CTX="${OLLAMA_CTX:-}"
LLAMACPP_MDL="${LLAMACPP_MODEL:-}"
LLAMACPP_CTX="${LLAMACPP_CTX:-65536}"

# hermes aliases "ollama" → "custom" internally; use "custom" directly so the
# config provider matches what sessions store, avoiding @custom:name:tag wrapping
# that causes rsplit to truncate "name:tag" model IDs to just "tag".
HERMES_PROVIDER="custom"

cfg() { hermes config set "$1" "$2"; }

cfg model.default  "$MODEL"
cfg model.provider "$HERMES_PROVIDER"
cfg model.base_url "$BASE_URL"
cfg model.api_key  ""
if [[ "$PROVIDER" == "llamacpp" ]]; then
    cfg model.context_length "$LLAMACPP_CTX"
elif [[ -n "$OLLAMA_CTX" ]]; then
    cfg model.context_length "$OLLAMA_CTX"
fi
cfg compression.threshold 0.6

if [[ -n "$OLLAMA_MDL" ]]; then
    cfg model_aliases.ollama.model    "$OLLAMA_MDL"
    cfg model_aliases.ollama.provider "ollama"
    cfg model_aliases.ollama.base_url "http://ollama:11434/v1"
fi

if [[ -n "$LLAMACPP_MDL" ]]; then
    cfg model_aliases.llamacpp.model           "$LLAMACPP_MDL"
    cfg model_aliases.llamacpp.provider        "custom"
    cfg model_aliases.llamacpp.base_url        "http://llamacpp:8080/v1"
    cfg model_aliases.llamacpp.context_length  "$LLAMACPP_CTX"
fi

# Write SOUL.md — loaded by hermes with every message, no restart needed.
# Tells the agent how to install software that persists across container restarts.
cat > /root/.hermes/SOUL.md << 'SOUL'
## Environment

You run inside a Docker container as root on a Linux host.

## Installing software

`apt-get install <pkg>` works immediately but is **lost on container restart** because it writes outside the persistent volume.

To install something that **persists across restarts**:
1. Add the package name to `/root/.hermes/apt-packages.txt` (one per line)
2. Run `apt-get install -y <pkg>` to also use it in the current session

The file is read on every container start and those packages are reinstalled automatically. You cannot modify the Dockerfile.

For Python dependencies, create a venv inside your workspace (e.g. `python3 -m venv ~/workspace/project/venv`) — the workspace is on the persistent volume so packages installed there survive restarts.
SOUL

# ── Skills ────────────────────────────────────────────────────────────────────
# Sync shared skills from the project volume mount into the hermes skills dir.
# Skills are on-demand: loaded via skills_list() / skill_view(), zero tokens
# until invoked, and available across all profiles.
if [[ -d /opt/shared-skills ]]; then
    cp -r /opt/shared-skills/. /root/.hermes/skills/
fi

# Reinstall any packages the agent has persisted across restarts
APT_PACKAGES=/root/.hermes/apt-packages.txt
if [[ -f "$APT_PACKAGES" ]] && [[ -s "$APT_PACKAGES" ]]; then
    echo "Installing persisted packages from $APT_PACKAGES..."
    apt-get update -qq
    xargs apt-get install -y --no-install-recommends < "$APT_PACKAGES"
fi

HERMES_PYTHON="/usr/local/lib/hermes-agent/venv/bin/python"

# Gateway must run alongside the webui — it handles agent session routing.
# 'gateway run' is the foreground form recommended for Docker/WSL; nohup +
# disown detach it from this shell so exec-ing into server.py doesn't orphan it.
nohup hermes gateway run > /root/.hermes/gateway.log 2>&1 &
disown

cd /opt/hermes-webui
exec "$HERMES_PYTHON" server.py
