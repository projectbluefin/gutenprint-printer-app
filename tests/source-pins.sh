#!/usr/bin/env bash
set -euo pipefail

# Every dependency proposal must keep the immutable source refs, the version
# metadata and the image labels in agreement, whichever updater wrote it:
#  - renovate.json rewrites include/source-pins.yml (tag, dereferenced
#    commit and packaged version together);
#  - update-base.yml rewrites the fsdk-containers junction and the FSDK
#    labels in elements/oci/gutenprint-printer-app.bst together.
# This runs in `just validate`, so a proposal that breaks the agreement fails
# its pull request instead of reaching the merge queue's full image build.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

pins=include/source-pins.yml
junction=elements/fsdk-containers.bst
oci=elements/oci/gutenprint-printer-app.bst
GUTENPRINT_REMOTE="${GUTENPRINT_REMOTE:-https://salsa.debian.org/printing-team/gutenprint.git}"
FSDK_CONTAINERS_REMOTE="${FSDK_CONTAINERS_REMOTE:-https://github.com/projectbluefin/fsdk-containers.git}"

fail() { printf 'source-pins: %s\n' "$*" >&2; exit 1; }
pin() { sed -n "s/^  $1: \"\\([^\"]*\\)\"\$/\\1/p" "$pins"; }
label() { sed -n "s/^ *'$1': '\\([^']*\\)'\$/\\1/p" "$oci"; }
sha40='^[0-9a-f]{40}$'

version="$(pin gutenprint-version)"
gutenprint_tag="$(pin gutenprint-tag)"
gutenprint_ref="$(pin gutenprint-ref)"
[[ -n "$version" && -n "$gutenprint_tag" && -n "$gutenprint_ref" ]] \
  || fail "$pins must define gutenprint-version, gutenprint-tag and gutenprint-ref"

# An optional .N suffix marks an OCI-only rebuild of the same Debian revision
# (registry tags are immutable); the Debian revision itself comes from the tag.
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

# The FSDK labels come from the junctioned fsdk-containers commit, whose own
# freedesktop-sdk.bst junction names the FSDK release and commit it builds on.
junction_ref="$(sed -n -E 's/^ +ref: .*([0-9a-f]{40})$/\1/p' "$junction")"
[[ "$junction_ref" =~ $sha40 ]] || fail "$junction does not pin a full fsdk-containers commit"
fsdk_version_label="$(label io.projectbluefin.fsdk.version)"
fsdk_ref_label="$(label io.projectbluefin.fsdk.ref)"
[[ -n "$fsdk_version_label" && -n "$fsdk_ref_label" ]] \
  || fail "$oci must label io.projectbluefin.fsdk.version and io.projectbluefin.fsdk.ref"

fsdk_pin="$(scripts/fsdk-pin.sh "$junction_ref" "$FSDK_CONTAINERS_REMOTE")"
read -r fsdk_version fsdk_ref <<< "$fsdk_pin"
[[ "$fsdk_version_label" == "$fsdk_version" ]] \
  || fail "io.projectbluefin.fsdk.version is '$fsdk_version_label' but fsdk-containers ${junction_ref:0:12} builds on FSDK ${fsdk_version}"
[[ "$fsdk_ref_label" == "$fsdk_ref" ]] \
  || fail "io.projectbluefin.fsdk.ref is '$fsdk_ref_label' but fsdk-containers ${junction_ref:0:12} pins FSDK commit ${fsdk_ref}"

printf 'OK: Gutenprint %s = %s@%s; FSDK %s@%s via fsdk-containers %s\n' \
  "$version" "$gutenprint_tag" "${gutenprint_ref:0:12}" "$fsdk_version" "${fsdk_ref:0:12}" "${junction_ref:0:12}"
