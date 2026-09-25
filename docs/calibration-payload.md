# Colour calibration payload

`gutenprint-printer-app` ships Gutenprint's colour-calibration utility and the
data that utility opens, so that an operator can calibrate a printer from
inside the image. This document records what is retained, where it comes from
upstream, how CI proves it is usable on a real image **without a printer**, and
which parts of Gutenprint's localization are intentionally *not* shipped.

Upstream reference: `salsa.debian.org/printing-team/gutenprint`, pinned by
`rockcraft.yaml`/`snap/snapcraft.yaml` at
`debian/5.3.4.20220624T01008808d602-4`. Line numbers below are from that ref.

## What is retained, and why it is where it is

| Path in the image | Source | Why it must be there |
| --- | --- | --- |
| `/usr/bin/cups-calibrate` | `bin_PROGRAMS = cups-calibrate` (`src/cups/Makefile.am:82`) | The calibration tool itself. |
| `/usr/share/cups/calibrate.ppm` | `CUPS_PKG = calibrate.ppm` (`src/cups/Makefile.am:150`) installed through `pkgdatadir = $(cups_conf_datadir)` (`:33`) | Pass #4 of the tool opens `CUPS_DATADIR "/calibrate.ppm"` (`src/cups/cups-calibrate.c:780`). CUPS is built with `--prefix=/usr`, so `CUPS_DATADIR` is `/usr/share/cups`; if the file is not primed the tool still runs and pass #4 silently produces nothing. |
| `/usr/share/locale/<lang>/gutenprint_<lang>.po` | `install-data-local` (`src/cups/Makefile.am:174,188-192`) copies `po/*.po` | The PPD generator reads them back at run time: `PACKAGE_LOCALE_DIR` (`src/cups/i18n.c:129`) with the path formula `"%s/%s/gutenprint_%s.po"` (`:137`). 27 catalogues ship in the pinned ref, including `de`, `fr`, `es`, `it`, `ja`, `zh_CN`, `pt`, `ru`. |
| `/usr/share/ppd/gutenprint.5.3` | `src/cups/gutenprint.c` (the CUPS driverd helper), mapped by both recipes' `organize:` | Dynamic PPD generation. `list` prints `"gutenprint.5.3://<driver>/expert"` (`:220`); `cat <uri>[/<lang>]` extracts the language from the second path segment (`:156`) and reloads the catalogue with `stp_i18n_load(language)` (`src/cups/genppd.c:1224`). |

Both packaging recipes prime these paths explicitly
(`rockcraft.yaml:487-495`, `snap/snapcraft.yaml:499-507`) and configure
Gutenprint with `--enable-nls`, `--enable-translated-cups-ppds`,
`--enable-simplified-cups-ppds` and `--disable-cups-ppds`
(`rockcraft.yaml:449-468`, `snap/snapcraft.yaml:470-478`).

`tests/check-calibration-retention.sh` guards exactly this contract, before any
build: if a prime entry or a configure flag is dropped, the image would still
build, every other check would still pass, and calibration would quietly lose
its scan target. The guard also fails if a future BuildStream/FSDK element
excludes the `locale` split domain (which would strip the catalogues' runtime
path) or if a composed OCI layer deletes any of these paths.

## How CI verifies it on a real image, without a printer

`tests/calibration-payload.sh` runs inside the built image
(`.github/workflows/calibration-ci.yml`) and asserts:

1. `/usr/bin/cups-calibrate` is executable and its shared-library closure
   resolves (`ldd` reports no `not found`).
2. The asset exists, is a valid binary PPM (`P6`, `576x192`, maxval 255), and
   the CUPS data path compiled into the binary is the path the image ships —
   read out of the binary itself with `grep -a -F`, not assumed.
3. 21 named catalogues plus at least 20 catalogues overall are present and
   carry `msgid` entries.
4. The shipped PPD generator consumes them: the untranslated PPD says
   `*LanguageVersion: English`; the *same* driver URI with `/de` appended is
   regenerated in German (`*StpLocale: "de"`, translated option names); and an
   unknown locale (`xx_YY`) falls back to untranslated output with no error.
5. A hardware-free invocation of `cups-calibrate` reaches pass #4 — the only
   pass that reads `calibrate.ppm` — and emits the shipped asset's pixel data,
   compared hex digit for hex digit (`src/cups/cups-calibrate.c:801,814`).

Nothing is printed: there is no printer, no paper, and the test says so.

### Why the invocation is intercepted rather than submitted

The image deliberately ships no CUPS client: passes are submitted by the tool
through `popen("lp -s ...")` (`src/cups/cups-calibrate.c:115`), and `lp` is not
in the image (the upstream snap does not ship it either — the application's own
print path goes through PAPPL, not the `lp` CLI). So the verification puts a
capturing `lp` earlier on `PATH`, feeds the tool's interactive prompts from a
fixed answer file, and inspects the PostScript stream the tool itself produced.
That is interception of genuine tool output, not a synthetic echo of expected
bytes: the comparison target is the asset the image actually contains, and the
whole stream — prolog, transforms, header and every pixel — must match.

## Intentional gaps, documented rather than silently dropped

**1. Prebuilt translated PPD trees are not shipped.** `--disable-cups-ppds`
sets `BUILD_CUPS_PPDS=no` (`configure.ac:327,332`), which leaves
`INSTALL_DATA_LOCAL_DEPS` empty (`src/cups/Makefile.am:160`), so
`install-data-local` skips the per-language PPD trees under CUPS' `modeldir`
(`:175-187`). Localization is instead produced on demand by the driver from the
`.po` catalogues, which is why step 4 of the test regenerates the German PPD
rather than looking for a prebuilt one. `--enable-translated-cups-ppds`
(`configure.ac:346`) is still passed because the catalogue install (`:188-193`)
is unconditional and independent of the legacy PPD trees.

Consequence worth knowing: `*LanguageVersion:` is the translated form of the
literal string `"English"` (`src/cups/genppd.c:313-316` tells translators to put
the English name of *their* language there), so `po/de.po` maps
`msgid "English"` to `msgstr "German"`. A German PPD saying
`*LanguageVersion: German` is correct upstream behaviour, not a mislabelled
catalogue.

**2. Missing locales fall back silently, by design.** `stp_i18n_load()` tries
`<locale>/gutenprint_<locale>.po`, retries with the two-letter prefix
(`de_DE.UTF-8` → `de`, `src/cups/i18n.c:141`), and returns `NULL` when neither
exists — the caller then emits untranslated English. Operators can point the
lookup elsewhere with the `STP_LOCALEDIR` environment variable
(`src/cups/i18n.c:96,128`). The test asserts this fallback is clean (no error,
no partial translation) rather than treating it as a failure.

**3. Upstream's `calibrate.ppm` is 20 bytes shorter than its own header
declares.** The file is 331,816 bytes: a 60-byte header followed by 331,756
payload bytes, while the header declares 576 × 192 × 3 = 331,776 payload bytes
(110,585 complete pixels plus 1 trailing byte). This is upstream's file, not a
packaging defect:

- Debian 5.3.3 orig tarball and the pinned 5.3.4 ref ship the byte-identical
  object (git blob `fc5bccc03a7128b2f8758d4890197c92153ebebb`, sha256
  `1db13cbbdb7ebab9f2af0795ce5d65b199130a0f9cd17fedaa9b8cba3d5c7323`).

Pass #4 reads `width * height` pixels without checking for EOF
(`src/cups/cups-calibrate.c:803-826`), so those final pixels are emitted as
wide `FFFFFFFF` groups: the last seven pixels of the *visual confirmation*
page (bottom-right of the final scanline) are stray. The numeric profile is unaffected — its values come from
the operator's measured pass #1-#3 entries, not from this preview image.

The test does not hide this: it derives the expected stream from the asset's
own bytes, asserts an exact match, and prints a `NOTE:` line reporting the
shortfall. It fails if the asset ever grows larger than the header declares, or
shrinks by a full scanline (1728 bytes) — i.e. if the file is damaged rather
than merely truncated upstream. If upstream ever ships a complete asset, the
same assertions hold with no `FFFFFFFF` tail and the note simply disappears.

## Reproducing the verification locally

```sh
# static contract, no build needed
bash tests/check-calibration-retention.sh

# real image (podman required; the rock takes a while to build)
sudo snap install rockcraft --classic
sudo rockcraft pack
sudo skopeo copy --insecure-policy oci-archive:gutenprint-printer-app_*.rock \
  docker-archive:/tmp/gutenprint.tar
podman load -i /tmp/gutenprint.tar
podman tag "$(podman images --format '{{.Repository}}:{{.Tag}}' \
  | grep gutenprint-printer-app | head -n1)" gutenprint-printer-app:build

IMAGE=gutenprint-printer-app:build bash tests/calibration-payload.sh
```

`.github/workflows/calibration-ci.yml` does exactly this, gated behind the
static guard so a recipe regression fails in seconds instead of after a full
rock build.
