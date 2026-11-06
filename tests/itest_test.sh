#!/usr/bin/env bash
# The test half of a rules_itest service_test: minio_server ran as an
# itest_service and its health check passed, so its env file is there.
set -euo pipefail
set -a; source "$TEST_TMPDIR/itest_server.env"; set +a
got=$("$MC" cat minio/data/seed/hello.txt)
[[ "$got" == "hello from the seed" ]] || { echo "FAIL: got '$got'" >&2; exit 1; }
echo "PASS"
