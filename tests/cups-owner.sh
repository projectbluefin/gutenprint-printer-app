#!/usr/bin/env bash
set -euo pipefail

owner=ghostscript-fsdk.bst:freedesktop-sdk.bst:components/_private/cups-base.bst
graph="$(just bst show --deps all --format '%{name}' oci/gutenprint-printer-app.bst)"
count="$(grep -cFx "$owner" <<< "$graph" || true)"
if [[ "$count" -ne 1 ]]; then
  printf 'Expected exactly one FSDK CUPS source owner %s, found %s\n' "$owner" "$count" >&2
  exit 1
fi
printf 'OK: Gutenprint image uses one shared, patched FSDK CUPS source artifact\n'
