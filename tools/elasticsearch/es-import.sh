#!/usr/bin/env bash

usage() {
    echo "Usage: $0 --src <index> [--dest <index>] --url <url> (--user <user> --pass <pass> | --apikey <key>) [--shards <n>] [--replicas <n>]"
    echo "Example: $0 --src my_index --url http://192.168.1.2:9200 --user admin --pass password123 --shards 3 --replicas 1"
    echo "         $0 --src my_index --url http://192.168.1.2:9200 --apikey VnVhQ2ZHY0JDZGJjZXZFbU..."
    echo ""
    echo "Options:"
    echo "  --shards <n>          Override number of primary shards (cannot be changed after creation)"
    echo "  --replicas <n>        Override number of replica shards"
    echo "  --apikey <key>        Elasticsearch API key (mutually exclusive with --user/--pass)"
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
APIKEY=""
SHARDS=""
REPLICAS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --src)      SRC_INDEX_NAME="$2";  shift 2 ;;
        --dest)     DEST_INDEX_NAME="$2"; shift 2 ;;
        --url)      DEST_URL="$2";        shift 2 ;;
        --user)     USER="$2";            shift 2 ;;
        --pass)     PASS="$2";            shift 2 ;;
        --apikey)   APIKEY="$2";          shift 2 ;;
        --shards)   SHARDS="$2";          shift 2 ;;
        --replicas) REPLICAS="$2";        shift 2 ;;
        *) echo "[ERROR] Unknown option: $1"; usage ;;
    esac
done

if [ -z "$SRC_INDEX_NAME" ] || [ -z "$DEST_URL" ]; then
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

if [[ -n "$SHARDS" && (! "$SHARDS" =~ ^[0-9]+$ || "$SHARDS" -lt 1) ]]; then
    echo "[ERROR] --shards must be a positive integer."
    exit 1
fi

if [[ -n "$REPLICAS" && ! "$REPLICAS" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] --replicas must be a non-negative integer."
    exit 1
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

# Patch settings file if --shards or --replicas override is requested
TEMP_SETTINGS=""
if [ -n "$SHARDS" ] || [ -n "$REPLICAS" ]; then
    if ! command -v jq &>/dev/null; then
        echo "[ERROR] --shards/--replicas requires jq. Install it first (e.g. brew install jq)."
        exit 1
    fi
    TEMP_SETTINGS=$(mktemp /tmp/es_settings_XXXXXX.json)
    trap 'rm -f "$TEMP_SETTINGS"' EXIT
    JQ_EXPR="."
    [ -n "$SHARDS" ]   && JQ_EXPR="${JQ_EXPR} | .settings.index.number_of_shards = \"${SHARDS}\""
    [ -n "$REPLICAS" ] && JQ_EXPR="${JQ_EXPR} | .settings.index.number_of_replicas = \"${REPLICAS}\""
    jq -c "${JQ_EXPR}" "$SETTINGS_FILE" > "$TEMP_SETTINGS"
    SETTINGS_FILE="$TEMP_SETTINGS"
    echo "[INFO] Settings override: shards=${SHARDS:-unchanged} replicas=${REPLICAS:-unchanged}"
fi
if [ -n "$APIKEY" ]; then
    HEADERS="{\"Authorization\": \"ApiKey ${APIKEY}\"}"
    CURL_AUTH=(-H "Authorization: ApiKey ${APIKEY}")
else
    AUTH_HEADER=$(echo -n "${USER}:${PASS}" | base64)
    HEADERS="{\"Authorization\": \"Basic ${AUTH_HEADER}\"}"
    CURL_AUTH=(-u "${USER}:${PASS}")
fi

echo "--------------------------------------------"
echo "Starting import of index: ${SRC_INDEX_NAME} -> ${DEST_INDEX_NAME}"
echo "Destination URL: ${DEST_URL}"
echo "Performance parameters: limit=${LIMIT} concurrent=${CONCURRENT} sockets=${MAX_SOCKETS} timeout=${TIMEOUT}ms compress=${FS_COMPRESS}"
echo "--------------------------------------------"
echo "Checking destination index status..."
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "${CURL_AUTH[@]}" "${DEST_URL}/${DEST_INDEX_NAME}")

if [ "$HTTP_CODE" == "200" ]; then
    echo "[WARN] Destination index '${DEST_INDEX_NAME}' already exists."
    # Non-interactive stdin (piped, cron) → abort by default for safety.
    if [ ! -t 0 ]; then
        echo "[ABORT] stdin is not a TTY; refusing to prompt. Delete the index manually or re-run in a terminal."
        exit 1
    fi
    echo "Choose how to proceed:"
    echo "  1) Abort import (default, safe)"
    echo "  2) Delete the existing index and re-import"
    while true; do
        read -rp "Enter choice [1-2]: " EXISTS_CHOICE
        case "$EXISTS_CHOICE" in
            ""|1)
                echo "[ABORT] Import aborted by user."
                exit 1
                ;;
            2)
                echo "[WARN] This will PERMANENTLY delete index '${DEST_INDEX_NAME}' and all its data."
                read -rp "Type 'delete' to confirm: " CONFIRM
                if [ "$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')" != "delete" ]; then
                    echo "[ABORT] Confirmation failed. Import aborted."
                    exit 1
                fi
                echo "[INFO] Deleting existing index '${DEST_INDEX_NAME}'..."
                DEL_RESP_FILE=$(mktemp /tmp/es_delete_resp_XXXXXX.json)
                DEL_CODE=$(curl -sk -o "$DEL_RESP_FILE" -w "%{http_code}" \
                    -X DELETE "${CURL_AUTH[@]}" "${DEST_URL}/${DEST_INDEX_NAME}")
                if [ "$DEL_CODE" != "200" ]; then
                    echo "[FAIL] Delete failed (HTTP $DEL_CODE). Response:"
                    cat "$DEL_RESP_FILE"; echo
                    rm -f "$DEL_RESP_FILE"
                    exit 1
                fi
                rm -f "$DEL_RESP_FILE"
                echo "[OK] Deleted. Continuing with import..."
                break
                ;;
            *)
                echo "Invalid choice, please enter 1 or 2."
                ;;
        esac
    done
elif [ "$HTTP_CODE" == "404" ]; then
    echo "[CONTINUE] Destination index does not exist, ready to create and import data..."
else
    echo "[ERROR] Failed to connect to destination ES or unknown error occurred (HTTP Code: $HTTP_CODE)"
    exit 1
fi

# 4. Create the destination index in one shot (settings + mappings + aliases),
#    then stream data via elasticdump.
#
# elasticdump's --type=settings|mapping|alias branches are unreliable for our export
# format (they silently no-op on cleanly-formed JSON). ES itself accepts the full
# index definition on PUT /{index}, so we assemble one request from the three files.
echo "[$(date +'%H:%M:%S')] Creating destination index with settings + mappings + aliases..."

if ! command -v jq &>/dev/null; then
    echo "[ERROR] Import requires jq. Install it first (e.g. brew install jq)."
    exit 1
fi

ALIAS_FILE="${BACKUP_DIR}/${SRC_INDEX_NAME}_alias.json"

# If --dest renames the index (typically the UUID inside the name changes),
# alias names in the backup embed the OLD UUID and must be rewritten to the new one.
# Heuristic: strip the longest common prefix and suffix between src and dest names —
# the remaining middle is treated as the "id part" and replaced everywhere in alias keys.
SRC_ID_PART=""
DEST_ID_PART=""
if [ "$SRC_INDEX_NAME" != "$DEST_INDEX_NAME" ]; then
    _s="$SRC_INDEX_NAME"; _d="$DEST_INDEX_NAME"
    _plen=0
    while [ $_plen -lt ${#_s} ] && [ $_plen -lt ${#_d} ] \
          && [ "${_s:$_plen:1}" = "${_d:$_plen:1}" ]; do
        _plen=$((_plen+1))
    done
    _slen=0
    while [ $((_plen + _slen)) -lt ${#_s} ] && [ $((_plen + _slen)) -lt ${#_d} ] \
          && [ "${_s:$((${#_s}-1-_slen)):1}" = "${_d:$((${#_d}-1-_slen)):1}" ]; do
        _slen=$((_slen+1))
    done
    SRC_ID_PART="${_s:$_plen:$((${#_s}-_plen-_slen))}"
    DEST_ID_PART="${_d:$_plen:$((${#_d}-_plen-_slen))}"
    if [ -n "$SRC_ID_PART" ] && [ -n "$DEST_ID_PART" ]; then
        echo "[INFO] Rewriting alias names: '${SRC_ID_PART}' -> '${DEST_ID_PART}'"
    fi
fi

# ES rejects these read-only / system-managed fields on index creation.
# Strip them from the settings block before PUT.
CREATE_BODY=$(jq -n \
    --slurpfile s "$SETTINGS_FILE" \
    --slurpfile m "$MAPPING_FILE" \
    --slurpfile a "$ALIAS_FILE" \
    --arg src "$SRC_INDEX_NAME" \
    --arg src_id "$SRC_ID_PART" \
    --arg dest_id "$DEST_ID_PART" \
    '{
        settings: (
            ($s[0][$src].settings // {})
            | .index |= (
                del(.creation_date, .uuid, .provided_name, .version,
                    .routing, .history, .resize, .frozen, .verified_before_close)
            )
        ),
        mappings: ($m[0][$src].mappings // {}),
        aliases: (
            ($a[0][$src].aliases // {})
            | if ($src_id | length) > 0 and ($dest_id | length) > 0
              then with_entries(.key |= (split($src_id) | join($dest_id)))
              else .
              end
        )
    }')

CREATE_RESPONSE_FILE=$(mktemp /tmp/es_create_resp_XXXXXX.json)
trap 'rm -f "$TEMP_SETTINGS" "$CREATE_RESPONSE_FILE"' EXIT

HTTP_CODE=$(curl -sk -o "$CREATE_RESPONSE_FILE" -w "%{http_code}" \
    -X PUT "${CURL_AUTH[@]}" \
    -H "Content-Type: application/json" \
    --data "$CREATE_BODY" \
    "${DEST_URL}/${DEST_INDEX_NAME}")

if [ "$HTTP_CODE" != "200" ]; then
    echo "[FAIL] Index creation failed (HTTP $HTTP_CODE). Response:"
    cat "$CREATE_RESPONSE_FILE"
    echo
    exit 1
fi

# Verify mappings actually landed (dynamic:strict with 0 properties is the failure mode we hit before).
PROP_COUNT=$(curl -sk "${CURL_AUTH[@]}" "${DEST_URL}/${DEST_INDEX_NAME}/_mapping" \
    | jq ".[\"${DEST_INDEX_NAME}\"].mappings.properties | length")
if [ "$PROP_COUNT" = "0" ] || [ -z "$PROP_COUNT" ] || [ "$PROP_COUNT" = "null" ]; then
    echo "[FAIL] Destination index was created but has 0 mapping properties. Aborting."
    exit 1
fi
echo "[OK] Index created with $PROP_COUNT mapping properties."

# 5. Stream data via elasticdump — this is what elasticdump is actually good at.
DATA_FILE_LOCAL="$DATA_FILE"
echo "[$(date +'%H:%M:%S')] Importing data..."
NODE_TLS_REJECT_UNAUTHORIZED=0 elasticdump \
  --input="${DATA_FILE_LOCAL}" \
  --output="${DEST_URL}/${DEST_INDEX_NAME}" \
  --output-headers="${HEADERS}" \
  --type="data" \
  --limit="${LIMIT}" \
  --concurrentRequests="${CONCURRENT}" \
  --maxSockets="${MAX_SOCKETS}" \
  --timeout="${TIMEOUT}" \
  --retryAttempts="${RETRY_ATTEMPTS}" \
  --retryDelay="${RETRY_DELAY}" \
  --fsCompress="${FS_COMPRESS}" \
  --noRefresh

if [ $? -ne 0 ]; then
    echo "[FAIL] Error occurred during data import!"
    exit 1
fi

echo "--------------------------------------------"
echo "Index ${SRC_INDEX_NAME} imported successfully as ${DEST_INDEX_NAME}!"
echo "--------------------------------------------"
