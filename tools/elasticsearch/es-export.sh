#!/bin/bash

# Argument validation
if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <INDEX_NAME> <SRC_URL> <USERNAME> <PASSWORD>"
    echo "Example: $0 my_index http://192.168.1.1:9200 admin password123"
    echo ""
    echo "Performance tuning environment variables (override as needed):"
    echo "  LIMIT=5000            Records per batch"
    echo "  CONCURRENT=3          Concurrent requests (data type only)"
    echo "  MAX_SOCKETS=20        HTTP connection pool size"
    echo "  TIMEOUT=120000        Request timeout (ms)"
    echo "  SCROLL_TIME=30m       Scroll context lifetime"
    echo "  RETRY_ATTEMPTS=3      Number of retry attempts on failure"
    echo "  RETRY_DELAY=5000      Retry interval (ms)"
    echo "  FS_COMPRESS=true      Local file gzip compression (true/false)"
    exit 1
fi

INDEX=$1
SRC_URL=$2
USER=$3
PASS=$4

# Performance parameters (environment variable overrides supported)
LIMIT=${LIMIT:-5000}
CONCURRENT=${CONCURRENT:-3}
MAX_SOCKETS=${MAX_SOCKETS:-20}
TIMEOUT=${TIMEOUT:-120000}
SCROLL_TIME=${SCROLL_TIME:-30m}
RETRY_ATTEMPTS=${RETRY_ATTEMPTS:-3}
RETRY_DELAY=${RETRY_DELAY:-5000}
FS_COMPRESS=${FS_COMPRESS:-true}

# Create backup directory (named after the index; append timestamp if it already exists)
BACKUP_DIR="./backup/${INDEX}"
if [ -d "$BACKUP_DIR" ]; then
    TIMESTAMP=$(date +'%Y%m%d_%H%M%S')
    BACKUP_DIR="./backup/${INDEX}_${TIMESTAMP}"
    echo "[INFO] Backup directory already exists, using timestamped directory: $BACKUP_DIR"
fi

mkdir -p "$BACKUP_DIR"

# Build authentication info
AUTH_HEADER=$(echo -n "${USER}:${PASS}" | base64)
HEADERS="{\"Authorization\": \"Basic ${AUTH_HEADER}\"}"

echo "--------------------------------------------"
echo "Starting export of index: ${INDEX}"
echo "Source URL: ${SRC_URL}"
echo "Storage directory: ${BACKUP_DIR}"
echo "Performance parameters: limit=${LIMIT} concurrent=${CONCURRENT} sockets=${MAX_SOCKETS} timeout=${TIMEOUT}ms scroll=${SCROLL_TIME} compress=${FS_COMPRESS}"
echo "--------------------------------------------"

# Types to export
TYPES=("settings" "mapping" "data" "alias")

for TYPE in "${TYPES[@]}"; do
    echo "[$(date +'%H:%M:%S')] Exporting ${TYPE}..."

    # Use .json.gz for data when compression is enabled; other types always use .json
    if [ "$TYPE" == "data" ] && [ "$FS_COMPRESS" == "true" ]; then
        OUTPUT_FILE="${BACKUP_DIR}/${INDEX}_${TYPE}.json.gz"
    else
        OUTPUT_FILE="${BACKUP_DIR}/${INDEX}_${TYPE}.json"
    fi

    # Enable concurrency and scroll optimization for data type; others use single request
    if [ "$TYPE" == "data" ]; then
        NODE_TLS_REJECT_UNAUTHORIZED=0 elasticdump \
          --input="${SRC_URL}/${INDEX}" \
          --input-headers="${HEADERS}" \
          --output="${OUTPUT_FILE}" \
          --type="${TYPE}" \
          --limit="${LIMIT}" \
          --concurrentRequests="${CONCURRENT}" \
          --maxSockets="${MAX_SOCKETS}" \
          --timeout="${TIMEOUT}" \
          --scrollTime="${SCROLL_TIME}" \
          --retryAttempts="${RETRY_ATTEMPTS}" \
          --retryDelay="${RETRY_DELAY}" \
          --fsCompress="${FS_COMPRESS}"
    else
        NODE_TLS_REJECT_UNAUTHORIZED=0 elasticdump \
          --input="${SRC_URL}/${INDEX}" \
          --input-headers="${HEADERS}" \
          --output="${OUTPUT_FILE}" \
          --type="${TYPE}" \
          --limit="${LIMIT}" \
          --timeout="${TIMEOUT}" \
          --retryAttempts="${RETRY_ATTEMPTS}" \
          --retryDelay="${RETRY_DELAY}"
    fi

    if [ $? -eq 0 ]; then
        echo "[DONE] ${TYPE} saved to ${OUTPUT_FILE}"
    else
        echo "[ERROR] ${TYPE} export failed!"
        exit 1
    fi
done

echo "--------------------------------------------"
echo "All export tasks completed!"
echo "File list:"
ls -lh "$BACKUP_DIR"
