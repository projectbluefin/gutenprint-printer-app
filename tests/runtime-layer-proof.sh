#!/usr/bin/env bash
set -euo pipefail

# Exhaustive verification of the shared printing runtime layer integration (issue #342):
# 1. Image manifest contains exactly 2 layers.
# 2. Layer 0 matches the published architecture blob from producer.
# 3. Config rootfs.diff_ids[0] matches the expected DiffID.
# 4. Inventory comparison: no unchanged regular lower files are duplicated into Layer 1.
# 5. Layer 1 contains the Gutenprint application payload.
# 6. Reports measured parent and overlay metrics (mediaType, encoded bytes, file counts).

IMAGE="${IMAGE:-ghcr.io/projectbluefin/gutenprint-printer-app:build}"

echo "Validating runtime layer structure and inventory for ${IMAGE}..."

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
layer0_type="$(jq -r '.layers[0].mediaType' <<< "${manifest}")"

layer1_digest="$(jq -r '.layers[1].digest' <<< "${manifest}")"
layer1_size="$(jq -r '.layers[1].size' <<< "${manifest}")"
layer1_type="$(jq -r '.layers[1].mediaType' <<< "${manifest}")"

if [[ "${layer0_digest}" != "${expected_blob}" ]]; then
  echo "FAIL: Layer 0 digest ${layer0_digest} does not match expected producer blob ${expected_blob}" >&2
  exit 1
fi

# 3. Export layers to project scratch directory to inspect tarballs
scratch_dir="files/runtime-layer/.inspect-${arch}"
rm -rf "${scratch_dir}"
mkdir -p "${scratch_dir}"
cleanup() { rm -rf "${scratch_dir}"; }
trap cleanup EXIT

skopeo copy "containers-storage:${IMAGE}" "dir:${scratch_dir}"

layer0_file="${scratch_dir}/${layer0_digest#sha256:}"
layer1_file="${scratch_dir}/${layer1_digest#sha256:}"

if [[ ! -f "${layer0_file}" || ! -f "${layer1_file}" ]]; then
  echo "FAIL: Exported layer tarball missing in ${scratch_dir}" >&2
  exit 1
fi

# 4. Deep inventory comparison: assert NO identical unchanged lower files exist in Layer 1
python3 - <<PYCHECK
import tarfile, hashlib, sys

def norm(path):
    return path.lstrip(".").lstrip("/")

def hash_member(tf, member):
    f = tf.extractfile(member)
    if f is None:
        return None
    h = hashlib.sha256()
    while chunk := f.read(65536):
        h.update(chunk)
    return h.hexdigest()

layer0_path = "${layer0_file}"
layer1_path = "${layer1_file}"

layer0_files = {}
layer0_total = 0
with tarfile.open(layer0_path, "r:*") as tf0:
    for m in tf0.getmembers():
        layer0_total += 1
        if m.isreg():
            p = norm(m.name)
            layer0_files[p] = (m.size, hash_member(tf0, m))

layer1_total = 0
layer1_reg = 0
layer1_whiteouts = 0
duplicated = []
gutenprint_found = set()

with tarfile.open(layer1_path, "r:*") as tf1:
    for m in tf1.getmembers():
        layer1_total += 1
        p = norm(m.name)
        if "/.wh." in p or p.startswith(".wh."):
            layer1_whiteouts += 1
        if p in ("usr/bin/gutenprint-printer-app", "usr/bin/cups-calibrate", "usr/share/cups/calibrate.ppm"):
            gutenprint_found.add(p)
        if m.isreg():
            layer1_reg += 1
            if p in layer0_files:
                l0_size, l0_hash = layer0_files[p]
                if m.size == l0_size:
                    l1_hash = hash_member(tf1, m)
                    if l1_hash == l0_hash:
                        duplicated.append((p, m.size))

print(f"Layer 0 ({'${arch}'}):")
print(f"  Digest: {'${layer0_digest}'}")
print(f"  MediaType: {'${layer0_type}'}")
print(f"  Encoded bytes: {'${layer0_size}'} ({int('${layer0_size}') / 1048576:.2f} MB)")
print(f"  Total tar entries: {layer0_total} (regular files: {len(layer0_files)})")
print(f"Layer 1 ({'${arch}'}):")
print(f"  Digest: {'${layer1_digest}'}")
print(f"  MediaType: {'${layer1_type}'}")
print(f"  Encoded bytes: {'${layer1_size}'} ({int('${layer1_size}') / 1048576:.2f} MB)")
print(f"  Total tar entries: {layer1_total} (regular files: {layer1_reg}, whiteouts: {layer1_whiteouts})")

missing_required = {"usr/bin/gutenprint-printer-app", "usr/bin/cups-calibrate", "usr/share/cups/calibrate.ppm"} - gutenprint_found
if missing_required:
    print(f"FAIL: Required Gutenprint application files missing from Layer 1: {sorted(missing_required)}", file=sys.stderr)
    sys.exit(1)

if duplicated:
    print(f"FAIL: {len(duplicated)} unchanged lower files were duplicated into Layer 1 overlay:", file=sys.stderr)
    for p, sz in duplicated[:10]:
        print(f"  - {p} ({sz} bytes)", file=sys.stderr)
    if len(duplicated) > 10:
        print(f"  ... and {len(duplicated) - 10} more", file=sys.stderr)
    sys.exit(1)

print("PASS: Zero identical lower files duplicated into Layer 1.")
PYCHECK

echo "OK: Runtime layer proof passed: 2 layers, exact Layer 0 producer blob (${arch}), diffID verified, zero lower duplicates."
