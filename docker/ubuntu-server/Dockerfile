FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    openssh-server \
    curl \
    git \
    wget \
    python3 \
    python-is-python3 \
    nodejs \
    npm \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create an 'ai' user that agents SSH in as
RUN useradd -m -s /bin/bash ai \
    && echo "ai:localai" | chpasswd \
    && mkdir -p /home/ai/.ssh \
    && chmod 700 /home/ai/.ssh

# Allow password auth and permit ai user login
RUN mkdir /var/run/sshd \
    && sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config \
    && echo "AllowUsers ai" >> /etc/ssh/sshd_config

# Default nginx site — agents are expected to customise this
RUN echo '<html><body><h1>LocalAI Server</h1><p>Agents can deploy here.</p></body></html>' \
    > /var/www/html/index.html

EXPOSE 80 22

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

CMD ["/entrypoint.sh"]
