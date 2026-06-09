#!/usr/bin/env bash
# Writes defaultProvider/defaultModel into pi's settings.json on every start,
# then keeps the container alive.
set -euo pipefail

MODEL="${INFERENCE_MODEL:-}"
SETTINGS_DIR="/home/pi/.pi/agent"
SETTINGS_FILE="${SETTINGS_DIR}/settings.json"

mkdir -p "$SETTINGS_DIR"

# Merge provider + model into existing settings (preserves other keys like lastChangelogVersion)
node - <<EOF
const fs = require('fs');
let existing = {};
try { existing = JSON.parse(fs.readFileSync('${SETTINGS_FILE}', 'utf8')); } catch (_) {}
const merged = { ...existing, defaultProvider: 'openai', defaultModel: '${MODEL}' };
fs.writeFileSync('${SETTINGS_FILE}', JSON.stringify(merged, null, 2) + '\n');
console.log('Pi config written:', JSON.stringify({ defaultProvider: merged.defaultProvider, defaultModel: merged.defaultModel }));
EOF

exec sleep infinity
