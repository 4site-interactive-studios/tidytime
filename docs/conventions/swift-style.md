# Swift style & conventions

Prescriptive Swift 6 conventions for TidyTime: strict concurrency, naming, GRDB records,
dependency injection over singletons, and file layout. Follow these so every target reads the
same and the guardrail tests stay green.

**Related:** [doc index](../README.md) · [PLAN.md](../../PLAN.md) · [CLAUDE.md](../../CLAUDE.md) ·
[module map](../architecture/module-map.md) · [data model](../architecture/data-model.md) ·
[error handling & logging](error-handling-logging.md) · [AI provider router](ai-provider-router.md)

---

## 0. Baseline

- **Swift 6 language mode**, strict concurrency **on** (`-strict-concurrency=complete`), warnings
  as errors in CI. Deployment target **macOS 14**; runtime-gate anything newer (the on-device
  model rung is `if #available(macOS 26, *)` + Apple Intelligence check).
- `async`/`await` and structured concurrency only. **No** completion-handler APIs in our own
  code; wrap legacy callback APIs in `withCheckedThrowingContinuation` at the boundary.
- Every target's public surface is explicit `public`; default to `internal`, tighten to
  `private`/`fileprivate` wherever possible.

## 1. Concurrency model

The rule of thumb: **shared mutable state lives in an actor; the UI lives on `@MainActor`;
everything that crosses a boundary is `Sendable`.**

**Actors for the capture pipeline and per-source ingest.** Each long-lived stateful component
that owns a buffer, a cursor, or a connection is an `actor` — `TidyCapture`'s watcher/idle
tracker, and **one actor per ingest source** in `TidyIngest` (Productive, Fathom, Google
Calendar, Slack) so their `sync()` loops and `sync_state` cursors can't race.

```swift
actor FathomIngest: IngestSource {
    private var cursor: String?            // created_after; actor-isolated, no lock needed
    private let api: any FathomAPI         // injected, Sendable
    private let store: StoreWriter

    func sync() async throws { /* poll, upsert via store, advance cursor */ }
}
```

**`@MainActor` for SwiftUI.** All `View`s, `@Observable`/view-model types, and anything touching
AppKit/`NSStatusItem` are `@MainActor`. `TidySurface` is presentation only — it never captures,
networks, or calls a provider (see [module map](../architecture/module-map.md)).

```swift
@MainActor @Observable
final class RecapViewModel {
    private(set) var cards: [SuggestionCard] = []
    private let store: SuggestionReading      // injected read model
    func load(day: String) async { cards = (try? await store.pending(day: day)) ?? [] }
}
```

**`Sendable` models.** Every type that crosses an actor/task boundary is `Sendable`. Value-type
GRDB records get it for free (all stored properties `Sendable`). Reference types that must be
`Sendable` are `final` + immutable, or an `actor`. Prefer marking protocols `Sendable`
(`protocol AIProvider: Sendable`) so conformers are checked.

- Don't reach for `@unchecked Sendable`. If you must (wrapping a thread-safe C API), isolate it
  in one small type and comment *why* it is safe.
- Don't spawn detached `Task {}` that escapes an actor's isolation to mutate its state. Keep work
  structured; use `async let` / `TaskGroup` for fan-out.
- `nonisolated` for pure, state-free members on an actor (e.g. a computed `id`).

## 2. Naming

| Kind | Rule | Example |
|---|---|---|
| Types (struct/class/actor/enum/protocol) | `PascalCase` | `ActivitySample`, `AIRouter` |
| DB table → record type | snake_case **plural** table → `PascalCase` **singular** | `activity_samples` → `ActivitySample`; `pd_time_entries` → `PdTimeEntry` |
| Methods, properties, cases | `camelCase` | `syncState`, `case refusedBudget` |
| Protocols | noun (capability) or `-ing`/`-able` | `BrowserAdapter`, `IngestSource`, `Sendable` |
| Acronyms | uppercase a leading acronym, else camel | `AIProvider`, `urlHost`, `parseJSON` |
| Booleans | `is`/`has`/`should` prefix, mirror DB `is_*`/`has_*` | `isSensitive`, `hasTranscript` |
| Files | named for the primary type | `ActivitySample.swift`, `AIRouter.swift` |

The snake_case↔PascalCase table mapping is **canonical** — the exact pairings live in
[data-model.md](../architecture/data-model.md) §Conventions (`activity_samples` → `ActivitySample`).
Never invent a variant.

## 3. GRDB records are value types

Every table in [data-model.md](../architecture/data-model.md) maps **1:1** to a `struct`
conforming to `Codable` + `FetchableRecord` + `MutablePersistableRecord`. Structs (not classes):
they're `Sendable`, copy-on-write, and free of identity surprises.

```swift
struct ActivitySample: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?                          // INTEGER PRIMARY KEY (rowid); nil until inserted
    var startedAt: Int64                    // Unix epoch seconds, UTC
    var endedAt: Int64?
    var appBundleId: String
    var appName: String
    var windowTitle: String?
    var isBrowser: Bool                     // maps INTEGER 0/1
    var url: String?
    var source: String                      // 'switch' | 'heartbeat'
    var createdAt: Int64

    static let databaseTableName = "activity_samples"
    enum CodingKeys: String, CodingKey {    // snake_case column mapping
        case id, url, source
        case startedAt = "started_at",  endedAt = "ended_at"
        case appBundleId = "app_bundle_id", appName = "app_name"
        case windowTitle = "window_title",  isBrowser = "is_browser"
        case createdAt = "created_at"
    }
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
```

Rules:
- **Mirror the schema exactly** — column names, units (seconds in our tables; Productive mirror
  keeps `time_minutes`/`billable_minutes` in minutes), timestamp columns as `Int64` epoch seconds.
- Local ids are `Int64?` (rowid alias). Mirror ids are the provider's `String` PK
  (`pd_*`, `meetings`, `calendar_events`) so re-sync is an upsert.
- Records hold **no I/O and no logic** beyond `didInsert`. Queries/DAOs live in `TidyStore`;
  domain logic lives in the consuming target. A record is data, not a service.
- Records are defined in **TidyCore**; DAOs and the `DatabaseMigrator` in **TidyStore**.

## 4. Dependency injection over singletons

**No `static let shared`.** Collaborators arrive through initializers, typed as protocols from
the [module map](../architecture/module-map.md) §Protocol seams. This is what lets unit tests run
with fixtures and an in-memory GRDB database and no live network/Accessibility.

```swift
struct SessionClassifier {
    let signals: EntitySignalReading      // protocol seam, not a concrete DAO
    let router: AIRouting                 // TidyAI entry; may be a stub in tests
    let clock: any Clock                  // injectable time — never Date() inline
    let log: TidyLog
}
```

- **Inject `Clock`**, never call `Date()`/`DispatchTime.now()` directly — tests need a
  deterministic clock (module map lists the `Clock` seam).
- The **only** composition root is the app target `TidyTimeApp`, which builds the graph once and
  hands pieces down. Library targets never construct their own dependencies from globals.
- Secrets come only through the `SecretStore` seam (`KeychainSecretStore`); there is no other
  accessor (guardrail [G6](../guardrails.md)).

Protocol seams to reuse rather than reinvent (full table in the module map): `BrowserAdapter`,
`AIProvider`, `ProductiveClient` (read-only), `IngestSource`, `SecretStore`, `Clock`,
`SensitivityGate`.

## 5. No force-unwrap in non-test code

`!`, `try!`, `as!`, and implicitly-unwrapped optionals are **banned outside `Tests/`**. Force
constructs are a lint failure, not a style nit — a crash in a menu bar app just makes capture
silently stop.

```swift
// NO
let host = URL(string: raw)!.host!

// YES — bind, or fail with a typed error the caller can log/handle
guard let url = URL(string: raw), let host = url.host else {
    throw CaptureError.malformedURL(raw)          // see error-handling-logging.md
}
```

- Optionals: `guard let` / `if let` / `??`. Prefer early-exit `guard` at the top of a function.
- Dictionary/route lookups that "can't fail" still bind-or-throw (see the router's
  `ModelRouting.resolve` in [ai-provider-router.md](ai-provider-router.md)).
- In tests, `#require` (Swift Testing) / `XCTUnwrap` is the sanctioned unwrap; bare `!` is fine
  only in test fixtures.

## 6. Value types by default

Prefer `struct` and `enum`. Reach for a reference type only when you need identity or shared
mutable state — and then it's an **`actor`** (shared mutable state) or a `final class` that is
immutable-and-`Sendable`. Model closed sets as `enum`; give enums that mirror DB `TEXT` columns a
`rawValue: String` matching the stored strings (`'switch'`, `'heartbeat'`, `'refused_budget'`).

## 7. File organization within a target

```
Packages/TidyKit/Sources/<Target>/
  <Target>.swift            // umbrella / entry type if any
  Models/                   // TidyCore only: one record per file
  <Concern>/                // folder per concern: Watcher/, Chrome/, Idle/ (TidyCapture)
    <Concern>.swift
    <Concern>+Extensions.swift
  Errors.swift              // the target's typed error enum(s) — see error doc
```

- **One primary type per file**, file named for it. Small related helpers may share a file.
- Split protocol conformances into `Type+Protocol.swift` extensions when a type gets long.
- Use `// MARK: -` to section a type; keep `public` API at the top.
- XcodeGen reads the folder tree — **new files under a target's path are picked up on
  `make generate`**; keep the layout above so files land in the right target
  ([module map](../architecture/module-map.md)).

## 8. Quick formatting rules

- ~100-column soft wrap. 4-space indent. One statement per line.
- Imports: alphabetized, no wildcard re-exports across targets; import the narrowest module.
- Trailing closures for the last closure arg; name earlier closures.
- `// MARK:` for sections; doc-comment (`///`) every `public` symbol with a one-line summary.
- No commented-out code in commits; no `TODO` without an [open-items](../open-items.md) or issue ref.
