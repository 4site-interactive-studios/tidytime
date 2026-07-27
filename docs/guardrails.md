# Guardrails

**Status:** normative · **Applies to:** every phase · **Last reviewed:** 2026-07-23

These are the invariants the product's trust depends on. Each one is stated, justified, and
paired with *how it is enforced in code* — because "we'll be careful" is not an enforcement
mechanism. Every guardrail here should have a corresponding test in
`Packages/TidyKit/Tests/` (see [build/testing-strategy.md](build/testing-strategy.md)); if it
doesn't yet, adding it is part of the phase that introduces the risk.

---

## G1 — v1 never writes to Productive

**Rule.** No `POST`, `PUT`, `PATCH`, or `DELETE` request is ever issued to
`api.productive.io`. The Productive token is used for `GET` only. The entire value
proposition is "suggest, human enters"; writing is v2 and gets audit logging + undo designed
properly ([decisions/0001-read-only-productive-v1.md](decisions/0001-read-only-productive-v1.md)).

**Enforcement.**
- The Productive client type in `TidyIngest` exposes **no** mutating methods — there is no
  code path that builds a non-GET `URLRequest` for the Productive host.
- A guardrail unit test asserts that the Productive client's request builder rejects/aborts
  any method other than `GET` (fail loudly in `DEBUG`).
- "Log it ✓" in the recap marks a suggestion handled **locally only** (`suggestions.status`);
  it never calls Productive.

## G2 — The sensitivity gate fails closed

**Rule.** Before any content is placed in a payload bound for a **cloud** model (Fireworks or
Anthropic), and before any note is generated, it passes the local sensitivity gate. Tripped
content (personnel, compensation, performance, legal, plus the user's flagged people/terms)
is **never** transmitted: the suggestion falls back to a generic task and a bland note, and
the work is resolved locally or left unclassified. Uncertainty resolves to **sensitive**.

**Enforcement.**
- The gate is a mandatory step in the cloud path, not an optional filter — cloud clients in
  `TidyAI` accept only `GatedPayload` values that can be produced solely by the gate.
- An **outbound-payload log** (local, `DEBUG`/opt-in) records the exact bytes sent to each
  cloud provider, so a test can seed a known sensitive phrase in a fixture transcript and
  assert it appears in **no** outbound payload (Phase 6 acceptance criterion).
- The gate's keyword/participant lists are user-editable in Settings but ship with sane
  defaults; an empty list never disables the gate.
- On-device model calls (Apple Foundation Models) stay on-device and are exempt from
  transmission concerns, but note generation still respects the generic-fallback rule.

## G3 — No Screen Recording permission is ever requested

**Rule.** Window titles are read via the Accessibility API (`AXUIElement`, focused window
title attribute). We deliberately avoid `CGWindowListCopyWindowInfo`'s `kCGWindowName`, which
triggers the Screen Recording (`kTCCServiceScreenCapture`) permission. Requesting Screen
Recording is a design failure, not a shortcut.

**Enforcement.**
- The app declares no Screen Recording usage and the capture code contains no
  `CGWindowList*` name-reading call.
- A guardrail test / lint check greps the `TidyCapture` sources for `CGWindowList` and fails
  if the window-name field is used.

## G4 — Local-first, then cheap, then smart

**Rule.** Classification climbs the ladder (rules → lexical → on-device → economy cloud →
Claude) only as far as needed. A session a rule or a high-margin lexical match can settle
**must not** reach a cloud model. See [architecture/classification-ladder.md](architecture/classification-ladder.md).

**Enforcement.**
- The router short-circuits: a confident result at any rung returns immediately; higher rungs
  are only invoked on explicit fall-through conditions.
- Every suggestion records the rung that produced it (`suggestions.produced_by_rung`); a
  dashboard metric tracks the share resolved on-device/free, and a spike in cloud share is a
  visible regression.

## G5 — Every cloud AI call is metered and capped

**Rule.** Each call to a cloud rung writes a row to `ai_calls` (provider, model, job type,
input/output tokens, computed cost, latency, outcome). Per-provider daily caps and a global
cap bound spend; tripping a cap drops the app to **local-only** with a visible menu bar
badge — never a silent failure, never an uncapped spend.

**Enforcement.**
- Cloud clients in `TidyAI` route through a single metered call site; there is no path that
  reaches a provider without writing a ledger row.
- The budget check is evaluated **before** dispatch; over-cap requests are refused and logged,
  not sent.

## G6 — Secrets live in the Keychain only

**Rule.** All API tokens/keys (Productive, Fathom, Google OAuth refresh token, Slack, Fireworks,
Anthropic) are stored in the macOS Keychain. They never appear in `config.json`, in the
SQLite DB, in logs, in the outbound-payload log, or in committed fixtures.

**Enforcement.**
- `TidyCore` exposes a `SecretStore` (Keychain-backed) as the only accessor; config parsing
  has no field for secrets.
- Logging redacts anything that looks like a token; the outbound-payload log strips auth
  headers. A test asserts no secret material is written by the logger.
- `.gitignore` excludes `config.json`, `*.xcconfig` local files, the DB, and any `secrets*`.

## G7 — Stable code signature (TCC durability)

**Rule.** The app is signed with a **stable identity** and a **fixed bundle id**
(`com.4site.TidyTime`, configurable). Ad-hoc or rotating signatures are never shipped, because
macOS keys Accessibility/Automation grants to the signature and silently revokes them when it
changes — the single most common way this class of app "mysteriously stops working."

**Enforcement.**
- Signing settings come from a committed base plus a local, gitignored `Local.xcconfig`
  (team id) — see [build/signing-and-tcc.md](build/signing-and-tcc.md).
- `make doctor` / the in-app `doctor` view surfaces current permission status so a dropped
  grant is *visible*, not silent.

## G8 — One process, no background daemons (v1)

**Rule.** All capture, ingest, understanding, and surface run in the single menu bar app
process. Launch-at-login is `SMAppService`; there are no helper tools or launch daemons in v1.
If the app isn't running, capture is off — and the absent menu bar icon says so.

**Enforcement.** No `launchd` plist, no XPC helper, no privileged helper in the build.
(The Google sign-in flow binds a **transient loopback-only listener** for the seconds between
opening the browser and receiving the redirect — in-process, `127.0.0.1`-bound, closed on
completion or timeout. Not a background service; documented here so its port never surprises.)

## G9 — Retention and privacy blast radius

**Rule.** Raw high-volume, sensitive rows (`activity_samples`, `page_snapshots`,
`slack_messages`, `transcript_utterances`) purge after the retention window (default 90 days,
configurable). Distilled artifacts (`sessions`, `suggestions`, `decisions`, daily rollups)
persist. All data stays in one SQLite file on one Mac, encrypted at rest by FileVault.

**Enforcement.** A retention job runs on a schedule (Phase 1) and is covered by a test that
seeds old rows and asserts they're gone after the window; nothing leaves the device except
post-gate distilled cloud payloads.

---

### Fast checklist before merging anything

- [ ] No non-`GET` request can reach `api.productive.io`.
- [ ] Any new cloud payload passes through the sensitivity gate.
- [ ] No `CGWindowList` window-name usage; no Screen Recording ask.
- [ ] New cloud calls write to `ai_calls` and honor budget caps.
- [ ] No secret in config/DB/logs/fixtures; Keychain only.
- [ ] Signing unchanged (stable identity); `.gitignore` still covers secrets/DB.
