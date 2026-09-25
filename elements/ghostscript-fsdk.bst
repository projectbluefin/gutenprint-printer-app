kind: junction
# The Ghostscript project owns the FSDK CUPS source and patch chain. Import its
# pinned junction rather than duplicating the CUPS, libcupsfilters or
# cups-filters patches here.
sources:
  - kind: git_repo
    url: github:projectbluefin/ghostscript-printer-app.git
    track: testing
    ref: v10.07.1-1-10-gd2ce02dc8965a66df2716266d14e155b1fb02b75

config:
  options:
    arch: "%{arch}"
