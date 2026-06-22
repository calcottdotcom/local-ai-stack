#!/usr/bin/env bash
# Writes models.json (provider baseUrl) and settings.json (default model) on
# every container start, then keeps the container alive.
set -euo pipefail

SETTINGS_DIR="/home/pi/.pi/agent"
mkdir -p "$SETTINGS_DIR"

# INFERENCE_BASE_URL, INFERENCE_MODEL, LLAMACPP_CTX are already in the
# container environment from docker-compose — node reads them via process.env.
node -e "
const fs = require('fs');
const baseUrl  = process.env.INFERENCE_BASE_URL || 'http://ollama:11434/v1';
const model    = process.env.INFERENCE_MODEL || '';
const provider = process.env.INFERENCE_PROVIDER || 'ollama';
const ctx      = parseInt((provider === 'llamacpp' ? process.env.LLAMACPP_CTX : process.env.OLLAMA_CTX) || '65536');
const dir      = '${SETTINGS_DIR}';

// models.json — override the built-in openai provider to use our local endpoint
const modelsJson = { providers: { openai: { baseUrl, apiKey: 'ollama', models: model ? [{ id: model, contextWindow: ctx }] : [] } } };
fs.writeFileSync(dir + '/models.json', JSON.stringify(modelsJson, null, 2) + '\n');
console.log('Pi models.json written:', JSON.stringify({ baseUrl, model }));

// settings.json — set default provider/model (preserves other existing keys)
let settings = {};
try { settings = JSON.parse(fs.readFileSync(dir + '/settings.json', 'utf8')); } catch (_) {}
settings = { ...settings, defaultProvider: 'openai', defaultModel: model };
fs.writeFileSync(dir + '/settings.json', JSON.stringify(settings, null, 2) + '\n');
console.log('Pi settings.json written:', JSON.stringify({ defaultProvider: settings.defaultProvider, defaultModel: settings.defaultModel }));
"

# APPEND_SYSTEM.md — appends to Pi's default system prompt every session.
# Built dynamically from shared skill files so it stays in sync automatically.
# Lists skills by name/description only; full details are in /opt/shared-skills/.
{
    echo "## Available Skills"
    echo ""
    echo "Skills are plain markdown docs, not built-in tools — there is no skill-calling mechanism."
    echo "To use one: open its SKILL.md with the read tool, then run the bash commands shown inside it directly."
    echo ""
    if [[ -d /opt/shared-skills ]]; then
        while IFS= read -r skill_file; do
            name=$(grep -m1 '^name:' "$skill_file" | sed 's/^name:[[:space:]]*//' | tr -d '"' || true)
            desc=$(grep -m1 '^description:' "$skill_file" | sed 's/^description:[[:space:]]*//' | tr -d '"' || true)
            rel="${skill_file#/opt/shared-skills/}"
            [[ -n "$name" ]] && echo "- **${name}** — ${desc} (\`/opt/shared-skills/${rel}\`)"
        done < <(find /opt/shared-skills -name SKILL.md | sort)
    fi
} > "$SETTINGS_DIR/APPEND_SYSTEM.md"

# Start OpenDesign in background; exposes the design UI on port 7456.
# --host 0.0.0.0 so nginx (a different container) can reach it; default is loopback-only.
node /app/apps/daemon/dist/cli.js --no-open --host 0.0.0.0 &

exec sleep infinity
