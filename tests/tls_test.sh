#!/usr/bin/env bash
# tls = True: https only (plain HTTP refused), mc and a Python client
# with MINIO_TLS_CA; restart keeps TLS.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$MINIO_TESTLIB"

[[ "$MINIO_TLS" == 1 && "$MINIO_ENDPOINT" == https://127.0.0.1:* && -f "$MINIO_TLS_CA" ]] || fail "env"
[[ "$AWS_CA_BUNDLE" == "$MINIO_TLS_CA" && "$MINIO_CONSOLE_URL" == https://* ]] || fail "AWS_CA_BUNDLE / console"
[[ "$(mc cat minio/data/seed/hello.txt)" == "hello from the seed" ]] || fail "mc over TLS"
python3 - "$MINIO_ENDPOINT" "$MINIO_TLS_CA" "$1" <<'PY' || fail "TLS client"
import ssl, sys, urllib.error, urllib.request
ep, ca, mode = sys.argv[1:]
ctx = ssl.create_default_context(cafile=ca)
assert urllib.request.urlopen(ep + "/minio/health/ready", context=ctx).status == 200
cert = ctx.wrap_socket(__import__("socket").create_connection(ep[8:].split(":")), server_hostname="127.0.0.1").getpeercert()
cn = dict(x[0] for x in cert["subject"])["commonName"]
assert cn == ("rules_minio server" if mode == "generated" else "provided server"), cn
# Plain HTTP gets Go's refusal, never MinIO.
try:
    urllib.request.urlopen("http" + ep[5:] + "/minio/health/ready", timeout=5)
    raise SystemExit("plain HTTP answered")
except urllib.error.HTTPError as e:
    body = e.read().decode()
    assert e.code == 400 and "HTTP request to an HTTPS server" in body, (e.code, body)
PY
echo "ok: TLS only ($1 certificate)"
minio_stop
minio_start
[[ "$(mc cat minio/data/seed/hello.txt)" == "hello from the seed" ]] || fail "after restart"
echo "PASS"
