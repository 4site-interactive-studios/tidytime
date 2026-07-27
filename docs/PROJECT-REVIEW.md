# Project-wide review — TidyTime v1

**Rounds**

| Round | Date | Reviewed | Reviewers | Findings | Tests |
|---|---|---|---|---|---|
| 1 | 2026-07-24 | everything up to `034e6b8` | 3 | 12, all fixed | 117 → 130 |
| 2 | 2026-07-25 | `034e6b8..dcffdac` (post-review delta + the never-reviewed site commit) | 4 | 52; HIGH/MED fixed | 152 → 184 |
| 3 | 2026-07-27 | `1e47046..59db8b1` (app shell, dmg pipeline, live-run fixes, OAuth, guided UI — 20 commits) | 4 | 32; HIGH + all actionable MED fixed | 268 → 279 |

> **Unreviewed at HEAD:** the app-shell wiring (`b5db65a`) landed *after* round 2 and has not been independently reviewed — by the rule below, it is unreviewed by definition.

> **Current as of the round-3 fix commits (post-`59db8b1`).** Round 3 covers the app shell, the dmg
> pipeline, the first-live-run fixes, the Google OAuth flow, and the guided Doctor/Credentials UI.
> Round 2 covers the four post-review enhancements *and* the companion
> site, which round 1 predated. See [How this doc stays honest](#how-this-doc-stays-honest).

---

## Round 1 — project-wide (2026-07-24, `034e6b8`)

**Method:** three independent reviewers (separate agents, no shared context),
each with Bash + Read over the built codebase, verdicts via structured output.

## Verdicts

| Reviewer | Verdict | Headline |
|---|---|---|
| Correctness | pass_with_concerns | Logic core sound; one real G9 gap (transcript retention) + edge cases |
| Test coverage | pass_with_concerns | 80.8% line overall / **~91% on the testable core**; specific gaps named |
| Plan & guardrail adherence | pass_with_concerns | G1/G3/G5/G6 solid & tested; two gaps (G2 empty-list, G3 lint) |

Full suite at review time: **117 tests, 0 failures.** After the fixes below: **130 tests, 0 failures.**

## Findings & disposition

Everything actionable was **fixed** (not just noted). Each fix has a regression test in
`Tests/TidyKitTests/ReviewHardeningTests.swift`.

| # | Sev | Finding | Disposition |
|---|---|---|---|
| 1 | HIGH | **G9:** `transcript_utterances` (raw sensitive meeting content) was configured for 90-day retention but never purged (no absolute timestamp column). | **Fixed** — `RetentionJob` now purges via the parent meeting's `recording_start`/`fetched_at`, keeping the meeting summary row. Test: `TranscriptRetentionTests`. |
| 2 | MED | **G2:** the sensitivity gate failed **open** on an empty term list, contradicting "an empty list never disables the gate." | **Fixed** — `SensitivityGate` now unions config terms with a hardcoded `floorTerms` list; even a default/empty `Config` blocks known sensitive phrases. Test: `SensitivityGateFloorTests`. |
| 3 | MED | `AnthropicProvider.complete` had **zero** test coverage (feeds the G5 ledger). | **Fixed** — `AnthropicParseTests` (multi-block content, token usage, schema-in-system, error path). |
| 4 | MED | The `meeting_segment` suggestion branch was never exercised. | **Fixed** — `MeetingSegmentTests`. |
| 5 | LOW | Gap-analysis remainder could emit a non-15-min suggestion (e.g. 35m). | **Fixed** — subtract logged from **raw** seconds before rounding; sub-threshold remainders skip. Tests: `GapRemainderTests` + updated `testGapAnalysisSkipsAlreadyLogged`. |
| 6 | LOW | Learning loop strengthened a hardcoded `url_host` signal regardless of the type that actually matched (polluting `entity_signals` with bogus rows keyed on Slack ids / email domains). | **Fixed** — `Classification` now carries `matchedSignalType`; `DayClassifier` strengthens the real type. Test: `LearningSignalTypeTests`. |
| 7 | LOW | AI budget "day" used a **UTC** window while the rest of the app uses the configured **local** day. | **Fixed** — default `dayBounds` now uses the local calendar day (app can still inject a config-tz variant). |
| 8 | LOW | `RecapAssembler.loggedMinutes` path uncovered. | **Fixed** — `RecapLoggedMinutesTests`. |
| 9 | LOW | Fireworks structured-output body + error path uncovered. | **Fixed** — `FireworksStructuredOutputTests`. |
| 10 | LOW | Dashboard CSV test asserted only the header. | **Fixed** — `DashboardCSVTests` asserts a concrete data row + row count. |
| 11 | LOW | **G3** had no automated lint (doc claimed one existed). | **Fixed** — `ScreenRecordingGuardrailTests` scans `TidyCapture` sources and fails on any `CGWindowList` usage. |
| 12 | note | DECISIONS.md over-claimed that sub-`min_session_seconds` runs are "recovered as pools." | **Corrected** in DECISIONS.md — sub-60s fragments are dropped as noise; pooling works on sessions above the 60s floor but below the 15-min threshold. |

## What the review confirmed (no change needed)

- **G1** (Productive read-only) is structurally enforced and tested — the request builder throws on
  any non-GET, the protocol has only `fetch*` methods, no mutating verb appears in `TidyIngest`.
- **G5** (metered + capped) — `AIRouter` is the sole `provider.complete` call site; every outcome
  writes an `ai_calls` row; budget checked before dispatch.
- **G6** (secrets) — only the Keychain `SecretStore` path; redaction proven; `.gitignore` covers it.
- The classification ladder, rounding math, migrations, and parsing all check out.
- The documented compile-only OS layers (LiveCapture, SwiftUI, live HTTP, on-device runtime path)
  are correctly out of scope for unit testing and account for nearly all uncovered lines.

## Residual (documented, not blocking)

- End-to-end transcript-split → multiple `meeting_segment` suggestions, on-device `@Generable`
  guided generation, and calibration sampling remain scaffolded (see the Phase 6 retrospective).
- Live cloud/on-device/OS calls require keys + a real Mac (macOS 26 + Apple Intelligence) and are
  verified manually, per the headless-build strategy in DECISIONS.md.

---

## Round 2 — post-review delta (2026-07-25, `034e6b8..dcffdac`)

**Why a second round.** Five commits landed *after* round 1 — four enhancements (tiered
change-gated heartbeat, the context-switching metric + Fireworks-only routing, finer within-app
attribution, chat separation by URL path) plus the companion site itself. None had ever been
reviewed; round 1's record was accurate for its sha and quietly became misleading.

**Method.** Four **blind** reviewers (separate agents, no shared context, read-only, structured
verdicts). Round 1 used three roles; round 2 added **R4 Documentation & site accuracy**, because
stale documentation was the delta's dominant defect class and had no owner in the round-1 split.
The known signature bug and the stale `data-model.md` were withheld and used as **calibration
probes** — all four reviewers caught their probe, so their other findings were trusted.

### Verdicts

| Reviewer | Verdict | Headline |
|---|---|---|
| R1 Correctness | **fail** | Three divergent context-signature definitions; recap switch-count and longest-focus both wrong |
| R2 Test coverage | pass_with_concerns | 152 pass, 81.8% line (core 90–92%) — round-1 figures hold; one dead flag, one unproven upgrade path, one vacuous assertion |
| R3 Guardrails & DoD | **fail** | No G1–G9 breach, but the Fireworks reroute corrupts the escalation-rate metric; ADR reversed without supersession; schema change without its doc |
| R4 Docs & site | **fail** | Site misstates AI routing, claims "7 phases complete" over a placeholder app shell, and says 117 tests vs 152 |

**52 findings** — 7 HIGH, 25 MED, 14 LOW, 6 notes.

### Test-count lineage

A hardcoded number rots; an auditable chain doesn't:

`117` (round 1) → `130` (round-1 fixes) → `135` → `141` → `147` → `152` (`dcffdac`) → `184` (round-2 fixes) → `194` (app wiring) → `204` → `231` (OAuth + ingest fixes) → `268` (Doctor tips, credentials, sign-in) → **`279`** (round-3 fixes). Regenerate with `make test`.

Regenerate with `make test`, which prints `Executed N tests`.

Coverage moved **down** from 82.16% to **64.3%** when the app shell was wired — that added ~1,500
lines of SwiftUI and live-OS code that cannot execute headlessly. The *testable core* is unchanged at
~90%. Recording the drop rather than quietly re-baselining is the point: coverage fell because
untestable surface area was added, not because tests were lost.

### Findings & disposition (HIGH/MED)

| # | Sev | Finding | Disposition |
|---|---|---|---|
| R1-1 / R3-7 | HIGH | Three context-signature definitions disagreed; capture + metric used the **raw** URL/title while sessionization normalized them, so per-message query churn, `#fragments`, trailing slashes and unread-badge ticks each wrote a sample row, re-fired `innerText`, and **counted as a context switch** (measured: 10 churn samples → switchCount 9, fragmentation 100%) | **Fixed** `46db539` — `TidyCore.ContextSignature` is the single definition; `ContextSignatureTests.testCaptureAndMetricAgreeOnEveryCase` fails if they re-diverge |
| R1-2 | HIGH | Unattended time counted as focus. Contiguous-by-construction samples mean idle gaps can never fire and `PowerObserver` is never constructed, so an overnight absence won `longestFocusSeconds` — and `writeRollup` **persisted** it, poisoning the trend series | **Fixed** `46db539` — `analyze(_:now:awayGaps:)` clips against away gaps, plus a generous 2h plausibility ceiling as fallback; open trailing sample clamped to `now` |
| R3-1 | HIGH | Rerouting escalation onto Fireworks corrupted `escalationRate`: the economy tier was classified by *provider name*, so escalations landed in their own denominator | **Fixed** `46db539` — tier derived from the job, not the vendor |
| R3-2 / R4-1 | HIGH | ADR 0008 still "Accepted" while HEAD contradicts it; 9+ docs and the site still said rung 5 = Claude | **Fixed** — new **ADR 0013**, 0008 superseded (banner + index), repo-wide sweep |
| R4-2 | HIGH | Site presents phases 0–6 as shipping while `App/TidyTimeApp.swift` is a placeholder | **Fixed** (step 8) — retitled to library status + explicit app-shell note |
| R4-3 / R3-3 | HIGH | `v2-context-switches` shipped without the required `data-model.md` update (DoD violation) | **Fixed** — columns documented + a table of all nine migrations |
| R1-3 | MED | `pageTexts` time-scoped only, so a ≤120s absorbed detour could supply **100%** of a session's attribution evidence | **Fixed** `46db539` — host-scoped |
| R1-6 | MED | `pageTexts` full-scanned `page_snapshots` per session | **Fixed** `46db539` — `v2-page-snapshot-time-index` |
| R3-6 | MED | `captureContent()` fired on any signature change, unbounding page-snapshot writes | **Fixed** `46db539` — fires only on page change |
| R1-7 / R2-01 | MED | `capture.separate_chats_by_path` read at **zero** production call sites — "configured ≠ enforced", the round-1 lesson, repeated four commits later | **Fixed** `46db539` — `ContextSignature.Policy(config.capture)` wired in `LiveCaptureController`; decode test added |
| R2-02 | MED | v2 migration only ever tested on a **fresh** DB | **Fixed** `46db539` — `MigrationUpgradePathTests` migrates `upTo: "v1-ai"`, inserts a rollup, then migrates the rest |
| R2-04 | MED | `testNativeSameTitleCannotSeparate` was **vacuous** (compared a pure function's output to itself) | **Fixed** `46db539` — asserts a concrete value |
| R3-4 | MED | Rung 4→5 is no longer a cost escalation (the placeholder escalation model is *cheaper*), inverting the ladder's economics | **Documented** — ADR 0013 restates rungs 4/5 as a **capability** split; G4's local-first claim is unaffected |
| R2-03 / R2-05 | MED | Uncovered branches: run-collapsing, open-sample fallback, `pageTexts` limit/order/window | **Fixed** `46db539` |
| R4-4/5/7/8, R3-8/9, R4-6/9 | MED | Stale counts, README under-claiming, capture-layer heartbeat contradiction, understand-layer grouping, missing settings keys, unlinked site | **Fixed** — doc sweep commit |

LOW findings and notes are recorded in the run transcript; the substantive ones are folded into
the fixes above.

### What round 2 confirmed

- **G2 holds** — page text reaches only the local rungs 1–2; no path from `pageTexts` to a cloud
  payload. The gate still owns the only route to a provider.
- **G3 lint reaches the new files** — `ScreenRecordingGuardrailTests` scans all of
  `Sources/TidyCapture`, including `CaptureCoordinator.swift`.
- **G1, G5, G6** unchanged and still enforced structurally + by test.
- Change-gating (once the signature was fixed) genuinely bounds `activity_samples` growth at a 1 s
  poll — which is what makes G9's 90-day window safe.

### Residual (documented, not blocking)

- **The app shell is still the Phase-0 placeholder** — `LiveCaptureController`, `SessionBuildJob`
  and every SwiftUI surface have no production construction site. This is the single largest gap
  between "tested library" and "working product".
- Idle-aware dwell relies on `away_gaps` being written, which needs `PowerObserver` wired in the app.
- The escalation model slug and its price are placeholders (`_build_time_checks`).
- `AXObserver`-driven within-app detection (instead of polling) remains the better long-term design.

## Round 3 — the unreviewed twenty (2026-07-27, `1e47046..59db8b1`)

Four blind reviewers over everything since the round-2 addendum: the wired app shell + dmg
pipeline, the Keychain/signing fixes, ingest wiring and the first-live-run corrections, the Google
OAuth engine + orchestrator, and the guided Doctor/Credentials UI. Uniquely, part of this delta had
already been validated by REAL use (signed install, TCC grants, live Slack/Fathom sync).

| Reviewer | Verdict | Headline |
|---|---|---|
| R1 Correctness | pass_with_concerns | OAuth/credentials/retention sound; unguarded concurrent ingest, permanently-nil Slack names, frozen menu-bar icon |
| R2 Coverage | pass_with_concerns | 268 pass; but 3 of 5 first-live-run fixes shipped with zero test protection |
| R3 Guardrails | pass_with_concerns | All nine hold in substance; dmg script displayed but didn't enforce signing; two unredacted error seams |
| R4 Docs & site | **fail** | README/site/RUNNING still claimed "never launched / 194 tests" after the app ran live |

**Disposition:** 32 findings — 3 HIGH (all doc-truth), 11 MED, 10 LOW, 8 notes. Every HIGH and
actionable MED/LOW fixed in the round-3 commits (`fix(review)` + the docs sweep), each with a
regression test where testable: ingest serialization (`ingestInFlight`), Slack `user_name`
backfill, menu-bar icon observation, redaction order + minimum-secret-length (both caught by the
new tests themselves), 410 syncToken recovery, loopback preconnect skip, make-dmg signing
enforcement, notification-status cache, and coverage for the Slack backoff / users throttle /
Fathom bound / google happy path. Deferred as notes: DPoP hardening, accept-loop content-length
parsing, catalog↔doc wording alignment.

**The recurring lesson, third time:** every review round's docs reviewer returned FAIL for the
same defect class — reality moved, prose didn't. The mitigation stays procedural (this doc's sha
stamp + the closing rule below), because a test cannot read English.

## How this doc stays honest

**A review is only valid for the sha it ran against.** Round 1 was accurate when written and became
misleading four commits later, with nobody touching it — that is the failure this round exists to
correct. Each round above is stamped with the range it reviewed; **commits after that range are
unreviewed by definition.** When adding a round, append — never rewrite an earlier round's findings.
