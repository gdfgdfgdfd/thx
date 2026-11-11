import SwiftUI
import TermCore

/// A plain SSH terminal on the selected host. What is run here stays out of the conversation.
struct ConsoleView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    var body: some View {
        let palette = model.palette

        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ConsoleHeader(palette: palette)
                            ForEach(model.console.entries) { entry in
                                ConsoleEntryView(entry: entry, palette: palette)
                            }
                            if model.consoleRunning {
                                ProgressView().controlSize(.small).tint(palette.accent)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: model.console.entries.count) {
                        proxy.scrollTo("end", anchor: .bottom)
                    }
                    .onChange(of: model.console.entries.last?.text) {
                        proxy.scrollTo("end", anchor: .bottom)
                    }
                }

                Rectangle().fill(palette.border).frame(height: 1)
                ConsoleInput(palette: palette, isFocused: $isFocused)
            }
            .background(palette.background.ignoresSafeArea())
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("terminal-done")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.console.clear()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(model.console.entries.isEmpty)
                    .accessibilityLabel("Clear")
                    .accessibilityIdentifier("terminal-clear")
                }
            }
        }
    }
}

private struct ConsoleHeader: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        if let host = model.activeHost {
            Text("\(host.address)\nCommands run on this host over SSH and stay out of the chat.")
                .font(palette.mono)
                .foregroundStyle(palette.dim)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("No SSH host selected.\nAdd one, then pick it below the message box.")
                    .font(palette.mono)
                    .foregroundStyle(palette.dim)
                Button("Add an SSH host") { model.openSettings(.host(nil)) }
                    .font(palette.label)
            }
        }
    }
}

private struct ConsoleEntryView: View {
    let entry: ConsoleEntry
    let palette: Palette

    var body: some View {
        switch entry.kind {
        case .note:
            Text(entry.text).font(palette.mono).foregroundStyle(palette.dim)
        case .command:
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("$ ").foregroundStyle(palette.accent)
                Text(entry.text).foregroundStyle(palette.text).textSelection(.enabled)
            }
            .font(palette.monoBold)
            .padding(.top, 4)
        case .output:
            // The final line break of a command's output would only add an empty row.
            Text(entry.text.hasSuffix("\n") ? String(entry.text.dropLast()) : entry.text)
                .font(palette.mono)
                .foregroundStyle(palette.text)
                .textSelection(.enabled)
        case .error:
            Text(entry.text).font(palette.mono).foregroundStyle(palette.error)
        }
    }
}

private struct ConsoleInput: View {
    @Environment(AppModel.self) private var model
    let palette: Palette
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 10) {
            Text("$").font(palette.monoBold).foregroundStyle(palette.accent)
            TextField("", text: $model.consoleInput, prompt: Text("command").foregroundStyle(palette.dim))
                .font(palette.mono)
                .foregroundStyle(palette.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused(isFocused)
                .onSubmit {
                    model.runConsole()
                    // Submitting drops focus; a terminal keeps the keyboard up.
                    DispatchQueue.main.async { isFocused.wrappedValue = true }
                }
                .accessibilityIdentifier("terminal-input")
            Button {
                if model.consoleRunning {
                    model.cancelConsole()
                } else {
                    model.runConsole()
                }
            } label: {
                Image(systemName: model.consoleRunning ? "stop.fill" : "return")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(palette.text)
                    .frame(width: 40, height: 34)
                    .outlined(palette, fill: palette.card)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.consoleRunning ? "Stop" : "Run")
            .accessibilityIdentifier("terminal-run")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
