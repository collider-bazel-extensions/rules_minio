#!/usr/bin/env python3
"""Resolve the conda-forge packages for rules_minio's hermetic toolchain
and emit private/conda_versions.bzl.
(Adapted from rules_valkey's tool, itself from rules_pg's.)

Maintainer usage:
    python3 tools/update_conda_versions.py --refresh \
        2025-10-15=2025.10.15.17.29.55,2025.08.13.08.35.41 \
        > private/conda_versions.bzl

Each argument is VERSION=SERVER,MC: the rules_minio version name (the
server's release date) and the conda-forge versions of minio-server and
minio-client. For each (version, supported platform) the script:
  1. Fetches conda-forge's repodata for that platform (and noarch).
  2. Picks the newest build of minio-server and minio-client of exactly
     those versions, and the newest openssl (the launcher makes TLS test
     certificates with it).
  3. BFS-expands their transitive `depends`, picking the highest version
     matching each constraint. (minio and mc have none; openssl brings
     ca-certificates and, on Linux, the GCC runtime.)
  4. Emits CONDA_CLOSURES[(version, platform)]. A platform where
     minio-server or minio-client has no build of that version is left
     out and listed in MISSING (the repository rule fails clearly).

It also pins IMAGE_LOADERS: the glibc dynamic loader for minio_image,
from conda-forge's sysroot_linux-* package (the binaries need nothing
else from libc).

Virtual packages (names starting with `__`, like `__glibc`) are
skipped: they are system constraints, not real packages.

The repodata cache lives in `~/.cache/rules_minio_conda_cache/`. Pass
`--refresh` when bumping versions: a stale cache silently pins whatever
was newest when it was filled. The cache's age is printed on every run.
"""

import argparse
import functools
import hashlib
import json
import os
import re
import sys
import time
import urllib.request
from pathlib import Path

CACHE_DIR = Path.home() / ".cache" / "rules_minio_conda_cache"
CONDA_FORGE_BASE = "https://conda.anaconda.org/conda-forge"
REFRESH = False  # set by --refresh

PLATFORMS = {
    "linux_amd64":  "linux-64",
    "linux_arm64":  "linux-aarch64",
    "darwin_amd64": "osx-64",
    "darwin_arm64": "osx-arm64",
}


def _http_get(url: str, binary: bool = False) -> bytes | str:
    req = urllib.request.Request(url, headers={"User-Agent": "rules_minio-update_conda_versions/1.0"})
    with urllib.request.urlopen(req) as resp:
        data = resp.read()
    return data if binary else data.decode("utf-8")


@functools.lru_cache(maxsize=None)
def _fetch_repodata(conda_platform: str) -> dict:
    """Fetch conda-forge's repodata.json for one platform. Cached on disk."""
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache_path = CACHE_DIR / f"repodata_{conda_platform}.json"
    if cache_path.exists() and not REFRESH:
        age_days = (time.time() - cache_path.stat().st_mtime) / 86400
        print(f"[cache] repodata for {conda_platform} is {age_days:.0f} days old "
              f"(pass --refresh to re-fetch)", file=sys.stderr)
        return json.loads(cache_path.read_text())
    print(f"[fetch] repodata for {conda_platform} (one-time, ~50-200MB)…", file=sys.stderr)
    body = _http_get(f"{CONDA_FORGE_BASE}/{conda_platform}/repodata.json")
    data = json.loads(body)
    cache_path.write_text(body)
    return data


def _parse_version(v: str) -> tuple:
    """A loose semver-ish key for sorting conda version strings.

    Conda versions are a superset of semver (`16.13`, `1.2.13rc1`,
    `3.0.7+deb`, …). For our purposes, take the leading dotted-int
    segments and ignore the rest.
    """
    parts = []
    for chunk in re.split(r"[.+-]", v):
        m = re.match(r"^(\d+)", chunk)
        if m:
            parts.append(int(m.group(1)))
        else:
            break
    return tuple(parts) or (0,)


def _matches_constraint(v: str, constraint: str) -> bool:
    """Check `v` against a conda-style version constraint, e.g.
    ">=1.19.3,<1.20.0a0". Returns True on match.

    Constraints support: ==, !=, >=, <=, >, <, =, and comma-separated
    AND. Wildcards (`*`) supported in `==1.2.*` form. Anything fancier
    (`(== or >=)`) falls back to True; that's a known loose match —
    the maintainer reviews the emitted pin set.
    """
    if not constraint:
        return True
    v_parts = _parse_version(v)
    for term in [t.strip() for t in constraint.split(",")]:
        if not term:
            continue
        m = re.match(r"^(==|!=|>=|<=|>|<|=)?\s*(.+)$", term)
        if not m:
            continue
        op = m.group(1) or "=="
        bound_raw = m.group(2).strip()
        if "*" in bound_raw:
            prefix = bound_raw.rstrip(".*")
            if op in ("==", "="):
                if not v.startswith(prefix):
                    return False
            continue
        b_parts = _parse_version(bound_raw)
        # Pad to equal length for comparison.
        n = max(len(v_parts), len(b_parts))
        a = v_parts + (0,) * (n - len(v_parts))
        b = b_parts + (0,) * (n - len(b_parts))
        if op == "==" or op == "=":
            if a != b:
                return False
        elif op == "!=":
            if a == b:
                return False
        elif op == ">=":
            if a < b:
                return False
        elif op == "<=":
            if a > b:
                return False
        elif op == ">":
            if a <= b:
                return False
        elif op == "<":
            if a >= b:
                return False
    return True


def _pick_best(repodata: dict, name: str, constraint: str) -> tuple[str, dict] | None:
    """Find the highest-version package on conda-forge that matches
    name + constraint. Returns (filename, package_info) or None.
    """
    candidates = []
    # repodata has two payload buckets: `packages` (legacy .tar.bz2)
    # and `packages.conda` (newer zstd-compressed .conda). Prefer
    # the latter — that's what we extract.
    for fname, info in repodata.get("packages.conda", {}).items():
        if info.get("name") != name:
            continue
        if not _matches_constraint(info.get("version", ""), constraint):
            continue
        candidates.append((fname, info))
    if not candidates:
        for fname, info in repodata.get("packages", {}).items():
            if info.get("name") != name:
                continue
            if not _matches_constraint(info.get("version", ""), constraint):
                continue
            candidates.append((fname, info))
    if not candidates:
        return None
    # Sort by (version, build_number, timestamp) descending.
    candidates.sort(
        key=lambda c: (
            _parse_version(c[1].get("version", "0")),
            c[1].get("build_number", 0),
            c[1].get("timestamp", 0),
        ),
        reverse=True,
    )
    return candidates[0]


# The image loaders: one glibc sysroot per Linux platform (noarch).
SYSROOTS = {
    "linux_amd64": ("sysroot_linux-64", "x86_64-conda-linux-gnu/sysroot/lib64/ld-2.28.so",
                    "lib64/ld-linux-x86-64.so.2"),
    "linux_arm64": ("sysroot_linux-aarch64", "aarch64-conda-linux-gnu/sysroot/lib64/ld-2.28.so",
                    "lib/ld-linux-aarch64.so.1"),
}
SYSROOT_VERSION = "2.28"


def _entry(name, pick, subdir):
    fname, info = pick
    sha = info.get("sha256") or _compute_sha256(f"{CONDA_FORGE_BASE}/{subdir}/{fname}")
    return {
        "name":    name,
        "version": info.get("version", ""),
        "build":   info.get("build", ""),
        "url":     f"{CONDA_FORGE_BASE}/{subdir}/{fname}",
        "sha256":  sha,
    }


def _resolve_closure(conda_platform: str, roots: list) -> list | None:
    """BFS the closure of `roots` [(name, constraint)] on conda_platform.
    None if a root has no matching build there."""
    repodata = _fetch_repodata(conda_platform)
    noarch_repodata = _fetch_repodata("noarch")

    def best(name: str, constraint: str):
        pick = _pick_best(repodata, name, constraint)
        if pick is not None:
            return pick, conda_platform
        pick = _pick_best(noarch_repodata, name, constraint)
        if pick is not None:
            return pick, "noarch"
        return None, None

    chosen = {}
    queue = []
    for name, constraint in roots:
        pick, subdir = best(name, constraint)
        if not pick:
            return None
        chosen[name] = (pick, subdir)
        queue.append(pick)
    while queue:
        _fname, info = queue.pop(0)
        for dep in info.get("depends", []):
            d = dep.split("::", 1)[-1].strip()
            parts = d.split(None, 1)
            name = parts[0]
            constraint = parts[1] if len(parts) > 1 else ""
            if name.startswith("__") or name in chosen:
                continue
            pick, subdir = best(name, constraint)
            if not pick:
                print(f"[warn] {conda_platform}: no candidate for {name} {constraint!r}", file=sys.stderr)
                continue
            chosen[name] = (pick, subdir)
            queue.append(pick)
    return sorted((_entry(n, p, s) for n, (p, s) in chosen.items()), key=lambda e: e["name"])


def _compute_sha256(url: str) -> str:
    body = _http_get(url, binary=True)
    return hashlib.sha256(body).hexdigest()


def _pin_lines(e, indent):
    pad = " " * indent
    return [pad + "{",
            f'{pad}    "name":    "{e["name"]}",',
            f'{pad}    "version": "{e["version"]}",',
            f'{pad}    "build":   "{e["build"]}",',
            f'{pad}    "url":     "{e["url"]}",',
            f'{pad}    "sha256":  "{e["sha256"]}",',
            pad + "},"]


def _emit_bzl(specs, closures, missing, loaders) -> str:
    argv = " ".join(f"{v}={s},{m}" for v, s, m in specs)
    lines = [
        '"""Auto-generated conda-forge pins for hermetic MinIO.',
        '',
        f'Generated by `python3 tools/update_conda_versions.py {argv}`',
        'against conda-forge\'s repodata.json. Each closure holds minio-server',
        '(`minio`), minio-client (`mc`) and openssl with its dependencies, for',
        'one platform. The repository rule merges every package into one tree.',
        '',
        'Maintainer flow:',
        f'    python3 tools/update_conda_versions.py --refresh {argv} \\',
        '        > private/conda_versions.bzl',
        '"""',
        '',
        '# version -> (minio-server, minio-client) conda versions',
        'RELEASES = {',
    ]
    for v, s, m in specs:
        lines.append(f'    "{v}": ("{s}", "{m}"),')
    lines += ['}', '', '# (version, platform) -> list of {name, version, build, url, sha256}',
              'CONDA_CLOSURES = {']
    for v, _, _ in specs:
        for plat in PLATFORMS:
            entries = closures.get((v, plat))
            if not entries:
                continue
            lines.append(f'    ("{v}", "{plat}"): [')
            for e in entries:
                lines += _pin_lines(e, 8)
            lines.append('    ],')
    lines += ['}', '', '# (version, platform) -> the package with no build there',
              'MISSING = {']
    for (v, plat), what in sorted(missing.items()):
        lines.append(f'    ("{v}", "{plat}"): "{what}",')
    lines += ['}', '', '# platform -> the sysroot package, its ld.so, and where the image puts it',
              'IMAGE_LOADERS = {']
    for plat, (e, member, dest) in loaders.items():
        lines.append(f'    "{plat}": {{')
        lines += _pin_lines(e, 4)[1:-1]
        lines.append(f'        "member":  "{member}",')
        lines.append(f'        "dest":    "{dest}",')
        lines.append('    },')
    lines += ['}', '']
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("specs", nargs="+", metavar="VERSION=SERVER,MC",
                        help="e.g. 2025-10-15=2025.10.15.17.29.55,2025.08.13.08.35.41")
    parser.add_argument("--refresh", action="store_true",
                        help="re-fetch conda-forge repodata instead of using the on-disk cache")
    args = parser.parse_args()
    global REFRESH
    REFRESH = args.refresh

    specs = []
    for s in args.specs:
        v, _, rest = s.partition("=")
        server, _, mc = rest.partition(",")
        if not (v and server and mc):
            parser.error(f"{s!r}: want VERSION=SERVER,MC")
        specs.append((v, server, mc))
    closures, missing = {}, {}
    for v, server, mc in specs:
        for plat_key, conda_plat in PLATFORMS.items():
            print(f"[resolve] {v} (minio-server {server}, minio-client {mc}) {plat_key}", file=sys.stderr)
            roots = [("minio-server", f"=={server}"), ("minio-client", f"=={mc}"), ("openssl", "")]
            closure = _resolve_closure(conda_plat, roots)
            if closure is None:
                repodata = _fetch_repodata(conda_plat)
                what = next(f"{n} {c[2:]}" for n, c in roots[:2] if not _pick_best(repodata, n, c))
                print(f"          → no {what} on {conda_plat}", file=sys.stderr)
                missing[(v, plat_key)] = what
                continue
            print(f"          → {len(closure)} packages", file=sys.stderr)
            closures[(v, plat_key)] = closure
    noarch = _fetch_repodata("noarch")
    loaders = {}
    for plat, (pkg, member, dest) in SYSROOTS.items():
        pick = _pick_best(noarch, pkg, f"=={SYSROOT_VERSION}")
        if not pick:
            raise RuntimeError(f"no {pkg} {SYSROOT_VERSION} on conda-forge/noarch")
        loaders[plat] = (_entry(pkg, pick, "noarch"), member, dest)
    sys.stdout.write(_emit_bzl(specs, closures, missing, loaders))


if __name__ == "__main__":
    main()
