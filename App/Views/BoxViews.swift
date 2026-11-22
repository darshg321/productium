import SwiftUI
import PhotosUI
import ProductiumCore

struct DumpBox: View {
    @Environment(AppModel.self) private var model
    @State private var picks: [PhotosPickerItem] = []
    @FocusState private var focused: Bool
    /// Typing stays in the view: writing each keystroke to `model.state` re-rendered every screen reading the state.
    /// The draft is saved once typing pauses, on send, and when the box goes away.
    @State private var text = ""
    @State private var loaded = false
    @State private var saveDraft: Task<Void, Never>?

    var body: some View {
        Card {
            let images = model.draftImages
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(images) { pic in
                            Image(uiImage: pic.image).resizable().scaledToFill()
                                .frame(width: 54, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    Button { model.removeDraftImage(pic.file) } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                    .padding(3)
                                    .accessibilityLabel("Remove image")
                                }
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                PhotosPicker(selection: $picks, maxSelectionCount: 6, matching: .images) {
                    Image(systemName: "photo.on.rectangle.angled").font(.title3).frame(height: 36)
                }
                .accessibilityLabel("Add screenshots")
                TextField("What's due, what happened, what changed?", text: $text, axis: .vertical)
                    .font(.body)
                    .lineLimit(1...8)
                    .focused($focused)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                if model.busy.contains("dump") {
                    ProgressView().frame(width: 32, height: 36)
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                            .foregroundStyle(canSend ? Color.accentColor : Color(.systemGray3))
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("Send")
                }
            }
            .buttonStyle(.borderless)
            if !model.state.conversation.isEmpty { ThreadView() }
        }
        .animation(.easeOut(duration: 0.2), value: model.state.conversation.turns.count)
        .onChange(of: picks) { _, items in Task { await load(items) } }
        .onAppear {
            if !loaded { text = model.draftText; loaded = true }
        }
        .onChange(of: model.draftText) { _, new in if new != text && saveDraft == nil { text = new } }
        .onChange(of: text) { _, new in
            saveDraft?.cancel()
            saveDraft = Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                storeDraft(new)
            }
        }
        .onChange(of: focused) { _, on in
            model.boxFocused = on
            if !on { storeDraft(text) }
        }
        .onDisappear { storeDraft(text) }
    }

    private func storeDraft(_ t: String) {
        saveDraft?.cancel()
        saveDraft = nil
        if model.draftText != t { model.draftText = t }
    }

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.state.draft.imageFiles.isEmpty }

    private func send() {
        let t = text, imgs = model.draftImages.map(\.ai)
        storeDraft(t)
        focused = false
        Task {
            if await model.submit(t, images: imgs, source: .app) {
                model.clearDraft()
                text = ""
                picks = []
            }
        }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        var out: [Data] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) else { continue }
            let scale = min(1, 1280 / max(img.size.width, img.size.height))
            let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
            if let jpg = small.jpegData(compressionQuality: 0.75) { out.append(jpg) }
        }
        model.addDraftImages(out)
        picks = []
    }
}

struct ThreadView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    var body: some View {
        let turns = model.state.conversation.turns
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            if turns.count > 1 {
                Button(expanded ? "Show Only the Latest" : "Show All \(turns.count) Prompts") {
                    withAnimation { expanded.toggle() }
                }
                .font(.footnote)
                .buttonStyle(.borderless)
            }
            ForEach(expanded ? turns : Array(turns.suffix(1))) { t in
                TurnView(turn: t)
            }
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                let convo = model.state.conversation
                let expired = convo.cacheExpired(now: ctx.date)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Spacer()
                        Button(convo.clearTitle) { withAnimation { model.clearConversation() } }
                            .font(.subheadline)
                            .foregroundStyle(expired ? Theme.alert : .secondary)
                            .buttonStyle(.borderless)
                    }
                    if let line = convo.outputLine {
                        Text(line).font(.caption2).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    if let note = convo.cacheNote(now: ctx.date) {
                        Text(note).font(.caption).foregroundStyle(Theme.alert)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .transition(.opacity)
    }
}

struct TurnView: View {
    @Environment(AppModel.self) private var model
    let turn: ConversationTurn
    @State private var showCall: AICall?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .trailing, spacing: 6) {
                if !turn.images.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(turn.images.indices, id: \.self) { i in
                            if let data = Data(base64Encoded: turn.images[i].base64), let img = UIImage(data: data) {
                                Image(uiImage: img).resizable().scaledToFill()
                                    .frame(width: 40, height: 54)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                        }
                    }
                }
                if !turn.text.isEmpty {
                    Text(turn.text)
                        .font(.subheadline)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            Text(turn.reply)
                .font(.subheadline)
                .foregroundStyle(turn.failed ? Theme.alert : .primary)
                .fixedSize(horizontal: false, vertical: true)
            if let d = turn.detail {
                DisclosureGroup("Details") {
                    Text(d).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.footnote)
            }
            ForEach(Array((turn.queries ?? []).enumerated()), id: \.offset) { _, q in
                LiveChart(query: q, title: turn.text.isEmpty ? nil : String(turn.text.prefix(60)))
            }
            ForEach(turn.applied.changes, id: \.self) { c in
                Label(c, systemImage: c.hasPrefix("(undone)") ? "arrow.uturn.backward" : "checkmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(turn.applied.problems, id: \.self) { p in
                Label(p, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            ForEach(model.approvals.filter { $0.turnId == turn.id }) { a in
                ApprovalRow(approval: a)
            }
            HStack(spacing: 16) {
                if model.undoTurnId == turn.id { Button("Undo") { withAnimation { model.undo() } } }
                if let c = model.call(turn.callId) {
                    Button("Prompt") { showCall = c }.foregroundStyle(.secondary)
                }
                Spacer()
                if let t = turn.tokens {
                    Text("\(tokensLabel(t.counted)) tokens out").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
        }
        .sheet(item: $showCall) { c in
            NavigationStack {
                AICallDetailView(call: c)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showCall = nil } } }
            }
        }
    }
}

/// One Approve / Decline (0.3, J2): a risky box change or an alarm the insight pass proposed.
struct ApprovalRow: View {
    @Environment(AppModel.self) private var model
    let approval: Approval

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(approval.why, systemImage: approval.addsAlarm ? "alarm" : "hand.raised")
                .font(.footnote).foregroundStyle(.orange)
            if approval.addsAlarm && !model.state.integrations.alarms {
                Text("Full-Screen Alarms are off. Allow turns them on.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(approval.addsAlarm ? "Allow" : "Approve") { withAnimation { model.approve(approval.id) } }
                    .buttonStyle(.borderedProminent)
                Button(approval.addsAlarm ? "No" : "Decline") { withAnimation { model.decline(approval.id) } }
                    .buttonStyle(.bordered)
            }
            .font(.subheadline)
        }
    }
}
