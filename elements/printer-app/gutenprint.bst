kind: manual
description: Build Gutenprint 5.3.6 CUPS raster driver, USB dye-sub backend and PPD generator.

sources:
  - kind: git_repo
    url: salsa:printing-team/gutenprint.git
    track: "%{gutenprint-tag}"
    ref: "%{gutenprint-ref}"

build-depends:
  - fsdk-containers.bst:freedesktop-sdk.bst:public-stacks/buildsystem-autotools.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:components/bison.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:components/flex.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:components/gettext.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:components/glib.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:components/python3.bst

depends:
  - fsdk-containers.bst:freedesktop-sdk.bst:components/cups.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:components/libusb.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:components/zlib.bst

config:
  configure-commands:
    - ./autogen.sh
    - |
      ./configure \
        --prefix=/usr \
        --libdir="%{libdir}" \
        --enable-shared \
        --disable-rpath \
        --with-modules=static \
        --without-gimp2 \
        --disable-libgutenprintui2 \
        --with-cups \
        --enable-cups-level3-ppds \
        --enable-translated-cups-ppds \
        --enable-simplified-cups-ppds \
        --enable-cups-1_2-enhancements \
        --disable-cups-ppds \
        --enable-escputil \
        --disable-samples \
        --disable-test \
        --disable-testpattern \
        --enable-nls \
        --without-doc
  build-commands:
    - make -j2
  install-commands:
    # Upstream creates backend/filter/driver in cups-config --serverbin by
    # default. Never write over the shared FSDK CUPS artifact's directories.
    - make DESTDIR="%{install-root}" cups_conf_serverbin=/usr/lib/gutenprint-printer-app install
    - mv "%{install-root}/usr/sbin/"* "%{install-root}/usr/bin/"
    - rmdir "%{install-root}/usr/sbin"
    - chmod 0755 "%{install-root}/usr/lib/gutenprint-printer-app/backend/gutenprint53+usb"
    - install -d "%{install-root}/usr/lib/gutenprint-printer-app/backend"
    - mv "%{install-root}/usr/share/cups/usb/net.sf.gimp-print.usb-quirks" "%{install-root}/usr/lib/gutenprint-printer-app/backend/"

public:
  bst:
    split-rules:
      # The default devel rule takes pkgconfig/*.pc but leaves the directory,
      # which would reach the runtime-only image as an empty pkgconfig dir.
      devel:
        (>):
          - '%{libdir}/pkgconfig'
