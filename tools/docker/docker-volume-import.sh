#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  docker-volume-import.sh <volume> <archive.tar.gz|archive.tgz|archive.tar|->

Import a tar archive into a Docker volume. The volume is created when it does
not already exist. Existing files in the volume are preserved unless the
archive contains files with the same paths.

Use '-' to read a gzip-compressed archive from standard input.

Examples:
  docker-volume-import.sh postgres-data ./postgres-data.tar.gz
  cat ./postgres-data.tar.gz | docker-volume-import.sh postgres-data -
EOF
}

VOLUME=""
ARCHIVE=""

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
            if [[ -z "$VOLUME" ]]; then
                VOLUME="$1"
            elif [[ -z "$ARCHIVE" ]]; then
                ARCHIVE="$1"
            else
                echo "[ERROR] Only one volume and one archive may be specified." >&2
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$VOLUME" || -z "$ARCHIVE" ]]; then
    echo "[ERROR] Volume and archive are required." >&2
    usage >&2
    exit 1
fi

command -v docker >/dev/null 2>&1 || { echo "[ERROR] docker command not found." >&2; exit 1; }

if [[ "$ARCHIVE" != "-" ]]; then
    [[ -f "$ARCHIVE" ]] || { echo "[ERROR] Archive not found: $ARCHIVE" >&2; exit 1; }
    ARCHIVE="$(cd "$(dirname "$ARCHIVE")" && pwd)/$(basename "$ARCHIVE")"
    case "$ARCHIVE" in
        *.tar.gz|*.tgz|*.tar) ;;
        *)
            echo "[ERROR] Unsupported archive format. Expected .tar, .tar.gz, .tgz, or -." >&2
            exit 1
            ;;
    esac
fi

if ! docker volume inspect "$VOLUME" >/dev/null 2>&1; then
    echo "[INFO] Creating Docker volume: $VOLUME"
    docker volume create "$VOLUME" >/dev/null
fi

echo "[INFO] Importing archive into Docker volume ${VOLUME}..."
if [[ "$ARCHIVE" == "-" ]]; then
    docker run --rm -i \
        -v "${VOLUME}:/volume" \
        alpine:3.20 \
        sh -c 'cat > /tmp/volume-archive && tar -xzf /tmp/volume-archive -C /volume && rm -f /tmp/volume-archive'
else
    ARCHIVE_DIR="$(dirname "$ARCHIVE")"
    ARCHIVE_NAME="$(basename "$ARCHIVE")"
    case "$ARCHIVE" in
        *.tar.gz|*.tgz)
            docker run --rm \
                -v "${VOLUME}:/volume" \
                -v "${ARCHIVE_DIR}:/backup:ro" \
                alpine:3.20 \
                tar -xzf "/backup/${ARCHIVE_NAME}" -C /volume
            ;;
        *.tar)
            docker run --rm \
                -v "${VOLUME}:/volume" \
                -v "${ARCHIVE_DIR}:/backup:ro" \
                alpine:3.20 \
                tar -xf "/backup/${ARCHIVE_NAME}" -C /volume
            ;;
    esac
fi

echo "[DONE] Docker volume imported: $VOLUME"