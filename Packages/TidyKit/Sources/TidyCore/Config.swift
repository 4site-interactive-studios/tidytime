import Foundation

/// Non-secret application configuration, mirroring `config.example.json`. Every field has a
/// default so a partial (or empty `{}`) config still loads; unknown keys are ignored. Secrets are
/// NEVER here — they live in the ``SecretStore`` (guardrail G6).
///
/// Decoding uses explicit snake_case `CodingKeys` (NOT `.convertFromSnakeCase`, which would also
/// mangle dictionary keys like `activity_samples` or `session_batch`).
public struct Config: Codable, Sendable, Equatable {
    public var organization: Organization
    public var productive: Productive
    public var google: Google
    public var capture: Capture
    public var sessionization: Sessionization
    public var suggestions: Suggestions
    public var recap: Recap
    public var nudges: Nudges
    public var sensitivity: Sensitivity
    public var retentionDays: [String: Int]
    public var ingest: Ingest
    public var ai: AI

    public init(
        organization: Organization = .init(),
        productive: Productive = .init(),
        google: Google = .init(),
        capture: Capture = .init(),
        sessionization: Sessionization = .init(),
        suggestions: Suggestions = .init(),
        recap: Recap = .init(),
        nudges: Nudges = .init(),
        sensitivity: Sensitivity = .init(),
        retentionDays: [String: Int] = Config.defaultRetention,
        ingest: Ingest = .init(),
        ai: AI = .init()
    ) {
        self.organization = organization
        self.productive = productive
        self.google = google
        self.capture = capture
        self.sessionization = sessionization
        self.suggestions = suggestions
        self.recap = recap
        self.nudges = nudges
        self.sensitivity = sensitivity
        self.retentionDays = retentionDays
        self.ingest = ingest
        self.ai = ai
    }

    public static let defaultRetention: [String: Int] = [
        "activity_samples": 90, "page_snapshots": 90, "slack_messages": 90, "transcript_utterances": 90,
    ]

    enum CodingKeys: String, CodingKey {
        case organization, productive, google, capture, sessionization, suggestions, recap, nudges
        case sensitivity, ingest, ai
        case retentionDays = "retention_days"
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let z = Config()
        organization = try c.decodeIfPresent(Organization.self, forKey: .organization) ?? z.organization
        productive = try c.decodeIfPresent(Productive.self, forKey: .productive) ?? z.productive
        google = try c.decodeIfPresent(Google.self, forKey: .google) ?? z.google
        capture = try c.decodeIfPresent(Capture.self, forKey: .capture) ?? z.capture
        sessionization = try c.decodeIfPresent(Sessionization.self, forKey: .sessionization) ?? z.sessionization
        suggestions = try c.decodeIfPresent(Suggestions.self, forKey: .suggestions) ?? z.suggestions
        recap = try c.decodeIfPresent(Recap.self, forKey: .recap) ?? z.recap
        nudges = try c.decodeIfPresent(Nudges.self, forKey: .nudges) ?? z.nudges
        sensitivity = try c.decodeIfPresent(Sensitivity.self, forKey: .sensitivity) ?? z.sensitivity
        retentionDays = try c.decodeIfPresent([String: Int].self, forKey: .retentionDays) ?? z.retentionDays
        ingest = try c.decodeIfPresent(Ingest.self, forKey: .ingest) ?? z.ingest
        ai = try c.decodeIfPresent(AI.self, forKey: .ai) ?? z.ai
    }

    // MARK: - Blocks

    public struct Organization: Codable, Sendable, Equatable {
        public var productiveOrganizationId: String
        public var productivePersonId: String
        public var timezone: String
        public init(productiveOrganizationId: String = "", productivePersonId: String = "",
                    timezone: String = "America/New_York") {
            self.productiveOrganizationId = productiveOrganizationId
            self.productivePersonId = productivePersonId
            self.timezone = timezone
        }
        enum CodingKeys: String, CodingKey {
            case productiveOrganizationId = "productive_organization_id"
            case productivePersonId = "productive_person_id"
            case timezone
        }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self); let z = Organization()
            productiveOrganizationId = try c.decodeIfPresent(String.self, forKey: .productiveOrganizationId) ?? z.productiveOrganizationId
            productivePersonId = try c.decodeIfPresent(String.self, forKey: .productivePersonId) ?? z.productivePersonId
            timezone = try c.decodeIfPresent(String.self, forKey: .timezone) ?? z.timezone
        }
    }

    public struct Productive: Codable, Sendable, Equatable {
        public var baseUrl: String
        public var taskDeepLinkPattern: String
        public var syncIntervalSeconds: Int
        public init(baseUrl: String = "https://api.productive.io/api/v2/",
                    taskDeepLinkPattern: String = "https://app.productive.io/{org}/task/{task_id}",
                    syncIntervalSeconds: Int = 900) {
            self.baseUrl = baseUrl; self.taskDeepLinkPattern = taskDeepLinkPattern
            self.syncIntervalSeconds = syncIntervalSeconds
        }
        enum CodingKeys: String, CodingKey {
            case baseUrl = "base_url", taskDeepLinkPattern = "task_deep_link_pattern"
            case syncIntervalSeconds = "sync_interval_seconds"
        }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self); let z = Productive()
            baseUrl = try c.decodeIfPresent(String.self, forKey: .baseUrl) ?? z.baseUrl
            taskDeepLinkPattern = try c.decodeIfPresent(String.self, forKey: .taskDeepLinkPattern) ?? z.taskDeepLinkPattern
            syncIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .syncIntervalSeconds) ?? z.syncIntervalSeconds
        }
    }

    public struct Google: Codable, Sendable, Equatable {
        public var clientId: String
        public var calendarId: String
        public var scopes: [String]
        public var internalDomains: [String]
        public init(clientId: String = "", calendarId: String = "primary",
                    scopes: [String] = ["https://www.googleapis.com/auth/calendar.readonly"],
                    internalDomains: [String] = []) {
            self.clientId = clientId; self.calendarId = calendarId
            self.scopes = scopes; self.internalDomains = internalDomains
        }
        enum CodingKeys: String, CodingKey {
            case clientId = "client_id", calendarId = "calendar_id", scopes
            case internalDomains = "internal_domains"
        }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self); let z = Google()
            clientId = try c.decodeIfPresent(String.self, forKey: .clientId) ?? z.clientId
            calendarId = try c.decodeIfPresent(String.self, forKey: .calendarId) ?? z.calendarId
            scopes = try c.decodeIfPresent([String].self, forKey: .scopes) ?? z.scopes
            internalDomains = try c.decodeIfPresent([String].self, forKey: .internalDomains) ?? z.internalDomains
        }
    }

    public struct KillSwitches: Codable, Sendable, Equatable {
        public var appWatcher: Bool, chrome: Bool, calendar: Bool, fathom: Bool, slack: Bool
        public init(appWatcher: Bool = true, chrome: Bool = true, calendar: Bool = true,
                    fathom: Bool = true, slack: Bool = true) {
            self.appWatcher = appWatcher; self.chrome = chrome; self.calendar = calendar
            self.fathom = fathom; self.slack = slack
        }
        enum CodingKeys: String, CodingKey { case appWatcher = "app_watcher", chrome, calendar, fathom, slack }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self); let z = KillSwitches()
            appWatcher = try c.decodeIfPresent(Bool.self, forKey: .appWatcher) ?? z.appWatcher
            chrome = try c.decodeIfPresent(Bool.self, forKey: .chrome) ?? z.chrome
            calendar = try c.decodeIfPresent(Bool.self, forKey: .calendar) ?? z.calendar
            fathom = try c.decodeIfPresent(Bool.self, forKey: .fathom) ?? z.fathom
            slack = try c.decodeIfPresent(Bool.self, forKey: .slack) ?? z.slack
        }
    }

    public struct Capture: Codable, Sendable, Equatable {
        public var browser: String
        public var heartbeatSeconds: Int
        public var idleThresholdSeconds: Int
        public var pageTextMaxBytes: Int
        public var killSwitches: KillSwitches
        public init(browser: String = "chrome", heartbeatSeconds: Int = 30,
                    idleThresholdSeconds: Int = 600, pageTextMaxBytes: Int = 4096,
                    killSwitches: KillSwitches = .init()) {
            self.browser = browser; self.heartbeatSeconds = heartbeatSeconds
            self.idleThresholdSeconds = idleThresholdSeconds; self.pageTextMaxBytes = pageTextMaxBytes
            self.killSwitches = killSwitches
        }
        enum CodingKeys: String, CodingKey {
            case browser, heartbeatSeconds = "heartbeat_seconds"
            case idleThresholdSeconds = "idle_threshold_seconds", pageTextMaxBytes = "page_text_max_bytes"
            case killSwitches = "kill_switches"
        }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self); let z = Capture()
            browser = try c.decodeIfPresent(String.self, forKey: .browser) ?? z.browser
            heartbeatSeconds = try c.decodeIfPresent(Int.self, forKey: .heartbeatSeconds) ?? z.heartbeatSeconds
            idleThresholdSeconds = try c.decodeIfPresent(Int.self, forKey: .idleThresholdSeconds) ?? z.idleThresholdSeconds
            pageTextMaxBytes = try c.decodeIfPresent(Int.self, forKey: .pageTextMaxBytes) ?? z.pageTextMaxBytes
            killSwitches = try c.decodeIfPresent(KillSwitches.self, forKey: .killSwitches) ?? z.killSwitches
        }
    }

    public struct Sessionization: Codable, Sendable, Equatable {
        public var detourToleranceSeconds: Int
        public var minSessionSeconds: Int
        public init(detourToleranceSeconds: Int = 120, minSessionSeconds: Int = 60) {
            self.detourToleranceSeconds = detourToleranceSeconds; self.minSessionSeconds = minSessionSeconds
        }
        enum CodingKeys: String, CodingKey {
            case detourToleranceSeconds = "detour_tolerance_seconds", minSessionSeconds = "min_session_seconds"
        }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self); let z = Sessionization()
            detourToleranceSeconds = try c.decodeIfPresent(Int.self, forKey: .detourToleranceSeconds) ?? z.detourToleranceSeconds
            minSessionSeconds = try c.decodeIfPresent(Int.self, forKey: .minSessionSeconds) ?? z.minSessionSeconds
        }
    }

    public struct Suggestions: Codable, Sendable, Equatable {
        public var incrementMinutes: Int
        public var roundUpBias: Double
        public var standaloneThresholdMinutes: Int
        public init(incrementMinutes: Int = 15, roundUpBias: Double = 0.4, standaloneThresholdMinutes: Int = 15) {
            self.incrementMinutes = incrementMinutes; self.roundUpBias = roundUpBias
            self.standaloneThresholdMinutes = standaloneThresholdMinutes
        }
        enum CodingKeys: String, CodingKey {
            case incrementMinutes = "increment_minutes", roundUpBias = "round_up_bias"
            case standaloneThresholdMinutes = "standalone_threshold_minutes"
        }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self); let z = Suggestions()
            incrementMinutes = try c.decodeIfPresent(Int.self, forKey: .incrementMinutes) ?? z.incrementMinutes
            roundUpBias = try c.decodeIfPresent(Double.self, forKey: .roundUpBias) ?? z.roundUpBias
            standaloneThresholdMinutes = try c.decodeIfPresent(Int.self, forKey: .standaloneThresholdMinutes) ?? z.standaloneThresholdMinutes
        }
    }

    public struct Recap: Codable, Sendable, Equatable {
        public var time: String
        public var morningCatchup: Bool
        public init(time: String = "17:00", morningCatchup: Bool = true) {
            self.time = time; self.morningCatchup = morningCatchup
        }
        enum CodingKeys: String, CodingKey { case time, morningCatchup = "morning_catchup" }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self); let z = Recap()
            time = try c.decodeIfPresent(String.self, forKey: .time) ?? z.time
            morningCatchup = try c.decodeIfPresent(Bool.self, forKey: .morningCatchup) ?? z.morningCatchup
        }
    }

    public struct QuietHours: Codable, Sendable, Equatable {
        public var start: String, end: String
        public init(start: String = "18:00", end: String = "09:00") { self.start = start; self.end = end }
    }

    public struct Nudges: Codable, Sendable, Equatable {
        public var enabled: Bool
        public var sustainedBlockMinutes: Int
        public var confidenceThreshold: Double
        public var dailyCap: Int
        public var quietHours: QuietHours
        public init(enabled: Bool = true, sustainedBlockMinutes: Int = 25, confidenceThreshold: Double = 0.7,
                    dailyCap: Int = 5, quietHours: QuietHours = .init()) {
            self.enabled = enabled; self.sustainedBlockMinutes = sustainedBlockMinutes
            self.confidenceThreshold = confidenceThreshold; self.dailyCap = dailyCap; self.quietHours = quietHours
        }
        enum CodingKeys: String, CodingKey {
            case enabled, sustainedBlockMinutes = "sustained_block_minutes"
            case confidenceThreshold = "confidence_threshold", dailyCap = "daily_cap", quietHours = "quiet_hours"
        }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self); let z = Nudges()
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? z.enabled
            sustainedBlockMinutes = try c.decodeIfPresent(Int.self, forKey: .sustainedBlockMinutes) ?? z.sustainedBlockMinutes
            confidenceThreshold = try c.decodeIfPresent(Double.self, forKey: .confidenceThreshold) ?? z.confidenceThreshold
            dailyCap = try c.decodeIfPresent(Int.self, forKey: .dailyCap) ?? z.dailyCap
            quietHours = try c.decodeIfPresent(QuietHours.self, forKey: .quietHours) ?? z.quietHours
        }
    }

    public struct Sensitivity: Codable, Sendable, Equatable {
        public var keywords: [String]
        public var flaggedPeople: [String]
        public var flaggedTerms: [String]
        public init(keywords: [String] = [], flaggedPeople: [String] = [], flaggedTerms: [String] = []) {
            self.keywords = keywords; self.flaggedPeople = flaggedPeople; self.flaggedTerms = flaggedTerms
        }
        enum CodingKeys: String, CodingKey {
            case keywords, flaggedPeople = "flagged_people", flaggedTerms = "flagged_terms"
        }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self); let z = Sensitivity()
            keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? z.keywords
            flaggedPeople = try c.decodeIfPresent([String].self, forKey: .flaggedPeople) ?? z.flaggedPeople
            flaggedTerms = try c.decodeIfPresent([String].self, forKey: .flaggedTerms) ?? z.flaggedTerms
        }
        /// The full set of terms/people the gate screens for (lowercased).
        public var allTerms: [String] {
            (keywords + flaggedPeople + flaggedTerms).map { $0.lowercased() }
        }
    }

    public struct Ingest: Codable, Sendable, Equatable {
        public var fathom: Fathom
        public var googleCalendar: GoogleCalendar
        public var slack: Slack
        public init(fathom: Fathom = .init(), googleCalendar: GoogleCalendar = .init(), slack: Slack = .init()) {
            self.fathom = fathom; self.googleCalendar = googleCalendar; self.slack = slack
        }
        enum CodingKeys: String, CodingKey { case fathom, googleCalendar = "google_calendar", slack }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self); let z = Ingest()
            fathom = try c.decodeIfPresent(Fathom.self, forKey: .fathom) ?? z.fathom
            googleCalendar = try c.decodeIfPresent(GoogleCalendar.self, forKey: .googleCalendar) ?? z.googleCalendar
            slack = try c.decodeIfPresent(Slack.self, forKey: .slack) ?? z.slack
        }
        public struct Fathom: Codable, Sendable, Equatable {
            public var pollIntervalSeconds: Int
            public init(pollIntervalSeconds: Int = 600) { self.pollIntervalSeconds = pollIntervalSeconds }
            enum CodingKeys: String, CodingKey { case pollIntervalSeconds = "poll_interval_seconds" }
            public init(from d: Decoder) throws {
                let c = try d.container(keyedBy: CodingKeys.self)
                pollIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 600
            }
        }
        public struct GoogleCalendar: Codable, Sendable, Equatable {
            public var pollIntervalSeconds: Int
            public init(pollIntervalSeconds: Int = 300) { self.pollIntervalSeconds = pollIntervalSeconds }
            enum CodingKeys: String, CodingKey { case pollIntervalSeconds = "poll_interval_seconds" }
            public init(from d: Decoder) throws {
                let c = try d.container(keyedBy: CodingKeys.self)
                pollIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 300
            }
        }
        public struct Slack: Codable, Sendable, Equatable {
            public var conversationListIntervalSeconds: Int
            public var historyIntervalSeconds: Int
            public init(conversationListIntervalSeconds: Int = 300, historyIntervalSeconds: Int = 180) {
                self.conversationListIntervalSeconds = conversationListIntervalSeconds
                self.historyIntervalSeconds = historyIntervalSeconds
            }
            enum CodingKeys: String, CodingKey {
                case conversationListIntervalSeconds = "conversation_list_interval_seconds"
                case historyIntervalSeconds = "history_interval_seconds"
            }
            public init(from d: Decoder) throws {
                let c = try d.container(keyedBy: CodingKeys.self); let z = Slack()
                conversationListIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .conversationListIntervalSeconds) ?? z.conversationListIntervalSeconds
                historyIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .historyIntervalSeconds) ?? z.historyIntervalSeconds
            }
        }
    }

    public struct AI: Codable, Sendable, Equatable {
        public var enabled: Bool
        public var routing: [String: String]
        public var models: [String: ModelConfig]
        public var pricesUsdPerMtok: [String: Price]
        public var budget: Budget
        public init(enabled: Bool = true, routing: [String: String] = [:],
                    models: [String: ModelConfig] = [:], pricesUsdPerMtok: [String: Price] = [:],
                    budget: Budget = .init()) {
            self.enabled = enabled; self.routing = routing; self.models = models
            self.pricesUsdPerMtok = pricesUsdPerMtok; self.budget = budget
        }
        enum CodingKeys: String, CodingKey {
            case enabled, routing, models, pricesUsdPerMtok = "prices_usd_per_mtok", budget
        }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self); let z = AI()
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? z.enabled
            routing = try c.decodeIfPresent([String: String].self, forKey: .routing) ?? z.routing
            models = try c.decodeIfPresent([String: ModelConfig].self, forKey: .models) ?? z.models
            pricesUsdPerMtok = try c.decodeIfPresent([String: Price].self, forKey: .pricesUsdPerMtok) ?? z.pricesUsdPerMtok
            budget = try c.decodeIfPresent(Budget.self, forKey: .budget) ?? z.budget
        }

        public struct Budget: Codable, Sendable, Equatable {
            public var dailyCapUsd: [String: Double]
            public var globalDailyCapUsd: Double?
            public init(dailyCapUsd: [String: Double] = [:], globalDailyCapUsd: Double? = nil) {
                self.dailyCapUsd = dailyCapUsd; self.globalDailyCapUsd = globalDailyCapUsd
            }
            enum CodingKeys: String, CodingKey {
                case dailyCapUsd = "daily_cap_usd", globalDailyCapUsd = "global_daily_cap_usd"
            }
            public init(from d: Decoder) throws {
                let c = try d.container(keyedBy: CodingKeys.self); let z = Budget()
                dailyCapUsd = try c.decodeIfPresent([String: Double].self, forKey: .dailyCapUsd) ?? z.dailyCapUsd
                globalDailyCapUsd = try c.decodeIfPresent(Double.self, forKey: .globalDailyCapUsd) ?? z.globalDailyCapUsd
            }
        }

        public struct ModelConfig: Codable, Sendable, Equatable {
            public var provider: String
            public var model: String
            public var endpoint: String?
            public init(provider: String = "", model: String = "", endpoint: String? = nil) {
                self.provider = provider; self.model = model; self.endpoint = endpoint
            }
        }
        public struct Price: Codable, Sendable, Equatable {
            public var input: Double?
            public var output: Double?
            public init(input: Double? = nil, output: Double? = nil) { self.input = input; self.output = output }
        }
    }
}
