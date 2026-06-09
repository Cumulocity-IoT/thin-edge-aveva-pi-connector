# tedge_setup.sh

Automates the installation and uninstallation of [thin-edge.io](https://thin-edge.io/) on a Debian-based VM, connecting it to Cumulocity IoT and preparing it to run the PI Historian connector.

## Supported modes

| Mode | Command | Description |
|---|---|---|
| Online install | `./tedge_setup.sh install` | Downloads packages from the internet via apt |
| Offline install | `./tedge_setup.sh install --offline` | Installs from local `.deb` files and Docker image tarball |
| Uninstall | `./tedge_setup.sh uninstall` | Removes thin-edge and all configuration |

---

## Prerequisites

- Debian-based OS (Debian, Ubuntu, Raspberry Pi OS)
- `sudo` access — verify before running:
  ```bash
  sudo -v
  ```
- Docker installed and running
- For **online** mode: internet access
- For **offline** mode: package files staged in `scripts/packages/` (see below)

---

## Online Installation

### Step 1 — Generate a device OTP in Cumulocity

1. Go to **Cumulocity Device Management → Registration → Register Device**
2. Choose **Bulk registration** or **Single device registration**
3. Note the **One-Time Password (OTP)** displayed

### Step 2 — Run the script

```bash
chmod +x scripts/tedge_setup.sh
scripts/tedge_setup.sh install
```

You will be prompted for:

| Prompt | Example |
|---|---|
| Cumulocity domain | `your-tenant.cumulocity.com` |
| Device external ID | `tedge-device-01` |
| OTP | *(from Step 1)* |

---

## Offline Installation

Use this when the target device has **no internet access**.

### Step 1 — Prepare the packages directory on a machine with internet access

Create a `packages/` folder next to the script and download the required files:

```bash
mkdir -p scripts/packages

# Download thin-edge .deb packages
apt-get download tedge-full tedge-container-plugin-ng

# Move downloaded .debs into packages/
mv *.deb scripts/packages/

# Copy the PI Historian offline tarball (produced by build_release.sh)
cp pi_historian_connector_*.tar.gz scripts/packages/
```

Expected layout:
```
scripts/
├── tedge_setup.sh
└── packages/
    ├── tedge-full_<version>_<arch>.deb
    ├── tedge-container-plugin-ng_<version>_<arch>.deb
    └── pi_historian_connector_<version>.tar.gz
```

> If multiple versions of a `.deb` are present, the script automatically selects the newest one.

### Step 2 — Transfer files to the target device

```bash
scp -r scripts/ user@<device-ip>:/home/user/
```

### Step 3 — Generate a device OTP in Cumulocity

Same as online Step 1 above.

### Step 4 — Run the script in offline mode

```bash
chmod +x scripts/tedge_setup.sh
scripts/tedge_setup.sh install --offline
```

---

## What the script does

| Step | Action |
|---|---|
| 1 | Prompt for domain, device ID, and OTP |
| 2 | Add thin-edge apt repositories *(online only)* |
| 3 | Install `tedge-full` |
| 4 | Configure `c8y.url` |
| 5 | Create `/etc/tedge/device-certs` and `/etc/tedge/c8y` directories |
| 6 | Download device certificate via OTP *(skipped if cert already exists)* |
| 7 | `tedge connect c8y` |
| 8 | Install `tedge-container-plugin-ng` |
| 9 | Load PI Historian Docker image via `docker load` *(offline only)* |
| 10 | Set `mqtt.bind.address 0.0.0.0` (required for Docker container access) |
| 11 | Set `c8y.proxy.bind.address 0.0.0.0` |
| 12 | `tedge reconnect c8y` to apply MQTT/proxy changes |
| 13 | Publish supported configuration types to Cumulocity |
| 14 | Create default `datapoints.json` and `pi_config.json` in `/etc/tedge/c8y/` |
| 15 | Register `pi_historian` log type in `tedge-log-plugin.toml` |

---

## Uninstallation

```bash
scripts/tedge_setup.sh uninstall
```

This will:
- Disconnect thin-edge from Cumulocity
- Purge `tedge-full` and `tedge-container-plugin-ng`
- Remove `/etc/tedge/device-certs` and `/etc/tedge/c8y`
- Run `apt-get autoremove` and `apt-get clean`

> The PI Historian Docker image is **not** removed automatically. To remove it: `docker rmi pi_historian_connector:<version>`

---

## Verifying the installation

```bash
# Check thin-edge service status
sudo systemctl status 'tedge-*'

# Check MQTT broker is listening on all interfaces
ss -tlnp | grep 1883

# Verify device appears in Cumulocity Device Management portal
```
