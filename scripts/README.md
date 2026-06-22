# Scripts

This directory contains shell scripts for setting up, building, and running the PI Historian Connector.

| Script | Purpose |
|--------|---------|
| `tedge_setup.sh` | Install or uninstall thin-edge.io on a Debian-based VM and connect it to Cumulocity IoT |
| `build_release.sh` | Build the online and offline release ZIPs for distribution |
| `start-tedge.sh` | Start thin-edge services (Mosquitto, mapper, agent) in a non-systemd environment such as a devcontainer |

---

## tedge_setup.sh

Automates the installation and uninstallation of [thin-edge.io](https://thin-edge.io/) on a Debian-based VM, connecting it to Cumulocity IoT and preparing it to run the PI Historian connector.

### Supported modes

| Mode | Command | Description |
|------|---------|-------------|
| Online install | `./tedge_setup.sh install` | Downloads packages from the internet via apt |
| Offline install | `./tedge_setup.sh install --offline` | Installs from local `.deb` files in `scripts/packages/` |
| Uninstall | `./tedge_setup.sh uninstall` | Removes thin-edge and all configuration |

---

### Prerequisites

- Debian-based OS (Debian, Ubuntu, Raspberry Pi OS)
- `sudo` access — verify before running:
  ```bash
  sudo -v
  ```
- Docker installed and running
- For **online** mode: internet access
- For **offline** mode: package files staged in `scripts/packages/` (see below)

---

### Online Installation

#### Step 1 — Generate a device OTP in Cumulocity

1. Go to **Cumulocity Device Management → Registration → Register Device**
2. Choose **Bulk registration** or **Single device registration**
3. Note the **One-Time Password (OTP)** displayed

#### Step 2 — Run the script

```bash
chmod +x scripts/tedge_setup.sh
scripts/tedge_setup.sh install
```

You will be prompted for:

| Prompt | Example |
|--------|---------|
| Cumulocity domain | `your-tenant.cumulocity.com` |
| Device external ID | `tedge-device-01` |
| OTP | *(from Step 1)* |
| PI Web API base URL | `https://your-pi-server.com/piwebapi` |
| PI username | `piuser` |
| PI password | *(input hidden)* |

The Cumulocity domain is accepted with or without the `https://` prefix — the script strips it automatically. The PI password is base64-encoded by the script before being written to `pi_config.json`.

---

### Offline Installation

Use this when the target device has **no internet access**.

#### Step 1 — Prepare the packages directory on a machine with internet access

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
    └── pi_historian_connector_<version>.tar.gz   # optional — for offline Docker image load
```

> If multiple versions of a `.deb` are present, the script automatically selects the newest one.

#### Step 2 — Transfer files to the target device

```bash
scp -r scripts/ user@<device-ip>:/home/user/
```

#### Step 3 — Generate a device OTP in Cumulocity

Same as online Step 1 above.

#### Step 4 — Run the script in offline mode

```bash
chmod +x scripts/tedge_setup.sh
scripts/tedge_setup.sh install --offline
```

---

### What the install script does

| Step | Action |
|------|--------|
| 1 | Prompt for Cumulocity domain, device ID, and OTP |
| 2 | Add thin-edge apt repositories *(online only)* |
| 3 | Install `tedge-full` |
| 4 | Configure `c8y.url` |
| 5 | Create `/etc/tedge/device-certs` and `/etc/tedge/c8y` directories |
| 6 | Download device certificate via OTP *(skipped if cert already exists)* |
| 7 | `tedge connect c8y` |
| 8 | Install `tedge-container-plugin-ng` |
| 9 | Load PI Historian Docker image via `docker load` *(offline only, if tarball is present)* |
| 10 | Set `mqtt.bind.address 0.0.0.0` (required for Docker container access to Mosquitto) |
| 11 | Set `c8y.proxy.bind.address 0.0.0.0` |
| 12 | `tedge reconnect c8y` to apply MQTT and proxy changes |
| 13 | Publish supported configuration types (`pi_datapoints`, `pi_config`, `tedge-configuration-plugin`, `pi_historian_connector`) |
| 14 | Create default `datapoints.json` and `pi_config.json` in `/etc/tedge/c8y/` |
| 15 | Register `pi_historian` log type in `tedge-log-plugin.toml` |
| 16 | Set correct ownership (`tedge:tedge`) and permissions (`644`) on config files |

#### Default config files created

`/etc/tedge/c8y/datapoints.json` (hardcoded default tags):
```json
[
    "REACTOR01.TEMP",
    "PUMP02.FLOW",
    "COMPRESSOR.PRESSURE",
    "MOTOR01.SPEED",
    "TANK01.LEVEL"
]
```

`/etc/tedge/c8y/pi_config.json` (populated from user input):
```json
{
    "RECORDING_AT_TIME": "?time=",
    "POLL_INTERVAL": 90,
    "PI_URL": "<entered PI Web API URL>",
    "PI_USER": "<entered PI username>",
    "PI_PASSWORD": "<base64-encoded PI password>"
}
```

> The PI password is base64-encoded by the script before being written. `RECORDING_AT_TIME` and `POLL_INTERVAL` are defined as constants at the top of the script and can be changed there without touching the logic.

---

### Uninstallation

```bash
scripts/tedge_setup.sh uninstall
```

This will:
- Disconnect thin-edge from Cumulocity (`tedge disconnect c8y`)
- Purge `tedge-container-plugin-ng` and `tedge-full` via `apt-get purge`
- Remove `/etc/tedge/device-certs` and `/etc/tedge/c8y`
- Run `apt-get autoremove` and `apt-get clean`

> The PI Historian Docker image is **not** removed automatically. To remove it: `docker rmi pi_historian_connector:<version>`

---

### Verifying the installation

```bash
# Check thin-edge service status
sudo systemctl status 'tedge-*'

# Check MQTT broker is listening on all interfaces
ss -tlnp | grep 1883

# Verify device appears in Cumulocity Device Management portal
```

---

## build_release.sh

Builds the online and offline release ZIPs from source. Run this on a **development machine with internet access** — not on the target device.

### Usage

```bash
chmod +x scripts/build_release.sh

# Pass version as argument
scripts/build_release.sh 0.0.4

# Or run interactively (will prompt for version)
scripts/build_release.sh
```

### Output

Two ZIP files are produced in the project root:

| File | Contents | Use case |
|------|----------|----------|
| `pi_historian_connector_v<version>_online.zip` | `app.py`, `docker-compose.yaml`, `Dockerfile`, `logging.conf`, `requirements.txt` | Target device has internet — Docker pulls the image on first run |
| `pi_historian_connector_v<version>_offline.zip` | Docker image tarball, pip wheels, auto-generated offline `docker-compose.yaml`, `logging.conf`, `requirements.txt` | Target device has no internet |

### Build steps

1. **Online ZIP** — zip source files directly from the working directory
2. **Download pip wheels** — `pip download` targeting Python 3.11, Linux x86_64 (`manylinux2014_x86_64`, CPython)
3. **Build Docker image** — `docker build -t pi_historian_connector:<version> .`
4. **Export image** — `docker save | gzip > pi_historian_connector_<version>.tar.gz`
5. **Package offline bundle** — copy tarball, wheels, logging config, and a pre-generated `docker-compose.yaml` (using the pre-loaded image) into a staging directory
6. **Create offline ZIP** — zip the staging directory
7. **Clean up** — remove the tarball, wheels directory, and staging directory

### Notes

- The offline `docker-compose.yaml` is generated by the script with the correct image name and tag — do not replace it with the online version.
- Pip wheels are downloaded for `manylinux2014_x86_64` / CPython 3.11 to match the `python:3.11-slim` Docker base image.
- The GitHub Actions release workflow (`release.yml`) runs this same script automatically on every `v*` tag push and on manual workflow dispatch.

---

## start-tedge.sh

Starts thin-edge services (Mosquitto, tedge-mapper, tedge-agent) in a **non-systemd environment** such as a dev container or Docker container where `systemctl` is not available.

### Usage

```bash
chmod +x scripts/start-tedge.sh
scripts/start-tedge.sh
```

The script blocks and tails all service logs until interrupted (Ctrl+C or container stop).

### What it does

1. Stops any existing Mosquitto, tedge-mapper, or tedge-agent processes
2. Writes a Mosquitto configuration that listens on all interfaces (`0.0.0.0:1883`) with anonymous access enabled
3. Starts `mosquitto` and waits until port 1883 is ready (up to 10 seconds)
4. Starts `tedge-mapper c8y`
5. Starts `tedge-agent`
6. Tails all service logs from `/var/log/tedge/` in a single stream
7. On exit (Ctrl+C, SIGINT, SIGTERM) gracefully stops all three processes

### Log files

| File | Service |
|------|---------|
| `/var/log/tedge/mosquitto.log` | Mosquitto broker |
| `/var/log/tedge/tedge-mapper.log` | Cumulocity mapper |
| `/var/log/tedge/tedge-agent.log` | thin-edge agent |

### Mosquitto configuration applied

```
listener 1883 0.0.0.0
allow_anonymous true
persistence true
persistence_location /var/lib/mosquitto/
log_dest stdout
```

> This configuration is intended for development only. For production, use `tedge_setup.sh` which configures Mosquitto through the standard thin-edge tooling.
