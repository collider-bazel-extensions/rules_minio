"""Bzlmod extension. One `version` tag: fetches the conda-forge MinIO
packages for each supported platform (minio_<ver>_<plat>), and the glibc
loader for minio_image (minio_loader_<plat>, Linux only, fetched only
when an image is built).
"""

load("//private:repositories.bzl", "minio_binary_repo", "minio_loader_repo")
load("//private:conda_versions.bzl", "RELEASES")
load("//private:versions.bzl", "DEFAULT_VERSION", "PLATFORMS")

_version_tag = tag_class(attrs = {
    "version": attr.string(mandatory = True),  # e.g. "2025-10-15"
})

def _impl(mctx):
    # Only honor `version` tags from the root module: the same is_root
    # guard as rules_valkey / rules_prometheus. Without it, rules_minio's
    # own MODULE.bazel and the consumer would each emit
    # `@minio_<ver>_<plat>` repos and Bazel would collide them. With no
    # root tag, the pinned default is used, so the tag is optional.
    versions = []
    for mod in mctx.modules:
        if mod.is_root:
            versions += [tag.version for tag in mod.tags.version]
    for v in versions or [DEFAULT_VERSION]:
        if v not in RELEASES:
            fail("rules_minio: unknown MinIO version {}. Known: {}".format(repr(v), sorted(RELEASES.keys())))
        for plat in PLATFORMS.keys():
            minio_binary_repo(
                name = "minio_{}_{}".format(v.replace("-", "_"), plat),
                version = v,
                platform = plat,
            )
    for plat in ("linux_amd64", "linux_arm64"):
        minio_loader_repo(name = "minio_loader_" + plat, platform = plat)

minio = module_extension(
    implementation = _impl,
    tag_classes = {"version": _version_tag},
)
