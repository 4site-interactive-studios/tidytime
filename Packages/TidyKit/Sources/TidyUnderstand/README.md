# TidyUnderstand

Turns raw capture and ingest into classified `sessions`: sessionization, entity resolution, the
local ladder rungs, the sensitivity gate, and the learning loop.

Related: [docs index](../../../../docs/README.md) ·
[understand-layer](../../../../docs/architecture/understand-layer.md) ·
[classification-ladder](../../../../docs/architecture/classification-ladder.md) ·
[guardrails](../../../../docs/guardrails.md) ·
[TidyAI](../TidyAI/README.md)

## Responsibility

Groups `activity_samples` into `sessions`, resolves each to a client/project via `entity_signals`,
runs rungs **1 (rules)** and **2 (lexical)** locally, applies the fail-closed sensitivity gate
before any cloud escalation, and feeds `decisions` back into the signal registry.

## Phase

Builds in **Phase 5** (recap & rules).

## Dependencies

- Internal: **TidyCore**, **TidyStore**. **Not** TidyAI — it reaches rungs 3–5 through the AI-router
  seam declared in TidyCore, and **degrades gracefully** when the router is unavailable (budget cap
  tripped / Apple Intelligence off). This keeps the graph acyclic and Phase 5 buildable before
  Phase 6 exists.

## Key types & files

| Type / file | Purpose |
|---|---|
| `Sessionizer` | `activity_samples` (+ away / meeting / slack signals) → `sessions`. |
| `EntityResolver` | Client registry over `entity_signals`; user-confirmed outranks inferred. |
| `Rung1Rules` / `Rung2Lexical` | Deterministic + fuzzy local classification. |
| `KeywordSensitivityGate` | `SensitivityGate` impl; fails closed → `GatedPayload` or generic fallback (G2). |
| `LearningLoop` | Reinforces `entity_signals` from `decisions`; raises `resolution_questions`. |

## Tables

- **Reads:** `activity_samples`, `page_snapshots`, `away_gaps`, `meetings`, `meeting_invitees`,
  `transcript_utterances`, `calendar_events`, `slack_messages`, the `pd_*` mirror, `decisions`.
- **Writes:** `sessions` (attribution + `produced_by_rung`, `rationale`, `is_sensitive`,
  `classified_at`), `entity_signals`, `resolution_questions`.

## Protocol seams

**Owns** the `SensitivityGate` implementation. **Consumes** the AI-router seam (rungs 3–5) and
`Clock`. Guardrails: **G2** (gate fails closed), **G4** (ladder short-circuit; records
`produced_by_rung`).
