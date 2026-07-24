import Foundation
import CryptoKit

/// Policy for capturing visible page text: truncate to a byte budget, content-hash to skip
/// duplicates. Pure and testable; the browser scripting that produces `rawText` is elsewhere.
public struct PageTextPolicy: Sendable {
    public let maxBytes: Int
    public init(maxBytes: Int = 4096) { self.maxBytes = maxBytes }

    public struct Prepared: Sendable, Equatable {
        public let text: String
        public let bytes: Int
        public let hash: String
    }

    public func prepare(_ raw: String) -> Prepared {
        let truncated = Self.truncateToBytes(raw, maxBytes)
        let data = Data(truncated.utf8)
        return Prepared(text: truncated, bytes: data.count, hash: Self.sha256(data))
    }

    /// Store only when the content changed since the last snapshot for this URL.
    public func shouldStore(newHash: String, previousHash: String?) -> Bool {
        newHash != previousHash
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Truncate to at most `maxBytes` UTF-8 bytes without splitting a character.
    static func truncateToBytes(_ s: String, _ maxBytes: Int) -> String {
        if s.utf8.count <= maxBytes { return s }
        var result = ""
        var count = 0
        for ch in s {
            let n = String(ch).utf8.count
            if count + n > maxBytes { break }
            result.append(ch)
            count += n
        }
        return result
    }
}
