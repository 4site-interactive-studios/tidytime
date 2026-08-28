# Environment setup

Everything a fresh machine (or a fresh Claude Code session) needs to go from `git clone` to a
running menu bar app: prerequisites, the one-time bootstrap, and how the SwiftPM package and the
XcodeGen-generated app fit together.

**Related:** [../README.md](../README.md) (doc index) · [signing-and-tcc.md](signing-and-tcc.md) ·
[xcodegen-spec.md](xcodegen-spec.md) · [testing-strategy.md](testing-strategy.md) ·
[../../PLAN.md](../../PLAN.md) §11

**Status:** build-ready · **Applies to:** Phase 0 onward · **Last verified:** 2026-07-23

---

## 1. Prerequisites

| Requirement | Minimum | Why | Verify |
|---|---|---|---|
| macOS | **14.0** (Sonoma) | app deployment target (`project.yml` → `deploymentTarget.macOS: "14.0"`) | `sw_vers -productVersion` |
| macOS + Apple Intelligence | **26** with Apple Intelligence **on** | on-device model rung 3 (Apple Foundation Models); **optional** — the ladder skips rung 3 if absent | System Settings → Apple Intelligence & Siri |
| Xcode | **16+** (ships Swift 6) | `SWIFT_VERSION = 6.0` / `swift-tools-version:6.0`; builds the `.app` | `xcodebuild -version` |
| Command Line Tools | matching Xcode | `xcodebuild`, `swift`, `codesign` | `xcode-select -p` |
| Homebrew | any current | installs XcodeGen | `brew --version` |
| XcodeGen | **2.40+** | generates `TidyTime.xcodeproj` from `project.yml` | `xcodegen --version` |

Notes:
- macOS 14 is the **floor**; rung 3 (`TidyAI` on-device) is gated to macOS 26 + Apple Intelligence
  **at runtime**, so the app builds and runs on 14–25 without it (falls through to the cloud rungs).
  See [../reference/apple-foundation-models.md](../reference/apple-foundation-models.md).
- ⚠️ **Build-time check:** confirm the installed Xcode's default toolchain is Swift 6. If
  `xcodebuild -version` reports Xcode < 16, the `SWIFT_VERSION = 6.0` build settings will not compile
  the strict-concurrency code in `TidyKit` ([../conventions/swift-style.md](../conventions/swift-style.md)).
- **Select Xcode** if multiple are installed: `sudo xcode-select -s /Applications/Xcode.app`.
- No **paid** Apple Developer Program membership is required. A free Apple ID "Personal Team" is
  enough to sign a locally-run app — see [signing-and-tcc.md](signing-and-tcc.md).

## 2. Repo layout you'll touch during setup

```
tidytime/
├─ Makefile                 # the only entry point you run — targets below
├─ project.yml              # XcodeGen spec → TidyTime.xcodeproj (generated, gitignored)
├─ Signing.xcconfig         # committed signing base; #include? "Local.xcconfig"
├─ Local.xcconfig.example   # copy → Local.xcconfig (gitignored), set DEVELOPMENT_TEAM
├─ config.example.json      # copy → config.json (gitignored); NON-SECRET settings only
├─ App/                     # thin app shell: TidyTimeApp.swift, Info.plist, entitlements
└─ Packages/TidyKit/        # all logic as SwiftPM library targets (TidyCore … TidySurface)
```

Generated / never-committed (already in `.gitignore`): `TidyTime.xcodeproj/`, `.build/`,
`config.json`, `Local.xcconfig`, `*.sqlite*`, `outbound-payloads*.log`. Secrets are **never** in
files — they live in the Keychain (guardrail [G6](../guardrails.md#g6--secrets-live-in-the-keychain-only)).

## 3. First-time flow

Run from the repo root. Each step maps to a `Makefile` target (§4).

```bash
# 1. Install XcodeGen (if needed) and generate the Xcode project.
make bootstrap
#    → brew install xcodegen (only if missing)
#    → make generate  (xcodegen generate → TidyTime.xcodeproj)
#    → prints: "Next: copy Local.xcconfig.example -> Local.xcconfig and set DEVELOPMENT_TEAM."

# 2. Set your signing team (one time). See signing-and-tcc.md for finding the id.
cp Local.xcconfig.example Local.xcconfig
$EDITOR Local.xcconfig            # set DEVELOPMENT_TEAM = <your 10-char Personal Team id>

# 3. Seed non-secret config. The app reads it from Application Support at runtime (see note).
cp config.example.json config.json
$EDITOR config.json               # set organization.productive_organization_id, timezone, etc.

# 4. Build / run / test.
make build                        # xcodebuild the app bundle (Debug)
make run                          # build, then `open` TidyTime.app → icon appears in the menu bar
make test                         # swift test in Packages/TidyKit (no signing, no network)
```

After `make run` the menu bar shows the clock/checkmark icon (`MenuBarExtra`). Because the app is
`LSUIElement` (agent, no Dock icon — [xcodegen-spec.md](xcodegen-spec.md)), the **only** UI is that
menu bar item. First launch triggers the permission prompts (Accessibility, then Automation on first
Chrome access) — see [../reference/macos-permissions-tcc.md](../reference/macos-permissions-tcc.md).

**Where `config.json` actually lives at runtime.** The running app reads
`~/Library/Application Support/TidyTime/config.json` (the path `make doctor` prints). Phase 0's config
plumbing seeds that file from the bundled `config.example.json` on first launch and creates the
Application Support directory ([phase-0-skeleton](../phases/phase-0-skeleton.md), App shell
`TidyTimeApp.swift`). Until that lands — or to override it for local dev — copy it there yourself:

```bash
mkdir -p "$HOME/Library/Application Support/TidyTime"
cp config.json "$HOME/Library/Application Support/TidyTime/config.json"
```

⚠️ **Build-time check:** the exact first-run seed-vs-manual-copy behavior is a Phase 0 implementation
detail; confirm against `TidyTimeApp.swift` / the Config loader in `TidyCore` when Phase 0 is built.
The repo-root `config.json` copy (step 3) keeps a readable, editable template beside the example even
if the app loads from Application Support.

## 4. Makefile targets (the terminal-drivable build)

The `Makefile` is the single interface; everything is driftable from the terminal (the Claude Code
workflow). Defaults: `CONFIG ?= Debug`, `DERIVED := .build/dd`, `PROJECT := TidyTime.xcodeproj`,
`SCHEME := TidyTime`.

| Target | Does | Underlying command |
|---|---|---|
| `make bootstrap` | install XcodeGen (if missing) + generate the project | `brew install xcodegen` then `make generate` |
| `make generate` | (re)generate `TidyTime.xcodeproj` from `project.yml` | `xcodegen generate` |
| `make build` | generate, then build the app bundle | `xcodebuild -project … -scheme TidyTime -configuration Debug -derivedDataPath .build/dd build` |
| `make run` | build, then launch | `open ".build/dd/Build/Products/Debug/TidyTime.app"` |
| `make test` | run TidyKit unit tests (fast, no signing) | `cd Packages/TidyKit && swift test` |
| `make package-test` | alias for `make test` | — |
| `make doctor` | print config + DB paths (run the app for live TCC status) | echoes the two paths under `~/Library/Application Support/TidyTime/` |
| `make lint` | verify internal doc links resolve | `bash scripts/check-doc-links.sh` |
| `make clean` | remove generated project + build output | `rm -rf .build/dd TidyTime.xcodeproj` |

- `make build` depends on `generate`, so it re-runs XcodeGen every build — new source files are always
  picked up. You only need a bare `make generate` when regenerating without building (e.g. to open the
  project in Xcode).
- `make test` runs against the **SwiftPM package directly** (`swift test`) — no Xcode project, no
  signing, no network. That's the fast inner loop for `TidyKit` logic and the guardrail tests
  ([testing-strategy.md](testing-strategy.md)).
- `make doctor` only prints on-disk paths; **live** permission status comes from the in-app *doctor*
  view (Phase 0 acceptance criterion — [../../PLAN.md](../../PLAN.md) §11).

## 5. How the SwiftPM package and the XcodeGen app fit together

Two build systems, one dependency edge — deliberate:

```
Packages/TidyKit  (SwiftPM package)              App/  (Xcode app target, via XcodeGen)
────────────────────────────────────            ───────────────────────────────────────
Package.swift declares 8 library products        project.yml declares ONE target: TidyTime
  TidyCore  TidyStore  TidyCapture                  type: application, sources: [App]
  TidyIngest  TidyUnderstand  TidyAI                 INFOPLIST_FILE, CODE_SIGN_ENTITLEMENTS
  TidySuggest  TidySurface                           LSUIElement, Hardened Runtime, signing
  (+ GRDB dependency)                                depends on package: TidyKit → all 8 products
        ▲                                                        │
        └──────────────── app links all 8 library products ─────┘
```

- **All logic** lives in `TidyKit` library targets and is testable with plain `swift test` — no app
  bundle, no signing, no Xcode. This is why the inner loop is fast.
- **The Xcode app target exists only** for what SwiftPM can't express: the `Info.plist` (bundle id,
  `LSUIElement`, `NSAppleEventsUsageDescription`), the entitlements
  (`com.apple.security.automation.apple-events`), Hardened Runtime, and a **stable code signature**.
  See [../decisions/0005-swift-swiftui-xcodegen-swiftpm.md](../decisions/0005-swift-swiftui-xcodegen-swiftpm.md).
- **XcodeGen maps folders to targets.** Adding a Swift file under `App/` or under any
  `Packages/TidyKit/Sources/<Target>/` directory means you must **`make generate`** (or `make build`,
  which generates first) so the file is picked up. New files won't compile until the project is
  regenerated — the most common "why isn't my file building" gotcha. Full spec:
  [xcodegen-spec.md](xcodegen-spec.md).
- **Target names and dependency rules** (the graph must stay acyclic) are canonical in
  [../architecture/module-map.md](../architecture/module-map.md).

## 6. Verifying a good setup (Phase 0 acceptance)

A correctly set-up environment satisfies Phase 0's checks
([../phases/phase-0-skeleton.md](../phases/phase-0-skeleton.md), [../../PLAN.md](../../PLAN.md) §11):

- [ ] `make build` succeeds (project generates, app compiles, signs with your stable identity).
- [ ] `make run` puts the icon in the menu bar; it **survives a reboot** (launch-at-login via
      `SMAppService`).
- [ ] `make test` is green — including the guardrail tests ([testing-strategy.md](testing-strategy.md)).
- [ ] The in-app *doctor* view shows the DB path, config path, and live permission status.
- [ ] `Local.xcconfig` and `config.json` exist locally and are **not** tracked by git
      (`git status --ignored` lists them under Ignored).

## 7. Common setup gotchas

| Symptom | Cause | Fix |
|---|---|---|
| `xcodegen: command not found` | Homebrew/XcodeGen not installed | `make bootstrap` (installs it), or `brew install xcodegen` |
| Build fails with a signing / "no team" error | `Local.xcconfig` missing or `DEVELOPMENT_TEAM` still `XXXXXXXXXX` | copy the example and set your Personal Team id ([signing-and-tcc.md](signing-and-tcc.md)) |
| App runs but permissions "mysteriously" reset after a rebuild | signature changed (ad-hoc / rotating identity) | ensure a **stable** identity + fixed bundle id — [signing-and-tcc.md](signing-and-tcc.md) (G7) |
| New `.swift` file doesn't compile / isn't found | project not regenerated | `make generate` (or `make build`) — XcodeGen reads the folder tree |
| `swift test` compiles but the app won't | test path uses SwiftPM only; app needs a valid `project.yml`/signing | run `make build`; fix signing before `make run` |
| Swift 6 concurrency errors on an older Xcode | Xcode < 16 toolchain | install Xcode 16+, `xcode-select -s` it |
