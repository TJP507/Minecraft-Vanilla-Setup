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
CYAN="\e[36m"
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
# TUI helpers
########################################

STEP=1
TOTAL_STEPS=20  # Approximate, some steps are optional

step() {
  local msg="$1"
  echo -e "\n${BLUE}┌────────────────────────────────────────────────────────────┐${RESET}"
  printf   "${BLUE}│${RESET} ${BOLD}[STEP %2d/%2d]${RESET} %-25s${BLUE}│${RESET}\n" "$STEP" "$TOTAL_STEPS" "$msg"
  echo -e   "${BLUE}└────────────────────────────────────────────────────────────┘${RESET}"
  STEP=$((STEP + 1))
}

ok() {
  local msg="$1"
  printf "  %b✔%b %s\n" "$GREEN" "$RESET" "$msg"
}

# Spinner runner: hides stdout, keeps stderr, shows spinner
run_with_spinner() {
  local msg="$1"
  shift

  step "$msg"

  local spinner=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )
  local i=0

  # Start command in background, stdout -> /dev/null
  "$@" > /dev/null &
  local cmd_pid=$!

  # Hide cursor if possible
  tput civis 2>/dev/null || true

  # Spinner loop
  while kill -0 "$cmd_pid" 2>/dev/null; do
    printf "\r  %b%s%b %s" "$CYAN" "${spinner[$i]}" "$RESET" "Working..."
    i=$(( (i + 1) % ${#spinner[@]} ))
    sleep 0.1
  done

  # Wait for command to finish & capture exit code
  wait "$cmd_pid"
  local rc=$?

  # Restore cursor
  tput cnorm 2>/dev/null || true

  if [[ $rc -eq 0 ]]; then
    printf "\r  %b✔%b %s\n" "$GREEN" "$RESET" "${msg} completed.         "
  else
    printf "\r  %b✖%b %s (exit code %d)\n" "$RED" "$RESET" "${msg} failed." "$rc"
  fi

  return "$rc"
}

########################################
# Helper functions
########################################

prompt_default() {
  local prompt="$1"
  local default="$2"
  local var
  read -r -p "  $prompt [$default]: " var || true
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
      read -r -p "  $prompt [Y/n]: " answer || true
      answer="${answer:-y}"
    else
      read -r -p "  $prompt [y/N]: " answer || true
      answer="${answer:-n}"
    fi
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) echo "  Please answer y or n." ;;
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
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${BLUE}║      Minecraft Server Setup for Ubuntu       ║${RESET}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════╝${RESET}"
echo
echo "This guided setup will:"
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
SERVER_NAME="$(prompt_default "Server name (directory & service suffix)" "$DEF_SERVER_NAME")"

MC_SERVER_DIR="${MC_BASE_DIR}/${SERVER_NAME}"
SERVICE_NAME="minecraft-${SERVER_NAME}"

# RAM with validation
while true; do
  MC_MIN_RAM="$(prompt_default "Minimum RAM for JVM (e.g., 2G, 1024M)" "$DEF_MIN_RAM")"
  if validate_ram "$MC_MIN_RAM"; then
    break
  else
    echo -e "  ${YELLOW}Invalid RAM format. Use something like 2G or 2048M.${RESET}"
  fi
done

while true; do
  MC_MAX_RAM="$(prompt_default "Maximum RAM for JVM (e.g., 4G, 4096M)" "$DEF_MAX_RAM")"
  if validate_ram "$MC_MAX_RAM"; then
    break
  else
    echo -e "  ${YELLOW}Invalid RAM format. Use something like 4G or 4096M.${RESET}"
  fi
done

MOTD="$(prompt_default "Server MOTD (message of the day)" "$DEF_MOTD")"

while true; do
  PORT="$(prompt_default "Server port" "$DEF_PORT")"
  if [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT > 0 && PORT < 65536 )); then
    break
  else
    echo -e "  ${YELLOW}Invalid port. Must be a number between 1 and 65535.${RESET}"
  fi
done

ok "Collected configuration values."

########################################
# Summary
########################################

step "Review configuration"

echo -e "  ${BOLD}Minecraft configuration:${RESET}"
echo -e "    User:            ${GREEN}${MC_USER}${RESET}"
echo -e "    Base directory:  ${GREEN}${MC_BASE_DIR}${RESET}"
echo -e "    Server dir:      ${GREEN}${MC_SERVER_DIR}${RESET}"
echo -e "    Service name:    ${GREEN}${SERVICE_NAME}${RESET}"
echo -e "    Version:         ${GREEN}${MC_VERSION}${RESET}"
echo -e "    JVM Min RAM:     ${GREEN}${MC_MIN_RAM}${RESET}"
echo -e "    JVM Max RAM:     ${GREEN}${MC_MAX_RAM}${RESET}"
echo -e "    MOTD:            ${GREEN}${MOTD}${RESET}"
echo -e "    Port:            ${GREEN}${PORT}${RESET}"
echo

if ! prompt_yes_no "Does this look correct? Proceed with installation?" "y"; then
  echo "  Aborting by user request."
  exit 0
fi
ok "Configuration confirmed by user."

########################################
# System update / dependencies
########################################

if prompt_yes_no "Run apt-get update/upgrade before installing Java? (Recommended on fresh systems)" "y"; then
  run_with_spinner "Updating package lists" apt-get update
  run_with_spinner "Upgrading installed packages" apt-get upgrade -y
  ok "System packages updated."
else
  ok "Skipped apt-get update/upgrade by user choice."
fi

run_with_spinner "Installing OpenJDK 21 & curl" apt-get install -y openjdk-21-jre-headless curl

########################################
# Users & directories
########################################

step "Ensuring minecraft user exists"
if id -u "${MC_USER}" >/dev/null 2>&1; then
  ok "User ${GREEN}${MC_USER}${RESET} already exists. Using existing user."
else
  run_with_spinner "Creating user ${MC_USER}" \
    useradd -r -m -U -d "${MC_BASE_DIR}" -s /bin/bash "${MC_USER}"
fi

step "Creating server directory"
mkdir -p "${MC_SERVER_DIR}"
ok "Using server directory: ${GREEN}${MC_SERVER_DIR}${RESET}"

########################################
# Download server jar
########################################

step "Downloading Minecraft server jar (v${MC_VERSION})"
if [[ -f "${MC_SERVER_DIR}/${MC_JAR_NAME}" ]]; then
  echo "  Jar already exists at ${MC_SERVER_DIR}/${MC_JAR_NAME}."
  if prompt_yes_no "Re-download and overwrite existing jar?" "n"; then
    run_with_spinner "Re-downloading server jar" \
      curl -fsSL "${MC_JAR_URL}" -o "${MC_SERVER_DIR}/${MC_JAR_NAME}"
  else
    ok "Keeping existing server jar."
  fi
else
  run_with_spinner "Downloading server jar" \
    curl -fsSL "${MC_JAR_URL}" -o "${MC_SERVER_DIR}/${MC_JAR_NAME}"
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
ok "EULA accepted in ${MC_SERVER_DIR}/eula.txt"

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
    ok "server.properties overwritten with basic template."
  else
    ok "Keeping existing server.properties."
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
  ok "server.properties created with basic template."
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
    ok "Imported ops.json to ${OPS_DEST}."
  else
    ok "Skipped ops.json import (user choice)."
  fi
else
  echo -e "  ${YELLOW}No ops.json found in script directory (${OPS_SRC}).${RESET}"
  ok "No ops.json imported (none found)."
fi

########################################
# Permissions & systemd service
########################################

step "Setting ownership on ${MC_BASE_DIR}"
chown -R "${MC_USER}:${MC_USER}" "${MC_BASE_DIR}"
ok "Ownership set to ${MC_USER}:${MC_USER} for ${MC_BASE_DIR}."

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
    ok "Keeping existing service file (no changes made)."
  else
    create_service_file
    ok "Service file updated at ${SERVICE_FILE}."
  fi
else
  create_service_file
  ok "Service file created at ${SERVICE_FILE}."
fi

step "Reloading systemd and enabling service"
systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}.service"
ok "Service ${SERVICE_NAME} enabled and started."

########################################
# Optional UFW rule
########################################

if command -v ufw &>/dev/null; then
  step "Firewall (UFW) configuration"
  if prompt_yes_no "Open TCP port ${PORT} in UFW?" "y"; then
    if ufw allow "${PORT}"/tcp; then
      ok "UFW rule added to allow TCP port ${PORT}."
    else
      echo -e "  ${YELLOW}Warning: Failed to modify UFW. Check firewall rules manually.${RESET}"
    fi
  else
    ok "Skipped UFW changes (user choice)."
  fi
else
  step "Firewall (UFW) configuration"
  ok "UFW not installed; skipping firewall configuration."
fi

########################################
# Done
########################################

step "Setup complete"

echo -e "${GREEN}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}║       Minecraft server setup complete!       ║${RESET}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${RESET}"
echo
ok "Minecraft service configured."

echo -e "  Service name: ${BOLD}${SERVICE_NAME}${RESET}"
echo -e "  Server dir:   ${BOLD}${MC_SERVER_DIR}${RESET}"
echo -e "  Version:      ${BOLD}${MC_VERSION}${RESET}"
echo
echo "  Useful commands:"
echo "    Check ${SERVICE_NAME} status :: systemctl status ${SERVICE_NAME}"
echo "    Watch ${SERVICE_NAME} logs   :: journalctl -u ${SERVICE_NAME} -f"
echo "    Stop ${SERVICE_NAME}         :: systemctl stop ${SERVICE_NAME}"
echo "    Start ${SERVICE_NAME}        :: systemctl start ${SERVICE_NAME}"
echo "    Restart ${SERVICE_NAME}      :: systemctl restart ${SERVICE_NAME}"
echo
echo "  ${BOLD}To adjust server settings, edit:${RESET}"
echo "    ${MC_SERVER_DIR}/server.properties"
echo
IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)
if [[ -n "${IP:-}" ]]; then
  ok "Server IP detected."
  echo -e "  ${BOLD}${GREEN}Connect from Minecraft client using:${RESET}"
  echo -e "    ${BOLD}${IP}:${PORT}${RESET}"
else
  echo -e "  ${BOLD}${YELLOW}Could not automatically detect server IP.${RESET}"
  echo -e "  Use your server's IP with port ${PORT}."
fi

echo
echo
