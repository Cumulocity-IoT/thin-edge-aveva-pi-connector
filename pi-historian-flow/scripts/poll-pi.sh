#!/usr/bin/env bash
# scripts/poll-pi.sh
#
# Long-running poller for AVEVA PI Web API.
# Writes one line per message to stdout on each cycle:
#   TOPIC<TAB>JSON_PAYLOAD
#
# Runs as a continuous process under tedge-flows [input.process].
# PI connection fields (PI_URL, PI_USER, PI_PASSWORD, POLL_INTERVAL,
# RECORDING_AT_TIME) are read from /etc/tedge/c8y/pi_config.json on every
# cycle, so changes pushed from Cumulocity take effect without a restart.
#
# Requires: bash, curl, jq

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARAMS_FILE="${SCRIPT_DIR}/../params.toml"
PI_CONFIG_FILE="/etc/tedge/c8y/pi_config.json"
DATAPOINTS_FILE="/etc/tedge/c8y/datapoints.json"

MAX_PAYLOAD_BYTES=16384

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

# --- helpers ---
pi_get() {
    curl -sf --connect-timeout 5 --max-time 30 \
        -H "Authorization: $AUTH" \
        -H "Content-Type: application/json" \
        "$1"
}

bytecount() { printf '%s' "$1" | wc -c; }

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

# --- main polling loop ---
PREV_DATAPOINTS_KEY=""
while true; do

    # Read PI connection config — re-read every cycle so remote updates take effect
    if [[ -f "$PI_CONFIG_FILE" ]] && jq empty "$PI_CONFIG_FILE" 2>/dev/null; then
        PI_URL="$(            jq -r '.PI_URL             // empty'   "$PI_CONFIG_FILE")"
        PI_USER="$(           jq -r '.PI_USER            // empty'   "$PI_CONFIG_FILE")"
        PI_PASSWORD_B64="$(   jq -r '.PI_PASSWORD        // empty'   "$PI_CONFIG_FILE")"
        POLL_INTERVAL="$(     jq -r '.POLL_INTERVAL      // 60'      "$PI_CONFIG_FILE")"
        RECORDING_AT_TIME="$( jq -r '.RECORDING_AT_TIME // "?time="' "$PI_CONFIG_FILE")"
    else
        [[ -f "$PI_CONFIG_FILE" ]] && \
            echo "[pi-historian] WARNING: $PI_CONFIG_FILE contains invalid JSON — falling back to params.toml" >&2
        PI_URL="$(param_str pi_url)"
        PI_USER="$(param_str pi_user)"
        PI_PASSWORD_B64="$(param_str pi_password)"
        POLL_INTERVAL=60
        RECORDING_AT_TIME="?time="
    fi

    QUERY_FILTER="$(param_str query_filter)"
    MEASUREMENT_TYPE="$(param_str measurement_type)"
    OUTPUT_TOPIC="$(param_str output_topic)"
    METADATA_TOPIC="$(param_str metadata_topic)"
    DEBUG="$(param_str debug)"

    # Read datapoints — re-read every cycle so remote updates take effect
    if [[ -f "$DATAPOINTS_FILE" ]]; then
        mapfile -t DATAPOINTS < <(jq -r '.[]' "$DATAPOINTS_FILE" 2>/dev/null)
    else
        mapfile -t DATAPOINTS < <(param_arr datapoints)
    fi

    DATAPOINTS_KEY="$(printf '%s\n' "${DATAPOINTS[@]}" | sort)"
    [[ "$DATAPOINTS_KEY" != "$PREV_DATAPOINTS_KEY" ]] && TWIN_CHANGED=true || TWIN_CHANGED=false

    if [[ -z "$PI_URL" || -z "$PI_USER" || ${#DATAPOINTS[@]} -eq 0 ]]; then
        echo "[pi-historian] Missing PI_URL, PI_USER, or empty datapoints" \
             "(checked ${PI_CONFIG_FILE} / ${DATAPOINTS_FILE} then params.toml)" >&2
        sleep "${POLL_INTERVAL:-60}"
        continue
    fi

    PI_PASSWORD="$(echo -n "$PI_PASSWORD_B64" | base64 --decode 2>/dev/null || echo "$PI_PASSWORD_B64")"
    AUTH="Basic $(printf '%s:%s' "$PI_USER" "$PI_PASSWORD" | base64 | tr -d '\n')"
    TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    MTYPE="${MEASUREMENT_TYPE:-pi_historianMeasurement}"

    # --- get dataserver points link ---
    DATASERVERS="$(pi_get "${PI_URL}/dataservers")" || {
        echo "[pi-historian] curl failed reaching ${PI_URL}/dataservers" >&2
        sleep "${POLL_INTERVAL:-60}"
        continue
    }
    POINTS_LINK="$(echo "$DATASERVERS" | jq -r '.Items[0].Links.Points // empty')"
    if [[ -z "$POINTS_LINK" ]]; then
        echo "[pi-historian] No Points link in dataservers response" >&2
        [[ "$DEBUG" == "true" ]] && echo "$DATASERVERS" >&2
        sleep "${POLL_INTERVAL:-60}"
        continue
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

        VAL_RESP="$(pi_get "${REC_LINK}attime${RECORDING_AT_TIME}${ENC_TS}")" || {
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
        if [[ "$(bytecount "$CANDIDATE")" -gt "$MAX_PAYLOAD_BYTES" ]]; then
            emit_measurement "$CHUNK_MDATA"
            NEW_MDATA="$(jq -cn --arg k "$KEY" --argjson v "$ENTRY" '{($k):$v}')"
        fi
        CHUNK_MDATA="$NEW_MDATA"

        # -- chunk twin metadata payload --
        if [[ "$TWIN_CHANGED" == true ]]; then
            NEW_MTAGS="$(echo "$CHUNK_MTAGS" | jq -c --arg k "$KEY" --arg d "$DESCRIPTOR" \
                '. + {($k):{description:$d}}')"
            CANDIDATE="$(jq -cn --arg ts "$TIMESTAMP" --argjson tags "$NEW_MTAGS" \
                '{"tags":$tags,"lastUpdated":$ts}')"
            if [[ "$(bytecount "$CANDIDATE")" -gt "$MAX_PAYLOAD_BYTES" ]]; then
                emit_twin "$CHUNK_MTAGS"
                NEW_MTAGS="$(jq -cn --arg k "$KEY" --arg d "$DESCRIPTOR" '{($k):{description:$d}}')"
            fi
            CHUNK_MTAGS="$NEW_MTAGS"
        fi

        [[ "$DEBUG" == "true" ]] && echo "[pi-historian] $TAG → $ENTRY" >&2
    done

    # --- emit remaining chunks ---
    emit_measurement "$CHUNK_MDATA"
    if [[ "$TWIN_CHANGED" == true ]]; then
        if emit_twin "$CHUNK_MTAGS"; then
            PREV_DATAPOINTS_KEY="$DATAPOINTS_KEY"
        fi
    fi

    sleep "${POLL_INTERVAL:-60}"
done
