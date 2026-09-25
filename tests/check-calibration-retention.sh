#!/usr/bin/env bash
#
# Static retention guard for the Gutenprint calibration payload (issue #13).
#
# The image ships the colour-calibration utility and its data only because the
# packaging recipes prime them explicitly. Upstream's recipe is the reference
# contract - snap/snapcraft.yaml primes usr/bin/cups-calibrate, usr/share/locale
# and usr/share/cups/calibrate.ppm - and rockcraft.yaml repeats it for the OCI
# image. If a prime entry or the NLS configure flags are dropped the image
# still builds, every other check still passes, and cups-calibrate silently
# loses the scan target it opens as CUPS_DATADIR "/calibrate.ppm"
# (upstream cups-calibrate.c:780). This guard fails fast, with no build.
#
# Usage: tests/check-calibration-retention.sh
set -euo pipefail

cd "$(dirname "$0")/.."

status=0

part_block() { # $1=recipe $2=part name
  awk -v part="$2" '
    $0 == "  " part ":" { inside = 1; next }
    inside && /^  [^ ]/ { exit }
    inside { print }
  ' "$1"
}

sub_block() { # $1=key, part block on stdin
  awk -v key="$1" '
    $0 == "    " key ":" { inside = 1; next }
    inside && /^    [^ ]/ { exit }
    inside { print }
  '
}

check_entries() { # $1=recipe $2=part $3=key $4..=required entries
  local recipe="$1" part="$2" key="$3"
  shift 3
  local block entry
  local -a missing=()

  [[ -f "$recipe" ]] || { printf 'FAIL: %s is missing\n' "$recipe" >&2; status=1; return; }

  block="$(part_block "$recipe" "$part" | sub_block "$key")"
  [[ -n "$block" ]] || { printf 'FAIL: %s part "%s" has no %s block\n' "$recipe" "$part" "$key" >&2; status=1; return; }

  for entry in "$@"; do
    grep -Fxq "      - $entry" <<<"$block" || missing+=("$entry")
  done

  if ((${#missing[@]} > 0)); then
    printf 'FAIL: %s part "%s" %s no longer carries: %s\n' "$recipe" "$part" "$key" "${missing[*]}" >&2
    status=1
  else
    printf 'OK: %s part "%s" %s carries %s\n' "$recipe" "$part" "$key" "$*"
  fi
}

# Both OCI recipes must prime the calibration utility, its data and the
# translated catalogue tree that the PPD generator reads at run time.
for recipe in rockcraft.yaml snap/snapcraft.yaml; do
  check_entries "$recipe" gutenprint prime \
    usr/bin/cups-calibrate \
    usr/share/cups/calibrate.ppm \
    usr/share/locale \
    'usr/sbin/*genppd*'

  check_entries "$recipe" gutenprint autotools-configure-parameters \
    --enable-nls \
    --enable-translated-cups-ppds \
    --enable-simplified-cups-ppds \
    --disable-cups-ppds
done

# The BuildStream graph is not on this branch yet; when it lands, its compose
# must keep the FSDK "locale" split domain, otherwise every generated PPD loses
# its translations even though the catalogues were built.
compose=elements/printer-app/core-runtime.bst
if [[ -f "$compose" ]]; then
  if awk '
    /^  exclude:/ { inside = 1; next }
    inside && /^  [^ ]/ { inside = 0 }
    inside && $0 == "    - locale" { found = 1 }
    END { exit !found }
  ' "$compose"; then
    printf 'FAIL: %s excludes the locale split domain; Gutenprint PPD translations need %s\n' \
      "$compose" '/usr/share/locale/<lang>/gutenprint_<lang>.po' >&2
    status=1
  else
    printf 'OK: %s retains the locale split domain\n' "$compose"
  fi
fi

element=elements/printer-app/gutenprint.bst
if [[ -f "$element" ]]; then
  for flag in --enable-nls --enable-translated-cups-ppds; do
    if grep -q -- "$flag" "$element"; then
      printf 'OK: %s configures %s\n' "$element" "$flag"
    else
      printf 'FAIL: %s no longer configures %s\n' "$element" "$flag" >&2
      status=1
    fi
  done
fi

# Nothing may scrub the calibration utility, its data or the catalogue tree out
# of the composed OCI layer.
for element in elements/oci/*.bst; do
  [[ -e "$element" ]] || continue
  if grep -qE 'rm[[:space:]]+-[rf]+[[:space:]].*(cups-calibrate|calibrate\.ppm|/usr/share/locale)' "$element"; then
    printf 'FAIL: %s deletes the calibration utility, its data or the locale tree\n' "$element" >&2
    status=1
  else
    printf 'OK: %s does not delete the calibration payload\n' "$element"
  fi
done

if ((status != 0)); then
  printf '\nThe calibration payload retention contract regressed; see docs/calibration-payload.md\n' >&2
  exit 1
fi

printf 'OK: calibration payload retention contract intact\n'
