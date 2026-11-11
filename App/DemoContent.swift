import Foundation
import TermCore

/// Sample content for `-demo` launches: the CI screenshots and the UI tests.
enum DemoContent {
    static let prompt = "why is nginx down on web1?"
    static let statusCommand = "systemctl status nginx --no-pager"
    static let fixCommand = "sudo sed -i 's/servr_name/server_name/' /etc/nginx/sites-enabled/app && sudo nginx -t && sudo systemctl reload nginx"

    static let diagnosis = "There is a **typo** in the site config, line 4:\n\n```nginx\nservr_name example.com;\n```\n\nIt should be `server_name`. I can fix it and reload:"
    static let resolution = "Fixed. nginx is serving again.\n\n- Config test passed\n- Service reloaded without dropping connections"

    static let files: [String: String] = [
        "notes/todo.md": "- rotate the deploy keys\n- renew the TLS cert on web2\n",
        "scripts/backup.sh": "#!/bin/sh\ntar czf /tmp/etc.tgz /etc\n",
        "nginx-app.conf": "server {\n    listen 80;\n    server_name example.com;\n    root /var/www/app;\n}\n",
        "report.md": "# Disk usage\n\n/dev/vda1  80G  31G  46G  41% /\n",
    ]

    static let auditSteps: [(command: String, output: String, ok: Bool)] = [
        ("uptime", " 15:02:11 up 41 days,  3:17,  1 user,  load average: 0.08, 0.03, 0.01\n", true),
        ("df -h /", "Filesystem      Size  Used Avail Use% Mounted on\n/dev/vda1        80G   31G   46G  41% /\n", true),
        ("free -m", "               total        used        free\nMem:            7941        2210        3120\n", true),
        ("sudo nginx -t", "nginx: configuration file /etc/nginx/nginx.conf test is successful\n", true),
        ("curl -sI https://example.com | head -1", "HTTP/2 200\n", true),
        ("systemctl --failed --no-legend", "certbot.service loaded failed failed Certbot renewal\n[exit 1]", false),
        ("ss -ltn | wc -l", "9\n", true),
    ]

    static let auditAnswer = "web1 is healthy apart from one failed unit. Before the release, run:\n\n```sh\nsudo systemctl restart certbot\nsudo certbot renew --dry-run\nsudo systemctl reload nginx\n```\n\n1. Disk and memory have room\n2. nginx config is valid and serving\n3. **certbot** renewal failed and needs a rerun"
}

/// Stands in for an SSH host in demo mode.
struct DemoShell: RemoteShell {
    var label = "web1"

    static func output(for command: String) -> (text: String, code: Int) {
        if command.hasPrefix("systemctl status") {
            return ("× nginx.service - A high performance web server\n     Active: failed (Result: exit-code)\nnginx: [emerg] unknown directive \"servr_name\"\n  in /etc/nginx/sites-enabled/app:4\n", 3)
        }
        if command.contains("nginx -t") {
            return ("nginx: configuration file /etc/nginx/nginx.conf test is successful\n", 0)
        }
        if command == "uptime" {
            return (" 15:02:11 up 41 days,  3:17,  1 user,  load average: 0.08, 0.03, 0.01\n", 0)
        }
        if command.hasPrefix("df") {
            return ("Filesystem      Size  Used Avail Use% Mounted on\n/dev/vda1        80G   31G   46G  41% /\n", 0)
        }
        if command == "false" { return ("", 1) }
        return ("demo host: \(command)\n", 0)
    }

    func run(command: String, timeout: TimeInterval, onOutput: @escaping @Sendable (String) -> Void) async throws -> Int {
        let result = Self.output(for: command)
        // Arrive line by line, the way a real command does.
        for line in result.text.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
            try await Task.sleep(for: .milliseconds(120))
            onOutput(String(line) + "\n")
        }
        return result.code
    }
}

/// Stands in for the model in demo mode: diagnoses the sample nginx problem in two tool calls, then answers.
struct DemoClient: ChatStreaming {
    func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let lastPrompt = request.messages.lastIndex { $0.role == .user } ?? 0
        let toolResults = request.messages[lastPrompt...].filter { $0.role == .tool }.count
        let events: [StreamEvent]
        switch toolResults {
        case 0:
            events = Self.words("Checking the service state first.") + [Self.call(DemoContent.statusCommand)]
        case 1:
            events = Self.words(DemoContent.diagnosis) + [Self.call(DemoContent.fixCommand)]
        default:
            events = Self.words(DemoContent.resolution) + [.usage(input: 2_400, output: 312)]
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                for event in events {
                    try? await Task.sleep(for: .milliseconds(25))
                    if Task.isCancelled { break }
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func words(_ text: String) -> [StreamEvent] {
        text.split(separator: " ", omittingEmptySubsequences: false).enumerated().map { index, word -> StreamEvent in
            StreamEvent.text((index == 0 ? "" : " ") + String(word))
        }
    }

    private static func call(_ command: String) -> StreamEvent {
        let arguments = (try? JSONSerialization.data(withJSONObject: ["command": command])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return .toolCallDelta(index: 0, id: "demo-\(UUID().uuidString.prefix(8))", name: "ssh_exec", arguments: arguments)
    }
}
