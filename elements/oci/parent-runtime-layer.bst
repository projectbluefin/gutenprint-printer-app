kind: import
description: Staged OCI layout of the signed digest-pinned shared printing runtime layer.

sources:
  - kind: local
    path: files/runtime-layer/%{arch}

config:
  target: /
