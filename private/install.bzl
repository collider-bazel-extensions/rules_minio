"""minio_install + minio_install_health_check — MinIO in a cluster.

minio_install applies a single-replica Deployment `minio` with Services
`minio` (S3 API, 9000) and `minio-console` (9001), running the image
minio_image builds from the pinned binaries (MinIO's own images are no
longer published for pulling). Its launcher (launcher.py install):

  1. creates the namespace and the Secret `minio` (root credentials:
     given, or kept from an earlier install, or generated);
  2. applies the manifest and waits for deploy/minio to roll out;
  3. creates buckets, IAM policies, users (secret keys in the Secret
     `minio-users`), bucket policies and lifecycle rules through
     `kubectl exec deploy/minio -- mc`;
  4. writes the ConfigMap `minio-provisioned` and runs until SIGTERM
     (the itest_service.exe contract).

minio_install_health_check exits 0 once `minio-provisioned` exists.
Both read KUBECONFIG, and KUBECTL (else kubectl on PATH), from the
environment, as rules_kubectl does.
"""

load(":providers.bzl", "MinioLifecycleInfo", "MinioPolicyInfo")
load(":server.bzl", "bucket_policy_files", "check_buckets", "check_users", "iam_policies",
     "lifecycle_files", "shell_quote")
load(":versions.bzl", "DEFAULT_IMAGE")

def _resolved(flag, path, value = None):
    arg = '"$p"' if value == None else shell_quote(value + "=") + '"$p"'
    return "p=\"$(resolve {})\"; opts+=({} {})".format(shell_quote(path), flag, arg)

def _wrapper(ctx, mode, lines, opts, files):
    out = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._tmpl,
        output = out,
        substitutions = {
            "__LAUNCHER__": ctx.file._launcher.short_path,
            "__MODE__": mode,
            "__FILES__": "\n".join(lines),
            "__OPTS__": " ".join([shell_quote(o) for o in opts]),
        },
        is_executable = True,
    )
    return DefaultInfo(executable = out, runfiles = ctx.runfiles(files = [out, ctx.file._launcher] + files))

def _minio_install_impl(ctx):
    label = ctx.label
    policies = iam_policies(label, ctx.attr.policies)
    lifecycle = lifecycle_files(label, ctx.attr.lifecycle)
    check_buckets(label, ctx.attr.buckets,
                  [("versioned", b) for b in ctx.attr.versioned] +
                  [("object_lock", b) for b in ctx.attr.object_lock] +
                  [("lifecycle", b) for b, _ in lifecycle])
    check_users(label, ctx.attr.users, policies.keys())
    for what, v in (("root_user", ctx.attr.root_user), ("root_password", ctx.attr.root_password)):
        for c in v.elems():
            if not (c.isalnum() or c in "._~-"):
                fail("{}: {} may only use letters, digits and . _ ~ - (it goes into an mc URL).".format(label, what))
    if ctx.attr.root_user and len(ctx.attr.root_user) < 3 or ctx.attr.root_password and len(ctx.attr.root_password) < 8:
        fail("{}: MinIO needs root_user of 3+ characters and root_password of 8+.".format(label))

    manifest = ctx.actions.declare_file(ctx.label.name + ".yaml")
    args = ctx.actions.args()
    args.add(ctx.file._launcher)
    args.add("manifest")
    args.add("--image", ctx.attr.image)
    args.add("--region", ctx.attr.region)
    if ctx.attr.storage:
        args.add("--storage", ctx.attr.storage)
    args.add(manifest)
    ctx.actions.run_shell(
        command = 'exec python3 "$@"',
        arguments = [args],
        inputs = [ctx.file._launcher],
        outputs = [manifest],
        use_default_shell_env = True,
        mnemonic = "MinioManifest",
    )

    lines = [_resolved("--manifest", manifest.short_path)]
    files = [manifest]
    for name, f in policies.items():
        lines.append(_resolved("--policy", f.short_path, name))
        files.append(f)
    for f in bucket_policy_files(label, ctx.attr.bucket_policies):
        lines.append(_resolved("--bucket-policy", f.short_path))
        files.append(f)
    for b, f in lifecycle:
        lines.append(_resolved("--lifecycle", f.short_path, b))
        files.append(f)
    opts = ["--namespace", ctx.attr.namespace, "--wait-timeout", ctx.attr.wait_timeout]
    for b in ctx.attr.buckets:
        opts += ["--bucket", b]
    for b in ctx.attr.versioned:
        opts += ["--versioned", b]
    for b in ctx.attr.object_lock:
        opts += ["--object-lock", b]
    for user, p in ctx.attr.users.items():
        opts += ["--user", "{}={}".format(user, ",".join([x.strip() for x in p.split(",") if x.strip()]))]
    if ctx.attr.root_user:
        opts += ["--root-user", ctx.attr.root_user]
    if ctx.attr.root_password:
        opts += ["--root-password", ctx.attr.root_password]
    return [
        _wrapper(ctx, "install", lines, opts, files),
        OutputGroupInfo(manifest = depset([manifest])),
    ]

_COMMON = {
    "namespace": attr.string(default = "minio", doc = "Namespace to install into (created if missing)."),
    "_launcher": attr.label(default = "//private:launcher.py", allow_single_file = True),
    "_tmpl": attr.label(default = "//private:install.sh.tmpl", allow_single_file = True),
}

minio_install = rule(
    implementation = _minio_install_impl,
    executable = True,
    doc = "Install MinIO into a cluster and provision it; runs until SIGTERM. " +
          "Drops into `itest_service.exe`. The manifest is the `manifest` output group.",
    attrs = dict(_COMMON, **{
        "image": attr.string(
            default = DEFAULT_IMAGE,
            doc = "The image to run. The default is what @rules_minio//:image " +
                  "builds: load it into kind (kind_cluster(images = [...])) or " +
                  "push it and name it here.",
        ),
        "storage": attr.string(
            doc = "A PersistentVolumeClaim of this size (e.g. \"10Gi\") for /data; " +
                  "default: emptyDir (data lasts as long as the pod).",
        ),
        "region": attr.string(default = "us-east-1", doc = "MINIO_SITE_REGION."),
        "root_user": attr.string(
            doc = "Root access key. Default: kept from an earlier install, else `minioadmin`.",
        ),
        "root_password": attr.string(
            doc = "Root secret key. Default: kept from an earlier install, else " +
                  "generated. Both end up in the Secret `minio`.",
        ),
        "buckets": attr.string_list(doc = "Buckets to create."),
        "versioned": attr.string_list(doc = "Buckets with versioning enabled."),
        "object_lock": attr.string_list(doc = "Buckets created with object lock."),
        "policies": attr.label_list(providers = [MinioPolicyInfo], doc = "minio_policy (type \"iam\") targets."),
        "users": attr.string_dict(
            doc = "User → comma-separated policies. Secret keys are generated " +
                  "(kept across installs) in the Secret `minio-users`.",
        ),
        "bucket_policies": attr.label_list(providers = [MinioPolicyInfo], doc = "minio_policy (type \"bucket\") targets."),
        "lifecycle": attr.label_keyed_string_dict(
            providers = [MinioLifecycleInfo],
            doc = "minio_lifecycle target → comma-separated buckets.",
        ),
        "wait_timeout": attr.string(default = "300s", doc = "How long to wait for the rollout."),
    }),
)

def _health_impl(ctx):
    return [_wrapper(ctx, "install-health", [], ["--namespace", ctx.attr.namespace], [])]

minio_install_health_check = rule(
    implementation = _health_impl,
    executable = True,
    doc = "Exits 0 once minio_install has provisioned MinIO (the ConfigMap " +
          "`minio-provisioned` exists). Drops into `itest_service.health_check`.",
    attrs = _COMMON,
)
