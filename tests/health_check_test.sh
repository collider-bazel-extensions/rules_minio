#!/usr/bin/env bash
# minio_health_check exits non-zero until the server's env file exists, then 0.
set -euo pipefail
CHECK="$TEST_SRCDIR/_main/$1"
env_file="$TEST_TMPDIR/test_server.env"
rm -f "$env_file"
if "$CHECK" 2>/dev/null; then echo "FAIL: passed without env file" >&2; exit 1; fi
echo "MINIO_HOST=127.0.0.1" > "$env_file"
"$CHECK" || { echo "FAIL: failed with env file present" >&2; exit 1; }
echo "PASS"
