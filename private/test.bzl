"""minio_test — sh_test macro with an auto-launched MinIO.

Each target gets its own minio_server (own port, own drives), so tests
are safe under `--jobs=N`.

The trampoline (minio_test_trampoline.sh) starts the server, waits for
its env file, sources it (MINIO_ENDPOINT, the AWS_* variables,
MC_HOST_minio, per-user keys, ...), puts the `mc` wrapper on PATH,
exports MINIO_TESTLIB and runs the test with the target's args. It runs
the test rather than exec'ing it, so it can stop the server when the
test ends, and stop the test if the server exits first.
"""

load("@rules_shell//shell:sh_binary.bzl", "sh_binary")
load("@rules_shell//shell:sh_test.bzl", "sh_test")
load(":server.bzl", "minio_server")

def minio_test(
        name,
        srcs,
        buckets = None,
        versioned = None,
        object_lock = None,
        policies = None,
        users = None,
        bucket_policies = None,
        lifecycle = None,
        seed = None,
        events = None,
        root_user = "minioadmin",
        root_password = "minioadmin",
        region = "us-east-1",
        drives = 1,
        tls = False,
        tls_cert = None,
        tls_key = None,
        tls_ca = None,
        server_env = None,
        ready_timeout = 30,
        extra_args = None,
        deps = None,
        data = None,
        args = None,
        size = "small",
        timeout = None,
        tags = None,
        **kwargs):
    """sh_test against an auto-launched MinIO.

    Args:
      name: target name.
      srcs: the test script (one file).
      buckets: buckets to create.
      versioned: buckets with versioning.
      object_lock: buckets with object lock.
      policies: minio_policy targets (type "iam").
      users: user → comma-separated policies.
      bucket_policies: minio_policy targets (type "bucket").
      lifecycle: minio_lifecycle target → comma-separated buckets.
      seed: files → "bucket" or "bucket/prefix".
      events: bucket → comma-separated event types (put, get, delete, ...).
      root_user: root access key.
      root_password: root secret key.
      region: the server's region.
      drives: 1, or 2..16 for one erasure set.
      tls: TLS only (generated test CA unless tls_cert/tls_key/tls_ca).
      tls_cert: server certificate (with tls_key, tls_ca).
      tls_key: server key.
      tls_ca: CA certificate.
      server_env: extra environment for minio.
      ready_timeout: seconds to wait for the server.
      extra_args: extra `minio server` options.
      deps: forwarded to the inner sh_binary.
      data: runfiles for the test (on the inner sh_binary and the
        sh_test, so `args` may use $(rootpath) on them).
      args: arguments for the test script.
      size: sh_test size. Default "small".
      timeout: sh_test timeout.
      tags: tags for the sh_test (helper targets also get "manual").
      **kwargs: forwarded to sh_test (env, env_inherit, flaky, ...).
    """
    tags = tags or []
    server_name = name + "_minio"
    minio_server(
        name = server_name,
        buckets = buckets or [],
        versioned = versioned or [],
        object_lock = object_lock or [],
        policies = policies or [],
        users = users or {},
        bucket_policies = bucket_policies or [],
        lifecycle = lifecycle or {},
        seed = seed or {},
        events = events or {},
        root_user = root_user,
        root_password = root_password,
        region = region,
        drives = drives,
        tls = tls,
        tls_cert = tls_cert,
        tls_key = tls_key,
        tls_ca = tls_ca,
        server_env = server_env or {},
        ready_timeout = str(ready_timeout),
        extra_args = extra_args or [],
        tags = tags + ["manual"],
        testonly = True,
    )

    inner_name = name + "_inner"
    sh_binary(
        name = inner_name,
        srcs = srcs,
        deps = deps,
        data = data,
        tags = tags + ["manual"],
        testonly = True,
    )

    sh_test(
        name = name,
        srcs = [Label("//private:minio_test_trampoline.sh")],
        args = [
            "$(rootpath :{})".format(server_name),
            "$(rootpath :{})".format(inner_name),
            server_name,
            "$(rootpath {})".format(Label("//private:testlib.sh")),
        ] + (args or []),
        # `data` here too, so `args` can use $(rootpath) on it.
        data = [
            ":" + server_name,
            ":" + inner_name,
            Label("//private:testlib.sh"),
        ] + (data or []),
        size = size,
        timeout = timeout,
        tags = tags,
        **kwargs
    )
