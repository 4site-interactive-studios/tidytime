# TidyTime v1 Plan
### A passive time-capture and attribution assistant for Productive

> **This file is the canonical source of truth for the project vision and scope.**
> It is the interview-locked plan, preserved verbatim. Every doc under `docs/` expands
> a slice of this into build-ready detail. When a doc and this plan disagree, this plan
> wins unless a superseding [Architecture Decision Record](docs/decisions/README.md) says otherwise.

Working name: **TidyTime** (fits the TidyContact family; rename freely). Prepared July 23, 2026 for Bryan Casler. Everything in this plan reflects the interview decisions and was checked against current vendor documentation; the few things that couldn't be verified from docs are marked as build-time checks.

---

## 1. What this is

A native macOS menu bar app that watches how you actually spend your workday (apps, Chrome tabs and page text, meetings, Slack, calendar), reconstructs your day into loggable blocks, matches those blocks against your Productive clients, projects, and tasks, and hands you ready-to-enter time entries: task, duration rounded to your 15-minute convention, and a one-to-two sentence note with a copy button.

v1 is **read-only against Productive**. It recommends; you enter. Nothing writes to Productive, ever, in this version. The Productive API token is used only for GET requests.

**v1 is successful if:** at the end of any workday, the recap surfaces the billable time you would otherwise have forgotten (the 15 client minutes inside an hour-long colleague call, the drive-by Slack DMs, the block you'd have misremembered), and getting your entries into Productive takes minutes instead of an end-of-week archaeology session.

## 2. Decisions locked in the interview

- Personal build first; everything org-specific lives in config so teammates can adopt later (install, paste tokens, pick browser)
- Both live nudges and an end-of-day recap; nudges rate-limited, meeting-aware, learning from dismissals
- No timers. The app is built for backfill: capture everything passively, attribute afterward
- Attribution hierarchy: **client → project → task**, in that order. Partial matches are surfaced, not hidden; services and budgets are out of scope for v1
- All entries resolve to a task (existing, or a proposed new task); 15-minute increments; micro-work pools per project into rolled-up entries; slight round-up bias
- Every suggestion carries an optional short note with one-click copy, plus a deep link to the task in Productive
- Sensitivity gate runs locally before anything else: personnel/comp/legal content never reaches a cloud model and defaults to a generic task with a bland note
- Classification ladder: deterministic rules → fuzzy matching → Apple's on-device model → economy cloud models (Kimi/GLM-class via Fireworks AI) → Claude only as escalation. Local-first, then cheap, then smart
- Every AI call is metered: provider, model, tokens, dollar cost, and outcome land in a local ledger so AI spend is attributable as overhead and tunable
- Sources: foreground app + window titles, Chrome (URL, title, visible page text), Google Calendar, Fathom transcripts, Slack via API (DMs and channels), idle/away detection
- Chrome only in v1; browser watching is an adapter so Safari, Firefox, and Dia can be added later
- Fathom recording start/end is ground truth for meeting duration; the calendar event supplies schedule and attendees
- Recap at a configurable fixed time in v1 (house norm: entries in by close of day, or first thing next morning); unreconciled days queue; dynamic wind-down detection comes later
- Metrics, no targets: observed vs. logged hours, billable vs. internal split, per-client weekly totals, capture health
- Hardware floor: MacBook Pro, M2 or newer, current macOS. Swift/SwiftUI. Built by Bryan driving Claude Code. No paid Apple Developer account
- Raw activity and page text retained 90 days locally; distilled summaries kept indefinitely (both adjustable)

## 3. System overview

Five layers, each useful without the ones above it:

```
┌─────────────────────────────────────────────────────────┐
│ SURFACE   menu bar · nudges · end-of-day recap ·        │
│           away prompts · dashboard · settings           │
├─────────────────────────────────────────────────────────┤
│ UNDERSTAND  sessionization · entity resolution ·        │
│             classification ladder · sensitivity gate ·  │
│             suggestion engine · learning loop           │
├─────────────────────────────────────────────────────────┤
│ STORE     SQLite (GRDB) in ~/Library/Application        │
│           Support/TidyTime · Keychain for tokens        │
├──────────────────────────┬──────────────────────────────┤
│ CAPTURE (local)          │ INGEST (APIs, read-only)     │
│ app & window watcher     │ Productive cache sync        │
│ Chrome adapter + page    │ Fathom meetings/transcripts  │
│ text · idle/away ·       │ Google Calendar events       │
│ meeting state            │ Slack messages               │
└──────────────────────────┴──────────────────────────────┘
```

One process (the menu bar app) runs everything. No daemons, no helper processes in v1; launch-at-login via `SMAppService`. Simpler to build, debug, and reason about, and if the app isn't running, the menu bar icon's absence tells you capture is off.

## 4. Capture layer (on-device)

**App watcher.** Subscribe to `NSWorkspace.didActivateApplicationNotification` for foreground app changes; read the focused window title through the Accessibility API (`AXUIElement`, focused window's title attribute). The Accessibility route deliberately avoids the `CGWindowList` name API, which would drag in the Screen Recording permission. Sample on every app/window switch plus a 30-second heartbeat.

**Chrome adapter.** For the active tab, AppleScript over Apple Events gets URL and title with no browser configuration. Visible page text comes from AppleScript's `execute javascript` in Chrome, which requires flipping View → Developer → "Allow JavaScript from Apple Events" once (still supported in current Chrome; part of one-time setup). Capture policy: snapshot `document.body.innerText` on tab focus and on meaningful title/URL change, truncate to ~4 KB, hash to skip duplicates. If the toggle is off or scripting fails, degrade silently to URL + title. Behind a `BrowserAdapter` protocol so Safari/Firefox/Dia land later without touching the pipeline.

**Idle and away.** `CGEventSource` idle seconds, polled; sleep/wake and screen-lock notifications close out sessions cleanly. Idle beyond a threshold (default 10 minutes) ends the current session and marks an away gap. On return, the away prompt asks what the gap was (see Surface layer).

**Meeting state.** Primarily inferred from calendar (an event happening now) plus frontmost app being Zoom/Meet/Slack huddle. Used to suppress nudges and to label concurrent screen activity as in-meeting context rather than separate work. Mic-in-use detection via CoreAudio is a possible refinement, not v1.

Performance bar: under ~2% average CPU, no fans, no perceptible lag. Event-driven with a slow heartbeat, batched writes.

## 5. Ingest layer (APIs, all read-only)

### Productive

JSON:API at `https://api.productive.io/api/v2/`, headers `X-Auth-Token` (personal token from Settings → API integrations → Generate new token) and `X-Organization-Id`. Documented limits: 100 requests per 10 seconds and 4,000 per 30 minutes, HTTP 429 on excess; pagination `page[number]`/`page[size]` (max 200). Read-only token scoping isn't documented, so the guarantee is architectural: v1 code contains no POST/PATCH/DELETE calls against Productive.

Synced into the local cache every ~15 minutes (a full refresh of your slice of the org is a handful of requests, nowhere near limits):

- **Companies** (clients) and **projects**: `project_type_id` distinguishes internal (1) from client work (2), and each project relates to its company. This is the client → project half of the hierarchy for free
- **Tasks**: filtered by project and assignee; title, description, task number, status, task list, assignee
- **Time entries**: filtered by `person_id` (you) and date range; `time` is minutes, plus `date`, `note`, `billable_time`, and task/service relationships. This is the "what's already logged" side of gap analysis
- **People**: to resolve your own person id at setup

Deep-link URL format for a task isn't in the API docs; grab the pattern from any open task in the web app during Phase 2 (one-time, stored in config).

### Fathom

REST at `https://api.fathom.ai/external/v1`, header `X-Api-Key` (key from User Settings → API Access). Keys are scoped to your user: your recordings plus what's shared with you. Limits: 60 calls/minute, 30/minute for heavy calls (transcripts).

`GET /meetings` with `created_after` for incremental sync, `include_transcript=true` and `include_summary=true`. Each meeting carries `scheduled_start_time`/`scheduled_end_time` and `recording_start_time`/`recording_end_time` (ground truth for duration), `calendar_invitees` with emails and an `is_external` flag (a strong client signal on its own), and a transcript as speaker-labeled, timestamped utterances. Poll every ~10 minutes; a webhook (`POST /webhooks`, "new meeting content ready") is an easy later upgrade.

### Google Calendar

Read-only via `calendar.readonly`, desktop OAuth (loopback). Create the OAuth client in a Google Cloud project set to **Internal** user type under the 4Site Workspace org: internal apps skip Google's sensitive-scope review, and the 7-day refresh-token expiry that plagues External/Testing apps doesn't apply. `events.list` with `timeMin`/`timeMax` and `singleEvents=true`, incremental sync via `syncToken`. Supplies the day's schedule, attendees, Meet/Zoom links, and nudge-suppression windows, and catches meetings Fathom didn't record.

### Slack

A custom **internal** app in the 4Site workspace with user-token scopes: `channels:history`, `channels:read`, `groups:history`, `groups:read`, `im:history`, `im:read`, `mpim:history`, `mpim:read`, `users:read`, `users:read.email`. You have admin rights, so creation and approval are self-serve.

The rate-limit question mattered and the answer is favorable: Slack's May 2025 crackdown (1 request/minute, 15 objects on `conversations.history`/`conversations.replies`) applies to distributed non-Marketplace apps. Internal customer-built apps are explicitly exempt and keep roughly 50+ requests/minute with up to 1,000 objects per call. So plain polling works: refresh the conversation list every few minutes, pull history for conversations with fresh activity, capture your messages and enough surrounding context to know what the exchange was about. This also catches Slack work done from your phone, which screen watching never sees. Socket Mode/Events API is a later optimization, not a v1 need.

## 6. Store layer

SQLite through GRDB (the standard Swift SQLite wrapper), WAL mode, in `~/Library/Application Support/TidyTime/`. All API tokens in the macOS Keychain, never in config files. Config itself (org id, person id, browser choice, thresholds, recap time, sensitivity lists) is a readable JSON file so a future teammate setup is transparent.

Core tables, one line each:

| Table | Holds |
|---|---|
| `activity_samples` | app, window title, URL, timestamps from the watcher |
| `page_snapshots` | truncated page text, content-hashed, FK to sample |
| `sessions` | contiguous focused blocks derived from samples |
| `away_gaps` | idle/lock/sleep gaps + your one-tap attribution |
| `meetings` / `transcript_utterances` | Fathom meetings; speaker, text, timestamp rows |
| `calendar_events` | events, attendees, conference links |
| `slack_messages` | channel/DM messages captured via API |
| `pd_companies` / `pd_projects` / `pd_tasks` / `pd_time_entries` | the Productive cache |
| `entity_signals` | signal → client/project mappings (domains, channels, EN accounts, people), with provenance: bootstrapped, learned, or user-confirmed |
| `suggestions` | proposed entries: block refs, task match, minutes, note, confidence, status |
| `decisions` | every accept, edit, reassign, or toss: the training signal |
| `pools` | per-project micro-work accumulators |
| `ai_calls` | the AI usage ledger: job, provider, model, tokens, cost, outcome |

Retention job: raw `activity_samples`, `page_snapshots`, `slack_messages`, and transcript rows purge after 90 days; `sessions`, `suggestions`, `decisions`, and daily rollups persist.

## 7. Understand layer

### Sessionization

Raw samples collapse into sessions: contiguous time on one "context" (a client's EN admin, a Google Doc, a Slack DM thread, a Zoom call), tolerating brief detours under ~2 minutes. Sessions are the unit everything downstream classifies, pools, and rounds. Meetings get their own session type built from Fathom/calendar rather than screen samples.

### Entity resolution: the client registry

At setup, bootstrap `entity_signals` from Productive itself: company names, project names, task vocabulary. Then cross-reference what capture sees. Your naming is consistent across Productive, Slack, Fathom, and org email addresses, so most signals resolve automatically: a Slack channel or a meeting title carrying a client's name, an attendee's email domain, a client domain or staging URL, an Engaging Networks account name in a page title or page text. When a recurring signal (a domain seen daily, an unmatched channel) can't be resolved, the app asks once, in the recap: "Which client is `staging.example.org`?" Answer once, it's a rule forever. Rules born from your answers outrank inferred ones.

### Classification ladder

Each session climbs only as far as needed:

1. **Deterministic rules.** A session dominated by a signal already in `entity_signals` gets that client/project immediately. Zero cost, fully local, and over time most sessions land here, because the learning loop keeps promoting confirmed patterns into rules.
2. **Lexical matching.** Tokenized window titles, URLs, and page text scored against the Productive cache (client names, project names, task titles). High-margin matches classify; near-ties fall through.
3. **On-device model.** Apple's Foundation Models framework (macOS 26, Apple Intelligence enabled, ~3B parameter model) with guided generation: a `@Generable` struct forces `{client_id, project_id, task_id?, confidence, rationale}` from a compact session summary. The 4,096-token context window is the design constraint: prompts carry a distilled session digest plus only the shortlisted candidates from step 2, never raw dumps. Right-sized for this; it's exactly the summarization/extraction/classification work Apple says the model is built for. If Apple Intelligence is off, the ladder skips this rung.
4. **Economy cloud tier (Fireworks AI).** The workhorse for anything the local rungs can't settle: low-confidence session batches, first-pass transcript segmentation, and note drafting. Fireworks serves open-weight models behind an OpenAI-compatible API (`https://api.fireworks.ai/inference/v1`) with structured-output support, so one client library covers every model. Kimi K2.6 is confirmed there today at $0.95/M input and $4.00/M output tokens with a 262K context window, which swallows full transcripts whole; GLM-class models are interchangeable alternatives. Model names are config strings, not code, because this catalog churns. At these prices the app can afford to be liberal: a full day of transcripts plus session batches costs cents, so more content gets cloud-quality attribution without the spend anxiety. For an hour-long Fathom transcript this rung returns time-bounded topic segments mapped to clients ("14 minutes on Client A's donation page, 6 on Client B's audit, remainder internal"), each tied to utterance timestamps so the math is auditable.
5. **Claude escalation.** Claude gets a job only when rung 4 earns it: schema-invalid output after one retry, self-reported confidence below threshold, transcript segments that don't add up to the recording duration, or a result that contradicts a strong lexical prior. Plus a calibration sample: in the early weeks, a small percentage of rung-4 outputs get a Claude second opinion so you learn where the cheap models are trustworthy and where they aren't, then the sample rate dials down. Escalations carry the cheaper model's attempt in the prompt so Claude adjudicates rather than starts over.

Budget control sits across both cloud rungs: per-provider daily caps plus a global cap, and tripping any cap drops the app to local-only with a menu bar badge instead of failing silently.

Every suggestion records which rung produced it and why ("matched EN account 'exampleorg'", "transcript segment 00:12:40–00:26:55"), so trust is inspectable.

### AI usage ledger

Every call to rungs 3–5 writes a row to `ai_calls`: timestamp, job type (session batch, transcript split, note draft, calibration check, escalation), provider and model, input/output tokens, computed dollar cost (from a price table in config, editable when providers reprice), latency, and outcome (ok, retried, escalated, error). The dashboard turns this into the numbers you asked for: month-to-date AI overhead in dollars, cost by job type, escalation rate (the "is the cheap tier earning its keep" metric), and the share of work resolved free on-device. A CSV export gives you the overhead figure for internal accounting. Same data drives the tuning loop: if Kimi settles 90%+ of its jobs without escalation, shift more volume down; if a job type escalates constantly, its prompts need work or it belongs to Claude outright.

### Sensitivity gate

Runs before rungs 3 and 4 and before note generation. Local keyword/participant screen for personnel, performance, compensation, legal, plus a user-maintained list of flagged people and terms. Tripped content: never sent to any cloud model, suggestion defaults to the appropriate generic task (e.g. "1:1 check-in"), note stays bland. The gate fails closed; an over-cautious generic note costs you one manual edit, the opposite failure writes "discussed PIP for [name]" into a time log.

### Learning loop

Every recap action lands in `decisions`. Reassignments create or strengthen signal mappings (reassign `staging.example.org` twice, it's a rule). Edits to durations tune rounding bias. Dismissed nudges raise that context's nudge threshold. Recent decisions also ride along as few-shot examples in rungs 3 and 4. No model training, no embeddings in v1; rules plus examples get most of the value with none of the machinery.

## 8. Suggestion engine

**From sessions to proposed entries.** Classified sessions for a day group by task (or by project when no task matched), sum real minutes, and round to 15-minute increments with your slight round-up bias (configurable). Anything at or above the threshold (default 15 real minutes) becomes a standalone suggestion.

**Micro-work pools.** Sub-threshold fragments accumulate per project across the day. When a pool crosses 15 minutes, or at recap time, it becomes one rolled-up suggestion with an itemized note: "Slack: helped Nick debug ENgrid selector; reviewed staging link; replied to Sebrinia re: timeline." Pools are how the little things stop evaporating.

**Meeting splitting.** For each meeting, duration comes from Fathom recording start/end (not the calendar slot). Transcript segments produce per-client suggestions plus a remainder ("internal: weekly sync"). A 61-minute call becomes: 15 min Client A, 15 min Client B (rounded from 6 with your bias, flagged as rounded), 30 min internal, with segment timestamps attached. Unrecorded meetings fall back to the calendar slot and attendee/title signals.

**Gap analysis.** The recap compares reconstructed time against `pd_time_entries` already logged for that day, so it recommends only what's missing and flags disagreements ("you logged 1h on Task X; I saw about 2h15m") rather than double-suggesting.

**New-task proposals.** When work clearly belongs to a client but matches no open task (rung 3/4 says so and lexical scores agree), the suggestion proposes a task: project, suggested title, short description, all copy-ready. You create it in Productive; next sync picks it up and the suggestion re-links.

**Anatomy of a suggestion card.**

> **Client › Project › Task** (or "propose new task: …")
> 1h 15m · confidence ●●●○ · "why" line (rule/match/segment that produced it)
> Note: one to two sentences, editable
> [Copy note] [Copy all] [Open task in Productive] [Log it ✓] [Edit] [Reassign] [Toss]

"Log it ✓" marks it handled locally (feeds gap analysis and metrics); the actual entry is yours to make in Productive. "Copy all" puts duration + note on the clipboard together.

## 9. Surface layer

**Menu bar.** Icon states: capturing / paused / attention needed. Popover: today so far (observed vs. logged), pending suggestion count, pause capture, open recap.

**Nudges.** Fire only when a sustained block (default 25–30 min) classifies confidently to one client and nothing is logged there yet. Never during meetings or within a calendar event; hard daily cap (default 5); quiet hours respected. Delivered as a notification: accept (marks it, copies the note) or snooze to recap. Repeated dismissals for a context raise its threshold. Everything a nudge would have said waits in the recap anyway; ignoring nudges costs nothing.

**Away prompt.** On return from a gap: "Away 47 min: break, call, or something else?" One tap: break (discard), call + who/which client (becomes a suggestion), other (type a word, classify from that). Unanswered prompts queue into the recap. This is where unrecorded phone calls get rescued.

**End-of-day recap.** A window (not a cramped popover): left side, the day as a vertical timeline (sessions colored by client, meetings, away gaps, already-logged entries overlaid); right side, the suggestion stack sorted by confidence, pools and unresolved questions ("which client is this domain?") at the bottom. Work the stack top to bottom, copy-paste into Productive as you go, done. Target: under five minutes on a normal day. Fires at a configurable time (default 5:00 pm ET); if a day closes unreconciled, the same view opens for yesterday at your first activity next morning. Skipped days queue.

**Dashboard.** Four numbers for the week, one small chart: observed vs. logged, billable vs. internal split, per-client totals, capture health (% of active time attributed). Plus an AI overhead panel from the usage ledger: month-to-date spend, cost by job type, escalation rate, on-device share, CSV export. Local only.

**Settings.** Tokens (Keychain), thresholds, rounding bias, recap time, nudge cap, quiet hours, sensitivity lists, retention windows, per-provider budget caps and the model price table, model routing (which model handles which job), kill switches per source.

## 10. Permissions and one-time setup

1. Accessibility (window titles): System Settings prompt on first run
2. Automation → Chrome and System Events (Apple Events): prompted on first use; `NSAppleEventsUsageDescription` strings explain why
3. Chrome: View → Developer → "Allow JavaScript from Apple Events" (one toggle; app detects and walks you through it, degrades to URL+title if off)
4. Notifications, for nudges and prompts
5. Apple Intelligence enabled in System Settings (for the on-device model rung; optional)
6. Productive: generate personal token (Settings → API integrations), paste token + org id
7. Fathom: generate API key (User Settings → API Access), paste
8. Slack: create the internal app from a bundled manifest in the 4Site workspace, install, paste user token (guided, ~10 minutes, self-serve with your admin rights)
9. Google: create Internal-type OAuth client in the 4Site Workspace GCP project (guided), sign in once
10. Fireworks AI and Anthropic API keys, pasted into Keychain (not needed until Phase 6)
11. Screen Recording: **not requested**, deliberately

Signing: no paid developer account needed. Use a free Apple ID personal team (or a stable self-signed certificate) with a fixed bundle id, because macOS ties permission grants to the code signature; ad-hoc signatures that change on every rebuild silently strip Accessibility/Automation grants. This is a known gotcha with a boring, well-documented fix, and it goes in the project README on day one.

## 11. Build plan

Tooling: Xcode project generated from a YAML spec via XcodeGen, built with `xcodebuild`, so everything is drivable from the terminal, which is the Claude Code workflow. Swift Package Manager alone can't comfortably produce a real .app bundle with the Info.plist keys and signing this needs. Each phase below ends with something you use daily, and each acceptance check is something you can verify without reading Swift.

**Phase 0: Skeleton (days, not weeks).**
Repo, XcodeGen spec, menu bar app via `MenuBarExtra`, SQLite + migrations, config file + Keychain plumbing, launch at login, signing set up with a stable identity.
*Accept when:* icon lives in the menu bar, survives reboot, a `tidytime doctor` debug view shows DB path and permission status.

**Phase 1: Capture (weeks 1–2).**
App/window watcher, idle/away and lock/sleep handling, Chrome adapter (URL, title, page text incl. the toggle walkthrough), sessionization, retention job. From the day this lands, data is banking; every later phase gets smarter because this ran longer.
*Accept when:* a full workday reads back as a coherent session timeline in the debug view, including page-text snapshots, with CPU staying quiet and no gaps across sleep/lock.

**Phase 2: Productive mirror (weeks 2–3).**
Read-only sync: companies, projects (internal vs. client via `project_type_id`), your tasks, your time entries; person-id resolution at setup; task deep-link pattern captured from the web app. Menu bar popover shows today's logged total.
*Accept when:* the local cache matches what Productive's UI shows for your week, and clicking a cached task opens it in Productive.

**Phase 3: Meetings and calendar (weeks 3–4).**
Google OAuth (Internal type) + calendar sync; Fathom polling with transcripts; meeting sessions with Fathom-true durations; away prompt; entity-signal bootstrap from Productive + attendee domains.
*Accept when:* yesterday's meetings appear with real recorded durations and attendees, and coming back from a long gap asks you about it.

**Phase 4: Slack (week 4).**
Internal app manifest, guided install, polling ingest of DMs/channels, Slack sessions merged into the timeline, pool seeding for drive-by help.
*Accept when:* a morning of Slack activity shows up attributed to the right conversations, including messages sent from your phone.

**Phase 5: Recap and rules (weeks 5–6).**
Ladder rungs 1–2 (rules + lexical), suggestion engine (rounding, pools, gap analysis, new-task proposals), recap window with timeline + card stack, copy buttons, morning catch-up, ask-once resolution questions, decisions recorded. This is the first version that answers "what did I miss today?" end to end, before any AI is involved.
*Accept when:* you reconcile a real day in under ten minutes and at least one forgotten billable block from that week made it into Productive because the recap caught it.

**Phase 6: Intelligence (weeks 6–8).**
Sensitivity gate (ships before or with the first cloud call), on-device model rung with guided generation, the provider router and usage ledger (ships with the first cloud call, not after), economy tier on Fireworks with batching, Claude escalation and calibration sampling, transcript splitting, nudges, learning loop promotions, dashboard.
*Accept when:* an hour-long mixed call yields correct per-client splits with timestamped rationale; a seeded sensitive phrase in a test transcript produces a generic suggestion and appears in no cloud payload (verifiable via a local log of outbound request bodies); every cloud call appears in the usage ledger with tokens and a cost that reconciles against the provider dashboards; nudges stay under the daily cap and stop poking where you've dismissed them.

Pace assumes evenings-and-gaps effort with Claude Code doing the heavy lifting; whole weeks may compress if you get runs of focused time. Order is deliberately capture-first: by the time Phase 6 tunes suggestion quality, there are 4+ weeks of your real history to tune against.

## 12. Risks

- **Permission fragility.** TCC grants dropping on rebuild is the classic trap; the stable-signing rule prevents it, and `tidytime doctor` makes any loss visible instead of silent
- **Chrome scripting changes.** `execute javascript` via Apple Events has been stable for years but is Google's to break; the fallback (URL + title only) keeps the app functional, and the extension route (native messaging) is the durable successor when other browsers arrive
- **On-device model availability.** Requires Apple Intelligence enabled; if off, the ladder skips to the cloud tiers, costing pennies more. The 4,096-token window is respected by design (digests, not dumps)
- **Economy-tier quality and catalog churn.** Open-weight models vary by task and Fireworks' lineup changes; the router treats model names as config, the calibration sample measures each model against Claude on your real data, and escalation catches individual failures. More content also flows to a third cloud provider than in the Claude-only design, which is the accepted trade for volume; the sensitivity gate applies identically to every cloud call
- **Slack policy drift.** Internal-app exemption from the 2025 rate limits is explicit today; if it ever tightens, polling cadence stretches and the Events API path exists
- **Attribution cold start.** Weeks 1–2 of suggestions will ask more questions and deserve more corrections; that's the learning loop's diet, not a failure. The recap is designed so a wrong guess costs one tap
- **Scope creep toward automation.** The line is bright: v1 never writes to Productive. The moment that changes (v2's approve button), write scope, audit logging, and undo get designed properly rather than bolted on
- **Privacy blast radius.** Everything sensitive stays in one SQLite file on one Mac, encrypted at rest by FileVault, purged on schedule; cloud payloads are distilled summaries post-gate. Worth stating internally when teammates adopt it

## 13. After v1

Roughly in order of likely value: write access with an approve button (entry lands in Productive on your explicit tap, using the same token upgraded to read/write); team rollout (config profiles, a setup doc, maybe a shared entity-signal starter pack per client); Safari/Firefox/Dia adapters via a WebExtension + native messaging; dynamic recap timing learned from your actual wind-down; weekly digest and billable targets; Fathom webhooks instead of polling; and the Productive-embedded UI surface you flagged from the start, which becomes practical once suggestions have a proven accuracy record worth putting inside Productive's chrome.

## 14. Open items

1. Confirm your Fathom plan includes API access (Settings → API Access showing a key-generation option answers it)
2. Capture the Productive task deep-link pattern from the web app (30 seconds, Phase 2)
3. Verify the exact Slack user-scope list at app-manifest time (names above are standard; the manifest editor validates)
4. Fireworks AI and Anthropic API keys for the cloud rungs, and whose accounts they bill to (yours vs. 4Site org keys); the usage ledger gives you the overhead number either way
5. Keep or replace the TidyTime name

## 15. Sources

Vendor documentation consulted July 23, 2026:

- Productive API: developer.productive.io (auth/index), developer.productive.io/time_entries.html, /tasks.html, /projects.html; rate limits and pagination from developer-old.productive.io
- Fathom API: developers.fathom.ai (api-overview.md, quickstart.md, api-reference/meetings/list-meetings.md, llms.txt index)
- Slack: docs.slack.dev changelog "Rate limit changes for non-Marketplace apps" (May 29, 2025) and scopes reference
- Google: developers.google.com/identity/protocols/oauth2 (refresh-token expiry in Testing status), developers.google.com/workspace/guides/configure-oauth-consent (Internal apps and sensitive scopes)
- Apple: machinelearning.apple.com "Apple Foundation Models 2025 updates" (~3B on-device model, guided generation, task fit); TN3193 and community documentation of the 4,096-token context window; Apple Developer forum threads on ad-hoc signing and TCC permission loss
- Chrome scripting: current community documentation of `execute javascript` and the "Allow JavaScript from Apple Events" toggle (2025)
- Fireworks AI: OpenAI-compatible endpoint, structured outputs, and Kimi K2.6 availability/pricing ($0.95/M in, $4.00/M out, 262K context) per current third-party provider references; confirm live pricing at fireworks.ai when the account is created
