kind: manual
description: Install isolated OCI launcher and shared CUPS executable links.

sources:
  - kind: local
    path: files

  - kind: local
    path: testpage.ps
build-depends:
  - fsdk-containers.bst:freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
  - fsdk-containers.bst:printing/base.bst

config:
  build-commands:
    - gs -q -dSAFER -dBATCH -dNOPAUSE -sDEVICE=pdfwrite -sOutputFile=testpage.pdf testpage.ps
  install-commands:
    - install -D -m 0755 container-entrypoint.sh "%{install-root}/usr/libexec/gutenprint-printer-app/container-entrypoint"
    - install -D -m 0644 testpage.pdf "%{install-root}/usr/share/gutenprint-printer-app/testpage.pdf"
    - install -d "%{install-root}/usr/share/ppd" "%{install-root}/usr/lib/gutenprint-printer-app/backend" "%{install-root}/usr/lib/gutenprint-printer-app/filter"
    - ln -s /usr/lib/gutenprint-printer-app/driver/gutenprint.5.3 "%{install-root}/usr/share/ppd/gutenprint.5.3"
    - |
      for backend in /usr/lib/cups/backend/{snmp,dnssd,socket,ipp,ipps,lpd,usb}; do
        test -x "$backend"
        ln -s "$backend" "%{install-root}/usr/lib/gutenprint-printer-app/backend/${backend##*/}"
      done
      for filter in /usr/lib/cups/filter/*; do
        test -x "$filter" || continue
        ln -s "$filter" "%{install-root}/usr/lib/gutenprint-printer-app/filter/${filter##*/}"
      done
