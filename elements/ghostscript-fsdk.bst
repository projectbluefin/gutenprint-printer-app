kind: junction
# The Ghostscript project owns the FSDK CUPS source and patch chain. Import its
# pinned junction rather than duplicating the CUPS, libcupsfilters or
# cups-filters patches here.
sources:
  - kind: git_repo
    url: github:projectbluefin/ghostscript-printer-app.git
    track: testing
    ref: v10.07.1-1-5-gdaf785716b1531e89236e6c8a4c6f82737d11e40

config:
  options:
    arch: "%{arch}"
