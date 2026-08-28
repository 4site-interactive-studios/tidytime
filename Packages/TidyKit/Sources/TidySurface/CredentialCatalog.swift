import Foundation
import TidyCore

/// Everything the Credentials tab knows about each key: a human name, what it's for, and
/// step-by-step instructions written for someone who has never seen an API key. Pure data +
/// pure picker logic — the view renders it; tests pin completeness and the lock-once-set rules.
///
/// Prose is a simplified retelling of docs/permissions-setup.md §6–10 — if that doc changes,
/// update both (a doc-sync test can't read markdown, so this is a stated convention).

public struct CredentialLink: Equatable, Sendable {
    public let title: String
    public let url: URL
    public init(_ title: String, _ url: URL) { self.title = title; self.url = url }
}

public struct CredentialInfo: Identifiable, Equatable, Sendable {
    /// The `SecretKey` constant — the Keychain account name.
    public let key: String
    public let displayName: String
    /// One plain-language line: what TidyTime does with it.
    public let purpose: String
    /// Ordered steps, written for non-techies. The view numbers them.
    public let steps: [String]
    public let links: [CredentialLink]
    /// False ⇒ never offered in the add picker (e.g. the Google refresh token is flow output).
    public let pastable: Bool
    public var id: String { key }

    public init(key: String, displayName: String, purpose: String, steps: [String],
                links: [CredentialLink] = [], pastable: Bool = true) {
        self.key = key; self.displayName = displayName; self.purpose = purpose
        self.steps = steps; self.links = links; self.pastable = pastable
    }
}

public enum CredentialCatalog {
    public static let all: [CredentialInfo] = [
        CredentialInfo(
            key: SecretKey.productiveToken,
            displayName: "Productive API token",
            purpose: "Lets TidyTime read your clients, projects, tasks, and logged time. It can never write anything back.",
            steps: [
                "Open Productive in your browser and sign in.",
                "Click your avatar (bottom-left) → Settings → API integrations.",
                "Click “Generate new token”, give it a name like “TidyTime”, and copy the token it shows you.",
                "Paste it below and click Save to Keychain.",
                "One more thing, once: TidyTime also needs your organization number. It's the number right after “app.productive.io/” in your browser's address bar (for example app.productive.io/1234-yourcompany → 1234). Put it in the settings file shown in Doctor → Paths → Config, inside “organization” → “productive_organization_id”.",
            ],
            links: [CredentialLink("Open Productive", URL(string: "https://app.productive.io")!)]),

        CredentialInfo(
            key: SecretKey.fathomKey,
            displayName: "Fathom API key",
            purpose: "Pulls your meeting recordings, real durations, and transcripts so meetings show up on your timeline.",
            steps: [
                "Open Fathom in your browser and sign in.",
                "Go to User Settings → API Access.",
                "Click to generate a key and copy it.",
                "Paste it below and click Save to Keychain.",
                "Don't see an “API Access” section? Your Fathom plan may not include it — TidyTime still works, using calendar events for meetings instead.",
            ],
            links: [CredentialLink("Open Fathom settings", URL(string: "https://fathom.video/settings")!)]),

        CredentialInfo(
            key: SecretKey.googleClientSecret,
            displayName: "Google client secret",
            purpose: "One of the three Google values. It lets TidyTime finish the Google sign-in handshake for read-only calendar access.",
            steps: [
                "Open the Google Cloud Console (link below) signed in with your work Google account.",
                "Create a project (or pick your company's existing one), then search for “Google Calendar API” and click Enable.",
                "Go to “Google Auth Platform” → “Audience”: choose User type “Internal”, fill in an app name like “TidyTime”, and save. (Google used to call this the “OAuth consent screen”.)",
                "Go to “Google Auth Platform” → “Clients” → “Create client” → Application type “Desktop app” → Create.",
                "Google now shows you a Client ID and a Client secret. They go to different places: the Client ID (ends in .apps.googleusercontent.com) goes in TidyTime's settings file (Doctor → Paths → Config) under “google” → “client_id”. The Client secret is what you paste below.",
                "The third value — the sign-in token — is created automatically when you click “Sign in with Google” underneath. You never type that one.",
            ],
            links: [CredentialLink("Open Google Cloud Console", URL(string: "https://console.cloud.google.com/auth/clients")!)]),

        CredentialInfo(
            key: SecretKey.googleRefreshToken,
            displayName: "Google sign-in (automatic)",
            purpose: "Created automatically when you click Sign in with Google — you never paste this one.",
            steps: [
                "Put the Client ID in the settings file (see the “Google client secret” instructions above).",
                "Paste the Google client secret in its row above.",
                "Click “Sign in with Google” below, approve in the browser window that opens, and come back here — done.",
            ],
            pastable: false),

        CredentialInfo(
            key: SecretKey.slackUserToken,
            displayName: "Slack user token",
            purpose: "Reads your own messages and channels (never posts) so quick Slack help shows up as billable time.",
            steps: [
                "Open api.slack.com/apps (link below) and click “Create New App” → “From an app manifest”.",
                "Pick your company's workspace.",
                "Paste the ready-made manifest from TidyTime's setup guide (docs/permissions-setup.md, section 8) and click through Create.",
                "Click “Install to Workspace” and Allow.",
                "On the left, open “OAuth & Permissions” and copy the token that starts with “xoxp-” — the User token, not the Bot one.",
                "Paste it below and click Save to Keychain.",
                "If the manifest is rejected: create the app “From scratch” instead, open OAuth & Permissions → User Token Scopes, and add the ten scopes listed in the setup guide one by one — then install and copy the xoxp- token the same way.",
            ],
            links: [CredentialLink("Open Slack apps", URL(string: "https://api.slack.com/apps")!)]),

        CredentialInfo(
            key: SecretKey.fireworksKey,
            displayName: "Fireworks AI key",
            purpose: "Powers the low-cost cloud AI that helps sort tricky time blocks. Costs cents per day, and TidyTime caps daily spend.",
            steps: [
                "Open fireworks.ai (link below), sign in or create an account.",
                "Go to your account's API Keys page and create a key (it starts with “fw_”).",
                "Paste it below and click Save to Keychain.",
            ],
            links: [CredentialLink("Open Fireworks AI", URL(string: "https://fireworks.ai")!)]),

        CredentialInfo(
            key: SecretKey.anthropicKey,
            displayName: "Anthropic API key",
            purpose: "Optional. Only used if you switch the escalation AI to talk to Claude directly instead of Fireworks.",
            steps: [
                "Open console.anthropic.com (link below) and sign in.",
                "Go to API Keys and create a key (it starts with “sk-ant-”).",
                "Paste it below and click Save to Keychain.",
                "If you're not sure you need this, skip it — everything works without it.",
            ],
            links: [CredentialLink("Open Anthropic Console", URL(string: "https://console.anthropic.com")!)]),
    ]

    public static func info(for key: String) -> CredentialInfo? {
        all.first { $0.key == key }
    }

    /// Add-picker choices: pastable AND not already set. This IS the lock-once-set rule — a stored
    /// key simply never reappears as a paste target until it's removed. (UI-level only:
    /// `SecretStore.set` stays callable so the OAuth flow and token rotation keep working.)
    public static func pickerChoices(present: [String]) -> [String] {
        all.filter { $0.pastable && !present.contains($0.key) }.map(\.key)
    }

    /// The picker selection after `saved` becomes locked: the next available choice, or nil when
    /// everything is set (the view then shows "Everything is set up ✓" instead of the add form).
    public static func nextSelection(afterSaving saved: String, present: [String]) -> String? {
        pickerChoices(present: present + [saved]).first
    }
}
