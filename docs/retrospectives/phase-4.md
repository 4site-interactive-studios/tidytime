# Phase 4 retrospective — Slack

**Date:** 2026-07-23 · **Status:** ✅ logic complete, tests green (81 total, +9) · **Commit:** `feat(phase-4)`

## What shipped (code-complete + unit-tested)

| Area | Type(s) | Tested by |
|---|---|---|
| Schema | `v1-slack` (slack_messages) + DAO (idempotent upsert, latest-ts cursor) | `SlackMigrationAndStoreTests` (3) |
| ts helper | `SlackTS.epoch` | `SlackTSTests` |
| Client | `LiveSlackClient` (auth.test, users.list, conversations.list/history, cursor paging, `ok:false`) + `FakeSlackClient` | `SlackSyncTests` (parse + error) |
| Sessions | `SlackSessionizer` (gap-split, nominal duration) | `SlackSessionizerTests` |
| Sync | `SlackSync` (per-conv cursor, `is_self`, idempotent rebuild) | `SlackSyncTests` |

## Divergences / decisions (see DECISIONS.md)

- `is_self` = message user == `auth.test` id (catches phone-sent Slack).
- Single-message clusters get a nominal 60s so drive-by help isn't zero-length.
- Idempotent re-sync: delete `kind='slack'` sessions by `source_ref`, rebuild from all messages.
- **Cross-phase lesson:** adding `slack_messages` made it a real retention target and broke a
  Phase-1 "absent table" test; fixed + added a positive purge test.

## Deferred to manual verification (needs a Slack token + workspace)

- The internal-app rate-limit exemption (build-time check), the exact scopes at manifest time, and
  that a morning of real Slack activity (incl. phone) attributes to the right conversations.

## Notes for Phase 5 (Recap & rules)

- This is the first phase with **no new external API** — it's the payoff phase: rungs 1–2 (rules +
  lexical), the suggestion engine (rounding, pools, gap analysis, new-task proposals), the recap
  UI, ask-once resolution questions, and `decisions` recording.
- Add `v1-understand` migration (entity_signals, pools, suggestions, decisions, resolution_questions,
  daily_rollups). All of this is pure/tested logic feeding the recap; the recap window itself is
  SwiftUI (compile-only) but its view-models read tested read-models.
- Sessions now carry `context_key` (screen), `sourceRef` (meeting/slack). Entity resolution maps
  context keys / invitee domains / channel names → clients.
