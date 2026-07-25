import Foundation
import TidyCore
import TidyStore

#if canImport(UserNotifications)
import UserNotifications
#endif

/// Delivers nudges as user notifications. The *decision* to nudge lives in `TidyAI.NudgeEngine`
/// (rate limits, quiet hours, meeting suppression, dismissal learning) — this type only presents,
/// and records the outcome so the engine can learn.
public protocol NudgeDelivering: Sendable {
    func deliver(title: String, body: String, identifier: String)
}

public struct SystemNudgeDelivery: NudgeDelivering {
    public init() {}
    public func deliver(title: String, body: String, identifier: String) {
        #if canImport(UserNotifications)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil                     // never startle; a nudge is optional by design
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        #endif
    }
}

/// Test double.
public final class RecordingNudgeDelivery: NudgeDelivering, @unchecked Sendable {
    private let lock = NSLock()
    private var _delivered: [(String, String, String)] = []
    public init() {}
    public func deliver(title: String, body: String, identifier: String) {
        lock.lock(); _delivered.append((title, body, identifier)); lock.unlock()
    }
    public var delivered: [(String, String, String)] {
        lock.lock(); defer { lock.unlock() }; return _delivered
    }
}

/// Formats a nudge from a classified session and logs it to the `nudges` table.
public struct NudgePresenter: Sendable {
    private let db: AppDatabase
    private let delivery: NudgeDelivering
    private let clock: TidyClock

    public init(db: AppDatabase, delivery: NudgeDelivering = SystemNudgeDelivery(),
                clock: TidyClock = SystemClock()) {
        self.db = db; self.delivery = delivery; self.clock = clock
    }

    /// Present a nudge for a sustained, confidently-classified block and record it.
    @discardableResult
    public func present(session: Session, clientName: String, minutes: Int) throws -> Int64? {
        guard let contextKey = session.contextKey ?? session.sourceRef else { return nil }
        let now = Int64(clock.now.timeIntervalSince1970)
        let id = try db.insertNudge(NudgeRecord(firedAt: now, contextKey: contextKey,
                                          clientId: session.clientId, sessionId: session.id))
        delivery.deliver(
            title: "\(minutes) min on \(clientName)",
            body: "Nothing logged there yet. Open the recap to review — or ignore this; it'll wait.",
            identifier: "tidytime.nudge.\(id)")
        return id
    }
}
