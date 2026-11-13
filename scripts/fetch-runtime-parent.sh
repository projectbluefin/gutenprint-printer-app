#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
arch="$(uname -m)"
case "$arch" in x86_64|aarch64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
key="$(just bst -o arch "$arch" show --deps none --format '%{full-key}' fsdk-containers.bst:oci/printing-runtime-layer.bst | tail -n 1 | sed 's/\x1b\[[0-9;]*m//g')"
[[ "$key" =~ ^[0-9a-f]{64}$ ]] || { echo "Invalid runtime layer key: $key" >&2; exit 1; }
repo=ghcr.io/projectbluefin/printing-runtime-layer
digest="$(skopeo inspect --format '{{.Digest}}' "docker://${repo}:${arch}-${key}")"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "Invalid runtime layer digest: $digest" >&2; exit 1; }
ref="${repo}@${digest}"
cosign verify \
  --certificate-identity https://github.com/projectbluefin/fsdk-containers/.github/workflows/printing-runtime-layer.yml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com "$ref" >/dev/null
tmp="$(mktemp -d "${PWD}/.runtime-parent.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
skopeo copy --preserve-digests "docker://${ref}" "oci:${tmp}:layer"
touch "$tmp/.gitkeep"
rm -rf runtime-parent
mv "$tmp" runtime-parent
