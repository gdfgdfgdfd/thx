import Foundation

/// One row of the on-screen transcript: a single block, or a run of consecutive tool blocks shown as one list.
public struct TranscriptGroup: Identifiable, Equatable, Sendable {
    public var items: [TranscriptItem]

    public init(items: [TranscriptItem]) {
        self.items = items
    }

    /// The first block's ID, so a list keeps its identity while tool calls are added to it.
    public var id: UUID { items[0].id }
    public var isActivity: Bool { items[0].kind == .tool }
}

public enum Transcript {
    /// Collapses consecutive tool blocks into one group so a long run stays short on screen.
    public static func groups(_ items: [TranscriptItem]) -> [TranscriptGroup] {
        var groups: [TranscriptGroup] = []
        for item in items {
            if item.kind == .tool, let last = groups.indices.last, groups[last].isActivity {
                groups[last].items.append(item)
            } else {
                groups.append(TranscriptGroup(items: [item]))
            }
        }
        return groups
    }

    /// The one-line result shown while a tool block is collapsed: the last line of output, plus the
    /// line before a trailing `[exit N]` marker, since that is where the error message is.
    public static func preview(_ output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return nil }
        if lines.count > 1, last.hasPrefix("[exit "), last.hasSuffix("]") {
            return "\(lines[lines.count - 2])  \(last)"
        }
        return last
    }

    /// Long output is shown from the end, where the result usually is.
    public static func tail(_ output: String, lines limit: Int = 40) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > limit else { return output }
        return "… \(lines.count - limit) earlier lines\n" + lines.suffix(limit).joined(separator: "\n")
    }

    public static func lineCount(_ output: String) -> Int {
        output.split(whereSeparator: \.isNewline).count
    }
}
