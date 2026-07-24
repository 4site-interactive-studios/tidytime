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

/// Exponential backoff with a cap; honors a server `Retry-After` when present.
public struct Backoff: Sendable {
    public let base: TimeInterval
    public let cap: TimeInterval
    public init(base: TimeInterval = 0.5, cap: TimeInterval = 30) { self.base = base; self.cap = cap }

    public func delay(attempt: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        if let retryAfter { return min(retryAfter, cap) }
        return min(cap, base * pow(2.0, Double(max(0, attempt))))
    }
}
