import Foundation
import TidyStore

/// Read model for the AI-overhead dashboard, built from `ai_calls` (all local).
public struct AIDashboard: Sendable, Equatable {
    public let totalCostUsd: Double
    public let callCount: Int
    public let costByJobType: [String: Double]
    public let costByProvider: [String: Double]
    /// escalations ÷ economy-tier calls — "is the cheap tier earning its keep".
    public let escalationRate: Double
    /// share of resolved calls handled free on-device.
    public let onDeviceShare: Double
    public let refusedSensitive: Int
    public let refusedBudget: Int
}

public struct DashboardBuilder: Sendable {
    private let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    public func build(from: Int64, to: Int64) throws -> AIDashboard {
        let calls = try db.aiCalls(from: from, to: to)
        var byJob: [String: Double] = [:]
        var byProvider: [String: Double] = [:]
        var total = 0.0
        var escalations = 0, economy = 0, onDevice = 0, resolved = 0
        var refusedSensitive = 0, refusedBudget = 0
        for c in calls {
            total += c.costUsd
            byJob[c.jobType, default: 0] += c.costUsd
            byProvider[c.provider, default: 0] += c.costUsd
            switch c.outcome {
            case "refused_sensitive": refusedSensitive += 1
            case "refused_budget": refusedBudget += 1
            case "ok", "retried", "escalated":
                resolved += 1
                if c.provider == "apple" { onDevice += 1 }
                if c.provider == "fireworks" { economy += 1 }
                if c.jobType == "escalation" || c.outcome == "escalated" { escalations += 1 }
            default: break
            }
        }
        return AIDashboard(
            totalCostUsd: total, callCount: calls.count, costByJobType: byJob, costByProvider: byProvider,
            escalationRate: economy > 0 ? Double(escalations) / Double(economy) : 0,
            onDeviceShare: resolved > 0 ? Double(onDevice) / Double(resolved) : 0,
            refusedSensitive: refusedSensitive, refusedBudget: refusedBudget)
    }

    /// CSV of the ledger for internal overhead accounting.
    public func csv(from: Int64, to: Int64) throws -> String {
        var out = "occurred_at,job_type,provider,model,input_tokens,output_tokens,cost_usd,outcome\n"
        for c in try db.aiCalls(from: from, to: to) {
            out += "\(c.occurredAt),\(c.jobType),\(c.provider),\(c.model),\(c.inputTokens),\(c.outputTokens),\(c.costUsd),\(c.outcome)\n"
        }
        return out
    }
}
