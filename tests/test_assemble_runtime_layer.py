"""Unit tests for scripts/assemble_runtime_layer_proof.py using tiny OCI fixtures."""

import gzip
import hashlib
import io
import json
import tarfile
import tempfile
import unittest
from pathlib import Path

from scripts.assemble_runtime_layer_proof import assemble_publication_layout


def make_tar_bytes(filename: str, content: bytes) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        ti = tarfile.TarInfo(name=filename)
        ti.size = len(content)
        ti.mtime = 1700000000
        ti.mode = 0o644
        tar.addfile(ti, io.BytesIO(content))
    return buf.getvalue()


def gzip_bytes(data: bytes) -> bytes:
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=1700000000) as gz:
        gz.write(data)
    return buf.getvalue()


def write_blob(blobs_dir: Path, data: bytes) -> tuple[str, int]:
    h = hashlib.sha256(data).hexdigest()
    digest = f"sha256:{h}"
    path = blobs_dir / h
    path.write_bytes(data)
    return digest, len(data)


def create_tiny_oci(
    base_dir: Path,
    arch: str,
    os_name: str,
    diff_ids: list[str],
    layer_payloads: list[bytes],
    is_gzip_layer: list[bool],
    rootfs_type: str = "layers",
    manifest_annotations: dict | None = None,
    index_annotations: dict | None = None,
) -> Path:
    blobs = base_dir / "blobs" / "sha256"
    blobs.mkdir(parents=True, exist_ok=True)

    # 1. Write layer blobs
    layers_desc = []
    for payload, gz in zip(layer_payloads, is_gzip_layer):
        d, sz = write_blob(blobs, payload)
        media_type = "application/vnd.oci.image.layer.v1.tar+gzip" if gz else "application/vnd.oci.image.layer.v1.tar"
        layers_desc.append({
            "mediaType": media_type,
            "digest": d,
            "size": sz,
        })

    # 2. Write config
    cfg: dict = {
        "architecture": arch,
        "os": os_name,
    }
    if rootfs_type is not None:
        cfg["rootfs"] = {"type": rootfs_type, "diff_ids": diff_ids}
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
        "annotations": manifest_annotations if manifest_annotations is not None else {"custom.manifest.label": "preserved"},
    }
    man_bytes = json.dumps(manifest, separators=(",", ":")).encode("utf-8")
    man_digest, man_size = write_blob(blobs, man_bytes)
    man_desc = {
        "mediaType": "application/vnd.oci.image.manifest.v1+json",
        "digest": man_digest,
        "size": man_size,
        "annotations": index_annotations if index_annotations is not None else {
            "org.opencontainers.image.ref.name": "build",
            "custom.index.label": "preserved",
        },
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
        # Unique isolated temporary directory under owned tests directory (never /tmp)
        self.tmp_dir = tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parent)
        self.scratch = Path(self.tmp_dir.name)
        self.parent_dir = self.scratch / "parent"
        self.child_dir = self.scratch / "child"
        self.output_dir = self.scratch / "output"

        # Construct REAL valid tar payloads and compute real DiffIDs
        self.parent_tar = make_tar_bytes("etc/os-release", b"NAME=Gutenprint-Base\nVERSION=26.08\n")
        self.diff_id_0 = f"sha256:{hashlib.sha256(self.parent_tar).hexdigest()}"
        self.parent_layer0_gz = gzip_bytes(self.parent_tar)

        self.child_l1_tar = make_tar_bytes("usr/bin/gutenprint-printer-app", b"#!/bin/sh\necho running app\n")
        self.diff_id_1 = f"sha256:{hashlib.sha256(self.child_l1_tar).hexdigest()}"

        # Child local build-out layer 0 is uncompressed tar with identical DiffID
        self.child_l0_uncompressed = self.parent_tar
        self.child_l1_uncompressed = self.child_l1_tar

    def tearDown(self):
        self.tmp_dir.cleanup()

    def test_valid_assembly_preserves_verbatim_parent_blob_and_child_metadata(self):
        create_tiny_oci(
            self.parent_dir,
            "amd64",
            "linux",
            [self.diff_id_0],
            [self.parent_layer0_gz],
            [True],
        )
        create_tiny_oci(
            self.child_dir,
            "amd64",
            "linux",
            [self.diff_id_0, self.diff_id_1],
            [self.child_l0_uncompressed, self.child_l1_uncompressed],
            [False, False],
        )

        res = assemble_publication_layout(self.child_dir, self.parent_dir, self.output_dir, "test-runtime-proof")
        self.assertTrue((self.output_dir / "index.json").is_file())

        # Inspect published index
        with open(self.output_dir / "index.json", encoding="utf-8") as f:
            published_index = json.load(f)
        idx_desc = published_index["manifests"][0]
        self.assertEqual(idx_desc["annotations"]["org.opencontainers.image.ref.name"], "test-runtime-proof")
        self.assertEqual(idx_desc["annotations"]["custom.index.label"], "preserved")

        # Inspect published manifest
        manifest_path = self.output_dir / "blobs" / "sha256" / res["manifest_digest"].removeprefix("sha256:")
        self.assertTrue(manifest_path.is_file())
        with open(manifest_path, encoding="utf-8") as f:
            manifest = json.load(f)

        # Assert custom manifest annotations are preserved
        self.assertEqual(manifest["annotations"]["custom.manifest.label"], "preserved")

        # Layer 0 must match parent verbatim (compressed tar+gzip)
        self.assertEqual(manifest["layers"][0]["digest"], res["layer0_digest"])
        self.assertEqual(manifest["layers"][0]["mediaType"], "application/vnd.oci.image.layer.v1.tar+gzip")
        p0_blob = self.output_dir / "blobs" / "sha256" / res["layer0_digest"].removeprefix("sha256:")
        self.assertEqual(p0_blob.read_bytes(), self.parent_layer0_gz)

        # Layer 1 must match child overlay verbatim
        self.assertEqual(manifest["layers"][1]["digest"], res["layer1_digest"])
        self.assertEqual(manifest["layers"][1]["mediaType"], "application/vnd.oci.image.layer.v1.tar")
        c1_blob = self.output_dir / "blobs" / "sha256" / res["layer1_digest"].removeprefix("sha256:")
        self.assertEqual(c1_blob.read_bytes(), self.child_l1_uncompressed)

        # Config must match child config verbatim
        self.assertEqual(manifest["config"]["digest"], res["config_digest"])

    def test_rejects_diffid_mismatch_before_write(self):
        create_tiny_oci(self.parent_dir, "amd64", "linux", [self.diff_id_0], [self.parent_layer0_gz], [True])
        other_tar = make_tar_bytes("etc/different", b"DIFFERENT\n")
        other_diffid = f"sha256:{hashlib.sha256(other_tar).hexdigest()}"
        create_tiny_oci(
            self.child_dir,
            "amd64",
            "linux",
            [other_diffid, self.diff_id_1],
            [other_tar, self.child_l1_uncompressed],
            [False, False],
        )

        with self.assertRaises(ValueError) as cm:
            assemble_publication_layout(self.child_dir, self.parent_dir, self.output_dir, "test-tag")
        self.assertIn("RootFS DiffID 0 mismatch", str(cm.exception))
        self.assertFalse(self.output_dir.exists())

    def test_rejects_architecture_mismatch_and_unsupported(self):
        create_tiny_oci(self.parent_dir, "arm64", "linux", [self.diff_id_0], [self.parent_layer0_gz], [True])
        create_tiny_oci(
            self.child_dir,
            "amd64",
            "linux",
            [self.diff_id_0, self.diff_id_1],
            [self.child_l0_uncompressed, self.child_l1_uncompressed],
            [False, False],
        )

        with self.assertRaises(ValueError) as cm:
            assemble_publication_layout(self.child_dir, self.parent_dir, self.output_dir, "test-tag")
        self.assertIn("Architecture mismatch", str(cm.exception))

        # Unsupported architecture
        create_tiny_oci(self.parent_dir, "riscv64", "linux", [self.diff_id_0], [self.parent_layer0_gz], [True])
        with self.assertRaises(ValueError) as cm2:
            assemble_publication_layout(self.child_dir, self.parent_dir, self.output_dir, "test-tag")
        self.assertIn("architecture must be one of", str(cm2.exception))

    def test_rejects_invalid_os(self):
        create_tiny_oci(self.parent_dir, "amd64", "darwin", [self.diff_id_0], [self.parent_layer0_gz], [True])
        create_tiny_oci(
            self.child_dir,
            "amd64",
            "darwin",
            [self.diff_id_0, self.diff_id_1],
            [self.child_l0_uncompressed, self.child_l1_uncompressed],
            [False, False],
        )

        with self.assertRaises(ValueError) as cm:
            assemble_publication_layout(self.child_dir, self.parent_dir, self.output_dir, "test-tag")
        self.assertIn("Child OS must be 'linux'", str(cm.exception))

    def test_rejects_missing_or_invalid_rootfs_fields(self):
        # Invalid rootfs type
        create_tiny_oci(self.parent_dir, "amd64", "linux", [self.diff_id_0], [self.parent_layer0_gz], [True], rootfs_type="invalid")
        create_tiny_oci(
            self.child_dir,
            "amd64",
            "linux",
            [self.diff_id_0, self.diff_id_1],
            [self.child_l0_uncompressed, self.child_l1_uncompressed],
            [False, False],
            rootfs_type="invalid",
        )
        with self.assertRaises(ValueError) as cm:
            assemble_publication_layout(self.child_dir, self.parent_dir, self.output_dir, "test-tag")
        self.assertIn("rootfs.type must be 'layers'", str(cm.exception))

    def test_rejects_invalid_layer_cardinality(self):
        # Parent with 2 layers (should have 1)
        extra_tar = make_tar_bytes("extra", b"extra\n")
        extra_diffid = f"sha256:{hashlib.sha256(extra_tar).hexdigest()}"
        create_tiny_oci(
            self.parent_dir,
            "amd64",
            "linux",
            [self.diff_id_0, extra_diffid],
            [self.parent_layer0_gz, extra_tar],
            [True, False],
        )
        create_tiny_oci(
            self.child_dir,
            "amd64",
            "linux",
            [self.diff_id_0, self.diff_id_1],
            [self.child_l0_uncompressed, self.child_l1_uncompressed],
            [False, False],
        )

        with self.assertRaises(ValueError) as cm:
            assemble_publication_layout(self.child_dir, self.parent_dir, self.output_dir, "test-tag")
        self.assertIn("Parent manifest must contain exactly 1 layer", str(cm.exception))

    def test_rejects_same_length_corrupted_blob(self):
        create_tiny_oci(self.parent_dir, "amd64", "linux", [self.diff_id_0], [self.parent_layer0_gz], [True])
        create_tiny_oci(
            self.child_dir,
            "amd64",
            "linux",
            [self.diff_id_0, self.diff_id_1],
            [self.child_l0_uncompressed, self.child_l1_uncompressed],
            [False, False],
        )

        # Corrupt parent blob by flipping bits without altering length
        parent_manifest = json.loads((self.parent_dir / "index.json").read_text())
        man_digest = parent_manifest["manifests"][0]["digest"]
        man = json.loads((self.parent_dir / "blobs" / "sha256" / man_digest.removeprefix("sha256:")).read_text())
        p0_hash = man["layers"][0]["digest"].removeprefix("sha256:")
        blob_file = self.parent_dir / "blobs" / "sha256" / p0_hash

        original_bytes = blob_file.read_bytes()
        corrupted = bytearray(original_bytes)
        corrupted[10] ^= 0xFF  # Flip byte inside blob
        corrupted_bytes = bytes(corrupted)
        self.assertEqual(len(corrupted_bytes), len(original_bytes))
        blob_file.write_bytes(corrupted_bytes)

        with self.assertRaises(ValueError) as cm:
            assemble_publication_layout(self.child_dir, self.parent_dir, self.output_dir, "test-tag")
        self.assertIn("blob digest mismatch", str(cm.exception))
        self.assertFalse(self.output_dir.exists())

    def test_rejects_malformed_digest_traversal(self):
        create_tiny_oci(self.parent_dir, "amd64", "linux", [self.diff_id_0], [self.parent_layer0_gz], [True])
        create_tiny_oci(
            self.child_dir,
            "amd64",
            "linux",
            [self.diff_id_0, self.diff_id_1],
            [self.child_l0_uncompressed, self.child_l1_uncompressed],
            [False, False],
        )

        # Inject malformed digest in child index
        index_file = self.child_dir / "index.json"
        idx = json.loads(index_file.read_text())
        idx["manifests"][0]["digest"] = "sha256:../../traversal"
        index_file.write_text(json.dumps(idx))

        with self.assertRaises(ValueError) as cm:
            assemble_publication_layout(self.child_dir, self.parent_dir, self.output_dir, "test-tag")
        self.assertIn("invalid digest", str(cm.exception))


if __name__ == "__main__":
    unittest.main()
