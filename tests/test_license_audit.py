import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location(
    "audit", Path(__file__).resolve().parents[1] / "scripts/audit-oci-licenses.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class LicenseAuditTests(unittest.TestCase):
    def setUp(self):
        self.sbom = {
            "spdxVersion": "SPDX-2.3",
            "packages": [{"name": "gutenprint", "SPDXID": "SPDXRef-gutenprint",
                          "licenseDeclared": "GPL-2.0-or-later"}],
            "hasExtractedLicensingInfos": [{"licenseId": "LicenseRef-custom",
                                           "extractedText": "Keep this notice"}],
            "externalDocumentRefs": [{"externalDocumentId": "DocumentRef-runtime"}],
        }
        self.index = {"annotations": {audit.LICENSE_KEY: "Apache-2.0"}}
        self.config = {"config": {"Labels": {audit.LICENSE_KEY: "Apache-2.0"}}}

    def report(self, configs=None):
        return audit.audit(self.sbom, self.index,
                           configs or {"amd64": self.config, "arm64": self.config},
                           "Apache-2.0")

    def test_inventory_preserves_unknowns_notices_and_input(self):
        before = copy.deepcopy(self.sbom)
        report = self.report()
        self.assertEqual(report["errors"], [])
        self.assertTrue(report["packages"][0]["reviewRequired"])
        self.assertEqual(report["packages"][0]["licenseConcluded"], "NOASSERTION")
        self.assertEqual(report["hasExtractedLicensingInfos"],
                         self.sbom["hasExtractedLicensingInfos"])
        self.assertEqual(report["externalDocumentRefs"], self.sbom["externalDocumentRefs"])
        self.assertEqual(self.sbom, before)

    def test_each_platform_must_agree(self):
        bad = {"config": {"Labels": {audit.LICENSE_KEY: "MIT"}}}
        report = self.report({"amd64": self.config, "arm64": bad})
        self.assertEqual(len(report["errors"]), 1)
        self.assertIn("arm64", report["errors"][0])

    def test_missing_index_label_fails(self):
        self.index = {}
        self.assertIn("index", self.report()["errors"][0])

    def test_missing_config_label_fails(self):
        self.assertEqual(len(self.report({"amd64": {}})["errors"]), 1)

    def test_differing_expressions_remain_visible(self):
        self.sbom["packages"][0]["licenseConcluded"] = "GPL-2.0-only"
        self.assertTrue(self.report()["packages"][0]["reviewRequired"])

    def test_empty_or_unsupported_sbom_rejected(self):
        for document in ({"spdxVersion": "SPDX-2.3", "packages": []},
                         {"spdxVersion": "SPDX-3.0", "packages": [{}]}):
            with self.assertRaises(ValueError):
                audit.audit(document, self.index, {}, "Apache-2.0")

    def test_package_without_name_or_identifier_rejected(self):
        for package in ({"SPDXID": "SPDXRef-x"}, {"name": "x"}):
            self.sbom["packages"] = [package]
            with self.assertRaisesRegex(ValueError, "name and SPDXID"):
                self.report()


class LicenseAuditCliTests(unittest.TestCase):
    """The exit status is the contract docs/oci-licenses.md documents."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        self.sbom = {"spdxVersion": "SPDX-2.3",
                     "packages": [{"name": "gutenprint", "SPDXID": "SPDXRef-g"}]}
        self.index = {"annotations": {audit.LICENSE_KEY: "Apache-2.0"}}
        self.configs = {"amd64": {"config": {"Labels": {audit.LICENSE_KEY: "Apache-2.0"}}},
                        "arm64": {"config": {"Labels": {audit.LICENSE_KEY: "Apache-2.0"}}}}

    def write(self, name, document):
        path = self.dir / name
        path.write_text(document if isinstance(document, str) else json.dumps(document))
        return path

    def run_cli(self, expected="Apache-2.0", sbom=None):
        argv = ["audit-oci-licenses.py",
                "--sbom", str(sbom or self.write("sbom.json", self.sbom)),
                "--index", str(self.write("index.json", self.index))]
        for name, config in self.configs.items():
            argv += ["--config", str(self.write(f"{name}.json", config))]
        argv += ["--expected-license", expected]
        out, err = io.StringIO(), io.StringIO()
        with mock.patch("sys.argv", argv), contextlib.redirect_stdout(out), \
                contextlib.redirect_stderr(err):
            try:
                status = int(audit.main())
            except SystemExit as exit_:
                status = exit_.code
        return status, out.getvalue(), err.getvalue()

    def test_matching_metadata_exits_zero_with_report(self):
        status, out, _ = self.run_cli()
        self.assertEqual(status, 0)
        report = json.loads(out)
        self.assertEqual(report["errors"], [])
        self.assertEqual(sorted(report["metadata"]),
                         sorted(["index", str(self.dir / "amd64.json"),
                                 str(self.dir / "arm64.json")]))

    def test_differing_metadata_exits_one_and_still_reports(self):
        self.configs["arm64"] = {"config": {"Labels": {audit.LICENSE_KEY: "MIT"}}}
        status, out, _ = self.run_cli()
        self.assertEqual(status, 1)
        errors = json.loads(out)["errors"]
        self.assertEqual(len(errors), 1)
        self.assertIn("arm64.json", errors[0])

    def test_unreadable_or_unsupported_input_exits_two(self):
        cases = {
            "missing file": self.dir / "absent.json",
            "invalid JSON": self.write("broken.json", "{"),
            "unsupported SPDX": self.write("v3.json", {"spdxVersion": "SPDX-3.0"}),
            "not an object": self.write("list.json", []),
        }
        for label, sbom in cases.items():
            with self.subTest(label):
                status, out, err = self.run_cli(sbom=sbom)
                self.assertEqual(status, 2)
                self.assertEqual(out, "")
                self.assertTrue(err.startswith("audit error: "), err)


if __name__ == "__main__":
    unittest.main()
