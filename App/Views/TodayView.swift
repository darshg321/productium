import SwiftUI
import PhotosUI
import ProductiumCore

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Binding var showGap: Bool

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                let now = ctx.date
                let bed = bedtime(now)
                let rest = model.state.plan.blocks.filter { $0.end > now && $0.start < bed && $0.kind != .sleep }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        DumpBox()
                        if let g = model.dueGap { GapQuestionCard(gap: g) }
                        if !model.state.proposals.pending.isEmpty { ProposalsCard() }
                        NowCard(now: now, showGap: $showGap)
                        Attention(now: now)
                        SectionTitle("Rest of Today")
                        DayNumbers(blocks: rest, now: now, bed: bed)
                        ScheduleCard(blocks: rest, from: now, bed: bed)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .background(Theme.background)
            .refreshable { await model.refresh() }
            .navigationTitle("Today")
            .usageMeter()
        }
    }

    private func bedtime(_ now: Date) -> Date {
        model.state.plan.blocks.first { $0.kind == .sleep && $0.end > now }?.start ?? now.addingTimeInterval(16 * 3600)
    }
}

struct DumpBox: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var picks: [PhotosPickerItem] = []
    @State private var images: [(UIImage, AIImage)] = []
    @FocusState private var focused: Bool

    var body: some View {
        Card {
            CardHeader(title: "Inbox", symbol: "tray.and.arrow.down.fill", color: .blue,
                       detail: model.busy.contains("dump") ? "Reading…" : nil)
            TextField("What's due, what happened, what changed?", text: $text, axis: .vertical)
                .font(.body)
                .lineLimit(2...8)
                .focused($focused)
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(images.indices, id: \.self) { i in
                            Image(uiImage: images[i].0).resizable().scaledToFill()
                                .frame(width: 54, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    Button { images.remove(at: i) } label: {
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
            HStack {
                PhotosPicker(selection: $picks, maxSelectionCount: 6, matching: .images) {
                    Image(systemName: "photo.on.rectangle").font(.title3)
                }
                .accessibilityLabel("Add screenshots")
                Spacer()
                if model.busy.contains("dump") {
                    ProgressView()
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.title)
                            .symbolRenderingMode(.hierarchical)
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
    }

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty }

    private func send() {
        let t = text, imgs = images.map(\.1)
        focused = false
        Task {
            if await model.dump(t, images: imgs) {
                text = ""
                images = []
                picks = []
            }
        }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        var out: [(UIImage, AIImage)] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) else { continue }
            let scale = min(1, 1280 / max(img.size.width, img.size.height))
            let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
            if let jpg = small.jpegData(compressionQuality: 0.75) {
                out.append((small, AIImage(mediaType: "image/jpeg", base64: jpg.base64EncodedString())))
            }
        }
        images = out
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
            HStack {
                let stats = model.state.conversation.tokenStats
                if stats.size > 0 {
                    Text("\(tokensLabel(stats.size)) tokens in this conversation")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Clear") { withAnimation { model.clearConversation() } }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.borderless)
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

struct ProposalsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let pending = model.state.proposals.pending
        let runId = pending.first?.runId
        let note = model.state.proposals.runs.first { $0.id == runId }?.note
        Card {
            CardHeader(title: "Productium suggests \(pending.count) change\(pending.count == 1 ? "" : "s")",
                       symbol: "sparkles", color: .purple)
            if let note { Text(note).font(.subheadline).fixedSize(horizontal: false, vertical: true) }
            ForEach(pending) { p in ProposalRow(proposal: p) }
            if let runId, pending.count > 1 {
                HStack {
                    Button("Approve All") { model.approveRun(runId) }
                    Spacer()
                    Button("Reject All", role: .destructive) { model.rejectRun(runId) }
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
            }
        }
    }
}

struct ProposalRow: View {
    @Environment(AppModel.self) private var model
    let proposal: BehaviourProposal

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text(proposal.title).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Text(proposal.reason).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if proposal.status == .pending {
                HStack(spacing: 16) {
                    Button("Approve") { model.approveProposal(proposal.id) }
                    Button("Reject") { model.rejectProposal(proposal.id) }.foregroundStyle(.secondary)
                    Spacer()
                    Menu { Button("Never Change This") { model.neverChange(proposal.id) } } label: { Image(systemName: "ellipsis") }
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
            }
        }
    }
}

struct GapQuestionCard: View {
    @Environment(AppModel.self) private var model
    let gap: MysteryGap
    @State private var answer = ""

    var body: some View {
        Card {
            CardHeader(title: GapDetector.question(gap, calendar: .current), symbol: "questionmark.circle.fill", color: .purple)
            HStack {
                TextField("e.g. gym, homework, with friends", text: $answer)
                    .submitLabel(.send)
                    .onSubmit(send)
                Button("Send", action: send).disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty)
                Button { model.dismissGap(gap) } label: { Image(systemName: "xmark") }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Not now")
            }
            .buttonStyle(.borderless)
        }
    }

    private func send() {
        let t = answer
        answer = ""
        Task { await model.answerGap(t, gap: gap) }
    }
}

struct NowCard: View {
    @Environment(AppModel.self) private var model
    let now: Date
    @Binding var showGap: Bool

    var body: some View {
        let current = model.state.plan.current(at: now)
        let next = model.state.plan.next(after: now)
        Card {
            if let b = current {
                CardHeader(title: "Now", symbol: Theme.symbol(for: b.kind), color: Theme.color(for: b),
                           detail: "until \(b.end.hm)")
            } else {
                CardHeader(title: "Now", symbol: "clock.fill", color: .secondary)
            }
            content(current)
            if let n = next, n.kind != .sleep {
                Divider()
                HStack(spacing: 8) {
                    Circle().fill(Theme.color(for: n)).frame(width: 8, height: 8)
                    Text("Next: \(blockLabel(n))").font(.subheadline).lineLimit(1)
                    Spacer()
                    Text(n.start.hm).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func content(_ current: PlannedBlock?) -> some View {
        if let b = current, b.isStudy {
            Text(b.title).font(.title2.weight(.bold)).fixedSize(horizontal: false, vertical: true)
            Text("\(minutesLeft(b)) min left" + (b.hint.map { " · \($0)" } ?? ""))
                .font(.subheadline).foregroundStyle(.secondary)
            ProgressView(value: progress(b)).tint(Theme.color(for: b))
            Button { model.startFocus(b) } label: {
                Text("Start Focus").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
        } else if let b = current, b.kind == .gap || b.kind == .breakTime || (b.kind == .free && minutesLeft(b) <= 20) {
            BigValue(value: "\(minutesLeft(b))", unit: "free minutes")
            Button { showGap = true } label: {
                Text("Use Them for Something Short").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        } else if let b = current, b.kind == .free {
            Text("Free time").font(.title2.weight(.bold))
            Text("Nothing to do until \(b.end.hm). Enjoy it.").font(.subheadline).foregroundStyle(.secondary)
        } else if let b = current {
            Text(blockLabel(b)).font(.title2.weight(.bold))
            ProgressView(value: progress(b)).tint(Theme.color(for: b))
        } else {
            Text("Nothing planned").font(.title2.weight(.bold))
            Text("Tell the Inbox what's coming up and it'll plan it.").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func minutesLeft(_ b: PlannedBlock) -> Int { max(1, Int(b.end.timeIntervalSince(now) / 60)) }

    private func progress(_ b: PlannedBlock) -> Double {
        let total = b.end.timeIntervalSince(b.start)
        return total > 0 ? min(1, max(0, now.timeIntervalSince(b.start) / total)) : 0
    }
}

func blockLabel(_ b: PlannedBlock) -> String {
    switch b.kind {
    case .free, .gap: return "Free time"
    case .breakTime: return "Break"
    case .windDown: return "Wind down, screens off"
    case .sleep: return "Bed"
    default: return b.title
    }
}

struct Attention: View {
    @Environment(AppModel.self) private var model
    let now: Date

    var body: some View {
        if let b = model.pendingOutcomes.last {
            Card {
                CardHeader(title: "Check-in", symbol: "checkmark.bubble.fill", color: .green, detail: b.start.relativeDay.capitalized)
                Text("Did you get to \(b.title)?").font(.headline).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button { model.logOutcome(blockId: b.id, status: .done) } label: { Text("Yes").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                    Button { model.logOutcome(blockId: b.id, status: .partial) } label: { Text("Partly").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                    Button { model.logOutcome(blockId: b.id, status: .skipped) } label: { Text("No").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                }
                .controlSize(.regular)
            }
        }
        if let expiry = model.signatureExpiry, expiry.timeIntervalSince(now) < 2 * 86400 {
            Card {
                CardHeader(title: "Refresh Needed", symbol: "exclamationmark.triangle.fill", color: Theme.alert)
                Text("This build stops opening \(expiry.relativeDay) at \(expiry.hm). Refresh it in SideStore.")
                    .font(.subheadline)
            }
        } else if model.supportSuggested {
            Card {
                CardHeader(title: "Checking In", symbol: "heart.fill", color: .pink)
                Text(Wellbeing.crisisText).font(.subheadline).foregroundStyle(.secondary)
            }
        } else if let w = model.activeWarnings.first(where: { $0.level != .info }) ?? model.activeWarnings.first {
            Card {
                CardHeader(title: "Heads Up", symbol: w.level == .critical ? "exclamationmark.triangle.fill" : "info.circle.fill",
                           color: w.level == .critical ? Theme.alert : .orange)
                Text(w.message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                Button("Dismiss") { model.state.dismissed.insert(w.message); model.save() }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
            }
        }
    }
}

struct DayNumbers: View {
    let blocks: [PlannedBlock]
    let now: Date
    let bed: Date

    var body: some View {
        let work = blocks.filter(\.isStudy).reduce(0) { $0 + remaining($1) }
        let free = blocks.filter { $0.kind == .free || $0.kind == .gap }.reduce(0) { $0 + remaining($1) }
        HStack(spacing: 10) {
            stat("Work", "pencil.line", Theme.focus, work > 0 ? durationLabel(work) : "Done")
            stat("Free", "sun.max.fill", Theme.free, durationLabel(free))
            stat("Bed", "moon.fill", Theme.sleep, bed.hm)
        }
    }

    private func remaining(_ b: PlannedBlock) -> Int { max(0, Int(b.end.timeIntervalSince(max(b.start, now)) / 60)) }

    private func stat(_ title: String, _ symbol: String, _ color: Color, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(color)
            Text(value).font(.system(.headline, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct ScheduleCard: View {
    let blocks: [PlannedBlock]
    let from: Date
    let bed: Date

    var body: some View {
        let shown = blocks.filter { $0.kind != .breakTime && $0.minutes >= 10 }
        Card {
            DayStrip(blocks: blocks, start: from, end: bed)
            HStack {
                Text(from.hm)
                Spacer()
                Text(bed.hm)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            if shown.isEmpty {
                Text("Nothing else before bed.").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 4)
            }
            ForEach(shown) { b in
                Divider()
                BlockRow(block: b, from: from)
            }
        }
    }
}

struct BlockRow: View {
    let block: PlannedBlock
    var from: Date = .distantPast

    var body: some View {
        let start = max(block.start, from)
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(Theme.color(for: block)).frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(blockLabel(block))
                    .font(block.isStudy ? .body.weight(.semibold) : .body)
                    .foregroundStyle(block.isStudy ? .primary : .secondary)
                    .lineLimit(2)
                Text("\(start.hm) – \(block.end.hm) · \(durationLabel(max(1, Int(block.end.timeIntervalSince(start) / 60))))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if block.borrowsSleep {
                    Label("Uses an hour of sleep, only because it's due.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.alert)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
