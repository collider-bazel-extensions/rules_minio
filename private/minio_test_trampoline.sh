#!/usr/bin/env bash
# minio_test trampoline — starts the server, then runs the user's test.
#
# Argv: <server> <inner> <server_name> <testlib.sh> [user args...]
set -euo pipefail

SERVER_SHORT="$1"; INNER_SHORT="$2"; SERVER_NAME="$3"; LIB_SHORT="$4"
shift 4

: "${TEST_TMPDIR:?minio_test: TEST_TMPDIR not set (expected under bazel test)}"
if [[ -z "${RUNFILES_DIR:-}" ]]; then
  RUNFILES_DIR="${TEST_SRCDIR:-$0.runfiles}"
  export RUNFILES_DIR
fi

resolve() {
  local p="$1"
  for c in "${RUNFILES_DIR}/_main/${p}" "${RUNFILES_DIR}/${p}" "${RUNFILES_DIR}/${p#../}"; do
    [[ -e "$c" ]] && { printf '%s\n' "$c"; return; }
  done
  echo "minio_test: not in runfiles: ${p}" >&2
  exit 1
}

server_pid=""
test_pid=""

# The test's process tree (the test and everything it started), so a
# stopped test leaves nothing running. pgrep -P: exact parent pid.
tree() {
  local p
  for p in $(pgrep -P "$1" 2>/dev/null); do tree "$p"; done
  echo "$1"
}
stop_test() {
  local pids p
  pids=$(tree "$test_pid")
  for p in $pids; do kill -TERM "$p" 2>/dev/null || true; done
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$test_pid" 2>/dev/null || break; sleep 0.2; done
  for p in $pids; do kill -KILL "$p" 2>/dev/null || true; done
  wait "$test_pid" 2>/dev/null || true
  test_pid=""
}

cleanup() {
  if [[ -n "$test_pid" ]]; then stop_test; fi
  if [[ -n "$server_pid" ]]; then
    kill -TERM "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

env_file="$TEST_TMPDIR/${SERVER_NAME}.env"
rm -f "$env_file"
"$(resolve "$SERVER_SHORT")" &
server_pid=$!
# The server enforces its own ready_timeout; this outer bound only guards
# against a hung launcher or setup script.
deadline=$(( $(date +%s) + 600 ))
until [[ -f "$env_file" ]]; do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    wait "$server_pid" && rc=0 || rc=$?
    server_pid=""
    echo "minio_test: MinIO server exited (status $rc) before it was ready; see [minio] lines above" >&2
    exit 1
  fi
  (( $(date +%s) < deadline )) || { echo "minio_test: timed out waiting for $env_file" >&2; exit 1; }
  sleep 0.1
done

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a
MINIO_TESTLIB="$(resolve "$LIB_SHORT")"
# `mc` on PATH is the env file's wrapper: this server's config dir (and CA).
PATH="$(dirname "$MC"):$PATH"
export MINIO_TESTLIB PATH

# Not exec: the trap must stop the server when the test ends. The test
# runs in the background (stdin kept) so the server can be watched: if it
# exits while the test runs (minio_stop leaves the launcher up), the test
# is stopped and fails with the server's status and log, instead of
# failing later on connection errors. Polling, not `wait -n`: bash 3.2.
inner="$(resolve "$INNER_SHORT")"
"$inner" "$@" 0<&0 &
test_pid=$!
while kill -0 "$test_pid" 2>/dev/null; do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    wait "$server_pid" && rc=0 || rc=$?
    server_pid=""
    stop_test
    {
      echo "minio_test: the MinIO server exited (status $rc) while the test was running; the test was stopped."
      if [[ -f "${MINIO_LOG:-}" ]]; then
        echo "minio_test: last lines of $MINIO_LOG:"
        tail -n 20 "$MINIO_LOG" | sed 's/^/  /'
      fi
    } >&2
    exit 1
  fi
  sleep 0.1
done
wait "$test_pid" && rc=0 || rc=$?
test_pid=""
exit "$rc"
