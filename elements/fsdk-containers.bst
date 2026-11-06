kind: junction
# fsdk-containers owns the one shared printing base (printing/base.bst): the
# patched FSDK CUPS, cups-filters, libcupsfilters, libppd, ghostscript,
# mutool, avahi-printing, PAPPL and pappl-retrofit. Reach FSDK only through
# fsdk-containers.bst:freedesktop-sdk.bst:...; see fsdk-containers
# docs/skills/printing-base.md.
sources:
- kind: git_repo
  url: github:projectbluefin/fsdk-containers.git
  track: main
  ref: d8204407efe0f5eba877dd7a9d6daa05c4632b5d
# Cross-junction includes expand in the subproject's variable scope. Expose
# the shared recipe there until its upstream include is cross-junction safe.
- kind: patch
  path: patches/fsdk-slim-printing-variables.patch

config:
  options:
    arch: '%{arch}'
