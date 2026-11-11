import SwiftUI
import TermCore
import UIKit
import UniformTypeIdentifiers

struct TerminalView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var inputFocused: Bool
    @State private var topHeight: CGFloat = 0
    @State private var bottomHeight: CGFloat = 0

    var body: some View {
        @Bindable var model = model
        let palette = model.palette

        ZStack {
            // The transcript runs underneath both bars, so the glass has content to pick up.
            TranscriptView(topInset: topHeight, bottomInset: bottomHeight)
            VStack(spacing: 0) {
                TopBar()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topHeight = $0 }
                Spacer(minLength: 0)
                Composer(inputFocused: $inputFocused)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomHeight = $0 }
            }
        }
        .background(palette.background.ignoresSafeArea())
        .preferredColorScheme(model.theme.isDark ? .dark : .light)
        .sheet(isPresented: $model.showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $model.showSessions) {
            SessionsView()
        }
        .sheet(item: $model.shareItem) { item in
            ShareSheet(text: item.text)
        }
        .fileImporter(isPresented: $model.showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.attach(urls)
            case .failure(let error): model.fail("file picker: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: Top bar

private struct TopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let palette = model.palette
        HStack(spacing: 8) {
            Button {
                model.openSessions()
            } label: {
                Image(systemName: "rectangle.stack")
                    .foregroundStyle(palette.text)
                    .frame(width: Metrics.barHeight, height: Metrics.barHeight)
                    .glass(in: Circle(), interactive: true)
            }
            .accessibilityLabel("Sessions")

            Menu {
                ForEach(model.profiles) { profile in
                    Section(profile.name) {
                        ForEach(profile.models, id: \.self) { id in
                            Button {
                                model.select(model: id, in: profile.id)
                            } label: {
                                if profile.id == model.activeProfile?.id, id == model.activeModel {
                                    Label(id, systemImage: "checkmark")
                                } else {
                                    Text(id)
                                }
                            }
                        }
                    }
                }
                Button("Settings…") { model.showSettings = true }
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(model.isRunning ? palette.accent : palette.success)
                        .frame(width: 7, height: 7)
                    Text(modelLabel).foregroundStyle(palette.text).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(palette.dim)
                }
                .padding(.horizontal, 14)
                .frame(height: Metrics.barHeight)
                .glass(in: Capsule(), interactive: true)
            }
            .accessibilityLabel("Model: \(modelLabel)")

            Spacer(minLength: 0)

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
                Button("No SSH host") { model.selectHost(nil) }
            } label: {
                Text(model.activeHost.map { "⇄ \($0.name)" } ?? "⇄ off")
                    .foregroundStyle(model.activeHost == nil ? palette.dim : palette.accent)
                    .lineLimit(1)
                    .frame(maxWidth: 110)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .frame(height: Metrics.barHeight)
                    .glass(in: Capsule(), interactive: true)
            }
            .accessibilityLabel(model.activeHost.map { "SSH host: \($0.name)" } ?? "SSH host: off")

            Button {
                model.showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(palette.text)
                    .frame(width: Metrics.barHeight, height: Metrics.barHeight)
                    .glass(in: Circle(), interactive: true)
            }
            .accessibilityLabel("Settings")
        }
        .font(palette.small)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 14)
        // Fades the transcript out before it reaches the status bar.
        .background {
            LinearGradient(
                stops: [
                    .init(color: palette.background, location: 0),
                    .init(color: palette.background.opacity(0.8), location: 0.6),
                    .init(color: palette.background.opacity(0), location: 1),
                ],
                startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
    }

    /// The model without its provider prefix; the menu lists the full IDs under each profile.
    private var modelLabel: String {
        guard model.activeProfile != nil else { return "no profile · /setup" }
        guard let id = model.activeModel else { return "no model" }
        return id.split(separator: "/").last.map(String.init) ?? id
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
