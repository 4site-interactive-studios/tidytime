# 0004 — Sensitivity gate fails closed

A local sensitivity gate screens all content before any cloud payload or note generation;
uncertainty resolves to **sensitive**, and tripped content never leaves the device.

Related: [README.md](README.md) · [../guardrails.md](../guardrails.md) ·
[../architecture/understand-layer.md](../architecture/understand-layer.md) ·
[0003](0003-local-first-classification-ladder.md)

**Status:** Accepted · **Date:** 2026-07-23

## Context

Capture sees everything on screen and in transcripts, including personnel, compensation,
performance-review, and legal content. Sending any of that to a cloud model is the one privacy
failure the product cannot survive. The asymmetry is decisive (PLAN §7): an over-cautious generic
note costs the user one manual edit; the opposite failure writes `"discussed PIP for [name]"` into
a payload sent to a third party. So the gate must fail toward *silence*, not toward *sending*.

## Decision

Run a **local keyword/participant sensitivity gate before rungs 3 and 4 and before any note
generation** (PLAN §7). It screens for personnel, performance, compensation, and legal content
plus a user-maintained list of flagged people and terms. Tripped content is **never transmitted**:
the suggestion falls back to the appropriate generic task (e.g. "1:1 check-in") with a bland note,
and the work is resolved locally or left unclassified. `sessions.is_sensitive` /
`suggestions.is_sensitive` are set. **Uncertainty resolves to sensitive.** This is guardrail
**[G2](../guardrails.md#g2--the-sensitivity-gate-fails-closed)**.

## Consequences

- Cloud clients in `TidyAI` accept only a `GatedPayload` value that **only the gate can produce** —
  the gate is a mandatory step in the type, not an optional filter a caller can skip.
- A local, opt-in **outbound-payload log** records the exact bytes sent to each provider, so a
  Phase 6 test can seed a known sensitive phrase in a fixture transcript and assert it appears in
  **no** outbound payload (PLAN §11, Phase 6 acceptance).
- Gate lists are user-editable in Settings but ship with sane defaults; **an empty list never
  disables the gate.**
- On-device model calls (rung 3) stay on-device and are exempt from *transmission* concerns, but
  note generation still respects the generic-fallback rule.
- Cost: some genuinely billable-but-innocuous sessions get a generic note and need a manual edit.
  Accepted deliberately — one edit is cheaper than one leak.

## Alternatives considered

- **Post-hoc redaction of payloads.** Rejected: redaction is fail-open (miss one term → it ships);
  the gate blocks the whole payload instead.
- **Cloud-side content policy.** Rejected: it can't run before we transmit, which is the only point
  that matters. The decision has to be made locally, before egress.
