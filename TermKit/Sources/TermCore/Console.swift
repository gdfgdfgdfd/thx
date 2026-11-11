import Foundation

/// One block of the terminal screen: a typed command, the output it produced, or a note from the app.
public struct ConsoleEntry: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable {
        case note, command, output, error
    }

    public var id: UUID
    public var kind: Kind
    public var text: String

    public init(id: UUID = UUID(), kind: Kind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

/// The scrollback of the terminal screen. It is separate from the chat and is never sent to the model.
public struct ConsoleLog: Equatable, Sendable {
    public private(set) var entries: [ConsoleEntry] = []

    static let entryLimit = 400
    static let outputLimit = 24_000

    public init() {}

    public mutating func note(_ text: String) { append(.note, text) }
    public mutating func command(_ text: String) { append(.command, text) }
    public mutating func error(_ text: String) { append(.error, text) }

    /// Adds streamed output to the block of the command that is running.
    public mutating func output(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        if let last = entries.indices.last, entries[last].kind == .output {
            entries[last].text += chunk
            // Keep the tail of a long-running command; that is where the result is.
            if entries[last].text.count > Self.outputLimit {
                entries[last].text = String(entries[last].text.suffix(Self.outputLimit * 2 / 3))
            }
        } else {
            append(.output, chunk)
        }
    }

    public mutating func clear() {
        entries = []
    }

    private mutating func append(_ kind: ConsoleEntry.Kind, _ text: String) {
        entries.append(ConsoleEntry(kind: kind, text: text))
        if entries.count > Self.entryLimit { entries.removeFirst(entries.count - Self.entryLimit) }
    }
}

public enum RelativeTime {
    /// A short "how long ago" label for a list: `now`, `5 min. ago`, `3 hr. ago`, `yesterday`, `4 days ago`.
    public static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 1 { return "now" }
        if seconds < 60 { return "\(seconds) sec. ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min. ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) hr. ago" }
        let days = hours / 24
        if days == 1 { return "yesterday" }
        if days < 7 { return "\(days) days ago" }
        if days < 30 { return "\(days / 7) wk. ago" }
        if days < 365 { return "\(days / 30) mo. ago" }
        return "\(days / 365) yr. ago"
    }
}
