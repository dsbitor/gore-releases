# Example: filtering text with a subprocess

The smallest useful gore script there is: run a familiar text-processing
tool, `awk`, the same way a shell would, and capture the result as a
structured value instead of scrollback. If the other examples in this
directory feel like a lot to take in at once, start here.

The real files, ready to run as-is: [`sum-sales/`](sum-sales/).

## The script

```python
# sum-sales.gbatch
gbatch_version = ">= 0"

def main(ctx, cfg):
    result = ctx.run(
        id = "sum",
        program = "awk",
        args = ["-F,", "{sum += $2} END {print sum}", "sales.csv"],
    )
    if result.failed:
        ctx.fail("awk failed", result.error)
        return
    ctx.success("total units sold: " + result.stdout.strip())
```

gore does not reimplement `awk`. It runs the real binary, exactly as a
shell pipeline would, and hands back a `StepResult` the script has to
actively check (`result.failed`) rather than silently continuing on a
nonzero exit the way an unguarded shell line would.

## Running it, for real

Against a `sales.csv` of:

```
widget,12
gadget,7
widget,3
gadget,9
```

`gore printlog latest`'s unedited output:

```
Run 8 — run — sum-sales.gbatch
  gore version: 0.1.0  (script requires >= 0)
  host:         MBP.local (pid 8717)
  user:         davidbanham
  started:      2026-08-30T23:19:20.171Z
  ended:        2026-08-30T23:19:20.305Z  (duration 0.134s)
  mode:         run  (interactive=no, unattended=yes)
  result:       OK  (exit code 0)

Events:
  23:19:20.304  step          sum     awk -F, {sum += $2} END {print sum} sales.csv
                               → exit 0  (0.130s)  OK
  23:19:20.305  diagnostic    [info] total units sold: 31
```

31 units, matching a hand check of the CSV (12 + 7 + 3 + 9). No
`config.gbatch`, no `cfg` fields used — a script that declares no
configuration file still receives a `cfg` argument, it simply carries
nothing.

## Where this goes next

See [`release-pipeline.md`](release-pipeline.md) for the same `ctx.run`
primitive used for real, high-stakes work — cross-compiling, signing,
and publishing — and [`backup-and-prune.md`](backup-and-prune.md) for
`ctx.pipe` chaining more than one subprocess together.
