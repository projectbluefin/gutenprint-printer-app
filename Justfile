# BuildStream runs inside the pinned freedesktop-sdk builder image.
bst2_image := env("BST2_IMAGE", "registry.gitlab.com/freedesktop-sdk/infrastructure/freedesktop-sdk-docker-images/bst2:64eb0b4930d57a92710822898fb73af6cc1ae35d")
image_ref := "ghcr.io/projectbluefin/gutenprint-printer-app:build"

default:
    @just --list

bst *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "${HOME}/.cache/buildstream"
    podman run --rm \
        --privileged \
        --device /dev/fuse \
        --network=host \
        -v "{{ justfile_directory() }}:/src:rw" \
        -v "${HOME}/.cache/buildstream:/root/.cache/buildstream:rw" \
        -w /src \
        "{{ bst2_image }}" \
        bash -c 'bst "$@"' -- --no-interactive {{ ARGS }}

validate:
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

verify:
    just build
    tests/cups-owner.sh
    tests/appliance.sh
    tests/socket-print.sh

sbom:
    #!/usr/bin/env bash
    set -euo pipefail
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
