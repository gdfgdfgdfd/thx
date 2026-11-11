import Foundation

public enum Markdown {
    public struct Segment: Equatable, Sendable {
        public var isCode: Bool
        public var text: String
        /// Code only: the fence's info string, e.g. `sh`.
        public var language: String?

        public init(isCode: Bool, text: String, language: String? = nil) {
            self.isCode = isCode
            self.text = text
            self.language = language
        }
    }

    /// Splits text into prose and fenced code blocks. An unclosed fence (mid-stream) is treated as code.
    public static func segments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var current: [Substring] = []
        var inCode = false
        var language: String?

        func flush() {
            let joined = current.joined(separator: "\n")
            current = []
            let body = inCode ? joined : joined.trimmingCharacters(in: .newlines)
            if !body.isEmpty { segments.append(Segment(isCode: inCode, text: body, language: inCode ? language : nil)) }
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                inCode.toggle()
                let info = trimmed.drop { $0 == "`" }.trimmingCharacters(in: .whitespaces)
                language = inCode && !info.isEmpty ? info : nil
            } else {
                current.append(line)
            }
        }
        flush()
        return segments
    }

    /// One line of prose with its block-level Markdown marker removed.
    public struct Line: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case text, heading, bullet, numbered, quote, rule
        }

        public var kind: Kind
        public var text: String
        /// What to show in front of the text: `•` for a bullet, `2.` for a numbered item, otherwise empty.
        public var marker: String
        /// Nesting depth of a list item.
        public var indent: Int

        public init(kind: Kind, text: String, marker: String = "", indent: Int = 0) {
            self.kind = kind
            self.text = text
            self.marker = marker
            self.indent = indent
        }
    }

    /// Classifies each line of a prose segment as a heading, list item, quote, rule or plain text.
    public static func lines(_ prose: String) -> [Line] {
        prose.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let leading = raw.prefix { $0 == " " || $0 == "\t" }
            let indent = min(leading.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2, 3)
            let body = raw.dropFirst(leading.count)

            if body.count >= 3, let first = body.first, "-*_".contains(first), body.allSatisfy({ $0 == first }) {
                return Line(kind: .rule, text: "")
            }
            let hashes = body.prefix { $0 == "#" }
            if (1...6).contains(hashes.count), body.dropFirst(hashes.count).first == " " {
                return Line(kind: .heading, text: body.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces))
            }
            if let first = body.first, "-*+•".contains(first), body.dropFirst().first == " " {
                return Line(kind: .bullet, text: body.dropFirst(2).trimmingCharacters(in: .whitespaces), marker: "•", indent: indent)
            }
            let digits = body.prefix { $0.isASCII && $0.isNumber }
            let afterDigits = body.dropFirst(digits.count)
            if (1...3).contains(digits.count), let separator = afterDigits.first, separator == "." || separator == ")",
               afterDigits.dropFirst().first == " " {
                return Line(kind: .numbered, text: afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces),
                            marker: "\(digits).", indent: indent)
            }
            if body.first == ">" {
                return Line(kind: .quote, text: body.dropFirst().trimmingCharacters(in: .whitespaces))
            }
            return Line(kind: .text, text: String(raw))
        }
    }

    /// Prose as blocks to lay out one under another: consecutive plain lines form a paragraph and
    /// consecutive quote lines one quote; every heading, list item and rule stands alone. Blank lines only separate.
    public static func blocks(_ prose: String) -> [Line] {
        var blocks: [Line] = []
        var paragraph: [String] = []

        func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(Line(kind: .text, text: paragraph.joined(separator: "\n")))
            paragraph = []
        }

        for line in lines(prose) {
            switch line.kind {
            case .text:
                if line.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    flush()
                } else {
                    paragraph.append(line.text)
                }
            case .quote:
                flush()
                if let last = blocks.indices.last, blocks[last].kind == .quote {
                    blocks[last].text += "\n" + line.text
                } else {
                    blocks.append(line)
                }
            case .heading, .bullet, .numbered, .rule:
                flush()
                blocks.append(line)
            }
        }
        flush()
        return blocks
    }

    public static func export(_ session: Session) -> String {
        var lines = ["# \(session.title)", ""]
        for item in session.transcript {
            switch item.kind {
            case .user: lines.append("**❯ \(item.text)**")
            case .assistant: lines.append(item.text)
            case .tool: lines.append("```\n\(item.title ?? "tool")\n\(item.text)\n```")
            case .info, .error: continue
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
