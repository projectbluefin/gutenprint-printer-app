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
  ref: c02bd1714164b8f18437805f49acc9f8f84b507b

# The producer generates this gitignored include from its FSDK junction
# before invoking bst; junction consumers must stage the same value so the
# shared runtime layer's key (oci/printing-runtime-layer.bst) resolves here.
- kind: local
  path: junction-files/fsdk-containers/include
  directory: include

config:
  options:
    arch: '%{arch}'
