"""Regression tests for the issue-policy catalog and issue-lifecycle caller."""

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG_PATH = ROOT / ".github" / "issue-policy.json"
WORKFLOW_PATH = ROOT / ".github" / "workflows" / "issue-lifecycle.yml"

STAGES = {
    "needs-triage",
    "triage/needs-information",
    "triage/accepted",
    "awaiting-release",
    "needs-verification",
}

REQUIRED_LABELS = {
    "kind/bug",
    "kind/feature",
    "kind/task",
    "needs-kind",
    "needs-human",
    "human-only",
    "tracking",
}


class IssuePolicyContractTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(CATALOG_PATH.is_file(), f"missing {CATALOG_PATH}")
        with CATALOG_PATH.open(encoding="utf-8") as fh:
            self.catalog = json.load(fh)

    def test_catalog_repository_and_display_name(self):
        self.assertEqual(
            self.catalog.get("repository"),
            "projectbluefin/gutenprint-printer-app",
        )
        self.assertTrue(bool(self.catalog.get("display_name", "").strip()))

    def test_catalog_comment_marker(self):
        marker = self.catalog.get("comment_marker", "")
        self.assertRegex(marker, r"^<!-- [A-Za-z0-9_.:-]+ -->$")

    def test_catalog_delivery_type(self):
        self.assertEqual(self.catalog.get("delivery", {}).get("type"), "image")

    def test_catalog_stages(self):
        self.assertEqual(set(self.catalog.get("stages", {})), STAGES)

    def test_catalog_required_labels(self):
        labels = self.catalog.get("labels", {})
        self.assertTrue(REQUIRED_LABELS.issubset(set(labels)))
        self.assertFalse(set(labels) & STAGES)

    def test_label_and_stage_definitions_colors_and_descriptions(self):
        combined = {**self.catalog.get("stages", {}), **self.catalog.get("labels", {})}
        for name, entry in combined.items():
            self.assertIsInstance(entry, dict, f"label {name} must be a dict")
            self.assertEqual(set(entry), {"color", "description"})
            self.assertRegex(entry["color"], r"^[0-9a-fA-F]{6}$")
            self.assertIsInstance(entry["description"], str)

    def test_retired_stages_do_not_overlap_active_definitions(self):
        retired = self.catalog.get("retired_stages", [])
        combined = set(self.catalog.get("stages", {})) | set(self.catalog.get("labels", {}))
        self.assertFalse(set(retired) & combined)
        self.assertIn("1-triage", retired)
        self.assertIn("3-clanker-queue", retired)

    def test_standing_issues_are_positive_integers(self):
        standing = self.catalog.get("standing_issues", [])
        self.assertIsInstance(standing, list)
        self.assertTrue(all(isinstance(n, int) and n >= 1 for n in standing))

    def test_workflow_caller_uses_actions_reusable_workflow(self):
        self.assertTrue(WORKFLOW_PATH.is_file(), f"missing {WORKFLOW_PATH}")
        content = WORKFLOW_PATH.read_text(encoding="utf-8")
        self.assertIn("projectbluefin/actions/.github/workflows/reusable-issue-lifecycle.yml", content)
        # Verify pinning to verified v1 release commit
        self.assertRegex(content, r"@48a0112c6293d00357eef0ef3a4ce2e54dbdd94a\s+#\s+v1")
        self.assertIn("projectbluefin/gutenprint-printer-app", content)


if __name__ == "__main__":
    unittest.main()
