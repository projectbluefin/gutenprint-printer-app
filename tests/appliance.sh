#!/usr/bin/env bash
set -euo pipefail

image="ghcr.io/projectbluefin/gutenprint-printer-app:build"
name=gutenprint-printer-app-smoke
failure_name=gutenprint-printer-app-child-failure
invalid_name=gutenprint-printer-app-invalid-port
symlink_name=gutenprint-printer-app-symlink-state
ephemeral_name=gutenprint-printer-app-no-volume
no_web_name=gutenprint-printer-app-no-web-interface
rejected_name=gutenprint-printer-app-rejected-setting
port="${PORT:-18050}"
no_web_port="$((port + 2))"
no_web_sink_port="$((no_web_port + 1000))"
no_web_output="$(mktemp)"
no_web_sink_pid=""
state_dir="$(mktemp -d)"
symlink_dir="$(mktemp -d)"
no_web_state_dir="$(mktemp -d)"

cleanup() {
  podman rm -f "$name" "$failure_name" "$invalid_name" "$symlink_name" "$ephemeral_name" "$no_web_name" "$rejected_name" >/dev/null 2>&1 || true
  if [[ -n "$no_web_sink_pid" ]]; then
    kill "$no_web_sink_pid" >/dev/null 2>&1 || true
    wait "$no_web_sink_pid" 2>/dev/null || true
  fi
  podman unshare rm -rf "$state_dir" "$symlink_dir" "$no_web_state_dir"
  rm -f "$no_web_output"
}
trap cleanup EXIT

# Job spool, TLS keys and state must be owner-only, as must files the app
# creates (its log), even on a volume that was created or left permissive.
assert_private_state() {
  local modes expected
  modes="$(podman unshare stat -c '%a %n' "$state_dir" "$state_dir/spool" "$state_dir/cups/ssl" \
    "$state_dir/gutenprint-printer-app.log")"
  expected="700 $state_dir"$'\n'"700 $state_dir/spool"$'\n'"700 $state_dir/cups/ssl"$'\n'"600 $state_dir/gutenprint-printer-app.log"
  if [[ "$modes" != "$expected" ]]; then
    printf 'Persistent state is not owner-only:\n%s\n' "$modes" >&2
    return 1
  fi
}

wait_for_http() {
  local target_port="$1" response
  for _ in $(seq 1 60); do
    if response="$(curl --fail --silent --show-error "http://127.0.0.1:${target_port}/" 2>/dev/null)" &&
      [[ "$response" == *'<title>Gutenprint Printer Application</title>'* ]]; then
      return 0
    fi
    sleep 1
  done
  podman logs "$name" >&2 || true
  return 1
}

podman run --rm --entrypoint /usr/bin/bash "$image" -c '
  set -euo pipefail
  test "$(id -u):$(id -g)" = 65532:65532
  test -x /usr/bin/gutenprint-printer-app
  test -x /usr/lib/gutenprint-printer-app/backend/gutenprint53+usb
  test -x /usr/lib/gutenprint-printer-app/backend/socket
  test -x /usr/lib/gutenprint-printer-app/backend/ipp
  test -x /usr/lib/gutenprint-printer-app/backend/ipps
  test -x /usr/lib/gutenprint-printer-app/backend/dnssd
  test -x /usr/lib/gutenprint-printer-app/backend/snmp
  test -x /usr/lib/gutenprint-printer-app/backend/usb
  test -x /usr/lib/gutenprint-printer-app/filter/rastertogutenprint.5.3
  test -x /usr/lib/gutenprint-printer-app/filter/commandtoepson
  test -x /usr/lib/gutenprint-printer-app/filter/commandtocanon
  test -x /usr/lib/gutenprint-printer-app/filter/gstoraster
  test -x /usr/lib/gutenprint-printer-app/driver/gutenprint.5.3
  test -x /usr/share/ppd/gutenprint.5.3
  test -x /usr/sbin/cups-genppd.5.3
  test -x /usr/bin/escputil
  test -x /usr/bin/cups-calibrate
  test -s /usr/share/cups/calibrate.ppm
  test -s /usr/share/gutenprint-printer-app/testpage.pdf
  test -d /usr/share/gutenprint
  for executable in \
    /usr/bin/gutenprint-printer-app \
    /usr/bin/cups-calibrate \
    /usr/lib/gutenprint-printer-app/filter/rastertogutenprint.5.3 \
    /usr/lib/gutenprint-printer-app/backend/gutenprint53+usb \
    /usr/lib/gutenprint-printer-app/driver/gutenprint.5.3; do
    dependencies="$(ldd "$executable")"
    [[ "$dependencies" != *"not found"* ]]
  done
  ppds="$(/usr/share/ppd/gutenprint.5.3 list)"
  [[ "$ppds" == *"Epson Stylus Photo R1800"* ]]
  [[ "$ppds" == *"Simplified"* ]]
'

# The documented rootless deployment: the volume belongs to the app's UID.
podman unshare chown 65532:65532 "$state_dir"
podman run -d \
  --name "$name" --network host -e PORT="$port" \
  -v "$state_dir:/var/lib/gutenprint-printer-app:Z" "$image" >/dev/null
wait_for_http "$port"
grep -q '<title>Gutenprint Printer Application</title>' <<< "$(curl --fail --silent --show-error --insecure "https://127.0.0.1:${port}/")"
grep -q 'NOTICE: web administration is reachable' <<< "$(podman logs "$name" 2>&1)"
podman unshare test -s "$state_dir/cups/snmp.conf"
podman unshare test -s "$state_dir/usb/net.sf.gimp-print.usb-quirks"
podman unshare test -s "$state_dir/usb/org.cups.usb-quirks"
assert_private_state
podman exec "$name" /usr/bin/bash -c 'printf "%s\n" "# preserved SNMP settings" > /var/lib/gutenprint-printer-app/cups/snmp.conf'
podman exec "$name" /usr/bin/bash -c 'printf "%s\n" "# preserved Gutenprint USB quirks" > /var/lib/gutenprint-printer-app/usb/net.sf.gimp-print.usb-quirks'
podman exec "$name" /usr/bin/bash -c 'printf "%s\n" "# preserved CUPS USB quirks" > /var/lib/gutenprint-printer-app/usb/org.cups.usb-quirks'
podman stop --time 15 "$name" >/dev/null
read -r running exit_status <<< "$(podman inspect "$name" --format '{{.State.Running}} {{.State.ExitCode}}')"
[[ "$running" == false && "$exit_status" -eq 143 ]]

# A restart repairs permissive directory modes without rewriting contents.
podman unshare chmod 0777 "$state_dir" "$state_dir/spool" "$state_dir/cups/ssl"
podman run -d \
  --name "$failure_name" --network host -e PORT="$port" \
  -v "$state_dir:/var/lib/gutenprint-printer-app:Z" "$image" >/dev/null
wait_for_http "$port"
assert_private_state
podman exec "$failure_name" /usr/bin/bash -c 'test "$(< /var/lib/gutenprint-printer-app/cups/snmp.conf)" = "# preserved SNMP settings"'
podman exec "$failure_name" /usr/bin/bash -c 'test "$(< /var/lib/gutenprint-printer-app/usb/net.sf.gimp-print.usb-quirks)" = "# preserved Gutenprint USB quirks"'
podman exec "$failure_name" /usr/bin/bash -c 'test "$(< /var/lib/gutenprint-printer-app/usb/org.cups.usb-quirks)" = "# preserved CUPS USB quirks"'
podman exec "$failure_name" /usr/bin/bash -c '
  for proc in /proc/[0-9]*; do
    read -r comm < "$proc/comm" || continue
    if [[ "$comm" == avahi-daemon ]]; then
      kill -TERM "${proc##*/}"
      exit 0
    fi
  done
  exit 1
'
for _ in $(seq 1 150); do
  [[ "$(podman inspect "$failure_name" --format '{{.State.Running}}')" == false ]] && break
  sleep 0.1
done
read -r running failure_status <<< "$(podman inspect "$failure_name" --format '{{.State.Running}} {{.State.ExitCode}}')"
[[ "$running" == false && "$failure_status" -ne 0 ]]

# Without a volume the image's own (root-owned) state directory is used: the
# app must still own writable, private ppd, spool and TLS directories.
podman run -d --name "$ephemeral_name" --network host -e PORT="$port" "$image" >/dev/null
wait_for_http "$port"
podman exec "$ephemeral_name" /usr/bin/bash -c '
  for dir in /var/lib/gutenprint-printer-app/{ppd,spool,cups/ssl}; do
    [[ -O "$dir" && -w "$dir" && "$(stat -c %a "$dir")" == 700 ]] || { printf "%s is not private and writable\n" "$dir" >&2; exit 1; }
  done
'
podman rm -f "$ephemeral_name" >/dev/null

set +e
podman run --name "$invalid_name" -e PORT=invalid "$image" >/dev/null 2>&1
invalid_status=$?
set -e
[[ "$invalid_status" -eq 64 ]]
grep -q 'PORT must be numeric' <<< "$(podman logs "$invalid_name" 2>&1)"

http_status() {
  local scheme="$1" target_port="$2" path="$3"
  curl --insecure --silent --output /dev/null --write-out '%{http_code}' \
    "${scheme}://127.0.0.1:${target_port}${path}" 2>/dev/null || printf '000'
}

# A rejected setting must exit before any service starts, with the named
# status and a diagnostic that explains the refusal.
expect_rejected_setting() {
  local expected_status="$1" expected_message="$2"
  shift 2
  local status logs
  set +e
  podman run --name "$rejected_name" "$@" "$image" >/dev/null 2>&1
  status=$?
  set -e
  logs="$(podman logs "$rejected_name" 2>&1)"
  if [[ "$status" -ne "$expected_status" || "$logs" != *"$expected_message"* ]]; then
    printf '%s\nFAIL: %s must exit %s with "%s" (status=%s)\n' "$logs" "$*" "$expected_status" "$expected_message" "$status" >&2
    exit 1
  fi
  podman rm "$rejected_name" >/dev/null
}

# Web administration knobs (ChairLift ADR-0016). Malformed or unsupported
# values fail closed instead of starting an unauthenticated web admin.
expect_rejected_setting 64 "unsupported option 'no-tls'" -e PRINTER_APP_SERVER_OPTIONS=no-web-interface,no-tls
# The shared printing base builds PAPPL without PAM, so an auth service cannot
# authenticate anyone in this image; refuse it outright rather than lock every
# administrator out with 401.
expect_rejected_setting 78 'set PRINTER_APP_SERVER_OPTIONS=no-web-interface to disable web administration instead' -e PRINTER_APP_AUTH_SERVICE=chairlift-printer
expect_rejected_setting 78 'set PRINTER_APP_SERVER_OPTIONS=no-web-interface to disable web administration instead' -e PRINTER_APP_AUTH_SERVICE=cups
expect_rejected_setting 78 'PRINTER_APP_ADMIN_GROUP requires PRINTER_APP_AUTH_SERVICE' -e PRINTER_APP_ADMIN_GROUP=nonroot

# With the web interface disabled, every admin page is gone while IPP keeps
# accepting and printing jobs.
chmod 0777 "$no_web_state_dir"
python3 tests/socket-sink.py "$no_web_sink_port" "$no_web_output" &
no_web_sink_pid=$!
podman run -d \
  --name "$no_web_name" \
  --network host \
  -e PORT="$no_web_port" \
  -e PRINTER_APP_SERVER_OPTIONS=no-web-interface \
  -v "$no_web_state_dir:/var/lib/gutenprint-printer-app:Z" \
  "$image" >/dev/null
no_web_system_uri="ipp://127.0.0.1:${no_web_port}/ipp/system"
no_web_printer_uri="ipp://127.0.0.1:${no_web_port}/ipp/print/no-web-test"
ready=0
for _ in $(seq 1 60); do
  if [[ "$(http_status http "$no_web_port" /)" == 404 && "$(http_status https "$no_web_port" /)" == 404 ]]; then
    ready=1
    break
  fi
  sleep 1
done
if [[ "$ready" -ne 1 ]]; then
  printf 'FAIL: listener did not answer (with 404) after starting with no-web-interface\n' >&2
  exit 1
fi
if grep -q 'NOTICE: web administration is reachable' <<< "$(podman logs "$no_web_name" 2>&1)"; then
  printf 'FAIL: entrypoint warned about reachable web administration although it was disabled\n' >&2
  exit 1
fi
no_web_drivers="$(podman exec "$no_web_name" gutenprint-printer-app -u "$no_web_system_uri" drivers)"
no_web_driver="$(awk '/"Epson Stylus Photo R1800 \(en\)"/ { gsub(/"/, "", $1); print $1; exit }' <<< "$no_web_drivers")"
[[ -n "$no_web_driver" ]] || { printf 'FAIL: could not find expert Epson Stylus Photo R1800 driver\n' >&2; exit 1; }
podman exec "$no_web_name" gutenprint-printer-app \
  -u "$no_web_system_uri" \
  -d no-web-test \
  -m "$no_web_driver" \
  -v "cups:socket://127.0.0.1:${no_web_sink_port}" \
  add
for scheme in http https; do
  for path in / /addprinter /config /logs /logfile.txt /network /security /no-web-test/ /no-web-test/config /no-web-test/device; do
    status="$(http_status "$scheme" "$no_web_port" "$path")"
    if [[ "$status" != 404 ]]; then
      printf 'FAIL: %s://127.0.0.1:%s%s returned %s with no-web-interface, expected 404\n' "$scheme" "$no_web_port" "$path" "$status" >&2
      exit 1
    fi
  done
done
podman exec "$no_web_name" gutenprint-printer-app -u "$no_web_printer_uri" \
  submit /usr/share/gutenprint-printer-app/testpage.pdf >/dev/null
for _ in $(seq 1 120); do
  [[ -s "$no_web_output" ]] && break
  sleep 0.5
done
if [[ ! -s "$no_web_output" ]]; then
  podman exec "$no_web_name" gutenprint-printer-app -u "$no_web_printer_uri" jobs >&2 || true
  printf 'FAIL: IPP print job produced no socket output with no-web-interface\n' >&2
  exit 1
fi
wait "$no_web_sink_pid"
no_web_sink_pid=""
python3 -c '
import pathlib, sys
payload = pathlib.Path(sys.argv[1]).read_bytes()
assert len(payload) > 512, len(payload)
assert b"\x1b@" in payload[:256], payload[:64].hex()
assert b"\x1b(" in payload[:1024], payload[:64].hex()
' "$no_web_output"
podman stop --time 15 "$no_web_name" >/dev/null

# A private directory that is a symlink stops startup; its target is untouched.
mkdir -m 0755 "$symlink_dir/outside"
ln -s /var/lib/gutenprint-printer-app/outside "$symlink_dir/spool"
podman unshare chown -h 65532:65532 "$symlink_dir" "$symlink_dir/outside" "$symlink_dir/spool"
set +e
podman run --name "$symlink_name" -e PORT="$port" \
  -v "$symlink_dir:/var/lib/gutenprint-printer-app:Z" "$image" >/dev/null 2>&1
symlink_status=$?
set -e
[[ "$symlink_status" -eq 1 ]]
grep -q 'spool must not be a symlink' <<< "$(podman logs "$symlink_name" 2>&1)"
[[ "$(podman unshare stat -c %a "$symlink_dir/outside")" == 755 ]]
printf 'OK: native nonroot Gutenprint payload, HTTPS, owner-only persistent state and supervised lifecycle\n'
