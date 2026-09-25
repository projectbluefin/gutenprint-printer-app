kind: manual
description: Build the Gutenprint Printer Application against the shared fsdk-containers printing base.

sources:
  - kind: local
    path: Makefile
  - kind: local
    path: gutenprint-printer-app.c
  - kind: local
    path: gutenprint-printer-app.1
  - kind: local
    path: gutenprint-printer-app.service
  - kind: local
    path: testpage.ps

build-depends:
  - fsdk-containers.bst:freedesktop-sdk.bst:public-stacks/buildsystem-autotools.bst

depends:
  - fsdk-containers.bst:printing/base.bst

config:
  build-commands:
    - make clean
    - make -j2 VERSION="%{gutenprint-version}" LDFLAGS="$LDFLAGS -ljpeg"
  install-commands:
    # Keep the application's filter and backend directories independent of
    # the shared FSDK CUPS owner.
    - make DESTDIR="%{install-root}" VERSION="%{gutenprint-version}" LDFLAGS="$LDFLAGS -ljpeg" cupsserverbin= unitdir= install
