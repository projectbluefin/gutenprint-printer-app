kind: junction
# The Ghostscript project owns the FSDK CUPS source and patch chain. Import its
# pinned junction rather than duplicating the CUPS, libcupsfilters or
# cups-filters patches here.
sources:
  - kind: git_repo
    url: github:projectbluefin/ghostscript-printer-app.git
    track: testing
    ref: v10.07.1-1-7-g1f6e00f45c05e756b86e291f5e751fbbeda752df

config:
  options:
    arch: "%{arch}"
