#!/usr/bin/env bash
# drives = 4: one erasure set of 4 drives, all online; objects are
# erasure-coded across them.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$MINIO_TESTLIB"
info=$(mc --json admin info minio)
python3 - "$info" <<'PY' || fail "admin info: $info"
import json, sys
s = json.loads(sys.argv[1])["info"]["servers"][0]
drives = s["drives"]
assert len(drives) == 4 and all(d["state"] == "ok" for d in drives), drives
PY
echo data > "$TEST_TMPDIR/f"
mc cp "$TEST_TMPDIR/f" minio/data/obj >/dev/null
n=$(find "$MINIO_DATA_DIR" -path '*/data/obj/xl.meta' | wc -l)
[[ "$n" == 4 ]] || fail "obj on $n drives, want 4"
echo "PASS: 4 drives online, the object on all 4"
