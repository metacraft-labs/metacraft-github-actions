#!/usr/bin/env python3
"""git-http-auth-server.py -- a real, hermetic, credential-checking git server.

WHY THIS EXISTS
---------------
The contract suites in this repo assert things about a CI git credential. The
cheap way to do that is to ask git's own matchers (`git config --get-urlmatch`,
`git ls-remote --get-url`) what they think, and this repo already does that in
`setup-nix/configure-git-auth-test.sh`. But those matchers answer about
*configuration*, and configuration is exactly the thing under test: a suite
built only from them can agree with a bug. That already happened once here --
`--get-urlmatch` cannot see a credential smuggled into a URL, so a header-only
suite reported "unauthenticated" for every third-party URL while the code it was
guarding was busy injecting a token into all of them, and passed.

So the suites that guard the clone path do not ask git what it would do. They
make git actually do it, against this server, over real HTTP, and this server
reports what arrived on the wire. If the credential does not reach the server,
the clone fails; if it reaches a repository it was not scoped to, the assertion
that no credential arrived fails. Both directions are observed rather than
modelled.

WHAT IT DOES
------------
Serves `git http-backend` (the real smart-HTTP CGI that ships with git) over
127.0.0.1 on an ephemeral port, in front of a directory of bare repositories.
Repositories whose path starts with a configured prefix require HTTP Basic
authentication matching a configured credential; everything else is public.

It prints one line to stdout -- `PORT <n>` -- once it is listening, then serves
until killed.

WHAT IT NEVER DOES
------------------
It never writes a credential anywhere. The expected credential is read from a
file (so it is not in this process's argv, which is world-readable in /proc) and
is compared with `hmac.compare_digest`. The request journal records only the
request path and one of `none` / `ok` / `mismatch` -- never a header value, not
even truncated, not even hashed. A test fixture that logs the secret it is
testing is a worse leak than the one it is testing for, because fixtures get
pasted into issues.

Usage:
  git-http-auth-server.py --root DIR --journal FILE
                          [--auth-prefix PATH --auth-file FILE]
"""

import argparse
import base64
import hmac
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ARGS = None
EXPECTED = None  # bytes: the full "Basic <b64>" value we accept, or None
JOURNAL_LOCK = threading.Lock()


def journal(path, verdict):
    with JOURNAL_LOCK:
        with open(ARGS.journal, "a", encoding="utf-8") as fh:
            fh.write("%s %s\n" % (verdict, path))
            fh.flush()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # Keep the suite's output about the suite. BaseHTTPRequestHandler logs every
    # request to stderr including the full request line; harmless here, but noise
    # in a test log is how a real failure gets skimmed past.
    def log_message(self, fmt, *a):  # noqa: A003
        pass

    def _protected(self, path):
        return ARGS.auth_prefix and path.startswith(ARGS.auth_prefix)

    def _check_auth(self, path):
        """Return True to proceed. Journals what arrived, never its value."""
        supplied = self.headers.get("Authorization")
        if not self._protected(path):
            journal(path, "public-auth" if supplied else "public-noauth")
            return True
        if supplied is None:
            journal(path, "none")
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="git"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return False
        # The auth SCHEME is compared case-insensitively and the PAYLOAD
        # byte-exactly. Both halves matter: git spells an `http.<url>.extraHeader`
        # exactly as configured (this repo writes `basic`), while curl spells a
        # credential taken from a URL's userinfo `Basic`. A case-sensitive
        # comparison would silently reject one of the two shapes and turn a
        # positive contract into a false negative -- which is how a suite ends up
        # "proving" a credential does not arrive when it does.
        scheme, _, payload = supplied.partition(" ")
        if (
            EXPECTED is not None
            and scheme.lower() == "basic"
            and hmac.compare_digest(payload.strip().encode("utf-8"), EXPECTED)
        ):
            journal(path, "ok")
            return True
        journal(path, "mismatch")
        self.send_response(403)
        self.send_header("Content-Length", "0")
        self.end_headers()
        return False

    def _cgi(self, method):
        path = self.path.split("?", 1)[0]
        query = self.path.split("?", 1)[1] if "?" in self.path else ""
        if not self._check_auth(path):
            return

        body = b""
        if method == "POST":
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else b""

        env = {
            "PATH": os.environ.get("PATH", ""),
            "GIT_PROJECT_ROOT": ARGS.root,
            "GIT_HTTP_EXPORT_ALL": "1",
            "REQUEST_METHOD": method,
            "PATH_INFO": path,
            "QUERY_STRING": query,
            "REMOTE_USER": "test",
            "REMOTE_ADDR": "127.0.0.1",
            "CONTENT_TYPE": self.headers.get("Content-Type", ""),
            "CONTENT_LENGTH": str(len(body)),
            "SERVER_PROTOCOL": "HTTP/1.1",
            "GIT_PROTOCOL": self.headers.get("Git-Protocol", ""),
        }

        proc = subprocess.run(
            [ARGS.http_backend],
            input=body,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            check=False,
        )
        raw = proc.stdout
        head, _, payload = raw.partition(b"\r\n\r\n")
        if not _:
            head, _, payload = raw.partition(b"\n\n")

        status = 200
        headers = []
        for line in head.replace(b"\r\n", b"\n").split(b"\n"):
            if not line:
                continue
            name, _, value = line.partition(b":")
            name = name.strip().decode("latin-1")
            value = value.strip().decode("latin-1")
            if name.lower() == "status":
                status = int(value.split()[0])
            else:
                headers.append((name, value))

        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):  # noqa: N802
        self._cgi("GET")

    def do_POST(self):  # noqa: N802
        self._cgi("POST")


def find_http_backend():
    exec_path = subprocess.run(
        ["git", "--exec-path"], stdout=subprocess.PIPE, check=True
    ).stdout.decode().strip()
    for candidate in (
        os.path.join(exec_path, "git-http-backend"),
        "/usr/lib/git-core/git-http-backend",
    ):
        if os.path.exists(candidate):
            return candidate
    raise SystemExit("git-http-auth-server: cannot locate git-http-backend")


def main():
    global ARGS, EXPECTED
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--journal", required=True)
    parser.add_argument("--auth-prefix", default="")
    # A FILE, not a value: an argv element is readable by every process on the
    # machine, and these suites run on shared self-hosted runners.
    parser.add_argument("--auth-file", default="")
    ARGS = parser.parse_args()
    ARGS.http_backend = find_http_backend()

    if ARGS.auth_file:
        with open(ARGS.auth_file, "rb") as fh:
            token = fh.read().strip()
        EXPECTED = base64.b64encode(b"x-access-token:" + token)

    open(ARGS.journal, "a", encoding="utf-8").close()
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    sys.stdout.write("PORT %d\n" % httpd.server_address[1])
    sys.stdout.flush()
    httpd.serve_forever()


if __name__ == "__main__":
    main()
