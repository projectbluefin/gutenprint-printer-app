#!/usr/bin/env bash
set -euo pipefail

# The "Seed printing base" step in every build/CI workflow downloads a
# pre-built printing-base bundle from projectbluefin/fsdk-containers and bakes
# it into the build cache before the signed, published image is built. That
# bundle is a signed supply-chain input, so its cosign check must name the one
# workflow that actually publishes it -- .github/workflows/printing-base.yml on
# refs/heads/main -- and nothing else.
#
# A former --certificate-identity-regexp (^...fsdk-containers/.github/workflows/)
# accepted a signature from any fsdk-containers workflow on any branch, so a
# branch push (no review, no merge) could bake a tampered bundle into the image.
# This runs in `just validate`, so a workflow that loosens the identity back to a
# pattern fails its pull request instead of reaching the merge queue.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

WORKFLOWS=.github/workflows
IDENTITY="https://github.com/projectbluefin/fsdk-containers/.github/workflows/printing-base.yml@refs/heads/main"
FILES=(
  "$WORKFLOWS/registry-actions.yml"
  "$WORKFLOWS/bst-cache.yml"
  "$WORKFLOWS/fsdk-ci.yml"
)

fail() { printf 'workflow-signing-identity: %s\n' "$*" >&2; exit 1; }

for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || fail "missing workflow $f"
  # Exact identity, single-quoted so no character is a wildcard.
  grep -qF -- "--certificate-identity '${IDENTITY}' \\" "$f" \
    || fail "$f does not pin cosign identity ${IDENTITY}"
done

# No over-broad pattern may survive anywhere: a future --certificate-identity-regexp
# would reopen the branch-push gap this test exists to close.
if grep -rnF -- "--certificate-identity-regexp" "$WORKFLOWS"; then
  fail "a --certificate-identity-regexp is still present under $WORKFLOWS"
fi

printf 'OK: printing base verified against %s in %d workflow(s)\n' \
  "$IDENTITY" "${#FILES[@]}"
