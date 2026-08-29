# TidySurface

Reusable SwiftUI surface — menu bar popover, nudges, away prompt, recap, dashboard, settings.
Presentation only: it reads models and records user decisions, never captures or calls the network.

Related: [docs index](../../../../docs/README.md) ·
[surface-layer](../../../../docs/architecture/surface-layer.md) ·
[module-map](../../../../docs/architecture/module-map.md) ·
[guardrails](../../../../docs/guardrails.md) ·
[TidySuggest](../TidySuggest/README.md)

## Responsibility

Renders the read models from TidyStore / TidySuggest and captures the user's actions. The recap's
"Log it ✓" marks a suggestion handled **locally only** — it never writes to Productive (G1).

## Phase

Builds as a **shell in Phase 0**, fleshed out across **Phases 5–6**.

## Dependencies

- Internal: **TidyCore**, **TidyStore**, **TidySuggest**. **No** capture, network, or provider deps
  (presentation-only rule).

## Key types & files

| Type / file | Purpose |
|---|---|
| `MenuBarPopover` | `MenuBarExtra` content; status + local-only budget / capture-health badges. |
| `NudgePresenter` | **Phase 6, not wired.** Written and unit-tested; no production call site, and `NudgeEngine` (TidyAI) that would drive it has none either. `nudges` stays empty. |
| `AwayPrompt` | **Not wired.** `PowerObserver` (`TidyCapture/LiveCapture.swift`) is never started, so no `away_gaps` row is ever created and the prompt has nothing to ask about. |
| `RecapWindow` | Timeline + suggestion card stack; accept / edit / reassign / toss / log. |
| `MainWindow` | Hosts **Recap** and **Stats** as two tabs of one window; the menu item picks the tab. |
| `DashboardView` | The **Stats** tab. Weekly metrics from `daily_rollups`; AI-overhead panel. No targets. |
| `SettingsView` | Gate lists, budgets, retention window, day / zone. |

## Tables

- **Reads** (via TidyStore read models): `suggestions`, `sessions`, `away_gaps`, `daily_rollups`,
  `nudges`, `resolution_questions`, `pd_*` (labels).
- **Writes** (via DAOs): `decisions`, `suggestions.status`, `away_gaps.attribution`,
  `nudges.outcome`, `resolution_questions` answers.

## Protocol seams

Consumes read-model seams only; owns none. Guardrail: **G1** — "Log it ✓" updates
`suggestions.status` locally, never a Productive write.
