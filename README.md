# gore

**Batch orchestration for the work that currently gets done
by writing a shell script, because a shell happens to be
sitting there, not because a shell is the right tool for the
job.**

A single binary. Scripts are written in Starlark, a real,
deterministic, Python-like language, not shell syntax. Every
`validate`, `dry-run`, and `run` is recorded to a local,
queryable SQLite journal, not scrollback.

---

## Download

On macOS and Linux:

```bash
brew install dsbitor/gore/gore
```

Or download a signed and notarized (macOS) / checksummed (all
platforms) archive directly from this repository's
[Releases page](https://github.com/dsbitor/gore-releases/releases/latest),
verify it against the accompanying `SHA256SUMS`, and put the
binary on your `PATH`. This repository holds compiled
binaries and release notes only; gore's own source is
developed separately and is not published here.

---

## What it is

gore is a batch orchestration CLI. It replaces the shell
script a team reaches for by default to set up a program,
run it, check its result, and record what happened, with a
real scripting language, structured results a script must
actively check, and a durable audit record of every run.

gore is not a shell. It does not compete with bash, zsh, or
fish for interactive use, and has no interactive prompt of
its own.

## Platforms

| OS | Architecture |
|---|---|
| macOS | Apple Silicon (arm64) |
| Linux | x86-64 (amd64) |
| Linux | ARM64 (aarch64) |

macOS binaries are code-signed and notarized under a
Developer ID Application certificate. A bare CLI binary in a
tarball can't receive a stapled notarization ticket the way
a `.app`/`.pkg`/`.dmg` can, so Gatekeeper verifies it via an
online check the first time it runs rather than fully
offline; this is stated plainly rather than implied to be
identical to an app bundle's own guarantee.

## Verifying a download

Every release publishes a `SHA256SUMS` file alongside its
archives:

```bash
shasum -a 256 -c SHA256SUMS
```

## Examples

Real, worked examples of gore scripts running for real, not
snippets. See [`examples/`](examples/).

- [`examples/filtering-with-awk.md`](examples/filtering-with-awk.md) —
  the smallest useful gore script: run `awk` on a CSV and capture the
  result. Start here.
- [`examples/backup-and-prune.md`](examples/backup-and-prune.md) — back
  up a SQLite database with its own online-safe `.backup` command, then
  prune old backups down to a five-file rotation.
- [`examples/notarization-delay-report.md`](examples/notarization-delay-report.md)
  — queries gore's own journal database from a step, real SQL kept in
  its own `.sql` files and fed to `sqlite3` via `ctx.run`'s
  `stdin_file`, not embedded as Starlark strings.
- [`examples/release-count-report.md`](examples/release-count-report.md)
  — a `curl | jq` habit translated into `ctx.pipe`, checking this
  repository's own release count against a maintenance threshold.
- [`examples/tooling-bundle.md`](examples/tooling-bundle.md) —
  downloads SQLite, Fossil, Go, and Quarto and re-packages them into an
  offline distribution bundle. Real bandwidth and disk cost; read the
  warning at the top before running it.
- [`examples/release-pipeline.md`](examples/release-pipeline.md) —
  the actual script that built and published this release, and the
  real `gore printlog` transcript of it running: cross-compiling,
  code-signing, notarizing, rendering the reference manual to PDF,
  checksumming, and publishing.

## Contact 

### ITOR 

I.T. Operational Risk (ITOR) is a small consulting company that
has specialized in Information Technology risk in production,
development and test environments. ITOR has 50 years of experience
evaluating, planning, and improving operational environments and has 
conducted  many different types of studies associated with, problem 
and risk identification, incident analysis, problem and risk resolution 
and the developed of improvement plans and activities in these areas.
Data collection and the programmatic analysis of data has been an 
integral part of those activities.

### eMail

Please contact us at itoperationalrisk at gmail dot com.


## Source

gore's source is developed separately and is not published
in this repository, by design, not yet, while the project is
still a prototype. This repository publishes compiled
release artifacts, examples and release notes only.

## License

Copyright 2026 David S. Banham and ITOR. All rights reserved.
