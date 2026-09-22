-- notarization-detail.sql
--
-- One row per successfully-notarized release: how long notarize-submit
-- itself took, how long Gatekeeper's own online check took to actually
-- accept the result afterward (NULL/blank if no gatekeeper-check-spctl
-- step exists for that run yet, an older release predating that
-- check), how many attempts that took, and whether it ultimately
-- succeeded.
--
-- Driven by the .gbatch script alongside this file via `ctx.run`'s
-- `stdin_file`, so this is a real .sql script, not a string embedded
-- in Starlark: `sqlite3 -header -column <journal.db> < this file`.
--
-- gore-design-baseline.md Section 6a, "A second real operational
-- detail, found cutting v0.4.121" is the operational background for
-- why this report exists.

-- Constants, named once here rather than repeated as literals through
-- the query below. step_notarize/step_gatekeeper are the exact step
-- IDs release.gbatch's own release() and verify_gatekeeper_online_check()
-- functions use (release/release.gbatch) -- change them here if those
-- step IDs are ever renamed, not scattered through the query.
-- ms_per_second and minutes_per_day are unit-conversion constants, not
-- operational settings, so they live here rather than in config.gbatch.
-- round_decimals is the one genuinely cosmetic choice (how many
-- decimal places notarize_seconds is displayed to).
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
    (SELECT COUNT(*) FROM events e2 JOIN step_events se2 ON e2.event_id = se2.event_id
     WHERE e2.run_id = r.run_id AND e2.step_id = :step_gatekeeper) as attempts,
    CASE last_check.succeeded
        WHEN 1 THEN 'SUCCESS'
        WHEN 0 THEN 'FAILED'
        ELSE 'N/A'
    END as status
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
