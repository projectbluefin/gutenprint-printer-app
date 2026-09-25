#!/usr/bin/env bash
#
# Real-image print-to-socket-sink verification for gutenprint-printer-app.
#
# Builds nothing here: the CI workflow loads the freshly built rock into podman
# and passes it via $IMAGE. This script drives a real print job through the
# image's IPP server and CUPS socket backend, capturing the raster bytes at the
# sink. No network printers, no mock echoes -- only the shipped image.
set -euo pipefail

IMAGE="${IMAGE:-gutenprint-printer-app:build}"
NAME="gutenprint-printer-app-payload"
PORT="${PORT:-18000}"
SINK_PORT="$((PORT + 1))"
STATE_DIR="$(mktemp -d)"
SINK_FILE="$(mktemp)"
COOKIE_FILE="$(mktemp)"
SINK_PID=""

cleanup() {
  podman rm -f "$NAME" >/dev/null 2>&1 || true
  if [[ -n "$SINK_PID" ]]; then
    kill "$SINK_PID" >/dev/null 2>&1 || true
    wait "$SINK_PID" 2>/dev/null || true
  fi
  podman unshare rm -rf "$STATE_DIR" 2>/dev/null || true
  rm -f "$SINK_FILE" "$COOKIE_FILE"
}
trap cleanup EXIT

# --- pick a real gutenprint driver from inside the image -------------------
pick_driver() {
  local drivers driver
  drivers="$(podman run --rm --entrypoint /usr/bin/bash "$IMAGE" -c \
    'gutenprint-printer-app drivers 2>/dev/null | tr -d " \r"' || true)"
  driver="$(printf '%s\n' "$drivers" | grep -Ei 'gutenprint|pcl|pxl|generic' | head -n1 || true)"
  if [[ -z "$driver" ]]; then
    driver="$(printf '%s\n' "$drivers" | head -n1 || true)"
  fi
  printf '%s' "$driver"
}

DRIVER="$(pick_driver)"
if [[ -z "$DRIVER" ]]; then
  echo "FAIL: no gutenprint driver found inside image" >&2
  exit 1
fi
echo "Using driver: $DRIVER"

chmod 0777 "$STATE_DIR"

# --- start the socket sink that captures the printed raster ----------------
python3 tests/socket-sink.py "$SINK_PORT" "$SINK_FILE" &
SINK_PID=$!

# --- start the image and wait for the web server ---------------------------
podman run -d \
  --name "$NAME" \
  --network host \
  -e PORT="$PORT" \
  -v "$STATE_DIR:/var/lib/gutenprint-printer-app:Z" \
  "$IMAGE" >/dev/null

ready=0
for _ in $(seq 1 120); do
  if curl --fail --silent --show-error "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [[ "$ready" -ne 1 ]]; then
  podman logs "$NAME" >&2 || true
  echo "FAIL: web server did not become ready" >&2
  exit 1
fi

# --- add a printer whose device URI is our socket sink ---------------------
PRINTER="socket-test"
PRINTER_URI="ipp://127.0.0.1:${PORT}/ipp/print/${PRINTER}"
podman exec "$NAME" gutenprint-printer-app \
  -u "cups:socket://127.0.0.1:${SINK_PORT}" \
  -d "$PRINTER" \
  -m "$DRIVER" \
  add

# --- request the built-in test page through the web UI ---------------------
printer_page="$(curl --fail --silent --show-error "http://127.0.0.1:${PORT}/${PRINTER}/")"
session="${printer_page#*name=\"session\" value=\"}"
session="${session%%\"*}"
if [[ -z "$session" || "$session" == "$printer_page" ]]; then
  echo "FAIL: could not extract session token from web UI" >&2
  exit 1
fi
curl --fail --silent --show-error \
  --cookie-jar "$COOKIE_FILE" \
  --data-urlencode "session=$session" \
  --data "action=print-test-page" \
  "http://127.0.0.1:${PORT}/${PRINTER}/" >/dev/null

# --- wait for the sink to receive printed bytes ----------------------------
received=0
for _ in $(seq 1 180); do
  [[ -s "$SINK_FILE" ]] && { received=1; break; }
  sleep 0.5
done
if [[ "$received" -ne 1 ]]; then
  podman exec "$NAME" gutenprint-printer-app -u "$PRINTER_URI" jobs >&2 || true
  podman logs "$NAME" >&2 || true
  echo "FAIL: print job produced no socket output" >&2
  exit 1
fi

wait "$SINK_PID"
SINK_PID=""

if [[ ! -s "$SINK_FILE" ]]; then
  echo "FAIL: socket sink captured an empty print job" >&2
  exit 1
fi
echo "OK: received $(( $(wc -c < "$SINK_FILE") )) bytes over the socket sink"

# --- confirm the job reached a terminal state ------------------------------
jobs=""
for _ in $(seq 1 120); do
  jobs="$(podman exec "$NAME" gutenprint-printer-app -u "$PRINTER_URI" jobs || true)"
  [[ "$jobs" == *"completed"* ]] && break
  sleep 0.5
done
if [[ "$jobs" != *"completed"* ]]; then
  echo "FAIL: print job did not reach completed state" >&2
  exit 1
fi

echo "OK: gutenprint print-to-socket-sink verification passed on $DRIVER"
