# Google Calendar API (read-only)

Read-only ingest of the user's Google Calendar via OAuth 2.0 (loopback + PKCE) and
`events.list` incremental sync, mapped into `calendar_events`. Supplies the day's schedule,
attendees, conference links, nudge-suppression windows, and a fallback for meetings Fathom
never recorded.

**Related:** [../README.md](../README.md) · [../../PLAN.md](../../PLAN.md) §5 ·
[./fathom-api.md](./fathom-api.md) · [../architecture/data-model.md](../architecture/data-model.md) ·
[../guardrails.md](../guardrails.md) · [../permissions-setup.md](../permissions-setup.md)

**Status:** stable · **Base URL:** `https://www.googleapis.com/calendar/v3` (OAuth endpoints
on `accounts.google.com` / `oauth2.googleapis.com`) · **Auth:** OAuth 2.0 desktop app,
loopback redirect + PKCE, scope `https://www.googleapis.com/auth/calendar.readonly` ·
**Source:** developers.google.com/workspace/calendar/api/v3/reference/events/list ·
developers.google.com/identity/protocols/oauth2/native-app ·
developers.google.com/identity/protocols/oauth2 ·
developers.google.com/workspace/guides/configure-oauth-consent · **Last verified:** 2026-07-23

---

## 1. What this source supplies

Google Calendar is one leg of the meetings/calendar phase ([Phase 3](../phases/phase-3-meetings-calendar.md)).
Per [PLAN.md](../../PLAN.md) §5, it is **read-only** and delivers:

- **The day's schedule** — event title, time bounds, status, description, location.
- **Attendees and organizer** — with an `is_external` flag derived by email domain, a strong
  client signal that seeds `entity_signals` and `meeting_invitees`.
- **Conference links** — Google Meet from `conferenceData`/`hangoutLink`, Zoom from `location`
  or `description`.
- **Nudge-suppression windows** — `[start_at, end_at)` of confirmed events; nudges never fire
  inside one ([PLAN.md](../../PLAN.md) §9, `TidySurface`).
- **A fallback for unrecorded meetings** — a calendar event with no matching Fathom recording
  still becomes a meeting session so its time is not lost ([suggestion-engine.md](../architecture/suggestion-engine.md)).

It writes `calendar_events`; cursor lives in `sync_state` (`source = 'google_calendar'`).
Guardrails: this is a GET-only source (no calendar mutations); the OAuth **refresh token** is a
secret and lives in the Keychain only ([G6](../guardrails.md#g6--secrets-live-in-the-keychain-only));
one process, poll-driven ([G8](../guardrails.md#g8--one-process-no-background-daemons-v1)).

## 2. Why the OAuth client MUST be created as **Internal** user type

Create the OAuth client in a Google Cloud project whose **OAuth consent screen is set to
`Internal` user type**, inside the **4Site Google Workspace org**. Console steps are in
[../permissions-setup.md](../permissions-setup.md); this section is the *why*, because getting
it wrong produces two failures that look like bugs in our code.

| Concern | `External` (+ `Testing`) | `Internal` (Workspace org) |
|---|---|---|
| Who can consent | Only test users you list | Any user **in the org** — no test-user list |
| Sensitive-scope verification | `calendar.readonly` is a **sensitive** scope → Google's app-verification/brand review before `Production` | **Skipped** — internal apps are not subject to sensitive-scope verification |
| Refresh-token lifetime | **Expires after 7 days** while status is `Testing` (verified below) | **No 7-day expiry** — there is no `Testing` gate for internal apps |
| Unverified-app warning screen | Shown until verified | Not shown for org users |

**The 7-day trap (verified 2026-07-23).** Google's docs state a refresh token
*"expiring in 7 days"* is issued to a project *"configured for an **external** user type and a
publishing status of **'Testing'**"* — unless the only scopes are name/email/profile.
`calendar.readonly` is not in that exempt subset, so an External+Testing TidyTime would silently
lose calendar access every week and force a re-consent. An `Internal` app has **no** `Testing`
publishing status and does not carry this expiry, so the refresh token persists until revoked,
six months of non-use, or a password change. This is exactly the "install once, run for months"
behavior a passive capture app needs.

**If `Internal` is not offered** the project is not inside the Workspace org, and the fix is to
move or recreate it there. Do **not** settle for `External` + `Testing`. If the project genuinely
cannot live in the org, the only other expiry-free path is `External` + publishing status
**`In production`**, which for a sensitive scope like `calendar.readonly` means going through
Google's verification first. That is a schedule cost, not a config toggle (verified 2026-08-28).

**Client type.** Create the credential as an **OAuth client ID → Application type: Desktop
app**. This yields a `client_id` and a `client_secret`. For a Desktop (installed) app the
`client_secret` is **not confidential** — it ships inside any distributed binary and PKCE, not
the secret, provides the real protection. Treat `client_id` + desktop `client_secret` as
non-secret config; treat the **refresh token** as the secret (Keychain).
⚠️ Build-time check: confirm the desktop-app client still returns a `client_secret` at creation
and whether Google's token endpoint requires it for this client type — installed-app clients
historically require sending it on the token exchange even though it is not secret.

## 3. OAuth 2.0 — loopback (127.0.0.1) flow with PKCE

The desktop flow: open the system browser to Google's auth page, run a throwaway HTTP listener
on a loopback port to catch the redirect with the `code`, exchange `code`+`code_verifier` for
tokens. No embedded webview. Loopback (`http://127.0.0.1:<port>`) is Google's **recommended**
redirect for macOS/Linux/Windows desktop apps.

### 3.1 One-time client registration (config)

Store these non-secret values in `config.json` (or compile them in):

```json
{
  "google": {
    "client_id": "1234567890-abcdefg.apps.googleusercontent.com",
    "client_secret": "GOCSPX-xxxxxxxxxxxxxxxxxxxx",
    "scopes": ["https://www.googleapis.com/auth/calendar.readonly"],
    "calendar_id": "primary",
    "internal_domains": ["4sitestudios.com", "4site.io"]
  }
}
```

`internal_domains` drives the `is_external` derivation (§6). The refresh token is **not** here —
it is written to Keychain after first consent ([G6](../guardrails.md#g6--secrets-live-in-the-keychain-only)).

### 3.2 PKCE parameters (generate per authorization)

```swift
// TidyIngest / GoogleOAuth
let codeVerifier  = randomURLSafe(length: 64)              // 43–128 unreserved chars
let codeChallenge = base64URLNoPad(sha256(codeVerifier))   // S256
let state         = randomURLSafe(length: 32)              // CSRF guard, verify on callback
let port          = bindEphemeralLoopbackListener()        // OS-assigned free port on 127.0.0.1
let redirectURI   = "http://127.0.0.1:\(port)"             // path optional; keep it stable per run
```

- `code_verifier`: high-entropy string, `[A-Z] [a-z] [0-9] - . _ ~`, length **43–128**.
- `code_challenge` = BASE64URL-no-pad( SHA-256( `code_verifier` ) ); `code_challenge_method=S256`.

### 3.3 Step 1 — authorization request (open in the system browser)

```http
GET https://accounts.google.com/o/oauth2/v2/auth
      ?client_id=1234567890-abcdefg.apps.googleusercontent.com
      &redirect_uri=http%3A%2F%2F127.0.0.1%3A49221
      &response_type=code
      &scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcalendar.readonly
      &code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM
      &code_challenge_method=S256
      &access_type=offline
      &prompt=consent
      &state=xYz...random
```

- `access_type=offline` is **required** to receive a refresh token.
- `prompt=consent` forces the consent screen so a refresh token is (re)issued even if the user
  previously granted access; drop it on silent re-auth if you already hold a refresh token.
- `state` is echoed back to the redirect — reject the callback if it doesn't match.

### 3.4 Step 2 — catch the redirect on the loopback listener

Google redirects the browser to:

```http
GET http://127.0.0.1:49221/?state=xYz...random&code=4/0Ax...authcode&scope=https://www.googleapis.com/auth/calendar.readonly
```

Verify `state`, read `code`, respond to the browser with a small "You can close this tab" HTML
page, then shut the listener down. On error Google appends `?error=access_denied`.

### 3.5 Step 3 — exchange code for tokens

```http
POST https://oauth2.googleapis.com/token
Content-Type: application/x-www-form-urlencoded

client_id=1234567890-abcdefg.apps.googleusercontent.com
&client_secret=GOCSPX-xxxxxxxxxxxxxxxxxxxx
&code=4/0Ax...authcode
&code_verifier=<the original verifier, NOT the challenge>
&grant_type=authorization_code
&redirect_uri=http://127.0.0.1:49221
```

```json
{
  "access_token": "ya29.a0Af...",
  "expires_in": 3599,
  "refresh_token": "1//09xy...refresh",
  "scope": "https://www.googleapis.com/auth/calendar.readonly",
  "token_type": "Bearer"
}
```

**On success:** write `refresh_token` to Keychain (`SecretStore`, key e.g.
`google.calendar.refresh_token`). Hold `access_token` + its expiry **in memory only**; never
persist the access token to disk or DB. `redirect_uri` on the exchange must byte-match the one
from Step 1.

### 3.6 Step 4 — refresh the access token (no user interaction)

```http
POST https://oauth2.googleapis.com/token
Content-Type: application/x-www-form-urlencoded

client_id=1234567890-abcdefg.apps.googleusercontent.com
&client_secret=GOCSPX-xxxxxxxxxxxxxxxxxxxx
&refresh_token=1//09xy...refresh
&grant_type=refresh_token
```

Refresh proactively when the cached access token is within ~5 min of expiry, or reactively on a
`401`. A `refresh_token` field is **not** returned here — keep reusing the stored one. If the
refresh call returns `400 invalid_grant`, the refresh token is dead (revoked, password change,
6-month idle, or — the failure the Internal setup exists to prevent — an External+Testing
7-day expiry): clear it from Keychain and re-run the §3.3 consent flow. Surface this in the
`doctor` view as a re-auth prompt, not a silent stall.

## 4. `events.list` — fetching events

```http
GET https://www.googleapis.com/calendar/v3/calendars/primary/events
      ?singleEvents=true
      &timeMin=2026-07-23T00:00:00-04:00
      &timeMax=2026-07-24T00:00:00-04:00
      &orderBy=startTime
      &maxResults=250
Authorization: Bearer ya29.a0Af...
```

| Param | Value we use | Notes |
|---|---|---|
| `singleEvents` | `true` | Expand recurring events into concrete instances. **Must stay constant** between a sync token and its follow-ups. |
| `timeMin` / `timeMax` | RFC3339 **with** offset | Initial/full sync only. Bound the window (see §5). Omitting `timeMax` with `singleEvents=true` risks unbounded recurring expansion. |
| `orderBy` | `startTime` | Only valid with `singleEvents=true`. **Incompatible with `syncToken`** (§5). |
| `maxResults` | ≤ **2500**, default **250** | Page count ceiling; a page may return fewer. Follow `nextPageToken`. |
| `pageToken` | echoed | Page through until the final page returns `nextSyncToken`. |
| `syncToken` | stored cursor | Incremental sync (§5). Cannot be combined with the time/order params. |
| `showDeleted` | (see §5) | With `syncToken`, deletions arrive as `status:"cancelled"` regardless. |

`calendarId=primary` targets the signed-in user's own calendar (v1 scope). Listing/other
calendars via `calendarList.list` is a later enhancement.

### 4.1 Example response (one timed event, abridged)

```json
{
  "kind": "calendar#events",
  "summary": "bryan@4sitestudios.com",
  "updated": "2026-07-23T13:02:11.000Z",
  "timeZone": "America/New_York",
  "nextSyncToken": "CPDAlvWDLx0KGjIzMDcyMzE...",
  "items": [
    {
      "id": "6f3k2l1a9b8c7d6e5f4g3h2i1j",
      "status": "confirmed",
      "htmlLink": "https://www.google.com/calendar/event?eid=NmYz...",
      "summary": "Client A — donation page review",
      "description": "Walkthrough of the new ENgrid donation form.\nZoom: https://us06web.zoom.us/j/8123456789?pwd=abcd",
      "location": "https://us06web.zoom.us/j/8123456789",
      "start": { "dateTime": "2026-07-23T10:00:00-04:00", "timeZone": "America/New_York" },
      "end":   { "dateTime": "2026-07-23T10:30:00-04:00", "timeZone": "America/New_York" },
      "iCalUID": "6f3k2l1a9b8c7d6e5f4g3h2i1j@google.com",
      "organizer": { "email": "bryan@4sitestudios.com", "displayName": "Bryan Casler", "self": true },
      "attendees": [
        { "email": "bryan@4sitestudios.com", "displayName": "Bryan Casler",
          "organizer": true, "self": true, "responseStatus": "accepted" },
        { "email": "maria@clienta.org", "displayName": "Maria P.",
          "responseStatus": "accepted" }
      ],
      "hangoutLink": "https://meet.google.com/abc-defg-hij",
      "conferenceData": {
        "conferenceId": "abc-defg-hij",
        "conferenceSolution": { "key": { "type": "hangoutsMeet" }, "name": "Google Meet" },
        "entryPoints": [
          { "entryPointType": "video", "uri": "https://meet.google.com/abc-defg-hij",
            "label": "meet.google.com/abc-defg-hij" },
          { "entryPointType": "phone", "uri": "tel:+1-000-000-0000", "pin": "123456" }
        ]
      }
    }
  ]
}
```

An all-day event uses `"start": { "date": "2026-07-23" }` / `"end": { "date": "2026-07-24" }`
(no `dateTime`); a deleted/cancelled instance arrives as `{ "id": "...", "status": "cancelled" }`
with most fields absent.

## 5. Incremental sync via `syncToken` (and the 410 reset)

The cursor is `sync_state.cursor` for `source = 'google_calendar'`
([data-model.md](../architecture/data-model.md#capture-tables-phase-1)).

**Initial / full sync**
1. `GET events` with `singleEvents=true` + `timeMin`/`timeMax` (bounded window, e.g. −7d…+30d
   around now) + `maxResults=250`.
2. Follow `nextPageToken` through every page — **the `nextSyncToken` appears only on the final
   page**. Upsert items as you go.
3. Persist the final `nextSyncToken` to `sync_state.cursor`.

**Incremental sync (steady state, every ~5 min)**
1. `GET events?syncToken=<cursor>&singleEvents=true` — **omit** `timeMin`, `timeMax`,
   `orderBy`, `q`, `updatedMin`, `iCalUID`. Passing any of them with `syncToken` returns
   **400**. This is the #1 mistake with this endpoint.
2. Google returns only entries changed since the token (including cancellations as
   `status:"cancelled"`). Page through; store the new `nextSyncToken`.
3. Changed events can fall outside the app's window of interest — filter by `start_at` locally
   at read time; do not try to bound the incremental request.

**410 GONE → drop token + full resync**

```http
HTTP/1.1 410 Gone
{ "error": { "errors": [ { "reason": "fullSyncRequired" } ], "code": 410,
             "message": "Sync token is no longer valid, a full sync is required." } }
```

On `410`, per Google: *clear the stored token and perform a full sync without any `syncToken`.*
Implementation: null out `sync_state.cursor`, optionally clear/re-upsert the windowed
`calendar_events`, and re-run the initial-sync path. Write the error to `sync_state.last_error`;
a 410 is expected housekeeping, not a fault.

**Rate limits.** Calendar API enforces per-minute per-user quotas; our ~5-min poll of one
calendar is far under them. Back off on `403 rateLimitExceeded`/`429` with exponential retry +
jitter; honor `Retry-After` when present. ⚠️ Build-time check: current default quota numbers on
the project's Calendar API quota page.

## 6. Mapping to `calendar_events`

Target table columns are fixed by [data-model.md](../architecture/data-model.md#meetings--calendar-phase-3).
Upsert on `id` (Google event id).

| `calendar_events` column | Source in the event JSON | Transform |
|---|---|---|
| `id` | `items[].id` | PK; string, upsert |
| `calendar_id` | request path | `"primary"` in v1 |
| `title` | `summary` | may be absent → NULL |
| `description` | `description` | raw; scanned for Zoom links (below) |
| `location` | `location` | raw; scanned for Zoom links |
| `start_at` | `start.dateTime` **or** `start.date` | RFC3339 → **epoch seconds UTC**; all-day → local midnight → UTC |
| `end_at` | `end.dateTime` **or** `end.date` | same |
| `all_day` | presence of `start.date` (no `dateTime`) | `1` if date-only else `0` |
| `status` | `status` | `'confirmed'` \| `'tentative'` \| `'cancelled'` |
| `organizer_email` | `organizer.email` | lowercased |
| `attendees_json` | `attendees[]` | array of `{email,name,responseStatus,is_external}` (§6.1) |
| `conference_url` | `conferenceData`/`hangoutLink`/`location`/`description` | resolution order in §6.2 |
| `ical_uid` | `iCalUID` | join key to Fathom (§7) |
| `updated_at` | `updated` | RFC3339 → epoch seconds |
| `fetched_at` | now | epoch seconds |

Timestamps are epoch seconds UTC per repo convention; Google gives offset-aware RFC3339, so
parse-to-`Date`-to-`timeIntervalSince1970`. Keep the original zone only implicitly (the offset
is in the string) — the `day` bucket used elsewhere is computed in the user's configured zone.

### 6.1 Attendees and `is_external`

`is_external` is **derived**, not from Google. For each attendee, take the domain after `@`,
lowercase it, and set `is_external = 1` when it is **not** in `config.google.internal_domains`.
This is the same signal `meeting_invitees.is_external` carries and a strong client cue for
entity resolution ([understand-layer.md](../architecture/understand-layer.md)). Skip
`resource`/room attendees (`attendee.resource == true`) and the `self` attendee for the external
count.

```json
"attendees_json": [
  { "email": "bryan@4sitestudios.com", "name": "Bryan Casler",
    "responseStatus": "accepted", "is_external": 0 },
  { "email": "maria@clienta.org", "name": "Maria P.",
    "responseStatus": "accepted", "is_external": 1 }
]
```

### 6.2 `conference_url` resolution (Meet + Zoom)

Populate `conference_url` by this order, first hit wins:

1. **Google Meet via `conferenceData.entryPoints`** — first entry with
   `entryPointType == "video"` → its `uri` (`https://meet.google.com/…`).
2. **`hangoutLink`** — legacy top-level Meet URL; use if `conferenceData` is absent.
3. **Zoom in `location`** — regex the `location` string for `https://[\w.-]*zoom\.us/(j|my)/…`.
4. **Zoom in `description`** — same regex over `description` (Zoom's add-on often writes the
   join URL and passcode into the body, as in the §4.1 example).

Zoom generally is **not** in `conferenceData` (that field is populated by Meet or by conference
add-ons), which is why `location`/`description` scanning is required to catch Zoom meetings.
Store the bare join URL; strip a trailing `?pwd=…` only if you also capture the passcode
elsewhere — otherwise keep it intact so the link works.

## 7. How calendar events earn their keep

**Nudge-suppression windows.** `TidySurface` must not fire a nudge during a meeting
([PLAN.md](../../PLAN.md) §9). Any `calendar_events` row with `status != 'cancelled'` and
`all_day = 0` contributes a busy interval `[start_at, end_at)`; the nudge scheduler checks
`now` against these before firing. All-day events (OOO, holidays) are informational, not
busy-blocks, so they don't suppress by themselves.

**Meeting-state inference.** An event overlapping `now` plus a frontmost Zoom/Meet/Slack-huddle
app tells the capture layer to label concurrent screen activity as *in-meeting context* rather
than separate work ([capture-layer.md](../architecture/capture-layer.md), [PLAN.md](../../PLAN.md) §4).

**Catching meetings Fathom didn't record.** Fathom is ground truth for *duration* when a
recording exists ([fathom-api.md](./fathom-api.md)); many meetings aren't recorded (phone,
client-hosted, ad-hoc). Reconciliation:

1. Match a `calendar_events` row to a Fathom `meetings` row by `ical_uid`/attendee-set/time
   overlap. On a match, the Fathom recording supplies duration; the event supplies schedule +
   attendees, and `meetings.calendar_event_id` links back.
2. A confirmed, timed event with **no** Fathom match becomes a **calendar-only meeting session**
   — `meetings.id = 'cal:<eventid>'`, `source = 'calendar'`, `duration_seconds` from
   `scheduled_end − scheduled_start` — so its time still reaches the suggestion stack
   ([suggestion-engine.md](../architecture/suggestion-engine.md)).

Attendee domains from events also seed `entity_signals` (`signal_type = 'email_domain'`,
provenance `bootstrapped`/`inferred`) exactly as Fathom invitees do.

## 8. Client shape & gotchas

`GoogleCalendarClient` sits in `TidyIngest` behind the `IngestSource` protocol
([module-map.md](../architecture/module-map.md)); OAuth token handling is its own unit so it can
be fixture-tested without live network.

```swift
protocol IngestSource { func sync() async throws }   // defined in TidyCore

struct GoogleCalendarClient {                          // TidyIngest
    let secrets: SecretStore                           // Keychain-backed
    let http: HTTPClient
    // ensureAccessToken() -> refresh if <5 min to expiry; re-auth on invalid_grant
    // listEvents(cursor:) -> pages; returns (events, nextSyncToken)
    // on 410 -> reset cursor, full resync
}
```

Gotchas:

- **`syncToken` + time params = 400.** Never send `timeMin`/`timeMax`/`orderBy`/`q` with a
  sync token (§5). Keep two code paths: bounded initial, token-only incremental.
- **`nextSyncToken` only on the last page.** Don't store a token mid-pagination; a partially
  paged sync that saves a token loses events.
- **`singleEvents` must not flip** between a token and its use, or the token is invalid.
- **All-day vs timed** — branch on `start.date` vs `start.dateTime`; mixing them corrupts
  `start_at`.
- **Cancelled instances** carry almost no fields — update the row's `status` to `'cancelled'`
  (don't hard-delete; the recap may reference it) and drop it from busy-windows.
- **Access token is not a stored secret** — memory only; only the **refresh token** goes to
  Keychain ([G6](../guardrails.md#g6--secrets-live-in-the-keychain-only)).
- **Clock skew / TZ** — always parse the RFC3339 offset; never assume the machine's local zone
  equals the event's zone.
- **Read-only by construction** — the client exposes only `GET`; there is no event-write path,
  consistent with the app-wide GET-only posture.

## 9. Cross-references

- Console setup (create the Internal OAuth client, enable Calendar API):
  [../permissions-setup.md](../permissions-setup.md).
- Meeting duration ground truth and transcript ingest: [./fathom-api.md](./fathom-api.md).
- Where the data lands: [../architecture/data-model.md](../architecture/data-model.md)
  (`calendar_events`, `meetings`, `sync_state`).
- Phase & acceptance criteria: [../phases/phase-3-meetings-calendar.md](../phases/phase-3-meetings-calendar.md).
- Invariants: [../guardrails.md](../guardrails.md) (G6 Keychain, G8 one-process, G9 retention).
