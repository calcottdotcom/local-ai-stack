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

### Phase 2 — Core Inference Services 🔄

**Goal:** Verify that Ollama and Llama.cpp containers start, accept requests, and serve models correctly. Establish the VRAM-to-context sizing logic with a real GPU.

- [x] Health checks on Ollama and Llama.cpp compose services
- [x] `just up` waits for service readiness after `docker compose up -d`
- [x] `just test-inference` and CI smoke test prove Ollama starts and serves requests (CPU mode)
- [x] MTP flag corrected to `--spec-type draft-mtp`; controlled via `LLAMACPP_EXTRA_ARGS` in `.env`
- [x] `just download` idempotent — skips re-pull/re-download if model already present
- [ ] Boot test: `just up ollama` starts without errors on a Linux/Nvidia machine
- [ ] Boot test: `just up llamacpp` starts without errors on a Linux/Nvidia machine
- [ ] `just download ollama model qwen3.5:9b` — pull succeeds and Modelfile is applied
- [ ] `just download llamacpp model <hf-repo>` — GGUF downloaded, model set in `.env`
- [ ] Provider switch interlock: switching from ollama → llamacpp stops ollama container
- [ ] VRAM-based context sizing produces sensible values across the 6/8/12/24 GB tiers
- [ ] `--spec-type draft-mtp` verified against a model that supports it (Qwen3/DeepSeek)

---

### Phase 3 — UI & Search Services 📋

**Goal:** OpenWebUI and Searxng are accessible and wired to the active inference provider.

- [ ] OpenWebUI loads at `http://localhost:8086`
- [ ] OpenWebUI model list reflects Ollama models after download
- [ ] OpenWebUI OpenAI-compatible mode works when switched to Llama.cpp
- [ ] Searxng loads at `http://localhost:8888`
- [ ] Searxng RSS/JSON output works (required for agent web-search skill)
- [ ] `just up ollama` / `just up llamacpp` hot-switches the inference endpoint in OpenWebUI without manual reconfiguration

---

### Phase 4 — Agents 📋

**Goal:** Hermes and Pi are containerised, connectable to the LLM, and accessible as documented.

- [ ] `docker/hermes/Dockerfile` builds successfully (hermes install script)
- [ ] `just hermes ssh` drops into a working shell with `hermes` on `$PATH`
- [ ] Hermes agent can reach the active inference endpoint from inside the container
- [ ] Hermes pointed at Searxng for web search (first-run prompt from README)
- [ ] `docker/hermes-webui` builds from the upstream GitHub context
- [ ] Hermes Web UI loads at `http://localhost:8787`
- [ ] `docker/pi/Dockerfile` builds successfully
- [ ] Pi coding agent starts and connects to the inference endpoint
- [ ] Ubuntu server sandbox starts with SSH and nginx accessible

---

### Phase 5 — Reverse Proxy & Local Domains 📋

**Goal:** All services accessible via `*.localai` with HTTPS.

- [ ] Nginx container starts and HTTP proxy works for each service
- [ ] `just setup local-domains` installs mkcert, generates certs, and updates `/etc/hosts`
- [ ] All `https://*.localai` URLs resolve and show valid certificates
- [ ] Nginx reloads correctly after cert generation

---

### Phase 6 — Media & Design 📋

**Goal:** ComfyUI and OpenDesign running and accessible.

- [ ] `just up comfy` starts ComfyUI with GPU passthrough
- [ ] ComfyUI web UI loads at `http://localhost:8188`
- [ ] Single-GPU warning is surfaced when Llama.cpp is also running
- [ ] OpenDesign loads at `http://localhost:7456`
- [ ] `OD_API_TOKEN` generation documented in setup wizard

---

### Phase 7 — `just setup` Polish 📋

**Goal:** A new user can run `just setup` on a fresh Linux + GPU machine and be ready to chat within 10 minutes.

- [ ] End-to-end test of the full setup wizard on a clean machine
- [ ] GPU detection works for both Nvidia and AMD
- [ ] Model recommendations match actual VRAM tiers
- [ ] All prompts have sensible defaults so Enter-through works
- [ ] Error messages are clear when prerequisites (docker, just, drivers) are missing

---

### Phase 8 — Mac & Windows Support 📋

**Goal:** The stack runs on Mac (Apple Silicon / Intel) and Windows (WSL2) with appropriate GPU or CPU-only fallback.

- [ ] Determine GPU passthrough approach for Mac (Metal via Ollama's native support)
- [ ] Determine GPU passthrough approach for Windows (WSL2 + Nvidia)
- [ ] OS detection in `just setup` and `scripts/gpu-detect.sh`
- [ ] Compose GPU overlays for Mac/Windows variants where needed
- [ ] `sed -i` portability fixed for macOS (`sed -i ''`)
- [ ] README updated with Mac/Windows instructions

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
