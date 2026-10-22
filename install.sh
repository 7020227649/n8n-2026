#!/usr/bin/env bash
# ==============================================================================
# One-Shot n8n Production Installer for Ubuntu 22.04 LTS (1 GB RAM VPS Optimized)
# Features:
#   - Interactive Domain Prompt & Validation
#   - 2 GB Swap File Creation & Kernel Memory Tuning
#   - Docker & Docker Compose v2 Official Setup
#   - n8n + Caddy Reverse Proxy (Automatic Let's Encrypt SSL)
#   - Memory & Execution Pruning Optimization for 1 GB VPS
#   - Manual Update Command (`sudo n8n-update`)
#   - Automated 15-Day Update Check via systemd Timer
# ==============================================================================

set -euo pipefail

# --- Colors for Output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}======================================================================${NC}"
echo -e "${CYAN}       n8n One-Shot Installer for Ubuntu 22.04 (1 GB VPS Ready)       ${NC}"
echo -e "${CYAN}======================================================================${NC}"

# --- 1. Root Privilege Check ---
if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}[ERROR] Please run this script as root (e.g., sudo bash install.sh)${NC}"
    exit 1
fi

# --- 2. Interactive Domain Prompt ---
DOMAIN_INPUT="${1:-}"

while true; do
    if [[ -z "${DOMAIN_INPUT}" ]]; then
        echo -e ""
        read -r -p "Enter the domain/subdomain to connect to n8n (e.g., n8n.web4cause.com): " DOMAIN_INPUT </dev/tty
    fi

    # Strip http://, https://, paths, and whitespace
    DOMAIN=$(echo "${DOMAIN_INPUT}" | sed -E 's|^https?://||I' | cut -d'/' -f1 | tr -d '[:space:]')

    # Validate domain format
    if [[ "${DOMAIN}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
        echo -e "${GREEN}[OK] Domain set to: ${DOMAIN}${NC}"
        break
    else
        echo -e "${RED}[INVALID] '${DOMAIN_INPUT}' is not a valid domain or subdomain. Please try again.${NC}"
        DOMAIN_INPUT=""
    fi
done

# Detect timezone or default to Asia/Kolkata
TIMEZONE=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
if [[ -z "${TIMEZONE}" || "${TIMEZONE}" == "n/a" ]]; then
    TIMEZONE="Asia/Kolkata"
fi
echo -e "${CYAN}[INFO] Using Timezone: ${TIMEZONE}${NC}"

# --- 3. Create 2 GB Swap File & Tune Kernel for 1 GB VPS ---
echo -e "\n${YELLOW}[1/6] Configuring 2 GB Swap Space & Kernel Parameters...${NC}"
if swapon --show | grep -q '/swapfile'; then
    echo -e "${GREEN}[OK] /swapfile is already active.${NC}"
else
    if [[ -f /swapfile ]]; then
        swapoff /swapfile 2>/dev/null || true
        rm -f /swapfile
    fi
    fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    echo -e "${GREEN}[OK] 2 GB Swap created and enabled persistently.${NC}"
fi

# Apply low-RAM kernel optimizations
cat >/etc/sysctl.d/99-n8n-swap.conf <<EOF
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF
sysctl --system >/dev/null

# --- 4. System Update & Docker Installation ---
echo -e "\n${YELLOW}[2/6] Updating Ubuntu packages and installing Docker...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release ufw

if ! command -v docker &>/dev/null; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list >/dev/null

    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    echo -e "${GREEN}[OK] Docker & Docker Compose installed successfully.${NC}"
else
    echo -e "${GREEN}[OK] Docker is already installed.${NC}"
    systemctl enable --now docker
fi

# --- 5. Configure Firewall (UFW) ---
echo -e "\n${YELLOW}[3/6] Configuring Firewall ports (22, 80, 443)...${NC}"
ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1
ufw allow 80/tcp >/dev/null 2>&1
ufw allow 443/tcp >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1 || true
echo -e "${GREEN}[OK] Firewall configured.${NC}"

# --- 6. Set Up n8n & Caddy Reverse Proxy ---
echo -e "\n${YELLOW}[4/6] Setting up n8n and Caddy in /opt/n8n...${NC}"
INSTALL_DIR="/opt/n8n"
mkdir -p "${INSTALL_DIR}"

# Create Docker volume for n8n data with proper permissions (node user UID 1000)
docker volume create n8n_data >/dev/null
docker volume create caddy_data >/dev/null
docker volume create caddy_config >/dev/null

cat >"${INSTALL_DIR}/.env" <<EOF
DOMAIN_NAME=${DOMAIN}
GENERIC_TIMEZONE=${TIMEZONE}
TZ=${TIMEZONE}
EOF

cat >"${INSTALL_DIR}/Caddyfile" <<EOF
${DOMAIN} {
    reverse_proxy n8n:5678 {
        flush_interval -1
    }
}
EOF

cat >"${INSTALL_DIR}/docker-compose.yml" <<'EOF'
services:
  caddy:
    image: caddy:2-alpine
    container_name: n8n_caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - n8n

  n8n:
    image: docker.n8n.io/n8nio/n8n:latest
    container_name: n8n_app
    restart: unless-stopped
    environment:
      - N8N_HOST=${DOMAIN_NAME}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - WEBHOOK_URL=https://${DOMAIN_NAME}/
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
      - TZ=${TZ}
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - N8N_RUNNERS_ENABLED=true
      # Memory & database pruning optimizations for 1 GB RAM VPS
      - NODE_OPTIONS=--max-old-space-size=768
      - EXECUTIONS_DATA_PRUNE=true
      - EXECUTIONS_DATA_MAX_AGE=168
      - EXECUTIONS_DATA_PRUNE_MAX_COUNT=5000
    volumes:
      - n8n_data:/home/node/.n8n

volumes:
  n8n_data:
    external: true
  caddy_data:
    external: true
  caddy_config:
    external: true
EOF

# --- 7. Create Update Script & 15-Day Automated Timer ---
echo -e "\n${YELLOW}[5/6] Configuring Manual Update Utility & 15-Day Auto-Update Timer...${NC}"

cat >/usr/local/bin/n8n-update <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/n8n"
LOG_FILE="/var/log/n8n-update.log"

echo "[$(date --iso-8601=seconds)] Checking for n8n updates..." | tee -a "${LOG_FILE}"
cd "${INSTALL_DIR}"

BEFORE_ID=$(docker images -q docker.n8n.io/n8nio/n8n:latest 2>/dev/null || true)
docker compose pull n8n caddy | tee -a "${LOG_FILE}"
AFTER_ID=$(docker images -q docker.n8n.io/n8nio/n8n:latest 2>/dev/null || true)

if [[ "${BEFORE_ID}" != "${AFTER_ID}" || -z "${BEFORE_ID}" ]]; then
    echo "[$(date --iso-8601=seconds)] New version detected! Updating containers..." | tee -a "${LOG_FILE}"
    docker compose up -d --remove-orphans | tee -a "${LOG_FILE}"
    docker image prune -f | tee -a "${LOG_FILE}"
    echo "[$(date --iso-8601=seconds)] Update completed successfully." | tee -a "${LOG_FILE}"
else
    echo "[$(date --iso-8601=seconds)] n8n is already on the latest version." | tee -a "${LOG_FILE}"
fi
EOF

chmod +x /usr/local/bin/n8n-update

cat >/etc/systemd/system/n8n-auto-update.service <<'EOF'
[Unit]
Description=n8n Automated Update Check Service
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/n8n-update
EOF

cat >/etc/systemd/system/n8n-auto-update.timer <<'EOF'
[Unit]
Description=Run n8n Auto-Update Check Every 15 Days

[Timer]
OnBootSec=15min
OnUnitActiveSec=15d
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now n8n-auto-update.timer

# --- 8. Launch Stack ---
echo -e "\n${YELLOW}[6/6] Pulling images and starting n8n stack...${NC}"
cd "${INSTALL_DIR}"
docker compose pull
docker compose up -d

echo -e "\n${GREEN}======================================================================${NC}"
echo -e "${GREEN}                 n8n Installation Complete!                           ${NC}"
echo -e "${GREEN}======================================================================${NC}"
echo -e "  URL:              https://${DOMAIN}"
echo -e "  Install Path:     /opt/n8n"
echo -e "  Swap Status:      $(swapon --show=NAME,SIZE --noheadings | tr -s ' ')"
echo -e "  Manual Update:    sudo n8n-update"
echo -e "  Auto-Update:      Active (Checks every 15 days via systemd timer)"
echo -e "  Timer Status:     systemctl list-timers n8n-auto-update.timer"
echo -e "  Update Logs:      cat /var/log/n8n-update.log"
echo -e "${GREEN}======================================================================${NC}"
