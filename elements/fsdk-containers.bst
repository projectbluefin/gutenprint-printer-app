kind: junction
# fsdk-containers owns the one shared printing base (printing/base.bst): the
# patched FSDK CUPS, cups-filters, libcupsfilters, libppd, ghostscript,
# mutool, avahi-printing, PAPPL and pappl-retrofit. Reach FSDK only through
# fsdk-containers.bst:freedesktop-sdk.bst:... and add no patches, overrides
# or options here; see fsdk-containers docs/skills/printing-base.md.
sources:
- kind: git_repo
  url: github:projectbluefin/fsdk-containers.git
  track: main
  ref: 961edf80eaeba39cf33f0db1a7f7b20c58ced640

config:
  options:
    arch: '%{arch}'
