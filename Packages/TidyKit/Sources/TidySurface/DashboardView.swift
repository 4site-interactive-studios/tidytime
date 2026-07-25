import SwiftUI
import TidyCore
import TidyStore
import TidyAI

/// Weekly metrics + the AI-overhead panel. **Metrics, no targets** (PLAN §2) — these describe the
/// week, they don't grade it.
public struct DashboardView: View {
    @ObservedObject var env: AppEnvironment
    @State private var rollups: [DailyRollup] = []
    @State private var ai: AIDashboard?
    @State private var exported: String?

    public init(env: AppEnvironment) { self.env = env }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("This week").font(.title2).bold()

                HStack(spacing: 12) {
                    tile("Observed", Format.hoursMinutes(rollups.reduce(0) { $0 + $1.observedSeconds }))
                    tile("Logged", Format.minutes(rollups.reduce(0) { $0 + $1.loggedMinutes }))
                    tile("Billable", Format.minutes(rollups.reduce(0) { $0 + $1.billableMinutes }))
                    tile("Capture health", Format.percent(avgHealth))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Context switching").font(.headline)
                    HStack(spacing: 12) {
                        tile("Switches", "\(rollups.reduce(0) { $0 + $1.contextSwitches })")
                        tile("Brief (<2m)", "\(rollups.reduce(0) { $0 + $1.briefSwitches })")
                        tile("Longest focus", Format.hoursMinutes(rollups.map(\.longestFocusSeconds).max() ?? 0))
                    }
                    Text("Counted from raw samples, so sub-minute thrash still registers; unattended time is clipped out.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let ai {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("AI overhead").font(.headline)
                        HStack(spacing: 12) {
                            tile("Spend", Format.usd(ai.totalCostUsd))
                            tile("Calls", "\(ai.callCount)")
                            tile("Escalation rate", Format.percent(ai.escalationRate))
                            tile("On-device", Format.percent(ai.onDeviceShare))
                        }
                        if ai.refusedBudget > 0 || ai.refusedSensitive > 0 {
                            Text("Refused: \(ai.refusedBudget) over budget · \(ai.refusedSensitive) sensitive (never sent).")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Button("Export ledger CSV") { exportCSV() }
                            .font(.caption)
                        if let exported {
                            Text("Saved to \(exported)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Per day").font(.headline)
                    ForEach(rollups, id: \.day) { r in
                        HStack {
                            Text(r.day).font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Text(Format.hoursMinutes(r.observedSeconds)).font(.system(size: 12))
                            Text("·").foregroundStyle(.secondary)
                            Text(Format.minutes(r.loggedMinutes)).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 620, minHeight: 560)
        .onAppear(perform: reload)
    }

    private var avgHealth: Double {
        let vals = rollups.compactMap(\.captureHealth)
        return vals.isEmpty ? 0 : vals.reduce(0, +) / Double(vals.count)
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .semibold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func reload() {
        let now = Date()
        let (_, todayEnd) = AppEnvironment.dayBounds(for: now, timeZone: env.timeZone)
        let weekStart = todayEnd - 7 * 86_400
        rollups = (try? env.db.rollups(from: AppEnvironment.dayString(Date(timeIntervalSince1970: TimeInterval(weekStart)), env.timeZone),
                                       to: AppEnvironment.dayString(now, env.timeZone))) ?? []
        ai = try? DashboardBuilder(db: env.db).build(from: weekStart, to: todayEnd)
    }

    private func exportCSV() {
        let now = Date()
        let (_, end) = AppEnvironment.dayBounds(for: now, timeZone: env.timeZone)
        guard let csv = try? DashboardBuilder(db: env.db).csv(from: end - 31 * 86_400, to: end) else { return }
        let url = env.paths.supportDirectory.appendingPathComponent("ai-usage.csv")
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        exported = url.path
    }
}
