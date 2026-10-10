"""Execute promote-stable.yml's fast-forward gate against fixture repositories.

The promote job is the only thing that moves `stable`. Its "Fast-forward
stable only from verified testing HEAD" step must push only the exact commit
the verify job rebuilt, only while that commit is still the tip of the source
branch, and only as a fast-forward of `stable`. The step runs only on a manual
dispatch, so these tests lift its `run:` block out of the workflow verbatim and
execute it in throwaway git repositories: the gate is tested as written.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/promote-stable.yml"
STEP_NAME = "Fast-forward stable only from verified testing HEAD"
TOKEN = "ghs_promoteGateFixtureToken0123456789"
GIT_ENV = {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}


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
        if line.strip() and len(line) - len(line.lstrip()) <= step_indent:
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
    indent = min(len(l) - len(l.lstrip()) for l in body if l.strip())
    return "\n".join(l[indent:] for l in body) + "\n"


def git(cwd, *args):
    return subprocess.run(
        ["git", "-c", "user.name=test", "-c", "user.email=test@example.invalid",
         "-c", "commit.gpgsign=false", "-c", "init.templateDir=",
         "-c", "init.defaultBranch=scratch", *args],
        cwd=cwd, check=True, capture_output=True, text=True,
        env={**os.environ, **GIT_ENV},
    ).stdout.strip()


class PromoteStableGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = step_script(WORKFLOW, STEP_NAME)
        # Follow the workflow's own source branch so a branch rename keeps
        # these tests meaningful instead of silently testing the old name.
        match = re.search(r"^git fetch origin (\S+) stable$", cls.script, re.M)
        if match is None:
            raise ValueError("gate no longer fetches `<source> stable` from origin")
        cls.source = match.group(1)

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="promote-stable-gate."))
        self.addCleanup(shutil.rmtree, self.tmp)
        self.origin = self.tmp / "origin.git"
        self.seed = self.tmp / "seed"
        git(self.tmp, "init", "--quiet", "--bare", str(self.origin))
        git(self.tmp, "init", "--quiet", str(self.seed))
        git(self.seed, "remote", "add", "origin", str(self.origin))
        self.released = self.commit("released")
        git(self.seed, "push", "--quiet", "origin", "HEAD:refs/heads/stable",
            f"HEAD:refs/heads/{self.source}")
        self.candidate = self.commit("verified candidate")
        self.push_source()

    def commit(self, message):
        git(self.seed, "commit", "--quiet", "--allow-empty", "-m", message)
        return git(self.seed, "rev-parse", "HEAD")

    def push_source(self, rev="HEAD"):
        git(self.seed, "push", "--quiet", "--force", "origin",
            f"{rev}:refs/heads/{self.source}")

    def origin_ref(self, branch):
        return git(self.tmp, "--git-dir", str(self.origin), "rev-parse",
                   f"refs/heads/{branch}")

    def checkout(self, sha):
        """Mirror actions/checkout with `ref: <sha>` and `fetch-depth: 0`."""
        work = self.tmp / "work"
        if work.exists():
            shutil.rmtree(work)
        git(self.tmp, "clone", "--quiet", "--no-checkout", str(self.origin), str(work))
        git(work, "checkout", "--quiet", "--detach", sha)
        return work

    def run_gate(self, work, candidate):
        env = {"PATH": os.environ["PATH"], "HOME": str(self.tmp), **GIT_ENV,
               "CANDIDATE": candidate, "GH_TOKEN": TOKEN}
        return subprocess.run(["bash", "-c", self.script], cwd=work, env=env,
                              capture_output=True, text=True)

    def assert_promoted(self, result, sha):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.origin_ref("stable"), sha)

    def assert_refused(self, result, stable_before):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.origin_ref("stable"), stable_before,
                         "a refused promotion must leave stable where it was")

    def test_source_tip_fast_forwards_stable(self):
        work = self.checkout(self.candidate)
        self.assert_promoted(self.run_gate(work, self.candidate), self.candidate)
        self.assertEqual(self.origin_ref(self.source), self.candidate)

    def test_several_commits_fast_forward_in_one_push(self):
        self.commit("second")
        head = self.commit("third")
        self.push_source()
        work = self.checkout(head)
        self.assert_promoted(self.run_gate(work, head), head)

    def test_candidate_already_on_stable_is_a_no_op(self):
        git(self.seed, "push", "--quiet", "origin", f"{self.candidate}:refs/heads/stable")
        work = self.checkout(self.candidate)
        self.assert_promoted(self.run_gate(work, self.candidate), self.candidate)

    def test_candidate_must_be_a_full_lowercase_sha(self):
        work = self.checkout(self.candidate)
        for candidate in ("", self.candidate[:7], self.candidate[:39],
                          self.candidate + "0", self.candidate.upper(),
                          self.source, "HEAD", f" {self.candidate}",
                          f"{self.candidate}\n"):
            with self.subTest(candidate=candidate):
                self.assert_refused(self.run_gate(work, candidate), self.released)

    def test_checked_out_commit_must_be_the_candidate(self):
        work = self.checkout(self.released)
        self.assert_refused(self.run_gate(work, self.candidate), self.released)

    def test_source_advanced_after_checkout_is_refused(self):
        # A commit landed during the verify job: the gate must re-fetch rather
        # than trust the clone's stale tracking ref, which still matches.
        work = self.checkout(self.candidate)
        self.commit("landed during verification")
        self.push_source()
        self.assertEqual(git(work, "rev-parse", f"origin/{self.source}"), self.candidate)
        self.assert_refused(self.run_gate(work, self.candidate), self.released)

    def test_source_rewound_past_candidate_is_refused(self):
        work = self.checkout(self.candidate)
        self.push_source(self.released)
        self.assert_refused(self.run_gate(work, self.candidate), self.released)

    def test_older_source_commit_is_refused(self):
        work = self.checkout(self.released)
        self.assert_refused(self.run_gate(work, self.released), self.released)

    def test_commit_never_on_source_is_refused(self):
        git(self.seed, "checkout", "--quiet", "--detach", self.released)
        stray = self.commit("never reached the source branch")
        git(self.seed, "push", "--quiet", "origin", f"{stray}:refs/heads/scratch")
        work = self.checkout(stray)
        self.assert_refused(self.run_gate(work, stray), self.released)

    def test_diverged_stable_is_never_rewritten(self):
        git(self.seed, "checkout", "--quiet", "--detach", self.released)
        hotfix = self.commit("hotfix pushed straight to stable")
        git(self.seed, "push", "--quiet", "origin", f"{hotfix}:refs/heads/stable")
        work = self.checkout(self.candidate)
        self.assert_refused(self.run_gate(work, self.candidate), hotfix)

    def test_token_is_never_printed_or_persisted(self):
        work = self.checkout(self.candidate)
        result = self.run_gate(work, self.candidate)
        self.assert_promoted(result, self.candidate)
        self.assertNotIn(TOKEN, result.stdout + result.stderr)
        config = (work / ".git/config").read_text()
        self.assertNotIn("extraheader", config)
        self.assertNotIn(TOKEN, config)


if __name__ == "__main__":
    unittest.main()
