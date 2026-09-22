# Example: gore releasing itself

This is not a toy demo. It is the actual script that builds and
publishes every release in this repository — cross-compiling three
platform binaries, code-signing and notarizing the macOS one, rendering
the [Programmer's Reference Manual](https://github.com/dsbitor/gore-releases/releases/latest/download/gore-prm.pdf)
to PDF with the real release version stamped into its own title page,
checksumming everything, **verifying all four other examples in this
directory still run clean against the binary it just built**,
publishing it all here, to `dsbitor/gore-releases`, and finally
checking whether the published macOS binary already clears Apple's
Gatekeeper. The script and transcript below are captured as of
`v0.4.133`; if you're reading this against a much later release, the
shape should still be recognizable, but check the actual
`release.gbatch` in a current checkout if something here looks off.

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
release_line = "0.4"

# Release notes convention (gore-design-baseline.md Section 6a, "Release
# notes convention"). Both empty by default, matching a Z-only release:
# nothing here for a user to evaluate, so the GitHub release gets a bare
# "vX.Y.Z" title and no body at all. Whoever bumps release_line above
# for a real milestone fills these in for that same release; whoever
# cuts the next Z-only release afterward clears them back to empty
# rather than letting stale prose describe a release it didn't ship
# with.
#
# release_title_suffix, when set, is appended to the GitHub release
# title after an em dash: "vX.Y.Z — <suffix>". Keep it to one line, one
# real fact, not the full description, that belongs in release_notes.
release_title_suffix = ""

# release_notes, when set, becomes the GitHub release body verbatim,
# via `--notes`. Three fixed sections, in order, per the convention:
# "What changed" (the fact), "Why" (the real motivation), "Upgrade
# notes" (only if something needs attention; omit the section entirely
# otherwise, never pad it with "no breaking changes").
release_notes = ""

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
# four other example scripts by running the freshly built gore binary
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
`release_title_suffix` and `release_notes` default to empty, a Z-only
release; whoever bumps `release_line` for a real milestone fills both
in for that one release and clears them back to empty afterward. The
run transcribed below had `publish_stage` set to `"publish"` and both
notes fields filled in for that specific release; all three were
reverted to their committed defaults immediately after.

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

    prm_pdf = render_prm(ctx, cfg, version)
    if prm_pdf == None:
        return
    release_assets = archives + [prm_pdf]

    if not write_checksums(ctx, cfg, release_assets):
        return

    ctx.success("built " + str(len(archives)) + " archives for version " + version)

    if publish_stage == "build":
        return

    # A local build never reaches this line, only a real release does
    # (cfg.publish_stage set to "notarize" or "publish"): the four
    # other distribution examples in this directory must all still run
    # clean against the binary just built, before this pipeline is
    # allowed anywhere near notarize or publish. gore regressing one of
    # the very scripts meant to remove a newcomer's fear of trying it
    # would be exactly the kind of rough edge this pipeline exists to
    # catch before an external user does.
    if not verify_examples(ctx, cfg, macos_binary):
        return

    if macos_binary != None:
        if not notarize(ctx, cfg, macos_binary):
            return

    if publish_stage == "notarize":
        return

    if not publish(ctx, cfg, version, release_assets):
        return

    if macos_binary != None:
        verify_gatekeeper_online_check(ctx, cfg, macos_binary)

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
# platform-independent. This is what `gore help`'s own usage text
# points at.
#
# The PDF's own title page carries the real release version, so a copy
# sitting in someone's Downloads folder six months from now can be
# matched back to the exact release it shipped with, rather than a
# manually-maintained version string that drifts the moment anyone
# forgets to bump it by hand (which is exactly what it had done before
# this was automated). Docs/gore-prm.md's own tracked source carries a
# literal placeholder, `GORE_RELEASE_VERSION`, never the real version;
# a *copy*, staged in build_dir alongside its own `title.tex` partial
# (Quarto's `template-partials` resolves relative to the rendered
# file's own directory), gets the placeholder substituted for real
# before Quarto ever sees it. The tracked source is never touched.
def render_prm(ctx, cfg, version):
    staged_src = std.path.join(cfg.build_dir, "gore-prm.md")
    copy_src_result = ctx.run(
        id = "copy-prm-source",
        program = "cp",
        args = [std.path.join(cfg.repo_root, "Docs/gore-prm.md"), staged_src],
        impact = "low",
    )
    if copy_src_result.failed:
        ctx.fail("could not stage PRM source for release", copy_src_result.error)
        return None

    copy_partial_result = ctx.run(
        id = "copy-prm-title-partial",
        program = "cp",
        args = [std.path.join(cfg.repo_root, "Docs/title.tex"), std.path.join(cfg.build_dir, "title.tex")],
        impact = "low",
    )
    if copy_partial_result.failed:
        ctx.fail("could not stage PRM title partial for release", copy_partial_result.error)
        return None

    stamp_result = ctx.run(
        id = "stamp-prm-version",
        program = "sed",
        args = ["-i", "", "s/GORE_RELEASE_VERSION/" + version + "/", staged_src],
        impact = "low",
    )
    if stamp_result.failed:
        ctx.fail("could not stamp the PRM's release version", stamp_result.error)
        return None

    render_result = ctx.run(
        id = "render-prm-pdf",
        program = "quarto",
        args = ["render", staged_src, "--to", "pdf"],
        environment = {"HOME": ctx.env("HOME")},
        timeout = "3m",
        impact = "low",
    )
    if render_result.failed:
        ctx.fail("PRM PDF render failed", render_result.error)
        return None

    ctx.success("rendered gore-prm.pdf, stamped version " + version)
    return std.path.join(cfg.build_dir, "gore-prm.pdf")

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
# No staple step: a bare CLI binary in a tarball, not a .app/.pkg/.dmg,
# cannot receive a stapled ticket; Gatekeeper verifies it via an online
# check at first run instead (see verify_gatekeeper_online_check,
# below, for a real, sometimes-surprising consequence of that).
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
#
# Title and notes follow the release notes convention: cfg.
# release_title_suffix and cfg.release_notes are both empty by default,
# a Z-only release, so the title stays a bare "vX.Y.Z" and --notes is
# omitted from the gh invocation entirely. `gh` itself defaults to an
# empty body when --notes/--notes-file/--generate-notes are all absent,
# never a hang waiting on a prompt, since this step never runs with a
# real terminal attached to prompt on in the first place.
def publish(ctx, cfg, version, archives):
    title = "v" + version
    if cfg.release_title_suffix != "":
        title = title + " — " + cfg.release_title_suffix

    args = ["release", "create", "v" + version, "--repo", cfg.releases_repo, "--title", title]
    if cfg.release_notes != "":
        args = args + ["--notes", cfg.release_notes]
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
        return False
    ctx.success("published v" + version + " to " + cfg.releases_repo)
    return True

# verify_gatekeeper_online_check gives real signal, not a blind wait, on
# whether a fresh download of the just-published macOS binary clears
# Gatekeeper's own online notarization check. notarytool reporting a
# submission Accepted does not mean the ticket is immediately
# retrievable by Gatekeeper's own separate online lookup — a real
# rejection ("Apple could not verify... is free of malware", spctl
# returning rejected/Unnotarized) has been hit minutes after a real
# publish and cleared on its own, with no other change, minutes to tens
# of minutes later.
#
# Runs after publish, warns rather than fails or gates: a real end user
# hitting this same window is this same known, transient condition, not
# evidence the release is broken, so this reports rather than blocks.
# ctx.retry polls instead of a fixed delay, the same primitive already
# wrapping notarize-submit for the identical reason, a real Apple-side
# condition that clears on its own after some wait.
#
# The check runs against a copy, never the archived binary itself: a
# real com.apple.quarantine attribute is a download-time property
# gore's own release archive never carries walking through this
# pipeline, so it's set here by hand to make the copy a faithful stand-
# in for what a real downloaded, unpacked binary looks like to
# Gatekeeper.
def verify_gatekeeper_online_check(ctx, cfg, macos_binary):
    work_dir = ctx.temp_dir()
    copy_path = std.path.join(work_dir, std.path.basename(macos_binary))
    copy_result = ctx.run(
        id = "gatekeeper-check-copy",
        program = "cp",
        args = [macos_binary, copy_path],
    )
    if copy_result.failed:
        ctx.log(
            "could not stage a copy for the post-publish Gatekeeper check: " + str(copy_result.error),
            severity = "warning",
        )
        return

    quarantine_result = ctx.run(
        id = "gatekeeper-check-quarantine",
        program = "xattr",
        args = ["-w", "com.apple.quarantine", "0081;00000000;curl;", copy_path],
    )
    if quarantine_result.failed:
        ctx.log(
            "could not simulate a quarantined download for the post-publish Gatekeeper check: " + str(quarantine_result.error),
            severity = "warning",
        )
        return

    result = ctx.retry(
        step = ctx.step(
            id = "gatekeeper-check-spctl",
            program = "spctl",
            args = ["-a", "-vvv", "-t", "install", copy_path],
        ),
        # apparent delay is about 5 minutes, if it takes longer than 15 mins
        # then the service should be considered down or unresponsive
        max_attempts = 16,
        delay = "60s",
    )
    if result.failed:
        ctx.log(
            "Gatekeeper's online notarization check did not accept the published binary within 16 attempts over ~15 minutes; this exceeds 3x the typical propagation delay and suggests the notarization service may be down or struggling, though it could still be the known propagation delay (gore-design-baseline.md Section 6a). A manual spctl check later is recommended",
            severity = "warning",
        )
        return

    ctx.log("Gatekeeper's online notarization check accepted the published binary")
```

## Running it, for real

The transcript below is `gore printlog`'s own output for the actual run
that published this repository's `v0.4.133` release — unedited, straight
from the journal. `HOME` and `PATH` are the only environment variables
this script is allowed to read; every subprocess call declares exactly
the environment it gets, nothing inherited implicitly, including the
four nested `gore run ...` calls the verification stage makes.

```
Run 225 — run — release.gbatch
  config:       config.gbatch
  gore version: 0.1.0  (script requires >= 0)
  host:         MBP.local (pid 87950)
  user:         davidbanham
  started:      2026-09-19T19:40:42.070Z
  ended:        2026-09-19T19:46:56.702Z  (duration 6m14.632s)
  mode:         run  (interactive=no, unattended=yes)
  allowed_env:  HOME, PATH
  result:       OK  (exit code 0)

Events:
  19:40:42.071  env-access    HOME
  19:40:42.079  step          fossil-checkin-count     fossil sql SELECT count(*) FROM event WHERE type='ci'
                               → exit 0  (0.007s)  OK
  19:40:42.080  diagnostic    [info] building gore 0.4.133  (fields: {"targets":3})
  19:40:42.080  step               ensure_dir /Users/davidbanham/BPRJ/gore/release/dist
                               → exit 0  ()  OK
  19:40:42.080  env-access    HOME
  19:40:42.571  step          build-gore-darwin-arm64     go build -ldflags -X main.version=0.4.133 -o /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64 ./cmd/gore
                               → exit 0  (0.489s)  OK
  19:40:42.571  diagnostic    [info] built gore-darwin-arm64
  19:40:42.572  env-access    HOME
  19:40:46.772  step          codesign-gore-darwin-arm64     codesign --force --options runtime --timestamp --sign Developer ID Application: David Banham (QER6R6D73F) --identifier com.dsbitor.gore-cli /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64
                               → exit 0  (4.199s)  OK
  19:40:46.772  REDACTED      stderr_captured  (matched revealed value of HOME)
  19:40:46.773  diagnostic    [info] signed /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64
  19:40:47.363  step          package-gore-darwin-arm64     tar -czf /Users/davidbanham/BPRJ/gore/release/dist/gore-0.4.133-darwin-arm64.tar.gz -C /Users/davidbanham/BPRJ/gore/release/dist gore-darwin-arm64
                               → exit 0  (0.590s)  OK
  19:40:47.364  diagnostic    [info] packaged gore-0.4.133-darwin-arm64.tar.gz
  19:40:47.364  env-access    HOME
  19:40:47.813  step          build-gore-linux-amd64     go build -ldflags -X main.version=0.4.133 -o /Users/davidbanham/BPRJ/gore/release/dist/gore-linux-amd64 ./cmd/gore
                               → exit 0  (0.449s)  OK
  19:40:47.814  diagnostic    [info] built gore-linux-amd64
  19:40:48.395  step          package-gore-linux-amd64     tar -czf /Users/davidbanham/BPRJ/gore/release/dist/gore-0.4.133-linux-amd64.tar.gz -C /Users/davidbanham/BPRJ/gore/release/dist gore-linux-amd64
                               → exit 0  (0.580s)  OK
  19:40:48.396  diagnostic    [info] packaged gore-0.4.133-linux-amd64.tar.gz
  19:40:48.397  env-access    HOME
  19:40:48.846  step          build-gore-linux-arm64     go build -ldflags -X main.version=0.4.133 -o /Users/davidbanham/BPRJ/gore/release/dist/gore-linux-arm64 ./cmd/gore
                               → exit 0  (0.449s)  OK
  19:40:48.847  diagnostic    [info] built gore-linux-arm64
  19:40:49.405  step          package-gore-linux-arm64     tar -czf /Users/davidbanham/BPRJ/gore/release/dist/gore-0.4.133-linux-arm64.tar.gz -C /Users/davidbanham/BPRJ/gore/release/dist gore-linux-arm64
                               → exit 0  (0.557s)  OK
  19:40:49.405  diagnostic    [info] packaged gore-0.4.133-linux-arm64.tar.gz
  19:40:49.409  step          copy-prm-source     cp /Users/davidbanham/BPRJ/gore/Docs/gore-prm.md /Users/davidbanham/BPRJ/gore/release/dist/gore-prm.md
                               → exit 0  (0.003s)  OK
  19:40:49.412  step          copy-prm-title-partial     cp /Users/davidbanham/BPRJ/gore/Docs/title.tex /Users/davidbanham/BPRJ/gore/release/dist/title.tex
                               → exit 0  (0.002s)  OK
  19:40:49.416  step          stamp-prm-version     sed -i  s/GORE_RELEASE_VERSION/0.4.133/ /Users/davidbanham/BPRJ/gore/release/dist/gore-prm.md
                               → exit 0  (0.004s)  OK
  19:40:49.416  env-access    HOME
  19:41:04.170  step          render-prm-pdf     quarto render /Users/davidbanham/BPRJ/gore/release/dist/gore-prm.md --to pdf
                               → exit 0  (14.753s)  OK
  19:41:04.171  diagnostic    [info] rendered gore-prm.pdf, stamped version 0.4.133
  19:41:04.281  step          checksums     shasum -a 256 gore-0.4.133-darwin-arm64.tar.gz gore-0.4.133-linux-amd64.tar.gz gore-0.4.133-linux-arm64.tar.gz gore-prm.pdf
                               → exit 0  (0.109s)  OK
  19:41:04.282  diagnostic    [info] wrote SHA256SUMS for 4 archives
  19:41:04.282  diagnostic    [info] built 3 archives for version 0.4.133
  19:41:04.282  cleanup       created  /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-2388757494
  19:41:04.288  step          copy-example-sum-sales     cp -R /Users/davidbanham/BPRJ/gore/examples/sum-sales/. /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-2388757494
                               → exit 0  (0.004s)  OK
  19:41:04.288  env-access    HOME
  19:41:04.289  env-access    PATH
  19:41:04.894  step          verify-sum-sales     /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64 run sum-sales.gbatch --unattended
                               → exit 0  (0.604s)  OK
  19:41:04.894  diagnostic    [info] verified example: sum-sales
  19:41:04.895  cleanup       created  /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-3323630098
  19:41:04.899  step          copy-example-release-count-report     cp -R /Users/davidbanham/BPRJ/gore/examples/release-count-report/. /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-3323630098
                               → exit 0  (0.003s)  OK
  19:41:04.900  env-access    HOME
  19:41:04.900  env-access    PATH
  19:41:05.386  step          verify-release-count-report     /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64 run release-count-report.gbatch --unattended
                               → exit 0  (0.485s)  OK
  19:41:05.386  diagnostic    [info] verified example: release-count-report
  19:41:05.387  cleanup       created  /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-1068593772
  19:41:05.391  step          copy-example-tooling-bundle     cp -R /Users/davidbanham/BPRJ/gore/examples/tooling-bundle/. /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-1068593772
                               → exit 0  (0.004s)  OK
  19:41:05.392  env-access    HOME
  19:41:05.392  env-access    PATH
  19:41:30.864  step          verify-tooling-bundle     /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64 run tooling-bundle.gbatch --unattended
                               → exit 0  (25.472s)  OK
  19:41:30.865  diagnostic    [info] verified example: tooling-bundle
  19:41:30.865  cleanup       created  /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-697429890
  19:41:30.875  step          copy-example-backup-and-prune     cp -R /Users/davidbanham/BPRJ/gore/examples/backup-and-prune/. /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-697429890
                               → exit 0  (0.009s)  OK
  19:41:30.932  step          seed-backup-and-prune-db     sqlite3 /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-697429890/journal.db CREATE TABLE verification_seed (id INTEGER)
                               → exit 0  (0.054s)  OK
  19:41:30.932  env-access    HOME
  19:41:30.933  env-access    PATH
  19:41:30.973  step          verify-backup-and-prune-run-0     /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64 run backup-and-prune.gbatch --unattended
                               → exit 0  (0.039s)  OK
  19:41:30.973  env-access    HOME
  19:41:30.973  env-access    PATH
  19:41:31.008  step          verify-backup-and-prune-run-1     /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64 run backup-and-prune.gbatch --unattended
                               → exit 0  (0.034s)  OK
  19:41:31.008  env-access    HOME
  19:41:31.009  env-access    PATH
  19:41:31.043  step          verify-backup-and-prune-run-2     /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64 run backup-and-prune.gbatch --unattended
                               → exit 0  (0.033s)  OK
  19:41:31.043  env-access    HOME
  19:41:31.043  env-access    PATH
  19:41:31.077  step          verify-backup-and-prune-run-3     /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64 run backup-and-prune.gbatch --unattended
                               → exit 0  (0.033s)  OK
  19:41:31.078  env-access    HOME
  19:41:31.078  env-access    PATH
  19:41:31.113  step          verify-backup-and-prune-run-4     /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64 run backup-and-prune.gbatch --unattended
                               → exit 0  (0.034s)  OK
  19:41:31.113  env-access    HOME
  19:41:31.113  env-access    PATH
  19:41:31.149  step          verify-backup-and-prune-run-5     /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64 run backup-and-prune.gbatch --unattended
                               → exit 0  (0.035s)  OK
  19:41:31.149  diagnostic    [info] verified example: backup-and-prune (6 runs, prune path exercised)
  19:41:31.149  diagnostic    [info] all distribution examples verified against /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64
  19:41:31.764  step          zip-for-notarize     zip -j /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64.zip /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64
                               → exit 0  (0.614s)  OK
  19:41:50.704  step          notarize-submit     xcrun notarytool submit /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64.zip --keychain-profile gore-notarize --wait
                               → exit 0  (18.938s)  OK
  19:41:50.704  REDACTED      stdout_captured  (matched revealed value of HOME)
  19:41:50.704  diagnostic    [info] notarized /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64
  19:41:50.705  env-access    HOME
  19:41:55.414  step          gh-release-create     gh release create v0.4.133 --repo dsbitor/gore-releases --title "v0.4.133 — PRM Appendix B, and fixed doc code-block/text line overflow" --notes "<the full release notes text — see the published release for the exact content>" /Users/davidbanham/BPRJ/gore/release/dist/gore-0.4.133-darwin-arm64.tar.gz /Users/davidbanham/BPRJ/gore/release/dist/gore-0.4.133-linux-amd64.tar.gz /Users/davidbanham/BPRJ/gore/release/dist/gore-0.4.133-linux-arm64.tar.gz /Users/davidbanham/BPRJ/gore/release/dist/gore-prm.pdf /Users/davidbanham/BPRJ/gore/release/dist/SHA256SUMS
                               → exit 0  (4.707s)  OK
  19:41:55.415  diagnostic    [info] published v0.4.133 to dsbitor/gore-releases
  19:41:55.415  cleanup       created  /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-1884005747
  19:41:55.425  step          gatekeeper-check-copy     cp /Users/davidbanham/BPRJ/gore/release/dist/gore-darwin-arm64 /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-1884005747/gore-darwin-arm64
                               → exit 0  (0.009s)  OK
  19:41:55.431  step          gatekeeper-check-quarantine     xattr -w com.apple.quarantine 0081;00000000;curl; /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-1884005747/gore-darwin-arm64
                               → exit 0  (0.003s)  OK
  19:41:55.692  step          gatekeeper-check-spctl     spctl -a -vvv -t install /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-1884005747/gore-darwin-arm64
                               → exit 3  (0.259s)  FAILED
                               error:  — exit code 3 not in allowed_exit_codes [0]
                               stdout: (empty)
                               stderr:
                                 /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-1884005747/gore-darwin-arm64: rejected
                                 source=Unnotarized Developer ID
                                 origin=Developer ID Application: David Banham (QER6R6D73F)
  19:42:55.947  step          gatekeeper-check-spctl     spctl -a -vvv -t install /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-1884005747/gore-darwin-arm64
                               → exit 3  (0.253s)  FAILED
                               error:  — exit code 3 not in allowed_exit_codes [0]
                               stdout: (empty)
                               stderr:
                                 /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-1884005747/gore-darwin-arm64: rejected
                                 source=Unnotarized Developer ID
                                 origin=Developer ID Application: David Banham (QER6R6D73F)
  19:43:56.124  step          gatekeeper-check-spctl     spctl -a -vvv -t install /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-1884005747/gore-darwin-arm64
                               → exit 3  (0.175s)  FAILED
                               error:  — exit code 3 not in allowed_exit_codes [0]
                               stdout: (empty)
                               stderr:
                                 /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-1884005747/gore-darwin-arm64: rejected
                                 source=Unnotarized Developer ID
                                 origin=Developer ID Application: David Banham (QER6R6D73F)
  19:44:56.290  step          gatekeeper-check-spctl     spctl -a -vvv -t install /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-1884005747/gore-darwin-arm64
                               → exit 3  (0.165s)  FAILED
                               error:  — exit code 3 not in allowed_exit_codes [0]
                               stdout: (empty)
                               stderr:
                                 /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-1884005747/gore-darwin-arm64: rejected
                                 source=Unnotarized Developer ID
                                 origin=Developer ID Application: David Banham (QER6R6D73F)
  19:45:56.476  step          gatekeeper-check-spctl     spctl -a -vvv -t install /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-1884005747/gore-darwin-arm64
                               → exit 3  (0.184s)  FAILED
                               error:  — exit code 3 not in allowed_exit_codes [0]
                               stdout: (empty)
                               stderr:
                                 /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-1884005747/gore-darwin-arm64: rejected
                                 source=Unnotarized Developer ID
                                 origin=Developer ID Application: David Banham (QER6R6D73F)
  19:46:56.685  step          gatekeeper-check-spctl     spctl -a -vvv -t install /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-1884005747/gore-darwin-arm64
                               → exit 0  (0.207s)  OK
  19:46:56.687  diagnostic    [info] Gatekeeper's online notarization check accepted the published binary
  19:46:56.688  cleanup       removed  /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-2388757494
  19:46:56.688  cleanup       removed  /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-3323630098
  19:46:56.700  cleanup       removed  /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-1068593772
  19:46:56.701  cleanup       removed  /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-697429890
  19:46:56.701  cleanup       removed  /var/folders/2d/zr1crjmn35z5g09gdqwcdr_80000gp/T/gore-1884005747
```

(The real `gh-release-create` line in the journal is one unbroken line
carrying the full multi-paragraph `--notes` text inline, since that's
exactly the string `ctx.run` was actually given; it's abbreviated above
for readability. Nothing else in this transcript is edited.)

A few things worth pointing out, since they're easy to miss on a first
skim:

- **The pipeline doesn't stop at "published."** `verify_gatekeeper_online_check`
  runs after `publish` and adds real, visible cost to this
  transcript: five rejected `spctl` attempts, about five minutes,
  before the sixth attempt reports `accepted`. This is not a bug in
  the release; it's Apple's own notarization-ticket propagation delay,
  the gap between `notarytool` reporting a submission `Accepted` and
  Gatekeeper's own separate online check actually being able to
  retrieve that ticket. The check polls with `ctx.retry` rather than a
  fixed wait, warns rather than fails if it never clears within its
  budget, and never touches the run's own success or failure either
  way, visible here: the run's own `result: OK` was decided before this
  check ever started.
- **The PRM's title page is stamped, not hand-maintained.** `copy-prm-source`,
  `copy-prm-title-partial`, and `stamp-prm-version` stage a
  disposable copy of `Docs/gore-prm.md`, substitute the real version
  into it, and only then hand that copy to `quarto render`. The
  tracked source file never changes; the PDF attached to this release
  reads "Version - 0.4.133" because this run wrote that in, not
  because someone edited a Markdown file by hand and might forget to
  next time.
- **Four `ctx.temp_dir()` directories are created and removed**, one per
  example (`backup-and-prune` reuses one across its six runs), plus a
  fifth for the post-publish Gatekeeper check. Every verification run
  happens in a disposable copy, never inside this checkout's own
  tracked `examples/` directory, and cleanup is automatic regardless of
  pass or fail.
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
  not a retry loop spinning.
- **Every step is confirmation-gated by `impact`.** `notarize-submit`
  and `gh-release-create` are `impact = "high"`; this run only
  proceeded past them non-interactively because it was invoked with
  `--unattended`. Run it without that flag and gore stops and asks,
  interactively, before either one.

## The result

What that run produced is exactly what's attached to
[the `v0.4.133` release](https://github.com/dsbitor/gore-releases/releases/tag/v0.4.133):
three platform tarballs, `gore-prm.pdf` with its title page correctly
reading "Version - 0.4.133", and one `SHA256SUMS` covering all four.
It's also, byte for byte, what `brew install dsbitor/gore/gore`
fetches — there is exactly one place a gore binary gets built, signed,
checksummed, and verified against every other example in this
directory, and this script is it.
