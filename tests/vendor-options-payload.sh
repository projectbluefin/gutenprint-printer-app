#!/usr/bin/env bash
#
# Real-image verification that expert Gutenprint PPDs and their PAPPL
# vendor-option budget are actually exposed and honoured by the shipped
# image (issue #9).
#
# `just verify` builds the real image and runs this script against it (no
# mock echoes, no synthetic PPD parsing):
#
#   1. Confirms the app registers expert, and no "Simplified", Gutenprint
#      drivers -- i.e. PAPPL_MAX_VENDOR >= 256 from the shared printing base
#      actually took effect, per the driver_display_regex selection in
#      gutenprint-printer-app.c.
#   2. Adds a printer with the expert Epson Stylus Photo R1800 driver and
#      confirms `options` reports more than 32 distinct vendor options --
#      proving the raised PAPPL vendor-option ceiling is in force.
#   3. Picks one supported non-default vendor option value, submits a print
#      job with it set, and diffs the bytes captured at the socket sink
#      against a baseline job printed with defaults -- proving the option
#      change reaches the real filter output, not just the job ticket.
set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/projectbluefin/gutenprint-printer-app:build}"
NAME="gutenprint-printer-app-vendor-options"
PORT="${PORT:-18100}"
SINK_PORT="$((PORT + 1))"
STATE_DIR="$(mktemp -d)"
BASELINE_SINK="$(mktemp)"
CHANGED_SINK="$(mktemp)"
COOKIE_JAR="$(mktemp)"
SINK_PID=""

cleanup() {
  podman rm -f "$NAME" >/dev/null 2>&1 || true
  if [[ -n "$SINK_PID" ]]; then
    kill "$SINK_PID" >/dev/null 2>&1 || true
    wait "$SINK_PID" 2>/dev/null || true
  fi
  podman unshare rm -rf "$STATE_DIR" 2>/dev/null || true
  rm -f "$BASELINE_SINK" "$CHANGED_SINK" "$COOKIE_JAR"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

chmod 0777 "$STATE_DIR"

# --- start the image --------------------------------------------------------
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
[[ "$ready" -eq 1 ]] || { podman logs "$NAME" >&2 || true; fail "web server did not become ready"; }

SYSTEM_URI="ipp://127.0.0.1:${PORT}/ipp/system"

# --- the app registers expert, not simplified, Gutenprint PPDs --------------
# gutenprint-printer-app.c only selects the expert PPDs (driver_display_regex)
# when PAPPL_MAX_VENDOR >= 256; otherwise it registers the "Simplified" ones.
# pappl-retrofit strips the "CUPS+Gutenprint" suffix from the descriptions.
drivers="$(podman exec "$NAME" gutenprint-printer-app -u "$SYSTEM_URI" drivers)"
if grep -qi 'simplified' <<<"$drivers"; then
  fail "simplified Gutenprint PPDs are registered -- PAPPL_MAX_VENDOR patch did not take effect in this image"
fi
DRIVER="$(awk '/"Epson Stylus Photo R1800 \(en\)"/ { print $1; exit }' <<<"$drivers")"
if [[ -z "$DRIVER" ]]; then
  printf '%s\n' "$drivers" >&2
  fail "no expert Epson Stylus Photo R1800 driver registered"
fi
echo "Using expert driver: $DRIVER"

PRINTER="vendor-options-test"
PRINTER_URI="ipp://127.0.0.1:${PORT}/ipp/print/${PRINTER}"
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

# --- confirm the vendor-option budget is actually available ----------------
# Standard IPP job attributes PAPPL renders for every driver; everything else
# is a PPD vendor option, which stock PAPPL caps at 32.
ipp_options='^(copies|media|media-source|media-type|orientation-requested|output-bin|print-color-mode|print-content-optimize|print-darkness|print-quality|print-scaling|print-speed|printer-resolution|sides)$'
options_output="$(podman exec "$NAME" gutenprint-printer-app -u "$PRINTER_URI" options)"
option_count="$(grep -Eo '^[[:space:]]*-o [A-Za-z0-9_-]+=' <<<"$options_output" \
  | sed -E 's/^[[:space:]]*-o //; s/=$//' | sort -u | grep -Evc "$ipp_options" || true)"
echo "Reported $option_count distinct vendor options for $DRIVER"
[[ "$option_count" -gt 32 ]] \
  || fail "only $option_count vendor options reported; expected more than 32 (PAPPL_MAX_VENDOR budget not exposed)"

# --- pick one non-default vendor option value to flip -----------------------
# Look for a Gutenprint-specific keyword option (skip the standard IPP
# attributes, which the socket-print test already covers) with at least one
# alternative to its default.
read -r opt_name opt_default opt_alt < <(printf '%s\n' "$options_output" | awk -v ipp="$ipp_options" '
  /^[[:space:]]*-o [A-Za-z0-9_-]+=.*\(default\)/ {
    line=$0
    sub(/^[[:space:]]*-o /, "", line)
    split(line, kv, "=")
    name=kv[1]
    val=kv[2]
    sub(/ \(default\)/, "", val)
    defaults[name]=val
    order[++n]=name
    next
  }
  /^[[:space:]]*-o [A-Za-z0-9_-]+=/ {
    line=$0
    sub(/^[[:space:]]*-o /, "", line)
    split(line, kv, "=")
    name=kv[1]
    val=kv[2]
    if (name in defaults && !(name in alt) && val != defaults[name] && name !~ ipp) {
      alt[name]=val
    }
  }
  END {
    for (i = 1; i <= n; i++) {
      name = order[i]
      if (name in alt) { print name, defaults[name], alt[name]; exit }
    }
  }
')
if [[ -z "${opt_name:-}" ]]; then
  echo "$options_output" >&2
  fail "could not find a Gutenprint vendor option with a non-default alternative value to test"
fi
echo "Testing vendor option: $opt_name (default=$opt_default, alternative=$opt_alt)"

# One job at a time: each capture must hold exactly one job, so wait for the
# previous job to leave the queue and for the sink to listen before submitting.
wait_for_idle_queue() {
  local jobs=""
  for _ in $(seq 1 240); do
    jobs="$(podman exec "$NAME" gutenprint-printer-app -u "$PRINTER_URI" jobs)"
    [[ "$jobs" != *pending* && "$jobs" != *processing* ]] && return 0
    sleep 0.5
  done
  printf '%s\n' "$jobs" >&2
  fail "print queue did not drain"
}

wait_for_sink() {
  for _ in $(seq 1 100); do
    [[ -n "$(ss -Htln "sport = :${SINK_PORT}")" ]] && return 0
    sleep 0.1
  done
  fail "socket sink did not listen on port ${SINK_PORT}"
}

dump_diagnostics() {
  podman ps -a --filter "name=^${NAME}\$" --format '{{.Status}}' >&2 || true
  podman logs --tail 50 "$NAME" >&2 || true
  podman exec "$NAME" gutenprint-printer-app -u "$PRINTER_URI" jobs >&2 || true
  podman unshare cat "$STATE_DIR/gutenprint-printer-app.log" >&2 || true
}

print_with_sink() {
  local option_setting="$1" out_file="$2"
  local -a options=()
  [[ -z "$option_setting" ]] || options=(-o "$option_setting")
  wait_for_idle_queue
  python3 tests/socket-sink.py "$SINK_PORT" "$out_file" &
  SINK_PID=$!
  wait_for_sink
  if ! podman exec "$NAME" gutenprint-printer-app submit \
    -u "$PRINTER_URI" "${options[@]}" \
    /usr/share/gutenprint-printer-app/testpage.pdf >/dev/null; then
    dump_diagnostics
    fail "could not submit the test page with option setting '${option_setting:-<defaults>}'"
  fi
  local received=0
  for _ in $(seq 1 180); do
    [[ -s "$out_file" ]] && { received=1; break; }
    sleep 0.5
  done
  wait "$SINK_PID" 2>/dev/null || true
  SINK_PID=""
  [[ "$received" -eq 1 ]] || { dump_diagnostics; fail "no socket output captured for option setting '$option_setting'"; }
  wait_for_idle_queue
  local jobs
  jobs="$(podman exec "$NAME" gutenprint-printer-app -u "$PRINTER_URI" jobs)"
  [[ "$(head -n 1 <<<"$jobs")" == *completed* ]] \
    || { printf '%s\n' "$jobs" >&2; fail "job with option setting '${option_setting:-<defaults>}' did not complete"; }
}

print_with_sink "" "$BASELINE_SINK"
print_with_sink "${opt_name}=${opt_alt}" "$CHANGED_SINK"

baseline_size="$(wc -c < "$BASELINE_SINK")"
changed_size="$(wc -c < "$CHANGED_SINK")"
echo "Baseline sink: ${baseline_size} bytes; changed sink: ${changed_size} bytes"

if cmp -s "$BASELINE_SINK" "$CHANGED_SINK"; then
  fail "changing $opt_name from '$opt_default' to '$opt_alt' produced byte-identical filter output -- option change did not reach the real driver/filter"
fi

echo "OK: expert driver '$DRIVER' exposes ${option_count} options; changing '$opt_name' altered the real filter output captured at the socket sink"
