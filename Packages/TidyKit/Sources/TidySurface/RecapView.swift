// Recap surface (SwiftUI). Compile-checked but not unit-tested — it renders the tested `RecapDay`
// read model. The app hosts this in a window at the configured recap time. See
// docs/architecture/surface-layer.md.
#if canImport(SwiftUI)
import SwiftUI
import TidyStore
import TidySuggest

/// End-of-day recap: the day's timeline on the left, the suggestion stack + open questions on the
/// right. Actions are delivered via the injected closure (the app wires it to `DecisionRecorder`).
@available(macOS 14.0, *)
public struct RecapView: View {
    public let recap: RecapDay
    public let onAction: (Suggestion, String) -> Void
    public let onCopy: (String) -> Void

    public init(recap: RecapDay,
                onAction: @escaping (Suggestion, String) -> Void = { _, _ in },
                onCopy: @escaping (String) -> Void = { _ in }) {
        self.recap = recap
        self.onAction = onAction
        self.onCopy = onCopy
    }

    public var body: some View {
        HSplitView {
            timeline
                .frame(minWidth: 260)
            stack
                .frame(minWidth: 380)
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private var header: some View {
        let observedMin = recap.observedSeconds / 60
        let attributedPct = Int((recap.attributionRate * 100).rounded())
        let cs = recap.contextSwitches
        return VStack(alignment: .leading, spacing: 2) {
            Text("Recap — \(recap.day)").font(.title2).bold()
            // "N min already logged" alone read as a progress bar for this window's buttons. It is
            // not: it comes from the Productive mirror, and v1 never writes to Productive, so it
            // could not move when the user marked a card. Say which number lives where.
            Text("\(observedMin) min observed · \(attributedPct)% attributed")
                .font(.caption).foregroundStyle(.secondary)
            Text("\(recap.loggedMinutes)m in Productive · \(recap.markedEnteredMinutes)m marked entered here")
                .font(.caption).foregroundStyle(.secondary)
            Text("\(cs.switchCount) context switches · \(String(format: "%.1f", cs.switchesPerActiveHour))/hr · \(Int(cs.fragmentation * 100))% brief · longest focus \(cs.longestFocusSeconds / 60)m")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading) {
            header.padding(.bottom, 4)
            List(recap.timeline, id: \.id) { session in
                HStack {
                    Circle().fill(session.clientId == nil ? Color.gray : Color.accentColor)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading) {
                        Text(session.title ?? session.contextKey ?? session.kind).lineLimit(1)
                        Text("\(session.durationSeconds / 60) min · \(session.kind)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }.padding()
    }

    /// Say WHICH link in the chain is missing.
    ///
    /// The pane used to render the word "Suggestions" over a blank list while the left pane
    /// cheerfully reported "N min observed · X% attributed" — which reads as broken, not as "nothing
    /// to suggest". Same principle as Doctor's ingest readiness rows: a zero is only trustworthy
    /// when it explains itself.
    @ViewBuilder private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(emptyHeadline).font(.callout)
            Text(emptyDetail).font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 6)
    }

    private var emptyHeadline: String {
        if recap.timeline.isEmpty { return "Nothing captured yet today." }
        if recap.attributedSeconds == 0 { return "Captured your day, but couldn’t match any of it to a client." }
        return "Nothing left to suggest."
    }

    private var emptyDetail: String {
        if recap.timeline.isEmpty {
            return "Suggestions appear once there are sessions to group. Check Doctor if capture looks paused."
        }
        if recap.attributedSeconds == 0 {
            return "That usually means the Productive mirror is empty or has no client vocabulary yet — "
                 + "open Doctor and check the productive row. Answering a question below also teaches it."
        }
        return "Nothing left to review — every suggestion for today has been marked entered or tossed."
    }

    private func sectionHeader(_ title: String, _ count: Int, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(title) (\(count))").font(.subheadline).bold()
            Text(hint).font(.caption2).foregroundStyle(.secondary).textCase(nil)
        }.padding(.top, 4)
    }

    private var stack: some View {
        VStack(alignment: .leading) {
            Text("Suggestions").font(.headline)
            List {
                if recap.suggestions.isEmpty { emptyState }
                // Two groups, because they are two different jobs. "Ready to log" is paste-and-save;
                // "Needs a task first" means leaving for Productive to create something before the
                // time has anywhere to go. Mixing them made every card look equally actionable.
                if !recap.readyToLog.isEmpty {
                    Section {
                        ForEach(recap.readyToLog, id: \.id) { s in
                            SuggestionCard(suggestion: s, names: recap.names,
                                           onAction: onAction, onCopy: onCopy)
                        }
                    } header: {
                        sectionHeader("Ready to log", recap.readyToLog.count,
                                      "these name a task — copy, paste, save")
                    }
                }
                if !recap.needsATask.isEmpty {
                    Section {
                        ForEach(recap.needsATask, id: \.id) { s in
                            SuggestionCard(suggestion: s, names: recap.names,
                                           onAction: onAction, onCopy: onCopy)
                        }
                    } header: {
                        sectionHeader("Needs a task first", recap.needsATask.count,
                                      "no task to log against yet — create one in Productive")
                    }
                }
                if !recap.questions.isEmpty {
                    Section("Questions") {
                        ForEach(recap.questions, id: \.id) { q in
                            Text(q.question).font(.callout)
                        }
                    }
                }
            }
        }.padding()
    }
}

@available(macOS 14.0, *)
struct SuggestionCard: View {
    let suggestion: Suggestion
    let names: [String: String]
    let onAction: (Suggestion, String) -> Void
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).bold()
                Spacer()
                Text("\(suggestion.minutes)m\(suggestion.isRoundedUp ? " ↑" : "")")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            if let note = suggestion.note {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let rationale = suggestion.rationale {
                Text(rationale).font(.caption2).foregroundStyle(.tertiary)
            }
            HStack {
                Button("Copy") { onCopy(copyPayload) }
                // Only when the pattern could actually be filled — `ProductiveDeepLink` returns nil
                // rather than emitting `//tasks/task/123`, and a link that promises a task and
                // delivers a 404 costs a context switch to discover.
                if let link = suggestion.deepLink, let url = URL(string: link) {
                    Link("Open in Productive", destination: url)
                }
                // Renamed from "Log it ✓". v1 never writes to Productive (G1) — this records that
                // YOU entered it, clears the card, and teaches the classifier. Calling that "Log it"
                // promised the one thing it does not do, and the user who reported the button as
                // broken was reading the label correctly.
                Button("Mark entered ✓") { onAction(suggestion, "log") }
                Button("Toss") { onAction(suggestion, "toss") }
            }.buttonStyle(.borderless).font(.caption)
        }.padding(.vertical, 4)
    }

    /// Names, not ids. The best cards — attributed all the way to a task — were headed by a bare
    /// number like `18609405`, which tells the user nothing about what they worked on.
    private var title: String {
        if suggestion.kind == "new_task", let t = suggestion.proposedTaskTitle { return "Propose task: \(t)" }
        for id in [suggestion.taskId, suggestion.projectId, suggestion.clientId].compactMap({ $0 }) {
            if let name = names[id], !name.isEmpty { return name }
        }
        return suggestion.taskId ?? suggestion.projectId ?? suggestion.clientId ?? suggestion.kind
    }
    /// Everything the manual entry needs, in the order the Productive form asks for it. The old
    /// payload was `"60m — note"`, which left the user to retype the client, project and task by
    /// hand — the actual work, and the reason "copy" did not save anyone anything.
    private var copyPayload: String {
        var parts: [String] = []
        let path = [suggestion.clientId, suggestion.projectId, suggestion.taskId]
            .compactMap { $0 }
            .compactMap { names[$0] }
            .filter { !$0.isEmpty }
        if !path.isEmpty { parts.append(path.joined(separator: " › ")) }
        else if suggestion.kind == "new_task", let t = suggestion.proposedTaskTitle {
            parts.append("(new task) \(t)")
        }
        parts.append("\(suggestion.minutes)m")
        if let note = suggestion.note, !note.isEmpty { parts.append(note) }
        return parts.joined(separator: " · ")
    }
}
#endif
