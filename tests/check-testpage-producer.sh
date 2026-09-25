#!/usr/bin/env bash
#
# Static producer guard for the Gutenprint test page (issue #18).
#
# The application asks PAPPL to print the file
# TESTPAGE_DIR/testpage.pdf, where TESTPAGE is "testpage.pdf"
# (gutenprint-printer-app.c:45) and TESTPAGE_DIR defaults to
# /usr/share/<SYSTEM_PACKAGE_NAME> (pappl-retrofit.c:4746), i.e.
# /usr/share/gutenprint-printer-app. Nothing in the source tree produces that
# PDF: "make install" copies testpage.ps into the same directory
# (Makefile:88), and the packaging recipes used to borrow pappl-retrofit's
# own usr/share/legacy-printer-app/testpage.pdf through an "organize:" rename.
# That file is another project's test page - A4, pointing at the
# pappl-retrofit issue tracker - so the page a user actually prints was never
# this project's, and it differed from the PostScript source shipped beside
# it.
#
# This guard fails fast, with no build, if a recipe stops deriving the PDF
# from this project's own PostScript, if the expected path and file name drift
# away from what the application opens, or if the borrowed PDF is reintroduced.
#
# Usage: tests/check-testpage-producer.sh
set -euo pipefail

cd "$(dirname "$0")/.."

status=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  status=1
}

pass() {
  printf 'OK: %s\n' "$*"
}

part_block() { # $1=recipe $2=part name
  # Slice from the top-level "parts:" map first: rockcraft and snapcraft also
  # declare a service of the same name under "services:".
  awk '/^parts:/ { found = 1 } found' "$1" | awk -v part="$2" '
    $0 == "  " part ":" { inside = 1; next }
    inside && /^  [^ ]/ { exit }
    inside { print }
  '
}

# --- The source of truth: this project's own PostScript test page ----------

source_ps=testpage.ps
if [[ ! -s "$source_ps" ]]; then
  fail "$source_ps is missing or empty; the PDF test page has no source"
else
  head -n 1 "$source_ps" | grep -q '^%!PS-Adobe-' \
    || fail "$source_ps is not a PostScript document"
  pass "$source_ps is a non-empty PostScript document"
fi

# The page geometry the shipped PDF must reproduce. The recipes pin
# -sPAPERSIZE=letter to exactly this value, so the file cannot silently follow
# whatever default paper size the build host happens to be configured with.
declared_box="$(sed -n 's/^%%BoundingBox:[[:space:]]*//p' "$source_ps" | head -n 1)"
if [[ "$declared_box" != "0 0 612 792" ]]; then
  fail "$source_ps declares '%%BoundingBox: ${declared_box:-<none>}', expected '0 0 612 792' (US Letter)"
else
  pass "$source_ps declares US Letter geometry (%%BoundingBox: $declared_box)"
fi

declared_pages="$(sed -n 's/^%%Pages:[[:space:]]*//p' "$source_ps" | head -n 1)"
if [[ "$declared_pages" != "1" ]]; then
  fail "$source_ps declares '%%Pages: ${declared_pages:-<none>}', expected '1'"
else
  pass "$source_ps declares a single page"
fi

# The whole point of issue #18 is that this project's test page is the one
# that gets printed; keep the text that identifies it as ours, so the source
# cannot quietly regress to another project's wording.
for marker in \
  'Printed with the OpenPrinting Gutenprint Printer Application' \
  'https://github.com/OpenPrinting/gutenprint-printer-app/issues'; do
  if grep -Fq "$marker" "$source_ps"; then
    pass "$source_ps carries the project marker '$marker'"
  else
    fail "$source_ps no longer carries the project marker '$marker'"
  fi
done

# --- The path the application opens must stay the one we produce -----------

source_c=gutenprint-printer-app.c
if grep -q '^#define TESTPAGE "testpage.pdf"' "$source_c"; then
  pass "$source_c opens the test page as testpage.pdf"
else
  fail "$source_c no longer defines TESTPAGE as \"testpage.pdf\""
fi

if grep -q '^#define SYSTEM_PACKAGE_NAME "gutenprint-printer-app"' "$source_c"; then
  pass "$source_c resolves TESTPAGE_DIR to /usr/share/gutenprint-printer-app"
else
  fail "$source_c changed SYSTEM_PACKAGE_NAME; the test page directory moved"
fi

expected=/usr/share/gutenprint-printer-app/testpage.pdf

# shellcheck disable=SC2016 # the $(prefix)/$(resourcedir) text is literal Makefile syntax
grep -q '^resourcedir[[:space:]]*=[[:space:]]*\$(prefix)/share/gutenprint-printer-app$' Makefile \
  || fail "Makefile no longer installs into $(dirname "$expected")"
# shellcheck disable=SC2016
if grep -q 'cp testpage.ps \$(resourcedir)' Makefile; then
  pass "Makefile ships the PostScript source beside the PDF in $(dirname "$expected")"
else
  fail "Makefile no longer copies testpage.ps into \$(resourcedir)"
fi

# --- Both OCI recipes must generate the PDF from that source ---------------

for recipe in rockcraft.yaml snap/snapcraft.yaml; do
  [[ -f "$recipe" ]] || { fail "$recipe is missing"; continue; }

  block="$(part_block "$recipe" gutenprint-printer-app)"
  if [[ -z "$block" ]]; then
    fail "$recipe has no gutenprint-printer-app part"
    continue
  fi

  if grep -Fq 'gs -q -dSAFER -dBATCH -dNOPAUSE -dFIXEDMEDIA -sPAPERSIZE=letter' <<<"$block" &&
    grep -Fq -- '-sDEVICE=pdfwrite' <<<"$block" &&
    grep -Fq -- '-sOutputFile=testpage.pdf testpage.ps' <<<"$block"; then
    pass "$recipe converts testpage.ps to testpage.pdf with Ghostscript pdfwrite"
  else
    fail "$recipe no longer converts testpage.ps to testpage.pdf with Ghostscript pdfwrite"
  fi

  if grep -Fq 'sPAPERSIZE=letter' <<<"$block" && grep -Fq -- '-dFIXEDMEDIA' <<<"$block"; then
    pass "$recipe pins the converted page to the source's US Letter geometry"
  else
    fail "$recipe does not pin the converted page size; the PDF would follow the build host default"
  fi

  if grep -Fq "$expected" <<<"$block"; then
    pass "$recipe installs the PDF at $expected"
  else
    fail "$recipe no longer installs the PDF at $expected"
  fi

  if awk '
    $0 == "    build-packages:" { inside = 1; next }
    inside && /^    [^ ]/ { exit }
    inside && $0 == "      - ghostscript" { found = 1 }
    END { exit !found }
  ' <<<"$block"; then
    pass "$recipe declares the Ghostscript build dependency"
  else
    fail "$recipe no longer declares the ghostscript build package needed to convert the test page"
  fi

  if awk '
    $0 == "    prime:" { inside = 1; next }
    inside && /^    [^ ]/ { exit }
    inside && $0 == "      - usr/share/gutenprint-printer-app" { found = 1 }
    END { exit !found }
  ' <<<"$block"; then
    pass "$recipe primes the whole usr/share/gutenprint-printer-app resourcedir"
  else
    fail "$recipe no longer primes usr/share/gutenprint-printer-app"
  fi

  # Regression guard: never let the borrowed legacy-printer-app PDF back in.
  # pappl-retrofit's data/testpage.pdf is a different, A4-sized test page.
  legacy="$(part_block "$recipe" pappl-retrofit | sed -n '/^    organize:/,/^    [^ ]/p')"
  if [[ -n "$legacy" ]] && grep -q 'testpage' <<<"$legacy"; then
    fail "$recipe part \"pappl-retrofit\" organizes a borrowed testpage into the app resourcedir again"
  else
    pass "$recipe does not borrow pappl-retrofit's test page"
  fi
done

# --- The image test must at least parse ------------------------------------

# tests/testpage-payload.sh runs inside the image from a quoted heredoc, which
# the linter does not parse; a syntax error buried there would only surface
# after a full image build. Catch it here instead.
payload=tests/testpage-payload.sh
if [[ -f "$payload" ]]; then
  body="$(mktemp)"
  trap 'rm -f "$body"' EXIT
  sed -n "/<<'IN_IMAGE'/,/^IN_IMAGE\$/p" "$payload" | sed '1d;$d' > "$body"
  if [[ ! -s "$body" ]]; then
    fail "$payload no longer embeds its in-image script in an IN_IMAGE heredoc"
  elif bash -n "$body"; then
    pass "$payload embeds a syntactically valid in-image script"
  else
    fail "$payload embeds an in-image script that does not parse"
  fi
fi

# --- When the BuildStream graph lands, its element must keep the producer ---

element=elements/printer-app/runtime-files.bst
if [[ -f "$element" ]]; then
  if grep -q 'components/ghostscript.bst' "$element"; then
    pass "$element keeps the pinned Ghostscript build dependency"
  else
    fail "$element no longer declares a Ghostscript build dependency"
  fi

  if grep -q -- '-sDEVICE=pdfwrite' "$element" && grep -q 'testpage.ps' "$element"; then
    pass "$element still converts testpage.ps to a PDF"
  else
    fail "$element no longer converts testpage.ps with the pdfwrite device"
  fi

  if grep -Fq "$expected" "$element"; then
    pass "$element installs the PDF at $expected"
  else
    fail "$element no longer installs the PDF at $expected"
  fi

  # The image-backed lanes must exercise what they ship.
  if grep -qF "$expected" tests/appliance.sh 2>/dev/null; then
    pass "tests/appliance.sh asserts the shipped PDF exists"
  else
    fail "tests/appliance.sh no longer asserts the shipped test-page PDF"
  fi

  if grep -q 'action=print-test-page' tests/socket-print.sh 2>/dev/null; then
    pass "tests/socket-print.sh exercises PAPPL's real print-test-page action"
  else
    fail "tests/socket-print.sh no longer exercises PAPPL's print-test-page action"
  fi
else
  printf 'NOTE: %s is not on this branch (pending the FSDK migration); its producer is guarded once it lands.\n' "$element"
fi

if ((status != 0)); then
  printf '\nThe test-page production contract regressed; see docs/testpage.md\n' >&2
  exit 1
fi

printf 'OK: test page is generated from this project'"'"'s own PostScript for %s\n' "$expected"
