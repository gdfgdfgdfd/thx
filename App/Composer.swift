import SwiftUI
import TermCore
import UIKit

/// Panels above and below the message box slide up from the bottom edge.
private let riseTransition = AnyTransition.move(edge: .bottom).combined(with: .opacity)

/// The floating input area: an approval request or command suggestions on top, the message box, and under it
/// either the host and permission switches or, while typing, a row of keys the iOS keyboard lacks.
struct Composer: View {
    @Environment(AppModel.self) private var model
    var inputFocused: FocusState<Bool>.Binding

    var body: some View {
        let palette = model.palette
        let showsKeys = inputFocused.wrappedValue

        VStack(spacing: 8) {
            if let approval = model.pendingApproval {
                ApprovalCard(approval: approval, palette: palette)
                    .transition(riseTransition)
            } else if !model.suggestions.isEmpty {
                SuggestionList(palette: palette)
                    .transition(riseTransition)
            }

            VStack(alignment: .leading, spacing: 10) {
                if model.editingItemID != nil {
                    EditingBanner(palette: palette)
                        .transition(.opacity)
                }
                if !model.pendingAttachments.isEmpty {
                    AttachmentStrip(palette: palette)
                        .transition(.opacity)
                }
                InputField(palette: palette, inputFocused: inputFocused, send: send)
                HStack(spacing: 10) {
                    PlusMenu(palette: palette)
                    Spacer(minLength: 0)
                    ModelButton(palette: palette)
                    SendButton(palette: palette, send: send)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .glass(in: RoundedRectangle(cornerRadius: Metrics.composerRadius, style: .continuous))

            if showsKeys {
                KeyRow(palette: palette, hideKeyboard: { inputFocused.wrappedValue = false })
                    .transition(.opacity)
            } else {
                StatusRow(palette: palette)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 6)
        // Fades the conversation out underneath, so nothing shows through around the home indicator.
        .background {
            LinearGradient(
                stops: [
                    .init(color: palette.background.opacity(0), location: 0),
                    .init(color: palette.background.opacity(0.85), location: 0.4),
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

    private func send() {
        model.submit()
        // Submitting drops focus; keep the keyboard up so the next message can be typed straight away.
        DispatchQueue.main.async { inputFocused.wrappedValue = true }
    }
}

private struct InputField: View {
    @Environment(AppModel.self) private var model
    let palette: Palette
    var inputFocused: FocusState<Bool>.Binding
    let send: () -> Void

    var body: some View {
        @Bindable var model = model

        Group {
            if model.inputIsSecret {
                SecureField("", text: $model.input, prompt: Text(model.placeholder).foregroundStyle(palette.dim))
            } else {
                TextField("", text: $model.input, prompt: Text(model.placeholder).foregroundStyle(palette.dim), axis: .vertical)
                    .lineLimit(1...6)
            }
        }
        .font(palette.prose)
        .foregroundStyle(palette.text)
        .tint(palette.accent)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.send)
        .focused(inputFocused)
        .onSubmit(send)
        .padding(.horizontal, 6)
        .accessibilityIdentifier("composer-input")
    }
}

/// Adds files to the next message: straight from the device, or from the workspace.
private struct PlusMenu: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        Menu {
            Button {
                model.showImporter = true
            } label: {
                Label("Attach files", systemImage: "paperclip")
            }
            Button {
                model.present(.files)
            } label: {
                Label("Workspace files", systemImage: "folder")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(palette.text)
                .frame(width: 34, height: 34)
                .outlined(palette, fill: palette.card)
        }
        .disabled(model.setup != nil || model.pendingApproval != nil)
        .accessibilityLabel("Add files")
        .accessibilityIdentifier("composer-plus")
    }
}

private struct ModelButton: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        Button {
            model.present(.models)
        } label: {
            HStack(spacing: 6) {
                Text(model.modelLabel)
                    .font(palette.label)
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.dim)
            }
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Model: \(model.modelLabel)")
        .accessibilityIdentifier("composer-model")
    }
}

/// Sends the message, or stops the run when there is nothing typed.
private struct SendButton: View {
    @Environment(AppModel.self) private var model
    let palette: Palette
    let send: () -> Void

    var body: some View {
        let hasInput = !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let stops = model.isRunning && !hasInput
        let isEnabled = stops || hasInput || model.setup != nil || !model.pendingAttachments.isEmpty

        Button {
            if stops {
                model.cancel()
            } else {
                send()
            }
        } label: {
            Image(systemName: stops ? "stop.fill" : "arrow.up")
                .font(.system(size: stops ? 13 : 16, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(isEnabled ? palette.onAccent : palette.dim.opacity(0.7))
                .frame(width: 36, height: 36)
                .background(isEnabled ? palette.accent : palette.inactive, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .animation(.snappy(duration: 0.2), value: isEnabled)
        .animation(.snappy(duration: 0.2), value: stops)
        .accessibilityLabel(stops ? "Stop" : "Send")
        .accessibilityIdentifier("composer-send")
    }
}

private struct EditingBanner: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil").foregroundStyle(palette.accent)
            Text("Editing · sending replaces the message and the replies after it")
                .foregroundStyle(palette.dim)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button {
                model.cancelEditing()
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(palette.dim)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel editing")
        }
        .font(palette.caption)
        .padding(.leading, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editing-banner")
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
                                .frame(width: 24, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(attachment.name)")
                    }
                    .font(palette.caption)
                    .foregroundStyle(palette.text)
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .frame(height: 32)
                    .outlined(palette, fill: palette.card, radius: 16)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("attachment-\(attachment.name)")
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
        }
    }
}

/// Which SSH host the agent works on, and whether it asks before acting.
private struct StatusRow: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(model.hosts) { host in
                    Button {
                        model.selectHost(host.id)
                    } label: {
                        if host.id == model.activeHost?.id {
                            Label("\(host.name)  \(host.address)", systemImage: "checkmark")
                        } else {
                            Text("\(host.name)  \(host.address)")
                        }
                    }
                }
                Button {
                    model.selectHost(nil)
                } label: {
                    if model.activeHost == nil {
                        Label("No SSH host", systemImage: "checkmark")
                    } else {
                        Text("No SSH host")
                    }
                }
                Divider()
                Button {
                    model.openSettings(.host(nil))
                } label: {
                    Label("Add host", systemImage: "plus")
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "server.rack").font(.system(size: 14))
                    Text(model.activeHost?.name ?? "No host").font(palette.label).lineLimit(1)
                }
                .foregroundStyle(palette.dim)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("SSH host: \(model.activeHost?.name ?? "none")")
            .accessibilityIdentifier("composer-host")

            Spacer(minLength: 0)

            Menu {
                ForEach(ApprovalMode.allCases, id: \.self) { mode in
                    Button {
                        model.setApprovalMode(mode)
                    } label: {
                        if mode == model.settings.approvalMode {
                            Label(mode.label, systemImage: "checkmark")
                        } else {
                            Text(mode.label)
                        }
                    }
                }
            } label: {
                Text(model.settings.approvalMode.label)
                    .font(palette.label)
                    .foregroundStyle(palette.dim)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .contentShape(Rectangle())
            }
            .glass(in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityLabel("Permissions: \(model.settings.approvalMode.label)")
            .accessibilityIdentifier("composer-permissions")
        }
        .padding(.horizontal, 8)
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
                key("paste") {
                    if let text = UIPasteboard.general.string { model.input += text }
                }
                key("⌄", action: hideKeyboard)
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 36)
        .clipShape(Capsule())
        .glass(in: Capsule())
    }

    private func key(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(palette.mono)
                .foregroundStyle(palette.text)
                .padding(.horizontal, 13)
                .frame(minWidth: 42, minHeight: 36)
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
                        Text("/\(command.name)").font(palette.mono).foregroundStyle(palette.accent)
                        Text(command.help).font(palette.caption).foregroundStyle(palette.dim).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .glass(in: RoundedRectangle(cornerRadius: Metrics.bubbleRadius, style: .continuous))
    }
}

private struct ApprovalCard: View {
    @Environment(AppModel.self) private var model
    let approval: PendingApproval
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Allow this action?")
                .font(palette.labelBold)
                .foregroundStyle(palette.text)
            Text(approval.summary)
                .font(palette.mono)
                .foregroundStyle(palette.text)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(palette.card, in: RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous))
            HStack(spacing: 8) {
                choice("Deny", "approval-deny", isPrimary: false) { model.resolveApproval(.deny) }
                choice("Always allow", "approval-always", isPrimary: false) { model.allowAlways() }
                choice("Allow", "approval-allow", isPrimary: true) { model.resolveApproval(.allow) }
            }
        }
        .padding(14)
        .glass(in: RoundedRectangle(cornerRadius: Metrics.bubbleRadius, style: .continuous))
    }

    private func choice(_ label: String, _ identifier: String, isPrimary: Bool, action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        return Button(action: action) {
            Text(label)
                .font(palette.labelBold)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(isPrimary ? palette.onAccent : palette.text)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(isPrimary ? palette.accent : palette.card, in: shape)
                .overlay { shape.stroke(isPrimary ? Color.clear : palette.border, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}
