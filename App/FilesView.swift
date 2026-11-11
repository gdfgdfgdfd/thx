import SwiftUI
import TermCore
import UniformTypeIdentifiers

/// The workspace: files the agent wrote and files brought in from the device.
/// Tapping files selects them, and Done attaches the selection to the next message.
struct FilesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""
    @State private var expanded: Set<String> = []
    @State private var selection: Set<String> = []
    /// Bumped to read the folder again after something changed on disk.
    @State private var revision = 0
    @State private var showImporter = false
    @State private var isImporting = false
    @State private var problem: String?
    @State private var viewing: WorkspaceEntry?

    var body: some View {
        let palette = model.palette
        let isFiltering = !filter.trimmingCharacters(in: .whitespaces).isEmpty
        let entries = visibleEntries()

        NavigationStack {
            VStack(spacing: 0) {
                FilterField(text: $filter, palette: palette)
                    .padding(.horizontal, Metrics.margin)
                    .padding(.top, 8)
                    .padding(.bottom, 6)

                if entries.isEmpty {
                    ContentUnavailableView(
                        isFiltering ? "No matching files" : "No files yet",
                        systemImage: "folder",
                        description: Text(isFiltering ? "Nothing in the workspace has that in its name."
                                                      : "Files the agent writes and files you import show up here."))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                row(entry, palette: palette, isFiltering: isFiltering)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                footer(palette)
            }
            .background(palette.background.ignoresSafeArea())
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { finish() }
                        .accessibilityIdentifier("files-done")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isImporting {
                        ProgressView()
                    } else {
                        Button {
                            showImporter = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Import files")
                        .accessibilityIdentifier("files-import")
                    }
                }
            }
            .navigationDestination(item: $viewing) { entry in
                FileViewer(entry: entry, isSelected: selection.contains(entry.path)) {
                    toggleSelection(entry.path)
                } delete: {
                    delete(entry)
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importFiles(urls)
            case .failure(let error): problem = error.localizedDescription
            }
        }
    }

    private func row(_ entry: WorkspaceEntry, palette: Palette, isFiltering: Bool) -> some View {
        FileRow(
            entry: entry, palette: palette, showsFolder: isFiltering,
            isExpanded: expanded.contains(entry.path), isSelected: selection.contains(entry.path),
            toggle: {
                if entry.isDirectory {
                    withAnimation(.snappy(duration: 0.2)) { toggleExpansion(entry.path) }
                } else {
                    toggleSelection(entry.path)
                }
            },
            open: { viewing = entry })
            .contextMenu {
                Button(role: .destructive) {
                    delete(entry)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }

    @ViewBuilder
    private func footer(_ palette: Palette) -> some View {
        VStack(spacing: 10) {
            if let problem {
                Text(problem)
                    .font(palette.caption)
                    .foregroundStyle(palette.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if selection.isEmpty {
                Text("Tap files to select them, then Done adds them to your message.")
                    .font(palette.caption)
                    .foregroundStyle(palette.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button {
                    finish()
                } label: {
                    Text(selection.count == 1 ? "Add 1 file to message" : "Add \(selection.count) files to message")
                        .font(palette.labelBold)
                        .foregroundStyle(palette.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(palette.accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("files-attach")
            }
        }
        .padding(.horizontal, Metrics.margin)
        .padding(.vertical, 10)
    }

    /// The rows to show: the folder tree with opened folders unfolded, or every file matching the filter.
    private func visibleEntries() -> [WorkspaceEntry] {
        _ = revision
        let files = model.files
        let query = filter.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { return files.search(query) }

        var rows: [WorkspaceEntry] = []
        var pending = Array(((try? files.list()) ?? []).reversed())
        while let entry = pending.popLast() {
            rows.append(entry)
            if entry.isDirectory, expanded.contains(entry.path) {
                pending.append(contentsOf: ((try? files.list(entry.path)) ?? []).reversed())
            }
        }
        return rows
    }

    private func toggleExpansion(_ path: String) {
        if expanded.contains(path) {
            expanded.remove(path)
        } else {
            expanded.insert(path)
        }
    }

    private func toggleSelection(_ path: String) {
        if selection.contains(path) {
            selection.remove(path)
        } else {
            selection.insert(path)
        }
    }

    /// Closes the sheet, taking the selected files along to the message box.
    private func finish() {
        model.attachWorkspaceFiles(selection.sorted())
        dismiss()
    }

    private func delete(_ entry: WorkspaceEntry) {
        do {
            try model.files.delete(entry.path)
            selection = selection.filter { $0 != entry.path && !$0.hasPrefix(entry.path + "/") }
            problem = nil
        } catch {
            problem = "Could not delete \(entry.name): \(error.localizedDescription)"
        }
        revision += 1
    }

    /// Copies files from the device into the workspace and selects them, so Done attaches them.
    private func importFiles(_ urls: [URL]) {
        isImporting = true
        problem = nil
        Task {
            let result = await model.importIntoWorkspace(urls)
            isImporting = false
            problem = result.failures.first
            if !result.paths.isEmpty { expanded.insert(Attachments.folder) }
            selection.formUnion(result.paths)
            revision += 1
        }
    }
}

private struct FilterField: View {
    @Binding var text: String
    let palette: Palette

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(palette.dim)
            TextField("", text: $text, prompt: Text("Filter files").foregroundStyle(palette.dim))
                .foregroundStyle(palette.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("files-filter")
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(palette.dim)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .font(palette.label)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .outlined(palette, fill: palette.card, radius: 12)
    }
}

private struct FileRow: View {
    let entry: WorkspaceEntry
    let palette: Palette
    /// While filtering the tree is flat, so each file says which folder it is in.
    let showsFolder: Bool
    let isExpanded: Bool
    let isSelected: Bool
    /// Opens a folder, or selects a file.
    let toggle: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 14) {
                    icon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(palette.prose)
                            .foregroundStyle(palette.text)
                            .lineLimit(1)
                        if showsFolder, !entry.folder.isEmpty {
                            Text(entry.folder)
                                .font(palette.caption)
                                .foregroundStyle(palette.dim)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .padding(.leading, Metrics.margin + CGFloat(showsFolder ? 0 : entry.depth) * 22)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("file-\(entry.path)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if !entry.isDirectory {
                Button(action: open) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.dim.opacity(0.6))
                        .frame(width: 48, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Preview \(entry.name)")
                .accessibilityIdentifier("preview-\(entry.path)")
            }
        }
        .background(isSelected ? palette.accent.opacity(0.14) : Color.clear)
    }

    @ViewBuilder
    private var icon: some View {
        if entry.isDirectory {
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.dim)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 20)
        } else if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(palette.accent)
                .frame(width: 20)
        } else {
            Image(systemName: "doc")
                .font(.system(size: 16))
                .foregroundStyle(palette.dim)
                .frame(width: 20)
        }
    }
}

/// One file: its text, with copy, share and delete, and a button to add it to the message.
private struct FileViewer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: WorkspaceEntry
    let isSelected: Bool
    let toggleSelection: () -> Void
    let delete: () -> Void
    @State private var content: String?
    @State private var isLoaded = false
    @State private var confirmsDelete = false

    var body: some View {
        let palette = model.palette
        let size = ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let content {
                    Text(content.isEmpty ? "(empty file)" : content)
                        .font(palette.mono)
                        .foregroundStyle(content.isEmpty ? palette.dim : palette.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if isLoaded {
                    ContentUnavailableView(
                        "No preview", systemImage: "doc",
                        description: Text("This is not a text file (\(size)). It can still be added to a message or shared."))
                }
            }
            .padding(Metrics.margin)
        }
        .background(palette.background.ignoresSafeArea())
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let content, !content.isEmpty {
                        Button {
                            UIPasteboard.general.string = content
                        } label: {
                            Label("Copy text", systemImage: "doc.on.doc")
                        }
                    }
                    ShareLink(item: model.workspace.appendingPathComponent(entry.path)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        confirmsDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("File actions")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                toggleSelection()
                dismiss()
            } label: {
                Text(isSelected ? "Remove from message" : "Add to message")
                    .font(palette.labelBold)
                    .foregroundStyle(isSelected ? palette.text : palette.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(isSelected ? palette.surface : palette.accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Metrics.margin)
            .padding(.vertical, 10)
            .background(palette.background)
            .accessibilityIdentifier("viewer-select")
        }
        .confirmationDialog("Delete \(entry.name)?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                delete()
                dismiss()
            }
        }
        .task {
            content = try? model.files.preview(entry.path)
            isLoaded = true
        }
    }
}
