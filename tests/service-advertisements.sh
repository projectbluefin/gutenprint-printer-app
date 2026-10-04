#!/usr/bin/env bash
#
# Real host-network observation; run on an otherwise quiet test LAN.
#
# The Gutenprint image inherits Avahi's sample ssh.service and sftp-ssh.service
# records. Nothing in this appliance serves SSH or SFTP, so publishing them
# under the host's name would misdirect LAN users. This proves the built image
# carries no such records and that starting or restarting instances of it adds
# none, while the appliance's own IPP queues stay discoverable on their distinct
# ports.
#
# This proves the built image advertises no container-supplied SSH/SFTP record
# and that two coexisting instances keep their own IPP queues discoverable across
# startup and restart. It does not prove physical USB or paper output.
set -euo pipefail

image="${IMAGE:-ghcr.io/projectbluefin/gutenprint-printer-app:build}"
app="${APP:-gutenprint-printer-app}"
state_root="${STATE_ROOT:-/var/lib/$app}"
port="${PORT:-18546}"
evidence="${EVIDENCE_DIR:-$(mktemp -d)}"
mkdir -p "$evidence"
state_dir="$(mktemp -d)"
prefix="service-advertisements-$$"
names=("$prefix-alpha" "$prefix-beta")
cleanup() {
  for name in "${names[@]}"; do
    podman logs "$name" > "$evidence/$name.log" 2>&1 || true
    podman rm -f "$name" >/dev/null 2>&1 || true
  done
  podman unshare rm -rf "$state_dir"
}
trap cleanup EXIT
for command in podman avahi-browse timeout curl python3; do
  command -v "$command" >/dev/null
done
podman image inspect "$image" > "$evidence/image.json"
podman run --rm --entrypoint /usr/bin/bash "$image" -ec '
  test ! -e /etc/avahi/services/ssh.service
  test ! -e /etc/avahi/services/sftp-ssh.service
'

snapshot() {
  local phase="$1" service
  for service in _ssh._tcp _sftp-ssh._tcp _ipp._tcp; do
    timeout 30 avahi-browse --resolve --terminate --parsable "$service" \
      > "$evidence/$phase.$service"
  done
}
remote_records() {
  # Ignore interface/protocol duplication, retain instance, host, address, port.
  awk -F ';' '$1 == "=" {print $4 ";" $5 ";" $6 ";" $7 ";" $8 ";" $9}' "$1" | LC_ALL=C sort -u
}
check_records() {
  local phase="$1" service index
  for service in _ssh._tcp _sftp-ssh._tcp; do
    if ! diff -u <(remote_records "$evidence/before.$service") \
                  <(remote_records "$evidence/$phase.$service"); then
      fail "$service records changed in $phase"
    fi
  done
  for index in 0 1; do
    # A resolved queue record must advertise this instance's distinct IPP port.
    if ! awk -F ';' -v port="$((port + index))" -v queue="${names[index]}" '
      $1 == "=" && $9 == port && index($0, "rp=ipp/print/" queue) {found=1}
      END {exit !found}
    ' "$evidence/$phase._ipp._tcp"; then
      fail "IPP queue ${names[index]} did not resolve in $phase"
    fi
  done
}
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  local name
  for name in "${names[@]}"; do
    podman logs "$name" >&2 2>/dev/null || true
  done
  exit 1
}
wait_for_http() {
  local target="$1"
  for _ in $(seq 1 60); do
    if curl --fail --silent "http://127.0.0.1:$target/" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  fail "service on port $target did not answer HTTP within 60s"
}

# Discover a real Gutenprint expert driver so the queue setup does not depend
# on a driver string that may not exist in every catalog build.
pick_driver() {
  local name="$1" port="$2" model="$3" drivers driver
  drivers="$(podman exec "$name" "$app" -u "ipp://127.0.0.1:${port}/ipp/system" drivers)"
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

snapshot before
for index in 0 1; do
  mkdir "$state_dir/$index"
  podman unshare chown 65532:65532 "$state_dir/$index"
  podman run -d --name "${names[index]}" --network host \
    -e PORT="$((port + index))" \
    -v "$state_dir/$index:$state_root:Z" "$image" >/dev/null
  wait_for_http "$((port + index))"
  driver="$(pick_driver "${names[index]}" "$((port + index))" "Epson Stylus Photo R1800")"
  podman exec "${names[index]}" "$app" \
    -u "ipp://127.0.0.1:$((port + index))/ipp/system" \
    -d "${names[index]}" -m "$driver" \
    -v "cups:socket://127.0.0.1:19999" add
done
# Allow mDNS probing/announcements to settle before each observation.
sleep 5
snapshot started
check_records started
podman restart --time 15 "${names[0]}" >/dev/null
wait_for_http "$port"
sleep 5
snapshot restarted
check_records restarted
printf 'PASS: SSH/SFTP records unchanged; both IPP queues resolve after startup/restart.\n'
printf 'Evidence: %s\nNo physical discovery or printed paper was tested.\n' "$evidence"
