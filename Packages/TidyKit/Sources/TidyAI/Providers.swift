import Foundation
import TidyCore
import TidyIngest

// Cloud + on-device provider implementations of `AIProvider`. Request-building + response-parsing
// are reused via TidyIngest's HTTPClient. ⚠️ Build-time checks: the exact Fireworks/Anthropic model
// slugs and, for Anthropic, the structured-output request shape (see docs + DECISIONS.md).

/// Fireworks AI — OpenAI-compatible `/chat/completions`.
public struct FireworksProvider: AIProvider {
    public let providerName = "fireworks"
    private let http: HTTPClient
    private let apiKey: String
    private let endpoint: URL

    public init(http: HTTPClient, apiKey: String,
                endpoint: URL = URL(string: "https://api.fireworks.ai/inference/v1")!) {
        self.http = http; self.apiKey = apiKey; self.endpoint = endpoint
    }

    private struct Response: Decodable {
        struct Choice: Decodable { struct Msg: Decodable { let content: String? }; let message: Msg }
        struct Usage: Decodable { let prompt_tokens: Int?; let completion_tokens: Int? }
        let choices: [Choice]
        let usage: Usage?
    }

    public func complete(model: String, systemPrompt: String?, userPrompt: String, jsonSchema: String?) async throws -> AICompletion {
        var messages: [[String: Any]] = []
        if let systemPrompt { messages.append(["role": "system", "content": systemPrompt]) }
        messages.append(["role": "user", "content": userPrompt])
        var body: [String: Any] = ["model": model, "messages": messages]
        if let jsonSchema, let schemaObj = try? JSONSerialization.jsonObject(with: Data(jsonSchema.utf8)) {
            body["response_format"] = ["type": "json_schema",
                                       "json_schema": ["name": "result", "schema": schemaObj]]
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        let request = HTTPRequest(method: "POST", url: endpoint.appendingPathComponent("chat/completions"),
                                  headers: ["Authorization": "Bearer \(apiKey)", "Content-Type": "application/json"],
                                  body: data)
        let response = try await http.send(request)
        guard (200..<300).contains(response.status) else {
            throw IngestError.http(status: response.status, body: String(decoding: response.body, as: UTF8.self))
        }
        let parsed = try JSONDecoder().decode(Response.self, from: response.body)
        return AICompletion(text: parsed.choices.first?.message.content ?? "",
                            inputTokens: parsed.usage?.prompt_tokens ?? 0,
                            outputTokens: parsed.usage?.completion_tokens ?? 0)
    }
}

/// Anthropic Claude — `/messages`. The JSON-schema structured-output surface is a build-time check;
/// here we pass any requested schema inside the system prompt and read the text back.
public struct AnthropicProvider: AIProvider {
    public let providerName = "anthropic"
    private let http: HTTPClient
    private let apiKey: String
    private let endpoint: URL
    private let maxTokens: Int

    public init(http: HTTPClient, apiKey: String,
                endpoint: URL = URL(string: "https://api.anthropic.com/v1")!, maxTokens: Int = 1024) {
        self.http = http; self.apiKey = apiKey; self.endpoint = endpoint; self.maxTokens = maxTokens
    }

    private struct Response: Decodable {
        struct Content: Decodable { let text: String? }
        struct Usage: Decodable { let input_tokens: Int?; let output_tokens: Int? }
        let content: [Content]
        let usage: Usage?
    }

    public func complete(model: String, systemPrompt: String?, userPrompt: String, jsonSchema: String?) async throws -> AICompletion {
        var system = systemPrompt ?? ""
        if let jsonSchema { system += "\n\nRespond ONLY with JSON matching this schema:\n\(jsonSchema)" }
        var body: [String: Any] = [
            "model": model, "max_tokens": maxTokens,
            "messages": [["role": "user", "content": userPrompt]],
        ]
        if !system.isEmpty { body["system"] = system }
        let data = try JSONSerialization.data(withJSONObject: body)
        let request = HTTPRequest(method: "POST", url: endpoint.appendingPathComponent("messages"),
                                  headers: ["x-api-key": apiKey, "anthropic-version": "2023-06-01",
                                            "Content-Type": "application/json"], body: data)
        let response = try await http.send(request)
        guard (200..<300).contains(response.status) else {
            throw IngestError.http(status: response.status, body: String(decoding: response.body, as: UTF8.self))
        }
        let parsed = try JSONDecoder().decode(Response.self, from: response.body)
        let text = parsed.content.compactMap { $0.text }.joined()
        return AICompletion(text: text, inputTokens: parsed.usage?.input_tokens ?? 0,
                            outputTokens: parsed.usage?.output_tokens ?? 0)
    }
}

/// Apple on-device (Foundation Models). Availability-gated; falls through (throws) when Apple
/// Intelligence is off or the framework is unavailable so the router escalates to a cloud rung.
public struct AppleOnDeviceProvider: AIProvider {
    public let providerName = "apple"
    public init() {}

    public func complete(model: String, systemPrompt: String?, userPrompt: String, jsonSchema: String?) async throws -> AICompletion {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return try await FoundationModelsRunner.respond(system: systemPrompt, user: userPrompt)
        }
        #endif
        throw TidyError.classification("Foundation Models unavailable (needs macOS 26 + Apple Intelligence)")
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
enum FoundationModelsRunner {
    static func respond(system: String?, user: String) async throws -> AICompletion {
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            throw TidyError.classification("Apple Intelligence not available on this device")
        }
        let session = system.map { LanguageModelSession(instructions: $0) } ?? LanguageModelSession()
        let response = try await session.respond(to: user)
        // Foundation Models doesn't expose token counts; leave 0 (on-device is free anyway).
        return AICompletion(text: response.content, inputTokens: 0, outputTokens: 0)
    }
}
#endif
