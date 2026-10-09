#!/usr/bin/env python3
"""Execute the release workflow's metadata gate against fixture repositories.

registry-actions.yml publishes an immutable OCI release for a pushed v* tag
only after the metadata job's "Require stable ancestry and matching immutable
release sources" step proves that the tag is on stable, that it names the
pinned Gutenprint version, that the pinned Debian tag still dereferences to
the pinned commit, and that the OCI element carries the FSDK labels. That
step only runs on a real tag push, so this test lifts its run block out of the
workflow verbatim and runs it in throwaway git repositories: a change to the
gate is tested as written, with no copy to drift from it.

The Gutenprint remote is redirected to a local bare repository through a
private git config (url.<local>.insteadOf), so no network is needed.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github/workflows/registry-actions.yml"
PINS = Path("include/source-pins.yml")
ELEMENT = Path("elements/oci/gutenprint-printer-app.bst")
STEP_NAME = "Require stable ancestry and matching immutable release sources"
GUTENPRINT_REMOTE = "https://salsa.debian.org/printing-team/gutenprint.git"
FSDK_REF = "b" * 40
DEBIAN_TAG = "debian/5.3.6-2026-02-01T02-18-9b0bdf87-4"
OUTPUT_KEYS = {"version", "revision", "created", "gutenprint_ref", "fsdk_version", "fsdk_ref"}


def step_script(workflow, step_name):
    """Return the dedented `run: |` body of the named step."""
    lines = workflow.read_text().splitlines()
    starts = [i for i, line in enumerate(lines)
              if re.fullmatch(rf"\s*- name: {re.escape(step_name)}", line)]
    if len(starts) != 1:
        raise ValueError(f"expected one step named {step_name!r} in {workflow}")
    step_indent = len(lines[starts[0]]) - len(lines[starts[0]].lstrip())
    run_at = None
    for i in range(starts[0] + 1, len(lines)):
        line = lines[i]
        indent = len(line) - len(line.lstrip())
        if line.strip() and indent <= step_indent:
            break
        if re.fullmatch(r"\s*run: \|", line):
            run_at = i
            break
    if run_at is None:
        raise ValueError(f"step {step_name!r} has no `run: |` block")
    run_indent = len(lines[run_at]) - len(lines[run_at].lstrip())
    body = []
    for line in lines[run_at + 1:]:
        if line.strip() and len(line) - len(line.lstrip()) <= run_indent:
            break
        body.append(line)
    while body and not body[-1].strip():
        body.pop()
    block_indent = min(len(l) - len(l.lstrip()) for l in body if l.strip())
    return "\n".join(l[block_indent:] for l in body) + "\n"


def pins_text(version="5.3.6-4.2", tag=DEBIAN_TAG, ref=None):
    return ("variables:\n"
            f'  gutenprint-version: "{version}"\n'
            f'  gutenprint-tag: "{tag}"\n'
            f'  gutenprint-ref: "{ref}"\n')


def element_text(fsdk_version="26.08.1", fsdk_ref=FSDK_REF):
    lines = ["kind: oci", "config:", "  images:", "  - annotations:"]
    if fsdk_version is not None:
        lines.append(f"              'io.projectbluefin.fsdk.version': '{fsdk_version}'")
    if fsdk_ref is not None:
        lines.append(f"              'io.projectbluefin.fsdk.ref': '{fsdk_ref}'")
    return "\n".join(lines) + "\n"


class ReleaseMetadataGate(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = step_script(WORKFLOW, STEP_NAME)

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="release-metadata."))
        self.addCleanup(shutil.rmtree, self.tmp)
        home = self.tmp / "home"
        home.mkdir()
        gitconfig = self.tmp / "gitconfig"
        self.salsa = self.tmp / "salsa.git"
        gitconfig.write_text(
            "[user]\n\tname = test\n\temail = test@example.invalid\n"
            "[init]\n\tdefaultBranch = stable\n"
            "[commit]\n\tgpgsign = false\n"
            "[tag]\n\tgpgsign = false\n"
            f'[url "{self.salsa.as_uri()}"]\n\tinsteadOf = {GUTENPRINT_REMOTE}\n')
        self.env = {
            "PATH": os.environ["PATH"],
            "HOME": str(home),
            "GIT_CONFIG_GLOBAL": str(gitconfig),
            "GIT_CONFIG_NOSYSTEM": "1",
            "LC_ALL": "C",
        }

        # The Debian packaging repository: an annotated release tag, as
        # salsa publishes them, on a commit whose id the pins must name.
        upstream = self.tmp / "gutenprint"
        self.git(self.tmp, "init", "--quiet", str(upstream))
        (upstream / "README").write_text("gutenprint\n")
        self.git(upstream, "add", "README")
        self.git(upstream, "commit", "--quiet", "-m", "release")
        self.gutenprint_ref = self.git(upstream, "rev-parse", "HEAD")
        self.git(upstream, "tag", "-a", "-m", "release", DEBIAN_TAG)
        (upstream / "README").write_text("gutenprint next\n")
        self.git(upstream, "commit", "--quiet", "-am", "next")
        self.other_ref = self.git(upstream, "rev-parse", "HEAD")
        self.git(upstream, "tag", "-a", "-m", "next", "debian/5.3.6-2026-03-01T00-00-00000000-5")
        self.git(self.tmp, "clone", "--quiet", "--bare", str(upstream), str(self.salsa))

        self.origin = self.tmp / "origin.git"
        self.work = self.tmp / "work"
        self.git(self.tmp, "init", "--quiet", "--bare", str(self.origin))
        self.git(self.tmp, "init", "--quiet", str(self.work))
        self.git(self.work, "remote", "add", "origin", str(self.origin))
        self.commit(pins_text(ref=self.gutenprint_ref), element_text(), "release")
        self.git(self.work, "push", "--quiet", "origin", "HEAD:refs/heads/stable")

    def git(self, cwd, *args):
        return subprocess.run(["git", *args], cwd=cwd, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, pins, element, message):
        for rel, text in ((PINS, pins), (ELEMENT, element)):
            path = self.work / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.git(self.work, "add", "-A")
        self.git(self.work, "commit", "--quiet", "--allow-empty", "-m", message)
        return self.git(self.work, "rev-parse", "HEAD")

    def run_gate(self, ref_name="v5.3.6-4.2"):
        output = self.tmp / "github_output"
        output.write_text("")
        env = dict(self.env, GITHUB_OUTPUT=str(output), GITHUB_REF_NAME=ref_name)
        # GitHub runs `shell: bash` steps as `bash --noprofile --norc -eo pipefail`.
        proc = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", self.script],
                              cwd=self.work, env=env, capture_output=True, text=True)
        outputs = dict(line.split("=", 1) for line in output.read_text().splitlines() if line)
        return proc, outputs

    def assert_refused(self, proc, outputs, message=None):
        self.assertNotEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(outputs, {}, "a refused release must not publish step outputs")
        if message is not None:
            self.assertIn(message, proc.stderr)

    def test_extracted_step_is_the_whole_gate(self):
        self.assertTrue(self.script.startswith("set -euo pipefail\n"), self.script[:80])
        self.assertIn('>> "$GITHUB_OUTPUT"', self.script)

    def test_stable_head_matching_pins_publishes_every_output(self):
        head = self.git(self.work, "rev-parse", "HEAD")
        proc, outputs = self.run_gate()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(set(outputs), OUTPUT_KEYS)
        self.assertEqual(outputs["version"], "5.3.6-4.2")
        self.assertEqual(outputs["revision"], head)
        self.assertEqual(outputs["created"], self.git(self.work, "show", "-s", "--format=%cI", "HEAD"))
        self.assertEqual(outputs["gutenprint_ref"], self.gutenprint_ref)
        self.assertEqual(outputs["fsdk_version"], "26.08.1")
        self.assertEqual(outputs["fsdk_ref"], FSDK_REF)

    def test_version_without_rebuild_suffix_passes(self):
        self.commit(pins_text(version="5.3.6-4", ref=self.gutenprint_ref), element_text(), "plain")
        self.git(self.work, "push", "--quiet", "origin", "HEAD:refs/heads/stable")
        proc, outputs = self.run_gate("v5.3.6-4")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(outputs["version"], "5.3.6-4")

    def test_tag_on_an_earlier_stable_commit_is_accepted(self):
        release = self.git(self.work, "rev-parse", "HEAD")
        self.commit(pins_text(ref=self.gutenprint_ref), element_text(), "later")
        self.git(self.work, "push", "--quiet", "origin", "HEAD:refs/heads/stable")
        self.git(self.work, "checkout", "--quiet", "--detach", release)
        proc, outputs = self.run_gate()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(outputs["revision"], release)

    def test_tag_off_stable_is_refused(self):
        self.commit(pins_text(ref=self.gutenprint_ref), element_text(), "unpromoted")
        proc, outputs = self.run_gate()
        self.assert_refused(proc, outputs, "Release tag must point at a commit promoted to stable")

    def test_stale_local_stable_ref_does_not_vouch_for_the_tag(self):
        # The local tracking ref still contains HEAD, but stable has since
        # been rewound past it: the gate must ask origin, not trust the clone.
        self.git(self.work, "fetch", "--quiet", "origin", "stable:refs/remotes/origin/stable")
        released = self.git(self.work, "rev-parse", "HEAD")
        self.git(self.work, "checkout", "--quiet", "--orphan", "rewound")
        rewound = self.commit(pins_text(ref=self.gutenprint_ref), element_text(), "rewound")
        # Rewind origin directly: a push from this clone would also move the
        # local tracking ref and hide the staleness under test.
        self.git(self.work, "push", "--quiet", "origin", f"{rewound}:refs/heads/rewound")
        self.git(self.origin, "update-ref", "refs/heads/stable", rewound)
        self.git(self.work, "checkout", "--quiet", "--detach", released)
        self.assertEqual(self.git(self.work, "rev-parse", "refs/remotes/origin/stable"), released)
        proc, outputs = self.run_gate()
        self.assert_refused(proc, outputs)

    def test_tag_naming_a_different_version_is_refused(self):
        for ref_name in ("v5.3.6-4.1", "5.3.6-4.2", "v5.3.6-4.2-rc1", "V5.3.6-4.2"):
            with self.subTest(ref_name=ref_name):
                proc, outputs = self.run_gate(ref_name)
                self.assert_refused(proc, outputs, "does not match Gutenprint version v5.3.6-4.2")

    def test_malformed_or_disagreeing_pins_are_refused(self):
        cases = {
            "version without Debian revision": pins_text(version="5.3.6", ref=self.gutenprint_ref),
            "version revision disagrees with tag": pins_text(version="5.3.6-5", ref=self.gutenprint_ref),
            "non-numeric rebuild suffix": pins_text(version="5.3.6-4.2rc1", ref=self.gutenprint_ref),
            "version upstream disagrees with tag": pins_text(version="5.3.7-4", ref=self.gutenprint_ref),
            "tag outside debian namespace": pins_text(tag="upstream/5.3.6-4", ref=self.gutenprint_ref),
            "abbreviated ref": pins_text(ref=self.gutenprint_ref[:12]),
            "uppercase ref": pins_text(ref=self.gutenprint_ref.upper()),
            "missing ref": pins_text(ref=""),
        }
        for name, pins in cases.items():
            with self.subTest(name):
                version = re.search(r'gutenprint-version: "([^"]*)"', pins).group(1)
                self.commit(pins, element_text(), name)
                self.git(self.work, "push", "--quiet", "origin", "HEAD:refs/heads/stable")
                proc, outputs = self.run_gate(f"v{version}")
                self.assert_refused(proc, outputs)

    def test_pinned_tag_must_still_dereference_to_the_pinned_commit(self):
        cases = {
            "tag absent from the Gutenprint remote": pins_text(
                tag="debian/5.3.6-2026-09-09T00-00-deadbeef-4", ref=self.gutenprint_ref),
            "ref names a different commit than the tag": pins_text(ref=self.other_ref),
        }
        for name, pins in cases.items():
            with self.subTest(name):
                self.commit(pins, element_text(), name)
                self.git(self.work, "push", "--quiet", "origin", "HEAD:refs/heads/stable")
                proc, outputs = self.run_gate()
                self.assert_refused(proc, outputs)

    def test_retagged_release_is_refused(self):
        upstream = self.tmp / "gutenprint"
        self.git(upstream, "tag", "-f", "-a", "-m", "moved", DEBIAN_TAG, self.other_ref)
        self.git(upstream, "push", "--quiet", "--force", str(self.salsa), f"refs/tags/{DEBIAN_TAG}")
        proc, outputs = self.run_gate()
        self.assert_refused(proc, outputs)

    def test_missing_or_malformed_fsdk_labels_are_refused(self):
        cases = {
            "no version label": element_text(fsdk_version=None),
            "empty version label": element_text(fsdk_version=""),
            "no ref label": element_text(fsdk_ref=None),
            "abbreviated ref label": element_text(fsdk_ref=FSDK_REF[:12]),
        }
        for name, element in cases.items():
            with self.subTest(name):
                self.commit(pins_text(ref=self.gutenprint_ref), element, name)
                self.git(self.work, "push", "--quiet", "origin", "HEAD:refs/heads/stable")
                proc, outputs = self.run_gate()
                self.assert_refused(proc, outputs)

    def test_repository_pins_and_element_satisfy_the_gate(self):
        # The committed pins and OCI element, with only gutenprint-ref pointed
        # at the fixture remote's commit, must pass for their own version tag.
        pins = (ROOT / PINS).read_text()
        version = re.search(r'^  gutenprint-version: "([^"]*)"$', pins, re.M).group(1)
        tag = re.search(r'^  gutenprint-tag: "([^"]*)"$', pins, re.M).group(1)
        upstream = self.tmp / "gutenprint"
        self.git(upstream, "tag", "-f", "-a", "-m", "repository pin", tag, self.gutenprint_ref)
        self.git(upstream, "push", "--quiet", "--force", str(self.salsa), f"refs/tags/{tag}")
        pins = re.sub(r'^(  gutenprint-ref: ")[^"]*(")$', rf"\g<1>{self.gutenprint_ref}\g<2>", pins, flags=re.M)
        self.commit(pins, (ROOT / ELEMENT).read_text(), "repository files")
        self.git(self.work, "push", "--quiet", "origin", "HEAD:refs/heads/stable")
        proc, outputs = self.run_gate(f"v{version}")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(outputs["version"], version)
        self.assertRegex(outputs["fsdk_ref"], r"^[0-9a-f]{40}$")
        self.assertTrue(outputs["fsdk_version"])


if __name__ == "__main__":
    unittest.main()
