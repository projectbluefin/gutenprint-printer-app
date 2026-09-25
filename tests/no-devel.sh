#!/usr/bin/env bash
set -euo pipefail

# fsdk-containers printing-base consumer contract, rule 5: the image is
# composed from runtime domains only, so no headers, static or libtool
# archives, pkg-config or CMake files may reach it.
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
# License texts are notices, not devel content: prune, never delete them.
bad="$(cd "${root}" && find . -path ./usr/share/licenses -prune -o \( -path ./usr/include -o -name '*.a' -o -name '*.la' \
      -o -type d -name pkgconfig -o -type d -name cmake \) -print -quit)"
[ -z "${bad}" ] || { echo "devel content in ${IMAGE}: ${bad}" >&2; exit 1; }
printf 'OK: %s holds no devel content\n' "${IMAGE}"
