"""minio_image — a container image of the pinned MinIO, as a
docker-archive tarball (`<name>.tar`).

MinIO's own images are no longer published for pulling, so the cluster
install runs this one: the same conda-forge minio and mc as the tests,
plus the glibc dynamic loader (see private/image.py). No base image and
no registry: hand the tarball to `kind_cluster(images = [...])`, or
`docker load` / `podman load` it and push it to your registry.
"""

load(":versions.bzl", "DEFAULT_IMAGE")

def _minio_image_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".tar")
    args = ctx.actions.args()
    args.add(ctx.file._builder)
    args.add("--arch", ctx.attr.arch)
    args.add("--tag", ctx.attr.tag)
    args.add("--minio", ctx.file.minio)
    args.add("--mc", ctx.file.mc)
    args.add("--loader", ctx.file.loader)
    args.add("--loader-dest", ctx.attr.loader_dest)
    args.add(out)
    ctx.actions.run_shell(
        command = 'exec python3 "$@"',
        arguments = [args],
        inputs = [ctx.file._builder, ctx.file.minio, ctx.file.mc, ctx.file.loader],
        outputs = [out],
        use_default_shell_env = True,
        mnemonic = "MinioImage",
        progress_message = "Writing MinIO image %{label} (" + ctx.attr.tag + ")",
    )
    return [DefaultInfo(files = depset([out]))]

minio_image = rule(
    implementation = _minio_image_impl,
    doc = "A docker-archive tarball of MinIO for one Linux platform.",
    attrs = {
        "minio": attr.label(mandatory = True, allow_single_file = True, doc = "The minio binary."),
        "mc": attr.label(mandatory = True, allow_single_file = True, doc = "The mc binary."),
        "loader": attr.label(mandatory = True, allow_single_file = True, doc = "The glibc dynamic loader."),
        "loader_dest": attr.string(mandatory = True, doc = "Where the binaries look for it, e.g. lib64/ld-linux-x86-64.so.2."),
        "arch": attr.string(mandatory = True, values = ["amd64", "arm64"]),
        "tag": attr.string(default = DEFAULT_IMAGE, doc = "The image reference in the archive."),
        "_builder": attr.label(default = "//private:image.py", allow_single_file = True),
    },
)
