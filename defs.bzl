"""Public API for rules_minio.

Policies (build time):
  minio_policy         — IAM or bucket policy documents: unknown keys
                         refused (MinIO silently drops them), then MinIO
                         itself loads them, as a validation action.
  minio_lifecycle      — a bucket lifecycle configuration, checked the same way.
  minio_policy_test / minio_lifecycle_test — the same checks at test time,
                         expecting a given error (or none).

Hermetic server (test time):
  minio_server         — long-running MinIO with buckets, policies, users,
                         lifecycle rules, seed objects and event
                         notifications; writes $TEST_TMPDIR/<name>.env.
  minio_health_check   — pairs with minio_server for itest_service.
  minio_test           — sh_test macro: auto-launched server.

Cluster install:
  minio_image          — a docker-archive image of the pinned binaries.
  minio_install / minio_install_health_check — Deployment + Services,
                         provisioned with buckets, policies and users.
"""

load("//private:image.bzl", _minio_image = "minio_image")
load("//private:install.bzl",
     _minio_install = "minio_install",
     _minio_install_health_check = "minio_install_health_check")
load("//private:policy.bzl",
     _minio_lifecycle = "minio_lifecycle",
     _minio_lifecycle_test = "minio_lifecycle_test",
     _minio_policy = "minio_policy",
     _minio_policy_test = "minio_policy_test")
load("//private:providers.bzl",
     _MinioBinaryInfo = "MinioBinaryInfo",
     _MinioLifecycleInfo = "MinioLifecycleInfo",
     _MinioPolicyInfo = "MinioPolicyInfo")
load("//private:server.bzl",
     _MinioServerInfo = "MinioServerInfo",
     _minio_health_check = "minio_health_check",
     _minio_server = "minio_server")
load("//private:test.bzl", _minio_test = "minio_test")
load("//private:versions.bzl", _DEFAULT_IMAGE = "DEFAULT_IMAGE")

minio_policy = _minio_policy
minio_lifecycle = _minio_lifecycle
minio_policy_test = _minio_policy_test
minio_lifecycle_test = _minio_lifecycle_test
minio_server = _minio_server
minio_health_check = _minio_health_check
minio_test = _minio_test
minio_image = _minio_image
minio_install = _minio_install
minio_install_health_check = _minio_install_health_check
MinioBinaryInfo = _MinioBinaryInfo
MinioPolicyInfo = _MinioPolicyInfo
MinioLifecycleInfo = _MinioLifecycleInfo
MinioServerInfo = _MinioServerInfo
DEFAULT_IMAGE = _DEFAULT_IMAGE
