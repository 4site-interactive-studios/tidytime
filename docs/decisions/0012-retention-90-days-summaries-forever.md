# 0012 — Retention: raw 90 days, summaries forever

High-volume, sensitive raw rows purge after a configurable window (default 90 days); distilled
artifacts persist indefinitely. All data stays in one local SQLite file.

Related: [README.md](README.md) · [../guardrails.md](../guardrails.md) ·
[../architecture/data-model.md](../architecture/data-model.md) ·
[0006](0006-grdb-sqlite-store.md)

**Status:** Accepted · **Date:** 2026-07-23

## Context

Passive capture accumulates the most sensitive, highest-volume data the app holds — window titles,
full page text, Slack messages, meeting transcripts. Keeping it forever grows the privacy blast
radius without proportional value: once a day is reconciled and distilled into sessions and
suggestions, the raw rows have done their job. But the distilled artifacts *are* the long-term value
(metrics, learned signals, the training signal for the learning loop), so they must survive
(PLAN §2, §6).

## Decision

A scheduled **retention job** (Phase 1, ongoing) deletes rows older than the configured window
(**default 90 days**, per-table configurable in `config.json`) from the high-volume/sensitive
tables, keeping distilled artifacts indefinitely (PLAN §6). This is guardrail
**[G9](../guardrails.md#g9--retention-and-privacy-blast-radius)**. Per
[data-model.md](../architecture/data-model.md):

| Purged after the window | Kept indefinitely |
|---|---|
| `activity_samples`, `page_snapshots` (cascade) | `sessions`, `suggestions`, `decisions` |
| `slack_messages` | `daily_rollups`, `entity_signals` |
| `transcript_utterances` (keep `meetings` summary rows) | `pools` (metadata), `ai_calls` |

## Consequences

- The privacy blast radius is one FileVault-encrypted SQLite file that **shrinks on schedule**;
  the newest ~90 days is all the raw detail that ever exists locally
  ([0006](0006-grdb-sqlite-store.md)).
- `page_snapshots` cascade-delete with their `activity_samples`; utterances drop past the window
  while the `meetings` summary row is kept, so meeting history survives without its raw transcript.
- Covered by a test that seeds old rows and asserts they're gone after the window (guardrail G9,
  Phase 1 acceptance).
- Trade-off: raw evidence older than the window can't be re-derived — accepted, because the
  distilled artifacts carry the durable value and the whole point is to not hoard raw content.
- Windows are per-table configurable, so a user who wants shorter/longer retention on a given table
  can set it without a code change.

## Alternatives considered

- **Keep everything forever.** Rejected: an ever-growing store of the most sensitive data for no
  proportional benefit — the opposite of the privacy posture.
- **Purge everything on the same short clock.** Rejected: would discard the distilled artifacts that
  power metrics and the learning loop; only the *raw* tier ages out.
