#!/usr/bin/env bash
# The validation action (launcher.py check), run directly: good documents
# pass; each bad one fails naming the file and the problem: unknown keys
# (MinIO would drop them), then MinIO's own errors.
#
# Argv: <launcher.py> <the toolchain's files...>
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
L="$1"; shift
for f in "$@"; do
  case "$f" in */bin/minio) MINIO="$f" ;; */bin/mc) MC="$f" ;; esac
done
D=tests/testdata

check() {  # check <type> FILE... → $out, $rc
  rc=0
  out=$(python3 "$L" check --minio "$MINIO" --mc "$MC" --type "$1" --label //t:t \
        --marker "$TEST_TMPDIR/m" "${@:2}" 2>&1) || rc=$?
}
want() {  # want <regex>: in the last output
  grep -qE -- "$1" <<<"$out" || fail "no '$1' in: $out"
}

check iam $D/policies/read_data.json $D/policies/write_uploads.json
[[ "$rc" == 0 ]] || fail "good IAM policies: $out"
check bucket $D/bucket_policies/public_downloads.json
[[ "$rc" == 0 ]] || fail "good bucket policy: $out"
check lifecycle $D/lifecycle/expire_tmp.json
[[ "$rc" == 0 ]] || fail "good lifecycle (with a transition): $out"
echo "ok: good documents pass"

check iam $D/bad/typo_condition.json $D/bad/unknown_action.json $D/bad/bad_resource.json $D/bad/not_json.json
[[ "$rc" == 1 ]] || fail "bad IAM policies: status $rc"
want "^minio_policy //t:t:$"
want "  $D/bad/typo_condition.json: Statement\[0\]\.Conditon: unknown field \(did you mean 'Condition'\?\); MinIO would ignore it"
want "  $D/bad/unknown_action.json: MinIO refused it: unsupported action 's3:GetObjects'"
want "  $D/bad/bad_resource.json: MinIO refused it: invalid resource 'data/\*'"
want "  $D/bad/not_json.json: not valid JSON: .*line 4"
echo "ok: IAM: unknown key (with suggestion), MinIO's errors, JSON errors; every file named"

check bucket $D/bad/no_principal.json $D/bad/two_buckets.json
[[ "$rc" == 1 ]] || fail "bad bucket policies: status $rc"
want "$D/bad/no_principal.json: MinIO refused it: invalid Principal"
want "$D/bad/two_buckets.json: a bucket policy's Resource must name one bucket .*downloads.*data"
echo "ok: bucket policies"

check lifecycle $D/bad/lifecycle_typo.json $D/bad/lifecycle_status.json
[[ "$rc" == 1 ]] || fail "bad lifecycle: status $rc"
want "^minio_lifecycle //t:t:$"
want "$D/bad/lifecycle_typo.json: Rules\[0\]\.Expiraton: unknown field \(did you mean 'Expiration'\?\)"
want "$D/bad/lifecycle_status.json: MinIO refused it: Status must be set to either Enabled or Disabled"
echo "ok: lifecycle"
[[ -z "$(pgrep -x minio -P $$ || true)" ]] || fail "a check left minio running"
echo "PASS"
