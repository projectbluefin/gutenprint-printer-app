#!/bin/sh
#
# Give the CUPS-style USB backends in a primed image root the ownership and
# permissions they need to talk to a printer's USB device nodes.
#
# Usage: harden-usb-backends.sh <image-root>
#
# The Printer Application runs as the non-root user "_daemon_" (see
# "run-user:" in rockcraft.yaml), but a device backend needs raw access to
# the USB device nodes of the printer.  As in a classic CUPS installation we
# therefore hand both backends to root and give them the set-user-ID bit, so
# that "_daemon_" can start them and their USB I/O runs with root privileges.
#
# Gutenprint deliberately installs its dye-sublimation backend with mode 700
# ("CUPS backends require no world-execute permissions if they are to be
# executed as root", src/cups/Makefile.am install-exec-hook).  A plain
# "chmod u+s" is not enough: it would leave "_daemon_" unable to execute the
# backend at all, which silently costs us all dye-sublimation printer
# support.  The backend must be made executable for others as well.

set -eu

root=${1:?usage: harden-usb-backends.sh <image-root>}
backend_dir="$root/usr/lib/gutenprint-printer-app/backend"

for backend in usb gutenprint53+usb; do
    path="$backend_dir/$backend"

    # A missing backend means the image silently lost USB printing support,
    # so fail the build rather than shipping without it.
    if [ ! -f "$path" ]; then
        echo "ERROR: USB backend '$backend' is missing from $backend_dir" >&2
        exit 1
    fi

    # craft-parts builds as root, so the backends are already owned by root;
    # state that explicitly, as the image must not depend on build defaults.
    # Only root may change ownership, so keep the mode work below working for
    # unprivileged callers such as the test suite.
    if [ "$(id -u)" = 0 ]; then
        chown 0:0 "$path"
    fi

    chmod 4755 "$path"
done

# The vendor quirk tables ship next to the backends, where the launcher seeds
# them into writable state for the "USB_QUIRK_DIR" of the patched CUPS
# backend.  Losing them silently changes which printers are recognized.
for quirk in org.cups.usb-quirks net.sf.gimp-print.usb-quirks; do
    if [ ! -f "$backend_dir/$quirk" ]; then
        echo "ERROR: USB quirk table '$quirk' is missing from $backend_dir" >&2
        exit 1
    fi
    chmod 644 "$backend_dir/$quirk"
done
