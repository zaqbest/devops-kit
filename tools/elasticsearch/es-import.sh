#!/usr/bin/env bash

usage() {
    echo "Usage: $0 --src <index> [--dest <index>] --url <url> --user <user> --pass <pass>"
    echo "Example: $0 --src my_index --url http://192.168.1.2:9200 --user admin --pass password123"
    echo ""
    echo "Performance tuning environment variables (override as needed):"
    echo "  LIMIT=5000            Records per batch"
    echo "  CONCURRENT=3          Concurrent requests (data type only)"
    echo "  MAX_SOCKETS=20        HTTP connection pool size"
    echo "  TIMEOUT=120000        Request timeout (ms)"
    echo "  RETRY_ATTEMPTS=3      Number of retry attempts on failure"
    echo "  RETRY_DELAY=5000      Retry interval (ms)"
    echo "  FS_COMPRESS=true      Read gzip-compressed files (must match export setting)"
    exit 1
}

SRC_INDEX_NAME=""
DEST_INDEX_NAME=""
DEST_URL=""
USER=""
PASS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --src)   SRC_INDEX_NAME="$2";  shift 2 ;;
        --dest)  DEST_INDEX_NAME="$2"; shift 2 ;;
        --url)   DEST_URL="$2";        shift 2 ;;
        --user)  USER="$2";            shift 2 ;;
        --pass)  PASS="$2";            shift 2 ;;
        *) echo "[ERROR] Unknown option: $1"; usage ;;
    esac
done

if [ -z "$SRC_INDEX_NAME" ] || [ -z "$DEST_URL" ] || [ -z "$USER" ] || [ -z "$PASS" ]; then
    echo "[ERROR] Missing required parameters."
    usage
fi

DEST_INDEX_NAME="${DEST_INDEX_NAME:-$SRC_INDEX_NAME}"

# Performance parameters (environment variable overrides supported)
LIMIT=${LIMIT:-5000}
CONCURRENT=${CONCURRENT:-3}
MAX_SOCKETS=${MAX_SOCKETS:-20}
TIMEOUT=${TIMEOUT:-120000}
RETRY_ATTEMPTS=${RETRY_ATTEMPTS:-3}
RETRY_DELAY=${RETRY_DELAY:-5000}
FS_COMPRESS=${FS_COMPRESS:-true}

# 1. Discover available backup directories (exact match + timestamped versions)
CANDIDATE_DIRS=()
while IFS= read -r line; do
    CANDIDATE_DIRS+=("$line")
done < <(find ./backup -maxdepth 1 -type d \( \
        -name "${SRC_INDEX_NAME}" \
        -o -name "${SRC_INDEX_NAME}[_.][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]" \
    \) | sort)

if [ "${#CANDIDATE_DIRS[@]}" -eq 0 ]; then
    echo "[ERROR] No backup directory found for index '${SRC_INDEX_NAME}' (./backup/${SRC_INDEX_NAME}*)"
    exit 1
elif [ "${#CANDIDATE_DIRS[@]}" -eq 1 ]; then
    BACKUP_DIR="${CANDIDATE_DIRS[0]}"
    echo "[INFO] Using backup directory: $BACKUP_DIR"
else
    echo "Multiple backup versions found, please choose the directory to import:"
    for i in "${!CANDIDATE_DIRS[@]}"; do
        echo "  $((i+1))) ${CANDIDATE_DIRS[$i]}"
    done
    while true; do
        read -rp "Enter number [1-${#CANDIDATE_DIRS[@]}]: " CHOICE
        if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#CANDIDATE_DIRS[@]}" ]; then
            BACKUP_DIR="${CANDIDATE_DIRS[$((CHOICE-1))]}"
            break
        fi
        echo "Invalid input, please try again."
    done
    echo "[INFO] Selected: $BACKUP_DIR"
fi

# Define backup file paths (data file extension follows compression setting)
SETTINGS_FILE="${BACKUP_DIR}/${SRC_INDEX_NAME}_settings.json"
MAPPING_FILE="${BACKUP_DIR}/${SRC_INDEX_NAME}_mapping.json"
ALIAS_FILE="${BACKUP_DIR}/${SRC_INDEX_NAME}_alias.json"
if [ "$FS_COMPRESS" == "true" ]; then
    DATA_FILE="${BACKUP_DIR}/${SRC_INDEX_NAME}_data.json.gz"
else
    DATA_FILE="${BACKUP_DIR}/${SRC_INDEX_NAME}_data.json"
fi

# Verify the selected directory contains all required backup files
if [ ! -f "$SETTINGS_FILE" ] || [ ! -f "$MAPPING_FILE" ] || [ ! -f "$DATA_FILE" ] || [ ! -f "$ALIAS_FILE" ]; then
    echo "[ERROR] Backup files in selected directory $BACKUP_DIR are incomplete, please check."
    exit 1
fi

# 2. Build authentication info
AUTH_HEADER=$(echo -n "${USER}:${PASS}" | base64)
HEADERS="{\"Authorization\": \"Basic ${AUTH_HEADER}\"}"

echo "--------------------------------------------"
echo "Starting import of index: ${SRC_INDEX_NAME} -> ${DEST_INDEX_NAME}"
echo "Destination URL: ${DEST_URL}"
echo "Performance parameters: limit=${LIMIT} concurrent=${CONCURRENT} sockets=${MAX_SOCKETS} timeout=${TIMEOUT}ms compress=${FS_COMPRESS}"
echo "--------------------------------------------"

# 3. Check whether the destination index already exists (core logic: abort if it does)
echo "Checking destination index status..."
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -u "${USER}:${PASS}" "${DEST_URL}/${DEST_INDEX_NAME}")

if [ "$HTTP_CODE" == "200" ]; then
    echo "[ABORT] Destination index '${DEST_INDEX_NAME}' already exists. Import aborted for data safety."
    exit 1
elif [ "$HTTP_CODE" == "404" ]; then
    echo "[CONTINUE] Destination index does not exist, ready to create and import data..."
else
    echo "[ERROR] Failed to connect to destination ES or unknown error occurred (HTTP Code: $HTTP_CODE)"
    exit 1
fi

# 4. Execute imports in order (Settings -> Mapping -> Data -> Alias)
TYPES=("settings" "mapping" "data" "alias")

for TYPE in "${TYPES[@]}"; do
    # Data file extension follows compression setting, others always .json
    if [ "$TYPE" == "data" ] && [ "$FS_COMPRESS" == "true" ]; then
        FILE="${BACKUP_DIR}/${SRC_INDEX_NAME}_${TYPE}.json.gz"
    else
        FILE="${BACKUP_DIR}/${SRC_INDEX_NAME}_${TYPE}.json"
    fi
    echo "[$(date +'%H:%M:%S')] Importing ${TYPE}..."

    # Enable concurrency and noRefresh for data type to speed up writes; others use single request
    if [ "$TYPE" == "data" ]; then
        NODE_TLS_REJECT_UNAUTHORIZED=0 elasticdump \
          --input="${FILE}" \
          --output="${DEST_URL}/${DEST_INDEX_NAME}" \
          --output-headers="${HEADERS}" \
          --type="${TYPE}" \
          --limit="${LIMIT}" \
          --concurrentRequests="${CONCURRENT}" \
          --maxSockets="${MAX_SOCKETS}" \
          --timeout="${TIMEOUT}" \
          --retryAttempts="${RETRY_ATTEMPTS}" \
          --retryDelay="${RETRY_DELAY}" \
          --fsCompress="${FS_COMPRESS}" \
          --noRefresh
    else
        NODE_TLS_REJECT_UNAUTHORIZED=0 elasticdump \
          --input="${FILE}" \
          --output="${DEST_URL}/${DEST_INDEX_NAME}" \
          --output-headers="${HEADERS}" \
          --type="${TYPE}" \
          --limit="${LIMIT}" \
          --timeout="${TIMEOUT}" \
          --retryAttempts="${RETRY_ATTEMPTS}" \
          --retryDelay="${RETRY_DELAY}"
    fi

    if [ $? -ne 0 ]; then
        echo "[FAIL] Error occurred during ${TYPE} import!"
        exit 1
    fi
done

echo "--------------------------------------------"
echo "Index ${SRC_INDEX_NAME} imported successfully as ${DEST_INDEX_NAME}!"
echo "--------------------------------------------"
