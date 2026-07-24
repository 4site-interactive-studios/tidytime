# TidySuggest

The suggestion engine: rounds classified time into 15-minute entries, pools micro-work, splits
meetings, runs gap analysis against logged time, and proposes new tasks. Emits `suggestions`.

Related: [docs index](../../../../docs/README.md) ·
[suggestion-engine](../../../../docs/architecture/suggestion-engine.md) ·
[data-model](../../../../docs/architecture/data-model.md) ·
[guardrails](../../../../docs/guardrails.md) ·
[TidyUnderstand](../TidyUnderstand/README.md)

## Responsibility

Converts `sessions` (plus away gaps and meetings) into `suggestions` — 15-min rounding with
round-up bias, micro-work `pools`, per-client meeting segments, gap analysis vs `pd_time_entries`,
and new-task proposals for unmatched work.

## Phase

Builds across **Phases 5–6**.

## Dependencies

- Internal: **TidyCore**, **TidyStore**, **TidyUnderstand**, **TidyAI** (per `Package.swift`). Uses
  the AI router for note drafting / new-task text but degrades gracefully without it.

## Key types & files

| Type / file | Purpose |
|---|---|
| `Rounder` | 15-min increments + round-up bias; sets `minutes`, `raw_seconds`, `is_rounded_up`. |
| `PoolManager` | Accumulates sub-threshold micro-work into `pools`; rolls up to one itemized suggestion. |
| `MeetingSplitter` | Splits recording duration into per-client `meeting_segment`s from the transcript. |
| `GapAnalyzer` | Reconstructed time vs `pd_time_entries`; suggests only the missing time. |
| `NewTaskProposer` | `proposed_task_title` / `_description` for client work with no open task. |

## Tables

- **Reads:** `sessions`, `away_gaps`, `meetings`, `transcript_utterances`, `pd_time_entries`,
  `pd_tasks`, `pd_projects`, `pd_companies`, `entity_signals`.
- **Writes:** `suggestions`, `pools`, `daily_rollups` (observed / attributed seconds).

## Protocol seams

Consumes the AI-router seam (via TidyAI) and the TidyCore rounding utilities. Guardrails: **G4**
(records `produced_by_rung`); propagates the gate's `is_sensitive` flag onto every suggestion.
