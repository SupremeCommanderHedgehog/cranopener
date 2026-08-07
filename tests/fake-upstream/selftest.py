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

COMPLETIONS = "/v1/chat/completions"

# Pinned here rather than read back out of scripts/edit-hello.json: a test that
# reads its expectation from the fixture agrees with the fixture no matter what
# either of them ends up saying.
TURNS = [
    "I will look at the workspace first.\n\nLet me list what is here.",
    "Now I will create the file that was asked for.",
    "The file is created. Let me confirm it is on disk.",
    "Confirmed. hello.txt exists and contains the expected text.",
    "The task is complete.",
]

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


def dig(obj, *keys):
    """Walk nested keys, returning None when the shape is not what was wanted.

    A regressed route answers with an error body instead of a completion, and
    reading a missing key straight out of it would end the run in a traceback
    -- which hides every assertion after the first regression instead of
    reporting them one line each.
    """
    for key in keys:
        try:
            obj = obj[key]
        except (KeyError, IndexError, TypeError):
            return None
    return obj


def post_raw(url, data):
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read())
    except OSError as exc:
        # A handler that raised leaves the client holding a reset rather than a
        # response. Reported as a failed assertion instead of a traceback,
        # because "answers instead of dying" is precisely what is under test.
        return 0, {"error": {"message": "no response: %r" % exc}}


def post(url, payload):
    return post_raw(url, json.dumps(payload).encode())


def get(url):
    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read())
    except OSError as exc:
        return 0, {"error": {"message": "no response: %r" % exc}}


def content(body):
    return dig(body, "choices", 0, "message", "content")


def recorded_bytes(directory, name):
    """The named recorded body, or None if there is no such file.

    Absent is an assertion failure, not a crash: a mutation that misnumbers
    every recorded file has to be reported by the name check rather than end
    the run before the name check runs.
    """
    try:
        with open(os.path.join(directory, name), "rb") as fh:
            return fh.read()
    except OSError:
        return None


def recorded_json(directory, name):
    try:
        return json.loads(recorded_bytes(directory, name))
    except (TypeError, ValueError):
        return None


def fresh_import(mode, script="", record_dir=""):
    """Import server.py fresh with `mode` in the environment; return the module.

    Fresh each time: the module reads its configuration at import and keeps
    request state on the handler class. Raises SystemExit when the module
    rejects the configuration, which is a behaviour under test rather than a
    mishap, so callers that pass a bad mode catch it.
    """
    os.environ["FAKE_TOOLS_MODE"] = mode
    os.environ["FAKE_SCRIPT"] = script
    os.environ["FAKE_RECORD_DIR"] = record_dir
    os.environ["FAKE_PORT"] = "0"

    sys.modules.pop("server", None)
    if HERE not in sys.path:
        sys.path.insert(0, HERE)
    import server
    return server


def run(mode, record_dir):
    """Start a server configured for `mode` and return its base URL + shutdown."""
    server = fresh_import(mode, os.path.join(HERE, "scripts", "edit-hello.json"),
                          record_dir)

    httpd = HTTPServer(("127.0.0.1", 0), server.Handler)
    server.Handler.seen = 0
    server.Handler.served = 0
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    return "http://127.0.0.1:%d" % httpd.server_port, httpd.shutdown


def reject_mode_checks(tmp):
    base, stop = run("reject", tmp)
    url = base + COMPLETIONS
    try:
        # req-001. The behaviour the stub exists for.
        code, body = post(url, {"model": "m", "messages": [],
                                "tools": [{"type": "function"}]})
        check("a request carrying tools is rejected", 400, code)
        check("the rejection names the offending parameter",
              "tools", dig(body, "error", "param"))

        # req-002, req-003. The script starts at turn one and advances only on
        # a served completion -- the refusal above consumed nothing.
        code, body = post(url, {"model": "m", "messages": []})
        check("a request without tools succeeds", 200, code)
        check("the first scripted turn is served", TURNS[0], content(body))

        code, body = post(url, {"model": "m", "messages": []})
        check("the second call advances the script", TURNS[1], content(body))

        # req-004, req-005. Paths the office endpoint does not serve.
        # `/v1/v1/...` is what a base_url that already ends in /v1 produces;
        # answering it here would green-light the likeliest misconfiguration.
        code, body = post(base + "/v1" + COMPLETIONS,
                          {"model": "m", "messages": []})
        check("a base_url that already ends in /v1 is a 404", 404, code)
        check("the 404 names the path that was asked for", True,
              "/v1/v1/chat/completions" in (dig(body, "error", "message") or ""))
        check("the 404 keeps the OpenAI error shape",
              "invalid_request_error", dig(body, "error", "type"))

        code, body = post(base + "/totally/wrong", {"model": "m", "messages": []})
        check("an unserved path is a 404", 404, code)

        # req-006 to req-009. Past turn three, which is where flattened-history
        # handling breaks and therefore the only region the integration test
        # cares about, then one call past the end of the script.
        code, body = post(url, {"model": "m", "messages": []})
        check("a 404 consumed no scripted turn", TURNS[2], content(body))

        code, body = post(url, {"model": "m", "messages": []})
        check("the script survives past turn three", TURNS[3], content(body))

        code, body = post(url, {"model": "m", "messages": []})
        check("the last scripted turn is served", TURNS[4], content(body))

        code, body = post(url, {"model": "m", "messages": []})
        check("running off the end repeats the last turn instead of failing",
              TURNS[4], content(body))

        # req-010, req-011. Presence of the key is what the office endpoint
        # objects to, so an empty or null `tools` is still a rejection.
        code, body = post(url, {"model": "m", "messages": [], "tools": []})
        check("an empty tools array is still a rejection", 400, code)

        code, body = post(url, {"model": "m", "messages": [], "tools": None})
        check("a null tools value is still a rejection", 400, code)

        # req-012 to req-016. Bodies that must produce a response rather than a
        # reset: a reset in the container test reads as "the stub died" and
        # sends the debugging to the transport layer.
        code, body = post_raw(url, b"not json at all")
        check("an unparseable body is a 400", 400, code)
        check("the unparseable 400 says so", "invalid JSON body",
              dig(body, "error", "message"))

        for payload in (None, [], "text", 7):
            code, body = post(url, payload)
            check("JSON %r is answered, not crashed on" % (payload,), 400, code)
            check("the %r 400 asks for a JSON object" % (payload,),
                  "request body must be a JSON object",
                  dig(body, "error", "message"))

        # Readiness and discovery. /healthz is the container readiness gate, so
        # a regression there shows up as a startup timeout in front of a server
        # that is working perfectly -- a bill this repo has already paid once.
        code, body = get(base + "/healthz")
        check("/healthz answers 200", 200, code)
        check("/healthz reports ok", "ok", dig(body, "status"))

        code, body = get(base + "/v1/models")
        check("GET /v1/models answers 200", 200, code)
        check("GET /v1/models returns a list", "list", dig(body, "object"))
        check("GET /v1/models names the model", "provider-a/fake",
              dig(body, "data", 0, "id"))

        code, _ = get(base + "/v1/v1/models")
        check("a doubled /v1 on the model listing is a 404", 404, code)

        # Names, not just a count: "recorded in wire order" is the property the
        # integration test leans on to prove no tools array reached the wire,
        # and a run that numbers every file wrong still counts correctly.
        recorded = sorted(f for f in os.listdir(tmp) if f.startswith("req-"))
        check("every request is recorded, numbered in wire order",
              ["req-%03d.json" % i for i in range(1, 17)], recorded)

        check("the recorded body is the one that was sent", True,
              "tools" in (recorded_json(tmp, "req-001.json") or {}))

        check("an unparseable body is recorded verbatim too",
              b"not json at all", recorded_bytes(tmp, "req-012.json"))
    finally:
        stop()


def ignore_mode_checks(tmp):
    base, stop = run("ignore", tmp)
    try:
        code, body = post(base + COMPLETIONS,
                          {"model": "m", "messages": [],
                           "tools": [{"type": "function"}]})
        check("ignore mode accepts tools instead of rejecting", 200, code)
        check("ignore mode still serves the script", TURNS[0], content(body))
    finally:
        stop()


def mode_validation_checks():
    # A mode this stub does not implement has to stop the process at startup.
    # The old fallback made FAKE_TOOLS_MODE=Reject a silent 'ignore', which
    # switches off the rejection and leaves every downstream test green.
    for bad in ("Rejcet", "off", ""):
        try:
            fresh_import(bad)
            err = None
        except SystemExit as exc:
            err = str(exc)
        check("FAKE_TOOLS_MODE=%r is refused at startup" % bad,
              True, err is not None)
        check("the refusal quotes the offending value %r" % bad,
              True, err is not None and repr(bad) in err)

    for given, wanted in ((" reject ", "reject"), ("REJECT", "reject"),
                          ("Ignore", "ignore"), ("\tignore\n", "ignore")):
        try:
            actual = fresh_import(given).TOOLS_MODE
        except SystemExit as exc:
            actual = "refused: %s" % exc
        check("FAKE_TOOLS_MODE=%r is accepted as %r" % (given, wanted),
              wanted, actual)


def main():
    with tempfile.TemporaryDirectory() as tmp:
        reject_mode_checks(tmp)

    with tempfile.TemporaryDirectory() as tmp:
        ignore_mode_checks(tmp)

    mode_validation_checks()

    print("\nselftest.py: %d run, %d failed" % (RUN, FAILED))
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
