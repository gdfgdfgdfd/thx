import SwiftUI
import TermCore

/// Picks the model, across every connection. A model ID that is not listed can be typed in and used.
struct ModelsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        let palette = model.palette
        let needle = query.trimmingCharacters(in: .whitespaces)

        NavigationStack {
            List {
                if let profile = model.activeProfile, !needle.isEmpty, !profile.models.contains(needle) {
                    Section {
                        Button {
                            choose(needle, in: profile.id)
                        } label: {
                            Label("Use “\(needle)”", systemImage: "plus")
                        }
                        .accessibilityIdentifier("models-use-custom")
                    } footer: {
                        Text("Adds this model ID to \(profile.name).")
                    }
                    .listRowBackground(palette.surface)
                }

                ForEach(model.profiles) { profile in
                    let ids = needle.isEmpty ? profile.models : profile.models.filter { $0.localizedCaseInsensitiveContains(needle) }
                    if !ids.isEmpty {
                        Section(profile.name) {
                            ForEach(ids, id: \.self) { id in
                                Button {
                                    choose(id, in: profile.id)
                                } label: {
                                    HStack {
                                        Text(id).foregroundStyle(palette.text)
                                        Spacer(minLength: 8)
                                        if profile.id == model.activeProfile?.id, id == model.activeModel {
                                            Image(systemName: "checkmark").foregroundStyle(palette.accent)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .listRowBackground(palette.surface)
                    }
                }

                Section {
                    Button {
                        model.openSettings()
                    } label: {
                        Label("Manage connections", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("models-manage")
                } footer: {
                    if model.profiles.isEmpty {
                        Text("Add a connection to an OpenAI-compatible gateway to get its models.")
                    }
                }
                .listRowBackground(palette.surface)
            }
            .sheetPage(palette)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search or enter a model ID")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func choose(_ id: String, in profileID: UUID) {
        model.select(model: id, in: profileID)
        dismiss()
    }
}

/// Finds a session by its title or by anything said in it.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        let palette = model.palette
        let isSearching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let matches = model.searchSessions(query)

        NavigationStack {
            List {
                if !matches.isEmpty {
                    Section(isSearching ? "\(matches.count) found" : "All sessions") {
                        ForEach(matches) { match in
                            Button {
                                model.switchSession(match.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(match.title).foregroundStyle(palette.text).lineLimit(1)
                                        Spacer(minLength: 8)
                                        Text(RelativeTime.short(match.updatedAt))
                                            .font(.caption)
                                            .foregroundStyle(palette.dim)
                                            .fixedSize()
                                    }
                                    if let snippet = match.snippet {
                                        Text(snippet).font(.footnote).foregroundStyle(palette.dim).lineLimit(2)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("search-result")
                        }
                    }
                    .listRowBackground(palette.surface)
                }
            }
            .sheetPage(palette)
            .overlay {
                if matches.isEmpty {
                    ContentUnavailableView(
                        isSearching ? "No sessions found" : "No sessions yet",
                        systemImage: "magnifyingglass",
                        description: Text(isSearching ? "Nothing was said about that in any saved session."
                                                      : "A session is saved once it has a first message."))
                        .allowsHitTesting(false)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search sessions")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
