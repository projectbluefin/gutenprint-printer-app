# The test page contract

Everything here is about one file: the PDF that PAPPL prints when a user
presses "Print Test Page", and where it comes from.

## What the application asks for

```
#define TESTPAGE "testpage.pdf"          gutenprint-printer-app.c:45
#define SYSTEM_PACKAGE_NAME "gutenprint-printer-app"
                                         gutenprint-printer-app.c:25
```

`TESTPAGE` is handed to pappl-retrofit as `testpage_data`, and the test-page
callback joins it with `testpage_dir` (pappl-retrofit.c:4521):

```c
snprintf(buffer, bufsize, "%s/%s", global_data->testpage_dir,
         (char *)(global_data->config->testpage_data));
```

`testpage_dir` comes from the `testpage-directory` option, then `TESTPAGE_DIR`,
and otherwise defaults to `/usr/share/<SYSTEM_PACKAGE_NAME>`
(pappl-retrofit.c:4740-4747). Nothing else in the tree sets it, so inside the
image the application opens:

```
/usr/share/gutenprint-printer-app/testpage.pdf
```

If that file is missing the callback does not fail loudly at startup; it logs
`Test page ... not found or not readable.` at the moment the user asks for a
test print (pappl-retrofit.c:4525-4530) and returns `NULL`. The user gets
nothing, and the queue reports the failure only then.

## Why the PDF has to be generated

The source tree ships the test page as PostScript, `testpage.ps`, and
`make install` copies it into the resource directory (Makefile:88):

```make
resourcedir = $(prefix)/share/gutenprint-printer-app
...
cp testpage.ps $(resourcedir)
```

The application prints the PDF, so something has to produce it.

The Rockcraft/Snap recipes this fork inherited borrowed one instead: their
`pappl-retrofit` part ran

```yaml
organize:
  usr/share/legacy-printer-app/testpage.pdf: usr/share/gutenprint-printer-app/testpage.pdf
```

pappl-retrofit does install such a file - `data/testpage.pdf` and
`data/testpage.ps` go into `$(datadir)/legacy-printer-app`
(pappl-retrofit `Makefile.am:197-203`) - but it is **another project's test
page**, and it is not this one:

| | repository `testpage.ps` | pappl-retrofit `data/testpage.pdf` |
| --- | --- | --- |
| page | `%%BoundingBox: 0 0 612 792` (US Letter) | A4, `/MediaBox [ 0 0 595.28 841.89 ]` |
| identifies itself | "Printed with the OpenPrinting Gutenprint Printer Application" | "your printer is not a PostScript printer" |
| bug reports go to | `.../gutenprint-printer-app/issues` | `.../pappl-retrofit/issues` |
| copyright | 2020-2021 | 2020 |

So pressing "Print Test Page" produced a page from a different project, at a
different paper size, pointing users at the wrong issue tracker - while the
project's own `testpage.ps` sat unread beside it. Editing `testpage.ps` had no
effect on what was printed.

## What the OCI image does

`elements/printer-app/runtime-files.bst` generates the PDF from this
project's own `testpage.ps` at build time, with the shared printing base's
Ghostscript `pdfwrite` device, and installs it where the application looks:

```yaml
gs -q -dSAFER -dBATCH -dNOPAUSE -dFIXEDMEDIA -sPAPERSIZE=letter \
  -sDEVICE=pdfwrite -sOutputFile=testpage.pdf testpage.ps
test -s testpage.pdf
install -D -m 0644 testpage.pdf \
  "%{install-root}/usr/share/gutenprint-printer-app/testpage.pdf"
```

The container entrypoint exports `TESTPAGE_DIR=/usr/share/gutenprint-printer-app`.
`elements/oci/gutenprint-printer-app.bst` removes
`/usr/share/legacy-printer-app`, pappl-retrofit's sample test page, from the
final layer, so the borrowed page cannot be printed by mistake.

`-dFIXEDMEDIA -sPAPERSIZE=letter` is not decoration. The source declares
`%%BoundingBox: 0 0 612 792` (testpage.ps:7) but never calls `setpagedevice` -
it sizes itself from the device's page (`clippath pathbbox`, testpage.ps:123).
Without the pin, the page follows the default paper size of the Ghostscript
that converts it. FSDK's Ghostscript defaults to A4, so the image shipped a
595x842pt page until the pin was added. The pin makes the shipped PDF match the
geometry its source declares.

## How it is verified

`just verify` runs `tests/testpage-payload.sh` against the real built image,
on native x86_64 and aarch64 in the merge queue. The appliance ships no grep,
sed or awk, so the script copies the files out and inspects them on the host,
and runs only the image's own Ghostscript inside it:

- `/usr/share/gutenprint-printer-app/testpage.pdf` exists, has a `%PDF-`
  header and an `%%EOF` trailer, and the application binary asks for that
  name;
- it is a single-page PDF whose `/MediaBox` is 612x792pt, matching the
  `%%BoundingBox` and `%%Pages` its own PostScript source declares, and that
  source still carries this project's text and issue tracker;
- `/usr/share/legacy-printer-app/testpage.pdf` is **absent**, so the borrowed
  artefact cannot come back unnoticed;
- the image's own Ghostscript interprets the PDF and renders it through its
  CUPS raster device, and the rendered page is compared against a blank page
  rendered through the same device, so "it rendered" cannot mean "it rendered
  nothing".

`tests/socket-print.sh`, also part of `just verify`, drives PAPPL's
print-test-page action end to end: the test page goes through the Gutenprint
raster filter and the CUPS socket backend into a byte-capturing sink.

### What is not verified here

No printer and no paper are involved. Physical paper output remains
unverified without hardware.
