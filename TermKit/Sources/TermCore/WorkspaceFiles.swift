import Foundation

/// A file or folder in the on-device workspace.
public struct WorkspaceEntry: Identifiable, Hashable, Sendable {
    /// Path relative to the workspace root, e.g. `notes/todo.md`.
    public var path: String
    public var isDirectory: Bool
    public var size: Int
    public var modified: Date?

    public init(path: String, isDirectory: Bool, size: Int = 0, modified: Date? = nil) {
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }

    public var id: String { path }
    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    /// The folder the entry sits in; empty at the top level.
    public var folder: String { path.split(separator: "/").dropLast().joined(separator: "/") }
    /// How many folders deep the entry sits; 0 at the top level.
    public var depth: Int { max(path.split(separator: "/").count - 1, 0) }
}

public struct WorkspaceError: LocalizedError, Equatable {
    public var message: String
    public var errorDescription: String? { message }

    public init(message: String) {
        self.message = message
    }
}

/// Browses the workspace folder the agent's file tools work in. Every path is confined to that folder.
public struct WorkspaceFiles: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Resolves a workspace-relative path, refusing anything that escapes the workspace.
    public func resolve(_ path: String) throws -> URL {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        var relative = path.trimmingCharacters(in: .whitespaces)
        while relative.hasPrefix("/") { relative.removeFirst() }
        let target = relative.isEmpty || relative == "." ? base
            : base.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        guard target.path == base.path || target.path.hasPrefix(base.path + "/") else {
            throw WorkspaceError(message: "path is outside the workspace: \(path)")
        }
        return target
    }

    /// The contents of one folder: folders first, then files, each in name order. Hidden files are left out.
    public func list(_ folder: String = "") throws -> [WorkspaceEntry] {
        let url = try resolve(folder)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let prefix = folder.split(separator: "/").joined(separator: "/")
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            .map { item -> WorkspaceEntry in
                let values = try? item.resourceValues(forKeys: Set(keys))
                return WorkspaceEntry(
                    path: prefix.isEmpty ? item.lastPathComponent : prefix + "/" + item.lastPathComponent,
                    isDirectory: values?.isDirectory ?? false,
                    size: values?.fileSize ?? 0,
                    modified: values?.contentModificationDate)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// Files anywhere in the workspace whose path contains `query`, in path order.
    public func search(_ query: String, limit: Int = 200) -> [WorkspaceEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        var found: [WorkspaceEntry] = []
        var folders = [""]
        while let folder = folders.popLast(), found.count < limit {
            for entry in (try? list(folder)) ?? [] {
                if entry.isDirectory {
                    folders.append(entry.path)
                } else if entry.path.range(of: needle, options: .caseInsensitive) != nil {
                    found.append(entry)
                }
            }
        }
        return Array(found.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }.prefix(limit))
    }

    public func delete(_ path: String) throws {
        let url = try resolve(path)
        guard url.path != root.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw WorkspaceError(message: "the workspace folder itself cannot be deleted")
        }
        try FileManager.default.removeItem(at: url)
    }

    /// The start of a file as text, or `nil` when it is not UTF-8 text.
    public func preview(_ path: String, limit: Int = 200_000) throws -> String? {
        let handle = try FileHandle(forReadingFrom: try resolve(path))
        defer { try? handle.close() }
        var data = handle.readData(ofLength: limit)
        if data.contains(0) { return nil }
        // A read that stops mid-character must not make the whole file look binary.
        for _ in 0..<4 {
            if let text = String(data: data, encoding: .utf8) { return text }
            if data.isEmpty { break }
            data.removeLast()
        }
        return nil
    }
}
