import Foundation

/// Drafts a one-to-two sentence time-entry note via the router. If the content is sensitive, over
/// budget, or the call fails, it returns the bland `fallback` — the sensitivity gate guarantees the
/// content never reached a cloud model (guardrail G2: a generic note over a leaked one).
public struct NoteDrafter: Sendable {
    private let router: AIRouter
    public init(router: AIRouter) { self.router = router }

    public func draft(context: String, fallback: String, requestRef: String? = nil) async -> String {
        let result = try? await router.run(
            job: "note_draft",
            systemPrompt: "Write a concise, professional one-sentence time-entry note. No names of people.",
            userPrompt: context, requestRef: requestRef)
        switch result {
        case .ok(let text, _): return text.isEmpty ? fallback : text
        default: return fallback   // refusedSensitive / refusedBudget / failed / nil → bland fallback
        }
    }
}
