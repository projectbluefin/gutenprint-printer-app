kind: junction
# The Ghostscript project owns the FSDK CUPS source and patch chain. Import its
# pinned junction rather than duplicating the CUPS, libcupsfilters or
# cups-filters patches here.
sources:
  - kind: git_repo
    url: github:projectbluefin/ghostscript-printer-app.git
    track: testing
    ref: v10.07.1-1-9-g6afc91ba87c3f20b131ee0722baed62200c18ee1

config:
  options:
    arch: "%{arch}"
