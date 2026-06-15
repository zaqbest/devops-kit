# Elasticsearch Backup & Restore Tools

Two shell scripts for backing up and restoring Elasticsearch indices via [elasticdump](https://github.com/elasticsearch-dump/elasticsearch-dump).

## Dependencies

| Tool | Purpose | Install |
|------|---------|---------|
| `elasticdump` | Core dump/restore engine | `npm install -g elasticdump` |
| `curl` | Check index existence before import | Built-in on macOS/Linux |
| `jq` | Patch shards/replicas at import time | `brew install jq` (only needed with `--shards`/`--replicas`) |

---

## es-export.sh

Export an Elasticsearch index (settings, mapping, data, alias) to a local backup directory.

### Usage

```bash
./es-export.sh --index <index> --url <url> (--user <user> --pass <pass> | --apikey <key>) [--max-docs <n>]
```

### Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `--index` | Yes | Index name to export |
| `--url` | Yes | Elasticsearch base URL, e.g. `http://192.168.1.1:9200` |
| `--user` | Yes* | Username |
| `--pass` | Yes* | Password |
| `--apikey` | Yes* | API Key (`--apikey` and `--user`/`--pass` are mutually exclusive) |
| `--max-docs` | No | Maximum number of documents to export; omit for all |

*`--user`+`--pass` 或 `--apikey` 二选一，必须提供其中一种。

### Performance Tuning (environment variables)

| Variable | Default | Description |
|----------|---------|-------------|
| `LIMIT` | `5000` | Records per batch |
| `CONCURRENT` | `3` | Concurrent requests (data type only) |
| `MAX_SOCKETS` | `20` | HTTP connection pool size |
| `TIMEOUT` | `120000` | Request timeout in milliseconds |
| `SCROLL_TIME` | `30m` | Scroll context lifetime |
| `RETRY_ATTEMPTS` | `3` | Retry count on failure |
| `RETRY_DELAY` | `5000` | Retry interval in milliseconds |
| `FS_COMPRESS` | `true` | Gzip-compress data file (`true`/`false`) |

### Output

Files are written to `./backup/<index>/`:

```
backup/
└── my_index/
    ├── my_index_settings.json
    ├── my_index_mapping.json
    ├── my_index_data.json.gz   # .json if FS_COMPRESS=false
    └── my_index_alias.json
```

If the directory already exists, a timestamped suffix is appended automatically (e.g. `my_index_20240615_143022`).

### Examples

```bash
# Full export (Basic Auth)
./es-export.sh --index my_index --url http://192.168.1.1:9200 --user admin --pass secret

# Full export (API Key)
./es-export.sh --index my_index --url http://192.168.1.1:9200 --apikey VnVhQ2ZHY0JDZGJjZXZFbU...

# Export at most 10,000 documents
./es-export.sh --index my_index --url http://192.168.1.1:9200 --apikey VnVhQ2ZHY0JDZGJjZXZFbU... --max-docs 10000

# Export without compression, larger batches
FS_COMPRESS=false LIMIT=10000 \
./es-export.sh --index my_index --url http://192.168.1.1:9200 --user admin --pass secret
```

---

## es-import.sh

Restore an Elasticsearch index from a local backup directory. Import order is always: **settings → mapping → data → alias**.

### Usage

```bash
./es-import.sh --src <index> [--dest <index>] --url <url> (--user <user> --pass <pass> | --apikey <key>) [--shards <n>] [--replicas <n>]
```

### Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `--src` | Yes | Source index name (matches the backup directory name) |
| `--dest` | No | Destination index name; defaults to `--src` if omitted |
| `--url` | Yes | Elasticsearch base URL, e.g. `http://192.168.1.2:9200` |
| `--user` | Yes* | Username |
| `--pass` | Yes* | Password |
| `--apikey` | Yes* | API Key (`--apikey` and `--user`/`--pass` are mutually exclusive) |
| `--shards` | No | Override primary shard count (requires `jq`; integer ≥ 1) |
| `--replicas` | No | Override replica count (requires `jq`; integer ≥ 0) |

*`--user`+`--pass` 或 `--apikey` 二选一，必须提供其中一种。

> **Note:** `--shards` takes effect only at index creation time and cannot be changed afterwards. `--replicas` can be adjusted at any time, but setting it here avoids a separate API call.

### Performance Tuning (environment variables)

| Variable | Default | Description |
|----------|---------|-------------|
| `LIMIT` | `5000` | Records per batch |
| `CONCURRENT` | `3` | Concurrent requests (data type only) |
| `MAX_SOCKETS` | `20` | HTTP connection pool size |
| `TIMEOUT` | `120000` | Request timeout in milliseconds |
| `RETRY_ATTEMPTS` | `3` | Retry count on failure |
| `RETRY_DELAY` | `5000` | Retry interval in milliseconds |
| `FS_COMPRESS` | `true` | Read gzip-compressed data file; must match the export setting |

### Safety

The script **aborts if the destination index already exists** to prevent accidental data overwrite.

### Examples

```bash
# Restore (Basic Auth)
./es-import.sh --src my_index --url http://192.168.1.2:9200 --user admin --pass secret

# Restore (API Key)
./es-import.sh --src my_index --url http://192.168.1.2:9200 --apikey VnVhQ2ZHY0JDZGJjZXZFbU...

# Restore to a different index name
./es-import.sh --src my_index --dest my_index_restored --url http://192.168.1.2:9200 --apikey VnVhQ2ZHY0JDZGJjZXZFbU...

# Override shards and replicas
./es-import.sh --src my_index --url http://192.168.1.2:9200 --user admin --pass secret --shards 3 --replicas 1

# Set replicas to 0 (useful for single-node clusters)
./es-import.sh --src my_index --url http://192.168.1.2:9200 --user admin --pass secret --replicas 0

# Restore uncompressed backup
FS_COMPRESS=false \
./es-import.sh --src my_index --url http://192.168.1.2:9200 --user admin --pass secret
```

---

## Typical Workflow

```bash
# 1. Export from source cluster
./es-export.sh --index my_index --url http://src-host:9200 --apikey <src-api-key>

# 2. Import to destination cluster (adjust shards/replicas as needed)
./es-import.sh --src my_index --url http://dst-host:9200 --apikey <dst-api-key> --shards 3 --replicas 1
```
