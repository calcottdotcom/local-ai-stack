FROM node:22-slim

ENV DEBIAN_FRONTEND=noninteractive

# Base tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Extended developer toolset — pre-installed to minimise agent apt-get usage
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Python
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    # Build tools & compilers
    build-essential \
    cmake \
    pkg-config \
    # Editors & utilities
    nano \
    vim \
    jq \
    wget \
    unzip \
    zip \
    tree \
    file \
    bc \
    less \
    ripgrep \
    # System tools
    lsof \
    procps \
    # Database
    sqlite3 \
    # Network tools
    iputils-ping \
    dnsutils \
    netcat-openbsd \
    rsync \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Go — official binary, multi-arch
RUN ARCH=$(uname -m) && \
    case "$ARCH" in x86_64) GOARCH=amd64 ;; aarch64) GOARCH=arm64 ;; *) echo "Unsupported arch: $ARCH" && exit 1 ;; esac && \
    curl -fsSL "https://go.dev/dl/go1.24.3.linux-${GOARCH}.tar.gz" | tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:${PATH}"

# Install Pi Coding Agent globally
RUN npm install -g @earendil-works/pi-coding-agent --ignore-scripts

# Create pi user then install Rust for that user
RUN useradd -m -s /bin/bash pi

USER pi
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
ENV PATH="/home/pi/.cargo/bin:${PATH}"

USER root
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
USER pi
WORKDIR /home/pi

CMD ["/entrypoint.sh"]
