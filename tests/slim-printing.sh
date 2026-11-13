#!/usr/bin/env bash
set -euo pipefail

# Read both lists from the resolved element so the shared list follows the pin.
IMAGE="${IMAGE:-ghcr.io/projectbluefin/gutenprint-printer-app:build}"
root="$(mktemp -d)"
ctr=""
cleanup() {
  if [ -n "${ctr}" ]; then podman rm "${ctr}" >/dev/null 2>&1 || true; fi
  chmod -R u+w "${root}" 2>/dev/null || true
  rm -rf "${root}"
}
trap cleanup EXIT
just bst show --deps none --format '%{vars}' oci/gutenprint-printer-app.bst \
  | python3 -c 'import sys, yaml; v = yaml.safe_load(sys.stdin); print(v["slim-printing-forbidden-paths"]); print(v["app-forbidden-paths"])' \
  > "${root}/forbidden"
mkdir "${root}/image"
ctr="$(podman create "${IMAGE}" /none)"
podman export "${ctr}" | tar -C "${root}/image" -xf -
shopt -s nullglob globstar
bad=0
while IFS= read -r pattern; do
  [ -n "${pattern}" ] || continue
  for match in "${root}/image"/${pattern}; do
    [ -e "${match}" ] || [ -L "${match}" ] || continue
    echo "forbidden path in ${IMAGE}: ${match#"${root}/image"}" >&2
    bad=1
  done
done < "${root}/forbidden"
[ "${bad}" -eq 0 ]
printf 'OK: %s contains no forbidden slim-printing paths\n' "${IMAGE}"
