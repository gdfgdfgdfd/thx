import SwiftUI
import TermCore
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let palette = model.palette

        ZStack(alignment: .leading) {
            ChatScreen()
            SidebarDrawer()
        }
        .background(palette.background.ignoresSafeArea())
        .tint(palette.accent)
        .preferredColorScheme(palette.colorScheme)
        .sheet(item: $model.activeSheet) { sheet in
            SheetContent(sheet: sheet)
                .tint(palette.accent)
                .preferredColorScheme(palette.colorScheme)
        }
        .sheet(item: $model.shareItem) { item in
            ShareSheet(text: item.text)
        }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.attach(urls)
            case .failure(let error): model.fail("file picker: \(error.localizedDescription)")
            }
        }
    }
}

private struct SheetContent: View {
    let sheet: AppSheet

    var body: some View {
        switch sheet {
        case .settings: SettingsView()
        case .files: FilesView()
        case .terminal: ConsoleView()
        case .models: ModelsView()
        case .search: SearchView()
        }
    }
}

// MARK: Chat screen

private struct ChatScreen: View {
    @Environment(AppModel.self) private var model
    @FocusState private var inputFocused: Bool
    @State private var topHeight: CGFloat = 0
    @State private var bottomHeight: CGFloat = 0

    var body: some View {
        let isEmpty = model.session.transcript.isEmpty

        ZStack {
            if isEmpty {
                EmptyState()
                    .padding(.top, topHeight)
                    .padding(.bottom, bottomHeight)
                    .transition(.opacity)
            } else {
                // The conversation runs underneath both bars, so the glass has content to pick up.
                TranscriptView(topInset: topHeight, bottomInset: bottomHeight)
                    .transition(.opacity)
            }
            VStack(spacing: 0) {
                TopBar()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topHeight = $0 }
                Spacer(minLength: 0)
                Composer(inputFocused: $inputFocused)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomHeight = $0 }
            }
        }
        .animation(.snappy(duration: 0.25), value: isEmpty)
        .onChange(of: model.focusRequests) { inputFocused = true }
        // The keyboard belongs to the message box; it should not sit under the sidebar or a sheet.
        .onChange(of: model.showSidebar) { if model.showSidebar { inputFocused = false } }
    }
}

// MARK: Top bar

private struct TopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let palette = model.palette

        HStack(spacing: 10) {
            // The glass goes around the button, as in the group on the right. Inside the button's label
            // it took the touch itself and the button never fired.
            HStack(spacing: 0) {
                barButton("sidebar.left", "Sidebar", "topbar-sidebar", palette) { model.openSidebar() }
            }
            .glass(in: Circle())

            Text(model.session.title)
                .font(palette.label)
                .foregroundStyle(palette.dim)
                .lineLimit(1)
                // The conversation scrolls underneath; the title must not swallow taps meant for it.
                .allowsHitTesting(false)
                .accessibilityIdentifier("session-title")

            Spacer(minLength: 8)

            HStack(spacing: 0) {
                barButton("apple.terminal", "Terminal", "topbar-terminal", palette) { model.present(.terminal) }
                barButton("folder", "Files", "topbar-files", palette) { model.present(.files) }
                barButton("square.and.pencil", "New session", "topbar-new", palette) { model.newSession() }
            }
            .padding(.horizontal, 4)
            .glass(in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 14)
        // Fades the conversation out before it reaches the status bar.
        .background {
            LinearGradient(
                stops: [
                    .init(color: palette.background, location: 0),
                    .init(color: palette.background.opacity(0.85), location: 0.6),
                    .init(color: palette.background.opacity(0), location: 1),
                ],
                startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
    }

    private func barButton(_ systemName: String, _ label: String, _ identifier: String, _ palette: Palette,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17))
                .foregroundStyle(palette.text)
                .frame(width: Metrics.barButton, height: Metrics.barButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: Empty session

private struct EmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let palette = model.palette
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)

        VStack(spacing: 20) {
            HStack(spacing: 12) {
                SparkMark(size: 30, color: palette.accent)
                Text("Ready when you are")
                    .font(.system(size: 30, design: .serif))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            VStack(spacing: 0) {
                if model.activeProfile == nil {
                    row("gearshape", "Add a connection", "empty-connection", palette) { model.openSettings(.connection(nil)) }
                    Rectangle().fill(palette.border).frame(height: 1)
                }
                row("folder", "Workspace files", "empty-files", palette) { model.present(.files) }
                Rectangle().fill(palette.border).frame(height: 1)
                row("apple.terminal", model.activeHost.map { "Terminal on \($0.name)" } ?? "Terminal", "empty-terminal", palette) {
                    model.present(.terminal)
                }
            }
            .frame(maxWidth: 300)
            .clipShape(shape)
            .overlay { shape.stroke(palette.border, lineWidth: 1) }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ systemName: String, _ title: String, _ identifier: String, _ palette: Palette,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemName)
                    .font(.system(size: 15))
                    .frame(width: 22)
                Text(title).font(palette.label)
                Spacer(minLength: 0)
            }
            .foregroundStyle(palette.text)
            .padding(.horizontal, 16)
            .frame(height: 45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}
