# Permissions & one-time setup

The one-time **human** checklist to bring a fresh Mac from clone to fully-capturing TidyTime:
every OS permission, vendor token, and account this app needs, in the order to do them, with the
exact click-path for each and where its secret lands. Expands [PLAN.md](../PLAN.md) §10.

**Related:** [docs index](README.md) · [PLAN.md](../PLAN.md) §10 ·
[build/signing-and-tcc.md](build/signing-and-tcc.md) (signing prerequisite) ·
[reference/macos-permissions-tcc.md](reference/macos-permissions-tcc.md) ·
[reference/slack-api.md](reference/slack-api.md) · [guardrails.md](guardrails.md) ·
[open-items.md](open-items.md)

**Status:** build-ready checklist · **Applies to:** first-run setup (Phase 0 → Phase 6) ·
**Secrets rule:** every token/key below goes in the **macOS Keychain** via `TidyCore`'s
`SecretStore` — never in `config.json`, the DB, logs, or fixtures (guardrail
[G6](guardrails.md#g6--secrets-live-in-the-keychain-only)) · **Last verified:** 2026-07-23

---

## 0. Prerequisite — stable signing (do this FIRST, before granting anything)

**Why first:** macOS keys every Accessibility/Automation grant to the app's **code signature**
(guardrail [G7](guardrails.md#g7--stable-code-signature-tcc-durability)). If you grant
Accessibility to an ad-hoc build and then rebuild with a rotating signature, macOS treats it as a
different app and **silently revokes** the grant — you would redo steps 1–2 on every build. Set up
a stable identity + the fixed bundle id `com.4site.TidyTime` **before** touching any TCC prompt.

- Full procedure (free Apple ID personal team or a stable self-signed cert, committed signing base
  + gitignored `Local.xcconfig`): **[build/signing-and-tcc.md](build/signing-and-tcc.md)**.
- No paid Apple Developer account is required.
- Verify signing is stable before proceeding: build twice and confirm
  `codesign -dvvv TidyTime.app` reports the **same** identifier + authority both times.

> ⚠️ Build-time check: if a previously-working grant disappears after a rebuild, the signature
> changed — fix signing, don't re-grant blindly. `tccutil reset All com.4site.TidyTime` clears
> stale grants for a clean re-test ([reference/macos-permissions-tcc.md](reference/macos-permissions-tcc.md) §7).

### Secrets → Keychain map (fill as you go)

All items live under Keychain service `com.4site.TidyTime` via `SecretStore`
([module-map](architecture/module-map.md#protocol-seams-the-extension-points),
`KeychainSecretStore`). Account names below are the **suggested convention** (confirm against the
`SecretStore` keys the app actually reads — see [open-items.md](open-items.md)).

| Step | Secret | Keychain account (convention) | Non-secret companion in `config.json` |
|---|---|---|---|
| 6 | Productive personal token | `productive_token` | `organization.productive_organization_id` |
| 7 | Fathom API key | `fathom_api_key` | — |
| 8 | Slack user token (`xoxp-…`) | `slack_user_token` | — |
| 9 | Google OAuth **refresh** token | `google_refresh_token` | OAuth *client id* is non-secret config |
| 10 | Fireworks API key (`fw_…`) | `fireworks_api_key` | model slug + prices in `ai.*` |
| 10 | Anthropic API key (`sk-ant-…`) | `anthropic_api_key` | model slug + prices in `ai.*` |

The Google OAuth **client secret** for a Desktop-type client is not a true secret (it ships in the
app), but the **refresh token** minted after first consent is — it goes in the Keychain
([reference/google-calendar-api.md](reference/google-calendar-api.md)).

---

## 1. Accessibility — window titles

Lets the watcher read the focused window's title via the Accessibility API (`AXUIElement`), which
is how we get titles **without** Screen Recording (guardrail
[G3](guardrails.md#g3--no-screen-recording-permission-is-ever-requested)).

**Click-path**
1. Launch TidyTime. On first run it calls `AXIsProcessTrustedWithOptions` and a system prompt
   appears; click **Open System Settings**.
2. **System Settings → Privacy & Security → Accessibility**.
3. Find **TidyTime** in the list and toggle it **on** (unlock with Touch ID / password if needed).
4. If the app's `doctor` view still shows Accessibility = `false`, **quit and relaunch** — some
   macOS versions only reflect the grant after a relaunch (⚠️ Build-time check, per
   [reference/macos-permissions-tcc.md](reference/macos-permissions-tcc.md) §1).

**Secret:** none — pure user grant, no Info.plist string, no Keychain item.
**Verify:** `make doctor` → Accessibility = `ok`.

---

## 2. Automation (Apple Events) → Google Chrome & System Events

Lets TidyTime send Apple Events to read Chrome's active-tab URL/title/text and (for meeting-state
inference) query System Events. TCC keys this **per target app**, so each prompts separately.

**Click-path**
1. With Chrome open and frontmost, trigger a capture (just use Chrome for a moment). macOS shows
   **"TidyTime wants access to control Google Chrome."** Click **OK**. The
   `NSAppleEventsUsageDescription` string explains why (read-only, never controls the browser).
2. The first time meeting-state inference runs, the same prompt appears for **System Events** →
   click **OK**.
3. To review/repair later: **System Settings → Privacy & Security → Automation** → expand
   **TidyTime** → ensure **Google Chrome** and **System Events** are checked.

**Secret:** none — TCC grant tied to the signature (see step 0).
**Verify:** `make doctor` → Automation → Chrome = `ok`, Automation → System Events = `ok`.

> Denial returns `errAEEventNotPermitted` (`-1743`); the app degrades (URL+title only, or no
> meeting-state) rather than crashing. Re-enable in the Automation pane above.

---

## 3. Chrome — "Allow JavaScript from Apple Events" (for visible page text)

This is a **Chrome-side toggle, not a TCC permission.** It unlocks `execute javascript`, which is
how the Chrome adapter reads `document.body.innerText` for `page_snapshots`. Without it, capture
degrades **silently** to URL + title only ([reference/chrome-scripting.md](reference/chrome-scripting.md) §3).

**Click-path**
1. In **Google Chrome**, menu bar → **View → Developer → "Allow JavaScript from Apple Events"** →
   click it so it shows a **checkmark**.
   - The **Developer** submenu lives under **View**; if you don't see it, it's near the bottom of
     the View menu.
2. No restart needed. TidyTime detects the toggle state on next capture.

**Secret:** none.
**Verify:** `make doctor` → Chrome JS = `ok` (the app runs a benign `execute javascript "1"` probe
and expects `"1"` back; a `turned off` error means the toggle is still off).

---

## 4. Notifications — nudges & away prompts

Lets nudges and the away prompt surface as system notifications. Managed by
`UNUserNotificationCenter` (**not** TCC), so it lives under a different Settings pane.

**Click-path**
1. The first time a nudge or away prompt would fire, macOS prompts **"TidyTime would like to send
   you notifications."** Click **Allow**.
2. To adjust later: **System Settings → Notifications → TidyTime** → enable **Allow
   Notifications** (Alerts style recommended).

**Secret:** none.
**Verify:** `make doctor` → Notifications = `authorized`.

> Denial loses nothing critical — everything a nudge would say still waits in the recap
> ([PLAN.md](../PLAN.md) §9). ⚠️ Build-time check: authorization prompts can behave differently for
> a `MenuBarExtra`/agent-style app; confirm the prompt appears on the target macOS.

---

## 5. Apple Intelligence — on-device model rung (OPTIONAL)

Enables classification-ladder **rung 3** (Apple Foundation Models, on-device, free). Optional: if
off, the ladder simply skips rung 3 and falls through to the cloud tiers, costing pennies more
([reference/apple-foundation-models.md](reference/apple-foundation-models.md)). Requires
**macOS 26+** and eligible hardware (M-series).

**Click-path**
1. **System Settings → Apple Intelligence & Siri** → turn **Apple Intelligence on** (first enable
   downloads the model; `.unavailable(.modelNotReady)` until it finishes — the app treats that as
   "skip rung 3" and retries later).
2. Nothing to enter in TidyTime; the app probes `SystemLanguageModel.default.availability` at
   runtime and shows the result in the `doctor` view.

**Secret:** none (on-device, no key — exempt from G6).
**Verify:** `doctor` view shows the on-device model as available; the AI dashboard later reports a
non-zero "share resolved free on-device."

> ⚠️ Build-time check: exact Settings pane label and availability enum cases can shift between
> macOS betas ([reference/apple-foundation-models.md](reference/apple-foundation-models.md)).

---

## 6. Productive — personal token + organization id

Read-only mirror of companies, projects, tasks, time entries, people
([reference/productive-api.md](reference/productive-api.md)). v1 is **GET-only**, guardrail
[G1](guardrails.md#g1--v1-never-writes-to-productive).

**Click-path**
1. In the Productive web app: **Settings → API integrations → Generate new token**. Copy the token.
2. Note your **Organization Id** (numeric) — it's on the same Settings page and in the web-app URL.
3. In TidyTime **Settings**, paste the **token** (→ Keychain) and the **organization id** (→
   `config.json` `organization.productive_organization_id`; it is non-secret).

**Secrets:** token → Keychain (`productive_token`); auth headers are `X-Auth-Token` +
`X-Organization-Id`. Org id → `config.json`.
**Verify:** setup resolves your own `person_id` (a `GET /people?filter[email]=…`) and the popover
shows today's logged total (Phase 2 acceptance).

> While you're in the web app, also grab the **task deep-link pattern** (open any task, copy the
> URL) for `config.productive.task_deep_link_pattern` — tracked in [open-items.md](open-items.md).

---

## 7. Fathom — API key

Meeting recordings + transcripts; recording start/end is ground truth for meeting duration
([reference/fathom-api.md](reference/fathom-api.md)).

**Click-path**
1. In Fathom: **User Settings → API Access → Generate key**. Copy the key.
   - If **API Access** does not appear, your plan tier may not include API access — see
     [open-items.md](open-items.md) item 1; TidyTime falls back to calendar-only meetings.
2. In TidyTime **Settings**, paste the key.

**Secret:** key → Keychain (`fathom_api_key`); auth header is `X-Api-Key`.
**Verify:** a live `GET /meetings` returns `200`; yesterday's meetings appear with recorded
durations (Phase 3 acceptance).

---

## 8. Slack — internal app (manifest → install → user token)

A **custom internal app** in the 4Site workspace with **user-token** scopes, polled read-only
([reference/slack-api.md](reference/slack-api.md)). You have workspace admin, so this is self-serve
(~10 min). No bot user, no posting — every scope is `:read`/`:history`.

**Click-path**
1. Go to <https://api.slack.com/apps> → **Create New App → From an app manifest**.
2. Select the **4Site** workspace.
3. Paste the **JSON** manifest below → **Next → Create**.
   > ⚠️ Slack's manifest editor is **JSON-only** in the current UI. An earlier version of this doc
   > led with a YAML manifest (with `#` comments); pasting that yields "invalid format".
4. Left nav → **Install App → Install to Workspace** → **Allow**.
5. Left nav → **OAuth & Permissions** → copy the **User OAuth Token** (starts with `xoxp-`).
6. In TidyTime **Settings → Credentials**, paste the `xoxp-…` token (goes to the Keychain).

**Ready-to-paste manifest (JSON).** Deliberately minimal — it mirrors Slack's own reference
structure exactly. Optional fields (`description`, `background_color`, `interactivity`) are omitted
on purpose: they add validator surface for no benefit, and their presence was the likely cause of a
reported "invalidly formatted" rejection.

```json
{
    "display_information": {
        "name": "TidyTime"
    },
    "oauth_config": {
        "scopes": {
            "user": [
                "channels:read",
                "channels:history",
                "groups:read",
                "groups:history",
                "im:read",
                "im:history",
                "mpim:read",
                "mpim:history",
                "users:read",
                "users:read.email"
            ]
        }
    },
    "settings": {
        "org_deploy_enabled": false,
        "socket_mode_enabled": false,
        "is_hosted": false,
        "token_rotation_enabled": false
    }
}
```

Two details that matter:
- Scopes go under **`user`**, not `bot`. A bot token only sees channels it's invited to; the point
  here is the installer's own DMs and channels.
- **`token_rotation_enabled: false`** — rotation issues short-lived tokens that must be refreshed,
  and `LiveSlackClient` does not implement refresh. Enabling it will break auth after ~12h.

### Fallback if the manifest is rejected (always works)

Manifest schemas drift; the UI never does. Create the app **From scratch**, then:

1. **OAuth & Permissions** → **User Token Scopes** (*not* Bot Token Scopes) → add the ten scopes
   above one at a time. Slack validates each as you add it, so a renamed/deprecated scope shows up
   immediately instead of as an opaque whole-manifest failure.
2. **Install to Workspace** → **Allow** → copy the **User OAuth Token** (`xoxp-…`).

**Secret:** `xoxp-…` user token → Keychain (`slack_user_token`); auth header is
`Authorization: Bearer xoxp-…`.
**Verify:** `auth.test` returns your `user_id`; a morning of Slack activity (including messages
sent from your phone) shows up attributed (Phase 4 acceptance).

> ⚠️ Build-time check: the manifest editor validates scope names on paste — confirm all ten are
> accepted and none is renamed/deprecated ([reference/slack-api.md](reference/slack-api.md) §2,
> [open-items.md](open-items.md) item 3). A missing `*:history` scope surfaces later as
> `{"ok":false,"error":"missing_scope"}`.

---

## 9. Google Calendar — Internal-type OAuth client (then sign in once)

Read-only calendar via OAuth 2.0 (loopback + PKCE), scope `calendar.readonly`. The client **must**
be created **Internal**-type in the 4Site Workspace GCP project so `calendar.readonly` skips
Google's sensitive-scope review **and** the refresh token does not expire every 7 days
([reference/google-calendar-api.md](reference/google-calendar-api.md) §2).

**Click-path (Google Cloud Console, signed in as a 4Site Workspace admin/user)**
1. **Select or create a project** inside the 4Site Workspace org (top project picker → your org).
2. **APIs & Services → Library** → search **Google Calendar API** → **Enable**.
3. **APIs & Services → OAuth consent screen** → **User type: Internal** → **Create** → fill app
   name (e.g. "TidyTime"), support email, developer email → **Save**. (Internal = no sensitive-scope
   verification, no Testing/Publishing gate.)
4. **APIs & Services → Credentials → Create Credentials → OAuth client ID** → **Application type:
   Desktop app** → name it → **Create**.
5. Copy the **Client ID** (and client secret — for a Desktop client this is not a true secret) into
   the app's Google config.
6. In TidyTime **Settings → Connect Google**, click sign-in: the app opens the system browser on a
   loopback redirect, you consent once, and it exchanges the code (PKCE) for tokens.

**Secret:** the **refresh token** minted after consent → Keychain (`google_refresh_token`). The
client id is non-secret config.
**Verify:** `events.list` returns the day's events; `syncToken` incremental sync works; meetings
Fathom didn't record still appear (Phase 3).

> ⚠️ Build-time check: an **External + Testing** client would silently lose access every 7 days —
> Internal is the whole point. Confirm the consent screen shows **Internal** before creating the
> client ([reference/google-calendar-api.md](reference/google-calendar-api.md) §2).

---

## 10. Fireworks AI + Anthropic — cloud AI keys (NOT needed until Phase 6)

The cloud rungs: Fireworks serves BOTH the economy tier (rung 4) and escalation (rung 5) by default
(ADR 0013), so only a Fireworks key is required. An Anthropic key is optional — needed only if you
switch `ai.routing.escalation` to the direct Claude path. Skip
until Phase 6; the app runs the full local ladder (rungs 1–3) without them.

**Click-path — Fireworks**
1. Sign in at <https://fireworks.ai> → **API Keys** → create a key (prefix `fw_`).
2. Confirm the live model slug + pricing at <https://fireworks.ai/models> (catalog churns) and
   update `config.json` `ai.models.fireworks-economy.model` +
   `ai.prices_usd_per_mtok` if they differ from the defaults
   ([reference/fireworks-ai.md](reference/fireworks-ai.md)).
3. In TidyTime **Settings**, paste the Fireworks key.

**Click-path — Anthropic**
1. Sign in at <https://console.anthropic.com> → **API keys** → create a key (prefix `sk-ant-`).
2. Set `ai.prices_usd_per_mtok["claude-opus-4-8"]` (input/output) — it ships **null**
   ([config.example.json](../config.example.json)); the ledger needs real numbers to compute
   `cost_usd` ([open-items.md](open-items.md)).
3. In TidyTime **Settings**, paste the Anthropic key.

**Secrets:** `fw_…` → Keychain (`fireworks_api_key`, header `Authorization: Bearer fw_…`);
`sk-ant-…` → Keychain (`anthropic_api_key`, headers `x-api-key` + `anthropic-version`). Model slugs,
prices, routing, and budget caps are **non-secret** `config.json` (`ai.*`).
**Verify:** first cloud call writes an `ai_calls` row whose `cost_usd` reconciles against the
provider dashboard; budget caps drop the app to local-only when tripped (Phase 6 acceptance,
guardrail [G5](guardrails.md#g5--every-cloud-ai-call-is-metered-and-capped)).

> ⚠️ Build-time check: **whose account bills** (your personal vs. 4Site org keys) is unresolved —
> [open-items.md](open-items.md) item 4. The usage ledger gives the overhead number either way.

---

## 11. Screen Recording — NOT requested (by design)

TidyTime **never** requests Screen Recording (`kTCCServiceScreenCapture`). It captures no screen
pixels and reads no window bitmaps; window titles come solely from Accessibility (step 1). This is
guardrail [G3](guardrails.md#g3--no-screen-recording-permission-is-ever-requested), enforced by a
grep test that fails on any `CGWindowList*` window-name usage. **If the setup flow ever asks for
Screen Recording, that is a bug — do not grant it.**

There is nothing to do here. Listed only so that a reviewer confirming the permission surface knows
its absence is intentional. `make doctor` prints Screen Recording = "not requested."

---

## Final acceptance — the whole surface at a glance

Run `make doctor` (or open the in-app doctor view). A correctly set-up machine shows:

| Item | Expected | Set in step |
|---|---|---|
| Accessibility | `ok` | 1 |
| Automation → Chrome | `ok` | 2 |
| Automation → System Events | `ok` | 2 |
| Chrome "Allow JavaScript from Apple Events" | `ok` | 3 |
| Notifications | `authorized` | 4 |
| Apple Intelligence (on-device rung) | available *(optional)* | 5 |
| Productive token + org id | resolves `person_id` | 6 |
| Fathom key | `GET /meetings` → 200 | 7 |
| Slack `xoxp-…` token | `auth.test` → your `user_id` | 8 |
| Google refresh token | `events.list` → 200 | 9 |
| Fireworks + Anthropic keys | first `ai_calls` row (Phase 6) | 10 |
| Screen Recording | "not requested" | 11 |

All secrets are in the Keychain (guardrail [G6](guardrails.md#g6--secrets-live-in-the-keychain-only));
`config.json` holds only non-secret settings and is gitignored. Grants survive rebuilds because the
signature is stable (step 0 / [build/signing-and-tcc.md](build/signing-and-tcc.md)).
