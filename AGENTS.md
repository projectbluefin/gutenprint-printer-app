# AGENTS.md

Bluefin fork of [OpenPrinting/gutenprint-printer-app](https://github.com/OpenPrinting/gutenprint-printer-app):
a PAPPL printer application with the Gutenprint drivers, built with BuildStream
on the freedesktop SDK (via `projectbluefin/fsdk-containers`) and published as a
signed OCI image. Upstream application and Snap changes go to OpenPrinting;
only the OCI appliance is maintained here. See `README.md` and `tests/README.md`.

## Checks and CI

- **`validate`** (`.github/workflows/validate.yml`): runs `pre-commit run --all-files`
  (`.pre-commit-config.yaml`) on `pull_request` and `merge_group`: YAML/JSON/TOML
  hygiene, `actionlint`, and `no-floating-action-tags` (third-party actions must
  be pinned to a full SHA). Required in the `main` ruleset. Run it before every commit.
- **`fsdk-ci.yml`**: pull requests run `just validate` (host unit tests,
  `tests/source-pins.sh`, BuildStream graph); the merge queue builds the native
  x86_64 and aarch64 images and runs `just verify` (real socket print).
- **Scorecard** (`.github/workflows/scorecard.yml`): OpenSSF Scorecard.
- **`license-audit.yml`**: unit tests for `scripts/audit-oci-licenses.py`.

## Issues, pull requests and labels

Prow drives review and merge: `/` commands in comments set labels, reviewers and
approvals, and Prow merges through the merge queue on `lgtm` + `approved`
(approvers come from `OWNERS`, generated from `projectbluefin/.project`; never
edit it by hand). See [Prow commands](https://github.com/cncf/prow-github-actions/blob/v3.0.1/docs/commands.md)
and the org [label workflow](https://github.com/projectbluefin/common/blob/main/docs/skills/label-workflow.md).
Repository Prow overrides live in `.github/prow.yaml`. Hive manages contributor
work and its labels, including the `needs-human` agent opt-out; do not remove them.

## Branches and releases

Target `main` for development PRs. Renovate (`renovate.json`) owns every pin:
the Gutenprint source pin in `include/source-pins.yml`, the fsdk-containers
junction in `elements/fsdk-containers.bst` (merged automatically once the
required image checks pass) and Action digests. There is no promotion step and
no tag-driven release: `registry-actions.yml` builds, verifies and publishes,
moving the version and `:stable` tags and adding an immutable `sha-` tag (see
"FSDK OCI Printer Application" in `README.md`). It still triggers on, and only
publishes from, the deleted `testing` branch, so merges to `main` currently
publish nothing; retargeting it to `main` is tracked in #115.
