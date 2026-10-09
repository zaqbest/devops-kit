#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  docker-image-export.sh [options] <image[:tag|@digest]>

Pull a Docker Hub image for one or more architectures and export each one as
a gzip-compressed Docker archive under ./images. The local image is removed
after export.
The default architectures are amd64 and arm64.

Options:
  -a, --arch <arch>       Target architecture; repeat or use comma-separated values
                          (default: amd64,arm64)
  -h, --help              Show this help

Examples:
  docker-image-export.sh nginx:1.27
  docker-image-export.sh --arch arm64 nginx:1.27
  docker-image-export.sh --arch amd64,arm64 nginx:1.27
EOF
}

ARCHES=("amd64" "arm64")
IMAGE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--arch)
            [[ $# -ge 2 ]] || { echo "[ERROR] --arch requires a value." >&2; exit 1; }
            if [[ "${ARCHES[*]}" == "amd64 arm64" ]]; then
                ARCHES=()
            fi
            IFS=',' read -r -a REQUESTED_ARCHES <<< "$2"
            ARCHES+=("${REQUESTED_ARCHES[@]}")
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

[[ ${#ARCHES[@]} -gt 0 ]] || { echo "[ERROR] At least one architecture is required." >&2; exit 1; }

for ARCH in "${ARCHES[@]}"; do
    if [[ ! "$ARCH" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        echo "[ERROR] Invalid architecture: $ARCH" >&2
        exit 1
    fi
done

command -v docker >/dev/null 2>&1 || { echo "[ERROR] docker command not found." >&2; exit 1; }
command -v gzip >/dev/null 2>&1 || { echo "[ERROR] gzip command not found." >&2; exit 1; }

SAFE_IMAGE="${IMAGE//\//@}"
SAFE_IMAGE="${SAFE_IMAGE//\//_}"
SAFE_IMAGE="${SAFE_IMAGE//:/_}"
OUTPUT_DIR="./images"
mkdir -p "$OUTPUT_DIR"

for ARCH in "${ARCHES[@]}"; do
    ARCH_OUTPUT="${OUTPUT_DIR}/${SAFE_IMAGE}-${ARCH}.tar.gz"

    if [[ -e "$ARCH_OUTPUT" ]]; then
        echo "[ERROR] Output file already exists: $ARCH_OUTPUT" >&2
        exit 1
    fi

    echo "[INFO] Pulling ${IMAGE} for linux/${ARCH}..."
    docker pull --platform "linux/${ARCH}" "$IMAGE"

    echo "[INFO] Saving image to ${ARCH_OUTPUT}..."
    if ! docker save "$IMAGE" | gzip -c > "$ARCH_OUTPUT"; then
        rm -f "$ARCH_OUTPUT"
        docker image rm "$IMAGE" >/dev/null 2>&1 || true
        echo "[ERROR] Failed to export image for ${ARCH}." >&2
        exit 1
    fi

    echo "[DONE] Image archive created: $ARCH_OUTPUT"
    echo "[INFO] Removing local image ${IMAGE}..."
    docker image rm "$IMAGE" >/dev/null 2>&1 || {
        echo "[WARN] Failed to remove local image: $IMAGE" >&2
    }
done