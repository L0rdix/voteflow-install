#!/usr/bin/env bash
set -euo pipefail

# VoteFlow — Proxmox LXC Installer
#
# Run on your Proxmox host as root (paste into the shell):
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/YOUR_ORG/YOUR_REPO/main/install.sh)"
#
# What this does:
#   1. Prompts for Gmail credentials
#   2. Creates a privileged Ubuntu 22.04 LXC container with Docker inside
#   3. Pulls the pre-built VoteFlow image from the container registry
#   4. Writes /opt/voteflow/.env and starts the container (restarts on boot)

# ── Docker image ──────────────────────────────────────────────────────────────
# Override with VOTEFLOW_IMAGE env var before running if you use a fork/mirror.
DOCKER_IMAGE="${VOTEFLOW_IMAGE:-amirrrr/voteflow:latest}"

# ── Colours (community-scripts palette) ───────────────────────────────────────
YW='\033[33m'
BL='\033[36m'
RD='\033[01;31m'
GN='\033[1;92m'
CL='\033[m'
CM=" ${GN}✔${CL}"
CROSS=" ${RD}✘${CL}"
INFO=" ${YW}➜${CL}"

header_info() {
  clear
  echo -e "${BL}"
  cat <<'BANNER'
  __   __    _       _____ _
  \ \ / /__ | |_ ___|  ___| | _____      __
   \ V / _ \| __/ _ \ |_  | |/ _ \ \ /\ / /
    | | (_) | ||  __/  _| | | (_) \ V  V /
    |_|\___/ \__\___|_|   |_|\___/ \_/\_/

  Proxmox LXC Installer
BANNER
  echo -e "${CL}"
}

msg_info()  { echo -e "${INFO} ${YW}${*}${CL}"; }
msg_ok()    { echo -e "${CM} ${GN}${*}${CL}"; }
msg_error() { echo -e "${CROSS} ${RD}${*}${CL}" >&2; }
die()       { msg_error "${*}"; exit 1; }

# ── Sanity checks ─────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]]             && die "Run as root on the Proxmox host."
command -v pct   &>/dev/null  || die "pct not found — is this a Proxmox VE host?"
command -v pveam &>/dev/null  || die "pveam not found — is this a Proxmox VE host?"
command -v openssl &>/dev/null || die "openssl not found."

header_info

# ── Gmail credentials ─────────────────────────────────────────────────────────
echo -e " ${BL}Gmail credentials (used for email notifications):${CL}"
echo -e " ${YW}Tip: use a Gmail App Password, not your regular password.${CL}"
echo -e " ${YW}      https://myaccount.google.com/apppasswords${CL}"
echo
read -rp "  Gmail address        : " MAIL_USER
[[ -z "$MAIL_USER" ]] && die "Gmail address cannot be empty."
read -rsp "  Gmail app password   : " MAIL_PASS
echo
[[ -z "$MAIL_PASS" ]] && die "Gmail app password cannot be empty."
echo

# ── Container settings ────────────────────────────────────────────────────────
NEXT_CTID=$(pvesh get /cluster/nextid 2>/dev/null || echo 100)
DEFAULT_STORAGE=$(pvesm status --content rootdir 2>/dev/null | awk 'NR==2{print $1}')
DEFAULT_STORAGE="${DEFAULT_STORAGE:-local-lvm}"

echo -e " ${BL}Container settings (press Enter to accept defaults):${CL}"
read -rp "  Container ID   [${NEXT_CTID}]       : " CTID
CTID="${CTID:-$NEXT_CTID}"
read -rp "  Hostname       [voteflow]          : " CT_HOST
CT_HOST="${CT_HOST:-voteflow}"
read -rp "  Storage        [${DEFAULT_STORAGE}] : " STORAGE
STORAGE="${STORAGE:-$DEFAULT_STORAGE}"
read -rp "  Memory (MB)    [2048]              : " MEMORY
MEMORY="${MEMORY:-2048}"
read -rp "  CPU cores      [2]                 : " CORES
CORES="${CORES:-2}"
read -rp "  Disk size (GB) [8]                 : " DISK
DISK="${DISK:-8}"
echo

# ── LXC template ─────────────────────────────────────────────────────────────
msg_info "Looking for Ubuntu 22.04 LXC template..."
TEMPLATE_FILE=$(pveam list local 2>/dev/null | awk '/ubuntu-22\.04/{print $1}' | head -n1)

if [[ -z "$TEMPLATE_FILE" ]]; then
  msg_info "Downloading Ubuntu 22.04 template (this may take a moment)..."
  AVAIL=$(pveam available 2>/dev/null | awk '/ubuntu-22\.04-standard/{print $2}' | head -n1)
  [[ -z "$AVAIL" ]] && die "Ubuntu 22.04 template not found via pveam. Check your internet connection."
  pveam download local "$AVAIL"
  TEMPLATE_FILE=$(pveam list local | awk '/ubuntu-22\.04/{print $1}' | head -n1)
fi
msg_ok "Template: $TEMPLATE_FILE"

# ── Destroy existing container (if any) ──────────────────────────────────────
if pct status "$CTID" &>/dev/null; then
  msg_info "Container $CTID already exists — removing for a clean install..."
  pct stop "$CTID" &>/dev/null || true
  pct destroy "$CTID" --force
  msg_ok "Removed existing container $CTID"
fi

# ── Create container ──────────────────────────────────────────────────────────
msg_info "Creating LXC container $CTID..."
pct create "$CTID" "$TEMPLATE_FILE" \
  --hostname "$CT_HOST" \
  --cores   "$CORES" \
  --memory  "$MEMORY" \
  --net0    name=eth0,bridge=vmbr0,ip=dhcp \
  --rootfs  "${STORAGE}:${DISK}" \
  --features nesting=1 \
  --unprivileged 0 \
  --onboot  1
msg_ok "Container $CTID created"

pct start "$CTID"
msg_ok "Container started"

# Give the container a moment to finish booting and get a DHCP lease.
msg_info "Waiting for network inside container..."
sleep 10

# ── Install Docker ────────────────────────────────────────────────────────────
msg_info "Installing Docker (this can take a few minutes)..."
pct exec "$CTID" -- bash -lc "
  export DEBIAN_FRONTEND=noninteractive
  apt-get update  -qq
  apt-get install -y -qq ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable\" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
"
msg_ok "Docker installed and running"

# ── Write .env on host, push into container ───────────────────────────────────
# Writing to a temp file on the host avoids any quoting / injection issues
# with special characters in the password.
msg_info "Writing environment configuration..."
JWT_SECRET=$(openssl rand -hex 32)
TMP_ENV=$(mktemp)
chmod 600 "$TMP_ENV"

cat > "$TMP_ENV" <<EOF
# VoteFlow runtime configuration
# Edit this file at /opt/voteflow/.env inside the container to change settings.

SPRING_MAIL_HOST=smtp.gmail.com
SPRING_MAIL_PORT=587
SPRING_MAIL_USERNAME=${MAIL_USER}
SPRING_MAIL_PASSWORD=${MAIL_PASS}

# H2 file database — data persists in /opt/voteflow/database/
SPRING_DATASOURCE_URL=jdbc:h2:file:./database/db;DB_CLOSE_DELAY=-1
SPRING_DATASOURCE_USERNAME=admin
SPRING_DATASOURCE_PASSWORD=password

# JWT signing secret — auto-generated, do not change after first run
SECURITY_JWT_SECRET=${JWT_SECRET}
EOF

pct exec "$CTID" -- mkdir -p /opt/voteflow
pct push "$CTID" "$TMP_ENV" /opt/voteflow/.env --perms 0600
rm -f "$TMP_ENV"
msg_ok "Environment file written to /opt/voteflow/.env"

# ── Pull image ────────────────────────────────────────────────────────────────
msg_info "Pulling Docker image ${DOCKER_IMAGE}..."
pct exec "$CTID" -- docker pull "${DOCKER_IMAGE}"
msg_ok "Image pulled"

# ── Run VoteFlow ──────────────────────────────────────────────────────────────
msg_info "Starting VoteFlow..."
pct exec "$CTID" -- docker run -d \
  --name voteflow \
  --env-file /opt/voteflow/.env \
  -p 8080:8080 \
  -v /opt/voteflow/database:/app/database \
  -v /opt/voteflow/log:/app/log \
  --restart unless-stopped \
  "${DOCKER_IMAGE}"
msg_ok "VoteFlow container started"

# ── Print summary ─────────────────────────────────────────────────────────────
CT_IP=$(pct exec "$CTID" -- ip -4 addr show eth0 2>/dev/null \
  | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "<container-ip>")

echo
echo -e " ${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo -e " ${GN} VoteFlow is up and running!${CL}"
echo -e " ${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo
echo -e "   URL        : ${BL}http://${CT_IP}:8080${CL}"
echo -e "   CTID       : ${YW}${CTID}${CL}  (Hostname: ${CT_HOST})"
echo -e "   Config     : ${YW}/opt/voteflow/.env${CL}  (inside the container)"
echo
echo -e " ${YW}Set FRONTEND_URL in .env to your public address so email links work:${CL}"
echo -e "   e.g. FRONTEND_URL=http://${CT_IP}:8080"
echo -e "   Logs       : ${YW}docker logs voteflow${CL}  (run inside the container)"
echo
echo -e " ${YW}To open a shell in the container:${CL}"
echo -e "   pct exec ${CTID} -- bash"
echo
echo -e " ${YW}To update VoteFlow to the latest version:${CL}"
echo -e "   pct exec ${CTID} -- bash -c \\"
echo -e "     'docker pull ${DOCKER_IMAGE} && docker rm -f voteflow && docker run -d --name voteflow --env-file /opt/voteflow/.env -p 8080:8080 -v /opt/voteflow/database:/app/database -v /opt/voteflow/log:/app/log --restart unless-stopped ${DOCKER_IMAGE}'"
echo
