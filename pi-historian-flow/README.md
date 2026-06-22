# pi-historian-flow

A [thin-edge.io](https://thin-edge.io) flow that polls an **AVEVA PI Web API** server every 60 seconds and publishes measurements and metadata to **Cumulocity IoT** via MQTT.

## Architecture

```
[scripts/poll-pi.sh]  ──curl──▶  PI Web API
        │
        │  stdout: TOPIC<TAB>JSON_PAYLOAD  (one line per message;
        │          multiple lines emitted when chunking kicks in)
        ▼
[tedge-flows input.process]   interval = 60s
        │
        │  Message { topic: "pi-historian/data", payload: line }
        ▼
[dist/main.js]  onMessage()   ── splits on TAB, re-emits on correct topic
        │
        ├──▶  c8y/measurement/measurements/create   { measurement chunk }  ×N
        └──▶  te/device/main///twin/pi_historianMetadata  { tag metadata chunk }  ×N
```

The tedge-flows JavaScript runtime (QuickJS) has no outbound networking, so all HTTP calls are handled by the shell script using `curl`. The JS bundle acts as a pure message router — it receives each line from the script and routes it to the correct MQTT topic.

## Prerequisites

| Requirement | Notes |
|---|---|
| thin-edge.io ≥ 2.0 | With `tedge-mapper-c8y` running |
| `curl` | Standard on most Linux distros |
| `jq` | `apt install jq` |
| Node.js + npm | Build-time only — not needed at runtime |

## Configuration

Copy the template and fill in your values:

```bash
cp params.toml.template params.toml
```

`params.toml`:

```toml
# Base URL of the PI Web API server
pi_url = "https://your-pi-server/piwebapi"

# Credentials — base64-encode your password:
#   echo -n 'mypassword' | base64
pi_user     = "piuser"
pi_password = "base64encodedpassword"

# PI tag names to poll
datapoints = ["REACTOR01.TEMP", "PUMP02.FLOW", "COMPRESSOR.PRESSURE"]

# Optional overrides (defaults shown)
measurement_type = "pi_historianMeasurement"
output_topic     = "c8y/measurement/measurements/create"
metadata_topic   = "te/device/main///twin"
query_filter     = "?query=PointType:Float32&namefilter="
debug            = false
```

### PI Web API query filter

`query_filter` is appended directly to the dataserver's Points link URL. The default restricts results to `Float32` points. Adjust if your tags use a different type (e.g. remove the `PointType:Float32` clause to match all types).

### SSL / self-signed certificates

If your PI Web API uses a self-signed certificate, add `-k` to the `curl` call in `scripts/poll-pi.sh`:

```bash
pi_get() {
    curl -skf \
        -H "Authorization: $AUTH" \
        ...
```

## Build

```bash
npm install
npm run build        # outputs dist/main.js
```

## Deploy

```bash
# Copy everything to the tedge flows directory
npm run deploy:local

# Reload the mapper to pick up the new flow
systemctl restart tedge-mapper-c8y
```

The deploy copies the full project (including `scripts/`, `dist/`, `flows.toml`, and `params.toml`) into `/etc/tedge/mappers/c8y/flows/pi-historian-flow/`.

## Undeploy

```bash
npm run undeploy:local
```

## Verify

Check the flow is running and the script is firing:

```bash
# Watch the mapper logs
journalctl -fu tedge-mapper-c8y | grep pi-historian

# Manually run the script (from the flow directory)
cd /etc/tedge/mappers/c8y/flows/pi-historian-flow
bash ./scripts/poll-pi.sh
```

A successful run prints at least two lines to stdout (more when chunking splits a large payload):

```
c8y/measurement/measurements/create	{"type":"pi_historianMeasurement","time":"...","pi_historianMeasurement":{...}}
c8y/measurement/measurements/create	{"type":"pi_historianMeasurement","time":"...","pi_historianMeasurement":{...}}
te/device/main///twin/pi_historianMetadata	{"tags":{...},"lastUpdated":"..."}
te/device/main///twin/pi_historianMetadata	{"tags":{...},"lastUpdated":"..."}
```

When there are only a few datapoints the output is one measurement line and one metadata line. Additional lines appear only when the tag count is large enough to exceed the 16 KB limit.

Enable `debug = true` in `params.toml` to log each tag's fetched value to stderr (visible in the mapper journal).

## Output format

### Measurements

Published to `c8y/measurement/measurements/create` every 60 seconds. When the full set of tags would produce a payload larger than 16 KB, the script emits multiple messages — each a self-contained measurement fragment sharing the same timestamp:

```json
{
  "type": "pi_historianMeasurement",
  "time": "2026-06-22T07:28:47Z",
  "pi_historianMeasurement": {
    "REACTOR01_TEMP":      { "value": 125.5, "unit": "degC" },
    "PUMP02_FLOW":         { "value": 42.1,  "unit": "m3/h" },
    "COMPRESSOR_PRESSURE": { "value": 8.3,   "unit": "bar"  }
  }
}
```

Tag names have dots replaced with underscores (PI convention → valid JSON key).

Tags returning a `SystemStateCode` object (e.g. motor state enumerations) include a `stringValue` field alongside the numeric `value`.

Tags that return non-numeric or unsupported values are silently skipped.

### Metadata

Published to `te/device/main///twin/pi_historianMetadata` on every poll cycle (idempotent). Large tag sets are split into multiple twin-update messages, each under 16 KB. Cumulocity thin-edge merges each partial update into the device managed object:

```json
{
  "tags": {
    "REACTOR01_TEMP": { "description": "Reactor 1 Inlet Temperature" },
    "PUMP02_FLOW":    { "description": "Feed Pump 2 Flow Rate" }
  },
  "lastUpdated": "2026-06-22T07:28:47Z"
}
```

## Project structure

```
pi-historian-flow/
├── flows.toml              # tedge-flows definition (input.process + JS step)
├── params.toml             # runtime config (gitignored — contains credentials)
├── params.toml.template    # checked-in defaults, safe to commit
├── scripts/
│   └── poll-pi.sh          # curl-based PI Web API poller
├── src/
│   └── main.ts             # JS message router (tab-split → MQTT topic)
├── dist/
│   └── main.js             # esbuild output — deployed to device
└── package.json
```

## Development notes

**Why a shell script instead of JS?**
The tedge-flows JavaScript runtime (QuickJS via rquickjs) intentionally exposes no networking APIs — only `console`, `crypto`, `TextEncoder`/`TextDecoder`, and a KV store. All HTTP calls must happen outside the JS sandbox. The `[input.process]` mechanism in `flows.toml` runs the shell script as a subprocess; its stdout lines are fed into the JS step as MQTT messages.

**Why compact JSON (`jq -c`)?**
`input.process` delivers each stdout line as a separate message. `jq` defaults to pretty-printed (multi-line) JSON, which would split a single payload across many messages. The `-c` flag forces single-line output, keeping each `TOPIC\tPAYLOAD` pair on one line.

**Why 16 KB chunks?**
The Cumulocity MQTT broker enforces a 16 KB maximum message size. When a polling cycle covers many PI tags, the combined measurement or twin-update JSON can exceed this limit. The script accumulates tags into a running chunk and flushes it as a separate MQTT message whenever the next tag would push the payload past 16 384 bytes. Measurement chunks and twin chunks are tracked independently, since the two payload structures have different per-entry overhead.
