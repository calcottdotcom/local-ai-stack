FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# Base tools needed by the hermes install script
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

# Extended developer toolset — pre-installed to minimise agent apt-get usage
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Python
    python3-pip \
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
    wget \
    unzip \
    zip \
    tree \
    file \
    bc \
    # System tools
    lsof \
    htop \
    procps \
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

# Rust — install to /usr/local so it lives in the image layer, not the /root volume
ENV CARGO_HOME=/usr/local/cargo
ENV RUSTUP_HOME=/usr/local/rustup
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
ENV PATH="/usr/local/cargo/bin:${PATH}"

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
