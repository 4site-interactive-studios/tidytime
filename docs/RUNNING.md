# Running TidyTime — what was built, and how to get it going

**Describes commit `fc269e0` · 347 tests passing (`make test` regenerates) · 2026-08-28.**
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
| **347 unit tests, 0 failures** | | `make test` |
| **64.25% line / 68.34% region coverage** on `Sources/` | measured 2026-08-28; the shortfall is SwiftUI + live-OS code that can't run headlessly | `make coverage` |
| **8 SwiftPM library targets** + 1 app target | | `Package.swift` |
| **9 guardrails**, each backed by a test | | [guardrails.md](guardrails.md) |
| **9 migrations** `v1-core` … `v2-page-snapshot-time-index` | additive; upgrade path tested | [data-model.md](architecture/data-model.md#registered-migrations-as-shipped) |
| **3 independent review rounds**, 96 findings | all HIGH + actionable MED/LOW fixed | [PROJECT-REVIEW.md](PROJECT-REVIEW.md) |

## What is NOT verified

Read this before trusting anything above. It is the difference between "tested library" and
"working product".

- **The app HAS run live** (2026-07-25→27, one Mac): signed dmg installed, Accessibility/Automation
  granted and persisting across rebuilds, capture banking real sessions with window titles,
  credentials stored via the Settings UI, and live **Slack + Fathom** syncs exercised — including
  surviving their first-run failure modes (unbounded history, 429 loops), which the app's own
  diagnostics caught. What live use has NOT touched yet:
  - **The Google sign-in click.** The flow is end-to-end tested against a real localhost socket
    with a simulated browser and token endpoint, but no human has completed it against real Google.
  - **Productive live sync** (waiting on the org id in config), **the cloud AI rungs** (no live
    Fireworks/Anthropic call yet), the recap/dashboard/nudge surfaces under real use.
- **Unit tests still exercise no SwiftUI view directly** — views render tested pure logic
  (`DoctorTips`, `CredentialCatalog`, readiness); rendering itself is verified by using the app.
- **API clients are tested against recorded fixtures**; Slack/Fathom have now also run live, the
  others have not.
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
to the **code signature**, so an unstable (ad-hoc) signature means grants never stick — System
Settings shows the toggle ON while the app still reads "not granted". This is not hypothetical; it
happened on the first real install.

You need a signing identity, which requires an Apple ID in Xcode (free — **no paid Developer
Program**):

1. **Xcode → Settings (⌘,) → Accounts → "+" → Apple ID** → sign in
2. Your name appears with a team called **"(Personal Team)"** — that's enough
3. Then:
```bash
bash scripts/find-team-id.sh   # finds your team id and writes Local.xcconfig
```
`make dmg` refuses to run if `DEVELOPMENT_TEAM` is still the placeholder, rather than quietly
producing an ad-hoc build. Doctor also reports the running app's signature, so an ad-hoc build
announces itself.

*No Apple ID at all?* A **self-signed** code-signing certificate (Keychain Access → Certificate
Assistant → Create a Certificate → type "Code Signing") also gives a stable identity; set
`CODE_SIGN_IDENTITY` to its name in `Local.xcconfig`.
✔ `codesign -dv --verbose=2 <built app>` shows a stable Team ID across rebuilds.
→ [build/signing-and-tcc.md](build/signing-and-tcc.md) · guardrail **G7**

**4 · Config.** Nothing to copy. The app writes a starter config on first launch and never
overwrites it:

```bash
open "$HOME/Library/Application Support/TidyTime/config.json"   # exists after the first launch
```

Note the location: the runtime file lives in **Application Support**, not the repo. A
`config.json` in the repo root is read by nothing (earlier revisions of this doc said to copy one
there — it never took effect).

Set `organization.productive_organization_id` + `productive_org_slug` and `google.client_id`.
Every key you leave out uses the compiled default, so the starter file is deliberately short;
[config.example.json](../config.example.json) is the full reference for what else can be tuned
(`capture.*`, `ai.*`, and the entries listed in its `_build_time_checks`). Copy a block out of it
into your config.json when you actually want to change that block — the starter omits `ai.*` on
purpose, because the example's model slugs are unverified and its null Claude prices would log
`$0` and disable that model's budget cap.
**No secrets here** — tokens live in the Keychain (**G6**).

**5 · Build and run.**
```bash
make build && make run
```
If `xcodebuild` fails to load a plug-in before compiling anything, run `xcodebuild -runFirstLaunch`
(it reinstalls stale system components; it worked here **without** sudo). `make typecheck-app`
compiles `App/` without xcodebuild if you need to isolate a code problem from a toolchain one.
✔ A menu-bar icon appears; clicking it shows today's observed/logged totals and opens Recap,
Dashboard, Settings, and Doctor. **Open Doctor first** — it shows live permission status and has the
one-click *Copy diagnostics* button.
**Packaging:** `make dmg` produces `dist/TidyTime.dmg` (needs `Local.xcconfig`). To try it before
setting a team id: `ALLOW_UNSIGNED=1 make dmg` → `dist/TidyTime-UNSIGNED-PREVIEW.dmg`. Either way the
build is unnotarized, so first launch needs right-click → **Open** (or
`xattr -d com.apple.quarantine /Applications/TidyTime.app`).

**6 · Grant permissions** (in order): Accessibility → Automation (Chrome + System Events) → Chrome's
*View → Developer → Allow JavaScript from Apple Events* → Notifications. Screen Recording is **never**
requested (**G3**). → [permissions-setup.md](permissions-setup.md) §§1–5 (11 steps, ~30 min)

**7 · Tokens & OAuth.** Productive personal token + org id · Fathom API key · Slack internal app
(manifest → install → user token) · Google **Internal**-type OAuth client → then click **Sign in
with Google** in Settings → Credentials (opens the browser, captures the redirect on localhost,
stores the refresh token; the Credentials tab walks every key step-by-step in plain language) ·
Fireworks key (Anthropic optional, only if you switch `ai.routing.escalation` to the direct path).
All land in the **Keychain**. A set key is locked until removed, and removal asks first.
→ [permissions-setup.md](permissions-setup.md) §§6–10 · billing decision in [open-items.md](open-items.md)

**8 · Verify.**
```bash
make doctor      # paths + permission status
make test        # 347 tests
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
