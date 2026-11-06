"""Supported platforms and the default MinIO version. The binary pins
themselves are the conda-forge packages in conda_versions.bzl
(tools/update_conda_versions.py)."""

DEFAULT_VERSION = "2025-10-15"

PLATFORMS = {
    "linux_amd64":  ["@platforms//os:linux", "@platforms//cpu:x86_64"],
    "linux_arm64":  ["@platforms//os:linux", "@platforms//cpu:arm64"],
    "darwin_amd64": ["@platforms//os:osx",   "@platforms//cpu:x86_64"],
    "darwin_arm64": ["@platforms//os:osx",   "@platforms//cpu:arm64"],
}

# The image minio_image tags and minio_install runs by default
# (`kind load` it, or push it and set minio_install(image = ...)).
DEFAULT_IMAGE = "rules-minio/minio:" + DEFAULT_VERSION
