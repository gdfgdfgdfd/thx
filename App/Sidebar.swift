import SwiftUI
import TermCore

/// The sidebar and the dimmed area beside it. Neither is in the view tree while the sidebar is closed.
struct SidebarDrawer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let palette = model.palette

        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                if model.showSidebar {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { model.closeSidebar() }
                        .gesture(DragGesture(minimumDistance: 20).onEnded { value in
                            if value.translation.width < -40 { model.closeSidebar() }
                        })
                        .accessibilityHidden(true)
                        .transition(.opacity)
                        .zIndex(1)

                    SidebarPanel(palette: palette)
                        .frame(width: min(geometry.size.width * 0.745, 340))
                        .transition(.move(edge: .leading))
                        .zIndex(2)
                }
            }
        }
        .allowsHitTesting(model.showSidebar)
    }
}

private struct SidebarPanel: View {
    @Environment(AppModel.self) private var model
    let palette: Palette
    @State private var renaming: SessionSummary?
    @State private var newTitle = ""

    var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 30, topTrailingRadius: 30, style: .continuous)
        let isRenaming = Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })

        VStack(alignment: .leading, spacing: 0) {
            header

            item("plus", "New session", "sidebar-new") { model.newSession() }
            item("magnifyingglass", "Search", "sidebar-search") { model.present(.search) }
            item("folder", "Files", "sidebar-files") { model.present(.files) }
            item("apple.terminal", "Terminal", "sidebar-terminal") { model.present(.terminal) }

            Text("Recents")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.dim)
                .padding(.leading, 20)
                .padding(.top, 22)
                .padding(.bottom, 8)

            recents

            Rectangle().fill(palette.border).frame(height: 1)
            footer
        }
        .background {
            shape.fill(palette.sidebar)
                .overlay { shape.stroke(palette.border, lineWidth: 1) }
                .ignoresSafeArea()
        }
        .alert("Rename session", isPresented: isRenaming) {
            TextField("Title", text: $newTitle)
            Button("Save") {
                if let renaming { model.renameSession(renaming.id, to: newTitle) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            SparkMark(size: 22, color: palette.accent)
            Text("TermAI")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(palette.text)
            Spacer(minLength: 0)
            Button {
                model.closeSidebar()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 17))
                    .foregroundStyle(palette.text)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close sidebar")
            .accessibilityIdentifier("sidebar-close")
        }
        .padding(.leading, 18)
        .padding(.trailing, 6)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private func item(_ systemName: String, _ title: String, _ identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemName)
                    .font(.system(size: 17))
                    .frame(width: 24)
                Text(title).font(.system(size: 17))
                Spacer(minLength: 0)
            }
            .foregroundStyle(palette.text)
            .padding(.horizontal, 20)
            .frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private var recents: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if model.sessionList.isEmpty {
                    Text("Sessions you start show up here.")
                        .font(palette.caption)
                        .foregroundStyle(palette.dim)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                }
                ForEach(model.sessionList) { summary in
                    recentRow(summary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    private func recentRow(_ summary: SessionSummary) -> some View {
        let isCurrent = summary.id == model.session.id
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        return Button {
            model.switchSession(summary.id)
        } label: {
            HStack(spacing: 8) {
                Text(summary.title)
                    .font(palette.label)
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(RelativeTime.short(summary.updatedAt))
                    .font(.system(size: 13))
                    .foregroundStyle(palette.dim)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(isCurrent ? palette.surface : Color.clear, in: shape)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("recent-session")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .contextMenu {
            Button {
                newTitle = summary.title
                renaming = summary
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                model.deleteSession(summary.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(model.profiles) { profile in
                    Button {
                        model.selectProfile(profile.id)
                    } label: {
                        if profile.id == model.activeProfile?.id {
                            Label(profile.name, systemImage: "checkmark")
                        } else {
                            Text(profile.name)
                        }
                    }
                }
                Divider()
                Button {
                    model.openSettings(.connection(nil))
                } label: {
                    Label("Add connection", systemImage: "plus")
                }
            } label: {
                HStack(spacing: 8) {
                    SparkMark(size: 18, color: palette.accent)
                    Text(model.activeProfile?.name ?? "No connection")
                        .font(palette.labelBold)
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                    Text("· Gateway")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.dim)
                        .fixedSize()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.dim)
                }
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("sidebar-connection")

            Spacer(minLength: 0)

            Button {
                model.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18))
                    .foregroundStyle(palette.dim)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("sidebar-settings")
        }
        .padding(.leading, 18)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
    }
}
