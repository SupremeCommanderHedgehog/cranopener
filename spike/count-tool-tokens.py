"""Report the token cost of the tool schemas in a captured request.

Deliberately has no `#!` line -- see the note in capture-request.py. Build
hosts running fapolicyd refuse to read shebang'd Python files, and this is
always invoked as `python3 <file>`. Do not add one back.

Uses the standard ~4-characters-per-token approximation rather than a real
tokenizer. That is deliberate: the question is "is this 5% or 40% of the
context window", which a rough estimate settles, and it keeps the spike free
of third-party dependencies on a machine that may not be able to install any.

Pass --context N to get the share of a specific window.

Usage:
  python3 count-tool-tokens.py captured-request.json
  python3 count-tool-tokens.py captured-request.json --context 128000
"""
import json
import sys

CHARS_PER_TOKEN = 4


def estimate(obj):
    return len(json.dumps(obj, separators=(",", ":"))) // CHARS_PER_TOKEN


def main(argv):
    path = argv[0]
    context = None
    if "--context" in argv:
        context = int(argv[argv.index("--context") + 1])

    with open(path) as fh:
        request = json.load(fh)

    tools = request.get("tools", [])
    if not tools:
        print("no `tools` array in the captured request", file=sys.stderr)
        print(f"top-level keys present: {sorted(request)}", file=sys.stderr)
        msgs = request.get("messages", [])
        print(f"messages: {len(msgs)}", file=sys.stderr)
        for m in msgs[:3]:
            body = str(m.get("content"))[:120].replace("\n", " ")
            print(f"  {m.get('role'):10s} {body}", file=sys.stderr)
        print(
            "\nA `permission` block set to deny strips tools from the request. "
            "So does disabling them via `tools` in the config.",
            file=sys.stderr,
        )
        return 1

    total = estimate(tools)
    messages = estimate(request.get("messages", []))

    print(f"tool count:          {len(tools)}")
    print(f"tool schema tokens:  ~{total}")
    print(f"message tokens:      ~{messages}")
    print(f"request total:       ~{total + messages}")

    if context:
        share = 100.0 * total / context
        print(f"context window:      {context}")
        print(f"schemas are:         {share:.1f}% of context")
        print()
        if share < 10:
            print("VERDICT: fine. No action needed.")
        elif share < 25:
            print("VERDICT: workable, but trim the tool set for long runs.")
        else:
            print("VERDICT: too large. Cut the tool set before building on this.")

    print()
    print("per tool, largest first:")
    ranked = sorted(
        ((estimate(t.get("function", t)), t) for t in tools),
        key=lambda pair: pair[0],
        reverse=True,
    )
    for size, tool in ranked:
        name = tool.get("function", {}).get("name") or tool.get("name") or "?"
        print(f"  {name:24s} ~{size}")

    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1:]))
