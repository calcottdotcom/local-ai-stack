# Local AI for Starters
There's loads of options for running local LLMs as well as utilities that can sit on top of them. This project aims to package together a few common use cases with some learning along the way.
 
## Key Components
 The parts listed below help make a local LLM go from "oh, interesting" to "wow - useful!". All are optional, swappable, learnable and expandable. This is an initial set of services which can replicate some cloud AI functionality on a local GPU.

* An LLM inference engine. We'll be using Ollama or Llama.cpp - both with benefits over each other.
* A web-based chat UI for that ChatGPT feel. We'll use OpenWebUI
* A web search service for the chat UI and other services to use. We'll use Searxng
* A generalist AI agent, which you can use to get to do stuff. We'll use Hermes
* A web ui for the generalist agent. We'll use Hermes Web UI
* A coding AI agent, lightweight and dedicated to coding as opposed to the generalist. We'll use Pi Coding Agent
* A general web server which the agents can ssh into to run things. We'll use an ubuntu container - asking the agents to setup nginx etc.
* A reverse proxy to allow for domain mapping to these container services on different ports. We'll use nginx.
* A wrapper for local domains and SSL using mkcert and your /etc/hosts file (optional but makes things feel more like real-world services!).
* A simple media-generation workflow service, using comfyui.
* Some simple containers wrapped behind just commands to prove that all the GPU passthrough is working (e.g. `just gpucheck`)

Each of these is outlined in more detail below. There's a one-shot docker compose file and some just commands you can run to go with the defaults, and a set of config and .env files you can edit to customise. 

## Requirements
This is currently targeting a linux environment with a dedicated GPU (ideally Nvidia, though AMD should work). Just is used to wrap bash and other commands, as is docker for containers.

To pass through your GPU to the docker containers:
* On Nvidia, you'll need to install the Nvidia Container Toolkit, as well as the official Nvidia linux drivers. 
* On AMD you'll need to install rocm and add your user to the render and video groups

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
Running `just hermes ssh` will ssh into the hermes container. This container has persistent volumes so anything installed by apt or in the home folders will survive a reboot. Running `hermes` within the ssh session will start the hermes session - on the first run its usually a good idea to tell the agent who they are and how to behave / sound.

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
