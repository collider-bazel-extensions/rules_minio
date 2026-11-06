"""Analysis-time tests: providers, executables, and the analysis errors
for bad attributes."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load(
    "//:defs.bzl",
    "MinioPolicyInfo",
    "MinioServerInfo",
    "minio_health_check",
    "minio_install",
    "minio_install_health_check",
    "minio_policy",
    "minio_server",
)

def _has_executable_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(env, target[DefaultInfo].files_to_run.executable != None,
                 "expected target to expose an executable")
    return analysistest.end(env)

_has_executable_test = analysistest.make(_has_executable_impl)

def _server_info_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[MinioServerInfo]
    asserts.equals(env, "2025-10-15", info.binary.version)
    asserts.equals(env, ["data", "logs"], info.buckets)
    asserts.true(env, info.tls)
    return analysistest.end(env)

_server_info_test = analysistest.make(_server_info_impl)

def _policy_info_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[MinioPolicyInfo]
    asserts.equals(env, "iam", info.type)
    asserts.equals(env, ["read_data", "write_uploads"], sorted(info.policies.keys()))
    asserts.equals(env, "read_data.json", info.policies["read_data"].basename)
    return analysistest.end(env)

_policy_info_test = analysistest.make(_policy_info_impl)

def _validation_impl(ctx):
    env = analysistest.begin(ctx)
    groups = analysistest.target_under_test(env)[OutputGroupInfo]
    files = groups._validation.to_list()
    asserts.equals(env, 1, len(files))
    asserts.true(env, files[0].basename.endswith(".checked"), files[0].basename)
    return analysistest.end(env)

_validation_test = analysistest.make(_validation_impl)

def _fails_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

_fails_test = analysistest.make(
    _fails_impl,
    expect_failure = True,
    attrs = {"message": attr.string()},
)

def analysis_test_suite(name):
    s = name + "_subject"
    m = ["manual"]
    minio_server(name = s + "_server", buckets = ["data", "logs"], tls = True, tags = m)
    minio_health_check(name = s + "_health", server = ":" + s + "_server", tags = m)
    minio_install(name = s + "_install", tags = m)
    minio_install_health_check(name = s + "_install_health", tags = m)
    minio_server(name = s + "_bad_bucket", buckets = ["Data_Bucket"], tags = m)
    minio_server(name = s + "_dup_bucket", buckets = ["data", "data"], tags = m)
    minio_server(name = s + "_versioned_unknown", buckets = ["data"], versioned = ["logs"], tags = m)
    minio_server(name = s + "_seed_unknown", buckets = ["data"], seed = {"//tests/testdata:seed": "other/x"}, tags = m)
    minio_server(name = s + "_events_unknown", buckets = ["data"], events = {"data": "put,wrote"}, tags = m)
    minio_server(name = s + "_user_policy", users = {"alice": "read_data"}, tags = m)
    minio_server(name = s + "_user_name", users = {"al": "readonly"}, tags = m)
    minio_server(name = s + "_short_password", root_password = "short", tags = m)
    minio_server(name = s + "_url_password", root_password = "pass/word:1", tags = m)
    minio_server(name = s + "_drives", drives = 17, tags = m)
    minio_server(name = s + "_timeout", ready_timeout = "soon", tags = m)
    minio_server(name = s + "_tls_no_tls", tls_ca = "//tests:certs/ca.crt", tags = m)
    minio_server(name = s + "_tls_partial", tls = True, tls_cert = "//tests:certs/server.crt", tags = m)
    minio_server(name = s + "_iam_as_bucket", bucket_policies = ["//tests/testdata:policies"], tags = m)
    minio_server(name = s + "_bucket_as_iam", policies = ["//tests/testdata:public_downloads"], tags = m)
    minio_policy(name = s + "_bad_type", srcs = ["//tests/testdata:policies/read_data.json"], type = "user", tags = m)
    minio_policy(
        name = s + "_dup_policy",
        srcs = [
            "//tests/testdata:policies/read_data.json",
            "//tests/testdata:bad/read_data.json",
        ],
        tags = m,
    )
    minio_install(name = s + "_install_password", root_password = "has space!", tags = m)
    minio_install(name = s + "_install_lifecycle", lifecycle = {"//tests/testdata:expire_tmp": "logs"}, tags = m)

    tests = {
        "_server_info": (_server_info_test, s + "_server", None),
        "_policy_info": (_policy_info_test, "//tests/testdata:policies", None),
        "_policy_validation": (_validation_test, "//tests/testdata:policies", None),
        "_lifecycle_validation": (_validation_test, "//tests/testdata:expire_tmp", None),
        "_server_executable": (_has_executable_test, s + "_server", None),
        "_health_executable": (_has_executable_test, s + "_health", None),
        "_install_executable": (_has_executable_test, s + "_install", None),
        "_install_health_executable": (_has_executable_test, s + "_install_health", None),
        "_bad_bucket": (_fails_test, s + "_bad_bucket", '"Data_Bucket" is not a valid bucket name'),
        "_dup_bucket": (_fails_test, s + "_dup_bucket", 'buckets: "data" is listed twice'),
        "_versioned_unknown": (_fails_test, s + "_versioned_unknown", 'versioned names bucket "logs", which `buckets` doesn\'t create'),
        "_seed_unknown": (_fails_test, s + "_seed_unknown", 'seed names bucket "other"'),
        "_events_unknown": (_fails_test, s + "_events_unknown", 'unknown event type "wrote"'),
        "_user_policy": (_fails_test, s + "_user_policy", 'gets policy "read_data", which is neither in `policies`'),
        "_user_name": (_fails_test, s + "_user_name", '"al" is not a valid user name'),
        "_short_password": (_fails_test, s + "_short_password", "root_password of 8+"),
        "_url_password": (_fails_test, s + "_url_password", "root_password may not contain"),
        "_drives": (_fails_test, s + "_drives", "drives = 17"),
        "_timeout": (_fails_test, s + "_timeout", "expected a positive number of seconds"),
        "_tls_no_tls": (_fails_test, s + "_tls_no_tls", "tls_ca need tls = True"),
        "_tls_partial": (_fails_test, s + "_tls_partial", "give tls_cert, tls_key and tls_ca together"),
        "_iam_as_bucket": (_fails_test, s + "_iam_as_bucket", "give minio_policy(type = \"bucket\") targets"),
        "_bucket_as_iam": (_fails_test, s + "_bucket_as_iam", "holds bucket policies; IAM policies go in `policies`"),
        "_bad_type": (_fails_test, s + "_bad_type", "want \"iam\" or \"bucket\""),
        "_dup_policy": (_fails_test, s + "_dup_policy", 'two policies named "read_data"'),
        "_install_password": (_fails_test, s + "_install_password", "root_password may only use letters"),
        "_install_lifecycle": (_fails_test, s + "_install_lifecycle", 'lifecycle names bucket "logs"'),
    }
    for suffix, (rule, target, message) in tests.items():
        kwargs = {"message": message} if message else {}
        rule(name = name + suffix, target_under_test = target if target.startswith("//") else ":" + target, **kwargs)
    native.test_suite(name = name, tests = [":" + name + suffix for suffix in tests])
