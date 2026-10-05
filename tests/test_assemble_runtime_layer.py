"""Unit tests for scripts/assemble-runtime-layer-proof.py using tiny OCI fixtures."""

import hashlib
import json
import shutil
import tempfile
import unittest
from pathlib import Path

from scripts.assemble_runtime_layer_proof import assemble_publication_layout


def write_blob(blobs_dir: Path, data: bytes) -> tuple[str, int]:
    h = hashlib.sha256(data).hexdigest()
    digest = f"sha256:{h}"
    path = blobs_dir / h
    path.write_bytes(data)
    return digest, len(data)


def create_tiny_oci(base_dir: Path, arch: str, os_name: str, diff_ids: list[str], layer_payloads: list[bytes]) -> Path:
    blobs = base_dir / "blobs" / "sha256"
    blobs.mkdir(parents=True, exist_ok=True)

    # 1. Write layer blobs
    layers_desc = []
    for i, payload in enumerate(layer_payloads):
        d, sz = write_blob(blobs, payload)
        media_type = "application/vnd.oci.image.layer.v1.tar+gzip" if i == 0 and len(layer_payloads) == 1 else "application/vnd.oci.image.layer.v1.tar"
        layers_desc.append({
            "mediaType": media_type,
            "digest": d,
            "size": sz,
        })

    # 2. Write config
    cfg = {
        "architecture": arch,
        "os": os_name,
        "rootfs": {"type": "layers", "diff_ids": diff_ids},
    }
    cfg_bytes = json.dumps(cfg, separators=(",", ":")).encode("utf-8")
    cfg_digest, cfg_size = write_blob(blobs, cfg_bytes)
    cfg_desc = {
        "mediaType": "application/vnd.oci.image.config.v1+json",
        "digest": cfg_digest,
        "size": cfg_size,
    }

    # 3. Write manifest
    manifest = {
        "schemaVersion": 2,
        "mediaType": "application/vnd.oci.image.manifest.v1+json",
        "config": cfg_desc,
        "layers": layers_desc,
        "annotations": {"test.annotation": "preserved"},
    }
    man_bytes = json.dumps(manifest, separators=(",", ":")).encode("utf-8")
    man_digest, man_size = write_blob(blobs, man_bytes)
    man_desc = {
        "mediaType": "application/vnd.oci.image.manifest.v1+json",
        "digest": man_digest,
        "size": man_size,
        "annotations": {"org.opencontainers.image.ref.name": "build"},
    }

    # 4. Write index.json
    idx = {
        "schemaVersion": 2,
        "mediaType": "application/vnd.oci.image.index.v1+json",
        "manifests": [man_desc],
    }
    with open(base_dir / "index.json", "w", encoding="utf-8") as f:
        json.dump(idx, f)

    with open(base_dir / "oci-layout", "w", encoding="utf-8") as f:
        json.dump({"imageLayoutVersion": "1.0.0"}, f)

    return base_dir


class AssembleRuntimeLayerTests(unittest.TestCase):
    def setUp(self):
        # Use project-local scratch directory, not /tmp
        self.scratch = Path(__file__).resolve().parent / ".fixtures"
        self.scratch.mkdir(parents=True, exist_ok=True)
        self.parent_dir = self.scratch / "parent"
        self.child_dir = self.scratch / "child"
        self.output_dir = self.scratch / "output"

        # Shared test hashes
        self.diff_id_0 = "sha256:3824256ba0d1eddb3ca84e8a042a3ef03bf5fbbdb28c6d67393642476c7c06f6"
        self.diff_id_1 = "sha256:1111111111111111111111111111111111111111111111111111111111111111"

        self.parent_payload = b"PARENT_LAYER_0_COMPRESSED_TAR_GZIP_CONTENT"
        self.child_l0_payload = b"CHILD_L0_UNCOMPRESSED_TAR_CONTENT"
        self.child_l1_payload = b"CHILD_L1_OVERLAY_CONTENT"

    def tearDown(self):
        shutil.rmtree(self.scratch, ignore_errors=True)

    def test_valid_assembly_preserves_verbatim_parent_blob_and_child_config(self):
        create_tiny_oci(self.parent_dir, "amd64", "linux", [self.diff_id_0], [self.parent_payload])
        create_tiny_oci(self.child_dir, "amd64", "linux", [self.diff_id_0, self.diff_id_1], [self.child_l0_payload, self.child_l1_payload])

        res = assemble_publication_layout(self.child_dir, self.parent_dir, self.output_dir, "test-tag")
        self.assertTrue((self.output_dir / "index.json").is_file())

        # Inspect published manifest
        manifest_path = self.output_dir / "blobs" / "sha256" / res["manifest_digest"].removeprefix("sha256:")
        self.assertTrue(manifest_path.is_file())
        with open(manifest_path, encoding="utf-8") as f:
            manifest = json.load(f)

        # Layer 0 must match parent verbatim
        self.assertEqual(manifest["layers"][0]["digest"], res["layer0_digest"])
        self.assertEqual(manifest["layers"][0]["mediaType"], "application/vnd.oci.image.layer.v1.tar+gzip")
        p0_blob = self.output_dir / "blobs" / "sha256" / res["layer0_digest"].removeprefix("sha256:")
        self.assertEqual(p0_blob.read_bytes(), self.parent_payload)

        # Layer 1 must match child overlay verbatim
        self.assertEqual(manifest["layers"][1]["digest"], res["layer1_digest"])
        c1_blob = self.output_dir / "blobs" / "sha256" / res["layer1_digest"].removeprefix("sha256:")
        self.assertEqual(c1_blob.read_bytes(), self.child_l1_payload)

        # Config must match child config verbatim
        self.assertEqual(manifest["config"]["digest"], res["config_digest"])

    def test_rejects_diffid_mismatch_before_write(self):
        create_tiny_oci(self.parent_dir, "amd64", "linux", [self.diff_id_0], [self.parent_payload])
        # Child has wrong DiffID 0
        create_tiny_oci(self.child_dir, "amd64", "linux", ["sha256:wrong00000000000000000000000000000000000000000000000000000000000", self.diff_id_1], [self.child_l0_payload, self.child_l1_payload])

        with self.assertRaises(ValueError) as cm:
            assemble_publication_layout(self.child_dir, self.parent_dir, self.output_dir, "test-tag")
        self.assertIn("RootFS DiffID 0 mismatch", str(cm.exception))
        # Must not write output
        self.assertFalse(self.output_dir.exists())

    def test_rejects_architecture_mismatch(self):
        create_tiny_oci(self.parent_dir, "arm64", "linux", [self.diff_id_0], [self.parent_payload])
        create_tiny_oci(self.child_dir, "amd64", "linux", [self.diff_id_0, self.diff_id_1], [self.child_l0_payload, self.child_l1_payload])

        with self.assertRaises(ValueError) as cm:
            assemble_publication_layout(self.child_dir, self.parent_dir, self.output_dir, "test-tag")
        self.assertIn("Architecture mismatch", str(cm.exception))

    def test_rejects_invalid_layer_cardinality(self):
        # Parent with 2 layers (should have 1)
        create_tiny_oci(self.parent_dir, "amd64", "linux", [self.diff_id_0, self.diff_id_1], [self.parent_payload, b"EXTRA"])
        create_tiny_oci(self.child_dir, "amd64", "linux", [self.diff_id_0, self.diff_id_1], [self.child_l0_payload, self.child_l1_payload])

        with self.assertRaises(ValueError) as cm:
            assemble_publication_layout(self.child_dir, self.parent_dir, self.output_dir, "test-tag")
        self.assertIn("Parent manifest must contain exactly 1 layer", str(cm.exception))

    def test_rejects_corrupted_blob(self):
        create_tiny_oci(self.parent_dir, "amd64", "linux", [self.diff_id_0], [self.parent_payload])
        create_tiny_oci(self.child_dir, "amd64", "linux", [self.diff_id_0, self.diff_id_1], [self.child_l0_payload, self.child_l1_payload])

        # Corrupt parent blob on disk
        parent_manifest = json.loads((self.parent_dir / "index.json").read_text())
        man_digest = parent_manifest["manifests"][0]["digest"]
        man = json.loads((self.parent_dir / "blobs" / "sha256" / man_digest.removeprefix("sha256:")).read_text())
        p0_hash = man["layers"][0]["digest"].removeprefix("sha256:")
        (self.parent_dir / "blobs" / "sha256" / p0_hash).write_bytes(b"CORRUPTED_DATA")

        with self.assertRaises(ValueError) as cm:
            assemble_publication_layout(self.child_dir, self.parent_dir, self.output_dir, "test-tag")
        self.assertIn("Blob", str(cm.exception))


if __name__ == "__main__":
    unittest.main()
