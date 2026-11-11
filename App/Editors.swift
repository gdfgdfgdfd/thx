import SwiftUI
import TermCore
import TermSSH

/// Where requests go: the gateway's address, how to sign in to it, and the models it offers.
struct ConnectionEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var profile: Profile
    @State var apiKey: String
    @State var headers: [HeaderField]
    let isNew: Bool
    @State private var modelsText = ""
    @State private var test = TestState.idle
    @State private var isFetching = false
    @State private var fetchMessage: String?
    @State private var confirmsDelete = false

    private enum TestState: Equatable {
        case idle, running
        case passed(String)
        case failed(String)
    }

    private var modelIDs: [String] {
        var seen = Set<String>()
        return modelsText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private var canSave: Bool {
        !profile.name.trimmingCharacters(in: .whitespaces).isEmpty && canTest
    }

    /// The gateway can be tried as soon as there is an address, before the connection has a name.
    private var canTest: Bool {
        URL(string: profile.baseURL.trimmingCharacters(in: .whitespaces))?.host != nil
    }

    var body: some View {
        let palette = model.palette

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connection")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(palette.text)
                    Text("Choose where TermAI sends inference requests.")
                        .font(.system(size: 15))
                        .foregroundStyle(palette.dim)
                }

                credentials(palette)
                models(palette)

                if !isNew {
                    DeleteButton(title: "Delete connection", palette: palette) { confirmsDelete = true }
                        .accessibilityIdentifier("connection-delete")
                }
            }
            .padding(Metrics.margin)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(palette.background.ignoresSafeArea())
        .navigationTitle(isNew ? "New connection" : profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!canSave)
            }
        }
        .confirmationDialog("Delete \(profile.name)?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete connection", role: .destructive) {
                model.deleteProfile(profile)
                dismiss()
            }
        } message: {
            Text("Its API key and headers are removed from the Keychain.")
        }
        .onAppear {
            if modelsText.isEmpty { modelsText = profile.models.joined(separator: "\n") }
        }
    }

    private func credentials(_ palette: Palette) -> some View {
        EditorCard("Gateway credentials", palette: palette) {
            Button {
                runTest()
            } label: {
                HStack(spacing: 8) {
                    testIndicator(palette)
                    Text("Test connection").font(.system(size: 15))
                }
                .foregroundStyle(palette.text)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(test == .running || !canTest)
            .accessibilityIdentifier("connection-test")
        } content: {
            testResult(palette)

            EditorField("Name", help: "Shown in the sidebar and the model picker.", palette: palette) {
                TextField("openrouter", text: $profile.name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .boxed(palette)
                    .accessibilityIdentifier("connection-name")
            }
            EditorField("Gateway base URL", help: "Full URL of the OpenAI-compatible endpoint, usually ending in /v1.", palette: palette) {
                TextField("https://api.openai.com/v1", text: $profile.baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .boxed(palette)
                    .accessibilityIdentifier("connection-url")
            }
            EditorField("Gateway API key", help: "Stored in the Keychain on this device. Leave empty if the server needs none.", palette: palette) {
                SecretField(placeholder: "", text: $apiKey, palette: palette)
            }
            EditorField("Gateway auth scheme", help: "How the key is sent: Authorization: Bearer, or an x-api-key header.", palette: palette) {
                Picker("Gateway auth scheme", selection: $profile.authScheme) {
                    Text("bearer").tag(AuthScheme.bearer)
                    Text("x-api-key").tag(AuthScheme.apiKey)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            customHeaders(palette)
        }
    }

    @ViewBuilder
    private func testIndicator(_ palette: Palette) -> some View {
        switch test {
        case .running:
            ProgressView().controlSize(.small)
        case .passed:
            Circle().fill(palette.success).frame(width: 8, height: 8)
        case .failed:
            Circle().fill(palette.error).frame(width: 8, height: 8)
        case .idle:
            Circle().fill(palette.dim).frame(width: 8, height: 8)
        }
    }

    @ViewBuilder
    private func testResult(_ palette: Palette) -> some View {
        switch test {
        case .passed(let message):
            Text(message).font(.system(size: 13)).foregroundStyle(palette.success)
                .accessibilityIdentifier("connection-test-result")
        case .failed(let message):
            Text(message).font(.system(size: 13)).foregroundStyle(palette.error)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("connection-test-result")
        case .idle, .running:
            EmptyView()
        }
    }

    private func customHeaders(_ palette: Palette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Custom headers")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.text)
                    Text("Sent with every request, e.g. HTTP-Referer. Stored in the Keychain.")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                PillButton(title: "Add header", systemImage: "plus", palette: palette) {
                    headers.append(HeaderField(name: "", value: ""))
                }
                .accessibilityIdentifier("connection-add-header")
            }
            ForEach($headers) { $field in
                HStack(spacing: 8) {
                    TextField("Name", text: $field.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .boxed(palette)
                    TextField("Value", text: $field.value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .boxed(palette)
                    Button {
                        let id = field.id
                        headers.removeAll { $0.id == id }
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 18))
                            .foregroundStyle(palette.dim)
                            .frame(width: 32, height: 42)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove header")
                }
            }
        }
    }

    private func models(_ palette: Palette) -> some View {
        EditorCard("Models", palette: palette) {
            Button {
                fetchModels()
            } label: {
                HStack(spacing: 8) {
                    if isFetching { ProgressView().controlSize(.small) }
                    Text("Fetch from endpoint").font(.system(size: 15))
                }
                .foregroundStyle(palette.text)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isFetching || !canTest)
            .accessibilityIdentifier("connection-fetch")
        } content: {
            if let fetchMessage {
                Text(fetchMessage).font(.system(size: 13)).foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            EditorField("Model IDs", help: "One per line.", palette: palette) {
                TextEditor(text: $modelsText)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(palette.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 110)
                    .padding(6)
                    .outlined(palette, fill: palette.background, radius: Metrics.controlRadius)
                    .accessibilityIdentifier("connection-models")
            }
            if !modelIDs.isEmpty {
                EditorField("Default model", help: "Used when you switch to this connection.", palette: palette) {
                    Picker("Default model", selection: Binding(
                        get: { profile.defaultModel.flatMap { modelIDs.contains($0) ? $0 : nil } ?? modelIDs[0] },
                        set: { profile.defaultModel = $0 })) {
                        ForEach(modelIDs, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func save() {
        var saved = profile
        saved.name = saved.name.trimmingCharacters(in: .whitespaces)
        saved.baseURL = saved.baseURL.trimmingCharacters(in: .whitespaces)
        saved.models = modelIDs
        if let chosen = saved.defaultModel, !modelIDs.contains(chosen) { saved.defaultModel = nil }
        model.saveProfile(saved, apiKey: apiKey, headers: headers)
        dismiss()
    }

    /// Asks the gateway for its models with what is typed in right now, saved or not.
    private func runTest() {
        test = .running
        let baseURL = profile.baseURL.trimmingCharacters(in: .whitespaces)
        let (key, scheme, extra) = (apiKey, profile.authScheme, headers)
        Task {
            do {
                let found = try await model.listModels(baseURL: baseURL, apiKey: key, authScheme: scheme, headers: extra)
                test = .passed("Connected · \(found.count) model\(found.count == 1 ? "" : "s") available")
            } catch {
                test = .failed(error.localizedDescription)
            }
        }
    }

    private func fetchModels() {
        isFetching = true
        fetchMessage = nil
        let baseURL = profile.baseURL.trimmingCharacters(in: .whitespaces)
        let (key, scheme, extra) = (apiKey, profile.authScheme, headers)
        Task {
            do {
                let fetched = try await model.listModels(baseURL: baseURL, apiKey: key, authScheme: scheme, headers: extra)
                let existing = Set(modelIDs)
                let added = fetched.filter { !existing.contains($0) }
                modelsText = (modelIDs + added).joined(separator: "\n")
                fetchMessage = "\(fetched.count) models found, \(added.count) added."
            } catch {
                fetchMessage = "Failed: \(error.localizedDescription)"
            }
            isFetching = false
        }
    }
}

/// A server the agent and the terminal reach over SSH.
struct HostEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var host: SSHHost
    @State var secret: String
    @State var passphrase: String
    let isNew: Bool
    @State private var confirmsDelete = false

    private var canSave: Bool {
        ![host.name, host.host, host.username].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            && (1...65_535).contains(host.port)
    }

    var body: some View {
        let palette = model.palette

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SSH host")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(palette.text)
                    Text("A server the agent and the terminal run commands on.")
                        .font(.system(size: 15))
                        .foregroundStyle(palette.dim)
                }

                server(palette)
                authentication(palette)
                if let key = host.trustedHostKey { hostKey(key, palette) }

                if !isNew {
                    DeleteButton(title: "Delete host", palette: palette) { confirmsDelete = true }
                        .accessibilityIdentifier("host-delete")
                }
            }
            .padding(Metrics.margin)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(palette.background.ignoresSafeArea())
        .navigationTitle(isNew ? "New host" : host.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!canSave)
            }
        }
        .confirmationDialog("Delete \(host.name)?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete host", role: .destructive) {
                model.deleteHost(host)
                dismiss()
            }
        } message: {
            Text("Its password or key is removed from the Keychain.")
        }
    }

    private func server(_ palette: Palette) -> some View {
        EditorCard("Server", palette: palette) {
            EditorField("Name", help: "Shown below the message box and in tool activity.", palette: palette) {
                TextField("web1", text: $host.name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .boxed(palette)
                    .accessibilityIdentifier("host-name")
            }
            EditorField("Hostname or IP", palette: palette) {
                TextField("10.0.0.12", text: $host.host)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .boxed(palette)
            }
            HStack(alignment: .top, spacing: 12) {
                EditorField("Username", palette: palette) {
                    TextField("deploy", text: $host.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .boxed(palette)
                }
                EditorField("Port", palette: palette) {
                    TextField("22", value: $host.port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .boxed(palette)
                }
                .frame(width: 96)
            }
        }
    }

    private func authentication(_ palette: Palette) -> some View {
        EditorCard("Authentication", palette: palette) {
            Picker("Method", selection: $host.auth) {
                Text("Password").tag(SSHHost.Auth.password)
                Text("Private key").tag(SSHHost.Auth.privateKey)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: host.auth) { _, method in
                // Switching back to the method that is saved brings its secret back rather than wiping it.
                let isSaved = model.hosts.first { $0.id == host.id }?.auth == method
                secret = isSaved ? model.hostSecret(for: host) : ""
                passphrase = isSaved ? model.hostPassphrase(for: host) : ""
            }

            if host.auth == .password {
                EditorField("Password", help: "Stored in the Keychain on this device.", palette: palette) {
                    SecretField(placeholder: "", text: $secret, palette: palette)
                }
            } else {
                EditorField("Private key", help: "An Ed25519 or RSA key in OpenSSH format (-----BEGIN OPENSSH PRIVATE KEY-----). Stored in the Keychain on this device.", palette: palette) {
                    TextEditor(text: $secret)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(palette.text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 120)
                        .padding(6)
                        .outlined(palette, fill: palette.background, radius: Metrics.controlRadius)
                }
                EditorField("Passphrase", help: "Only if the key has one.", palette: palette) {
                    SecretField(placeholder: "", text: $passphrase, palette: palette)
                }
            }
        }
    }

    private func hostKey(_ key: String, _ palette: Palette) -> some View {
        EditorCard("Trusted host key", palette: palette) {
            PillButton(title: "Forget", palette: palette) { host.trustedHostKey = nil }
        } content: {
            Text(SSHKeys.fingerprint(ofOpenSSHKey: key))
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(palette.text)
                .textSelection(.enabled)
            Text("Recorded on first connection. Connections are refused if the server presents a different key.")
                .font(.system(size: 13))
                .foregroundStyle(palette.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save() {
        var saved = host
        saved.name = saved.name.trimmingCharacters(in: .whitespaces)
        saved.host = saved.host.trimmingCharacters(in: .whitespaces)
        saved.username = saved.username.trimmingCharacters(in: .whitespaces)
        model.saveHost(saved, secret: secret, passphrase: passphrase)
        dismiss()
    }
}
