#!/usr/bin/env python3
"""Runs MinIO for rules_minio. Modes:

  launcher.py check --minio BIN --mc BIN --type iam|bucket|lifecycle
                    --label L --marker OUT FILE...
      minio_policy / minio_lifecycle's validation action. First a strict
      field check: MinIO silently drops keys it doesn't know (a misspelled
      `Conditon` makes the policy broader than written), so unknown keys
      fail, with the closest known one suggested. Then a throwaway MinIO
      on a free 127.0.0.1 port loads every document with mc (IAM policies
      by `mc admin policy create`, bucket policies by `mc anonymous
      set-json` on the bucket they name, lifecycle rules by `mc ilm rule
      import`), so MinIO's own parser has the last word. Writes OUT.

  launcher.py serve --minio BIN --mc BIN --env-file PATH --state-dir DIR
                    --ready-timeout S [options] [-- EXTRA_SERVER_ARGS...]
      minio_server. One MinIO on a free port (one drive, or --drives N
      in one erasure set), then buckets, IAM policies, users, bucket
      policies, lifecycle rules, seed objects and event notifications.
      Writes the env file atomically (see write_env), then serves a
      control endpoint (POST /stop, /start) until SIGTERM / SIGINT, which
      stop the server, remove the env file and exit 0. If the server
      exits on its own, exits with its status.

  launcher.py manifest --image REF [--storage SIZE] OUT
      minio_install's manifest: Deployment + Services (+ PVC).

  launcher.py install --namespace NS --manifest FILE [provisioning options]
      minio_install. Applies the manifest, waits for the rollout, creates
      buckets, policies and users through `kubectl exec ... mc`, writes
      the `minio-provisioned` ConfigMap and idles until SIGTERM.

  launcher.py install-health --namespace NS
      minio_install_health_check: exits 0 once `minio-provisioned` exists.

A server that refuses its arguments, exits, or isn't ready in time is an
error that names the cause and prints the server's log.
"""

import argparse
import base64
import difflib
import errno
import json
import os
import re
import secrets
import shlex
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Failed(Exception):
    """The server refused its arguments, or a start / provisioning step failed."""


def _log(msg):
    print(f"[minio] {msg}", file=sys.stderr, flush=True)


def _read(path):
    try:
        with open(path, errors="replace") as f:
            return f.read()
    except OSError:
        return "(no log)"


def _free_ports(n):
    socks = []
    try:
        for _ in range(n):
            s = socket.socket()
            s.bind(("127.0.0.1", 0))
            socks.append(s)
        return [s.getsockname()[1] for s in socks]
    finally:
        for s in socks:
            s.close()


# ---- strict document checks --------------------------------------------------------
#
# MinIO's policy and lifecycle parsers ignore keys they don't know, so a
# typo silently changes what a document means. These are the keys they
# read (IAM policy grammar; mc ilm export JSON).

_POLICY_TOP = {"Version", "Id", "ID", "Statement"}
_STATEMENT = {"Sid", "SID", "Effect", "Principal", "NotPrincipal", "Action", "NotAction",
              "Resource", "NotResource", "Condition"}
_LIFECYCLE_RULE = {
    "ID": None, "Status": None, "Prefix": None,
    "Filter": {"Prefix": None, "Tag": {"Key": None, "Value": None},
               "And": {"Prefix": None, "Tags": [{"Key": None, "Value": None}],
                       "ObjectSizeGreaterThan": None, "ObjectSizeLessThan": None},
               "ObjectSizeGreaterThan": None, "ObjectSizeLessThan": None},
    "Expiration": {"Days": None, "Date": None, "ExpiredObjectDeleteMarker": None,
                   "ExpiredObjectAllVersions": None},
    "NoncurrentVersionExpiration": {"NoncurrentDays": None, "NewerNoncurrentVersions": None},
    "Transition": {"Days": None, "Date": None, "StorageClass": None},
    "NoncurrentVersionTransition": {"NoncurrentDays": None, "StorageClass": None},
    "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": None},
    "DelMarkerExpiration": {"Days": None},
}
_TRANSITIONS = ("Transition", "NoncurrentVersionTransition")


def _unknown(where, key, known):
    near = difflib.get_close_matches(key, sorted(known), n=1, cutoff=0.6)
    return f"{where}{key}: unknown field" + (f" (did you mean '{near[0]}'?)" if near else "") + \
        f"; MinIO would ignore it"


def _check_keys(value, schema, where, errs):
    """Unknown keys in `value` against `schema` (dict: key → sub-schema or
    None; [schema]: a list of those)."""
    if isinstance(schema, list):
        if isinstance(value, list):
            for i, v in enumerate(value):
                _check_keys(v, schema[0], f"{where}[{i}]", errs)
        return
    if not isinstance(schema, dict) or not isinstance(value, dict):
        return
    for k, v in value.items():
        if k not in schema:
            errs.append(_unknown(where + "." if where else "", k, schema))
        elif schema[k] is not None:
            _check_keys(v, schema[k], f"{where}.{k}" if where else k, errs)


def _load_json(path):
    try:
        with open(path) as f:
            return json.load(f), None
    except ValueError as e:
        return None, f"not valid JSON: {e}"
    except OSError as e:
        return None, str(e)


def check_policy_keys(doc):
    errs = []
    if not isinstance(doc, dict):
        return ["want a JSON object with Version and Statement"]
    for k in doc:
        if k not in _POLICY_TOP:
            errs.append(_unknown("", k, _POLICY_TOP))
    stmts = doc.get("Statement")
    if isinstance(stmts, dict):
        stmts = [stmts]
    for i, s in enumerate(stmts if isinstance(stmts, list) else []):
        if isinstance(s, dict):
            for k in s:
                if k not in _STATEMENT:
                    errs.append(_unknown(f"Statement[{i}].", k, _STATEMENT))
    return errs


def check_lifecycle_keys(doc):
    if not isinstance(doc, dict) or not isinstance(doc.get("Rules"), list):
        return ['want a JSON object {"Rules": [...]} (the `mc ilm rule export` format)']
    errs = []
    for k in doc:
        if k != "Rules":
            errs.append(_unknown("", k, {"Rules"}))
    _check_keys(doc["Rules"], [_LIFECYCLE_RULE], "Rules", errs)
    return errs


def without_transitions(doc):
    """The lifecycle rules MinIO can load without a remote tier, and
    whether any transition was taken out."""
    rules, dropped = [], False
    for r in doc["Rules"]:
        if isinstance(r, dict) and any(t in r for t in _TRANSITIONS):
            r = {k: v for k, v in r.items() if k not in _TRANSITIONS}
            dropped = True
            if not any(k in r for k in _LIFECYCLE_RULE if k not in ("ID", "Status", "Prefix", "Filter")):
                continue
        rules.append(r)
    return dict(doc, Rules=rules), dropped


_ARN = re.compile(r"^arn:aws:s3:::([^/*?]+)")


def policy_buckets(doc):
    """The buckets a bucket policy's resources name."""
    out = []
    stmts = doc.get("Statement") if isinstance(doc, dict) else None
    if isinstance(stmts, dict):
        stmts = [stmts]
    for s in stmts if isinstance(stmts, list) else []:
        res = s.get("Resource", []) if isinstance(s, dict) else []
        for r in [res] if isinstance(res, str) else res if isinstance(res, list) else []:
            m = _ARN.match(r) if isinstance(r, str) else None
            if m and m.group(1) not in out:
                out.append(m.group(1))
    return out


# ---- the server -----------------------------------------------------------------------

_READY_PATH = "/minio/health/ready"
# Start attempts: new free ports each time on a first start; the same
# ports, _RETRY_DELAY apart, on a restart.
_ATTEMPTS = 5
_RETRY_DELAY = 0.2
_PORT_TAKEN = "port is already in use"


def _server_env(extra):
    """The environment for minio / mc: the caller's, without MinIO, mc or
    AWS settings (an env file sourced by a test sets them), plus ours."""
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("MINIO_", "MC_", "AWS_"))}
    env.update(extra)
    return env


class Server:
    """One minio process: its ports, arguments and log, restartable."""

    def __init__(self, binary, argv, env, log, port, console_port, tls_ca=None):
        self.binary, self.argv, self.env, self.log = binary, argv, env, log
        self.port, self.console_port, self.tls_ca = port, console_port, tls_ca
        self.proc = None
        self.stopped = False  # stopped on request (not a crash)

    @property
    def endpoint(self):
        return f"{'https' if self.tls_ca else 'http'}://127.0.0.1:{self.port}"

    def ready(self):
        """The API is ready, and the console listens: MinIO binds the
        console after the API is up, and exits if its port was taken
        meanwhile, so a start isn't done before both (and a clash is
        retried by launch)."""
        ctx = ssl.create_default_context(cafile=self.tls_ca) if self.tls_ca else None
        try:
            with urllib.request.urlopen(self.endpoint + _READY_PATH, timeout=1, context=ctx) as r:
                if r.status != 200:
                    return False
        except (OSError, urllib.error.URLError, ssl.SSLError):
            return False
        if self.env.get("MINIO_BROWSER") == "off":
            return True
        try:
            socket.create_connection(("127.0.0.1", self.console_port), timeout=1).close()
            return True
        except OSError:
            return False

    def start(self, deadline, append=False):
        """Start minio and wait until it is ready. Returns (ready, the log
        this start wrote)."""
        with open(self.log, "a" if append else "w") as log:
            offset = os.path.getsize(self.log)
            self.proc = subprocess.Popen([self.binary] + self.argv, stdout=log, stderr=subprocess.STDOUT,
                                         stdin=subprocess.DEVNULL, env=self.env)
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                break
            if self.ready():
                self.stopped = False
                return True, self.log_from(offset)
            time.sleep(0.05)
        return False, self.log_from(offset)

    def log_from(self, offset):
        try:
            with open(self.log, "rb") as f:
                f.seek(offset)
                return f.read().decode("utf-8", "replace")
        except OSError:
            return "(no log)"

    def stop(self, requested=True):
        """SIGTERM: MinIO finishes in-flight requests and exits."""
        self.stopped = self.stopped or requested
        p = self.proc
        if p is not None and p.poll() is None:
            p.terminate()
            try:
                p.wait(30)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()

    def taken(self):
        return [f"{name} {p}" for name, p in (("port", self.port), ("console port", self.console_port))
                if not _bindable(p)]


def _bindable(port):
    """Whether minio could listen on 127.0.0.1:port again (it sets
    SO_REUSEADDR too, so TIME_WAIT connections don't count)."""
    s = socket.socket()
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", port))
        return True
    except OSError as e:
        if e.errno == errno.EADDRINUSE:
            return False
        raise
    finally:
        s.close()


def _explain(log):
    """The useful part of a failed start: MinIO's FATAL / ERROR lines and
    what follows them, or the last lines."""
    lines = [l for l in log.splitlines() if l.strip()]
    for i, l in enumerate(lines):
        if re.match(r"\s*(FATAL|ERROR)\b", l):
            return "\n".join("  " + x for x in lines[i:i + 8])
    return "\n".join("  " + x for x in lines[-10:])


def launch(minio, state_dir, drives, env, extra, ready_timeout, tls_ca=None):
    """A Server on free ports, ready. New ports on a clash."""
    deadline = time.monotonic() + ready_timeout
    data = os.path.join(state_dir, "data")
    if drives > 1:
        for i in range(1, drives + 1):
            os.makedirs(os.path.join(data, f"drive{i}"), exist_ok=True)
        paths = [os.path.join(data, f"drive{{1...{drives}}}")]
    else:
        os.makedirs(data, exist_ok=True)
        paths = [data]
    certs = os.path.join(state_dir, "certs")
    os.makedirs(certs, exist_ok=True)
    log = os.path.join(state_dir, "minio.log")
    for attempt in range(1, _ATTEMPTS + 1):
        port, console = _free_ports(2)
        # --certs-dir always: otherwise MinIO reads ~/.minio/certs.
        argv = ["server"] + paths + ["--address", f"127.0.0.1:{port}",
                                     "--console-address", f"127.0.0.1:{console}",
                                     "--certs-dir", certs] + extra
        s = Server(minio, argv, env, log, port, console, tls_ca)
        ok, out = s.start(deadline)
        if ok:
            return s
        if s.proc.poll() is None:
            s.stop()
            raise Failed(f"minio was not ready within {ready_timeout:g}s on port {port}. Log:\n{out}")
        if _PORT_TAKEN in out and attempt < _ATTEMPTS:
            _log(f"a port was taken (attempt {attempt}); retrying")
            continue
        raise Failed(f"minio exited with status {s.proc.returncode} before it was ready:\n{_explain(out)}")
    raise Failed(f"minio could not get free ports after {_ATTEMPTS} attempts")


def restart(server, ready_timeout):
    """Start a stopped server again with the same arguments (ports, drives,
    credentials, TLS). Raises Failed naming a port another process holds."""
    taken = []
    for attempt in range(1, _ATTEMPTS + 1):
        if attempt > 1:
            time.sleep(_RETRY_DELAY)
        taken = server.taken()
        if taken:
            _log(f"minio: taken: {', '.join(taken)} (attempt {attempt})")
            continue
        ok, out = server.start(time.monotonic() + ready_timeout, append=True)
        if ok:
            return
        if server.proc.poll() is None:
            server.proc.kill()
            server.proc.wait()
        if _PORT_TAKEN in out:
            taken = server.taken() or ["a port"]
            _log(f"minio: a port was taken while starting (attempt {attempt})")
            continue
        raise Failed("minio did not start again: "
                     + ("not ready in time" if server.proc.returncode is None
                        else f"exit {server.proc.returncode}") + f":\n{_explain(out)}")
    raise Failed(f"minio could not listen on its ports again after {_ATTEMPTS} attempts "
                 f"{_RETRY_DELAY:g}s apart: another process holds {', '.join(taken)} "
                 "(Address already in use)")


# ---- mc ---------------------------------------------------------------------------------


class Mc:
    """mc against one server, as alias `minio`, with its own config dir
    (and the test CA under it, for TLS)."""

    def __init__(self, binary, config_dir, server, user, password, env=None):
        self.binary, self.config_dir = binary, config_dir
        self.env = dict(env or _server_env({}))
        host = server.endpoint.replace("://", f"://{user}:{password}@", 1)
        self.env["MC_HOST_minio"] = host
        os.makedirs(os.path.join(config_dir, "certs", "CAs"), exist_ok=True)
        if server.tls_ca:
            shutil.copyfile(server.tls_ca, os.path.join(config_dir, "certs", "CAs", "ca.crt"))

    def run(self, *argv, stdin=None, what=None):
        """Run `mc --json ARGV`; raise Failed with mc's message."""
        def once():
            return subprocess.run([self.binary, "--config-dir", self.config_dir, "--json", "--no-color"]
                                  + list(argv), input=stdin, capture_output=True, text=True, env=self.env)
        r = retry_uninitialized(once)
        if r.returncode == 0:
            return r.stdout
        raise Failed(f"{what or 'mc ' + ' '.join(argv[:3])}: {mc_error(r.stdout + r.stderr)}")


# /minio/health/ready can answer 200 a moment before the object layer is
# up (seen with several drives on a slow machine); requests then fail with
# this. Retried, for up to _INIT_WAIT seconds.
_UNINITIALIZED = "Server not initialized yet"
_INIT_WAIT = 30


def retry_uninitialized(run):
    deadline = time.monotonic() + _INIT_WAIT
    while True:
        r = run()
        if r.returncode == 0 or _UNINITIALIZED not in r.stdout + r.stderr or time.monotonic() >= deadline:
            return r
        time.sleep(0.2)


def mc_error(out):
    """mc --json's error: the cause's message (MinIO's own words)."""
    for line in out.splitlines():
        try:
            d = json.loads(line)
        except ValueError:
            continue
        e = d.get("error") if isinstance(d, dict) else None
        if isinstance(e, dict):
            cause = (e.get("cause") or {}).get("message")
            return (cause or e.get("message") or line).strip()
    return out.strip() or "failed"


# ---- TLS -------------------------------------------------------------------------------

# Without one, the closure's openssl looks for a config at its build-time
# prefix and fails.
_OPENSSL_CNF = "[req]\ndistinguished_name = dn\n[dn]\n"


def _openssl(openssl, d, *argv):
    env = dict(os.environ, OPENSSL_CONF=os.path.join(d, "openssl.cnf"))
    r = subprocess.run([openssl] + list(argv), cwd=d, env=env, capture_output=True, text=True)
    if r.returncode != 0:
        raise Failed(f"openssl {argv[0]} failed making the test certificates:\n{r.stderr}")


def make_certs(openssl, d):
    """A throwaway CA and a server certificate for 127.0.0.1 / localhost
    in d. Returns (ca, cert, key)."""
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    with open(os.path.join(d, "openssl.cnf"), "w") as f:
        f.write(_OPENSSL_CNF)
    _openssl(openssl, d, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
             "-subj", "/CN=rules_minio test CA", "-keyout", "ca.key", "-out", "ca.crt",
             "-addext", "basicConstraints=critical,CA:TRUE",
             "-addext", "keyUsage=critical,keyCertSign,cRLSign",
             "-addext", "subjectKeyIdentifier=hash")
    with open(os.path.join(d, "server.ext"), "w") as f:
        f.write("basicConstraints=critical,CA:FALSE\n"
                "keyUsage=critical,digitalSignature,keyEncipherment\n"
                "extendedKeyUsage=serverAuth\n"
                "subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n"
                "subjectAltName=IP:127.0.0.1,DNS:localhost\n")
    _openssl(openssl, d, "req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=rules_minio server",
             "-keyout", "server.key", "-out", "server.csr")
    _openssl(openssl, d, "x509", "-req", "-in", "server.csr", "-CA", "ca.crt", "-CAkey", "ca.key",
             "-CAcreateserial", "-days", "2", "-extfile", "server.ext", "-out", "server.crt")
    return [os.path.join(d, n) for n in ("ca.crt", "server.crt", "server.key")]


def install_certs(state_dir, ca, cert, key):
    """MinIO's certs dir layout: public.crt, private.key, CAs/."""
    certs = os.path.join(state_dir, "certs")
    os.makedirs(os.path.join(certs, "CAs"), exist_ok=True)
    shutil.copyfile(cert, os.path.join(certs, "public.crt"))
    shutil.copyfile(key, os.path.join(certs, "private.key"))
    shutil.copyfile(ca, os.path.join(certs, "CAs", "ca.crt"))
    os.chmod(os.path.join(certs, "private.key"), 0o600)


# ---- event notifications ----------------------------------------------------------------

_TARGET = "RULES"  # the webhook target's name: arn:minio:sqs:<region>:RULES:webhook


class EventSink:
    """A webhook endpoint MinIO posts bucket notifications to. Each record
    becomes one JSON line in `path`: {event, bucket, key, size, record}."""

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        open(path, "w").close()
        sink = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                sink.record(body)
                self.send_response(200)
                self.send_header("Content-Length", "0")
                self.end_headers()

            # MinIO probes the endpoint before it posts.
            do_GET = do_HEAD = do_POST

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.httpd.daemon_threads = True
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}/events"

    def record(self, body):
        from urllib.parse import unquote_plus
        try:
            d = json.loads(body)
        except ValueError:
            return
        lines = []
        for r in d.get("Records") or []:
            s3 = r.get("s3") or {}
            obj = s3.get("object") or {}
            lines.append(json.dumps({
                "event": r.get("eventName"),
                "bucket": (s3.get("bucket") or {}).get("name"),
                "key": unquote_plus(obj.get("key") or ""),
                "size": obj.get("size"),
                "record": r,
            }, separators=(",", ":")))
        if lines:
            with self.lock, open(self.path, "a") as f:
                f.write("\n".join(lines) + "\n")

    def env(self):
        return {f"MINIO_NOTIFY_WEBHOOK_ENABLE_{_TARGET}": "on",
                f"MINIO_NOTIFY_WEBHOOK_ENDPOINT_{_TARGET}": self.url}


# ---- provisioning ------------------------------------------------------------------------


def _pairs(values, what):
    out = []
    for v in values:
        k, sep, rest = v.partition("=")
        if not sep or not k or not rest:
            raise Failed(f"--{what} {v!r}: want KEY=VALUE")
        out.append((k, rest))
    return out


def _policy_bucket(path, buckets):
    """The bucket a bucket policy names (minio_policy checked it names one)."""
    doc, err = _load_json(path)
    named = policy_buckets(doc) if not err else []
    if len(named) != 1:
        raise Failed(f"bucket policy {path}: its Resource must name one bucket, found {named or 'none'}")
    if named[0] not in buckets:
        raise Failed(f"bucket policy {path} is for bucket {named[0]}, which `buckets` doesn't create")
    return named[0]


def lifecycle_for_server(path, note):
    """A lifecycle file as MinIO can load it here: transitions need a
    remote tier, so they're taken out (with a note)."""
    doc, err = _load_json(path)
    if err:
        raise Failed(f"lifecycle {path}: {err}")
    doc, dropped = without_transitions(doc)
    if dropped:
        note(f"lifecycle {os.path.basename(path)}: transitions left out (they need a remote tier)")
    return json.dumps(doc) if doc["Rules"] else None


def provision(mc, args, region):
    """Buckets, IAM policies, users, bucket policies, lifecycle rules,
    seed objects and event notifications, in that order. Returns the
    users' secret keys."""
    for b in args.bucket:
        flags = ["--with-lock"] if b in args.object_lock else []
        mc.run("mb", *flags, f"minio/{b}", what=f"bucket {b}")
        if b in args.versioned and b not in args.object_lock:
            mc.run("version", "enable", f"minio/{b}", what=f"versioning on {b}")
    for name, path in _pairs(args.policy, "policy"):
        mc.run("admin", "policy", "create", "minio", name, path, what=f"policy {name} ({path})")
    secrets_ = {}
    for user, policies in _pairs(args.user, "user"):
        secret = secrets.token_hex(16)
        mc.run("admin", "user", "add", "minio", user, secret, what=f"user {user}")
        names = [p for p in policies.split(",") if p]
        if names:
            mc.run("admin", "policy", "attach", "minio", *names, "--user", user,
                   what=f"user {user}: attaching {', '.join(names)}")
        secrets_[user] = secret
    for path in args.bucket_policy:
        bucket = _policy_bucket(path, args.bucket)
        mc.run("anonymous", "set-json", path, f"minio/{bucket}", what=f"bucket policy {path} on {bucket}")
    for bucket, path in _pairs(args.lifecycle, "lifecycle"):
        rules = lifecycle_for_server(path, _log)
        if rules:
            mc.run("ilm", "rule", "import", f"minio/{bucket}", stdin=rules,
                   what=f"lifecycle {path} on {bucket}")
    for dest, path in _pairs(args.seed, "seed"):
        target = f"minio/{dest.strip('/')}/"
        if os.path.isdir(path):
            mc.run("cp", "--recursive", path.rstrip("/") + "/", target, what=f"seed {path} → {dest}")
        else:
            mc.run("cp", path, target, what=f"seed {path} → {dest}")
        _log(f"seeded {os.path.basename(path.rstrip('/'))} → {dest}")
    # Last, so seeding sends no events.
    for bucket, events in _pairs(args.events, "events"):
        mc.run("event", "add", f"minio/{bucket}", f"arn:minio:sqs:{region}:{_TARGET}:webhook",
               "--event", events, what=f"events {events} on {bucket}")
    return secrets_


# ---- check -------------------------------------------------------------------------------

_CHECK_USER, _CHECK_PASSWORD = "rules-minio-check", "rules-minio-check-only"


def check(args):
    """Strict keys first (no server needed), then MinIO loads each file."""
    problems, docs = [], {}
    for path in args.files:
        doc, err = _load_json(path)
        if err:
            problems.append(f"{path}: {err}")
            continue
        errs = check_lifecycle_keys(doc) if args.type == "lifecycle" else check_policy_keys(doc)
        if args.type == "bucket" and not errs:
            buckets = policy_buckets(doc)
            if len(buckets) != 1:
                errs.append("a bucket policy's Resource must name one bucket "
                            f"(arn:aws:s3:::BUCKET[/...]); found {buckets or 'none'}")
        problems += [f"{path}: {e}" for e in errs]
        if not errs:
            docs[path] = doc
    if docs:
        problems += _load_in_minio(args, docs)
    if problems:
        print(f"minio_{'lifecycle' if args.type == 'lifecycle' else 'policy'} {args.label}:\n"
              + "\n".join("  " + p for p in problems), file=sys.stderr)
        return 1
    open(args.marker, "w").close()
    return 0


def _load_in_minio(args, docs):
    work = tempfile.mkdtemp(prefix="rules-minio-check-")
    server = None
    try:
        env = _server_env({"MINIO_ROOT_USER": _CHECK_USER, "MINIO_ROOT_PASSWORD": _CHECK_PASSWORD,
                           "MINIO_UPDATE": "off", "MINIO_BROWSER": "off", "HOME": work})
        try:
            server = launch(args.minio, work, 1, env, [], args.ready_timeout)
        except Failed as e:
            return [f"could not start MinIO to check them: {e}"]
        mc = Mc(args.mc, os.path.join(work, "mc"), server, _CHECK_USER, _CHECK_PASSWORD, env)
        problems = []
        for i, (path, doc) in enumerate(docs.items()):
            try:
                if args.type == "iam":
                    mc.run("admin", "policy", "create", "minio", f"check-{i}", path, what="MinIO refused it")
                elif args.type == "bucket":
                    bucket = policy_buckets(doc)[0]
                    mc.run("mb", "--ignore-existing", f"minio/{bucket}", what=f"bucket {bucket}")
                    mc.run("anonymous", "set-json", path, f"minio/{bucket}", what="MinIO refused it")
                else:
                    loadable = without_transitions(doc)[0]
                    if not loadable["Rules"]:
                        continue  # transitions only: checked above, not loadable here
                    bucket = f"lifecycle-check-{i}"
                    mc.run("mb", f"minio/{bucket}", what=f"bucket {bucket}")
                    mc.run("ilm", "rule", "import", f"minio/{bucket}",
                           stdin=json.dumps(loadable), what="MinIO refused it")
            except Failed as e:
                problems.append(f"{path}: {e}")
        return problems
    finally:
        if server:
            server.stop()
        shutil.rmtree(work, ignore_errors=True)


# ---- serve -------------------------------------------------------------------------------


def write_env(env_file, values):
    tmp = env_file + ".tmp"
    with open(tmp, "w") as f:
        for k, v in values.items():
            f.write(f"{k}={shlex.quote(str(v))}\n")
    os.replace(tmp, env_file)


def env_name(user):
    return re.sub(r"[^A-Za-z0-9]", "_", user).upper()


def mc_wrapper(state_dir, mc, config_dir):
    """`mc` with this server's config dir (its CA, under TLS), for PATH."""
    d = os.path.join(state_dir, "bin")
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, "mc")
    with open(path, "w") as f:
        f.write(f"#!/bin/sh\nexec {shlex.quote(mc)} --config-dir {shlex.quote(config_dir)} \"$@\"\n")
    os.chmod(path, 0o755)
    return path


class Control:
    """POST /stop, /start: stop the server / start it again."""

    def __init__(self, server, ready_timeout, stopping):
        self.server, self.ready_timeout, self.stopping = server, ready_timeout, stopping
        self.lock = threading.Lock()

    def handle(self, path):
        if self.stopping:
            return 503, "shutting down"
        with self.lock:
            if path == "/stop":
                self.server.stop()
                _log("stopped (control)")
                return 200, "stopped"
            if path == "/start":
                if self.server.proc is None or self.server.proc.poll() is not None:
                    try:
                        restart(self.server, self.ready_timeout)
                    except Failed as e:
                        _log(str(e))
                        return 500, str(e)
                    _log("started again (control)")
                return 200, "started"
        return 404, f"unknown control path {path}"

    def serve(self):
        control = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                self.rfile.read(int(self.headers.get("Content-Length") or 0))
                status, text = control.handle(self.path)
                body = (text + "\n").encode()
                self.send_response(status)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        httpd.daemon_threads = True
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        return httpd


def serve(args):
    if args.drives < 1 or args.drives > 16:
        _log(f"--drives {args.drives}: want 1 (one drive) or 2..16 (one erasure set)")
        return 1
    os.makedirs(args.state_dir, exist_ok=True)
    try:
        os.remove(args.env_file)
    except FileNotFoundError:
        pass

    # Installed before the server starts, so a signal during start-up
    # still stops it. Once ready, the handler only asks it to stop and the
    # main loop (polling) notices.
    server_box, stopping, ready = [], [], []

    def _on_signal(signum, _frame):
        if stopping:
            return
        _log(f"signal {signum}; stopping")
        stopping.append(signum)
        for s in server_box:
            p = s.proc
            if p is not None and p.poll() is None:
                p.terminate()
                killer = threading.Timer(10, p.kill)
                killer.daemon = True
                killer.start()
        if not ready:
            raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    sink = None
    try:
        try:
            tls_ca = None
            if args.tls:
                if args.tls_cert:
                    ca, cert, key = (os.path.abspath(p) for p in (args.tls_ca, args.tls_cert, args.tls_key))
                else:
                    ca, cert, key = make_certs(args.openssl, os.path.join(args.state_dir, "tls"))
                install_certs(args.state_dir, ca, cert, key)
                tls_ca = ca
            extra_env = {"MINIO_ROOT_USER": args.root_user, "MINIO_ROOT_PASSWORD": args.root_password,
                         "MINIO_SITE_REGION": args.region, "MINIO_UPDATE": "off",
                         "HOME": args.state_dir}
            if args.events:
                sink = EventSink(os.path.join(args.state_dir, "events.jsonl"))
                extra_env.update(sink.env())
            for k, v in _pairs(args.server_env, "server-env"):
                extra_env[k] = v
            env = _server_env(extra_env)
            server = launch(args.minio, args.state_dir, args.drives, env, args.extra,
                            args.ready_timeout, tls_ca)
            server_box.append(server)
            config_dir = os.path.join(args.state_dir, "mc")
            mc = Mc(args.mc, config_dir, server, args.root_user, args.root_password)
            users = provision(mc, args, args.region)
        except Failed as e:
            _log(str(e))
            for s in server_box:
                s.stop()
                _log(f"stopped minio (port {s.port})")
            return 1
        except SystemExit:
            for s in server_box:
                s.stop()
            raise

        control = Control(server, args.ready_timeout, stopping)
        httpd = control.serve()
        endpoint = server.endpoint
        values = {
            "MINIO_ENDPOINT": endpoint,
            "MINIO_HOST": "127.0.0.1",
            "MINIO_PORT": server.port,
            "MINIO_CONSOLE_URL": f"{'https' if tls_ca else 'http'}://127.0.0.1:{server.console_port}",
            "MINIO_ROOT_USER": args.root_user,
            "MINIO_ROOT_PASSWORD": args.root_password,
            "MINIO_REGION": args.region,
            "AWS_ACCESS_KEY_ID": args.root_user,
            "AWS_SECRET_ACCESS_KEY": args.root_password,
            "AWS_REGION": args.region,
            "AWS_DEFAULT_REGION": args.region,
            "AWS_ENDPOINT_URL": endpoint,
            "AWS_ENDPOINT_URL_S3": endpoint,
            "MC_HOST_minio": mc.env["MC_HOST_minio"],
        }
        for user, secret in users.items():
            values[f"MINIO_USER_{env_name(user)}_ACCESS_KEY"] = user
            values[f"MINIO_USER_{env_name(user)}_SECRET_KEY"] = secret
        if tls_ca:
            values["MINIO_TLS"] = "1"
            values["MINIO_TLS_CA"] = tls_ca
            values["AWS_CA_BUNDLE"] = tls_ca
        if sink:
            values["MINIO_EVENTS_FILE"] = sink.path
        values["MINIO_CONTROL_URL"] = f"http://127.0.0.1:{httpd.server_address[1]}"
        values["MINIO_LOG"] = server.log
        values["MINIO_DATA_DIR"] = os.path.join(args.state_dir, "data")
        values["MINIO_SERVER"] = os.path.abspath(args.minio)
        values["MC"] = mc_wrapper(args.state_dir, os.path.abspath(args.mc), config_dir)
        write_env(args.env_file, values)
        ready.append(True)
        _log(f"ready on {endpoint}"
             + (f" ({args.drives} drives)" if args.drives > 1 else "")
             + f"; env file {args.env_file}")

        # Run until signalled, or until the server exits without being
        # asked to (minio_stop leaves the launcher running).
        crashed = False
        while not stopping and not crashed:
            p = server.proc
            if p is not None and p.poll() is not None and not server.stopped:
                with control.lock:  # not mid-restart
                    crashed = server.proc is p and not server.stopped
            time.sleep(0.1)
        httpd.shutdown()
        server.stop(requested=False)
        try:
            os.remove(args.env_file)
        except FileNotFoundError:
            pass
        if stopping:
            return 0
        rc = server.proc.returncode
        _log(f"minio exited with status {rc}. Log:\n{_read(server.log)}")
        return rc if rc and rc > 0 else 1
    finally:
        if sink:
            sink.httpd.shutdown()


# ---- cluster install ---------------------------------------------------------------------

_LABELS = {"app.kubernetes.io/name": "minio", "app.kubernetes.io/managed-by": "rules_minio"}
_SECRET, _USERS_SECRET, _MARKER = "minio", "minio-users", "minio-provisioned"
_URL_SAFE = re.compile(r"^[A-Za-z0-9._~-]+$")


def render_manifest(image, storage, region):
    """The install's objects: Services minio (S3 API, 9000) and
    minio-console (9001), a single-replica Deployment minio, and with
    `storage` a PersistentVolumeClaim (else emptyDir). The root
    credentials come from the Secret `minio`, which the installer
    creates; MC_HOST_local lets `kubectl exec ... mc` reach the server."""
    volume = ({"name": "data", "persistentVolumeClaim": {"claimName": "minio-data"}} if storage
              else {"name": "data", "emptyDir": {}})
    secret = lambda key: {"valueFrom": {"secretKeyRef": {"name": _SECRET, "key": key}}}
    probe = lambda path: {"httpGet": {"path": path, "port": "api"}, "periodSeconds": 5}
    container = {
        "name": "minio",
        "image": image,
        "imagePullPolicy": "IfNotPresent",
        "command": ["/usr/bin/minio"],
        "args": ["server", "/data", "--address", ":9000", "--console-address", ":9001",
                 "--certs-dir", "/tmp/certs"],
        "env": [{"name": "MINIO_ROOT_USER", **secret("rootUser")},
                {"name": "MINIO_ROOT_PASSWORD", **secret("rootPassword")},
                {"name": "MINIO_SITE_REGION", "value": region},
                {"name": "MINIO_UPDATE", "value": "off"},
                {"name": "HOME", "value": "/tmp"},
                {"name": "MC_HOST_local",
                 "value": "http://$(MINIO_ROOT_USER):$(MINIO_ROOT_PASSWORD)@127.0.0.1:9000"}],
        "ports": [{"name": "api", "containerPort": 9000}, {"name": "console", "containerPort": 9001}],
        "readinessProbe": probe("/minio/health/ready"),
        "livenessProbe": dict(probe("/minio/health/live"), initialDelaySeconds=10),
        "resources": {"requests": {"cpu": "100m", "memory": "256Mi"}},
        "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True,
                            "capabilities": {"drop": ["ALL"]}},
        "volumeMounts": [{"name": "data", "mountPath": "/data"}, {"name": "tmp", "mountPath": "/tmp"}],
    }
    deployment = {
        "apiVersion": "apps/v1", "kind": "Deployment",
        "metadata": {"name": "minio", "labels": _LABELS},
        "spec": {
            "replicas": 1,
            "strategy": {"type": "Recreate"},
            "selector": {"matchLabels": {"app.kubernetes.io/name": "minio"}},
            "template": {
                "metadata": {"labels": _LABELS},
                "spec": {
                    "securityContext": {"runAsUser": 1000, "runAsGroup": 1000, "fsGroup": 1000,
                                        "runAsNonRoot": True, "seccompProfile": {"type": "RuntimeDefault"}},
                    "containers": [container],
                    "volumes": [volume, {"name": "tmp", "emptyDir": {}}],
                },
            },
        },
    }
    service = lambda name, port, port_name: {
        "apiVersion": "v1", "kind": "Service",
        "metadata": {"name": name, "labels": _LABELS},
        "spec": {"selector": {"app.kubernetes.io/name": "minio"},
                 "ports": [{"name": port_name, "port": port, "targetPort": port_name}]},
    }
    docs = [service("minio", 9000, "api"), service("minio-console", 9001, "console")]
    if storage:
        docs.append({"apiVersion": "v1", "kind": "PersistentVolumeClaim",
                     "metadata": {"name": "minio-data", "labels": _LABELS},
                     "spec": {"accessModes": ["ReadWriteOnce"],
                              "resources": {"requests": {"storage": storage}}}})
    docs.append(deployment)
    # JSON is YAML; one document per object, readable in a diff.
    return "".join("---\n" + json.dumps(d, indent=2) + "\n" for d in docs)


class Kubectl:
    def __init__(self, namespace):
        if not os.environ.get("KUBECONFIG"):
            raise Failed("KUBECONFIG is not set (rules_kind's env file sets it)")
        self.base = [os.environ.get("KUBECTL") or shutil.which("kubectl") or "kubectl",
                     "--kubeconfig", os.environ["KUBECONFIG"], "-n", namespace]
        self.namespace = namespace

    def run(self, *argv, stdin=None, check=True):
        r = subprocess.run(self.base + list(argv), input=stdin, capture_output=True, text=True)
        if check and r.returncode != 0:
            raise Failed(f"kubectl {' '.join(argv[:3])}: {(r.stderr or r.stdout).strip()}")
        return r

    def mc(self, *argv, stdin=None, what=None):
        r = retry_uninitialized(lambda: self.run(
            "exec", "-i" if stdin is not None else "-t=false", "deploy/minio", "-c", "minio",
            "--", "/usr/bin/mc", "--config-dir", "/tmp/.mc", "--json", "--no-color", *argv,
            stdin=stdin, check=False))
        if r.returncode != 0:
            raise Failed(f"{what or 'mc ' + ' '.join(argv[:3])}: {mc_error(r.stdout + r.stderr)}")
        return r.stdout

    def put(self, name, text):
        """A file in the pod's /tmp, for mc commands that need a real file
        (`anonymous set-json` can't read a pipe). The image has no shell or
        tar, so `kubectl cp` can't be used; `mc pipe` writes local paths."""
        path = "/tmp/rules-minio/" + name
        self.mc("pipe", path, stdin=text, what=f"copying {name} into the pod")
        return path

    def secret(self, name):
        r = self.run("get", "secret", name, "-o", "json", check=False)
        if r.returncode != 0:
            return None
        return {k: base64.b64decode(v).decode() for k, v in (json.loads(r.stdout).get("data") or {}).items()}

    def put_secret(self, name, data):
        doc = {"apiVersion": "v1", "kind": "Secret", "metadata": {"name": name, "labels": _LABELS},
               "type": "Opaque", "stringData": data}
        self.run("apply", "--server-side", "--force-conflicts", "-f", "-", stdin=json.dumps(doc))


def install(args):
    stop = []
    signal.signal(signal.SIGTERM, lambda *_: stop.append(1))
    signal.signal(signal.SIGINT, lambda *_: stop.append(1))
    try:
        k = Kubectl(args.namespace)
        ns = {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": args.namespace}}
        k.run("apply", "-f", "-", stdin=json.dumps(ns))
        # Root credentials: the given ones, else those already installed,
        # else new ones. URL-safe: MC_HOST_local embeds them.
        root = k.secret(_SECRET) or {}
        user = args.root_user or root.get("rootUser") or "minioadmin"
        password = args.root_password or root.get("rootPassword") or secrets.token_hex(16)
        for what, v in (("root_user", user), ("root_password", password)):
            if not _URL_SAFE.match(v):
                raise Failed(f"{what} may only use letters, digits and . _ ~ - (it goes into an mc URL)")
        k.put_secret(_SECRET, {"rootUser": user, "rootPassword": password})
        k.run("delete", "configmap", _MARKER, "--ignore-not-found")
        _log(f"applying {args.manifest} in namespace {args.namespace}")
        k.run("apply", "--server-side", "--force-conflicts", "-f", args.manifest)
        r = k.run("rollout", "status", "deploy/minio", f"--timeout={args.wait_timeout}", check=False)
        if r.returncode != 0:
            dump = [k.run(*a, check=False) for a in (("get", "pods,deploy,svc", "-o", "wide"),
                                                     ("describe", "deploy/minio"),
                                                     ("logs", "deploy/minio", "--tail=100"))]
            raise Failed(f"deploy/minio did not roll out within {args.wait_timeout}: {r.stderr.strip()}\n"
                         + "\n".join(d.stdout + d.stderr for d in dump))
        _provision_cluster(k, args)
        marker = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": _MARKER, "labels": _LABELS},
                  "data": {"buckets": ",".join(args.bucket), "users": ",".join(u for u, _ in _pairs(args.user, "user"))}}
        k.run("apply", "-f", "-", stdin=json.dumps(marker))
        _log(f"MinIO installed and provisioned in {args.namespace}")
    except Failed as e:
        _log(str(e))
        return 1
    # itest_service.exe contract: keep running until told to stop.
    while not stop:
        time.sleep(0.5)
    return 0


def _provision_cluster(k, args):
    for b in args.bucket:
        flags = ["--with-lock"] if b in args.object_lock else []
        k.mc("mb", "--ignore-existing", *flags, f"local/{b}", what=f"bucket {b}")
        if b in args.versioned and b not in args.object_lock:
            k.mc("version", "enable", f"local/{b}", what=f"versioning on {b}")
    for name, path in _pairs(args.policy, "policy"):
        k.mc("admin", "policy", "create", "local", name, k.put(f"policy-{name}.json", open(path).read()),
             what=f"policy {name}")
    if args.user:
        users = k.secret(_USERS_SECRET) or {}
        for user, policies in _pairs(args.user, "user"):
            users.setdefault(user, secrets.token_hex(16))
            k.mc("admin", "user", "add", "local", user, users[user], what=f"user {user}")
            names = [p for p in policies.split(",") if p]
            if names:
                k.mc("admin", "policy", "attach", "local", *names, "--user", user,
                     what=f"user {user}: attaching {', '.join(names)}")
        k.put_secret(_USERS_SECRET, users)
    for path in args.bucket_policy:
        bucket = _policy_bucket(path, args.bucket)
        k.mc("anonymous", "set-json", k.put(f"bucket-policy-{bucket}.json", open(path).read()),
             f"local/{bucket}", what=f"bucket policy on {bucket}")
    for bucket, path in _pairs(args.lifecycle, "lifecycle"):
        rules = lifecycle_for_server(path, _log)
        if rules:
            k.mc("ilm", "rule", "import", f"local/{bucket}", stdin=rules, what=f"lifecycle on {bucket}")


def install_health(args):
    try:
        r = Kubectl(args.namespace).run("get", "configmap", _MARKER, check=False)
    except Failed as e:
        _log(str(e))
        return 1
    if r.returncode == 0:
        return 0
    print(f"[minio_install_health_check] {args.namespace}/{_MARKER} not there yet", file=sys.stderr)
    return 1


# ---- main ----------------------------------------------------------------------------------


def _provisioning_args(p):
    p.add_argument("--bucket", action="append", default=[])
    p.add_argument("--versioned", action="append", default=[])
    p.add_argument("--object-lock", action="append", default=[])
    p.add_argument("--policy", action="append", default=[], help="NAME=FILE")
    p.add_argument("--user", action="append", default=[], help="NAME=POLICY,POLICY")
    p.add_argument("--bucket-policy", action="append", default=[], help="FILE (names its bucket)")
    p.add_argument("--lifecycle", action="append", default=[], help="BUCKET=FILE")


def main(argv):
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="mode", required=True)

    c = sub.add_parser("check")
    c.add_argument("--minio", required=True)
    c.add_argument("--mc", required=True)
    c.add_argument("--type", required=True, choices=["iam", "bucket", "lifecycle"])
    c.add_argument("--label", default="")
    c.add_argument("--marker", required=True)
    c.add_argument("--ready-timeout", type=float, default=30.0)
    c.add_argument("files", nargs="+")

    s = sub.add_parser("serve")
    s.add_argument("--minio", required=True)
    s.add_argument("--mc", required=True)
    s.add_argument("--openssl")
    s.add_argument("--env-file", required=True)
    s.add_argument("--state-dir", required=True)
    s.add_argument("--ready-timeout", type=float, default=30.0)
    s.add_argument("--root-user", default="minioadmin")
    s.add_argument("--root-password", default="minioadmin")
    s.add_argument("--region", default="us-east-1")
    s.add_argument("--drives", type=int, default=1)
    _provisioning_args(s)
    s.add_argument("--events", action="append", default=[], help="BUCKET=put,delete,...")
    s.add_argument("--seed", action="append", default=[], help="BUCKET/PREFIX/=PATH")
    s.add_argument("--server-env", action="append", default=[], help="KEY=VALUE")
    s.add_argument("--tls", action="store_true")
    s.add_argument("--tls-cert")
    s.add_argument("--tls-key")
    s.add_argument("--tls-ca")
    s.add_argument("extra", nargs="*")

    m = sub.add_parser("manifest")
    m.add_argument("--image", required=True)
    m.add_argument("--storage", default="")
    m.add_argument("--region", default="us-east-1")
    m.add_argument("out")

    i = sub.add_parser("install")
    i.add_argument("--namespace", required=True)
    i.add_argument("--manifest", required=True)
    i.add_argument("--wait-timeout", default="300s")
    i.add_argument("--root-user", default="")
    i.add_argument("--root-password", default="")
    _provisioning_args(i)

    h = sub.add_parser("install-health")
    h.add_argument("--namespace", required=True)

    args = p.parse_args(argv)
    if args.mode == "manifest":
        with open(args.out, "w") as f:
            f.write(render_manifest(args.image, args.storage, args.region))
        return 0
    if args.mode == "install":
        return install(args)
    if args.mode == "install-health":
        return install_health(args)
    if not 0 < args.ready_timeout < float("inf"):
        _log(f"--ready-timeout must be a positive number of seconds, got {args.ready_timeout}")
        return 1
    args.minio = os.path.abspath(args.minio)
    args.mc = os.path.abspath(args.mc)
    if args.mode == "check":
        return check(args)
    args.state_dir = os.path.abspath(args.state_dir)
    args.env_file = os.path.abspath(args.env_file)
    return serve(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
