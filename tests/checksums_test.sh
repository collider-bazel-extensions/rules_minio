#!/usr/bin/env bash
# Fails when any conda pin in private/conda_versions.bzl lacks a 64-hex
# SHA-256, a pinned platform lacks minio-server / minio-client / openssl,
# or a Linux image loader is missing. No network.
set -euo pipefail
f="${TEST_SRCDIR}/_main/private/conda_versions.bzl"
urls=$(grep -cE '"url":' "$f" || true)
pinned=$(grep -cE '"sha256":[[:space:]]*"[0-9a-f]{64}"' "$f" || true)
count() { grep -cE "\"name\":[[:space:]]*\"$1\"" "$f" || true; }
platforms=$(grep -cE '^    \("[0-9-]+", "[a-z0-9_]+"\): \[' "$f" || true)
missing=$(grep -cE '^    \("[0-9-]+", "[a-z0-9_]+"\): "' "$f" || true)
echo "urls=$urls pinned=$pinned platforms=$platforms missing=$missing" \
     "minio-server=$(count minio-server) minio-client=$(count minio-client) openssl=$(count openssl)"
if [[ "$urls" -eq 0 || "$pinned" -ne "$urls" || $((platforms + missing)) -ne 4 \
      || "$(count minio-server)" -ne "$platforms" || "$(count minio-client)" -ne "$platforms" \
      || "$(count openssl)" -ne "$platforms" || "$(count 'sysroot_linux-64')" -ne 1 \
      || "$(count 'sysroot_linux-aarch64')" -ne 1 ]]; then
  echo "FAIL: every URL needs a 64-hex SHA-256; each of the 4 platforms a closure (minio-server," \
       "minio-client, openssl) or a MISSING entry; both Linux loaders pinned" \
       "(python3 tools/update_conda_versions.py --refresh ... > private/conda_versions.bzl)" >&2
  exit 1
fi
echo "PASS"
