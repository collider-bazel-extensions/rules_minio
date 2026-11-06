"""Providers exposed by rules_minio."""

MinioBinaryInfo = provider(
    doc = "MinIO toolchain binaries (one conda-forge closure).",
    fields = {
        "version": "string — pinned MinIO version (the server's release date, e.g. 2025-10-15)",
        "server":  "File — minio",
        "mc":      "File — mc, the MinIO client",
        "openssl": "File — the closure's openssl CLI (test certificates)",
        "files":   "depset of File — the binaries plus the shared libraries " +
                   "openssl loads through its RPATH; every runfiles tree or " +
                   "action that runs a binary needs all of it",
    },
)

MinioPolicyInfo = provider(
    doc = "Checked policy documents (minio_policy).",
    fields = {
        "type":     "string — \"iam\" (user / group policies) or \"bucket\" (bucket policies)",
        "policies": "dict of string → File: policy name (the file's basename " +
                    "without .json) → the document",
        "files":    "depset of File — the documents",
    },
)

MinioLifecycleInfo = provider(
    doc = "A checked bucket lifecycle configuration (minio_lifecycle).",
    fields = {
        "config": "File — the configuration (mc ilm export JSON)",
    },
)
