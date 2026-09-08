# x5ch-cr

Crystal port of [x5ch-go](https://github.com/Neko-Kuroi/termchan) (a Go port of
the Ruby CLI [x5ch](https://github.com/kogfx/x5ch)) — a terminal 5ch browser
with a Discord mirroring/transfer feature.

**Lineage:** Ruby (`kogfx/x5ch`, untyped) → Go (`Neko-Kuroi/termchan`, types
fixed here) → Crystal (this repo, ported from the Go source with the Ruby
original as a cross-reference).

## Status

All functionality from x5ch-go is ported and verified, **except
`export-batch`**, which is also unimplemented in the Go source. This includes
the full interactive TUI (menus, boards, threads, pager, search, Discord
transfer queue, history management) and the non-interactive subcommands
(`search`, `read`, `export`).

## Layout

```
src/x5ch/
├── fivechbrowser/   # HTTP fetch, HTML/JSON parsing, board menu, thread list,
│                     # ff5ch search, next-thread detection, browser facade,
│                     # archival export, shared interfaces
├── history/         # JSON-file-backed read-history store
├── discord/         # Discord bot client (thread creation, message posting)
├── transfer/        # background queue worker that mirrors threads to Discord
├── terminal/         # raw-mode toggling, terminal size, East-Asian width
│                     # calculation — shared by pager/ and selector/
├── pager/           # scrollable thread-content viewer
├── selector/        # generic paginated list picker (menus, boards, threads)
└── cmd/             # config, PID/lock handling, subcommands, screen
                      # rendering helpers, and main.cr (entry point)
```

10 directories, 25 files. `terminal/` has no equivalent in x5ch-go; it was
split out during the Crystal port because both `pager/` and `selector/` need
the same raw-mode/size/width logic.

## Building

Requires Crystal 1.11.2+.

```sh
crystal build src/x5ch/cmd/main.cr -o x5ch
./x5ch                                    # interactive TUI
./x5ch search <keyword>                   # one-shot JSON search
./x5ch read <board_url> <dat_file>        # one-shot JSON thread read
./x5ch export <board_url> <dat_file> [--since-num N]   # archival JSON export
```

Configuration is via environment variables (all optional, sensible defaults
under `$HOME`):

| Variable | Purpose |
|---|---|
| `X5CH_DISCORD_BOT_TOKEN` | Discord bot token (transfer feature disabled without it) |
| `X5CH_DISCORD_CHANNEL_ID` | Discord channel to create threads in |
| `X5CH_HISTORY_FILE` | default `~/.x5ch_history.json` |
| `X5CH_QUEUE_FILE` | default `~/.x5ch_queue.json` |
| `X5CH_LOCK_FILE` | default `~/.x5ch.lock` |
| `X5CH_PID_FILE` | default `~/.x5ch.pid` |

## Testing approach

Every module was verified by writing a throwaway test file, compiling it with
`crystal build -o bin` (never `crystal run` — see below), and running the
resulting binary — never by type-checking alone.

This mattered because `crystal build --no-codegen` (used for quick syntax/type
checks throughout development) **does not type-check a method body unless
something in the program actually calls it.** A method full of typos or
missing requires can pass `--no-codegen` cleanly if nothing exercises it. This
was confirmed directly: a method calling a nonexistent function compiled with
exit 0 as long as nothing called that method. Three real bugs (a wrong
`URI` method name, two missing `include`s) only surfaced once `main.cr` wired
every module together and were invisible to all the individual per-file
checks that preceded it.

Interactive modules (`pager`, `selector`, `cmd/menus.cr`, `cmd/content.cr`,
`cmd/main.cr`) were tested against a **real pseudo-terminal** (`openpty` via
FFI), not mocked input/output, since raw-mode behavior, terminal escape
sequences, and concurrent read/write timing don't show up any other way. Key
practices that came out of that:

- One persistent reader fiber per PTY side, pushing into a buffered
  `Channel(Bytes)`, drained with `select` + `timeout` — not a new fiber per
  read attempt (abandoned fibers silently steal bytes meant for later reads).
- `crystal build -o bin && ./bin`, not `crystal run` — the latter intermittently
  hung on PTY-driven programs in this environment for no clear reason.
- Draining "until N seconds of silence" doesn't work against a process that
  emits output on a steady cadence shorter than N (looks exactly like a hang);
  drain for a fixed total duration instead.
- Sending a raw `0x03` byte to a *separate child process* over a PTY does not
  reliably become a real `SIGINT` unless that process has been made a session
  leader with a controlling terminal (`setsid` + `TIOCSCTTY`), which plain
  process spawning doesn't set up. `Process.signal(Signal::TERM, pid)` is a
  more reliable way to test signal-triggered cleanup paths.

Most tests were re-run 3× to rule out fiber-scheduling flakiness.

## Notable deviations from and fixes to the Go source

- **`fivechbrowser/parse.cr`**: the Ruby original's "restore stripped `h`"
  regex (`/(^|[^h])(tps?:\/\/)/`) is buggy and corrupts already-correct URLs
  (`http://` → `hthtp://`), confirmed by direct testing. The Go port fixed
  this with a negative lookbehind; Crystal's native `Regex` lookbehind support
  let this port follow Go's fix directly.
- **`fivechbrowser/export.cr`**: Crystal's `Time#to_rfc3339` always forces
  UTC, unlike Go's `time.RFC3339Nano` which preserves the original offset.
  A custom formatter (`format_rfc3339_nano`) reproduces Go's exact output,
  including trailing-zero fraction trimming.
- **`fivechbrowser/nextthread.cr`, `fivechbrowser/browser.cr`**: both had a
  URL-building bug using `URI#host` (drops the port) instead of `URI#authority`
  (`host[:port]`) — found via a test against a non-default-port mock server.
- **`pager/pager.cr`**: the first draft invented a `/`-search feature and a
  background-fiber key reader, neither of which exist in the real
  `pager.go`. It was rewritten from scratch to match the actual Go source
  (single synchronous blocking read loop, `ContentItem`-styled-line renderer,
  `contextAt`-based `Result{thread, res}`) after this was caught by a test
  failure and a careful re-read.
- **`terminal/terminal.cr`**: `IO::FileDescriptor#raw!`/`#cooked!` do not
  durably change terminal mode in Crystal 1.11.2 — an internal `ensure`
  always reverts them immediately. Replaced with hand-rolled
  `enable_raw_mode`/`restore_mode` using `tcgetattr`/`cfmakeraw`/`tcsetattr`
  directly, verified against a real PTY.
- **`transfer/worker.cr`**: Crystal has no `sync.Cond` equivalent. Implemented
  the wait/signal/broadcast pattern by replacing a `Channel(Nil)` with a fresh
  one and closing the old one — any fiber blocked on `receive` for the old
  channel wakes immediately with `Channel::ClosedError`, which is treated as
  the wake signal.
- **`selector/selector.cr`**: ported `ReadLine`'s byte-by-byte input handling
  as-is, including an inherited limitation from the Go source — it mishandles
  multi-byte UTF-8 (e.g. Japanese) typed live into search/number prompts,
  since each byte is converted independently rather than reassembled into
  proper codepoints.

## Recurring Crystal gotchas found during this port

1. `crystal build --no-codegen` doesn't check unreached method bodies (see
   Testing approach above).
2. An unqualified call to a `def self.foo` from inside a `class` nested in a
   `module`, or from an instance method of the same class, does not resolve —
   it must be qualified. Two `def self.` methods in the *same* module/class
   scope can call each other unqualified, though.
3. A method with an explicit `: Nil` return type silently discards whatever
   its body evaluates to.
4. Crystal `Channel`s raise `Channel::ClosedError` on `receive` from an
   already-closed channel; Go's channels return the zero value instead.
5. `require` only accepts relative paths or shard names, never absolute
   filesystem paths.
6. A `Regex` literal's `/m` modifier means DOTALL (Ruby/Onigmo convention),
   not line-anchored multiline as in many other regex flavors.
7. `next` cannot be used inside a `Proc` literal.
8. Reusing a variable name across unrelated top-level `spawn`/`select` blocks
   in one script file unifies its inferred type across the whole file, which
   can produce spurious type errors far from the real problem.