import XCTest
@testable import TermCore

/// Replays scripted streams, one per model call, and records the requests it received.
final class ScriptedClient: ChatStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[StreamEvent]]
    private(set) var requests: [ChatRequest] = []

    init(_ scripts: [[StreamEvent]]) {
        self.scripts = scripts
    }

    func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        lock.lock()
        requests.append(request)
        let events = scripts.isEmpty ? [] : scripts.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            events.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

struct FakeShell: RemoteShell {
    var label = "box"
    func run(command: String, timeout: TimeInterval, onOutput: @escaping @Sendable (String) -> Void) async throws -> Int {
        onOutput("ran: \(command)\n")
        return command.contains("fail") ? 3 : 0
    }
}

actor Recorder {
    var messages: [ChatMessage] = []
    var finished: [(id: String, result: ToolResult, denied: Bool)] = []
    var text = ""

    func record(_ event: AgentEvent) {
        switch event {
        case .message(let message): messages.append(message)
        case .toolFinished(let id, let result, let denied): finished.append((id, result, denied))
        case .assistantDelta(let delta): text += delta
        default: break
        }
    }
}

final class TermCoreTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("termcore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
    }

    // MARK: Streaming

    func testSSEParserHandlesSplitChunksAndCRLF() {
        var parser = SSEParser()
        XCTAssertEqual(parser.feed(Data("data: {\"a\"".utf8)), [])
        XCTAssertEqual(parser.feed(Data(":1}\r\n\r\ndata:[DONE]\n: comment\nevent: x\n".utf8)), ["{\"a\":1}", "[DONE]"])
    }

    func testSSEParserKeepsMultibyteCharactersSplitAcrossChunks() {
        var parser = SSEParser()
        let bytes = Array("data: héllo ✓\n".utf8)
        XCTAssertEqual(parser.feed(Data(bytes[..<8])), [])
        XCTAssertEqual(parser.feed(Data(bytes[8...])), ["héllo ✓"])
    }

    func testDecodeTextToolCallsAndUsage() {
        XCTAssertEqual(OpenAIClient.decode(#"{"choices":[{"delta":{"content":"hi"}}]}"#), [.text("hi")])
        XCTAssertEqual(
            OpenAIClient.decode(#"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"c1","function":{"name":"ssh_exec","arguments":"{\"co"}}]}}]}"#),
            [.toolCallDelta(index: 1, id: "c1", name: "ssh_exec", arguments: "{\"co")])
        XCTAssertEqual(OpenAIClient.decode(#"{"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":3}}"#),
                       [.usage(input: 12, output: 3)])
        XCTAssertEqual(OpenAIClient.decode("not json"), [])
    }

    func testRequestBodyAndEndpoint() throws {
        let request = ChatRequest(
            baseURL: "https://example.com/v1/", apiKey: "k", model: "m",
            messages: [
                ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "c1", name: "ssh_exec", arguments: "")]),
                ChatMessage(role: .tool, content: "out", toolCallID: "c1"),
            ],
            tools: ToolBox(workspace: workspace, shell: FakeShell()).specs)
        let urlRequest = try OpenAIClient.urlRequest(for: request)
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer k")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "m")
        XCTAssertEqual(body["stream"] as? Bool, true)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let call = try XCTUnwrap((messages[0]["tool_calls"] as? [[String: Any]])?.first)
        XCTAssertEqual((call["function"] as? [String: Any])?["arguments"] as? String, "{}")
        XCTAssertEqual(messages[1]["tool_call_id"] as? String, "c1")
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 5)
        let schema = (tools[0]["function"] as? [String: Any])?["parameters"] as? [String: Any]
        XCTAssertEqual(schema?["type"] as? String, "object")

        XCTAssertThrowsError(try OpenAIClient.endpoint("ftp://x", "/models"))
        XCTAssertThrowsError(try OpenAIClient.endpoint("not a url", "/models"))
    }

    func testAPIErrorExtractsMessage() {
        let error = APIError.from(status: 401, body: Data(#"{"error":{"message":"bad key"}}"#.utf8))
        XCTAssertEqual(error, APIError(status: 401, message: "bad key"))
        XCTAssertEqual(APIError.from(status: 502, body: Data("Bad Gateway".utf8)).message, "Bad Gateway")
    }

    // MARK: Agent

    func testAgentRunsToolThenAnswers() async throws {
        let client = ScriptedClient([
            [.text("checking"),
             .toolCallDelta(index: 0, id: "c1", name: "ssh_exec", arguments: "{\"command\":"),
             .toolCallDelta(index: 0, id: nil, name: nil, arguments: "\"uptime\"}")],
            [.text("all good")],
        ])
        let recorder = Recorder()
        let agent = Agent(client: client, tools: ToolBox(workspace: workspace, shell: FakeShell()))
        try await agent.run(
            request: ChatRequest(baseURL: "http://x", apiKey: "", model: "m", messages: [ChatMessage(role: .user, content: "status?")]),
            approve: { _, summary in
                XCTAssertEqual(summary, "ssh box $ uptime")
                return .allow
            },
            emit: { await recorder.record($0) })

        let messages = await recorder.messages
        XCTAssertEqual(messages.map(\.role), [.assistant, .tool, .assistant])
        XCTAssertEqual(messages[0].toolCalls?.first?.arguments, "{\"command\":\"uptime\"}")
        XCTAssertEqual(messages[1].toolCallID, "c1")
        XCTAssertEqual(messages[1].content, "ran: uptime\n\n[exit 0]")
        XCTAssertEqual(messages[2].content, "all good")

        // The second model call must see the tool result.
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertEqual(client.requests[1].messages.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(client.requests[0].tools.first?.name, "ssh_exec")
    }

    func testDeniedToolIsReportedToTheModelAndNotRun() async throws {
        let client = ScriptedClient([
            [.toolCallDelta(index: 0, id: "c1", name: "write_file", arguments: "{\"path\":\"a.txt\",\"content\":\"x\"}")],
            [.text("ok, skipped")],
        ])
        let recorder = Recorder()
        let agent = Agent(client: client, tools: ToolBox(workspace: workspace, shell: nil))
        try await agent.run(
            request: ChatRequest(baseURL: "http://x", apiKey: "", model: "m", messages: [ChatMessage(role: .user, content: "write")]),
            approve: { _, _ in .deny },
            emit: { await recorder.record($0) })

        let finished = await recorder.finished
        XCTAssertEqual(finished.count, 1)
        XCTAssertTrue(finished[0].denied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("a.txt").path))
        let messages = await recorder.messages
        XCTAssertEqual(messages[1].role, .tool)
        XCTAssertTrue(messages[1].content.contains("declined"))
    }

    func testReadOnlyToolsSkipApprovalAndFailedCommandsAreErrors() async throws {
        try Data("hello".utf8).write(to: workspace.appendingPathComponent("note.txt"))
        let client = ScriptedClient([
            [.toolCallDelta(index: 0, id: "", name: "read_file", arguments: "{\"path\":\"note.txt\"}"),
             .toolCallDelta(index: 1, id: "c2", name: "ssh_exec", arguments: "{\"command\":\"fail\"}")],
            [.text("done")],
        ])
        let recorder = Recorder()
        let asked = Recorder()
        let agent = Agent(client: client, tools: ToolBox(workspace: workspace, shell: FakeShell()))
        try await agent.run(
            request: ChatRequest(baseURL: "http://x", apiKey: "", model: "m", messages: [ChatMessage(role: .user, content: "go")]),
            approve: { call, _ in
                await asked.record(.assistantDelta(call.name))
                return .allow
            },
            emit: { await recorder.record($0) })

        let askedFor = await asked.text
        XCTAssertEqual(askedFor, "ssh_exec")
        let finished = await recorder.finished
        XCTAssertEqual(finished[0].result, ToolResult(text: "hello"))
        XCTAssertTrue(finished[1].result.isError)
        XCTAssertTrue(finished[1].result.text.hasSuffix("[exit 3]"))
        // A call that arrived without an id still gets one, so its result can be matched.
        let messages = await recorder.messages
        XCTAssertFalse(try XCTUnwrap(messages[0].toolCalls?[0].id).isEmpty)
        XCTAssertEqual(messages[1].toolCallID, messages[0].toolCalls?[0].id)
    }

    func testAgentStopsAfterMaxSteps() async {
        let loop: [StreamEvent] = [.toolCallDelta(index: 0, id: "c", name: "list_files", arguments: "{}")]
        let agent = Agent(client: ScriptedClient([loop, loop, loop]), tools: ToolBox(workspace: workspace, shell: nil), maxSteps: 2)
        do {
            try await agent.run(
                request: ChatRequest(baseURL: "http://x", apiKey: "", model: "m", messages: []),
                approve: { _, _ in .allow }, emit: { _ in })
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AgentError, .tooManySteps(2))
        }
    }

    // MARK: Tools

    func testWorkspaceToolsStayInsideWorkspace() async throws {
        let tools = ToolBox(workspace: workspace, shell: nil)
        let write = await tools.run(ToolCall(id: "1", name: "write_file", arguments: #"{"path":"dir/a.txt","content":"abc"}"#)) { _ in }
        XCTAssertEqual(write, ToolResult(text: "wrote 3 bytes"))
        let list = await tools.run(ToolCall(id: "2", name: "list_files", arguments: #"{"path":"dir"}"#)) { _ in }
        XCTAssertEqual(list.text, "a.txt  3")
        let root = await tools.run(ToolCall(id: "3", name: "list_files", arguments: "{}")) { _ in }
        XCTAssertEqual(root.text, "dir/")

        for path in ["../outside.txt", "dir/../../outside.txt", "/../../etc/passwd"] {
            let escaped = await tools.run(ToolCall(id: "4", name: "read_file", arguments: "{\"path\":\"\(path)\"}")) { _ in }
            XCTAssertTrue(escaped.isError, path)
            XCTAssertTrue(escaped.text.contains("outside the workspace"), escaped.text)
        }
        // An absolute-looking path is treated as relative to the workspace root.
        let absolute = await tools.run(ToolCall(id: "5", name: "read_file", arguments: #"{"path":"/dir/a.txt"}"#)) { _ in }
        XCTAssertEqual(absolute.text, "abc")

        let noShell = await tools.run(ToolCall(id: "6", name: "ssh_exec", arguments: #"{"command":"ls"}"#)) { _ in }
        XCTAssertTrue(noShell.isError)
        XCTAssertFalse(tools.specs.contains { $0.name == "ssh_exec" })
    }

    func testSymlinkCannotEscapeWorkspace() async throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("secret".utf8).write(to: outside.appendingPathComponent("s.txt"))
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("link"), withDestinationURL: outside)

        let result = await ToolBox(workspace: workspace, shell: nil)
            .run(ToolCall(id: "1", name: "read_file", arguments: #"{"path":"link/s.txt"}"#)) { _ in }
        XCTAssertTrue(result.isError, result.text)
    }

    func testTruncateAndStripHTML() {
        let long = String(repeating: "a", count: 50) + String(repeating: "b", count: 50)
        let cut = Truncate.middle(long, limit: 20)
        XCTAssertTrue(cut.hasPrefix("aaaaaaaaaa\n"))
        XCTAssertTrue(cut.hasSuffix("\nbbbbbbbbbb"))
        XCTAssertTrue(cut.contains("80 characters omitted"))
        XCTAssertEqual(ToolBox.stripHTML("<html><style>p{}</style><p>Tom &amp; Jerry</p><script>x()</script></html>"), "Tom & Jerry")
    }

    func testMarkdownSegmentsAndExport() {
        XCTAssertEqual(Markdown.segments("intro\n\n```sh\nls -la\n\necho hi\n```\nafter"), [
            .init(isCode: false, text: "intro"),
            .init(isCode: true, text: "ls -la\n\necho hi", language: "sh"),
            .init(isCode: false, text: "after"),
        ])
        // A fence still open while streaming renders as code.
        XCTAssertEqual(Markdown.segments("a\n```\nx = 1"), [.init(isCode: false, text: "a"), .init(isCode: true, text: "x = 1")])
        XCTAssertEqual(Markdown.segments(""), [])

        let session = Session(title: "t", transcript: [
            TranscriptItem(kind: .user, text: "hi"), TranscriptItem(kind: .info, text: "noise"),
            TranscriptItem(kind: .tool, text: "up 3 days", title: "ssh box $ uptime"), TranscriptItem(kind: .assistant, text: "fine"),
        ])
        XCTAssertEqual(Markdown.export(session), "# t\n\n**❯ hi**\n\n```\nssh box $ uptime\nup 3 days\n```\n\nfine\n")
    }

    func testMarkdownLines() {
        typealias Line = Markdown.Line
        XCTAssertEqual(Markdown.lines("## Plan\n- one\n  * nested\n2) two\n> note\n---\n**bold** text\n1.5 times\n-x"), [
            Line(kind: .heading, text: "Plan"),
            Line(kind: .bullet, text: "one", marker: "•"),
            Line(kind: .bullet, text: "nested", marker: "•", indent: 1),
            Line(kind: .numbered, text: "two", marker: "2."),
            Line(kind: .quote, text: "note"),
            Line(kind: .rule, text: ""),
            Line(kind: .text, text: "**bold** text"),
            Line(kind: .text, text: "1.5 times"),
            Line(kind: .text, text: "-x"),
        ])
        // Blank lines survive so paragraphs keep their spacing.
        XCTAssertEqual(Markdown.lines("a\n\nb").map(\.text), ["a", "", "b"])
    }

    func testTranscriptGroupsToolRunsAndSummarisesOutput() {
        let items = [
            TranscriptItem(kind: .user, text: "go"), TranscriptItem(kind: .tool, text: "1"), TranscriptItem(kind: .tool, text: "2"),
            TranscriptItem(kind: .assistant, text: "mid"), TranscriptItem(kind: .tool, text: "3"), TranscriptItem(kind: .assistant, text: "end"),
        ]
        let groups = Transcript.groups(items)
        XCTAssertEqual(groups.map { $0.items.map(\.text) }, [["go"], ["1", "2"], ["mid"], ["3"], ["end"]])
        XCTAssertEqual(groups.map(\.isActivity), [false, true, false, true, false])
        // A list keeps its identity as calls are added, so the view is updated rather than replaced.
        XCTAssertEqual(groups[1].id, items[1].id)
        XCTAssertEqual(Transcript.groups([]), [])

        XCTAssertEqual(Transcript.preview("a\nb\n\n"), "b")
        XCTAssertEqual(Transcript.preview("nginx: unknown directive\n[exit 3]"), "nginx: unknown directive  [exit 3]")
        XCTAssertEqual(Transcript.preview("[exit 1]"), "[exit 1]")
        XCTAssertNil(Transcript.preview(" \n"))
        XCTAssertEqual(Transcript.lineCount("a\nb\n"), 2)
        XCTAssertEqual(Transcript.tail("1\n2\n3\n4", lines: 2), "… 2 earlier lines\n3\n4")
        XCTAssertEqual(Transcript.tail("1\n2", lines: 2), "1\n2")
    }

    func testAttachmentsAreCopiedIntoTheWorkspaceAndSentWithThePrompt() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("picked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let note = outside.appendingPathComponent("note.txt")
        try Data("use ```fences```".utf8).write(to: note)
        let binary = outside.appendingPathComponent("photo.bin")
        try Data([0xFF, 0xD8, 0x00, 0x10]).write(to: binary)

        let first = try Attachments.importFile(at: note, into: workspace)
        let second = try Attachments.importFile(at: note, into: workspace)
        let third = try Attachments.importFile(at: binary, into: workspace)
        XCTAssertEqual([first.path, second.path, third.path], ["uploads/note.txt", "uploads/note-2.txt", "uploads/photo.bin"])
        XCTAssertEqual(first.text, "use ```fences```")
        XCTAssertEqual(first.size, 16)
        XCTAssertNil(third.text)

        // The copy is where the agent's file tools can read it.
        let read = try ToolBox(workspace: workspace, shell: nil).resolve(first.path)
        XCTAssertEqual(try String(contentsOf: read, encoding: .utf8), "use ```fences```")
        XCTAssertEqual(try Attachments.load(second.path, in: workspace).text, first.text)

        XCTAssertEqual(Attachments.prompt("hi", attachments: []), "hi")
        // The fence is longer than any run of backticks in the file, so the contents cannot close it early.
        XCTAssertEqual(Attachments.prompt("check this", attachments: [first]),
                       "check this\n\n[attached file: uploads/note.txt]\n````\nuse ```fences```\n````")
        let binaryOnly = Attachments.prompt("", attachments: [third])
        XCTAssertTrue(binaryOnly.hasPrefix("[attached file: uploads/photo.bin, 4 bytes."), binaryOnly)
    }

    func testSessionsSavedBeforePromptLinksStillLoad() throws {
        let json = #"{"id":"5B0E1A62-7C2F-4E7B-9A53-1C0D6F2E8A11","kind":"user","text":"old prompt"}"#
        let item = try JSONDecoder().decode(TranscriptItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.text, "old prompt")
        XCTAssertNil(item.messageIndex)
        XCTAssertNil(item.attachments)
    }

    func testToolOutputArrivesInOrderBeforeTheResult() async throws {
        struct Chatty: RemoteShell {
            var label = "box"
            func run(command: String, timeout: TimeInterval, onOutput: @escaping @Sendable (String) -> Void) async throws -> Int {
                for n in 0..<200 { onOutput("\(n),") }
                return 0
            }
        }
        actor Log {
            var entries: [String] = []
            func add(_ entry: String) { entries.append(entry) }
        }
        let log = Log()
        let client = ScriptedClient([[.toolCallDelta(index: 0, id: "c1", name: "ssh_exec", arguments: "{\"command\":\"x\"}")], [.text("ok")]])
        try await Agent(client: client, tools: ToolBox(workspace: workspace, shell: Chatty())).run(
            request: ChatRequest(baseURL: "http://x", apiKey: "", model: "m", messages: []),
            approve: { _, _ in .allow },
            emit: { event in
                switch event {
                case .toolOutput(_, let chunk): await log.add(chunk)
                case .toolFinished: await log.add("END")
                default: break
                }
            })
        let entries = await log.entries
        XCTAssertEqual(entries, (0..<200).map { "\($0)," } + ["END"])
    }

    // MARK: Commands, storage

    func testCommandParsing() {
        XCTAssertEqual(Commands.parse("  "), .empty)
        XCTAssertEqual(Commands.parse("hello"), .prompt("hello"))
        XCTAssertEqual(Commands.parse("/model  gpt-x "), .command(name: "model", args: "gpt-x"))
        XCTAssertEqual(Commands.parse("/NEW"), .command(name: "new", args: ""))
        XCTAssertEqual(Commands.parse("/etc/hosts looks odd"), .prompt("/etc/hosts looks odd"))
        XCTAssertEqual(Commands.parse("! ls -la"), .shell("ls -la"))
        XCTAssertEqual(Commands.parse("!"), .empty)
        XCTAssertEqual(Commands.suggestions(for: "/se").map(\.name), ["setup", "sessions"])
        XCTAssertEqual(Commands.suggestions(for: "/model x"), [])
        XCTAssertEqual(Commands.suggestions(for: "hi"), [])
    }

    func testStorageRoundTrip() {
        let storage = Storage(directory: workspace)
        let profile = Profile(name: "p", baseURL: "https://x/v1", models: ["a", "b"])
        storage.saveProfiles([profile])
        storage.saveHosts([SSHHost(name: "h", host: "example.com", port: 2222, username: "u", auth: .privateKey)])
        var settings = AppSettings()
        settings.themeID = "crt-amber"
        settings.approvalMode = .auto
        storage.saveSettings(settings)

        // Whole-second dates: the store keeps ISO 8601 timestamps without fractions.
        let older = Session(title: "older", createdAt: Date(timeIntervalSince1970: 50), updatedAt: Date(timeIntervalSince1970: 100),
                            messages: [ChatMessage(role: .user, content: "1")])
        let newer = Session(title: "newer", createdAt: Date(timeIntervalSince1970: 60), updatedAt: Date(timeIntervalSince1970: 200), messages: [ChatMessage(role: .user, content: "2")],
                            transcript: [TranscriptItem(kind: .tool, text: "out", title: "ssh $ ls", status: .ok)])
        storage.saveSession(older)
        storage.saveSession(newer)
        storage.saveSession(Session())  // empty sessions are not persisted

        let reloaded = Storage(directory: workspace)
        XCTAssertEqual(reloaded.loadProfiles(), [profile])
        XCTAssertEqual(reloaded.loadHosts().first?.address, "u@example.com:2222")
        XCTAssertEqual(reloaded.loadSettings(), settings)
        XCTAssertEqual(reloaded.sessionSummaries().map(\.title), ["newer", "older"])
        XCTAssertEqual(reloaded.loadSession(id: newer.id), newer)
        reloaded.deleteSession(id: newer.id)
        XCTAssertEqual(reloaded.sessionSummaries().map(\.title), ["older"])
        XCTAssertEqual(Theme.named("nope"), .dark)
        XCTAssertEqual(Theme.all.map(\.id), ["dark", "light", "crt-green", "crt-amber"])
    }

    func testAuthSchemeAndCustomHeaders() throws {
        let referer = HeaderField(name: " HTTP-Referer ", value: " https://termai.example ")
        let headers = [
            referer, HeaderField(name: "", value: "x"), HeaderField(name: "Bad Name", value: "x"),
            HeaderField(name: "X-Line", value: "a\nb"), HeaderField(name: "Content-Type", value: "text/plain"),
        ]
        let request = ChatRequest(baseURL: "https://example.com/v1", apiKey: "k", model: "m", messages: [],
                                  authScheme: .apiKey, headers: headers)
        let chat = try OpenAIClient.urlRequest(for: request)
        XCTAssertEqual(chat.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertNil(chat.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(chat.value(forHTTPHeaderField: "HTTP-Referer"), "https://termai.example")
        XCTAssertNil(chat.value(forHTTPHeaderField: "Bad Name"))
        XCTAssertNil(chat.value(forHTTPHeaderField: "X-Line"))
        // A custom header cannot change what the request body is declared as.
        XCTAssertEqual(chat.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let models = try OpenAIClient.modelsRequest(baseURL: "https://example.com/v1/", apiKey: "k", authScheme: .bearer, headers: headers)
        XCTAssertEqual(models.url?.absoluteString, "https://example.com/v1/models")
        XCTAssertEqual(models.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        XCTAssertEqual(models.value(forHTTPHeaderField: "HTTP-Referer"), "https://termai.example")

        // Without a key nothing is added, so a gateway that wants its own Authorization header can have one.
        let own = try OpenAIClient.modelsRequest(baseURL: "https://example.com/v1", apiKey: "", authScheme: .bearer,
                                                 headers: [HeaderField(name: "Authorization", value: "Basic abc")])
        XCTAssertEqual(own.value(forHTTPHeaderField: "Authorization"), "Basic abc")

        // Headers are kept in the secret store as one string; unsendable rows are not kept.
        let kept = [HeaderField(name: "HTTP-Referer", value: "https://termai.example"), HeaderField(name: "Content-Type", value: "text/plain")]
        XCTAssertEqual(Headers.decode(Headers.encode(headers)), kept)
        XCTAssertNil(Headers.encode([HeaderField(name: " ", value: "x")]))
        XCTAssertEqual(Headers.decode(nil), [])
        XCTAssertEqual(Headers.decode("not json"), [])
    }

    func testProfilesSavedBeforeAuthSchemesStillLoad() throws {
        let id = UUID()
        let json = "{\"id\":\"\(id.uuidString)\",\"name\":\"p\",\"baseURL\":\"https://x/v1\",\"models\":[\"a\"]}"
        let old = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
        XCTAssertEqual(old, Profile(id: id, name: "p", baseURL: "https://x/v1", models: ["a"], authScheme: .bearer))

        let current = Profile(name: "q", baseURL: "https://y/v1", authScheme: .apiKey)
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: try JSONEncoder().encode(current)), current)
        XCTAssertEqual(current.headersKey, "profile.\(current.id.uuidString).headers")
        XCTAssertEqual(ApprovalMode.allCases.map(\.label), ["Manual", "Auto"])
    }

    func testWorkspaceFilesBrowsing() throws {
        let files = WorkspaceFiles(root: workspace)
        for (path, content) in ["notes/todo.md": "buy milk", "scripts/deploy.sh": "#!/bin/sh", "report.md": "héllo",
                                "nginx-app.conf": "server {}", ".hidden": "x"] {
            let url = workspace.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
        try Data([0x89, 0x50, 0x00, 0x01]).write(to: workspace.appendingPathComponent("scripts/logo.png"))

        // Folders first, then files, each by name; hidden files are not listed.
        let top = try files.list()
        XCTAssertEqual(top.map(\.path), ["notes", "scripts", "nginx-app.conf", "report.md"])
        XCTAssertEqual(top.map(\.isDirectory), [true, true, false, false])
        XCTAssertEqual(top[3].size, 6)

        let nested = try XCTUnwrap(try files.list("scripts/").first)
        XCTAssertEqual(nested.path, "scripts/deploy.sh")
        XCTAssertEqual([nested.name, nested.folder], ["deploy.sh", "scripts"])
        XCTAssertEqual([nested.depth, top[0].depth], [1, 0])

        XCTAssertEqual(files.search("TODO").map(\.path), ["notes/todo.md"])
        XCTAssertEqual(files.search("scripts").map(\.path), ["scripts/deploy.sh", "scripts/logo.png"])
        XCTAssertEqual(files.search(" "), [])

        XCTAssertEqual(try files.preview("report.md"), "héllo")
        // A preview cut in the middle of a character still reads as text.
        XCTAssertEqual(try files.preview("report.md", limit: 2), "h")
        XCTAssertNil(try files.preview("scripts/logo.png"))

        try files.delete("notes")
        XCTAssertEqual(try files.list().map(\.path), ["scripts", "nginx-app.conf", "report.md"])
        for path in ["", "../outside", "scripts/../.."] {
            XCTAssertThrowsError(try files.delete(path), path)
        }
        XCTAssertThrowsError(try files.list("../"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path))
    }

    func testSessionSearchRenameAndTitles() throws {
        let storage = Storage(directory: workspace)
        let keys = Session(title: "Rotate the deploy keys", updatedAt: Date(timeIntervalSince1970: 200),
                           messages: [ChatMessage(role: .user, content: "rotate")],
                           transcript: [
                               TranscriptItem(kind: .user, text: "rotate the deploy keys"),
                               TranscriptItem(kind: .info, text: "an ed25519 note that is not part of the conversation"),
                               TranscriptItem(kind: .assistant, text: "Generated a new\ned25519 key pair and installed it on web1."),
                           ])
        let disk = Session(title: "Disk usage report", updatedAt: Date(timeIntervalSince1970: 100),
                           messages: [ChatMessage(role: .user, content: "disk")],
                           transcript: [TranscriptItem(kind: .tool, text: "/dev/vda1  80G", title: "ssh db1 $ df -h /")])
        storage.saveSession(keys)
        storage.saveSession(disk)

        XCTAssertEqual(storage.searchSessions("").map(\.title), ["Rotate the deploy keys", "Disk usage report"])
        XCTAssertEqual(storage.searchSessions("DEPLOY"), [SessionMatch(id: keys.id, title: keys.title, updatedAt: keys.updatedAt)])
        XCTAssertEqual(storage.searchSessions("ED25519").map(\.snippet), ["Generated a new ed25519 key pair and installed it on web1."])
        XCTAssertEqual(storage.searchSessions("df -h").map(\.snippet), ["ssh db1 $ df -h /"])
        XCTAssertEqual(storage.searchSessions("nothing like this"), [])

        let long = String(repeating: "a ", count: 60) + "needle" + String(repeating: " b", count: 60)
        let snippet = try XCTUnwrap(Storage.snippet(of: long, around: "NEEDLE"))
        XCTAssertTrue(snippet.hasPrefix("…") && snippet.hasSuffix("…") && snippet.contains("a needle b"), snippet)
        XCTAssertLessThan(snippet.count, 130)

        storage.renameSession(id: disk.id, title: "db1 disk")
        XCTAssertEqual(storage.sessionSummaries(), [
            SessionSummary(id: keys.id, title: "Rotate the deploy keys", updatedAt: keys.updatedAt),
            SessionSummary(id: disk.id, title: "db1 disk", updatedAt: disk.updatedAt),
        ])

        XCTAssertEqual(Session.title(from: "why is nginx down on web1?"), "Why is nginx down on web1?")
        XCTAssertEqual(Session.title(from: "\n   second line is first\nmore"), "Second line is first")
        XCTAssertEqual(Session.title(from: "  \n"), "New session")
        XCTAssertEqual(Session().title, "New session")
        let cut = Session.title(from: String(repeating: "word ", count: 30))
        XCTAssertTrue(cut.hasSuffix("d…") && cut.count <= 60, cut)
    }

    func testConsoleLogAndRelativeTime() {
        var log = ConsoleLog()
        log.note("connecting")
        log.command("uptime")
        log.output("up ")
        log.output("41 days\n")
        log.output("")
        log.command("uptime")
        log.error("boom")
        log.output("late")
        XCTAssertEqual(log.entries.map(\.kind), [.note, .command, .output, .command, .error, .output])
        XCTAssertEqual(log.entries[2].text, "up 41 days\n")

        // A chatty command keeps its tail, not everything it ever printed.
        log.output(String(repeating: "x", count: 30_000) + "END")
        XCTAssertLessThanOrEqual(log.entries.last?.text.count ?? 0, 24_000)
        XCTAssertEqual(log.entries.last?.text.hasSuffix("END"), true)

        log.clear()
        XCTAssertEqual(log.entries, [])

        let now = Date(timeIntervalSince1970: 1_000_000)
        let ago = [0: "now", 1: "1 sec. ago", 90: "1 min. ago", 3 * 3_600: "3 hr. ago", 30 * 3_600: "yesterday",
                   4 * 86_400: "4 days ago", 15 * 86_400: "2 wk. ago", 70 * 86_400: "2 mo. ago", 800 * 86_400: "2 yr. ago"]
        for (seconds, label) in ago {
            XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-Double(seconds)), now: now), label)
        }
        // A clock that moved backwards must not produce a negative age.
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(50), now: now), "now")
    }

    func testMarkdownBlocks() {
        typealias Line = Markdown.Line
        XCTAssertEqual(Markdown.blocks("Intro line\nsecond line\n\n# Steps\n- one\n- two\n\n> q1\n> q2\n1. first\n\n\nEnd"), [
            Line(kind: .text, text: "Intro line\nsecond line"),
            Line(kind: .heading, text: "Steps"),
            Line(kind: .bullet, text: "one", marker: "•"),
            Line(kind: .bullet, text: "two", marker: "•"),
            Line(kind: .quote, text: "q1\nq2"),
            Line(kind: .numbered, text: "first", marker: "1."),
            Line(kind: .text, text: "End"),
        ])
        XCTAssertEqual(Markdown.blocks(" \n\n"), [])
    }

    // MARK: Live HTTP (needs a mock server; see Tests/mock_server.py)

    func testLiveStreamingAgainstMockServer() async throws {
        guard let base = ProcessInfo.processInfo.environment["TERMAI_TEST_BASEURL"] else {
            throw XCTSkip("set TERMAI_TEST_BASEURL to run")
        }
        let client = OpenAIClient()
        let models = try await client.listModels(baseURL: base, apiKey: "test-key")
        XCTAssertEqual(models, ["mock-a", "mock-b"])

        let recorder = Recorder()
        let agent = Agent(client: client, tools: ToolBox(workspace: workspace, shell: FakeShell()))
        try await agent.run(
            request: ChatRequest(baseURL: base, apiKey: "test-key", model: "mock-a", messages: [ChatMessage(role: .user, content: "go")]),
            approve: { _, _ in .allow }, emit: { await recorder.record($0) })
        let messages = await recorder.messages
        XCTAssertEqual(messages.map(\.role), [.assistant, .tool, .assistant])
        XCTAssertEqual(messages[1].content, "ran: echo hi\n\n[exit 0]")
        XCTAssertEqual(messages[2].content, "héllo ✓ done")

        do {
            for try await _ in client.streamChat(ChatRequest(baseURL: base, apiKey: "wrong", model: "m", messages: [])) {}
            XCTFail("expected 401")
        } catch {
            XCTAssertEqual(error as? APIError, APIError(status: 401, message: "bad key"))
        }
    }
}
