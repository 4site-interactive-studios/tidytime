import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A minimal request/response pair + client protocol so all ingest is testable with a fake.
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method; self.url = url; self.headers = headers; self.body = body
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }
    /// Convenience for tests: a JSON response.
    public static func json(_ string: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers, body: Data(string.utf8))
    }

    /// Case-**insensitive** header lookup. HTTP header names are case-insensitive by spec, and
    /// over HTTP/2 they are lowercase on the wire — so `headers["Retry-After"]` on a real HTTP/2
    /// response misses `retry-after` every time. All three ingest clients did exactly that, which
    /// silently disabled every server-directed backoff: `Retry-After` parsed as `nil` and the
    /// client fell back to its own (much shorter) exponential delay while believing it was
    /// honoring the server. Never subscript `headers` directly for a server-sent name.
    public func header(_ name: String) -> String? {
        if let exact = headers[name] { return exact }
        let wanted = name.lowercased()
        return headers.first { $0.key.lowercased() == wanted }?.value
    }

    /// Seconds the server says to wait, from whichever rate-limit header it actually sends.
    ///
    /// `Retry-After` is the common one, but it is **not** universal: Fathom advertises the IETF
    /// `RateLimit-*` family (`ratelimit-limit`, `ratelimit-remaining`, `ratelimit-reset`) and sends
    /// no `Retry-After` at all — verified against a live `api.fathom.ai` response on 2026-08-28.
    /// A client that only reads `Retry-After` is flying blind against that provider.
    public var serverRequestedDelay: TimeInterval? {
        if let ra = header("Retry-After").flatMap(TimeInterval.init) { return ra }
        // `ratelimit-reset` is seconds-until-reset. A 0 means "the window has already rolled";
        // treat it as no guidance rather than "retry instantly", which would hammer the limit.
        if let reset = header("RateLimit-Reset").flatMap(TimeInterval.init), reset > 0 { return reset }
        return nil
    }
}

public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// Live client over URLSession.
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var req = URLRequest(url: request.url)
        req.httpMethod = request.method
        for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = request.body
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw IngestError.transport("non-HTTP response")
            }
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields {
                if let ks = k as? String, let vs = v as? String { headers[ks] = vs }
            }
            return HTTPResponse(status: http.statusCode, headers: headers, body: data)
        } catch let e as IngestError {
            throw e
        } catch {
            throw IngestError.transport("\(error)")
        }
    }
}

/// Test double: returns queued responses in order and records every request sent.
public final class FakeHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<HTTPResponse, IngestError>]
    private var _sent: [HTTPRequest] = []

    public init(_ responses: [HTTPResponse]) { queue = responses.map { .success($0) } }
    public init(results: [Result<HTTPResponse, IngestError>]) { queue = results }

    public var sentRequests: [HTTPRequest] {
        lock.lock(); defer { lock.unlock() }; return _sent
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let next: Result<HTTPResponse, IngestError>? = lock.withLock {
            _sent.append(request)
            return queue.isEmpty ? nil : queue.removeFirst()
        }
        guard let next else { throw IngestError.transport("FakeHTTPClient: no stubbed response for \(request.url)") }
        return try next.get()
    }
}

/// Exponential backoff with a cap; honors a server-requested delay when present.
public struct Backoff: Sendable {
    public let base: TimeInterval
    public let cap: TimeInterval
    public init(base: TimeInterval = 0.5, cap: TimeInterval = 30) { self.base = base; self.cap = cap }

    /// Total seconds this backoff will sleep across `retries` attempts with no server guidance.
    /// Used to state the real waited time in an exhausted-retries error, instead of guessing.
    public func totalDelay(retries: Int) -> TimeInterval {
        (0..<max(0, retries)).reduce(0) { $0 + delay(attempt: $1) }
    }

    public func delay(attempt: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        if let retryAfter { return min(retryAfter, cap) }
        return min(cap, base * pow(2.0, Double(max(0, attempt))))
    }
}
