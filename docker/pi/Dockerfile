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
USER pi
WORKDIR /home/pi

# Keep the container alive for 'docker exec -it pi bash' or for running
# pi in headless/server mode once that is supported
CMD ["sleep", "infinity"]
