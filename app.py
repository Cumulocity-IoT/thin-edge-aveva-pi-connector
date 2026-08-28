import os
import math
import time
import json
import random
import shutil
import base64
import hashlib
import logging
import logging.config
import urllib3
import requests
import base64
from datetime import datetime, timezone, timedelta
from typing import Optional, Dict, Any, Iterable, List
from logging.handlers import RotatingFileHandler
from requests.auth import HTTPBasicAuth
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
import paho.mqtt.client as mqtt
from paho.mqtt.client import CallbackAPIVersion

# Disable SSL warnings
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Setup Logging
LOG_DIR = "/etc/tedge/c8y/logs"
os.makedirs(LOG_DIR, exist_ok=True)
logging.config.fileConfig('logging.conf')
log = logging.getLogger(__name__)
log.info("Log rotation setup successfully!")

# Configuration
CONFIG = {
    "PI_DATAPOINTS_FILE": "/etc/tedge/c8y/datapoints.json",
    "MQTT_BROKER": "host.containers.internal",
    "MQTT_PORT": 1883,
    "HTTP_PORT": 8001,
    "MQTT_MEASUREMENT_TOPIC": "c8y/measurement/measurements/create",
    "MQTT_INVENTORY_TOPIC": "te/device/main///twin",
    "PI_CONFIG": "/etc/tedge/c8y/pi_config.json",
    "PI_DEVICE_CONFIG": "/etc/tedge/c8y/pihistorian_device_config.json",
    "PI_URL": "https://{{PI_URL}}/piwebapi",
    "PI_HEADERS": {"content-type": "application/json"},
    "QUERY_FILTER": "?query=PointType:Float32&namefilter=",
    "RECORDING_AT_TIME": "?time=",
    "POLL_INTERVAL": 60,
    "MEASUREMENT_TYPE": "pi_historianMeasurement",
    "METADATA_TYPE": "pi_historianMetadata",
    "BATCH_SIZE": 60,
    "MQTT_PUBLISH_TIMEOUT": 1,
    "BATCH_ASSIGNMENT_FILE": "/etc/tedge/c8y/tag_batches.json"
}

# Globals
pi_config: Dict[str, Any] = {}
datapoint_list: Iterable[str] = []
tag_batches: Dict[int, List[str]] = {}
mqtt_client: Optional[mqtt.Client] = None
pi_client = None
pi_auth = None
metadata_publish_count: int = 0
measurement_publish_count: int = 0


# ---- Utility Functions ----
def read_json_file(file_path: str) -> Dict[str, Any]:
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        log.error(f"Failed to read JSON from {file_path}: {e}")
        return {}

def init_pi_session():
    global pi_client, pi_auth
    pi_client = requests.Session()

    encoded_password = CONFIG.get("PI_PASSWORD", "")
    decoded_password = ""
    if encoded_password:
        try:
            decoded_password = base64.b64decode(encoded_password, validate=True).decode("utf-8")
        except Exception as e:
            log.error(f"Invalid PI_PASSWORD encoding. Using empty password. Error: {e}")
    else:
        log.warning("PI_PASSWORD is missing. PI authentication may fail.")

    pi_auth = HTTPBasicAuth(CONFIG.get("PI_USER", ""), decoded_password)

def load_configuration():
    global pi_config
    pi_config = read_json_file(CONFIG["PI_CONFIG"])
    CONFIG.update(pi_config)
    if not pi_config:
        log.error("No valid pi_config.json found, using existing configuration.")
    init_pi_session()
    log.info("Configuration loaded successfully. PI_URL=%s, POLL_INTERVAL=%s", CONFIG.get("PI_URL"), CONFIG.get("POLL_INTERVAL"))


def load_datapoints():
    global datapoint_list, tag_batches
    raw_datapoints = read_json_file(CONFIG["PI_DATAPOINTS_FILE"])
    if isinstance(raw_datapoints, list):
        datapoint_list = raw_datapoints
    else:
        datapoint_list = []
        if raw_datapoints:
            log.error("Invalid datapoints format. Expected JSON array of tag names.")

    if not datapoint_list:
        log.warning("Empty datapoints file.")
    tag_batches = assign_batches(datapoint_list)
    log.info("Assigned %d tags to %d batches.", len(datapoint_list), len(tag_batches))
    update_tag_metadata()

def connect_mqtt():
    global mqtt_client
    client_id = f"python-mqtt-{random.randint(0, 1000)}"
    mqtt_client = mqtt.Client(client_id=client_id, callback_api_version=CallbackAPIVersion.VERSION2)

    def on_connect(client, userdata, flags, rc, properties=None):
        if rc == mqtt.MQTT_ERR_SUCCESS:
            log.info("Connected to MQTT broker.")
        else:
            log.error(f"MQTT connection failed, rc={rc}")

    mqtt_client.on_connect = on_connect
    mqtt_client.connect(CONFIG["MQTT_BROKER"], CONFIG["MQTT_PORT"], 60)
    mqtt_client.loop_start()

def publish_msg(topic: str, msg: dict):
    if mqtt_client:
        timeout = CONFIG.get("MQTT_PUBLISH_TIMEOUT", 1)
        result = mqtt_client.publish(topic, msg)
        result.wait_for_publish(timeout=timeout)
        size_kb = len(msg.encode("utf-8")) / 1024 if isinstance(msg, str) else len(str(msg).encode("utf-8")) / 1024
        if not result.is_published():
            log.warning("MQTT publish timed out after %ss on topic: %s (%.2f KB)", timeout, topic, size_kb)
        else:
            log.info("Published on topic: %s (%.2f KB)", topic, size_kb)
    else:
        log.error("MQTT client is not connected.")

def get_datapoints_link() -> Optional[str]:
    try:
        response = pi_client.get(f"{CONFIG['PI_URL']}/dataservers", auth=pi_auth, headers=CONFIG["PI_HEADERS"], verify=False)
        response.raise_for_status()
        return response.json().get("Items", [{}])[0].get("Links", {}).get("Points")
    except Exception as e:
        log.error(f"Error retrieving datapoints link: {e}")
        return None

def get_pi_datapoints(datapoints_link: str, name_filter: str) -> Optional[Dict[str, Any]]:
    try:
        url = f"{datapoints_link}{CONFIG['QUERY_FILTER']}{name_filter}"
        response = pi_client.get(url, auth=pi_auth, headers=CONFIG["PI_HEADERS"], verify=False)
        response.raise_for_status()
        item = response.json().get("Items", [{}])[0]
        return {
            "Descriptor": item.get("Descriptor"),
            "EngineeringUnits": item.get("EngineeringUnits"),
            "RecordedData": item.get("Links", {}).get("RecordedData")
        }
    except Exception as e:
        log.error(f"Failed to get PI datapoint {name_filter}: {e}")
        return None

def get_recorded_data(url: str, timestamp: str) -> Optional[float]:
    try:
        full_url = f"{url}attime{CONFIG['RECORDING_AT_TIME']}{timestamp}"
        response = pi_client.get(full_url, auth=pi_auth, headers=CONFIG["PI_HEADERS"], verify=False)
        response.raise_for_status()
        return response.json().get("Value")
    except Exception as e:
        log.error(f"Error fetching recorded data: {e}")
        return None


# ---- File Watcher ----
class ConfigFileHandler(FileSystemEventHandler):
    def __init__(self, watched_files):
        self.watched_files = set(map(os.path.realpath, watched_files))

    def process_file(self, path: str, event_type: str):
        real_path = os.path.realpath(path)
        if real_path == os.path.realpath(CONFIG["PI_CONFIG"]):
            log.info(f"Reloading config ({event_type}) from: {real_path}")
            load_configuration()
        elif real_path == os.path.realpath(CONFIG["PI_DATAPOINTS_FILE"]):
            log.info(f"Reloading datapoints ({event_type}) from: {real_path}")
            load_datapoints()

    def on_modified(self, event):
        if not event.is_directory:
            self.process_file(event.src_path, event.event_type.upper())

    def on_moved(self, event):
        if not event.is_directory:
            self.process_file(event.dest_path, event.event_type.upper())

    def on_created(self, event):
        if not event.is_directory:
            self.process_file(event.src_path, event.event_type.upper())

def start_file_watcher() -> Optional[object]:
    handler = ConfigFileHandler([CONFIG["PI_CONFIG"], CONFIG["PI_DATAPOINTS_FILE"]])
    observer = Observer()
    common_path = os.path.commonpath([os.path.dirname(CONFIG["PI_CONFIG"]), os.path.dirname(CONFIG["PI_DATAPOINTS_FILE"])])
    if not os.path.isdir(common_path):
        log.error(f"Watcher path does not exist: {common_path}. File watching disabled.")
        return None
    observer.schedule(handler, common_path, recursive=False)
    observer.start()
    return observer

def update_tag_metadata():
    global metadata_publish_count
    try:
        if not tag_batches:
            log.warning("Skipping metadata update: no datapoints loaded.")
            return

        link = get_datapoints_link()
        if not link:
            log.error("Skipping metadata update: unable to connect to PI or resolve datapoints link.")
            return

        for batch_id, tags in tag_batches.items():
            data_series = {}
            for key in tags:
                dp = get_pi_datapoints(link, key)
                if not dp:
                    log.error("Skipping metadata for '%s': PI query failed.", key)
                    continue
                data_series[key.replace(".", "_")] = {"description": dp.get("Descriptor")}

            metadata_publish_count += 1
            payload = {
                "tags": data_series,
                "lastUpdated": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')
            }
            topic = f"{CONFIG['MQTT_INVENTORY_TOPIC']}/{CONFIG['METADATA_TYPE']}_batch{batch_id}"
            publish_msg(topic, json.dumps(payload, indent=4))
            log.info("Metadata published for batch %d (%d tags) [metadata_publish_count=%d].", batch_id, len(tags), metadata_publish_count)
    except Exception as e:
        log.error("Metadata update failed: %s", e)

def classify_value(value_str):
    # Try parsing as float (numerical)
    try:
        float(value_str)
        return "Numerical"
    except (ValueError, TypeError):
        pass

    # Try parsing as JSON (e.g., dict)
    try:
       if isinstance(value_str, dict):
            return "JSON"
    except json.JSONDecodeError:
        pass

    return "Unknown"

def backup_batch_assignments():
    src = CONFIG["BATCH_ASSIGNMENT_FILE"]
    if not os.path.exists(src):
        return
    backup_dir = os.path.join(os.path.dirname(src), "tag_batches_backups")
    os.makedirs(backup_dir, exist_ok=True)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    dst = os.path.join(backup_dir, f"tag_batches_{timestamp}.json")
    try:
        shutil.copy2(src, dst)
        backups = sorted(f for f in os.listdir(backup_dir) if f.startswith("tag_batches_") and f.endswith(".json"))
        for old in backups[:-10]:
            os.remove(os.path.join(backup_dir, old))
        log.info("Backup saved: %s (%d/10 backups retained).", dst, min(len(backups), 10))
    except Exception as e:
        log.error("Failed to backup tag_batches.json: %s", e)

def save_batch_assignments(ledger: Dict[str, Any]):
    backup_batch_assignments()
    path = CONFIG["BATCH_ASSIGNMENT_FILE"]
    try:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(ledger, f, indent=4)
        log.info("Saved batch assignments (%d tags) to %s.", len(ledger) - 1, path)
    except Exception as e:
        log.error("Failed to save batch assignments to %s: %s", path, e)

def assign_batches(tags: list) -> Dict[int, List[str]]:
    batch_size = CONFIG.get("BATCH_SIZE", 60)
    ledger: Dict[str, Any] = read_json_file(CONFIG["BATCH_ASSIGNMENT_FILE"])

    if ledger and "_num_batches" in ledger:
        # Reuse the stored divisor so existing batch IDs never shift
        num_batches = ledger["_num_batches"]
        changed = False
    else:
        # First run or file was deleted: compute from current tag list
        num_batches = math.ceil(len(tags) / batch_size) if tags else 1
        ledger["_num_batches"] = num_batches
        changed = True

    for tag in tags:
        if tag not in ledger:
            ledger[tag] = int(hashlib.md5(tag.encode()).hexdigest(), 16) % num_batches
            changed = True

    if changed:
        save_batch_assignments(ledger)

    batches: Dict[int, List[str]] = {}
    for tag in tags:
        bid = ledger[tag]
        batches.setdefault(bid, []).append(tag)

    return batches

# ---- Main Logic ----
def main():
    global measurement_publish_count
    try:
        load_configuration()
    except Exception as e:
        log.error(f"Startup configuration load failed: {e}")

    try:
        connect_mqtt()
    except Exception as e:
        log.error(f"MQTT initialization failed: {e}")

    try:
        start_file_watcher()
    except Exception as e:
        log.error(f"File watcher initialization failed: {e}")

    try:
        load_datapoints()
    except Exception as e:
        log.error(f"Datapoints load failed: {e}")

    while True:
        try:
            measurement_publish_count = 0
            metadata_publish_count = 0
            log.info("Starting data collection cycle... [measurement_publish_count=%d]", measurement_publish_count)
            link = get_datapoints_link()

            if not link:
                time.sleep(CONFIG["POLL_INTERVAL"])
                continue

            timestamp = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')

            for batch_id, tags in tag_batches.items():
                batch_data = {}
                batch_type = f"{CONFIG['MEASUREMENT_TYPE']}_batch{batch_id}"

                for key in tags:
                    dp = get_pi_datapoints(link, key)
                    if not dp or not dp.get("RecordedData"):
                        continue

                    value = get_recorded_data(dp["RecordedData"], timestamp)
                    if value is None:
                        continue

                    series = key.replace(".", "_")
                    unit = dp.get("EngineeringUnits", "")

                    value_type = classify_value(value)
                    if value_type == "JSON" and isinstance(value, dict):
                        log.info("JSON value for key: %s, value: %s", key, value)
                        batch_data[series] = {
                            "value": value.get("Value"),
                            "unit": unit,
                            "stringValue": value.get("Name")
                        }
                    else:
                        batch_data[series] = {"value": value, "unit": unit}

                if not batch_data:
                    log.info("Batch %d: no data collected, skipping publish.", batch_id)
                    continue

                payload = {
                    "type": batch_type,
                    "time": timestamp,
                    batch_type: batch_data
                }
                measurement_publish_count += 1
                publish_msg(CONFIG["MQTT_MEASUREMENT_TOPIC"], json.dumps(payload, indent=4))
                log.info("Published batch %d (%d series) [measurement_publish_count=%d].", batch_id, len(batch_data), measurement_publish_count)

            time.sleep(CONFIG["POLL_INTERVAL"])

        except Exception as e:
            log.error(f"Main loop error: {e}")
            time.sleep(CONFIG["POLL_INTERVAL"])

if __name__ == "__main__":
    main()
