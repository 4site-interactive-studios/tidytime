// TidyAI — the provider router (the single metered call site), the on-device rung, the Fireworks and
// Anthropic cloud clients, the usage ledger (ai_calls), and budget caps. The ONLY place cloud calls
// happen; every call is sensitivity-gated (G2) and metered + budget-capped (G5).
// See docs/architecture/classification-ladder.md and docs/conventions/ai-provider-router.md.
import Foundation
import TidyCore
import TidyStore
import TidyUnderstand

/// One model completion.
public struct AICompletion: Sendable, Equatable {
    public let text: String
    public let inputTokens: Int
    public let outputTokens: Int
    public init(text: String, inputTokens: Int, outputTokens: Int) {
        self.text = text; self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }
}

/// A single provider (Apple on-device, Fireworks, Anthropic). Kept minimal: one call.
public protocol AIProvider: Sendable {
    var providerName: String { get }   // 'apple' | 'fireworks' | 'anthropic'
    func complete(model: String, systemPrompt: String?, userPrompt: String, jsonSchema: String?) async throws -> AICompletion
}

/// Cost from the config price table ($/M tokens).
public enum ModelCost {
    public static func cost(model: String, input: Int, output: Int, prices: [String: Config.AI.Price]) -> Double {
        guard let p = prices[model] else { return 0 }
        return (p.input ?? 0) * Double(input) / 1_000_000 + (p.output ?? 0) * Double(output) / 1_000_000
    }
}

/// Per-provider + global daily spend caps (guardrail G5).
public struct BudgetPolicy: Sendable {
    public let perProviderDailyCapUsd: [String: Double]
    public let globalDailyCapUsd: Double?
    public init(perProviderDailyCapUsd: [String: Double] = [:], globalDailyCapUsd: Double? = nil) {
        self.perProviderDailyCapUsd = perProviderDailyCapUsd
        self.globalDailyCapUsd = globalDailyCapUsd
    }
    public init(config: Config) {
        self.init(perProviderDailyCapUsd: config.ai.budget.dailyCapUsd,
                  globalDailyCapUsd: config.ai.budget.globalDailyCapUsd)
    }
    public func isOverCap(provider: String, providerSpend: Double, globalSpend: Double) -> Bool {
        if let cap = perProviderDailyCapUsd[provider], providerSpend >= cap { return true }
        if let g = globalDailyCapUsd, globalSpend >= g { return true }
        return false
    }
}

/// The exact payload that would be sent to a cloud model. Recorded (opt-in) so a test can prove no
/// sensitive content ever reaches a provider (guardrail G2). Contains prompts only — never auth.
public struct OutboundPayload: Sendable, Equatable {
    public let provider: String
    public let system: String?
    public let user: String
    public let schema: String?
}

public protocol OutboundPayloadRecorder: Sendable {
    func record(_ payload: OutboundPayload)
}

public final class InMemoryOutboundRecorder: OutboundPayloadRecorder, @unchecked Sendable {
    private let lock = NSLock()
    private var _payloads: [OutboundPayload] = []
    public init() {}
    public func record(_ payload: OutboundPayload) { lock.lock(); _payloads.append(payload); lock.unlock() }
    public var payloads: [OutboundPayload] { lock.lock(); defer { lock.unlock() }; return _payloads }
    /// True if `needle` appears anywhere in any recorded payload (the guardrail assertion).
    public func containsText(_ needle: String) -> Bool {
        payloads.contains { ($0.user + ($0.system ?? "") + ($0.schema ?? "")).localizedCaseInsensitiveContains(needle) }
    }
}

public enum AIResult: Sendable, Equatable {
    case ok(text: String, costUsd: Double)
    case refusedSensitive
    case refusedBudget
    case failed(String)
}

/// The single metered call site. Order of operations (never reordered):
///   sensitivity gate → resolve route → budget check → record outbound → call → write ledger row.
public struct AIRouter: Sendable {
    private let db: AppDatabase
    private let clock: TidyClock
    private let gate: SensitivityGate
    private let budget: BudgetPolicy
    private let prices: [String: Config.AI.Price]
    private let routing: [String: String]
    private let models: [String: Config.AI.ModelConfig]
    private let providers: [String: AIProvider]
    private let outbound: OutboundPayloadRecorder?
    private let dayBounds: @Sendable (Date) -> (Int64, Int64)

    public init(db: AppDatabase, clock: TidyClock = SystemClock(), gate: SensitivityGate,
                budget: BudgetPolicy, config: Config, providers: [AIProvider],
                outbound: OutboundPayloadRecorder? = nil,
                dayBounds: (@Sendable (Date) -> (Int64, Int64))? = nil) {
        self.db = db; self.clock = clock; self.gate = gate; self.budget = budget
        self.prices = config.ai.pricesUsdPerMtok
        self.routing = config.ai.routing
        self.models = config.ai.models
        self.providers = Dictionary(providers.map { ($0.providerName, $0) }, uniquingKeysWith: { a, _ in a })
        self.outbound = outbound
        // Budget "day" = the user's LOCAL calendar day, matching the recap/gap-analysis day
        // boundary (data-model.md "Days" convention) — not UTC. The app can inject a config-tz
        // variant; the default uses the current zone so the cap resets at local midnight.
        self.dayBounds = dayBounds ?? { now in
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone.current
            let start = cal.startOfDay(for: now)
            let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            return (Int64(start.timeIntervalSince1970), Int64(end.timeIntervalSince1970))
        }
    }

    @discardableResult
    public func run(job: String, systemPrompt: String? = nil, userPrompt: String,
                    jsonSchema: String? = nil, requestRef: String? = nil) async throws -> AIResult {
        let occurred = Int64(clock.now.timeIntervalSince1970)

        // 1. Sensitivity gate (G2) — fails closed; blocked content is NEVER sent.
        if gate.isSensitive(userPrompt) || (systemPrompt.map(gate.isSensitive) ?? false) {
            try db.insertAICall(AICall(occurredAt: occurred, jobType: job, provider: "none", model: "none",
                                       outcome: "refused_sensitive", requestRef: requestRef))
            return .refusedSensitive
        }

        // 2. Resolve route.
        guard let modelKey = routing[job], let mc = models[modelKey], let provider = providers[mc.provider] else {
            try db.insertAICall(AICall(occurredAt: occurred, jobType: job, provider: "none", model: "none",
                                       outcome: "error", requestRef: requestRef, error: "no route for job \(job)"))
            return .failed("no route for job \(job)")
        }

        // 3. Budget check (G5) — over cap → local-only, nothing sent.
        let (from, to) = dayBounds(clock.now)
        let providerSpend = try db.aiCost(from: from, to: to, provider: mc.provider)
        let globalSpend = try db.aiCost(from: from, to: to)
        if budget.isOverCap(provider: mc.provider, providerSpend: providerSpend, globalSpend: globalSpend) {
            try db.insertAICall(AICall(occurredAt: occurred, jobType: job, provider: mc.provider, model: mc.model,
                                       outcome: "refused_budget", requestRef: requestRef))
            return .refusedBudget
        }

        // 4. Record the exact outbound payload (gate passed → safe to record & send).
        outbound?.record(OutboundPayload(provider: mc.provider, system: systemPrompt, user: userPrompt, schema: jsonSchema))

        // 5. Call + 6. ledger.
        let start = clock.now
        do {
            let completion = try await provider.complete(model: mc.model, systemPrompt: systemPrompt,
                                                         userPrompt: userPrompt, jsonSchema: jsonSchema)
            let latency = Int(clock.now.timeIntervalSince(start) * 1000)
            let cost = ModelCost.cost(model: mc.model, input: completion.inputTokens,
                                      output: completion.outputTokens, prices: prices)
            try db.insertAICall(AICall(occurredAt: occurred, jobType: job, provider: mc.provider, model: mc.model,
                                       inputTokens: completion.inputTokens, outputTokens: completion.outputTokens,
                                       costUsd: cost, latencyMs: latency, outcome: "ok", requestRef: requestRef))
            return .ok(text: completion.text, costUsd: cost)
        } catch {
            try db.insertAICall(AICall(occurredAt: occurred, jobType: job, provider: mc.provider, model: mc.model,
                                       outcome: "error", requestRef: requestRef, error: "\(error)"))
            return .failed("\(error)")
        }
    }
}

/// Test double.
public struct FakeAIProvider: AIProvider {
    public let providerName: String
    public var response: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var shouldFail: Bool
    public init(providerName: String, response: String = "{}", inputTokens: Int = 10,
                outputTokens: Int = 20, shouldFail: Bool = false) {
        self.providerName = providerName; self.response = response
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.shouldFail = shouldFail
    }
    public func complete(model: String, systemPrompt: String?, userPrompt: String, jsonSchema: String?) async throws -> AICompletion {
        if shouldFail { throw TidyError.classification("fake provider failure") }
        return AICompletion(text: response, inputTokens: inputTokens, outputTokens: outputTokens)
    }
}
