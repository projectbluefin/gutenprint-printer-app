#!/usr/bin/env bash
set -euo pipefail

# The shipped image must carry exactly the pinned source metadata: the version
# label and the Gutenprint commit label come from printer-app/version.bst, so a
# proposal that changed include/source-pins.yml without rebuilding, or a stale
# artifact, shows up here rather than in the released index.
cd "$(dirname "${BASH_SOURCE[0]}")/.."
IMAGE="${IMAGE:-ghcr.io/projectbluefin/gutenprint-printer-app:build}"

pin() { sed -n "s/^  $1: \"\\([^\"]*\\)\"\$/\\1/p" include/source-pins.yml; }
element_label() { sed -n "s/^ *'$1': '\\([^']*\\)'\$/\\1/p" elements/oci/gutenprint-printer-app.bst; }
image_label() { podman image inspect --format "{{ index .Config.Labels \"$1\" }}" "$IMAGE"; }

status=0
expect() {
  local key="$1" want="$2" got
  got="$(image_label "$key")"
  if [[ "$got" != "$want" ]]; then
    printf 'label %s is "%s", expected "%s"\n' "$key" "$got" "$want" >&2
    status=1
  fi
}

expect org.opencontainers.image.version "$(pin gutenprint-version)"
expect io.projectbluefin.gutenprint.ref "$(pin gutenprint-ref)"
expect io.projectbluefin.fsdk.version "$(element_label io.projectbluefin.fsdk.version)"
expect io.projectbluefin.fsdk.ref "$(element_label io.projectbluefin.fsdk.ref)"

[[ "$status" -eq 0 ]] || exit "$status"
printf 'OK: %s labels match include/source-pins.yml and the pinned FSDK\n' "$IMAGE"
