import SwiftUI
import ProductiumCore

/// The main way in. One line, typed or dictated (keyboard mic). Anything goes:
/// "chem test fri ch 4-5", "left home", "soccer mon wed 4-6", "finished math", "tired".
struct QuickAddSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private let quick = ["Left home", "At school", "Left school", "Home", "Starting homework", "Finished homework"]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                TextField("What's new?", text: $text, axis: .vertical)
                    .font(.title3)
                    .lineLimit(1...4)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(14)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
                Text("e.g. “bio quiz thursday on cells” · “debate tue 3:30–5” · “essay done” · “stressed”")
                    .font(.caption).foregroundStyle(.secondary)

                SectionTitle("Check in")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(quick, id: \.self) { q in
                            Button(q) { model.logMarker(q); model.toast = "Logged · \(q)"; dismiss() }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                SectionTitle("Mood")
                MoodPicker(selected: model.todayMood?.mood) { model.logMood($0, energy: nil, note: nil); dismiss() }
                Spacer()
                NavigationLink { TaskDetailView(itemId: nil) } label: {
                    Label("Add a task manually", systemImage: "square.and.pencil").font(.subheadline)
                }
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if model.busy.contains("add") { ProgressView() } else {
                        Button("Send", action: send).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear { focused = true }
        }
    }

    private func send() {
        let t = text
        Task {
            await model.submit(t)
            dismiss()
        }
    }
}
