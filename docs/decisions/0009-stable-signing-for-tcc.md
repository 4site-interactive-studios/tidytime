# 0009 — Stable code signature for TCC durability

The app ships a stable code signature and fixed bundle id so macOS keeps Accessibility/Automation
grants across rebuilds instead of silently revoking them.

Related: [README.md](README.md) · [../guardrails.md](../guardrails.md) ·
[../build/signing-and-tcc.md](../build/signing-and-tcc.md) ·
[0007](0007-accessibility-not-screen-recording.md)

**Status:** Accepted · **Date:** 2026-07-23

## Context

macOS keys **TCC permission grants to the code signature** (PLAN §10, §12). An ad-hoc or rotating
signature — the default when you rebuild casually without a stable identity — produces a *different*
signature each build, so macOS treats each rebuild as a new app and **silently strips** the
Accessibility and Automation grants the app depends on. This is the single most common way this
class of app "mysteriously stops working," and the project ships with **no paid Apple Developer
account** (PLAN §2), so the fix has to work with a free identity.

## Decision

Sign with a **stable identity and a fixed bundle id** (`com.4site.TidyTime`, configurable) — a free
Apple ID personal team or a stable self-signed certificate, not an ad-hoc/rotating signature
(PLAN §10). Signing settings come from a committed base plus a **local, gitignored `Local.xcconfig`**
carrying the team id, so the signature is reproducible without committing anyone's identity. This is
guardrail **[G7](../guardrails.md#g7--stable-code-signature-tcc-durability)**; details in
[../build/signing-and-tcc.md](../build/signing-and-tcc.md).

## Consequences

- TCC grants (Accessibility for window titles per [0007](0007-accessibility-not-screen-recording.md),
  Automation for Apple Events into Chrome per [0010](0010-chrome-only-behind-browseradapter.md))
  **survive rebuilds** — capture doesn't silently die after a routine `make build`.
- `make doctor` / the in-app doctor view surfaces current permission status, so a dropped grant is
  **visible**, not a silent capture outage (PLAN §12).
- No paid developer account required; the free personal-team path is documented in the README on
  day one so a teammate doesn't trip the same wire.
- Trade-off: each machine needs its own `Local.xcconfig`; the app isn't notarized/distributable
  as-is, which is fine for a personal/internal build.

## Alternatives considered

- **Ad-hoc signing (`-`).** Rejected: the signature changes every build, so TCC grants evaporate —
  the exact failure mode this ADR exists to prevent.
- **Paid Developer ID + notarization.** Deferred: unnecessary for a personal build with no paid
  account; revisit at team rollout (PLAN §13) if distribution outside dev machines is wanted.
