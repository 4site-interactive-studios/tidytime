import SwiftUI
import TidyCore
import TidyStore
import TidySuggest

/// Live wrapper around the pure `RecapView`: loads the day from the store, wires suggestion actions
/// to `decisions` (the learning-loop signal), and handles copy-to-clipboard.
///
/// **"Log it ✓" marks the suggestion handled locally only** — it never writes to Productive
/// (guardrail G1). The user still enters the time; this just stops it being suggested again.
@available(macOS 14.0, *)
public struct RecapWindow: View {
    @ObservedObject var env: AppEnvironment
    @State private var day: Date = Date()
    @State private var recap: RecapDay?
    @State private var toast: String?

    public init(env: AppEnvironment) { self.env = env }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let recap {
                RecapView(recap: recap, onAction: handle, onCopy: copy)
            } else {
                VStack {
                    Spacer()
                    Text("Nothing captured for this day yet.").foregroundStyle(.secondary)
                    Spacer()
                }
            }
            if let toast {
                Text(toast).font(.caption).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear(perform: load)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
            Text(AppEnvironment.dayString(day, env.timeZone))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .disabled(Calendar.current.isDateInToday(day))
            Spacer()
            Button("Re-run pipeline") { env.runPipelineOnce(); load() }
                .help("Rebuild sessions and re-classify this day from the captured samples.")
        }
        .padding(10)
    }

    private func shift(_ days: Int) {
        day = Calendar.current.date(byAdding: .day, value: days, to: day) ?? day
        load()
    }

    private func load() {
        let (from, to) = AppEnvironment.dayBounds(for: day, timeZone: env.timeZone)
        let assembler = RecapAssembler(db: env.db, config: env.config,
                                       selfPersonId: (try? env.db.selfPerson())?.id)
        recap = try? assembler.assemble(day: AppEnvironment.dayString(day, env.timeZone), from: from, to: to)
    }

    /// Records the user's decision, then updates the suggestion's status.
    private func handle(_ suggestion: Suggestion, _ action: String) {
        guard let id = suggestion.id else { return }
        let now = Int64(Date().timeIntervalSince1970)
        let status: String
        switch action {
        case "log": status = "logged"
        case "toss": status = "tossed"
        case "snooze": status = "snoozed"
        default: status = suggestion.status
        }
        do {
            try env.db.updateSuggestionStatus(id: id, status: status, now: now)
            try env.db.insertDecision(Decision(suggestionId: id, action: action,
                                               clientId: suggestion.clientId,
                                               projectId: suggestion.projectId,
                                               taskId: suggestion.taskId, createdAt: now))
            env.logger.info("recap decision", ["action": action, "suggestion": "\(id)"])
            load()
        } catch {
            env.logger.error("recap decision failed", ["error": "\(error)"])
        }
    }

    private func copy(_ text: String) {
        SystemClipboard().copy(text)
        toast = "Copied."
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); toast = nil }
    }
}
