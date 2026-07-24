# 0007 — Accessibility window titles, not Screen Recording

Window titles come from the Accessibility API (`AXUIElement`), deliberately avoiding
`CGWindowList`'s window-name field so the Screen Recording permission is never requested.

Related: [README.md](README.md) · [../guardrails.md](../guardrails.md) ·
[../architecture/capture-layer.md](../architecture/capture-layer.md) ·
[../reference/macos-permissions-tcc.md](../reference/macos-permissions-tcc.md)

**Status:** Accepted · **Date:** 2026-07-23

## Context

Capture needs the focused window's title as a primary attribution signal (PLAN §4). macOS exposes
window titles two ways. `CGWindowListCopyWindowInfo`'s `kCGWindowName` field is trivial to call,
but reading it triggers the **Screen Recording** permission (`kTCCServiceScreenCapture`) — the
scariest prompt macOS shows, and one that would let the app capture pixel contents it has no reason
to want. For a tool whose entire pitch is privacy-respecting passive capture, asking for Screen
Recording is a design failure (PLAN §10, item 11).

## Decision

Read the focused window's title through the **Accessibility API** — subscribe to
`NSWorkspace.didActivateApplicationNotification`, then read the focused window's title attribute via
`AXUIElement` (PLAN §4). **Never** call `CGWindowList*` for the window-name field, and **never**
declare or request Screen Recording. This is guardrail
**[G3](../guardrails.md#g3--no-screen-recording-permission-is-ever-requested)**.

## Consequences

- The app requests **Accessibility** (and Automation for Apple Events), not Screen Recording — a
  materially smaller, more explainable ask (see
  [../reference/macos-permissions-tcc.md](../reference/macos-permissions-tcc.md)).
- A guardrail lint/test greps `TidyCapture` for `CGWindowList` and fails if the window-name field is
  used, so this can't regress silently.
- We get titles, not pixels — which is exactly the granularity attribution needs; page *text* comes
  from Chrome scripting ([0010](0010-chrome-only-behind-browseradapter.md)), not screen capture.
- Accessibility grants are keyed to the code signature, so this decision leans on stable signing
  ([0009](0009-stable-signing-for-tcc.md)); `make doctor` surfaces a dropped grant.
- Some apps expose thin AX trees; title read can be empty. Accepted — degrade to app name + bundle
  id rather than reach for Screen Recording.

## Alternatives considered

- **`CGWindowList` window names.** Rejected: pulls in Screen Recording, over-broad and alarming for
  the value returned. This is the whole point of the guardrail.
- **Screen capture + OCR.** Rejected outright: maximal permission, maximal privacy blast radius,
  and unnecessary when AX titles + Chrome page text already cover attribution.
