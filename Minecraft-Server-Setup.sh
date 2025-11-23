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
trap 'echo -e "${RED}An error occurred on line ${LINENO}. Exiting.${RESET}" >&2' ERR

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

echo -e "${BOLD}${BLUE}Minecraft Server Setup for Ubuntu${RESET}"
echo "This will install Java, create a Minecraft user & directory, and configure a systemd service."
echo

########################################
# Prompt for config
########################################

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

echo
echo -e "${BOLD}Minecraft EULA${RESET}"
echo "You must accept the Minecraft EULA to run the server."
echo "See: https://aka.ms/MinecraftEULA"
if ! prompt_yes_no "Do you accept the Minecraft EULA?" "n"; then
  echo -e "${RED}You must accept the EULA to continue. Exiting.${RESET}"
  exit 1
fi

########################################
# Summary
########################################

echo
echo -e "${BOLD}${BLUE}Summary of configuration:${RESET}"
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
# Installation steps
########################################

echo -e "${BLUE}=== Updating package index and installing dependencies ===${RESET}"
apt-get update -y
apt-get install -y openjdk-21-jre-headless curl

echo -e "${BLUE}=== Creating minecraft user (if needed) ===${RESET}"
if id -u "${MC_USER}" >/dev/null 2>&1; then
  echo "User ${MC_USER} already exists. Using existing user."
else
  useradd -r -m -U -d "${MC_BASE_DIR}" -s /bin/bash "${MC_USER}"
  echo "Created user ${MC_USER}."
fi

echo -e "${BLUE}=== Creating server directory at ${MC_SERVER_DIR} ===${RESET}"
mkdir -p "${MC_SERVER_DIR}"

echo -e "${BLUE}=== Downloading Minecraft server jar (v${MC_VERSION}) ===${RESET}"
if [[ -f "${MC_SERVER_DIR}/${MC_JAR_NAME}" ]]; then
  echo "Jar already exists at ${MC_SERVER_DIR}/${MC_JAR_NAME}."
  if prompt_yes_no "Re-download and overwrite existing jar?" "n"; then
    curl -fL "${MC_JAR_URL}" -o "${MC_SERVER_DIR}/${MC_JAR_NAME}"
  else
    echo "Keeping existing jar."
  fi
else
  curl -fL "${MC_JAR_URL}" -o "${MC_SERVER_DIR}/${MC_JAR_NAME}"
fi

echo -e "${BLUE}=== Writing EULA file ===${RESET}"
cat > "${MC_SERVER_DIR}/eula.txt" <<EOF
# Generated by setup script. By setting eula=true you indicate your agreement to the Minecraft EULA:
# https://aka.ms/MinecraftEULA
eula=true
EOF

echo -e "${BLUE}=== Creating server.properties (if it does not already exist) ===${RESET}"
if [[ -f "${MC_SERVER_DIR}/server.properties" ]]; then
  echo "server.properties already exists."
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
  else
    echo "Keeping existing server.properties."
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
fi

echo -e "${BLUE}=== Setting ownership for ${MC_BASE_DIR} ===${RESET}"
chown -R "${MC_USER}:${MC_USER}" "${MC_BASE_DIR}"

echo -e "${BLUE}=== Creating systemd service: ${SERVICE_NAME} ===${RESET}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

if [[ -f "${SERVICE_FILE}" ]]; then
  echo "Service file ${SERVICE_FILE} already exists."
  if ! prompt_yes_no "Overwrite existing service file?" "n"; then
    echo "Not overwriting service file. Skipping service creation."
  else
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
  fi
else
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
fi

echo -e "${BLUE}=== Reloading systemd and enabling service ===${RESET}"
systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}.service"

########################################
# Optional UFW rule
########################################

if command -v ufw &>/dev/null; then
  echo
  echo -e "${BLUE}=== Firewall (UFW) configuration ===${RESET}"
  if prompt_yes_no "Attempt to open TCP port ${PORT} in UFW?" "y"; then
    ufw allow "${PORT}"/tcp || echo -e "${YELLOW}Warning: Failed to modify UFW. You may need to adjust firewall rules manually.${RESET}"
  fi
fi

########################################
# Done
########################################

echo
echo -e "${GREEN}=== Setup complete! ===${RESET}"
echo -e "Service name: ${BOLD}${SERVICE_NAME}${RESET}"
echo -e "Server dir:   ${BOLD}${MC_SERVER_DIR}${RESET}"
echo
echo "Useful commands:"
echo "  systemctl status ${SERVICE_NAME}"
echo "  journalctl -u ${SERVICE_NAME} -f"
echo "  systemctl stop ${SERVICE_NAME}"
echo "  systemctl start ${SERVICE_NAME}"
echo
echo "If you need to adjust server settings, edit:"
echo "  ${MC_SERVER_DIR}/server.properties"
echo
echo "Then restart the server:"
echo "  systemctl restart ${SERVICE_NAME}"
echo
echo -e "${GREEN}You can now try connecting from a Minecraft client to:${RESET}"
echo -e "  ${BOLD}<your-server-ip>:${PORT}${RESET}"
