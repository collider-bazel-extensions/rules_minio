#!/usr/bin/env bash
# A server that can't start, isn't ready in time, or whose provisioning
# fails exits non-zero, names the cause, and writes no env file;
# minio_test fails before running the test body.
#
# Argv: <bad_flag server> <bad_provision server> <slow server> <trampoline>
#       <failing_minio_test server> <failing_minio_test inner> <testlib.sh>
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

run() {
  local name="$1" path="$TEST_SRCDIR/_main/$2" rc=0
  out=$(timeout 120 "$path" 2>&1) || rc=$?
  [[ "$rc" != 0 ]] || fail "$name: exited 0. Output: $out"
  [[ "$rc" != 124 ]] || fail "$name: hung. Output: $out"
  [[ ! -f "$TEST_TMPDIR/$name.env" ]] || fail "$name: env file written"
}

run bad_flag_server "$1"
grep -q "minio exited with status 1 before it was ready" <<<"$out" || fail "bad_flag: cause: $out"
grep -qi "flag provided but not defined: -no-such-option" <<<"$out" || fail "bad_flag: server message: $out"
echo "ok: minio that can't start"

run bad_provision_server "$2"
grep -q "bucket policy .*public_downloads.json is for bucket downloads, which \`buckets\` doesn't create" <<<"$out" \
  || fail "bad_provision: cause: $out"
port=$(sed -n 's/^\[minio\] stopped minio (port \([0-9]*\))$/\1/p' <<<"$out")
[[ -n "$port" ]] || fail "bad_provision: the stopped server's port not named: $out"
if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then fail "bad_provision: server left running on $port"; fi
echo "ok: failing provisioning stops the server"

run slow_server "$3"
grep -q "minio was not ready within 0.001s" <<<"$out" || fail "slow: cause: $out"
echo "ok: readiness timeout"

inner_tmp="$TEST_TMPDIR/inner"; mkdir -p "$inner_tmp"
rc=0
out=$(TEST_TMPDIR="$inner_tmp" timeout 120 "$TEST_SRCDIR/_main/$4" "$5" "$6" failing_minio_test_minio "$7" 2>&1) || rc=$?
[[ "$rc" != 0 && "$rc" != 124 ]] || fail "failing minio_test: status $rc: $out"
grep -q "minio_test: MinIO server exited" <<<"$out" || fail "minio_test: cause: $out"
if grep -q "TEST BODY RAN" <<<"$out"; then fail "minio_test ran the test body"; fi
echo "PASS: minio_test fails before the test runs"
