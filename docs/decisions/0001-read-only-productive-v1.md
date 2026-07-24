# 0001 — Read-only Productive in v1

TidyTime suggests time entries but never writes them; the Productive token is used for `GET` only.

Related: [README.md](README.md) · [../guardrails.md](../guardrails.md) ·
[../../PLAN.md](../../PLAN.md) · [../reference/productive-api.md](../reference/productive-api.md)

**Status:** Accepted · **Date:** 2026-07-23

## Context

The whole product is "reconstruct the day, hand you ready-to-enter suggestions; you enter them"
(PLAN §1). Writing entries back into Productive is a fundamentally different risk class: a wrong
automated write corrupts the client's billing record, and undoing it requires audit trails the v1
scope doesn't build. Productive's own docs don't document read-only token scoping (PLAN §5), so
"the token can't write" is not a guarantee the vendor gives us — the guarantee has to be
**architectural**, enforced in our code.

## Decision

v1 issues **only `GET`** requests to `https://api.productive.io`. No `POST`, `PUT`, `PATCH`, or
`DELETE`, ever. "Log it ✓" in the recap marks a suggestion handled **locally** by flipping
`suggestions.status` to `'logged'` — it does not touch Productive. This is guardrail
**[G1](../guardrails.md#g1--v1-never-writes-to-productive)**.

## Consequences

- The `ProductiveClient` seam in `TidyIngest` (see
  [../architecture/module-map.md](../architecture/module-map.md)) exposes **no** mutating method;
  there is no code path that builds a non-`GET` request for the Productive host.
- A guardrail unit test asserts the request builder rejects any method other than `GET` (fails
  loudly in `DEBUG`), so a regression is a failing test, not a silent billing write.
- The human keeps final control: every entry is copy-pasted into Productive by a person, which is
  also the point (trust before automation).
- Gap analysis reads `pd_time_entries` to avoid double-suggesting; that read is the only Productive
  dependency the recap has.

## Alternatives considered

- **Write with an approve button now.** Rejected for v1: write scope demands audit logging + undo
  designed properly, not bolted on (PLAN §12). It is explicitly the **v2** headline (PLAN §13) and
  will arrive as a *separate* write client behind its own seam, superseding this ADR.
- **Trust a read-only scoped token.** Rejected: scoping isn't documented, so it can't be the
  enforcement mechanism — only a defense-in-depth bonus if it exists.
