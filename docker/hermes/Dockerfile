FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# Core tools needed by the hermes install script and day-to-day use
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    python3 \
    python-is-python3 \
    python3-venv \
    ripgrep \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Node 22 LTS (hermes requires it)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Create the hermes user that will own the agent data volume
RUN useradd -m -s /bin/bash hermes

USER hermes
WORKDIR /home/hermes

# Install hermes agent for this user
RUN curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash

# Ensure hermes binary is on PATH
ENV PATH="/home/hermes/.local/bin:/home/hermes/.hermes/bin:${PATH}"

# Keep the container alive so 'docker exec -it hermes bash' works
CMD ["sleep", "infinity"]
