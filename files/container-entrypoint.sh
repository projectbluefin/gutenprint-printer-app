#!/usr/bin/env bash
set -euo pipefail

usage_error() {
  printf '%s\n' "$1" >&2
  exit 64
}

config_error() {
  printf '%s\n' "$1" >&2
  exit 78
}

if [[ -n "${PORT:-}" && ! "$PORT" =~ ^[0-9]+$ ]]; then
  usage_error 'PORT must be numeric'
fi

# Web administration knobs (ChairLift ADR-0016). PAPPL serves IPP and the web
# interface on one listener, so on host networking the only boundary around the
# admin pages is authorization. Every value is validated here and the container
# exits non-zero rather than start with a setting the server would silently
# ignore or weaken: pappl-retrofit drops unknown server-options without a
# diagnostic, and PAPPL skips the group check for an admin-group it cannot
# resolve. Exit 64 marks a malformed value; exit 78 marks a value this image
# cannot honour.

# PAPPL server options this appliance forwards. Everything else pappl-retrofit
# understands either weakens the appliance (no-tls, none) or is already the
# default (web-log, web-network, web-security), so it is not accepted.
allowed_server_options=(no-web-interface)
server_options=()
if [[ -n "${PRINTER_APP_SERVER_OPTIONS:-}" ]]; then
  [[ "$PRINTER_APP_SERVER_OPTIONS" =~ ^[a-z-]+(,[a-z-]+)*$ ]] \
    || usage_error 'PRINTER_APP_SERVER_OPTIONS must be a comma-separated list of PAPPL server options'
  IFS=, read -r -a requested_server_options <<< "$PRINTER_APP_SERVER_OPTIONS"
  for option in "${requested_server_options[@]}"; do
    allowed=0
    for candidate in "${allowed_server_options[@]}"; do
      [[ "$option" == "$candidate" ]] && allowed=1
    done
    ((allowed)) || usage_error "PRINTER_APP_SERVER_OPTIONS contains unsupported option '${option}'; supported: ${allowed_server_options[*]}"
    server_options+=("$option")
  done
fi

# Syntax first (exit 64), then what this image can honour (exit 78), so a
# malformed value is diagnosed the same way on any host.
if [[ -n "${PRINTER_APP_AUTH_SERVICE:-}" ]]; then
  [[ "$PRINTER_APP_AUTH_SERVICE" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
    || usage_error 'PRINTER_APP_AUTH_SERVICE must be a PAM service name: letters, digits, "_", "." or "-", not starting with "." or "-"'
fi
if [[ -n "${PRINTER_APP_ADMIN_GROUP:-}" ]]; then
  [[ "$PRINTER_APP_ADMIN_GROUP" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] \
    || usage_error 'PRINTER_APP_ADMIN_GROUP must be a group name: letters, digits, "_", "." or "-", starting with a letter or "_"'
fi

# While the shared printing base builds PAPPL with --disable-libpam, PAPPL
# cannot authenticate users via PAM and forwarding an auth service locks every
# administrator out with 401. Refuse PRINTER_APP_AUTH_SERVICE outright with
# exit 78; set PRINTER_APP_SERVER_OPTIONS=no-web-interface to disable web
# administration instead.
if [[ -n "${PRINTER_APP_AUTH_SERVICE:-}" ]]; then
  config_error "PRINTER_APP_AUTH_SERVICE=${PRINTER_APP_AUTH_SERVICE} cannot be honoured (PAPPL is built without PAM); set PRINTER_APP_SERVER_OPTIONS=no-web-interface to disable web administration instead"
fi

# admin-group only restricts who may administer once auth-service authenticates
# them, and PAPPL treats an unresolvable group as "no group check", so both an
# unset auth service and an unknown group would start unauthenticated.
if [[ -n "${PRINTER_APP_ADMIN_GROUP:-}" ]]; then
  [[ -n "${PRINTER_APP_AUTH_SERVICE:-}" ]] \
    || config_error 'PRINTER_APP_ADMIN_GROUP requires PRINTER_APP_AUTH_SERVICE; a group cannot be enforced without authentication'
  group_known=0
  while IFS=: read -r group_name _; do
    [[ "$group_name" == "$PRINTER_APP_ADMIN_GROUP" ]] && group_known=1
  done < /etc/group
  ((group_known)) \
    || config_error "PRINTER_APP_ADMIN_GROUP=${PRINTER_APP_ADMIN_GROUP} is not a group in this image's /etc/group; PAPPL would skip the group check and admit every authenticated user"
fi

state_dir=/var/lib/gutenprint-printer-app
# Print jobs, TLS keys and printer state are owner-only: new files inherit
# umask 077, and the directory modes are reapplied on every start because a
# mounted volume hides the image's. Never follow a symlink out of the volume.
umask 077
private_dirs=("$state_dir/spool" "$state_dir/cups/ssl")
for dir in "$state_dir" "$state_dir/cups" "${private_dirs[@]}"; do
  if [[ -L "$dir" ]]; then
    printf '%s must not be a symlink\n' "$dir" >&2
    exit 1
  fi
done
mkdir -p "$state_dir/ppd" "$state_dir/usb" "${private_dirs[@]}" /run/dbus /run/avahi-daemon /run/gutenprint-printer-app
chmod 0700 "${private_dirs[@]}"
# The image's own state directory is root-owned 0777 (BuildStream artifacts
# carry no ownership), and a volume root may belong to the operator: secure
# it only when this user owns it, as with `podman unshare chown 65532:65532`.
if [[ -O "$state_dir" ]]; then
  chmod 0700 "$state_dir"
fi
if [[ ! -e "$state_dir/cups/snmp.conf" && ! -L "$state_dir/cups/snmp.conf" ]]; then
  cp /etc/cups/snmp.conf "$state_dir/cups/snmp.conf"
fi
for defaults in /usr/share/cups/usb/org.cups.usb-quirks /usr/lib/gutenprint-printer-app/backend/net.sf.gimp-print.usb-quirks; do
  target="$state_dir/usb/${defaults##*/}"
  if [[ ! -e "$target" && ! -L "$target" ]]; then
    cp "$defaults" "$target"
  fi
done

export BACKEND_DIR=/usr/lib/gutenprint-printer-app/backend
export CUPS_SERVERBIN=/usr/lib/gutenprint-printer-app
export CUPS_SERVERROOT="$state_dir/cups"
export FILTER_DIR=/usr/lib/gutenprint-printer-app/filter
export PATH="$FILTER_DIR:$PATH"
export PPDC_DATADIR=/usr/share/ppdc
export PPD_PATHS="/usr/share/ppd/:$state_dir/ppd/"
export SPOOL_DIR="$state_dir/spool"
export STATE_DIR="$state_dir"
export STATE_FILE="$state_dir/gutenprint-printer-app.state"
export TESTPAGE_DIR=/usr/share/gutenprint-printer-app
export TMPDIR=/tmp
export USB_QUIRK_DIR="$state_dir"

children=()
stop_children() {
  local index pid
  for ((index = ${#children[@]} - 1; index >= 0; index--)); do
    pid="${children[index]}"
    kill -TERM "$pid" 2>/dev/null || true
  done
  wait "${children[@]}" 2>/dev/null || true
}
handle_signal() {
  trap - TERM INT EXIT
  stop_children
  exit 143
}
trap handle_signal TERM INT
trap stop_children EXIT

dbus-daemon --system --nofork --nopidfile &
children+=("$!")
for _ in $(seq 1 30); do
  [[ -S /run/dbus/system_bus_socket ]] && break
  sleep 0.1
done
[[ -S /run/dbus/system_bus_socket ]]

avahi-daemon --no-drop-root --no-chroot &
children+=("$!")
for _ in $(seq 1 30); do
  [[ -f /run/avahi-daemon/pid ]] && break
  sleep 0.1
done
[[ -f /run/avahi-daemon/pid ]]

args=(-o "log-file=$state_dir/gutenprint-printer-app.log")
args+=(-o "server-port=${PORT:-18050}")
if ((${#server_options[@]} > 0)); then
  args+=(-o "server-options=$(IFS=,; printf '%s' "${server_options[*]}")")
fi
if [[ -n "${PRINTER_APP_AUTH_SERVICE:-}" ]]; then
  args+=(-o "auth-service=$PRINTER_APP_AUTH_SERVICE")
fi
if [[ -n "${PRINTER_APP_ADMIN_GROUP:-}" ]]; then
  args+=(-o "admin-group=$PRINTER_APP_ADMIN_GROUP")
fi

web_interface_disabled=0
for option in "${server_options[@]}"; do
  [[ "$option" == no-web-interface ]] && web_interface_disabled=1
done
if [[ -z "${PRINTER_APP_AUTH_SERVICE:-}" ]] && ((!web_interface_disabled)); then
  printf 'NOTICE: web administration is reachable by every client that can reach the IPP port; set PRINTER_APP_SERVER_OPTIONS=no-web-interface to disable it\n' >&2
fi

gutenprint-printer-app "${args[@]}" server &
children+=("$!")

if wait -n "${children[@]}"; then
  status=1
else
  status=$?
fi
stop_children
trap - TERM INT EXIT
exit "$status"
