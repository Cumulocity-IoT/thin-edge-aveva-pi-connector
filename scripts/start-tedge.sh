#!/bin/bash
set -e

LOG_DIR="/var/log/tedge"
sudo mkdir -p "$LOG_DIR"
sudo chown "$(id -u):$(id -g)" "$LOG_DIR"

stop_services() {
    echo "[tedge] Stopping services..."
    sudo pkill -f mosquitto   2>/dev/null || true
    sudo pkill -f tedge-mapper 2>/dev/null || true
    sudo pkill -f tedge-agent  2>/dev/null || true
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
sudo mosquitto -c /etc/mosquitto/mosquitto.conf > "$LOG_DIR/mosquitto.log" 2>&1 &

# Wait until mosquitto is actually ready
for i in $(seq 1 10); do
    (: < /dev/tcp/localhost/1883) 2>/dev/null && break
    echo "[tedge] Waiting for mosquitto... ($i)"
    sleep 1
done

echo "[tedge] Starting tedge-mapper..."
sudo tedge-mapper c8y > "$LOG_DIR/tedge-mapper.log" 2>&1 &

sleep 1

echo "[tedge] Starting tedge-agent..."
sudo tedge-agent > "$LOG_DIR/tedge-agent.log" 2>&1 &

echo "[tedge] All services started."
echo "[tedge] Logs: $LOG_DIR/"
echo ""

# Keep the script alive and tail all logs together
tail -f "$LOG_DIR/mosquitto.log" \
        "$LOG_DIR/tedge-mapper.log" \
        "$LOG_DIR/tedge-agent.log"