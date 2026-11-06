# rules_minio

Bazel rules for [MinIO](https://github.com/minio/minio), the S3-compatible object store. They check policies at build time, run a hermetic MinIO in tests, and install MinIO into a cluster. Three families in one repo:

- **Policies (build time)**
  - `minio_policy` — IAM or bucket policy documents. Unknown keys fail the build (MinIO silently drops them), then MinIO itself loads every document as a validation action, so its own errors fail `bazel build`.
  - `minio_lifecycle` — a bucket lifecycle configuration, checked the same way.
- **Hermetic server (test time)**
  - `minio_server` — a long-running MinIO on a free port with your buckets (versioned, object-locked), IAM policies, users, bucket policies, lifecycle rules, seed objects and event notifications in place. It writes `$TEST_TMPDIR/<name>.env` once ready, including the standard `AWS_*` variables, so S3 SDKs work unchanged. It can serve TLS, use several drives (erasure coding), and be stopped and started again mid-test.
  - `minio_health_check` — pairs with `minio_server` for `itest_service`.
  - `minio_test` — `sh_test` macro with an auto-launched server and `mc` helpers.
- **Cluster install (kind / production-shaped)**
  - `minio_image` / `@rules_minio//:image` — a container image of the same pinned binaries, as a tarball. MinIO no longer publishes images for pulling.
  - `minio_install` — a single-replica Deployment and Services, then buckets, policies, users, bucket policies and lifecycle rules provisioned through `mc` in the pod.
  - `minio_install_health_check` — paired readiness probe.

No host `minio` or `mc` needed. The binaries come from pinned, SHA-256-verified conda-forge packages, and need nothing from the host beyond libc. The rules need `python3` on the host.

> **About upstream:** MinIO's community edition moved to source-only distribution in 2025: `dl.min.io` returns 410, its images can no longer be pulled, and `minio/minio` is archived. rules_minio uses conda-forge's builds of the final release, `RELEASE.2025-10-15T17-29-55Z` (a security fix), and builds its own image from them.

## Install (Bzlmod)

```python
bazel_dep(name = "rules_minio", version = "0.1.0")
git_override(
    module_name = "rules_minio",
    remote = "https://github.com/collider-bazel-extensions/rules_minio",
    tag = "v0.1.0",
)
```

To pin by archive and integrity instead of a git tag, replace the `git_override` with:

```python
archive_override(
    module_name = "rules_minio",
    urls = ["https://github.com/collider-bazel-extensions/rules_minio/archive/refs/tags/v0.1.0.tar.gz"],
    strip_prefix = "rules_minio-0.1.0",
    integrity = "sha256-Mnou1IzEZT86ZekhBxkD8rt5SYDd7q5zJXWwXf6Elzo=",
)
```

That's all: rules_minio registers its toolchains and fetches the binaries only for the platform a build needs. The `minio` extension honours only the root module's `minio.version(version = "2025-10-15")` tag (the `mod.is_root` guard used across this organization) and uses that version without one.

**Platforms:** linux_amd64, darwin_amd64 and darwin_arm64. conda-forge has no linux_arm64 build of the 2025-10-15 server, so on linux_arm64 the binaries' targets fail with that message.

## Policies

```python
load("@rules_minio//:defs.bzl", "minio_lifecycle", "minio_policy")

minio_policy(
    name = "policies",
    srcs = ["read_data.json", "write_uploads.json"],   # policies read_data, write_uploads
)

minio_policy(
    name = "public_downloads",
    srcs = ["public_downloads.json"],
    type = "bucket",                                    # anonymous access to one bucket
)

minio_lifecycle(
    name = "expire_tmp",
    src = "expire_tmp.json",                            # the `mc ilm rule export` JSON
)
```

- **Names:** each policy is named after its file: `read_data.json` is the policy `read_data`.
- **Unknown keys fail.** MinIO ignores keys it doesn't know, so a typo silently changes a document. A misspelled `Condition` drops the condition, and the policy grants more than written:

  ```
  minio_policy //policies:app:
    policies/app.json: Statement[0].Conditon: unknown field (did you mean 'Condition'?); MinIO would ignore it
  ```

- **Then MinIO decides.** A throwaway MinIO loads every document: `mc admin policy create` for IAM policies, `mc anonymous set-json` on the named bucket for bucket policies, `mc ilm rule import` for lifecycle rules. Its errors fail the build, naming the file:

  ```
  minio_policy //policies:app:
    policies/app.json: MinIO refused it: unsupported action 's3:GetObjects'
    policies/other.json: MinIO refused it: invalid condition key 'aws:usrname'
  ```

  This catches what JSON schemas don't: unknown actions, malformed resources, condition keys that don't apply to an action, a bucket policy without a `Principal`. A bucket policy must name exactly one bucket in its `Resource`.
- **Transitions:** lifecycle `Transition` / `NoncurrentVersionTransition` rules need a remote tier. They are key-checked but not loaded, at build time and on the hermetic server (whose log notes it).
- **Cost and network:** one MinIO start per target, about 0.5 s. Everything runs on 127.0.0.1, so `--sandbox_default_allow_network=false` works.

## Hermetic server

### `minio_test`

```python
load("@rules_minio//:defs.bzl", "minio_test")

minio_test(
    name = "storage_test",
    srcs = ["storage_test.sh"],
    buckets = ["data", "logs", "downloads", "vault"],
    versioned = ["logs"],
    object_lock = ["vault"],
    policies = [":policies"],
    users = {"alice": "read_data", "ops": "readwrite"},
    bucket_policies = [":public_downloads"],
    lifecycle = {":expire_tmp": "logs"},
    seed = {"//testdata:fixtures": "data"},
    events = {"data": "put,delete"},
    data = [":my_service"],
)
```

```sh
# storage_test.sh
source "$MINIO_TESTLIB"
./my_service --s3-endpoint "$AWS_ENDPOINT_URL" &      # AWS_* are set: SDKs just work
minio_wait_object minio/data/out/report.json          # wait for the service to write it
[[ "$(mc cat minio/data/out/report.json)" == '{"ok": true}' ]]
minio_wait_event s3:ObjectCreated out/report.json     # the notification arrived
! minio_as alice cp report.json minio/data/x          # alice can only read
```

What the test sees:

| Variable | |
|---|---|
| `MINIO_ENDPOINT` | `http://127.0.0.1:<port>`, or `https://…` with `tls` |
| `MINIO_HOST`, `MINIO_PORT`, `MINIO_REGION` | the server |
| `MINIO_CONSOLE_URL` | the console (object browser) |
| `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD` | root credentials (default `minioadmin` / `minioadmin`) |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | the root credentials, for S3 SDKs |
| `AWS_ENDPOINT_URL`, `AWS_ENDPOINT_URL_S3` | the endpoint (AWS SDKs and CLI v2 read these) |
| `AWS_REGION`, `AWS_DEFAULT_REGION` | the region |
| `MC_HOST_minio` | `mc`'s alias `minio` for the server |
| `MINIO_USER_<NAME>_ACCESS_KEY`, `MINIO_USER_<NAME>_SECRET_KEY` | per user (`<NAME>` upper-cased, other characters `_`); secret keys are random |
| `MINIO_TLS`, `MINIO_TLS_CA`, `AWS_CA_BUNDLE` | with `tls`: `1`, and the CA to trust |
| `MINIO_EVENTS_FILE` | with `events`: the notifications, one JSON line each |
| `MINIO_CONTROL_URL` | the launcher's control endpoint (`minio_stop` / `minio_start`) |
| `MINIO_LOG`, `MINIO_DATA_DIR` | the server's log and drives |
| `MINIO_SERVER`, `MC` | the binaries; `MC` (also `mc` on `PATH`) is a wrapper with this server's config dir, and CA under TLS |
| `MINIO_TESTLIB` | shell helpers (below) |

| Helper | |
|---|---|
| `mc ARGS…` | the MinIO client; alias `minio` is the server |
| `minio_as USER ARGS…` | `mc` as one of `users` instead of root |
| `minio_wait EXPECTED ARGS…` | waits until `mc ARGS` prints `EXPECTED` |
| `minio_wait_object PATH` | waits until `mc stat PATH` succeeds (`minio/bucket/key`) |
| `minio_wait_event EVENT KEY` | waits for a notification whose event name starts with `EVENT` (`s3:ObjectCreated`, `s3:ObjectRemoved:Delete`) for object `KEY`; prints its JSON line |
| `minio_events` | the notifications so far, one `event bucket key` line each |
| `minio_empty BUCKET…` | removes every object (and version) |
| `minio_stop` | stops the server |
| `minio_start` | starts it again **on the same port**, with the same drives (so the same data), credentials, users and TLS; waits until it's ready |

Waits give up after `$MINIO_WAIT_TIMEOUT` seconds (default 30).

| `minio_test` / `minio_server` argument | Default | |
|---|---|---|
| `buckets` | `[]` | buckets to create |
| `versioned` | `[]` | buckets with versioning |
| `object_lock` | `[]` | buckets with object lock (versioned, as S3 requires) |
| `policies` | `[]` | `minio_policy` targets (`type = "iam"`), created by name |
| `users` | `{}` | user → comma-separated policies, from `policies` or built in (`readonly`, `readwrite`, `writeonly`, `diagnostics`, `consoleAdmin`) |
| `bucket_policies` | `[]` | `minio_policy` targets (`type = "bucket"`), each set on the bucket it names |
| `lifecycle` | `{}` | `minio_lifecycle` target → comma-separated buckets |
| `seed` | `{}` | files → `"bucket"` or `"bucket/prefix"`; each file keeps its path relative to its package (`testdata:fixtures/a.json` → `data/fixtures/a.json`) |
| `events` | `{}` | bucket → comma-separated event types: `put`, `get`, `delete`, `replica`, `ilm`, `scanner` |
| `root_user`, `root_password` | `minioadmin`, `minioadmin` | root credentials (3+ and 8+ characters) |
| `region` | `us-east-1` | `MINIO_SITE_REGION` |
| `drives` | `1` | `1`: one drive; `2`..`16`: one erasure set of that many drives |
| `tls` | `False` | TLS only (plain HTTP is refused) |
| `tls_cert`, `tls_key`, `tls_ca` | generated | your own server certificate (for `127.0.0.1`), key and CA; all three or none |
| `server_env` | `{}` | extra environment for `minio`, e.g. `{"MINIO_API_REQUESTS_MAX": "10"}` |
| `ready_timeout` | `30` | seconds to wait for the server |
| `extra_args` | `[]` | extra `minio server` options |
| `args`, `env`, `data`, `deps`, `size`, `timeout`, `tags`, … | | as for `sh_test` (`minio_test` only) |

Bucket names, every bucket an attribute refers to, user names and their policies, event types and the TLS attributes are checked when the BUILD file is analysed.

**Order and readiness.** The server is ready once `/minio/health/ready` answers. Then, in order: buckets, IAM policies, users, bucket policies, lifecycle rules, seed objects, and last the event notifications (so seeding sends none). Only then is the env file written: about 0.5 s for a provisioned server.

**Failures.** The test fails, names the cause and shows the server's log if MinIO refuses its arguments, exits, or isn't ready within `ready_timeout`, or if a provisioning step fails (with `mc`'s message). The test body never runs.

If the server exits **while the test runs**, other than through `minio_stop`, the test is stopped at once, with everything it started. It fails with the server's exit status and the end of its log:

```
minio_test: the MinIO server exited (status 0) while the test was running; the test was stopped.
minio_test: last lines of …/minio.log:
  …
```

Each test gets its own server, with its own port and drives, so tests are safe under `--jobs=N`. The server is stopped when the test ends. The server ignores the caller's `MINIO_*`, `MC_*` and `AWS_*` variables and `~/.minio`, so a sourced env file or host setup can't leak in.

**Stopping and starting the server.** `minio_stop` and `minio_start` exercise clients that must fail closed while storage is down and recover when it returns:

```sh
source "$MINIO_TESTLIB"
minio_stop
! ./my_client get key               # must fail, not hang or serve stale data
minio_start                         # same port, data, credentials and TLS
[[ "$(./my_client get key)" == v ]]
```

- **Data:** the drives persist, so objects, buckets, policies and users all come back.
- **A taken port:** if another process has taken the port meanwhile, `minio_start` retries 5 times, 0.2 s apart. It then fails with `minio_start: 500: … another process holds port <port> (Address already in use)`, and the server can be started again later.
- **From other languages:** `POST $MINIO_CONTROL_URL/stop` and `/start`.

**Event notifications.** With `events`, MinIO posts notifications to a webhook in the launcher, which appends each record to `MINIO_EVENTS_FILE` as one JSON line: `{"event": "s3:ObjectCreated:Put", "bucket": "data", "key": "a b.txt", "size": 3, "record": {…}}`. The key is URL-decoded; `record` is MinIO's S3 event record as sent.

**TLS.** `tls = True` makes the server TLS-only. Without your own certificates, a throwaway CA and a server certificate for `127.0.0.1` / `localhost` are made at start, with the `openssl` from the toolchain's conda packages. `mc` trusts it automatically. Other clients take `MINIO_TLS_CA` (`AWS_CA_BUNDLE` for AWS SDKs).

### `minio_server` + `minio_health_check` (rules_itest)

```python
minio_server(name = "minio", buckets = ["data"], seed = {":fixtures": "data"}, tags = ["manual"])
minio_health_check(name = "minio_health", server = ":minio", tags = ["manual"])

itest_service(
    name = "minio_svc",
    exe = ":minio",
    health_check = ":minio_health",
)
```

The server writes `$TEST_TMPDIR/minio.env` (named after the target) with the variables above. A service or test in any language reads it, or takes `AWS_ENDPOINT_URL` from a wrapper. SIGTERM stops the server, removes the file and exits 0.

## Cluster install

```python
load("@rules_kind//:defs.bzl", "kind_cluster")
load("@rules_minio//:defs.bzl", "minio_install", "minio_install_health_check")

kind_cluster(name = "cluster", images = ["@rules_minio//:image"])

minio_install(
    name = "minio_install",
    namespace = "storage",
    buckets = ["data", "downloads"],
    versioned = ["data"],
    policies = [":policies"],
    users = {"alice": "read_data"},
    bucket_policies = [":public_downloads"],
    lifecycle = {":expire_tmp": "data"},
    tags = ["manual"],
)
minio_install_health_check(name = "minio_install_health", namespace = "storage", tags = ["manual"])

itest_service(
    name = "minio_install_svc",
    exe = ":minio_install",
    health_check = ":minio_install_health",
    deps = [":kind_svc"],
)
```

- **The image:** `@rules_minio//:image` is a docker-archive tarball (`rules-minio/minio:2025-10-15`) holding the pinned `minio` and `mc`, the glibc dynamic loader (all the binaries need), `/etc/passwd`, `/tmp` and `/data`. It has no base image and no shell; it runs as user 1000. Give it to `kind_cluster(images = …)`. For another cluster, `docker load` / `podman load` it, push it, and set `minio_install(image = "registry.example/minio:…")`.
- **What's applied:**
  - Services `minio` (S3 API, 9000) and `minio-console` (9001);
  - a single-replica Deployment `minio`: non-root, read-only root filesystem, readiness `/minio/health/ready`;
  - with `storage = "10Gi"`, a PersistentVolumeClaim for `/data`; otherwise an emptyDir.

  The objects carry no namespace, so `namespace` (default `minio`) places them. The manifest is the `manifest` output group.
- **Credentials:** the root credentials live in the Secret `minio`. They are `root_user` / `root_password` if given, else whatever an earlier install stored, else `minioadmin` and a generated password. Users' secret keys are generated and kept in the Secret `minio-users`, one key per user. Credentials may only use letters, digits and `. _ ~ -`.
- **Provisioning:** once `deploy/minio` has rolled out, buckets, policies, users, bucket policies and lifecycle rules are created through `kubectl exec deploy/minio -- mc`. Then the ConfigMap `minio-provisioned` is written, which `minio_install_health_check` waits for. A second install keeps the credentials and the data.
- **kubectl:** both read `KUBECONFIG`, and `KUBECTL` (else `kubectl` on `PATH`), from the environment, as rules_kubectl does. rules_kind's env file sets them.
- **Smoke test:** `tests/install_smoke/` installs into kind (namespace `storage`). It checks the provisioning in the pod, then from other pods through the Service: alice reads with her key from `minio-users` but can't write, and anonymous reads work for `downloads` only. Last, it checks that a second install keeps credentials and data.

## Pinned versions

| Component | Version | Source |
|---|---|---|
| minio (server) | `RELEASE.2025-10-15T17-29-55Z` | conda-forge `minio-server` 2025.10.15.17.29.55 |
| mc (client) | `RELEASE.2025-08-13T08-35-41Z` | conda-forge `minio-client` 2025.08.13.08.35.41 |
| openssl (test certificates) | 4.1.0 | conda-forge |
| glibc loader (image) | 2.28 | conda-forge `sysroot_linux-64` / `sysroot_linux-aarch64` |

To re-pin, run `python3 tools/update_conda_versions.py --refresh 2025-10-15=2025.10.15.17.29.55,2025.08.13.08.35.41 > private/conda_versions.bzl`. It resolves the packages for all four platforms from conda-forge's repodata, with SHA-256s, and lists platforms without a build as `MISSING`.

## Development

```sh
bazel test //tests/...                                                # no container runtime
bazel test //tests/install_smoke:smoke_test --test_output=streamed    # needs Docker or podman
```

See [DESIGN.md](DESIGN.md) for the architecture and trade-offs.
