#!/bin/bash

# This script automates the installation and uninstallation of ThinEdge.io
# on a Debian-based system, connecting it to Cumulocity IoT.
#
# Usage:
#   ./tedge_setup.sh install           # online — downloads packages from internet
#   ./tedge_setup.sh install --offline # offline — installs from local .deb files
#   ./tedge_setup.sh uninstall
#
# Offline mode expects the following files in ./packages/ (relative to this script):
#   tedge-full_*.deb
#   tedge-container-plugin-ng_*.deb
# And the PI Historian connector offline ZIP unpacked in the same directory:
#   docker-compose.yaml
#   pi_historian_connector_*.tar.gz

set -euo pipefail # Exit immediately if a command exits with a non-zero status.
                  # Exit if any unset variables are used.
                  # Exit if a command in a pipeline fails.

# ========== Constants ==========
CERT_DIR="/etc/tedge/device-certs"
CONFIG_DIR="/etc/tedge/c8y"
LOG_PLUGIN_TOML="/etc/tedge/plugins/tedge-log-plugin.toml"
CONFIG_PLUGIN_TOML="/etc/tedge/plugins/tedge-configuration-plugin.toml"
LOG_ENTRY_TYPE="pi_historian"
TEDGE_FILE_OWNER="tedge"
LOG_ENTRY_PATH="/etc/tedge/c8y/logs/*"

RECORDING_AT_TIME="?time="
POLL_INTERVAL=90

SUPPORTED_CONFIGS='["pi_datapoints","pi_config","tedge-configuration-plugin","pi_historian_connector"]'

DEFAULT_DATAPOINTS='[
    "REACTOR01.TEMP",
    "PUMP02.FLOW",
    "COMPRESSOR.PRESSURE",
    "MOTOR01.SPEED",
    "TANK01.LEVEL"
]'

ACTION=${1:-}
OFFLINE=false
[[ "${2:-}" == "--offline" ]] && OFFLINE=true

# Directory containing this script (used to locate offline packages)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES_DIR="${SCRIPT_DIR}/packages"

# Check if an action is provided
if [[ -z "$ACTION" ]]; then
    echo "Usage: $0 [install|uninstall] [--offline]"
    exit 1
fi

# ========== Environment Detection ==========
# Detect whether we are running inside a container (devcontainer / Docker).
# In a container systemd is not available, so service management is handled
# via scripts/start-tedge.sh instead of systemctl.
IS_CONTAINER=false
if [[ -f /.dockerenv ]] || \
   [[ -n "${REMOTE_CONTAINERS:-}" ]] || \
   [[ -n "${CODESPACES:-}" ]] || \
   grep -q 'docker\|lxc\|kubepods' /proc/1/cgroup 2>/dev/null; then
    IS_CONTAINER=true
fi

# ========== Logging Helpers ==========
log() { echo -e "\033[1;32m[+] $1\033[0m"; }
warn() { echo -e "\033[1;33m[!] $1\033[0m"; }
error_exit() { echo -e "\033[1;31m[x] Error: $1\033[0m" >&2; exit 1; }

# ========== Prompt Helper ==========
prompt_input() {
    local prompt_msg="$1"
    local default_val="$2"
    local user_input

    read -rp "$prompt_msg [$default_val]: " user_input
    echo "${user_input:-$default_val}"
}

# ========== Package Install Helper ==========
# install_deb <package-name> <glob-pattern-for-local-deb>
# In offline mode: installs from local .deb matching the glob under PACKAGES_DIR.
# In online mode: installs via apt-get.
install_deb() {
    local pkg_name="$1"
    local deb_glob="$2"

    if [[ "$OFFLINE" == "true" ]]; then
        local deb_file
        deb_file=$(find "$PACKAGES_DIR" -maxdepth 1 -name "$deb_glob" | sort -V | tail -1)
        if [[ -z "$deb_file" ]]; then
            error_exit "Offline install failed: '${deb_glob}' not found in ${PACKAGES_DIR}/. Copy the required .deb file and retry."
        fi
        log "Installing ${pkg_name} from local package: $(basename "$deb_file")..."
        if ! sudo dpkg -i "$deb_file"; then
            log "dpkg reported dependency issues — attempting to fix with apt-get install -f..."
            sudo apt-get install -f -y || error_exit "Failed to install ${pkg_name} (offline). Check that all dependency .deb files are present in ${PACKAGES_DIR}/."
        fi
    else
        log "Installing ${pkg_name} from apt..."
        sudo apt-get install -y "$pkg_name" || error_exit "Failed to install ${pkg_name} (online). Check your internet connection and apt repository configuration."
    fi
    log "${pkg_name} installed successfully."
}

# ========== Install Function ==========
install() {
    echo "---- ThinEdge.io Device Installation ----"
    [[ "$OFFLINE" == "true" ]] && log "Mode: OFFLINE (packages from ${PACKAGES_DIR}/)" \
                                || log "Mode: ONLINE (packages from internet)"

    # User Inputs
    CUMULOCITY_DOMAIN=$(prompt_input "Enter your Cumulocity domain" "your-tenant.cumulocity.com")
    # Strip protocol prefix and trailing slash — tedge expects domain only (e.g. tenant.cumulocity.com)
    CUMULOCITY_DOMAIN="${CUMULOCITY_DOMAIN#https://}"
    CUMULOCITY_DOMAIN="${CUMULOCITY_DOMAIN#http://}"
    CUMULOCITY_DOMAIN="${CUMULOCITY_DOMAIN%/}"
    DEVICE_EXTERNAL_ID=$(prompt_input "Enter thin-edge device external Id" "tedge-device-01")
    read -rsp "Enter the One-Time Password (OTP) from Cumulocity Device Registration: " ENROLLMENT_OTP; echo
    [[ -z "$ENROLLMENT_OTP" ]] && error_exit "OTP cannot be empty. Generate it in Cumulocity → Device Management → Registration."

    # PI System Inputs
    PI_URL=$(prompt_input "Enter PI Web API base URL" "https://your-pi-server.com/piwebapi")
    # Strip trailing slash
    PI_URL="${PI_URL%/}"
    PI_USER=$(prompt_input "Enter PI username" "piuser")
    read -rsp "Enter PI password: " PI_PASSWORD_PLAIN; echo
    [[ -z "$PI_PASSWORD_PLAIN" ]] && error_exit "PI password cannot be empty."
    PI_PASSWORD=$(echo -n "$PI_PASSWORD_PLAIN" | base64)

    if [[ "$OFFLINE" == "true" ]]; then
        log "Offline mode: skipping repository setup."
        [[ -d "$PACKAGES_DIR" ]] || error_exit "Packages directory not found: ${PACKAGES_DIR}/"
    else
        # Add ThinEdge repositories
        log "Adding ThinEdge repositories..."
        curl -1sLf 'https://dl.cloudsmith.io/public/thinedge/tedge-release/setup.deb.sh' | sudo -E bash || error_exit "Failed to add tedge-release repository"
        curl -1sLf 'https://dl.cloudsmith.io/public/thinedge/community/setup.deb.sh' | sudo -E bash || error_exit "Failed to add tedge-community repository"
        log "Updating apt cache..."
        sudo apt-get update || error_exit "Failed to update apt cache"
    fi

    # Install ThinEdge.io
    install_deb "tedge-full" "tedge-full_*.deb"

    # Configure Cumulocity URL
    log "Configuring Cumulocity URL: $CUMULOCITY_DOMAIN"
    sudo tedge config set c8y.url "$CUMULOCITY_DOMAIN" || error_exit "Failed to set c8y.url"

    # Ensure certificate and config directories exist with correct permissions
    log "Ensuring certificate and config directories exist and have correct permissions..."
    sudo mkdir -p "$CERT_DIR" "$CONFIG_DIR" || error_exit "Failed to create necessary directories"
    sudo chown tedge:tedge "$CERT_DIR" "$CONFIG_DIR" || error_exit "Failed to change ownership of tedge directories"
    sudo chmod 755 "$CERT_DIR" "$CONFIG_DIR" || error_exit "Failed to set permissions for tedge directories"

    # Download device certificate only if it does not already exist
    if sudo tedge cert show c8y &>/dev/null; then
        warn "Device certificate already exists — skipping download."
    else
        log "Downloading device certificate for '$DEVICE_EXTERNAL_ID'..."
        sudo tedge cert download c8y --device-id "$DEVICE_EXTERNAL_ID" --one-time-password "$ENROLLMENT_OTP" || error_exit "Failed to download device certificate"
    fi

    # Connect ThinEdge.io to Cumulocity IoT
    log "Connecting ThinEdge.io to Cumulocity IoT..."
    if [[ "$IS_CONTAINER" == "true" ]]; then
        # systemd is not available in a container. Inject a temporary no-op
        # systemctl onto PATH so `tedge connect` can write the bridge/TLS
        # config without failing on service management, then start the real
        # services via start-tedge.sh.
        _NOOP="$(mktemp -d)"
        cat > "${_NOOP}/systemctl" << 'NOOP_EOF'
#!/bin/bash
echo "[systemctl-noop] $*" >&2
exit 0
NOOP_EOF
        chmod +x "${_NOOP}/systemctl"
        connect_output="$(sudo env PATH="${_NOOP}:${PATH}" tedge connect c8y 2>&1)" && \
            echo "$connect_output" || {
            if echo "$connect_output" | grep -q "already established"; then
                warn "thin-edge is already connected to Cumulocity — skipping connect."
            else
                echo "$connect_output" >&2
                warn "tedge connect reported errors (likely service-start related in container) — proceeding."
            fi
        }
        rm -rf "${_NOOP}"
    else
        if connect_output=$(sudo tedge connect c8y 2>&1); then
            echo "$connect_output"
        elif echo "$connect_output" | grep -q "already established"; then
            warn "thin-edge is already connected to Cumulocity — skipping connect."
        else
            echo "$connect_output" >&2
            error_exit "Failed to connect ThinEdge.io to Cumulocity"
        fi
    fi

    # Install ThinEdge Container Plugin (Next Generation)
    log "Installing tedge-container-plugin-ng..."
    install_deb "tedge-container-plugin-ng" "tedge-container-plugin-ng_*.deb"

    # Load PI Historian Docker image (offline mode only)
    if [[ "$OFFLINE" == "true" ]]; then
        local tarball
        tarball=$(find "$PACKAGES_DIR" -maxdepth 1 -name "pi_historian_connector_*.tar.gz" | sort -V | tail -1)
        if [[ -n "$tarball" ]]; then
            log "Loading PI Historian Docker image from: $(basename "$tarball")..."
            docker load < "$tarball" || error_exit "Failed to load PI Historian Docker image"
        else
            warn "No pi_historian_connector_*.tar.gz found in ${PACKAGES_DIR}/ — skipping Docker image load."
        fi
    fi

    # Update Mosquitto listener to allow external connections
    log "Updating MQTT bind Address to 0.0.0.0 to allow external connections..."
    sudo tedge config set mqtt.bind.address 0.0.0.0 || warn "Failed to set mqtt.bind.address. Continuing."


    # Configure HTTP proxy and open firewall port
    log "Configuring HTTP proxy bind address for Cumulocity mapper..."
    sudo tedge config set c8y.proxy.bind.address 0.0.0.0 || warn "Failed to set c8y.proxy.bind.address. Continuing."

    
    if [[ "$IS_CONTAINER" == "true" ]]; then
        log "Container environment — starting services via start-tedge.sh (after all config applied)..."
        sudo bash "${SCRIPT_DIR}/start-tedge.sh" &
        sleep 2
    else
        log "Restarting tedge c8y service..."
        sudo tedge reconnect c8y || warn "Failed to restart tedge c8y service. Please check the service status."
    fi

    # Publish Device Configuration (Supported Configurations)
    log "Publishing device configuration to Cumulocity IoT..."
    tedge mqtt pub 'te/device/main///twin/c8y_SupportedConfigurations' "$SUPPORTED_CONFIGS"

    # Create JSON configuration files in /etc/tedge/c8y
    log "Creating JSON configuration files in $CONFIG_DIR..."

    sudo tee "$CONFIG_DIR/datapoints.json" >/dev/null <<EOF
$DEFAULT_DATAPOINTS
EOF

    sudo tee "$CONFIG_DIR/pi_config.json" >/dev/null <<EOF
{
    "RECORDING_AT_TIME": "${RECORDING_AT_TIME}",
    "POLL_INTERVAL": ${POLL_INTERVAL},
    "PI_URL": "${PI_URL}",
    "PI_USER": "${PI_USER}",
    "PI_PASSWORD": "${PI_PASSWORD}"
}
EOF

    # ── Register pi_datapoints and pi_config in tedge-configuration-plugin.toml ──
    sudo mkdir -p "$(dirname "$CONFIG_PLUGIN_TOML")"

    if sudo grep -qF 'type = "pi_datapoints"' "$CONFIG_PLUGIN_TOML" 2>/dev/null; then
        log "pi_datapoints config entry already present in $CONFIG_PLUGIN_TOML — skipping."
    else
        printf "\n[[files]]\npath = \"$CONFIG_DIR/datapoints.json\"\ntype = \"pi_datapoints\"\nuser = \"$TEDGE_FILE_OWNER\"\ngroup = \"$TEDGE_FILE_OWNER\"\nmode = 0o644\n" \
            | sudo tee -a "$CONFIG_PLUGIN_TOML" >/dev/null \
            && log "pi_datapoints entry appended to $CONFIG_PLUGIN_TOML." \
            || warn "Failed to append pi_datapoints entry to $CONFIG_PLUGIN_TOML."
    fi

    if sudo grep -qF 'type = "pi_config"' "$CONFIG_PLUGIN_TOML" 2>/dev/null; then
        log "pi_config config entry already present in $CONFIG_PLUGIN_TOML — skipping."
    else
        printf "\n[[files]]\npath = \"$CONFIG_DIR/pi_config.json\"\ntype = \"pi_config\"\nuser = \"$TEDGE_FILE_OWNER\"\ngroup = \"$TEDGE_FILE_OWNER\"\nmode = 0o640\n" \
            | sudo tee -a "$CONFIG_PLUGIN_TOML" >/dev/null \
            && log "pi_config entry appended to $CONFIG_PLUGIN_TOML." \
            || warn "Failed to append pi_config entry to $CONFIG_PLUGIN_TOML."
    fi

    # ── Register pi_historian log type in tedge-log-plugin.toml ──────────────
    local LOG_ENTRY="[[files]]\npath = \"${LOG_ENTRY_PATH}\"\ntype = \"${LOG_ENTRY_TYPE}\""

    if sudo grep -qF "type = \"${LOG_ENTRY_TYPE}\"" "$LOG_PLUGIN_TOML" 2>/dev/null; then
        log "pi_historian log entry already present in $LOG_PLUGIN_TOML — skipping."
    else
        sudo mkdir -p "$(dirname "$LOG_PLUGIN_TOML")"
        printf '\n%b\n' "$LOG_ENTRY" | sudo tee -a "$LOG_PLUGIN_TOML" >/dev/null \
            && log "pi_historian log entry appended to $LOG_PLUGIN_TOML." \
            || warn "Failed to append pi_historian log entry to $LOG_PLUGIN_TOML."
    fi

    sudo chown tedge:tedge "$CONFIG_DIR"/*.json || error_exit "Failed to change ownership of JSON config files"
    sudo chmod 644 "$CONFIG_DIR/datapoints.json" || error_exit "Failed to set permissions for datapoints.json"
    sudo chmod 640 "$CONFIG_DIR/pi_config.json"  || error_exit "Failed to set permissions for pi_config.json"

    log "All ThinEdge.io configuration files created in $CONFIG_DIR"
    log "ThinEdge.io device setup completed successfully!"
    echo "----------------------------------------"
    log "Please verify device connection in Cumulocity IoT portal."
    if [[ "$IS_CONTAINER" == "true" ]]; then
        log "Services running in background via start-tedge.sh. Logs: /var/log/tedge/"
    else
        log "You can check ThinEdge.io services status with: sudo systemctl status 'tedge-*'"
    fi
}

# ========== Uninstall Function ==========
uninstall() {
    echo "---- ThinEdge.io Uninstallation ----"

    log "Disconnecting ThinEdge.io from Cumulocity IoT..."
    sudo tedge disconnect c8y || warn "Disconnection skipped or failed. It might not have been connected."

    log "Purging ThinEdge.io components: tedge-container-plugin-ng and tedge-full..."
    sudo apt-get purge -y tedge-container-plugin-ng tedge-full || warn "Package purge failed. Some ThinEdge.io packages might remain."
    
    log "Removing ThinEdge.io configuration directories: $CERT_DIR and $CONFIG_DIR..."
    sudo rm -rf "$CERT_DIR" || warn "Failed to remove $CERT_DIR"
    sudo rm -rf "$CONFIG_DIR" || warn "Failed to remove $CONFIG_DIR"

    log "Cleaning up apt caches and orphaned dependencies..."
    sudo apt-get autoremove -y || warn "Failed to autoremove orphaned packages."
    sudo apt-get clean || warn "Failed to clean apt cache."

    log "Uninstallation complete."
    echo "----------------------------------------"
}

# ========== Main Execution Block ==========
case "$ACTION" in
    install)
        install
        ;;
    uninstall)
        uninstall
        ;;
    *)
        error_exit "Invalid action: '$ACTION'. Usage: $0 [install|uninstall]"
        ;;
esac