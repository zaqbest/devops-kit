#!/bin/bash

usage() {
    echo "Usage: $0 --index <index> --url <url> (--user <user> --pass <pass> | --apikey <key>) [--max-docs <n>]"
    echo "Example: $0 --index my_index --url http://192.168.1.1:9200 --user admin --pass password123 --max-docs 10000"
    echo "         $0 --index my_index --url http://192.168.1.1:9200 --apikey VnVhQ2ZHY0JDZGJjZXZFbU..."
    echo ""
    echo "Options:"
    echo "  --max-docs <n>        Maximum number of documents to export (default: unlimited)"
    echo "  --apikey <key>        Elasticsearch API key (mutually exclusive with --user/--pass)"
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
}

INDEX=""
SRC_URL=""
USER=""
PASS=""
APIKEY=""
MAX_DOCS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --index)    INDEX="$2";    shift 2 ;;
        --url)      SRC_URL="$2";  shift 2 ;;
        --user)     USER="$2";     shift 2 ;;
        --pass)     PASS="$2";     shift 2 ;;
        --apikey)   APIKEY="$2";   shift 2 ;;
        --max-docs) MAX_DOCS="$2"; shift 2 ;;
        *) echo "[ERROR] Unknown option: $1"; usage ;;
    esac
done

if [ -z "$INDEX" ] || [ -z "$SRC_URL" ]; then
    echo "[ERROR] Missing required parameters."
    usage
fi

if [ -n "$APIKEY" ] && ([ -n "$USER" ] || [ -n "$PASS" ]); then
    echo "[ERROR] --apikey and --user/--pass are mutually exclusive."
    exit 1
fi

if [ -z "$APIKEY" ] && ([ -z "$USER" ] || [ -z "$PASS" ]); then
    echo "[ERROR] Either --apikey or both --user and --pass are required."
    exit 1
fi

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

# Build authentication header
if [ -n "$APIKEY" ]; then
    HEADERS="{\"Authorization\": \"ApiKey ${APIKEY}\"}"
    CURL_AUTH=(-H "Authorization: ApiKey ${APIKEY}")
else
    AUTH_HEADER=$(echo -n "${USER}:${PASS}" | base64)
    HEADERS="{\"Authorization\": \"Basic ${AUTH_HEADER}\"}"
    CURL_AUTH=(-u "${USER}:${PASS}")
fi

echo "--------------------------------------------"
echo "Starting export of index: ${INDEX}"
echo "Source URL: ${SRC_URL}"
echo "Storage directory: ${BACKUP_DIR}"
echo "Performance parameters: limit=${LIMIT} concurrent=${CONCURRENT} sockets=${MAX_SOCKETS} timeout=${TIMEOUT}ms scroll=${SCROLL_TIME} compress=${FS_COMPRESS}"
if [ -n "$MAX_DOCS" ]; then
    echo "Max docs: ${MAX_DOCS}"
fi
echo "--------------------------------------------"

# Check index status — closed indices cannot be scrolled
echo "Checking index status..."
INDEX_STATUS=$(curl -sk "${CURL_AUTH[@]}" "${SRC_URL}/_cat/indices/${INDEX}?h=status" | tr -d '[:space:]')
if [ "$INDEX_STATUS" == "close" ]; then
    echo "[ERROR] Index '${INDEX}' is closed. Scroll/search is not available on closed indices."
    echo "        Open it first, then re-run the export:"
    echo "          POST ${SRC_URL}/${INDEX}/_open"
    exit 1
elif [ -z "$INDEX_STATUS" ]; then
    echo "[ERROR] Index '${INDEX}' not found or unreachable."
    exit 1
fi
echo "[OK] Index status: ${INDEX_STATUS}"

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

    # elasticdump has a known bug where --type=settings/alias file-output writes the
    # JSON payload wrapped in an extra string layer ("{\"...\":..." instead of {"...":...).
    # Grab those endpoints with curl directly — they're a single GET each, no scroll needed.
    if [ "$TYPE" == "settings" ] || [ "$TYPE" == "alias" ]; then
        ENDPOINT="_${TYPE}"
        HTTP_CODE=$(curl -sk -o "$OUTPUT_FILE" -w "%{http_code}" \
            "${CURL_AUTH[@]}" "${SRC_URL}/${INDEX}/${ENDPOINT}")
        if [ "$HTTP_CODE" != "200" ]; then
            echo "[ERROR] ${TYPE} export failed (HTTP $HTTP_CODE). Response:"
            cat "$OUTPUT_FILE"
            exit 1
        fi
        # Sanity check: must be a JSON object, not a string
        if command -v jq &>/dev/null; then
            TOP_TYPE=$(jq -r 'type' "$OUTPUT_FILE" 2>/dev/null)
            if [ "$TOP_TYPE" != "object" ]; then
                echo "[ERROR] ${TYPE} export produced non-object JSON (type=$TOP_TYPE)."
                exit 1
            fi
        fi
        echo "[DONE] ${TYPE} saved to ${OUTPUT_FILE}"
        continue
    fi

    # Enable concurrency and scroll optimization for data type; others use single request
    if [ "$TYPE" == "data" ]; then
        MAX_DOCS_ARG=""
        if [ -n "$MAX_DOCS" ]; then
            MAX_DOCS_ARG="--size=${MAX_DOCS}"
        fi
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
          --fsCompress="${FS_COMPRESS}" \
          ${MAX_DOCS_ARG}
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
