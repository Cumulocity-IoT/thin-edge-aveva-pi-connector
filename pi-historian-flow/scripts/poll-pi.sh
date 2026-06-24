#!/usr/bin/env bash
# scripts/poll-pi.sh
#
# Polls AVEVA PI Web API and writes one line per result to stdout:
#   TOPIC<TAB>JSON_PAYLOAD
#
# Called by tedge-flows [input.process] every 60 s.
# Requires: bash, curl, jq
#
# Config is read from ../params.toml (sibling of this script's parent dir).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARAMS_FILE="${SCRIPT_DIR}/../params.toml"

# --- minimal params.toml reader ---
param_str() {
    grep -E "^[[:space:]]*$1[[:space:]]*=" "$PARAMS_FILE" 2>/dev/null \
        | head -1 \
        | sed -E "s/^[^=]*=[[:space:]]*['\"]?//; s/['\"][[:space:]]*(#.*)?$//"
}
param_arr() {
    grep -E "^[[:space:]]*$1[[:space:]]*=" "$PARAMS_FILE" 2>/dev/null \
        | head -1 \
        | sed -E "s/^[^=]*=[[:space:]]*\[//; s/\][[:space:]]*(#.*)?$//" \
        | tr ',' '\n' \
        | sed -E "s/^[[:space:]]*['\"]?//; s/['\"]?[[:space:]]*$//" \
        | grep -v '^[[:space:]]*$'
}

PI_CONFIG_FILE="/etc/tedge/c8y/pi_config.json"
if [[ -f "$PI_CONFIG_FILE" ]]; then
    PI_URL="$(jq -r '.PI_URL // empty' "$PI_CONFIG_FILE")"
    PI_USER="$(jq -r '.PI_USER // empty' "$PI_CONFIG_FILE")"
    PI_PASSWORD_B64="$(jq -r '.PI_PASSWORD // empty' "$PI_CONFIG_FILE")"
else
    PI_URL="$(param_str pi_url)"
    PI_USER="$(param_str pi_user)"
    PI_PASSWORD_B64="$(param_str pi_password)"
fi

QUERY_FILTER="$(param_str query_filter)"
MEASUREMENT_TYPE="$(param_str measurement_type)"
OUTPUT_TOPIC="$(param_str output_topic)"
METADATA_TOPIC="$(param_str metadata_topic)"
DEBUG="$(param_str debug)"

DATAPOINTS_FILE="/etc/tedge/c8y/datapoints.json"
if [[ -f "$DATAPOINTS_FILE" ]]; then
    mapfile -t DATAPOINTS < <(jq -r '.[]' "$DATAPOINTS_FILE" 2>/dev/null)
else
    mapfile -t DATAPOINTS < <(param_arr datapoints)
fi

if [[ -z "$PI_URL" || -z "$PI_USER" || ${#DATAPOINTS[@]} -eq 0 ]]; then
    echo "[pi-historian] Missing PI_URL, PI_USER, or empty datapoints" \
         "(checked ${PI_CONFIG_FILE} / ${DATAPOINTS_FILE} then params.toml)" >&2
    exit 0
fi

PI_PASSWORD="$(echo -n "$PI_PASSWORD_B64" | base64 --decode 2>/dev/null || echo "$PI_PASSWORD_B64")"
AUTH="Basic $(printf '%s:%s' "$PI_USER" "$PI_PASSWORD" | base64 | tr -d '\n')"
TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
MTYPE="${MEASUREMENT_TYPE:-pi_historianMeasurement}"

# Maximum MQTT payload size in bytes; payloads are split into chunks below this limit.
MAX_PAYLOAD_BYTES=16384

# --- helpers ---
pi_get() {
    curl -sf \
        -H "Authorization: $AUTH" \
        -H "Content-Type: application/json" \
        "$1"
}

urlencode() {
    local s="$1" out="" i c o
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9._~-]) out+="$c" ;;
            *) printf -v o '%%%02X' "'$c"; out+="$o" ;;
        esac
    done
    printf '%s' "$out"
}

emit_measurement() {
    local data="$1"
    [[ "$(echo "$data" | jq 'length')" -gt 0 ]] || return
    local payload
    payload="$(jq -cn \
        --arg  type "$MTYPE" \
        --arg  time "$TIMESTAMP" \
        --argjson data "$data" \
        '{"type":$type,"time":$time,($type):$data}')"
    printf '%s\t%s\n' "${OUTPUT_TOPIC:-c8y/measurement/measurements/create}" "$payload"
}

emit_twin() {
    local tags="$1"
    [[ "$(echo "$tags" | jq 'length')" -gt 0 ]] || return
    local payload
    payload="$(jq -cn \
        --arg  ts   "$TIMESTAMP" \
        --argjson tags "$tags" \
        '{"tags":$tags,"lastUpdated":$ts}')"
    printf '%s\t%s\n' \
        "${METADATA_TOPIC:-te/device/main///twin}/pi_historianMetadata" \
        "$payload"
}

# --- get dataserver points link ---
DATASERVERS="$(pi_get "${PI_URL}/dataservers")" || {
    echo "[pi-historian] curl failed reaching ${PI_URL}/dataservers" >&2
    exit 0
}
POINTS_LINK="$(echo "$DATASERVERS" | jq -r '.Items[0].Links.Points // empty')"
if [[ -z "$POINTS_LINK" ]]; then
    echo "[pi-historian] No Points link in dataservers response" >&2
    [[ "$DEBUG" == "true" ]] && echo "$DATASERVERS" >&2
    exit 0
fi

# --- collect per-tag data with 16 KB chunking ---
ENC_TS="$(urlencode "$TIMESTAMP")"
CHUNK_MDATA="{}"
CHUNK_MTAGS="{}"

for TAG in "${DATAPOINTS[@]}"; do
    KEY="${TAG//./_}"

    ENC_TAG="$(urlencode "$TAG")"
    META_RESP="$(pi_get "${POINTS_LINK}${QUERY_FILTER}${ENC_TAG}")" || {
        [[ "$DEBUG" == "true" ]] && echo "[pi-historian] meta fetch failed: $TAG" >&2
        continue
    }

    DESCRIPTOR="$(echo "$META_RESP" | jq -r '.Items[0].Descriptor       // ""')"
    UNITS="$(     echo "$META_RESP" | jq -r '.Items[0].EngineeringUnits  // ""')"
    REC_LINK="$(  echo "$META_RESP" | jq -r '.Items[0].Links.RecordedData // empty')"
    [[ -z "$REC_LINK" ]] && continue

    VAL_RESP="$(pi_get "${REC_LINK}attime?time=${ENC_TS}")" || {
        [[ "$DEBUG" == "true" ]] && echo "[pi-historian] value fetch failed: $TAG" >&2
        continue
    }

    VAL_TYPE="$(echo "$VAL_RESP" | jq -r '.Value | type')"
    case "$VAL_TYPE" in
        number)
            ENTRY="$(echo "$VAL_RESP" | jq -c --arg u "$UNITS" '{value:.Value, unit:$u}')"
            ;;
        object)
            # SystemStateCode: { Value: number, Name: string }
            ENTRY="$(echo "$VAL_RESP" | jq -c --arg u "$UNITS" \
                '{value:.Value.Value, unit:$u, stringValue:.Value.Name}')"
            ;;
        string)
            NUM="$(echo "$VAL_RESP" | jq -r '.Value')"
            if [[ "$NUM" =~ ^-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$ ]]; then
                ENTRY="$(jq -cn --argjson v "$NUM" --arg u "$UNITS" '{value:$v, unit:$u}')"
            else
                [[ "$DEBUG" == "true" ]] && \
                    echo "[pi-historian] skipping $TAG — non-numeric string: $NUM" >&2
                continue
            fi
            ;;
        *)
            [[ "$DEBUG" == "true" ]] && \
                echo "[pi-historian] skipping $TAG — unsupported type: $VAL_TYPE" >&2
            continue
            ;;
    esac

    # -- chunk measurement payload --
    NEW_MDATA="$(echo "$CHUNK_MDATA" | jq -c --arg k "$KEY" --argjson v "$ENTRY" '. + {($k):$v}')"
    CANDIDATE="$(jq -cn --arg type "$MTYPE" --arg time "$TIMESTAMP" --argjson data "$NEW_MDATA" \
        '{"type":$type,"time":$time,($type):$data}')"
    if [[ "${#CANDIDATE}" -gt "$MAX_PAYLOAD_BYTES" ]]; then
        emit_measurement "$CHUNK_MDATA"
        NEW_MDATA="$(jq -cn --arg k "$KEY" --argjson v "$ENTRY" '{($k):$v}')"
    fi
    CHUNK_MDATA="$NEW_MDATA"

    # -- chunk twin metadata payload --
    NEW_MTAGS="$(echo "$CHUNK_MTAGS" | jq -c --arg k "$KEY" --arg d "$DESCRIPTOR" \
        '. + {($k):{description:$d}}')"
    CANDIDATE="$(jq -cn --arg ts "$TIMESTAMP" --argjson tags "$NEW_MTAGS" \
        '{"tags":$tags,"lastUpdated":$ts}')"
    if [[ "${#CANDIDATE}" -gt "$MAX_PAYLOAD_BYTES" ]]; then
        emit_twin "$CHUNK_MTAGS"
        NEW_MTAGS="$(jq -cn --arg k "$KEY" --arg d "$DESCRIPTOR" '{($k):{description:$d}}')"
    fi
    CHUNK_MTAGS="$NEW_MTAGS"

    [[ "$DEBUG" == "true" ]] && echo "[pi-historian] $TAG → $ENTRY" >&2
done

# --- emit remaining chunks ---
emit_measurement "$CHUNK_MDATA"
emit_twin "$CHUNK_MTAGS"
