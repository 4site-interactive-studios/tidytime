import SwiftUI
import TidyCore
import TidyStore

/// "Away 47 min: break, call, or something else?" — one tap. This is where unrecorded phone calls
/// get rescued (PLAN §9). Unanswered prompts simply queue into the recap; nothing is lost.
public struct AwayPromptView: View {
    public let gap: AwayGap
    public let onResolve: (String, String?) -> Void   // (attribution, note)
    public let onDismiss: () -> Void

    public init(gap: AwayGap, onResolve: @escaping (String, String?) -> Void,
                onDismiss: @escaping () -> Void) {
        self.gap = gap; self.onResolve = onResolve; self.onDismiss = onDismiss
    }

    @State private var otherText = ""

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Away \(Format.hoursMinutes(gap.durationSeconds))")
                .font(.headline)
            Text("What was that? (\(gap.cause))")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button("Break") { onResolve("break", nil) }
                Button("Call") { onResolve("call", nil) }
            }

            HStack {
                TextField("Something else…", text: $otherText)
                Button("Save") { onResolve("other", otherText.isEmpty ? nil : otherText) }
                    .disabled(otherText.isEmpty)
            }

            Button("Ask me at recap") { onDismiss() }
                .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 340)
    }
}

/// Resolves away gaps against the store (the view stays presentation-only).
public struct AwayGapResolver: Sendable {
    private let db: AppDatabase
    private let clock: TidyClock
    public init(db: AppDatabase, clock: TidyClock = SystemClock()) { self.db = db; self.clock = clock }

    /// Oldest unresolved gap in the window, if any — what the prompt should ask about next.
    public func nextUnresolved(from: Int64, to: Int64, minimumSeconds: Int = 300) throws -> AwayGap? {
        try db.unresolvedAwayGaps(from: from, to: to).first { $0.durationSeconds >= minimumSeconds }
    }

    public func resolve(_ gap: AwayGap, attribution: String, note: String?) throws {
        guard let id = gap.id else { return }
        try db.resolveAwayGap(id: id, attribution: attribution, note: note,
                              resolvedAt: Int64(clock.now.timeIntervalSince1970))
    }
}
