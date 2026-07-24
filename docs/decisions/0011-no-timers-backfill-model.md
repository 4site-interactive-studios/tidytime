# 0011 — No timers — passive capture + backfill

TidyTime has no stopwatch and asks for no start/stop. It captures the day passively and attributes
it afterward, reconstructing loggable blocks from what actually happened.

Related: [README.md](README.md) · [../../PLAN.md](../../PLAN.md) ·
[../architecture/suggestion-engine.md](../architecture/suggestion-engine.md) ·
[../architecture/capture-layer.md](../architecture/capture-layer.md)

**Status:** Accepted · **Date:** 2026-07-23

## Context

The problem TidyTime solves is *forgotten* billable time — the 15 client minutes inside an hour-long
call, the drive-by Slack DMs, the block you'd misremember (PLAN §1). Timer-based tools fail exactly
here: they require you to remember to start and stop, which is the discipline knowledge workers
don't have and the reason time gets lost. The house norm is entries in by close of day; the tool has
to work *after the fact*, not demand behavior change up front (PLAN §2).

## Decision

**No timers.** The app is built for **backfill**: capture everything passively (app/window,
Chrome, calendar, Fathom, Slack, idle/away), then attribute afterward (PLAN §2). Sessions are
*derived* from `activity_samples` and ingest, not started by the user. Meeting duration is Fathom
recording start/end (ground truth), not a running clock. The user's only interaction is
**reviewing** suggestions at recap time and answering the occasional away prompt — never running a
stopwatch.

## Consequences

- Nothing is lost to forgetting to hit start: if it happened on the machine (or in a synced source),
  it's captured and offered back at recap.
- The design centers on **reconstruction quality** — sessionization, pools for micro-work, meeting
  splitting, gap analysis against `pd_time_entries` (see
  [suggestion-engine.md](../architecture/suggestion-engine.md)) — rather than on live tracking UI.
- Live **nudges** exist but are advisory and rate-limited; ignoring every nudge costs nothing
  because everything waits in the recap anyway (PLAN §9). Nudges are not timers.
- Trade-off: attribution is a *guess* to confirm, not a user-declared fact — the recap is built so a
  wrong guess costs one tap, and the learning loop improves guesses over time.

## Alternatives considered

- **Manual start/stop timers.** Rejected: they lose precisely the forgotten time the product exists
  to recover, and demand the discipline users lack.
- **Live auto-timer that switches projects on context change.** Rejected for v1: it commits to an
  attribution in real time (often wrong mid-context) instead of reconstructing with full-day
  hindsight; backfill with the whole day in view is more accurate and less intrusive.
