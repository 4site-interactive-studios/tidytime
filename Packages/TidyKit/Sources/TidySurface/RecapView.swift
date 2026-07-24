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
        return VStack(alignment: .leading, spacing: 2) {
            Text("Recap — \(recap.day)").font(.title2).bold()
            Text("\(observedMin) min observed · \(attributedPct)% attributed · \(recap.loggedMinutes) min already logged")
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

    private var stack: some View {
        VStack(alignment: .leading) {
            Text("Suggestions").font(.headline)
            List {
                ForEach(recap.suggestions, id: \.id) { s in
                    SuggestionCard(suggestion: s, onAction: onAction, onCopy: onCopy)
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
                Button("Log it ✓") { onAction(suggestion, "log") }
                Button("Toss") { onAction(suggestion, "toss") }
            }.buttonStyle(.borderless).font(.caption)
        }.padding(.vertical, 4)
    }

    private var title: String {
        if suggestion.kind == "new_task", let t = suggestion.proposedTaskTitle { return "Propose task: \(t)" }
        return suggestion.taskId ?? suggestion.projectId ?? suggestion.clientId ?? suggestion.kind
    }
    private var copyPayload: String {
        "\(suggestion.minutes)m — \(suggestion.note ?? "")"
    }
}
#endif
