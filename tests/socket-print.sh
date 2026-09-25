#!/usr/bin/env bash
set -euo pipefail

image="ghcr.io/projectbluefin/gutenprint-printer-app:build"
name=gutenprint-printer-app-socket-print
port="${PORT:-18052}"
sink_port="$((port + 1000))"
state_dir="$(mktemp -d)"
output_file="$(mktemp)"
cookie_file="$(mktemp)"
sink_pid=""

cleanup() {
  podman rm -f "$name" >/dev/null 2>&1 || true
  [[ -z "$sink_pid" ]] || { kill "$sink_pid" 2>/dev/null || true; wait "$sink_pid" 2>/dev/null || true; }
  podman unshare rm -rf "$state_dir"
  rm -f "$output_file" "$cookie_file"
}
trap cleanup EXIT
chmod 0777 "$state_dir"
python3 tests/socket-sink.py "$sink_port" "$output_file" &
sink_pid=$!

podman run -d \
  --name "$name" --network host -e PORT="$port" \
  -v "$state_dir:/var/lib/gutenprint-printer-app:Z" "$image" >/dev/null
ready=0
for _ in $(seq 1 60); do
  if curl --fail --silent --show-error "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [[ "$ready" -ne 1 ]]; then
  podman logs "$name" >&2
  exit 1
fi

system_uri="ipp://127.0.0.1:${port}/ipp/system"
printer_uri="ipp://127.0.0.1:${port}/ipp/print/socket-test"
drivers="$(podman exec "$name" gutenprint-printer-app -u "$system_uri" drivers)"
driver="$(python3 -c '
import sys
for line in sys.stdin:
    if "Epson Stylus Photo R1800" in line and "Simplified" not in line:
        print(line.split()[0].strip("\""))
        break
' <<< "$drivers")"
if [[ -z "$driver" || "$driver" == *[!a-z0-9-]* ]]; then
  printf 'No expert Epson Stylus Photo R1800 driver in live catalog:\n%s\n' "$drivers" >&2
  exit 1
fi
# Create the printer through PAPPL's non-IPP web form. The shared PAPPL patch
# maps this selection to cups:socket, not PAPPL's own socket backend.
add_page="$(curl --fail --silent --show-error --insecure --location \
  --cookie-jar "$cookie_file" "https://127.0.0.1:${port}/addprinter")"
[[ "$add_page" == *'value="socket"'* && "$add_page" == *'name="hostname"'* ]]
session="${add_page#*name=\"session\" value=\"}"
session="${session%%\"*}"
[[ -n "$session" && "$session" != "$add_page" ]]
curl --fail --silent --show-error --insecure --location \
  --cookie "$cookie_file" --cookie-jar "$cookie_file" \
  --data-urlencode "session=$session" \
  --data-urlencode 'printer_name=socket-test' \
  --data-urlencode "driver_name=$driver" \
  --data-urlencode 'device_uri=socket' \
  --data-urlencode "hostname=127.0.0.1:${sink_port}" \
  "https://127.0.0.1:${port}/addprinter" >/dev/null

# The job enters via PAPPL's HTTP/IPP print-test-page action, then passes
# through the real Gutenprint raster filter and CUPS socket backend.
printer_page="$(curl --fail --silent --show-error \
  --cookie "$cookie_file" --cookie-jar "$cookie_file" "http://127.0.0.1:${port}/socket-test/")"
session="${printer_page#*name=\"session\" value=\"}"
session="${session%%\"*}"
[[ -n "$session" && "$session" != "$printer_page" ]]
curl --fail --silent --show-error \
  --cookie "$cookie_file" \
  --data-urlencode "session=$session" \
  --data 'action=print-test-page' \
  "http://127.0.0.1:${port}/socket-test/" >/dev/null

for _ in $(seq 1 120); do
  [[ -s "$output_file" ]] && break
  sleep 1
done
if [[ ! -s "$output_file" ]]; then
  podman logs "$name" >&2
  cat "$state_dir/gutenprint-printer-app.log" >&2 || true
  exit 1
fi
wait "$sink_pid"
sink_pid=""
python3 -c '
import pathlib
import sys
payload = pathlib.Path(sys.argv[1]).read_bytes()
assert len(payload) > 512, len(payload)
assert b"\x1b@" in payload[:256], payload[:64].hex()
assert b"\x1b(" in payload[:1024], payload[:64].hex()
' "$output_file"

jobs=""
for _ in $(seq 1 120); do
  jobs="$(podman exec "$name" gutenprint-printer-app -u "$printer_uri" jobs)"
  [[ "$jobs" == *completed* ]] && break
  sleep 1
done
[[ "$jobs" == *completed* ]]

podman stop --time 15 "$name" >/dev/null
podman rm "$name" >/dev/null
podman run -d \
  --name "$name" --network host -e PORT="$port" \
  -v "$state_dir:/var/lib/gutenprint-printer-app:Z" "$image" >/dev/null
for _ in $(seq 1 60); do
  if curl --fail --silent --show-error "http://127.0.0.1:${port}/socket-test/" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
printers="$(podman exec "$name" gutenprint-printer-app -u "$system_uri" printers)"
[[ "$printers" == *socket-test* ]]
printf 'OK: IPP job completed through Gutenprint ESC/P2 raster and CUPS socket; queue persisted\n'
