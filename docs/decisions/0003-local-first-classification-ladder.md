# 0003 — Local-first classification ladder

Every session is classified by climbing a five-rung ladder — rules → lexical → on-device →
economy cloud → Claude — stopping at the first rung that answers confidently.

Related: [README.md](README.md) · [../guardrails.md](../guardrails.md) ·
[../architecture/classification-ladder.md](../architecture/classification-ladder.md) ·
[0008](0008-fireworks-economy-plus-claude-escalation.md)

**Status:** Accepted · **Date:** 2026-07-23

## Context

Attribution (client → project → task) is the app's core inference. Sending every session to a
cloud model would be expensive, slow, and would leak content unnecessarily. But pure rules can't
handle the long tail. PLAN §2 and §7 lock a graduated approach: local-first, then cheap, then
smart, so most work is settled free and on-device and cloud spend is reserved for what earns it.

## Decision

Classify each session by climbing **[rungs 1–5](../architecture/classification-ladder.md)**, only
as far as needed:

1. **Deterministic rules** — a session dominated by a signal in `entity_signals` gets its
   client/project immediately. Zero cost, fully local.
2. **Lexical matching** — tokenized titles/URLs/page text scored against the Productive cache;
   high-margin matches classify, near-ties fall through.
3. **On-device model** — Apple Foundation Models with guided generation (macOS 26 + Apple
   Intelligence); skipped if unavailable.
4. **Economy cloud** — Fireworks AI for what local rungs can't settle.
5. **Claude escalation** — only when rung 4 earns it.

A confident result at any rung **short-circuits**; each suggestion records
`sessions.produced_by_rung` and a `rationale`. This is guardrail
**[G4](../guardrails.md#g4--local-first-then-cheap-then-smart)**.

## Consequences

- The learning loop keeps promoting user-confirmed patterns into rung-1 rules, so the free rung's
  share **grows over time** — a dashboard metric tracks it, and a cloud-share spike is a visible
  regression.
- A session a rule or high-margin lexical match can settle **must not** reach a cloud model; the
  router enforces the fall-through conditions rather than always escalating.
- Rungs 4–5 run *after* the sensitivity gate ([0004](0004-sensitivity-gate-fail-closed.md)) and are
  metered + capped ([0008](0008-fireworks-economy-plus-claude-escalation.md)).
- More moving parts than a single-model design; mitigated by every rung recording *why* it fired,
  so trust is inspectable.

## Alternatives considered

- **Cloud-only (one strong model).** Rejected: needless cost and content egress for work a rule
  already answers; violates local-first.
- **Rules-only.** Rejected: can't cover the long tail (novel domains, ambiguous meetings); the
  higher rungs exist precisely for fall-through.
