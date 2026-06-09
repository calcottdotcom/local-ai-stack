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
const baseUrl = process.env.INFERENCE_BASE_URL || 'http://ollama:11434/v1';
const model   = process.env.INFERENCE_MODEL || '';
const ctx     = parseInt(process.env.LLAMACPP_CTX || '65536');
const dir     = '${SETTINGS_DIR}';

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

exec sleep infinity
