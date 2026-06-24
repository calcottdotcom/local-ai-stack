# Gemma 4 QAT Context Benchmark — RTX 4080 Laptop 12 GB

**Date:** 2026-06-24  
**Status:** 12 GB complete. 8 GB section is a placeholder — not yet benchmarked.

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

Both are QAT (Quantization-Aware Training) variants — higher quality at the same bit-width vs post-training quantization. Do not substitute non-QAT variants; the quality difference is meaningful for these model sizes.

**Gemma 4 architecture note:** Both models use hybrid local/global attention — most transformer layers use a sliding window (4K tokens), with sparse global attention layers attending the full sequence. This is why VRAM scales very sub-linearly with context length compared to a fully-dense transformer.

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

## TurboQuant (AtomicBot fork) — NOT YET BENCHMARKED

The `scripts/bench-rd.sh turbo3` phase and `scripts/bench-rd.sh mtp` phase require the custom Docker image built from `docker/llamacpp-tq/Dockerfile` (AtomicBot-ai/atomic-llama-cpp-turboquant fork).

**Build status:** Not yet completed. Previous build attempt was interrupted by system sleep during a ~30-minute CUDA compilation. Image: `local-ai-stack/llamacpp-tq`.

**Expected benefit for 12B:** TurboQuant `turbo3` (4.3× KV compression) should allow 12B to run at 256K context comfortably within 12 GB. MTP head (`mtp-gemma-4-12B-it.gguf`, 242 MB) claims +30–50% TG throughput.

**Build command:**
```bash
docker build -t local-ai-stack/llamacpp-tq docker/llamacpp-tq/
# Allow ~30 min. Ensure WSL2 has RAM headroom before starting (wsl --shutdown first).
```

---

## 8 GB VRAM — PLACEHOLDER

> **Not yet benchmarked.** The following are estimates only.

Target hardware: RTX 4060 / RTX 3070 / RX 6700 XT class (8 GB VRAM).

### Gemma 4 12B — estimated 8 GB config

The 12B model weights alone are 6.3 GB, leaving ~1.7 GB for KV cache and overhead on an 8 GB card. Full GPU layer loading should still be possible but context window will be very constrained with f16 KV.

| KV type | Expected max CTX | Notes |
|---------|-----------------|-------|
| f16 | ~8 192–16 384 | Very limited; likely marginal |
| q4_0 | ~32 768–49 152 | More practical |
| turbo3 (TQ) | ~65 536–98 304 | Requires TQ image build |

**To benchmark:** `bash scripts/bench-rd.sh f16 4096 8192 12288 16384` then `bash scripts/bench-rd.sh q4_0 16384 32768 49152`.

### Gemma 4 26B A4B — estimated 8 GB config

With only ~1.7 GB free after the 12B weights, the 26B (13.3 GB) will need heavy CPU offloading. Rough estimate: ~10–12 GPU layers, ~18 on CPU, with ~6 GB of model weights in RAM.

TG speed will be lower than the 12 GB results. The 3.8B active param MoE architecture helps, but with most layers on CPU, expect TG in the range of 5–12 tok/s.

**To benchmark:** `GPU_LAYERS_26B=12 bash scripts/bench-rd.sh 26b 4096 8192 16384 32768`

---

## Summary for handoff

| Model | GPU layers | KV type | Recommended CTX | VRAM | TG tok/s | System RAM |
|-------|-----------|---------|----------------|------|----------|------------|
| 12B | 99 (all) | f16 | 196 608 | 11.2 GB | ~25 | ~2 GB |
| 26B A4B | 23 / 30 | q4_0 | 98 304 | 11.3 GB | ~21 | ~5 GB |

Both models are QAT variants from Unsloth. Both run on the standard `ghcr.io/ggml-org/llama.cpp:server-cuda` image — no custom build needed for these configurations. The TurboQuant image is a future optimisation, not a prerequisite.
