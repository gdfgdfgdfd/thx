import SwiftUI
import TermCore
import UIKit

/// Panels above and below the input slide up from the bottom edge.
private let riseTransition = AnyTransition.move(edge: .bottom).combined(with: .opacity)

/// The floating input area: approval or command suggestions on top, then the message field, then the key row.
struct Composer: View {
    @Environment(AppModel.self) private var model
    var inputFocused: FocusState<Bool>.Binding

    var body: some View {
        @Bindable var model = model
        let palette = model.palette
        let showsKeys = inputFocused.wrappedValue || model.demoShowsKeys

        VStack(spacing: 8) {
            if let approval = model.pendingApproval {
                ApprovalCard(approval: approval, palette: palette)
                    .transition(riseTransition)
            } else if !model.suggestions.isEmpty {
                SuggestionList(palette: palette)
                    .transition(riseTransition)
            }

            VStack(alignment: .leading, spacing: 8) {
                if model.editingItemID != nil {
                    EditingBanner(palette: palette)
                        .transition(.opacity)
                }
                if !model.pendingAttachments.isEmpty {
                    AttachmentStrip(palette: palette)
                        .transition(.opacity)
                }
                HStack(alignment: .bottom, spacing: 6) {
                    leadingControl(palette: palette)
                    Group {
                        if model.inputIsSecret {
                            SecureField("", text: $model.input, prompt: Text(model.placeholder).foregroundStyle(palette.dim))
                        } else {
                            TextField("", text: $model.input, prompt: Text(model.placeholder).foregroundStyle(palette.dim), axis: .vertical)
                                .lineLimit(1...6)
                        }
                    }
                    .font(palette.font)
                    .foregroundStyle(palette.text)
                    .tint(palette.accent)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .focused(inputFocused)
                    .onSubmit(send)
                    .padding(.vertical, 8)

                    SendButton(palette: palette, send: send)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .glass(in: RoundedRectangle(cornerRadius: Metrics.composerRadius, style: .continuous))

            if showsKeys {
                KeyRow(palette: palette, hideKeyboard: { inputFocused.wrappedValue = false })
                    .transition(riseTransition)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 8)
        // Fades the transcript out underneath, so nothing shows through around the home indicator.
        .background {
            LinearGradient(
                stops: [
                    .init(color: palette.background.opacity(0), location: 0),
                    .init(color: palette.background.opacity(0.85), location: 0.45),
                    .init(color: palette.background, location: 1),
                ],
                startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
        .animation(.snappy(duration: 0.25), value: model.pendingApproval)
        .animation(.snappy(duration: 0.25), value: model.suggestions.count)
        .animation(.snappy(duration: 0.25), value: model.pendingAttachments)
        .animation(.snappy(duration: 0.25), value: model.editingItemID)
        .animation(.snappy(duration: 0.25), value: showsKeys)
    }

    /// The files button; the setup wizard shows its question mark there instead.
    @ViewBuilder
    private func leadingControl(palette: Palette) -> some View {
        if model.setup != nil {
            Text("?").font(palette.bold).foregroundStyle(palette.accent)
                .frame(width: 34, height: 34)
        } else {
            Button {
                model.showFilePicker = true
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(palette.dim)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.pendingApproval != nil)
            .accessibilityLabel("Attach files")
        }
    }

    private func send() {
        model.submit()
        // Submitting drops focus; keep the keyboard up like a terminal would.
        DispatchQueue.main.async { inputFocused.wrappedValue = true }
    }
}

/// Sends the input, or stops the run when there is nothing typed.
private struct SendButton: View {
    @Environment(AppModel.self) private var model
    let palette: Palette
    let send: () -> Void

    var body: some View {
        let hasInput = !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let stops = model.isRunning && model.pendingApproval == nil && !hasInput
        let isEnabled = stops || hasInput || model.setup != nil || !model.pendingAttachments.isEmpty

        Button {
            if stops {
                model.cancel()
            } else {
                send()
            }
        } label: {
            Image(systemName: stops ? "stop.fill" : "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(palette.background)
                .frame(width: 34, height: 34)
                .background(stops ? palette.error : (isEnabled ? palette.accent : palette.dim.opacity(0.45)), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .animation(.snappy(duration: 0.2), value: isEnabled)
        .animation(.snappy(duration: 0.2), value: stops)
        .accessibilityLabel(stops ? "Stop" : "Send")
    }
}

private struct EditingBanner: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil").foregroundStyle(palette.accent)
            Text("editing · sending replaces the message and its replies")
                .foregroundStyle(palette.dim)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button {
                model.cancelEditing()
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(palette.dim)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel editing")
        }
        .font(palette.small)
        .padding(.leading, 8)
        .padding(.top, 2)
    }
}

private struct AttachmentStrip: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.pendingAttachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: attachment.text == nil ? "doc" : "doc.text")
                        Text(attachment.name).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                            .foregroundStyle(palette.dim)
                        Button {
                            model.removeAttachment(attachment.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(palette.dim)
                                .frame(width: 22, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(attachment.name)")
                    }
                    .font(palette.small)
                    .foregroundStyle(palette.text)
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .frame(height: 30)
                    .background(palette.bubble, in: Capsule())
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(.top, 2)
    }
}

private struct KeyRow: View {
    @Environment(AppModel.self) private var model
    let palette: Palette
    let hideKeyboard: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                key("esc") { model.escape() }
                key("/") { model.input += "/" }
                key("!") { model.input += "!" }
                key("↑") { model.historyUp() }
                key("↓") { model.historyDown() }
                key("tab") { model.completeSuggestion() }
                key("^C", tint: model.isRunning ? palette.error : nil) { model.cancel() }
                key("paste") {
                    if let text = UIPasteboard.general.string { model.input += text }
                }
                key("⌄", action: hideKeyboard)
            }
            .padding(.horizontal, 6)
        }
        .frame(height: Metrics.barHeight)
        .clipShape(Capsule())
        .glass(in: Capsule())
    }

    private func key(_ label: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(palette.small)
                .foregroundStyle(tint ?? palette.text)
                .padding(.horizontal, 12)
                .frame(minWidth: 40, minHeight: Metrics.barHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SuggestionList: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.suggestions.prefix(6), id: \.name) { command in
                Button {
                    model.input = "/\(command.name) "
                } label: {
                    HStack(spacing: 10) {
                        Text("/\(command.name)").foregroundStyle(palette.accent)
                        Text(command.help).foregroundStyle(palette.dim).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(palette.small)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .glass(in: RoundedRectangle(cornerRadius: Metrics.bubbleRadius, style: .continuous))
    }
}

private struct ApprovalCard: View {
    @Environment(AppModel.self) private var model
    let approval: PendingApproval
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("run this?").font(palette.small).foregroundStyle(palette.accent)
            Text(approval.summary).font(palette.small).foregroundStyle(palette.text).lineLimit(6)
            HStack(spacing: 8) {
                choice("[y] yes", palette.success) { model.resolveApproval(.allow) }
                choice("[n] no", palette.error) { model.resolveApproval(.deny) }
                choice("[a] always", palette.dim) { model.allowAlways() }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(in: RoundedRectangle(cornerRadius: Metrics.bubbleRadius, style: .continuous))
    }

    private func choice(_ label: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(palette.small).foregroundStyle(color)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(color.opacity(0.14), in: Capsule())
                .overlay { Capsule().stroke(color.opacity(0.5), lineWidth: 0.5) }
        }
        .buttonStyle(.plain)
    }
}
