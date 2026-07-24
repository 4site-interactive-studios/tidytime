# TidyCore

Foundation layer for every other target: domain models, config, secrets, logging, time/rounding
utilities, shared errors, and the cross-layer protocol seams. It performs no I/O of its own.

Related: [docs index](../../../../docs/README.md) ·
[module-map](../../../../docs/architecture/module-map.md) ·
[data-model](../../../../docs/architecture/data-model.md) ·
[guardrails](../../../../docs/guardrails.md) ·
[TidyStore](../TidyStore/README.md)

## Responsibility

The GRDB record types (1:1 with the schema), `Config` loading, the Keychain-backed `SecretStore`,
`TidyLog`, time/rounding helpers, typed errors, and the protocol definitions that keep the pipeline
decoupled. Pure logic — no database, network, or filesystem access.

## Phase

Builds in **Phase 0** (skeleton). Grows as later phases add record types for their new tables.

## Dependencies

- Internal: **none** — everything may depend on TidyCore; TidyCore depends on nothing internal.
- External: `GRDB` (for record conformances `FetchableRecord` / `MutablePersistableRecord`).

## Key types & files

| Type / file | Purpose |
|---|---|
| `*` record structs | `Codable` GRDB records, PascalCase-singular per table (`activity_samples` → `ActivitySample`). Defined here, persisted by TidyStore. |
| `Config` | Loads non-secret `config.json` (retention windows, budgets, gate lists, day/zone). No secret fields (G6). |
| `SecretStore` / `KeychainSecretStore` | The **only** token accessor; Keychain-backed (G6). |
| `TidyLog` | `os.Logger` wrapper; redacts token-shaped strings; never `print` (G6). |
| `Clock` | Injectable time seam; system clock in app, deterministic clock in tests. |
| `TidyError` | Typed, never-swallowed error hierarchy. |
| Rounding utils | 15-min increment + round-up-bias helpers consumed by TidySuggest. |

## Tables

Defines the record type for **every** table in
[data-model](../../../../docs/architecture/data-model.md); reads/writes none itself (TidyStore owns
all DB I/O).

## Protocol seams (owned)

Declares the cross-target seams so orchestrators avoid hard target deps: `Clock`, `SecretStore`,
`SensitivityGate` + `GatedPayload` (so TidyAI can require gated input without depending on
TidyUnderstand), and the **AI router / `AIProvider`** seam (so TidyUnderstand consumes rungs 3–5
without a target dep on TidyAI — see the graph note in
[module-map](../../../../docs/architecture/module-map.md) and `Package.swift`). Target-local seams
(`BrowserAdapter`, `IngestSource`, `ProductiveClient`) live in their owning targets.
