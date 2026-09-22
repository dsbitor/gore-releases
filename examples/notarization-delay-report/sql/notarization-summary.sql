-- notarization-summary.sql
--
-- Five aggregate stats, one SELECT per stat, UNION ALL'd into a single
-- result set: total notarized releases, how many of those have a
-- recorded Gatekeeper check at all (older releases won't), and average
-- /min/max propagation delay plus average notarization time across the
-- ones that do.
--
-- Driven by the .gbatch script alongside this file via `ctx.run`'s
-- `stdin_file`, so this is a real .sql script, not a string embedded
-- in Starlark: `sqlite3 <journal.db> < this file`.
--
-- Each SELECT repeats the same runs/events/step_events joins as
-- notarization-detail.sql rather than sharing a CTE, so any one stat
-- can be read, copied out, and run on its own while debugging.

-- See notarization-detail.sql for why these are named constants here
-- rather than literals repeated through the query, and why they live
-- in the .sql file rather than config.gbatch.
.param set :step_notarize 'notarize-submit'
.param set :step_gatekeeper 'gatekeeper-check-spctl'
.param set :ms_per_second 1000.0
.param set :minutes_per_day 1440
.param set :round_decimals 1

SELECT
    'Total releases with notarization: ' || COUNT(*) as stat
FROM runs r
JOIN events e_notarize ON r.run_id = e_notarize.run_id
JOIN step_events notarize ON e_notarize.event_id = notarize.event_id
WHERE e_notarize.step_id = :step_notarize
  AND notarize.succeeded = 1
UNION ALL
SELECT
    'Releases with Gatekeeper checks:  ' || COUNT(CASE WHEN last_check.succeeded = 1 THEN 1 END)
FROM runs r
JOIN events e_notarize ON r.run_id = e_notarize.run_id
JOIN step_events notarize ON e_notarize.event_id = notarize.event_id
LEFT JOIN (
    SELECT e.run_id, e.occurred_at, se.succeeded,
           ROW_NUMBER() OVER (PARTITION BY e.run_id ORDER BY e.occurred_at DESC) as rn
    FROM events e
    JOIN step_events se ON e.event_id = se.event_id
    WHERE e.step_id = :step_gatekeeper
) last_check ON r.run_id = last_check.run_id AND last_check.rn = 1
WHERE e_notarize.step_id = :step_notarize
  AND notarize.succeeded = 1
UNION ALL
SELECT
    'Average propagation delay:        ' ||
    ROUND(AVG(CASE WHEN last_check.succeeded = 1
        THEN CAST((julianday(last_check.occurred_at) - julianday(e_notarize.occurred_at)) * :minutes_per_day AS REAL)
    END), :round_decimals) || ' minutes'
FROM runs r
JOIN events e_notarize ON r.run_id = e_notarize.run_id
JOIN step_events notarize ON e_notarize.event_id = notarize.event_id
LEFT JOIN (
    SELECT e.run_id, e.occurred_at, se.succeeded,
           ROW_NUMBER() OVER (PARTITION BY e.run_id ORDER BY e.occurred_at DESC) as rn
    FROM events e
    JOIN step_events se ON e.event_id = se.event_id
    WHERE e.step_id = :step_gatekeeper
) last_check ON r.run_id = last_check.run_id AND last_check.rn = 1
WHERE e_notarize.step_id = :step_notarize
  AND notarize.succeeded = 1
UNION ALL
SELECT
    'Min propagation delay:            ' ||
    MIN(CASE WHEN last_check.succeeded = 1
        THEN CAST((julianday(last_check.occurred_at) - julianday(e_notarize.occurred_at)) * :minutes_per_day AS INTEGER)
    END) || ' minutes'
FROM runs r
JOIN events e_notarize ON r.run_id = e_notarize.run_id
JOIN step_events notarize ON e_notarize.event_id = notarize.event_id
LEFT JOIN (
    SELECT e.run_id, e.occurred_at, se.succeeded,
           ROW_NUMBER() OVER (PARTITION BY e.run_id ORDER BY e.occurred_at DESC) as rn
    FROM events e
    JOIN step_events se ON e.event_id = se.event_id
    WHERE e.step_id = :step_gatekeeper
) last_check ON r.run_id = last_check.run_id AND last_check.rn = 1
WHERE e_notarize.step_id = :step_notarize
  AND notarize.succeeded = 1
UNION ALL
SELECT
    'Max propagation delay:            ' ||
    MAX(CASE WHEN last_check.succeeded = 1
        THEN CAST((julianday(last_check.occurred_at) - julianday(e_notarize.occurred_at)) * :minutes_per_day AS INTEGER)
    END) || ' minutes'
FROM runs r
JOIN events e_notarize ON r.run_id = e_notarize.run_id
JOIN step_events notarize ON e_notarize.event_id = notarize.event_id
LEFT JOIN (
    SELECT e.run_id, e.occurred_at, se.succeeded,
           ROW_NUMBER() OVER (PARTITION BY e.run_id ORDER BY e.occurred_at DESC) as rn
    FROM events e
    JOIN step_events se ON e.event_id = se.event_id
    WHERE e.step_id = :step_gatekeeper
) last_check ON r.run_id = last_check.run_id AND last_check.rn = 1
WHERE e_notarize.step_id = :step_notarize
  AND notarize.succeeded = 1
UNION ALL
SELECT
    'Average notarization time:        ' ||
    ROUND(AVG(notarize.duration_ms / :ms_per_second), :round_decimals) || ' seconds'
FROM runs r
JOIN events e_notarize ON r.run_id = e_notarize.run_id
JOIN step_events notarize ON e_notarize.event_id = notarize.event_id
WHERE e_notarize.step_id = :step_notarize
  AND notarize.succeeded = 1;
