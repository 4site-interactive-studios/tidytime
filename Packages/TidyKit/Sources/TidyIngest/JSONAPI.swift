import Foundation

/// Minimal JSON:API decoding for the resources TidyTime reads from Productive. Not a general
/// implementation — just documents whose `data` is an array of resources with typed attributes and
/// single/array relationships. We do NOT use `.convertFromSnakeCase` (it would also mangle the
/// relationships dictionary keys); attribute structs use explicit CodingKeys.
public struct JSONAPIDocument<A: Decodable & Sendable>: Decodable, Sendable {
    public let data: [JSONAPIResource<A>]
    public let links: Links?
    /// How many resources in `data` could not be decoded and were skipped. Surfaced rather than
    /// swallowed: silently dropping rows is how a sync looks healthy while losing data.
    public let skipped: Int

    public struct Links: Decodable, Sendable {
        public let next: String?
    }

    enum CodingKeys: String, CodingKey { case data, links }

    /// Decodes `data` **element by element**, keeping the good resources and counting the bad.
    ///
    /// A plain `[JSONAPIResource<A>]` decode is all-or-nothing: one malformed resource anywhere in
    /// the page throws, which aborts the whole sync — and, because `ProductiveSync.run()` fetches
    /// tasks before time entries, aborts every later step too. One unexpected attribute in one row
    /// should not cost the user their time entries.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        links = try container.decodeIfPresent(Links.self, forKey: .links)

        var kept: [JSONAPIResource<A>] = []
        var dropped = 0
        var array = try container.nestedUnkeyedContainer(forKey: .data)
        while !array.isAtEnd {
            do {
                kept.append(try array.decode(JSONAPIResource<A>.self))
            } catch {
                // The element must still be consumed or the loop never advances. Decoding it as a
                // free-form value is what moves the cursor past the bad entry.
                _ = try? array.decode(AnyJSON.self)
                dropped += 1
            }
        }
        data = kept
        skipped = dropped
    }
}

/// Consumes an arbitrary JSON value. Exists only so a failed element decode can be skipped past —
/// `UnkeyedDecodingContainer` has no other way to advance.
struct AnyJSON: Decodable {
    init(from decoder: Decoder) throws {
        if let c = try? decoder.singleValueContainer(), c.decodeNil() { return }
        if var c = try? decoder.unkeyedContainer() {
            while !c.isAtEnd { _ = try? c.decode(AnyJSON.self) }
            return
        }
        _ = try? decoder.container(keyedBy: AnyKey.self)
    }
    struct AnyKey: CodingKey {
        var stringValue: String; var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
        init?(intValue: Int) { self.intValue = intValue; stringValue = String(intValue) }
    }
}

public struct JSONAPIResource<A: Decodable & Sendable>: Decodable, Sendable {
    public let id: String
    public let type: String
    public let attributes: A
    public let relationships: [String: JSONAPIRelationship]?

    /// The id of a to-one relationship (e.g. a project's `company`).
    public func relationshipId(_ name: String) -> String? {
        guard let rel = relationships?[name], case .one(let ident)? = rel.data else { return nil }
        return ident.id
    }
}

public struct ResourceIdentifier: Decodable, Sendable {
    public let type: String
    public let id: String
}

public struct JSONAPIRelationship: Decodable, Sendable {
    public let data: RelationshipData?

    public enum RelationshipData: Decodable, Sendable {
        case one(ResourceIdentifier)
        case many([ResourceIdentifier])

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let single = try? container.decode(ResourceIdentifier.self) {
                self = .one(single)
            } else if let list = try? container.decode([ResourceIdentifier].self) {
                self = .many(list)
            } else {
                // `data: null` decodes the relationship's `data` as nil at the outer level; if we
                // somehow reach here with an unexpected shape, surface it.
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "unrecognized relationship data shape")
            }
        }
    }
}

// MARK: - Lenient scalar decoding

/// Vendor JSON is not as typed as its documentation claims.
///
/// Productive's own API reference shows `"task_number": 412` and `"status": 1` — integers. The live
/// API returns `task_number` as a **string**. Our model, our fixtures, and the reference doc were
/// all written from that doc, so all three agreed with each other and disagreed with reality, and
/// The 332-test suite said nothing. The first live sync threw
/// `typeMismatch … Expected to decode Int but found a string instead` on `data[0].attributes`,
/// which aborted `ProductiveSync.run()` before it ever reached time entries — leaving `pd_tasks`
/// *and* `pd_time_entries` at zero while companies, projects and people synced fine.
///
/// These helpers accept either representation and **never throw**: an unparseable value degrades
/// that one field to `nil`. Same principle as the Slack per-conversation skip — one bad attribute
/// should cost one field, not a whole source.
extension KeyedDecodingContainer {
    /// An integer sent as a JSON number *or* a JSON string (`412` or `"412"`).
    ///
    /// Floats are accepted and truncated only when they are integral, so a genuine `4.5` becomes
    /// `nil` rather than a silently wrong `4`.
    func lenientInt(_ key: Key) -> Int? {
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i }
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if let i = Int(trimmed) { return i }
            if let d = Double(trimmed), d == d.rounded(), d.magnitude < 9e15 { return Int(d) }
            return nil
        }
        if let d = try? decodeIfPresent(Double.self, forKey: key),
           d == d.rounded(), d.magnitude < 9e15 { return Int(d) }
        return nil
    }

    /// A string sent as a JSON string *or* a JSON scalar (`"1"`, `1`, `true`).
    ///
    /// Productive's `status` is documented as `1`/`2` (open/closed) but modelled here as a string;
    /// this accepts both so the field survives whichever the API sends. An integral number is
    /// rendered without a decimal point, so `1` becomes `"1"` and never `"1.0"`.
    func lenientString(_ key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) {
            return d == d.rounded() && d.magnitude < 9e15 ? String(Int(d)) : String(d)
        }
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return String(b) }
        return nil
    }

    /// A timestamp-or-null field that is consumed as a **presence flag**.
    ///
    /// Deliberately NOT `lenientString`. `closed_at` / `archived_at` are read as
    /// `attributes.closedAt != nil`, so any non-nil value means "closed". `lenientString` coerces
    /// JSON `false` into `"false"` and `0` into `"0"` — both non-nil — which would mark **every
    /// task closed and every company archived** the moment Productive returned `false` instead of
    /// `null`. Verified: a JSON `false` through the lenient path yields `Optional("false")`.
    ///
    /// Leniency is right for a value that is genuinely a number-or-string. It is actively wrong for
    /// a value whose *presence* is the signal. Accepts a real string or nothing, and still never
    /// throws. An empty string is treated as absent — a blank timestamp is not a date.
    func lenientTimestamp(_ key: Key) -> String? {
        guard let s = (try? decodeIfPresent(String.self, forKey: key)) ?? nil else { return nil }
        return s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s
    }

    /// A required string. Throws when absent or unusable so the element-level skip drops that one
    /// row — used for fields a record is meaningless without.
    func lenientRequiredString(_ key: Key) throws -> String {
        guard let s = (try? decodeIfPresent(String.self, forKey: key)) ?? nil,
              !s.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self,
                debugDescription: "expected a non-empty string for \(key.stringValue)")
        }
        return s
    }

    /// A required integer that the vendor may send either way. Throws only when the value is
    /// genuinely absent or unusable — callers treat that as "skip this row", not "abort the sync".
    func lenientRequiredInt(_ key: Key) throws -> Int {
        guard let value = lenientInt(key) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self,
                debugDescription: "expected a number or numeric string for \(key.stringValue)")
        }
        return value
    }
}
