#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/project/scripts" "$tmp/project/runtime-parent" "$tmp/bin"
cp "$root/scripts/fetch-runtime-parent.sh" "$tmp/project/scripts/"
printf 'old\n' > "$tmp/project/runtime-parent/old"
export LOG="$tmp/log"
export PATH="$tmp/bin:$PATH"
cat > "$tmp/bin/uname" <<'EOF'
#!/bin/sh
echo x86_64
EOF
cat > "$tmp/bin/just" <<'EOF'
#!/bin/sh
printf '%064d\n' 1
EOF
cat > "$tmp/bin/skopeo" <<'EOF'
#!/bin/bash
printf 'skopeo %s\n' "$*" >> "$LOG"
if [[ "$1" == inspect ]]; then
  printf 'sha256:%064d\n' 2
else
  mkdir -p "${4#oci:}"
fi
EOF
cat > "$tmp/bin/cosign" <<'EOF'
#!/bin/sh
printf 'cosign %s\n' "$*" >> "$LOG"
[ "${FAIL_VERIFY:-0}" = 0 ]
EOF
chmod +x "$tmp/bin/"*
repo=ghcr.io/projectbluefin/printing-runtime-layer
digest="sha256:$(printf '%064d' 2)"
export FAIL_VERIFY=1
if bash "$tmp/project/scripts/fetch-runtime-parent.sh"; then
  echo 'unverified parent accepted' >&2; exit 1
fi
[[ -f "$tmp/project/runtime-parent/old" ]]
! grep -q '^skopeo copy ' "$LOG"
export FAIL_VERIFY=0
bash "$tmp/project/scripts/fetch-runtime-parent.sh"
[[ ! -e "$tmp/project/runtime-parent/old" ]]
grep -F -- "--certificate-identity https://github.com/projectbluefin/fsdk-containers/.github/workflows/printing-runtime-layer.yml@refs/heads/main" "$LOG" >/dev/null
grep -F -- "skopeo copy --preserve-digests docker://${repo}@${digest} " "$LOG" >/dev/null
