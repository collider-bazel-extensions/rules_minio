# rules_minio design

rules_minio follows rules_valkey's shape: a conda-forge toolchain, a Python launcher behind every rule, a watching `sh_test` trampoline and an itest-shaped cluster install. This file records where MinIO pushed it elsewhere, and why.

## Where the binaries come from

MinIO's community edition went source-only in 2025: `dl.min.io` answers 410, its images on quay.io and Docker Hub can't be pulled anonymously, and `minio/minio` on GitHub is archived. Its last release is `RELEASE.2025-10-15T17-29-55Z`, a security fix.

conda-forge still builds that release (`minio-server`) and `mc` (`minio-client` 2025-08-13), with SHA-256s in its repodata. `tools/update_conda_versions.py` (from rules_valkey's, itself from rules_pg's) resolves them, plus `openssl` with its dependencies, per platform into `private/conda_versions.bzl`. The repository rule merges the packages into one tree. Bazel extracts `.conda` (zip) and the inner `.tar.zst` itself, so no host unzip or zstd is needed.

- **minio and mc** are Go PIE executables. They have no `DT_NEEDED` entries, but do have an `INTERP` (`/lib64/ld-linux-x86-64.so.2`): the loader does their relocations. On a host that's the host's loader; in the image it's the one rules_minio ships (below).
- **openssl** is only for TLS test certificates, as in rules_valkey (with a minimal `OPENSSL_CONF`, since the conda build looks for its config at its build prefix).
- **linux_arm64:** conda-forge has no 2025-10-15 `minio-server` build for linux-aarch64 (2025-01-20 has one). Mixing versions per platform would make the same test behave differently by host, so that platform is listed in `MISSING`. Its repo's targets are genrules that fail with the reason. That's clearer than a fetch error, or "no matching toolchain".
- **Version names:** the server's release date (`2025-10-15`), not conda's `2025.10.15.17.29.55`. `RELEASES` maps one to the other, and `version_test` checks that the binary reports the matching `RELEASE.…` tag.
- **The extension** uses the root module's `minio.version()` tag if there is one, else the pinned default. So a consumer needs no extension setup at all, unlike rules_valkey, where the tag is required.

## Build-time checks: why two stages

MinIO's policy parser (and its lifecycle parser) ignore unknown JSON keys. A misspelled `Conditon` is dropped, and the stored policy then grants without the condition. A misspelled `Statment` drops every statement. rules_kyverno found the same class of problem in Kyverno, and solved it the same way:

1. **Strict keys, in Python, without a server.** These are the keys of the IAM policy grammar MinIO reads (`Version`, `Id`, `Statement`; `Sid`, `Effect`, `Principal`, `NotPrincipal`, `Action`, `NotAction`, `Resource`, `NotResource`, `Condition`), and the lifecycle rule tree as `mc ilm rule export` writes it. `difflib` suggests the closest known key. Condition operators and keys are left to MinIO, which knows them.
2. **MinIO loads every document** that passed stage 1, in a throwaway server on a free 127.0.0.1 port. It starts in about 0.4 s and needs no network, so it works in the sandbox with network blocked. MinIO is strict where it matters:
   - unknown actions;
   - resources that aren't ARNs;
   - condition keys that don't apply to an action (`s3:x-amz-server-side-encryption` with `s3:AbortMultipartUpload`);
   - empty condition values;
   - a bucket policy without a `Principal`, or for another bucket.

   The message is the cause from `mc --json`, which is MinIO's own text.

- **Bucket policies** must name exactly one bucket in `Resource`. The check creates that bucket and runs `mc anonymous set-json` on it. The hermetic server and the install read the bucket from the document too, so `bucket_policies` needs no bucket mapping.
- **Lifecycle transitions** need a remote tier (`InvalidStorageClass` without one). Neither the check nor the hermetic server can have one, so `Transition` / `NoncurrentVersionTransition` are key-checked and taken out before MinIO loads the rules; the server's log says so.
- One server start per target, so a target with many files costs about 0.5 s plus about 0.05 s per file.

## The hermetic server

`launcher.py serve` does the following:

1. **Ports:** two free ports (API and console). If MinIO reports `port is already in use`, it retries with new ones, up to 5 attempts.
2. **Start:**
   - the drives under `<state>/data`: one directory, or `drive{1...N}` (MinIO's ellipsis) for one erasure set. In erasure mode MinIO refuses drives on the root filesystem ("drive not found, will be retried"), where a CI runner's sandbox is, so `MINIO_CI_CD=on` is set with several drives;
   - `--certs-dir <state>/certs`, always. Without it MinIO reads `~/.minio/certs`. Under TLS that dir holds `public.crt`, `private.key` and `CAs/`;
   - the environment: the caller's, minus every `MINIO_*`, `MC_*` and `AWS_*` variable (a sourced env file sets them), plus root credentials, `MINIO_SITE_REGION`, `MINIO_UPDATE=off`, `HOME=<state>`, the webhook target and `server_env`.
3. **Readiness:** `GET /minio/health/ready` returns 200 (over TLS with the test CA). Two caveats:
   - With several drives on a slow machine (CI), it can answer a moment before the object layer is up, and requests then fail with `Server not initialized yet`. Every `mc` call (here and in the install) retries that error for up to 30 s.
   - MinIO binds the console port only *after* the API is ready, and exits if a parallel test took that port meanwhile. So readiness also waits for the console port to accept connections. A clash then happens before "ready", and the start is retried with new ports.
   - MinIO prints its startup banner slightly *after* this, so nothing reads the port from its log.
4. **Provisioning** through `mc --json` with its own `--config-dir` (the test CA under `certs/CAs/`). The order:
   - buckets: `mb --with-lock` for object lock (which implies versioning), `version enable`;
   - IAM policies;
   - users, with random 32-hex secret keys, and their attached policies;
   - bucket policies;
   - lifecycle rules;
   - seed objects (`mc cp`, recursive for directories);
   - event subscriptions last, so seeding sends none.

   A failing step stops the server, logs `stopped minio (port N)`, and exits 1.
5. **The env file**, written atomically. It holds the MinIO variables and the standard `AWS_*` ones: `AWS_ENDPOINT_URL(_S3)` is read by current AWS SDKs and CLI v2, `AWS_CA_BUNDLE` by the SDKs. It also holds `MC_HOST_minio`, and `MC`, an `mc` wrapper with the config dir baked in that the trampoline puts on `PATH`.
6. **Control endpoint** `POST /stop` (SIGTERM; MinIO drains) and `/start`:
   - start uses the same argv and environment, so the same port, drives, credentials and TLS;
   - ports are bind-checked first, with 5 retries 0.2 s apart and a 500 naming the port;
   - drives persist, so a restarted server has its buckets, objects, policies and users.

**Event notifications** use one webhook target, `RULES`, configured by environment (`MINIO_NOTIFY_WEBHOOK_ENABLE_RULES`, `…_ENDPOINT_RULES`). Its endpoint is a small HTTP server in the launcher, started before MinIO, which probes it.
- Subscriptions: `mc event add minio/<bucket> arn:minio:sqs:<region>:RULES:webhook --event …`.
- Each record becomes one JSON line: `event`, `bucket`, the URL-decoded `key`, `size`, and the raw `record`, so shell tests can match without parsing S3 event JSON.
- MinIO delivers asynchronously; `minio_wait_event` polls the file.

**Shutdown and watching** work as in rules_valkey:
- signal handlers are installed before the start;
- once the server is ready, a signal only terminates it, and arms a kill timer;
- a server exiting on its own (not through the control endpoint) ends the launcher with its status;
- the trampoline runs the test in the background, polls both pids (bash 3.2: no `wait -n`), and if the server dies first, kills the test's process tree and fails with the status and log tail.

**Analysis-time checks** catch the mistakes that would otherwise surface as a failed start:
- bucket names follow S3 rules;
- every bucket referred to by `versioned`, `object_lock`, `events`, `lifecycle` or `seed` is in `buckets`;
- user names are valid, and their policies are in `policies` or built in;
- event types are known;
- `drives` is in range;
- credentials are long enough and safe in a URL;
- TLS files come all three or none;
- IAM vs bucket policy targets go in the right attribute.

**Seed paths** are package-relative, the most predictable choice: a file keeps its path relative to its own package under `bucket[/prefix]`. A directory (tree artifact) is copied recursively.

## The image

`minio_image` writes the `docker save` format itself (`private/image.py`). That's what `kind load image-archive`, `docker load` and `podman load` read: `manifest.json`, a config blob, and one layer.
- **Contents:** `minio`, `mc`, the glibc loader at the binaries' `INTERP` path, `/etc/passwd` and `/etc/group` (root, minio 1000), `/tmp` and `/data` (1777). `HOME=/tmp`, because MinIO looks up its config dir and fails without one. The user is 1000.
- **Determinism:** every entry has mtime 0 and root ownership, and the JSON is canonical, so the same inputs give the same bytes and image ID (`image_test` rebuilds and compares).
- **No rules_oci:** no base image is needed, the format is small, and it avoids a registry pull at build time and a dependency on every consumer.
- **The loader** comes from conda-forge's `sysroot_linux-*` 2.28 package (about 24 MB, fetched only when an image is built), in its own `minio_loader_<plat>` repo.

## The cluster install

The official chart (`minio-5.4.0` from charts.min.io) is still downloadable, but doesn't fit:
- its Deployment runs `/bin/sh -ce /usr/bin/docker-entrypoint.sh minio server …`;
- buckets, users and policies are created by post-install Jobs running shell scripts in an `mc` image.

Both images are gone, and the rules_minio image has no shell. So the manifest is generated (`launcher.py manifest`): two Services, a single-replica `Recreate` Deployment and, with `storage`, a PVC. It's JSON documents, which is YAML, and readable in a diff. `command: [/usr/bin/minio]` also works with an image that has an entrypoint script, e.g. a mirror of an old upstream image.

Provisioning needs the server running, so it can't be part of `kubectl apply`. `kubectl_apply` (rules_kubectl) can wait only for rollouts and CRDs. So `minio_install` follows rules_vault's HA install: its own launcher (`launcher.py install`) does the following.

1. **Namespace**, then the Secret `minio`: `root_*` if given, else the stored values, else `minioadmin` and a random password. Credentials go into `MC_HOST_local` through `$(VAR)` expansion in the pod spec, which can't URL-encode, so they're restricted to URL-safe characters.
2. **Apply** with `--server-side --force-conflicts`. The marker ConfigMap `minio-provisioned` is deleted first, so a re-install isn't healthy until it's done again. Then `rollout status deploy/minio`; on failure, pods, the Deployment description and logs are printed.
3. **Provision** through `kubectl exec deploy/minio -c minio -- /usr/bin/mc --config-dir /tmp/.mc --json …`. The image has no shell or tar, so `kubectl cp` can't deliver documents. `mc anonymous set-json` can't read a pipe (it gets EOF), so each document is first written into the pod's `/tmp` with `mc pipe <local path>`, fed over `kubectl exec -i`. Lifecycle rules go straight to `mc ilm rule import`'s stdin. It is idempotent:
   - `mb --ignore-existing`;
   - `policy create` overwrites;
   - `policy attach` of an attached policy succeeds;
   - users' keys are reused from the Secret `minio-users`.
4. **Marker:** writes `minio-provisioned`, then idles until SIGTERM (the `itest_service.exe` contract, as `kubectl_apply` does).

`minio_install_health_check` exits 0 once the marker exists.

## Tests

- `//tests/...` needs no container runtime.
- Most tests are `minio_test`s against real servers. `check_test` runs the validation action directly on good and bad documents, and the analysis tests cover the attribute checks.
- The failure modes have their own tests: a server that can't start, failing provisioning (server stopped), a readiness timeout, a server dying mid-test, cleanup at the end of a test, and restarts with a held port.
- `tests/install_smoke` is the only test needing Docker or podman. It runs kind with the image loaded, then the install, then checks from other pods, then a second install.
