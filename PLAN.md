# Local AI Stack — Build Plan

## Overview

A self-hosted AI stack running on a local GPU. Services are orchestrated via Docker Compose, controlled through a `justfile`, and targeted at Linux with Nvidia or AMD GPU passthrough. Mac/Windows support is a future goal.

---

## Phases

### Phase 1 — Project Scaffolding ✅

**Goal:** Get the full directory structure, compose files, justfile, and CI in place so everything can be built incrementally against a stable skeleton.

- [x] Docker Compose base file with all services (`docker/docker-compose.yml`)
- [x] Inference overlay files — Ollama and Llama.cpp as mutually exclusive profiles
- [x] ComfyUI standalone overlay
- [x] GPU passthrough overlays (nvidia/amd × ollama/llamacpp/comfy)
- [x] `justfile` with all documented commands (`up`, `down`, `download`, `set`, `hermes`, `setup`, `gpucheck`, `logs`, `status`, `test`)
- [x] `.env.example` with all tunables
- [x] Dockerfile stubs — Hermes CLI container, Pi Coding Agent, Ubuntu server sandbox
- [x] Nginx config with upstream blocks for all `.localai` virtual hosts
- [x] Searxng `settings.yml` with JSON/RSS output enabled for agent use
- [x] `scripts/setup.sh` — interactive wizard with GPU detection and VRAM-aware model recommendations
- [x] `scripts/setup-local-domains.sh` — mkcert SSL + `/etc/hosts` wiring
- [x] `scripts/download-model.sh` — VRAM-aware context window sizing for Ollama and Llama.cpp
- [x] `scripts/gpu-detect.sh` — GPU vendor and VRAM detection helper
- [x] CI workflow (GitHub Actions) running on PRs to `main`
- [x] `just test` local test suite mirroring CI

---

### Phase 2 — Core Inference (Ollama) ✅

**Goal:** Verify that Ollama starts, accepts GPU-accelerated requests, and serves models correctly on a real Linux/Nvidia machine.

- [x] Health checks on Ollama compose service
- [x] `just up` waits for service readiness after `docker compose up -d`
- [x] `just test-inference` and CI smoke test prove Ollama starts and serves requests (CPU mode)
- [x] `just download` idempotent — skips re-pull if model already present
- [x] Boot test: `just up ollama` starts without errors on Linux/Nvidia (RTX 5060 Ti, Ubuntu 24.04)
- [x] `just download ollama model qwen3.5:9b` — pull succeeds and Modelfile applied (65536 ctx for 15GB VRAM)
- [x] GPU inference: **55.7 tok/s** on 9B model, 9GB VRAM utilisation on RTX 5060 Ti
- [x] VRAM-based context sizing verified: 15GB / ~6GB model → 65536 tokens
- [x] Provider switch interlock: switching to llamacpp stops ollama container (confirmed)
- [x] `just gpucheck` works on Linux/Nvidia

**Fixes discovered during live testing:**
- Build context paths: `./hermes` → `./docker/hermes` (required by `--project-directory .`)
- nginx: `proxy_pass $upstream` + `resolver 127.0.0.11` so nginx starts without all containers running
- Ollama healthcheck: `ollama list` (no `curl` in the image)
- `LLAMACPP_EXTRA_ARGS` must be quoted in `.env` to survive `source .env`
- Nvidia container toolkit: `no-cgroups=true` required inside a Proxmox VM

---

### Phase 3 — UI & Search Services ✅

**Goal:** OpenWebUI and Searxng are accessible, wired to the active inference provider, and usable end-to-end.

- [x] OpenWebUI loads at `http://localhost:8086`
- [x] OpenWebUI model list reflects Ollama models — `qwen3.5:9b` and `qwen3.5:localai` visible after download
- [x] OpenWebUI chat works end-to-end via the Ollama backend (verified via `/api/chat/completions`)
- [x] Searxng loads at `http://localhost:8888`
- [x] Searxng JSON output works — 21 results returned for test query
- [x] Searxng RSS output works — returns valid feed with real results
- [x] Searxng reachable from inside the Docker network (`http://searxng:8080`) — confirmed from hermes container
- [x] `just up ollama` sets `OLLAMA_BASE_URL=http://ollama:11434` in OpenWebUI; switching provider will recreate the container with updated env (hot-switch confirmed by env inspection)

---

### Phase 4 — Agents ✅

**Goal:** Hermes and Pi are containerised, connectable to the LLM, and accessible as documented.

- [x] `docker/hermes/Dockerfile` builds successfully (hermes install script)
- [x] `just hermes ssh` drops into a working shell with `hermes` on `$PATH`
- [x] Hermes agent can reach the active inference endpoint from inside the container
- [x] Hermes pointed at Searxng for web search (first-run prompt from README)
- [x] `docker/hermes-webui` builds from the upstream GitHub context
- [x] Hermes Web UI loads at `http://localhost:8787`
- [x] `docker/pi/Dockerfile` builds successfully
- [x] Pi coding agent starts and connects to the inference endpoint
- [x] Ubuntu server sandbox starts with SSH and nginx accessible

**Fixes discovered during live testing:**
- `just hermes ssh` must use `-u hermes` flag so the shell runs as the hermes user with the correct `$PATH`; defaulting to root misses the user-local install paths
- Ubuntu 24.04 base image ships an `ubuntu` user at uid 1000, pushing hermes to uid 1001. Docker volume init writes files owned by uid 1000, so hermes (1001) gets Permission denied on `drwxr-x---`. Fixed by removing the ubuntu user in the Dockerfile so hermes claims uid 1000.
- Agent containers started before `just download` complete have a stale `INFERENCE_MODEL` env var. Fixed by having `download-model.sh` restart running agent containers after updating `.env`.
- Pi coding agent uses `~/.pi/agent/models.json` (not env vars alone) to override the provider base URL. Entrypoint writes both `models.json` and `settings.json` on every start.

---

### Phase 5 — Mac & Windows Support 🔄

**Goal:** The stack runs on Mac (Apple Silicon / Intel) and Windows (WSL2) with appropriate GPU or CPU-only fallback.

**macOS:**
- [x] Ollama runs natively on host (Metal acceleration); Docker containers use `host.docker.internal:11434`
- [x] `detect_platform()` in `gpu-detect.sh` returns `mac`; `detect_gpu()` uses `sysctl hw.memsize` (40% RAM estimate)
- [x] `sedi()` helper in `gpu-detect.sh` — BSD `sed -i ''` on Mac, GNU `sed -i` elsewhere
- [x] `just setup` on Mac: checks Ollama CLI, skips provider selection, sets `host.docker.internal` URLs in `.env`
- [x] `just up ollama` on Mac: skips ollama/GPU overlays, starts base compose only, waits on host port 11434
- [x] `just up llamacpp` / `just up comfy` on Mac: exits with clear unsupported message
- [x] `just down/restart/logs` on Mac: skips provider/GPU overlays for ollama
- [x] `just download ollama model` on Mac: uses native `ollama pull/create` on host (no `docker exec`)
- [x] All `sed -i` calls in `justfile` and `download-model.sh` replaced with `sedi`
- [x] README macOS section: full install guide, RAM-tier model table, host-Ollama explanation

**Windows (WSL2):**
- [x] `detect_platform()` returns `wsl` when `/proc/version` contains "microsoft" or "wsl"
- [x] `just setup` shows WSL2-specific install instructions for docker and just
- [x] README Windows section: 5-step guide (WSL2 enable, Docker Desktop, just, Nvidia drivers, clone & run)
- [ ] End-to-end test on a real Windows machine (WSL2 + Docker Desktop)

---

### Phase 6 — Reverse Proxy & Local Domains 📋

**Goal:** All services accessible via `*.localai` with HTTPS.

- [ ] Nginx container starts and HTTP proxy works for each service
- [ ] `just setup local-domains` installs mkcert, generates certs, and updates `/etc/hosts`
- [ ] All `https://*.localai` URLs resolve and show valid certificates
- [ ] Nginx reloads correctly after cert generation

---

### Phase 7 — Media & Design 📋

**Goal:** ComfyUI and OpenDesign running and accessible.

- [ ] `just up comfy` starts ComfyUI with GPU passthrough
- [ ] ComfyUI web UI loads at `http://localhost:8188`
- [ ] Single-GPU warning is surfaced when running alongside another inference provider
- [ ] OpenDesign loads at `http://localhost:7456`
- [ ] `OD_API_TOKEN` generation documented in setup wizard

---

### Phase 8 — Llama.cpp Inference 📋

**Goal:** Verify llama.cpp with a real GGUF model and confirm MTP speculative decoding gives a meaningful speed boost over baseline.

- [ ] `just download llamacpp model <hf-repo>` — GGUF downloaded to volume, `.env` updated
- [ ] `just up llamacpp` starts the server and reaches the `/health` endpoint
- [ ] Inference request returns a valid response via the OpenAI-compatible API
- [ ] `--spec-type draft-mtp` flag confirmed working with a Qwen3 or DeepSeek model
- [ ] Provider switch: `just up llamacpp` while Ollama running → Ollama stops, llamacpp starts, OpenWebUI switches over

---

### Phase 9 — `just setup` Polish 📋

**Goal:** A new user can run `just setup` on a fresh Linux + GPU machine and be ready to chat within 10 minutes.

- [ ] End-to-end test of the full setup wizard on a clean machine
- [ ] GPU detection works for both Nvidia and AMD
- [ ] Model recommendations match actual VRAM tiers
- [ ] All prompts have sensible defaults so Enter-through works
- [ ] Error messages are clear when prerequisites (docker, just, drivers) are missing

---

## Key Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Inference provider selection | Separate compose overlays | Keeps services physically isolated; `just` enforces mutual exclusion |
| GPU passthrough | Per-provider overlay files | Nvidia/AMD differ structurally; overlays keep base files clean |
| Compose file location | `docker/` subdir | Keeps project root clean; `--project-directory .` preserves bind-mount paths |
| Agent web search | Searxng RSS/JSON | Self-hosted, no API key, works for both web and news categories |
| Context window sizing | VRAM-tier lookup table | Simple, predictable, avoids model-specific calculations at download time |
| `just hermes ssh` | `docker exec` | Simpler than real SSH for a local stack; functionally equivalent |
| Llama.cpp priority | Phase 7 (after agents/UI) | Ollama covers the MVP use case; llamacpp testing requires a GGUF download |
