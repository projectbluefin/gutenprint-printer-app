# BuildStream runs inside the pinned freedesktop-sdk builder image. The tag
# names the source commit for readability, but a registry tag is mutable — the
# @sha256 digest is the immutable pin podman actually pulls by. When bumping
# the tag, refresh the digest too:
#   skopeo inspect --format '{{.Digest}}' docker://<image>:<tag>
bst2_image := env("BST2_IMAGE", "registry.gitlab.com/freedesktop-sdk/infrastructure/freedesktop-sdk-docker-images/bst2:64eb0b4930d57a92710822898fb73af6cc1ae35d@sha256:2ca3b449b594e9284bd60f436a4efad1365116b7d3d7129fd08b7a4f459d3561")
image_ref := "ghcr.io/projectbluefin/gutenprint-printer-app:build"

default:
    @just --list

bst *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    # BST_FLAGS adds global bst options; CI sets it to
    # `--config /src/ci/buildstream.conf`.
    mkdir -p "${HOME}/.cache/buildstream"
    podman run --rm \
        --privileged \
        --device /dev/fuse \
        --network=host \
        -v "{{ justfile_directory() }}:/src:rw" \
        -v "${HOME}/.cache/buildstream:/root/.cache/buildstream:rw" \
        -w /src \
        "{{ bst2_image }}" \
        bash -c 'bst "$@"' -- --no-interactive ${BST_FLAGS:-} {{ ARGS }}

validate:
    PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py'
    tests/source-pins.sh
    tests/entrypoint-validation.sh
    just bst show --deps all oci/gutenprint-printer-app.bst

fetch:
    #!/usr/bin/env bash
    set -euo pipefail
    for attempt in 1 2 3; do
        if just bst source fetch --ignore-project-source-remotes \
            --source-remote https://cache.projectbluefin.io:11001 \
            --deps all oci/gutenprint-printer-app.bst; then
            exit 0
        fi
        echo "source fetch failed (attempt ${attempt}/3)" >&2
        if [[ "$attempt" -lt 3 ]]; then sleep 15; fi
    done
    exit 1

build:
    just bst build oci/gutenprint-printer-app.bst
    just export

export:
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf .build-out
    just bst artifact checkout oci/gutenprint-printer-app.bst --directory /src/.build-out
    image_id="$(podman pull -q oci:.build-out)"
    rm -rf .build-out
    podman tag "$image_id" "{{ image_ref }}"

# Host-only: the entrypoint must reject malformed web-administration settings
# before it touches the image or persistent state.
verify-entrypoint-validation:
    tests/entrypoint-validation.sh

verify:
    tests/entrypoint-validation.sh
    just build
    tests/image-metadata.sh
    tests/no-devel.sh
    tests/locale-slim.sh
    tests/vendor-options-payload.sh
    tests/cups-owner.sh
    tests/calibration-payload.sh
    tests/appliance.sh
    tests/device-settings-web-admin.sh
    tests/socket-print.sh
    tests/coexistence.sh
    just check-no-remote-login-records
    tests/testpage-payload.sh
    python3 tests/device-selection.py -- podman run --rm --entrypoint /usr/bin/gutenprint-printer-app {{ image_ref }}

# Avahi's sample ssh/sftp-ssh records must not ship in an appliance that
# serves neither. Image-level, so `just verify` catches a reintroduction
# without host networking.
check-no-remote-login-records:
    #!/usr/bin/env bash
    set -euo pipefail
    podman run --rm --entrypoint /usr/bin/bash "{{ image_ref }}" -ec '
        test ! -e /etc/avahi/services/ssh.service
        test ! -e /etc/avahi/services/sftp-ssh.service
    '
    echo "OK: no SSH/SFTP service records in {{ image_ref }}"

# Requires host Avahi and avahi-browse on a quiet test LAN; not part of
# `just verify`. Observes real records before and after starting and
# restarting two instances with distinct names, ports and state volumes.
verify-service-advertisements:
    just build
    tests/service-advertisements.sh

sbom:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "${HOME}/.cache/buildstream"
    git_sha="$(git rev-parse HEAD)"
    podman run --rm \
        --privileged \
        --device /dev/fuse \
        --network=host \
        -v "{{ justfile_directory() }}:/src:rw" \
        -v "${HOME}/.cache/buildstream:/root/.cache/buildstream:rw" \
        -w /src \
        -e GIT_SHA="$git_sha" \
        "{{ bst2_image }}" \
        bash -c '
          pip install --quiet git+https://gitlab.com/BuildStream/buildstream-sbom.git@0706fec3bedf6f73bd9d2fed32c2aed585feef8d
          buildstream-sbom oci/gutenprint-printer-app.bst \
              --spdx-name gutenprint-printer-app \
              --spdx-namespace "https://github.com/projectbluefin/gutenprint-printer-app/sbom/${GIT_SHA}" \
              --spdx-creator "Tool: buildstream-sbom" \
              --spdx-creator "Organization: projectbluefin" \
              --deps all \
              --output /src/gutenprint-printer-app.spdx.json
        '
