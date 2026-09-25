#!/usr/bin/env bash
set -euo pipefail

owner=fsdk-containers.bst:freedesktop-sdk.bst:components/_private/cups-base.bst
graph="$(just bst show --deps all --format '%{name}' oci/gutenprint-printer-app.bst)"
count="$(grep -cFx "$owner" <<< "$graph" || true)"
if [[ "$count" -ne 1 ]]; then
  printf 'Expected exactly one FSDK CUPS source owner %s, found %s\n' "$owner" "$count" >&2
  exit 1
fi
# avahi-printing.bst is the base's nonroot avahi-daemon; FSDK's avahi.bst
# installs the same daemon and must never be staged next to it.
if grep -qFx fsdk-containers.bst:freedesktop-sdk.bst:components/avahi.bst <<< "$graph"; then
  printf 'components/avahi.bst is staged next to the printing base avahi-printing.bst\n' >&2
  exit 1
fi
printf 'OK: Gutenprint image uses the one shared, patched fsdk-containers printing-base CUPS\n'
