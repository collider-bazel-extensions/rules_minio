"""Per-platform MinIO repo: the pinned conda-forge packages for minio
(server), mc (client) and openssl (TLS test certificates), merged into
one tree.

Each `.conda` file is a zip holding `pkg-<name>.tar.zst` (the files) and
`info-<name>.tar.zst` (metadata). Bazel extracts both formats itself, so
no host unzip or zstd is needed. minio and mc are Go binaries with no
library dependencies; openssl finds the merged lib/ through its
RPATH=$ORIGIN/../lib.

A platform with no conda-forge build of the version (MISSING) gets a repo
whose targets fail with that message when built, instead of a fetch
error or a "no matching toolchain" one.

`minio_loader_repo` is the glibc dynamic loader for minio_image, from
conda-forge's sysroot package: the binaries are PIE executables with no
DT_NEEDED entries, so the loader is all they need from libc.
"""

load(":conda_versions.bzl", "CONDA_CLOSURES", "IMAGE_LOADERS", "MISSING")

_BUILD = """\
package(default_visibility = ["//visibility:public"])

filegroup(name = "minio", srcs = ["bin/minio"])

filegroup(name = "mc", srcs = ["bin/mc"])

# The closure's OpenSSL CLI: minio_server(tls = True) makes its test
# certificates with it.
filegroup(name = "openssl", srcs = ["bin/openssl"])

# Shared libraries openssl loads through its RPATH.
filegroup(name = "libs", srcs = glob(["lib/**"], allow_empty = True))
"""

_MISSING_BUILD = """\
package(default_visibility = ["//visibility:public"])

# conda-forge has no {what} build for {platform}: every target here fails
# when built, with this message.
[genrule(
    name = n,
    outs = [n + ".unavailable"],
    cmd = "echo 'rules_minio: MinIO {version} is not available for {platform}: conda-forge has no {what} build for it.' >&2; exit 1",
) for n in ["minio", "mc", "openssl", "libs"]]
"""

def _extract_conda(rctx, url, sha256, tmp):
    rctx.download_and_extract(url = url, sha256 = sha256, output = tmp, type = "zip")
    inner = [p for p in rctx.path(tmp).readdir() if p.basename.startswith("pkg-")]
    if len(inner) != 1:
        fail("rules_minio: {} has no pkg-*.tar.zst".format(url))
    return inner[0]

def _impl(rctx):
    key = (rctx.attr.version, rctx.attr.platform)
    if key in MISSING:
        rctx.file("BUILD.bazel", _MISSING_BUILD.format(
            version = rctx.attr.version, platform = rctx.attr.platform, what = MISSING[key]))
        return
    closure = CONDA_CLOSURES.get(key)
    if not closure:
        fail("rules_minio: no conda pins for MinIO {} on {}. Known: {}".format(
            rctx.attr.version, rctx.attr.platform, sorted(CONDA_CLOSURES.keys())))
    for i, pkg in enumerate(closure):
        inner = _extract_conda(rctx, pkg["url"], pkg["sha256"], "_dl/{}_{}".format(i, pkg["name"]))
        rctx.extract(inner, output = ".")
    rctx.delete("_dl")
    for b in ("minio", "mc", "openssl"):
        if not rctx.path("bin/" + b).exists:
            fail("rules_minio: bin/{} missing from the conda packages".format(b))
    rctx.file("BUILD.bazel", _BUILD)

minio_binary_repo = repository_rule(
    implementation = _impl,
    attrs = {
        "version":  attr.string(mandatory = True),
        "platform": attr.string(mandatory = True),
    },
)

_LOADER_BUILD = """\
package(default_visibility = ["//visibility:public"])

# The glibc dynamic loader, installed in minio_image at /{dest}.
filegroup(name = "loader", srcs = ["ld.so"])
"""

def _loader_impl(rctx):
    pin = IMAGE_LOADERS[rctx.attr.platform]
    inner = _extract_conda(rctx, pin["url"], pin["sha256"], "_dl")
    rctx.extract(inner, output = "_sysroot")
    src = rctx.path("_sysroot/" + pin["member"])
    if not src.exists:
        fail("rules_minio: {} has no {}".format(pin["url"], pin["member"]))
    rctx.file("ld.so", rctx.read(src), executable = True)
    rctx.delete("_dl")
    rctx.delete("_sysroot")
    rctx.file("BUILD.bazel", _LOADER_BUILD.format(dest = pin["dest"]))

minio_loader_repo = repository_rule(
    implementation = _loader_impl,
    attrs = {"platform": attr.string(mandatory = True)},
)
