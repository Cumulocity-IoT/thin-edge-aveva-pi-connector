# PI Historian Service

A Python-based service for [thin-edge](https://thin-edge.io/) designed to read data from the AVEVA PI System using REST APIs and publish it to an MQTT broker via thin-edge. The application also supports live configuration updates, enabling runtime changes without the need for a restart.

## Architecture Diagram

<img width="2060" height="470" alt="image" src="https://github.com/user-attachments/assets/2b20fd59-c544-4d49-8bf0-c7e6132b297b" />


## Features

- Periodic PI data collection via REST API (PI Web API)
- Structured MQTT message publishing to Cumulocity IoT via thin-edge
- Real-time monitoring of configuration file changes
- Dynamic reconfiguration without service restart
- Digital and enumeration tag support (handles JSON/dict values from PI digital points)
- Stable tag-to-batch assignment — each PI tag is permanently mapped to a batch ID regardless of adding or removing other tags
- Application logs written to `/etc/tedge/c8y/logs/` (persisted on host via volume mount, daily rotation)

## Requirements

- Python 3.11+
- MQTT Broker (e.g., Mosquitto) version 2.1.0+
- Access to PI Web API

## Configuration

The following configuration files must be uploaded to the Cumulocity tenant for controlling the config changes remotely.

### Required Files

- `pi_config.json`: PI server connection details used to fetch data and authenticate against the PI system.

    ```json
    {
        "RECORDING_AT_TIME": "?time=",
        "POLL_INTERVAL": 60,
        "PI_USER": "default_user",
        "PI_PASSWORD": "default_password-base64-encoded",
        "PI_URL": "https://default-url.com/piwebapi",
        "BATCH_SIZE": 60,
        "MQTT_PUBLISH_TIMEOUT": 1
    }
    ```

    | Key | Default | Description |
    |---|---|---|
    | `RECORDING_AT_TIME` | `"?time="` | Query string prefix used when requesting a value at a specific timestamp from PI Web API. |
    | `POLL_INTERVAL` | `60` | Seconds between data collection cycles. |
    | `PI_USER` | — | PI Web API username. |
    | `PI_PASSWORD` | — | PI Web API password, base64-encoded. |
    | `PI_URL` | — | Full base URL of the PI Web API server. |
    | `BATCH_SIZE` | `60` | Maximum number of PI tags per MQTT measurement batch. Only used when `tag_batches.json` does not yet exist (first run). Changing it after the first run has no effect unless `tag_batches.json` is deleted. |
    | `MQTT_PUBLISH_TIMEOUT` | `1` | Seconds to wait for MQTT publish acknowledgement. A warning is logged if the message is not confirmed within this window. |

- `datapoints.json`: List of PI tags to read and publish to Cumulocity, with optional friendly names.

    ```json
    [
        "78FIQ301.A",
        "78FIC102.A"
    ]
    ```

- `tag_batches.json` *(auto-generated)*: Persistent ledger that records the batch ID assigned to every PI tag. Created automatically on first run at `/etc/tedge/c8y/tag_batches.json`. Do not edit manually. If accidentally deleted it is regenerated with identical assignments as long as `datapoints.json` has not changed.

    ```json
    {
        "_num_batches": 2,
        "78FIQ301_A": 0,
        "78FIC102_A": 1
    }
    ```

Upload the above configuration files into Cumulocity → Configuration Management tab, like below.

![Configuration Screenshot](configurations.png)

### Configuration via thin-edge

Update your `tedge-configuration-plugin` to include the configuration files uploaded to Cumulocity Configuration Management.

In the plugin configuration, the `type` values (for example, `pi_datapoints`) are the Cumulocity configuration type identifiers mapped to the local file paths; they are not the filenames themselves.

```toml
[[files]]
path = "/etc/tedge/tedge.toml"
type = "tedge.toml"

[[files]]
group = "tedge"
mode = 444
path = "/etc/tedge/plugins/tedge-log-plugin.toml"
type = "tedge-log-plugin"
user = "tedge"

[[files]]
path = "/etc/tedge/c8y/datapoints.json"
type = "pi_datapoints"
user = "tedge"
group = "tedge"
mode = 0o644

[[files]]
path = "/etc/tedge/c8y/pi_config.json"
type = "pi_config"
user = "tedge"
group = "tedge"
mode = 0o640
```

1. Push `tedge-configuration-plugin` configuration file first.
2. Then push:
   - `pi_config`
   - `pi_datapoints`

⚠️ The configuration plugin must be applied before deploying dependent configuration files.


## Prerequisites

Make sure the following are in place before proceeding:

- thin-edge installed and connected to the Cumulocity tenant — see [scripts/README.md](scripts/README.md) for the automated setup script
- Device registered as a thin-edge device
- Docker installed on the target VM
- Container group feature installed on the device
- Mosquitto broker exposed for external communication
- `unzip` package installed on the device

> **Automated setup:** `scripts/tedge_setup.sh` handles thin-edge installation, device registration (via OTP), certificate download, MQTT configuration, and PI connector prerequisites in a single command. Accepts Cumulocity domain with or without the `https://` prefix. See [scripts/README.md](scripts/README.md) for full instructions.

### thin-edge MQTT configuration

The PI connector runs inside a Docker container and connects to the Mosquitto broker on the host via `host.containers.internal`. By default Mosquitto only listens on `localhost`, which blocks this connection. Run the following **once** after thin-edge is installed and before starting the PI connector:

```bash
# Allow Mosquitto to accept connections from Docker containers
sudo tedge config set mqtt.bind.address 0.0.0.0

# Apply the change by reconnecting thin-edge to Cumulocity
sudo tedge reconnect c8y
```

> These steps are automated by `scripts/tedge_setup.sh install` — see [scripts/README.md](scripts/README.md).

---

## Build Instructions

### Option 1: Download Prebuilt Release (Recommended)

Download the latest stable build directly from GitHub Releases:

**Latest Release:**  
[repo release](https://github.com/Cumulocity-IoT/thin-edge-aveva-pi-connector/releases)

Two release assets are published for each version:

| Asset | Description |
|---|---|
| `pi_historian_connector_<version>_online.zip` | Standard release — Docker image is pulled from Docker Hub on first run. Requires internet on the target device. |
| `pi_historian_connector_<version>_offline.zip` | Offline release — includes a pre-built Docker image tarball and pip wheels. No internet required on the target device. |

---

### Option 2: Build From Source

#### Build both ZIPs using the build script

Running `build_release.sh` produces **both** the online and offline ZIPs in a single pass:

```bash
git clone https://github.com/Cumulocity-IoT/thin-edge-aveva-pi-connector.git
cd thin-edge-aveva-pi-connector

chmod +x scripts/build_release.sh
scripts/build_release.sh 0.0.4
```

The script will:
1. Create `pi_historian_connector_v0.0.4_online.zip` — source files only
2. Download pip dependency wheels for Python 3.11 / Linux x86_64
3. Build the Docker image locally
4. Export the image as a `.tar.gz` tarball
5. Generate an offline `docker-compose.yaml` with the correct image reference
6. Bundle everything into `pi_historian_connector_v0.0.4_offline.zip`
7. Clean up all temporary files and staging directories

The release CI (`release.yml`) runs the same script automatically on every tag push (`v*`) and can also be triggered manually via **Actions → Build and Upload ZIP Release → Run workflow**.

---

## Deploy Using Prebuilt Release (Standard / Online)

1. Download the `*_online.zip` from [releases](https://github.com/Cumulocity-IoT/thin-edge-aveva-pi-connector/releases)

2. Unzip the package:
   ```bash
   unzip pi_historian_connector_v<version>_online.zip -d pi_historian_connector_v<version>
   cd pi_historian_connector_v<version>
   ```

3. Start the service (Docker will pull the image on first run):
   ```bash
   docker compose up -d
   ```

---

## Offline Installation

Use this procedure when the target device has **no internet access**. Download the `*_offline.zip` from [releases](https://github.com/Cumulocity-IoT/thin-edge-aveva-pi-connector/releases) or build it using `scripts/build_release.sh`.

### Prerequisites on the target device

- Docker installed and running
- `unzip` installed
- `docker compose` (v2) or `docker-compose` (v1) available

### Step 1 — Transfer the release bundle

Copy the `*_offline.zip` to the target device via USB, SCP, or any other transfer method:

```bash
scp pi_historian_connector_v0.0.4_offline.zip user@<device-ip>:/home/user/
```

### Step 2 — Unzip the bundle

```bash
unzip pi_historian_connector_v0.0.4_offline.zip -d pi_historian_connector_v0.0.4
cd pi_historian_connector_v0.0.4
```

The zip extracts files directly at the top level:

```
docker-compose.yaml                            # offline service definition (pre-configured)
logging.conf                                   # logging configuration (writes to /etc/tedge/c8y/logs/)
requirements.txt                               # Python dependencies (reference only)
pi_historian_connector_0.0.4.tar.gz            # pre-built Docker image tarball
packages/                                      # pip wheels for offline pip install
  ├── requests-*.whl
  ├── urllib3-*.whl
  ├── paho_mqtt-*.whl
  ├── watchdog-*.whl
  └── ...
```

### Step 3 — Load the Docker image

```bash
docker load < pi_historian_connector_0.0.4.tar.gz
```

Verify the image was loaded:

```bash
docker images | grep pi_historian_connector
```

Expected output:
```
pi_historian_connector   0.0.4   <id>   ...
```

### Step 4 — Ensure config files are in place

The service mounts `/etc/tedge/c8y` for both configuration and log output. Make sure the following files exist on the device before starting:

```
/etc/tedge/c8y/pi_config.json
/etc/tedge/c8y/datapoints.json
```

Application logs are written to `/etc/tedge/c8y/logs/pi_historian.log` on the host (rotated daily, 3 days retained).

> These config files are created automatically by `scripts/tedge_setup.sh install` — see [scripts/README.md](scripts/README.md).

See the [Configuration](#configuration) section for the expected file formats.

### Step 5 — Start the service

```bash
docker compose up -d
```

### Step 6 — Verify it is running

```bash
docker compose ps
docker compose logs -f
```

### Stopping the service

```bash
docker compose down
```

---

## Production Deployment via Cumulocity

### 1. Upload the Zipped Archive

- Go to the **Cumulocity Software Management UI**
- Upload the `.zip` file
- Set the **Software Type** to `container-group`

### 2. Deploy to thin-edge Device

- Navigate to the target **thin-edge device** in Cumulocity Device Management
- Go to **Software > Install**
- Select the uploaded software package and version

The container will be deployed and started automatically on the thin-edge VM.


## Batch Assignment

PI tags are grouped into batches before being published to MQTT. Each batch is published as a separate measurement type (`pi_historianMeasurement_batch<N>`) and metadata topic (`pi_historianMetadata_batch<N>`).

### How batch IDs are assigned

On first run (or if `tag_batches.json` is missing), the number of batches is computed as:

```
num_batches = ceil(total_tags / BATCH_SIZE)   # BATCH_SIZE default: 60
```

Each tag is then assigned a batch ID using a deterministic hash:

```
batch_id = md5(tag_name) % num_batches
```

The resulting mapping is saved to `/etc/tedge/c8y/tag_batches.json` alongside the `_num_batches` value used.

### Stability guarantees

| Scenario | Result |
|---|---|
| Tag added to `datapoints.json` | New tag hashed with the **stored** `_num_batches`; all existing tags keep their batch ID |
| Tag removed from `datapoints.json` | Ledger entry is retained; re-adding the tag later restores the same batch ID |
| `tag_batches.json` deleted accidentally | Regenerated automatically on next startup; assignments are **identical** if `datapoints.json` has not changed |
| `datapoints.json` grows significantly across a `BATCH_SIZE` boundary after file deletion | `num_batches` is recomputed from the new list length; assignments regenerate with the new divisor |

> **Do not modify `_num_batches` manually.** Changing it causes all tags to be remapped to new batch IDs, creating orphaned topics in Cumulocity.

### Automatic backups

Every time `tag_batches.json` is updated, the previous version is backed up automatically before the new content is written:

- **Backup location:** `/etc/tedge/c8y/tag_batches_backups/`
- **Naming format:** `tag_batches_YYYYMMDD_HHMMSS.json` (UTC timestamp)
- **Retention:** last 10 backups are kept; older ones are deleted automatically

```
/etc/tedge/c8y/tag_batches_backups/
  tag_batches_20260828_083000.json
  tag_batches_20260828_091500.json
  tag_batches_20260828_102300.json
  ...  (max 10 files)
```

To restore a backup, copy the desired file back to `/etc/tedge/c8y/tag_batches.json` and restart the service.

### Supported operations

The following operations are safe and fully supported at any point in the service lifecycle.

| Operation | How | What happens |
|---|---|---|
| **Add new PI tags** | Append entries to `datapoints.json` | Each new tag is hashed and assigned to a batch immediately on the next file-change event. All existing tag-to-batch assignments stay unchanged. |
| **Remove PI tags** | Delete entries from `datapoints.json` | The tag stops being polled and published. Its ledger entry is kept in `tag_batches.json`, so re-adding the same tag name later restores the exact same batch ID. |
| **Rebalance / resize batches** | Delete `tag_batches.json` while the full desired tag list is already in `datapoints.json`, then restart | `num_batches` is recomputed from the current list length, giving an evenly distributed layout. Do this only intentionally — all tags move to new batch IDs and existing Cumulocity measurement topics become orphans. |
| **Restore a previous batch layout** | Copy the desired file from `/etc/tedge/c8y/tag_batches_backups/` back to `/etc/tedge/c8y/tag_batches.json`, then restart | The service picks up the restored ledger and resumes publishing under the batch IDs it contained. |
| **Change poll interval** | Update `POLL_INTERVAL` in `pi_config.json` and push via Cumulocity | Takes effect on the next configuration reload without a restart. |
| **Scale the tag list** | Keep adding tags to `datapoints.json` | Each tag is assigned via the stored `_num_batches` divisor. Batches may grow beyond `BATCH_SIZE` over time; rebalance when needed (see row above). |
| **Inspect current batch layout** | Read `/etc/tedge/c8y/tag_batches.json` | Shows the batch ID for every known tag and the `_num_batches` divisor in use. |

### Limitations and what not to do

| # | What not to do | Why |
|---|---|---|
| 1 | **Do not change `BATCH_SIZE` after initial deployment** | `BATCH_SIZE` determines `num_batches` on first run. Changing it and then deleting `tag_batches.json` causes a different `num_batches`, remapping all tags to new batch IDs and orphaning existing Cumulocity topics. |
| 2 | **Do not modify `_num_batches` in `tag_batches.json` manually** | `_num_batches` is the frozen divisor used by the hash formula. Any change causes every tag to resolve to a different batch ID on the next restart. |
| 3 | **Do not manually edit tag entries in `tag_batches.json`** | Incorrect or duplicate entries will cause tags to be published under the wrong batch topic or skipped entirely. Use backups to restore if the file is corrupted. |
| 4 | **Do not rename a PI tag without updating the ledger** | A renamed tag is treated as a completely new tag — it is assigned a new batch ID via the hash. The old entry remains in the ledger as an orphan and the old Cumulocity topic will stop receiving data. |
| 5 | **Do not delete `tag_batches.json` after significantly growing the tag list** | If `len(tags)` has crossed a `BATCH_SIZE` boundary since the file was first generated, deletion triggers a recompute of `num_batches` with a different value, remapping all existing tags. |
| 6 | **Do not expect batch sizes to stay exactly at `BATCH_SIZE` after repeated tag additions** | `_num_batches` is frozen after first run. As new tags accumulate, some batches will exceed `BATCH_SIZE`. To rebalance, delete `tag_batches.json` with the current full tag list in place so it is regenerated with an updated `num_batches`. |
| 7 | **Do not push `tag_batches.json` via Cumulocity Configuration Management** | The file is managed entirely by the application. Pushing it from Cumulocity would trigger the file watcher and reload datapoints, but the file would be overwritten again on the next tag list change. |

---

## MIT License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for full details.

## Disclaimer
AVEVA, PI System, and PI Server are trademarks or registered trademarks of AVEVA Group plc or its subsidiaries in the U.S. and other countries. This project is an independent open-source initiative and is not affiliated with, sponsored by, or endorsed by AVEVA.

-------------------------------------------
These tools are provided as-is and without warranty or support. They do not constitute part of the Cumulocity product suite. Users are free to use, fork and modify them, subject to the license agreement. While Cumulocity GmbH welcomes contributions, we cannot guarantee to include every contribution in the master project.

----------------------------------
You can find additional information in the [Cumulocity Community](https://community.cumulocity.com/).
