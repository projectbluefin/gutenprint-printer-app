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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-out", type=Path, required=True, help="BuildStream OCI checkout directory")
    parser.add_argument("--parent-dir", type=Path, required=True, help="Original parent OCI layer directory")
    parser.add_argument("--output", type=Path, required=True, help="Output publication OCI layout directory")
    parser.add_argument("--tag", type=str, required=True, help="Tag name for index.json reference")
    args = parser.parse_args()

    if not args.build_out.is_dir():
        print(f"ERROR: build-out directory {args.build_out} does not exist", file=sys.stderr)
        return 1
    if not args.parent_dir.is_dir():
        print(f"ERROR: parent directory {args.parent_dir} does not exist", file=sys.stderr)
        return 1

    # 1. Read child manifest from build-out
    child_index = read_json(args.build_out / "index.json")
    child_manifest_desc = child_index["manifests"][0]
    child_manifest = read_json(blob_path(args.build_out, child_manifest_desc["digest"]))

    config_desc = child_manifest["config"]
    child_layer1_desc = child_manifest["layers"][1]

    # 2. Read parent manifest from parent-dir
    parent_index = read_json(args.parent_dir / "index.json")
    parent_manifest_desc = parent_index["manifests"][0]
    parent_manifest = read_json(blob_path(args.parent_dir, parent_manifest_desc["digest"]))
    parent_layer0_desc = parent_manifest["layers"][0]

    # 3. Create output directory layout
    out_blobs = args.output / "blobs" / "sha256"
    out_blobs.mkdir(parents=True, exist_ok=True)

    # Copy parent Layer 0 blob
    p0_src = blob_path(args.parent_dir, parent_layer0_desc["digest"])
    shutil.copyfile(p0_src, blob_path(args.output, parent_layer0_desc["digest"]))

    # Copy child Layer 1 blob
    c1_src = blob_path(args.build_out, child_layer1_desc["digest"])
    shutil.copyfile(c1_src, blob_path(args.output, child_layer1_desc["digest"]))

    # Copy child config blob
    cfg_src = blob_path(args.build_out, config_desc["digest"])
    shutil.copyfile(cfg_src, blob_path(args.output, config_desc["digest"]))

    # 4. Construct published manifest
    published_manifest = {
        "schemaVersion": 2,
        "mediaType": "application/vnd.oci.image.manifest.v1+json",
        "config": config_desc,
        "layers": [
            parent_layer0_desc,
            child_layer1_desc,
        ],
    }
    manifest_bytes = json.dumps(published_manifest, separators=(",", ":")).encode("utf-8")
    manifest_hash = hashlib.sha256(manifest_bytes).hexdigest()
    manifest_digest = f"sha256:{manifest_hash}"

    with open(out_blobs / manifest_hash, "wb") as f:
        f.write(manifest_bytes)

    # 5. Write index.json
    published_index = {
        "schemaVersion": 2,
        "mediaType": "application/vnd.oci.image.index.v1+json",
        "manifests": [
            {
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "digest": manifest_digest,
                "size": len(manifest_bytes),
                "annotations": {
                    "org.opencontainers.image.ref.name": args.tag,
                },
            }
        ],
    }
    with open(args.output / "index.json", "w", encoding="utf-8") as f:
        json.dump(published_index, f, separators=(",", ":"))

    # 6. Write oci-layout
    with open(args.output / "oci-layout", "w", encoding="utf-8") as f:
        json.dump({"imageLayoutVersion": "1.0.0"}, f)

    print(f"Assembled publication OCI layout at {args.output}")
    print(f"  Manifest: {manifest_digest}")
    print(f"  Layer 0: {parent_layer0_desc['digest']} ({parent_layer0_desc['size']} bytes, {parent_layer0_desc['mediaType']})")
    print(f"  Layer 1: {child_layer1_desc['digest']} ({child_layer1_desc['size']} bytes, {child_layer1_desc['mediaType']})")
    print(f"  Config: {config_desc['digest']} ({config_desc['size']} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
