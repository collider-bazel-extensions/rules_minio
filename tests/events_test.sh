#!/usr/bin/env bash
# Bucket notifications reach MINIO_EVENTS_FILE: puts and deletes on
# `data`, not gets (not subscribed) nor other buckets, nor the seed.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$MINIO_TESTLIB"

[[ -f "$MINIO_EVENTS_FILE" ]] || fail "no MINIO_EVENTS_FILE"
[[ ! -s "$MINIO_EVENTS_FILE" ]] || fail "seeding sent events: $(cat "$MINIO_EVENTS_FILE")"
echo hi > "$TEST_TMPDIR/f"
mc cp "$TEST_TMPDIR/f" "minio/data/in/a file.txt" >/dev/null
line=$(minio_wait_event s3:ObjectCreated "in/a file.txt") || fail "no put event"
python3 -c 'import json,sys; r=json.loads(sys.argv[1]); assert r["bucket"]=="data" and r["size"]==3 and r["record"]["awsRegion"]=="us-east-1", r' "$line" \
  || fail "event fields: $line"
mc cat "minio/data/in/a file.txt" >/dev/null
mc cp "$TEST_TMPDIR/f" minio/other/b >/dev/null
mc rm "minio/data/in/a file.txt" >/dev/null
minio_wait_event s3:ObjectRemoved "in/a file.txt" >/dev/null || fail "no delete event"
sleep 1
got=$(minio_events)
[[ "$got" == "s3:ObjectCreated:Put data in/a file.txt"$'\n'"s3:ObjectRemoved:Delete data in/a file.txt" ]] \
  || fail "events: $got"
echo "ok: put + delete on data recorded (key decoded); no get, no other bucket, no seed"
rc=0; MINIO_WAIT_TIMEOUT=1 minio_wait_event s3:ObjectCreated nothing 2>"$TEST_TMPDIR/err" || rc=$?
[[ "$rc" == 1 ]] && grep -q "no s3:ObjectCreated notification for nothing after 1s; got:" "$TEST_TMPDIR/err" \
  || fail "minio_wait_event timeout: $rc $(cat "$TEST_TMPDIR/err")"
echo "PASS"
