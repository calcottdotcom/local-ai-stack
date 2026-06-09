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

WORKDIR /root

# Install hermes agent as root
RUN curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash

ENV PATH="/root/.local/bin:/root/.hermes/bin:${PATH}"

EXPOSE 8787

# Clone hermes-webui outside the volume mount so it survives volume attachment
RUN git clone --depth 1 https://github.com/nesquena/hermes-webui.git /opt/hermes-webui

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

CMD ["/entrypoint.sh"]
