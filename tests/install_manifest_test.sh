#!/usr/bin/env bash
# minio_install's generated manifests: objects, image, probes, the
# credentials from the Secret, emptyDir by default, a PVC with `storage`.
# Argv: <default manifest> <manifest with storage + image>
set -euo pipefail
python3 - "$1" "$2" <<'PY'
import json, sys
def docs(path):
    return [json.loads(d) for d in open(path).read().split("---\n") if d.strip()]
a, b = docs(sys.argv[1]), docs(sys.argv[2])
kinds = lambda ds: [(d["kind"], d["metadata"]["name"]) for d in ds]
assert kinds(a) == [("Service", "minio"), ("Service", "minio-console"), ("Deployment", "minio")], kinds(a)
assert kinds(b) == [("Service", "minio"), ("Service", "minio-console"),
                    ("PersistentVolumeClaim", "minio-data"), ("Deployment", "minio")], kinds(b)
for d in a + b:
    assert "namespace" not in d["metadata"], d["metadata"]
dep = a[-1]["spec"]["template"]["spec"]
c = dep["containers"][0]
assert c["image"] == "rules-minio/minio:2025-10-15" and c["imagePullPolicy"] == "IfNotPresent", c["image"]
assert c["command"] == ["/usr/bin/minio"] and c["args"][:2] == ["server", "/data"], c["args"]
env = {e["name"]: e for e in c["env"]}
assert env["MINIO_ROOT_PASSWORD"]["valueFrom"]["secretKeyRef"] == {"name": "minio", "key": "rootPassword"}
assert env["MINIO_SITE_REGION"]["value"] == "us-east-1"
assert c["readinessProbe"]["httpGet"]["path"] == "/minio/health/ready"
assert {v["name"]: list(v)[1] for v in dep["volumes"]} == {"data": "emptyDir", "tmp": "emptyDir"}
assert dep["securityContext"]["runAsNonRoot"] is True and c["securityContext"]["readOnlyRootFilesystem"] is True
bdep = b[-1]["spec"]["template"]["spec"]
assert bdep["containers"][0]["image"] == "registry.example/minio:1"
assert bdep["volumes"][0] == {"name": "data", "persistentVolumeClaim": {"claimName": "minio-data"}}
assert b[2]["spec"]["resources"]["requests"]["storage"] == "5Gi"
assert {e["name"]: e.get("value") for e in bdep["containers"][0]["env"]}["MINIO_SITE_REGION"] == "eu-central-1"
print("PASS")
PY
