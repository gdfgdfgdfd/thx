import SwiftUI
import TermCore

/// Lists saved sessions so the conversation can be switched without typing `/sessions`.
struct SessionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        model.newSession()
                    } label: {
                        Label("New session", systemImage: "plus")
                    }
                    .disabled(model.isRunning)
                } footer: {
                    if model.isRunning {
                        Text("Stop the current run to start or switch sessions.")
                    }
                }

                if !model.sessionList.isEmpty {
                    Section("Recent") {
                        ForEach(model.sessionList) { summary in
                            let isCurrent = summary.id == model.session.id
                            Button {
                                model.switchSession(summary.id)
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(summary.title).foregroundStyle(.primary).lineLimit(1)
                                        Text(summary.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    if isCurrent {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isRunning && !isCurrent)
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) {
                                    model.deleteSession(summary.id)
                                }
                                .disabled(model.isRunning && isCurrent)
                            }
                        }
                    }
                }
            }
            .overlay {
                if model.sessionList.isEmpty {
                    ContentUnavailableView(
                        "No saved sessions", systemImage: "rectangle.stack",
                        description: Text("A session is saved once it has a first message."))
                        .allowsHitTesting(false)
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
