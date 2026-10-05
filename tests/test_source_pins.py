"""Hermetic tests for the tests/source-pins.sh gate and scripts/fsdk-pin.sh.

`just validate` runs source-pins.sh against the real Gutenprint and
fsdk-containers remotes, where every pin agrees, so only its pass path ever
executes there. These tests copy the gate, the helper and the three pinned
files into a scratch tree, point both remotes at local git repositories, and
check that every disagreement is rejected.
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PINS = "include/source-pins.yml"
JUNCTION = "elements/fsdk-containers.bst"
OCI = "elements/oci/gutenprint-printer-app.bst"

VERSION = "5.3.6-4.2"
TAG = "debian/5.3.6-2026-02-01T02-18-9b0bdf87-4"
FSDK_VERSION = "26.08.1"
FSDK_REF = "b02b59ffe19a49a402f357fd5fcb1d552ebc50d7"
OTHER_SHA = "0123456789abcdef0123456789abcdef01234567"


def git_env(home):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update({
        "HOME": str(home),
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
        "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "test@example.invalid",
        "GIT_TERMINAL_PROMPT": "0",
    })
    return env


def sub(text, pattern, replacement):
    new, n = re.subn(pattern, replacement, text, count=1, flags=re.M)
    if n != 1:
        raise AssertionError(f"fixture pattern {pattern!r} not found")
    return new


class SourcePinsTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="source-pins-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.env = git_env(self.tmp)
        self.tree = self.tmp / "tree"
        for rel in ("tests/source-pins.sh", "scripts/fsdk-pin.sh", PINS, JUNCTION, OCI):
            dest = self.tree / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / rel, dest)

        self.gutenprint = self.tmp / "gutenprint"
        self.gutenprint_ref = self.commit(self.gutenprint, "README", "gutenprint\n")
        self.git(self.gutenprint, "tag", "-a", "-m", "release", TAG)
        # A later commit, so the tag is not simply the branch tip.
        self.commit(self.gutenprint, "README", "later\n")

        self.fsdk_containers = self.tmp / "fsdk-containers"
        self.junction_ref = self.fsdk_commit(f"freedesktop-sdk-{FSDK_VERSION}-0-g{FSDK_REF}")
        self.commit(self.fsdk_containers, "later", "later\n")

        self.set_pins(VERSION, TAG, self.gutenprint_ref)
        self.set_junction_ref(self.junction_ref)
        self.set_labels(FSDK_VERSION, FSDK_REF)

    def git(self, repo, *args):
        return subprocess.run(["git", "-C", str(repo), *args], env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, repo, name, content):
        if not repo.exists():
            repo.mkdir(parents=True)
            self.git(repo, "init", "-q")
        path = repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        self.git(repo, "add", "-A")
        self.git(repo, "commit", "-q", "-m", name)
        return self.git(repo, "rev-parse", "HEAD")

    def fsdk_commit(self, ref_line_value):
        content = ("kind: junction\nsources:\n- kind: git_repo\n"
                   "  url: gitlab:freedesktop-sdk/freedesktop-sdk.git\n"
                   f"  ref: {ref_line_value}\n")
        return self.commit(self.fsdk_containers, "elements/freedesktop-sdk.bst", content)

    def edit(self, rel, pattern, replacement):
        path = self.tree / rel
        path.write_text(sub(path.read_text(), pattern, replacement))

    def set_pins(self, version, tag, ref):
        self.edit(PINS, r'^  gutenprint-version: ".*"$', f'  gutenprint-version: "{version}"')
        self.edit(PINS, r'^  gutenprint-tag: ".*"$', f'  gutenprint-tag: "{tag}"')
        self.edit(PINS, r'^  gutenprint-ref: ".*"$', f'  gutenprint-ref: "{ref}"')

    def set_junction_ref(self, ref):
        self.edit(JUNCTION, r"^  ref: .*$", f"  ref: {ref}")

    def set_labels(self, version, ref):
        self.edit(OCI, r"^( *)'io\.projectbluefin\.fsdk\.version': '.*'$",
                  rf"\1'io.projectbluefin.fsdk.version': '{version}'")
        self.edit(OCI, r"^( *)'io\.projectbluefin\.fsdk\.ref': '.*'$",
                  rf"\1'io.projectbluefin.fsdk.ref': '{ref}'")

    def run_gate(self):
        env = dict(self.env,
                   GUTENPRINT_REMOTE=str(self.gutenprint),
                   FSDK_CONTAINERS_REMOTE=str(self.fsdk_containers))
        return subprocess.run(["bash", str(self.tree / "tests/source-pins.sh")], env=env,
                              cwd=self.tmp, capture_output=True, text=True, timeout=60)

    def assertPasses(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("OK: "), result.stdout)
        return result.stdout

    def assertRejected(self, message=None):
        result = self.run_gate()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("OK:", result.stdout)
        if message is not None:
            self.assertIn(message, result.stderr)
        return result.stderr


class PassPathTests(SourcePinsTestCase):
    def test_agreeing_pins_pass_and_report_every_pin(self):
        out = self.assertPasses()
        self.assertIn(f"Gutenprint {VERSION} = {TAG}@{self.gutenprint_ref[:12]}", out)
        self.assertIn(f"FSDK {FSDK_VERSION}@{FSDK_REF[:12]}", out)
        self.assertIn(f"via fsdk-containers {self.junction_ref[:12]}", out)

    def test_version_without_rebuild_suffix_passes(self):
        self.set_pins("5.3.6-4", TAG, self.gutenprint_ref)
        self.assertPasses()

    def test_two_component_fsdk_version_passes(self):
        ref = self.fsdk_commit(f"freedesktop-sdk-26.08-12-g{FSDK_REF}")
        self.set_junction_ref(ref)
        self.set_labels("26.08", FSDK_REF)
        self.assertPasses()


class GutenprintPinTests(SourcePinsTestCase):
    def test_missing_pin_is_rejected(self):
        self.edit(PINS, r'^  gutenprint-tag: ".*"\n', "")
        self.assertRejected("must define gutenprint-version, gutenprint-tag and gutenprint-ref")

    def test_version_without_debian_revision_is_rejected(self):
        self.set_pins("5.3.6", TAG, self.gutenprint_ref)
        self.assertRejected("is not <upstream>-<debian revision>[.N]")

    def test_tag_outside_debian_namespace_is_rejected(self):
        self.set_pins(VERSION, "v5.3.6-4", self.gutenprint_ref)
        self.assertRejected("is not a debian/<upstream>-<snapshot>-<revision> tag")

    def test_version_revision_disagreeing_with_tag_is_rejected(self):
        self.set_pins("5.3.6-3", TAG, self.gutenprint_ref)
        self.assertRejected("does not match gutenprint-tag")

    def test_version_upstream_disagreeing_with_tag_is_rejected(self):
        self.set_pins("5.3.7-4", TAG, self.gutenprint_ref)
        self.assertRejected("does not match gutenprint-tag")

    def test_abbreviated_ref_is_rejected(self):
        self.set_pins(VERSION, TAG, self.gutenprint_ref[:12])
        self.assertRejected("is not a full commit")

    def test_tag_absent_from_remote_is_rejected(self):
        self.git(self.gutenprint, "tag", "-d", TAG)
        self.assertRejected(f"could not resolve {TAG}")

    def test_tag_naming_a_different_commit_is_rejected(self):
        self.set_pins(VERSION, TAG, OTHER_SHA)
        err = self.assertRejected(f"but gutenprint-ref pins {OTHER_SHA}")
        self.assertIn(f"is commit {self.gutenprint_ref}", err)

    def test_retagged_release_is_rejected(self):
        moved = self.commit(self.gutenprint, "README", "retagged\n")
        self.git(self.gutenprint, "tag", "-f", "-a", "-m", "retag", TAG, moved)
        self.assertRejected(f"is commit {moved}")


class FsdkPinTests(SourcePinsTestCase):
    def test_junction_without_full_commit_is_rejected(self):
        self.set_junction_ref(self.junction_ref[:12])
        self.assertRejected("does not pin a full fsdk-containers commit")

    def test_missing_fsdk_label_is_rejected(self):
        self.edit(OCI, r"^ *'io\.projectbluefin\.fsdk\.ref': '.*'\n", "")
        self.assertRejected("must label io.projectbluefin.fsdk.version and io.projectbluefin.fsdk.ref")

    def test_stale_fsdk_version_label_is_rejected(self):
        self.set_labels("26.08.0", FSDK_REF)
        self.assertRejected(f"builds on FSDK {FSDK_VERSION}")

    def test_stale_fsdk_ref_label_is_rejected(self):
        self.set_labels(FSDK_VERSION, OTHER_SHA)
        self.assertRejected(f"pins FSDK commit {FSDK_REF}")

    def test_junction_bump_without_label_update_is_rejected(self):
        newer = "fedcba9876543210fedcba9876543210fedcba98"
        self.set_junction_ref(self.fsdk_commit(f"freedesktop-sdk-26.08.2-0-g{newer}"))
        self.assertRejected("builds on FSDK 26.08.2")

    def test_junction_commit_absent_from_remote_is_rejected(self):
        self.set_junction_ref(OTHER_SHA)
        self.assertRejected()

    def test_malformed_freedesktop_sdk_ref_is_rejected(self):
        self.set_junction_ref(self.fsdk_commit(f"freedesktop-sdk-{FSDK_VERSION}"))
        self.assertRejected("is not freedesktop-sdk-<version>-<n>-g<commit>")


class FsdkPinScriptTests(SourcePinsTestCase):
    def fsdk_pin(self, *args):
        return subprocess.run(["bash", str(self.tree / "scripts/fsdk-pin.sh"), *args],
                              env=self.env, capture_output=True, text=True, timeout=60)

    def test_prints_version_and_commit(self):
        result = self.fsdk_pin(self.junction_ref, str(self.fsdk_containers))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"{FSDK_VERSION} {FSDK_REF}\n")

    def test_usage_errors_exit_2(self):
        for args in ([], [self.junction_ref, "a", "b"], [self.junction_ref[:12]],
                     [self.junction_ref.upper()]):
            with self.subTest(args=args):
                result = self.fsdk_pin(*args)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("usage:", result.stderr)
                self.assertEqual(result.stdout, "")

    def test_abbreviated_fsdk_commit_in_ref_is_rejected(self):
        ref = self.fsdk_commit(f"freedesktop-sdk-{FSDK_VERSION}-0-g{FSDK_REF[:12]}")
        result = self.fsdk_pin(ref, str(self.fsdk_containers))
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
