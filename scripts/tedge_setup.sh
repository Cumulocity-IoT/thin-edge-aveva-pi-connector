#!/bin/bash

# This script automates the installation and uninstallation of ThinEdge.io
# on a Debian-based system, connecting it to Cumulocity IoT.

set -euo pipefail # Exit immediately if a command exits with a non-zero status.
                  # Exit if any unset variables are used.
                  # Exit if a command in a pipeline fails.

ACTION=${1:-}

# Check if an action is provided
if [[ -z "$ACTION" ]]; then
    echo "Usage: $0 [install|uninstall]"
    exit 1
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

# ========== Function: Create EST Registration File ==========
create_est_registration_file() {
    local otp="$1"
    local device_id_param="$2" # Use the passed device_id

    log "Generating ESTRegistrationFile.csv with OTP for device: $device_id_param"

    sudo tee "$CONFIG_DIR/ESTRegistrationFile.csv" >/dev/null <<EOF
ID;TYPE;NAME;ICCID;IDTYPE;PATH;SHELL;AUTH_TYPE;ENROLLMENT_OTP
$device_id_param;;;;;;;CERTIFICATES;$otp
EOF

    sudo chown tedge:tedge "$CONFIG_DIR/ESTRegistrationFile.csv" || error_exit "Failed to change ownership of ESTRegistrationFile.csv"
    sudo chmod 644 "$CONFIG_DIR/ESTRegistrationFile.csv" || error_exit "Failed to set permissions for ESTRegistrationFile.csv"

    log "File created at $CONFIG_DIR/ESTRegistrationFile.csv"
}

# ========== Install Function ==========
install() {
    echo "---- ThinEdge.io Device Installation ----"

    # User Inputs - Centralized for clarity
    CUMULOCITY_DOMAIN=$(prompt_input "Enter your Cumulocity domain" "Your cumulocity Tenant domain URL")
    CUMULOCITY_TENANT=$(prompt_input "Enter your Cumulocity tenant" "Your Cumulocity tenant id")
    CUMULOCITY_USER=$(prompt_input "Enter your Cumulocity Tenant User" "Your Cumulocity Tenant User name")
    read -rsp "Enter your Cumulocity Tenant Password [will not show]: " CUMULOCITY_PASSWORD; echo
    DEVICE_EXTERNAL_ID=$(prompt_input "Enter thin-edge external Id" "tedge-test-vm2")
    VM_USER=$(prompt_input "Enter your VM user Id" "<Your VM user id>")

    # Directories
    readonly CERT_DIR="/etc/tedge/device-certs"
    readonly CONFIG_DIR="/etc/tedge/c8y"

    # Add ThinEdge repositories
    log "Adding ThinEdge repositories..."
    curl -1sLf 'https://dl.cloudsmith.io/public/thinedge/tedge-release/setup.deb.sh' | sudo -E bash || error_exit "Failed to add tedge-release repository"
    curl -1sLf 'https://dl.cloudsmith.io/public/thinedge/community/setup.deb.sh' | sudo -E bash || error_exit "Failed to add tedge-community repository"

    # Install ThinEdge.io and its dependencies
    log "Updating apt cache and installing ThinEdge.io..."
    sudo apt-get update || error_exit "Failed to update apt cache"
    sudo apt-get install -y tedge-full || error_exit "ThinEdge.io installation failed"

    # Configure Cumulocity URL
    log "Configuring Cumulocity URL: $CUMULOCITY_DOMAIN"
    sudo tedge config set c8y.url "$CUMULOCITY_DOMAIN" || error_exit "Failed to set c8y.url"

    # Ensure certificate and config directories exist with correct permissions
    log "Ensuring certificate and config directories exist and have correct permissions..."
    sudo mkdir -p "$CERT_DIR" "$CONFIG_DIR" || error_exit "Failed to create necessary directories"
    sudo chown tedge:tedge "$CERT_DIR" "$CONFIG_DIR" || error_exit "Failed to change ownership of tedge directories"
    sudo chmod 755 "$CERT_DIR" "$CONFIG_DIR" || error_exit "Failed to set permissions for tedge directories"

    # Generate OTP and EST Registration File
    log "Generating One-Time Password for device registration..."
    ENROLLMENT_OTP=$(head /dev/urandom | tr -dc A-Za-z0-9@#%! | head -c 12 ; echo '') # Safer OTP generation
    create_est_registration_file "$ENROLLMENT_OTP" "$DEVICE_EXTERNAL_ID"

    # Register device in Cumulocity IoT
    log "Registering device '$DEVICE_EXTERNAL_ID' in Cumulocity IoT..."
    AUTH_CREDENTIALS="${CUMULOCITY_TENANT}/${CUMULOCITY_USER}:${CUMULOCITY_PASSWORD}"
    AUTH_HEADER=$(printf "%s" "$AUTH_CREDENTIALS" | base64 --wrap=0) # --wrap=0 for no line breaks
    
    curl_output=$(curl -s -X POST \
        -H "Authorization: Basic $AUTH_HEADER" \
        -F "file=@$CONFIG_DIR/ESTRegistrationFile.csv;type=text/csv" \
        "https://$CUMULOCITY_DOMAIN/devicecontrol/bulkNewDeviceRequests" || error_exit "Failed to register device with Cumulocity")

    if echo "$curl_output" | grep -q "error"; then
        error_exit "Cumulocity device registration returned an error: $curl_output"
    fi
    log "Device registration request sent successfully."

    # Download device certificate
    log "Downloading device certificate for '$DEVICE_EXTERNAL_ID'..."
    sudo tedge cert download c8y --device-id "$DEVICE_EXTERNAL_ID" --one-time-password "$ENROLLMENT_OTP" || error_exit "Failed to download device certificate"

    # Connect ThinEdge.io to Cumulocity IoT
    log "Connecting ThinEdge.io to Cumulocity IoT..."
    sudo tedge connect c8y || error_exit "Failed to connect ThinEdge.io to Cumulocity"

    # Install ThinEdge Container Plugin (Next Generation)
    log "Installing tedge-container-plugin-ng..."
    sudo apt-get install -y tedge-container-plugin-ng || warn "tedge-container-plugin-ng installation failed. Continuing with setup."

    # Update Mosquitto listener to allow external connections
    log "Updating Mosquitto listener to 0.0.0.0 and restarting service..."
    # Use ! for in-place editing when `set -u` is active, or use a temp file.
    # A safer approach for sed with variables and potential unset issues is to use a temporary file.
    if sudo sed -i.bak 's/^listener 1883 127\.0\.0\.1/listener 1883 0.0.0.0/' /etc/tedge/mosquitto-conf/tedge-mosquitto.conf; then
        log "Mosquitto configuration updated."
    else
        warn "Mosquitto config update failed. Manual intervention might be needed."
    fi
    sudo systemctl restart mosquitto || warn "Mosquitto restart failed. Check Mosquitto logs."
    sudo systemctl enable mosquitto || warn "Failed to enable Mosquitto service at boot."


    # Configure HTTP proxy and open firewall port
    log "Configuring HTTP proxy for Cumulocity mapper..."
    sudo tedge config set c8y.proxy.client.host 0.0.0.0 || warn "Failed to set c8y.proxy.client.host. Continuing."
    
    if command -v ufw &> /dev/null; then
        log "Allowing port 8001/tcp through UFW firewall..."
        sudo ufw allow 8001/tcp || warn "Failed to add UFW rule for port 8001/tcp. It might already be open or UFW is not active."
    else
        warn "UFW (Uncomplicated Firewall) not found. Skipping firewall configuration for port 8001/tcp."
    fi
    
    log "Restarting tedge-mapper-c8y service..."
    sudo systemctl restart tedge-mapper-c8y || warn "tedge-mapper-c8y restart failed. Check service logs."
    sudo systemctl enable tedge-mapper-c8y || warn "Failed to enable tedge-mapper-c8y service at boot."

    # Publish Device Configuration (Supported Configurations)
    log "Publishing device configuration to Cumulocity IoT..."
    tedge mqtt pub 'te/device/main///twin/c8y_SupportedConfigurations' '[
        "pi_datapoints",
        "pi_config",
        "tedge-configuration-plugin"
    ]'
    # Create JSON configuration files in /etc/tedge/c8y
    log "Creating JSON configuration files in $CONFIG_DIR..."
    
    sudo tee "$CONFIG_DIR/datapoints.json" >/dev/null <<EOF
[
    "78FIQ301.A", "78FIC102.A"
]
EOF

    sudo tee "$CONFIG_DIR/pi_config.json" >/dev/null <<EOF
{
    "RECORDING_AT_TIME": "?time=",
    "POLL_INTERVAL": 90
}
EOF

    sudo tee "$CONFIG_DIR/pihistorian_device_config.json" >/dev/null <<EOF
{
    "CATEGORY": "PIHistorian",
    "KEY": "$DEVICE_EXTERNAL_ID"
}
EOF

    sudo chown tedge:tedge "$CONFIG_DIR"/*.json || error_exit "Failed to change ownership of JSON config files"
    sudo chmod 644 "$CONFIG_DIR"/*.json || error_exit "Failed to set permissions for JSON config files"

    log "All ThinEdge.io configuration files created in $CONFIG_DIR"
    log "ThinEdge.io device setup completed successfully!"
    echo "----------------------------------------"
    log "Please verify device connection in Cumulocity IoT portal."
    log "You can check ThinEdge.io services status with: sudo systemctl status 'tedge-*'"
}

# ========== Uninstall Function ==========
uninstall() {
    echo "---- ThinEdge.io Uninstallation ----"
    # Directories
    readonly CERT_DIR="/etc/tedge/device-certs"
    readonly CONFIG_DIR="/etc/tedge/c8y"

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