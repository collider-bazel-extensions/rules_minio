#!/usr/bin/env bash
# Inner test for server_cleanup_test: records where minio listened.
set -euo pipefail
echo "$MINIO_PORT" > "$RECORD_FILE"
