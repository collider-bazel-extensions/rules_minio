"""minio_server + minio_health_check — hermetic MinIO test fixtures.

`minio_server` is a long-running executable (see launcher.py serve): one
MinIO on a free 127.0.0.1 port, with its buckets, policies, users and
seed objects in place. Then it writes `$TEST_TMPDIR/<name>.env`:

    MINIO_ENDPOINT=http://127.0.0.1:<port>     (https:// with tls)
    MINIO_HOST, MINIO_PORT, MINIO_CONSOLE_URL, MINIO_REGION
    MINIO_ROOT_USER, MINIO_ROOT_PASSWORD
    AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION,
    AWS_DEFAULT_REGION, AWS_ENDPOINT_URL, AWS_ENDPOINT_URL_S3
    MC_HOST_minio                               (mc's alias `minio`)
    MINIO_USER_<NAME>_ACCESS_KEY / _SECRET_KEY  (per user)
    MINIO_TLS, MINIO_TLS_CA, AWS_CA_BUNDLE      (with tls)
    MINIO_EVENTS_FILE                           (with events)
    MINIO_CONTROL_URL, MINIO_LOG, MINIO_DATA_DIR, MINIO_SERVER, MC

and runs until SIGTERM. `minio_health_check` exits 0 iff that file
exists; it drops into `itest_service.health_check`.
"""

load(":providers.bzl", "MinioLifecycleInfo", "MinioPolicyInfo")

_TOOLCHAIN = "//toolchain:minio"

# Policies every MinIO has.
BUILTIN_POLICIES = ["consoleAdmin", "diagnostics", "readonly", "readwrite", "writeonly"]

_EVENTS = ["put", "get", "delete", "replica", "ilm", "scanner"]

MinioServerInfo = provider(
    doc = "A minio_server target.",
    fields = {
        "binary":  "MinioBinaryInfo: the toolchain's binaries.",
        "buckets": "list of string: the buckets it creates.",
        "tls":     "bool: whether it serves TLS only.",
    },
)

def shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"

def check_timeout(label, value):
    """Validate a timeout attribute: a positive number of seconds."""
    raw = value.strip()
    digits = raw.replace(".", "", 1)
    if not raw or not digits.isdigit() or not digits.replace("0", ""):
        fail("{}: ready_timeout = {}: expected a positive number of seconds.".format(
            label, repr(value)))
    return raw

def check_bucket(label, what, b):
    """S3 bucket naming: 3-63 of a-z 0-9 . -, starting and ending with a
    letter or digit."""
    ok = len(b) >= 3 and len(b) <= 63 and b[0].isalnum() and b[-1].isalnum()
    for c in b.elems():
        if not (c.isdigit() or (c.isalpha() and c.islower()) or c in ".-"):
            ok = False
    if not ok or ".." in b:
        fail(("{}: {}: {} is not a valid bucket name (3-63 characters: lowercase letters, " +
             "digits, '.' and '-', starting and ending with a letter or digit).").format(label, what, repr(b)))

def check_buckets(label, buckets, used):
    """`used` [(attribute, bucket)] must name buckets in `buckets`."""
    seen = {}
    for b in buckets:
        check_bucket(label, "buckets", b)
        if b in seen:
            fail("{}: buckets: {} is listed twice.".format(label, repr(b)))
        seen[b] = True
    for what, b in used:
        if b not in seen:
            fail("{}: {} names bucket {}, which `buckets` doesn't create.".format(label, what, repr(b)))

def check_users(label, users, policy_names):
    for user, policies in users.items():
        if len(user) < 3 or not user.replace("-", "").replace("_", "").replace(".", "").replace("@", "").isalnum():
            fail(("{}: users: {} is not a valid user name (3+ characters: letters, digits, " +
                 "'-', '_', '.', '@').").format(label, repr(user)))
        for p in [p.strip() for p in policies.split(",") if p.strip()]:
            if p not in policy_names and p not in BUILTIN_POLICIES:
                fail("{}: users: {} gets policy {}, which is neither in `policies` ({}) nor built in ({}).".format(
                    label, repr(user), repr(p), ", ".join(sorted(policy_names)) or "none",
                    ", ".join(BUILTIN_POLICIES)))

def iam_policies(label, targets):
    """name → File for minio_policy(type = "iam") targets."""
    out = {}
    for t in targets:
        info = t[MinioPolicyInfo]
        if info.type != "iam":
            fail(("{}: policies: {} holds {} policies; IAM policies go in `policies`, bucket " +
                 "policies in `bucket_policies`.").format(label, t.label, info.type))
        for name, f in info.policies.items():
            if name in out:
                fail("{}: policies: two policies named {}.".format(label, repr(name)))
            out[name] = f
    return out

def bucket_policy_files(label, targets):
    out = []
    for t in targets:
        info = t[MinioPolicyInfo]
        if info.type != "bucket":
            fail(("{}: bucket_policies: {} holds {} policies; give minio_policy(type = \"bucket\") " +
                 "targets.").format(label, t.label, info.type))
        out += info.policies.values()
    return out

def lifecycle_files(label, mapping):
    """[(bucket, File)] from {minio_lifecycle target: "bucket,bucket"}."""
    out = []
    for t, buckets in mapping.items():
        for b in [b.strip() for b in buckets.split(",") if b.strip()]:
            out.append((b, t[MinioLifecycleInfo].config))
    return out

def seed_entries(label, mapping):
    """[(destination, File)]: each file of each target, under
    bucket[/prefix], at its path relative to its package."""
    out = []
    for t, dest in mapping.items():
        dest = dest.strip("/")
        if not dest:
            fail("{}: seed: {} needs a bucket (\"bucket\" or \"bucket/prefix\").".format(label, t.label))
        for f in t.files.to_list():
            rel = f.short_path
            if rel.startswith("../"):
                rel = rel.split("/", 2)[2]
            pkg = f.owner.package + "/" if f.owner and f.owner.package else ""
            if pkg and rel.startswith(pkg):
                rel = rel[len(pkg):]
            sub = rel.rpartition("/")[0] if not f.is_directory else rel
            out.append(((dest + "/" + sub) if sub else dest, f))
    return out

def _resolved(flag, path, value = None):
    # Resolved into a variable first: a failing $(resolve) inside an
    # argument list would not stop the script under `set -e`.
    arg = '"$p"' if value == None else shell_quote(value + "=") + '"$p"'
    return "p=\"$(resolve {})\"; opts+=({} {})".format(shell_quote(path), flag, arg)

def _minio_server_impl(ctx):
    mn = ctx.toolchains[_TOOLCHAIN].minio
    label = ctx.label
    if ctx.attr.drives < 1 or ctx.attr.drives > 16:
        fail("{}: drives = {}: want 1 (one drive) or 2..16 (one erasure set).".format(label, ctx.attr.drives))
    if len(ctx.attr.root_user) < 3 or len(ctx.attr.root_password) < 8:
        fail("{}: MinIO needs root_user of 3+ characters and root_password of 8+.".format(label))
    for what, v in (("root_user", ctx.attr.root_user), ("root_password", ctx.attr.root_password)):
        if "\n" in v or ":" in v or "@" in v or "/" in v:
            fail("{}: {} may not contain ':', '@', '/' or a newline (it goes into URLs).".format(label, what))
    tls_given = [a for a in ("tls_cert", "tls_key", "tls_ca") if getattr(ctx.file, a)]
    if tls_given and not ctx.attr.tls:
        fail("{}: {} need tls = True.".format(label, ", ".join(tls_given)))
    if tls_given and len(tls_given) != 3:
        fail("{}: give tls_cert, tls_key and tls_ca together (or none: generated).".format(label))

    policies = iam_policies(label, ctx.attr.policies)
    lifecycle = lifecycle_files(label, ctx.attr.lifecycle)
    seed = seed_entries(label, ctx.attr.seed)
    used = [("versioned", b) for b in ctx.attr.versioned] + \
           [("object_lock", b) for b in ctx.attr.object_lock] + \
           [("events", b) for b in ctx.attr.events.keys()] + \
           [("lifecycle", b) for b, _ in lifecycle] + \
           [("seed", d.split("/")[0]) for d, _ in seed]
    check_buckets(label, ctx.attr.buckets, used)
    check_users(label, ctx.attr.users, policies.keys())
    for b, events in ctx.attr.events.items():
        for e in [e.strip() for e in events.split(",")]:
            if e not in _EVENTS:
                fail("{}: events[{}]: unknown event type {} (known: {}).".format(
                    label, repr(b), repr(e), ", ".join(_EVENTS)))

    lines, files, opts = [], [], []
    for name, f in policies.items():
        lines.append(_resolved("--policy", f.short_path, name))
        files.append(f)
    for f in bucket_policy_files(label, ctx.attr.bucket_policies):
        lines.append(_resolved("--bucket-policy", f.short_path))
        files.append(f)
    for b, f in lifecycle:
        lines.append(_resolved("--lifecycle", f.short_path, b))
        files.append(f)
    for dest, f in seed:
        lines.append(_resolved("--seed", f.short_path, dest + "/"))
        files.append(f)
    for a in ("tls_cert", "tls_key", "tls_ca"):
        f = getattr(ctx.file, a)
        if f:
            lines.append(_resolved("--" + a.replace("_", "-"), f.short_path))
            files.append(f)
    if ctx.attr.tls:
        lines.append(_resolved("--openssl", mn.openssl.short_path))
        opts.append("--tls")
    for b in ctx.attr.buckets:
        opts += ["--bucket", b]
    for b in ctx.attr.versioned:
        opts += ["--versioned", b]
    for b in ctx.attr.object_lock:
        opts += ["--object-lock", b]
    for user, p in ctx.attr.users.items():
        opts += ["--user", "{}={}".format(user, ",".join([x.strip() for x in p.split(",") if x.strip()]))]
    for b, events in ctx.attr.events.items():
        opts += ["--events", "{}={}".format(b, ",".join([e.strip() for e in events.split(",")]))]
    for k, v in ctx.attr.server_env.items():
        opts += ["--server-env", "{}={}".format(k, v)]
    opts += ["--root-user", ctx.attr.root_user, "--root-password", ctx.attr.root_password,
             "--region", ctx.attr.region, "--drives", str(ctx.attr.drives)]

    wrapper = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._tmpl,
        output = wrapper,
        substitutions = {
            "__NAME__":          ctx.label.name,
            "__LAUNCHER__":      ctx.file._launcher.short_path,
            "__MINIO__":         mn.server.short_path,
            "__MC__":            mn.mc.short_path,
            "__READY_TIMEOUT__": check_timeout(label, ctx.attr.ready_timeout),
            "__FILES__":         "\n".join(lines),
            "__OPTS__":          " ".join([shell_quote(o) for o in opts]),
            "__EXTRA_ARGS__":    " ".join([shell_quote(a) for a in ctx.attr.extra_args]),
        },
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [wrapper, ctx.file._launcher] + files, transitive_files = mn.files)
    return [
        DefaultInfo(executable = wrapper, runfiles = runfiles),
        MinioServerInfo(binary = mn, buckets = ctx.attr.buckets, tls = ctx.attr.tls),
    ]

SERVER_ATTRS = {
    "buckets": attr.string_list(
        doc = "Buckets to create.",
    ),
    "versioned": attr.string_list(
        doc = "Buckets (from `buckets`) with versioning enabled.",
    ),
    "object_lock": attr.string_list(
        doc = "Buckets (from `buckets`) created with object lock (versioned, as S3 requires).",
    ),
    "policies": attr.label_list(
        providers = [MinioPolicyInfo],
        doc = "minio_policy targets (type \"iam\"): created by name, for `users`.",
    ),
    "users": attr.string_dict(
        doc = "User → comma-separated policies (from `policies`, or built in: " +
              ", ".join(BUILTIN_POLICIES) + "). Each gets a random secret key, " +
              "exported as MINIO_USER_<NAME>_SECRET_KEY.",
    ),
    "bucket_policies": attr.label_list(
        providers = [MinioPolicyInfo],
        doc = "minio_policy targets (type \"bucket\"): each document is set on " +
              "the bucket its Resource names (anonymous access).",
    ),
    "lifecycle": attr.label_keyed_string_dict(
        providers = [MinioLifecycleInfo],
        doc = "minio_lifecycle target → comma-separated buckets it applies to.",
    ),
    "seed": attr.label_keyed_string_dict(
        allow_files = True,
        doc = "Files → \"bucket\" or \"bucket/prefix\". Each file is uploaded at its " +
              "path relative to its package (a directory, recursively).",
    ),
    "events": attr.string_dict(
        doc = "Bucket → comma-separated event types (" + ", ".join(_EVENTS) + "). " +
              "Notifications are recorded, one JSON line each, in MINIO_EVENTS_FILE.",
    ),
    "root_user": attr.string(
        default = "minioadmin",
        doc = "Root access key (3+ characters). Also AWS_ACCESS_KEY_ID.",
    ),
    "root_password": attr.string(
        default = "minioadmin",
        doc = "Root secret key (8+ characters). Also AWS_SECRET_ACCESS_KEY.",
    ),
    "region": attr.string(
        default = "us-east-1",
        doc = "The server's region (MINIO_SITE_REGION). Also AWS_REGION.",
    ),
    "drives": attr.int(
        default = 1,
        doc = "1: one drive. 2..16: one erasure set of that many drives.",
    ),
    "tls": attr.bool(
        doc = "Serve TLS only. Without tls_cert/tls_key/tls_ca, a throwaway " +
              "CA and certificate (for 127.0.0.1 / localhost) are made at start " +
              "with the toolchain's openssl. Env: MINIO_TLS=1, MINIO_TLS_CA, https:// endpoint.",
    ),
    "tls_cert": attr.label(allow_single_file = True, doc = "Server certificate (for 127.0.0.1)."),
    "tls_key": attr.label(allow_single_file = True, doc = "Server key."),
    "tls_ca": attr.label(allow_single_file = True, doc = "CA that signed the certificate."),
    "server_env": attr.string_dict(
        doc = "Extra environment for minio, e.g. {\"MINIO_API_REQUESTS_MAX\": \"10\"}.",
    ),
    "ready_timeout": attr.string(
        default = "30",
        doc = "Seconds to wait for the server to be ready.",
    ),
    "extra_args": attr.string_list(
        doc = "Extra `minio server` options.",
    ),
}

minio_server = rule(
    implementation = _minio_server_impl,
    executable = True,
    doc = """\
Long-running MinIO for tests and rules_itest compositions. Writes
`$TEST_TMPDIR/<name>.env` once the server is ready and its buckets,
policies, users, lifecycle rules, seed objects and event notifications
are in place. If MinIO refuses its arguments, exits, isn't ready within
`ready_timeout`, or a provisioning step fails, it exits non-zero, naming
the cause.
""",
    attrs = dict(SERVER_ATTRS, **{
        "_launcher": attr.label(default = "//private:launcher.py", allow_single_file = True),
        "_tmpl": attr.label(default = "//private:server.sh.tmpl", allow_single_file = True),
    }),
    toolchains = [_TOOLCHAIN],
)

# ---- minio_health_check ---------------------------------------------------------

def _minio_health_check_impl(ctx):
    wrapper = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._tmpl,
        output = wrapper,
        substitutions = {"__ENV_FILE_NAME__": ctx.attr.server.label.name + ".env"},
        is_executable = True,
    )
    return [DefaultInfo(executable = wrapper)]

minio_health_check = rule(
    implementation = _minio_health_check_impl,
    executable = True,
    attrs = {
        "server": attr.label(
            mandatory = True,
            providers = [MinioServerInfo],
            doc = "The minio_server this check pairs with.",
        ),
        "_tmpl": attr.label(default = "//private:health_check.sh.tmpl", allow_single_file = True),
    },
)
