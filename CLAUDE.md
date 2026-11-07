# rules_minio

Bazel rules for MinIO:
- build-time policy and lifecycle checks: strict keys, then MinIO itself (`minio_policy`, `minio_lifecycle`);
- a hermetic per-test server with buckets, policies, users, seed objects and event notifications (`minio_server`, `minio_test`);
- an image of the pinned binaries and a provisioned cluster install (`minio_image`, `minio_install`).

It mirrors rules_valkey's structure, with binaries from conda-forge as rules_valkey and rules_pg do; see DESIGN.md.

## Commit requirements

- All tests must pass before any commit with code changes: `bazel test //tests/...`. Run the kind smoke `//tests/install_smoke:smoke_test` too when install or image code changes.
- All documentation (`README.md`, `DESIGN.md`, `CLAUDE.md`) must be updated to reflect any code changes before committing: new rules, changed attributes, new public API surface, behaviour changes.

## Repo layout

```
rules_minio/
├── MODULE.bazel              # module; toolchain registration; dev deps (itest, kind)
├── defs.bzl                  # public API re-exports
├── extensions.bzl            # `minio.version()` → minio_<ver>_<plat> + minio_loader_<plat> repos
├── BUILD.bazel               # //:image alias → //image:minio_linux_amd64
├── private/
│   ├── conda_versions.bzl    # RELEASES, CONDA_CLOSURES, MISSING, IMAGE_LOADERS (generated)
│   ├── versions.bzl          # DEFAULT_VERSION, PLATFORMS, DEFAULT_IMAGE
│   ├── repositories.bzl      # binary repo (.conda merge; MISSING → failing stubs); loader repo
│   ├── providers.bzl         # MinioBinaryInfo, MinioPolicyInfo, MinioLifecycleInfo
│   ├── policy.bzl            # minio_policy, minio_lifecycle (+ validation action); *_test variants
│   ├── launcher.py           # check, serve, manifest, install, install-health
│   ├── server.bzl            # minio_server, minio_health_check, MinioServerInfo, attribute checks
│   ├── server.sh.tmpl        # runfiles resolution (into variables) → launcher.py serve
│   ├── test.bzl              # minio_test
│   ├── minio_test_trampoline.sh  # server → env → test (not exec), watching the server
│   ├── testlib.sh            # minio_as, minio_wait(_object, _event), minio_events, minio_empty, minio_stop/start
│   ├── image.bzl, image.py   # minio_image: docker-archive tarball, deterministic
│   ├── install.bzl           # minio_install (+ manifest output group), minio_install_health_check
│   └── install.sh.tmpl       # runfiles → launcher.py install / install-health
├── image/BUILD.bazel         # minio_linux_amd64, minio_linux_arm64 (fails: no server build)
├── toolchain/                # toolchain_type, per-platform toolchains, :current
├── tools/update_conda_versions.py
└── tests/
    ├── BUILD.bazel
    ├── analysis_tests.bzl    # providers, executables, validation outputs, every attribute check
    ├── testdata/             # policies (IAM, bucket), lifecycle, bad documents, seed files
    ├── check_test.sh         # validation action: good docs pass; typos, MinIO errors, JSON errors named
    ├── policy_test_failure_test.sh  # minio_policy_test fails on each wrong expectation
    ├── api_test.sh           # env, buckets/versioning/lock, users get exactly their policies, bucket
    │                         # policy, lifecycle (transition left out), seed paths, SigV4 from AWS_*, helpers
    ├── events_test.sh, drives_test.sh, tls_test.sh (+ make_certs.sh genrule)
    ├── restart_test.sh, restart_failure_test.sh
    ├── server_died_test.sh   # (+ dies.sh, exit3.sh) server dies mid-test → stopped, named
    ├── server_test.sh, server_failure_test.sh, server_cleanup_test.sh, itest_test.sh,
    ├── health_check_test.sh, install_manifest_test.sh, image_test.sh, checksums_test.sh, version_test.sh
    └── install_smoke/        # kind (image loaded) + minio_install(namespace = "storage")
```

## Key concepts

- **Upstream is source-only.** dl.min.io answers 410, the images can't be pulled, `minio/minio` is archived. Binaries are conda-forge's `minio-server` / `minio-client`; the image is built here. linux_arm64 has no 2025-10-15 server build: `MISSING`, failing stub targets.
- **Strict keys first.** MinIO drops unknown policy / lifecycle keys silently (a misspelled `Condition` widens a policy). `launcher.py check` refuses them with a suggestion, then a throwaway MinIO loads the documents (`mc --json`; the cause message is MinIO's).
- **Transitions** need a remote tier: key-checked, then taken out before MinIO loads lifecycle rules (build check and server).
- **Isolation.** The server gets the caller's environment minus `MINIO_*`, `MC_*`, `AWS_*`, plus its own; always `--certs-dir` (else `~/.minio/certs`); `mc` always `--config-dir` (the `MC` wrapper on PATH bakes it in).
- **Several drives** set `MINIO_CI_CD=on`: erasure mode refuses drives on the root filesystem (where GitHub runners' sandboxes are; locally the test tree is usually on another mount, so it passes anyway).
- **Readiness.** `/minio/health/ready` 200, then provisioning (events last, so seeding sends none), then the env file. The ready endpoint can answer before the object layer is up (several drives, slow CI): `mc` calls retry `Server not initialized yet` for 30 s (`retry_uninitialized`). Readiness also waits for the console port to accept connections: MinIO binds it after the API and dies if it was taken, which must happen before "ready" so `launch` retries with new ports. MinIO prints its banner after it is ready: don't parse ports from its log.
- **Install provisioning** goes through `kubectl exec deploy/minio -- mc` (no shell or tar in the image). `mc anonymous set-json` can't read a pipe, so documents are first written into the pod's /tmp with `mc pipe <path>`. Credentials must be URL-safe (`MC_HOST_local` via `$(VAR)` expansion). The marker ConfigMap `minio-provisioned` is deleted at the start of an install and written at the end.
- **Watching.** The trampoline backgrounds the test and polls both pids (bash 3.2); if the server dies first, it kills the test's process tree (`pgrep -P`) and fails with the status and `$MINIO_LOG` tail.

## Public API

```python
load("@rules_minio//:defs.bzl",
    "minio_policy",                # srcs, type ("iam" | "bucket")
    "minio_lifecycle",             # src
    "minio_policy_test",           # srcs, type, expect_error (regex; empty: expect a pass)
    "minio_lifecycle_test",        # src, expect_error
    "minio_server",                # buckets, versioned, object_lock, policies, users, bucket_policies,
                                   # lifecycle, seed, events, root_user, root_password, region, drives,
                                   # tls, tls_cert/key/ca, server_env, ready_timeout, extra_args
    "minio_health_check",          # server
    "minio_test",                  # srcs + minio_server attrs + args, env, data, deps, ...
    "minio_image",                 # minio, mc, loader, loader_dest, arch, tag
    "minio_install",               # namespace, image, storage, region, root_user, root_password, buckets,
                                   # versioned, object_lock, policies, users, bucket_policies, lifecycle,
                                   # wait_timeout
    "minio_install_health_check",  # namespace
    "MinioBinaryInfo", "MinioPolicyInfo", "MinioLifecycleInfo", "MinioServerInfo", "DEFAULT_IMAGE",
)
```

`@rules_minio//:image` is the linux_amd64 image tarball (`rules-minio/minio:2025-10-15`).

## Development

```sh
bazel test //tests/...                                  # no container runtime
systemd-run --scope --user --property=Delegate=yes -- \
    bazel test //tests/install_smoke:smoke_test --test_output=streamed   # kind (podman)
python3 tools/update_conda_versions.py --refresh \
    2025-10-15=2025.10.15.17.29.55,2025.08.13.08.35.41 > private/conda_versions.bzl
```

To find stray servers, use `pgrep -x minio` (an exact process name), never `pkill -f` with a pattern. The pattern matches the shell running it.

### Test results (last full run: 2026-11-06)

All 53 test targets pass on Linux x86_64 (MinIO RELEASE.2025-10-15T17-29-55Z): 52 in `//tests/...` (27 of them analysis tests) and the kind smoke on rootless podman. Other checks:
- `//tests/...` passed with network blocked in the sandbox (`--sandbox_default_allow_network=false`), and 10 runs of every test in parallel (450 runs, before the 7 policy-test targets were added), with no stray `minio` left.
- `bazel build //tests/testdata:typo_policy` fails, naming the misspelled `Conditon` (CI checks it).
- The image loads into podman and kind, and runs under the default SELinux labels.

| Test target | What it verifies | Result |
|---|---|---|
| `//tests:check_test` | good IAM, bucket and lifecycle documents pass; unknown keys (with suggestion), MinIO's errors (action, resource, Principal, Status) and JSON errors fail, each file named | PASSED |
| `//tests:typo_resource_test`, `unknown_action_test`, `bucket_policy_principal_test`, `lifecycle_typo_test`, `good_policies_test`, `good_lifecycle_test` | minio_policy_test / minio_lifecycle_test: refusals matched (file and key named), good documents accepted | PASSED |
| `//tests:policy_test_failure_test` | a policy test fails on a non-matching error, on a refusal without expect_error, and on a pass with one | PASSED |
| `//tests:api_test` | env (AWS_*, region, mc on PATH), buckets, versioning, object lock, seed paths, users get exactly their policies, anonymous reads via the bucket policy, lifecycle rules (transition left out), a SigV4 client from AWS_* alone, wait/empty helpers, args | PASSED |
| `//tests:events_test` | put and delete notifications recorded (key decoded), not gets, other buckets or the seed; wait timeout message | PASSED |
| `//tests:drives_test` | 4 drives online, an object on all 4 | PASSED |
| `//tests:tls_test`, `tls_provided_test` | TLS only (plain HTTP refused), mc and a Python client with MINIO_TLS_CA, generated and own certificates, restart | PASSED |
| `//tests:restart_test` | stop: clients fail, port closed; start: same port, data and users | PASSED |
| `//tests:restart_failure_test` | held port → 500 naming it; starts later; brief hold retried | PASSED |
| `//tests:server_died_test` | server dies mid-test → test stopped within seconds, status + log tail; test's own exit status kept | PASSED |
| `//tests:server_test` | direct run: root credentials, server_env, extra_args, caller's MINIO_* / MC_HOST_* / AWS_* ignored, SIGTERM exit 0 | PASSED |
| `//tests:server_failure_test` | bad flag (MinIO's message), failing provisioning (server stopped), timeout, test body skipped | PASSED |
| `//tests:server_cleanup_test` | the server is stopped when a minio_test ends | PASSED |
| `//tests:itest_test` | minio_server + health check as an itest_service | PASSED |
| `//tests:install_manifest_test` | objects, image, probes, Secret refs, security context; emptyDir vs PVC, image and region attrs | PASSED |
| `//tests:image_test` | docker-archive layout, modes, deterministic rebuild, the loader alone runs minio | PASSED |
| `//tests:health_check_test`, `checksums_test`, `version_test` | env-file probe; conda pins; one version everywhere, matching `minio --version` | PASSED |
| `//tests:analysis_tests` (27) | providers, executables, validation outputs; bucket names, unknown buckets, users, policies, events, passwords, drives, timeout, TLS sets, IAM vs bucket targets, duplicate policy names, install credentials | PASSED |
| `//tests/install_smoke:smoke_test` | kind, namespace `storage`: provisioning in the pod; alice and anonymous access through the Service from other pods; a second install keeps credentials and data | PASSED |

## Known limitations

- `python3` is required on the host: the validation actions, the launcher, the image writer and the install.
- No linux_arm64 server at the pinned version (conda-forge has no build).
- One server per test: no distributed (multi-node) mode, no site replication, no KMS / SSE-KMS, no LDAP / OpenID.
- Lifecycle transitions aren't loaded anywhere (no remote tier).
- The install is one replica; seed objects and event notifications are test-time only.
- `minio_test` wraps `sh_test`; other languages use `minio_server` through rules_itest.
