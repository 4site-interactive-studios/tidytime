# Project-wide retrospective — TidyTime v1

**Date:** 2026-07-24 · Companion to the independent [PROJECT-REVIEW.md](../PROJECT-REVIEW.md).

## What was built

Seven phases (0–6), each shipped as tested logic behind protocols with a `feat` commit and a
separate `docs` retrospective commit, plus a running [DECISIONS.md](../../DECISIONS.md):

- **Phase 0** — test & debug infra: config, Keychain secrets, dual-sink structured logging, the
  copy-to-clipboard diagnostic bundle, GRDB store.
- **Phase 1** — capture: watcher/adapter protocols, sessionization, page-text dedup, retention.
- **Phase 2** — read-only Productive mirror (G1 enforced by test).
- **Phase 3** — Fathom + Google Calendar ingest, meeting sessions, away-gap resolution.
- **Phase 4** — Slack ingest + timeline sessions.
- **Phase 5** — classification rungs 1–2, the suggestion engine (rounding, pools, gap analysis,
  new-task), recap read-model, learning loop, sensitivity gate.
- **Phase 6** — the metered AI router, cloud + real on-device providers, ledger, budgets, nudges,
  dashboard.

### Post-v1 enhancements (added *after* the round-1 review)

- **Tiered change-gated capture** (`294ef0d`) — a fast detection tick (default 1 s) + a slow
  page-text tick, recording a sample only when the context signature changes.
- **Context-switching metric** + Fireworks-only AI routing (`bf5463f`) — quantifies the
  fragmentation agentic tooling causes, computed from the raw sample stream.
- **Finer within-app attribution** (`546fde7`) — title-discriminated grouping + page text into rung 2.
- **Chat separation by URL path** (`dcffdac`) — same-title chats become distinct sessions.
- **Companion site** (`51fe2b0`).

**Final state:** **194 unit tests, 0 failures; 64.3% line coverage on `Sources/`** (~90% on the testable core; the app-shell wiring added ~1,500 lines of SwiftUI that can't run headlessly) (re-measured with
`make coverage` after the round-2 fixes, not carried forward); 8 SwiftPM library targets; 9
guardrails, each backed by a test.

## How it was built (and the honest constraint)

Developed in a **headless environment** — no way to grant TCC, run the GUI, complete OAuth, or hit
live APIs. The strategy (recorded in DECISIONS.md and every phase's "Status: as built") was to put
all logic behind protocols and test it with fakes + in-memory GRDB, while OS/UI/live-network code is
written to **compile** (availability-guarded) and verified manually on a real Mac. This is why the
raw coverage number (80.8%) is lower than the core (~91%): the gap is almost entirely the
intentionally-untested `LiveCapture`, SwiftUI views, live `URLSession` client, and the on-device
runtime path.

## What went well

- **Guardrails as tests, not vibes.** G1/G2/G3/G5/G6/G9 each fail the build on violation. The
  independent review specifically confirmed G1/G5/G6 and, after fixes, G2/G3/G9.
- **Reusable seams paid off.** One HTTP/Backoff layer served four ingest clients; the `AIProvider`
  protocol let the router be tested without any provider; `FixedClock` made every time-dependent
  path deterministic.
- **The DECISIONS log caught its own drift** — the review found one inaccurate claim in it, which is
  exactly the kind of thing the log exists to keep honest.

## What the review changed

The three-agent review surfaced **12 items**; all actionable ones were fixed with regression tests
(see [PROJECT-REVIEW.md](../PROJECT-REVIEW.md)). The two that mattered most were real guardrail gaps
that "looked done" but weren't enforced: transcript retention (G9) and the gate's empty-list
fail-open (G2). Both are now enforced by test.

## What the second round changed

Four blind reviewers audited the five post-review commits (see
[PROJECT-REVIEW.md § Round 2](../PROJECT-REVIEW.md)). Three returned **fail**. The substantive ones:

- The **context-switching metric over-counted** — capture and the metric keyed on the raw URL/title
  while sessionization normalized them, so per-message churn and unread-badge ticks read as context
  switches. One shared definition now lives in `TidyCore.ContextSignature`.
- **Unattended time counted as focus**, and `writeRollup` persisted it — poisoning the very trend
  series the metric exists to build.
- **Rerouting escalation to Fireworks silently broke `escalationRate`**, which classified tiers by
  vendor. A routing change quietly invalidated a metric keyed on the routing dimension.
- **An absorbed detour could supply 100% of a session's attribution evidence** (page text was
  time-scoped only).

## What remains for a real Mac / a human

- **Wire the app shell.** `LiveCaptureController`, `SessionBuildJob` and every SwiftUI surface have
  no production construction site — `App/TidyTimeApp.swift` is still the Phase-0 placeholder. This
  is the largest remaining gap between "tested library" and "working product".
- Build & run (`make bootstrap && make run`), grant permissions, paste tokens, complete OAuth, create
  the Slack app — then verify the manual acceptance criteria in each phase doc.
- Pick the real Fireworks escalation model slug and confirm live pricing (`_build_time_checks`).
- Wire the remaining Phase 6 refinements (end-to-end transcript splitting into per-client segments,
  on-device `@Generable` guided generation, calibration sampling).
- Replace the site's synthetic mockups with real screenshots.

## Biggest lessons for the next AI worker

**Round 2: a review is only valid for the sha it ran against.** Round 1's record was accurate when
written and was quietly false four commits later, with nobody editing it. Stamp reviews with their
range; treat anything after it as unreviewed. And note the sting: the round-1 lesson below —
"configured ≠ enforced" — was itself **violated four commits after being written**
(`separate_chats_by_path` shipped as config no production code read). *A lesson recorded in a doc is
not a control; only a test is.*

**Round 1: "Configured" is not "enforced."** Two guardrails were listed in config and docs but silently did
nothing (G9 transcript purge, G2 empty-list). If a guarantee matters, it needs a test that fails
when the guarantee is broken — the config entry alone is a false sense of safety.
