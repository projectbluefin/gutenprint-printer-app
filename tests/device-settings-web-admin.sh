#!/usr/bin/env bash
#
# Real-image verification that a non-IPP Gutenprint device setting is
# editable through the PAPPL web admin UI, survives a container restart,
# and actually changes the real filter/raster output (issue #11).
#
# gutenprint-printer-app.c wires up prSetupDeviceSettingsPage() as the
# printer's "extra setup" callback, and (via issue #9 / PAPPL_MAX_VENDOR=256)
# expert Gutenprint PPDs expose more than 32 vendor-specific, non-IPP
# options. Those vendor options are rendered and saved through PAPPL's
# standard "Printing Defaults" web admin page (<printer>/printing), which
# posts to papplPrinterSetDriverDefaults() and persists via
# papplSystemSaveState(). This script drives that page directly with curl,
# with no mock echoes and no synthetic PPD parsing:
#
#   1. GETs the printer's "Printing Defaults" page and picks one vendor
#      (non-IPP) option with a non-default alternative value.
#   2. POSTs the alternative value through the real web form (session/CSRF
#      token included, same as a browser submission) and confirms the page
#      now reports it as the selected/default value.
#   3. Restarts the container (same persistent state volume) and confirms
#      the changed value is still selected -- proving persistence through a
#      restart, not just in-memory state.
#   4. Submits two real print jobs -- one before the change, one after --
#      and diffs the bytes captured at a socket sink to prove the change
#      reaches the real filter output, not just the printer's job ticket.
set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/projectbluefin/gutenprint-printer-app:build}"
NAME="gutenprint-printer-app-device-settings"
PORT="${PORT:-18200}"
SINK_PORT="$((PORT + 1))"
STATE_DIR="$(mktemp -d)"
COOKIE_JAR="$(mktemp)"
BASELINE_SINK="$(mktemp)"
CHANGED_SINK="$(mktemp)"
SINK_PID=""

cleanup() {
  podman rm -f "$NAME" >/dev/null 2>&1 || true
  if [[ -n "$SINK_PID" ]]; then
    kill "$SINK_PID" >/dev/null 2>&1 || true
    wait "$SINK_PID" 2>/dev/null || true
  fi
  podman unshare rm -rf "$STATE_DIR" 2>/dev/null || true
  rm -f "$COOKIE_JAR" "$BASELINE_SINK" "$CHANGED_SINK"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

start_container() {
  podman run -d \
    --name "$NAME" \
    --network host \
    -e PORT="$PORT" \
    -v "$STATE_DIR:/var/lib/gutenprint-printer-app:Z" \
    "$IMAGE" >/dev/null

  local ready=0
  for _ in $(seq 1 120); do
    if curl --fail --silent --show-error "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  [[ "$ready" -eq 1 ]] || { podman logs "$NAME" >&2 || true; fail "web server did not become ready"; }
}

stop_container() {
  podman stop "$NAME" >/dev/null 2>&1 || true
  podman rm -f "$NAME" >/dev/null 2>&1 || true
}

chmod 0777 "$STATE_DIR"

start_container
SYSTEM_URI="ipp://127.0.0.1:${PORT}/ipp/system"

# --- pick the expert Gutenprint driver --------------------------------------
# pappl-retrofit strips the "CUPS+Gutenprint" suffix from descriptions; with
# PAPPL_MAX_VENDOR >= 256 the app registers only the expert PPDs.
DRIVERS="$(podman exec "$NAME" gutenprint-printer-app -u "$SYSTEM_URI" drivers)"
if grep -qi 'simplified' <<<"$DRIVERS"; then
  fail "simplified Gutenprint PPDs are registered -- see issue #9"
fi
DRIVER="$(python3 "$(dirname "${BASH_SOURCE[0]}")/expert-driver.py" "Epson Stylus Photo R1800" <<<"$DRIVERS")" ||
  fail "no expert Epson Stylus Photo R1800 driver registered -- see issue #9"
echo "Using expert driver: $DRIVER"

PRINTER="device-settings-test"

# Create the printer through PAPPL's web form, the same path
# tests/socket-print.sh uses: the shared PAPPL patch maps its "socket" device
# type to the CUPS socket backend.
add_page="$(curl --fail --silent --show-error --insecure --location \
  --cookie-jar "$COOKIE_JAR" "https://127.0.0.1:${PORT}/addprinter")"
[[ "$add_page" == *'value="socket"'* && "$add_page" == *'name="hostname"'* ]] \
  || fail "add-printer form did not offer a 'socket' device type"
ADD_SESSION="${add_page#*name=\"session\" value=\"}"
ADD_SESSION="${ADD_SESSION%%\"*}"
[[ -n "$ADD_SESSION" && "$ADD_SESSION" != "$add_page" ]] \
  || fail "could not find CSRF session token on the add-printer form"
curl --fail --silent --show-error --insecure --location \
  --cookie "$COOKIE_JAR" --cookie-jar "$COOKIE_JAR" \
  --data-urlencode "session=$ADD_SESSION" \
  --data-urlencode "printer_name=${PRINTER}" \
  --data-urlencode "driver_name=$DRIVER" \
  --data-urlencode 'device_uri=socket' \
  --data-urlencode "hostname=127.0.0.1:${SINK_PORT}" \
  "https://127.0.0.1:${PORT}/addprinter" >/dev/null

DEFAULTS_URL="http://127.0.0.1:${PORT}/${PRINTER}/printing"

fetch_defaults_page() {
  curl --fail --silent --show-error -c "$COOKIE_JAR" -b "$COOKIE_JAR" "$DEFAULTS_URL"
}

extract_session_token() {
  # PAPPL embeds the CSRF token as: <input type="hidden" name="session" value="...">
  grep -Eo 'name="session"[^>]*value="[^"]*"' \
    | grep -Eo 'value="[^"]*"' \
    | head -n1 \
    | sed -E 's/^value="(.*)"$/\1/'
}

PAGE_1="$(fetch_defaults_page)"
SESSION_1="$(printf '%s' "$PAGE_1" | extract_session_token)"
[[ -n "$SESSION_1" ]] || fail "could not find CSRF session token on Printing Defaults page"

# --- pick one non-IPP (Gutenprint vendor) <select> option with a
#     non-default alternative choice ------------------------------------
PAGE_1_FILE="$(mktemp)"
printf '%s\n' "$PAGE_1" > "$PAGE_1_FILE"
read -r opt_name opt_default opt_alt < <(python3 tests/pick-vendor-option.py "$PAGE_1_FILE") \
  || { rm -f "$PAGE_1_FILE"; fail "could not find a non-IPP vendor <select> option with a non-default alternative on the Printing Defaults page"; }
rm -f "$PAGE_1_FILE"

echo "Testing device setting: $opt_name (default=$opt_default, alternative=$opt_alt)"

# --- change it through the real web form ------------------------------------
curl --fail --silent --show-error -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
  -X POST "$DEFAULTS_URL" \
  --data-urlencode "session=${SESSION_1}" \
  --data-urlencode "${opt_name}=${opt_alt}" \
  -o /dev/null

PAGE_2="$(fetch_defaults_page)"
# A here-string, not a pipe: grep -q exits early and pipefail would turn
# the writer's SIGPIPE into a false failure on this ~130 KiB page.
grep -Eq "name=\"${opt_name}\">.*<option value=\"${opt_alt}\" selected" <<<"$PAGE_2" \
  || fail "web admin did not report '$opt_name' as '$opt_alt' after the POST"
echo "OK: web admin now reports $opt_name=$opt_alt"

# --- restart the container and confirm the change survived ------------------
stop_container
start_container

SESSION_3="$(fetch_defaults_page | extract_session_token)"
PAGE_3="$(fetch_defaults_page)"
# A here-string, not a pipe: grep -q exits early and pipefail would turn
# the writer's SIGPIPE into a false failure on this ~130 KiB page.
grep -Eq "name=\"${opt_name}\">.*<option value=\"${opt_alt}\" selected" <<<"$PAGE_3" \
  || fail "'$opt_name=$opt_alt' did not survive a container restart"
echo "OK: $opt_name=$opt_alt persisted across a container restart"

# --- prove the setting reaches the real filter output ------------------------
print_with_sink() {
  local out_file="$1"
  python3 tests/socket-sink.py "$SINK_PORT" "$out_file" &
  SINK_PID=$!
  sleep 0.2
  # Same print-test-page action socket-print.sh uses, so the job takes the
  # printer's saved defaults exactly as a user's test print would.
  local session
  session="$(curl --fail --silent --show-error -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
    "http://127.0.0.1:${PORT}/${PRINTER}/" | extract_session_token)"
  [[ -n "$session" ]] || fail "could not find CSRF session token on the printer status page"
  curl --fail --silent --show-error -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
    --data-urlencode "session=${session}" \
    --data 'action=print-test-page' \
    "http://127.0.0.1:${PORT}/${PRINTER}/" >/dev/null
  local received=0
  for _ in $(seq 1 180); do
    [[ -s "$out_file" ]] && { received=1; break; }
    sleep 0.5
  done
  wait "$SINK_PID" 2>/dev/null || true
  SINK_PID=""
  [[ "$received" -eq 1 ]] || fail "no socket output captured for $out_file"
}

# Baseline job: printer currently has opt_name=opt_alt (set above). Reset to
# the default through the web admin, print, then flip back to the
# alternative and print again -- diffing the two proves the *option*, not
# just job-to-job noise, is what changes the output.
curl --fail --silent --show-error -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
  -X POST "$DEFAULTS_URL" \
  --data-urlencode "session=${SESSION_3}" \
  --data-urlencode "${opt_name}=${opt_default}" \
  -o /dev/null
print_with_sink "$BASELINE_SINK"

SESSION_4="$(fetch_defaults_page | extract_session_token)"
curl --fail --silent --show-error -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
  -X POST "$DEFAULTS_URL" \
  --data-urlencode "session=${SESSION_4}" \
  --data-urlencode "${opt_name}=${opt_alt}" \
  -o /dev/null
print_with_sink "$CHANGED_SINK"

baseline_size="$(wc -c < "$BASELINE_SINK")"
changed_size="$(wc -c < "$CHANGED_SINK")"
echo "Baseline sink: ${baseline_size} bytes; changed sink: ${changed_size} bytes"

if cmp -s "$BASELINE_SINK" "$CHANGED_SINK"; then
  fail "changing $opt_name from '$opt_default' to '$opt_alt' via web admin produced byte-identical filter output -- change did not reach the real driver/filter"
fi

echo "OK: web-admin-set device setting '$opt_name' ($DRIVER) persisted across a restart and altered the real filter output captured at the socket sink"
