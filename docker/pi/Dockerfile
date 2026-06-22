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
    # Chromium runtime deps (required by CloakBrowser)
    libasound2 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libcairo2 \
    libcups2 \
    libdrm2 \
    libgbm1 \
    libglib2.0-0 \
    libnspr4 \
    libnss3 \
    libpango-1.0-0 \
    libvulkan1 \
    libxdamage1 \
    libxext6 \
    libxfixes3 \
    libxkbcommon0 \
    libxrandr2 \
    xdg-utils \
    && rm -rf /var/lib/apt/lists/*

# CloakBrowser — stealth Chromium for bypassing bot detection
RUN pip install --no-cache-dir --break-system-packages cloakbrowser mcp-cloakbrowser

# Go — official binary, multi-arch
RUN ARCH=$(uname -m) && \
    case "$ARCH" in x86_64) GOARCH=amd64 ;; aarch64) GOARCH=arm64 ;; *) echo "Unsupported arch: $ARCH" && exit 1 ;; esac && \
    curl -fsSL "https://go.dev/dl/go1.24.3.linux-${GOARCH}.tar.gz" | tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:${PATH}"

# Install Pi Coding Agent globally
RUN npm install -g @earendil-works/pi-coding-agent --ignore-scripts

# OpenDesign — copy runtime from official image; pi agent drives it
COPY --from=vanjayak/open-design:latest /app /app
# Rebuild better-sqlite3 for glibc: the COPY gives the Alpine/musl-linked binary.
# Install from npm into a temp dir (triggers node-gyp automatically), swap the .node file.
RUN npm install --prefix /tmp/bs better-sqlite3@12.10.0 \
    && cp /tmp/bs/node_modules/better-sqlite3/build/Release/better_sqlite3.node \
        /app/apps/daemon/node_modules/.pnpm/better-sqlite3@12.10.0/node_modules/better-sqlite3/build/Release/better_sqlite3.node \
    && rm -rf /tmp/bs

# Create pi user, then own the opendesign app tree and data dir
RUN useradd -m -s /bin/bash pi && mkdir -p /app/.od && chown -R pi:pi /app

USER pi
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
ENV PATH="/home/pi/.cargo/bin:${PATH}"

USER root
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
USER pi
WORKDIR /home/pi

EXPOSE 7456

CMD ["/entrypoint.sh"]
