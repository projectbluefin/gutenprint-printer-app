"""Validate .github/issue-policy.json against the released actions schema/validator."""

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG_PATH = ROOT / ".github" / "issue-policy.json"
WORKFLOW_PATH = ROOT / ".github" / "workflows" / "issue-lifecycle.yml"

# Exact constants from projectbluefin/actions scripts/issue_policy.py@48a0112c (v1)
STAGES = {
    "needs-triage",
    "triage/needs-information",
    "triage/accepted",
    "awaiting-release",
    "needs-verification",
}


def protected_labels(catalog):
    """Exact operator-owned names, compared like GitHub labels, never managed here."""
    return {name.lower() for name in catalog.get("protected_labels", [])}


def validate_catalog(catalog, repository=None):
    """Canonical validator from projectbluefin/actions scripts/issue_policy.py."""
    repo = catalog.get("repository", "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo) or repo.lower().startswith("ublue-os/"):
        raise ValueError("Invalid or prohibited catalog repository")
    if repository is not None and repository != repo:
        raise ValueError(f"Catalog only writes {repo}; repository mismatch")
    if set(catalog.get("stages", {})) != STAGES:
        raise ValueError("Catalog must define the five lifecycle stages")
    if not isinstance(catalog.get("display_name"), str) or not catalog["display_name"].strip():
        raise ValueError("Catalog requires display_name")
    if not re.fullmatch(r"<!-- [A-Za-z0-9_.:-]+ -->", catalog.get("comment_marker", "")):
        raise ValueError("Catalog requires a unique hidden comment_marker")
    if catalog.get("delivery", {}).get("type") not in {"image", "release"}:
        raise ValueError("Catalog delivery.type must be image or release")
    labels = catalog.get("labels", {})
    required = {"kind/bug", "kind/feature", "kind/task", "needs-kind", "needs-human", "human-only", "tracking"}
    if not required <= set(labels) or set(labels) & STAGES:
        raise ValueError("Catalog is missing lifecycle gate/classification definitions")
    for name, definition in (catalog["stages"] | labels).items():
        if not isinstance(name, str) or not name or not isinstance(definition, dict) or set(definition) != {"color", "description"}:
            raise ValueError("Invalid catalog label definition")
        if not re.fullmatch(r"[0-9a-fA-F]{6}", definition["color"]) or not isinstance(definition["description"], str):
            raise ValueError("Invalid label color or description")
    signals = catalog.get("protected_labels", [])
    if not isinstance(signals, list) or any(not isinstance(name, str) or not name for name in signals):
        raise ValueError("protected_labels must explicitly list independent operational label names")
    unmanaged = protected_labels(catalog)
    if len(unmanaged) != len(signals) or unmanaged & {name.lower() for name in catalog["stages"] | labels}:
        raise ValueError("protected_labels must be unique and outside managed catalog definitions")
    retired = catalog.get("retired_stages")
    if not isinstance(retired, list) or any(not isinstance(n, str) or not n for n in retired) or set(retired) & set(catalog["stages"] | labels) or any(name.lower() in unmanaged for name in retired):
        raise ValueError("Retired labels must not overlap canonical definitions or protected operational labels")
    if not isinstance(catalog.get("standing_issues"), list) or any(type(n) is not int or n < 1 for n in catalog["standing_issues"]):
        raise ValueError("Invalid standing issue numbers")
    aliases = catalog.get("label_aliases")
    if not isinstance(aliases, dict):
        raise ValueError("Catalog requires explicit label_aliases")
    protected = STAGES | {"blocked", "hold", "needs-human", "human-only", "needs-kind", "tracking", "lgtm", "automerge"} | unmanaged
    for old, new in aliases.items():
        if not isinstance(old, str) or not old or old.lower() in protected or old.startswith(("agent/", "hive/")) or old in set(catalog["stages"] | labels):
            raise ValueError("Alias cannot retire a canonical or independent operational label")
        if new is not None and (new not in labels or new.lower() in protected or not new.startswith(("kind/", "area/"))):
            raise ValueError("Aliases may only map descriptive labels, never grant a lifecycle stage or gate")
    sources = catalog.get("kind_sources", {})
    if not isinstance(sources, dict) or any(
        old not in labels or old.startswith("kind/") or not isinstance(new, str)
        or new not in labels or not new.startswith("kind/")
        for old, new in sources.items()
    ):
        raise ValueError("kind_sources must map existing operational labels to catalog kinds")
    gates = catalog.get("gate_labels", [])
    if not isinstance(gates, list) or any(not isinstance(name, str) or name not in labels for name in gates):
        raise ValueError("gate_labels must name existing independent catalog labels")
    for field_type in ("bug_fields", "feature_fields"):
        field_names = catalog.get(field_type, [])
        if not isinstance(field_names, list) or any(not isinstance(name, str) or not name.strip() for name in field_names):
            raise ValueError(f"{field_type} must name the repository's issue-form headings")
    prior_markers = catalog.get("prior_comment_markers", [])
    if not isinstance(prior_markers, list) or any(
        not isinstance(marker, str) or not re.fullmatch(r"<!-- [A-Za-z0-9_.:-]+ -->", marker)
        for marker in prior_markers
    ):
        raise ValueError("prior_comment_markers must be explicit hidden lifecycle markers")
    workflows = catalog.get("main_ci_workflows", [])
    if not isinstance(workflows, list) or any(
        not isinstance(path, str) or not re.fullmatch(r"\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml", path)
        for path in workflows
    ):
        raise ValueError("main_ci_workflows must name repository-owned CI workflow paths")
    intake_rules = catalog.get("intake_rules", [])
    if not isinstance(intake_rules, list) or len(intake_rules) > 64:
        raise ValueError("intake_rules must be a bounded list of descriptive metadata rules")
    protected_intake = protected | set(retired) | set(gates) | {"ai-fix-requested"}
    for rule in intake_rules:
        if not isinstance(rule, dict) or set(rule) != {"match", "labels"}:
            raise ValueError("intake_rules require match selectors and metadata labels only")
        selectors, targets = rule["match"], rule["labels"]
        if not isinstance(selectors, dict) or not selectors or not set(selectors) <= {"title_prefixes", "body_contains", "body_headings"}:
            raise ValueError("Unsupported intake selector; use literal title prefixes, body text or headings")
        for values in selectors.values():
            if not isinstance(values, list) or not 1 <= len(values) <= 16 or any(
                not isinstance(value, str) or not value.strip() or len(value) > 256 for value in values
            ):
                raise ValueError("Intake selectors must be bounded nonempty literal strings")
        if not isinstance(targets, list) or not 1 <= len(targets) <= 8 or any(
            not isinstance(name, str) or name not in labels or name in protected_intake or name.lower() in unmanaged
            or name.startswith(("needs-", "hive/", "queue/", "status/")) for name in targets
        ):
            raise ValueError("Intake targets must be catalog metadata, never stages, consent, dispatch or independent control labels")
    return catalog


class CanonicalIssuePolicyValidationTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(CATALOG_PATH.is_file(), f"missing {CATALOG_PATH}")
        with CATALOG_PATH.open(encoding="utf-8") as fh:
            self.catalog = json.load(fh)

    def test_canonical_actions_validator_passes(self):
        validated = validate_catalog(self.catalog, "projectbluefin/gutenprint-printer-app")
        self.assertIsInstance(validated, dict)

    def test_workflow_caller_contract(self):
        self.assertTrue(WORKFLOW_PATH.is_file(), f"missing {WORKFLOW_PATH}")
        content = WORKFLOW_PATH.read_text(encoding="utf-8")
        self.assertIn("projectbluefin/actions/.github/workflows/reusable-issue-lifecycle.yml", content)
        self.assertRegex(content, r"@48a0112c6293d00357eef0ef3a4ce2e54dbdd94a\s+#\s+v1")
        self.assertIn("github.repository == 'projectbluefin/gutenprint-printer-app'", content)
        self.assertIn("issues: write", content)
        self.assertIn("contents: read", content)
        self.assertIn("actions: read", content)
        self.assertNotIn("pull-requests: write", content)
        self.assertNotIn("secrets: inherit", content)


if __name__ == "__main__":
    unittest.main()
