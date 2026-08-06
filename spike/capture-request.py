#!/usr/bin/env python3
"""Record the exact /v1/chat/completions body opencode sends.

opencode re-sends its tool schemas on every turn, so their size sets a floor
on context consumption for the whole session. Guessing at that floor is how
you discover in week six that the tool definitions alone eat a third of the
window. This captures the real thing.

Returns a minimal valid OpenAI response so opencode does not error out before
the body has been written.

Usage: python3 capture-request.py [output-path] [port]
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

OUT = sys.argv[1] if len(sys.argv) > 1 else "captured-request.json"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8899


def has_tools(body):
    """True if this body carries a non-empty tools array."""
    try:
        return bool(json.loads(body).get("tools"))
    except (ValueError, AttributeError, TypeError):
        return False


class Handler(BaseHTTPRequestHandler):
    # opencode may send several requests per run, and a later one can carry no
    # tools at all. Overwriting blindly would discard the body we came for.
    captured_tools = False

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)

        tools = has_tools(body)
        if tools or not Handler.captured_tools:
            with open(OUT, "wb") as fh:
                fh.write(body)
            if tools:
                Handler.captured_tools = True
            print(
                f"captured {length} bytes (tools={tools}) -> {OUT}",
                flush=True,
            )
        else:
            print(f"ignored {length} bytes (no tools)", flush=True)

        payload = json.dumps(
            {
                "id": "chatcmpl-capture",
                "object": "chat.completion",
                "created": 0,
                "model": "capture",
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": "captured"},
                        "finish_reason": "stop",
                    }
                ],
                "usage": {
                    "prompt_tokens": 0,
                    "completion_tokens": 0,
                    "total_tokens": 0,
                },
            }
        ).encode()

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        # The default handler logs every request to stderr, which buries the
        # one line we actually care about.
        pass


if __name__ == "__main__":
    print(f"listening on :{PORT}, writing to {OUT}", flush=True)
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
