# Spike tooling

Tools that answer questions the design cannot answer by reasoning. Kept in the
repository rather than thrown away, because they get re-run whenever the
question comes back — after an opencode upgrade, or after a change to the tool
set.

All tooling is endpoint-agnostic. Targets come from the environment, because
this repository is public.

| Tool | Question it answers |
|---|---|
| `capture-request.py` | What does opencode actually send to a model? |
| `count-tool-tokens.py` | How much context do the tool schemas cost? |
| `measure-tool-schema.sh` | Both of the above, end to end, against a real image |

## Measuring the tool schema cost

opencode re-sends its full tool schema on every turn, so its size sets a floor
on context consumption for an entire session. If the schemas alone consume a
large share of the window, that constrains the design before anything else
does — and the cheapest fix (trimming the tool set) has to happen early.

From this machine, against the Linux build host:

```bash
bash scripts/dev/remote-measure.sh
```

Or directly, on any host with podman and the image:

```bash
IMAGE=cranopener:dev CONTEXT=128000 bash spike/measure-tool-schema.sh
```

Reading the result:

| Schemas as a share of context | Meaning |
|---|---|
| under 10% | Fine. No action needed. |
| 10–25% | Workable, but trim the tool set for long autonomous runs. |
| over 25% | Too large. Cut the tool set before building on this. |

The run also writes `tests/fixtures/opencode-request.json` — a real captured
request with the model name replaced. That fixture is the ground truth any
future request-transform test would be written against.

## Notes

The token counts are estimates at four characters per token, not real
tokenizer output. That is deliberate: the question is "is this 5% or 40% of
the window", which an estimate settles, and it keeps the tooling dependency
free on machines where installing packages is not straightforward.

Results belong in `RESULTS.md`, which is gitignored along with the rest of
`docs/`-style local notes if it contains anything environment-specific.
