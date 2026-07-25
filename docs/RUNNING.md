# Running TidyTime — what was built, and how to get it going

**Describes commit `ec1beb2`+ · 194 tests passing · 2026-07-25.**
If `HEAD` is newer than that, re-verify before trusting the numbers below — regenerate them with
`make test` and `make coverage` rather than copying them forward.

> This doc owns **sequence and state**: what exists, and the order to do things in. The linked docs
> own **detail**. If a step here starts restating click paths, it has drifted — trim it.

## Read this if…

- **You're setting up a Mac** → jump to [Runbook](#runbook--zero-to-running).
- **You want to know what actually exists** → [What was built](#what-was-built) and, more importantly,
  [What is NOT verified](#what-is-not-verified).
- **You're an AI session picking this up cold** → read [CLAUDE.md](../CLAUDE.md), then
  [DECISIONS.md](../DECISIONS.md) (append-only log of choices, fixes, and abandoned approaches),
  then the phase doc you're working in.

## What was built

Seven phases, each shipped with tests and a retrospective, then five post-v1 enhancements.

| Phase | Theme | What shipped | Doc |
|---|---|---|---|
| 0 | Test & debug infrastructure | Config + loader, Keychain `SecretStore`, `Redactor`, dual-sink structured logging (os.Logger + rotating JSONL), the redacted **diagnostic bundle** + clipboard seam, GRDB `AppDatabase` + migrator | [phase-0](phases/phase-0-skeleton.md) · [retro](retrospectives/phase-0.md) |
| 1 | Capture | `activity_samples`/`page_snapshots`/`sessions`/`away_gaps`, `ContextKey`, `PageTextPolicy` (truncate + hash dedup), `Sessionizer` (detour absorption, min-session floor), `AwayGapDetector`, `RetentionJob` | [phase-1](phases/phase-1-capture.md) · [retro](retrospectives/phase-1.md) |
| 2 | Productive mirror | Reusable HTTP layer + `Backoff`, JSON:API decoder, **GET-only** request builder (G1), paginating client, `ProductiveSync`, deep links | [phase-2](phases/phase-2-productive.md) · [retro](retrospectives/phase-2.md) |
| 3 | Meetings & calendar | Fathom client/mapper/sync (recording-span duration, idempotent re-sync), Google Calendar client/sync (`syncToken`, `is_external`), away-gap resolution | [phase-3](phases/phase-3-meetings-calendar.md) · [retro](retrospectives/phase-3.md) |
| 4 | Slack | `LiveSlackClient` (cursor pagination, `ok:false` surfacing), `SlackSessionizer`, per-conversation cursors, `is_self` detection | [phase-4](phases/phase-4-slack.md) · [retro](retrospectives/phase-4.md) |
| 5 | Recap & rules | Classification rungs 1–2, entity resolution + learning loop, sensitivity gate, suggestion engine (rounding, pools, meeting split, gap analysis, new-task), recap read-model | [phase-5](phases/phase-5-recap-rules.md) · [retro](retrospectives/phase-5.md) |
| 6 | Intelligence | Metered `AIRouter` (gate → budget → dispatch → ledger), Fireworks/Anthropic/on-device providers, `BudgetPolicy`, `NoteDrafter`, `NudgeEngine`, AI-overhead dashboard + CSV | [phase-6](phases/phase-6-intelligence.md) · [retro](retrospectives/phase-6.md) |

| Enhancement | Commit | What changed |
|---|---|---|
| Tiered change-gated capture | `294ef0d` | Fast detection tick (default 1 s) + slow page-text tick; a sample is written only when the context signature changes |
| Context-switching metric | `bf5463f` | Switches/hr, dwell, brief-switch fragmentation, longest focus — from the raw sample stream; persisted daily |
| Fireworks-only AI routing | `bf5463f` | Economy **and** escalation on one vendor ([ADR 0013](decisions/0013-all-cloud-inference-through-fireworks.md)) |
| Finer within-app attribution | `546fde7` | Title-discriminated grouping + page text into rung 2 |
| Chat separation by URL path | `dcffdac` | Same-title chats become distinct sessions |

Architecture: [overview](architecture/overview.md) · [module map](architecture/module-map.md) ·
[data model](architecture/data-model.md). Guardrails: [guardrails.md](guardrails.md) (G1–G9).

## Current state (verified)

| | | Produced by |
|---|---|---|
| **194 unit tests, 0 failures** | | `cd Packages/TidyKit && swift test` |
| **64.3% line coverage** on `Sources/` | ~90% on the testable core; the rest is SwiftUI + live-OS code that can't run headlessly | `make coverage` |
| **8 SwiftPM library targets** + 1 app target | | `Package.swift` |
| **9 guardrails**, each backed by a test | | [guardrails.md](guardrails.md) |
| **9 migrations** `v1-core` … `v2-page-snapshot-time-index` | additive; upgrade path tested | [data-model.md](architecture/data-model.md#registered-migrations-as-shipped) |
| **2 independent review rounds**, 64 findings | all HIGH/MED fixed | [PROJECT-REVIEW.md](PROJECT-REVIEW.md) |

## What is NOT verified

Read this before trusting anything above. It is the difference between "tested library" and
"working product".

- **The app is wired but has never been RUN.** `App/TidyTimeApp.swift` now constructs
  `AppEnvironment` and hosts the full surface, and the code **type-checks against the real SDK**
  (`make typecheck-app`) — but nobody has launched it, granted it a permission, or seen a window.
  You will be the first.
- ⚠️ **`xcodebuild` is broken on the development machine**, so no `.app` or `.dmg` has ever been
  produced. A stale `/Library/Developer/PrivateFrameworks/DVTDownloads.framework` (Jan 2026) doesn't
  match Xcode 26.6. **Fix: `sudo xcodebuild -runFirstLaunch`** (needs your password). Until then
  `make build` / `make run` / `make dmg` will fail before compiling anything — `make typecheck-app`
  is the workaround that proves the code itself is sound.
- **Every SwiftUI / AppKit / OS-integration path is compile-only.** No test exercises the timers,
  `NSWorkspace` observers, Accessibility reads, AppleScript, or any view.
- **No live API call has ever been made from this repo.** Productive, Fathom, Google, Slack, Fireworks
  and Anthropic clients are all tested against **recorded fixtures**.
- **TCC (Accessibility, Automation, Notifications), Google OAuth, the Slack app install, and the
  on-device Foundation Models rung require a real Mac** (+ macOS 26 and Apple Intelligence for rung 3)
  and are verified **manually**.
- **Model slugs and prices in `config.example.json` are placeholders** — see its `_build_time_checks`.
- **Performance targets are targets, not measurements.** The "~2% CPU" figure has never been measured.

## Runbook — zero to running

Each step says how you'll know it worked. Detail lives in the linked docs.

**1 · Prerequisites.** macOS 14+ (macOS 26 + Apple Intelligence for the on-device rung), Apple
Silicon (M2+), Xcode 16+, Homebrew, and an Apple ID (a **free** Personal Team is enough — no paid
Developer Program). → [build/environment-setup.md](build/environment-setup.md)

**2 · Generate the project.**
```bash
make bootstrap
```
✔ Installs XcodeGen if needed and produces `TidyTime.xcodeproj`.

**3 · Signing — do this BEFORE granting any permission.** macOS ties Accessibility/Automation grants
to the **code signature**, so an unstable signature silently revokes everything you grant.
```bash
cp Local.xcconfig.example Local.xcconfig   # then set DEVELOPMENT_TEAM
```
✔ `codesign -dv --verbose=2 <built app>` shows a stable Team ID across rebuilds.
→ [build/signing-and-tcc.md](build/signing-and-tcc.md) · guardrail **G7**

**4 · Config.**
```bash
cp config.example.json config.json
```
Set `organization.*` (Productive org + person id) and `google.*`; review `capture.*`
(`detection_interval_seconds`, `content_interval_seconds`, `separate_chats_by_path`,
`identity_query_keys`) and `ai.*`. Resolve the entries listed in `_build_time_checks`.
**No secrets here** — tokens live in the Keychain (**G6**).

**5 · Build and run.**
```bash
make typecheck-app     # proves App/ compiles even if xcodebuild is unhealthy
make build && make run
```
✔ A menu-bar icon appears; clicking it shows today's observed/logged totals and opens Recap,
Dashboard, Settings, and Doctor. **Open Doctor first** — it shows live permission status and has the
one-click *Copy diagnostics* button.
⚠️ If `xcodebuild` errors about a plug-in before compiling, run `sudo xcodebuild -runFirstLaunch`
(see [What is NOT verified](#what-is-not-verified)).

**6 · Grant permissions** (in order): Accessibility → Automation (Chrome + System Events) → Chrome's
*View → Developer → Allow JavaScript from Apple Events* → Notifications. Screen Recording is **never**
requested (**G3**). → [permissions-setup.md](permissions-setup.md) §§1–5 (11 steps, ~30 min)

**7 · Tokens & OAuth.** Productive personal token + org id · Fathom API key · Slack internal app
(manifest → install → user token) · Google **Internal**-type OAuth client → sign in once · Fireworks
key (Anthropic optional, only if you switch `ai.routing.escalation` to the direct path).
All land in the **Keychain**. → [permissions-setup.md](permissions-setup.md) §§6–10 ·
billing decision in [open-items.md](open-items.md)

**8 · Verify.**
```bash
make doctor      # paths + permission status
make test        # 184 tests
make coverage    # per-file coverage
make lint        # documentation links resolve
```
Then walk the per-phase manual acceptance checks and the final-acceptance table in
[permissions-setup.md](permissions-setup.md).

**Troubleshooting:** [build/environment-setup.md](build/environment-setup.md) (gotchas) ·
[build/signing-and-tcc.md](build/signing-and-tcc.md) (`tccutil reset` to re-test a first run).

## Make targets

| Target | Does |
|---|---|
| `bootstrap` | Install XcodeGen + generate the project |
| `generate` | Regenerate `TidyTime.xcodeproj` from `project.yml` (after adding files) |
| `build` / `run` | Build / build + launch the app |
| `test` | `swift test` over TidyKit |
| `coverage` | Tests + per-file llvm-cov report for `Sources/` |
| `typecheck-app` | Compile-check `App/` against the SDK without xcodebuild |
| `dmg` | Release build packaged as `dist/TidyTime.dmg` |
| `doctor` | Print config/DB paths |
| `lint` | Verify relative documentation links resolve |
| `clean` | Remove generated project + build artifacts |

## Where to go next

[CLAUDE.md](../CLAUDE.md) (rules + repo map) · [DECISIONS.md](../DECISIONS.md) (why things are the
way they are) · [PLAN.md](../PLAN.md) (canonical vision) · [docs/README.md](README.md) (full index) ·
[PROJECT-REVIEW.md](PROJECT-REVIEW.md) (both review rounds) ·
[retrospectives/](retrospectives/README.md) · [open-items.md](open-items.md) (unresolved questions).
