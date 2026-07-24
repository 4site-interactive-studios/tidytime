import XCTest
import Foundation
import TidyCore
import TidyStore
import TidyUnderstand
@testable import TidyIngest
@testable import TidyAI

private func aiConfig(cap: Double? = nil, global: Double? = nil) -> Config {
    var cfg = Config()
    cfg.ai.routing = ["note_draft": "economy", "session_batch": "economy", "escalation": "claude"]
    cfg.ai.models = [
        "economy": .init(provider: "fireworks", model: "kimi", endpoint: nil),
        "claude": .init(provider: "anthropic", model: "claude-opus-4-8", endpoint: nil),
    ]
    cfg.ai.pricesUsdPerMtok = ["kimi": .init(input: 1.0, output: 4.0), "claude-opus-4-8": .init(input: 15, output: 75)]
    cfg.ai.budget = .init(dailyCapUsd: cap.map { ["fireworks": $0] } ?? [:], globalDailyCapUsd: global)
    return cfg
}

private func makeRouter(db: AppDatabase, config: Config, gateTerms: [String] = [],
                        provider: AIProvider, outbound: OutboundPayloadRecorder? = nil,
                        clock: TidyClock = FixedClock(Date(timeIntervalSince1970: 1_000_000))) -> AIRouter {
    AIRouter(db: db, clock: clock, gate: SensitivityGate(terms: gateTerms),
             budget: BudgetPolicy(config: config), config: config, providers: [provider],
             outbound: outbound, dayBounds: { _ in (0, 10_000_000) })
}

final class ModelCostTests: XCTestCase {
    func testCostFromPriceTable() {
        let prices = ["kimi": Config.AI.Price(input: 0.95, output: 4.0)]
        // 1M input + 0.5M output
        let cost = ModelCost.cost(model: "kimi", input: 1_000_000, output: 500_000, prices: prices)
        XCTAssertEqual(cost, 0.95 + 2.0, accuracy: 1e-9)
        XCTAssertEqual(ModelCost.cost(model: "unknown", input: 1000, output: 1000, prices: prices), 0)
    }
}

final class AIRouterTests: XCTestCase {
    /// G5: a successful call is metered into ai_calls with a computed cost.
    func testSuccessfulCallIsLedgered() async throws {
        let db = try AppDatabase.inMemory()
        let cfg = aiConfig()
        let router = makeRouter(db: db, config: cfg,
                                provider: FakeAIProvider(providerName: "fireworks", response: "{\"ok\":1}",
                                                         inputTokens: 1_000_000, outputTokens: 1_000_000))
        let result = try await router.run(job: "session_batch", userPrompt: "classify these sessions")
        guard case .ok(let text, let cost) = result else { return XCTFail("expected ok, got \(result)") }
        XCTAssertEqual(text, "{\"ok\":1}")
        XCTAssertEqual(cost, 1.0 + 4.0, accuracy: 1e-9)  // kimi 1.0 in + 4.0 out per M
        let calls = try db.aiCalls(from: 0, to: 10_000_000)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].outcome, "ok")
        XCTAssertEqual(calls[0].provider, "fireworks")
    }

    /// G2: sensitive content is refused, ledgered as refused_sensitive, and NEVER recorded outbound.
    func testSensitiveContentNeverSent() async throws {
        let db = try AppDatabase.inMemory()
        let outbound = InMemoryOutboundRecorder()
        let router = makeRouter(db: db, config: aiConfig(), gateTerms: ["PIP", "salary"],
                                provider: FakeAIProvider(providerName: "fireworks"), outbound: outbound)
        let secret = "discussed the PIP for the new hire and their salary"
        let result = try await router.run(job: "note_draft", userPrompt: secret)
        XCTAssertEqual(result, .refusedSensitive)
        // The provider was never asked, and the sensitive text is in NO outbound payload.
        XCTAssertTrue(outbound.payloads.isEmpty)
        XCTAssertFalse(outbound.containsText("PIP"))
        XCTAssertFalse(outbound.containsText("salary"))
        XCTAssertEqual(try db.aiCalls(from: 0, to: 10_000_000).first?.outcome, "refused_sensitive")
    }

    /// G5: when today's spend is at/over the provider cap, the call is refused (local-only).
    func testBudgetCapRefusesCall() async throws {
        let db = try AppDatabase.inMemory()
        // Seed prior spend at the cap.
        try db.insertAICall(AICall(occurredAt: 5, jobType: "session_batch", provider: "fireworks",
                                   model: "kimi", costUsd: 2.0, outcome: "ok"))
        let router = makeRouter(db: db, config: aiConfig(cap: 2.0),
                                provider: FakeAIProvider(providerName: "fireworks"))
        let result = try await router.run(job: "session_batch", userPrompt: "more work")
        XCTAssertEqual(result, .refusedBudget)
        XCTAssertEqual(try db.aiCalls(from: 0, to: 10_000_000).last?.outcome, "refused_budget")
    }

    func testNoRouteFails() async throws {
        let db = try AppDatabase.inMemory()
        let router = makeRouter(db: db, config: aiConfig(), provider: FakeAIProvider(providerName: "fireworks"))
        let result = try await router.run(job: "unknown_job", userPrompt: "x")
        guard case .failed = result else { return XCTFail("expected failure") }
    }

    func testProviderErrorIsLedgered() async throws {
        let db = try AppDatabase.inMemory()
        let router = makeRouter(db: db, config: aiConfig(),
                                provider: FakeAIProvider(providerName: "fireworks", shouldFail: true))
        let result = try await router.run(job: "session_batch", userPrompt: "x")
        guard case .failed = result else { return XCTFail("expected failure") }
        XCTAssertEqual(try db.aiCalls(from: 0, to: 10_000_000).first?.outcome, "error")
    }
}

final class NoteDrafterTests: XCTestCase {
    func testSensitiveDraftReturnsFallback() async throws {
        let db = try AppDatabase.inMemory()
        let router = makeRouter(db: db, config: aiConfig(), gateTerms: ["termination"],
                                provider: FakeAIProvider(providerName: "fireworks", response: "should not be used"))
        let note = await NoteDrafter(router: router).draft(
            context: "1:1 about termination details", fallback: "1:1 check-in")
        XCTAssertEqual(note, "1:1 check-in")  // gate → generic fallback
    }
    func testNormalDraftUsesModel() async throws {
        let db = try AppDatabase.inMemory()
        let router = makeRouter(db: db, config: aiConfig(),
                                provider: FakeAIProvider(providerName: "fireworks", response: "Reviewed the donation page."))
        let note = await NoteDrafter(router: router).draft(
            context: "worked on the donation page layout", fallback: "worked on client project")
        XCTAssertEqual(note, "Reviewed the donation page.")
    }
}

final class FireworksParseTests: XCTestCase {
    func testParsesChatCompletion() async throws {
        let json = """
        { "choices": [ { "message": { "content": "14 min Client A, 6 min internal" } } ],
          "usage": { "prompt_tokens": 1200, "completion_tokens": 40 } }
        """
        let http = FakeHTTPClient([.json(json)])
        let provider = FireworksProvider(http: http, apiKey: "fw-key")
        let completion = try await provider.complete(model: "kimi", systemPrompt: "split this",
                                                     userPrompt: "transcript...", jsonSchema: nil)
        XCTAssertEqual(completion.text, "14 min Client A, 6 min internal")
        XCTAssertEqual(completion.inputTokens, 1200)
        XCTAssertEqual(completion.outputTokens, 40)
        XCTAssertEqual(http.sentRequests[0].method, "POST")
        XCTAssertEqual(http.sentRequests[0].headers["Authorization"], "Bearer fw-key")
    }
}

final class DashboardTests: XCTestCase {
    func testAggregatesLedger() throws {
        let db = try AppDatabase.inMemory()
        try db.insertAICall(AICall(occurredAt: 1, jobType: "session_batch", provider: "fireworks", model: "kimi", costUsd: 0.10, outcome: "ok"))
        try db.insertAICall(AICall(occurredAt: 2, jobType: "escalation", provider: "anthropic", model: "claude", costUsd: 0.50, outcome: "ok"))
        try db.insertAICall(AICall(occurredAt: 3, jobType: "on_device_classify", provider: "apple", model: "fm", costUsd: 0, outcome: "ok"))
        try db.insertAICall(AICall(occurredAt: 4, jobType: "note_draft", provider: "none", model: "none", outcome: "refused_sensitive"))
        let dash = try DashboardBuilder(db: db).build(from: 0, to: 100)
        XCTAssertEqual(dash.totalCostUsd, 0.60, accuracy: 1e-9)
        XCTAssertEqual(dash.refusedSensitive, 1)
        XCTAssertEqual(dash.onDeviceShare, 1.0 / 3.0, accuracy: 0.01)  // 1 apple of 3 resolved
        XCTAssertEqual(dash.escalationRate, 1.0, accuracy: 0.01)       // 1 escalation / 1 economy call
        XCTAssertTrue(try DashboardBuilder(db: db).csv(from: 0, to: 100).contains("job_type"))
    }
}
