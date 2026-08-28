import Foundation

/// Writes a starter `config.json` on first launch, so the file the app tells people to edit
/// actually exists.
///
/// Before this, nothing in the tree ever wrote `AppPaths.configURL` — `ensureDirectories()` created
/// the support and logs directories and stopped there. A fresh install therefore ran entirely on
/// the compiled defaults in `Config.swift` while Doctor's own remedy text
/// (`TroubleshootingTips`) and `docs/permissions-setup.md` both said "open config.json in any text
/// editor". On the machine this was found on, that was an annoyance. On a second person's machine
/// it is a dead end before they start: `organization.productive_organization_id` defaults to `""`,
/// so Productive ingest is skipped forever and every `pd_*` table stays empty.
///
/// ## What gets seeded, and what deliberately does not
///
/// The seed is a **subset** of `config.example.json`, not a copy. `Config` decoding falls back to
/// the compiled default for every absent block and every absent field, so omitting a key is the
/// safe choice and writing one is a commitment. Two rules decide each key:
///
/// 1. **Never seed a value that would override a working default with a placeholder.** The example
///    file is a schema showcase; its `REPLACE_WITH_…` strings and its `ai` block are actively
///    harmful as runtime values. `google.client_id` is the sharpest case — a non-empty placeholder
///    defeats the `.isEmpty` checks that produce the precise "add your Client ID" guidance, and
///    the user gets an opaque OAuth failure instead. The `ai` block would swap a clean
///    "no route configured, nothing is sent" state for unverified model slugs plus a null-priced
///    entry that costs `$0.00` in the ledger — quietly disabling the G5 daily cap for that model.
/// 2. **Seed a key only if a user plausibly needs to change it.** Everything else (`capture`,
///    `sessionization`, `suggestions`, `recap`, `nudges`, `retention_days`, `ingest`) matches its
///    compiled default, and seeding it just freezes today's numbers into every install where a
///    future default improvement can never reach them.
///
/// `productive` is omitted for a third reason: its `task_deep_link_pattern` in the example was
/// wrong on both the org token and the path, and seeding a plausible-looking broken URL is worse
/// than leaving the (now corrected) default in place.
public struct ConfigSeeder: Sendable {
    public init() {}

    public enum Outcome: Equatable, Sendable {
        /// A starter file was written.
        case wrote
        /// A file was already there and was left completely untouched.
        case alreadyExists
        /// Seeding failed. Never fatal — a read-only support directory must not stop the app.
        case failed(String)

        public var logValue: String {
            switch self {
            case .wrote: return "wrote a starter config.json"
            case .alreadyExists: return "existing config.json left untouched"
            case .failed(let why): return "could not write a starter config.json: \(why)"
            }
        }
    }

    /// Write the starter file **only** when nothing is there.
    ///
    /// The no-overwrite rule is absolute, and the machine that prompted this change is the reason:
    /// its `config.json` had been hand-written that same day with a real organization id and a
    /// corrected deep-link pattern. A seeder that overwrote — or "helpfully" merged in missing
    /// keys — would have destroyed both. Existence is the whole test; the file's contents are
    /// never read, parsed, or repaired here.
    @discardableResult
    public func seedIfMissing(at url: URL, fileManager: FileManager = .default) -> Outcome {
        guard !fileManager.fileExists(atPath: url.path) else { return .alreadyExists }
        do {
            try Data(Self.starterJSON.utf8).write(to: url, options: .atomic)
            return .wrote
        } catch {
            return .failed("\(error)")
        }
    }

    /// The starter file, written verbatim.
    ///
    /// Hand-written rather than encoded from `Config()`: JSON has no comments, so `_about` is the
    /// only place to orient someone who arrived here from a Doctor tip, and round-tripping the
    /// full `Config` struct would emit every default — exactly what rule 2 above rules out.
    /// Unknown keys such as `_about` are ignored by the decoder.
    public static let starterJSON = """
    {
      "_about": "TidyTime settings. NON-SECRET values only — every token and API key lives in the macOS Keychain, never here. Anything you leave out uses the app's built-in default, so it is safe to delete a line you do not need. The full list of tunables is config.example.json in the TidyTime repo. Quit and reopen TidyTime after editing.",

      "organization": {
        "_help": "Open any page in Productive and look at the address bar: app.productive.io/2650-acme-inc/... -> productive_organization_id is the NUMBER (2650), productive_org_slug is the WHOLE first segment (2650-acme-inc). They are different strings and both are needed: the API uses the number, task deep links use the slug. Set productive_self_email to your Productive login email — without it TidyTime cannot tell which tasks are yours, so it pulls the whole organization and never syncs your time entries.",
        "productive_organization_id": "",
        "productive_org_slug": "",
        "productive_self_email": "",
        "productive_person_id": "",
        "timezone": "America/New_York"
      },

      "google": {
        "_help": "client_id comes from the Google Cloud OAuth client you create during setup. Leave it empty until you have one; the client secret goes in the Keychain, not here.",
        "client_id": "",
        "internal_domains": []
      }
    }

    """
}
