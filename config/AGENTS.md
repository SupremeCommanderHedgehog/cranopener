# House rules

These instructions apply to every session run inside the cranopener container.

## Environment

This container ships C/C++, C#/F#, Go, Julia, Node.js, Python, R, and Rust
toolchains. Prefer the language already used by the project you are in; do not
introduce a new one without being asked.

The working directory is `/workspace`, which is normally a mounted host
directory. Treat everything outside `/workspace` as disposable — changes there
are lost when the container exits.

## Conventions

- Match the surrounding code's style, naming, and comment density.
- Run a project's existing tests before claiming a change works.
- Do not add dependencies to satisfy a one-off need.
