#!/usr/bin/env bash
# systemctl mock for containerised dev environments.
# Handles the subset of commands thin-edge.io calls internally.

set -euo pipefail

ACTION="${1:-}"
SERVICE="${2:-}"

# ── Helpers ────────────────────────────────────────────────────────────────

log()  { echo "[systemctl-mock] $*" >&2; }

stop_service() {
  local svc="$1"
  case "$svc" in
    mosquitto)
      pkill -x mosquitto 2>/dev/null && log "Stopped mosquitto" || log "mosquitto was not running"
      ;;
    tedge-mapper | tedge-mapper@c8y)
      pkill -f "tedge-mapper c8y" 2>/dev/null && log "Stopped tedge-mapper" || log "tedge-mapper was not running"
      ;;
    tedge-agent)
      pkill -f "tedge-agent" 2>/dev/null && log "Stopped tedge-agent" || log "tedge-agent was not running"
      ;;
    tedge-watchdog)
      pkill -f "tedge-watchdog" 2>/dev/null && log "Stopped tedge-watchdog" || log "tedge-watchdog was not running"
      ;;
    *)
      log "stop: unknown service '$svc' — no-op"
      ;;
  esac
}

start_service() {
  local svc="$1"
  case "$svc" in
    mosquitto)
      mosquitto -d -c /etc/tedge/mosquitto-conf/tedge-mosquitto.conf \
        >> /var/log/mosquitto.log 2>&1
      log "Started mosquitto"
      ;;
    tedge-mapper | tedge-mapper@c8y)
      tedge-mapper c8y >> /var/log/tedge-mapper.log 2>&1 &
      log "Started tedge-mapper (PID $!)"
      ;;
    tedge-agent)
      tedge-agent >> /var/log/tedge-agent.log 2>&1 &
      log "Started tedge-agent (PID $!)"
      ;;
    tedge-watchdog)
      tedge-watchdog >> /var/log/tedge-watchdog.log 2>&1 &
      log "Started tedge-watchdog (PID $!)"
      ;;
    *)
      log "start: unknown service '$svc' — no-op"
      ;;
  esac
}

is_active() {
  local svc="$1"
  case "$svc" in
    mosquitto)         pgrep -x mosquitto      >/dev/null 2>&1 ;;
    tedge-mapper*)     pgrep -f "tedge-mapper" >/dev/null 2>&1 ;;
    tedge-agent)       pgrep -f "tedge-agent"  >/dev/null 2>&1 ;;
    tedge-watchdog)    pgrep -f "tedge-watchdog" >/dev/null 2>&1 ;;
    *)                 return 1 ;;
  esac
}

# ── Dispatch ───────────────────────────────────────────────────────────────

case "$ACTION" in
  start)
    start_service "$SERVICE"
    ;;
  stop)
    stop_service "$SERVICE"
    ;;
  restart)
    stop_service "$SERVICE"
    sleep 1
    start_service "$SERVICE"
    ;;
  enable | disable | mask | unmask)
    log "$ACTION $SERVICE — no-op in container"
    ;;
  daemon-reload)
    log "daemon-reload — no-op in container"
    ;;
  is-active | is-enabled)
    if is_active "$SERVICE"; then
      echo "active"
      exit 0
    else
      echo "inactive"
      exit 1
    fi
    ;;
  status)
    if is_active "$SERVICE"; then
      echo "● $SERVICE — active (running)"
      exit 0
    else
      echo "● $SERVICE — inactive (dead)"
      exit 1
    fi
    ;;
  *)
    log "Unsupported action '$ACTION' — no-op"
    ;;
esac