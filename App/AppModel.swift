import Foundation
import Observation
import SwiftUI
import TermCore
import TermSSH
import UIKit

struct PendingApproval: Identifiable, Equatable {
    let id = UUID()
    let summary: String
}

struct ShareItem: Identifiable {
    let id = UUID()
    let text: String
}

/// The sheets the main screen presents, one at a time.
enum AppSheet: String, Identifiable {
    case settings, files, terminal, models, search

    var id: String { rawValue }
}

/// A page pushed inside the settings sheet.
enum SettingsRoute: Hashable {
    /// `nil` adds a new connection.
    case connection(UUID?)
    /// `nil` adds a new host.
    case host(UUID?)
    case systemPrompt
}

/// What came of copying picked files into the workspace.
struct ImportResult {
    var paths: [String] = []
    var failures: [String] = []
}

/// The `/setup` wizard: each step consumes one line of input.
enum SetupStep {
    case name
    case baseURL(name: String)
    case apiKey(name: String, baseURL: String)
    case model(name: String, baseURL: String, apiKey: String, models: [String])

    var placeholder: String {
        switch self {
        case .name: return "Connection name"
        case .baseURL: return "Base URL"
        case .apiKey: return "API key (hidden)"
        case .model: return "Model ID"
        }
    }

    var isSecret: Bool {
        if case .apiKey = self { return true }
        return false
    }
}

private struct Failure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

@MainActor
@Observable
final class AppModel {
    var profiles: [Profile] = []
    var hosts: [SSHHost] = []
    var settings = AppSettings()
    var session = Session()
    var input = ""
    var isRunning = false
    var pendingApproval: PendingApproval?
    var setup: SetupStep?
    var usageLine: String?
    /// Bumped when the transcript should jump to the bottom.
    var scrollTick = 0
    /// Bumped when the message box should take the keyboard.
    var focusRequests = 0
    var runStartedAt = Date()

    var activeSheet: AppSheet?
    var settingsPath: [SettingsRoute] = []
    var showSidebar = false
    /// The system file picker opened from the message box.
    var showImporter = false
    var shareItem: ShareItem?

    /// Saved sessions, most recent first.
    var sessionList: [SessionSummary] = []
    /// Files picked for the next prompt.
    var pendingAttachments: [Attachment] = []
    /// The sent prompt being edited: sending replaces it and everything after it.
    var editingItemID: UUID?
    /// Tool steps whose output is unfolded.
    var expandedTools: Set<UUID> = []
    /// Long tool lists unfolded to show every step.
    var expandedGroups: Set<UUID> = []

    /// The terminal screen. It shares the SSH connection with the agent, but not the conversation.
    var console = ConsoleLog()
    var consoleInput = ""
    var consoleRunning = false

    @ObservationIgnored let storage: Storage
    @ObservationIgnored let secrets: SecretStore
    @ObservationIgnored let workspace: URL
    /// Sample content and a scripted model, for screenshots and UI tests. Nothing touches real storage or the network.
    @ObservationIgnored let isDemo: Bool
    @ObservationIgnored private let client: ChatStreaming
    @ObservationIgnored private let demoShell: RemoteShell?
    @ObservationIgnored private var demoShellAnnounced = false
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var consoleTask: Task<Void, Never>?
    @ObservationIgnored private var approvalContinuation: CheckedContinuation<ApprovalDecision, Never>?
    @ObservationIgnored private var alwaysAllow = false
    @ObservationIgnored private var connection: SSHConnection?
    @ObservationIgnored private var connectionHostID: UUID?
    @ObservationIgnored private var pendingConnect: (hostID: UUID, task: Task<SSHConnection, Error>)?
    @ObservationIgnored private var assistantItemID: UUID?
    @ObservationIgnored private var toolItems: [String: UUID] = [:]
    @ObservationIgnored private var promptHistory: [String] = []
    @ObservationIgnored private var historyIndex: Int?
    @ObservationIgnored private var listedSessions: [SessionSummary] = []

    init() {
        let files = FileManager.default
        let arguments = ProcessInfo.processInfo.arguments
        let demo = arguments.contains("-demo")
        let support: URL
        if demo {
            let scratch = files.temporaryDirectory.appendingPathComponent("termai-demo-\(UUID().uuidString)")
            support = scratch.appendingPathComponent("support")
            workspace = scratch.appendingPathComponent("workspace")
            secrets = InMemorySecretStore()
            client = DemoClient()
            demoShell = DemoShell()
        } else {
            support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TermAI")
            workspace = files.urls(for: .documentDirectory, in: .userDomainMask)[0]
            secrets = KeychainStore()
            client = OpenAIClient()
            demoShell = nil
        }
        isDemo = demo
        try? files.createDirectory(at: support, withIntermediateDirectories: true)
        try? files.createDirectory(at: workspace, withIntermediateDirectories: true)
        storage = Storage(directory: support)
        profiles = storage.loadProfiles()
        hosts = storage.loadHosts()
        settings = storage.loadSettings()
        sessionList = storage.sessionSummaries()

        if demo { loadDemo(arguments) }
    }

    // MARK: Derived state

    var theme: Theme { Theme.named(settings.themeID) }
    var palette: Palette { Palette(theme: theme, fontSize: settings.fontSize) }
    var files: WorkspaceFiles { WorkspaceFiles(root: workspace) }

    var activeProfile: Profile? {
        profiles.first { $0.id == settings.activeProfileID } ?? profiles.first
    }

    var activeModel: String? {
        if let model = settings.activeModel, !model.isEmpty { return model }
        return activeProfile?.preferredModel
    }

    /// The active model without its provider prefix, as shown in the message box.
    var modelLabel: String {
        guard activeProfile != nil else { return "No connection" }
        guard let id = activeModel, !id.isEmpty else { return "No model" }
        return id.split(separator: "/").last.map(String.init) ?? id
    }

    var activeHost: SSHHost? {
        hosts.first { $0.id == settings.activeHostID }
    }

    var suggestions: [SlashCommand] {
        setup == nil && pendingApproval == nil ? Commands.suggestions(for: input) : []
    }

    var inputIsSecret: Bool { setup?.isSecret ?? false }

    var placeholder: String {
        if let setup { return setup.placeholder }
        if pendingApproval != nil { return "Waiting for your approval" }
        return isRunning ? "Working… stop to send something else" : "Describe a task or type / for commands"
    }

    func update(_ change: (inout AppSettings) -> Void) {
        change(&settings)
        storage.saveSettings(settings)
    }

    func setApprovalMode(_ mode: ApprovalMode) {
        update { $0.approvalMode = mode }
        // Going back to asking also ends an "always allow" given earlier in the session.
        if mode == .ask { alwaysAllow = false }
    }

    // MARK: Navigation

    func openSidebar() {
        refreshSessions()
        withAnimation(.snappy(duration: 0.3)) { showSidebar = true }
    }

    func closeSidebar() {
        withAnimation(.snappy(duration: 0.3)) { showSidebar = false }
    }

    func present(_ sheet: AppSheet) {
        closeSidebar()
        if sheet == .settings { settingsPath = [] }
        activeSheet = sheet
    }

    /// Opens settings, optionally straight on one of its pages.
    func openSettings(_ route: SettingsRoute? = nil) {
        closeSidebar()
        settingsPath = route.map { [$0] } ?? []
        activeSheet = .settings
    }

    // MARK: Transcript

    @discardableResult
    private func append(_ kind: TranscriptItem.Kind, _ text: String, title: String? = nil,
                        status: TranscriptItem.Status? = nil, messageIndex: Int? = nil,
                        attachments: [String]? = nil) -> UUID {
        let item = TranscriptItem(kind: kind, text: text, title: title, status: status,
                                  messageIndex: messageIndex, attachments: attachments)
        session.transcript.append(item)
        return item.id
    }

    func info(_ text: String) { append(.info, text) }
    func fail(_ text: String) { append(.error, text) }

    private func mutateItem(_ id: UUID?, _ change: (inout TranscriptItem) -> Void) {
        guard let id, let index = session.transcript.lastIndex(where: { $0.id == id }) else { return }
        change(&session.transcript[index])
    }

    private func appendOutput(_ id: UUID?, _ chunk: String) {
        mutateItem(id) { item in
            item.text += chunk
            // Only the tail is shown; keep the stored text bounded for long-running commands.
            if item.text.count > 24_000 { item.text = String(item.text.suffix(16_000)) }
        }
    }

    /// The answer the copy button under the transcript copies: the last block, when it is a reply.
    var lastAnswer: String? {
        guard let last = session.transcript.last, last.kind == .assistant else { return nil }
        return last.text
    }

    func toggleTool(_ id: UUID) {
        if expandedTools.contains(id) {
            expandedTools.remove(id)
        } else {
            expandedTools.insert(id)
        }
    }

    func toggleGroup(_ id: UUID) {
        if expandedGroups.contains(id) {
            expandedGroups.remove(id)
        } else {
            expandedGroups.insert(id)
        }
    }

    // MARK: Input

    func submit() {
        let raw = input
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        input = ""
        historyIndex = nil
        scrollTick += 1

        if let step = setup {
            advanceSetup(step, trimmed)
            return
        }
        if pendingApproval != nil {
            switch trimmed.lowercased() {
            case "y", "yes": resolveApproval(.allow)
            case "a", "always": allowAlways()
            case "n", "no": resolveApproval(.deny)
            default: break
            }
            return
        }

        let parsed = Commands.parse(raw)
        if parsed != .empty, promptHistory.last != trimmed { promptHistory.append(trimmed) }
        switch parsed {
        case .empty:
            // Files alone are a valid prompt.
            if !pendingAttachments.isEmpty { send("") }
        case .prompt(let text): send(text)
        case .shell(let command): runShell(command)
        case .command(let name, let args):
            append(.user, trimmed)
            runCommand(name, args)
        }
    }

    func historyUp() {
        guard !promptHistory.isEmpty else { return }
        let index = max((historyIndex ?? promptHistory.count) - 1, 0)
        historyIndex = index
        input = promptHistory[index]
    }

    func historyDown() {
        guard let current = historyIndex else { return }
        if current + 1 < promptHistory.count {
            historyIndex = current + 1
            input = promptHistory[current + 1]
        } else {
            historyIndex = nil
            input = ""
        }
    }

    func completeSuggestion() {
        if let first = suggestions.first { input = "/\(first.name) " }
    }

    func escape() {
        if setup != nil {
            setup = nil
            info("setup cancelled")
        }
        if editingItemID != nil {
            editingItemID = nil
            pendingAttachments = []
        }
        input = ""
        historyIndex = nil
    }

    // MARK: Agent runs

    private func send(_ text: String) {
        guard !isRunning else {
            input = text
            return info("busy. stop the current run first")
        }
        guard let profile = activeProfile else { return fail("no connection yet. add one in Settings, or type /setup") }
        guard let model = activeModel else { return fail("no model selected. pick one from the model menu") }
        if let id = editingItemID { rewind(to: id) }
        editingItemID = nil
        let attachments = pendingAttachments
        pendingAttachments = []
        if session.messages.isEmpty {
            session.title = Session.title(from: text.isEmpty ? attachments.first?.name ?? "" : text)
        }
        session.messages.append(ChatMessage(role: .user, content: Attachments.prompt(text, attachments: attachments)))
        append(.user, text, messageIndex: session.messages.count - 1,
               attachments: attachments.isEmpty ? nil : attachments.map(\.path))
        session.updatedAt = Date()
        persist()
        startRun(profile: profile, model: model)
    }

    private func startRun(profile: Profile, model: String) {
        isRunning = true
        usageLine = nil
        runStartedAt = Date()
        assistantItemID = nil
        let apiKey = secrets.secret(for: profile.secretKey) ?? ""
        let extraHeaders = customHeaders(for: profile)
        if profile.baseURL.lowercased().hasPrefix("http://"), !apiKey.isEmpty {
            info("note: \(profile.name) uses plain http, so the API key is sent unencrypted")
        }
        let history = session.messages
        let host = activeHost
        let client = self.client

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                var shell: RemoteShell?
                if let host {
                    do {
                        shell = try await self.remoteShell(for: host, notes: .chat)
                    } catch {
                        self.fail("ssh \(host.name): \(error.localizedDescription)")
                        self.info("continuing without SSH")
                    }
                }
                try Task.checkCancellation()
                let system = SystemPrompt.build(custom: self.settings.systemPrompt, hostLabel: shell == nil ? nil : host?.address)
                let request = ChatRequest(
                    baseURL: profile.baseURL, apiKey: apiKey, model: model,
                    messages: [ChatMessage(role: .system, content: system)] + history,
                    authScheme: profile.authScheme, headers: extraHeaders)
                let agent = Agent(client: client, tools: ToolBox(workspace: self.workspace, shell: shell))
                try await agent.run(
                    request: request,
                    approve: { [weak self] _, summary in await self?.requestApproval(summary) ?? .deny },
                    emit: { [weak self] event in await self?.handle(event) })
            } catch {
                if error is CancellationError || Task.isCancelled {
                    self.info("stopped")
                } else {
                    self.fail(error.localizedDescription)
                }
            }
            self.finishRun()
        }
    }

    private func finishRun() {
        for index in session.transcript.indices where session.transcript[index].status == .running {
            session.transcript[index].status = .failed
        }
        isRunning = false
        runTask = nil
        assistantItemID = nil
        toolItems = [:]
        session.updatedAt = Date()
        persist()
    }

    private func handle(_ event: AgentEvent) {
        switch event {
        case .assistantDelta(let delta):
            if assistantItemID == nil { assistantItemID = append(.assistant, "") }
            mutateItem(assistantItemID) { $0.text += delta }
        case .message(let message):
            session.messages.append(message)
            if message.role == .assistant { assistantItemID = nil }
        case .toolStarted(let call, let summary):
            toolItems[call.id] = append(.tool, "", title: summary, status: .running)
        case .toolOutput(let id, let chunk):
            appendOutput(toolItems[id], chunk)
        case .toolFinished(let id, let result, let denied):
            mutateItem(toolItems[id]) { item in
                item.status = denied ? .denied : (result.isError ? .failed : .ok)
                if denied {
                    item.text = "declined"
                } else if item.text.isEmpty {
                    item.text = String(result.text.prefix(2_000))
                } else if result.isError, let last = result.text.split(separator: "\n").last {
                    if !item.text.hasSuffix("\n") { item.text += "\n" }
                    item.text += last
                }
            }
        case .usage(let input, let output):
            let seconds = Int(Date().timeIntervalSince(runStartedAt).rounded())
            usageLine = "\(Self.compact(input)) in · \(Self.compact(output)) out · \(seconds)s"
        }
    }

    static func compact(_ count: Int) -> String {
        count >= 1_000 ? String(format: "%.1fk", Double(count) / 1_000) : "\(count)"
    }

    func cancel() {
        guard isRunning else { return }
        runTask?.cancel()
        if pendingApproval != nil { resolveApproval(.deny) }
        // A run restored for a screenshot has no task behind it to wind things down.
        if runTask == nil { finishRun() }
    }

    // MARK: Edit and resend

    /// Whether a prompt block still maps onto the model history, so it can be edited or resent.
    func canRewind(_ item: TranscriptItem) -> Bool {
        guard item.kind == .user, let index = item.messageIndex, session.messages.indices.contains(index) else { return false }
        return session.messages[index].role == .user
    }

    var lastPromptID: UUID? {
        session.transcript.last { canRewind($0) }?.id
    }

    /// Puts a sent prompt back in the message box. Sending it replaces that prompt and everything after it.
    func beginEditing(_ id: UUID) {
        guard let item = session.transcript.first(where: { $0.id == id }), canRewind(item) else { return }
        editingItemID = id
        input = item.text
        pendingAttachments = reloadAttachments(of: item)
        historyIndex = nil
        focusRequests += 1
    }

    func cancelEditing() {
        guard editingItemID != nil else { return }
        editingItemID = nil
        pendingAttachments = []
        input = ""
    }

    /// Sends a prompt again, dropping the replies it got the first time.
    func resend(_ id: UUID) {
        guard !isRunning else { return info("busy. stop the current run first") }
        guard let item = session.transcript.first(where: { $0.id == id }), canRewind(item) else { return fail("nothing to retry") }
        guard activeProfile != nil, activeModel != nil else { return fail("no connection or model selected") }
        editingItemID = id
        pendingAttachments = reloadAttachments(of: item)
        scrollTick += 1
        send(item.text)
    }

    func retryLast() {
        guard let id = lastPromptID else { return fail("nothing to retry") }
        resend(id)
    }

    private func reloadAttachments(of item: TranscriptItem) -> [Attachment] {
        (item.attachments ?? []).compactMap { try? Attachments.load($0, in: workspace) }
    }

    /// Drops a prompt and everything after it from the transcript and from the model history.
    private func rewind(to id: UUID) {
        guard let position = session.transcript.firstIndex(where: { $0.id == id }),
              canRewind(session.transcript[position]),
              let index = session.transcript[position].messageIndex else { return }
        session.transcript.removeSubrange(position...)
        session.messages.removeSubrange(index...)
    }

    // MARK: Attachments

    /// Attaches files chosen in the system picker; they are copied into the workspace first.
    func attach(_ urls: [URL]) {
        Task { [weak self] in
            guard let self else { return }
            let result = await self.importIntoWorkspace(urls)
            for failure in result.failures { self.fail(failure) }
            self.attachWorkspaceFiles(result.paths)
        }
    }

    /// Copies picked files into the workspace's uploads folder.
    func importIntoWorkspace(_ urls: [URL]) async -> ImportResult {
        let workspace = self.workspace
        // Copying can be slow for large or iCloud files; keep it off the main thread.
        let outcomes = await Task.detached {
            urls.map { url -> Result<Attachment, Error> in Result { try importPickedFile(url, into: workspace) } }
        }.value
        var result = ImportResult()
        for (url, outcome) in zip(urls, outcomes) {
            switch outcome {
            case .success(let attachment): result.paths.append(attachment.path)
            case .failure(let error): result.failures.append("could not import \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }

    /// Adds files that are already in the workspace to the next prompt.
    func attachWorkspaceFiles(_ paths: [String]) {
        for path in paths where !pendingAttachments.contains(where: { $0.path == path }) {
            do {
                pendingAttachments.append(try Attachments.load(path, in: workspace))
            } catch {
                fail("could not attach \(path): \(error.localizedDescription)")
            }
        }
    }

    func removeAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    // MARK: Approval

    private func requestApproval(_ summary: String) async -> ApprovalDecision {
        if settings.approvalMode == .auto || alwaysAllow { return .allow }
        if Task.isCancelled { return .deny }
        pendingApproval = PendingApproval(summary: summary)
        scrollTick += 1
        return await withCheckedContinuation { approvalContinuation = $0 }
    }

    func resolveApproval(_ decision: ApprovalDecision) {
        pendingApproval = nil
        approvalContinuation?.resume(returning: decision)
        approvalContinuation = nil
    }

    func allowAlways() {
        alwaysAllow = true
        info("allowing every action for the rest of this session")
        resolveApproval(.allow)
    }

    // MARK: SSH

    /// Where connection progress is reported: the chat for the agent, the terminal screen for the terminal.
    private enum NoteTarget {
        case chat, console
    }

    private func note(_ text: String, to target: NoteTarget) {
        switch target {
        case .chat: info(text)
        case .console: console.note(text)
        }
    }

    private func remoteShell(for host: SSHHost, notes: NoteTarget) async throws -> RemoteShell {
        if let demoShell {
            if !demoShellAnnounced {
                demoShellAnnounced = true
                note("connecting to \(host.address)…", to: notes)
            }
            return demoShell
        }
        return try await connect(to: host, notes: notes)
    }

    private func connect(to host: SSHHost, notes: NoteTarget) async throws -> SSHConnection {
        if let connection, connectionHostID == host.id, connection.isConnected { return connection }
        // The agent and the terminal can ask at the same moment; both get the one connection being opened.
        if let pending = pendingConnect, pending.hostID == host.id { return try await pending.task.value }
        let task = Task { try await self.openConnection(to: host, notes: notes) }
        pendingConnect = (host.id, task)
        defer {
            if pendingConnect?.hostID == host.id { pendingConnect = nil }
        }
        return try await task.value
    }

    private func openConnection(to host: SSHHost, notes: NoteTarget) async throws -> SSHConnection {
        await dropConnection()
        guard let secret = secrets.secret(for: host.secretKey), !secret.isEmpty else {
            throw Failure(message: "no password or key stored for this host; add one in Settings")
        }
        let credentials = SSHCredentials(
            host: host.host, port: host.port, username: host.username,
            secret: host.auth == .password
                ? .password(secret)
                : .privateKey(pem: secret, passphrase: secrets.secret(for: host.passphraseKey)))
        note("connecting to \(host.address)…", to: notes)
        let new = try await SSHConnection.connect(credentials, label: host.name, trustedHostKey: host.trustedHostKey)
        if host.trustedHostKey == nil, !new.hostKey.isEmpty, let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index].trustedHostKey = new.hostKey
            storage.saveHosts(hosts)
            note("first connection: trusting host key \(SSHKeys.fingerprint(ofOpenSSHKey: new.hostKey))", to: notes)
        }
        connection = new
        connectionHostID = host.id
        return new
    }

    private func dropConnection() async {
        let old = connection
        connection = nil
        connectionHostID = nil
        await old?.close()
    }

    /// `!command`: run directly on the active host and tell the model what happened.
    private func runShell(_ command: String) {
        guard !isRunning else { return info("busy. stop the current run first") }
        guard let host = activeHost else {
            return fail("no SSH host selected. add one in Settings, then pick it below the message box")
        }
        isRunning = true
        runStartedAt = Date()
        runTask = Task { [weak self] in
            guard let self else { return }
            var itemID: UUID?
            do {
                let shell = try await self.remoteShell(for: host, notes: .chat)
                let id = self.append(.tool, "", title: "ssh \(host.name) $ \(command)", status: .running)
                itemID = id
                let (output, continuation) = AsyncStream<String>.makeStream()
                let forwarder = Task { [weak self] in
                    for await chunk in output { self?.appendOutput(id, chunk) }
                }
                let code: Int
                do {
                    code = try await shell.run(command: command, timeout: 300) { continuation.yield($0) }
                } catch {
                    continuation.finish()
                    await forwarder.value
                    throw error
                }
                continuation.finish()
                await forwarder.value
                self.mutateItem(id) { $0.status = code == 0 ? .ok : .failed }
                if code != 0 { self.appendOutput(id, "[exit \(code)]") }
                let text = self.session.transcript.first { $0.id == id }?.text ?? ""
                self.session.messages.append(ChatMessage(
                    role: .user,
                    content: "[I ran this on \(host.address) myself]\n$ \(command)\n\(Truncate.middle(text, limit: 4_000))\n[exit \(code)]"))
            } catch {
                self.mutateItem(itemID) { $0.status = .failed }
                if error is CancellationError || Task.isCancelled {
                    self.info("stopped")
                } else {
                    self.fail("ssh \(host.name): \(error.localizedDescription)")
                }
            }
            self.finishRun()
        }
    }

    // MARK: Terminal screen

    /// Runs the typed command on the active host. Nothing from here reaches the conversation.
    func runConsole() {
        let command = consoleInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !consoleRunning else { return }
        guard let host = activeHost else {
            return console.error("no SSH host selected. add one in Settings, then pick it below the message box")
        }
        consoleInput = ""
        console.command(command)
        consoleRunning = true
        consoleTask = Task { [weak self] in
            guard let self else { return }
            do {
                let shell = try await self.remoteShell(for: host, notes: .console)
                let (output, continuation) = AsyncStream<String>.makeStream()
                let forwarder = Task { [weak self] in
                    for await chunk in output { self?.console.output(chunk) }
                }
                let code: Int
                do {
                    code = try await shell.run(command: command, timeout: 300) { continuation.yield($0) }
                } catch {
                    continuation.finish()
                    await forwarder.value
                    throw error
                }
                continuation.finish()
                await forwarder.value
                if code != 0 { self.console.note("[exit \(code)]") }
            } catch {
                if error is CancellationError || Task.isCancelled {
                    self.console.note("^C")
                } else {
                    self.console.error(error.localizedDescription)
                }
            }
            self.consoleRunning = false
            self.consoleTask = nil
        }
    }

    func cancelConsole() {
        consoleTask?.cancel()
    }

    // MARK: Commands

    private func runCommand(_ name: String, _ args: String) {
        let changesSession = ["new", "sessions", "retry", "clear", "setup"].contains(name)
        if isRunning, changesSession, !(name == "sessions" && args.isEmpty) {
            return info("busy. stop the current run first")
        }
        switch name {
        case "help":
            let width = Commands.all.map(\.usage.count).max() ?? 0
            let lines = Commands.all.map { $0.usage.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.help }
            info(lines.joined(separator: "\n") + "\n\n!<command>  run a command on the SSH host yourself")
        case "setup":
            setup = .name
            info("new connection. esc cancels.\nname (e.g. openrouter):")
        case "config":
            openSettings()
        case "model": modelCommand(args)
        case "profile": profileCommand(args)
        case "host": hostCommand(args)
        case "approve":
            if let mode = ApprovalMode(rawValue: args.lowercased()) {
                setApprovalMode(mode)
            } else if !args.isEmpty {
                return fail("usage: /approve ask|auto")
            }
            info("permissions: \(settings.approvalMode.label). \(settings.approvalMode.summary)")
        case "theme":
            if args.isEmpty {
                info(Theme.all.map { ($0.id == theme.id ? "* " : "  ") + $0.id.padding(toLength: 11, withPad: " ", startingAt: 0) + $0.name }
                    .joined(separator: "\n"))
            } else if let match = Theme.all.first(where: { $0.id == args.lowercased() || $0.name.lowercased().hasPrefix(args.lowercased()) }) {
                update { $0.themeID = match.id }
                info("theme: \(match.name)")
            } else {
                fail("unknown theme. options: " + Theme.all.map(\.id).joined(separator: ", "))
            }
        case "system":
            if args.isEmpty {
                info(settings.systemPrompt.isEmpty ? "no custom system prompt. /system <text> sets one" : settings.systemPrompt)
            } else {
                update { $0.systemPrompt = args.lowercased() == "reset" ? "" : args }
                info(settings.systemPrompt.isEmpty ? "system prompt reset" : "system prompt set")
            }
        case "new":
            startNewSession()
        case "sessions": sessionsCommand(args)
        case "retry":
            if let id = lastPromptID { return resend(id) }
            // Sessions saved before prompts were linked to the history: rerun without trimming the screen.
            guard let index = session.messages.lastIndex(where: { $0.role == .user }) else { return fail("nothing to retry") }
            guard let profile = activeProfile, let model = activeModel else { return fail("no connection or model selected") }
            session.messages.removeSubrange((index + 1)...)
            startRun(profile: profile, model: model)
        case "copy":
            guard let last = session.transcript.last(where: { $0.kind == .assistant }) else { return fail("no answer to copy") }
            UIPasteboard.general.string = last.text
            info("copied \(last.text.count) characters")
        case "export":
            guard !session.isEmpty else { return fail("nothing to export yet") }
            shareItem = ShareItem(text: Markdown.export(session))
        case "clear":
            session.transcript.removeAll()
            editingItemID = nil
        default:
            fail("unknown command: /\(name)")
        }
    }

    private func modelCommand(_ args: String) {
        guard let profile = activeProfile else { return fail("no connection yet. add one in Settings, or type /setup") }
        if args.isEmpty {
            let current = activeModel
            let lines = profile.models.map { ($0 == current ? "* " : "  ") + $0 }
            info(lines.isEmpty ? "no models saved for \(profile.name). /model <id> adds one" : lines.joined(separator: "\n"))
            return
        }
        // Accept an exact ID, a unique substring of a saved ID, or a brand-new ID.
        let matches = profile.models.filter { $0.localizedCaseInsensitiveContains(args) }
        let chosen = profile.models.first { $0 == args } ?? (matches.count == 1 ? matches[0] : args)
        select(model: chosen, in: profile.id)
        info("model: \(chosen)")
    }

    private func profileCommand(_ args: String) {
        if args.isEmpty {
            let current = activeProfile?.id
            let lines = profiles.map { ($0.id == current ? "* " : "  ") + $0.name + "  " + $0.baseURL }
            return info(lines.isEmpty ? "no connections. add one in Settings, or type /setup" : lines.joined(separator: "\n"))
        }
        guard let match = profiles.first(where: { $0.name.lowercased().hasPrefix(args.lowercased()) }) else {
            return fail("no connection named \(args)")
        }
        selectProfile(match.id)
        info("connection: \(match.name) · \(match.preferredModel ?? "no model")")
    }

    private func hostCommand(_ args: String) {
        if args.isEmpty {
            let current = activeHost?.id
            let lines = hosts.map { ($0.id == current ? "* " : "  ") + $0.name + "  " + $0.address }
            return info(lines.isEmpty ? "no SSH hosts. add one in Settings" : lines.joined(separator: "\n") + (current == nil ? "\n(none selected)" : ""))
        }
        if ["off", "none"].contains(args.lowercased()) {
            selectHost(nil)
            return info("ssh: off")
        }
        guard let match = hosts.first(where: { $0.name.lowercased().hasPrefix(args.lowercased()) }) else {
            return fail("no host named \(args)")
        }
        selectHost(match.id)
        info("ssh: \(match.name) (\(match.address)). connects on first use")
    }

    private func sessionsCommand(_ args: String) {
        if args.isEmpty {
            listedSessions = Array(storage.sessionSummaries().prefix(20))
            let lines = listedSessions.enumerated().map { index, summary in
                "\(index + 1)".padding(toLength: 4, withPad: " ", startingAt: 0)
                    + RelativeTime.short(summary.updatedAt).padding(toLength: 13, withPad: " ", startingAt: 0) + summary.title
            }
            return info(lines.isEmpty ? "no saved sessions" : lines.joined(separator: "\n") + "\n\n/sessions <n> opens one")
        }
        guard let number = Int(args), listedSessions.indices.contains(number - 1) else {
            return fail("run /sessions first, then /sessions <n>")
        }
        switchSession(listedSessions[number - 1].id)
    }

    // MARK: Sessions

    /// Saves the current session and refreshes the list the sidebar shows.
    private func persist() {
        storage.saveSession(session)
        sessionList = storage.sessionSummaries()
    }

    func refreshSessions() {
        sessionList = storage.sessionSummaries()
    }

    private func resetSessionState() {
        alwaysAllow = false
        usageLine = nil
        editingItemID = nil
        pendingAttachments = []
        expandedTools = []
        expandedGroups = []
        input = ""
    }

    private func startNewSession() {
        persist()
        session = Session()
        resetSessionState()
    }

    func newSession() {
        closeSidebar()
        activeSheet = nil
        guard !isRunning else { return info("busy. stop the current run before starting a new session") }
        guard !session.transcript.isEmpty || !session.isEmpty else { return }
        startNewSession()
    }

    func switchSession(_ id: UUID) {
        closeSidebar()
        activeSheet = nil
        guard id != session.id else { return }
        guard !isRunning else { return info("busy. stop the current run before switching sessions") }
        guard let loaded = storage.loadSession(id: id) else {
            refreshSessions()
            return fail("that session could not be opened")
        }
        persist()
        session = loaded
        resetSessionState()
        scrollTick += 1
    }

    func deleteSession(_ id: UUID) {
        let isCurrent = id == session.id
        guard !(isCurrent && isRunning) else { return }
        storage.deleteSession(id: id)
        if isCurrent {
            session = Session()
            resetSessionState()
        }
        refreshSessions()
    }

    func renameSession(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if id == session.id { session.title = trimmed }
        storage.renameSession(id: id, title: trimmed)
        refreshSessions()
    }

    func searchSessions(_ query: String) -> [SessionMatch] {
        storage.searchSessions(query)
    }

    // MARK: Connections

    func select(model: String, in profileID: UUID) {
        if let index = profiles.firstIndex(where: { $0.id == profileID }), !profiles[index].models.contains(model) {
            profiles[index].models.append(model)
            storage.saveProfiles(profiles)
        }
        update {
            $0.activeProfileID = profileID
            $0.activeModel = model
        }
    }

    func selectProfile(_ id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        update {
            $0.activeProfileID = profile.id
            $0.activeModel = profile.preferredModel
        }
    }

    func apiKey(for profile: Profile) -> String { secrets.secret(for: profile.secretKey) ?? "" }

    func customHeaders(for profile: Profile) -> [HeaderField] {
        Headers.decode(secrets.secret(for: profile.headersKey))
    }

    func saveProfile(_ profile: Profile, apiKey: String, headers: [HeaderField] = []) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        storage.saveProfiles(profiles)
        secrets.setSecret(apiKey, for: profile.secretKey)
        secrets.setSecret(Headers.encode(headers), for: profile.headersKey)
        if settings.activeProfileID == nil || profiles.count == 1 {
            update {
                $0.activeProfileID = profile.id
                $0.activeModel = profile.preferredModel
            }
        } else if settings.activeProfileID == profile.id, let model = settings.activeModel, !profile.models.contains(model) {
            update { $0.activeModel = profile.preferredModel }
        }
    }

    func deleteProfile(_ profile: Profile) {
        profiles.removeAll { $0.id == profile.id }
        storage.saveProfiles(profiles)
        secrets.setSecret(nil, for: profile.secretKey)
        secrets.setSecret(nil, for: profile.headersKey)
        if settings.activeProfileID == profile.id {
            update {
                $0.activeProfileID = profiles.first?.id
                $0.activeModel = profiles.first?.preferredModel
            }
        }
    }

    /// The model IDs a gateway advertises. Demo mode answers from the saved connection instead of the network.
    func listModels(baseURL: String, apiKey: String, authScheme: AuthScheme, headers: [HeaderField]) async throws -> [String] {
        if isDemo {
            try await Task.sleep(for: .milliseconds(300))
            return profiles.first?.models ?? []
        }
        return try await OpenAIClient().listModels(baseURL: baseURL, apiKey: apiKey, authScheme: authScheme, headers: headers)
    }

    // MARK: SSH hosts

    func hostSecret(for host: SSHHost) -> String { secrets.secret(for: host.secretKey) ?? "" }
    func hostPassphrase(for host: SSHHost) -> String { secrets.secret(for: host.passphraseKey) ?? "" }

    func selectHost(_ id: UUID?) {
        update { $0.activeHostID = id }
        if connectionHostID != id { Task { await dropConnection() } }
    }

    func saveHost(_ host: SSHHost, secret: String, passphrase: String) {
        let isFirst = hosts.isEmpty
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        storage.saveHosts(hosts)
        secrets.setSecret(secret, for: host.secretKey)
        secrets.setSecret(passphrase, for: host.passphraseKey)
        if isFirst { update { $0.activeHostID = host.id } }
        // Reconnect with the new details on next use.
        if connectionHostID == host.id { Task { await dropConnection() } }
    }

    func deleteHost(_ host: SSHHost) {
        hosts.removeAll { $0.id == host.id }
        storage.saveHosts(hosts)
        secrets.setSecret(nil, for: host.secretKey)
        secrets.setSecret(nil, for: host.passphraseKey)
        if settings.activeHostID == host.id { selectHost(nil) }
    }

    // MARK: Setup wizard

    private func advanceSetup(_ step: SetupStep, _ value: String) {
        switch step {
        case .name:
            guard !value.isEmpty else { return info("name:") }
            append(.user, value)
            setup = .baseURL(name: value)
            info("base URL (e.g. https://api.openai.com/v1):")
        case .baseURL(let name):
            guard let url = URL(string: value), url.scheme?.hasPrefix("http") == true, url.host != nil else {
                return info("that is not an http(s) URL. base URL:")
            }
            append(.user, value)
            setup = .apiKey(name: name, baseURL: value)
            info("API key (hidden, stored in the Keychain; empty for none):")
        case .apiKey(let name, let baseURL):
            append(.user, value.isEmpty ? "(none)" : String(repeating: "•", count: min(value.count, 16)))
            info("fetching models…")
            Task { [weak self] in
                var models: [String] = []
                var problem: String?
                do {
                    models = try await self?.listModels(baseURL: baseURL, apiKey: value, authScheme: .bearer, headers: []) ?? []
                } catch {
                    problem = error.localizedDescription
                }
                guard let self, case .apiKey? = self.setup else { return }
                self.setup = .model(name: name, baseURL: baseURL, apiKey: value, models: models)
                if let problem {
                    self.fail("could not list models: \(problem)")
                    self.info("type a model ID to use anyway:")
                } else if models.isEmpty {
                    self.info("the endpoint listed no models. model ID:")
                } else {
                    let shown = models.prefix(12).joined(separator: "\n  ")
                    let more = models.count > 12 ? "\n  … \(models.count - 12) more" : ""
                    self.info("\(models.count) models:\n  \(shown)\(more)\ndefault model ID (enter for \(models[0])):")
                }
            }
        case .model(let name, let baseURL, let apiKey, let models):
            let chosen = value.isEmpty ? models.first : (models.first { $0 == value }
                ?? models.first { $0.localizedCaseInsensitiveContains(value) } ?? value)
            guard let chosen else { return info("model ID:") }
            append(.user, chosen)
            var profile = Profile(name: name, baseURL: baseURL, models: models, defaultModel: chosen)
            if !profile.models.contains(chosen) { profile.models.insert(chosen, at: 0) }
            saveProfile(profile, apiKey: apiKey)
            update {
                $0.activeProfileID = profile.id
                $0.activeModel = chosen
            }
            setup = nil
            info("saved. \(name) · \(chosen) is active.")
        }
    }

    // MARK: Demo content

    private func loadDemo(_ arguments: [String]) {
        let profile = Profile(name: "openrouter", baseURL: "https://openrouter.ai/api/v1",
                              models: ["anthropic/claude-sonnet-5", "openai/gpt-6-luna"], defaultModel: "anthropic/claude-sonnet-5")
        let host = SSHHost(name: "web1", host: "10.0.0.12", username: "deploy")
        profiles = [profile]
        hosts = [host]
        secrets.setSecret("placeholder-key-for-demo-mode", for: profile.secretKey)
        secrets.setSecret(Headers.encode([HeaderField(name: "HTTP-Referer", value: "https://termai.example")]), for: profile.headersKey)
        settings = AppSettings(activeProfileID: profile.id, activeModel: profile.defaultModel, activeHostID: host.id,
                               themeID: UserDefaults.standard.string(forKey: "theme") ?? Theme.dark.id)

        let earlier: [(title: String, age: TimeInterval)] = [
            ("Rotate the deploy keys", 3 * 3_600), ("Draft release notes for 0.2", 26 * 3_600), ("Disk usage report for db1", 4 * 86_400),
        ]
        for entry in earlier {
            storage.saveSession(Session(
                title: entry.title, updatedAt: Date().addingTimeInterval(-entry.age),
                messages: [ChatMessage(role: .user, content: entry.title), ChatMessage(role: .assistant, content: "Done on web1.")],
                transcript: [TranscriptItem(kind: .user, text: entry.title, messageIndex: 0),
                             TranscriptItem(kind: .assistant, text: "Done on web1.")]))
        }
        for (path, content) in DemoContent.files {
            let url = workspace.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(content.utf8).write(to: url)
        }

        if !arguments.contains("-demoEmpty") {
            loadDemoConversation(steps: arguments.contains("-demoSteps"), approval: arguments.contains("-demoApproval"))
        }
        refreshSessions()

        if arguments.contains("-demoCompose") {
            editingItemID = lastPromptID
            input = "why is nginx down on web1? check the error log too"
            attachWorkspaceFiles(["nginx-app.conf", "report.md"])
        }
        if arguments.contains("-demoTerminal") {
            console.note("connecting to \(host.address)…")
            demoShellAnnounced = true
            for command in ["uptime", "df -h /"] {
                console.command(command)
                console.output(DemoShell.output(for: command).text)
            }
            activeSheet = .terminal
        }
        if arguments.contains("-demoSidebar") { showSidebar = true }
        if arguments.contains("-demoSettings") { activeSheet = .settings }
        if arguments.contains("-demoConnection") { openSettings(.connection(profile.id)) }
        if arguments.contains("-demoHost") { openSettings(.host(host.id)) }
        if arguments.contains("-demoFiles") { activeSheet = .files }
        if arguments.contains("-demoModels") { activeSheet = .models }
        if arguments.contains("-demoSearch") { activeSheet = .search }
    }

    private func loadDemoConversation(steps: Bool, approval: Bool) {
        let prompt = steps ? "audit web1 before the release" : DemoContent.prompt
        session = Session(title: Session.title(from: prompt), messages: [ChatMessage(role: .user, content: prompt)])
        append(.user, prompt, messageIndex: 0)

        if steps {
            append(.assistant, "Running the pre-release checks on web1.")
            var failed: UUID?
            for step in DemoContent.auditSteps {
                let id = append(.tool, step.output, title: "ssh web1 $ \(step.command)", status: step.ok ? .ok : .failed)
                if !step.ok { failed = id }
            }
            if let failed { expandedTools = [failed] }
            append(.assistant, DemoContent.auditAnswer)
            usageLine = "6.1k in · 540 out · 21s"
        } else {
            append(.assistant, "Checking the service state first.")
            append(.tool, DemoShell.output(for: DemoContent.statusCommand).text + "[exit 3]",
                   title: "ssh web1 $ \(DemoContent.statusCommand)", status: .failed)
            append(.assistant, DemoContent.diagnosis)
            if approval {
                append(.tool, "", title: "ssh web1 $ \(DemoContent.fixCommand)", status: .running)
                isRunning = true
                pendingApproval = PendingApproval(summary: "ssh web1 $ \(DemoContent.fixCommand)")
            } else {
                append(.tool, DemoShell.output(for: DemoContent.fixCommand).text,
                       title: "ssh web1 $ \(DemoContent.fixCommand)", status: .ok)
                append(.assistant, DemoContent.resolution)
                usageLine = "2.4k in · 312 out · 9s"
            }
        }
        storage.saveSession(session)
    }
}

/// Copies a file chosen in the picker into the workspace. Picked URLs are security-scoped and may be
/// iCloud placeholders, so the scope is opened and the read goes through a file coordinator.
private func importPickedFile(_ url: URL, into workspace: URL) throws -> Attachment {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }

    var coordinationError: NSError?
    var outcome: Result<Attachment, Error>?
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
        outcome = Result { try Attachments.importFile(at: readable, into: workspace) }
    }
    if let coordinationError { throw coordinationError }
    guard let outcome else { throw Failure(message: "the file could not be read") }
    return try outcome.get()
}
