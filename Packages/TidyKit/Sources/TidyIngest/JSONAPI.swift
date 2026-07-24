import Foundation

/// Minimal JSON:API decoding for the resources TidyTime reads from Productive. Not a general
/// implementation — just documents whose `data` is an array of resources with typed attributes and
/// single/array relationships. We do NOT use `.convertFromSnakeCase` (it would also mangle the
/// relationships dictionary keys); attribute structs use explicit CodingKeys.
public struct JSONAPIDocument<A: Decodable & Sendable>: Decodable, Sendable {
    public let data: [JSONAPIResource<A>]
    public let links: Links?

    public struct Links: Decodable, Sendable {
        public let next: String?
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
