"""minio_policy + minio_lifecycle — policy documents and lifecycle
configurations checked at build time.

MinIO's parsers ignore keys they don't know, so a typo silently changes a
document's meaning: a misspelled `Conditon` drops the condition and the
policy grants more than written. The validation action (launcher.py
check) refuses unknown keys, suggesting the closest known one, then has a
throwaway MinIO load every document, so MinIO's own errors fail the
build:

    minio_policy //policies:app:
      policies/app.json: MinIO refused it: unsupported action 's3:GetObjects'
"""

load(":providers.bzl", "MinioLifecycleInfo", "MinioPolicyInfo")

_TOOLCHAIN = "//toolchain:minio"

def label_text(label):
    """//pkg:name, or @repo//pkg:name outside the main repo."""
    repo = "@" + label.repo_name if label.repo_name else ""
    return "{}//{}:{}".format(repo, label.package, label.name)

def _check(ctx, kind, files):
    mn = ctx.toolchains[_TOOLCHAIN].minio
    marker = ctx.actions.declare_file(ctx.label.name + ".checked")
    args = ctx.actions.args()
    args.add(ctx.file._launcher)
    args.add("check")
    args.add("--minio", mn.server)
    args.add("--mc", mn.mc)
    args.add("--type", kind)
    args.add("--label", label_text(ctx.label))
    args.add("--marker", marker)
    args.add_all(files)
    ctx.actions.run_shell(
        command = 'exec python3 "$@"',
        arguments = [args],
        inputs = depset(files + [ctx.file._launcher], transitive = [mn.files]),
        outputs = [marker],
        # python3 from the user's PATH, as for the test-time launcher.
        use_default_shell_env = True,
        mnemonic = "MinioCheck",
        progress_message = "Checking MinIO {} %{{label}}".format(
            "lifecycle rules" if kind == "lifecycle" else kind + " policies"),
    )
    return marker

def policy_name(f):
    """A policy's name: its file's basename without `.json`."""
    return f.basename[:-len(".json")] if f.basename.endswith(".json") else f.basename

def _minio_policy_impl(ctx):
    if ctx.attr.type not in ("iam", "bucket"):
        fail("{}: type = {}: want \"iam\" or \"bucket\".".format(ctx.label, repr(ctx.attr.type)))
    policies = {}
    for f in ctx.files.srcs:
        name = policy_name(f)
        if name in policies:
            fail("{}: two policies named {} ({} and {}); a policy is named after its file.".format(
                ctx.label, repr(name), policies[name].short_path, f.short_path))
        policies[name] = f
    marker = _check(ctx, ctx.attr.type, ctx.files.srcs)
    files = depset(ctx.files.srcs)
    return [
        DefaultInfo(files = files),
        MinioPolicyInfo(type = ctx.attr.type, policies = policies, files = files),
        OutputGroupInfo(_validation = depset([marker])),
    ]

minio_policy = rule(
    implementation = _minio_policy_impl,
    doc = "Policy documents (JSON), checked on every build: unknown keys, then MinIO loads them.",
    attrs = {
        "srcs": attr.label_list(
            mandatory = True,
            allow_empty = False,
            allow_files = [".json"],
            doc = "Policy documents. Each policy is named after its file: " +
                  "`read_data.json` is the policy `read_data`.",
        ),
        "type": attr.string(
            default = "iam",
            doc = "\"iam\": user / group policies (`mc admin policy create`). " +
                  "\"bucket\": bucket policies (`mc anonymous set-json`), each " +
                  "naming one bucket in its Resource.",
        ),
        "_launcher": attr.label(default = "//private:launcher.py", allow_single_file = True),
    },
    toolchains = [_TOOLCHAIN],
)

def _minio_lifecycle_impl(ctx):
    marker = _check(ctx, "lifecycle", [ctx.file.src])
    return [
        DefaultInfo(files = depset([ctx.file.src])),
        MinioLifecycleInfo(config = ctx.file.src),
        OutputGroupInfo(_validation = depset([marker])),
    ]

minio_lifecycle = rule(
    implementation = _minio_lifecycle_impl,
    doc = "A bucket lifecycle configuration (the `mc ilm rule export` JSON), checked on every build.",
    attrs = {
        "src": attr.label(
            mandatory = True,
            allow_single_file = [".json"],
            doc = "{\"Rules\": [...]}. Transition rules are key-checked, but " +
                  "not loaded: they need a remote tier.",
        ),
        "_launcher": attr.label(default = "//private:launcher.py", allow_single_file = True),
    },
    toolchains = [_TOOLCHAIN],
)
