# 0005 — Swift/SwiftUI, XcodeGen shell + SwiftPM TidyKit

TidyTime is Swift 6 / SwiftUI; the build is a thin XcodeGen-generated app shell wrapping a local
SwiftPM package (`TidyKit`) that holds all logic.

Related: [README.md](README.md) · [../architecture/module-map.md](../architecture/module-map.md) ·
[../../CLAUDE.md](../../CLAUDE.md) · [0009](0009-stable-signing-for-tcc.md)

**Status:** Accepted · **Date:** 2026-07-23

## Context

The app is a native macOS menu-bar tool that needs Accessibility, Apple Events, Notifications, the
on-device Foundation Models framework, and `MenuBarExtra` — all first-class only in Swift/SwiftUI
(PLAN §2). It is built by one person driving Claude Code, so the whole build must be
**terminal-drivable** and diff-friendly. Two structural facts collide: SwiftPM gives clean,
testable, dependency-ruled library targets but **cannot comfortably emit a real `.app` bundle**
with the Info.plist keys, entitlements, and signing this app needs (PLAN §11); a hand-maintained
`.xcodeproj` is a giant merge-hostile XML blob.

## Decision

- **Language/UI:** Swift 6, SwiftUI, `MenuBarExtra`. Deployment target macOS 14; the on-device rung
  is gated to macOS 26 + Apple Intelligence at runtime.
- **Logic in SwiftPM:** all eight library targets (`TidyCore … TidySurface`) live in
  `Packages/TidyKit/` — testable with fixtures + in-memory GRDB, dependency graph enforced by
  SwiftPM (see [../architecture/module-map.md](../architecture/module-map.md)).
- **App shell via XcodeGen:** `project.yml` → `xcodebuild`. The `App/` target is a thin shell
  owning `@main`, Info.plist, entitlements, and signing — the things SwiftPM can't express.
  Regenerate with `make generate` after adding files.

## Consequences

- Everything is terminal-drivable (`make bootstrap/generate/build/run/test`), which is the Claude
  Code workflow.
- `project.yml` is small and human-reviewable; the generated `.xcodeproj` is disposable and
  gitignored, so no merge conflicts in project XML.
- Logic tests never launch the app: they run against `TidyKit` directly.
- Two build tools to install (XcodeGen via brew, Xcode toolchain); a one-time `make bootstrap` cost.

## Alternatives considered

- **SwiftPM only.** Rejected: can't produce the signed `.app` with the Info.plist/entitlement keys
  Accessibility, Apple Events, and launch-at-login require (PLAN §11).
- **Plain hand-maintained `.xcodeproj`.** Rejected: merge-hostile XML, not cleanly diffable or
  scriptable, and buries the module boundaries `TidyKit` makes explicit.
