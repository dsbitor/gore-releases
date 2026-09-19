# Example: a curl-and-jq maintenance check

A habit most shell scripters already have — `curl ... | jq ...` — turned
into a gore `ctx.pipe`. This one queries the real public GitHub API for
`dsbitor/gore-releases`' own release count, no authentication required,
and logs a maintenance warning if there are more than ten.

The real file, ready to run as-is: [`release-count-report/`](release-count-report/).

## The script

```python
# release-count-report.gbatch
gbatch_version = ">= 0"

# Translates a familiar `curl ... | jq ...` habit into gore: fetch the
# real release list for dsbitor/gore-releases from GitHub's public API,
# no authentication needed, and count it. Past a threshold, this is a
# maintenance signal, not a failure, so it's logged as a warning, not
# ctx.fail: an old-releases pile-up is worth someone's attention, but
# it isn't this run's own problem.
def main(ctx, cfg):
    result = ctx.pipe(
        id = "release-count",
        stages = [
            ctx.step(
                id = "fetch",
                program = "curl",
                args = ["-s", "https://api.github.com/repos/dsbitor/gore-releases/releases"],
            ),
            ctx.step(id = "count", program = "jq", args = ["length"]),
        ],
    )
    if result.failed:
        ctx.fail(result.failed_step + " failed", result.error)
        return

    count = int(result.output.strip())
    threshold = 10

    if count > threshold:
        ctx.log(
            "maintenance required: " + str(count) + " releases published, consider pruning old ones",
            severity = "warning",
            fields = {"count": count, "threshold": threshold},
        )
        return

    ctx.success(str(count) + " releases published, within the maintenance threshold (" + str(threshold) + ")")
```

Two stages, `curl` then `jq`, each a real subprocess, `ctx.pipe` runs
them to completion in sequence and hands the first stage's full output
to the second — not a live-streaming shell pipe, but for a small JSON
response like this one that distinction doesn't matter in practice. No
`config.gbatch` needed; the repository name and threshold are simple
enough to leave inline for this example, an actual maintenance script
would likely move both into config.

## Running it, for real

This is a live, read-only query — no side effects, nothing to
confirm, safe to run as often as you like. Unedited `gore printlog`
output from a real run against the real repository:

```
Run 236 — run — release-count-report.gbatch
  gore version: 0.1.0  (script requires >= 0)
  host:         MBP.local (pid 93937)
  user:         davidbanham
  started:      2026-09-19T20:40:53.794Z
  ended:        2026-09-19T20:40:54.042Z  (duration 0.248s)
  mode:         run  (interactive=no, unattended=yes)
  result:       OK  (exit code 0)

Events:
  20:40:54.033  step          fetch     curl -s https://api.github.com/repos/dsbitor/gore-releases/releases
                               → exit 0  (0.236s)  OK
  20:40:54.040  step          count     jq length
                               → exit 0  (0.005s)  OK
  20:40:54.041  diagnostic    [info] 9 releases published, within the maintenance threshold (10)
```

Nine releases existed at the time this ran, still under the
threshold but not by much — so this transcript happens to show the
quiet path, not the warning. This count only ever goes up, and this
repository will cross ten releases eventually, so don't take "within
threshold" as a permanent property of this example; it's a live query
against whatever this repository's real release count is the moment
you run it. Bump `threshold` down locally and run it again if you want
to see the `[warning] maintenance required` branch fire for real
without waiting for that to happen naturally.

## Where this goes next

See [`backup-and-prune.md`](backup-and-prune.md) for `ctx.pipe` chained
with a real deletion downstream, and
[`release-pipeline.md`](release-pipeline.md) for the same `ctx.log`
primitive used as a plain progress checkpoint rather than a threshold
warning.
