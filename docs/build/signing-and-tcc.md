# Signing & TCC durability (G7)

Why TidyTime **must** ship a stable code signature, how the committed `Signing.xcconfig` +
gitignored `Local.xcconfig` deliver one with a free Apple ID, and the `tccutil` moves for re-testing
the first-run permission flow. This is the single most common way this class of app "mysteriously
stops working" — get it right on day one.

**Related:** [../README.md](../README.md) (doc index) · [xcodegen-spec.md](xcodegen-spec.md) ·
[environment-setup.md](environment-setup.md) ·
[../reference/macos-permissions-tcc.md](../reference/macos-permissions-tcc.md) ·
[../guardrails.md](../guardrails.md) (G7) ·
[../decisions/0009-stable-signing-for-tcc.md](../decisions/0009-stable-signing-for-tcc.md) ·
[../../PLAN.md](../../PLAN.md) §10

**Status:** critical / build-ready · **Bundle id:** `com.4site.TidyTime` (fixed) ·
**Signing:** stable identity, **no paid Apple Developer account** · **Last verified:** 2026-07-23

---

## 1. The problem: TCC keys grants to the code signature

macOS's permission system (**TCC** — Transparency, Consent & Control) does not identify an app by its
path or its bundle id alone. Every grant — Accessibility, Automation (Apple Events) — is bound to the
app's **code signing identity** (its *designated requirement*, derived from the signing certificate +
bundle id). When macOS sees a binary whose signature doesn't match the one it granted, it treats it as
a **different app** and **silently revokes** the grant. No error, no prompt — capture just stops
returning window titles or page text.

**The trap.** An **ad-hoc** signature (`CODE_SIGN_IDENTITY = -`, what you get with no team) is
**recomputed on every build**. So every `make build` produces a "new app" to TCC, and Accessibility /
Automation grants drop on each rebuild. For an app whose entire job is passive capture, that reads as
"it worked yesterday and now it's dead" — the exact failure mode called out in
[../../PLAN.md](../../PLAN.md) §12 (Risks → Permission fragility).

**The fix (guardrail [G7](../guardrails.md#g7--stable-code-signature-tcc-durability)).** Sign with a
**stable identity** and a **fixed bundle id** so the designated requirement is identical across
rebuilds. Then a granted permission stays granted, and the *doctor* view makes any real loss visible
instead of silent.

## 2. A free Apple ID "Personal Team" is enough

You do **not** need the paid Apple Developer Program ($99/yr) for TidyTime v1. A **free Apple ID**
gives you a **Personal Team**, whose Apple Development certificate is a stable identity that persists
across rebuilds. That is all TCC durability requires for a locally-run, non-distributed app.

Set it up once in Xcode:

1. **Xcode → Settings → Accounts → “+” → Apple ID** — sign in with any Apple ID.
2. Xcode provisions a **Personal Team** and a local **Apple Development** signing certificate.
3. Find the **10-character Team ID**: Accounts → select the Apple ID → the team row shows it, or:
   ```bash
   # After one signed build, read it back from the built settings:
   xcodebuild -project TidyTime.xcodeproj -scheme TidyTime -showBuildSettings \
     | grep DEVELOPMENT_TEAM
   ```

Alternative (no Apple ID at all): a **stable self-signed certificate** in your login Keychain also
works, as long as it doesn't change between builds. The Personal Team route is simpler and is the
documented default. Either way, **never** ship an ad-hoc / rotating signature.

## 3. How signing is wired: `Signing.xcconfig` + `Local.xcconfig`

Signing is split so the **stable, shareable** parts are committed and the **machine-local** team id
stays out of git.

**`Signing.xcconfig` (committed):**

```xcconfig
// Signing.xcconfig — committed. Keeps a STABLE code signature so macOS does not revoke
// Accessibility/Automation (TCC) grants on rebuild. See docs/build/signing-and-tcc.md (G7).
//
// The optional include below pulls in your machine-local team id without committing it.
#include? "Local.xcconfig"

CODE_SIGN_STYLE = Automatic
PRODUCT_BUNDLE_IDENTIFIER = com.4site.TidyTime

// DEVELOPMENT_TEAM is provided by Local.xcconfig (copy Local.xcconfig.example → Local.xcconfig).
// A free Apple ID "Personal Team" works — no paid Apple Developer account required.
```

**`Local.xcconfig` (gitignored — copy from `Local.xcconfig.example`):**

```xcconfig
DEVELOPMENT_TEAM = XXXXXXXXXX   // your 10-char Personal Team id
```

Key mechanics:
- **`#include? "Local.xcconfig"`** — the `?` makes the include **optional**: the project still
  generates and CI still parses the config when `Local.xcconfig` is absent (it just has no team id).
  This is why the file can be gitignored without breaking `make generate`.
- **`project.yml` references `Signing.xcconfig`** for both configs (`configFiles: { Debug, Release }`)
  so the same stable identity applies to Debug and Release builds — see
  [xcodegen-spec.md](xcodegen-spec.md).
- **`CODE_SIGN_STYLE = Automatic`** lets Xcode manage the Personal Team's development certificate.
- **`PRODUCT_BUNDLE_IDENTIFIER = com.4site.TidyTime`** is fixed here **and** in `project.yml`'s base
  settings — the bundle id is half of the designated requirement, so it must never drift.
- `.gitignore` already excludes `Local.xcconfig` (and `config.json`, the DB, `*.pem`, `*.p12`,
  `secrets*`) — guardrail [G6](../guardrails.md#g6--secrets-live-in-the-keychain-only). The team id is
  not a secret, but keeping it machine-local avoids churn across contributors' machines.

## 4. Hardened Runtime + the Apple Events entitlement (both required)

Two independent settings must line up for TidyTime to send Apple Events (read Chrome tab URL/title/
page text, probe meeting state):

| Setting | Where | Value | Why |
|---|---|---|---|
| Hardened Runtime | `project.yml` base settings | `ENABLE_HARDENED_RUNTIME = YES` | required for a modern, notarizable, stable-identity macOS app; also what the Apple Events entitlement attaches to |
| Apple Events entitlement | `App/TidyTime.entitlements` | `com.apple.security.automation.apple-events = true` | under Hardened Runtime, **all** outgoing Apple Events are blocked *before TCC is even consulted* without this entitlement |
| Apple Events purpose string | `App/Info.plist` | `NSAppleEventsUsageDescription` | required by macOS to show the Automation prompt; missing it makes Apple Events fail (historically crash) |

```xml
<!-- App/TidyTime.entitlements -->
<key>com.apple.security.automation.apple-events</key>
<true/>
```

The order of gates when TidyTime scripts Chrome: **Hardened Runtime entitlement** (must be present) →
**TCC Automation grant** for TidyTime→Chrome (user approves once) → Chrome's own "Allow JavaScript
from Apple Events" toggle (only for `execute javascript`, **not** a TCC permission). The runtime probe
code and OSStatus handling are in
[../reference/macos-permissions-tcc.md](../reference/macos-permissions-tcc.md) §2 and
[../reference/chrome-scripting.md](../reference/chrome-scripting.md).

## 5. Non-sandboxed, on purpose

TidyTime v1 runs **without** the App Sandbox (`App/TidyTime.entitlements` declares **no**
`com.apple.security.app-sandbox`). This is deliberate, not an oversight:

- It drives the **Accessibility API** against **other** apps' UI (`AXUIElement` window titles) — the
  sandbox forbids cross-app Accessibility.
- It sends **Apple Events to arbitrary apps** (Chrome, System Events) — sandbox Apple-Event access is
  restricted to declared, temporary-exception targets and is a poor fit here.
- It reads/writes `~/Library/Application Support/TidyTime/` (the SQLite store) and the Keychain.
- It is a **personal, non-App-Store** tool, so the sandbox buys little and blocks the core capture.

What we keep instead: **Hardened Runtime ON**, a **stable signature**, one process with **no
helpers/daemons** ([G8](../guardrails.md#g8--one-process-no-background-daemons-v1)), and the sensitivity
gate + Keychain-only secrets for the privacy story. Rationale of record:
[../decisions/0007-accessibility-not-screen-recording.md](../decisions/0007-accessibility-not-screen-recording.md)
and [../decisions/0009-stable-signing-for-tcc.md](../decisions/0009-stable-signing-for-tcc.md).

> Reminder (G3): even non-sandboxed, TidyTime reads window titles via Accessibility and **never**
> touches `CGWindowList`'s window-name field, so **Screen Recording is never requested**. See
> [../reference/macos-permissions-tcc.md](../reference/macos-permissions-tcc.md) §4.

## 6. `tccutil reset` — re-testing the first-run flow

Development means re-running the "first launch" prompt flow many times. `tccutil` clears prior grants
per service, scoped to the bundle id, so the next launch re-prompts:

```bash
# Reset one service for TidyTime only (always pass the bundle id — omitting it hits every app).
tccutil reset Accessibility com.4site.TidyTime
tccutil reset AppleEvents   com.4site.TidyTime   # Automation grants (all TidyTime→target pairs)

# Reset every TCC service TidyTime has touched:
tccutil reset All com.4site.TidyTime
```

Gotchas:
- The service name for **Automation** is **`AppleEvents`** (matches `kTCCServiceAppleEvents`), not
  "Automation"; Accessibility is `Accessibility`.
- **Always** pass `com.4site.TidyTime`. Without a bundle id, `tccutil reset <service>` clears that
  service for **every** app on the machine.
- `tccutil` does **not** manage **Notifications** (not a TCC service) — reset those via System
  Settings → Notifications.
- After a reset, **relaunch** the app to re-trigger the prompts.
- **Don't confuse a `tccutil` reset with a signature-change revocation.** Both drop grants. If grants
  vanish *without* a reset, suspect the signature changed (§1) — verify with §7 before blaming TCC.
- ⚠️ **Build-time check:** SIP restricts editing some TCC entries; resetting your **own** app's grants
  works, but confirm on the target macOS if a reset appears to no-op.

## 7. Verifying signature stability

Confirm two builds produce the **same** designated requirement (the thing TCC keys on):

```bash
APP=".build/dd/Build/Products/Debug/TidyTime.app"

# 1. Identity + team should be a real cert, NOT "adhoc".
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E 'Authority|TeamIdentifier|Signature|flags'
#   Good:  Authority=Apple Development: you@example.com (…)   TeamIdentifier=<your team>
#   Bad:   Signature=adhoc            (rotates every build → grants drop)

# 2. The designated requirement must be identical across rebuilds.
codesign -d -r- "$APP"                 # prints: designated => identifier "com.4site.TidyTime" and …
```

Rebuild, run `codesign -d -r-` again, and diff the output — it must match byte-for-byte. If
`Signature=adhoc` shows up, `DEVELOPMENT_TEAM` isn't set (`Local.xcconfig` missing or still
`XXXXXXXXXX`); fix that before chasing "disappearing permissions."

## 8. The doctor view surfaces dropped grants

Because a real revocation is silent, TidyTime makes it **visible**: the in-app **doctor** view (and
`make doctor` for the on-disk paths) shows live TCC status for Accessibility, Automation→Chrome,
Automation→System Events, and Notifications — so a dropped grant shows as `denied`/`false` instead of
mystery-broken capture. Probes are non-prompting; the status table and Swift probes are in
[../reference/macos-permissions-tcc.md](../reference/macos-permissions-tcc.md) §6. Surfacing dropped
grants is a **Phase 0 acceptance criterion** ([../phases/phase-0-skeleton.md](../phases/phase-0-skeleton.md),
[../../PLAN.md](../../PLAN.md) §11).

## 9. Checklist

- [ ] `Local.xcconfig` exists locally with a real 10-char `DEVELOPMENT_TEAM` (gitignored).
- [ ] `Signing.xcconfig` committed; `PRODUCT_BUNDLE_IDENTIFIER = com.4site.TidyTime` here **and** in
      `project.yml` base settings.
- [ ] `codesign -dv` shows an **Apple Development** (or stable self-signed) identity — **never**
      `Signature=adhoc`.
- [ ] `codesign -d -r-` output is identical across two rebuilds.
- [ ] `ENABLE_HARDENED_RUNTIME = YES`; `com.apple.security.automation.apple-events = true`;
      `NSAppleEventsUsageDescription` present.
- [ ] **No** `com.apple.security.app-sandbox` entitlement (non-sandboxed by design).
- [ ] Doctor view shows live permission status; a toggled-off grant flips its row without crashing.
