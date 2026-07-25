# Glossary

Domain terms used across the docs and code. When a term maps to a table or type, the name is
given so the vocabulary stays consistent.

## Product & domain

- **TidyTime** — this app. Working name; part of the "Tidy" family (see *TidyContact*).
- **TidyContact** — a sibling 4Site product; TidyTime borrows its naming convention, nothing else.
- **4Site / 4Site Studios** — the organization; the Slack workspace and Google Workspace org
  the internal apps are created in. Client work is done here.
- **Bryan** — the first user; the personal build targets his workflow before team rollout.

## Productive (the billing system we mirror)

- **Productive** — the project-management / time-tracking SaaS TidyTime suggests entries for.
  JSON:API at `api.productive.io`. See [reference/productive-api.md](reference/productive-api.md).
- **Company** — Productive's term for a **client** (also an internal "company"). Cached as
  `pd_companies`. In TidyTime UX we say *client*.
- **Project** — a body of work under a company. Cached as `pd_projects`. `project_type_id`
  distinguishes **internal** (`1`) from **client/deliverable** (`2`) work.
- **Task** — the unit an entry resolves to. Cached as `pd_tasks` (title, description, task
  number, status, task list, assignee).
- **Time entry** — a logged block: `time` (minutes), `date`, `note`, `billable_time`, task/
  service relationships. Cached as `pd_time_entries`; the "already logged" side of gap analysis.
- **Service / Budget** — Productive concepts **out of scope for v1** attribution.
- **Person** — a Productive user; we resolve the user's own `person_id` at setup (`pd_people`).
- **Deep link** — the web-app URL that opens a task. Pattern isn't in the API; captured once
  from the web app and stored in config (`⚠️ Build-time check`).

## Attribution model

- **Attribution hierarchy** — **client → project → task**, in that order.
- **Session** — a contiguous block of focused time on one *context* (a client's admin, a
  Google Doc, a Slack thread, a meeting), tolerating brief detours. Table `sessions`. The unit
  everything downstream classifies, pools, and rounds.
- **Context** — the "what am I working on" a session is about; resolves to a client/project.
- **Entity signal** — a mapping from an observable (email domain, Slack channel, staging URL,
  Engaging Networks account name, person) to a client/project, with **provenance**
  (bootstrapped / learned / user-confirmed). Table `entity_signals`. User-confirmed rules
  outrank inferred ones.
- **Rung** — a level of the [classification ladder](architecture/classification-ladder.md):
  1 rules, 2 lexical, 3 on-device model, 4 economy cloud, 5 escalation (a stronger model, same vendor by default — ADR 0013).
- **Sensitivity gate** — the local screen that keeps personnel/comp/legal/flagged content out
  of cloud payloads; **fails closed**. See [guardrails.md](guardrails.md) G2.
- **Pool** — a per-project accumulator for sub-threshold *micro-work* fragments that roll up
  into one itemized suggestion. Table `pools`.
- **Micro-work** — short interruptions (a Slack answer, a quick review) below the standalone
  threshold (default 15 real minutes) that would otherwise evaporate; captured via pools.
- **Suggestion** — a proposed time entry (task match, minutes, note, confidence, rung,
  status). Table `suggestions`. Rendered as a *suggestion card*.
- **Decision** — the user's action on a suggestion (accept / edit / reassign / toss / log).
  Table `decisions`. The training signal for the learning loop.
- **Gap analysis** — comparing reconstructed time against `pd_time_entries` already logged for
  a day, so only missing time is suggested and disagreements are flagged.
- **New-task proposal** — a suggestion for work that belongs to a client but matches no open
  task; proposes project + title + description, copy-ready.
- **Away gap** — an idle/lock/sleep interval; the user attributes it via the *away prompt*.
  Table `away_gaps`.

## Capture & sources

- **Watcher** — the capture component subscribing to app-activation and reading window titles
  via Accessibility. Writes `activity_samples`.
- **Browser adapter** — the `BrowserAdapter` protocol; v1 has one implementation, **Chrome**,
  via AppleScript/Apple Events. Safari/Firefox/Dia are post-v1.
- **Page snapshot** — truncated (~4 KB), content-hashed `document.body.innerText` of the
  active tab. Table `page_snapshots`.
- **Fathom** — meeting recorder/transcriber; its **recording start/end is ground truth for
  meeting duration**. See [reference/fathom-api.md](reference/fathom-api.md). Tables
  `meetings`, `transcript_utterances`.
- **Meeting split** — dividing a meeting's real duration into per-client segments from the
  transcript, plus an internal remainder.
- **Heartbeat** — the periodic (30 s) sample the watcher emits even without an app switch.

## AI

- **Classification ladder** — the local-first → cheap → smart escalation path (rungs 1–5).
- **On-device model** — Apple Foundation Models (~3B, macOS 26 + Apple Intelligence), used
  with **guided generation** (`@Generable`). 4,096-token context → digests, not raw dumps.
- **Economy cloud tier** — Fireworks AI serving open-weight models (Kimi K2.6, GLM-class)
  behind an OpenAI-compatible API; the cloud workhorse. Model names are **config**, not code.
- **Escalation (rung 5)** — a stronger adjudicator, invoked only when the economy tier earns it
  (schema-invalid, low confidence, transcript math doesn't reconcile, contradicts a strong
  prior) plus a decaying **calibration sample**.
- **Calibration sample** — a small, decaying fraction of economy-tier outputs given a Claude
  second opinion to measure where cheap models are trustworthy.
- **AI usage ledger** — table `ai_calls`; every cloud call's provider/model/tokens/cost/outcome.
- **Budget cap** — per-provider daily + global spend limits; tripping one → local-only mode.

## Surface

- **Nudge** — a rate-limited, meeting-aware live notification when a sustained block classifies
  confidently and isn't logged yet. Learns from dismissals.
- **Recap** — the end-of-day (configurable time) window: timeline on the left, suggestion
  stack on the right. Unreconciled days queue to the next morning.
- **Dashboard** — weekly metrics (observed vs. logged, billable vs. internal, per-client
  totals, capture health) + AI overhead panel. Local only, **no targets**.
- **Doctor** — the in-app debug view (and `make doctor`) showing DB path, config path, and
  permission status; makes dropped TCC grants visible.

## Platform / build

- **TCC** — Apple's Transparency, Consent & Control: the permission system behind
  Accessibility, Automation, Notifications. Grants are keyed to the **code signature**.
- **XcodeGen** — generates `TidyTime.xcodeproj` from `project.yml`, so the build is
  terminal-drivable.
- **GRDB** — the Swift SQLite toolkit used for the store (WAL mode, `DatabaseMigrator`).
- **`SMAppService`** — the API for launch-at-login (no login-item helper needed).
- **Engaging Networks (EN)** — a digital-engagement/fundraising platform 4Site builds on;
  **ENgrid** is 4Site's page-template framework for EN. EN **account names** and staging URLs
  are strong client signals that show up in page titles and page text.
