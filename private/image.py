#!/usr/bin/env python3
"""Writes a docker-archive image tarball (the `docker save` format, which
`kind load image-archive`, `docker load` and `podman load` read) holding
MinIO and nothing else of note:

  /usr/bin/minio, /usr/bin/mc      the pinned conda-forge binaries
  /<loader>                        the glibc dynamic loader (all they need:
                                   PIE executables with no DT_NEEDED)
  /etc/passwd, /etc/group          root and minio (1000)
  /tmp, /data                      writable (1777)

  image.py --arch amd64 --tag REF --minio F --mc F --loader F --loader-dest PATH OUT

One layer, every entry with mtime 0 and root ownership, so the same
inputs give the same tarball (and image ID).
"""

import argparse
import hashlib
import io
import json
import os
import sys
import tarfile


def _info(name, kind, mode, size=0):
    t = tarfile.TarInfo(name)
    t.type, t.mode, t.size = kind, mode, size
    t.mtime, t.uid, t.gid, t.uname, t.gname = 0, 0, 0, "", ""
    return t


def layer(files, loader_dest):
    """The layer tar: (path → source file) plus the fixed tree."""
    buf = io.BytesIO()
    text = {
        "etc/passwd": "root:x:0:0:root:/root:/sbin/nologin\nminio:x:1000:1000:minio:/tmp:/sbin/nologin\n",
        "etc/group": "root:x:0:\nminio:x:1000:\n",
    }
    dirs = {"etc": 0o755, "tmp": 0o1777, "data": 0o1777, "usr": 0o755, "usr/bin": 0o755,
            os.path.dirname(loader_dest): 0o755}
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for d in sorted(dirs):
            tar.addfile(_info(d + "/", tarfile.DIRTYPE, dirs[d]))
        for path in sorted(set(files) | set(text)):
            if path in text:
                data = text[path].encode()
                tar.addfile(_info(path, tarfile.REGTYPE, 0o644, len(data)), io.BytesIO(data))
            else:
                with open(files[path], "rb") as f:
                    tar.addfile(_info(path, tarfile.REGTYPE, 0o755, os.path.getsize(files[path])), f)
    return buf.getvalue()


def main(argv):
    p = argparse.ArgumentParser()
    p.add_argument("--arch", required=True)
    p.add_argument("--tag", required=True)
    p.add_argument("--minio", required=True)
    p.add_argument("--mc", required=True)
    p.add_argument("--loader", required=True)
    p.add_argument("--loader-dest", required=True)
    p.add_argument("out")
    a = p.parse_args(argv)
    data = layer({"usr/bin/minio": a.minio, "usr/bin/mc": a.mc, a.loader_dest: a.loader}, a.loader_dest)
    diff_id = "sha256:" + hashlib.sha256(data).hexdigest()
    config = json.dumps({
        "architecture": a.arch,
        "os": "linux",
        "config": {
            "Env": ["PATH=/usr/bin", "HOME=/tmp"],
            "Entrypoint": ["/usr/bin/minio"],
            "Cmd": ["server", "/data"],
            "User": "1000:1000",
            "WorkingDir": "/tmp",
            "ExposedPorts": {"9000/tcp": {}, "9001/tcp": {}},
            "Labels": {"org.opencontainers.image.title": "MinIO (rules_minio)",
                       "org.opencontainers.image.source": "https://github.com/collider-bazel-extensions/rules_minio"},
        },
        "rootfs": {"type": "layers", "diff_ids": [diff_id]},
        "history": [{"created_by": "rules_minio minio_image"}],
    }, sort_keys=True, separators=(",", ":")).encode()
    config_name = hashlib.sha256(config).hexdigest() + ".json"
    layer_name = diff_id[len("sha256:"):] + "/layer.tar"
    manifest = json.dumps([{"Config": config_name, "RepoTags": [a.tag], "Layers": [layer_name]}]).encode()
    with tarfile.open(a.out, "w", format=tarfile.USTAR_FORMAT) as tar:
        for name, blob in ((config_name, config), (layer_name, data), ("manifest.json", manifest)):
            if "/" in name:
                tar.addfile(_info(name.split("/")[0] + "/", tarfile.DIRTYPE, 0o755))
            tar.addfile(_info(name, tarfile.REGTYPE, 0o644, len(blob)), io.BytesIO(blob))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
