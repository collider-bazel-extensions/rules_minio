#!/usr/bin/env bash
# A restart that can't get its port back fails, naming the port, and the
# server can be started later; a port held only briefly is retried
# (5 attempts, 0.2 s apart) and the restart succeeds.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$MINIO_TESTLIB"

hold() {  # hold <port> <seconds>: listen on 127.0.0.1:<port> in the background
  local ready="$TEST_TMPDIR/held.$1.$2"
  rm -f "$ready"
  python3 -c '
import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen()
open(sys.argv[3], "w").close()
time.sleep(float(sys.argv[2]))
' "$1" "$2" "$ready" &
  holder=$!
  for _ in $(seq 1 100); do [[ -f "$ready" ]] && return; sleep 0.02; done
  fail "could not hold port $1"
}

port=$MINIO_PORT
echo v > "$TEST_TMPDIR/f"; mc cp "$TEST_TMPDIR/f" minio/data/k >/dev/null
minio_stop
hold "$port" 3
rc=0; out=$(minio_start 2>&1) || rc=$?
[[ "$rc" != 0 ]] || fail "restart succeeded while port $port was held"
grep -q "minio_start: 500: minio could not listen on its ports again after 5 attempts 0.2s apart: another process holds port $port (Address already in use)" <<<"$out" \
  || fail "cause not named: $out"
wait "$holder"
echo "ok: a port held throughout fails the restart, naming it"
minio_start
[[ "$(mc cat minio/data/k)" == v ]] || fail "not serving after the failed restart"
echo "ok: starts afterwards"
minio_stop
hold "$port" 0.3
minio_start || fail "restart failed although the port was released within the retry window"
wait "$holder"
[[ "$(mc cat minio/data/k)" == v ]] || fail "not serving after a retried restart"
echo "PASS: a port held for 0.3 s is retried"
