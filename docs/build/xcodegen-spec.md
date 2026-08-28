# XcodeGen spec (`project.yml`)

A field-by-field walkthrough of the committed `project.yml`: how it generates `TidyTime.xcodeproj`,
how the app target consumes the `TidyKit` SwiftPM package, and the folders-map-to-targets rule that
makes `make generate` a required step after adding files.

**Related:** [../README.md](../README.md) (doc index) · [environment-setup.md](environment-setup.md) ·
[signing-and-tcc.md](signing-and-tcc.md) · [../architecture/module-map.md](../architecture/module-map.md) ·
[../decisions/0005-swift-swiftui-xcodegen-swiftpm.md](../decisions/0005-swift-swiftui-xcodegen-swiftpm.md) ·
[../../PLAN.md](../../PLAN.md) §11

**Status:** build-ready · **Generator:** XcodeGen (`xcodegen generate`) · **Output:**
`TidyTime.xcodeproj` (gitignored) · **Last verified:** 2026-07-23

---

## 1. Why XcodeGen at all

`TidyTime.xcodeproj` is a **generated artifact**, not a committed one (`.gitignore` excludes
`TidyTime.xcodeproj/`). The source of truth is the human-readable `project.yml`. This keeps the build
**terminal-drivable** (the Claude Code workflow), avoids `.pbxproj` merge conflicts, and makes the
project reproducible from a one-line `make generate`.

SwiftPM alone can't produce this app: it can't express the `Info.plist` keys (`LSUIElement`,
`NSAppleEventsUsageDescription`), the entitlements, Hardened Runtime, or the stable signing that TCC
durability needs. So the split is: **logic in a SwiftPM package** (`Packages/TidyKit`, testable with
`swift test`), **the `.app` shell via XcodeGen** (`App/`). Rationale of record:
[../decisions/0005-swift-swiftui-xcodegen-swiftpm.md](../decisions/0005-swift-swiftui-xcodegen-swiftpm.md).

## 2. The full committed spec

```yaml
# project.yml — generates TidyTime.xcodeproj (gitignored). Run `make generate`.
name: TidyTime

options:
  bundleIdPrefix: com.4site
  deploymentTarget:
    macOS: "14.0"
  createIntermediateGroups: true
  generateEmptyDirectories: true

configs:
  Debug: debug
  Release: release

configFiles:
  Debug: Signing.xcconfig
  Release: Signing.xcconfig

settings:
  base:
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
    SWIFT_VERSION: "6.0"
    ENABLE_HARDENED_RUNTIME: YES
    PRODUCT_BUNDLE_IDENTIFIER: com.4site.TidyTime

packages:
  TidyKit:
    path: Packages/TidyKit

targets:
  TidyTime:
    type: application
    platform: macOS
    sources:
      - App
    settings:
      base:
        INFOPLIST_FILE: App/Info.plist
        CODE_SIGN_ENTITLEMENTS: App/TidyTime.entitlements
        PRODUCT_NAME: TidyTime
    dependencies:
      - package: TidyKit
        products:
          - TidyCore
          - TidyStore
          - TidyCapture
          - TidyIngest
          - TidyUnderstand
          - TidyAI
          - TidySuggest
          - TidySurface

schemes:
  TidyTime:
    build:
      targets:
        TidyTime: all
    run:
      config: Debug
    test:
      config: Debug
```

## 3. Section-by-section

### `options`

| Key | Value | Meaning |
|---|---|---|
| `bundleIdPrefix` | `com.4site` | default prefix for generated bundle ids (the app id is set explicitly, so this mainly documents the namespace) |
| `deploymentTarget.macOS` | `"14.0"` | the app's floor — matches `Packages/TidyKit` `platforms: [.macOS(.v14)]`. The macOS 26 on-device rung is a **runtime** gate, not a build-time bump |
| `createIntermediateGroups` | `true` | Xcode groups mirror the on-disk folder nesting (readable project navigator) |
| `generateEmptyDirectories` | `true` | keeps empty source dirs represented, so a new empty target folder still appears |

### `configs`

Maps the two build configurations to their base type: `Debug → debug`, `Release → release`. Standard;
`make build` uses `Debug` by default (`CONFIG ?= Debug` in the `Makefile`).

### `configFiles` → `Signing.xcconfig`

```yaml
configFiles:
  Debug: Signing.xcconfig
  Release: Signing.xcconfig
```

Both configurations pull signing from the **committed** `Signing.xcconfig`, which itself does
`#include? "Local.xcconfig"` (optional) to layer in the machine-local `DEVELOPMENT_TEAM`. This is how
the app gets a **stable code signature** (fixed bundle id + Personal Team) so macOS doesn't revoke TCC
grants on rebuild. Full mechanism and the "why it must be stable" argument:
[signing-and-tcc.md](signing-and-tcc.md) (guardrail
[G7](../guardrails.md#g7--stable-code-signature-tcc-durability)).

### `settings.base`

| Setting | Value | Why it's here |
|---|---|---|
| `MARKETING_VERSION` | `"0.1.0"` | `CFBundleShortVersionString` (via `$(MARKETING_VERSION)` in `Info.plist`) |
| `CURRENT_PROJECT_VERSION` | `"1"` | `CFBundleVersion` |
| `SWIFT_VERSION` | `"6.0"` | Swift 6 language mode (matches `swift-tools-version:6.0`) — needs Xcode 16+ |
| `ENABLE_HARDENED_RUNTIME` | `YES` | required by the stable-signing / Apple-Events story; the `com.apple.security.automation.apple-events` entitlement attaches to it ([signing-and-tcc.md](signing-and-tcc.md) §4) |
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.4site.TidyTime` | the fixed bundle id — **also** set in `Signing.xcconfig`; both must agree (it's half the designated requirement TCC keys on) |

### `packages` — the local SwiftPM package

```yaml
packages:
  TidyKit:
    path: Packages/TidyKit
```

Declares `TidyKit` as a **local** Swift package by path. XcodeGen resolves it from `Package.swift`,
which exposes eight library **products** (`TidyCore`, `TidyStore`, `TidyCapture`, `TidyIngest`,
`TidyUnderstand`, `TidyAI`, `TidySuggest`, `TidySurface`) plus the transitive GRDB dependency. The app
depends on the **products**; the internal target graph and its acyclic dependency rules live in
[../architecture/module-map.md](../architecture/module-map.md).

### `targets.TidyTime` — the app shell

```yaml
targets:
  TidyTime:
    type: application
    platform: macOS
    sources:
      - App                       # ← folder maps to target (see §4)
    settings:
      base:
        INFOPLIST_FILE: App/Info.plist
        CODE_SIGN_ENTITLEMENTS: App/TidyTime.entitlements
        PRODUCT_NAME: TidyTime
    dependencies:
      - package: TidyKit
        products: [ TidyCore, TidyStore, TidyCapture, TidyIngest,
                    TidyUnderstand, TidyAI, TidySuggest, TidySurface ]
```

- **`type: application` / `platform: macOS`** — a real `.app` bundle.
- **`sources: [App]`** — the target compiles **everything under `App/`**: `TidyTimeApp.swift` (the
  `@main` `MenuBarExtra` scene), and the `Info.plist` / entitlements are referenced by the settings
  below. The `App/` folder is intentionally thin — just the shell; **all logic is in `TidyKit`**.
- **`INFOPLIST_FILE: App/Info.plist`** — supplies bundle metadata and, critically:
  - **`LSUIElement = true`** → the app is a **menu bar agent**: no Dock icon, no default window. The
    `MenuBarExtra` item is the whole UI. (Set in `Info.plist`, not `project.yml`.)
  - **`NSAppleEventsUsageDescription`** → the purpose string macOS shows in the Automation prompt.
  - `CFBundleIdentifier = $(PRODUCT_BUNDLE_IDENTIFIER)`, versions from `$(MARKETING_VERSION)` /
    `$(CURRENT_PROJECT_VERSION)`, `LSMinimumSystemVersion = $(MACOSX_DEPLOYMENT_TARGET)`.
- **`CODE_SIGN_ENTITLEMENTS: App/TidyTime.entitlements`** — declares
  `com.apple.security.automation.apple-events = true` (send Apple Events under Hardened Runtime) and,
  by omission, **no App Sandbox** (non-sandboxed by design — [signing-and-tcc.md](signing-and-tcc.md)
  §5).
- **`dependencies` → `package: TidyKit`** — the app links **all eight** library products. This is the
  single edge from the app shell into the logic package.

### `schemes.TidyTime`

```yaml
schemes:
  TidyTime:
    build:  { targets: { TidyTime: all } }
    run:    { config: Debug }
    test:   { config: Debug }
```

One shared scheme named `TidyTime` (what `make build`/`make run` pass to `xcodebuild -scheme
TidyTime`). `run`/`test` default to `Debug`. Note that **unit tests run via `swift test` against the
package** ([testing-strategy.md](testing-strategy.md)), so the scheme's `test` config is for running
tests through Xcode/`xcodebuild` if needed, not the primary loop.

## 4. Folders map to targets → re-run `make generate` after adding files

XcodeGen builds each target's file list from the **on-disk folder tree** under its `sources` path — it
does **not** track individual files. Consequences:

- Add a `.swift` file under `App/` (app target) or under any
  `Packages/TidyKit/Sources/<Target>/` directory, and it is picked up **only after the project is
  regenerated**.
- So: **run `make generate` (or `make build`, which generates first) after adding, moving, or removing
  source files.** A "file not found in build" or "my new type won't compile" almost always means the
  project is stale.
- The same rule maps the eight `Packages/TidyKit/Sources/*` folders to the eight library targets: the
  folder name **is** the target name. Adding `Sources/TidyStore/RetentionJob.swift` puts it in
  `TidyStore` automatically on the next generate — no manual project edit.
- New **targets** (rare in v1) or new **package products** require editing `Package.swift` and/or
  `project.yml`, then `make generate`.

```bash
# After creating a new source file anywhere under App/ or Packages/TidyKit/Sources/:
make generate      # refresh TidyTime.xcodeproj from the folder tree
# or just:
make build         # generates, then builds
```

## 5. Where the pieces live

| Path | Role |
|---|---|
| `project.yml` | this spec (committed) |
| `TidyTime.xcodeproj/` | generated output (gitignored) |
| `App/TidyTimeApp.swift` | `@main` `MenuBarExtra` shell; Phase 0 wires the dependency container, DB, config/Keychain, `SMAppService`, doctor view |
| `App/Info.plist` | bundle metadata, `LSUIElement`, `NSAppleEventsUsageDescription` |
| `App/TidyTime.entitlements` | `com.apple.security.automation.apple-events`; no sandbox |
| `Signing.xcconfig` (+ `Local.xcconfig`) | stable signing (G7) — [signing-and-tcc.md](signing-and-tcc.md) |
| `Packages/TidyKit/Package.swift` | the eight library targets + GRDB — [../architecture/module-map.md](../architecture/module-map.md) |

The app shell holds **only** the scene and wiring; the logic lives in `TidyKit`. Keep it that way:
new features belong in a `TidyKit` target and reach the app through its product dependency, not in
`App/`.

## 6. Gotchas

- **Stale project** — the #1 issue. Adding files without `make generate` → "not found"/won't compile.
- **Bundle id drift** — `PRODUCT_BUNDLE_IDENTIFIER` is set in **both** `project.yml` and
  `Signing.xcconfig`; if they ever disagree, the signature's designated requirement changes and TCC
  grants drop (G7). Keep them identical at `com.4site.TidyTime`.
- **`LSUIElement` lives in `Info.plist`, not `project.yml`** — don't "fix" a missing Dock icon by
  removing it; the Dock-less agent is intended.
- **Deployment target vs. runtime gate** — don't raise `deploymentTarget` to macOS 26 for the
  on-device rung; that rung is gated at runtime so the app still builds/runs on macOS 14–25.
- ⚠️ **Build-time check:** confirm the installed **XcodeGen** version parses `configFiles` and
  `packages` as written (2.40+ does). If `make generate` errors on a key, check `xcodegen --version`.
