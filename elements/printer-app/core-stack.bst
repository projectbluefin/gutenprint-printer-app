kind: stack
description: Gutenprint driver, source-built printer app and its runtime closure.

depends:
  - printer-app/application.bst
  - printer-app/gutenprint.bst
  - printer-app/runtime-files.bst
  - ghostscript-fsdk.bst:freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
  - ghostscript-fsdk.bst:freedesktop-sdk.bst:components/avahi.bst
  - ghostscript-fsdk.bst:freedesktop-sdk.bst:components/ca-certificates.bst
  - ghostscript-fsdk.bst:freedesktop-sdk.bst:components/catatonit.bst
  - ghostscript-fsdk.bst:freedesktop-sdk.bst:components/cups-daemon-only.bst
  - ghostscript-fsdk.bst:freedesktop-sdk.bst:components/cups-filters.bst
  - ghostscript-fsdk.bst:freedesktop-sdk.bst:components/dbus.bst
  - ghostscript-fsdk.bst:freedesktop-sdk.bst:components/ghostscript.bst
  - ghostscript-fsdk.bst:freedesktop-sdk.bst:components/libcupsfilters.bst
  - ghostscript-fsdk.bst:freedesktop-sdk.bst:components/libppd.bst
  - ghostscript-fsdk.bst:freedesktop-sdk.bst:components/mutool.bst
  - ghostscript-fsdk.bst:freedesktop-sdk.bst:components/tzdata.bst
