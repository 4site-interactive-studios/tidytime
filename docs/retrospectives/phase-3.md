# Phase 3 retrospective — Meetings & calendar

**Date:** 2026-07-23 · **Status:** ✅ logic complete, tests green (72 total, +9) · **Commit:** `feat(phase-3)`

## What shipped (code-complete + unit-tested)

| Area | Type(s) | Tested by |
|---|---|---|
| Schema | `v1-meetings` (meetings, meeting_invitees, transcript_utterances, calendar_events) + DAOs | `FathomSyncTests`, `CalendarTests` |
| Time parsing | `TimeParse` (RFC3339, HH:MM:SS, domain, external, day-epoch) | `TimeParseTests` (4) |
| Fathom | `LiveFathomClient` + `FathomMapper` + `FathomSync` + `MeetingSessionBuilder` | `FathomParseTests`, `FathomSyncTests` |
| Google Calendar | `LiveGoogleCalendarClient` + `GCalMapper` + `CalendarSync` | `CalendarTests` (2) |
| Away prompt data | `resolveAwayGap`, `unresolvedAwayGaps` | `AwayGapResolutionTests` |

## Divergences / decisions (see DECISIONS.md)

- Meeting **duration = recording span** (Fathom ground truth); DTO shape is a build-time check.
- **Idempotent re-sync**: child rows replaced, meeting session deleted-by-`source_ref` then rebuilt.
- Google is camelCase (no CodingKeys); cancelled → deletions; `is_external` via `internal_domains`.
- OAuth token behind an injected provider; only the live exchange is untested.
- `meetings.calendar_event_id` left NULL (Fathom doesn't return it) — match later by time+attendees.

## Deferred to manual verification (needs live services + auth)

- Fathom API access on the user's plan, exact response shape, and 429/`Retry-After` behavior.
- The Google **Internal-type OAuth** loopback+PKCE flow and refresh-token longevity.
- That yesterday's meetings show real recorded durations + attendees end-to-end.

## Notes for Phase 4 (Slack)

- Add `v1-slack` migration (`slack_messages`) — **this is its own migration** (a doc bug in an
  earlier draft claimed otherwise; already corrected). Reuse the HTTP/Backoff layer.
- Slack Web API cursor pagination; user-token scopes; the internal-app rate-limit exemption is a
  build-time check. Merge Slack activity into the timeline as `kind='slack'` sessions.
