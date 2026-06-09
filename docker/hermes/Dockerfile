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

# Ubuntu 24.04 ships with an 'ubuntu' user at uid 1000. Remove it so hermes
# can take uid 1000, which matches the volume ownership on the host.
RUN userdel -r ubuntu && useradd -m -u 1000 -s /bin/bash hermes

USER hermes
WORKDIR /home/hermes

# Install hermes agent for this user
RUN curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash

# Ensure hermes binary is on PATH
ENV PATH="/home/hermes/.local/bin:/home/hermes/.hermes/bin:${PATH}"

EXPOSE 8787

# Clone hermes-webui outside /home/hermes (which is a volume mount) so the
# venv and source survive volume attachment without being shadowed.
USER root
RUN git clone --depth 1 https://github.com/nesquena/hermes-webui.git /opt/hermes-webui \
    && chown -R hermes:hermes /opt/hermes-webui

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
USER hermes

CMD ["/entrypoint.sh"]
