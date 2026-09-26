#!/usr/bin/env bash
#
# Real-image verification that two Gutenprint Printer Application instances
# coexist on one host (issue #5): each has its own port and persistent volume,
# owns a different printer, prints to its own socket sink, and advertises only
# its own queue over DNS-SD. tests/mdns-browse.py observes the real mDNS
# traffic on the link the way any other LAN host would. Both instances are
# then recreated on the same volumes and must still expose exactly their own
# printer and advertisement.
#
# This proves the LAN and state isolation of the OCI image with synthetic
# socket destinations only. It does not prove physical USB or paper output.
set -euo pipefail

image="${IMAGE:-ghcr.io/projectbluefin/gutenprint-printer-app:build}"
port_a="${PORT:-18400}"
port_b="$((port_a + 1))"
sink_port_a="$((port_a + 1000))"
sink_port_b="$((port_b + 1000))"
name_a=gutenprint-printer-app-coexist-a
name_b=gutenprint-printer-app-coexist-b
printer_a=studio-epson-r1800
printer_b=office-epson-r800
model_a="Epson Stylus Photo R1800"
model_b="Epson Stylus Photo R800"
state_a="$(mktemp -d)"
state_b="$(mktemp -d)"
output_a="$(mktemp)"
output_b="$(mktemp)"
cookie_file="$(mktemp)"
sink_pids=()

cleanup() {
  podman rm -f "$name_a" "$name_b" >/dev/null 2>&1 || true
  local pid
  for pid in "${sink_pids[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  podman unshare rm -rf "$state_a" "$state_b"
  rm -f "$output_a" "$output_b" "$cookie_file"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  podman logs "$name_a" >&2 2>/dev/null || true
  podman logs "$name_b" >&2 2>/dev/null || true
  exit 1
}

start_instance() {
  local name="$1" port="$2" state_dir="$3"
  podman run -d \
    --name "$name" --network host -e PORT="$port" \
    -v "$state_dir:/var/lib/gutenprint-printer-app:Z" "$image" >/dev/null
}

wait_for_http() {
  local name="$1" port="$2"
  for _ in $(seq 1 60); do
    if curl --fail --silent --show-error "http://127.0.0.1:${port}/" 2>/dev/null |
      grep -q '<title>Gutenprint Printer Application</title>'; then
      return 0
    fi
    sleep 1
  done
  fail "$name did not serve HTTP on port $port"
}

pick_driver() {
  local name="$1" port="$2" model="$3" drivers driver
  drivers="$(podman exec "$name" gutenprint-printer-app -u "ipp://127.0.0.1:${port}/ipp/system" drivers)"
  driver="$(python3 -c '
import re
import sys
model = re.compile(re.escape(sys.argv[1]) + r"(?![0-9A-Za-z])")
for line in sys.stdin:
    if model.search(line) and "Simplified" not in line:
        print(line.split()[0].strip("\""))
        break
' "$model" <<< "$drivers")"
  if [[ -z "$driver" || "$driver" == *[!a-z0-9-]* ]]; then
    fail "no expert '$model' driver in $name live catalog"
  fi
  printf '%s' "$driver"
}

# Create a queue through PAPPL's manual network-printer web form, exactly as an
# administrator would; the shared PAPPL patch maps it to cups:socket.
add_socket_printer() {
  local port="$1" printer="$2" driver="$3" sink_port="$4" add_page session
  add_page="$(curl --fail --silent --show-error --insecure --location \
    --cookie-jar "$cookie_file" "https://127.0.0.1:${port}/addprinter")"
  [[ "$add_page" == *'value="socket"'* && "$add_page" == *'name="hostname"'* ]] || fail "addprinter form on $port lacks the socket option"
  session="${add_page#*name=\"session\" value=\"}"
  session="${session%%\"*}"
  [[ -n "$session" && "$session" != "$add_page" ]] || fail "no session token on $port"
  curl --fail --silent --show-error --insecure --location \
    --cookie "$cookie_file" --cookie-jar "$cookie_file" \
    --data-urlencode "session=$session" \
    --data-urlencode "printer_name=$printer" \
    --data-urlencode "driver_name=$driver" \
    --data-urlencode 'device_uri=socket' \
    --data-urlencode "hostname=127.0.0.1:${sink_port}" \
    "https://127.0.0.1:${port}/addprinter" >/dev/null
}

print_test_page() {
  local port="$1" printer="$2" printer_page session
  printer_page="$(curl --fail --silent --show-error \
    --cookie "$cookie_file" --cookie-jar "$cookie_file" "http://127.0.0.1:${port}/${printer}/")"
  session="${printer_page#*name=\"session\" value=\"}"
  session="${session%%\"*}"
  [[ -n "$session" && "$session" != "$printer_page" ]] || fail "no session token on printer page $port/$printer"
  curl --fail --silent --show-error \
    --cookie "$cookie_file" \
    --data-urlencode "session=$session" \
    --data 'action=print-test-page' \
    "http://127.0.0.1:${port}/${printer}/" >/dev/null
}

# Each instance must list exactly its own queue.
assert_own_printer_only() {
  local name="$1" port="$2" own="$3" other="$4" printers
  printers="$(podman exec "$name" gutenprint-printer-app -u "ipp://127.0.0.1:${port}/ipp/system" printers)"
  [[ "$printers" == *"$own"* ]] || fail "$name does not list its own printer $own: $printers"
  [[ "$printers" != *"$other"* ]] || fail "$name lists the other instance's printer $other: $printers"
}

# The saved state of each volume names only that instance's queue.
assert_own_state_only() {
  local state_dir="$1" own="$2" other="$3" state
  state="$(podman unshare cat "$state_dir/gutenprint-printer-app.state")"
  [[ "$state" == *"$own"* ]] || fail "$state_dir state lacks $own"
  [[ "$state" != *"$other"* ]] || fail "$state_dir state contains the other instance's $other"
}

# Browse the real mDNS traffic as another host on the link would, with the
# dependency-free resolver in tests/mdns-browse.py (the image's avahi-browse
# is not used: an observer must not depend on either instance's Avahi).
browse_services() {
  python3 tests/mdns-browse.py "$1" 2
}

# Every advertised queue of $service_type must be one of the two synthetic
# printers, have exactly one service name, and resolve to the port and `rp=`
# path of the instance that owns it.
assert_unique_advertisements() {
  local service_type="$1" records=""
  for _ in $(seq 1 5); do
    records="$(browse_services "$service_type")"
    [[ "$records" == *"$printer_a"* && "$records" == *"$printer_b"* ]] && break
    sleep 3
  done
  [[ -n "$records" ]] || fail "no $service_type advertisements seen on the link"
  printf '%s\n' "$records" | python3 -c '
import collections
import json
import sys

printer_a, printer_b, port_a, port_b, service_type = sys.argv[1:6]
expected = {printer_a: int(port_a), printer_b: int(port_b)}
names = set()
ports = collections.defaultdict(set)
paths = collections.defaultdict(set)
for line in sys.stdin:
    if not line.strip():
        continue
    record = json.loads(line)
    name = record["name"]
    if record["type"] != service_type:
        continue
    owner = [p for p in expected if p in name]
    if len(owner) != 1:
        sys.exit(f"unexpected {service_type} advertisement {name!r}; only {sorted(expected)} may advertise")
    names.add(name)
    ports[owner[0]].add(record["port"])
    paths[owner[0]].update(t for t in record["txt"] if t.startswith("rp="))
for printer, port in expected.items():
    owned = {n for n in names if printer in n}
    if len(owned) != 1:
        sys.exit(f"{printer} must have exactly one {service_type} service name, saw {sorted(owned)}")
    if ports[printer] != {port}:
        sys.exit(f"{printer} advertised on ports {sorted(map(str, ports[printer]))}, expected {port}")
    if paths[printer] != {f"rp=ipp/print/{printer}"}:
        sys.exit(f"{printer} advertised rp {sorted(paths[printer])}, expected ipp/print/{printer}")
if len(names) != 2:
    sys.exit(f"expected two distinct {service_type} names, saw {sorted(names)}")
print(f"{service_type}: {sorted(names)} on ports {[sorted(ports[p]) for p in expected]}")
' "$printer_a" "$printer_b" "$port_a" "$port_b" "$service_type" || fail "$service_type advertisements are not isolated:"$'\n'"$records"
}

wait_for_completed_job() {
  local name="$1" port="$2" printer="$3" jobs=""
  for _ in $(seq 1 120); do
    jobs="$(podman exec "$name" gutenprint-printer-app -u "ipp://127.0.0.1:${port}/ipp/print/${printer}" jobs)"
    [[ "$jobs" == *completed* ]] && return 0
    sleep 1
  done
  fail "$name job on $printer did not complete: $jobs"
}

assert_escp2_payload() {
  local output="$1" label="$2"
  python3 -c '
import pathlib
import sys
payload = pathlib.Path(sys.argv[1]).read_bytes()
assert len(payload) > 512, len(payload)
assert b"\x1b@" in payload[:256], payload[:64].hex()
assert b"\x1b(" in payload[:1024], payload[:64].hex()
' "$output" || fail "$label sink did not receive ESC/P2 raster output"
}

# Rootless deployment as documented: separate volumes owned by the app's UID.
podman unshare chown 65532:65532 "$state_a" "$state_b"
start_instance "$name_a" "$port_a" "$state_a"
start_instance "$name_b" "$port_b" "$state_b"
wait_for_http "$name_a" "$port_a"
wait_for_http "$name_b" "$port_b"

driver_a="$(pick_driver "$name_a" "$port_a" "$model_a")"
driver_b="$(pick_driver "$name_b" "$port_b" "$model_b")"
[[ "$driver_a" != "$driver_b" ]] || fail "synthetic printers must use distinct models"
add_socket_printer "$port_a" "$printer_a" "$driver_a" "$sink_port_a"
add_socket_printer "$port_b" "$printer_b" "$driver_b" "$sink_port_b"

assert_own_printer_only "$name_a" "$port_a" "$printer_a" "$printer_b"
assert_own_printer_only "$name_b" "$port_b" "$printer_b" "$printer_a"
assert_unique_advertisements _ipp._tcp
assert_unique_advertisements _ipps._tcp

# Both instances print concurrently, each into its own sink.
python3 tests/socket-sink.py "$sink_port_a" "$output_a" &
sink_pids+=("$!")
python3 tests/socket-sink.py "$sink_port_b" "$output_b" &
sink_pids+=("$!")
print_test_page "$port_a" "$printer_a"
print_test_page "$port_b" "$printer_b"
wait_for_completed_job "$name_a" "$port_a" "$printer_a"
wait_for_completed_job "$name_b" "$port_b" "$printer_b"
for pid in "${sink_pids[@]}"; do
  wait "$pid"
done
sink_pids=()
assert_escp2_payload "$output_a" "$name_a"
assert_escp2_payload "$output_b" "$name_b"

# Recreating both containers on their own volumes keeps each queue, and its
# advertisement, with the instance that configured it.
podman stop --time 15 "$name_a" "$name_b" >/dev/null
podman rm "$name_a" "$name_b" >/dev/null
assert_own_state_only "$state_a" "$printer_a" "$printer_b"
assert_own_state_only "$state_b" "$printer_b" "$printer_a"
start_instance "$name_a" "$port_a" "$state_a"
start_instance "$name_b" "$port_b" "$state_b"
wait_for_http "$name_a" "$port_a"
wait_for_http "$name_b" "$port_b"
assert_own_printer_only "$name_a" "$port_a" "$printer_a" "$printer_b"
assert_own_printer_only "$name_b" "$port_b" "$printer_b" "$printer_a"
assert_unique_advertisements _ipp._tcp

printf 'OK: two instances on ports %s/%s kept separate state, printed to separate sinks and advertised distinct DNS-SD queues\n' "$port_a" "$port_b"
