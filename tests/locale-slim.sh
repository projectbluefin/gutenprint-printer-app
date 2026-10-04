#!/usr/bin/env bash
set -euo pipefail

# Runtime compose slimming (issue #56): the FSDK stack's locale catalogs
# (coreutils.mo, glib20.mo, bash.mo, libc.mo, ...) total ~56 MiB and are
# unrelated to Gutenprint. The OCI layer keeps only the gutenprint domain the
# PPD generator and the app need: gutenprint.mo plus the
# /usr/share/locale/<lang>/gutenprint_<lang>.po catalogues it reads
# (docs/calibration-payload.md). This asserts no other file under
# /usr/share/locale reaches the image, and that Gutenprint's own catalogs are
# still present. Run by `just verify` against the built image.
#
# Usage: IMAGE=<image-ref> tests/locale-slim.sh
IMAGE="${IMAGE:-ghcr.io/projectbluefin/gutenprint-printer-app:build}"
root="$(mktemp -d)"
ctr="$(podman create "${IMAGE}" /none)"
cleanup() {
  podman rm "${ctr}" >/dev/null 2>&1 || true
  chmod -R u+w "${root}" 2>/dev/null || true
  rm -rf "${root}"
}
trap cleanup EXIT
podman export "${ctr}" | tar -C "${root}" -xf -

# Every shipped file under /usr/share/locale must belong to the gutenprint
# domain; anything else is an unrelated FSDK catalog that must not ship.
unrelated="$(cd "${root}" && find usr/share/locale -type f ! -name 'gutenprint*' -print -quit)"
[ -z "${unrelated}" ] || { echo "unrelated locale catalogs in ${IMAGE}: ${unrelated}" >&2; exit 1; }

# Gutenprint's own catalogs must still be present: the .mo the app loads and
# the .po the PPD generator reads (docs/calibration-payload.md).
mo="$(cd "${root}" && find usr/share/locale -name 'gutenprint.mo' -print -quit)"
po="$(cd "${root}" && find usr/share/locale -name 'gutenprint_*.po' -print -quit)"
[ -n "${mo}" ]  || { echo "gutenprint.mo missing from ${IMAGE}" >&2; exit 1; }
[ -n "${po}" ]  || { echo "gutenprint_<lang>.po catalogues missing from ${IMAGE}" >&2; exit 1; }

catalog_count="$(cd "${root}" && find usr/share/locale -name 'gutenprint*' -type f | wc -l)"
(( catalog_count >= 20 )) || \
  { echo "only ${catalog_count} gutenprint locale files retained, expected at least 20" >&2; exit 1; }

printf 'OK: %s ships only the gutenprint locale domain (%s files)\n' "${IMAGE}" "${catalog_count}"
