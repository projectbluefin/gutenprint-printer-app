#!/usr/bin/env python3
"""Assemble published OCI layout carrying the original compressed Layer 0 descriptor and blob."""

import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path


def read_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def blob_path(oci_dir, digest):
    algo, h = digest.split(":", 1)
    return oci_dir / "blobs" / algo / h


def verify_blob(path, expected_digest, expected_size):
    if not path.is_file():
        raise ValueError(f"Blob file missing: {path}")
    actual_size = path.stat().st_size
    if actual_size != expected_size:
        raise ValueError(f"Blob size mismatch for {expected_digest}: expected {expected_size}, got {actual_size}")
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    actual_digest = f"sha256:{h.hexdigest()}"
    if actual_digest != expected_digest:
        raise ValueError(f"Blob digest mismatch: expected {expected_digest}, computed {actual_digest}")


def assemble_publication_layout(build_out: Path, parent_dir: Path, output_dir: Path, tag: str):
    if not build_out.is_dir():
        raise ValueError(f"build-out directory {build_out} does not exist")
    if not parent_dir.is_dir():
        raise ValueError(f"parent directory {parent_dir} does not exist")

    # 1. Read child index and manifest from build-out
    child_index = read_json(build_out / "index.json")
    if len(child_index.get("manifests", [])) != 1:
        raise ValueError(f"Child index must contain exactly 1 manifest, got {len(child_index.get('manifests', []))}")
    child_manifest_desc = child_index["manifests"][0]
    child_manifest = read_json(blob_path(build_out, child_manifest_desc["digest"]))

    if len(child_manifest.get("layers", [])) != 2:
        raise ValueError(f"Child manifest must contain exactly 2 layers, got {len(child_manifest.get('layers', []))}")

    config_desc = child_manifest["config"]
    child_layer1_desc = child_manifest["layers"][1]
    child_config = read_json(blob_path(build_out, config_desc["digest"]))

    # 2. Read parent index and manifest from parent_dir
    parent_index = read_json(parent_dir / "index.json")
    if len(parent_index.get("manifests", [])) != 1:
        raise ValueError(f"Parent index must contain exactly 1 manifest, got {len(parent_index.get('manifests', []))}")
    parent_manifest_desc = parent_index["manifests"][0]
    parent_manifest = read_json(blob_path(parent_dir, parent_manifest_desc["digest"]))

    if len(parent_manifest.get("layers", [])) != 1:
        raise ValueError(f"Parent manifest must contain exactly 1 layer, got {len(parent_manifest.get('layers', []))}")
    parent_layer0_desc = parent_manifest["layers"][0]
    parent_config = read_json(blob_path(parent_dir, parent_manifest["config"]["digest"]))

    # 3. Structural validation BEFORE any output writes
    if child_config.get("architecture") != parent_config.get("architecture"):
        raise ValueError(
            f"Architecture mismatch: child is {child_config.get('architecture')}, parent is {parent_config.get('architecture')}"
        )
    if child_config.get("os") != parent_config.get("os"):
        raise ValueError(f"OS mismatch: child is {child_config.get('os')}, parent is {parent_config.get('os')}")

    parent_diff_id = parent_config.get("rootfs", {}).get("diff_ids", [""])[0]
    child_diff_id_0 = child_config.get("rootfs", {}).get("diff_ids", [""])[0]
    if child_diff_id_0 != parent_diff_id:
        raise ValueError(
            f"RootFS DiffID 0 mismatch: child has {child_diff_id_0}, parent has {parent_diff_id}"
        )

    # 4. Verify blob digests and sizes before copying
    p0_blob = blob_path(parent_dir, parent_layer0_desc["digest"])
    verify_blob(p0_blob, parent_layer0_desc["digest"], parent_layer0_desc["size"])

    c1_blob = blob_path(build_out, child_layer1_desc["digest"])
    verify_blob(c1_blob, child_layer1_desc["digest"], child_layer1_desc["size"])

    cfg_blob = blob_path(build_out, config_desc["digest"])
    verify_blob(cfg_blob, config_desc["digest"], config_desc["size"])

    # 5. Create output layout and copy verified blobs
    out_blobs = output_dir / "blobs" / "sha256"
    out_blobs.mkdir(parents=True, exist_ok=True)

    shutil.copyfile(p0_blob, blob_path(output_dir, parent_layer0_desc["digest"]))
    shutil.copyfile(c1_blob, blob_path(output_dir, child_layer1_desc["digest"]))
    shutil.copyfile(cfg_blob, blob_path(output_dir, config_desc["digest"]))

    # 6. Construct published manifest (preserve all child fields, swap only layers[0])
    published_manifest = dict(child_manifest)
    published_manifest["layers"] = [
        parent_layer0_desc,
        child_layer1_desc,
    ]
    manifest_bytes = json.dumps(published_manifest, separators=(",", ":")).encode("utf-8")
    manifest_hash = hashlib.sha256(manifest_bytes).hexdigest()
    manifest_digest = f"sha256:{manifest_hash}"

    with open(out_blobs / manifest_hash, "wb") as f:
        f.write(manifest_bytes)

    # 7. Construct published index (preserve child index annotations/fields, update digest/size)
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

    # 8. Write oci-layout
    with open(output_dir / "oci-layout", "w", encoding="utf-8") as f:
        json.dump({"imageLayoutVersion": "1.0.0"}, f)

    return {
        "manifest_digest": manifest_digest,
        "layer0_digest": parent_layer0_desc["digest"],
        "layer0_size": parent_layer0_desc["size"],
        "layer0_type": parent_layer0_desc["mediaType"],
        "layer1_digest": child_layer1_desc["digest"],
        "layer1_size": child_layer1_desc["size"],
        "config_digest": config_desc["digest"],
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
