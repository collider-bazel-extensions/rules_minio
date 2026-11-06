"""minio_toolchain — exposes the platform-resolved MinIO binaries as a
`ToolchainInfo`, so rules resolve them via
`ctx.toolchains["@rules_minio//toolchain:minio"]`.

`current_minio_toolchain` forwards them as a plain target (files +
runfiles) for `data = [...]` use in tests.
"""

load("//private:providers.bzl", "MinioBinaryInfo")

MINIO_TOOLCHAIN_TYPE = Label("//toolchain:minio")

def _toolchain_impl(ctx):
    files = depset(
        [ctx.file.server, ctx.file.mc, ctx.file.openssl],
        transitive = [ctx.attr.libs[DefaultInfo].files],
    )
    info = MinioBinaryInfo(
        version = ctx.attr.version,
        server  = ctx.file.server,
        mc      = ctx.file.mc,
        openssl = ctx.file.openssl,
        files   = files,
    )
    return [
        platform_common.ToolchainInfo(minio = info),
        DefaultInfo(files = files, runfiles = ctx.runfiles(transitive_files = files)),
    ]

minio_toolchain = rule(
    implementation = _toolchain_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "server":  attr.label(allow_single_file = True, mandatory = True),
        "mc":      attr.label(allow_single_file = True, mandatory = True),
        "openssl": attr.label(allow_single_file = True, mandatory = True),
        "libs":    attr.label(mandatory = True),
    },
)

def _current_impl(ctx):
    info = ctx.toolchains[MINIO_TOOLCHAIN_TYPE].minio
    return [
        info,
        DefaultInfo(files = info.files, runfiles = ctx.runfiles(transitive_files = info.files)),
    ]

current_minio_toolchain = rule(
    implementation = _current_impl,
    toolchains = [MINIO_TOOLCHAIN_TYPE],
    doc = "The resolved MinIO binaries and their libraries, as files and runfiles.",
)
