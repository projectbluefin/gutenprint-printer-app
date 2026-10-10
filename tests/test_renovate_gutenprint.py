"""Renovate must track every Debian Gutenprint tag format and derive the version."""

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SALSA = "https://salsa.debian.org/printing-team/gutenprint.git"


def render(template, new_value, new_digest):
    """Render autoReplaceStringTemplate like Renovate's `replace` helper."""
    def helper(match):
        find, repl = match.groups()
        return re.sub(find, re.sub(r"\$(\d)", r"\\\1", repl), new_value)
    out = re.sub(r"\{\{\{replace '([^']*)' '([^']*)' newValue\}\}\}", helper, template)
    return out.replace("{{{newValue}}}", new_value).replace("{{{newDigest}}}", new_digest)


class GutenprintRenovateTests(unittest.TestCase):
    def test_all_tag_formats_map_to_upstream_and_revision(self):
        config = json.loads((ROOT / "renovate.json").read_text())
        (manager,) = [m for m in config["customManagers"] if m.get("packageNameTemplate") == SALSA]
        self.assertEqual(manager["versioningTemplate"], "deb")
        extract = re.compile(manager["extractVersionTemplate"].replace("(?<", "(?P<"))
        pattern = re.compile(manager["matchStrings"][0].replace("(?<", "(?P<"))
        pins = (ROOT / "include/source-pins.yml").read_text()
        match = pattern.search(pins)
        self.assertIsNotNone(match, "matchStrings no longer matches include/source-pins.yml")
        digest = "0" * 40
        for tag, version in {
            "debian/5.3.3-9": "5.3.3-9",
            "debian/5.3.4.20220624T01008808d602-4": "5.3.4-4",
            "debian/5.3.6-2026-02-01T02-18-9b0bdf87-4": "5.3.6-4",
            "debian/5.3.6-2026-09-01T00-00-abcdef01-1": "5.3.6-1",
        }.items():
            new_value = extract.fullmatch(tag)["version"]
            replaced = render(manager["autoReplaceStringTemplate"], new_value, digest)
            self.assertEqual(
                replaced,
                f'gutenprint-version: "{version}"\n  gutenprint-tag: "{tag}"\n  gutenprint-ref: "{digest}"',
            )
            # The rewritten block must still be matched on the next run.
            self.assertEqual(pattern.search(pins.replace(match[0], replaced))["currentValue"], new_value)


if __name__ == "__main__":
    unittest.main()
