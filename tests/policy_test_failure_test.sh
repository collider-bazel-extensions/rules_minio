#!/usr/bin/env bash
# minio_policy_test fails when its expectation doesn't hold: an error that
# doesn't match, a refusal with no expect_error, a pass with one.
# Argv: <wrong_message> <unexpected_refusal> <unexpected_pass>
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
run() {  # run <test> → $out; the test must exit 1
  local rc=0
  out=$("$TEST_SRCDIR/_main/$1" 2>&1) || rc=$?
  [[ "$rc" == 1 ]] || fail "$1: exit $rc, want 1. Output: $out"
}
run "$1"
grep -q "FAIL: the error does not match: Conditon" <<<"$out" || fail "wrong_message: $out"
grep -q "Resorce: unknown field" <<<"$out" || fail "wrong_message: the check's output not shown: $out"
run "$2"
grep -q "FAIL: the check refused typo_resource.json" <<<"$out" || fail "unexpected_refusal: $out"
run "$3"
grep -q "FAIL: the check accepted read_data.json; expected an error matching: unknown field" <<<"$out" \
  || fail "unexpected_pass: $out"
echo "PASS"
