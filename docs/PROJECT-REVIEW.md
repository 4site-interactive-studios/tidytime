# Project-wide review — TidyTime v1

**Date:** 2026-07-24 · **Method:** three independent reviewers (separate agents, no shared context),
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
