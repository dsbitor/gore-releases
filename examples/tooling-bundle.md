# Example: building an offline tooling bundle

Downloads four real, independently maintained CLI tools, SQLite,
Fossil, Go, and Quarto, gore's own toolset, and re-packages them into
one zip for local, offline distribution: the kind of thing you'd hand
to a machine that can't reach the internet, or archive as "exactly what
we built this release with."

> **Disk and bandwidth, before you run this.** At the versions pinned
> in `config.gbatch` below, this downloads roughly 325 MB (Go and
> Quarto are the bulk of it) and produces a similarly sized output
> bundle, already-compressed archives don't shrink much further under
> zip, so budget around **650 MB of working storage at peak**. Bumping
> any pinned version later, especially Go or Quarto, can only make that
> larger, never smaller — this script says so in its own opening
> comment too, not just here.

The real files, ready to run as-is: [`tooling-bundle/`](tooling-bundle/).

## The config

```python
# config.gbatch
gbatch_version = ">= 0"

# Versions are pinned by hand here, the same philosophy gore's own
# release pipeline uses for release_line: chosen deliberately, not
# resolved to "whatever is newest today" automatically. Bump these on
# purpose when you want newer tools; each one was a real, working URL
# at the time this example was written.
tools = [
    {
        "name": "sqlite",
        "url": "https://www.sqlite.org/2026/sqlite-tools-osx-arm64-3530400.zip",
        "filename": "sqlite-tools-osx-arm64-3530400.zip",
    },
    {
        "name": "fossil",
        "url": "https://fossil-scm.org/home/uv/fossil-mac-arm-2.28.tar.gz",
        "filename": "fossil-mac-arm-2.28.tar.gz",
    },
    {
        "name": "go",
        "url": "https://go.dev/dl/go1.27.0.darwin-arm64.tar.gz",
        "filename": "go1.27.0.darwin-arm64.tar.gz",
    },
    {
        "name": "quarto",
        "url": "https://github.com/quarto-dev/quarto-cli/releases/download/v1.10.18/quarto-1.10.18-macos.tar.gz",
        "filename": "quarto-1.10.18-macos.tar.gz",
    },
]

download_dir = "downloads"
bundle_name = "tooling-bundle.zip"
```

These targets are all macOS/arm64 for this run; a version that also
covered Linux would branch per tool the same way `release.gbatch`
branches per platform target, that pattern isn't repeated here to keep
this example a manageable size.

## The script

```python
# tooling-bundle.gbatch
gbatch_version = ">= 0"

# WARNING: this script downloads four real tools and re-packages them
# into a zip bundle for local, offline distribution. At the pinned
# versions in config.gbatch below, that's roughly 325 MB downloaded
# (Go and Quarto are the bulk of it) plus a similarly sized output
# bundle, since already-compressed archives don't shrink much further
# under zip — call it ~650 MB of working storage at peak, all of it
# under cfg.download_dir and cfg.bundle_name. Bumping any pinned
# version later, especially Go or Quarto, can only make this larger,
# never smaller; check config.gbatch's own URLs before assuming this
# number still holds.

load("config.gbatch", "cfg")

# Downloads four real, independently maintained CLI tools, SQLite,
# Fossil, Go, and Quarto, gore's own toolset (Taskfile.yml,
# standards-go.md). Quarto's own PDF rendering needs LaTeX and Pandoc;
# rather than pulling in a multi-gigabyte TeX distribution as part of
# this script, it checks whether both are already on this machine and
# warns, by name, if either is missing, the same thing `quarto check`
# itself would tell you.
def main(ctx, cfg):
    ctx.ensure_dir(cfg.download_dir)

    downloaded = []
    for tool in cfg.tools:
        path = download_tool(ctx, cfg, tool)
        if path == None:
            return
        downloaded.append(path)

    check_quarto_dependencies(ctx)

    if not build_bundle(ctx, cfg, downloaded):
        return

    ctx.success("bundle ready: " + cfg.bundle_name)

def download_tool(ctx, cfg, tool):
    out_path = std.path.join(cfg.download_dir, tool["filename"])
    result = ctx.run(
        id = "download-" + tool["name"],
        program = "curl",
        args = ["-sL", "-o", out_path, tool["url"]],
        timeout = "5m",
    )
    if result.failed:
        ctx.fail("download failed for " + tool["name"], result.error)
        return None
    ctx.success("downloaded " + tool["name"])
    return out_path

# check_quarto_dependencies looks for pdflatex and pandoc the same way
# a shell script would, `which`, and logs a named warning for each one
# missing, rather than downloading either: a full LaTeX distribution
# runs from tens of megabytes to several gigabytes, far outside what a
# "download four small CLIs" bundle should silently balloon into.
def check_quarto_dependencies(ctx):
    for tool_name in ["pdflatex", "pandoc"]:
        result = ctx.run(
            id = "check-" + tool_name,
            program = "which",
            args = [tool_name],
        )
        if result.failed:
            ctx.log(
                tool_name + " not found; Quarto needs it to render PDFs and it is not included in this bundle",
                severity = "warning",
                fields = {"missing": tool_name},
            )
        else:
            ctx.success(tool_name + " already present")

def build_bundle(ctx, cfg, files):
    args = ["-j", cfg.bundle_name] + files
    result = ctx.run(
        id = "zip-bundle",
        program = "zip",
        args = args,
        timeout = "3m",
    )
    if result.failed:
        ctx.fail("could not build bundle", result.error)
        return False
    return True
```

## Running it, for real

Unedited `gore printlog` output. This machine genuinely doesn't have
`pdflatex` or `pandoc` installed, so the two warnings below aren't
staged, they're what actually happened:

```
Run 20 — run — tooling-bundle.gbatch
  config:       config.gbatch
  gore version: 0.1.0  (script requires >= 0)
  host:         MBP.local (pid 9012)
  user:         davidbanham
  started:      2026-08-30T23:22:09.305Z
  ended:        2026-08-30T23:22:24.061Z  (duration 14.756s)
  mode:         run  (interactive=no, unattended=yes)
  result:       OK  (exit code 0)

Events:
  23:22:09.307  step               ensure_dir downloads
                               → exit 0  ()  OK
  23:22:09.919  step          download-sqlite     curl -sL -o downloads/sqlite-tools-osx-arm64-3530400.zip https://www.sqlite.org/2026/sqlite-tools-osx-arm64-3530400.zip
                               → exit 0  (0.611s)  OK
  23:22:09.920  diagnostic    [info] downloaded sqlite
  23:22:10.524  step          download-fossil     curl -sL -o downloads/fossil-mac-arm-2.28.tar.gz https://fossil-scm.org/home/uv/fossil-mac-arm-2.28.tar.gz
                               → exit 0  (0.603s)  OK
  23:22:10.525  diagnostic    [info] downloaded fossil
  23:22:12.076  step          download-go     curl -sL -o downloads/go1.27.0.darwin-arm64.tar.gz https://go.dev/dl/go1.27.0.darwin-arm64.tar.gz
                               → exit 0  (1.550s)  OK
  23:22:12.076  diagnostic    [info] downloaded go
  23:22:17.061  step          download-quarto     curl -sL -o downloads/quarto-1.10.18-macos.tar.gz https://github.com/quarto-dev/quarto-cli/releases/download/v1.10.18/quarto-1.10.18-macos.tar.gz
                               → exit 0  (4.984s)  OK
  23:22:17.061  diagnostic    [info] downloaded quarto
  23:22:17.068  step          check-pdflatex     which pdflatex
                               → exit 1  (0.004s)  FAILED
                               error:  — exit code 1 not in allowed_exit_codes [0]
                               stdout: (empty)
                               stderr: (empty)
  23:22:17.068  diagnostic    [warning] pdflatex not found; Quarto needs it to render PDFs and it is not included in this bundle  (fields: {"missing":"pdflatex"})
  23:22:17.072  step          check-pandoc     which pandoc
                               → exit 1  (0.002s)  FAILED
                               error:  — exit code 1 not in allowed_exit_codes [0]
                               stdout: (empty)
                               stderr: (empty)
  23:22:17.072  diagnostic    [warning] pandoc not found; Quarto needs it to render PDFs and it is not included in this bundle  (fields: {"missing":"pandoc"})
  23:22:24.056  step          zip-bundle     zip -j tooling-bundle.zip downloads/sqlite-tools-osx-arm64-3530400.zip downloads/fossil-mac-arm-2.28.tar.gz downloads/go1.27.0.darwin-arm64.tar.gz downloads/quarto-1.10.18-macos.tar.gz
                               → exit 0  (6.982s)  OK
  23:22:24.056  diagnostic    [info] bundle ready: tooling-bundle.zip
```

A step reporting `FAILED` here (`check-pdflatex`, `check-pandoc`) is
not the same as the run failing: `which` genuinely exits 1 when it
doesn't find something, and the script's own `if result.failed:`
branch treats that as expected, routine information, worth a `warning`
log entry, not `ctx.fail`. The run's own `result: OK` at the top
reflects that distinction. The real output: `tooling-bundle.zip`, 322
MB, containing all four downloaded archives, unpacked and installed
from wherever you'd normally put a CLI tool.

## Where this goes next

See [`release-pipeline.md`](release-pipeline.md) for the same
"download, verify, package" shape used to build and publish gore
itself, and [`backup-and-prune.md`](backup-and-prune.md) for a much
smaller-footprint script if 650 MB gave you pause.
