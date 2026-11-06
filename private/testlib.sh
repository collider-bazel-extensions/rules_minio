#!/usr/bin/env bash
# Helpers for minio_test scripts:  source "$MINIO_TESTLIB"
#
#   mc ARGS...                    the MinIO client; alias `minio` is the server
#                                 (on PATH; uses this server's CA under TLS)
#   minio_as USER ARGS...         mc as USER (one of `users`) instead of root
#   minio_wait EXPECTED ARGS...   wait until `mc ARGS` prints EXPECTED
#   minio_wait_object PATH        wait until mc can stat PATH (minio/bucket/key)
#   minio_wait_event EVENT KEY    wait for a notification: EVENT is a prefix
#                                 of the event name (s3:ObjectCreated), KEY the
#                                 object key; prints its JSON line
#   minio_events                  the notifications so far: "event bucket key"
#   minio_empty BUCKET...         remove every object (and version) in BUCKETs
#   minio_stop / minio_start      stop the server / start it again (below)
#
# The waits give up after $MINIO_WAIT_TIMEOUT seconds (default 30).

minio_as() {
  local user="$1" var secret
  shift
  var="MINIO_USER_$(printf '%s' "$user" | tr -c 'A-Za-z0-9' '_' | tr 'a-z' 'A-Z')_SECRET_KEY"
  secret="${!var:-}"
  if [[ -z "$secret" ]]; then
    echo "minio_as: no user $user (no \$$var)" >&2
    return 2
  fi
  MC_HOST_minio="${MINIO_ENDPOINT%%://*}://$user:$secret@${MINIO_ENDPOINT#*://}" mc "$@"
}

_minio_until() {  # _minio_until WHAT COMMAND...: retry COMMAND until it succeeds
  local what="$1" deadline=$(( $(date +%s) + ${MINIO_WAIT_TIMEOUT:-30} ))
  shift
  until "$@"; do
    if (( $(date +%s) >= deadline )); then
      echo "$what: gave up after ${MINIO_WAIT_TIMEOUT:-30}s" >&2
      return 1
    fi
    sleep 0.1
  done
}

minio_wait() {
  local want="$1"
  shift
  _minio_eq() { [[ "$(mc "$@" 2>&1)" == "$want" ]]; }
  _minio_until "minio_wait: \`mc $*\` never printed '$want' (last: '$(mc "$@" 2>&1 | head -c 300)')" _minio_eq "$@"
}

minio_wait_object() {
  _minio_until "minio_wait_object: $1 never appeared" mc stat "$1" >/dev/null 2>&1
}

_minio_event_line() {  # print the first record matching EVENT-prefix and KEY
  [[ -n "${MINIO_EVENTS_FILE:-}" ]] || { echo "minio_wait_event: the server has no \`events\`" >&2; return 2; }
  python3 - "$MINIO_EVENTS_FILE" "$1" "$2" <<'PY'
import json, sys
path, event, key = sys.argv[1:]
for line in open(path):
    try:
        r = json.loads(line)
    except ValueError:
        continue
    if (r.get("event") or "").startswith(event) and r.get("key") == key:
        print(line.strip())
        sys.exit(0)
sys.exit(1)
PY
}

minio_wait_event() {
  local event="$1" key="$2" line deadline=$(( $(date +%s) + ${MINIO_WAIT_TIMEOUT:-30} ))
  while :; do
    line="$(_minio_event_line "$event" "$key")" && { printf '%s\n' "$line"; return 0; }
    [[ $? -eq 2 ]] && return 2
    if (( $(date +%s) >= deadline )); then
      echo "minio_wait_event: no $event notification for $key after ${MINIO_WAIT_TIMEOUT:-30}s; got:" >&2
      minio_events | sed 's/^/  /' >&2
      return 1
    fi
    sleep 0.1
  done
}

minio_events() {
  [[ -n "${MINIO_EVENTS_FILE:-}" ]] || { echo "minio_events: the server has no \`events\`" >&2; return 2; }
  python3 -c '
import json, sys
for line in open(sys.argv[1]):
    r = json.loads(line)
    print(r["event"], r["bucket"], r["key"])
' "$MINIO_EVENTS_FILE"
}

minio_empty() {
  local b
  for b in "$@"; do
    # --versions: all versions and delete markers too (versioned buckets).
    mc rm --recursive --force --versions "minio/$b" >/dev/null 2>&1 || true
    mc rm --recursive --force "minio/$b" >/dev/null 2>&1 || true
  done
}

# minio_stop    stop the server (SIGTERM: MinIO finishes in-flight requests).
# minio_start   start it again on the same port, with the same drives (so
#               the same data), credentials and TLS; waits until it's ready.
minio_stop()  { _minio_control /stop; }
minio_start() { _minio_control /start; }

_minio_control() {  # _minio_control /stop|/start
  python3 - "$MINIO_CONTROL_URL$1" "minio_${1#/}" <<'PY'
import sys, urllib.error, urllib.request
url, helper = sys.argv[1:]
try:
    urllib.request.urlopen(urllib.request.Request(url, data=b"", method="POST"), timeout=300)
except urllib.error.HTTPError as e:
    sys.exit(f"{helper}: {e.code}: {e.read().decode().strip()}")
PY
}
