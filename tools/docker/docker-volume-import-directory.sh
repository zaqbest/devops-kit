#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  docker-volume-import-directory.sh <directory> <volume>

Copy the contents of a local directory into a Docker volume. The volume is
created when it does not already exist. Existing files in the volume are
preserved unless the source directory contains files with the same paths.

The directory itself is not copied as an extra top-level directory; its
contents are copied into the root of the volume.

Examples:
  docker-volume-import-directory.sh ./postgres-data postgres-data
  docker-volume-import-directory.sh /srv/uploads uploads
EOF
}

SOURCE_DIRECTORY=""
VOLUME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -* )
            echo "[ERROR] Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            if [[ -z "$SOURCE_DIRECTORY" ]]; then
                SOURCE_DIRECTORY="$1"
            elif [[ -z "$VOLUME" ]]; then
                VOLUME="$1"
            else
                echo "[ERROR] Only one source directory and one volume may be specified." >&2
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$SOURCE_DIRECTORY" || -z "$VOLUME" ]]; then
    echo "[ERROR] Source directory and volume are required." >&2
    usage >&2
    exit 1
fi

[[ -d "$SOURCE_DIRECTORY" ]] || {
    echo "[ERROR] Source directory not found: $SOURCE_DIRECTORY" >&2
    exit 1
}

command -v docker >/dev/null 2>&1 || { echo "[ERROR] docker command not found." >&2; exit 1; }

SOURCE_DIRECTORY="$(cd "$SOURCE_DIRECTORY" && pwd)"

if ! docker volume inspect "$VOLUME" >/dev/null 2>&1; then
    echo "[INFO] Creating Docker volume: $VOLUME"
    docker volume create "$VOLUME" >/dev/null
fi

echo "[INFO] Importing directory ${SOURCE_DIRECTORY} into Docker volume ${VOLUME}..."
docker run --rm \
    -v "${VOLUME}:/volume" \
    -v "${SOURCE_DIRECTORY}:/source:ro" \
    alpine:3.20 \
    sh -c 'cp -a /source/. /volume/'

echo "[DONE] Directory imported into Docker volume: $VOLUME"