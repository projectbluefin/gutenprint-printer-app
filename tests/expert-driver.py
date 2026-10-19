#!/usr/bin/env python3
"""Print the expert Gutenprint driver name for one printer model.

Reads the output of `gutenprint-printer-app -u ... drivers` on stdin and
prints the driver name of the row whose description is exactly
"<model> (en)". Every image test that adds a printer selects its driver
through this script, so the listing format is parsed in one place.

Rows are parsed like tests/device-selection.py does: shell-quoted, exactly
three fields (name, description, device ID). Exits non-zero, with the
listing on stderr, when the listing is malformed, no row matches, or the
matched name is not a plain [a-z0-9-] driver name.
"""
import re
import shlex
import sys

NAME = re.compile(r"[a-z0-9-]+")


def expert_driver(listing, model):
    wanted = f"{model} (en)"
    for line in listing.splitlines():
        if not line.strip():
            continue
        row = shlex.split(line)
        if len(row) != 3:
            raise ValueError(f"unexpected driver listing row: {line!r}")
        name, description, _device_id = row
        if description == wanted:
            if not NAME.fullmatch(name):
                raise ValueError(f"driver name {name!r} for {wanted!r} is not [a-z0-9-]")
            return name
    raise LookupError(f"no expert {model!r} driver in the live catalog")


def main(argv):
    if len(argv) != 2 or not argv[1]:
        print("usage: expert-driver.py <model> < drivers-listing", file=sys.stderr)
        return 2
    listing = sys.stdin.read()
    try:
        print(expert_driver(listing, argv[1]))
    except (LookupError, ValueError) as err:
        print(f"expert-driver: {err}", file=sys.stderr)
        print(listing, file=sys.stderr, end="")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
