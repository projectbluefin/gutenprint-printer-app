#!/bin/sh
#
# Verify the USB printing payload of a built gutenprint-printer-app image.
#
# Run this *inside* the image under test, so that the backends and "ldd"
# resolve against the image's own libraries instead of the host's:
#
#   docker run --rm --entrypoint /bin/sh \
#       -v "$PWD/tests:/tests:ro" \
#       gutenprint-printer-app:latest /tests/check-usb-backend-payload.sh
#
# It checks the acceptance criteria for the dye-sublimation USB backend:
#   * the backend executables and the vendor quirk tables are present,
#   * the backends resolve every shared library they link against,
#   * device discovery with no printer attached terminates safely.
#
# Physical paper output cannot be verified here; it needs real hardware.
#
# USB_BACKEND_DIR relocates the checks for images which install the backends
# elsewhere, such as the BuildStream/FSDK layout.  It defaults to the path
# Rockcraft primes, which is what CI checks.  Note that the ownership check
# below still requires the backends to belong to root, so pointing this at an
# unprivileged fixture outside a container cannot produce a passing run.

set -u

backend_dir=${USB_BACKEND_DIR:-/usr/lib/gutenprint-printer-app/backend}
failures=0

fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

pass() {
    echo "ok: $*"
}

# --- Payload: executables and quirk tables are present ---------------------

for backend in usb gutenprint53+usb; do
    path="$backend_dir/$backend"

    if [ ! -f "$path" ]; then
        fail "USB backend $path is missing"
        continue
    fi

    mode=$(stat -c '%a' "$path")
    owner=$(stat -c '%u:%g' "$path")

    # The run user ("_daemon_") must be able to start the backend...
    if [ ! -x "$path" ]; then
        fail "$path is not executable (mode $mode)"
    fi
    # ...and the set-user-ID bit is what lets it reach the USB device nodes.
    # Compare inside the arithmetic expansion: a bare "04000" on the right
    # hand side of "[" would be read as decimal 4000, not octal.
    if [ "$((0$mode & 04000))" -eq 0 ]; then
        fail "$path is missing the set-user-ID bit (mode $mode)"
    fi
    if [ "$owner" != "0:0" ]; then
        fail "$path is not owned by root (owner $owner)"
    fi

    echo "  $path mode=$mode owner=$owner"
done

for quirk in org.cups.usb-quirks net.sf.gimp-print.usb-quirks; do
    if [ ! -f "$backend_dir/$quirk" ]; then
        fail "USB quirk table $backend_dir/$quirk is missing"
    elif [ ! -r "$backend_dir/$quirk" ]; then
        fail "USB quirk table $backend_dir/$quirk is not readable"
    else
        pass "quirk table $quirk is present ($(wc -l <"$backend_dir/$quirk") lines)"
    fi
done

# --- Linked libraries resolve ---------------------------------------------

if command -v ldd >/dev/null 2>&1; then
    for backend in usb gutenprint53+usb; do
        path="$backend_dir/$backend"
        [ -f "$path" ] || continue

        resolution=$(ldd "$path" 2>&1)
        if printf '%s\n' "$resolution" | grep -q 'not found'; then
            fail "$path has unresolved shared libraries:"
            printf '%s\n' "$resolution" | grep 'not found' >&2
        else
            pass "$path resolves all $(printf '%s\n' "$resolution" | grep -c '=>') linked libraries"
        fi
    done
else
    fail "ldd is unavailable, cannot verify library resolution"
fi

# --- Device discovery with no printer attached -----------------------------

# A backend which blocks forever on a missing printer is not a safe exit, so
# bound the run when the image provides a timeout command.
discover() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 30 "$@"
    else
        "$@"
    fi
}

for backend in usb gutenprint53+usb; do
    path="$backend_dir/$backend"
    [ -f "$path" ] || continue

    output=$(cd /tmp && discover "$path" 2>&1)
    status=$?

    if [ "$status" -eq 124 ]; then
        fail "$backend did not terminate within 30s during device discovery"
        continue
    fi
    # A CUPS backend reports discovered devices on stdout and exits 0; an
    # empty device list is not an error.  Anything else - a signal, a core
    # dump, a crash - is not a safe no-printer exit.
    if [ "$status" -gt 1 ]; then
        fail "$backend exited with status $status when no printer was attached"
        printf '%s\n' "$output" >&2
        continue
    fi

    pass "$backend exited $status during discovery with no printer attached"
    if [ -n "$output" ]; then
        printf '  %s output: %s\n' "$backend" "$(printf '%s' "$output" | head -n 3 | tr '\n' ' ')"
    fi
done

if [ "$failures" -ne 0 ]; then
    echo "$failures USB backend payload check(s) failed" >&2
    exit 1
fi

echo "USB backend payload checks passed"
