import SwiftUI
import PhotosUI
import ProductiumCore

/// Today, top to bottom, in order of how often it's needed:
///   1. the box: tell it anything, or fix anything
///   2. what to do now
///   3. at most one question and one warning
///   4. the rest of the day, drawn to scale
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Binding var showGap: Bool
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                let now = ctx.date
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        header(now)
                        DumpBox()
                        NowLine(now: now, showGap: $showGap)
                        Attention(now: now)
                        DayRuler(from: now, blocks: model.state.plan.blocks.filter { $0.end > now && $0.start < bedtime(now) })
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .refreshable { await model.refresh() }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
        }
    }

    private func bedtime(_ now: Date) -> Date {
        model.state.plan.blocks.first { $0.kind == .sleep && $0.end > now }?.start ?? now.addingTimeInterval(16 * 3600)
    }

    private func header(_ now: Date) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(now.formatted(.dateTime.weekday(.wide))).font(.display(34, .bold))
            Text(now.formatted(.dateTime.month(.abbreviated).day())).font(.title3).foregroundStyle(.secondary)
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").font(.title3).foregroundStyle(.secondary)
            }
            .accessibilityLabel("Settings")
        }
        .padding(.top, 16)
    }
}

// MARK: - The box

struct DumpBox: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var picks: [PhotosPickerItem] = []
    @State private var images: [(UIImage, AIImage)] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("What's due, what happened, what changed?")
                        .font(.display(20, .regular))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                }
                TextField("", text: $text, axis: .vertical)
                    .font(.display(20, .regular))
                    .lineLimit(3...10)
                    .focused($focused)
                    .submitLabel(.return)
            }
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(images.indices, id: \.self) { i in
                            Image(uiImage: images[i].0).resizable().scaledToFill()
                                .frame(width: 56, height: 76).clipped()
                                .overlay(alignment: .topTrailing) {
                                    Button { images.remove(at: i) } label: {
                                        Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.white)
                                            .frame(width: 20, height: 20).background(.black.opacity(0.6))
                                    }
                                    .accessibilityLabel("Remove image")
                                }
                        }
                    }
                }
            }
            HStack(spacing: 18) {
                PhotosPicker(selection: $picks, maxSelectionCount: 6, matching: .images) {
                    Label("Screenshot", systemImage: "photo").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy.contains("dump") {
                    ProgressView()
                } else {
                    Button(action: send) {
                        Text("Send").font(.body.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 20).frame(height: 40)
                            .background(canSend ? Theme.cobalt : Color.gray.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.radius))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
            }
            if let r = model.receipt { ReceiptView(receipt: r) }
        }
        .padding(16)
        .background(Theme.fog.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(alignment: .leading) {
            Rectangle().fill(focused ? Theme.cobalt : .clear).frame(width: 3)
        }
        .animation(.easeOut(duration: 0.2), value: focused)
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

    /// Screenshots are downscaled to ≤1600 px JPEG: plenty to read text, small to send.
    private func load(_ items: [PhotosPickerItem]) async {
        var out: [(UIImage, AIImage)] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) else { continue }
            let scale = min(1, 1600 / max(img.size.width, img.size.height))
            let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
            let small = UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
            if let jpg = small.jpegData(compressionQuality: 0.8) {
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
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.vertical, 4)
            Text(receipt.reply)
                .font(.subheadline)
                .foregroundStyle(receipt.failed ? Theme.signal : .primary)
                .fixedSize(horizontal: false, vertical: true)
            if !receipt.changes.isEmpty {
                Text(receipt.changes.joined(separator: "\n")).font(.footnote).foregroundStyle(.secondary)
            }
            HStack(spacing: 20) {
                if receipt.canUndo { TextAction("Undo") { withAnimation { model.undo() } } }
                Spacer()
                TextAction("Clear", color: .secondary) { withAnimation { model.receipt = nil } }
            }
            .font(.subheadline)
            .padding(.top, 2)
        }
        .transition(.opacity)
    }
}

// MARK: - Now

struct NowLine: View {
    @Environment(AppModel.self) private var model
    let now: Date
    @Binding var showGap: Bool

    var body: some View {
        let current = model.state.plan.current(at: now)
        VStack(alignment: .leading, spacing: 10) {
            if let b = current, b.isStudy {
                Text(b.title).font(.display(26, .semibold)).fixedSize(horizontal: false, vertical: true)
                Text("\(minutesLeft(b)) min left" + (b.hint.map { ". \($0)" } ?? ""))
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Start") { model.startFocus(b) }.buttonStyle(SlabButtonStyle())
            } else if let b = current, b.kind == .gap || b.kind == .breakTime || (b.kind == .free && minutesLeft(b) <= 20) {
                Text("\(minutesLeft(b)) free minutes").font(.display(26, .semibold))
                TextAction("Use them for something short") { showGap = true }
            } else if let b = current, b.kind == .free {
                Text("Free until \(b.end.hm)").font(.display(26, .semibold))
            } else if let b = current {
                Text(b.title).font(.display(26, .semibold))
                Text("until \(b.end.hm)").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("Nothing planned right now").font(.display(26, .semibold))
            }
        }
    }

    private func minutesLeft(_ b: PlannedBlock) -> Int { max(1, Int(b.end.timeIntervalSince(now) / 60)) }
}

// MARK: - One question, one warning

struct Attention: View {
    @Environment(AppModel.self) private var model
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let b = model.pendingOutcomes.last {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Did you get to \(b.title)?").font(.body)
                    HStack(spacing: 24) {
                        TextAction("Yes") { model.logOutcome(blockId: b.id, status: .done) }
                        TextAction("Partly") { model.logOutcome(blockId: b.id, status: .partial) }
                        TextAction("No", color: .secondary) { model.logOutcome(blockId: b.id, status: .skipped) }
                    }
                }
            }
            if let expiry = model.signatureExpiry, expiry.timeIntervalSince(now) < 2 * 86400 {
                Text("This build stops opening \(expiry.relativeDay) at \(expiry.hm). Refresh it in SideStore.")
                    .font(.subheadline).foregroundStyle(Theme.signal)
            } else if model.supportSuggested {
                Text(Wellbeing.crisisText).font(.subheadline).foregroundStyle(.secondary)
            } else if let w = model.activeWarnings.first(where: { $0.level != .info }) ?? model.activeWarnings.first {
                Text(w.message)
                    .font(.subheadline)
                    .foregroundStyle(w.level == .critical ? Theme.signal : .secondary)
                    .onTapGesture { model.state.dismissed.insert(w.message); model.save() }
            }
        }
    }
}

// MARK: - The day, to scale

/// Blocks drawn with height proportional to duration. The bar's colour says what the
/// time is for (cobalt focus, daylight free, fog fixed, night sleep), and the label
/// says what exactly.
struct DayRuler: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let from: Date
    let blocks: [PlannedBlock]
    var pointsPerMinute: CGFloat = 0.9

    var body: some View {
        let shown = blocks.filter { $0.kind != .breakTime && $0.kind != .sleep && $0.minutes >= 10 }
        VStack(alignment: .leading, spacing: 2) {
            ForEach(shown) { b in
                let start = max(b.start, from)
                let mins = max(1, Int(b.end.timeIntervalSince(start) / 60))
                HStack(alignment: .top, spacing: 12) {
                    Text(start.hm).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .trailing)
                    Rectangle().fill(Theme.color(for: b.kind)).frame(width: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label(b)).font(b.isStudy ? .subheadline.weight(.semibold) : .subheadline)
                            .foregroundStyle(b.isStudy ? .primary : .secondary)
                        if b.borrowsSleep { Text("Uses an hour of sleep. Only because it's due.").font(.caption).foregroundStyle(Theme.signal) }
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: max(26, CGFloat(mins) * pointsPerMinute), alignment: .top)
            }
            if let bed = blocks.first(where: { $0.kind == .sleep }) {
                HStack(spacing: 12) {
                    Text(bed.start.hm).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 58, alignment: .trailing)
                    Rectangle().fill(Theme.night).frame(width: 6, height: 26)
                    Text("Bed").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.4), value: blocks.map(\.id))
    }

    private func label(_ b: PlannedBlock) -> String {
        switch b.kind {
        case .free, .gap: return "Free"
        case .windDown: return "Wind down, screens off"
        default: return b.title
        }
    }
}
