"""A stub OpenAI-compatible endpoint that refuses the `tools` parameter.

This exists so the provider-A path can be falsified at a desk instead of on an
office visit. It mimics the one behaviour that defines that endpoint -- it will
not accept tool definitions -- and records every request body so a test can
assert what actually went over the wire rather than what a harness claims it
sent.

Deliberately has no `#!` line: build hosts running fapolicyd refuse to read
shebang'd Python files, and this is always invoked as `python3 <file>`.

Configuration is entirely environmental, so the same file serves the offline
self-test and the in-container integration test:

  FAKE_PORT        listen port, default 8899
  FAKE_TOOLS_MODE  'reject' (400, the observed office behaviour) or 'ignore'
                   (200, tools silently dropped). Both were reported as
                   possible; a harness must survive either.
  FAKE_SCRIPT      path to a JSON file with a "responses" array of assistant
                   texts, replayed one per request
  FAKE_RECORD_DIR  directory to write each request body into, as req-NNN.json

Usage: python3 server.py
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(os.environ.get("FAKE_PORT", "8899"))
TOOLS_MODE = os.environ.get("FAKE_TOOLS_MODE", "reject")
SCRIPT_PATH = os.environ.get("FAKE_SCRIPT", "")
RECORD_DIR = os.environ.get("FAKE_RECORD_DIR", "")


def load_responses():
    if not SCRIPT_PATH:
        return ["ok"]
    with open(SCRIPT_PATH) as fh:
        return json.load(fh)["responses"]


class Handler(BaseHTTPRequestHandler):
    responses = load_responses()
    # Two counters on purpose. `seen` numbers every request that arrives, so
    # the recorded bodies stay in wire order including the ones that were
    # refused. `served` walks the script and only moves when a completion
    # actually went back -- a refused request produced no assistant turn, so
    # letting it consume one would silently shift the whole conversation and
    # make a harness look like it skipped a step it never took.
    seen = 0
    served = 0

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            self._send(200, {"object": "list",
                             "data": [{"id": "provider-a/fake",
                                       "object": "model"}]})
        elif self.path.rstrip("/") == "/healthz":
            self._send(200, {"status": "ok"})
        else:
            self._send(404, {"error": {"message": "not found"}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)

        Handler.seen += 1
        n = Handler.seen

        if RECORD_DIR:
            os.makedirs(RECORD_DIR, exist_ok=True)
            with open(os.path.join(RECORD_DIR, "req-%03d.json" % n), "wb") as fh:
                fh.write(raw)

        try:
            body = json.loads(raw)
        except ValueError:
            self._send(400, {"error": {"message": "invalid JSON body"}})
            return

        # The whole point of this stub. The office endpoint will not accept
        # tool definitions, so a harness that sends them must fail here, loudly
        # and at the desk, rather than silently at the provider a month later.
        if "tools" in body and TOOLS_MODE == "reject":
            self._send(400, {"error": {
                "message": "this endpoint does not support the 'tools' parameter",
                "type": "invalid_request_error",
                "param": "tools",
            }})
            return

        idx = min(Handler.served, len(Handler.responses) - 1)
        Handler.served += 1
        text = Handler.responses[idx]

        self._send(200, {
            "id": "chatcmpl-fake-%03d" % n,
            "object": "chat.completion",
            "created": 0,
            "model": body.get("model", "provider-a/fake"),
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": text},
                "finish_reason": "stop",
            }],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0,
                      "total_tokens": 0},
        })

    def log_message(self, *args):
        # The default handler logs every request to stderr, which buries the
        # lines a test actually reads.
        pass


def serve():
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    print("fake upstream on :%d, tools=%s" % (PORT, TOOLS_MODE), flush=True)
    sys.exit(serve())
