# Example: gore releasing itself

This is not a toy demo. It is the actual script that built and published
the release you are looking at right now — cross-compiling three
platform binaries, code-signing and notarizing the macOS one, rendering
the [Programmer's Reference Manual](https://github.com/dsbitor/gore-releases/releases/latest/download/gore-prm.pdf)
to PDF, checksumming everything, **verifying all five examples in this
directory still run clean against the binary it just built**, and
publishing it all here, to `dsbitor/gore-releases`.

The point of this example isn't to explain gore's syntax line by line —
the PRM does that. It's to show what a real, working `.gbatch` script and
a real run of it actually look like, end to end, so you can judge for
yourself whether the tool is worth your time before writing a single
line. The other four examples in this directory are, literally, part of
this script's own release gate now: if any of them ever regresses, this
pipeline refuses to notarize or publish until that's fixed.

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

# PATH is needed here for a reason specific to this script: it verifies
# five other example scripts by running the freshly built gore binary
# against them as a subprocess, and that nested gore process needs PATH
# to find awk, sqlite3, curl, and everything else those examples call.
allowed_env = ["HOME", "PATH"]

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
# every archive, verifies all five distribution examples, and, as a
# separate, explicitly confirmation-gated step, publishes to the
# releases repository.
#
# cfg.publish_stage controls how far this run goes, since notarize and
# publish are real, external, hard-to-reverse actions this script must
# never take by accident just because someone ran the whole thing:
#   "build"     stops after every archive is built, signed, and
#               checksummed.
#   "notarize"  additionally verifies every example, then submits the
#               macOS archive for notarization.
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

    # A local build never reaches this line, only a real release does:
    # every example in this directory must still run clean against the
    # binary just built, before this pipeline is allowed anywhere near
    # notarize or publish. gore regressing one of the very scripts
    # meant to remove a newcomer's fear of trying it would be exactly
    # the kind of rough edge this pipeline exists to catch before an
    # external user does.
    if not verify_examples(ctx, cfg, macos_binary):
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

# verify_examples runs the other four example scripts in this directory
# against the just-built, just-signed binary for this host platform,
# before this pipeline is allowed anywhere near notarize or publish.
# This example, release-pipeline, is this script itself; reaching this
# line at all is already that example running for real, nothing further
# to verify separately.
def verify_examples(ctx, cfg, gore_binary):
    simple_examples = [
        {"name": "sum-sales", "script": "sum-sales.gbatch"},
        {"name": "release-count-report", "script": "release-count-report.gbatch"},
        {"name": "tooling-bundle", "script": "tooling-bundle.gbatch"},
    ]
    for example in simple_examples:
        if not run_example_once(ctx, cfg, gore_binary, example["name"], example["script"]):
            return False

    if not verify_backup_and_prune(ctx, cfg, gore_binary):
        return False

    ctx.success("all distribution examples verified against " + gore_binary)
    return True

# run_example_once copies one example's source directory into a fresh,
# disposable ctx.temp_dir() and runs it there once with --unattended.
# Never inside this checkout's own tracked examples/ directory: a
# verification run, pass or fail, leaves nothing behind to clean up or
# accidentally commit, ctx.temp_dir()'s own automatic removal handles
# that.
def run_example_once(ctx, cfg, gore_binary, name, script):
    src_dir = std.path.join(cfg.repo_root, "examples/" + name)
    work_dir = ctx.temp_dir()
    copy_result = ctx.run(
        id = "copy-example-" + name,
        program = "cp",
        args = ["-R", src_dir + "/.", work_dir],
    )
    if copy_result.failed:
        ctx.fail("could not stage example " + name + " for verification", copy_result.error)
        return False

    run_result = ctx.run(
        id = "verify-" + name,
        program = gore_binary,
        args = ["run", script, "--unattended"],
        environment = {"HOME": ctx.env("HOME"), "PATH": ctx.env("PATH")},
        cwd = work_dir,
        timeout = "5m",
    )
    if run_result.failed:
        ctx.fail("example verification failed: " + name, run_result.error)
        return False
    ctx.success("verified example: " + name)
    return True

# verify_backup_and_prune runs its own scratch database through six
# real invocations, exactly enough to exercise the actual prune path
# (keep_count = 5 in the example's own config.gbatch), not just a
# single does-it-run smoke test. The seed database is a fresh, minimal
# SQLite file created here, never a copy of gore's own real journal.db:
# a release gate has no business touching production data, synthetic
# or not, the example only needs something real for a
# `sqlite3 ... .backup` command to back up.
def verify_backup_and_prune(ctx, cfg, gore_binary):
    src_dir = std.path.join(cfg.repo_root, "examples/backup-and-prune")
    work_dir = ctx.temp_dir()
    copy_result = ctx.run(
        id = "copy-example-backup-and-prune",
        program = "cp",
        args = ["-R", src_dir + "/.", work_dir],
    )
    if copy_result.failed:
        ctx.fail("could not stage example backup-and-prune for verification", copy_result.error)
        return False

    seed_result = ctx.run(
        id = "seed-backup-and-prune-db",
        program = "sqlite3",
        args = [std.path.join(work_dir, "journal.db"), "CREATE TABLE verification_seed (id INTEGER)"],
    )
    if seed_result.failed:
        ctx.fail("could not seed scratch database for backup-and-prune verification", seed_result.error)
        return False

    for i in range(6):
        run_result = ctx.run(
            id = "verify-backup-and-prune-run-" + str(i),
            program = gore_binary,
            args = ["run", "backup-and-prune.gbatch", "--unattended"],
            environment = {"HOME": ctx.env("HOME"), "PATH": ctx.env("PATH")},
            cwd = work_dir,
            timeout = "1m",
        )
        if run_result.failed:
            ctx.fail("example verification failed: backup-and-prune (run " + str(i) + ")", run_result.error)
            return False

    ctx.success("verified example: backup-and-prune (6 runs, prune path exercised)")
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
that published this repository's `v0.1.95` release — unedited, straight
from the journal. `HOME` and `PATH` are the only environment variables
this script is allowed to read; every subprocess call declares exactly
the environment it gets, nothing inherited implicitly, including the
four nested `gore run ...` calls the verification stage makes.

```
Run 63 — run — release.gbatch
  config:       config.gbatch
  gore version: 0.1.0  (script requires >= 0)
  host:         MBP.local (pid 19633)
  user:         davidbanham
  started:      2026-08-31T00:41:00.139Z
  ended:        2026-08-31T00:42:02.630Z  (duration 1m2.491s)
  mode:         run  (interactive=no, unattended=yes)
  allowed_env:  HOME, PATH
  result:       OK  (exit code 0)

Events:
  00:41:00.141  env-access    HOME
  00:41:00.155  step          fossil-checkin-count     fossil sql SELECT count(*) FROM event WHERE type='ci'
                               → exit 0  (0.013s)  OK
  00:41:00.156  diagnostic    [info] building gore 0.1.95  (fields: {"targets":3})
  00:41:00.156  step               ensure_dir /Users/davidbanham/BPRJ/gore/release/dist
                               → exit 0  ()  OK
  00:41:00.157  env-access    HOME
  00:41:01.266  step          build-gore-darwin-arm64     go build -ldflags -X main.version=0.1.95 -o /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64 ./cmd/gore
                               → exit 0  (1.108s)  OK
  00:41:01.267  diagnostic    [info] built gore-darwin-arm64
  00:41:01.267  env-access    HOME
  00:41:05.497  step          codesign-gore-darwin-arm64     codesign --force --options runtime --timestamp --sign Developer ID Application: David Banham (QER6R6D73F) --identifier com.dsbitor.gore-cli /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64
                               → exit 0  (4.228s)  OK
  00:41:05.497  REDACTED      stderr_captured  (matched revealed value of HOME)
  00:41:05.498  diagnostic    [info] signed /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64
  00:41:05.946  step          package-gore-darwin-arm64     tar -czf /Users/davidbanham/BPRJ/gore/release/dist/gore-0.1.95-darwin-arm64.tar.gz -C /Users/davidbanham/BPRJ/gore/release/dist gore-darwin-arm64
                               → exit 0  (0.447s)  OK
  00:41:05.946  diagnostic    [info] packaged gore-0.1.95-darwin-arm64.tar.gz
  00:41:05.950  env-access    HOME
  00:41:06.785  step          build-gore-linux-amd64     go build -ldflags -X main.version=0.1.95 -o /Users/davidbanham/BPRJ/gore/release/dist/gore-linux-amd64 ./cmd/gore
                               → exit 0  (0.834s)  OK
  00:41:06.786  diagnostic    [info] built gore-linux-amd64
  00:41:07.217  step          package-gore-linux-amd64     tar -czf /Users/davidbanham/BPRJ/gore/release/dist/gore-0.1.95-linux-amd64.tar.gz -C /Users/davidbanham/BPRJ/gore/release/dist gore-linux-amd64
                               → exit 0  (0.430s)  OK
  00:41:07.217  diagnostic    [info] packaged gore-0.1.95-linux-amd64.tar.gz
  00:41:07.218  env-access    HOME
  00:41:07.990  step          build-gore-linux-arm64     go build -ldflags -X main.version=0.1.95 -o /Users/davidbanham/BPRJ/gore/release/dist/gore-linux-arm64 ./cmd/gore
                               → exit 0  (0.772s)  OK
  00:41:07.991  diagnostic    [info] built gore-linux-arm64
  00:41:08.435  step          package-gore-linux-arm64     tar -czf /Users/davidbanham/BPRJ/gore/release/dist/gore-0.1.95-linux-arm64.tar.gz -C /Users/davidbanham/BPRJ/gore/release/dist gore-linux-arm64
                               → exit 0  (0.444s)  OK
  00:41:08.436  diagnostic    [info] packaged gore-0.1.95-linux-arm64.tar.gz
  00:41:08.436  env-access    HOME
  00:41:18.922  step          render-prm-pdf     quarto render /Users/davidbanham/BPRJ/gore/Docs/gore-prm.md --to pdf
                               → exit 0  (10.482s)  OK
  00:41:18.927  step          copy-prm-pdf     cp /Users/davidbanham/BPRJ/gore/Docs/gore-prm.pdf /Users/davidbanham/BPRJ/gore/release/dist/gore-prm.pdf
                               → exit 0  (0.004s)  OK
  00:41:18.928  diagnostic    [info] rendered gore-prm.pdf
  00:41:19.058  step          checksums     shasum -a 256 gore-0.1.95-darwin-arm64.tar.gz gore-0.1.95-linux-amd64.tar.gz gore-0.1.95-linux-arm64.tar.gz gore-prm.pdf
                               → exit 0  (0.128s)  OK
  00:41:19.058  diagnostic    [info] wrote SHA256SUMS for 4 archives
  00:41:19.058  diagnostic    [info] built 3 archives for version 0.1.95
  00:41:19.059  cleanup       created  /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-680423295
  00:41:19.064  step          copy-example-sum-sales     cp -R /Users/davidbanham/BPRJ/gore/examples/sum-sales/. /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-680423295
                               → exit 0  (0.003s)  OK
  00:41:19.065  env-access    HOME
  00:41:19.065  env-access    PATH
  00:41:19.948  step          verify-sum-sales     /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64 run sum-sales.gbatch --unattended
                               → exit 0  (0.882s)  OK
  00:41:19.948  diagnostic    [info] verified example: sum-sales
  00:41:19.949  cleanup       created  /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-2609522521
  00:41:19.952  step          copy-example-release-count-report     cp -R /Users/davidbanham/BPRJ/gore/examples/release-count-report/. /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-2609522521
                               → exit 0  (0.003s)  OK
  00:41:19.953  env-access    HOME
  00:41:19.953  env-access    PATH
  00:41:20.211  step          verify-release-count-report     /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64 run release-count-report.gbatch --unattended
                               → exit 0  (0.257s)  OK
  00:41:20.212  diagnostic    [info] verified example: release-count-report
  00:41:20.212  cleanup       created  /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-3999565884
  00:41:20.216  step          copy-example-tooling-bundle     cp -R /Users/davidbanham/BPRJ/gore/examples/tooling-bundle/. /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-3999565884
                               → exit 0  (0.003s)  OK
  00:41:20.216  env-access    HOME
  00:41:20.216  env-access    PATH
  00:41:40.376  step          verify-tooling-bundle     /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64 run tooling-bundle.gbatch --unattended
                               → exit 0  (20.159s)  OK
  00:41:40.376  diagnostic    [info] verified example: tooling-bundle
  00:41:40.379  cleanup       created  /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-1888200957
  00:41:40.384  step          copy-example-backup-and-prune     cp -R /Users/davidbanham/BPRJ/gore/examples/backup-and-prune/. /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-1888200957
                               → exit 0  (0.004s)  OK
  00:41:40.397  step          seed-backup-and-prune-db     sqlite3 /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-1888200957/journal.db CREATE TABLE verification_seed (id INTEGER)
                               → exit 0  (0.012s)  OK
  00:41:40.397  env-access    HOME
  00:41:40.397  env-access    PATH
  00:41:40.426  step          verify-backup-and-prune-run-0     /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64 run backup-and-prune.gbatch --unattended
                               → exit 0  (0.028s)  OK
  00:41:40.426  env-access    HOME
  00:41:40.426  env-access    PATH
  00:41:40.449  step          verify-backup-and-prune-run-1     /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64 run backup-and-prune.gbatch --unattended
                               → exit 0  (0.022s)  OK
  00:41:40.450  env-access    HOME
  00:41:40.450  env-access    PATH
  00:41:40.473  step          verify-backup-and-prune-run-2     /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64 run backup-and-prune.gbatch --unattended
                               → exit 0  (0.023s)  OK
  00:41:40.474  env-access    HOME
  00:41:40.474  env-access    PATH
  00:41:40.498  step          verify-backup-and-prune-run-3     /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64 run backup-and-prune.gbatch --unattended
                               → exit 0  (0.023s)  OK
  00:41:40.498  env-access    HOME
  00:41:40.498  env-access    PATH
  00:41:40.522  step          verify-backup-and-prune-run-4     /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64 run backup-and-prune.gbatch --unattended
                               → exit 0  (0.023s)  OK
  00:41:40.522  env-access    HOME
  00:41:40.522  env-access    PATH
  00:41:40.546  step          verify-backup-and-prune-run-5     /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64 run backup-and-prune.gbatch --unattended
                               → exit 0  (0.023s)  OK
  00:41:40.547  diagnostic    [info] verified example: backup-and-prune (6 runs, prune path exercised)
  00:41:40.547  diagnostic    [info] all distribution examples verified against /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64
  00:41:40.988  step          zip-for-notarize     zip -j /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64.zip /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64
                               → exit 0  (0.440s)  OK
  00:41:59.866  step          notarize-submit     xcrun notarytool submit /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64.zip --keychain-profile gore-notarize --wait
                               → exit 0  (18.878s)  OK
  00:41:59.867  REDACTED      stdout_captured  (matched revealed value of HOME)
  00:41:59.867  diagnostic    [info] notarized /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64
  00:41:59.867  env-access    HOME
  00:42:02.598  step          gh-release-create     gh release create v0.1.95 --repo dsbitor/gore-releases --title v0.1.95 /Users/davidbanham/BPRJ/gore/release/dist/gore-0.1.95-darwin-arm64.tar.gz /Users/davidbanham/BPRJ/gore/release/dist/gore-0.1.95-linux-amd64.tar.gz /Users/davidbanham/BPRJ/gore/release/dist/gore-0.1.95-linux-arm64.tar.gz /Users/davidbanham/BPRJ/gore/release/dist/gore-prm.pdf /Users/davidbanham/BPRJ/gore/release/dist/SHA256SUMS
                               → exit 0  (2.730s)  OK
  00:42:02.599  diagnostic    [info] published v0.1.95 to dsbitor/gore-releases
  00:42:02.601  cleanup       removed  /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-680423295
  00:42:02.602  cleanup       removed  /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-2609522521
  00:42:02.629  cleanup       removed  /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-3999565884
  00:42:02.630  cleanup       removed  /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-1888200957
```

A few things worth pointing out, since they're easy to miss on a first
skim:

- **This is the first real release the verification gate ever ran
  against**, and it genuinely caught a real bug the run before this one:
  the nested `gore run ...` calls had no `PATH`, so their own subprocess
  calls (`awk`, `sqlite3`, `curl`, ...) couldn't resolve, and the whole
  pipeline correctly stopped short of notarize. Fixed by adding `PATH`
  to `allowed_env` and forwarding it explicitly, as you can see above.
  The gate is not hypothetical; it already did its job once before this
  transcript was ever captured.
- **Four `ctx.temp_dir()` directories are created and removed**, one per
  example (`backup-and-prune` reuses one across its six runs). Every
  verification run happens in a disposable copy, never inside this
  checkout's own tracked `examples/` directory, and cleanup is automatic
  regardless of pass or fail.
- **`REDACTED`** entries appear twice — once for `codesign`'s stderr,
  once for `notarytool`'s stdout — because both processes echoed back a
  value that matched the real, revealed value of `HOME` at that moment.
  gore doesn't know in advance what a subprocess will print; it redacts
  after the fact by pattern-matching against every environment value
  it has handed out during the run, not by trusting the subprocess to
  behave.
- **`notarize-submit` was wrapped in `ctx.retry`** (`max_attempts = 3`,
  `delay = "30s"`), but this particular run succeeded on the first
  attempt — the 18.9 seconds you see is Apple's own service latency,
  not a retry loop spinning. `ctx.retry`'s failure-then-succeed path is
  exercised by its own unit tests, not by this transcript.
- **Every step is confirmation-gated by `impact`.** `notarize-submit`
  and `gh-release-create` are `impact = "high"`; this run only
  proceeded past them non-interactively because it was invoked with
  `--unattended`. Run it without that flag and gore stops and asks,
  interactively, before either one.

## The result

What that run produced is exactly what's attached to
[the `v0.1.95` release](https://github.com/dsbitor/gore-releases/releases/tag/v0.1.95):
three platform tarballs, `gore-prm.pdf`, and one `SHA256SUMS` covering
all four. It's also, byte for byte, what `brew install dsbitor/gore/gore`
fetches — there is exactly one place a gore binary gets built, signed,
checksummed, and verified against every other example in this
directory, and this script is it.
