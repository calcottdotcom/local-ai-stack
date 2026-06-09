#!/usr/bin/env bash
# Writes models.json (provider baseUrl) and settings.json (default model) on
# every container start, then keeps the container alive.
set -euo pipefail

BASE_URL="${INFERENCE_BASE_URL:-http://ollama:11434/v1}"
MODEL="${INFERENCE_MODEL:-}"
CTX="${LLAMACPP_CTX:-65536}"
SETTINGS_DIR="/home/pi/.pi/agent"

mkdir -p "$SETTINGS_DIR"

# Write models.json — override the built-in openai provider to use our local endpoint
node -e "
const fs = require('fs');
const models = process.env.MODEL ? [{ id: process.env.MODEL, contextWindow: parseInt(process.env.CTX) }] : [];
const cfg = { providers: { openai: { baseUrl: process.env.BASE_URL, apiKey: 'ollama', models } } };
fs.writeFileSync('${SETTINGS_DIR}/models.json', JSON.stringify(cfg, null, 2) + '\n');
console.log('Pi models.json written:', JSON.stringify({ baseUrl: process.env.BASE_URL, model: process.env.MODEL }));
" MODEL="$MODEL" CTX="$CTX" BASE_URL="$BASE_URL"

# Write settings.json — set default provider/model (merges with existing keys)
node -e "
const fs = require('fs');
const path = '${SETTINGS_DIR}/settings.json';
let existing = {};
try { existing = JSON.parse(fs.readFileSync(path, 'utf8')); } catch (_) {}
const merged = { ...existing, defaultProvider: 'openai', defaultModel: process.env.MODEL };
fs.writeFileSync(path, JSON.stringify(merged, null, 2) + '\n');
console.log('Pi settings.json written:', JSON.stringify({ defaultProvider: merged.defaultProvider, defaultModel: merged.defaultModel }));
" MODEL="$MODEL"

exec sleep infinity
