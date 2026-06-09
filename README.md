# Local AI for Starters
There's loads of options for running local LLMs as well as utilities that can sit on top of them. This project aims to package together a few common use cases with some learning along the way.
 
## Key Components
 The parts listed below help make a local LLM go from "oh, interesting" to "wow - useful!". All are optional, swappable, learnable and expandable. This is an initial set of services which can replicate some cloud AI functionality on a local GPU.

* An LLM inference engine. We'll be using [Ollama](https://ollama.com/) or [Llama.cpp](https://github.com/ggml-org/llama.cpp) - both with benefits over each other.
* A web-based chat UI for that ChatGPT feel. We'll use [OpenWebUI](https://github.com/open-webui/open-webui)
* A web search service for the chat UI and other services to use. We'll use [Searxng](https://github.com/searxng/searxng)
* A generalist AI agent with a built-in web UI, which you can use to get things done. We'll use [Hermes](https://github.com/nousresearch/hermes-agent) with [Hermes Web UI](https://github.com/nesquena/hermes-webui) embedded in the same container
* A coding AI agent, lightweight and dedicated to coding as opposed to the generalist. We'll use [Pi Coding Agent](https://github.com/earendil-works/pi)
* A general web server which the agents can ssh into to run things. We'll use an ubuntu container - asking the agents to setup nginx etc.
* A reverse proxy to allow for domain mapping to these container services on different ports. We'll use nginx. Along with this we have a wrapper for local domains and SSL using [mkcert](https://github.com/filosottile/mkcert) and your `/etc/hosts` file (optional but makes things feel more like real-world services!).
* A web-design tool using AI, using [open design](https://github.com/nexu-io/open-design)
* A simple media-generation workflow service, using [comfyui](https://github.com/comfy-org/comfyui).
* Some simple containers wrapped behind just commands to prove that all the GPU passthrough is working (e.g. `just gpucheck`) which use things like nvtop, nvidia-smi etc.

Each of these is outlined in more detail below. There's a one-shot docker compose file and some just commands you can run to go with the defaults, and a set of config and .env files you can edit to customise. 

## Requirements

You'll need **Docker** and **just** installed. The stack runs on Linux, Windows (via WSL2), and macOS.

### Linux (native)

Install the [Nvidia Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) for Nvidia GPU passthrough, or ROCm + video/render group membership for AMD.

```bash
sudo apt install just        # Ubuntu/Debian
# or: curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to ~/.local/bin
```

### Windows (WSL2)

WSL2 lets you run the full stack inside a Linux environment on Windows. Docker Desktop handles the container runtime and GPU passthrough.

**Step 1 — Enable WSL2** (skip if already done):
```powershell
# Run in PowerShell as Administrator
wsl --install
# Restart when prompted, then open the Ubuntu app to finish setup
```

**Step 2 — Install Docker Desktop for Windows:**
[https://docs.docker.com/desktop/setup/install/windows-install/](https://docs.docker.com/desktop/setup/install/windows-install/)

In Docker Desktop → Settings → General: enable **"Use WSL 2 based engine"**.  
In Docker Desktop → Settings → Resources → WSL Integration: enable your Ubuntu distro.

**Step 3 — Install `just` inside WSL** (open the Ubuntu/WSL terminal):
```bash
sudo apt install just
```

**Step 4 — Nvidia GPU passthrough** (skip if no Nvidia GPU):  
Install the [Nvidia CUDA drivers for WSL](https://developer.nvidia.com/cuda/wsl) on Windows (not inside WSL — the Windows driver is sufficient). Verify with `nvidia-smi` inside WSL.

**Step 5 — Clone and run:**
```bash
git clone https://github.com/calcottdotcom/local-ai-stack.git
cd local-ai-stack
just setup
```

> All commands run inside your WSL terminal. The stack itself runs in Docker — no Linux knowledge required beyond the above.

### macOS

On macOS, Ollama runs **natively on the host** (not in Docker) so it can use Metal GPU acceleration. Docker containers connect to it via `host.docker.internal`.

**Step 1 — Install Docker Desktop for Mac:**  
[https://docs.docker.com/desktop/setup/install/mac-install/](https://docs.docker.com/desktop/setup/install/mac-install/)

**Step 2 — Install `just` and Ollama:**
```bash
brew install just
brew install ollama
```
Or install Ollama from [https://ollama.com/download/mac](https://ollama.com/download/mac) (menu bar app).

**Step 3 — Start Ollama** (if using the menu bar app, just open it; if using Homebrew, run `ollama serve`).

**Step 4 — Clone and run:**
```bash
git clone https://github.com/calcottdotcom/local-ai-stack.git
cd local-ai-stack
just setup
```

The setup wizard detects macOS, estimates usable RAM for model sizing (40% of total — conservative for OS + Docker overhead), and skips the provider selection (Ollama only on Mac). It will recommend a model appropriate for your RAM:

| Total RAM | Recommended model |
|-----------|------------------|
| 24 GB+    | gemma4:12b (128K context) |
| 16 GB     | gemma4:12b |
| 12 GB     | qwen3.5:9b |
| 8 GB      | qwen3.5:7b |
| < 8 GB    | qwen3.5:4b |

> **Note:** Llama.cpp and ComfyUI are not supported on macOS — `just up ollama` is the only inference path.

## Getting started
### Setup
Just run `just setup` for an interactive setup process which will analyse the requirements from above and your GPU / system to recommend you some models and setup. It will also offer to install mkcert and modify your /etc/hosts file.

## Running the stack
All of the containers belong to the same docker compose stack (named `local-ai-stack`) and there's a few options here:
* `just up ollama` runs the stack with ollama as the inference provider
* `just up llamacpp` runs the stack with llama.cpp as the inference provider
* `just up comfy` runs the comfyui service. Note that if you only have one GPU you're unlikely to be able to run this alongside llamacpp
* `just setup local-domains` will modify your /etc/hosts file and configure mkcert

These commands automatically rewire the config files for OpenWebUI, Hermes, Pi etc to use the correct inference provider but running them may restart your service.

The containers make use of local mounted volumes for certain folders so you can edit files from your host machine, but other things that aren't usually editable are in persistent docker volumes.

### Getting models
We provide a simple way to get models into ollama and llama.cpp. We recommend starting with either Qwen3.5 9b or Gemma4 12b (the latter is more recent but probably won't run on less than 12GB VRAM).

You can run (for example):
* `just download ollama model qwen3.5:9b` (for example) which will automatically analyse your vram to set a context window size using a Modelfile.
* `just download llamacpp model google/gemma-4-12B-it-qat-q4_0-gguf` - this uses huggingface model names to download. This commands then runs the  `just set llamacpp [modelname]` command to set the default model.

These commands show progress and on completion where the files were stored.

## Testing
The services that run by default are:
* Ollama on 11435 (so it doesn't clash with anything on your host machine running on the default port of 11434). If you've run the local domains setup script this will live on https://ollama.localai
* Llama.cpp on 8089 (default usually 8080 but that's commonly used so we override). Local domain is https://llamacpp.localai
* Chat UI on port 8086 / https://chat.localai
* Searxng on 8888 / https://searxng.localai
* Hermes web ui on 8787 / https://hermes.localai
* General server for ai output: localhost:8087 / https://www.localai
* ComfyUI for media generation on localhost:8188 / https://comfyui.localai
* OpenDesign for web design on localhost:7456 / https://design.localai
* Reverse proxy runs on 80 and 443 to handle custom domains with SSL.

The quickest test to ensure the basics are working is to run `just up ollama` then use the just command to `just download ollama model qwen3.5:9b`. This will take a few minutes depending on your internet speed.

Next, go to the chat UI and you should see the model named in the top left. If using ollama, you can choose between multiple models you've downloaded.

## Starting with agents
Running `just hermes ssh` will ssh into the hermes container. The hermes container runs as root, so the agent can `apt-get install` freely during a session. To persist a package across container restarts, add it to `~/.hermes/apt-packages.txt` (one per line) — those packages are reinstalled automatically on every start. Files and Python venvs created inside the workspace (`~/workspace/`) live on a persistent Docker volume and survive restarts normally. Running `hermes` within the ssh session will start the hermes session - on the first run it's usually a good idea to tell the agent who they are and how to behave / sound.

By default the agents don't know how to do web searches using the tools we've given them. So for the first prompt, try:
```
Update your web search skill to only use the local searxng instance which runs at searxng:8888. 
An example query for a general search would be: 
http://searxng:8888/search?q=local%20ai&categories=general&format=rss
and for "news" it'd be:
http://searxng:8888/search?q=local%20ai&categories=news&format=rss
Test that it works and let me know if not!
```
From then on, get the agent to fix itself with things like this.

## Technical notes
* All docker containers communicate with each other on their own docker network (local-ai-net) rather than going to the host and back in. This means inter-container communication happens on default ports but the EXPOSED ports to the host are the ones listed above.
* Context window size is maximised to make agents useful but we do not spill over into system RAM unless the GPU VRAM is very low (e.g. 6GB). Better to suggest a smaller model.
* Llama.cpp uses MTP to speed up inference. We only use models with that enabled.
* Other than installing `just` and `docker` as well as drivers, the user shouldn't have to know how to install everything. For example mkcert - we can offer to install it using the just scripts.