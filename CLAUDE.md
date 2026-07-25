# CLAUDE.md — TidyTime

> Loaded into every Claude Code session in this repo. Keep it lean and high-signal.
> Deep detail lives in `docs/`; this file tells you what the project is, the rules you
> may never break, and where to read next. **Read the docs you need before writing code —
> do not guess at an API shape or a table name.**

## What this is

TidyTime is a **native macOS menu bar app** (Swift/SwiftUI) that passively watches a
knowledge worker's day — foreground app + window titles, Chrome (URL/title/visible text),
Google Calendar, Fathom meeting transcripts, Slack — reconstructs it into sessions, and
produces **ready-to-enter time-entry suggestions** for [Productive](https://productive.io)
(client → project → task, rounded to 15 min, with a short note and a deep link).

It **recommends; the human enters.** Full vision: [PLAN.md](PLAN.md).

> **Before starting work, read [DECISIONS.md](DECISIONS.md).** It's the append-only log of
> architecture choices, non-obvious fixes, and abandoned approaches, written for an AI session with
> no memory of the ones before it. It will save you from relearning or undoing settled decisions.
> Append to it (with the commit that makes the decision) whenever you make a significant choice.

## Prime directives (non-negotiable — see [docs/guardrails.md](docs/guardrails.md))

1. **v1 is READ-ONLY against Productive.** No `POST`/`PATCH`/`DELETE`/`PUT` to
   `api.productive.io`, ever. The whole product is "suggest, don't write." A write call is
   a release-blocking bug, not a feature. This is enforced by test, not just discipline.
2. **The sensitivity gate fails closed.** Personnel / compensation / performance / legal
   content, and anything on the user's flagged lists, must never appear in a payload sent to
   any cloud model. When in doubt, it's sensitive → generic task, bland note, local-only.
3. **No Screen Recording permission.** Window titles come from the Accessibility API
   (`AXUIElement`), never `CGWindowList`'s window-name field. Requesting Screen Recording is
   a design failure.
4. **Local-first, then cheap, then smart.** Every classification climbs the ladder only as
   far as it must: rules → lexical → on-device model → economy cloud → escalation. Never call a
   cloud model for something a rule or a fuzzy match already answers.
5. **Every cloud AI call is metered** into the `ai_calls` ledger (provider, model, tokens,
   cost, outcome) and bounded by budget caps. No un-ledgered, un-capped cloud call.
6. **Tokens live in the macOS Keychain, never in files, logs, or the DB.** Config
   (`config.json`) holds non-secret settings only.
7. **Stable code signature.** Never ship an ad-hoc / changing signature — macOS ties TCC
   permission grants to the signature and silently revokes them on change. See
   [docs/build/signing-and-tcc.md](docs/build/signing-and-tcc.md).

## Tech stack

- **Language/UI:** Swift 6, SwiftUI, `MenuBarExtra`. Deployment target macOS 14; the
  on-device model rung is gated to macOS 26 + Apple Intelligence at runtime.
- **Storage:** SQLite via **GRDB** (WAL), at `~/Library/Application Support/TidyTime/`.
- **Project generation:** **XcodeGen** (`project.yml`) → `xcodebuild`. Logic lives in a
  local SwiftPM package (`Packages/TidyKit`); the Xcode app target is a thin shell for the
  Info.plist / entitlements / signing that SwiftPM can't express.
- **Cloud AI:** Fireworks AI (OpenAI-compatible) serves **both** the economy tier and escalation
  by default (ADR 0013); the Anthropic/Claude direct path stays implemented but off. On-device:
  Apple Foundation Models.
- **Launch at login:** `SMAppService`. One process, no helpers/daemons in v1.

## Repo map

```
PLAN.md                     Canonical vision & scope (source of truth)
CLAUDE.md                   You are here
config.example.json         Config schema; copy to config.json (gitignored)
project.yml                 XcodeGen spec for the app target
App/                        Thin app shell: @main, Info.plist, entitlements
Packages/TidyKit/           All logic, as SwiftPM library targets:
  Sources/TidyCore/           models, Config, Keychain, logging, time utils
  Sources/TidyStore/          GRDB schema, migrations, DAOs, retention
  Sources/TidyCapture/        app/window watcher, Chrome adapter, idle, meeting state
  Sources/TidyIngest/         Productive, Fathom, Google Calendar, Slack clients + sync
  Sources/TidyUnderstand/     sessionization, entity resolution, ladder, sensitivity gate
  Sources/TidyAI/             provider router, on-device rung, cloud clients, usage ledger
  Sources/TidySuggest/        rounding, pools, meeting split, gap analysis, new-task proposals
  Sources/TidySurface/        SwiftUI: popover, nudges, away prompt, recap, dashboard, settings
docs/                       All reference & build documentation — see docs/README.md
  docs/RUNNING.md             What was built + the end-to-end runbook (start here to run it)
site/                       Companion single-page static site — keep its claims in sync with HEAD
scripts/                    Dev helpers (doc-link check, coverage, etc.)
```

Module responsibilities & dependency rules: [docs/architecture/module-map.md](docs/architecture/module-map.md).
The database schema (the shared vocabulary of table/column names):
[docs/architecture/data-model.md](docs/architecture/data-model.md).

## Build / run / test

```bash
make bootstrap   # install XcodeGen (brew) + generate TidyTime.xcodeproj
make generate    # regenerate the Xcode project from project.yml (after adding files)
make build       # xcodebuild the app
make run         # build + launch the app
make test        # run TidyKit unit tests
make doctor      # print DB path, config path, and permission status
```

Regenerate the project (`make generate`) whenever you add/remove source files — XcodeGen
reads the folder tree, so new files under a target's path are picked up automatically.

## How this project is built: phases

The build is **capture-first and strictly phased**. Each phase ends in something usable and
has an explicit, human-verifiable acceptance check. **Do not pull work forward across phase
boundaries** unless a phase doc says a seam is expected earlier.

| Phase | Theme | Doc |
|---|---|---|
| 0 | Skeleton (menu bar, DB, config, signing) | [docs/phases/phase-0-skeleton.md](docs/phases/phase-0-skeleton.md) |
| 1 | Capture (watcher, Chrome, idle, sessionization) | [docs/phases/phase-1-capture.md](docs/phases/phase-1-capture.md) |
| 2 | Productive mirror (read-only sync) | [docs/phases/phase-2-productive.md](docs/phases/phase-2-productive.md) |
| 3 | Meetings & calendar (Fathom, Google) | [docs/phases/phase-3-meetings-calendar.md](docs/phases/phase-3-meetings-calendar.md) |
| 4 | Slack ingest | [docs/phases/phase-4-slack.md](docs/phases/phase-4-slack.md) |
| 5 | Recap & rules (rungs 1–2, suggestion engine, recap UI) | [docs/phases/phase-5-recap-rules.md](docs/phases/phase-5-recap-rules.md) |
| 6 | Intelligence (gate, on-device, cloud router, ledger, nudges) | [docs/phases/phase-6-intelligence.md](docs/phases/phase-6-intelligence.md) |

Start any work session by opening the current phase doc and its acceptance criteria.
Full doc index and suggested reading order: [docs/README.md](docs/README.md).

## Conventions (full: docs/conventions/)

- Swift style, naming, concurrency (`async`/`await`, actors for the capture pipeline):
  [docs/conventions/swift-style.md](docs/conventions/swift-style.md).
- Errors are typed and never silently swallowed; logging goes through `TidyLog`
  (os.Logger), never `print`; secrets never logged:
  [docs/conventions/error-handling-logging.md](docs/conventions/error-handling-logging.md).
- Every external API client isolates I/O behind a protocol so it can be tested with
  recorded fixtures — no live network in unit tests.
- Timestamps: store as **INTEGER Unix epoch seconds, UTC**. Durations in **seconds** in our
  own tables; Productive's `time`/`billable_time` stay in **minutes** (mirror the API as-is).

## Definition of done for any change

- Compiles (`make build`) and unit tests pass (`make test`).
- No new lint violation of the prime directives (read-only Productive; no `CGWindowList`
  name API; no secrets in logs) — the guardrail tests stay green.
- New user-facing behavior is reflected in the relevant phase doc's acceptance criteria.
- If it touches the schema, it's a **new** GRDB migration (never edit a shipped one) and
  `docs/architecture/data-model.md` is updated in the same change.
- If it adds config, `config.example.json` and [docs/architecture/data-model.md] /
  settings docs are updated.

## When docs and reality disagree

Vendor APIs drift. If the live API contradicts a `docs/reference/*` file, **trust the live
API, fix the doc in the same PR, and stamp it with the new verification date.** Items the
plan itself flagged as unverifiable are marked "⚠️ Build-time check" — resolve those against
the real service, don't assume.
