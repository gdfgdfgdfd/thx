import Foundation

/// How a connection sends its API key.
public enum AuthScheme: String, Codable, Sendable, CaseIterable {
    /// `Authorization: Bearer <key>`
    case bearer
    /// `x-api-key: <key>`
    case apiKey = "x-api-key"
}

/// An extra HTTP header sent with every request of a connection.
public struct HeaderField: Codable, Equatable, Identifiable, Sendable {
    /// Identity for editing rows only; it is not stored and does not take part in equality.
    public var id = UUID()
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case name, value
    }

    public static func == (lhs: HeaderField, rhs: HeaderField) -> Bool {
        lhs.name == rhs.name && lhs.value == rhs.value
    }
}

public enum Headers {
    private static let nameCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~")
        .union(.init(charactersIn: "0"..."9")).union(.init(charactersIn: "a"..."z")).union(.init(charactersIn: "A"..."Z"))

    /// Trims every row and drops the ones HTTP cannot carry: no name, or a name or value with characters a header may not contain.
    public static func sanitized(_ fields: [HeaderField]) -> [HeaderField] {
        fields.compactMap { field in
            let name = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.unicodeScalars.allSatisfy(nameCharacters.contains),
                  !value.contains(where: \.isNewline) else { return nil }
            return HeaderField(name: name, value: value)
        }
    }

    /// The form kept in the secret store; `nil` when there is nothing to keep.
    public static func encode(_ fields: [HeaderField]) -> String? {
        let kept = sanitized(fields)
        guard !kept.isEmpty, let data = try? JSONEncoder().encode(kept) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ text: String?) -> [HeaderField] {
        guard let text, let fields = try? JSONDecoder().decode([HeaderField].self, from: Data(text.utf8)) else { return [] }
        return fields
    }
}

/// A connection to an OpenAI-compatible gateway: base URL plus the model IDs available on it.
/// The API key and custom headers live in the secret store.
public struct Profile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var baseURL: String
    public var models: [String]
    public var defaultModel: String?
    public var authScheme: AuthScheme

    public init(id: UUID = UUID(), name: String, baseURL: String, models: [String] = [], defaultModel: String? = nil,
                authScheme: AuthScheme = .bearer) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.models = models
        self.defaultModel = defaultModel
        self.authScheme = authScheme
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        models = try container.decodeIfPresent([String].self, forKey: .models) ?? []
        defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel)
        // Profiles saved before the auth scheme existed always sent a bearer token.
        authScheme = try container.decodeIfPresent(AuthScheme.self, forKey: .authScheme) ?? .bearer
    }

    public var secretKey: String { "profile.\(id.uuidString).apikey" }
    public var headersKey: String { "profile.\(id.uuidString).headers" }
    public var preferredModel: String? { defaultModel ?? models.first }
}

public struct SSHHost: Codable, Identifiable, Equatable, Sendable {
    public enum Auth: String, Codable, Sendable, CaseIterable {
        case password
        case privateKey
    }

    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var auth: Auth
    /// OpenSSH-format host key recorded on first connect; later connects must match it.
    public var trustedHostKey: String?

    public init(id: UUID = UUID(), name: String, host: String, port: Int = 22, username: String,
                auth: Auth = .password, trustedHostKey: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.trustedHostKey = trustedHostKey
    }

    public var secretKey: String { "host.\(id.uuidString).secret" }
    public var passphraseKey: String { "host.\(id.uuidString).passphrase" }
    public var address: String { "\(username)@\(host)" + (port == 22 ? "" : ":\(port)") }
}

public struct ToolCall: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// Raw JSON object string as produced by the model.
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    public var argumentValues: [String: Any] {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    public func string(_ key: String) -> String? { argumentValues[key] as? String }

    public func number(_ key: String) -> Double? {
        let value = argumentValues[key]
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

public struct ChatMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant, tool
    }

    public var role: Role
    public var content: String
    public var toolCalls: [ToolCall]?
    public var toolCallID: String?

    public init(role: Role, content: String, toolCalls: [ToolCall]? = nil, toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}

/// One block in the on-screen transcript.
public struct TranscriptItem: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case user, assistant, tool, info, error
    }

    public enum Status: String, Codable, Sendable {
        case running, ok, failed, denied
    }

    public var id: UUID
    public var kind: Kind
    public var text: String
    /// Tool blocks only: the one-line description, e.g. `ssh web1 $ uptime`.
    public var title: String?
    public var status: Status?
    /// Prompt blocks only: where the prompt sits in `Session.messages`, so it can be edited and resent.
    public var messageIndex: Int?
    /// Prompt blocks only: workspace-relative paths of the files attached to it.
    public var attachments: [String]?

    public init(id: UUID = UUID(), kind: Kind, text: String, title: String? = nil, status: Status? = nil,
                messageIndex: Int? = nil, attachments: [String]? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.title = title
        self.status = status
        self.messageIndex = messageIndex
        self.attachments = attachments
    }
}

public struct Session: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [ChatMessage]
    public var transcript: [TranscriptItem]

    public static let untitled = "New session"

    public init(id: UUID = UUID(), title: String = Session.untitled, createdAt: Date = Date(), updatedAt: Date = Date(),
                messages: [ChatMessage] = [], transcript: [TranscriptItem] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.transcript = transcript
    }

    public var isEmpty: Bool { messages.isEmpty }

    /// A session is named after its first prompt: the first line, capitalised, cut to a list-friendly length.
    public static func title(from prompt: String, limit: Int = 60) -> String {
        let line = prompt.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard let first = line.first else { return untitled }
        let title = first.uppercased() + line.dropFirst()
        return title.count > limit ? String(title.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : title
    }
}

public struct SessionSummary: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var updatedAt: Date

    public init(id: UUID, title: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }
}

/// A session found by search, with the text around the first hit when it was not in the title.
public struct SessionMatch: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var updatedAt: Date
    public var snippet: String?

    public init(id: UUID, title: String, updatedAt: Date, snippet: String? = nil) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.snippet = snippet
    }
}

public enum ApprovalMode: String, Codable, Sendable, CaseIterable {
    /// Ask before anything that changes state or leaves the device.
    case ask
    /// Run every tool call without asking.
    case auto

    public var label: String {
        switch self {
        case .ask: return "Manual"
        case .auto: return "Auto"
        }
    }

    public var summary: String {
        switch self {
        case .ask: return "Always ask before commands, file edits and web requests."
        case .auto: return "Run commands, file edits and web requests without asking."
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var activeProfileID: UUID?
    public var activeModel: String?
    public var activeHostID: UUID?
    public var themeID: String
    public var fontSize: Double
    public var approvalMode: ApprovalMode
    public var systemPrompt: String

    public init(activeProfileID: UUID? = nil, activeModel: String? = nil, activeHostID: UUID? = nil,
                themeID: String = Theme.dark.id, fontSize: Double = 13,
                approvalMode: ApprovalMode = .ask, systemPrompt: String = "") {
        self.activeProfileID = activeProfileID
        self.activeModel = activeModel
        self.activeHostID = activeHostID
        self.themeID = themeID
        self.fontSize = fontSize
        self.approvalMode = approvalMode
        self.systemPrompt = systemPrompt
    }
}
