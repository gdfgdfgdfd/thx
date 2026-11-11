import SwiftUI
import TermCore
import UIKit

/// New rows fade in while sliding up a little.
private let rowTransition = AnyTransition.asymmetric(
    insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity)

struct TranscriptView: View {
    @Environment(AppModel.self) private var model
    /// Heights of the bars floating over the transcript.
    let topInset: CGFloat
    let bottomInset: CGFloat

    var body: some View {
        let palette = model.palette
        let groups = Transcript.groups(model.session.transcript)
        let lastPromptID = model.lastPromptID

        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(groups) { group in
                            row(group, palette: palette, lastPromptID: lastPromptID)
                                .transition(rowTransition)
                        }
                        footer(palette: palette, lastPromptID: lastPromptID)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, topInset + 4)
                    .padding(.bottom, bottomInset + 6)
                    // A short transcript starts at the top, like a fresh terminal, rather than hugging the input.
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
                    .shadow(color: model.theme.glow ? palette.text.opacity(0.55) : .clear, radius: 3)
                    .animation(.snappy(duration: 0.3), value: groups.count)
                }
                // Stay pinned to the newest output while it streams, unless the user scrolls up.
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.scrollTick) {
                    withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ group: TranscriptGroup, palette: Palette, lastPromptID: UUID?) -> some View {
        if group.isActivity {
            ActivityList(items: group.items, palette: palette)
        } else {
            let item = group.items[0]
            switch item.kind {
            case .user:
                PromptBubble(item: item, palette: palette, canRewind: model.canRewind(item),
                             isLastPrompt: item.id == lastPromptID)
            case .assistant:
                ReplyView(text: item.text, palette: palette)
            case .tool:
                EmptyView()
            case .info:
                Text(item.text).font(palette.font).foregroundStyle(palette.dim).textSelection(.enabled)
            case .error:
                Text(item.text).font(palette.font).foregroundStyle(palette.error).textSelection(.enabled)
            }
        }
    }

    /// Run status while the agent works; afterwards the usage line with copy and retry for the last exchange.
    @ViewBuilder
    private func footer(palette: Palette, lastPromptID: UUID?) -> some View {
        if model.isRunning {
            if model.pendingApproval == nil {
                WorkingIndicator(since: model.runStartedAt, palette: palette)
                    .transition(.opacity)
            }
        } else {
            let answer = model.session.transcript.last.flatMap { $0.kind == .assistant ? $0.text : nil }
            if model.usageLine != nil || answer != nil || lastPromptID != nil {
                HStack(spacing: 0) {
                    if let usage = model.usageLine {
                        Text(usage).font(palette.small).foregroundStyle(palette.dim)
                    }
                    Spacer(minLength: 8)
                    if let answer {
                        CopyButton(text: answer, palette: palette)
                    }
                    if lastPromptID != nil {
                        IconButton(systemName: "arrow.clockwise", label: "Retry", palette: palette) { model.retryLast() }
                    }
                }
            }
        }
    }
}

// MARK: Prompt

private struct PromptBubble: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptItem
    let palette: Palette
    let canRewind: Bool
    let isLastPrompt: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.bubbleRadius, style: .continuous)
        let isEditing = model.editingItemID == item.id

        VStack(alignment: .trailing, spacing: 2) {
            VStack(alignment: .leading, spacing: 8) {
                if !item.text.isEmpty {
                    Text(item.text).font(palette.font).foregroundStyle(palette.text)
                }
                if let files = item.attachments, !files.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(files, id: \.self) { path in
                            Label((path as NSString).lastPathComponent, systemImage: "doc")
                                .font(palette.small)
                                .foregroundStyle(palette.dim)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(palette.bubble, in: shape)
            .overlay { shape.stroke(isEditing ? palette.accent : .clear, lineWidth: 1) }
            .contentShape(.contextMenuPreview, shape)
            .contextMenu {
                Button {
                    UIPasteboard.general.string = item.text
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                if canRewind {
                    Button {
                        model.beginEditing(item.id)
                    } label: {
                        Label("Edit and resend", systemImage: "pencil")
                    }
                    Button {
                        model.resend(item.id)
                    } label: {
                        Label("Resend", systemImage: "arrow.clockwise")
                    }
                }
            }

            if canRewind, isLastPrompt, !model.isRunning, !isEditing {
                IconButton(systemName: "pencil", label: "Edit and resend", palette: palette) {
                    model.beginEditing(item.id)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 44)
    }
}

// MARK: Reply

private struct ReplyView: View {
    let text: String
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Markdown.segments(text).enumerated()), id: \.offset) { _, segment in
                if segment.isCode {
                    CodeBlock(code: segment.text, language: segment.language, palette: palette)
                } else {
                    Text(RichText.render(segment.text, palette: palette))
                        .font(palette.font)
                        .foregroundStyle(palette.text)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// A fenced block with its own copy button, so a command or list can be taken in one tap.
private struct CodeBlock: View {
    let code: String
    let language: String?
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(language ?? "text").font(palette.small).foregroundStyle(palette.dim)
                Spacer(minLength: 8)
                CopyButton(text: code, palette: palette, label: "Copy")
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .background(palette.text.opacity(0.05))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(palette.font).foregroundStyle(palette.text).textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(palette)
    }
}

enum RichText {
    /// Prose with the Markdown the model is told it may use: headings, lists, quotes, bold and inline code.
    static func render(_ prose: String, palette: Palette) -> AttributedString {
        var result = AttributedString()
        for (index, line) in Markdown.lines(prose).enumerated() {
            if index > 0 { result += AttributedString("\n") }
            var prefix = String(repeating: "  ", count: line.indent)
            var body = inline(line.text, palette: palette)
            switch line.kind {
            case .text:
                break
            case .heading:
                body.swiftUI.font = palette.bold
            case .bullet, .numbered:
                prefix += line.marker + " "
            case .quote:
                prefix += "▎ "
                body.swiftUI.foregroundColor = palette.dim
            case .rule:
                body = AttributedString("────────────")
                body.swiftUI.foregroundColor = palette.dim
            }
            if !prefix.isEmpty {
                var marker = AttributedString(prefix)
                marker.swiftUI.foregroundColor = palette.dim
                result += marker
            }
            result += body
        }
        return result
    }

    private static func inline(_ text: String, palette: Palette) -> AttributedString {
        // Most lines carry no markup; skipping the parser for them keeps streaming cheap.
        guard text.contains(where: { "*_`[~".contains($0) }),
              var parsed = try? AttributedString(
                markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(text)
        }
        let code = parsed.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }.map(\.range)
        for range in code { parsed[range].swiftUI.foregroundColor = palette.accent }
        return parsed
    }
}

// MARK: Tool activity

/// Consecutive tool calls as one compact list: a line per call, output folded away until tapped.
private struct ActivityList: View {
    @Environment(AppModel.self) private var model
    let items: [TranscriptItem]
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle().fill(palette.edge).frame(height: 0.5).padding(.leading, 36)
                }
                ToolRow(item: item, palette: palette, isExpanded: model.expandedTools.contains(item.id)) {
                    withAnimation(.snappy(duration: 0.25)) { model.toggleTool(item.id) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(palette)
    }
}

private struct ToolRow: View {
    let item: TranscriptItem
    let palette: Palette
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        let lines = Transcript.lineCount(item.text)

        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 8) {
                    StatusGlyph(status: item.status, palette: palette)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title ?? "tool")
                            .foregroundStyle(palette.text.opacity(0.9))
                            .lineLimit(isExpanded ? nil : 1)
                            .multilineTextAlignment(.leading)
                        if !isExpanded, let preview = Transcript.preview(item.text) {
                            HStack(spacing: 6) {
                                Text("⎿ \(preview)").lineLimit(1)
                                if lines > 1 {
                                    Text("+\(lines - 1)").fixedSize()
                                }
                            }
                            .foregroundStyle(palette.dim)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.dim)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .padding(.top, 3)
                }
                .font(palette.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Hides the output" : "Shows the output")

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    if item.text.isEmpty {
                        Text("no output").font(palette.small).foregroundStyle(palette.dim)
                    } else {
                        Text(Transcript.tail(item.text))
                            .font(palette.small)
                            .foregroundStyle(palette.dim)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            CopyButton(text: item.text, palette: palette, label: "Copy output")
                        }
                    }
                }
                .padding(.leading, 36)
                .padding(.trailing, 8)
                .padding(.bottom, 8)
                .transition(.opacity)
            }
        }
    }
}

private struct StatusGlyph: View {
    let status: TranscriptItem.Status?
    let palette: Palette

    var body: some View {
        Group {
            switch status {
            case .running:
                ProgressView().controlSize(.small).scaleEffect(0.7).tint(palette.accent)
            case .ok:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.success)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(palette.error)
            case .denied:
                Image(systemName: "slash.circle").foregroundStyle(palette.dim)
            case nil:
                Image(systemName: "circle").foregroundStyle(palette.dim)
            }
        }
        .font(.system(size: 13))
        .frame(width: 16, height: 16)
        .transition(AnyTransition.scale(scale: 0.6).combined(with: .opacity))
        .animation(.snappy(duration: 0.25), value: status)
    }
}

// MARK: Run status

private struct WorkingIndicator: View {
    let since: Date
    let palette: Palette

    var body: some View {
        HStack(spacing: 8) {
            PulsingDots(color: palette.accent)
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text("working · \(max(0, Int(context.date.timeIntervalSince(since))))s")
                    .font(palette.small)
                    .foregroundStyle(palette.dim)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
        .accessibilityLabel("Working")
    }
}

private struct PulsingDots: View {
    let color: Color
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
                    .opacity(isAnimating ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(index) * 0.2), value: isAnimating)
            }
        }
        .onAppear { isAnimating = true }
    }
}
