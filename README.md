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

No release has been published yet. This repository holds
compiled binaries and release notes only, gore's own source
is developed separately and is not published here.

Once a release exists, the intended path on macOS and Linux:

```bash
brew install gore
```

(planned, once a Homebrew tap exists) or download a signed
and notarized (macOS) / checksummed (all platforms) archive
directly from this repository's
[Releases page](https://github.com/dsbitor/gore-releases/releases).

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

## Source

gore's source is developed separately and is not published
in this repository, by design, not yet, while the project is
still a prototype. This repository publishes compiled
release artifacts and release notes only.

## License

Copyright 2026 David S. Banham. All rights reserved.
