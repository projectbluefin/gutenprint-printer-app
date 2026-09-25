#!/usr/bin/env bash
#
# Image-backed verification that the built image ships a real, usable test page
# at the path the application prints from (issue #18).
#
# What this proves, inside a real image:
#   1. The exact file the application opens exists:
#      TESTPAGE_DIR/testpage.pdf, where TESTPAGE is "testpage.pdf"
#      (gutenprint-printer-app.c:45) and TESTPAGE_DIR defaults to
#      /usr/share/<SYSTEM_PACKAGE_NAME> (pappl-retrofit.c:4746).
#   2. It is a well-formed single-page PDF whose page geometry is the one this
#      project's PostScript source declares (testpage.ps:7,
#      "%%BoundingBox: 0 0 612 792"), not whatever default paper size the
#      build host happened to be configured with.
#   3. It is not a borrowed artefact: /usr/share/legacy-printer-app/testpage.pdf
#      - pappl-retrofit's own A4 legacy test page, which the recipes used to
#      rename into place - is absent from the image.
#   4. It really is consumable: the image's own Ghostscript interprets the PDF
#      and renders it through its CUPS raster device, which is the same
#      interpreter and device chain the application uses for PDF jobs
#      (gutenprint-printer-app.c PR_CONVERT_PDF_TO_RASTER), and the rendered
#      page is not blank.
#
# What this does NOT claim: nothing is printed. There is no printer and no
# paper here. PAPPL's print-test-page action is exercised end to end by the
# FSDK lane's tests/socket-print.sh where that graph lives; see docs/testpage.md.
#
# Usage: IMAGE=<image-ref> tests/testpage-payload.sh
set -euo pipefail

image="${IMAGE:-gutenprint-printer-app:build}"

if ! podman image exists "$image"; then
  printf 'FAIL: image %s is not loaded; build it first (see docs/testpage.md)\n' "$image" >&2
  exit 1
fi

printf 'Verifying the test page in %s (no printer involved)\n' "$image"

podman run --rm -i --entrypoint /usr/bin/bash "$image" -s <<'IN_IMAGE'
set -euo pipefail

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'OK: %s\n' "$*"; }

for tool in awk od stat grep sed head tail mktemp gs; do
  command -v "$tool" >/dev/null 2>&1 || fail "the image does not provide '$tool', needed to verify the test page"
done

pdf=/usr/share/gutenprint-printer-app/testpage.pdf
ps=/usr/share/gutenprint-printer-app/testpage.ps
legacy=/usr/share/legacy-printer-app/testpage.pdf

# --- 1. The file the application opens is there ---------------------------

test -s "$pdf" || fail "$pdf is missing or empty; PAPPL would log 'Test page ... not found'"
head -c 5 "$pdf" | grep -q '%PDF-' || fail "$pdf has no %PDF- header"
# A PDF's trailer sits at the end, but Ghostscript and the CUPS filter chain
# may append job metadata after it, so look through the final block rather
# than the final bytes.
tail -c 4096 "$pdf" | grep -a -q '%%EOF' || fail "$pdf has no %%EOF trailer"
ok "$pdf is a non-empty PDF document ($(stat -c %s "$pdf") bytes)"

# The binary must ask for that exact file name, otherwise the document above
# is never the one printed.
grep -a -F -q 'testpage.pdf' /usr/bin/gutenprint-printer-app \
  || fail "the application binary does not ask for testpage.pdf"
ok "the application binary asks for testpage.pdf"

# --- 2. Its geometry is the one the PostScript source declares ------------

test -s "$ps" || fail "$ps (the PostScript source of the test page) is missing"

declared_box="$(sed -n 's/^%%BoundingBox:[[:space:]]*//p' "$ps" | head -n 1)"
[[ "$declared_box" == "0 0 612 792" ]] \
  || fail "$ps declares '%%BoundingBox: ${declared_box:-<none>}', expected '0 0 612 792'"

declared_pages="$(sed -n 's/^%%Pages:[[:space:]]*//p' "$ps" | head -n 1)"
[[ "$declared_pages" == "1" ]] || fail "$ps declares '%%Pages: ${declared_pages:-<none>}', expected '1'"

# The test page must still be this project's page, not another project's.
grep -Fq 'Printed with the OpenPrinting Gutenprint Printer Application' "$ps" \
  || fail "$ps no longer carries this project's test-page text"
grep -Fq 'https://github.com/OpenPrinting/gutenprint-printer-app/issues' "$ps" \
  || fail "$ps no longer points at this project's issue tracker"

grep -a -q '/Type[[:space:]]*/Catalog' "$pdf" || fail "$pdf has no document catalog"
grep -a -q '/Type[[:space:]]*/Pages' "$pdf" || fail "$pdf has no page tree"

box="$(grep -a -o '/MediaBox[[:space:]]*\[[^]]*\]' "$pdf" | head -n 1)"
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
tr '\n' ' ' < "$pdf" > flat.txt
pages_dict="$(grep -a -o '/Type[[:space:]]*/Pages[^>]*>>' flat.txt | head -n 1)"
[[ -n "$pages_dict" ]] || fail "$pdf has no page tree dictionary"

count="$(grep -a -o '/Count[[:space:]]*[0-9]*' <<<"$pages_dict" | grep -a -o '[0-9]*' | head -n 1)"
[[ "$count" == "$declared_pages" ]] \
  || fail "$pdf has ${count:-<none>} page(s); $ps declares $declared_pages"
ok "$pdf is a single-page ${width}x${height}pt PDF, matching $ps"

# --- 3. The borrowed legacy test page must not be in the image ------------

if [[ -e "$legacy" ]]; then
  fail "$legacy (pappl-retrofit's own A4 test page) is shipped again; the app prints PDF, so its presence means the borrowed artefact is back"
fi
ok "$legacy is not shipped"

# --- 4. The image's own interpreter consumes and renders it ---------------

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"
cp "$pdf" page.pdf

# The source of truth for "not blank": render the image's own test page and a
# deliberately empty page through the same device chain and compare. A blank
# page compresses to almost nothing, so this needs no magic size threshold.
cat > blank.ps <<'BLANK_PS'
%!PS-Adobe-3.0
%%BoundingBox: 0 0 612 792
%%Pages: 1
showpage
BLANK_PS

set +e
gs -q -dSAFER -dBATCH -dNOPAUSE -dFIXEDMEDIA -sPAPERSIZE=letter -sDEVICE=cups \
  -sOutputFile=page.ras page.pdf > gs.out 2> gs.err
status=$?
set -e
if [[ "$status" -ne 0 ]]; then
  sed -n '1,20p' gs.err >&2
  fail "the image's Ghostscript exited $status interpreting $pdf"
fi
grep -qiE 'error|unrecoverable|not found' gs.err && { sed -n '1,20p' gs.err >&2; fail "Ghostscript reported an error rendering $pdf"; }
test -s page.ras || fail "rendering $pdf produced no raster"
head -c 4 page.ras | grep -qE '^RaS[0-9]' || fail "rendering $pdf produced no CUPS raster job"

gs -q -dSAFER -dBATCH -dNOPAUSE -dFIXEDMEDIA -sPAPERSIZE=letter -sDEVICE=cups \
  -sOutputFile=blank.ras blank.ps >/dev/null 2>&1

page_size="$(stat -c %s page.ras)"
blank_size="$(stat -c %s blank.ras)"
(( page_size > blank_size )) \
  || fail "the rendered test page ($page_size bytes) is no larger than a blank page ($blank_size bytes)"
ok "the image's Ghostscript rendered $pdf to a non-blank CUPS raster ($page_size bytes vs $blank_size for a blank page)"

printf 'OK: the shipped test page is this project'"'"'s own, valid, renderable PDF (no printer involved)\n'
IN_IMAGE
