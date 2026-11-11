import Foundation

/// Holds API keys, passwords and private keys. The app backs this with the Keychain.
public protocol SecretStore: AnyObject {
    func secret(for key: String) -> String?
    func setSecret(_ value: String?, for key: String)
}

public final class InMemorySecretStore: SecretStore {
    private var values: [String: String] = [:]
    public init() {}
    public func secret(for key: String) -> String? { values[key] }
    public func setSecret(_ value: String?, for key: String) { values[key] = value }
}

/// JSON files under one directory: profiles, hosts, settings and one file per session.
public final class Storage {
    public let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL) {
        self.directory = directory
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
    }

    private var sessionsDirectory: URL { directory.appendingPathComponent("sessions", isDirectory: true) }

    private func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to name: String) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    public func loadProfiles() -> [Profile] { read([Profile].self, from: "profiles.json") ?? [] }
    public func saveProfiles(_ profiles: [Profile]) { write(profiles, to: "profiles.json") }

    public func loadHosts() -> [SSHHost] { read([SSHHost].self, from: "hosts.json") ?? [] }
    public func saveHosts(_ hosts: [SSHHost]) { write(hosts, to: "hosts.json") }

    public func loadSettings() -> AppSettings { read(AppSettings.self, from: "settings.json") ?? AppSettings() }
    public func saveSettings(_ settings: AppSettings) { write(settings, to: "settings.json") }

    public func saveSession(_ session: Session) {
        guard !session.isEmpty else { return }
        write(session, to: "sessions/\(session.id.uuidString).json")
    }

    public func loadSession(id: UUID) -> Session? {
        read(Session.self, from: "sessions/\(id.uuidString).json")
    }

    public func deleteSession(id: UUID) {
        try? FileManager.default.removeItem(at: sessionsDirectory.appendingPathComponent("\(id.uuidString).json"))
    }

    /// Renames a saved session without counting it as activity, so it keeps its place in the list.
    public func renameSession(id: UUID, title: String) {
        guard var session = loadSession(id: id) else { return }
        session.title = title
        saveSession(session)
    }

    private func allSessions() -> [Session] {
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> Session? in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(Session.self, from: data)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Most recently updated first.
    public func sessionSummaries() -> [SessionSummary] {
        allSessions().map { SessionSummary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }
    }

    /// Sessions whose title or conversation contains `query`, most recently updated first.
    /// An empty query lists every session.
    public func searchSessions(_ query: String) -> [SessionMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return allSessions().compactMap { session -> SessionMatch? in
            let match = SessionMatch(id: session.id, title: session.title, updatedAt: session.updatedAt)
            if needle.isEmpty || session.title.range(of: needle, options: .caseInsensitive) != nil { return match }
            for item in session.transcript where item.kind == .user || item.kind == .assistant || item.kind == .tool {
                for text in [item.title, item.text] {
                    if let text, let snippet = Self.snippet(of: text, around: needle) {
                        return SessionMatch(id: session.id, title: session.title, updatedAt: session.updatedAt, snippet: snippet)
                    }
                }
            }
            return nil
        }
    }

    /// The text around the first occurrence of `needle`, on one line, or `nil` when it does not occur.
    static func snippet(of text: String, around needle: String, context: Int = 36) -> String? {
        guard let range = text.range(of: needle, options: .caseInsensitive) else { return nil }
        let start = text.index(range.lowerBound, offsetBy: -context, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: context * 2, limitedBy: text.endIndex) ?? text.endIndex
        let body = text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (start > text.startIndex ? "…" : "") + body + (end < text.endIndex ? "…" : "")
    }
}
