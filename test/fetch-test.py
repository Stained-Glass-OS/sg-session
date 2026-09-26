#!/usr/bin/python3
# Unit gate for lib/sg-fetch, what downloads the first-run setup's browser
# (the image has no curl: the first ISO's Firefox never arrived). A local
# HTTPS server with a certificate made here (trusted through SSL_CERT_FILE):
# a file arrives whole; a redirect to https follows; a redirect to http, an
# http:// URL and a 404 fail and leave nothing behind. Skips (77) without
# openssl.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
import http.server
import os
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
FETCH = os.path.join(HERE, "..", "lib", "sg-fetch")
FAILS = 0
PAYLOAD = os.urandom(300000)
PLAIN_PORT = [0]
# the system's Python, as sg-fetch's #! line: a private build (pyenv) may carry
# its own trust store and ignore SSL_CERT_FILE
PY = "/usr/bin/python3" if os.access("/usr/bin/python3", os.X_OK) else sys.executable


def check(cond, what):
    global FAILS
    print(("PASS " if cond else "FAIL ") + what)
    if not cond:
        FAILS += 1


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path == "/setup.exe":
            self.send_response(200)
            self.send_header("Content-Length", str(len(PAYLOAD)))
            self.end_headers()
            self.wfile.write(PAYLOAD)
        elif self.path == "/to-https":
            self.send_response(302)
            self.send_header("Location", "https://localhost:%d/setup.exe" % self.server.server_port)
            self.end_headers()
        elif self.path == "/to-http":
            # to a plain HTTP server that really serves the file
            self.send_response(302)
            self.send_header("Location", "http://localhost:%d/setup.exe" % PLAIN_PORT[0])
            self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()


def main():
    if not shutil.which("openssl"):
        print("SKIP: no openssl")
        return 77
    tmp = tempfile.mkdtemp(prefix="sg-fetch-test.")
    # a CA and a server certificate it signed -- Python's default context
    # checks strictly (X509_STRICT), as it will for the real publisher
    ca, cakey = os.path.join(tmp, "ca.pem"), os.path.join(tmp, "ca.key")
    cert, key, csr = os.path.join(tmp, "cert.pem"), os.path.join(tmp, "key.pem"), os.path.join(tmp, "req.csr")
    ext = os.path.join(tmp, "leaf.ext")
    with open(ext, "w") as f:
        f.write("basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n"
                "extendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost\n"
                "authorityKeyIdentifier=keyid\nsubjectKeyIdentifier=hash\n")
    for argv in (["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", cakey, "-out", ca, "-days", "1",
                  "-subj", "/CN=sg-fetch test CA", "-addext", "basicConstraints=critical,CA:TRUE",
                  "-addext", "keyUsage=critical,keyCertSign,cRLSign"],
                 ["openssl", "req", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", csr, "-subj", "/CN=localhost"],
                 ["openssl", "x509", "-req", "-in", csr, "-CA", ca, "-CAkey", cakey, "-CAcreateserial", "-out", cert,
                  "-days", "1", "-extfile", ext]):
        subprocess.run(argv, check=True, capture_output=True)
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    plain = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    PLAIN_PORT[0] = plain.server_port
    threading.Thread(target=plain.serve_forever, daemon=True).start()
    base = "https://localhost:%d" % srv.server_port
    env = dict(os.environ, SSL_CERT_FILE=ca, SG_FETCH_TRIES="2", SG_FETCH_TIMEOUT="10")

    def fetch(url, name):
        out = os.path.join(tmp, name)
        r = subprocess.run([PY, FETCH, url, out], env=env, capture_output=True, text=True, timeout=120)
        data = open(out, "rb").read() if os.path.exists(out) else None
        return r.returncode, data, os.path.exists(out + ".part"), r.stderr.strip()

    rc, data, part, err = fetch(base + "/setup.exe", "a.exe")
    check(rc == 0 and data == PAYLOAD and not part, "an https download arrives whole (%d bytes) %s" % (len(data or b""), err))
    rc, data, part, err = fetch(base + "/to-https", "b.exe")
    check(rc == 0 and data == PAYLOAD, "a redirect to https is followed %s" % err)
    rc, data, part, err = fetch(base + "/to-http", "c.exe")
    check(rc != 0 and data is None and not part and "refusing" in err, "a redirect to http is refused, nothing left: %s" % err)
    rc, data, part, err = fetch("http://localhost:%d/setup.exe" % PLAIN_PORT[0], "d.exe")
    check(rc != 0 and data is None, "an http:// URL is refused: %s" % err)
    rc, data, part, err = fetch(base + "/missing", "e.exe")
    check(rc != 0 and data is None and not part, "a 404 fails, nothing left: %s" % err)
    env.pop("SSL_CERT_FILE")
    rc, data, part, err = fetch(base + "/setup.exe", "f.exe")
    check(rc != 0 and data is None, "an untrusted certificate fails: %s" % err[:80])
    srv.shutdown()
    plain.shutdown()
    shutil.rmtree(tmp, ignore_errors=True)
    print("fetch-test: %s" % ("all passed" if not FAILS else "%d failed" % FAILS))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
