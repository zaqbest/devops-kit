#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  docker-image-export.sh [options] <image[:tag|@digest]>

Pull a Docker Hub image for a specific architecture and export it as a gzip
compressed Docker archive. The default architecture is amd64.

Options:
  -a, --arch <arch>       Target architecture (default: amd64)
  -o, --output <file>     Output archive (default: ./<image>-<arch>.tar.gz)
  -h, --help              Show this help

Examples:
  docker-image-export.sh nginx:1.27
  docker-image-export.sh --arch arm64 --output ./nginx-arm64.tar.gz nginx:1.27
EOF
}

ARCH="amd64"
OUTPUT=""
IMAGE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--arch)
            [[ $# -ge 2 ]] || { echo "[ERROR] --arch requires a value." >&2; exit 1; }
            ARCH="$2"
            shift 2
            ;;
        -o|--output)
            [[ $# -ge 2 ]] || { echo "[ERROR] --output requires a value." >&2; exit 1; }
            OUTPUT="$2"
            shift 2
            ;;
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
            [[ -z "$IMAGE" ]] || { echo "[ERROR] Only one image may be specified." >&2; exit 1; }
            IMAGE="$1"
            shift
            ;;
    esac
done

if [[ -z "$IMAGE" ]]; then
    echo "[ERROR] Image is required." >&2
    usage >&2
    exit 1
fi

if [[ ! "$ARCH" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "[ERROR] Invalid architecture: $ARCH" >&2
    exit 1
fi

command -v docker >/dev/null 2>&1 || { echo "[ERROR] docker command not found." >&2; exit 1; }
command -v gzip >/dev/null 2>&1 || { echo "[ERROR] gzip command not found." >&2; exit 1; }

if [[ -z "$OUTPUT" ]]; then
    SAFE_IMAGE="${IMAGE//\//@}"
    SAFE_IMAGE="${SAFE_IMAGE//\//_}"
    SAFE_IMAGE="${SAFE_IMAGE//:/_}"
    OUTPUT="./${SAFE_IMAGE}-${ARCH}.tar.gz"
fi

if [[ -e "$OUTPUT" ]]; then
    echo "[ERROR] Output file already exists: $OUTPUT" >&2
    exit 1
fi

OUTPUT_DIR="$(dirname "$OUTPUT")"
mkdir -p "$OUTPUT_DIR"

echo "[INFO] Pulling ${IMAGE} for linux/${ARCH}..."
docker pull --platform "linux/${ARCH}" "$IMAGE"

echo "[INFO] Saving image to ${OUTPUT}..."
if ! docker save "$IMAGE" | gzip -c > "$OUTPUT"; then
    rm -f "$OUTPUT"
    echo "[ERROR] Failed to export image." >&2
    exit 1
fi

echo "[DONE] Image archive created: $OUTPUT"