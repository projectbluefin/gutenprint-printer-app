#!/usr/bin/env bash
set -euo pipefail

# Assertions for shared printing runtime layer integration (issue #342):
# 1. Image has exactly 2 layers.
# 2. Layer 0 matches the published architecture blob from producer.
# 3. Config rootfs.diff_ids[0] matches the expected DiffID.
# 4. Unchanged lower-layer base files do not appear in the Layer 1 delta.
# 5. Layer 1 contains the Gutenprint application payload.
# 6. Reports measured parent and overlay sizes and file counts.

IMAGE="${IMAGE:-ghcr.io/projectbluefin/gutenprint-printer-app:build}"

echo "Validating runtime layer structure for ${IMAGE}..."

# Inspect image architecture and rootfs diff_ids
arch="$(podman image inspect --format '{{.Architecture}}' "${IMAGE}")"
diff_ids="$(podman image inspect --format '{{json .RootFS.Layers}}' "${IMAGE}")"

case "${arch}" in
  amd64)
    expected_blob="sha256:48f4771e199eead682c592e87c043c2389670e5b84e8d35cc40204e3b24fcd4f"
    expected_diffid="sha256:3824256ba0d1eddb3ca84e8a042a3ef03bf5fbbdb28c6d67393642476c7c06f6"
    ;;
  arm64)
    expected_blob="sha256:ab5ecb38c3290228a32ec8b8ec1453738ce66ffb0557deab3b71172236ae4836"
    expected_diffid="sha256:7b5cfbbf083c6dd11a91e56bdf1a520bfd65017042a406607e15bf943714b7e9"
    ;;
  *)
    echo "FAIL: Unsupported architecture ${arch}" >&2
    exit 1
    ;;
esac

# 1. Assert DiffID
diffid_0="$(jq -r '.[0] // ""' <<< "${diff_ids}")"
diffid_count="$(jq 'length' <<< "${diff_ids}")"
if [[ "${diffid_count}" -ne 2 ]]; then
  echo "FAIL: Expected exactly 2 diff_ids, found ${diffid_count}: ${diff_ids}" >&2
  exit 1
fi
if [[ "${diffid_0}" != "${expected_diffid}" ]]; then
  echo "FAIL: Layer 0 DiffID is ${diffid_0}, expected ${expected_diffid}" >&2
  exit 1
fi

# 2. Inspect manifest layers via skopeo
manifest="$(skopeo inspect --raw "containers-storage:${IMAGE}")"
layer_count="$(jq '.layers | length' <<< "${manifest}")"
if [[ "${layer_count}" -ne 2 ]]; then
  echo "FAIL: Expected exactly 2 layers in manifest, found ${layer_count}" >&2
  exit 1
fi

layer0_digest="$(jq -r '.layers[0].digest' <<< "${manifest}")"
layer0_size="$(jq -r '.layers[0].size' <<< "${manifest}")"
layer1_digest="$(jq -r '.layers[1].digest' <<< "${manifest}")"
layer1_size="$(jq -r '.layers[1].size' <<< "${manifest}")"

if [[ "${layer0_digest}" != "${expected_blob}" ]]; then
  echo "FAIL: Layer 0 digest ${layer0_digest} does not match expected producer blob ${expected_blob}" >&2
  exit 1
fi

echo "Layer 0 (shared runtime base):"
echo "  Digest: ${layer0_digest}"
echo "  Compressed size: ${layer0_size} bytes ($(( layer0_size / 1048576 )) MB)"
echo "Layer 1 (application delta overlay):"
echo "  Digest: ${layer1_digest}"
echo "  Compressed size: ${layer1_size} bytes ($(( layer1_size / 1048576 )) MB)"

# 3. Export to project scratch to inspect layer 1 tarball directly
scratch_dir="files/runtime-layer/.inspect-${arch}"
rm -rf "${scratch_dir}"
mkdir -p "${scratch_dir}"
cleanup() { rm -rf "${scratch_dir}"; }
trap cleanup EXIT

skopeo copy "containers-storage:${IMAGE}" "dir:${scratch_dir}"

# Find layer 1 tarball in exported dir
layer1_file="${scratch_dir}/${layer1_digest#sha256:}"
if [[ ! -f "${layer1_file}" ]]; then
  echo "FAIL: Layer 1 file not found at ${layer1_file}" >&2
  exit 1
fi

layer1_tar_contents="$(tar -tf "${layer1_file}")"
layer1_file_count="$(wc -l <<< "${layer1_tar_contents}")"
echo "  File count: ${layer1_file_count} entries"

# 4. Assert unchanged lower base files are absent from layer 1
for forbidden in usr/bin/bash usr/bin/python3 usr/bin/gs; do
  if grep -qFx "${forbidden}" <<< "${layer1_tar_contents}"; then
    echo "FAIL: Unchanged base file ${forbidden} duplicated in Layer 1 overlay" >&2
    exit 1
  fi
done

# 5. Assert Gutenprint app files are present in layer 1
for required in usr/bin/gutenprint-printer-app usr/bin/cups-calibrate usr/share/cups/calibrate.ppm; do
  if ! grep -qFx "${required}" <<< "${layer1_tar_contents}"; then
    echo "FAIL: Required Gutenprint file ${required} missing from Layer 1 overlay" >&2
    exit 1
  fi
done

echo "OK: Runtime layer proof passed: 2 layers, Layer 0 matches producer blob (${arch}), no base file duplication."
