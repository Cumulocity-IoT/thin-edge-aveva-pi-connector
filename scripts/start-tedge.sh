#!/bin/bash
set -e

LOG_DIR="/var/log/tedge"
mkdir -p "$LOG_DIR"

stop_services() {
    echo "[tedge] Stopping services..."
    pkill -f mosquitto   2>/dev/null || true
    pkill -f tedge-mapper 2>/dev/null || true
    pkill -f tedge-agent  2>/dev/null || true
}

trap stop_services EXIT INT TERM

# Kill any existing instances
stop_services
sleep 1

# 1. Apply the mosquitto.conf fix
sudo tee /etc/mosquitto/mosquitto.conf << 'EOF'
listener 1883 0.0.0.0
allow_anonymous true
persistence true
persistence_location /var/lib/mosquitto/
log_dest stdout
EOF

echo "[tedge] Starting mosquitto..."
mosquitto -c /etc/mosquitto/mosquitto.conf \
          > "$LOG_DIR/mosquitto.log" 2>&1 &

# Wait until mosquitto is actually ready
for i in $(seq 1 10); do
    nc -z localhost 1883 2>/dev/null && break
    echo "[tedge] Waiting for mosquitto... ($i)"
    sleep 1
done

echo "[tedge] Starting tedge-mapper..."
tedge-mapper c8y > "$LOG_DIR/tedge-mapper.log" 2>&1 &

sleep 1

echo "[tedge] Starting tedge-agent..."
tedge-agent > "$LOG_DIR/tedge-agent.log" 2>&1 &

echo "[tedge] All services started."
echo "[tedge] Logs: $LOG_DIR/"
echo ""

# Keep the script alive and tail all logs together
tail -f "$LOG_DIR/mosquitto.log" \
        "$LOG_DIR/tedge-mapper.log" \
        "$LOG_DIR/tedge-agent.log"