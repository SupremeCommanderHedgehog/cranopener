#!/usr/bin/env python3
"""A minimal OpenAI-shaped endpoint that records what actually arrived.

The office probe's whole job is to capture evidence, and the one failure it
could not diagnose -- three requests whose bodies never reached the upstream --
is invisible from the response alone. So this stub records the REQUEST side:
how many bytes of body arrived, per request. That is the thing test-probe.sh
asserts on, and it is the thing the trip could not tell us.

Deliberately not tests/fake-upstream/server.py: that one exists to refuse the
`tools` parameter for the OpenHands path and is shaped by that job. This one
answers everything successfully and only counts bytes.

Usage: server.py <port-file> <request-log>
  <port-file>    the bound port is written here once listening, so the caller
                 never has to guess a free port or race a fixed one
  <request-log>  one JSON object per request, appended as they arrive
"""
import http.server
import json
import os
import sys

PORT_FILE, REQUEST_LOG = sys.argv[1], sys.argv[2]

# Reproduces the August failure shape: bodies above a threshold are answered
# with the endpoint's own complaint about an empty body. The real mechanism is
# unknown -- curl sent no Expect header, and whether the bytes left the machine
# was never recorded -- so this stub imitates the symptom, which is all the
# probe can key on.
MAX_BODY = int(os.environ.get("PROBE_STUB_MAX_BODY") or 0)

# A refusal that is genuinely about size, so the two kinds of rejection can be
# told apart in a test: this one is a real answer about the window and must not
# be retried, MAX_BODY's is not an answer at all.
HARD_MAX = int(os.environ.get("PROBE_STUB_HARD_MAX") or 0)

# With this set, only the FIRST oversized body draws the empty-body complaint.
# That is what a retry succeeding looks like from the probe's side, and it is
# the case where the bracket has to survive a rung that was already rejected
# for a different reason.
EMPTY_ONCE = os.environ.get("PROBE_STUB_EMPTY_BODY_ONCE") == "1"
_served_empty = []

# A JSON file with a "responses" array of assistant texts, replayed one per
# POST. Step 4 is a conversation, so testing it needs an upstream that can say
# different things on different turns -- including, at a chosen turn, something
# with no tool call in it.
SCRIPT = os.environ.get("PROBE_STUB_SCRIPT", "")
_responses = json.load(open(SCRIPT))["responses"] if SCRIPT else None
_served = []

MODELS = {
    "object": "list",
    "data": [{"id": "stub-model", "object": "model", "owned_by": "stub"}],
}


def record(entry):
    with open(REQUEST_LOG, "a") as fh:
        fh.write(json.dumps(entry) + "\n")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def reply(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        record({"method": "GET", "path": self.path, "body_bytes": 0})
        self.reply(MODELS)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        # Whether the body parses matters as much as whether it arrived: the
        # office failure was a well-formed request whose body was empty by the
        # time something upstream tried to parse it.
        try:
            json.loads(raw)
            parsed = True
        except Exception:
            parsed = False
        record({
            "method": "POST",
            "path": self.path,
            "body_bytes": len(raw),
            "parsed": parsed,
            "http_version": self.request_version,
        })
        if HARD_MAX and len(raw) > HARD_MAX:
            self.reply({"error": {
                "message": "This model's maximum context length is 4096 tokens",
                "type": "invalid_request_error",
            }}, status=400)
            return
        if MAX_BODY and len(raw) > MAX_BODY and not (EMPTY_ONCE and _served_empty):
            _served_empty.append(1)
            self.reply({"error": {
                "message": "Invalid JSON in request body: EOF while parsing a value at line 1 column 0",
                "type": "invalid_request",
            }}, status=400)
            return
        # Steps 1b, 2 and 3 are POSTs too, and they would eat the script before
        # step 4 sent its first turn. They each carry exactly one message; the
        # conversation carries a system prompt as well, and grows from there.
        # Message count is what tells them apart without the stub having to
        # know anything about the probe's internals.
        is_conversation = False
        try:
            is_conversation = len(json.loads(raw).get("messages", [])) >= 2
        except Exception:
            pass

        if _responses and is_conversation:
            # Past the end, repeat the last one rather than crashing: a stub
            # that dies under an over-running loop turns a probe bug into a
            # transport failure and sends the investigation to the wrong layer.
            content = _responses[min(len(_served), len(_responses) - 1)]
            _served.append(1)
        else:
            content = "ok"

        self.reply({
            "id": "chatcmpl-stub",
            "object": "chat.completion",
            "model": "stub-model",
            "choices": [{
                "index": 0,
                "finish_reason": "stop",
                "message": {"role": "assistant", "content": content},
            }],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        })

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w") as fh:
    fh.write(str(server.server_address[1]))
server.serve_forever()
