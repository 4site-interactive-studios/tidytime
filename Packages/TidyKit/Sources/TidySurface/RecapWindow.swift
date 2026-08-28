import SwiftUI
import TidyCore
import TidyStore
import TidySuggest
import TidyUnderstand

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
    /// Route through `DecisionRecorder` rather than writing the two rows by hand.
    ///
    /// This view previously called `updateSuggestionStatus` + `insertDecision` directly, which
    /// produced the same two rows and **skipped the learning loop** — `DecisionRecorder` is the only
    /// thing that writes a `user_confirmed` signal, and `user_confirmed` outranks `bootstrapped` and
    /// `inferred` forever. `RecapView`'s own doc comment claimed the app wired it; it did not, so
    /// accepting a suggestion taught the system nothing and accuracy could never improve with use.
    private func handle(_ suggestion: Suggestion, _ action: String) {
        guard let id = suggestion.id else { return }
        do {
            // Accepting is the user saying "these sessions really were this client". The durable
            // thing to remember is the context key — a host or Slack conversation that recurs
            // tomorrow — not this one suggestion. Only on accept: tossing says the attribution was
            // wrong, so confirming it would teach the opposite of what the user meant.
            var confirm: DecisionRecorder.SignalRef?
            if action == "log", suggestion.clientId != nil {
                confirm = Self.signalToConfirm(db: env.db, suggestion: suggestion)
            }
            try DecisionRecorder(db: env.db).record(
                suggestionId: id, action: action,
                clientId: suggestion.clientId, projectId: suggestion.projectId,
                taskId: suggestion.taskId, confirmSignal: confirm)
            env.logger.info("recap decision", [
                "action": action, "suggestion": "\(id)",
                "confirmed": confirm.map { "\($0.type)=\($0.value)" } ?? "none",
            ])
            load()
        } catch {
            env.logger.error("recap decision failed", ["error": "\(error)"])
        }
    }

    /// The signal an accepted suggestion should promote, derived from the sessions behind it.
    /// Returns nil when the sessions carry nothing durable (an `app:` key names a tool, not a
    /// client, so confirming it would attribute every future use of that app to this client).
    public static func signalToConfirm(db: AppDatabase, suggestion: Suggestion) -> DecisionRecorder.SignalRef? {
        struct Refs: Decodable { let sessions: [Int64]? }
        guard let data = suggestion.sourceRefsJson.data(using: .utf8),
              let ids = (try? JSONDecoder().decode(Refs.self, from: data))?.sessions, !ids.isEmpty,
              let keys = try? db.sessionContextKeys(ids: ids) else { return nil }
        for key in keys {
            if key.hasPrefix("web:") { return .init(type: "url_host", value: String(key.dropFirst(4))) }
            if key.hasPrefix("slack:") { return .init(type: "slack_channel", value: String(key.dropFirst(6))) }
        }
        return nil
    }

    private func copy(_ text: String) {
        SystemClipboard().copy(text)
        toast = "Copied."
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); toast = nil }
    }
}
