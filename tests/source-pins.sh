#!/usr/bin/env bash
set -euo pipefail

# Every dependency proposal must keep the immutable source refs and the
# version metadata in agreement:
#  - renovate.json rewrites include/source-pins.yml (tag, dereferenced
#    commit and packaged version together);
#  - renovate.json bumps the fsdk-containers junction ref, whose FSDK release
#    registry-actions.yml derives (scripts/fsdk-pin.sh) to label the image.
# This runs in `just validate`, so a proposal that breaks the agreement fails
# its pull request instead of reaching the merge queue's full image build.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

pins=include/source-pins.yml
junction=elements/fsdk-containers.bst
GUTENPRINT_REMOTE="${GUTENPRINT_REMOTE:-https://salsa.debian.org/printing-team/gutenprint.git}"
FSDK_CONTAINERS_REMOTE="${FSDK_CONTAINERS_REMOTE:-https://github.com/projectbluefin/fsdk-containers.git}"

fail() { printf 'source-pins: %s\n' "$*" >&2; exit 1; }
pin() { sed -n "s/^  $1: \"\\([^\"]*\\)\"\$/\\1/p" "$pins"; }
sha40='^[0-9a-f]{40}$'

version="$(pin gutenprint-version)"
gutenprint_tag="$(pin gutenprint-tag)"
gutenprint_ref="$(pin gutenprint-ref)"
[[ -n "$version" && -n "$gutenprint_tag" && -n "$gutenprint_ref" ]] \
  || fail "$pins must define gutenprint-version, gutenprint-tag and gutenprint-ref"

# An optional .N suffix marks an OCI-only rebuild of the same Debian revision
# (Renovate drops it on the next revision); the Debian revision itself comes
# from the tag.
[[ "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+-[0-9]+)(\.[0-9]+)?$ ]] \
  || fail "gutenprint-version '$version' is not <upstream>-<debian revision>[.N]"
debian_version="${BASH_REMATCH[1]}"
[[ "$gutenprint_tag" =~ ^debian/([0-9]+\.[0-9]+\.[0-9]+)-.*-([0-9]+)$ ]] \
  || fail "gutenprint-tag '$gutenprint_tag' is not a debian/<upstream>-<snapshot>-<revision> tag"
tag_version="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
[[ "$debian_version" == "$tag_version" ]] \
  || fail "gutenprint-version '$version' does not match gutenprint-tag '$gutenprint_tag' ($tag_version)"
[[ "$gutenprint_ref" =~ $sha40 ]] || fail "gutenprint-ref '$gutenprint_ref' is not a full commit"

# The tag must dereference to the pinned commit: Renovate replaces both, and a
# hand edit of either one would otherwise build a source the tag never named.
tag_commit="$(git ls-remote "$GUTENPRINT_REMOTE" "refs/tags/${gutenprint_tag}^{}" | cut -f1)"
[[ "$tag_commit" =~ $sha40 ]] || fail "could not resolve ${gutenprint_tag} at ${GUTENPRINT_REMOTE}"
[[ "$tag_commit" == "$gutenprint_ref" ]] \
  || fail "${gutenprint_tag} is commit ${tag_commit}, but gutenprint-ref pins ${gutenprint_ref}"

# The junctioned fsdk-containers commit must name the FSDK release it builds
# on, or publishing could not label the image with it.
junction_ref="$(sed -n -E 's/^ +ref: .*([0-9a-f]{40})$/\1/p' "$junction")"
[[ "$junction_ref" =~ $sha40 ]] || fail "$junction does not pin a full fsdk-containers commit"
# Assign first: a failure inside a here-string's $(...) would not stop set -e.
fsdk_pin="$(scripts/fsdk-pin.sh "$junction_ref" "$FSDK_CONTAINERS_REMOTE")"
read -r fsdk_version fsdk_ref <<< "$fsdk_pin"

printf 'OK: Gutenprint %s = %s@%s; FSDK %s@%s via fsdk-containers %s\n' \
  "$version" "$gutenprint_tag" "${gutenprint_ref:0:12}" "$fsdk_version" "${fsdk_ref:0:12}" "${junction_ref:0:12}"
