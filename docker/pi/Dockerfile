FROM node:22-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Pi Coding Agent globally
RUN npm install -g @earendil-works/pi-coding-agent --ignore-scripts

# Create a non-root user for the agent to run as
RUN useradd -m -s /bin/bash pi

# Entrypoint writes settings.json from env vars, then keeps container alive
USER root
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
USER pi
WORKDIR /home/pi

CMD ["/entrypoint.sh"]
