# Error handling & logging

How TidyTime raises, propagates, and records failure: typed errors per module, never swallowed;
all logging through `TidyLog` (os.Logger) with mandatory secret redaction; and the separate
opt-in outbound-payload log that proves the sensitivity gate. `print()` is banned.

**Related:** [doc index](../README.md) · [PLAN.md](../../PLAN.md) · [guardrails.md](../guardrails.md) ·
[swift style](swift-style.md) · [AI provider router](ai-provider-router.md) ·
[module map](../architecture/module-map.md)

---

## 1. Principles

1. **Errors are typed.** Each module defines its own `Error` enum; no `NSError`, no raw `String`
   throws, no stringly-typed sentinels.
2. **Never silently swallow.** Every `catch` (and every `try?`) either recovers, wraps-and-
   rethrows, or logs at an appropriate level and handles. An empty `catch {}` is a review reject.
3. **Log through `TidyLog`, never `print()`.** `print`/`NSLog`/`debugPrint` are banned in
   non-test code (grep-enforced, §7).
4. **Secrets never reach a log** (guardrail [G6](../guardrails.md)) — not the normal log, not the
   outbound-payload log, not an error's `description`.

## 2. Typed errors per module

One error enum per target (or per concern within a target), conforming to `Error` **and**
`Sendable`, named `<Area>Error`. Lives in the target's `Errors.swift`
([swift-style §7](swift-style.md)).

```swift
enum CaptureError: Error, Sendable {
    case malformedURL(String)
    case accessibilityDenied
    case chromeScriptingFailed(underlying: String)   // wrap, don't leak NSError
}

enum IngestError: Error, Sendable {
    case http(status: Int, provider: String)          // e.g. Productive 429
    case rateLimited(retryAfter: TimeInterval?)
    case decoding(source: String, underlying: Error)
    case notReadOnly                                  // guardrail G1 trip — see below
}
```

- **Wrap, don't leak.** Convert third-party/`NSError` into your enum's case, keeping a redacted
  `underlying` description — never re-throw a provider error whose `userInfo` might carry a token.
- **User-facing** errors (surfaced in the recap/doctor view) also conform to `LocalizedError`
  with a bland `errorDescription`; keep detail in the log, not the alert.
- **Guardrail trips are loud.** The Productive client rejects any non-`GET` method by throwing
  `IngestError.notReadOnly` and `assertionFailure` in `DEBUG` (guardrail
  [G1](../guardrails.md)) — a would-be write must crash the debug build, not warn.

## 3. `throws` vs `Result`

- **Prefer `throws`** for `async` functions — it composes with `try await` and structured
  concurrency. This is the default.
- **Use `Result`** only where you must *store* or *aggregate* outcomes without throwing: a
  `TaskGroup` collecting per-source sync results, a batch where one failure shouldn't abort the
  rest. Convert back to `throws` at the call site.

```swift
// Aggregate: one source failing must not kill the others.
await withTaskGroup(of: (String, Result<Void, Error>).self) { group in
    for source in sources { group.addTask { (source.id, await Result { try await source.sync() })} }
    for await (id, result) in group {
        if case .failure(let error) = result { log.error("sync failed", source: id, error: error) }
    }
}
```

- **`try?` requires intent + a log.** Using `try?` to turn an error into `nil` is allowed only
  when `nil` is a real, handled outcome *and* the discarded error is logged. A bare `try?` that
  drops the error is swallowing (§4).

## 4. Never silently swallow

Every failure site does exactly one of:

| Do | When |
|---|---|
| **Recover** (fallback value/path) | The failure is expected and has a defined degrade — e.g. Chrome scripting off → fall back to URL + title ([capture layer](../architecture/capture-layer.md)); log at `.notice`. |
| **Wrap & rethrow** | The caller is better placed to decide; add context (`throw IngestError.decoding(source: "fathom", underlying: e)`). |
| **Log & handle** | The buck stops here (a sync loop, a UI action). Log at `.error`, keep the app running. |

Banned: `catch {}`, `catch { }`, `try? doThing()` with no log, `catch { return }` that hides the
cause. If you truly want to ignore an error, write `catch { log.debug("ignored", error: error) }`
and say why in a comment.

## 5. `TidyLog` over `os.Logger`

`TidyLog` (in **TidyCore**) is a thin, `Sendable` wrapper over `os.Logger`. It fixes the
subsystem, enforces per-target categories, and applies redaction so call sites can't get privacy
wrong.

- **Subsystem:** the bundle id, `com.4site.TidyTime`.
- **Category:** one per target/concern — `capture`, `ingest.productive`, `ingest.fathom`,
  `understand`, `ai.router`, `store`, `surface`, `doctor`. Pass it once at construction.

```swift
public struct TidyLog: Sendable {
    private let logger: Logger
    public init(category: String) {
        self.logger = Logger(subsystem: "com.4site.TidyTime", category: category)
    }
    // Interpolations default to .private; callers pass only non-secret context.
    public func debug(_ msg: String)  { logger.debug("\(msg, privacy: .public)") }
    public func notice(_ msg: String) { logger.notice("\(msg, privacy: .public)") }
    public func error(_ msg: String, error: Error) {
        logger.error("\(msg, privacy: .public): \(Redact.describe(error), privacy: .public)")
    }
}
```

Level mapping (os.Logger): `.debug` (dev noise, not persisted) · `.info`/`.notice` (lifecycle,
sync ran, N rows) · `.error` (a handled failure) · `.fault` (a guardrail/invariant breach).
Never log at a level that persists user content — message **text**, page snapshots, transcript
utterances, and Slack bodies are **never** logged; log ids and counts, not content.

## 6. Mandatory secret redaction (G6)

No token/key (Productive `X-Auth-Token`, Fathom `X-Api-Key`, Slack user token, Google refresh
token, Fireworks/Anthropic keys) may appear in **any** log. Secrets live in the Keychain via
`SecretStore` and are read at the point of use only.

- `TidyLog` routes error descriptions through a `Redact` helper that strips anything
  token-shaped (long high-entropy strings, `Bearer …`, `xoxp-…`, `sk-…`, header names
  `authorization`/`x-api-key`/`x-auth-token`).
- **Never** interpolate a `URLRequest`'s headers, a raw response body, or a caught networking
  error's `userInfo` into a log line — wrap the error into a typed case first (§2).
- A guardrail test seeds a known fake token through the logger and asserts it appears **nowhere**
  in captured log output ([G6](../guardrails.md), testing-strategy).

```swift
enum Redact {
    static func describe(_ error: Error) -> String { scrub("\(error)") }
    static func scrub(_ s: String) -> String { /* mask Bearer/xox*/sk-*/x-*-token headers */ }
}
```

## 7. Outbound-payload log (proves G2, strips auth)

A **separate, opt-in** log — distinct from `TidyLog` — that records the exact bytes sent to each
cloud provider (Fireworks, Anthropic), so a test can prove the sensitivity gate worked. It exists
to make guardrail [G2](../guardrails.md) *auditable*, and it is the mechanism behind the Phase 6
acceptance check "a seeded sensitive phrase appears in no cloud payload".

- **Off by default; `DEBUG`/opt-in only** (`config`-gated flag or a `#if DEBUG` build). Never on
  in a release build a normal user runs.
- Writes **one record per outbound cloud request**: timestamp, provider, model, `job_type`,
  `request_ref`, and the **request body** (the `GatedPayload`-derived JSON) — the same body the
  router sent, so what you assert against is what actually left the machine.
- **Strips auth headers before writing.** `Authorization`, `X-Api-Key`, `X-Auth-Token` (and
  anything `Redact.scrub` catches) are removed — the payload log proves *content* left correctly
  without ever persisting a *secret* (G6 and G2 hold simultaneously).
- Lives beside the DB in `~/Library/Application Support/TidyTime/`, is itself subject to
  retention, and is emitted at the single metered call site so nothing bypasses it
  ([ai-provider-router.md](ai-provider-router.md) §metered call site).

```swift
struct OutboundPayloadLog {
    let enabled: Bool                                  // DEBUG/opt-in only
    func record(provider: String, model: String, job: String,
                requestRef: String, body: Data, headers: [String: String]) {
        guard enabled else { return }
        let safeHeaders = headers.filter { !Self.authHeaders.contains($0.key.lowercased()) }
        append(.init(provider: provider, model: model, job: job,
                     requestRef: requestRef, body: body, headers: safeHeaders))
    }
    static let authHeaders: Set<String> = ["authorization", "x-api-key", "x-auth-token"]
}
```

**Test shape (Phase 6):** seed a fixture transcript containing a flagged phrase → run the ladder
→ assert the session's `is_sensitive = 1`, the suggestion fell back to a generic task, and the
phrase appears in **zero** `OutboundPayloadLog` records
([classification-ladder](../architecture/classification-ladder.md) / G2).

## 8. `print()` is banned

`print`, `debugPrint`, `NSLog`, `dump`, and `fputs(stderr)` are not used in non-test code. They
bypass redaction, privacy levels, and categories, and they can leak content or a secret straight
to the console.

- Enforcement: a guardrail/lint check greps `Packages/TidyKit/Sources/**` for `print(` /
  `NSLog(` and fails the build on a hit (mirrors the `CGWindowList` grep for
  [G3](../guardrails.md)). Diagnostics go through `TidyLog`; the `doctor` view reads structured
  state, it doesn't `print`.
