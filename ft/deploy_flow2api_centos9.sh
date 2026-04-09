#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_SRC="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEFAULT_INSTALL_DIR="/opt/flow2api"
DEFAULT_SERVICE_NAME="flow2api"
DEFAULT_RUN_USER="flow2api"
DEFAULT_HOST="0.0.0.0"
DEFAULT_PORT="8000"
DEFAULT_PYTHON_BIN="python3.11"

INSTALL_DIR="$DEFAULT_INSTALL_DIR"
SERVICE_NAME="$DEFAULT_SERVICE_NAME"
RUN_USER="$DEFAULT_RUN_USER"
HOST="$DEFAULT_HOST"
PORT="$DEFAULT_PORT"
EFFECTIVE_HOST="$HOST"
EFFECTIVE_PORT="$PORT"
ADMIN_USER="admin"
ADMIN_PASS=""
API_KEY=""
CACHE_BASE_URL=""
OPEN_FIREWALL=0
PYTHON_BIN="$DEFAULT_PYTHON_BIN"
WITH_PLAYWRIGHT_BROWSER=0

usage() {
  cat <<EOF
Usage:
  sudo bash $SCRIPT_NAME [options]

Options:
  --install-dir <dir>         Install directory, default: $DEFAULT_INSTALL_DIR
  --service-name <name>       systemd service name, default: $DEFAULT_SERVICE_NAME
  --run-user <user>           Service user, default: $DEFAULT_RUN_USER
  --host <host>               Bind host written into setting.toml, default: $DEFAULT_HOST
  --port <port>               Bind port written into setting.toml, default: $DEFAULT_PORT
  --admin-user <name>         Initial admin username, default: admin
  --admin-pass <password>     Initial admin password, random if omitted on first install
  --api-key <key>             Initial API key, random if omitted on first install
  --cache-base-url <url>      Initial cache.base_url, optional
  --python-bin <bin>          Python executable, default: $DEFAULT_PYTHON_BIN
  --open-firewall             If firewalld is active, open the service port automatically
  --with-playwright-browser   Also run playwright install chromium
  --help                      Show this help

Examples:
  sudo bash $SCRIPT_NAME --port 38000 --open-firewall
  sudo bash $SCRIPT_NAME --install-dir /srv/flow2api --port 8000 --admin-pass 'StrongPass123'
  sudo bash $SCRIPT_NAME --port 8000 --cache-base-url 'https://flow.example.com'
EOF
}

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

log() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "Please run as root, for example: sudo bash $SCRIPT_NAME --port 8000"
  fi
}

check_os() {
  if [[ ! -f /etc/os-release ]]; then
    fail "Cannot detect OS. /etc/os-release is missing."
  fi

  # shellcheck disable=SC1091
  . /etc/os-release
  local major="${VERSION_ID%%.*}"

  case "${ID:-}" in
    centos|rhel|rocky|almalinux|ol)
      ;;
    *)
      fail "This script supports CentOS/RHEL-family systems. Detected: ${ID:-unknown}"
      ;;
  esac

  [[ "$major" == "9" ]] || fail "This script targets EL9/CentOS 9. Detected VERSION_ID=${VERSION_ID:-unknown}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-dir)
        [[ $# -ge 2 ]] || fail "--install-dir requires a value"
        INSTALL_DIR="$2"
        shift 2
        ;;
      --service-name)
        [[ $# -ge 2 ]] || fail "--service-name requires a value"
        SERVICE_NAME="$2"
        shift 2
        ;;
      --run-user)
        [[ $# -ge 2 ]] || fail "--run-user requires a value"
        RUN_USER="$2"
        shift 2
        ;;
      --host)
        [[ $# -ge 2 ]] || fail "--host requires a value"
        HOST="$2"
        shift 2
        ;;
      --port)
        [[ $# -ge 2 ]] || fail "--port requires a value"
        PORT="$2"
        shift 2
        ;;
      --admin-user)
        [[ $# -ge 2 ]] || fail "--admin-user requires a value"
        ADMIN_USER="$2"
        shift 2
        ;;
      --admin-pass)
        [[ $# -ge 2 ]] || fail "--admin-pass requires a value"
        ADMIN_PASS="$2"
        shift 2
        ;;
      --api-key)
        [[ $# -ge 2 ]] || fail "--api-key requires a value"
        API_KEY="$2"
        shift 2
        ;;
      --cache-base-url)
        [[ $# -ge 2 ]] || fail "--cache-base-url requires a value"
        CACHE_BASE_URL="$2"
        shift 2
        ;;
      --python-bin)
        [[ $# -ge 2 ]] || fail "--python-bin requires a value"
        PYTHON_BIN="$2"
        shift 2
        ;;
      --open-firewall)
        OPEN_FIREWALL=1
        shift
        ;;
      --with-playwright-browser)
        WITH_PLAYWRIGHT_BROWSER=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        fail "Unknown option: $1"
        ;;
    esac
  done
}

validate_args() {
  [[ "$PORT" =~ ^[0-9]+$ ]] || fail "--port must be a number"
  (( PORT >= 1 && PORT <= 65535 )) || fail "--port must be between 1 and 65535"
  [[ "$SERVICE_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || fail "--service-name only supports letters, numbers, dot, underscore and dash"
  [[ "$RUN_USER" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]] || fail "--run-user format is invalid"
  [[ "$ADMIN_USER" =~ ^[^[:space:]]+$ ]] || fail "--admin-user must not contain whitespace"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

random_secret() {
  local length="${1:-32}"
  if command_exists openssl; then
    openssl rand -hex "$length" | cut -c1-"$length"
    return 0
  fi

  tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$length"
}

install_packages() {
  local python_bin_name=""
  local python_version=""
  local python_packages=()

  python_bin_name="$(basename "$PYTHON_BIN")"
  if [[ "$python_bin_name" =~ python([0-9]+\.[0-9]+)$ ]]; then
    python_version="${BASH_REMATCH[1]}"
    python_packages=("python${python_version}" "python${python_version}-pip" "python${python_version}-devel")
  else
    warn "Cannot infer EL9 package names from --python-bin=${PYTHON_BIN}, falling back to Python 3.11 packages."
    python_packages=("python3.11" "python3.11-pip" "python3.11-devel")
  fi

  log "Installing system packages..."
  dnf install -y \
    git \
    openssl \
    rsync \
    gcc \
    gcc-c++ \
    make \
    libffi-devel \
    openssl-devel \
    sqlite \
    ca-certificates \
    findutils \
    "${python_packages[@]}"
}

ensure_python() {
  command_exists "$PYTHON_BIN" || fail "Python executable not found: $PYTHON_BIN"
  "$PYTHON_BIN" --version
  "$PYTHON_BIN" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' \
    || fail "Flow2API requires Python 3.11 or newer. Current interpreter is too old: $PYTHON_BIN"
}

ensure_service_user() {
  if ! id "$RUN_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "/home/${RUN_USER}" --shell /sbin/nologin "$RUN_USER"
  fi
}

stop_existing_service_if_any() {
  if systemctl list-unit-files | grep -q "^${SERVICE_NAME}\.service"; then
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      log "Stopping existing service ${SERVICE_NAME} before syncing files..."
      systemctl stop "$SERVICE_NAME"
    fi
  fi
}

sync_repo() {
  local target_real=""
  mkdir -p "$INSTALL_DIR"
  target_real="$(cd "$INSTALL_DIR" && pwd)"

  if [[ "$target_real" == "$REPO_SRC" ]]; then
    log "Install directory is the current repository, skipping file sync."
    return 0
  fi

  log "Syncing repository into ${INSTALL_DIR}..."
  rsync -a \
    --exclude '.git' \
    --exclude '.github' \
    --exclude '.venv' \
    --exclude '__pycache__' \
    --exclude '.pytest_cache' \
    --exclude 'node_modules' \
    --exclude 'ft/node_modules' \
    --exclude 'data' \
    --exclude 'tmp' \
    --exclude 'config/setting.toml' \
    --exclude 'logs.txt' \
    --exclude 'flow2api.out' \
    --exclude 'one-api.db' \
    "${REPO_SRC}/" "${INSTALL_DIR}/"
}

prepare_runtime_dirs() {
  install -d -m 755 "${INSTALL_DIR}/data"
  install -d -m 755 "${INSTALL_DIR}/tmp"
  install -d -m 755 "${INSTALL_DIR}/config"
  chown -R "${RUN_USER}:${RUN_USER}" "${INSTALL_DIR}"
}

create_or_update_venv() {
  log "Creating virtual environment with ${PYTHON_BIN}..."
  "$PYTHON_BIN" -m venv --clear "${INSTALL_DIR}/.venv"

  log "Installing Python dependencies..."
  "${INSTALL_DIR}/.venv/bin/pip" install --upgrade pip setuptools wheel
  "${INSTALL_DIR}/.venv/bin/pip" install -r "${INSTALL_DIR}/requirements.txt"

  if [[ "$WITH_PLAYWRIGHT_BROWSER" -eq 1 ]]; then
    log "Installing Playwright Chromium..."
    "${INSTALL_DIR}/.venv/bin/playwright" install chromium
  fi

  chown -R "${RUN_USER}:${RUN_USER}" "${INSTALL_DIR}/.venv"
}

update_setting_file() {
  local config_file="$1"
  local api_key="$2"
  local admin_user="$3"
  local admin_pass="$4"
  local host="$5"
  local port="$6"
  local cache_base_url="$7"

  "$PYTHON_BIN" - "$config_file" "$api_key" "$admin_user" "$admin_pass" "$host" "$port" "$cache_base_url" <<'PY'
from pathlib import Path
import re
import sys

config_file = Path(sys.argv[1])
api_key, admin_user, admin_pass, host, port, cache_base_url = sys.argv[2:8]

def toml_string(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')

text = config_file.read_text(encoding="utf-8")

patterns = [
    (r'(?m)^api_key = ".*"$', f'api_key = "{toml_string(api_key)}"'),
    (r'(?m)^admin_username = ".*"$', f'admin_username = "{toml_string(admin_user)}"'),
    (r'(?m)^admin_password = ".*"$', f'admin_password = "{toml_string(admin_pass)}"'),
    (r'(?m)^host = ".*"$', f'host = "{toml_string(host)}"'),
    (r'(?m)^port = .*$', f'port = {port}'),
]

if cache_base_url:
    patterns.append((r'(?m)^base_url = ".*"$', f'base_url = "{toml_string(cache_base_url)}"'))

for pattern, replacement in patterns:
    text, count = re.subn(pattern, replacement, text, count=1)
    if count != 1:
        raise SystemExit(f"Failed to update config pattern: {pattern}")

config_file.write_text(text, encoding="utf-8")
PY
}

read_effective_server_config() {
  local config_file="$1"
  local host_value=""
  local port_value=""

  host_value="$(awk -F'"' '/^host = / {print $2}' "$config_file" | head -n 1)"
  port_value="$(awk -F'= ' '/^port = / {print $2}' "$config_file" | tr -d ' ' | head -n 1)"

  if [[ -n "$host_value" ]]; then
    EFFECTIVE_HOST="$host_value"
  fi
  if [[ -n "$port_value" ]]; then
    EFFECTIVE_PORT="$port_value"
  fi
}

write_setting_toml() {
  local config_file="${INSTALL_DIR}/config/setting.toml"
  local example_file="${INSTALL_DIR}/config/setting_example.toml"
  local generated_admin_pass="${ADMIN_PASS}"
  local generated_api_key="${API_KEY}"
  local created_new=0

  if [[ ! -f "$config_file" ]]; then
    [[ -f "$example_file" ]] || fail "Missing config template: ${example_file}"
    cp "$example_file" "$config_file"
    created_new=1

    if [[ -z "$generated_admin_pass" ]]; then
      generated_admin_pass="$(random_secret 20)"
    fi
    if [[ -z "$generated_api_key" ]]; then
      generated_api_key="$(random_secret 32)"
    fi

    update_setting_file \
      "$config_file" \
      "$generated_api_key" \
      "$ADMIN_USER" \
      "$generated_admin_pass" \
      "$HOST" \
      "$PORT" \
      "$CACHE_BASE_URL"

    read_effective_server_config "$config_file"

    chown "${RUN_USER}:${RUN_USER}" "$config_file"

    cat <<EOF

[INFO] First install detected. Generated initial credentials:
  Admin URL: http://SERVER_IP:${EFFECTIVE_PORT}
  Admin User: ${ADMIN_USER}
  Admin Password: ${generated_admin_pass}
  API Key: ${generated_api_key}

Please save them now. Future runs of this script will not overwrite setting.toml.
EOF
  else
    log "Existing config found, keeping ${config_file} unchanged."
    read_effective_server_config "$config_file"
    if [[ "$PORT" != "$EFFECTIVE_PORT" ]]; then
      warn "Requested --port ${PORT}, but existing setting.toml still uses port ${EFFECTIVE_PORT}."
    fi
    if [[ -n "$CACHE_BASE_URL" ]]; then
      warn "cache.base_url was not updated because setting.toml already exists. Change it in the admin page or edit the file manually if needed."
    fi
  fi

  if [[ "$created_new" -eq 1 ]]; then
    log "Initial configuration written to ${config_file}"
  fi
}

write_systemd_service() {
  local unit_file="/etc/systemd/system/${SERVICE_NAME}.service"

  cat >"$unit_file" <<EOF
[Unit]
Description=Flow2API service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_USER}
WorkingDirectory=${INSTALL_DIR}
Environment=PYTHONUNBUFFERED=1
ExecStart=${INSTALL_DIR}/.venv/bin/python main.py
Restart=always
RestartSec=5
TimeoutStopSec=30
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
}

open_firewalld_port_if_requested() {
  if [[ "$OPEN_FIREWALL" -ne 1 ]]; then
    return 0
  fi

  if ! command_exists firewall-cmd; then
    warn "firewall-cmd not found; skipped firewall opening"
    return 0
  fi

  if ! systemctl is-active --quiet firewalld; then
    warn "firewalld is not active; skipped firewall opening"
    return 0
  fi

  firewall-cmd --permanent --add-port="${EFFECTIVE_PORT}/tcp" >/dev/null
  firewall-cmd --reload >/dev/null
  log "Opened firewalld port ${EFFECTIVE_PORT}/tcp"
}

show_summary() {
  local server_ip=""
  server_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -z "$server_ip" ]]; then
    server_ip="<SERVER_IP>"
  fi

  cat <<EOF

[INFO] Deployment completed.

Service:
  systemctl status ${SERVICE_NAME} --no-pager
  journalctl -u ${SERVICE_NAME} -f

Project:
  Install dir: ${INSTALL_DIR}
  Config: ${INSTALL_DIR}/config/setting.toml
  Database: ${INSTALL_DIR}/data/flow.db
  Temp dir: ${INSTALL_DIR}/tmp

Access:
  http://${server_ip}:${EFFECTIVE_PORT}

Common commands:
  systemctl restart ${SERVICE_NAME}
  systemctl stop ${SERVICE_NAME}
  systemctl start ${SERVICE_NAME}
EOF
}

main() {
  require_root
  check_os
  parse_args "$@"
  validate_args
  install_packages
  ensure_python
  ensure_service_user
  stop_existing_service_if_any
  sync_repo
  prepare_runtime_dirs
  create_or_update_venv
  write_setting_toml
  write_systemd_service
  open_firewalld_port_if_requested
  show_summary
}

main "$@"
