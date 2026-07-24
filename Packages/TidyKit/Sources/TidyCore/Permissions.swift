import Foundation

/// Reports macOS permission/TCC status for the diagnostic bundle and the `doctor` view. The real
/// implementation (Accessibility / Automation / Notifications checks) lives in the capture/app
/// layer; tests and early phases use ``StaticPermissionProvider``.
public protocol PermissionStatusProviding: Sendable {
    func statuses() -> [String: String]
}

public struct StaticPermissionProvider: PermissionStatusProviding {
    public let values: [String: String]
    public init(_ values: [String: String] = [:]) { self.values = values }
    public func statuses() -> [String: String] { values }
}
