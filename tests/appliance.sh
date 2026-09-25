#!/usr/bin/env bash
set -euo pipefail

image="ghcr.io/projectbluefin/gutenprint-printer-app:build"
name=gutenprint-printer-app-smoke
failure_name=gutenprint-printer-app-child-failure
invalid_name=gutenprint-printer-app-invalid-port
port="${PORT:-18050}"
state_dir="$(mktemp -d)"

cleanup() {
  podman rm -f "$name" "$failure_name" "$invalid_name" >/dev/null 2>&1 || true
  podman unshare rm -rf "$state_dir"
}
trap cleanup EXIT

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

chmod 0777 "$state_dir"
podman run -d \
  --name "$name" --network host -e PORT="$port" \
  -v "$state_dir:/var/lib/gutenprint-printer-app:Z" "$image" >/dev/null
wait_for_http "$port"
curl --fail --silent --show-error --insecure "https://127.0.0.1:${port}/" | grep -q '<title>Gutenprint Printer Application</title>'
test -s "$state_dir/cups/snmp.conf"
test -s "$state_dir/usb/net.sf.gimp-print.usb-quirks"
test -s "$state_dir/usb/org.cups.usb-quirks"
podman exec "$name" /usr/bin/bash -c 'printf "%s\n" "# preserved SNMP settings" > /var/lib/gutenprint-printer-app/cups/snmp.conf'
podman exec "$name" /usr/bin/bash -c 'printf "%s\n" "# preserved Gutenprint USB quirks" > /var/lib/gutenprint-printer-app/usb/net.sf.gimp-print.usb-quirks'
podman exec "$name" /usr/bin/bash -c 'printf "%s\n" "# preserved CUPS USB quirks" > /var/lib/gutenprint-printer-app/usb/org.cups.usb-quirks'
podman stop --time 15 "$name" >/dev/null
read -r running exit_status <<< "$(podman inspect "$name" --format '{{.State.Running}} {{.State.ExitCode}}')"
[[ "$running" == false && "$exit_status" -eq 143 ]]

podman run -d \
  --name "$failure_name" --network host -e PORT="$port" \
  -v "$state_dir:/var/lib/gutenprint-printer-app:Z" "$image" >/dev/null
wait_for_http "$port"
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

set +e
podman run --name "$invalid_name" -e PORT=invalid "$image" >/dev/null 2>&1
invalid_status=$?
set -e
[[ "$invalid_status" -eq 64 ]]
podman logs "$invalid_name" 2>&1 | grep -q 'PORT must be numeric'
printf 'OK: native nonroot Gutenprint payload, HTTPS, persistent state and supervised lifecycle\n'
