#!/usr/bin/env bash
# The pinned version agrees everywhere: DEFAULT_VERSION, the conda pins,
# the toolchain, MODULE.bazel's repos, the image tag, and the binary.
# Argv: <the toolchain's files...>
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
for f in "$@"; do
  case "$f" in */bin/minio) MINIO="$f" ;; */bin/mc) MC="$f" ;; esac
done
R="$TEST_SRCDIR/_main"
v=$(sed -n 's/^DEFAULT_VERSION = "\(.*\)"/\1/p' "$R/private/versions.bzl")
[[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || fail "DEFAULT_VERSION '$v'"
server=$(sed -n "s/^    \"$v\": (\"\([0-9.]*\)\", \"\([0-9.]*\)\"),/\1/p" "$R/private/conda_versions.bzl")
[[ -n "$server" ]] || fail "no RELEASES entry for $v"
u=${v//-/_}
grep -q "\"minio_${u}_linux_amd64\"" "$R/MODULE.bazel" || fail "MODULE.bazel doesn't use_repo minio_${u}_*"
[[ $(grep -c "version = \"$v\"" "$R/toolchain/BUILD.bazel") == 4 ]] || fail "toolchain/BUILD.bazel: not 4 toolchains at $v"
[[ $(grep -c "@minio_${u}_" "$R/image/BUILD.bazel") == 4 ]] || fail "image/BUILD.bazel not at $v"
# 2025.10.15.17.29.55 → RELEASE.2025-10-15T17-29-55Z
IFS=. read -r y mo d h mi s <<<"$server"
want="RELEASE.$y-$mo-${d}T$h-$mi-${s}Z"
got=$("$MINIO" --version | head -1)
[[ "$got" == "minio version $want "* ]] || fail "minio --version: '$got', want $want"
"$MC" --version >/dev/null || fail "mc --version"
echo "PASS: $v = $want everywhere"
