#!/usr/bin/env bash
# minio_test end to end: env, buckets (versioned, object lock), IAM
# policies and users, a bucket policy, lifecycle rules, seed objects,
# the mc alias, an S3 client from the env alone, and the test's args.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$MINIO_TESTLIB"

[[ "$#" == 2 && "$1" == one && "$2" == "two words" ]] || fail "args: $*"
[[ "$MINIO_ENDPOINT" == "http://127.0.0.1:$MINIO_PORT" ]] || fail "endpoint $MINIO_ENDPOINT"
[[ "$AWS_ENDPOINT_URL" == "$MINIO_ENDPOINT" && "$AWS_ENDPOINT_URL_S3" == "$MINIO_ENDPOINT" ]] || fail "AWS_ENDPOINT_URL"
[[ "$AWS_ACCESS_KEY_ID" == minioadmin && "$AWS_SECRET_ACCESS_KEY" == minioadmin ]] || fail "AWS keys"
[[ "$AWS_REGION" == eu-west-2 && "$MINIO_REGION" == eu-west-2 ]] || fail "region"
[[ "$(command -v mc)" == "$MC" ]] || fail "mc on PATH is $(command -v mc), not $MC"
echo "ok: env"

[[ "$(mc ls minio/ | awk '{print $NF}' | tr '\n' ' ')" == "data/ downloads/ logs/ uploads/ vault/ " ]] \
  || fail "buckets: $(mc ls minio/)"
mc version info minio/logs | grep -q "versioning is enabled" || fail "logs not versioned"
mc version info minio/vault | grep -q "versioning is enabled" || fail "vault (object lock) not versioned"
mc version info minio/data | grep -q "versioning is enabled" && fail "data versioned"
# (mc's text output says "not enabled" when no default mode is set.)
mc --json retention info --default minio/vault | grep -q '"enabled":"Enabled"' \
  || fail "vault has no object lock: $(mc --json retention info --default minio/vault)"
mc --json retention info --default minio/data | grep -q '"enabled":"Enabled"' && fail "data has object lock"
echo "ok: buckets, versioning, object lock"

[[ "$(mc cat minio/data/seed/hello.txt)" == "hello from the seed" ]] || fail "seed hello.txt"
[[ "$(mc cat minio/data/fixtures/seed/nested/user.json)" == '{"id": 1, "name": "ada"}' ]] || fail "seed nested/user.json (path kept)"
[[ "$(mc cat minio/data/fixtures/seed/hello.txt)" == "hello from the seed" ]] || fail "seed under prefix"
echo "ok: seed objects at their package-relative paths"

mc admin policy info minio read_data >/dev/null || fail "policy read_data missing"
[[ "$MINIO_USER_ALICE_ACCESS_KEY" == alice && -n "$MINIO_USER_ALICE_SECRET_KEY" ]] || fail "alice keys"
[[ "$(minio_as alice cat minio/data/seed/hello.txt)" == "hello from the seed" ]] || fail "alice can't read data"
echo x > "$TEST_TMPDIR/x"
if minio_as alice cp "$TEST_TMPDIR/x" minio/data/x 2>/dev/null; then fail "alice wrote to data"; fi
minio_as alice ls minio/logs 2>/dev/null && fail "alice listed logs"
minio_as bob_ops cp "$TEST_TMPDIR/x" minio/uploads/incoming/x >/dev/null || fail "bob_ops can't upload"
minio_as bob_ops cp "$TEST_TMPDIR/x" minio/uploads/elsewhere 2>/dev/null && fail "bob_ops wrote outside incoming/"
echo "ok: users get exactly their policies"

mc cp "$TEST_TMPDIR/x" minio/downloads/file.txt >/dev/null
python3 - "$MINIO_ENDPOINT" <<'PY' || fail "anonymous access"
import sys, urllib.error, urllib.request
e = sys.argv[1]
assert urllib.request.urlopen(e + "/downloads/file.txt").read() == b"x\n"
try:
    urllib.request.urlopen(e + "/data/seed/hello.txt")
    raise SystemExit("anonymous read of data allowed")
except urllib.error.HTTPError as err:
    assert err.code == 403, err.code
PY
echo "ok: bucket policy: anonymous reads of downloads only"

rules=$(mc --json ilm rule ls minio/logs | python3 -c 'import json,sys; print(" ".join(sorted(r["ID"] for r in json.load(sys.stdin)["config"]["Rules"])))')
[[ "$rules" == "expire-tmp old-versions" ]] || fail "lifecycle rules on logs: '$rules' (the transition must be left out)"
echo "ok: lifecycle rules applied, transition left out"

python3 - <<'PY' || fail "S3 client from env"
import hashlib, hmac, datetime, os, urllib.request
# A SigV4 ListBuckets with only the standard AWS_* variables.
ep, key, secret, region = (os.environ[k] for k in
    ("AWS_ENDPOINT_URL", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_REGION"))
host = ep.split("://", 1)[1]
now = datetime.datetime.now(datetime.timezone.utc)
amz, day = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
h = hashlib.sha256(b"").hexdigest()
canon = f"GET\n/\n\nhost:{host}\nx-amz-content-sha256:{h}\nx-amz-date:{amz}\n\nhost;x-amz-content-sha256;x-amz-date\n{h}"
scope = f"{day}/{region}/s3/aws4_request"
sts = f"AWS4-HMAC-SHA256\n{amz}\n{scope}\n{hashlib.sha256(canon.encode()).hexdigest()}"
k = ("AWS4" + secret).encode()
for part in (day, region, "s3", "aws4_request"):
    k = hmac.new(k, part.encode(), hashlib.sha256).digest()
sig = hmac.new(k, sts.encode(), hashlib.sha256).hexdigest()
req = urllib.request.Request(ep + "/", headers={
    "x-amz-date": amz, "x-amz-content-sha256": h,
    "Authorization": f"AWS4-HMAC-SHA256 Credential={key}/{scope}, "
                     f"SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature={sig}"})
body = urllib.request.urlopen(req).read().decode()
assert "<Name>data</Name>" in body, body
PY
echo "ok: a SigV4 client works from AWS_* alone"

minio_wait_object minio/data/seed/hello.txt
(sleep 1; mc cp "$TEST_TMPDIR/x" minio/data/later >/dev/null) &
minio_wait_object minio/data/later || fail "minio_wait_object"
minio_wait "x" cat minio/data/later || fail "minio_wait"
minio_empty logs data
[[ -z "$(mc ls --recursive --versions minio/logs)" ]] || fail "minio_empty left versions in logs"
[[ -z "$(mc ls --recursive minio/data)" ]] || fail "minio_empty left objects in data"
echo "ok: helpers"
echo "PASS"
