import SwiftUI
import TermCore
import TermSSH

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        let palette = model.palette

        NavigationStack(path: $model.settingsPath) {
            Form {
                Section {
                    ForEach(model.profiles) { profile in
                        NavigationLink(value: SettingsRoute.connection(profile.id)) {
                            row(profile.name, detail: profile.baseURL, isActive: profile.id == model.activeProfile?.id, palette: palette)
                        }
                    }
                    NavigationLink(value: SettingsRoute.connection(nil)) {
                        Label("Add connection", systemImage: "plus")
                    }
                    .accessibilityIdentifier("settings-add-connection")
                } header: {
                    Text("Connections")
                } footer: {
                    Text("OpenAI-compatible gateways. API keys and custom headers are stored in the Keychain on this device.")
                }
                .listRowBackground(palette.surface)

                Section {
                    ForEach(model.hosts) { host in
                        NavigationLink(value: SettingsRoute.host(host.id)) {
                            row(host.name, detail: host.address, isActive: host.id == model.activeHost?.id, palette: palette)
                        }
                    }
                    NavigationLink(value: SettingsRoute.host(nil)) {
                        Label("Add host", systemImage: "plus")
                    }
                    .accessibilityIdentifier("settings-add-host")
                } header: {
                    Text("SSH hosts")
                } footer: {
                    Text("The agent runs commands on the selected host. Switch hosts below the message box.")
                }
                .listRowBackground(palette.surface)

                Section {
                    Picker("Permissions", selection: Binding(
                        get: { model.settings.approvalMode },
                        set: { model.setApprovalMode($0) })) {
                        ForEach(ApprovalMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    NavigationLink(value: SettingsRoute.systemPrompt) {
                        Text("System prompt")
                    }
                } header: {
                    Text("Agent")
                } footer: {
                    Text(model.settings.approvalMode.summary)
                }
                .listRowBackground(palette.surface)

                Section {
                    Picker("Theme", selection: binding(\.themeID)) {
                        ForEach(Theme.all) { theme in
                            Text(theme.name).tag(theme.id)
                        }
                    }
                    Stepper("Text size: \(Int(model.settings.fontSize))", value: binding(\.fontSize), in: 10...20, step: 1)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Files the agent writes are in Files › On My iPhone › TermAI.")
                }
                .listRowBackground(palette.surface)
            }
            .sheetPage(palette)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                destination(route)
            }
        }
    }

    private func row(_ title: String, detail: String, isActive: Bool, palette: Palette) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if isActive {
                Image(systemName: "checkmark").foregroundStyle(palette.accent)
                    .accessibilityLabel("Active")
            }
        }
    }

    @ViewBuilder
    private func destination(_ route: SettingsRoute) -> some View {
        switch route {
        case .connection(let id):
            let existing = model.profiles.first { $0.id == id }
            let profile = existing ?? Profile(name: "", baseURL: "https://")
            ConnectionEditor(profile: profile, apiKey: model.apiKey(for: profile),
                             headers: model.customHeaders(for: profile), isNew: existing == nil)
        case .host(let id):
            let existing = model.hosts.first { $0.id == id }
            let host = existing ?? SSHHost(name: "", host: "", username: "")
            HostEditor(host: host, secret: model.hostSecret(for: host),
                       passphrase: model.hostPassphrase(for: host), isNew: existing == nil)
        case .systemPrompt:
            SystemPromptEditor()
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in model.update { $0[keyPath: keyPath] = value } })
    }
}

private struct SystemPromptEditor: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let palette = model.palette
        let text = Binding(
            get: { model.settings.systemPrompt },
            set: { value in model.update { $0.systemPrompt = value } })

        VStack(alignment: .leading, spacing: 10) {
            Text("Added to every conversation, after the app's own instructions.")
                .font(palette.caption)
                .foregroundStyle(palette.dim)
            TextEditor(text: text)
                .font(palette.mono)
                .foregroundStyle(palette.text)
                .scrollContentBackground(.hidden)
                .padding(8)
                .outlined(palette, fill: palette.card, radius: 12)
                .accessibilityIdentifier("system-prompt")
        }
        .padding(Metrics.margin)
        .background(palette.background.ignoresSafeArea())
        .navigationTitle("System prompt")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Editor building blocks

/// A titled card of fields, with room for one action beside the title.
struct EditorCard<Accessory: View, Content: View>: View {
    let title: String
    let palette: Palette
    let accessory: Accessory
    let content: Content

    init(_ title: String, palette: Palette, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.palette = palette
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(palette.text)
                Spacer(minLength: 8)
                accessory
            }
            .frame(minHeight: 34)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .outlined(palette, fill: palette.sidebar, radius: 16)
    }
}

extension EditorCard where Accessory == EmptyView {
    init(_ title: String, palette: Palette, @ViewBuilder content: () -> Content) {
        self.init(title, palette: palette, accessory: { EmptyView() }, content: content)
    }
}

/// One labelled field: what it is, a line of help, then the control.
struct EditorField<Content: View>: View {
    let title: String
    let help: String
    let palette: Palette
    let content: Content

    init(_ title: String, help: String = "", palette: Palette, @ViewBuilder content: () -> Content) {
        self.title = title
        self.help = help
        self.palette = palette
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.text)
            if !help.isEmpty {
                Text(help)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content.padding(.top, 3)
        }
    }
}

extension View {
    /// The box around a text field in an editor.
    func boxed(_ palette: Palette, minHeight: CGFloat = 42) -> some View {
        font(.system(size: 15))
            .foregroundStyle(palette.text)
            .padding(.horizontal, 12)
            .frame(minHeight: minHeight)
            .outlined(palette, fill: palette.background, radius: Metrics.controlRadius)
    }
}

/// A password-style field with an eye to show what was typed.
struct SecretField: View {
    let placeholder: String
    @Binding var text: String
    let palette: Palette
    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isRevealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .foregroundStyle(palette.dim)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRevealed ? "Hide" : "Show")
        }
        .boxed(palette)
    }
}

/// A small quiet button used beside card titles.
struct PillButton: View {
    let title: String
    var systemImage: String?
    let palette: Palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 13, weight: .medium))
                }
                Text(title).font(.system(size: 15))
            }
            .foregroundStyle(palette.text)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// The destructive button at the bottom of an editor.
struct DeleteButton: View {
    let title: String
    let palette: Palette
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.error)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .outlined(palette, fill: palette.sidebar, radius: 12)
        }
        .buttonStyle(.plain)
    }
}
