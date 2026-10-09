#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  docker-image-import.sh <archive.tar.gz|archive.tgz|archive.tar|->

Import a Docker image archive into the local Docker daemon. Use '-' to read
the archive from standard input.

Examples:
  docker-image-import.sh ./nginx-amd64.tar.gz
  docker-image-import.sh ./nginx.tar
  cat ./nginx.tar.gz | docker-image-import.sh -
EOF
}

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
            [[ -z "$ARCHIVE" ]] || { echo "[ERROR] Only one archive may be specified." >&2; exit 1; }
            ARCHIVE="$1"
            shift
            ;;
    esac
done

if [[ -z "$ARCHIVE" ]]; then
    echo "[ERROR] Archive is required." >&2
    usage >&2
    exit 1
fi

command -v docker >/dev/null 2>&1 || { echo "[ERROR] docker command not found." >&2; exit 1; }

if [[ "$ARCHIVE" == "-" ]]; then
    command -v gzip >/dev/null 2>&1 || { echo "[ERROR] gzip command not found." >&2; exit 1; }
    echo "[INFO] Loading Docker archive from standard input..."
    gzip -dc | docker load
elif [[ "$ARCHIVE" == *.tar.gz || "$ARCHIVE" == *.tgz ]]; then
    [[ -f "$ARCHIVE" ]] || { echo "[ERROR] Archive not found: $ARCHIVE" >&2; exit 1; }
    command -v gzip >/dev/null 2>&1 || { echo "[ERROR] gzip command not found." >&2; exit 1; }
    echo "[INFO] Loading compressed Docker archive: $ARCHIVE"
    gzip -dc -- "$ARCHIVE" | docker load
elif [[ "$ARCHIVE" == *.tar ]]; then
    [[ -f "$ARCHIVE" ]] || { echo "[ERROR] Archive not found: $ARCHIVE" >&2; exit 1; }
    echo "[INFO] Loading Docker archive: $ARCHIVE"
    docker load --input "$ARCHIVE"
else
    echo "[ERROR] Unsupported archive format. Expected .tar, .tar.gz, .tgz, or -." >&2
    exit 1
fi

echo "[DONE] Docker archive imported."