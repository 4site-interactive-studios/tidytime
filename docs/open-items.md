# Open items

Unresolved questions to settle **during** the build — each with why it matters, the phase it must
be resolved by, and exactly how to resolve it. The first group is [PLAN.md](../PLAN.md) §14
verbatim; the second collects the `⚠️ Build-time check` flags the reference docs raise. Check the
box and stamp the date when resolved.

**Related:** [docs index](README.md) · [PLAN.md](../PLAN.md) §14 ·
[permissions-setup.md](permissions-setup.md) · [guardrails.md](guardrails.md) ·
[config.example.json](../config.example.json)

**Status:** living checklist · **Last reviewed:** 2026-07-23

---

## A. PLAN §14 open items

### A1 — Confirm the Fathom plan includes API access

- [ ] **Resolved** (date: ____ )
- **Question:** Does Bryan's Fathom plan tier expose API key generation?
- **Why it matters:** Fathom recording start/end is ground truth for meeting duration
  ([PLAN.md](../PLAN.md) §5). No API access → no transcripts, no true durations; the app falls back
  to calendar-only meetings (schedule + attendees, no recorded span), degrading Phase 3 quality.
- **Resolve by:** **Phase 3** (Meetings & calendar).
- **How to resolve:** In Fathom, open **User Settings → API Access**. If a **Generate key** option
  appears, API access is included — generate the key (step 7 of
  [permissions-setup.md](permissions-setup.md)) and confirm a live `GET /meetings` returns `200`.
  If absent, contact Fathom about a tier that includes it, or accept calendar-only meetings for v1.
  See [reference/fathom-api.md](reference/fathom-api.md).

### A2 — Capture the Productive task deep-link pattern

- [ ] **Resolved** (date: ____ )
- **Question:** What is the exact web-app URL that opens a specific task?
- **Why it matters:** Every suggestion card has an "Open task in Productive" deep link
  ([PLAN.md](../PLAN.md) §8). The pattern is **not** in the API docs and must be observed from the
  running web app; a wrong pattern makes every deep link dead.
- **Resolve by:** **Phase 2** (Productive mirror). Acceptance requires clicking a cached task to
  open it in Productive.
- **How to resolve:** Open any task in the Productive web app, copy the URL, and generalize it into
  `config.productive.task_deep_link_pattern`. The default placeholder is
  `https://app.productive.io/{org}/task/{task_id}` ([config.example.json](../config.example.json)) —
  replace with the real shape (confirm the `{org}` segment and whether it's task **id** vs. task
  **number**). See [reference/productive-api.md](reference/productive-api.md).

### A3 — Verify the exact Slack user-scope list at manifest time

- [ ] **Resolved** (date: ____ )
- **Question:** Are all ten user-token scopes still valid, correctly named, and sufficient?
- **Why it matters:** A missing/renamed `*:history` scope surfaces at runtime as
  `{"ok":false,"error":"missing_scope"}` and silently drops whole conversation classes from capture
  ([reference/slack-api.md](reference/slack-api.md) §2).
- **Resolve by:** **Phase 4** (Slack), at app-manifest creation.
- **How to resolve:** Paste the bundled manifest (step 8 of
  [permissions-setup.md](permissions-setup.md)) into the Slack manifest editor, which **validates
  scope names on paste**. Confirm all ten are accepted:
  `channels:read/history`, `groups:read/history`, `im:read/history`, `mpim:read/history`,
  `users:read`, `users:read.email`. Then install and confirm `auth.test` succeeds with the
  `xoxp-…` token.

### A4 — Fireworks + Anthropic keys, and whose account bills

- [ ] **Resolved** (date: ____ )
- **Question:** Are the cloud keys provisioned, and do they bill Bryan's personal accounts or 4Site
  org accounts?
- **Why it matters:** These meter real dollars. The billing decision affects how AI overhead is
  accounted (personal expense vs. org overhead) — though the `ai_calls` ledger produces the overhead
  figure either way ([PLAN.md](../PLAN.md) §7, §14). Without keys, rungs 4–5 are unavailable
  (the app stays on the local ladder).
- **Resolve by:** **Phase 6** (Intelligence) — not needed before.
- **How to resolve:** Decide personal vs. 4Site org for each provider; create the keys
  (<https://fireworks.ai> API Keys; <https://console.anthropic.com> API keys), paste into Keychain
  (step 10 of [permissions-setup.md](permissions-setup.md)). Set per-provider `budget.daily_cap_usd`
  in `config.json` to bound spend on whichever account bills. Export the ledger CSV monthly for
  accounting.

### A5 — Keep or replace the "TidyTime" name

- [ ] **Resolved** (date: ____ )
- **Question:** Ship as "TidyTime" or rename?
- **Why it matters:** The name is woven into the **bundle id** `com.4site.TidyTime`, and the bundle
  id is load-bearing for TCC grant durability (guardrail
  [G7](guardrails.md#g7--stable-code-signature-tcc-durability)). Renaming **after** grants exist
  drops those grants and forces re-permissioning. Cheap to change early, expensive late.
- **Resolve by:** **Phase 0** (before any TCC grant is issued). Lock it with signing.
- **How to resolve:** Confirm the working name (fits the "Tidy" family — TidyContact). If changing,
  do it in Phase 0: update `project.yml` `PRODUCT_BUNDLE_IDENTIFIER`, the display name, and every
  doc reference **before** granting Accessibility/Automation. See
  [build/signing-and-tcc.md](build/signing-and-tcc.md).

---

## B. Build-time checks from the reference docs

These are facts the vendor docs couldn't pin down at planning time (2026-07-23) and that must be
verified against the live service/SDK on the build machine. Trust the live API and fix the doc in
the same change ([CLAUDE.md](../CLAUDE.md) "When docs and reality disagree").

### B1 — Fireworks model slug (catalog churn)

- [ ] **Resolved** (date: ____ )
- **Question:** Is `accounts/fireworks/models/kimi-k2p6` still the live serverless slug?
- **Why it matters:** The Fireworks catalog churns; a stale slug returns `404 / model not found`
  and blocks rung 4 entirely ([reference/fireworks-ai.md](reference/fireworks-ai.md)).
- **Resolve by:** **Phase 6**, when the Fireworks account is created.
- **How to resolve:** Check <https://fireworks.ai/models> for the live slug; update
  `config.json` `ai.models.fireworks-economy.model`. It's a **config edit, never code** — the router
  treats the slug as opaque. GLM-class models are interchangeable fallbacks (PLAN §12).

### B2 — Live pricing: Kimi confirm + Claude prices are null

- [ ] **Resolved** (date: ____ )
- **Question:** Are Kimi's prices still $0.95/M in, $4.00/M out — and what are Claude's prices?
- **Why it matters:** `ai_calls.cost_usd` is computed from `ai.prices_usd_per_mtok`; the Claude row
  ships **null/null** ([config.example.json](../config.example.json)), so any escalation logs `0`
  cost until real numbers are set — breaking the overhead metric and Phase 6's
  ledger-vs-dashboard reconciliation (guardrail [G5](guardrails.md#g5--every-cloud-ai-call-is-metered-and-capped)).
- **Resolve by:** **Phase 6**.
- **How to resolve:** Confirm Kimi pricing at <https://fireworks.ai/pricing>; set
  `prices_usd_per_mtok["claude-opus-4-8"]` input/output from
  <https://console.anthropic.com> / Anthropic pricing. Verify the model slug `claude-opus-4-8` is
  current for the escalation model too. Then reconcile a day's summed `cost_usd` against both
  provider dashboards.

### B3 — Slack internal-app rate-limit exemption still in force

- [ ] **Resolved** (date: ____ )
- **Question:** Are internal customer-built apps still exempt from the May 2025 `conversations.*`
  throttle (1 req/min, 15 objects)?
- **Why it matters:** The whole poll-only design depends on internal apps keeping ~50+/min and
  1,000 objects/call. If the exemption tightens, plain polling breaks
  ([reference/slack-api.md](reference/slack-api.md) §7).
- **Resolve by:** **Phase 4**.
- **How to resolve:** Re-read the changelog (<https://docs.slack.dev/changelog/2025/05/29/rate-limit-changes-for-non-marketplace-apps/>)
  and the rate-limits page when the app is created. If tightened: stretch the poll interval, drop
  `limit` to 15, and move toward the Events API / Socket Mode (PLAN §12 "Slack policy drift"). The
  ingest retry path already handles the tightened case generically.

### B4 — Apple Foundation Models context window (~4,096 tokens)

- [ ] **Resolved** (date: ____ )
- **Question:** Is the on-device context window really ~4,096 tokens on the build machine?
- **Why it matters:** It's the hard design constraint for rung 3 — it dictates "digests, not raw
  dumps." Over-budget prompts fail; under-using it wastes the free rung
  ([reference/apple-foundation-models.md](reference/apple-foundation-models.md)).
- **Resolve by:** **Phase 6** (on-device rung).
- **How to resolve:** Apple publishes no single canonical number; run a quick over-length probe on
  the actual macOS 26 build target to find the real limit. Treat 4,096 as the conservative budget
  until measured; keep digest + shortlisted candidates well under it (truncate the digest, never the
  candidate list).

### B5 — Foundation Models API surface (`availability`, `@Generable`/`@Guide`)

- [ ] **Resolved** (date: ____ )
- **Question:** Do `SystemLanguageModel.default.availability` (+ its `unavailable` reason cases) and
  the `@Generable`/`@Guide` + `session.respond(to:generating:)` signatures match the SDK we build
  against?
- **Why it matters:** These macro/enum names shift between betas; a mismatch fails to compile or
  mishandles the "skip rung 3" fall-through
  ([reference/apple-foundation-models.md](reference/apple-foundation-models.md)).
- **Resolve by:** **Phase 6**.
- **How to resolve:** Build against the target FoundationModels SDK; verify `.available` /
  `.unavailable(_)` cases and treat **any** non-`.available` state as "skip to rung 4." If a `@Guide`
  numeric-range helper is missing, keep description-only guides and clamp `confidence` after decoding.
  Also settle the on-device **model label** and whether token counts are exposed for the `ai_calls`
  row (use `'apple-on-device'` + `0`/estimate if not).

### B6 — Fireworks structured-output variant (`json_schema` vs `json_object`)

- [ ] **Resolved** (date: ____ )
- **Question:** Does the live endpoint enforce the OpenAI `response_format: json_schema` grammar
  (not silently downgrade to unenforced `json_object`)?
- **Why it matters:** Rung 4 relies on schema-constrained decoding to return the classification
  struct; a silent downgrade yields unvalidated prose and spurious rung-5 escalations
  ([reference/fireworks-ai.md](reference/fireworks-ai.md)).
- **Resolve by:** **Phase 6**.
- **How to resolve:** Send a real request with `json_schema` and assert the returned JSON validates
  against the expected struct. Always validate the parsed JSON regardless; a validation failure is a
  retry, then an escalation.

### B7 — TCC live-refresh vs. relaunch, and agent-app notification prompt

- [ ] **Resolved** (date: ____ )
- **Question:** Does `AXIsProcessTrusted()` flip to `true` live after granting, or only after
  relaunch? Does the notification-auth prompt appear for a `MenuBarExtra`/agent-style app?
- **Why it matters:** The `doctor` view must not cache a stale `false`, and setup instructions must
  tell the user to relaunch if needed ([reference/macos-permissions-tcc.md](reference/macos-permissions-tcc.md)
  §1, §3).
- **Resolve by:** **Phase 0–1** (permissions plumbing).
- **How to resolve:** On the target macOS, toggle Accessibility and observe whether `doctor` updates
  without relaunch; if not, re-poll and instruct a relaunch. Confirm the
  `UNUserNotificationCenter.requestAuthorization` prompt actually surfaces from the menu-bar app.

### B8 — Keychain `SecretStore` account naming (not yet canonical)

- [ ] **Resolved** (date: ____ )
- **Question:** What are the exact Keychain service/account keys `SecretStore` reads for each token?
- **Why it matters:** [permissions-setup.md](permissions-setup.md) documents a **suggested** account
  convention (`productive_token`, `fathom_api_key`, `slack_user_token`, `google_refresh_token`,
  `fireworks_api_key`, `anthropic_api_key`) but no doc canonically defines them; the setup checklist
  and the `KeychainSecretStore` implementation must agree or the app can't read a pasted secret.
- **Resolve by:** **Phase 0** (Keychain plumbing) / each provider's phase.
- **How to resolve:** Define the account keys once in `TidyCore`'s `KeychainSecretStore`
  ([module-map](architecture/module-map.md#protocol-seams-the-extension-points)) under service
  `com.4site.TidyTime`, and reconcile the table in
  [permissions-setup.md](permissions-setup.md) §0 to match. This is a doc/impl consistency task, not
  a vendor unknown.
