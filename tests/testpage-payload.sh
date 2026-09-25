#!/usr/bin/env bash
#
# Image-backed verification that the built image ships a real, usable test page
# at the path the application prints from (issue #18).
#
# What this proves, against the real image:
#   1. The exact file the application opens exists:
#      TESTPAGE_DIR/testpage.pdf, where TESTPAGE is "testpage.pdf"
#      (gutenprint-printer-app.c:45) and TESTPAGE_DIR is
#      /usr/share/gutenprint-printer-app (the entrypoint exports it; it is also
#      pappl-retrofit's /usr/share/<SYSTEM_PACKAGE_NAME> default).
#   2. It is a well-formed single-page PDF whose page geometry is the one this
#      project's PostScript source declares (testpage.ps:7,
#      "%%BoundingBox: 0 0 612 792"), not whatever default paper size the
#      build's Ghostscript happened to be configured with.
#   3. It is not a borrowed artefact: /usr/share/legacy-printer-app/testpage.pdf
#      - pappl-retrofit's own A4 legacy test page - is absent from the image.
#   4. It really is consumable: the image's own Ghostscript interprets the PDF
#      and renders it through its CUPS raster device, and the rendered page is
#      not blank.
#
# The appliance ships no grep, sed or awk, so the files are copied out and
# inspected on the host; only the image's own Ghostscript runs inside it.
#
# What this does NOT claim: nothing is printed. There is no printer and no
# paper here. PAPPL's print-test-page action is exercised end to end by
# tests/socket-print.sh; see docs/testpage.md.
#
# Usage: IMAGE=<image-ref> tests/testpage-payload.sh
set -euo pipefail

image="${IMAGE:-ghcr.io/projectbluefin/gutenprint-printer-app:build}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'OK: %s\n' "$*"; }

podman image exists "$image" || fail "image $image is not loaded; build it first (just build)"

printf 'Verifying the test page in %s (no printer involved)\n' "$image"

pdf=/usr/share/gutenprint-printer-app/testpage.pdf
ps=/usr/share/gutenprint-printer-app/testpage.ps
legacy=/usr/share/legacy-printer-app/testpage.pdf

work="$(mktemp -d)"
ctr="$(podman create "$image" /none)"
cleanup() {
  podman rm "$ctr" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

podman cp "$ctr:$pdf" "$work/testpage.pdf" 2>/dev/null \
  || fail "$pdf is missing; PAPPL would log 'Test page ... not found'"
podman cp "$ctr:$ps" "$work/testpage.ps" 2>/dev/null \
  || fail "$ps (the PostScript source of the test page) is missing"
podman cp "$ctr:/usr/bin/gutenprint-printer-app" "$work/app"
cd "$work"

# --- 1. The file the application opens is there ---------------------------

test -s testpage.pdf || fail "$pdf is empty"
head -c 5 testpage.pdf | grep -q '%PDF-' || fail "$pdf has no %PDF- header"
# A PDF's trailer sits at the end, but writers may append data after it, so
# look through the final block rather than the final bytes.
tail -c 4096 testpage.pdf | grep -a -q '%%EOF' || fail "$pdf has no %%EOF trailer"
ok "$pdf is a non-empty PDF document ($(stat -c %s testpage.pdf) bytes)"

# The binary must ask for that exact file name, otherwise the document above
# is never the one printed.
grep -a -F -q 'testpage.pdf' app || fail "the application binary does not ask for testpage.pdf"
ok "the application binary asks for testpage.pdf"

# --- 2. Its geometry is the one the PostScript source declares ------------

declared_box="$(sed -n 's/^%%BoundingBox:[[:space:]]*//p' testpage.ps | head -n 1)"
[[ "$declared_box" == "0 0 612 792" ]] \
  || fail "$ps declares '%%BoundingBox: ${declared_box:-<none>}', expected '0 0 612 792'"

declared_pages="$(sed -n 's/^%%Pages:[[:space:]]*//p' testpage.ps | head -n 1)"
[[ "$declared_pages" == "1" ]] || fail "$ps declares '%%Pages: ${declared_pages:-<none>}', expected '1'"

# The test page must still be this project's page, not another project's.
grep -Fq 'Printed with the OpenPrinting Gutenprint Printer Application' testpage.ps \
  || fail "$ps no longer carries this project's test-page text"
grep -Fq 'https://github.com/OpenPrinting/gutenprint-printer-app/issues' testpage.ps \
  || fail "$ps no longer points at this project's issue tracker"

grep -a -q '/Type[[:space:]]*/Catalog' testpage.pdf || fail "$pdf has no document catalog"
grep -a -q '/Type[[:space:]]*/Pages' testpage.pdf || fail "$pdf has no page tree"

box="$(grep -a -o '/MediaBox[[:space:]]*\[[^]]*\]' testpage.pdf | head -n 1)"
[[ -n "$box" ]] || fail "$pdf declares no /MediaBox"
read -r width height < <(awk '
  {
    gsub(/[^0-9. -]/, "", $0)
    n = split($0, v, /[[:space:]]+/)
    got = 0
    for (i = 1; i <= n; i++) if (v[i] ~ /^-?[0-9]/) num[++got] = v[i]
    if (got >= 4) printf "%.0f %.0f\n", num[3] - num[1], num[4] - num[2]
  }' <<<"$box")
[[ -n "${width:-}" && -n "${height:-}" ]] || fail "could not read a rectangle out of '$box'"

(( width >= 611 && width <= 613 )) \
  || fail "$pdf is ${width}pt wide; the source declares 612pt (US Letter)"
(( height >= 791 && height <= 793 )) \
  || fail "$pdf is ${height}pt high; the source declares 792pt (US Letter)"

# The page tree dictionary can span lines, and grep is line-oriented, so
# flatten the document before pulling the dictionary out of it.
tr '\n' ' ' < testpage.pdf > flat.txt
pages_dict="$(grep -a -o '/Type[[:space:]]*/Pages[^>]*>>' flat.txt | head -n 1)"
[[ -n "$pages_dict" ]] || fail "$pdf has no page tree dictionary"

count="$(grep -a -o '/Count[[:space:]]*[0-9]*' <<<"$pages_dict" | grep -a -o '[0-9]*' | head -n 1)"
[[ "$count" == "$declared_pages" ]] \
  || fail "$pdf has ${count:-<none>} page(s); $ps declares $declared_pages"
ok "$pdf is a single-page ${width}x${height}pt PDF, matching $ps"

# --- 3. The borrowed legacy test page must not be in the image ------------

if podman cp "$ctr:$legacy" legacy.pdf 2>/dev/null; then
  fail "$legacy (pappl-retrofit's own A4 test page) is shipped again"
fi
ok "$legacy is not shipped"

# --- 4. The image's own interpreter consumes and renders it ---------------

# The source of truth for "not blank": render the image's own test page and a
# deliberately empty page through the same device chain and compare them. The
# cups device writes uncompressed raster, so both are the same size and only
# their pixels can tell them apart.
render() {
  podman run --rm -i --entrypoint /usr/bin/gs "$image" \
    -q -dSAFER -dBATCH -dNOPAUSE -dFIXEDMEDIA -sPAPERSIZE=letter -sDEVICE=cups \
    -sstdout=%stderr -sOutputFile=- "$@"
}

set +e
render "$pdf" > page.ras 2> gs.err
status=$?
set -e
if [[ "$status" -ne 0 ]]; then
  sed -n '1,20p' gs.err >&2
  fail "the image's Ghostscript exited $status interpreting $pdf"
fi
if grep -qiE 'error|unrecoverable|not found' gs.err; then
  sed -n '1,20p' gs.err >&2
  fail "Ghostscript reported an error rendering $pdf"
fi
test -s page.ras || fail "rendering $pdf produced no raster"
# The sync word is written in host byte order: "RaS3" or, little-endian, "3SaR".
head -c 4 page.ras | grep -qE '^(RaS[0-9]|[0-9]SaR)' || fail "rendering $pdf produced no CUPS raster job"

printf '%s\n' '%!PS-Adobe-3.0' '%%BoundingBox: 0 0 612 792' '%%Pages: 1' 'showpage' \
  | render - > blank.ras 2>/dev/null

[[ "$(stat -c %s page.ras)" -eq "$(stat -c %s blank.ras)" ]] \
  || fail "the test page and a blank page rendered to different raster geometry"
differing="$(cmp -l page.ras blank.ras | wc -l || true)"
(( differing > 0 )) || fail "the rendered test page is identical to a blank page"
ok "the image's Ghostscript rendered $pdf to a non-blank CUPS raster ($differing bytes differ from a blank page)"

printf 'OK: the shipped test page is this project'"'"'s own, valid, renderable PDF (no printer involved)\n'
