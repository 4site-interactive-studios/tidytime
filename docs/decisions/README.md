# Architecture Decision Records

The "why" behind TidyTime's locked choices. Each ADR captures one decision in a fixed shape —
**Context** (the forces at play), **Decision** (what we chose), **Consequences** (what it costs
and buys), and **Alternatives considered** — and is **immutable once accepted**. We don't edit an
accepted ADR to change its mind; we write a new ADR that supersedes it and update the index.

Related: [../README.md](../README.md) · [../../PLAN.md](../../PLAN.md) ·
[../guardrails.md](../guardrails.md) · [../architecture/module-map.md](../architecture/module-map.md)

## What an ADR is (and isn't)

- **Is:** a durable record of a decision that shaped the architecture, grounded in
  [PLAN.md](../../PLAN.md) (the interview-locked scope) and the [guardrails](../guardrails.md).
- **Isn't:** a design doc, a how-to, or a spec. Those live under `architecture/`, `build/`, and
  `reference/`. An ADR links out to them; it doesn't duplicate them.
- **Lifecycle:** `Proposed → Accepted → (Superseded by NNNN)`. All v1 ADRs below ship
  **Accepted** because they encode decisions the interview already locked. A reversal (e.g. v2's
  Productive write access) is a *new* ADR that marks the old one **Superseded**, never an edit.

## Index

| # | Title | Status | Guardrail |
|---|---|---|---|
| [0001](0001-read-only-productive-v1.md) | Read-only Productive in v1 | Accepted | G1 |
| [0002](0002-single-process-no-daemons.md) | Single menu-bar process, no daemons | Accepted | G8 |
| [0003](0003-local-first-classification-ladder.md) | Local-first classification ladder | Accepted | G4 |
| [0004](0004-sensitivity-gate-fail-closed.md) | Sensitivity gate fails closed | Accepted | G2 |
| [0005](0005-swift-swiftui-xcodegen-swiftpm.md) | Swift/SwiftUI, XcodeGen shell + SwiftPM `TidyKit` | Accepted | — |
| [0006](0006-grdb-sqlite-store.md) | GRDB + SQLite (WAL) single-file store | Accepted | G9 |
| [0007](0007-accessibility-not-screen-recording.md) | Accessibility window titles, not Screen Recording | Accepted | G3 |
| [0008](0008-fireworks-economy-plus-claude-escalation.md) | Fireworks economy tier + Claude escalation | **Superseded by 0013** | G5 |
| [0009](0009-stable-signing-for-tcc.md) | Stable code signature for TCC durability | Accepted | G7 |
| [0010](0010-chrome-only-behind-browseradapter.md) | Chrome only in v1, behind `BrowserAdapter` | Accepted | — |
| [0011](0011-no-timers-backfill-model.md) | No timers — passive capture + backfill | Accepted | — |
| [0012](0012-retention-90-days-summaries-forever.md) | Retention: raw 90 days, summaries forever | Accepted | G9 |
