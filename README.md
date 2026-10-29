# joy-cli-platform

The Roc platform `./joy` runs on: a command-line platform whose program can also
serve HTTP, publish server-sent events and watch files.

## What it offers

| Module | From | What it is for |
|---|---|---|
| `Env`, `Path`, `File`, `Cmd`, `Signal`, `Stdout`, `Stderr`, `Http`, `Url`, `OsStr`, `IOErr`, `Duration`, `Sleep`, `Monotonic`, `Utc`, `Random`, `System` | basic-cli 0.30.0 | arguments and settings, files, processes that are spawned, read, polled and killed, Ctrl-C, output, HTTP requests |
| `Tty` | basic-cli 0.30.0, plus `size!`, `is_terminal!` and `is_tty!` from basic-cli's terminal fork | raw mode restored on exit, signals and crashes, and what prompts need to know about the terminal |
| `Stdin` | basic-cli 0.30.0, plus `bytes_within!` | reading keys with a timeout |
| `Server` | new, with basic-webserver's file serving | a server `main!` starts and stops, with handlers on threads of their own |
| `Sse` | basic-webserver | event frames |
| `Events` | new | a broadcast `main!` publishes to and event streams read from |
| `Watch` | new | changed files, from the operating system or by polling |
| `Crypt` | basic-webserver, plus `Sha256` and `hash_file!` | content hashes for names in a build |

Left out: SQLite, TCP, Unix sockets and locales from basic-cli, and request
body sinks, multipart forms, readiness and metrics probes, compression and
access logs from basic-webserver.

### Server

`Server.start!` binds a port, port 0 for one from the system, and returns once
it listens, with the port it got. `ServerErr(AddrInUse)` means the port is
taken. The server runs until `Server.stop!` or until `main!` returns.

The handler is a Roc closure, and its context is whatever it captures. It
runs on one of the server's handler threads, beside `main!` and beside other
requests. It gets the shared `http` package's `Request`, so a proxy can pass
it to `Http.send!` as it is, and answers with one of:

- `Server.respond(response)`, a `Response` built in Roc
- `Server.file(root, path)`, a file from a root declared at start, streamed by
  the host. Paths are opened one component at a time without following links,
  dotfiles are refused, and conditional and range requests are answered.
- `Server.stream(events, headers)`, an event stream

A handler that returns `Err` is logged to stderr and answered with a 500.

### Events

`Events.publish!` sends a frame to every open stream at once, and returns
how many it reached. Each new stream starts with the greeting given to
`Events.set_greeting!`, the `hello` of `./joy dev`, and setting the greeting
and opening a stream do not race. A stream that falls behind by more than the
buffer holds is closed, so the page reconnects and starts from the greeting.

### Watch

One watch per folder, `trees` with every folder below them and `folders`
alone, and folders named in `skip` never entered. What `Watch.next!` reports
comes from comparing each file's size and time of change with what the watch
saw before. A burst of events is one list once nothing has changed for
`quiet`, an event that changed nothing is not reported, and lost events are
caught by comparing everything. `poll: Every(interval)` compares on a timer
for filesystems that send no events. `Watch.set!` changes the watched
folders without losing changes in the ones kept.

### Signals

As in basic-cli 0.30, a program that calls `Signal.catch!([Interrupt])` gets
`Err(Interrupted)` from blocking effects on Ctrl-C, `Watch.next!` included,
and acknowledges it with `Signal.poll!()` before cleaning up. Without
`catch!`, Ctrl-C ends the process, leashed children with it, and the terminal
is restored.

## Status

The targets are Linux (x64 and arm64, musl) and macOS (x64 and arm64), built
against Roc 0c440e5, Joy's pin. Linux x64 is built and tested. On macOS,
`Watch` uses kqueue, so the host needs no system frameworks. Windows is not a
target yet.

## Development

The Nix shell has the pinned Roc, Rust, Zig and Python:

```sh
nix develop
./ci/regenerate_glue.sh      # after changing platform/Host.roc or main.roc
python3 scripts/build.py     # the host for this machine
python3 scripts/test.py      # Rust tests, roc test, and every app in scripts/test_spec.json
```

`tests/server.roc`, `tests/watch.roc`, `tests/terminal.roc` and
`tests/crypt.roc` cover the additions. The Rust tests cover the file server,
the watch, events and hashing.
