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

Both OCI recipes used to borrow one instead: the `pappl-retrofit` part ran

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

## What the recipes do now

Both `rockcraft.yaml` and `snap/snapcraft.yaml` generate the PDF in the
`gutenprint-printer-app` part, from that part's own source, with the
Ghostscript `pdfwrite` device:

```yaml
gs -q -dSAFER -dBATCH -dNOPAUSE -dFIXEDMEDIA -sPAPERSIZE=letter \
  -sDEVICE=pdfwrite -sOutputFile=testpage.pdf testpage.ps
test -s testpage.pdf
install -D -m 0644 testpage.pdf \
  "$CRAFT_PART_INSTALL/usr/share/gutenprint-printer-app/testpage.pdf"
```

`ghostscript` is a `build-packages` entry of that part: a build-time converter
only. The image's own Ghostscript is deliberately built raster/PostScript-only
(`--with-drivers=cups,pwgraster,ps2write` in the `ghostscript` part) and is
never asked to write PDFs, so adding the `pdfwrite` device to the shipped
interpreter would grow the appliance for no runtime reason.

`-dFIXEDMEDIA -sPAPERSIZE=letter` is not decoration. The source declares
`%%BoundingBox: 0 0 612 792` (testpage.ps:7) but never calls `setpagedevice` -
it sizes itself from the device's page (`clippath pathbbox`, testpage.ps:123).
Without the pin, the page follows whatever default paper size the build host's
Ghostscript was configured with, which is how the borrowed A4 artefact arose
in the first place. The pin makes the shipped PDF match the geometry its
source declares.

## How it is verified

`tests/check-testpage-producer.sh` - static, no build, seconds:

- `testpage.ps` is a PostScript document, declares US Letter and one page, and
  still carries this project's own test-page text and issue URL;
- `gutenprint-printer-app.c` still opens `testpage.pdf` from a
  `gutenprint-printer-app` resource directory, and `Makefile` still ships the
  PostScript source beside it;
- both recipes still convert the source with `pdfwrite`, pin the page size,
  install to `/usr/share/gutenprint-printer-app/testpage.pdf`, declare the
  `ghostscript` build package and prime the resource directory;
- neither recipe reintroduces the borrowed `legacy-printer-app` test page;
- the in-image script of `tests/testpage-payload.sh` parses;
- when the BuildStream graph lands (`elements/printer-app/runtime-files.bst`),
  that element keeps its pinned `components/ghostscript.bst` build dependency,
  its `pdfwrite` conversion, its install path, and `tests/appliance.sh` /
  `tests/socket-print.sh` keep asserting and exercising the result.

`tests/testpage-payload.sh` + `.github/workflows/testpage-ci.yml` - inside a
real built image:

- `/usr/share/gutenprint-printer-app/testpage.pdf` exists, has a `%PDF-`
  header and an `%%EOF` trailer, and the application binary asks for that
  name;
- it is a single-page PDF whose `/MediaBox` is 612x792pt, matching the
  `%%BoundingBox` and `%%Pages` its own PostScript source declares;
- `/usr/share/legacy-printer-app/testpage.pdf` is **absent**, so the borrowed
  artefact cannot come back unnoticed;
- the image's own Ghostscript interprets the PDF and renders it through its
  CUPS raster device - the same interpreter and device chain the application
  uses for PDF jobs - and the rendered page is compared against a blank page
  rendered through the same device, so "it rendered" cannot mean "it rendered
  nothing".

### What is not verified here

No printer and no paper are involved, and this lane does not drive PAPPL's
print-test-page action end to end. That action is exercised for the FSDK lane
by `tests/socket-print.sh`, which prints the test page through the Gutenprint
raster filter to a real socket sink where that graph lives. Physical paper
output remains unverified without hardware.
