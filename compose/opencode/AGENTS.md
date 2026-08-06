# House rules

These instructions apply to every session run inside the cranopener container.

## Environment

This container ships C/C++, C#/F#, Go, Julia, Node.js, Python, R, and Rust
toolchains. Prefer the language already used by the project you are in; do not
introduce a new one without being asked.

The working directory is `/workspace`, which is normally a mounted host
directory. Treat everything outside `/workspace` as disposable — changes there
are lost when the container exits.

## Unattended operation

Sessions usually run with no operator watching. Anything that waits for input
waits forever.

- Pass non-interactive flags explicitly: `git --no-pager`, `apt-get -y`,
  `npm --yes`. Do not rely on a default being non-interactive.
- Never start a pager, file watcher, REPL, or development server in the
  foreground.
- Bound every test and build command with a timeout, and treat a timeout as a
  failure to report rather than a reason to retry.
- Prefer one command that reports everything over a sequence that needs a
  decision between each step.

## Conventions

- Match the surrounding code's style, naming, and comment density.
- Run a project's existing tests before claiming a change works.
- Do not add dependencies to satisfy a one-off need.
