kind: manual
description: Emit the packaged version from the single pinned Gutenprint source metadata.

build-depends:
  - ghostscript-fsdk.bst:freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

config:
  install-commands:
    - printf '%s\n' '%{gutenprint-version}' > '%{install-root}/VERSION'
    - printf '%s\n' '%{gutenprint-ref}' > '%{install-root}/GUTENPRINT_REF'
