import Foundation

/// A file the user attached to a prompt. It is copied into the workspace so the agent's file tools can reach it.
public struct Attachment: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Path relative to the workspace root, as the `read_file` tool expects it.
    public var path: String
    public var size: Int
    /// The contents, when the file is UTF-8 text small enough to send along with the prompt.
    public var text: String?

    public init(id: UUID = UUID(), name: String, path: String, size: Int, text: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.text = text
    }
}

public enum Attachments {
    public static let folder = "uploads"
    /// Larger text files stay in the workspace and are read by the agent on demand.
    public static let inlineLimit = 48_000

    /// Copies a picked file into the workspace's uploads folder, renaming it if the name is taken.
    public static func importFile(at source: URL, into workspace: URL) throws -> Attachment {
        let files = FileManager.default
        let directory = workspace.appendingPathComponent(folder, isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)

        let stem = source.deletingPathExtension().lastPathComponent
        let suffix = source.pathExtension.isEmpty ? "" : "." + source.pathExtension
        var name = source.lastPathComponent
        var copy = 1
        while files.fileExists(atPath: directory.appendingPathComponent(name).path) {
            copy += 1
            name = "\(stem)-\(copy)\(suffix)"
        }
        try files.copyItem(at: source, to: directory.appendingPathComponent(name))
        return try load("\(folder)/\(name)", in: workspace)
    }

    /// Reads a file already in the workspace, e.g. to resend a prompt with its attachments.
    public static func load(_ path: String, in workspace: URL) throws -> Attachment {
        let url = workspace.appendingPathComponent(path)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        var text: String?
        if size <= inlineLimit, let decoded = String(data: try Data(contentsOf: url), encoding: .utf8), !decoded.contains("\0") {
            text = decoded
        }
        return Attachment(name: url.lastPathComponent, path: path, size: size, text: text)
    }

    /// What the model receives: the prompt, then each attachment's contents or where to find it.
    public static func prompt(_ text: String, attachments: [Attachment]) -> String {
        var parts = text.isEmpty ? [] : [text]
        for attachment in attachments {
            if let body = attachment.text {
                let fence = String(repeating: "`", count: max(3, longestBacktickRun(body) + 1))
                parts.append("[attached file: \(attachment.path)]\n\(fence)\n\(body)\n\(fence)")
            } else {
                parts.append("[attached file: \(attachment.path), \(attachment.size) bytes. Not shown here because it is binary or large; it is saved in the workspace at that path.]")
            }
        }
        return parts.joined(separator: "\n\n")
    }

    private static func longestBacktickRun(_ text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            current = character == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }
}
