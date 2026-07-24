// TidySuggest — the suggestion engine: 15-minute rounding with round-up bias, micro-work pools,
// meeting splitting, gap analysis vs already-logged entries, and new-task proposals. Emits
// `suggestions`. See docs/architecture/suggestion-engine.md.
import Foundation

/// Rounds real seconds to the billing increment with a slight round-up bias, keeping a minimum of
/// one increment for any kept item (so 6 real minutes still becomes 15, flagged as rounded up).
public struct RoundingPolicy: Sendable {
    public let incrementMinutes: Int
    public let roundUpBias: Double
    public init(incrementMinutes: Int = 15, roundUpBias: Double = 0.4) {
        self.incrementMinutes = incrementMinutes
        self.roundUpBias = roundUpBias
    }

    public func rounded(seconds: Int) -> (minutes: Int, roundedUp: Bool) {
        guard seconds > 0 else { return (0, false) }
        let rawMinutes = Double(seconds) / 60.0
        let units = rawMinutes / Double(incrementMinutes)
        // floor(units + bias) rounds up once the fractional part exceeds (1 - bias).
        var roundedUnits = Int(floor(units + roundUpBias))
        if roundedUnits < 1 { roundedUnits = 1 }         // keep at least one increment
        let minutes = roundedUnits * incrementMinutes
        let roundedUp = Double(minutes) > rawMinutes + 1e-9
        return (minutes, roundedUp)
    }
}
