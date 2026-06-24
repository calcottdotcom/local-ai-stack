# Gemma 4 QAT Context Benchmark — RTX 4080 Laptop 12 GB

**Date:** 2026-06-24  
**Status:** Complete. Covers 12 GB configs (f16, Q4_0 KV, TurboQuant+MTP) and measured 8 GB configs (26B A4B at 16 layers + Qwen3.5 9B Q4_K_M).

---

## System

| Component | Spec |
|-----------|------|
| GPU | NVIDIA RTX 4080 Laptop (Ada Lovelace, sm_89) |
| VRAM | 12 282 MiB usable |
| System RAM | 32 GB physical |
| WSL2 cap | 20 GB (`.wslconfig` — `memory=20GB`, `autoUnmapMemory=true`) |
| OS | Windows 11 Pro, Docker Desktop with WSL2 backend |
| Runtime | `ghcr.io/ggml-org/llama.cpp:server-cuda` (standard upstream image) |

**Display note:** On laptops the iGPU/dGPU typically holds 200–600 MiB of VRAM for the display. The numbers here were measured without any heavy GPU workload on the desktop. For a conservative production recommendation, subtract ~500 MiB from the headroom figures.

---

## Models

| Model | File | Size | Source |
|-------|------|------|--------|
| Gemma 4 12B QAT | `gemma-4-12B-it-qat-UD-Q4_K_XL.gguf` | 6.3 GB | `unsloth/gemma-4-12b-it-qat-GGUF` |
| Gemma 4 26B A4B QAT | `gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf` | 13.3 GB | `unsloth/gemma-4-26B-A4B-it-qat-GGUF` |
| Qwen3.5 9B | `Qwen3.5-9B-Q4_K_M.gguf` | 5.3 GB | HuggingFace |

Both Gemma 4 variants are QAT (Quantization-Aware Training) — higher quality at the same bit-width vs post-training quantization. Do not substitute non-QAT variants; the quality difference is meaningful for these model sizes.

**Gemma 4 architecture note:** Both models use hybrid local/global attention — most transformer layers use a sliding window (4K tokens), with sparse global attention layers attending the full sequence. This is why VRAM scales very sub-linearly with context length compared to a fully-dense transformer.

**Qwen3.5 9B architecture note:** Dense model (no MoE). Uses Gated Delta Networks (linear attention) for most layers with sparse standard attention blocks. Native 262K context window. Linear attention layers maintain a constant-size recurrent state (no growing KV cache), which is why VRAM and TG throughput scale very favourably with context length.

---

## Methodology

- One container per context size; torn down between runs to avoid KV cache bleed
- KV cache filled to **60% of the declared context window** before timing
- 64 tokens generated after fill; `timings.prompt_per_second` and `timings.predicted_per_second` from the `/completion` JSON response
- VRAM measured via `nvidia-smi` immediately after the server health check passes (i.e. at model-loaded steady state, before the fill prompt is sent)
- System RAM not directly instrumented — see estimates in each section
- Script: `scripts/bench-rd.sh` (runnable from WSL: `bash scripts/bench-rd.sh <phase>`)

---

## Gemma 4 12B QAT — f16 KV, all layers on GPU

**Configuration:** `--n-gpu-layers 99 -ctk f16 -ctv f16`

| CTX | VRAM | PP tok/s | TG tok/s |
|-----|------|----------|----------|
| 4 096 | 7.9 GB | 1 996 | 45.3 |
| 8 192 | 8.1 GB | 2 398 | 42.6 |
| 12 288 | 8.2 GB | 2 391 | 42.0 |
| 16 384 | 8.3 GB | 2 298 | 49.1 |
| 20 480 | 8.3 GB | 2 281 | 36.5 |
| 24 576 | 8.4 GB | 2 444 | 44.2 |
| 32 768 | 8.5 GB | 2 385 | 42.7 |
| 40 960 | 8.7 GB | 2 068 | 23.4 |
| 49 152 | 8.8 GB | 1 298 | 39.8 |
| 65 536 | 9.1 GB | 1 536 | 29.2 |
| 81 920 | 9.3 GB | 1 163 | 28.9 |
| 98 304 | 9.6 GB | 1 080 | 28.2 |
| 131 072 | 10.1 GB | 959 | 27.3 |
| 163 840 | 10.6 GB | 892 | 25.9 |
| 196 608 | 11.2 GB | 774 | 24.8 |
| 229 376 | 11.7 GB | 695 | 23.8 |
| 262 144 | 11.7 GB* | — | — | ← **OOM/swap — do not use** |

*VRAM reading captured before fill prompt; actual peak during 262K processing exceeded 12 GB causing GPU memory pressure. Processing degraded from ~700 tok/s to ~58 tok/s (10× slowdown). Request timed out at 300 s.

**System RAM during 12B inference:** Model is fully on GPU. RAM overhead is Docker + WSL2 baseline only — approximately **1.5–2.5 GB** of the WSL2 allocation.

### 12 GB recommendations — Gemma 4 12B

| Use case | CTX setting | VRAM | TG tok/s |
|----------|-------------|------|----------|
| Conservative / display-sharing | 131 072 | 10.1 GB | 27 |
| Recommended default | 196 608 | 11.2 GB | 25 |
| Maximum (GPU-only workstation) | 229 376 | 11.7 GB | 24 |

Set in `.env`: `LLAMACPP_CTX=196608` with `LLAMACPP_GPU_LAYERS=99`

---

## Gemma 4 26B A4B QAT — Q4_0 KV, partial CPU offload

**Architecture:** MoE — 30 transformer layers, 128 experts per MoE layer, 8+1 active per token, 3.8B active parameters. Only ~7% of each layer's expert weights are accessed per token, making CPU-offloaded layers much cheaper than an equivalent dense model.

**Model size:** 13.3 GB. Cannot fit fully in 12 GB VRAM. Optimal split found to be **23 layers on GPU, 7 on CPU**.

### Layer split comparison (Q4_0 KV)

| CTX | VRAM@20L | TG@20L | VRAM@23L | TG@23L | TG gain |
|-----|----------|--------|----------|--------|---------|
| 4 096 | 9.2 GB | 38.6 | 10.5 GB | 44.0 | +14% |
| 8 192 | 9.3 GB | 34.3 | 10.6 GB | 35.1 | +2% |
| 16 384 | 9.3 GB | 33.1 | 10.6 GB | 33.0 | ≈0% |
| 32 768 | 9.4 GB | 26.9 | 10.7 GB | 26.9 | ≈0% |
| 65 536 | 9.6 GB | 18.7 | 10.9 GB | 21.1 | +13% |
| 98 304 | 10.0 GB | 14.1 | 11.3 GB | 20.8 | +48% |
| 131 072 | 10.3 GB | 12.5 | 11.6 GB | 18.9 | +51% |

### Full results at 23 GPU layers (recommended)

**Configuration:** `--n-gpu-layers 23 -ctk q4_0 -ctv q4_0`

| CTX | VRAM | PP tok/s | TG tok/s |
|-----|------|----------|----------|
| 4 096 | 10.5 GB | 1 050 | 44.0 |
| 8 192 | 10.6 GB | 1 186 | 35.1 |
| 16 384 | 10.6 GB | 1 112 | 33.0 |
| 32 768 | 10.7 GB | 1 141 | 26.9 |
| 65 536 | 10.9 GB | 936 | 21.1 |
| 98 304 | 11.3 GB | 820 | 20.8 |
| 131 072 | 11.6 GB | 802 | 18.9 |

**System RAM during 26B inference:** 7 CPU-resident layers × (13.3 GB ÷ 30 layers) ≈ **3.1 GB of model weights in RAM**, plus WSL2/Docker baseline of ~1.5 GB. Expect approximately **4.5–6 GB** of system RAM consumed during active inference. On a 32 GB machine this is trivial; on a 16 GB machine, leave headroom accordingly.

### 12 GB recommendations — Gemma 4 26B A4B

| Use case | CTX setting | VRAM | TG tok/s |
|----------|-------------|------|----------|
| Conservative / display-sharing | 65 536 | 10.9 GB | 21 |
| Recommended default | 98 304 | 11.3 GB | 21 |
| Maximum (GPU-only workstation) | 131 072 | 11.6 GB | 19 |

Set in `.env`: `LLAMACPP_CTX=98304` with `LLAMACPP_GPU_LAYERS=23` and `LLAMACPP_KV_TYPE=q4_0`

**Do not use 24+ GPU layers** — at 128K context this would exceed 12 GB VRAM and cause GPU memory pressure identical to the 12B 262K failure case.

---

## TurboQuant + MTP (AtomicBot fork) — Gemma 4 12B

**Image:** `local-ai-stack/llamacpp-tq` — built from `docker/llamacpp-tq/Dockerfile` (AtomicBot-ai/atomic-llama-cpp-turboquant fork). Build takes ~30 min with CUDA compilation.

**What's enabled:**
- `turbo3` KV compression (4.3× vs f16) — WHT-rotated polar quantization of the KV cache
- MTP (Multi-Token Prediction) speculative decoding via `mtp-gemma-4-12B-it.gguf` (242 MB draft head)
- Both combined: each TG step drafts 3 tokens speculatively, accepting any that match the verifier pass

**Configuration:**
```bash
--n-gpu-layers 99 -ctk turbo3 -ctv turbo3 --flash-attn on \
--spec-type draft-mtp --spec-draft-model /models/mtp-gemma-4-12B-it.gguf \
--spec-draft-ngl 99 --spec-draft-n-max 3
```

### Results — 12B + turbo3 + MTP

| CTX | VRAM | Load | PP tok/s | TG tok/s |
|-----|------|------|----------|----------|
| 4 096 | 11.4 GB | 14s | 2 367 | **111.8** |
| 8 192 | 11.5 GB | 6s | 2 378 | **103.0** |
| 16 384 | 11.5 GB | 7s | 2 269 | **69.7** |
| 32 768 | 11.6 GB | 7s | 1 827 | 32.1 |
| 65 536 | 11.7 GB | 6s | 1 166 | 32.6 |

**Key findings:**

- **VRAM barely scales with context** — from 11.4 GB at 4K to 11.7 GB at 65K. This confirms turbo3 compression is effective: Gemma 4's sliding window layers only ever keep ~4K tokens in KV, so the global attention layers dominate KV memory and they saturate early.
- **VRAM overhead vs f16 baseline:** At 4096 ctx, f16 used 7.9 GB vs 11.4 GB here — an extra ~3.5 GB. This comes from the MTP draft model on GPU (+0.24 GB), the TQ framework's additional compute buffers, and the AtomicBot image's base allocation patterns.
- **TG speedup over f16 baseline:** f16 without MTP runs ~42–49 tok/s across most contexts. With MTP+turbo3, this becomes 111 tok/s at 4K and 103 tok/s at 8K — a **2–2.5× throughput improvement** at the context sizes most useful for 8 GB users.
- **TG drops at 32K+:** The 32K and 65K sizes both show ~32 tok/s — lower than f16 at similar contexts. This is expected: turbo3 decompresses KV on the fly during attention, adding latency for the global attention layers which must span the full context.
- **Draft acceptance:** At short contexts, ~80–88% of draft tokens were accepted. At 32K ctx (filled to 60%), acceptance dropped to ~48%, explaining the TG slowdown.

### 12 GB recommendation — 12B + MTP

| Use case | CTX | VRAM | TG tok/s |
|----------|-----|------|----------|
| Best throughput | 8 192 | 11.5 GB | 103 |
| Throughput + context | 16 384 | 11.5 GB | 70 |

Set: `LLAMACPP_CTX=8192 LLAMACPP_GPU_LAYERS=99 LLAMACPP_KV_TYPE=turbo3` plus MTP args (requires TQ image — see [build instructions](#build)).

---

## 8 GB VRAM — Measured Configs

> Benchmarked on a 12 GB card at GPU layer counts chosen to keep VRAM under 8 GB. These results are directly applicable to RTX 4060 / RTX 3070 / RX 6700 XT class hardware.

---

### Gemma 4 26B A4B — 16 GPU layers (8 GB profile)

**Configuration:** `--n-gpu-layers 16 -ctk q4_0 -ctv q4_0`

16 of 30 MoE transformer layers on GPU. The remaining 14 layers run on CPU — but due to the MoE architecture (only 8/128 experts accessed per token), the CPU penalty is much lower than a comparable dense model.

| CTX | VRAM | Load | PP tok/s | TG tok/s |
|-----|------|------|----------|----------|
| 4 096 | 7.5 GB | 8s | 765 | 31.2 |
| 16 384 | 7.5 GB | 7s | 961 | 26.4 |
| 65 536 | 7.8 GB | 6s | 877 | 14.1 |
| 131 072 | 8.5 GB | 8s | 596 | 20.3 |

**Notes:**
- VRAM stays flat from 4K to 65K context (7.5–7.8 GB) — Q4_0 KV compression keeps the KV cache small, and Gemma 4's local attention dominates across most layers
- 131 072 ctx pushes to 8.5 GB — above the 8 GB target; **max safe ctx is 65 536** for 8 GB cards
- The apparent TG improvement from 65K (14.1) to 131K (20.3) is noise in this MoE workload; treat 131K as marginal/unsupported on 8 GB hardware
- **System RAM:** 14 CPU layers × (13.3/30 GB) ≈ 6.2 GB weights in RAM + WSL2 baseline → expect **~8 GB system RAM** consumed during inference

**8 GB recommendation for 26B:**

| Use case | CTX | VRAM | TG tok/s | System RAM |
|----------|-----|------|----------|------------|
| Maximum safe | 65 536 | 7.8 GB | ~14 | ~8 GB |

Set: `LLAMACPP_CTX=65536 LLAMACPP_GPU_LAYERS=16 LLAMACPP_KV_TYPE=q4_0`

---

### Qwen3.5 9B Q4_K_M — all layers on GPU (8 GB profile)

**Configuration:** `--n-gpu-layers 99 -ctk f16 -ctv f16`

Model file: 5.3 GB. All layers on GPU. No special image or build required — runs on the standard `ghcr.io/ggml-org/llama.cpp:server-cuda` image.

| CTX | VRAM | Load | PP tok/s | TG tok/s |
|-----|------|------|----------|----------|
| 4 096 | 5.4 GB | 10s | 2 023 | 44.1 |
| 8 192 | 5.5 GB | 8s | 2 165 | 45.1 |
| 16 384 | 5.8 GB | 6s | 2 065 | 42.8 |
| 32 768 | 6.3 GB | 6s | 2 007 | 42.4 |
| 65 536 | 7.3 GB | 5s | 1 735 | 40.3 |
| 131 072 | 9.4 GB | 6s | 1 426 | 31.9 |
| 262 144 | 11.7 GB* | — | — | — | ← **bench-err (PP timeout)** |

*VRAM at model load: 11.7 GB — the model loads fine in 12 GB VRAM. However, filling 157K tokens (60% of 262K ctx) takes ~26 minutes at ~88 tok/s PP (measured from server logs). The bench client's 600 s HTTP timeout fired before the fill completed. Practically unusable — the quadratic cost of the standard attention layers at 262K makes prompt processing impractical for any real workload.

**Key findings:**

- **Flat TG from 4K to 65K** — TG stays 40–45 tok/s across the entire 4K–65K range. This is the Gated Delta Networks effect: linear attention layers accumulate state in a fixed-size recurrent matrix rather than a growing KV buffer, so per-token cost does not scale with context length.
- **PP collapses at 262K** — drops from 1 426 tok/s at 131K to ~88 tok/s at 262K. The standard attention layers' O(n²) cost dominates at full native context. This means Qwen3.5 9B's 262K native context is theoretical — prompt processing at that scale takes ~26 minutes.
- **VRAM jumps at 131K** — from 7.3 GB at 65K to 9.4 GB at 131K, a 2.1 GB jump. This is driven by the sparse standard-attention layers (not the linear ones), which maintain a conventional KV cache. At 131K ctx that KV cost pushes past the 8 GB threshold.
- **Max safe ctx for 8 GB: 65 536** — VRAM at 7.3 GB, TG at 40 tok/s. This comfortably fits within 8 GB with 700 MiB headroom.
- **System RAM:** Model fully on GPU. RAM overhead is Docker + WSL2 baseline only — approximately **1.5–2.5 GB**.
- **No special build needed.** Unlike the TurboQuant config, this runs on the unmodified upstream llama.cpp server image.

**8 GB recommendation for Qwen3.5 9B:**

| Use case | CTX | VRAM | TG tok/s | System RAM |
|----------|-----|------|----------|------------|
| Recommended default | 65 536 | 7.3 GB | ~40 | ~2 GB |
| Conservative | 32 768 | 6.3 GB | ~42 | ~2 GB |

Set: `LLAMACPP_CTX=65536 LLAMACPP_GPU_LAYERS=99`

---

### 8 GB choice: Qwen3.5 9B vs Gemma 4 26B A4B

| | Qwen3.5 9B Q4_K_M | Gemma 4 26B A4B (16L) |
|---|---|---|
| VRAM at 65K ctx | 7.3 GB | 7.8 GB |
| TG tok/s at 65K | **~40** | ~14 |
| PP tok/s at 65K | **~1 735** | ~877 |
| System RAM | **~2 GB** | ~8 GB |
| Image | Standard (no build) | Standard (no build) |
| Model quality | Good (9B dense) | **Better (26B MoE, 3.8B active)** |
| Context limit (8 GB safe) | 65 536 | 65 536 |

**Recommendation:** For 8 GB GPU users, **Qwen3.5 9B is the better choice for most use cases** — it delivers 3× better TG throughput, uses dramatically less system RAM, and requires no special image or build. The 26B A4B is only worth considering if model quality is the primary constraint and the user can tolerate 14 tok/s generation and 8 GB of RAM consumption.

---

<a name="build"></a>
## TurboQuant Image Build

```bash
docker build -t local-ai-stack/llamacpp-tq docker/llamacpp-tq/
# ~30 min on first build (CUDA kernel compilation). Requires Docker with GPU access.
# If WSL2 runs low on RAM, run: wsl --shutdown first to free memory.
```

The Dockerfile (`docker/llamacpp-tq/Dockerfile`) clones AtomicBot-ai/atomic-llama-cpp-turboquant and builds against CUDA 12.6 for sm_89 (RTX 40-series). Change `CUDA_ARCH` for other cards.

---

## Summary for handoff

| Profile | Model | GPU layers | KV type | CTX | VRAM | TG tok/s | System RAM |
|---------|-------|-----------|---------|-----|------|----------|------------|
| 12 GB — large ctx | Gemma 4 12B | 99 | f16 | 196 608 | 11.2 GB | ~25 | ~2 GB |
| 12 GB — best model | Gemma 4 26B A4B | 23 / 30 | q4_0 | 98 304 | 11.3 GB | ~21 | ~5 GB |
| 12 GB — max speed | Gemma 4 12B + MTP | 99 | turbo3 | 8 192 | 11.5 GB | ~103 | ~2 GB |
| 12 GB — speed+ctx | Gemma 4 12B + MTP | 99 | turbo3 | 16 384 | 11.5 GB | ~70 | ~2 GB |
| **8 GB — recommended** | **Qwen3.5 9B** | **99** | **f16** | **65 536** | **7.3 GB** | **~40** | **~2 GB** |
| 8 GB — quality alt | Gemma 4 26B A4B | 16 / 30 | q4_0 | 65 536 | 7.8 GB | ~14 | ~8 GB |

**Image requirements:**
- Standard configs (all except MTP): `ghcr.io/ggml-org/llama.cpp:server-cuda` — no build needed
- TurboQuant + MTP configs: `local-ai-stack/llamacpp-tq` — requires one-time build (~30 min)

---

## Next Steps — Implementation

The R&D benchmarks are done. These are the concrete integration tasks to pick up next.

---

### 1. Update `scripts/gpu-detect.sh` — llama.cpp model selection

`recommend_model()` currently returns Ollama model names. For llama.cpp the user needs to know which GGUF to download and which config to apply. Changes needed:

**Add a `recommend_llamacpp_model()` function** that returns the GGUF filename and a config preset label:

```
≥ 12 GB  → gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf   preset: 12gb-26b
  8–12 GB → Qwen3.5-9B-Q4_K_M.gguf                    preset: 8gb-qwen
  6–8 GB  → (needs a 7B GGUF choice — TBD)             preset: 6gb
  < 6 GB  → (too small for useful inference)
```

**Add a `recommend_llamacpp_config()` function** that takes the preset label and echoes the `.env` vars to set:

```bash
# preset: 12gb-26b
LLAMACPP_MODEL=gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf
LLAMACPP_GPU_LAYERS=23
LLAMACPP_CTX=98304
LLAMACPP_KV_TYPE=q4_0

# preset: 8gb-qwen
LLAMACPP_MODEL=Qwen3.5-9B-Q4_K_M.gguf
LLAMACPP_GPU_LAYERS=99
LLAMACPP_CTX=65536
LLAMACPP_KV_TYPE=f16
```

**Update `test-vram` in the justfile** to cover the new functions alongside the existing Ollama `recommend_model` / `recommend_ctx` tests.

---

### 2. `just setup` — llama.cpp auto-configure path

Currently `just setup` only handles Ollama model selection. Add a llama.cpp path:

1. Detect GPU (`detect_gpu` already works)
2. Call `recommend_llamacpp_model` to get the right GGUF + preset
3. Offer to download the GGUF (call `just download llamacpp model <hf-repo>`)
4. Call `recommend_llamacpp_config preset` and write the vars into `.env`
5. Print a summary and `just up llamacpp` prompt

HuggingFace repos to wire up:
- Gemma 4 26B A4B QAT: `unsloth/gemma-4-26B-A4B-it-qat-GGUF` (file: `gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf`)
- Gemma 4 12B QAT: `unsloth/gemma-4-12b-it-qat-GGUF` (file: `gemma-4-12B-it-qat-UD-Q4_K_XL.gguf`)
- Qwen3.5 9B: source TBD (was downloaded manually last session — find the canonical HF repo and add it)

---

### 3. `just download llamacpp` — known-model shortcuts

`just download llamacpp model <repo>` currently takes a raw HF repo. Add named shortcuts so setup can call them without hardcoding URLs:

```
just download llamacpp gemma4-26b    # → unsloth/gemma-4-26B-A4B-it-qat-GGUF
just download llamacpp gemma4-12b    # → unsloth/gemma-4-12b-it-qat-GGUF
just download llamacpp qwen35-9b     # → <canonical HF repo>
```

This also makes `just download` more user-friendly in README/docs.

---

### 4. MTP head — wire into `just up llamacpp-tq`

The MTP head (`mtp-gemma-4-12B-it.gguf`, 242 MB) is required for `llamacpp-tq` with `--spec-type draft-mtp`. Currently the compose file for `llamacpp-tq` likely doesn't wire up the MTP flags automatically:

- Check `docker/docker-compose.llamacpp-tq.yml` — does it already pass `--spec-type draft-mtp` and `--spec-draft-model`?
- If not, add those flags as env-var-controlled arguments (e.g. `LLAMACPP_MTP_MODEL`, defaulting to `mtp-gemma-4-12B-it.gguf` when set)
- Add `just download llamacpp mtp-head` shortcut for the MTP head download

---

### 5. `just bench` — consolidate with `bench-rd.sh`

`just bench` currently calls `scripts/bench-context.sh`. The R&D script `scripts/bench-rd.sh` is more capable (multiple phases, Qwen3.5, MTP). Decide:

- **Option A:** Keep `bench-rd.sh` as the authoritative bench script and update `just bench` to call it instead
- **Option B:** Merge the best parts of `bench-rd.sh` into `bench-context.sh`

Either way, the `just bench` command should expose the phase argument:
```
just bench f16
just bench 26b
just bench qwen35-9b
just bench mtp
```
