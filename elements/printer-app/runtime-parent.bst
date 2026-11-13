kind: import

# The signed shared printing runtime layer, staged by
# scripts/fetch-runtime-parent.sh (`just prepare-parent`) as an OCI layout.
sources:
  - kind: local
    path: runtime-parent
