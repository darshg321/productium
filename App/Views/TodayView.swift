import SwiftUI
import PhotosUI
import ProductiumCore

/// Today, as a column of cards on the grouped background (the Health summary layout),
/// in order of how often each is needed:
///   1. Inbox: tell it anything, or fix anything
///   2. Now: what to do this minute, and what's next
///   3. at most one question and one heads-up
///   4. three numbers for the rest of the day, then the schedule
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

// MARK: - Inbox

/// The one box. Typed text and screenshots go to Claude (lite), which returns changes;
/// the receipt says what changed, with Undo, and what it cost.
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
            if let r = model.receipt { ReceiptView(receipt: r) }
        }
        .animation(.easeOut(duration: 0.2), value: model.receipt)
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

    /// Screenshots are downscaled to ≤1280 px JPEG: plenty to read text, and image tokens scale
    /// with pixels (about w×h/750), so this keeps a screenshot near 1.5k tokens instead of 2.5k+.
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

struct ReceiptView: View {
    @Environment(AppModel.self) private var model
    let receipt: AppModel.Receipt

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(receipt.reply)
                .font(.subheadline)
                .foregroundStyle(receipt.failed ? Theme.alert : .primary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(receipt.changes, id: \.self) { c in
                Label(c, systemImage: c == "Undone" ? "arrow.uturn.backward" : "checkmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                if receipt.canUndo { Button("Undo") { withAnimation { model.undo() } } }
                Spacer()
                if let t = receipt.tokens {
                    Text("\(tokensLabel(t)) tokens").font(.caption).foregroundStyle(.tertiary)
                }
                Button("Clear") { withAnimation { model.receipt = nil } }.foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
        }
        .transition(.opacity)
    }
}

// MARK: - Now

struct NowCard: View {
    @Environment(AppModel.self) private var model
    let now: Date
    @Binding var showGap: Bool

    var body: some View {
        let current = model.state.plan.current(at: now)
        let next = model.state.plan.next(after: now)
        Card {
            if let b = current {
                CardHeader(title: "Now", symbol: Theme.symbol(for: b.kind), color: Theme.color(for: b.kind),
                           detail: "until \(b.end.hm)")
            } else {
                CardHeader(title: "Now", symbol: "clock.fill", color: .secondary)
            }
            content(current)
            if let n = next, n.kind != .sleep {
                Divider()
                HStack(spacing: 8) {
                    Circle().fill(Theme.color(for: n.kind)).frame(width: 8, height: 8)
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
            ProgressView(value: progress(b)).tint(Theme.color(for: b.kind))
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
            ProgressView(value: progress(b)).tint(Theme.color(for: b.kind))
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

/// Short, human labels for plan blocks.
func blockLabel(_ b: PlannedBlock) -> String {
    switch b.kind {
    case .free, .gap: return "Free time"
    case .breakTime: return "Break"
    case .windDown: return "Wind down, screens off"
    case .sleep: return "Bed"
    default: return b.title
    }
}

// MARK: - One question, one heads-up

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

// MARK: - The rest of the day

/// Three numbers, side by side: work left, free time left, bedtime.
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

/// The day from now to bed: a strip to scale, then one row per block.
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
            RoundedRectangle(cornerRadius: 2).fill(Theme.color(for: block.kind)).frame(width: 4, height: 34)
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
