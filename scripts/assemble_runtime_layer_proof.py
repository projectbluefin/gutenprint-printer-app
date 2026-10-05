#!/usr/bin/env python3
"""Assemble published OCI layout carrying the original compressed Layer 0 descriptor and blob."""

import argparse
import hashlib
import json
import re
import shutil
import sys
from pathlib import Path

SHA256_RE = re.compile(r"^sha256:([0-9a-f]{64})$")
SUPPORTED_ARCHES = {"amd64", "arm64"}


def read_json(path: Path):
    if not path.is_file():
        raise ValueError(f"JSON file missing: {path}")
    with open(path, "r", encoding="utf-8") as f:
        try:
            return json.load(f)
        except json.JSONDecodeError as e:
            raise ValueError(f"Malformed JSON in {path}: {e}") from e


def blob_path(oci_dir: Path, digest: str) -> Path:
    m = SHA256_RE.match(digest)
    if not m:
        raise ValueError(f"Invalid sha256 digest format: {digest!r}")
    return oci_dir / "blobs" / "sha256" / m.group(1)


def verify_descriptor_and_blob(oci_dir: Path, desc: dict, context: str) -> Path:
    if not isinstance(desc, dict):
        raise ValueError(f"{context} descriptor must be an object, got {type(desc)}")
    digest = desc.get("digest")
    if not isinstance(digest, str) or not SHA256_RE.match(digest):
        raise ValueError(f"{context} descriptor missing or invalid digest: {digest!r}")
    size = desc.get("size")
    if not isinstance(size, int) or size < 0:
        raise ValueError(f"{context} descriptor missing or invalid size: {size!r}")

    p = blob_path(oci_dir, digest)
    if not p.is_file():
        raise ValueError(f"{context} blob file missing: {p}")
    actual_size = p.stat().st_size
    if actual_size != size:
        raise ValueError(f"{context} blob size mismatch for {digest}: expected {size}, got {actual_size}")

    h = hashlib.sha256()
    with open(p, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    actual_digest = f"sha256:{h.hexdigest()}"
    if actual_digest != digest:
        raise ValueError(f"{context} blob digest mismatch: expected {digest}, computed {actual_digest}")

    return p


def assemble_publication_layout(build_out: Path, parent_dir: Path, output_dir: Path, tag: str):
    if not build_out.is_dir():
        raise ValueError(f"build-out directory {build_out} does not exist")
    if not parent_dir.is_dir():
        raise ValueError(f"parent directory {parent_dir} does not exist")

    # 1. Read and verify child index
    child_index = read_json(build_out / "index.json")
    manifests = child_index.get("manifests")
    if not isinstance(manifests, list) or len(manifests) != 1:
        raise ValueError(f"Child index must contain exactly 1 manifest, got {manifests}")
    child_manifest_desc = manifests[0]
    child_manifest_path = verify_descriptor_and_blob(build_out, child_manifest_desc, "child index manifest")
    child_manifest = read_json(child_manifest_path)

    # 2. Read and verify child manifest descriptors
    layers = child_manifest.get("layers")
    if not isinstance(layers, list) or len(layers) != 2:
        raise ValueError(f"Child manifest must contain exactly 2 layers, got {layers}")
    child_l0_desc = layers[0]
    child_l1_desc = layers[1]
    verify_descriptor_and_blob(build_out, child_l0_desc, "child layer 0")
    c1_blob = verify_descriptor_and_blob(build_out, child_l1_desc, "child layer 1")

    child_config_desc = child_manifest.get("config")
    cfg_blob = verify_descriptor_and_blob(build_out, child_config_desc, "child config")
    child_config = read_json(cfg_blob)

    # 3. Read and verify parent index
    parent_index = read_json(parent_dir / "index.json")
    p_manifests = parent_index.get("manifests")
    if not isinstance(p_manifests, list) or len(p_manifests) != 1:
        raise ValueError(f"Parent index must contain exactly 1 manifest, got {p_manifests}")
    parent_manifest_desc = p_manifests[0]
    parent_manifest_path = verify_descriptor_and_blob(parent_dir, parent_manifest_desc, "parent index manifest")
    parent_manifest = read_json(parent_manifest_path)

    # 4. Read and verify parent manifest descriptors
    p_layers = parent_manifest.get("layers")
    if not isinstance(p_layers, list) or len(p_layers) != 1:
        raise ValueError(f"Parent manifest must contain exactly 1 layer, got {p_layers}")
    parent_layer0_desc = p_layers[0]
    p0_blob = verify_descriptor_and_blob(parent_dir, parent_layer0_desc, "parent layer 0")

    parent_config_desc = parent_manifest.get("config")
    p_cfg_blob = verify_descriptor_and_blob(parent_dir, parent_config_desc, "parent config")
    parent_config = read_json(p_cfg_blob)

    # 5. Strict architectural and configuration validation BEFORE any output writes
    child_arch = child_config.get("architecture")
    parent_arch = parent_config.get("architecture")
    if child_arch not in SUPPORTED_ARCHES:
        raise ValueError(f"Child architecture must be one of {SUPPORTED_ARCHES}, got {child_arch!r}")
    if parent_arch not in SUPPORTED_ARCHES:
        raise ValueError(f"Parent architecture must be one of {SUPPORTED_ARCHES}, got {parent_arch!r}")
    if child_arch != parent_arch:
        raise ValueError(f"Architecture mismatch: child is {child_arch}, parent is {parent_arch}")

    child_os = child_config.get("os")
    parent_os = parent_config.get("os")
    if child_os != "linux":
        raise ValueError(f"Child OS must be 'linux', got {child_os!r}")
    if parent_os != "linux":
        raise ValueError(f"Parent OS must be 'linux', got {parent_os!r}")

    # Validate rootfs structures: no missing values, no success defaults
    child_rootfs = child_config.get("rootfs")
    if not isinstance(child_rootfs, dict) or child_rootfs.get("type") != "layers":
        raise ValueError("Child config rootfs.type must be 'layers'")
    child_diff_ids = child_rootfs.get("diff_ids")
    if not isinstance(child_diff_ids, list) or len(child_diff_ids) != 2:
        raise ValueError(f"Child config rootfs.diff_ids must contain exactly 2 entries, got {child_diff_ids}")
    for did in child_diff_ids:
        if not isinstance(did, str) or not SHA256_RE.match(did):
            raise ValueError(f"Child diff_id must be valid sha256: {did!r}")

    parent_rootfs = parent_config.get("rootfs")
    if not isinstance(parent_rootfs, dict) or parent_rootfs.get("type") != "layers":
        raise ValueError("Parent config rootfs.type must be 'layers'")
    parent_diff_ids = parent_rootfs.get("diff_ids")
    if not isinstance(parent_diff_ids, list) or len(parent_diff_ids) != 1:
        raise ValueError(f"Parent config rootfs.diff_ids must contain exactly 1 entry, got {parent_diff_ids}")
    if not isinstance(parent_diff_ids[0], str) or not SHA256_RE.match(parent_diff_ids[0]):
        raise ValueError(f"Parent diff_id must be valid sha256: {parent_diff_ids[0]!r}")

    if child_diff_ids[0] != parent_diff_ids[0]:
        raise ValueError(f"RootFS DiffID 0 mismatch: child has {child_diff_ids[0]}, parent has {parent_diff_ids[0]}")

    # 6. Create output layout and copy verified blobs (now safe after all validations passed)
    out_blobs = output_dir / "blobs" / "sha256"
    out_blobs.mkdir(parents=True, exist_ok=True)

    shutil.copyfile(p0_blob, blob_path(output_dir, parent_layer0_desc["digest"]))
    shutil.copyfile(c1_blob, blob_path(output_dir, child_l1_desc["digest"]))
    shutil.copyfile(cfg_blob, blob_path(output_dir, child_config_desc["digest"]))

    # 7. Construct published manifest (preserve all child fields, swap only layers[0])
    published_manifest = dict(child_manifest)
    published_manifest["layers"] = [
        parent_layer0_desc,
        child_l1_desc,
    ]
    manifest_bytes = json.dumps(published_manifest, separators=(",", ":")).encode("utf-8")
    manifest_hash = hashlib.sha256(manifest_bytes).hexdigest()
    manifest_digest = f"sha256:{manifest_hash}"

    with open(out_blobs / manifest_hash, "wb") as f:
        f.write(manifest_bytes)

    # 8. Construct published index (preserve child index annotations/fields, update digest/size)
    published_index = dict(child_index)
    new_desc = dict(child_manifest_desc)
    new_desc["digest"] = manifest_digest
    new_desc["size"] = len(manifest_bytes)
    ann = dict(new_desc.get("annotations", {}))
    ann["org.opencontainers.image.ref.name"] = tag
    new_desc["annotations"] = ann
    published_index["manifests"] = [new_desc]

    with open(output_dir / "index.json", "w", encoding="utf-8") as f:
        json.dump(published_index, f, separators=(",", ":"))

    # 9. Write oci-layout
    with open(output_dir / "oci-layout", "w", encoding="utf-8") as f:
        json.dump({"imageLayoutVersion": "1.0.0"}, f)

    return {
        "manifest_digest": manifest_digest,
        "layer0_digest": parent_layer0_desc["digest"],
        "layer0_size": parent_layer0_desc["size"],
        "layer0_type": parent_layer0_desc["mediaType"],
        "layer1_digest": child_l1_desc["digest"],
        "layer1_size": child_l1_desc["size"],
        "config_digest": child_config_desc["digest"],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-out", type=Path, required=True, help="BuildStream OCI checkout directory")
    parser.add_argument("--parent-dir", type=Path, required=True, help="Original parent OCI layer directory")
    parser.add_argument("--output", type=Path, required=True, help="Output publication OCI layout directory")
    parser.add_argument("--tag", type=str, required=True, help="Tag name for index.json reference")
    args = parser.parse_args()

    try:
        res = assemble_publication_layout(args.build_out, args.parent_dir, args.output, args.tag)
        print(f"Assembled publication OCI layout at {args.output}")
        print(f"  Manifest: {res['manifest_digest']}")
        print(f"  Layer 0: {res['layer0_digest']} ({res['layer0_size']} bytes, {res['layer0_type']})")
        print(f"  Layer 1: {res['layer1_digest']} ({res['layer1_size']} bytes)")
        print(f"  Config: {res['config_digest']}")
        return 0
    except ValueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
