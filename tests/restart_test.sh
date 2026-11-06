#!/usr/bin/env bash
# minio_stop: clients fail; minio_start: same port, credentials, users
# and data (drives persist).
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$MINIO_TESTLIB"
echo kept > "$TEST_TMPDIR/f"
mc cp "$TEST_TMPDIR/f" minio/data/k >/dev/null
port=$MINIO_PORT
minio_stop
if mc ls minio/data >/dev/null 2>&1; then fail "mc worked while stopped"; fi
(exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && fail "port $port open while stopped"
echo "ok: stopped"
minio_start
[[ "$(mc cat minio/data/k)" == kept ]] || fail "data lost"
[[ "$(minio_as alice cat minio/data/k)" == kept ]] || fail "user lost"
grep -q "127.0.0.1:$port" <<<"$(mc admin info minio)" || fail "not on port $port"
echo "PASS: started again on $port with its data and users"
