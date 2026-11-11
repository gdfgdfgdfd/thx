import SwiftUI
import TermCore
import UIKit

/// New rows fade in while sliding up a little.
private let rowTransition = AnyTransition.asymmetric(
    insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity)

struct TranscriptView: View {
    @Environment(AppModel.self) private var model
    /// Heights of the bars floating over the conversation.
    let topInset: CGFloat
    let bottomInset: CGFloat

    var body: some View {
        let palette = model.palette
        let groups = Transcript.groups(model.session.transcript)
        let lastPromptID = model.lastPromptID

        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(groups) { group in
                            row(group, palette: palette, lastPromptID: lastPromptID)
                                .transition(rowTransition)
                        }
                        footer(palette: palette, lastPromptID: lastPromptID)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, Metrics.margin)
                    .padding(.top, topInset + 4)
                    .padding(.bottom, bottomInset + 8)
                    // A short conversation starts at the top rather than hugging the message box.
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
        // A different session is a different scroll view: it opens at its own latest message.
        .id(model.session.id)
    }

    @ViewBuilder
    private func row(_ group: TranscriptGroup, palette: Palette, lastPromptID: UUID?) -> some View {
        if group.isActivity {
            ActivityList(group: group, palette: palette)
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
                Text(item.text)
                    .font(palette.mono)
                    .foregroundStyle(palette.dim)
                    .textSelection(.enabled)
            case .error:
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12))
                    Text(item.text).font(palette.mono).textSelection(.enabled)
                }
                .foregroundStyle(palette.error)
            }
        }
    }

    /// The run status while the agent works; afterwards copy and retry for the last exchange, and what it cost.
    @ViewBuilder
    private func footer(palette: Palette, lastPromptID: UUID?) -> some View {
        if model.isRunning {
            if model.pendingApproval == nil {
                WorkingIndicator(since: model.runStartedAt, palette: palette)
                    .transition(.opacity)
            }
        } else if model.lastAnswer != nil || lastPromptID != nil || model.usageLine != nil {
            HStack(spacing: 2) {
                if let answer = model.lastAnswer {
                    CopyButton(text: answer, palette: palette, iconSize: 17)
                        .accessibilityIdentifier("copy-answer")
                }
                if lastPromptID != nil {
                    IconButton(systemName: "arrow.clockwise", label: "Retry", palette: palette, iconSize: 17) {
                        model.retryLast()
                    }
                    .accessibilityIdentifier("retry-last")
                }
                if let usage = model.usageLine {
                    Text(usage)
                        .font(palette.caption)
                        .foregroundStyle(palette.dim)
                        .padding(.leading, 8)
                }
                Spacer(minLength: 0)
            }
            // The buttons carry their own padding; pull them back to the text margin.
            .padding(.leading, -8)
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
                    Text(item.text).font(palette.prose).foregroundStyle(palette.text)
                }
                if let files = item.attachments, !files.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(files, id: \.self) { path in
                            Label((path as NSString).lastPathComponent, systemImage: "doc")
                                .font(palette.caption)
                                .foregroundStyle(palette.dim)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(palette.surface, in: shape)
            .overlay { shape.stroke(isEditing ? palette.accent : Color.clear, lineWidth: 1) }
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
                IconButton(systemName: "pencil", label: "Edit message", palette: palette) {
                    model.beginEditing(item.id)
                }
                .accessibilityIdentifier("edit-last-prompt")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }
}

// MARK: Reply

private struct ReplyView: View {
    let text: String
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(Markdown.segments(text).enumerated()), id: \.offset) { _, segment in
                if segment.isCode {
                    CodeBlock(code: segment.text, language: segment.language, palette: palette)
                } else {
                    ProseView(text: segment.text, palette: palette)
                }
            }
        }
    }
}

/// Prose laid out block by block, so list items hang under their marker and paragraphs keep their spacing.
private struct ProseView: View {
    let text: String
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(Markdown.blocks(text).enumerated()), id: \.offset) { _, block in
                BlockView(block: block, palette: palette)
            }
        }
    }
}

private struct BlockView: View {
    let block: Markdown.Line
    let palette: Palette

    var body: some View {
        switch block.kind {
        case .text:
            paragraph(palette.text)
        case .heading:
            Text(RichText.inline(block.text, palette: palette))
                .font(palette.heading)
                .foregroundStyle(palette.text)
                .textSelection(.enabled)
                .padding(.top, 4)
        case .bullet, .numbered:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(block.marker)
                    .font(palette.prose)
                    .foregroundStyle(palette.dim)
                    .monospacedDigit()
                paragraph(palette.text)
            }
            .padding(.leading, CGFloat(block.indent) * 18 + 2)
        case .quote:
            paragraph(palette.dim)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(palette.border).frame(width: 3)
                }
        case .rule:
            Rectangle().fill(palette.border).frame(height: 1).padding(.vertical, 4)
        }
    }

    private func paragraph(_ color: Color) -> some View {
        Text(RichText.inline(block.text, palette: palette))
            .font(palette.prose)
            .foregroundStyle(color)
            .lineSpacing(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum RichText {
    /// Inline Markdown: bold, italics, links and code. Code is set in the accent colour and a monospaced face.
    static func inline(_ text: String, palette: Palette) -> AttributedString {
        // Most text carries no markup; skipping the parser for it keeps streaming cheap.
        guard text.contains(where: { "*_`[~".contains($0) }),
              var parsed = try? AttributedString(
                markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(text)
        }
        let code = parsed.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }.map(\.range)
        for range in code {
            parsed[range].swiftUI.foregroundColor = palette.accent
            parsed[range].swiftUI.font = palette.monoInline
        }
        return parsed
    }
}

/// A fenced block with its own copy button, so a command or a list can be taken in one tap.
private struct CodeBlock: View {
    let code: String
    let language: String?
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(language ?? "text").font(palette.caption).foregroundStyle(palette.dim)
                Spacer(minLength: 8)
                CopyButton(text: code, palette: palette, label: "Copy", iconSize: 14)
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.top, 2)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(palette.mono)
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(palette)
    }
}

// MARK: Tool activity

/// Consecutive tool calls as one compact list: a line per call, output folded away until tapped.
/// A long list shows its newest steps and folds the rest behind its header.
private struct ActivityList: View {
    @Environment(AppModel.self) private var model
    let group: TranscriptGroup
    let palette: Palette

    private static let foldAbove = 5
    private static let shownWhenFolded = 3

    var body: some View {
        let items = group.items
        let isLong = items.count > Self.foldAbove
        let isFolded = isLong && !model.expandedGroups.contains(group.id)
        let visible = isFolded ? Array(items.suffix(Self.shownWhenFolded)) : items

        VStack(alignment: .leading, spacing: 0) {
            if isLong {
                header(items: items, isFolded: isFolded)
                separator(inset: 0)
            }
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                if index > 0 { separator(inset: 39) }
                ToolRow(item: item, palette: palette, isExpanded: model.expandedTools.contains(item.id)) {
                    withAnimation(.snappy(duration: 0.25)) { model.toggleTool(item.id) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(palette)
    }

    private func separator(inset: CGFloat) -> some View {
        Rectangle().fill(palette.border).frame(height: 1).padding(.leading, inset)
    }

    private func header(items: [TranscriptItem], isFolded: Bool) -> some View {
        let failed = items.filter { $0.status == .failed }.count
        let summary = "\(items.count) steps" + (failed > 0 ? " · \(failed) failed" : "")

        return Button {
            withAnimation(.snappy(duration: 0.25)) { model.toggleGroup(group.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet").font(.system(size: 13)).foregroundStyle(palette.dim)
                Text(summary).font(palette.caption).foregroundStyle(palette.dim)
                Spacer(minLength: 8)
                Text(isFolded ? "Show all" : "Show less").font(palette.caption).foregroundStyle(palette.accent)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tool-group-toggle")
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
                HStack(alignment: .top, spacing: 10) {
                    StatusGlyph(status: item.status, palette: palette)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title ?? "tool")
                            .foregroundStyle(palette.text)
                            .lineLimit(isExpanded ? nil : 1)
                            .multilineTextAlignment(.leading)
                        if !isExpanded, let preview = Transcript.preview(item.text) {
                            HStack(spacing: 6) {
                                Text(preview).lineLimit(1)
                                if lines > 1 {
                                    Text("+\(lines - 1)").fixedSize()
                                }
                            }
                            .foregroundStyle(palette.dim)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.dim)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .padding(.top, 3)
                }
                .font(palette.mono)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tool-row")
            .accessibilityHint(isExpanded ? "Hides the output" : "Shows the output")

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    if item.text.isEmpty {
                        Text("no output").font(palette.mono).foregroundStyle(palette.dim)
                    } else {
                        Text(Transcript.tail(item.text))
                            .font(palette.mono)
                            .foregroundStyle(palette.dim)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("tool-output")
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            CopyButton(text: item.text, palette: palette, label: "Copy output")
                        }
                    }
                }
                .padding(.leading, 39)
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
                ProgressView().controlSize(.small).tint(palette.accent)
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
        .font(.system(size: 16))
        .frame(width: 17, height: 17)
        .animation(.snappy(duration: 0.25), value: status)
    }
}

// MARK: Run status

private struct WorkingIndicator: View {
    let since: Date
    let palette: Palette
    @State private var isSpinning = false

    var body: some View {
        HStack(spacing: 10) {
            SparkMark(size: 18, color: palette.accent)
                .rotationEffect(.degrees(isSpinning ? 360 : 0))
                .animation(.linear(duration: 2.4).repeatForever(autoreverses: false), value: isSpinning)
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text("Working · \(max(0, Int(context.date.timeIntervalSince(since))))s")
                    .font(palette.caption)
                    .foregroundStyle(palette.dim)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
        .onAppear { isSpinning = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Working")
    }
}
