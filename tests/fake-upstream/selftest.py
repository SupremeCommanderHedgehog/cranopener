"""Exercise the fake upstream in-process.

Runs the server on a thread and drives it with urllib. In-process rather than
as a subprocess because a leaked background server on Windows is a hang in CI
rather than a failure, and because a URL opened from a script file avoids the
Defender heuristic that kills inline `python3 -c` with urlopen.

Deliberately has no `#!` line: build hosts running fapolicyd refuse to read
shebang'd Python files, and this is always invoked as `python3 <file>`.

Usage: python3 selftest.py
Exit 0 on success; prints one line per assertion.
"""
import json
import os
import sys
import tempfile
import threading
import urllib.error
import urllib.request
from http.server import HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))

RUN = 0
FAILED = 0


def check(desc, expected, actual):
    global RUN, FAILED
    RUN += 1
    if expected == actual:
        print("ok   %s" % desc)
    else:
        FAILED += 1
        print("FAIL %s\n       expected: %r\n       actual:   %r"
              % (desc, expected, actual))


def post(url, payload):
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read())


def content(body):
    return body["choices"][0]["message"]["content"]


def run(mode, record_dir):
    """Start a server configured for `mode` and return its base URL + shutdown."""
    os.environ["FAKE_TOOLS_MODE"] = mode
    os.environ["FAKE_SCRIPT"] = os.path.join(HERE, "scripts", "edit-hello.json")
    os.environ["FAKE_RECORD_DIR"] = record_dir
    os.environ["FAKE_PORT"] = "0"

    # Imported fresh each time: the module reads its configuration at import
    # and keeps request state on the handler class.
    for name in list(sys.modules):
        if name == "server":
            del sys.modules[name]
    sys.path.insert(0, HERE)
    import server

    httpd = HTTPServer(("127.0.0.1", 0), server.Handler)
    server.Handler.seen = 0
    server.Handler.served = 0
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    return "http://127.0.0.1:%d" % httpd.server_port, httpd.shutdown


def main():
    with tempfile.TemporaryDirectory() as tmp:
        base, stop = run("reject", tmp)
        try:
            code, body = post(base + "/v1/chat/completions",
                              {"model": "m", "messages": [],
                               "tools": [{"type": "function"}]})
            check("a request carrying tools is rejected", 400, code)
            check("the rejection names the offending parameter",
                  "tools", body["error"]["param"])

            code, body = post(base + "/v1/chat/completions",
                              {"model": "m", "messages": []})
            check("a request without tools succeeds", 200, code)
            check("the first scripted turn is served",
                  "I will look at the workspace first.",
                  content(body).split("\n")[0])

            code, body = post(base + "/v1/chat/completions",
                              {"model": "m", "messages": []})
            check("the second call advances the script",
                  "Now I will create the file that was asked for.",
                  content(body))

            recorded = sorted(f for f in os.listdir(tmp)
                              if f.startswith("req-"))
            check("every request body is recorded", 3, len(recorded))

            with open(os.path.join(tmp, recorded[0])) as fh:
                check("the recorded body is the one that was sent",
                      True, "tools" in json.load(fh))
        finally:
            stop()

    with tempfile.TemporaryDirectory() as tmp:
        base, stop = run("ignore", tmp)
        try:
            code, _ = post(base + "/v1/chat/completions",
                           {"model": "m", "messages": [],
                            "tools": [{"type": "function"}]})
            check("ignore mode accepts tools instead of rejecting", 200, code)
        finally:
            stop()

    print("\nselftest.py: %d run, %d failed" % (RUN, FAILED))
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
