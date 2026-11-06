#!/usr/bin/env bash
# Full E2E install smoke for minio_install in namespace `storage`:
#
#   1. The itest chain (kind with the image loaded → minio_install) has
#      rolled out deploy/minio and provisioned it.
#   2. In the pod (kubectl exec mc): buckets, versioning, object lock,
#      lifecycle rules, the IAM policy; alice reads data but can't write.
#   3. Through the Service from other pods (the same image's mc): alice
#      with her key from the Secret `minio-users`; anonymous reads of
#      `downloads` only (the bucket policy).
#   4. A second install keeps the root and user credentials and the data.
set -euo pipefail

env_file="$TEST_TMPDIR/cluster.env"
[[ -f "$env_file" ]] || { echo "missing kind env file" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

KCTL=("$KUBECTL" --kubeconfig="$KUBECONFIG")
NS=storage
fail() {
  echo "smoke: FAIL — $*" >&2
  "${KCTL[@]}" -n "$NS" get pods,svc,cm,secret -o wide >&2 || true
  "${KCTL[@]}" -n "$NS" logs deploy/minio --tail=100 >&2 || true
  exit 1
}
MC=("${KCTL[@]}" -n "$NS" exec -i deploy/minio -c minio -- /usr/bin/mc --config-dir /tmp/.mc)
secret() { "${KCTL[@]}" -n "$NS" get secret "$1" -o "jsonpath={.data.$2}" | base64 -d; }
image=$("${KCTL[@]}" -n "$NS" get deploy minio -o jsonpath='{.spec.template.spec.containers[0].image}')
[[ "$image" == rules-minio/minio:2025-10-15 ]] || fail "image $image"
client() {  # client NAME MC_HOST_s ARGS...: mc in a pod of its own, via the Service
  local name="$1" host="$2"
  shift 2
  "${KCTL[@]}" -n "$NS" run "$name" --rm -i --restart=Never --quiet --image="$image" \
    --env="MC_HOST_s=$host" --env=HOME=/tmp --command -- /usr/bin/mc --config-dir /tmp/.mc "$@"
}

[[ "$("${MC[@]}" ls local/ | awk '{print $NF}' | tr '\n' ' ')" == "data/ downloads/ vault/ " ]] \
  || fail "buckets: $("${MC[@]}" ls local/)"
"${MC[@]}" version info local/data | grep -q "versioning is enabled" || fail "data not versioned"
"${MC[@]}" --json retention info --default local/vault | grep -q '"enabled":"Enabled"' || fail "vault: no object lock"
rules=$("${MC[@]}" --json ilm rule ls local/data | python3 -c 'import json,sys; print(" ".join(sorted(r["ID"] for r in json.load(sys.stdin)["config"]["Rules"])))')
[[ "$rules" == "expire-tmp old-versions" ]] || fail "lifecycle: $rules"
"${MC[@]}" admin policy info local read_data >/dev/null || fail "no read_data policy"
echo "smoke: buckets, versioning, object lock, lifecycle and policy provisioned"

# The client pods resolve minio.storage.svc: a fresh kind cluster's
# CoreDNS may not be serving yet.
"${KCTL[@]}" -n kube-system rollout status deploy/coredns --timeout=180s >/dev/null || fail "CoreDNS not ready"

echo "hello from the smoke test" | "${MC[@]}" pipe local/data/greeting.txt >/dev/null || fail "write"
echo "public" | "${MC[@]}" pipe local/downloads/file.txt >/dev/null || fail "write downloads"
alice=$(secret minio-users alice)
[[ ${#alice} == 32 ]] || fail "alice's key in minio-users: '${alice}'"
host="http://minio.$NS.svc:9000"
got=$(client alice-read "http://alice:$alice@minio.$NS.svc:9000" cat s/data/greeting.txt) || fail "alice read: $got"
[[ "$got" == "hello from the smoke test" ]] || fail "alice read: '$got'"
if client alice-write "http://alice:$alice@minio.$NS.svc:9000" cp /etc/passwd s/data/x >/dev/null 2>&1; then
  fail "alice could write to data"
fi
echo "smoke: alice (read_data) reads through the Service, can't write"
got=$(client anon-read "$host" cat s/downloads/file.txt) || fail "anonymous read: $got"
[[ "$got" == public ]] || fail "anonymous read: '$got'"
if client anon-data "$host" cat s/data/greeting.txt >/dev/null 2>&1; then fail "anonymous read of data"; fi
echo "smoke: the bucket policy gives anonymous reads of downloads only"

root=$(secret minio rootPassword)
# Run the install again (it runs until SIGTERM once done).
# (service_test doesn't pass the test's args: the runfiles path, as the wrappers.)
install="${TEST_SRCDIR:-${RUNFILES_DIR:-$0.runfiles}}/_main/tests/install_smoke/minio_install_bin.sh"
[[ -x "$install" ]] || fail "minio_install_bin not at $install"
"$install" > "$TEST_TMPDIR/reinstall.log" 2>&1 &
again=$!
for _ in $(seq 1 120); do
  grep -q "installed and provisioned" "$TEST_TMPDIR/reinstall.log" && break
  kill -0 "$again" 2>/dev/null || { cat "$TEST_TMPDIR/reinstall.log" >&2; fail "second install exited"; }
  sleep 1
done
kill -TERM "$again"; wait "$again" || true
grep -q "installed and provisioned" "$TEST_TMPDIR/reinstall.log" || { cat "$TEST_TMPDIR/reinstall.log" >&2; fail "second install"; }
[[ "$(secret minio rootPassword)" == "$root" ]] || fail "root password changed"
[[ "$(secret minio-users alice)" == "$alice" ]] || fail "alice's key changed"
[[ "$("${MC[@]}" cat local/data/greeting.txt)" == "hello from the smoke test" ]] || fail "data lost"
"${KCTL[@]}" -n "$NS" get configmap minio-provisioned >/dev/null || fail "no minio-provisioned after the second install"
echo "smoke: OK — a second install keeps credentials and data"
