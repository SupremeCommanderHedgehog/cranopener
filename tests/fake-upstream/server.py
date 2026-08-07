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
                   possible; a harness must survive either. Surrounding
                   whitespace and case are ignored; any other value is a
                   startup error, never a silent fallback.
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
SCRIPT_PATH = os.environ.get("FAKE_SCRIPT", "")
RECORD_DIR = os.environ.get("FAKE_RECORD_DIR", "")

# The only three paths the office endpoint serves, and therefore the only three
# this stub serves. Matched exactly rather than by suffix -- see route().
COMPLETIONS_PATH = "/v1/chat/completions"
MODELS_PATH = "/v1/models"
HEALTH_PATH = "/healthz"

TOOLS_MODES = ("reject", "ignore")
TOOLS_MODE_RAW = os.environ.get("FAKE_TOOLS_MODE", "reject")
TOOLS_MODE = TOOLS_MODE_RAW.strip().lower()
# Refuse to start on a mode this file does not implement, rather than treating
# anything unrecognised as 'ignore'. Under the old fallback a mode spelled
# 'Reject' quietly switched off the single behaviour this stub exists to
# reproduce and every test downstream still reported green -- a stub that
# passes on a misconfiguration is worth less than no stub at all.
if TOOLS_MODE not in TOOLS_MODES:
    raise SystemExit(
        "FAKE_TOOLS_MODE=%r is not a mode this stub implements; expected %s"
        % (TOOLS_MODE_RAW, " or ".join(repr(m) for m in TOOLS_MODES)))


def load_responses():
    if not SCRIPT_PATH:
        return ["ok"]
    with open(SCRIPT_PATH) as fh:
        return json.load(fh)["responses"]


def route(path):
    """The request path with any query string and trailing slash removed.

    Callers compare the result exactly, never by suffix. A base_url that
    already ends in `/v1` produces `/v1/v1/chat/completions`, which is the
    single most common way to misconfigure an OpenAI client; the office
    endpoint 404s it. A stub that answers it turns the misconfiguration most
    likely to be hit into a green test, which is the opposite of the job.
    """
    return path.split("?", 1)[0].rstrip("/") or "/"


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

    def _not_found(self, path):
        # Echoes the path back: when a harness is pointed at the wrong base_url
        # the fix is entirely in the path it asked for, and a bare "not found"
        # sends the reader to the server instead of to their own config.
        self._send(404, {"error": {
            "message": "unknown path: %s" % path,
            "type": "invalid_request_error",
        }})

    def _bad_request(self, message):
        self._send(400, {"error": {
            "message": message,
            "type": "invalid_request_error",
        }})

    def do_GET(self):
        path = route(self.path)
        if path == MODELS_PATH:
            self._send(200, {"object": "list",
                             "data": [{"id": "provider-a/fake",
                                       "object": "model"}]})
        elif path == HEALTH_PATH:
            self._send(200, {"status": "ok"})
        else:
            self._not_found(path)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        path = route(self.path)

        # Counted and recorded before routing or validation, because the record
        # is evidence of what crossed the wire and a body sent to the wrong path
        # is exactly the evidence a misconfiguration investigation needs. Only
        # `served` must stay put for these -- a 404 produced no assistant turn.
        Handler.seen += 1
        n = Handler.seen

        if RECORD_DIR:
            os.makedirs(RECORD_DIR, exist_ok=True)
            with open(os.path.join(RECORD_DIR, "req-%03d.json" % n), "wb") as fh:
                fh.write(raw)

        if path != COMPLETIONS_PATH:
            self._not_found(path)
            return

        try:
            body = json.loads(raw)
        except ValueError:
            self._bad_request("invalid JSON body")
            return

        # `null`, `[]`, `"text"` and `7` are all valid JSON and none of them is
        # a request. Letting one reach `body.get` below raises inside the
        # handler and the client sees a connection reset, which reads as "the
        # stub died" and sends the investigation to the transport layer instead
        # of to the harness that sent the body.
        if not isinstance(body, dict):
            self._bad_request("request body must be a JSON object")
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

        # The script is a fixture, not a bound. A harness that keeps talking
        # past the last scripted turn gets the last turn repeated rather than a
        # crash or a 500: a stub that dies under a runaway loop turns a harness
        # bug into a transport failure and sends the investigation to the wrong
        # layer again. The repetition is not hidden -- the recorded bodies show
        # every extra request -- so a run that ran off the end stays diagnosable.
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
