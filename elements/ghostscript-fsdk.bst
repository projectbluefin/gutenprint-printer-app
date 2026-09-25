kind: junction
# The Ghostscript project owns the FSDK CUPS source and patch chain. Import its
# pinned junction rather than duplicating the CUPS, libcupsfilters or
# cups-filters patches here.
sources:
  - kind: git_repo
    url: github:projectbluefin/ghostscript-printer-app.git
    track: testing
    ref: v10.07.1-1-4-gf36174f27f5bb08421712bd77680cbddfc71862e

config:
  options:
    arch: "%{arch}"
