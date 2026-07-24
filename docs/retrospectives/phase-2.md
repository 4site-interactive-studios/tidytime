# Phase 2 retrospective — Productive mirror (read-only)

**Date:** 2026-07-23 · **Status:** ✅ logic complete, tests green (63 total, +17) · **Commit:** `feat(phase-2)`

## What shipped (code-complete + unit-tested)

| Area | Type(s) | Tested by |
|---|---|---|
| HTTP layer | `HTTPClient`, `URLSessionHTTPClient`, `FakeHTTPClient`, `Backoff` | `BackoffTests`, retry tests |
| JSON:API | `JSONAPIDocument/Resource/Relationship` decoding | via parse tests |
| Productive client | `ProductiveRequestBuilder` (GET-only), `LiveProductiveClient` (paginate + 429 retry), `PDMapper` | `ProductiveParseTests` (4), `ProductivePagingAndRetryTests` (3) |
| Sync | `ProductiveSync` (+ `FakeProductiveClient`), self-resolution, cursor | `ProductiveSyncTests` |
| Schema | `v1-productive` migration + pd_* records/DAOs | `ProductiveStoreTests` (4) |
| Deep link | `ProductiveDeepLink` | `DeepLinkTests` |
| **Guardrail G1** | builder refuses POST/PATCH/PUT/DELETE | `ProductiveGuardrailTests` |

Coverage climbed as ingest is highly testable with fakes; the only untested lines here are
`URLSessionHTTPClient.send` (live network) — everything else runs.

## Divergences / decisions (see DECISIONS.md)

- **G1 is a hard structural + tested invariant** — no non-GET request can be built.
- Productive **attribute/filter names are build-time checks**; fixtures follow the documented shape
  and the mapping is isolated in one file for easy correction at integration.
- Reusable HTTP/Backoff/retry pattern established for Phases 3–4.

## Deferred to manual verification (needs live Productive + a token)

- That the cache actually matches Productive's UI for the user's week, and clicking a cached task
  opens it (deep-link pattern is a Phase-2 build-time check to capture from the web app).
- The exact attribute/filter key names against the live API. The sync/parse machinery is proven
  against fixtures; only the field-name mapping is unconfirmed.

## Notes for Phase 3 (Meetings & calendar)

- Reuse `HTTPClient`/`Backoff`. Add `v1-meetings` migration (meetings, meeting_invitees,
  transcript_utterances, calendar_events).
- Fathom + Google clients behind protocols with fixtures; Google OAuth (loopback+PKCE) token
  handling stays behind a `SecretStore`-backed seam (refresh token in Keychain) — the token
  exchange itself is live-only, but request building + response parsing are testable.
- Fathom `recording_start/end` is the duration ground truth; build meeting sessions from it.
- Entity-signal bootstrap starts here (attendee domains) but the `entity_signals` table lands in
  Phase 5 — keep bootstrap data flowing into it then, or add the table early if convenient.
