# TidyTime documentation

This is the map. Everything a future Claude Code session needs to build a phase correctly
lives under `docs/`, grounded in the canonical [PLAN.md](../PLAN.md) at the repo root.

## How to read this (suggested order)

1. **[../PLAN.md](../PLAN.md)** — the vision and scope. Read once, fully.
2. **[../CLAUDE.md](../CLAUDE.md)** — the prime directives and repo map. Always loaded.
3. **[guardrails.md](guardrails.md)** — the invariants you may never break, and how each is
   enforced. Read before writing any code that touches Productive, the cloud, or logs.
4. **[architecture/overview.md](architecture/overview.md)** — the five layers and the one-process model.
5. **[architecture/data-model.md](architecture/data-model.md)** — the SQLite schema. The shared
   vocabulary of table and column names every other doc references.
6. The **phase doc** you are currently building (`phases/phase-N-*.md`), plus the
   **reference docs** it points at.

## Architecture (`architecture/`)

| Doc | Covers |
|---|---|
| [overview.md](architecture/overview.md) | Five-layer system, single-process model, data flow |
| [module-map.md](architecture/module-map.md) | SwiftPM targets, responsibilities, dependency rules, protocol seams |
| [data-model.md](architecture/data-model.md) | SQLite schema, DDL, indices, migrations, retention |
| [capture-layer.md](architecture/capture-layer.md) | Watcher, Chrome adapter, idle/away, meeting state |
| [ingest-layer.md](architecture/ingest-layer.md) | Sync engines, incremental sync, rate-limit handling |
| [understand-layer.md](architecture/understand-layer.md) | Sessionization, entity resolution, sensitivity gate, learning loop |
| [classification-ladder.md](architecture/classification-ladder.md) | The five rungs in detail, routing, budgets |
| [suggestion-engine.md](architecture/suggestion-engine.md) | Rounding, pools, meeting split, gap analysis, new-task proposals |
| [surface-layer.md](architecture/surface-layer.md) | Menu bar, nudges, away prompt, recap, dashboard, settings |

## Reference (`reference/`) — external ground truth, dated

| Doc | Service |
|---|---|
| [productive-api.md](reference/productive-api.md) | Productive JSON:API (read-only) |
| [fathom-api.md](reference/fathom-api.md) | Fathom meetings & transcripts |
| [google-calendar-api.md](reference/google-calendar-api.md) | Google Calendar (read-only OAuth) |
| [slack-api.md](reference/slack-api.md) | Slack Web API (internal app) |
| [fireworks-ai.md](reference/fireworks-ai.md) | Fireworks AI economy cloud tier |
| [apple-foundation-models.md](reference/apple-foundation-models.md) | On-device model rung |
| [chrome-scripting.md](reference/chrome-scripting.md) | AppleScript / Apple Events into Chrome |
| [macos-permissions-tcc.md](reference/macos-permissions-tcc.md) | Accessibility, Automation, Notifications, TCC |

## Build (`build/`)

| Doc | Covers |
|---|---|
| [environment-setup.md](build/environment-setup.md) | Xcode, XcodeGen, toolchain, first generate |
| [signing-and-tcc.md](build/signing-and-tcc.md) | Stable signing so TCC grants survive rebuilds |
| [xcodegen-spec.md](build/xcodegen-spec.md) | `project.yml` structure and how targets map to folders |
| [testing-strategy.md](build/testing-strategy.md) | Unit tests, fixtures, guardrail tests, what "done" means |

## Phases (`phases/`) — the build order

[phase-0](phases/phase-0-skeleton.md) · [phase-1](phases/phase-1-capture.md) ·
[phase-2](phases/phase-2-productive.md) · [phase-3](phases/phase-3-meetings-calendar.md) ·
[phase-4](phases/phase-4-slack.md) · [phase-5](phases/phase-5-recap-rules.md) ·
[phase-6](phases/phase-6-intelligence.md)

## Decisions (`decisions/`)

Architecture Decision Records — the "why" behind the locked choices.
Index: [decisions/README.md](decisions/README.md).

## Conventions (`conventions/`)

[swift-style.md](conventions/swift-style.md) ·
[error-handling-logging.md](conventions/error-handling-logging.md) ·
[ai-provider-router.md](conventions/ai-provider-router.md)

## Cross-cutting

| Doc | Covers |
|---|---|
| [guardrails.md](guardrails.md) | The safety invariants and their enforcement |
| [permissions-setup.md](permissions-setup.md) | The one-time human setup checklist |
| [glossary.md](glossary.md) | Domain terms (Productive, EN/ENgrid, Fathom, session, pool, rung…) |
| [open-items.md](open-items.md) | Unresolved questions to settle during the build |
| [retrospectives/](retrospectives/README.md) | Per-phase + project retrospectives (what actually shipped) |
| [PROJECT-REVIEW.md](PROJECT-REVIEW.md) | Independent 3-agent review + fix dispositions |
| [../DECISIONS.md](../DECISIONS.md) | Running decision & learning log (read before working) |

---

**Doc conventions.** Every reference doc opens with a metadata block (status, source URLs,
last-verified date). Facts that couldn't be verified from vendor docs are marked
`⚠️ Build-time check`. Internal links are relative. When you change behavior, update the doc
in the same change — stale docs are worse than no docs.
