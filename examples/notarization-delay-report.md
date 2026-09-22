# Example: querying a SQLite database from a step

A gore-native conversion of a small bash+`sqlite3` utility this
project already carried: querying gore's own journal database for how
long Apple's notarization ticket takes to actually propagate to
Gatekeeper's own online check, after `notarytool` itself reports a
submission "Accepted" (see `gore-design-baseline.md` Section 6a, "A
second real operational detail, found cutting v0.4.121", in the main
repository, for the operational background).

The interesting part isn't the notarization angle specifically, it's
the general shape: two real SQL queries, kept in their own `.sql`
files rather than embedded as Starlark strings, fed to `sqlite3` on
stdin via `ctx.run`'s `stdin_file` parameter. This is also the worked
example for `stdin_file` in the
[Programmer's Reference Manual](https://github.com/dsbitor/gore-releases/releases/latest/download/gore-prm.pdf)
itself ("Querying a SQLite database from a step").

The real files, ready to run as-is: [`notarization-delay-report/`](notarization-delay-report/).

## The layout

```
notarization-delay-report/
  config.gbatch
  notarization-delay-report.gbatch
  sql/
    notarization-detail.sql
    notarization-summary.sql
```

Two modes, `detail` (one row per notarized release) or `summary`
(aggregate stats), picked in `config.gbatch` rather than as a CLI
argument — gore scripts take no custom flags of their own.

## The queries

Each `.sql` file is a real, standalone script: copy either one and run
it directly with `sqlite3 <journal.db> < notarization-detail.sql`, no
gore involved, to check or extend it. Both open with a `.param set`
block naming the constants the query would otherwise repeat as
literals — step IDs from the release pipeline that wrote the journal,
and a couple of unit-conversion numbers:

```sql
-- sql/notarization-detail.sql (excerpt)
.param set :step_notarize 'notarize-submit'
.param set :step_gatekeeper 'gatekeeper-check-spctl'
.param set :ms_per_second 1000.0
.param set :minutes_per_day 1440
.param set :round_decimals 1

SELECT
    r.run_id,
    datetime(r.started_at) as run_started,
    ROUND(notarize.duration_ms / :ms_per_second, :round_decimals) as notarize_seconds,
    -- julianday() difference is in fractional days; scale by
    -- minutes_per_day (24 * 60) to get whole minutes of propagation
    -- delay between notarize-submit and Gatekeeper's own check.
    CAST((julianday(last_check.occurred_at) - julianday(e_notarize.occurred_at)) * :minutes_per_day AS INTEGER) as delay_minutes,
    ...
FROM runs r
JOIN events e_notarize ON r.run_id = e_notarize.run_id
JOIN step_events notarize ON e_notarize.event_id = notarize.event_id
-- last_check picks the most recent gatekeeper-check-spctl attempt per
-- run (ctx.retry can log several before it succeeds or gives up), via
-- ROW_NUMBER() partitioned by run and ordered newest-first, keeping
-- only rn = 1.
LEFT JOIN (
    SELECT e.run_id, e.occurred_at, se.succeeded,
           ROW_NUMBER() OVER (PARTITION BY e.run_id ORDER BY e.occurred_at DESC) as rn
    FROM events e
    JOIN step_events se ON e.event_id = se.event_id
    WHERE e.step_id = :step_gatekeeper
) last_check ON r.run_id = last_check.run_id AND last_check.rn = 1
WHERE e_notarize.step_id = :step_notarize
  AND notarize.succeeded = 1
ORDER BY r.run_id DESC;
```

The step IDs and unit conversions stay in the `.sql` file rather than
moving to `config.gbatch`: they're facts about the schema and about
the release pipeline's own step IDs, not values an operator would
tune at run time. `journal_db` and `sql_dir`, the two things a reader
actually would want to override, are the config values.

## The script

```python
# notarization-delay-report.gbatch (excerpt)
load("config.gbatch", "cfg")

def main(ctx, cfg):
    if cfg.mode != "detail" and cfg.mode != "summary":
        ctx.fail("config.gbatch: mode must be \"detail\" or \"summary\", got " + repr(cfg.mode), None)
        return

    journal_db = resolve_journal_db(ctx, cfg)
    ...
    if cfg.mode == "summary":
        run_summary(ctx, journal_db, cfg.sql_dir)
    else:
        run_detail(ctx, journal_db, cfg.sql_dir)

def run_detail(ctx, journal_db, sql_dir):
    result = ctx.run(
        id = "query-detail",
        program = "sqlite3",
        args = ["-header", "-column", journal_db],
        stdin_file = std.path.join(sql_dir, "notarization-detail.sql"),
        impact = "low",
    )
    if result.failed:
        ctx.fail("detail query failed", result.error)
        return
    if result.stdout != None:
        print(result.stdout)
    ctx.success("detail report generated")
```

`stdin_file` feeds the `.sql` file straight to `sqlite3` on stdin,
exactly the way running it by hand would — gore never parses or
templates the file's contents, just hands it through. `journal_db`
resolution mirrors `cmd/gore/journal.go`'s own default path logic
exactly (`config.gbatch`'s `journal_db` first if set, else
`$XDG_DATA_HOME/gore/journal.db`, else
`$HOME/.local/share/gore/journal.db`), since this report has no other
source of truth for where gore itself would have written the journal
it's about to read.

`config.gbatch`'s `sql_dir = "sql"` is relative, the same convention
[`backup-and-prune/config.gbatch`](backup-and-prune/config.gbatch)
uses for `db_path`: `ctx.run` resolves a relative path against gore's
own process directory, so this works as-is provided you run gore from
inside this example directory. A real deployment would more likely
build `sql_dir` from an absolute `repo_root`, the way
`release/config.gbatch` does in the main repository, since a relative
path stops working the moment gore is invoked from somewhere else.

## Running it, for real

Unedited `gore printlog` output from real runs of the published files
above, unattended, against a real journal database (13 notarized
releases, 4 with a recorded Gatekeeper check):

Detail mode:
```
Run 267 — run — notarization-delay-report.gbatch
  config:       config.gbatch
  gore version: 0.4.133  (script requires >= 0)
  host:         MBP.local (pid 34179)
  user:         davidbanham
  started:      2026-09-22T19:35:06.347Z
  ended:        2026-09-22T19:35:06.370Z  (duration 0.023s)
  mode:         run  (interactive=no, unattended=yes)
  result:       OK  (exit code 0)

Events:
  19:35:06.349  env-access    XDG_DATA_HOME
  19:35:06.349  env-access    HOME
  19:35:06.350  existence-check          /Users/davidbanham/.local/share/gore/journal.db  → exists=true
  19:35:06.369  step          query-detail     sqlite3 -header -column /Users/davidbanham/.local/share/gore/journal.db
                               → exit 0  (0.017s)  OK
  19:35:06.369  diagnostic    [info] detail report generated
```
which printed:
```
run_id  run_started          notarize_seconds  delay_minutes  attempts  status
------  -------------------  ----------------  -------------  --------  -------
250     2026-09-22 02:25:22  24.9              4              5         SUCCESS
225     2026-09-19 19:40:42  18.9              5              6         SUCCESS
194     2026-09-18 00:48:07  19.1              5              6         SUCCESS
193     2026-09-18 00:48:01                    0              1         SUCCESS
178     2026-09-17 17:33:39  18.8                             0         N/A
...
```

Summary mode, `mode = "summary"` in `config.gbatch`:
```
Run 268 — run — notarization-delay-report.gbatch
  config:       config.gbatch
  gore version: 0.4.133  (script requires >= 0)
  host:         MBP.local (pid 34197)
  user:         davidbanham
  started:      2026-09-22T19:35:12.438Z
  ended:        2026-09-22T19:35:12.448Z  (duration 0.010s)
  mode:         run  (interactive=no, unattended=yes)
  result:       OK  (exit code 0)

Events:
  19:35:12.439  env-access    XDG_DATA_HOME
  19:35:12.440  env-access    HOME
  19:35:12.440  existence-check          /Users/davidbanham/.local/share/gore/journal.db  → exists=true
  19:35:12.448  step          query-summary     sqlite3 /Users/davidbanham/.local/share/gore/journal.db
                               → exit 0  (0.007s)  OK
  19:35:12.448  diagnostic    [info] summary report generated
```
which printed:
```
Total releases with notarization: 13
Releases with Gatekeeper checks:  4
Average propagation delay:        3.6 minutes
Min propagation delay:            0 minutes
Max propagation delay:            5 minutes
Average notarization time:        20.2 seconds
```

## Where this goes next

See [`backup-and-prune.md`](backup-and-prune.md) for another example
built around a real SQLite database, `.backup`-ing and pruning it
rather than querying it, and
[`release-pipeline.md`](release-pipeline.md) for `ctx.retry`, the
primitive `verify_gatekeeper_online_check` (the step whose data this
example reports on) is itself built from.
