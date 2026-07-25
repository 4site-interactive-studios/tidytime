# TidyTime

**A passive time-capture and attribution assistant for [Productive](https://productive.io).**

TidyTime is a native macOS menu bar app that watches how you actually spend your workday —
foreground apps and window titles, Chrome (URL, title, visible page text), Google Calendar,
Fathom meeting transcripts, and Slack — reconstructs the day into loggable blocks, matches
each block to your Productive **client → project → task**, and hands you ready-to-enter time
entries: the task, a duration rounded to 15 minutes, and a one-to-two sentence note with a
copy button and a deep link.

**It recommends; you enter.** v1 is **read-only** against Productive — nothing is ever written
back. It's built for *backfill*, not stopwatch discipline: capture everything passively,
attribute afterward, and at end of day (or first thing the next morning) reconcile a whole day
in a few minutes instead of an end-of-week archaeology session.

> **Status: library complete; app shell not yet wired.**
> All seven phases (0–6) of logic ship as tested SwiftPM targets under `Packages/TidyKit`
> — **184 unit tests, 0 failures**, ~82% line coverage — covering capture, the read-only Productive
> mirror, Fathom/Calendar/Slack ingest, the classification ladder, the suggestion engine, and the
> metered AI router. The macOS app target in `App/` is **still the Phase-0 placeholder**: it renders
> a static menu-bar item and does not yet host those modules, so `make run` launches a shell, not the
> product. Live OS/TCC, OAuth, and cloud paths are compile-only here and verified manually on a Mac.
> Start at **[docs/RUNNING.md](docs/RUNNING.md)** · review history in
> [docs/PROJECT-REVIEW.md](docs/PROJECT-REVIEW.md).

## Why it exists

The billable time you forget is the time that never got captured: the 15 client minutes inside
an hour-long colleague call, the drive-by Slack DMs, the block you'd have misremembered a week
later. TidyTime's job is to surface exactly that, with enough context that logging it is a
copy-paste.

## How it works (one screen)

```
CAPTURE (local)                 INGEST (read-only APIs)
 app & window watcher            Productive  · Fathom
 Chrome URL/title/text           Google Calendar · Slack
 idle / away · meeting state
        └──────────────┬─────────────────┘
                       ▼
        STORE — SQLite (GRDB) + Keychain
                       ▼
        UNDERSTAND — sessionize · resolve entities ·
        classification ladder (rules → lexical → on-device
        → economy cloud → escalation) · sensitivity gate
                       ▼
        SUGGEST — round · pool micro-work · split meetings ·
        gap-analyze vs. what's already logged
                       ▼
        SURFACE — menu bar · nudges · end-of-day recap ·
        dashboard · settings
```

Everything runs in one menu bar process. Sensitive content (personnel, comp, legal) never
leaves the machine. Every cloud AI call is metered and budget-capped. Full architecture:
[docs/architecture/overview.md](docs/architecture/overview.md).

## Repository layout

| Path | What |
|---|---|
| [PLAN.md](PLAN.md) | The canonical vision & scope (source of truth) |
| [CLAUDE.md](CLAUDE.md) | Orchestration brief + prime directives (loaded by Claude Code) |
| [docs/](docs/README.md) | All reference, architecture, phase, and decision docs |
| `project.yml` | XcodeGen spec for the app target |
| `App/` | Thin app shell (`@main`, Info.plist, entitlements) |
| `Packages/TidyKit/` | All logic, as SwiftPM library targets |
| `config.example.json` | Non-secret config template (copy to `config.json`) |

## Getting started (developer)

**Prerequisites:** macOS 14+ (macOS 26 + Apple Intelligence unlocks the on-device model rung),
Xcode 16+, [Homebrew](https://brew.sh). Hardware floor: Apple Silicon (M2 or newer).

```bash
make bootstrap                             # installs XcodeGen, generates TidyTime.xcodeproj
cp Local.xcconfig.example Local.xcconfig   # then set DEVELOPMENT_TEAM (a free Apple ID works)
cp config.example.json config.json         # non-secret settings; edit as needed
make build                                 # build the app
make run                                   # build + launch (icon appears in the menu bar)
make test                                  # run the TidyKit unit tests
```

**Important — stable signing.** macOS ties Accessibility/Automation permission grants to the
code signature. Sign with a **stable identity** (personal team) so grants survive rebuilds; an
ad-hoc or rotating signature silently drops them. See
[docs/build/signing-and-tcc.md](docs/build/signing-and-tcc.md). One-time human setup
(permissions, tokens, OAuth): [docs/permissions-setup.md](docs/permissions-setup.md).

## Build phases

Capture-first and strictly ordered; each phase ends in something usable with a human-verifiable
acceptance check.

0. [Skeleton](docs/phases/phase-0-skeleton.md) — menu bar, DB, config, signing
1. [Capture](docs/phases/phase-1-capture.md) — watcher, Chrome, idle, sessionization
2. [Productive mirror](docs/phases/phase-2-productive.md) — read-only sync
3. [Meetings & calendar](docs/phases/phase-3-meetings-calendar.md) — Fathom, Google
4. [Slack](docs/phases/phase-4-slack.md) — DM/channel ingest
5. [Recap & rules](docs/phases/phase-5-recap-rules.md) — suggestion engine + recap UI
6. [Intelligence](docs/phases/phase-6-intelligence.md) — gate, on-device, cloud router, ledger, nudges

## Guarantees

- **Read-only against Productive.** No write call exists in v1.
- **Sensitivity gate fails closed.** Personnel/comp/legal content never reaches a cloud model.
- **No Screen Recording permission** is requested — window titles come from Accessibility.
- **Secrets in Keychain only**; local data stays on one Mac, purged on a retention schedule.

Details and enforcement: [docs/guardrails.md](docs/guardrails.md).

## License

Private / internal (4Site Studios). Not for redistribution.
