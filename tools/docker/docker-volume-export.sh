#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  docker-volume-export.sh [options] <volume> [archive.tar.gz]

Export a Docker volume to a gzip-compressed tar archive. The archive is
created through a temporary container, so the script does not depend on the
Docker volume's host filesystem path.

If the archive path is omitted, <volume>-YYYYmmdd-HHMMSS.tar.gz is created in
the current directory. A timestamp is also added before .tar.gz in a supplied
archive path. Existing archive files are never overwritten.

Options:
  --exclude <directory>   Exclude a directory relative to the volume root (repeatable)
  -h, --help              Show this help

Examples:
  docker-volume-export.sh postgres-data
  docker-volume-export.sh --exclude cache --exclude logs/old postgres-data ./backup/postgres-data.tar.gz
EOF
}

VOLUME=""
ARCHIVE=""
EXCLUDES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --exclude)
            if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
                echo "[ERROR] --exclude requires a directory." >&2
                exit 1
            fi
            EXCLUDE="${2#./}"
            EXCLUDE="${EXCLUDE%/}"
            if [[ -z "$EXCLUDE" || "$EXCLUDE" == /* || "$EXCLUDE" == "." || "$EXCLUDE" == ".." || "$EXCLUDE" == ../* || "$EXCLUDE" == */../* || "$EXCLUDE" == */.. || "$EXCLUDE" == */./* || "$EXCLUDE" == */. ]]; then
                echo "[ERROR] Excluded directory must be relative to the volume root: $2" >&2
                exit 1
            fi
            EXCLUDES+=("--exclude=./${EXCLUDE}")
            shift 2
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
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
if [[ "$ARCHIVE" == *.tar.gz ]]; then
    ARCHIVE="${ARCHIVE%.tar.gz}-${TIMESTAMP}.tar.gz"
else
    echo "[ERROR] Archive path must end in .tar.gz: $ARCHIVE" >&2
    exit 1
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
    sh -c 'archive="$1"; shift; tar -C /volume "$@" -czf "/backup/$archive" .' \
    sh "$ARCHIVE_NAME" "${EXCLUDES[@]}"; then
    rm -f "$ARCHIVE"
    echo "[ERROR] Failed to export Docker volume: $VOLUME" >&2
    exit 1
fi

echo "[DONE] Docker volume archive created: $ARCHIVE"