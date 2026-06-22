#!/usr/bin/env bash
set -euo pipefail

# --conf-only: skip mkcert, CA install, cert generation, /etc/hosts, and nginx
# reload. Used by CI to generate nginx config files against pre-existing certs.
CONF_ONLY=false
if [[ "${1:-}" == "--conf-only" ]]; then
    CONF_ONLY=true
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CERTS_DIR="$ROOT_DIR/config/nginx/certs"
CONF_D="$ROOT_DIR/config/nginx/conf.d"

# Provides: PLATFORM (linux | wsl | mac), detect_platform(), sedi()
# shellcheck source=scripts/gpu-detect.sh
source "$SCRIPT_DIR/gpu-detect.sh"

bold() { echo -e "\033[1m$*\033[0m"; }
info() { echo -e "  \033[36m→\033[0m $*"; }
ok()   { echo -e "  \033[32m✓\033[0m $*"; }
warn() { echo -e "  \033[33m!\033[0m $*"; }

DOMAINS=(
    "ollama.localai"
    "llamacpp.localai"
    "chat.localai"
    "searxng.localai"
    "hermes.localai"
    "www.localai"
    "comfyui.localai"
    "design.localai"
)

echo ""
bold "Local Domains Setup"
echo "────────────────────────────────────────"

if [[ "$CONF_ONLY" != "true" ]]; then

    # ── WSL: point mkcert at a Windows-accessible CA root ─────────────────────
    # When CAROOT is inside the Windows filesystem, the CA cert can be imported
    # into the Windows trust store so browsers on the Windows host trust it.

    if [[ "$PLATFORM" == "wsl" ]]; then
        WIN_USER=$(powershell.exe -Command "[Environment]::UserName" 2>/dev/null | tr -d '\r\n')
        WIN_CAROOT="/mnt/c/Users/${WIN_USER}/AppData/Local/mkcert"
        mkdir -p "$WIN_CAROOT"
        export CAROOT="$WIN_CAROOT"
        info "WSL detected — CA will be stored at Windows path: C:\\Users\\${WIN_USER}\\AppData\\Local\\mkcert"
    fi

    # ── mkcert ─────────────────────────────────────────────────────────────────

    if ! command -v mkcert &>/dev/null; then
        warn "mkcert is not installed."
        read -rp "  Install mkcert now? [Y/n]: " INSTALL_MKCERT
        INSTALL_MKCERT=${INSTALL_MKCERT:-Y}
        if [[ "$INSTALL_MKCERT" =~ ^[Yy]$ ]]; then
            if command -v apt-get &>/dev/null; then
                sudo apt-get update -qq && sudo apt-get install -y mkcert libnss3-tools
            elif command -v brew &>/dev/null; then
                brew install mkcert nss
            else
                warn "Cannot auto-install mkcert. Install it manually: https://github.com/FiloSottile/mkcert"
                exit 1
            fi
        else
            warn "Skipping — local domains will run on HTTP only."
            exit 0
        fi
    fi
    ok "mkcert is available"

    # ── Install local CA ───────────────────────────────────────────────────────

    info "Installing local certificate authority..."
    mkcert -install
    ok "Local CA installed"

    # ── Generate certs ────────────────────────────────────────────────────────
    # CAROOT export propagates into the subshell so mkcert uses the right CA.

    mkdir -p "$CERTS_DIR"
    info "Generating certificates in $CERTS_DIR..."
    (
        cd "$CERTS_DIR"
        mkcert "${DOMAINS[@]}"
        # mkcert writes a single cert covering all domains — rename to
        # predictable filenames for nginx.
        mv ./*+*-key.pem localai-key.pem 2>/dev/null || true
        mv ./*+*.pem     localai.pem     2>/dev/null || true
    )
    ok "Certificates generated"

    # ── /etc/hosts and Windows trust store ────────────────────────────────────

    HOSTS_BLOCK_START="# BEGIN local-ai-stack"
    HOSTS_BLOCK_END="# END local-ai-stack"

    update_hosts_file() {
        # Remove previous block, append new one. Args: <hosts-file> [sudo]
        local hosts_file="$1" use_sudo="${2:-false}"
        local cmd_prefix=""
        [[ "$use_sudo" == "true" ]] && cmd_prefix="sudo"

        if grep -q "$HOSTS_BLOCK_START" "$hosts_file" 2>/dev/null; then
            $cmd_prefix sed -i "/$HOSTS_BLOCK_START/,/$HOSTS_BLOCK_END/d" "$hosts_file"
        fi
        {
            echo "$HOSTS_BLOCK_START"
            for domain in "${DOMAINS[@]}"; do
                echo "127.0.0.1  $domain"
            done
            echo "$HOSTS_BLOCK_END"
        } | $cmd_prefix tee -a "$hosts_file" > /dev/null
    }

    if [[ "$PLATFORM" == "wsl" ]]; then
        # On WSL we need two things that require Windows admin:
        #   1. Import the mkcert CA into the Windows certificate store so that
        #      Chrome, Edge, and other Windows browsers trust the certs.
        #   2. Add the .localai entries to the Windows hosts file so that
        #      Windows programs (browsers) can resolve the domain names.
        # We combine both into one PowerShell script and trigger a single UAC
        # prompt so the user only has to click "Yes" once.

        WIN_CA_WIN_PATH="C:\\Users\\${WIN_USER}\\AppData\\Local\\mkcert\\rootCA.pem"
        WIN_HOSTS_PATH='C:\Windows\System32\drivers\etc\hosts'

        info "Requesting Windows admin access for CA import and hosts file..."
        PS_FILE=$(mktemp /tmp/localai-XXXXXX.ps1)

        {
            # CA import — idempotent: skip if mkcert CA is already trusted
            echo "\$caPath = '${WIN_CA_WIN_PATH}'"
            echo "\$existing = Get-ChildItem Cert:\\LocalMachine\\Root |"
            echo "    Where-Object { \$_.Subject -like '*mkcert*' }"
            echo "if (-not \$existing) {"
            echo "    Import-Certificate -FilePath \$caPath -CertStoreLocation Cert:\\LocalMachine\\Root | Out-Null"
            echo "    Write-Host 'mkcert CA imported into Windows certificate store.'"
            echo "} else {"
            echo "    Write-Host 'mkcert CA already trusted — skipping import.'"
            echo "}"
            echo ""
            # Hosts file — remove old block, append fresh one
            echo "\$hostsPath = '${WIN_HOSTS_PATH}'"
            echo "\$lines = (Get-Content \$hostsPath) |"
            echo "    Where-Object { \$_ -notmatch '${HOSTS_BLOCK_START}|${HOSTS_BLOCK_END}|\.localai' }"
            echo "\$new = @("
            echo "    '${HOSTS_BLOCK_START}'"
            for domain in "${DOMAINS[@]}"; do
                echo "    '127.0.0.1  ${domain}'"
            done
            echo "    '${HOSTS_BLOCK_END}'"
            echo ")"
            echo "(\$lines + \$new) | Set-Content \$hostsPath"
            echo "Write-Host 'Windows hosts file updated.'"
        } > "$PS_FILE"

        WIN_PS_PATH=$(wslpath -w "$PS_FILE")
        powershell.exe -Command \
            "Start-Process powershell -Verb RunAs -Wait \
             -ArgumentList '-ExecutionPolicy Bypass -File \"${WIN_PS_PATH}\"'"
        rm -f "$PS_FILE"
        ok "Windows certificate store and hosts file updated"

        # Also update WSL's own /etc/hosts so in-WSL tools (curl, tests) resolve
        # the domains to the nginx container via Docker's loopback.
        info "Updating WSL /etc/hosts (for in-WSL tools)..."
        update_hosts_file "/etc/hosts" "true"
        ok "WSL /etc/hosts updated"

    else
        # Linux / macOS: straightforward sudo hosts update
        info "Adding entries to /etc/hosts (requires sudo)..."
        update_hosts_file "/etc/hosts" "true"
        ok "/etc/hosts updated"
    fi

fi  # end non-conf-only section

# ── nginx HTTPS config ─────────────────────────────────────────────────────────
# ssl.conf is gitignored — generated here and loaded by nginx alongside
# services.conf (which this script also rewrites to redirect HTTP to HTTPS).

info "Writing HTTPS server blocks to $CONF_D/ssl.conf..."
cat > "$CONF_D/ssl.conf" <<'NGINX'
# Auto-generated by setup-local-domains.sh — do not edit manually
# Re-run 'just setup local-domains' to regenerate.

ssl_certificate     /etc/nginx/certs/localai.pem;
ssl_certificate_key /etc/nginx/certs/localai-key.pem;
ssl_protocols       TLSv1.2 TLSv1.3;
ssl_ciphers         HIGH:!aNULL:!MD5;

server {
    listen 443 ssl;
    server_name chat.localai;
    location / {
        set $upstream            http://openwebui:8080;
        proxy_pass               $upstream;
        proxy_set_header         Host              $host;
        proxy_set_header         X-Real-IP         $remote_addr;
        proxy_set_header         X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header         X-Forwarded-Proto https;
        proxy_set_header         Upgrade           $http_upgrade;
        proxy_set_header         Connection        $connection_upgrade;
        proxy_read_timeout       300s;
    }
}

server {
    listen 443 ssl;
    server_name ollama.localai;
    location / {
        set $upstream            http://ollama:11434;
        proxy_pass               $upstream;
        proxy_set_header         Host              $host;
        proxy_set_header         X-Real-IP         $remote_addr;
        proxy_set_header         X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header         X-Forwarded-Proto https;
        proxy_read_timeout       300s;
    }
}

server {
    listen 443 ssl;
    server_name llamacpp.localai;
    location / {
        set $upstream            http://llamacpp:8080;
        proxy_pass               $upstream;
        proxy_set_header         Host              $host;
        proxy_set_header         X-Real-IP         $remote_addr;
        proxy_set_header         X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header         X-Forwarded-Proto https;
        proxy_read_timeout       300s;
    }
}

server {
    listen 443 ssl;
    server_name searxng.localai;
    location / {
        set $upstream            http://searxng:8080;
        proxy_pass               $upstream;
        proxy_set_header         Host              $host;
        proxy_set_header         X-Real-IP         $remote_addr;
        proxy_set_header         X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header         X-Forwarded-Proto https;
    }
}

server {
    listen 443 ssl;
    server_name hermes.localai;
    location / {
        set $upstream            http://hermes:8787;
        proxy_pass               $upstream;
        proxy_set_header         Host              $host;
        proxy_set_header         X-Real-IP         $remote_addr;
        proxy_set_header         X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header         X-Forwarded-Proto https;
        proxy_set_header         Upgrade           $http_upgrade;
        proxy_set_header         Connection        $connection_upgrade;
        proxy_read_timeout       300s;
    }
}

server {
    listen 443 ssl;
    server_name www.localai;
    location / {
        set $upstream            http://ubuntu-server:80;
        proxy_pass               $upstream;
        proxy_set_header         Host              $host;
        proxy_set_header         X-Real-IP         $remote_addr;
        proxy_set_header         X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header         X-Forwarded-Proto https;
    }
}

server {
    listen 443 ssl;
    server_name comfyui.localai;
    location / {
        set $upstream            http://comfyui:8188;
        proxy_pass               $upstream;
        proxy_set_header         Host              $host;
        proxy_set_header         X-Real-IP         $remote_addr;
        proxy_set_header         X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header         X-Forwarded-Proto https;
        proxy_set_header         Upgrade           $http_upgrade;
        proxy_set_header         Connection        $connection_upgrade;
        proxy_read_timeout       300s;
    }
}

server {
    listen 443 ssl;
    server_name design.localai;
    location / {
        set $upstream            http://pi:7456;
        proxy_pass               $upstream;
        proxy_set_header         Host              $host;
        proxy_set_header         X-Real-IP         $remote_addr;
        proxy_set_header         X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header         X-Forwarded-Proto https;
        proxy_set_header         Upgrade           $http_upgrade;
        proxy_set_header         Connection        $connection_upgrade;
    }
}
NGINX
ok "SSL config written"

# ── Rewrite services.conf to redirect HTTP → HTTPS ────────────────────────────
# Per-domain exact matches override any wildcard approach so redirects fire
# reliably regardless of nginx's server block selection order.

info "Updating services.conf to redirect HTTP traffic to HTTPS..."
cat > "$CONF_D/services.conf" <<'NGINX'
# HTTP → HTTPS redirects — updated by setup-local-domains.sh
# To restore plain-HTTP access: git checkout config/nginx/conf.d/services.conf

server { listen 80; server_name chat.localai;     return 301 https://$host$request_uri; }
server { listen 80; server_name ollama.localai;   return 301 https://$host$request_uri; }
server { listen 80; server_name llamacpp.localai; return 301 https://$host$request_uri; }
server { listen 80; server_name searxng.localai;  return 301 https://$host$request_uri; }
server { listen 80; server_name hermes.localai;   return 301 https://$host$request_uri; }
server { listen 80; server_name www.localai;      return 301 https://$host$request_uri; }
server { listen 80; server_name comfyui.localai;  return 301 https://$host$request_uri; }
server { listen 80; server_name design.localai;   return 301 https://$host$request_uri; }
NGINX
ok "services.conf updated with HTTP redirects"

if [[ "$CONF_ONLY" != "true" ]]; then

    # ── Reload nginx ───────────────────────────────────────────────────────────

    if docker ps -q --filter name=nginx | grep -q .; then
        info "Reloading nginx..."
        docker exec nginx nginx -s reload
        ok "nginx reloaded"
    fi

    echo ""
    bold "Local domains ready!"
    for domain in "${DOMAINS[@]}"; do
        echo "  https://$domain"
    done
    echo ""

fi
