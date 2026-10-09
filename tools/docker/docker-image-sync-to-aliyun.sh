#!/usr/bin/env bash

set -euo pipefail

REGISTRY="registry.cn-hangzhou.aliyuncs.com"
ACR_NAMESPACE="${ACR_NAMESPACE:-zaqbest}"
ARCHES=("amd64" "arm64")
SOURCE_IMAGE=""
TARGET_IMAGE=""

usage() {
    cat <<'EOF'
Usage:
  docker-image-sync-to-aliyun.sh [options] <source-image> <target-image>

Pull an image from Docker Hub and push it to Alibaba Cloud Container Registry.
The default Alibaba Cloud namespace is zaqbest. It can be changed with:
  export ACR_NAMESPACE="your-aliyun-namespace"

The target image can be specified as repository[:tag], for example nginx:1.27.
You may also specify namespace/repository[:tag] explicitly.

Each architecture is first pushed with an architecture suffix, then a
multi-architecture manifest is created using the original target tag:
  registry.cn-hangzhou.aliyuncs.com/my-space/nginx:1.27-amd64
  registry.cn-hangzhou.aliyuncs.com/my-space/nginx:1.27-arm64
  registry.cn-hangzhou.aliyuncs.com/my-space/nginx:1.27

When the target tag is not latest, the same multi-architecture manifest is
also published as latest.

Set these environment variables to let this script log in automatically:
  export ACR_USERNAME="your-aliyun-username"
  export ACR_PASSWORD="your-aliyun-password"

If the variables are not configured, log in manually first:
  docker login
  docker login registry.cn-hangzhou.aliyuncs.com

Options:
  -a, --arch <arch>       Target architecture; repeat or use comma-separated values
                          (default: amd64,arm64)
  -h, --help              Show this help

Examples:
  docker-image-sync-to-aliyun.sh nginx:1.27 nginx:1.27
  docker-image-sync-to-aliyun.sh --arch arm64 nginx:1.27 nginx:1.27
  docker-image-sync-to-aliyun.sh --arch amd64,arm64 nginx:1.27 nginx:1.27
EOF
}

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
            if [[ -z "$SOURCE_IMAGE" ]]; then
                SOURCE_IMAGE="$1"
            elif [[ -z "$TARGET_IMAGE" ]]; then
                TARGET_IMAGE="$1"
            else
                echo "[ERROR] Only one source image and one target image may be specified." >&2
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$SOURCE_IMAGE" || -z "$TARGET_IMAGE" ]]; then
    echo "[ERROR] Source image and target image are required." >&2
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

if [[ "$TARGET_IMAGE" == */*/* ]]; then
    echo "[ERROR] Target image must be in the form <repository>[:tag] or <namespace>/<repository>[:tag]." >&2
    exit 1
fi

if [[ "$TARGET_IMAGE" == *@* ]]; then
    echo "[ERROR] Target image must use a tag, not a digest." >&2
    exit 1
fi

command -v docker >/dev/null 2>&1 || { echo "[ERROR] docker command not found." >&2; exit 1; }

if [[ "$TARGET_IMAGE" != */* ]]; then
    TARGET_IMAGE="${ACR_NAMESPACE}/${TARGET_IMAGE}"
fi

ACR_USERNAME="${ACR_USERNAME:-}"
ACR_PASSWORD="${ACR_PASSWORD:-}"
if [[ -n "$ACR_USERNAME" && -n "$ACR_PASSWORD" ]]; then
    echo "[INFO] Logging in to ${REGISTRY} as ${ACR_USERNAME}..."
    printf '%s' "$ACR_PASSWORD" | docker login "$REGISTRY" \
        --username "$ACR_USERNAME" \
        --password-stdin
elif [[ -n "$ACR_USERNAME" || -n "$ACR_PASSWORD" ]]; then
    echo "[ERROR] ACR_USERNAME and ACR_PASSWORD must be configured together." >&2
    exit 1
else
    echo "[WARN] ACR_USERNAME/ACR_PASSWORD are not configured. Ensure Docker is already logged in to ${REGISTRY}." >&2
fi

TARGET_REPOSITORY="${TARGET_IMAGE%%:*}"
TARGET_TAG="${TARGET_IMAGE#*:}"
if [[ "$TARGET_REPOSITORY" == "$TARGET_IMAGE" ]]; then
    TARGET_TAG="latest"
fi

TARGET_MANIFEST="${REGISTRY}/${TARGET_REPOSITORY}:${TARGET_TAG}"
ARCH_IMAGES=()

for ARCH in "${ARCHES[@]}"; do
    TARGET_TAGGED_IMAGE="${REGISTRY}/${TARGET_REPOSITORY}:${TARGET_TAG}-${ARCH}"
    ARCH_IMAGES+=("$TARGET_TAGGED_IMAGE")

    echo "[INFO] Pulling ${SOURCE_IMAGE} for linux/${ARCH}..."
    docker pull --platform "linux/${ARCH}" "$SOURCE_IMAGE"

    echo "[INFO] Tagging ${SOURCE_IMAGE} as ${TARGET_TAGGED_IMAGE}..."
    docker tag "$SOURCE_IMAGE" "$TARGET_TAGGED_IMAGE"

    echo "[INFO] Pushing ${TARGET_TAGGED_IMAGE}..."
    docker push "$TARGET_TAGGED_IMAGE"

    echo "[INFO] Removing local image tags..."
    docker image rm "$TARGET_TAGGED_IMAGE" >/dev/null 2>&1 || true
    docker image rm "$SOURCE_IMAGE" >/dev/null 2>&1 || true
    echo "[DONE] Synced ${SOURCE_IMAGE} for linux/${ARCH} to ${TARGET_TAGGED_IMAGE}"
done

echo "[INFO] Creating multi-architecture manifest ${TARGET_MANIFEST}..."
docker manifest rm "$TARGET_MANIFEST" >/dev/null 2>&1 || true
docker manifest create "$TARGET_MANIFEST" "${ARCH_IMAGES[@]}"

for INDEX in "${!ARCHES[@]}"; do
    ARCH="${ARCHES[$INDEX]}"
    ARCH_IMAGE="${ARCH_IMAGES[$INDEX]}"
    echo "[INFO] Annotating ${ARCH_IMAGE} as linux/${ARCH}..."
    docker manifest annotate "$TARGET_MANIFEST" "$ARCH_IMAGE" \
        --os linux \
        --arch "$ARCH"
done

echo "[INFO] Pushing multi-architecture manifest ${TARGET_MANIFEST}..."
docker manifest push "$TARGET_MANIFEST"
docker manifest rm "$TARGET_MANIFEST" >/dev/null 2>&1 || true

if [[ "$TARGET_TAG" != "latest" ]]; then
    LATEST_MANIFEST="${REGISTRY}/${TARGET_REPOSITORY}:latest"
    echo "[INFO] Creating latest manifest ${LATEST_MANIFEST}..."
    docker manifest rm "$LATEST_MANIFEST" >/dev/null 2>&1 || true
    docker manifest create "$LATEST_MANIFEST" "${ARCH_IMAGES[@]}"

    for INDEX in "${!ARCHES[@]}"; do
        ARCH="${ARCHES[$INDEX]}"
        ARCH_IMAGE="${ARCH_IMAGES[$INDEX]}"
        docker manifest annotate "$LATEST_MANIFEST" "$ARCH_IMAGE" \
            --os linux \
            --arch "$ARCH"
    done

    echo "[INFO] Pushing latest manifest ${LATEST_MANIFEST}..."
    docker manifest push "$LATEST_MANIFEST"
    docker manifest rm "$LATEST_MANIFEST" >/dev/null 2>&1 || true
    echo "[DONE] Published latest manifest: ${LATEST_MANIFEST}"
fi

echo "[DONE] Synced ${SOURCE_IMAGE} to ${TARGET_MANIFEST}"