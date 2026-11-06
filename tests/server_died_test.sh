#!/usr/bin/env bash
# minio_test watches the server: if it dies while the test runs, the test
# is stopped at once and fails with the server's status and log. A test
# that fails on its own keeps its exit status.
#
# Argv: <trampoline> <testlib.sh>
#       <dies server> <dies inner> <exit3 server> <exit3 inner>
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$TEST_SRCDIR/_main/$1"; LIB="$2"

inner_tmp="$TEST_TMPDIR/dies"; mkdir -p "$inner_tmp"
start=$(date +%s); rc=0
out=$(TEST_TMPDIR="$inner_tmp" timeout 120 "$T" "$3" "$4" server_dies_minio "$LIB" 2>&1) || rc=$?
took=$(( $(date +%s) - start ))
echo "$out"
[[ "$rc" == 1 ]] || fail "status $rc, want 1"
grep -q "minio_test: the MinIO server exited (status [0-9]*) while the test was running; the test was stopped." <<<"$out" || fail "no watch message"
grep -q "minio_test: last lines of .*minio.log:" <<<"$out" || fail "no log tail"
grep -q "BODY FINISHED" <<<"$out" && fail "the test body ran on after the server died"
(( took < 20 )) || fail "took ${took}s: the test wasn't stopped promptly"
echo "ok: server died mid-test -> stopped and failed in ${took}s"

inner_tmp="$TEST_TMPDIR/exit3"; mkdir -p "$inner_tmp"
rc=0; TEST_TMPDIR="$inner_tmp" timeout 120 "$T" "$5" "$6" exit3_minio "$LIB" a b >/dev/null 2>&1 || rc=$?
[[ "$rc" == 3 ]] || fail "test's own status: $rc, want 3"
echo "ok: the test's own exit status is kept"
echo "PASS"
