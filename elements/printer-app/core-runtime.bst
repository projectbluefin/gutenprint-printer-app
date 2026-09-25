kind: compose
description: Drop build tools while retaining shell, drivers, filters and PPD resources.

build-depends:
  - printer-app/core-stack.bst

config:
  exclude:
    - debug
    - devel
    - doc
    - static-blocklist
    - tests
    - vm-only
