#!/usr/bin/env bash
# minio_image: a docker-archive with one layer holding the binaries, the
# loader and the fixed tree; deterministic metadata; the binaries run with
# only that loader (no host libc). Argv: <image.tar> <image.py> <minio> <mc> <loader>
set -euo pipefail
python3 - "$@" <<'PY'
import hashlib, io, json, os, subprocess, sys, tarfile, tempfile
img, builder, minio, mc, loader = sys.argv[1:]
t = tarfile.open(img)
m = json.load(t.extractfile("manifest.json"))
assert len(m) == 1 and m[0]["RepoTags"] == ["rules-minio/minio:2025-10-15"], m
cfg = json.load(t.extractfile(m[0]["Config"]))
assert cfg["architecture"] == "amd64" and cfg["os"] == "linux", cfg
assert cfg["config"]["Entrypoint"] == ["/usr/bin/minio"] and "HOME=/tmp" in cfg["config"]["Env"]
assert cfg["config"]["User"] == "1000:1000"
layer_blob = t.extractfile(m[0]["Layers"][0]).read()
assert cfg["rootfs"]["diff_ids"] == ["sha256:" + hashlib.sha256(layer_blob).hexdigest()]
layer = tarfile.open(fileobj=io.BytesIO(layer_blob))
entries = {i.name: i for i in layer.getmembers()}
for name, mode in (("usr/bin/minio", 0o755), ("usr/bin/mc", 0o755),
                   ("lib64/ld-linux-x86-64.so.2", 0o755), ("tmp", 0o1777), ("data", 0o1777)):
    assert name in entries and entries[name].mode == mode, (name, entries.get(name))
assert all(i.mtime == 0 and i.uid == 0 and i.gid == 0 for i in entries.values())
assert layer.extractfile("usr/bin/minio").read() == open(minio, "rb").read()
assert b"minio:x:1000:1000" in layer.extractfile("etc/passwd").read()
# Same inputs, same bytes.
with tempfile.TemporaryDirectory() as d:
    again = os.path.join(d, "again.tar")
    subprocess.run([sys.executable, builder, "--arch", "amd64", "--tag", "rules-minio/minio:2025-10-15",
                    "--minio", minio, "--mc", mc, "--loader", loader,
                    "--loader-dest", "lib64/ld-linux-x86-64.so.2", again], check=True)
    assert open(again, "rb").read() == open(img, "rb").read(), "not deterministic"
# The image's loader alone runs the binary.
out = subprocess.run([loader, minio, "--version"], capture_output=True, text=True, check=True).stdout
assert out.startswith("minio version RELEASE.2025-10-15T17-29-55Z"), out
print("PASS")
PY
