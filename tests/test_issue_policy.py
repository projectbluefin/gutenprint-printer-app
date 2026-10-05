"""Repo-specific contract tests for .github/issue-policy.json and issue-lifecycle.yml."""

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG_PATH = ROOT / ".github" / "issue-policy.json"
WORKFLOW_PATH = ROOT / ".github" / "workflows" / "issue-lifecycle.yml"

EXPECTED_STAGES = {
    "needs-triage",
    "triage/needs-information",
    "triage/accepted",
    "awaiting-release",
    "needs-verification",
}


class RepoIssuePolicyContractTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(CATALOG_PATH.is_file(), f"missing {CATALOG_PATH}")
        with CATALOG_PATH.open(encoding="utf-8") as fh:
            self.catalog = json.load(fh)

    def test_catalog_repository_and_marker(self):
        self.assertEqual(
            self.catalog.get("repository"),
            "projectbluefin/gutenprint-printer-app",
        )
        self.assertEqual(self.catalog.get("delivery", {}).get("type"), "image")
        marker = self.catalog.get("comment_marker", "")
        self.assertRegex(marker, r"^<!-- gutenprint-issue-lifecycle:v1 -->$")

    def test_catalog_stages(self):
        self.assertEqual(set(self.catalog.get("stages", {})), EXPECTED_STAGES)

    def test_actionable_bugs_remain_routable_not_standing(self):
        standing = self.catalog.get("standing_issues", [])
        # Only Epic #1 and Dependency Dashboard #45 qualify as standing trackers
        self.assertEqual(standing, [1, 45])
        # Actionable bugs #48 (unsigned tag) and #75 (Renovate tracking) must remain routable
        self.assertNotIn(48, standing)
        self.assertNotIn(75, standing)

    def test_legacy_label_aliases_map_safely_to_canonical_kinds(self):
        aliases = self.catalog.get("label_aliases", {})
        self.assertEqual(aliases.get("bug"), "kind/bug")
        self.assertEqual(aliases.get("enhancement"), "kind/feature")
        self.assertEqual(aliases.get("question"), "kind/task")

    def test_needs_decision_is_protected_operational_label(self):
        protected = self.catalog.get("protected_labels", [])
        self.assertIn("needs-decision", protected)

    def test_workflow_caller_contract(self):
        self.assertTrue(WORKFLOW_PATH.is_file(), f"missing {WORKFLOW_PATH}")
        content = WORKFLOW_PATH.read_text(encoding="utf-8")
        self.assertIn("projectbluefin/actions/.github/workflows/reusable-issue-lifecycle.yml@v1", content)
        self.assertIn("github.repository == 'projectbluefin/gutenprint-printer-app'", content)
        self.assertIn("issues: write", content)
        self.assertIn("contents: read", content)
        self.assertIn("actions: read", content)
        self.assertIn("pull-requests: write", content)
        self.assertNotIn("secrets: inherit", content)


if __name__ == "__main__":
    unittest.main()
