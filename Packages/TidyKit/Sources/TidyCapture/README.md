# TidyCapture

On-device capture of the foreground context — apps, window titles, Chrome tabs, idle/away, and
meeting state — writing raw activity to the store.

Related: [docs index](../../../../docs/README.md) ·
[capture-layer](../../../../docs/architecture/capture-layer.md) ·
[phase-1-capture](../../../../docs/phases/phase-1-capture.md) ·
[guardrails](../../../../docs/guardrails.md) ·
[TidyStore](../TidyStore/README.md)

## Responsibility

Observes the active app (`NSWorkspace`), reads the focused window title via the Accessibility API
(never `CGWindowList` — G3), pulls the active Chrome tab through `BrowserAdapter`, tracks idle/away
via `CGEventSource`, and listens for sleep/lock. Emits switch + 30 s heartbeat samples and away gaps.

## Phase

Builds in **Phase 1** (capture).

## Dependencies

- Internal: **TidyCore**, **TidyStore**. Does **not** depend on TidyIngest or TidyAI.

## Key types & files

| Type / file | Purpose |
|---|---|
| `Watcher` | Subscribes to `NSWorkspace.didActivateApplicationNotification`; writes `activity_samples`. |
| `AXWindowTitleReader` | Focused-window title via `AXUIElement` (G3 — no `CGWindowList` name field). |
| `ChromeAdapter` | `BrowserAdapter` impl via AppleScript / Apple Events; active-tab URL / title / `innerText`. |
| `IdleMonitor` | `CGEventSource.secondsSinceLastEventType`; opens/closes `away_gaps`. |
| Sleep/lock observers | `NSWorkspace` sleep/wake + screen-lock notifications feed `away_gaps.cause`. |
| `Heartbeat` | 30 s sampler emitting `source='heartbeat'` rows without an app switch. |
| Meeting-state inference | Detects in-meeting state (for nudge suppression downstream). |

## Tables

- **Writes** (via TidyStore DAOs): `activity_samples`, `page_snapshots`, `away_gaps`.

## Protocol seams

**Owns** `BrowserAdapter` (v1 = `ChromeAdapter`; Safari / Firefox / Dia later). Consumes `Clock`.
Guardrail: **G3** — Accessibility-only window titles, no Screen Recording permission.
