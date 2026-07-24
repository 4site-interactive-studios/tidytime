import Foundation
import TidyCore

/// Decides whether a live nudge should fire. Pure decision logic (the app supplies the inputs and,
/// on a fire, writes a `nudges` row and posts the notification). Meeting-aware, quiet-hours-aware,
/// daily-capped, and it backs off from contexts the user keeps dismissing.
public struct NudgeEngine: Sendable {
    public let enabled: Bool
    public let sustainedBlockSeconds: Int
    public let confidenceThreshold: Double
    public let dailyCap: Int
    public let quietStartMinute: Int?
    public let quietEndMinute: Int?
    public let maxDismissalsBeforeMute: Int

    public init(enabled: Bool = true, sustainedBlockSeconds: Int = 25 * 60, confidenceThreshold: Double = 0.7,
                dailyCap: Int = 5, quietStartMinute: Int? = nil, quietEndMinute: Int? = nil,
                maxDismissalsBeforeMute: Int = 3) {
        self.enabled = enabled; self.sustainedBlockSeconds = sustainedBlockSeconds
        self.confidenceThreshold = confidenceThreshold; self.dailyCap = dailyCap
        self.quietStartMinute = quietStartMinute; self.quietEndMinute = quietEndMinute
        self.maxDismissalsBeforeMute = maxDismissalsBeforeMute
    }

    public init(config: Config) {
        self.init(enabled: config.nudges.enabled,
                  sustainedBlockSeconds: config.nudges.sustainedBlockMinutes * 60,
                  confidenceThreshold: config.nudges.confidenceThreshold,
                  dailyCap: config.nudges.dailyCap,
                  quietStartMinute: NudgeEngine.minuteOfDay(config.nudges.quietHours.start),
                  quietEndMinute: NudgeEngine.minuteOfDay(config.nudges.quietHours.end))
    }

    public struct Input: Sendable {
        public var confidence: Double
        public var sustainedSeconds: Int
        public var isInMeeting: Bool
        public var alreadyLoggedForContext: Bool
        public var nudgesFiredToday: Int
        public var dismissalsForContext: Int
        public var minuteOfDay: Int
        public init(confidence: Double, sustainedSeconds: Int, isInMeeting: Bool,
                    alreadyLoggedForContext: Bool, nudgesFiredToday: Int, dismissalsForContext: Int, minuteOfDay: Int) {
            self.confidence = confidence; self.sustainedSeconds = sustainedSeconds; self.isInMeeting = isInMeeting
            self.alreadyLoggedForContext = alreadyLoggedForContext; self.nudgesFiredToday = nudgesFiredToday
            self.dismissalsForContext = dismissalsForContext; self.minuteOfDay = minuteOfDay
        }
    }

    public struct Decision: Sendable, Equatable {
        public let shouldFire: Bool
        public let reason: String
    }

    public func decide(_ i: Input) -> Decision {
        if !enabled { return .init(shouldFire: false, reason: "nudges disabled") }
        if i.isInMeeting { return .init(shouldFire: false, reason: "in a meeting") }
        if let s = quietStartMinute, let e = quietEndMinute, Self.inWindow(i.minuteOfDay, s, e) {
            return .init(shouldFire: false, reason: "quiet hours")
        }
        if i.nudgesFiredToday >= dailyCap { return .init(shouldFire: false, reason: "daily cap reached") }
        if i.sustainedSeconds < sustainedBlockSeconds { return .init(shouldFire: false, reason: "block not sustained") }
        if i.alreadyLoggedForContext { return .init(shouldFire: false, reason: "already logged") }
        if i.dismissalsForContext >= maxDismissalsBeforeMute {
            return .init(shouldFire: false, reason: "muted after repeated dismissals")
        }
        // Each dismissal raises the bar for this context.
        let effectiveThreshold = confidenceThreshold + 0.1 * Double(i.dismissalsForContext)
        if i.confidence < effectiveThreshold {
            return .init(shouldFire: false, reason: "below confidence threshold (\(String(format: "%.2f", effectiveThreshold)))")
        }
        return .init(shouldFire: true, reason: "sustained, confident, unlogged")
    }

    public static func minuteOfDay(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }

    /// Handles windows that wrap past midnight (e.g. 18:00 → 09:00).
    public static func inWindow(_ minute: Int, _ start: Int, _ end: Int) -> Bool {
        start <= end ? (minute >= start && minute < end) : (minute >= start || minute < end)
    }
}
