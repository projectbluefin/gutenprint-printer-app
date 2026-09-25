kind: stack
description: Gutenprint driver, source-built printer app and its runtime closure.

depends:
  - printer-app/application.bst
  - printer-app/gutenprint.bst
  - printer-app/runtime-files.bst
  - fsdk-containers.bst:printing/base.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:components/ca-certificates.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:components/catatonit.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:components/dbus.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:components/tzdata.bst
