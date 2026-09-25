#!/usr/bin/env bash
#
# Hardware-free verification that the built image retains the Gutenprint
# colour-calibration utility and the data it needs (issue #13).
#
# What this proves, against the real image:
#   1. /usr/bin/cups-calibrate is present, executable and its ELF runtime
#      closure resolves.
#   2. The CUPS data directory compiled into the utility
#      (CUPS_DATADIR "/calibrate.ppm", upstream cups-calibrate.c:780) resolves
#      to the /usr/share/cups/calibrate.ppm asset the image ships, and that
#      asset is a well-formed binary PPM.
#   3. The utility loads that asset at run time: an invocation that goes
#      through pass #4 - the only pass that reads calibrate.ppm - must emit the
#      shipped asset's own pixel data, pixel for pixel.
#   4. The translated Gutenprint catalogues are retained and consumed: upstream
#      installs po/*.po as /usr/share/locale/<lang>/gutenprint_<lang>.po
#      (src/cups/Makefile.am:189) and the PPD generator reads them back from
#      PACKAGE_LOCALE_DIR (/usr/share/locale, src/cups/i18n.c:128-137).
#
# The appliance ships no grep, sed or awk, so only the image's own programs
# (cups-calibrate, the PPD generator, ldd) run inside it; their output and the
# shipped files are inspected on the host.
#
# What this does NOT claim: nothing is printed. There is no printer and no
# paper in this test, and the appliance runs no CUPS scheduler for `lp` to
# submit to, so the calibration tool's job submission is intercepted and
# inspected rather than submitted to a queue. Print-to-socket-sink behaviour is verified separately.
# Calibration asset/rendering limitations that are real shipping behaviour are
# reported, not hidden - see docs/calibration-payload.md.
#
# Usage: IMAGE=<image-ref> tests/calibration-payload.sh
set -euo pipefail

image="${IMAGE:-ghcr.io/projectbluefin/gutenprint-printer-app:build}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'OK: %s\n' "$*"; }

podman image exists "$image" || fail "image $image is not loaded; build it first (just build)"

printf 'Verifying calibration payload in %s (no printer involved)\n' "$image"

calibrate=/usr/bin/cups-calibrate
asset=/usr/share/cups/calibrate.ppm
driver=/usr/share/ppd/gutenprint.5.3

work="$(mktemp -d)"
ctr="$(podman create "$image" /none)"
cleanup() {
  podman rm "$ctr" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
in_image() {
  local entrypoint="$1"
  shift
  podman run --rm -i --entrypoint "$entrypoint" "$image" "$@"
}

# --- 1. Utility present, executable, runtime closure resolves ---------------

in_image /usr/bin/bash -c "test -x $calibrate" || fail "$calibrate is missing or not executable"
deps="$(in_image /usr/bin/ldd "$calibrate" 2>&1)" || fail "ldd failed on $calibrate: $deps"
[[ "$deps" != *"not found"* ]] || fail "$calibrate has unresolved shared libraries: $deps"
ok "cups-calibrate is present and its shared library closure resolves"

# --- 2. Compiled-in CUPS data directory agrees with the retained asset ------

podman cp "$ctr:$calibrate" "$work/cups-calibrate"
grep -a -F -q "$asset" "$work/cups-calibrate" \
  || fail "$calibrate does not embed the CUPS data path $asset"
podman cp "$ctr:$asset" "$work/calibrate.ppm" 2>/dev/null || fail "$asset is missing"
test -s "$work/calibrate.ppm" || fail "$asset is empty"

read -r magic width height maxval header_bytes < <(
  od -An -tu1 -v -N 512 "$work/calibrate.ppm" | awk '
    { for (i = 1; i <= NF; i++) b[++n] = $i }
    END {
      i = 1; tok = 0
      while (tok < 4) {
        while (i <= n && (b[i] == 32 || b[i] == 9 || b[i] == 10 || b[i] == 13)) i++
        if (i > n) break
        if (b[i] == 35) { while (i <= n && b[i] != 10) i++; continue }
        s = ""
        while (i <= n && !(b[i] == 32 || b[i] == 9 || b[i] == 10 || b[i] == 13)) s = s sprintf("%c", b[i++])
        t[++tok] = s
      }
      if (tok != 4) { print "BAD 0 0 0 0"; exit }
      printf "%s %s %s %s %d\n", t[1], t[2], t[3], t[4], i
    }'
) || fail "could not parse a PPM header out of $asset"

[[ "$magic" == "P6" ]] || fail "$asset is not a binary PPM (magic '$magic')"
[[ "$maxval" == "255" ]] || fail "$asset declares maxval '$maxval', expected 255"
[[ "$width" =~ ^[0-9]+$ && "$height" =~ ^[0-9]+$ ]] || fail "$asset has non-numeric dimensions '$width'x'$height'"
(( width > 0 && height > 0 )) || fail "$asset has empty dimensions ${width}x${height}"

file_bytes="$(stat -c %s "$work/calibrate.ppm")"
payload_bytes=$(( file_bytes - header_bytes ))
declared_payload=$(( width * height * 3 ))
(( payload_bytes <= declared_payload )) \
  || fail "$asset holds $payload_bytes payload bytes, more than its header declares ($declared_payload)"
shortfall=$(( declared_payload - payload_bytes ))
(( shortfall < width * 3 )) \
  || fail "$asset is short by $shortfall bytes, at least a full ${width}-pixel scanline; the asset is damaged"

asset_hex="$(od -An -tx1 -v "$work/calibrate.ppm" | tr -d ' \n' | tr 'a-f' 'A-F')"
[[ "${#asset_hex}" -eq $(( file_bytes * 2 )) ]] || fail "could not hex-encode $asset"
pixels_hex="${asset_hex:$(( header_bytes * 2 ))}"

if (( shortfall == 0 )); then
  ok "calibrate.ppm is a valid P6 asset, ${width}x${height}, $payload_bytes payload bytes at $asset"
else
  ok "calibrate.ppm is a P6 asset, ${width}x${height}, $payload_bytes payload bytes at $asset"
  printf 'NOTE: the shipped asset is %d bytes short of the %d bytes its own header declares (%d complete pixels plus %d trailing bytes); upstream ships the same file, so pass #4 reads past EOF for the final pixels. See docs/calibration-payload.md.\n' \
    "$shortfall" "$declared_payload" "$(( payload_bytes / 3 ))" "$(( payload_bytes % 3 ))"
fi

# --- 3. Translated Gutenprint catalogues are retained ----------------------

locale_root=/usr/share/locale
# One line per catalogue: path, size, and whether it carries a msgid entry
# (bash builtins only: the image has no grep).
in_image /usr/bin/bash -s > "$work/catalogs" <<'IN_IMAGE'
shopt -s nullglob
for catalog in /usr/share/locale/*/gutenprint_*.po; do
  has_msgid=0
  while IFS= read -r line; do
    if [[ "$line" == 'msgid '* ]]; then
      has_msgid=1
      break
    fi
  done < "$catalog"
  printf '%s %s %s\n' "$catalog" "$(stat -c %s "$catalog")" "$has_msgid"
done
IN_IMAGE

core_langs=(ca da de el es 'fi' fr hu it ja nb nl pl pt ru sk sv tr uk vi zh_CN)
missing=()
for lang in "${core_langs[@]}"; do
  grep -q "^$locale_root/$lang/gutenprint_$lang.po [1-9]" "$work/catalogs" || missing+=("$lang")
done
if (( ${#missing[@]} > 0 )); then
  fail "translated Gutenprint catalogues missing for: ${missing[*]} (upstream installs usr/share/locale)"
fi

catalog_count="$(wc -l < "$work/catalogs")"
(( catalog_count >= 20 )) \
  || fail "only $catalog_count translated Gutenprint catalogues retained, expected at least 20"
while read -r catalog size has_msgid; do
  (( size > 0 )) || fail "$catalog is empty"
  (( has_msgid == 1 )) || fail "$catalog carries no msgid entries"
done < "$work/catalogs"
ok "$catalog_count translated Gutenprint catalogues retained under $locale_root"

# --- 4. The shipped PPD generator consumes those catalogues ----------------

in_image /usr/bin/bash -c "test -x $driver" || fail "$driver (Gutenprint PPD generator) is missing"
in_image "$driver" list > "$work/ppd-list" || fail "$driver list failed"
uri="$(head -n 1 "$work/ppd-list" | cut -d'"' -f2)"
[[ "$uri" =~ ^gutenprint\..*://.+/expert$ ]] || fail "unexpected PPD generator entry '$uri'"

c_ppd="$(in_image "$driver" cat "$uri")"
[[ "$c_ppd" == *"*LanguageVersion: English"* ]] \
  || fail "untranslated PPD has no '*LanguageVersion: English' line"
[[ "$c_ppd" == *"*StpLocale"* ]] || fail "untranslated PPD has no '*StpLocale' line"

de_ppd="$(in_image "$driver" cat "$uri/de")"
[[ "$de_ppd" == *"*LanguageVersion: German"* ]] \
  || fail "German PPD was not translated; $locale_root/de/gutenprint_de.po is not being consumed"
grep -qE 'StpLocale:[[:space:]]*"de"' <<<"$de_ppd" || fail "German PPD does not record its locale"

translated=""
for token in 'Druckqualität' 'Medienart' 'Seitengröße' 'Tintensatz' 'Auflösung' 'Helligkeit'; do
  if [[ "$de_ppd" == *"$token"* ]]; then
    translated="$token"
    break
  fi
done
[[ -n "$translated" ]] || fail "German PPD carries no translated Gutenprint option names"
ok "PPD generator consumes the retained catalogues (German PPD says '$translated')"

# A locale without a catalogue must fall back to untranslated output without
# error rather than failing or silently mangling the PPD; see
# docs/calibration-payload.md for the source-backed policy.
xx_ppd="$(in_image "$driver" cat "$uri/xx_YY")" \
  || fail "PPD generator failed for an unknown locale instead of falling back"
[[ "$xx_ppd" == *"*LanguageVersion: English"* ]] \
  || fail "unknown locale did not fall back to untranslated output"
[[ "$xx_ppd" != *"$translated"* ]] || fail "unknown locale produced translated output"
ok "unknown locale xx_YY falls back to untranslated output without error"

# --- 5. Hardware-free calibration invocation loads the asset ---------------

capture="$work/passes.ps"
set +e
in_image /usr/bin/bash -s > "$capture" 2> "$work/stderr" <<'IN_IMAGE'
set -euo pipefail
shim_dir="$(mktemp -d)"
# Job submission interceptor, ahead of the image's own lp on PATH. The
# appliance runs no CUPS scheduler and this test has no printer, so the
# calibration tool's PostScript stream is captured instead of submitted.
printf '%s\n' '#!/usr/bin/bash' 'cat >> "$CALIBRATION_CAPTURE"' > "$shim_dir/lp"
chmod 0755 "$shim_dir/lp"
# Answers for the tool's interactive prompts: no printer/resolution/media
# overrides, skip passes 1-3 ("n"), a hex digit for every measured calibration
# value, then ENTER to continue into pass #4 - the only pass that reads
# calibrate.ppm - and finally "n" to decline saving a profile.
printf '%s\n' '' '' '' n 5 5 5 n 5 n 5 5 5 '' n n > "$shim_dir/answers"
PATH="$shim_dir:$PATH" CALIBRATION_CAPTURE="$shim_dir/passes.ps" \
  timeout 300 /usr/bin/cups-calibrate < "$shim_dir/answers" > /dev/null
cat "$shim_dir/passes.ps"
IN_IMAGE
status=$?
set -e
if [[ "$status" -ne 0 ]]; then
  sed -n '1,40p' "$work/stderr" >&2
  fail "cups-calibrate exited $status"
fi
if grep -qE 'not found|cannot open|No such file|error while loading|Permission denied' "$work/stderr"; then
  sed -n '1,40p' "$work/stderr" >&2
  fail "cups-calibrate reported a missing library or asset"
fi
test -s "$capture" || fail "cups-calibrate emitted no calibration pass output"
grep -q 'false 3 colorimage' "$capture" || fail "captured pass output has no colorimage block"
grep -qx "${width} ${height} 8" "$capture" \
  || fail "captured pass output is not sized from ${width}x${height} calibrate.ppm"
grep -qx "\[${width} 0 0 ${height} 0 0\]" "$capture" \
  || fail "captured pass output has no ${width}x${height} image transform"

# pass #4 writes one pixel per "%02X%02X%02X"; it never checks for EOF, so
# pixels it reads past the end of a short asset come out as wide FFFFFFFF
# groups. Derive the exact expected stream from the shipped asset's own bytes
# so this holds whether upstream ships a short or a complete asset.
capture_hex="$(awk '
  /colorimage/ { payload = 1; next }
  payload && /^[0-9A-F]+$/ && length($0) >= 4 { printf "%s", $0; got = 1; next }
  payload && got { exit }
' "$capture")"

complete_pixels=$(( payload_bytes / 3 ))
remainder=$(( payload_bytes % 3 ))
remaining_pixels=$(( width * height - complete_pixels ))
expected_hex="${pixels_hex:0:$(( complete_pixels * 6 ))}"
if (( remainder > 0 && remaining_pixels > 0 )); then
  expected_hex+="${pixels_hex:$(( complete_pixels * 6 ))}"
  for ((i = remainder; i < 3; i++)); do expected_hex+="FFFFFFFF"; done
  remaining_pixels=$(( remaining_pixels - 1 ))
fi
for ((i = 0; i < remaining_pixels; i++)); do expected_hex+="FFFFFFFFFFFFFFFFFFFFFFFF"; done

[[ "$capture_hex" == "$expected_hex" ]] \
  || fail "captured pass output does not match the shipped asset (${#capture_hex} hex digits, expected ${#expected_hex})"
ok "hardware-free pass #4 loaded calibrate.ppm and emitted all $(( width * height )) pixels (${#capture_hex} hex digits)"

printf 'OK: Gutenprint calibration utility, data and catalogues verified in a real image (no printer involved)\n'
