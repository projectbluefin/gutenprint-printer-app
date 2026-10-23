#!/usr/bin/env bash
# Exercise the launch and supervision tail of files/container-entrypoint.sh on
# the host, without building or running the OCI image.
#
# The entrypoint is PID 1 of the appliance: it builds the PAPPL command line,
# starts dbus-daemon, avahi-daemon and gutenprint-printer-app, and its traps
# are the only thing that stops them. The image suites never signal the
# container or kill one of its daemons, so stop_children(), handle_signal() and
# the `wait -n` status propagation are otherwise unexecuted. A regression here
# is a container that leaves daemons behind, hangs on shutdown, reports success
# after a daemon died, or forwards the wrong options to PAPPL.
#
# Three blocks are sliced out of the entrypoint by marker, so the test runs the
# real code rather than a copy, and fails loudly if a marker disappears:
#   supervision  children=()                        .. trap stop_children EXIT
#   arguments    args=(-o "log-file=...")           .. line before the server launch
#   launch       gutenprint-printer-app ... server & .. end of file
# dbus-daemon and avahi-daemon are replaced by stand-ins started by the harness,
# and gutenprint-printer-app by a stub on PATH that records its arguments.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
entrypoint="$root/files/container-entrypoint.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

line_of() {
  local pattern="$1" line
  line="$(grep -n -E "$pattern" "$entrypoint" | head -n 1 | cut -d: -f1)"
  if [[ -z "${line:-}" ]]; then
    printf 'tests/entrypoint-supervisor.sh: no line matching %s in %s\n' "$pattern" "$entrypoint" >&2
    exit 1
  fi
  printf '%s\n' "$line"
}

supervision_start="$(line_of '^children=\(\)$')"
supervision_end="$(line_of '^trap stop_children EXIT$')"
arguments_start="$(line_of '^args=\(-o "log-file=')"
launch_start="$(line_of '^gutenprint-printer-app "\$\{args\[@\]\}" server &$')"
if ((supervision_end <= supervision_start || arguments_start <= supervision_end || launch_start <= arguments_start)); then
  printf 'tests/entrypoint-supervisor.sh: unexpected block order in %s\n' "$entrypoint" >&2
  exit 1
fi
sed -n "${supervision_start},${supervision_end}p" "$entrypoint" >"$work/supervision.sh"
sed -n "${arguments_start},$((launch_start - 1))p" "$entrypoint" >"$work/arguments.sh"
sed -n "${launch_start},\$p" "$entrypoint" >"$work/launch.sh"

# A stand-in daemon. It announces itself only once its TERM trap is installed,
# records its name when stopped, and in exit:N mode exits N once all three
# children are up, so "a daemon died while the appliance was running" is
# deterministic and no sibling can be stopped before its trap exists.
child="$work/child.sh"
cat >"$child" <<'CHILD'
#!/usr/bin/env bash
name="$1" ready="$2" mode="$3" stopped="$4"
trap 'printf "%s\n" "$name" >>"$stopped"; exit 0' TERM
: >"$ready.$name"
case "$mode" in
  run) while :; do sleep 0.05; done ;;
  exit:*)
    for peer in dbus-daemon avahi-daemon gutenprint-printer-app; do
      while [[ ! -e "$ready.$peer" ]]; do sleep 0.05; done
    done
    exit "${mode#exit:}"
    ;;
esac
CHILD
chmod +x "$child"

mkdir "$work/bin"
cat >"$work/bin/gutenprint-printer-app" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$SERVER_ARGS"
exec "$CHILD" gutenprint-printer-app "$READY" "$SERVER_MODE" "$STOPPED"
STUB
chmod +x "$work/bin/gutenprint-printer-app"

# Sources the three slices in entrypoint order. stop_children is wrapped to
# count calls, and kill to record which child each TERM targets, by position:
# the entrypoint starts dbus-daemon, avahi-daemon, gutenprint-printer-app.
cat >"$work/harness.sh" <<HARNESS
#!/usr/bin/env bash
set -euo pipefail
dbus_mode="\$1"
shift
server_options=("\$@")
printf '%s\n' "\$\$" >"\${HARNESS_PID:-/dev/null}"
source "$work/supervision.sh"
eval "original_\$(declare -f stop_children)"
stop_children() { printf 'stop\n' >>"\$CALLS"; original_stop_children; }
names=(dbus-daemon avahi-daemon gutenprint-printer-app)
kill() {
  local index
  if [[ "\${1:-}" == -TERM ]]; then
    for index in "\${!children[@]}"; do
      [[ "\${children[index]}" == "\${2:-}" ]] && printf '%s\n' "\${names[index]}" >>"\$ORDER"
    done
  fi
  builtin kill "\$@"
}
"\$CHILD" dbus-daemon "\$READY" "\$dbus_mode" "\$STOPPED" &
children+=("\$!")
"\$CHILD" avahi-daemon "\$READY" run "\$STOPPED" &
children+=("\$!")
source "$work/arguments.sh"
source "$work/launch.sh"
HARNESS

failures=0
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}
pass() { printf 'ok: %s\n' "$1"; }

case_dir=""
new_case() {
  case_dir="$(mktemp -d "$work/case.XXXXXX")"
  mkdir "$case_dir/state"
  : >"$case_dir/order"
  : >"$case_dir/calls"
  : >"$case_dir/stopped"
}

# harness_env: environment for one harness run in $case_dir.
harness_env() {
  printf '%s\n' \
    "PATH=$work/bin:$PATH" \
    "CHILD=$child" \
    "READY=$case_dir/ready" \
    "STOPPED=$case_dir/stopped" \
    "ORDER=$case_dir/order" \
    "CALLS=$case_dir/calls" \
    "SERVER_ARGS=$case_dir/args"
}

# run_harness <server mode> <dbus mode> [server option...]
# Extra environment (PORT, PRINTER_APP_*) is passed through EXTRA_ENV.
run_harness() {
  local server_mode="$1" dbus_mode="$2" env_lines=()
  shift 2
  mapfile -t env_lines < <(harness_env)
  set +e
  env -i "${env_lines[@]}" "SERVER_MODE=$server_mode" state_dir="$case_dir/state" ${EXTRA_ENV:-} \
    timeout 30 bash "$work/harness.sh" "$dbus_mode" "$@" 2>"$case_dir/stderr"
  status=$?
  set -e
}

await_ready() {
  local want="$1" waited=0 seen file
  while :; do
    seen=0
    for file in "$case_dir"/ready.*; do
      [[ -e "$file" ]] && seen=$((seen + 1))
    done
    ((seen >= want)) && return 0
    ((++waited > 400)) && return 1
    sleep 0.05
  done
}

expect_stopped_once() {
  local label="$1" want
  for want in "${@:2}"; do
    [[ "$(grep -c -x "$want" "$case_dir/stopped" || true)" == 1 ]] \
      || fail "$label: $want was not stopped exactly once (stopped: $(paste -sd, "$case_dir/stopped"))"
  done
}

# --- PAPPL command line -------------------------------------------------------

new_case
EXTRA_ENV="" run_harness exit:0 run
expected="$(printf '%s\n' -o "log-file=$case_dir/state/gutenprint-printer-app.log" -o server-port=18050 server)"
if [[ "$(cat "$case_dir/args")" == "$expected" ]]; then
  pass 'defaults pass log-file and the default port 18050 to PAPPL'
else
  fail "defaults: gutenprint-printer-app got: $(paste -sd' ' "$case_dir/args")"
fi
if grep -q '^NOTICE: web administration is reachable' "$case_dir/stderr"; then
  pass 'open web administration prints the NOTICE'
else
  fail "open web administration did not print the NOTICE: $(cat "$case_dir/stderr")"
fi

new_case
EXTRA_ENV="PORT=8000" run_harness exit:0 run no-web-interface
expected="$(printf '%s\n' -o "log-file=$case_dir/state/gutenprint-printer-app.log" \
  -o server-port=8000 -o server-options=no-web-interface server)"
if [[ "$(cat "$case_dir/args")" == "$expected" ]]; then
  pass 'PORT and server options are forwarded to PAPPL'
else
  fail "PORT/no-web-interface: gutenprint-printer-app got: $(paste -sd' ' "$case_dir/args")"
fi
if grep -q NOTICE "$case_dir/stderr"; then
  fail 'no-web-interface still printed the web administration NOTICE'
else
  pass 'no-web-interface suppresses the NOTICE'
fi

new_case
EXTRA_ENV="" run_harness exit:0 run no-web-interface no-web-interface
if grep -qx 'server-options=no-web-interface,no-web-interface' "$case_dir/args"; then
  pass 'repeated server options are joined with commas'
else
  fail "repeated options: gutenprint-printer-app got: $(paste -sd' ' "$case_dir/args")"
fi

# --- exit status propagation --------------------------------------------------

new_case
EXTRA_ENV="" run_harness exit:0 run
if ((status == 1)); then
  pass 'server exiting 0 still fails the container (exit 1)'
else
  fail "server exiting 0: container exited $status, expected 1"
fi
expect_stopped_once 'server exiting 0' dbus-daemon avahi-daemon
if [[ "$(paste -sd, "$case_dir/order")" == gutenprint-printer-app,avahi-daemon,dbus-daemon ]]; then
  pass 'children are stopped newest first'
else
  fail "stop order: $(paste -sd, "$case_dir/order"), expected gutenprint-printer-app,avahi-daemon,dbus-daemon"
fi
[[ "$(grep -c -x stop "$case_dir/calls" || true)" == 1 ]] \
  || fail "server exiting 0: stop_children ran $(grep -c -x stop "$case_dir/calls" || true) times, expected 1"

new_case
EXTRA_ENV="" run_harness exit:7 run
if ((status == 7)); then
  pass "server's failure status is the container's exit status"
else
  fail "server exiting 7: container exited $status, expected 7"
fi
expect_stopped_once 'server exiting 7' dbus-daemon avahi-daemon

new_case
EXTRA_ENV="" run_harness run exit:3
if ((status == 3)); then
  pass "a dying dbus-daemon stops the appliance with its status"
else
  fail "dbus-daemon exiting 3: container exited $status, expected 3"
fi
expect_stopped_once 'dbus-daemon exiting 3' avahi-daemon gutenprint-printer-app

# --- stop on request ----------------------------------------------------------

# Async commands in a non-interactive shell start with SIGINT ignored, and bash
# cannot trap a signal ignored on entry; restore the default so INT reaches the
# entrypoint's trap as it would for PID 1.
for signal in TERM INT; do
  new_case
  mapfile -t env_lines < <(harness_env)
  env -i "${env_lines[@]}" SERVER_MODE=run state_dir="$case_dir/state" HARNESS_PID="$case_dir/pid" \
    env --default-signal=INT timeout --foreground 30 bash "$work/harness.sh" run 2>"$case_dir/stderr" &
  timeout_pid=$!
  if ! await_ready 3; then
    fail "SIG$signal: children never became ready"
    builtin kill -KILL "$timeout_pid" 2>/dev/null || true
    wait "$timeout_pid" 2>/dev/null || true
    continue
  fi
  # Signal the harness itself, as the runtime signals PID 1. Signalling timeout
  # would test its forwarding instead: uutils timeout exits 128+signal rather
  # than with the child's status. timeout only guards against a hang.
  builtin kill "-$signal" "$(<"$case_dir/pid")"
  set +e
  wait "$timeout_pid"
  status=$?
  set -e
  if ((status == 143)); then
    pass "SIG$signal stops the appliance with exit 143"
  else
    fail "SIG$signal: container exited $status, expected 143"
  fi
  expect_stopped_once "SIG$signal" dbus-daemon avahi-daemon gutenprint-printer-app
  calls="$(grep -c -x stop "$case_dir/calls" || true)"
  ((calls == 1)) || fail "SIG$signal: stop_children ran $calls times, expected 1 (EXIT trap not disarmed?)"
done

if ((failures > 0)); then
  printf 'FAIL: %d entrypoint supervision check(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'OK: entrypoint launches, supervises and stops its daemons as specified\n'
