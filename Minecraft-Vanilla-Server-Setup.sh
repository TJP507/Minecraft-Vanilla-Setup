#!/usr/bin/env bash
set -euo pipefail

########################################
# Friendly Minecraft Server Setup Script
# For Ubuntu (systemd + apt)
########################################

# Colors
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
BLUE="\e[34m"
BOLD="\e[1m"
RESET="\e[0m"

# Error trap
trap 'echo -e "\n${RED}An error occurred on line ${LINENO}. Exiting.${RESET}" >&2' ERR

# Defaults
DEF_MC_USER="minecraft"
DEF_BASE_DIR="/opt/minecraft"
DEF_SERVER_NAME="server1"
DEF_MIN_RAM="2G"
DEF_MAX_RAM="4G"
DEF_MOTD="My Minecraft Server"
DEF_PORT="25565"

# Minecraft version & jar info (hardcoded here)
MC_VERSION="1.21.1"
MC_JAR_NAME="server-${MC_VERSION}.jar"
MC_JAR_URL="https://piston-data.mojang.com/v1/objects/59353fb40c36d304f2035d51e7d6e6baa98dc05c/server.jar"

# Directory where this script lives (for finding ops.json)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

########################################
# "GUI-ish" step helper
########################################

STEP=1
step() {
  local msg="$1"
  echo -e "\n${BLUE}[STEP ${STEP}]${RESET} ${BOLD}${msg}${RESET}"
  STEP=$((STEP + 1))
}

# Run a command quietly (hide stdout, show stderr on error)
run_quiet() {
  # usage: run_quiet <description> <command> [args...]
  local msg="$1"
  shift
  step "$msg"
  # show a tiny hint while running
  echo -e "  ${YELLOW}Working... please wait.${RESET}"
  "$@" > /dev/null
  echo -e "  ${GREEN}Done.${RESET}"
}

########################################
# Helper functions
########################################

prompt_default() {
  local prompt="$1"
  local default="$2"
  local var
  read -r -p "$prompt [$default]: " var || true
  if [[ -z "$var" ]]; then
    echo "$default"
  else
    echo "$var"
  fi
}

prompt_yes_no() {
  local prompt="$1"
  local default="$2" # y or n
  local answer
  while true; do
    if [[ "$default" == "y" ]]; then
      read -r -p "$prompt [Y/n]: " answer || true
      answer="${answer:-y}"
    else
      read -r -p "$prompt [y/N]: " answer || true
      answer="${answer:-n}"
    fi
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

validate_ram() {
  local value="$1"
  if [[ "$value" =~ ^[0-9]+[MGmg]$ ]]; then
    return 0
  else
    return 1
  fi
}

########################################
# Pre-checks
########################################

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}This script must be run as root. Use: sudo $0${RESET}"
  exit 1
fi

if ! command -v apt-get &>/dev/null; then
  echo -e "${RED}apt-get not found. This script is intended for Ubuntu/Debian systems.${RESET}"
  exit 1
fi

if ! command -v systemctl &>/dev/null; then
  echo -e "${RED}systemctl not found. This script requires systemd.${RESET}"
  exit 1
fi

clear
echo -e "${BOLD}${BLUE}========================================${RESET}"
echo -e "${BOLD}${BLUE}   Minecraft Server Setup for Ubuntu   ${RESET}"
echo -e "${BOLD}${BLUE}========================================${RESET}"
echo
echo "This wizard will:"
echo "  • Install Java"
echo "  • Create a Minecraft user & directories"
echo "  • Download the server jar"
echo "  • Create & enable a systemd service"
echo

########################################
# Prompt for config
########################################
step "Configuration"

MC_USER="$(prompt_default "Minecraft system user" "$DEF_MC_USER")"
MC_BASE_DIR="$(prompt_default "Base directory for all Minecraft servers" "$DEF_BASE_DIR")"
SERVER_NAME="$(prompt_default "Server name (will be directory & service suffix)" "$DEF_SERVER_NAME")"

MC_SERVER_DIR="${MC_BASE_DIR}/${SERVER_NAME}"
SERVICE_NAME="minecraft-${SERVER_NAME}"

# RAM prompts with validation
while true; do
  MC_MIN_RAM="$(prompt_default "Minimum RAM for JVM (e.g., 2G, 1024M)" "$DEF_MIN_RAM")"
  if validate_ram "$MC_MIN_RAM"; then
    break
  else
    echo -e "${YELLOW}Invalid RAM format. Use something like 2G or 2048M.${RESET}"
  fi
done

while true; do
  MC_MAX_RAM="$(prompt_default "Maximum RAM for JVM (e.g., 4G, 4096M)" "$DEF_MAX_RAM")"
  if validate_ram "$MC_MAX_RAM"; then
    break
  else
    echo -e "${YELLOW}Invalid RAM format. Use something like 4G or 4096M.${RESET}"
  fi
done

MOTD="$(prompt_default "Server MOTD (message of the day)" "$DEF_MOTD")"

while true; do
  PORT="$(prompt_default "Server port" "$DEF_PORT")"
  if [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT > 0 && PORT < 65536 )); then
    break
  else
    echo -e "${YELLOW}Invalid port. Must be a number between 1 and 65535.${RESET}"
  fi
done

########################################
# Summary
########################################

step "Review configuration"

echo -e "  Minecraft user:   ${GREEN}${MC_USER}${RESET}"
echo -e "  Base directory:   ${GREEN}${MC_BASE_DIR}${RESET}"
echo -e "  Server directory: ${GREEN}${MC_SERVER_DIR}${RESET}"
echo -e "  Service name:     ${GREEN}${SERVICE_NAME}${RESET}"
echo -e "  Minecraft version:${GREEN}${MC_VERSION}${RESET}"
echo -e "  JVM Min RAM:      ${GREEN}${MC_MIN_RAM}${RESET}"
echo -e "  JVM Max RAM:      ${GREEN}${MC_MAX_RAM}${RESET}"
echo -e "  MOTD:             ${GREEN}${MOTD}${RESET}"
echo -e "  Port:             ${GREEN}${PORT}${RESET}"
echo

if ! prompt_yes_no "Proceed with installation?" "y"; then
  echo "Aborting by user request."
  exit 0
fi

########################################
# System update / dependencies
########################################

if prompt_yes_no "Run apt-get update/upgrade before installing Java? (Recommended on fresh systems)" "y"; then
  run_quiet "Updating package lists" apt-get update
  run_quiet "Upgrading installed packages" apt-get upgrade -y
fi

run_quiet "Installing OpenJDK 21 & curl" apt-get install -y openjdk-21-jre-headless curl

########################################
# Users & directories
########################################

step "Ensuring minecraft user exists"
if id -u "${MC_USER}" >/dev/null 2>&1; then
  echo -e "  User ${GREEN}${MC_USER}${RESET} already exists. Using existing user."
else
  run_quiet "Creating user ${MC_USER}" \
    useradd -r -m -U -d "${MC_BASE_DIR}" -s /bin/bash "${MC_USER}"
fi

step "Creating server directory"
mkdir -p "${MC_SERVER_DIR}"
echo -e "  Using server directory: ${GREEN}${MC_SERVER_DIR}${RESET}"

########################################
# Download server jar
########################################

step "Downloading Minecraft server jar (v${MC_VERSION})"
if [[ -f "${MC_SERVER_DIR}/${MC_JAR_NAME}" ]]; then
  echo "  Jar already exists at ${MC_SERVER_DIR}/${MC_JAR_NAME}."
  if prompt_yes_no "Re-download and overwrite existing jar?" "n"; then
    curl -fsSL "${MC_JAR_URL}" -o "${MC_SERVER_DIR}/${MC_JAR_NAME}"
    echo -e "  ${GREEN}Jar re-downloaded.${RESET}"
  else
    echo "  Keeping existing jar."
  fi
else
  curl -fsSL "${MC_JAR_URL}" -o "${MC_SERVER_DIR}/${MC_JAR_NAME}"
  echo -e "  ${GREEN}Jar downloaded.${RESET}"
fi

########################################
# EULA & server.properties
########################################

step "Writing EULA file"
cat > "${MC_SERVER_DIR}/eula.txt" <<EOF
# Generated by setup script. By setting eula=true you indicate your agreement to the Minecraft EULA:
# https://aka.ms/MinecraftEULA
eula=true
EOF
echo -e "  ${GREEN}EULA accepted in ${MC_SERVER_DIR}/eula.txt${RESET}"

step "Creating server.properties (if needed)"
if [[ -f "${MC_SERVER_DIR}/server.properties" ]]; then
  echo "  server.properties already exists."
  if prompt_yes_no "Overwrite existing server.properties with a basic template?" "n"; then
    cat > "${MC_SERVER_DIR}/server.properties" <<EOF
# Basic generated config - edit to taste.
motd=${MOTD}
server-port=${PORT}
enable-command-block=false
max-players=20
online-mode=true
level-name=world
gamemode=survival
difficulty=normal
EOF
    echo -e "  ${GREEN}server.properties overwritten with template.${RESET}"
  else
    echo "  Keeping existing server.properties."
  fi
else
  cat > "${MC_SERVER_DIR}/server.properties" <<EOF
# Basic generated config - edit to taste.
motd=${MOTD}
server-port=${PORT}
enable-command-block=false
max-players=20
online-mode=true
level-name=world
gamemode=survival
difficulty=normal
EOF
  echo -e "  ${GREEN}server.properties created.${RESET}"
fi

########################################
# Import ops.json if present
########################################

step "Checking for ops.json to import"
OPS_SRC="${SCRIPT_DIR}/ops.json"
OPS_DEST="${MC_SERVER_DIR}/ops.json"

if [[ -f "${OPS_SRC}" ]]; then
  echo "  Found ops.json in script directory: ${OPS_SRC}"
  if prompt_yes_no "Import this ops.json into the server directory?" "y"; then
    cp "${OPS_SRC}" "${OPS_DEST}"
    echo -e "  ${GREEN}Imported ops.json to ${OPS_DEST}.${RESET}"
  else
    echo -e "  ${YELLOW}Skipping ops.json import.${RESET}"
  fi
else
  echo -e "  ${YELLOW}No ops.json found in script directory (${OPS_SRC}).${RESET}"
  echo -e "  You can add OPs later with /op in-game or by creating ops.json in ${MC_SERVER_DIR}."
fi

########################################
# Permissions & systemd service
########################################

step "Setting ownership on ${MC_BASE_DIR}"
chown -R "${MC_USER}:${MC_USER}" "${MC_BASE_DIR}"
echo -e "  ${GREEN}Ownership updated.${RESET}"

step "Creating systemd service: ${SERVICE_NAME}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

create_service_file() {
  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Minecraft Server instance: ${SERVER_NAME}
After=network.target

[Service]
WorkingDirectory=${MC_SERVER_DIR}
User=${MC_USER}
Group=${MC_USER}
Restart=always
RestartSec=10
Nice=1

ExecStart=/usr/bin/java -Xms${MC_MIN_RAM} -Xmx${MC_MAX_RAM} -jar ${MC_JAR_NAME} nogui

TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF
}

if [[ -f "${SERVICE_FILE}" ]]; then
  echo "  Service file ${SERVICE_FILE} already exists."
  if prompt_yes_no "Overwrite existing service file?" "n"; then
    echo "  Not overwriting service file. Skipping service creation."
  else
    create_service_file
    echo -e "  ${GREEN}Service file updated.${RESET}"
  fi
else
  create_service_file
  echo -e "  ${GREEN}Service file created.${RESET}"
fi

step "Reloading systemd and enabling service"
systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}.service"
echo -e "  ${GREEN}Service ${SERVICE_NAME} enabled and started.${RESET}"

########################################
# Optional UFW rule
########################################

if command -v ufw &>/dev/null; then
  step "Firewall (UFW) configuration"
  if prompt_yes_no "Open TCP port ${PORT} in UFW?" "y"; then
    ufw allow "${PORT}"/tcp || echo -e "  ${YELLOW}Warning: Failed to modify UFW. Check firewall rules manually.${RESET}"
  else
    echo "  Skipping UFW changes."
  fi
fi

########################################
# Done
########################################

step "Setup complete"

echo -e "${GREEN}=== Minecraft server setup is complete! ===${RESET}"
echo
echo -e "  Service name: ${BOLD}${SERVICE_NAME}${RESET}"
echo -e "  Server dir:   ${BOLD}${MC_SERVER_DIR}${RESET}"
echo
echo "Useful commands:"
echo "  systemctl status ${SERVICE_NAME}"
echo "  journalctl -u ${SERVICE_NAME} -f"
echo "  systemctl stop ${SERVICE_NAME}"
echo "  systemctl start ${SERVICE_NAME}"
echo "  systemctl restart ${SERVICE_NAME}"
echo
echo "If you need to adjust server settings, edit:"
echo "  ${MC_SERVER_DIR}/server.properties"
echo
IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)
if [[ -n "${IP:-}" ]]; then
  echo -e "${GREEN}You can now try connecting from a Minecraft client to:${RESET}"
  echo -e "  ${BOLD}${IP}:${PORT}${RESET}"
else
  echo -e "${YELLOW}Could not automatically detect the server IP. Use your server's IP with port ${PORT}.${RESET}"
fi
