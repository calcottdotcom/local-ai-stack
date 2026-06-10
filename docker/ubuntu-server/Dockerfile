FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Base tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    wget \
    python3 \
    python-is-python3 \
    && rm -rf /var/lib/apt/lists/*

# Node 22 LTS
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Extended developer toolset — pre-installed to minimise agent apt-get usage
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Web server & SSH
    nginx \
    openssh-server \
    # Python
    python3-pip \
    python3-venv \
    python3-dev \
    # Build tools & compilers
    build-essential \
    cmake \
    pkg-config \
    autoconf \
    # Editors & terminal
    nano \
    vim \
    tmux \
    less \
    # File & archive utilities
    jq \
    unzip \
    zip \
    tree \
    file \
    bc \
    ripgrep \
    # System tools
    lsof \
    htop \
    procps \
    sudo \
    # Database clients
    sqlite3 \
    postgresql-client \
    default-mysql-client \
    redis-tools \
    # Network tools
    iputils-ping \
    traceroute \
    dnsutils \
    net-tools \
    nmap \
    netcat-openbsd \
    socat \
    rsync \
    openssh-client \
    telnet \
    # Media
    ffmpeg \
    imagemagick \
    && rm -rf /var/lib/apt/lists/*

# Go — official binary, multi-arch
RUN ARCH=$(uname -m) && \
    case "$ARCH" in x86_64) GOARCH=amd64 ;; aarch64) GOARCH=arm64 ;; *) echo "Unsupported arch: $ARCH" && exit 1 ;; esac && \
    curl -fsSL "https://go.dev/dl/go1.24.3.linux-${GOARCH}.tar.gz" | tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:${PATH}"

# Create the ai user agents SSH into, with passwordless sudo for session installs
RUN useradd -m -s /bin/bash ai \
    && echo "ai:localai" | chpasswd \
    && mkdir -p /home/ai/.ssh \
    && chmod 700 /home/ai/.ssh \
    && echo "ai ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Rust — installed for the ai user so it's available in SSH sessions
USER ai
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path && \
    echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> /home/ai/.bashrc
USER root

# SSH config
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
