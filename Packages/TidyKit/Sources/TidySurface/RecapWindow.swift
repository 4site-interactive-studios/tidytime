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
                taskId: suggestion.taskId, confirmSignal: confirm,
                // The card may have been on screen across a regeneration, in which case its id is
                // dead. Re-point at the row representing the same work now.
                resolve: { [db = env.db] stale in
                    guard let stale else { return nil }
                    return (try? db.liveSuggestionId(matching: stale, day: suggestion.day,
                                                     attributionKey: suggestion.attributionKey)) ?? nil
                })
            env.logger.info("recap decision", [
                "action": action, "suggestion": "\(id)",
                "confirmed": confirm.map { "\($0.type)=\($0.value)" } ?? "none",
            ])
            load()
        } catch {
            env.logger.error("recap decision failed", ["error": "\(error)"])
        }
    }

    /// Hosts that are TOOLS, not clients.
    ///
    /// This list is load-bearing. On the machine this shipped from, the only two confirmable cards
    /// were backed by `calendar.google.com` and `youtube.com` — so a single click on "Log it ✓"
    /// would have written `url_host youtube.com -> <that client>` with `user_confirmed` provenance,
    /// which outranks bootstrapped and inferred FOREVER and has no removal path in the UI. One
    /// accepted card would have permanently mis-attributed every future YouTube session.
    ///
    /// Matched on the registrable suffix so `mail.google.com` and `docs.google.com` are covered
    /// without enumerating subdomains.
    static let toolHosts: Set<String> = [
        "google.com", "gmail.com", "youtube.com", "slack.com", "productive.io", "github.com",
        "anthropic.com", "claude.ai", "openai.com", "chatgpt.com", "notion.so", "figma.com",
        "zoom.us", "atlassian.net", "linear.app", "bugherd.com", "dropbox.com", "box.com",
        "microsoft.com", "office.com", "live.com", "apple.com", "icloud.com", "localhost",
        "reddit.com", "x.com", "twitter.com", "linkedin.com", "stackoverflow.com",
    ]

    /// Is this host a tool rather than a client's own domain?
    static func isToolHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if toolHosts.contains(h) { return true }
        return toolHosts.contains { h.hasSuffix("." + $0) }
    }

    /// The signal an accepted suggestion should promote, derived from the sessions behind it.
    ///
    /// Returns nil when the sessions carry nothing durable: an `app:` key names a tool, and a
    /// tool HOST is the same problem one layer down. A `user_confirmed` rule is permanent and
    /// outranks everything, so the bar for writing one is "this host identifies a client", not
    /// "the user accepted a card that happened to involve this host".
    public static func signalToConfirm(db: AppDatabase, suggestion: Suggestion) -> DecisionRecorder.SignalRef? {
        struct Refs: Decodable { let sessions: [Int64]? }
        guard let data = suggestion.sourceRefsJson.data(using: .utf8),
              let ids = (try? JSONDecoder().decode(Refs.self, from: data))?.sessions, !ids.isEmpty,
              let keys = try? db.sessionContextKeys(ids: ids) else { return nil }
        for key in keys {
            if key.hasPrefix("web:") {
                let host = String(key.dropFirst(4))
                if isToolHost(host) { continue }
                return .init(type: "url_host", value: host)
            }
            // A Slack conversation IS client-specific in a way a shared tool host is not — a channel
            // belongs to one piece of work even though slack.com does not.
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
