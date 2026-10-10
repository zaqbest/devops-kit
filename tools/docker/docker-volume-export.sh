#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  docker-volume-export.sh [options] <volume> [archive.tar.gz]

Export a Docker volume to a gzip-compressed tar archive. The archive is
created through a temporary container, so the script does not depend on the
Docker volume's host filesystem path.

If the archive path is omitted, <volume>.tar.gz is created in the current
directory. Existing archive files are never overwritten.

Options:
  -h, --help              Show this help

Examples:
  docker-volume-export.sh postgres-data
  docker-volume-export.sh postgres-data ./backup/postgres-data.tar.gz
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

if [[ -z "$VOLUME" ]]; then
    echo "[ERROR] Volume is required." >&2
    usage >&2
    exit 1
fi

if [[ -z "$ARCHIVE" ]]; then
    ARCHIVE="${VOLUME}.tar.gz"
fi

command -v docker >/dev/null 2>&1 || { echo "[ERROR] docker command not found." >&2; exit 1; }
command -v gzip >/dev/null 2>&1 || { echo "[ERROR] gzip command not found." >&2; exit 1; }

docker volume inspect "$VOLUME" >/dev/null 2>&1 || {
    echo "[ERROR] Docker volume not found: $VOLUME" >&2
    exit 1
}

if [[ -e "$ARCHIVE" ]]; then
    echo "[ERROR] Output file already exists: $ARCHIVE" >&2
    exit 1
fi

mkdir -p "$(dirname "$ARCHIVE")"
ARCHIVE_DIR="$(cd "$(dirname "$ARCHIVE")" && pwd)"
ARCHIVE_NAME="$(basename "$ARCHIVE")"

echo "[INFO] Exporting Docker volume ${VOLUME} to ${ARCHIVE}..."
if ! docker run --rm \
    -v "${VOLUME}:/volume:ro" \
    -v "${ARCHIVE_DIR}:/backup" \
    alpine:3.20 \
    sh -c 'tar -C /volume -czf "/backup/$1" .' \
    sh "$ARCHIVE_NAME"; then
    rm -f "$ARCHIVE"
    echo "[ERROR] Failed to export Docker volume: $VOLUME" >&2
    exit 1
fi

echo "[DONE] Docker volume archive created: $ARCHIVE"