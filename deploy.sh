#!/usr/bin/env bash
# deploy.sh - Automated Dockerized App deployer (for remote Linux hosts)
# Usage: ./deploy.sh
# Optional: ./deploy.sh --cleanup (to attempt cleanup on remote host)
# NOTE: This script uses bash features. Keep PAT and sensitive data secure.

set -Eeuo pipefail
IFS=$'\n\t'

# -----------------------
# Config / Globals
# -----------------------
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOGFILE="./deploy_${TIMESTAMP}.log"
EXIT_CODE=0

# colors for terminal
_red() { printf "\033[0;31m%s\033[0m\n" "$*"; }
_green() { printf "\033[0;32m%s\033[0m\n" "$*"; }
_yellow() { printf "\033[0;33m%s\033[0m\n" "$*"; }

# Logging
log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOGFILE}"
}

die() {
  local code="${1:-1}"; shift || true
  log "ERROR: $*"
  _red "ERROR: $*"
  EXIT_CODE=$code
  exit "${code}"
}

trap 'last_status=$?; if [ $last_status -ne 0 ]; then log "Script failed with exit code $last_status"; fi' EXIT

# -----------------------
# Helper functions
# -----------------------
prompt() {
  local varname="$1"; local prompt_msg="$2"; local default="${3:-}"
  local answer
  if [ -n "${default}" ]; then
    printf "%s [%s]: " "${prompt_msg}" "${default}"
  else
    printf "%s: " "${prompt_msg}"
  fi
  if ! read -r answer; then die 2 "Failed to read input"; fi
  answer="${answer:-$default}"
  eval "$varname=\"\$answer\""
}

validate_nonempty() {
  local val="$1"; local name="$2"
  if [ -z "${val:-}" ]; then die 3 "Missing required value for ${name}"; fi
}

# Run remote commands via SSH
remote_exec() {
  local user="$1"; local host="$2"; local key="$3"; shift 3
  local cmd="$*"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no -i "${key}" "${user}@${host}" "${cmd}"
}

# Check SSH connectivity
ssh_check() {
  local user="$1"; local host="$2"; local key="$3"
  log "Checking SSH connectivity to ${user}@${host} ..."
  if ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -i "${key}" "${user}@${host}" 'echo SSH_OK' 2>/dev/null | grep -q SSH_OK; then
    log "SSH connectivity OK"
  else
    die 4 "Unable to SSH to ${user}@${host}. Check IP, key path and network."
  fi
}

# Simple remote apt-get install helper for Debian/Ubuntu
remote_apt_install() {
  local user="$1"; local host="$2"; local key="$3"; shift 3
  local pkgs="$*"
  remote_exec "${user}" "${host}" "${key}" "sudo DEBIAN_FRONTEND=noninteractive apt-get update -y && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ${pkgs}"
}

# -----------------------
# Parse arguments
# -----------------------
CLEANUP_MODE=0
if [ "${1:-}" = "--cleanup" ]; then CLEANUP_MODE=1; fi

# -----------------------
# 1. Collect user inputs
# -----------------------
log "Starting deployment script..."
echo "You will be prompted for inputs. Sensitive inputs (PAT) will be used but not stored by this script."
prompt GIT_URL "Git repository URL (HTTPS, e.g. https://github.com/user/repo.git)"
prompt PAT "Personal Access Token (PAT) - will be used to authenticate git clone (input hidden)"; true
# hide PAT echo
if [ -t 0 ]; then
  stty -echo
  printf ""
  stty echo
fi
# This above is a placeholder - the prompt read will show PAT; in some terminals use read -s for hidden
# One can use this one line approach to hide PAT echo also 'read -s -p "Enter your Personal Access Token (PAT): " PAT'
#                                                           echo

printf "Enter PAT (input will be hidden): "
read -rs PAT
echo

prompt BRANCH "Branch name (default: main)" "main"
prompt REMOTE_USER "Remote SSH username (e.g. ubuntu)" "ubuntu"
prompt REMOTE_HOST "Remote server IP address or domain"
prompt SSH_KEY "SSH private key path (absolute or relative, e.g. ~/.ssh/id_rsa)"
prompt APP_PORT "Application internal container port (e.g. 3000)" "3000"

validate_nonempty "${GIT_URL}" "Git repository URL"
validate_nonempty "${PAT}" "Personal Access Token"
validate_nonempty "${REMOTE_HOST}" "Remote host"
validate_nonempty "${SSH_KEY}" "SSH key"
validate_nonempty "${APP_PORT}" "Application port"

# Extract repo name
REPO_NAME="$(basename -s .git "${GIT_URL}")"
LOCAL_REPO_DIR="./${REPO_NAME}"

log "Inputs collected. Repo: ${REPO_NAME}, Branch: ${BRANCH}, Remote: ${REMOTE_USER}@${REMOTE_HOST}, App port: ${APP_PORT}"
log "Log file: ${LOGFILE}"

# -----------------------
# CLEANUP MODE
# -----------------------
if [ "${CLEANUP_MODE}" -eq 1 ]; then
  log "CLEANUP MODE: Attempting to remove deployed resources on remote host..."
  ssh_check "${REMOTE_USER}" "${REMOTE_HOST}" "${SSH_KEY}"
  CLEAN_CMD=$(cat <<EOF

sudo systemctl stop nginx || true
sudo docker ps -q | xargs -r sudo docker stop || true
sudo docker ps -aq | xargs -r sudo docker rm -f || true
sudo docker images -q | xargs -r sudo docker rmi -f || true
sudo rm -rf /opt/${REPO_NAME} || true
sudo rm -f /etc/nginx/sites-enabled/${REPO_NAME} /etc/nginx/sites-available/${REPO_NAME} || true
sudo nginx -t && sudo systemctl reload nginx || true
EOF
)
  remote_exec "${REMOTE_USER}" "${REMOTE_HOST}" "${SSH_KEY}" "${CLEAN_CMD}" && log "Cleanup completed" || die 5 "Cleanup failed"
  exit 0
fi

# -----------------------
# 2. Clone or update local repo
# -----------------------
log "Cloning or updating repository locally..."
# Use PAT in HTTPS clone - caution: PAT may appear in process lists; recommend using git credential helpers in production
AUTH_GIT_URL="$(echo "${GIT_URL}" | sed -E "s#https://#https://${PAT}@#")"

if [ -d "${LOCAL_REPO_DIR}/.git" ]; then
  log "Repository already cloned locally. Pulling latest changes..."
  (cd "${LOCAL_REPO_DIR}" && git fetch --all --prune && git checkout "${BRANCH}" && git pull origin "${BRANCH}") || die 6 "Git pull failed"
else
  log "Cloning repo: ${GIT_URL}"
  git clone --branch "${BRANCH}" "${AUTH_GIT_URL}" "${LOCAL_REPO_DIR}" || die 7 "Git clone failed"
fi

# -----------------------
# 3. Navigate into the Cloned Directory
# -----------------------
log "Validating repo for Dockerfile or docker-compose.yml..."
if [ -f "${LOCAL_REPO_DIR}/Dockerfile" ]; then
  HAS_DOCKERFILE=1
  log "Found Dockerfile"
elif [ -f "${LOCAL_REPO_DIR}/docker-compose.yml" ] || [ -f "${LOCAL_REPO_DIR}/docker-compose.yaml" ]; then
  HAS_COMPOSE=1
  log "Found docker-compose file"
else
  die 8 "Neither Dockerfile nor docker-compose.yml found in repository root."
fi

# -----------------------
# 4. SSH into the Remote Server
# -----------------------
ssh_check "${REMOTE_USER}" "${REMOTE_HOST}" "${SSH_KEY}"

# -----------------------
# 5. Prepare remote environment
# -----------------------
log "Preparing remote environment (update, install Docker, docker-compose plugin, nginx)..."

REMOTE_PREP_CMDS=$(cat <<'EOF'
set -e
# Detect package manager and install (assume Debian/Ubuntu)
if [ -x "$(command -v apt-get)" ]; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg lsb-release software-properties-common
  # Install Docker (official)
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io
  fi
  # Docker Compose plugin
  if ! docker compose version >/dev/null 2>&1; then
    sudo apt-get install -y docker-compose-plugin
  fi
  # Nginx
  if ! command -v nginx >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nginx
  fi
else
  echo "Non-debian OS detected. Please install Docker, Docker Compose and Nginx manually or extend script."
  exit 1
fi
# Add user to docker group
sudo usermod -aG docker "$USER" || true
# Enable services
sudo systemctl enable --now docker
sudo systemctl enable --now nginx
# Print versions
docker --version || true
docker compose version || true
nginx -v || true
EOF
)

remote_exec "${REMOTE_USER}" "${REMOTE_HOST}" "${SSH_KEY}" "${REMOTE_PREP_CMDS}" || die 9 "Remote environment preparation failed"

log "Remote environment ready."

# -----------------------
# 6a. Transfer files to remote host
# -----------------------
REMOTE_BASE_DIR="/opt/${REPO_NAME}"
log "Transferring project files to remote: ${REMOTE_BASE_DIR}"
# Use rsync if available
if command -v rsync >/dev/null 2>&1; then
  rsync -az --delete -e "ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no" "${LOCAL_REPO_DIR}/" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_BASE_DIR}/" || die 10 "Rsync transfer failed"
else
  # fallback to scp (less efficient)
  scp -r -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${LOCAL_REPO_DIR}" "${REMOTE_USER}@${REMOTE_HOST}:/tmp/" || die 10 "SCP failed"
  remote_exec "${REMOTE_USER}" "${REMOTE_HOST}" "${SSH_KEY}" "sudo mv /tmp/${REPO_NAME} ${REMOTE_BASE_DIR} && sudo chown -R ${REMOTE_USER}:${REMOTE_USER} ${REMOTE_BASE_DIR}" || die 10 "Remote move failed"
fi
log "Project files transferred."

# -----------------------
# 6b. Build and run containers remotely
# -----------------------
log "Building and starting application containers on remote host..."

if [ -f "${LOCAL_REPO_DIR}/docker-compose.yml" ] || [ -f "${LOCAL_REPO_DIR}/docker-compose.yaml" ]; then
  # Use docker-compose
  REMOTE_DEPLOY_COMPOSE=$(cat <<EOF
set -e
cd "${REMOTE_BASE_DIR}"
# Ensure old stack removed
if docker compose ps >/dev/null 2>&1; then
  docker compose down --remove-orphans || true
fi
docker compose pull || true
docker compose up -d --build
# Wait a bit for containers to become healthy
sleep 3
docker compose ps
EOF
)
  remote_exec "${REMOTE_USER}" "${REMOTE_HOST}" "${SSH_KEY}" "${REMOTE_DEPLOY_COMPOSE}" || die 11 "docker-compose deployment failed"
else
  # Single Dockerfile flow
  REMOTE_DEPLOY_DOCKERFILE=$(cat <<EOF
set -e
cd "${REMOTE_BASE_DIR}"
# Gracefully stop existing container(s) with same name
APP_NAME="${REPO_NAME}_app"
if docker ps --format '{{.Names}}' | grep -q "${APP_NAME}" ; then
  docker stop "${APP_NAME}" || true
  docker rm "${APP_NAME}" || true
fi
# Build image
docker build -t "${APP_NAME}:latest" .
# Remove existing container and run new one mapping port
docker run -d --rm --name "${APP_NAME}" -p "127.0.0.1:${APP_PORT}:${APP_PORT}" "${APP_NAME}:latest"
sleep 3
docker ps --filter name="${APP_NAME}"
EOF
)
  remote_exec "${REMOTE_USER}" "${REMOTE_HOST}" "${SSH_KEY}" "${REMOTE_DEPLOY_DOCKERFILE}" || die 11 "Dockerfile build/run failed"
fi

log "Containers built and started."

# -----------------------
# 7. Configure Nginx as a reverse proxy
# -----------------------
log "Configuring Nginx as reverse proxy..."
NGINX_CONF_PATH="/etc/nginx/sites-available/${REPO_NAME}"
NGINX_CONF_SYM="/etc/nginx/sites-enabled/${REPO_NAME}"
REMOTE_NGINX_CONF=$(cat <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    access_log /var/log/nginx/${REPO_NAME}.access.log;
    error_log /var/log/nginx/${REPO_NAME}.error.log;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF
)

# Write config remotely and enable
remote_exec "${REMOTE_USER}" "${REMOTE_HOST}" "${SSH_KEY}" "echo '${REMOTE_NGINX_CONF}' | sudo tee ${NGINX_CONF_PATH} > /dev/null" || die 12 "Failed to write nginx config"
remote_exec "${REMOTE_USER}" "${REMOTE_HOST}" "${SSH_KEY}" "sudo ln -sf ${NGINX_CONF_PATH} ${NGINX_CONF_SYM} || true; sudo nginx -t" || die 12 "Nginx config test failed"
remote_exec "${REMOTE_USER}" "${REMOTE_HOST}" "${SSH_KEY}" "sudo systemctl reload nginx" || die 12 "Failed to reload nginx"

log "Nginx configured and reloaded."

# -----------------------
# 8. Validate Deployments
# -----------------------
log "Validating deployment..."

VALIDATE_CMD=$(cat <<EOF
set -e
# Docker service
if ! systemctl is-active --quiet docker; then echo "docker_down"; exit 6; fi
# Check container(s)
if docker ps --format '{{.Names}}' | grep -q '${REPO_NAME}'; then
  echo "container_ok"
fi
# Nginx test
sudo nginx -t >/dev/null 2>&1
if [ \$? -ne 0 ]; then echo "nginx_test_fail"; exit 7; fi
# Test endpoint locally
if command -v curl >/dev/null 2>&1; then
  curl -fsS "http://127.0.0.1:${APP_PORT}/" >/dev/null 2>&1 && echo "local_http_ok" || echo "local_http_fail"
fi
EOF
)

remote_exec "${REMOTE_USER}" "${REMOTE_HOST}" "${SSH_KEY}" "${VALIDATE_CMD}" | tee -a "${LOGFILE}" || log "Validation commands returned non-zero; check logs"

# Test remote accessibility from local machine (port 80)
PUBLIC_URL="http://${REMOTE_HOST}/"
log "Testing remote URL: ${PUBLIC_URL}"
if curl -fsS --max-time 10 "${PUBLIC_URL}" >/dev/null 2>&1; then
  log "Remote HTTP test OK: ${PUBLIC_URL}"
else
  log "Warning: Remote HTTP test failed from this network. The server may be blocked by firewall or ISP. Check remote firewall (ufw/security group) to ensure port 80 is open."
fi

# -----------------------
# Success summary
# -----------------------
log "Deployment finished. Summary:"
_green "Repository: ${GIT_URL} (branch ${BRANCH})"
_green "Remote host: ${REMOTE_USER}@${REMOTE_HOST}"
_green "App port (container): ${APP_PORT}"
_green "Nginx proxy: http://${REMOTE_HOST}/ -> 127.0.0.1:${APP_PORT}"
log "Log saved to ${LOGFILE}"

# Exit cleanly
exit 0
