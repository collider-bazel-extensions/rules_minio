#!/usr/bin/env bash
# minio_server run directly (as rules_itest would): env file, extra_args
# and server_env applied, root credentials as given, the caller's MinIO /
# mc / AWS settings ignored, SIGTERM.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

SERVER="$TEST_SRCDIR/_main/$1"
env_file="$TEST_TMPDIR/test_server.env"
rm -f "$env_file"
MINIO_ROOT_PASSWORD=wrong-password MC_HOST_minio=http://x:y@127.0.0.1:1 AWS_ACCESS_KEY_ID=wrong \
  MINIO_VOLUMES=/nonexistent "$SERVER" &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 300); do [[ -f "$env_file" ]] && break; sleep 0.1; done
[[ -f "$env_file" ]] || fail "env file not written"
set -a; source "$env_file"; set +a
[[ "$MINIO_ROOT_USER" == app-admin && "$MINIO_ROOT_PASSWORD" == "app-secret-123" ]] || fail "root credentials"
[[ "$AWS_ACCESS_KEY_ID" == app-admin ]] || fail "AWS_ACCESS_KEY_ID"
"$MC" ls minio/data >/dev/null || fail "mc with the env file's alias"
# server_env: MINIO_API_REQUESTS_MAX; extra_args: --quiet.
"$MC" admin config get minio api | grep -q '^# MINIO_API_REQUESTS_MAX=7$' || fail "server_env not applied: $("$MC" admin config get minio api)"
grep -q -- "--quiet" <<<"$(tr '\0' ' ' < /proc/$(pgrep -P "$pid" -x minio)/cmdline 2>/dev/null || ps -o args= -p "$(pgrep -P "$pid" -x minio)")" \
  || fail "extra_args not passed"
echo "ok: configured server"

kill -TERM "$pid"
rc=0; wait "$pid" || rc=$?
trap - EXIT
[[ "$rc" == 0 ]] || fail "SIGTERM exit status $rc"
[[ ! -f "$env_file" ]] || fail "env file left after SIGTERM"
if (exec 3<>"/dev/tcp/127.0.0.1/$MINIO_PORT") 2>/dev/null; then fail "port still open"; fi
echo "PASS: SIGTERM stops minio, exit 0, env file removed"
