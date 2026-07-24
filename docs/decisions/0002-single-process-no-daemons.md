# 0002 — Single menu-bar process, no daemons

All capture, ingest, understanding, and surface work runs in one menu-bar app process; launch at
login is `SMAppService`, with no helper tools or launch daemons in v1.

Related: [README.md](README.md) · [../guardrails.md](../guardrails.md) ·
[../../PLAN.md](../../PLAN.md) · [../architecture/module-map.md](../architecture/module-map.md)

**Status:** Accepted · **Date:** 2026-07-23

## Context

TidyTime spans capture, four ingest sources, a classification pipeline, and a SwiftUI surface. A
"proper" macOS design might split capture into a background daemon so it survives the UI. But
daemons and XPC helpers add signing, entitlement, IPC, and lifecycle complexity that a personal
build driven by Claude Code has to debug the hard way — and they hide capture state from the user.
PLAN §3 makes the call explicit: one process, no helpers.

## Decision

Run **everything in the single `TidyTimeApp` menu-bar process**. Launch-at-login is
[`SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice) (the
modern API — no login-item helper bundle needed). No `launchd` plist, no XPC service, no privileged
helper ships in v1. This is guardrail
**[G8](../guardrails.md#g8--one-process-no-background-daemons-v1)**.

## Consequences

- **If the app isn't running, capture is off — and the absent menu-bar icon says so** (PLAN §3).
  Capture state is legible to the user with zero extra UI; there is no silent background collector.
- Simpler to build, debug, and reason about: one address space, one crash log, one set of TCC
  grants tied to one signature (see [0009](0009-stable-signing-for-tcc.md)).
- The capture pipeline must be resilient inside the app: event-driven with a slow heartbeat,
  batched writes, sleep/wake and lock notifications close sessions cleanly, all under the ~2% CPU
  bar (PLAN §4). Concurrency uses actors (see conventions).
- Trade-off accepted: no capture while the app is quit or crashed. For a personal, always-open
  menu-bar tool this is acceptable; a crash is visible immediately.
- Enforcement is structural: the build contains no daemon plist or helper target, so this can't
  regress by accident.

## Alternatives considered

- **Background `launchd` daemon for capture.** Rejected: hides capture state, multiplies signing
  and TCC surface, and a headless collector is exactly the privacy posture we don't want.
- **XPC helper for the AI/network work.** Rejected as premature; one process is fine at v1 volume,
  and the money-guarded cloud calls (see [0008](0008-fireworks-economy-plus-claude-escalation.md))
  are already isolated behind `TidyAI`.
