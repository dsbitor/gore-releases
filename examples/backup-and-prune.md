# Example: backing up and pruning a database

The classic shell-script task: back up a database, keep a rotation of
recent copies, and quietly delete the rest. This example backs up a
real SQLite database, gore's own journal, and prunes down to a
five-file rotation, a typical business week of daily backups.

The real files, ready to run as-is: [`backup-and-prune/`](backup-and-prune/).

## The config

```python
# config.gbatch
gbatch_version = ">= 0"

# Point this at whatever SQLite database is worth protecting. This
# example demos it against a copy of gore's own journal.db.
db_path = "journal.db"
backup_dir = "backups"

# "Today's backup plus the four before it" — a typical business week's
# worth of daily backups, five files on disk at any time.
keep_count = 5
```

## The script

```python
# backup-and-prune.gbatch
gbatch_version = ">= 0"

load("config.gbatch", "cfg")

# Backs up a SQLite database via its own online-safe .backup command,
# not a plain file copy — copying a live SQLite file risks a torn,
# inconsistent snapshot if a writer touches it mid-copy, something
# .backup is specifically designed to avoid. Then prunes down to
# cfg.keep_count, oldest first, the same retention shape as a typical
# daily-backup rotation.
def main(ctx, cfg):
    ctx.ensure_dir(cfg.backup_dir)

    stamp_result = ctx.run(
        id = "timestamp",
        program = "date",
        args = ["+%Y%m%d-%H%M%S"],
    )
    if stamp_result.failed:
        ctx.fail("could not read the clock", stamp_result.error)
        return
    stamp = stamp_result.stdout.strip()

    # ctx.run_id makes the filename unique even if two backups land in
    # the same second, and doubles as a cross-reference back to
    # `gore printlog <run-id>` for this exact backup.
    backup_name = "journal-" + stamp + "-run" + str(ctx.run_id) + ".db"
    backup_path = std.path.join(cfg.backup_dir, backup_name)

    backup_result = ctx.run(
        id = "sqlite-backup",
        program = "sqlite3",
        args = [cfg.db_path, ".backup " + backup_path],
    )
    if backup_result.failed:
        ctx.fail("backup failed", backup_result.error)
        return
    ctx.success("backed up " + cfg.db_path + " to " + backup_path)

    prune(ctx, cfg)

# prune lists existing backups the same way a shell script would,
# gore has no directory-listing primitive of its own, then deletes the
# oldest ones down to cfg.keep_count. find avoids the "no matches"
# error a shell glob throws on an empty directory; sort relies on the
# timestamp prefix in each filename to put oldest first.
def prune(ctx, cfg):
    listing = ctx.pipe(
        id = "list-backups",
        stages = [
            ctx.step(id = "find-backups", program = "find", args = [cfg.backup_dir, "-maxdepth", "1", "-name", "journal-*.db"]),
            ctx.step(id = "sort-backups", program = "sort"),
        ],
    )
    if listing.failed:
        ctx.fail(listing.failed_step + " failed", listing.error)
        return

    paths = []
    for line in listing.output.strip().split("\n"):
        if line != "":
            paths.append(line)

    excess = len(paths) - cfg.keep_count
    if excess <= 0:
        ctx.success("no pruning needed, " + str(len(paths)) + " backups on hand")
        return

    for old_path in paths[:excess]:
        result = ctx.remove(old_path)
        if result.failed:
            ctx.fail("could not remove " + old_path, result.error)
            return
        ctx.success("pruned " + old_path)
```

`ctx.remove` is declared `impact="medium"` for a single, non-recursive
delete — still confirmation-gated: run this without `--unattended` and
gore stops and asks before removing anything, the same as it would for
any other medium- or high-impact step.

## Running it, for real

This script ran six times in a row against a real copy of gore's own
`journal.db`, `keep_count = 5`. The first five runs each added a backup
with nothing to prune. The sixth is the interesting one — five files
already on hand, a new one just written, six total, one over budget:

```
Run 15 — run — backup-and-prune.gbatch
  config:       config.gbatch
  gore version: 0.1.0  (script requires >= 0)
  host:         MBP.local (pid 8911)
  user:         davidbanham
  started:      2026-08-30T23:21:28.041Z
  ended:        2026-08-30T23:21:28.071Z  (duration 0.030s)
  mode:         run  (interactive=no, unattended=yes)
  result:       OK  (exit code 0)

Events:
  23:21:28.043  step               ensure_dir backups
                               → exit 0  ()  OK
  23:21:28.050  step          timestamp     date +%Y%m%d-%H%M%S
                               → exit 0  (0.006s)  OK
  23:21:28.062  step          sqlite-backup     sqlite3 journal.db .backup backups/journal-20260830-192128-run15.db
                               → exit 0  (0.011s)  OK
  23:21:28.063  diagnostic    [info] backed up journal.db to backups/journal-20260830-192128-run15.db
  23:21:28.066  step          find-backups     find backups -maxdepth 1 -name journal-*.db
                               → exit 0  (0.003s)  OK
  23:21:28.070  step          sort-backups     sort
                               → exit 0  (0.002s)  OK
  23:21:28.070  step               remove backups/journal-20260830-192117-run10.db
                               → exit 0  ()  OK
  23:21:28.070  diagnostic    [info] pruned backups/journal-20260830-192117-run10.db
```

`journal-20260830-192117-run10.db`, the oldest of the six, the one from
run 10, is exactly what gets removed. `backups/` afterward holds five
files, runs 11 through 15, oldest to newest — the rotation held.

## Where this goes next

See [`release-pipeline.md`](release-pipeline.md) for `ctx.retry` wrapping
a real external service call, and
[`release-count-report.md`](release-count-report.md) for `ctx.pipe`
chaining subprocesses whose output is text, not files.
