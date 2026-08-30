# Example: gore releasing itself

This is not a toy demo. It is the actual script that built and published
the release you are looking at right now — cross-compiling three
platform binaries, code-signing and notarizing the macOS one, rendering
the [Programmer's Reference Manual](../../../gore-releases/releases/latest/download/gore-prm.pdf)
to PDF, checksumming everything, and publishing it all here, to
`dsbitor/gore-releases`.

The point of this example isn't to explain gore's syntax line by line —
the PRM does that. It's to show what a real, working `.gbatch` script and
a real run of it actually look like, end to end, so you can judge for
yourself whether the tool is worth your time before writing a single
line. More examples will land here over time; this first one is simply
the results of gore's own release pipeline, unedited.

## The config

Every gore script separates the logic (`release.gbatch`, below) from the
values it operates on (`config.gbatch`). Nothing here is a secret —
notarization credentials live in a macOS keychain profile referenced by
name, never as a literal value in this file.

```python
gbatch_version = ">= 0"

# Human-chosen release line (X.Y). Bumped deliberately for a real
# milestone, never automatically. Z is computed at build time by
# release.gbatch itself (gore-design-baseline.md Section 6a,
# "Versioning"), not declared here.
release_line = "0.1"

# repo_root is an absolute path, deliberately: gore has no "path to the
# running script" primitive, and ctx.run's own cwd is always resolved
# against gore's own process directory, never the script's, so an
# absolute path here is the honest choice, not a workaround. Update
# this if the checkout ever moves.
repo_root = "/Users/davidbanham/BPRJ/gore"
src_dir = repo_root + "/src"
build_dir = repo_root + "/release/dist"

# The initial platform matrix settled in Section 6a: darwin/arm64,
# linux/amd64, linux/arm64. No 32-bit target of any kind; darwin/amd64
# deferred pending real demand, not excluded on technical grounds.
targets = [
    {"os": "darwin", "arch": "arm64"},
    {"os": "linux", "arch": "amd64"},
    {"os": "linux", "arch": "arm64"},
]

# Code signing (macOS only), reusing the existing Developer ID
# Application certificate already issued for a prior project
# (architechture/macos-app-cli-code-signing.md), with gore's own
# signing identifier rather than that prior project's.
signing_identity = "Developer ID Application: David Banham (QER6R6D73F)"
bundle_id = "com.dsbitor.gore-cli"

# Notarization credentials are never handled by this script directly:
# notarytool reads them from a keychain profile created once, out of
# band, via `xcrun notarytool store-credentials gore-notarize`. This
# keeps no Apple ID, password, or API key anywhere in this repository
# or in gore's own process environment.
notarize_keychain_profile = "gore-notarize"

releases_repo = "dsbitor/gore-releases"

allowed_env = ["HOME"]

# How far one run of release.gbatch goes: "build" (default, safe),
# "notarize", or "publish". See release.gbatch's own doc comment on
# main() for what each stops after. Changed here, in config, rather
# than in the script, since this is a value the script operates on, not
# logic.
publish_stage = "build"
```

`publish_stage` defaults to `"build"` in the committed file — running
this script does nothing external unless someone deliberately flips it.
The run transcribed below had it set to `"publish"` for that one run,
then reverted immediately after.

## The script

```python
gbatch_version = ">= 0"

load("config.gbatch", "cfg")

# gore's own release pipeline (gore-design-baseline.md Section 6a,
# "Build orchestration: intended to be a gore script"). Cross-compiles
# the platform matrix, signs and notarizes the macOS binary, checksums
# every archive, and, as a separate, explicitly confirmation-gated
# step, publishes to the releases repository.
#
# cfg.publish_stage controls how far this run goes, since notarize and
# publish are real, external, hard-to-reverse actions this script must
# never take by accident just because someone ran the whole thing:
#   "build"     stops after every archive is built, signed, and
#               checksummed.
#   "notarize"  additionally submits the macOS archive for
#               notarization.
#   "publish"   additionally creates the GitHub release. impact="high"
#               on that step alone means this still won't happen
#               non-interactively without --unattended.
def main(ctx, cfg):
    publish_stage = cfg.publish_stage

    version = compute_version(ctx, cfg)
    if version == None:
        return
    ctx.log("building gore " + version, fields = {"targets": len(cfg.targets)})

    ctx.ensure_dir(cfg.build_dir)

    archives = []
    macos_binary = None
    for target in cfg.targets:
        binary_path = build_binary(ctx, cfg, target, version)
        if binary_path == None:
            return

        if target["os"] == "darwin":
            if not sign_binary(ctx, cfg, binary_path):
                return
            macos_binary = binary_path

        archive_path = package_binary(ctx, cfg, binary_path, target, version)
        if archive_path == None:
            return
        archives.append(archive_path)

    prm_pdf = render_prm(ctx, cfg)
    if prm_pdf == None:
        return
    release_assets = archives + [prm_pdf]

    if not write_checksums(ctx, cfg, release_assets):
        return

    ctx.success("built " + str(len(archives)) + " archives for version " + version)

    if publish_stage == "build":
        return

    if macos_binary != None:
        if not notarize(ctx, cfg, macos_binary):
            return

    if publish_stage == "notarize":
        return

    publish(ctx, cfg, version, release_assets)

# compute_version implements Section 6a's settled scheme: X.Y from
# config, human-chosen, Z the Fossil check-in count at build time,
# computed unconditionally for every build, whether or not it is ever
# published.
def compute_version(ctx, cfg):
    result = ctx.run(
        id = "fossil-checkin-count",
        program = "fossil",
        args = ["sql", "SELECT count(*) FROM event WHERE type='ci'"],
        cwd = cfg.repo_root,
        environment = {"HOME": ctx.env("HOME")},
        impact = "low",
    )
    if result.failed:
        ctx.fail("could not read the Fossil check-in count", result.error)
        return None
    if result.stdout == None:
        # dry-run: ctx.run reports a placeholder result with no real
        # stdout to parse, not an empty string, None. A script that
        # goes on to use a step's captured output must handle this
        # case explicitly; there is no real check-in count to report
        # yet, so a clearly-marked placeholder version stands in.
        return cfg.release_line + ".0-dryrun"
    return cfg.release_line + "." + result.stdout.strip()

# build_binary cross-compiles one platform target. HOME is required for
# the go tool's own module cache; GOOS/GOARCH select the target,
# resolved against gore's own process PATH for finding `go` itself, not
# environment=, the same distinction the PRM's own build example
# documents.
def build_binary(ctx, cfg, target, version):
    name = "gore-" + target["os"] + "-" + target["arch"]
    out_path = std.path.join(cfg.build_dir, name)
    result = ctx.run(
        id = "build-" + name,
        program = "go",
        args = [
            "build",
            "-ldflags", "-X main.version=" + version,
            "-o", out_path,
            "./cmd/gore",
        ],
        environment = {"GOOS": target["os"], "GOARCH": target["arch"], "HOME": ctx.env("HOME")},
        cwd = cfg.src_dir,
        timeout = "5m",
        impact = "low",
    )
    if result.failed:
        ctx.fail("build failed for " + name, result.error)
        return None
    ctx.success("built " + name)
    return out_path

# sign_binary reuses the Developer ID Application certificate already
# issued for a prior project, with gore's own bundle identifier.
# --options runtime and --timestamp match Apple's own recommendation
# for Developer ID distribution.
def sign_binary(ctx, cfg, binary_path):
    result = ctx.run(
        id = "codesign-" + std.path.basename(binary_path),
        program = "codesign",
        args = [
            "--force",
            "--options", "runtime",
            "--timestamp",
            "--sign", cfg.signing_identity,
            "--identifier", cfg.bundle_id,
            binary_path,
        ],
        environment = {"HOME": ctx.env("HOME")},
        impact = "medium",
    )
    if result.failed:
        ctx.fail("codesign failed for " + binary_path, result.error)
        return False
    ctx.success("signed " + binary_path)
    return True

# package_binary tars up one platform's binary. -C plus a bare filename
# (rather than a full path) keeps the tarball's own internal layout
# flat, just the binary, not the full build_dir path structure.
def package_binary(ctx, cfg, binary_path, target, version):
    name = std.path.basename(binary_path)
    archive_name = "gore-" + version + "-" + target["os"] + "-" + target["arch"] + ".tar.gz"
    archive_path = std.path.join(cfg.build_dir, archive_name)
    result = ctx.run(
        id = "package-" + name,
        program = "tar",
        args = ["-czf", archive_path, "-C", cfg.build_dir, name],
        impact = "low",
    )
    if result.failed:
        ctx.fail("packaging failed for " + name, result.error)
        return None
    ctx.success("packaged " + archive_name)
    return archive_path

# render_prm builds the Programmer's Reference Manual PDF, via the same
# Quarto renderer already used by hand for Docs/gore-prm.md, and stages
# a copy in build_dir as its own release asset — one PDF, not
# duplicated into each platform archive, since its content is
# platform-independent. This is what `gore help`'s own usage text and
# the Homebrew formula's caveats both point at.
def render_prm(ctx, cfg):
    prm_src = std.path.join(cfg.repo_root, "Docs/gore-prm.md")
    render_result = ctx.run(
        id = "render-prm-pdf",
        program = "quarto",
        args = ["render", prm_src, "--to", "pdf"],
        environment = {"HOME": ctx.env("HOME")},
        timeout = "3m",
        impact = "low",
    )
    if render_result.failed:
        ctx.fail("PRM PDF render failed", render_result.error)
        return None

    src_pdf = std.path.join(cfg.repo_root, "Docs/gore-prm.pdf")
    dest_pdf = std.path.join(cfg.build_dir, "gore-prm.pdf")
    copy_result = ctx.run(
        id = "copy-prm-pdf",
        program = "cp",
        args = [src_pdf, dest_pdf],
        impact = "low",
    )
    if copy_result.failed:
        ctx.fail("could not stage PRM PDF for release", copy_result.error)
        return None
    ctx.success("rendered gore-prm.pdf")
    return dest_pdf

# write_checksums produces one SHA256SUMS file covering every archive.
# stdout_file redirects shasum's own output directly, no intermediate
# shell redirect needed.
def write_checksums(ctx, cfg, archives):
    names = []
    for path in archives:
        names.append(std.path.basename(path))
    result = ctx.run(
        id = "checksums",
        program = "shasum",
        args = ["-a", "256"] + names,
        cwd = cfg.build_dir,
        stdout_file = std.path.join(cfg.build_dir, "SHA256SUMS"),
        impact = "low",
    )
    if result.failed:
        ctx.fail("checksum failed", result.error)
        return False
    ctx.success("wrote SHA256SUMS for " + str(len(archives)) + " archives")
    return True

# notarize submits the signed macOS binary for notarization, retried up
# to 3 times 30 seconds apart via ctx.retry — a bounded, sequential loop
# built specifically for this case: a real Apple service call that can
# fail transiently and succeed on a second attempt. --keychain-profile
# means no Apple ID, password, or API key ever appears in this script
# or its environment; the profile is created once, out of band, via
# `xcrun notarytool store-credentials <cfg.notarize_keychain_profile>`.
def notarize(ctx, cfg, binary_path):
    zip_path = binary_path + ".zip"
    zip_result = ctx.run(
        id = "zip-for-notarize",
        program = "zip",
        args = ["-j", zip_path, binary_path],
        impact = "low",
    )
    if zip_result.failed:
        ctx.fail("zip for notarization failed", zip_result.error)
        return False

    submission = ctx.retry(
        step = ctx.step(
            id = "notarize-submit",
            program = "xcrun",
            args = [
                "notarytool", "submit", zip_path,
                "--keychain-profile", cfg.notarize_keychain_profile,
                "--wait",
            ],
            timeout = "20m",
            impact = "high",
        ),
        max_attempts = 3,
        delay = "30s",
    )
    if submission.failed:
        ctx.fail("notarization failed after 3 attempts", submission.error)
        return False
    ctx.success("notarized " + binary_path)
    return True

# publish creates the GitHub release — the one genuinely irreversible
# step in this whole pipeline, impact="high" and given its own id so it
# is always confirmation-gated, interactively or via --unattended,
# never silently.
def publish(ctx, cfg, version, archives):
    args = ["release", "create", "v" + version, "--repo", cfg.releases_repo, "--title", "v" + version]
    args = args + archives
    args = args + [std.path.join(cfg.build_dir, "SHA256SUMS")]
    result = ctx.run(
        id = "gh-release-create",
        program = "gh",
        args = args,
        environment = {"HOME": ctx.env("HOME")},
        impact = "high",
    )
    if result.failed:
        ctx.fail("gh release create failed", result.error)
        return
    ctx.success("published v" + version + " to " + cfg.releases_repo)
```

## Running it, for real

The transcript below is `gore printlog`'s own output for the actual run
that published this repository's `v0.1.77` release — unedited, straight
from the journal. `HOME` is the only environment variable this script is
allowed to read (`allowed_env = ["HOME"]` in the config above); every
subprocess call declares exactly the environment it gets, nothing
inherited implicitly. Notice the real 18-second wait inside the
`notarize-submit` step — that's Apple's notarization service, not gore
being slow — and that `gh-release-create`'s argument list is exactly the
three platform tarballs, the PDF, and one shared `SHA256SUMS`, matching
`release_assets` in the script above.

```
Run 6 — run — release.gbatch
  config:       config.gbatch
  gore version: 0.1.0  (script requires >= 0)
  host:         MBP.local (pid 2221)
  user:         davidbanham
  started:      2026-08-30T17:31:49.912Z
  ended:        2026-08-30T17:32:32.494Z  (duration 42.582s)
  mode:         run  (interactive=no, unattended=yes)
  allowed_env:  HOME
  result:       OK  (exit code 0)

Events:
  17:31:49.915  env-access    HOME
  17:31:49.929  step          fossil-checkin-count     fossil sql SELECT count(*) FROM event WHERE type='ci'
                               → exit 0  (0.013s)  OK
  17:31:49.929  diagnostic    [info] building gore 0.1.77  (fields: {"targets":3})
  17:31:49.930  step               ensure_dir /Users/davidbanham/BPRJ/gore/release/dist
                               → exit 0  ()  OK
  17:31:49.930  env-access    HOME
  17:31:50.156  step          build-gore-darwin-arm64     go build -ldflags -X main.version=0.1.77 -o /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64 ./cmd/gore
                               → exit 0  (0.224s)  OK
  17:31:50.156  diagnostic    [info] built gore-darwin-arm64
  17:31:50.156  env-access    HOME
  17:31:54.816  step          codesign-gore-darwin-arm64     codesign --force --options runtime --timestamp --sign Developer ID Application: David Banham (QER6R6D73F) --identifier com.dsbitor.gore-cli /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64
                               → exit 0  (4.659s)  OK
  17:31:54.817  REDACTED      stderr_captured  (matched revealed value of HOME)
  17:31:54.817  diagnostic    [info] signed /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64
  17:31:55.253  step          package-gore-darwin-arm64     tar -czf /Users/davidbanham/BPRJ/gore/release/dist/gore-0.1.77-darwin-arm64.tar.gz -C /Users/davidbanham/BPRJ/gore/release/dist gore-darwin-arm64
                               → exit 0  (0.435s)  OK
  17:31:55.256  diagnostic    [info] packaged gore-0.1.77-darwin-arm64.tar.gz
  17:31:55.257  env-access    HOME
  17:31:55.377  step          build-gore-linux-amd64     go build -ldflags -X main.version=0.1.77 -o /Users/davidbanham/BPRJ/gore/release/dist/gore-linux-amd64 ./cmd/gore
                               → exit 0  (0.120s)  OK
  17:31:55.377  diagnostic    [info] built gore-linux-amd64
  17:31:55.794  step          package-gore-linux-amd64     tar -czf /Users/davidbanham/BPRJ/gore/release/dist/gore-0.1.77-linux-amd64.tar.gz -C /Users/davidbanham/BPRJ/gore/release/dist gore-linux-amd64
                               → exit 0  (0.415s)  OK
  17:31:55.796  diagnostic    [info] packaged gore-0.1.77-linux-amd64.tar.gz
  17:31:55.796  env-access    HOME
  17:31:55.909  step          build-gore-linux-arm64     go build -ldflags -X main.version=0.1.77 -o /Users/davidbanham/BPRJ/gore/release/dist/gore-linux-arm64 ./cmd/gore
                               → exit 0  (0.112s)  OK
  17:31:55.910  diagnostic    [info] built gore-linux-arm64
  17:31:56.322  step          package-gore-linux-arm64     tar -czf /Users/davidbanham/BPRJ/gore/release/dist/gore-0.1.77-linux-arm64.tar.gz -C /Users/davidbanham/BPRJ/gore/release/dist gore-linux-arm64
                               → exit 0  (0.411s)  OK
  17:31:56.322  diagnostic    [info] packaged gore-0.1.77-linux-arm64.tar.gz
  17:31:56.323  env-access    HOME
  17:32:06.279  step          render-prm-pdf     quarto render /Users/davidbanham/BPRJ/gore/Docs/gore-prm.md --to pdf
                               → exit 0  (9.955s)  OK
  17:32:06.283  step          copy-prm-pdf     cp /Users/davidbanham/BPRJ/gore/Docs/gore-prm.pdf /Users/davidbanham/BPRJ/gore/release/dist/gore-prm.pdf
                               → exit 0  (0.003s)  OK
  17:32:06.283  diagnostic    [info] rendered gore-prm.pdf
  17:32:06.379  step          checksums     shasum -a 256 gore-0.1.77-darwin-arm64.tar.gz gore-0.1.77-linux-amd64.tar.gz gore-0.1.77-linux-arm64.tar.gz gore-prm.pdf
                               → exit 0  (0.095s)  OK
  17:32:06.379  diagnostic    [info] wrote SHA256SUMS for 4 archives
  17:32:06.380  diagnostic    [info] built 3 archives for version 0.1.77
  17:32:06.835  step          zip-for-notarize     zip -j /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64.zip /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64
                               → exit 0  (0.454s)  OK
  17:32:25.464  step          notarize-submit     xcrun notarytool submit /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64.zip --keychain-profile gore-notarize --wait
                               → exit 0  (18.626s)  OK
  17:32:25.465  REDACTED      stdout_captured  (matched revealed value of HOME)
  17:32:25.465  diagnostic    [info] notarized /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64
  17:32:25.465  env-access    HOME
  17:32:32.492  step          gh-release-create     gh release create v0.1.77 --repo dsbitor/gore-releases --title v0.1.77 /Users/davidbanham/BPRJ/gore/release/dist/gore-0.1.77-darwin-arm64.tar.gz /Users/davidbanham/BPRJ/gore/release/dist/gore-0.1.77-linux-amd64.tar.gz /Users/davidbanham/BPRJ/gore/release/dist/gore-0.1.77-linux-arm64.tar.gz /Users/davidbanham/BPRJ/gore/release/dist/gore-prm.pdf /Users/davidbanham/BPRJ/gore/release/dist/SHA256SUMS
                               → exit 0  (7.026s)  OK
  17:32:32.494  diagnostic    [info] published v0.1.77 to dsbitor/gore-releases
```

A few things worth pointing out, since they're easy to miss on a first
skim:

- **`REDACTED`** entries appear twice — once for `codesign`'s stderr,
  once for `notarytool`'s stdout — because both processes echoed back a
  value that matched the real, revealed value of `HOME` at that moment.
  gore doesn't know in advance what a subprocess will print; it redacts
  after the fact by pattern-matching against every environment value
  it has handed out during the run, not by trusting the subprocess to
  behave.
- **`notarize-submit` was wrapped in `ctx.retry`** (`max_attempts = 3`,
  `delay = "30s"`), but this particular run succeeded on the first
  attempt — the 18.6 seconds you see is Apple's own service latency,
  not a retry loop spinning. `ctx.retry`'s failure-then-succeed path is
  exercised by its own unit tests, not by this transcript.
- **Every step is confirmation-gated by `impact`.** `notarize-submit`
  and `gh-release-create` are `impact = "high"`; this run only
  proceeded past them non-interactively because it was invoked with
  `--unattended`. Run it without that flag and gore stops and asks,
  interactively, before either one.

## The result

What that run produced is exactly what's attached to
[the `v0.1.77` release](https://github.com/dsbitor/gore-releases/releases/tag/v0.1.77):
three platform tarballs, `gore-prm.pdf`, and one `SHA256SUMS` covering
all four. It's also, byte for byte, what `brew install dsbitor/gore/gore`
fetches — there is exactly one place a gore binary gets built, signed,
and checksummed, and this script is it.
