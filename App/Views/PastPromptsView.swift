import SwiftUI
import ProductiumCore

struct PastPromptsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        let found = model.state.archive.search(query)
        List {
            if found.isEmpty {
                Section {
                    Text(query.isEmpty ? "Conversations you clear from the Inbox are kept here." : "Nothing matches “\(query)”.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(found) { c in
                        NavigationLink { PastConversationView(id: c.id) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(c.title ?? c.suggestedTitle).lineLimit(2)
                                Text("\((c.archivedAt ?? c.startedAt).formatted(date: .abbreviated, time: .shortened)) · \(c.turns.count) prompt\(c.turns.count == 1 ? "" : "s") · \(tokensLabel(c.tokenStats.size)) tokens")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { model.deleteArchivedConversation(found[i].id) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Search prompts and replies")
        .navigationTitle("Past Prompts")
    }
}

struct PastConversationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var confirmDelete = false

    var body: some View {
        if let c = model.state.archive.conversations.first(where: { $0.id == id }) {
            List {
                Section {
                    ForEach(c.turns) { t in
                        TurnView(turn: t).padding(.vertical, 4)
                    }
                } footer: {
                    Text("\(tokensLabel(c.tokenStats.size)) tokens carried by the last request · \(tokensLabel(c.tokenStats.outputTotal)) written in total.")
                }
                Section {
                    Button("Resume This Conversation") {
                        model.resumeConversation(id)
                        dismiss()
                    }
                    Button("Delete", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Resuming makes it the Inbox's conversation again. The current one is archived.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(c.title ?? c.suggestedTitle)
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Delete this conversation?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    model.deleteArchivedConversation(id)
                    dismiss()
                }
            }
        } else {
            ContentUnavailableView("Gone", systemImage: "tray")
        }
    }
}
