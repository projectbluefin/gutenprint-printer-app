#!/usr/bin/env bash
# Fail-closed checks for the web-administration knobs of
# files/container-entrypoint.sh. Every case here must be rejected before the
# entrypoint touches persistent state, so this runs on the host without the
# image; the accepted values are exercised against the real image by
# tests/appliance.sh.
set -Eeuo pipefail

entrypoint="$(dirname "$0")/../files/container-entrypoint.sh"
failures=0

# expect_rejection <exit status> <diagnostic substring> NAME=VALUE...
expect_rejection() {
  local expected_status="$1" expected_message="$2"
  shift 2
  local output status
  set +e
  output="$(env -i PATH="$PATH" "$@" bash "$entrypoint" 2>&1 </dev/null)"
  status=$?
  set -e
  if [[ "$status" -ne "$expected_status" || "$output" != *"$expected_message"* ]]; then
    printf 'FAIL: %s exited %s (expected %s) with: %s\n' "$*" "$status" "$expected_status" "$output" >&2
    failures=$((failures + 1))
  else
    printf 'ok: %s -> %s\n' "$*" "$status"
  fi
}

expect_rejection 64 'PORT must be numeric' PORT=invalid

# Only allow-listed PAPPL server options are forwarded; pappl-retrofit would
# silently drop anything else, and no-tls / none weaken the appliance.
expect_rejection 64 "unsupported option 'no-tls'" PRINTER_APP_SERVER_OPTIONS=no-tls
expect_rejection 64 "unsupported option 'none'" PRINTER_APP_SERVER_OPTIONS=none
expect_rejection 64 "unsupported option 'web-remote'" PRINTER_APP_SERVER_OPTIONS=no-web-interface,web-remote
expect_rejection 64 'comma-separated list' PRINTER_APP_SERVER_OPTIONS=no-web-interface,
expect_rejection 64 'comma-separated list' PRINTER_APP_SERVER_OPTIONS='no-web-interface no-tls'
expect_rejection 64 'comma-separated list' PRINTER_APP_SERVER_OPTIONS='No-Web-Interface'

# A PAM service name is a file name under /etc/pam.d.
expect_rejection 64 'PRINTER_APP_AUTH_SERVICE must be a PAM service name' PRINTER_APP_AUTH_SERVICE=../shadow
expect_rejection 64 'PRINTER_APP_AUTH_SERVICE must be a PAM service name' PRINTER_APP_AUTH_SERVICE='login other'
expect_rejection 64 'PRINTER_APP_AUTH_SERVICE must be a PAM service name' PRINTER_APP_AUTH_SERVICE=-login
expect_rejection 64 'PRINTER_APP_AUTH_SERVICE must be a PAM service name' PRINTER_APP_AUTH_SERVICE='a=b'

# A group is only meaningful once an auth service authenticates users, and
# PAPPL skips the group check entirely for a group it cannot resolve.
expect_rejection 64 'PRINTER_APP_ADMIN_GROUP must be a group name' PRINTER_APP_ADMIN_GROUP='bad;group'
expect_rejection 64 'PRINTER_APP_ADMIN_GROUP must be a group name' PRINTER_APP_ADMIN_GROUP='1admins'
expect_rejection 78 'PRINTER_APP_ADMIN_GROUP requires PRINTER_APP_AUTH_SERVICE' PRINTER_APP_ADMIN_GROUP=wheel
expect_rejection 78 'set PRINTER_APP_SERVER_OPTIONS=no-web-interface to disable web administration instead' PRINTER_APP_AUTH_SERVICE=nonexistent-pam-service
expect_rejection 78 'set PRINTER_APP_SERVER_OPTIONS=no-web-interface to disable web administration instead' PRINTER_APP_AUTH_SERVICE=cups

if ((failures > 0)); then
  printf 'FAIL: %d entrypoint validation case(s) did not fail closed\n' "$failures" >&2
  exit 1
fi
printf 'OK: entrypoint rejects malformed web-administration settings\n'
