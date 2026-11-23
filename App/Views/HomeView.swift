import SwiftUI
import Charts
import ProductiumCore

// v1.3 C1: Home is "now", top to bottom: what's running, the box, anything waiting on you, Start / Switch To, mood,
// "What were you doing?", assumed time to confirm, today's rings, then Up Next. How the day and week went is Review.

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @State private var now = Date()
    /// The cards below the box recompute the day's log; they refresh every 30 s, but not while you type.
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                Spacer(minLength: 8)
                                if let w = model.aiWorking {
                                    Label(w, systemImage: "sparkles")
                                        .font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                                        .symbolEffect(.pulse, options: .repeating)
                                        .transition(.opacity)
                                }
                            }
                            .padding(.horizontal, 4)
                            .animation(.default, value: model.aiWorking)
                            if let r = model.running { RunningCard(entry: r, now: now) }
                            DumpBox()
                            AlertCard(now: now)
                            ForEach(model.approvals.filter { $0.turnId == nil }) { a in Card { ApprovalRow(approval: a) } }
                            if let q = model.state.inference.pending.first { QuestionCard(question: q) }
                            if model.screenshotOffer != nil { ScreenshotOfferCard() }
                        }
                        StartList(now: now).id("grid")
                        FocusCard(now: now)
                        MoodButtons(now: now)
                        GapsCard(now: now).id("gaps")
                        AssumedCard(now: now).id("assumed")
                        RingsCard(now: now).id("ring")
                        UpNextCard(now: now).id("upnext")
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.scrollTarget) { _, t in if let t { proxy.scrollTo(t, anchor: .top) } }
            }
            .background(Theme.background)
            .refreshable {
                await model.refresh(full: false, force: true)
                now = Date()
                Task { await model.refreshRemote() }
            }
            .onReceive(tick) { t in if !model.boxFocused { now = t } }
            .onChange(of: model.state.entries.count) { _, _ in now = Date() }
            .navigationTitle("Today")
            .usageMeter()
        }
    }
}

// MARK: - D1 / D6: what's running (design E: one row above the box)

struct RunningCard: View {
    @Environment(AppModel.self) private var model
    let entry: Entry
    let now: Date
    @State private var movingStart = false

    var body: some View {
        let tree = model.state.categories
        let color = Theme.color(category: entry.category, tree: tree)
        HStack(spacing: 12) {
            Image(systemName: Theme.symbol(category: entry.category, tree: tree))
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(color, in: Circle())
                .symbolEffect(.pulse, options: .repeating)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.headline).lineLimit(1)
                Button { movingStart = true } label: {
                    Text(model.goalLine(for: entry) ?? "Started \(entry.start.hm)")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Change when it started")
            }
            Spacer(minLength: 6)
            Text(timerInterval: entry.start...Date.distantFuture, countsDown: false)
                .font(.system(.title2, design: .rounded).monospacedDigit().weight(.semibold))
                .frame(maxWidth: 104, alignment: .trailing)
            if let t = entry.taskId, model.state.items.contains(where: { $0.id == t && $0.isOpen }) {
                Menu {
                    Button("15 More Minutes", systemImage: "plus") { model.extend(t, minutes: 15) }
                    Button("30 More Minutes", systemImage: "plus") { model.extend(t, minutes: 30) }
                    Button("Finish Tomorrow", systemImage: "arrow.uturn.forward") { model.finishTomorrow(t) }
                } label: { circle("plus", .blue) }
                    .accessibilityLabel("Needs more time")
                Button { model.complete(t) } label: { circle("checkmark", .green) }
                    .accessibilityLabel("Done")
            }
            Button { model.stopRunning(source: "home") } label: { circle("stop.fill", .red) }
                .accessibilityLabel("Stop \(entry.title)")
        }
        .buttonStyle(TilePress())
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .sheet(isPresented: $movingStart) {
            StartTimeSheet(title: "\(entry.title) Started", initial: entry.start) { model.moveRunningStart(to: $0) }
        }
    }

    private func circle(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(color, in: Circle())
    }
}

// MARK: - Design E: Start / Switch To as a list, filtered by group

struct StartList: View {
    @Environment(AppModel.self) private var model
    let now: Date
    @State private var filter = Filter.suggested
    @State private var showMore = false
    @State private var editing: QuickStart?
    @State private var picking: QuickStart?

    enum Filter: String, CaseIterable, Identifiable {
        case suggested = "Suggested", work = "Work", essentials = "Essentials", free = "Free"
        var id: String { rawValue }
    }

    var body: some View {
        let ranked = model.startButtons(now: now)
        let running = model.running.map { CategoryRules.key($0.title) }
        let all = (ranked.row + ranked.more).filter { !$0.keys.contains(running ?? "") }
        let shown = rows(all)
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(model.running == nil ? "Start" : "Switch To", action: "All") { showMore = true }
            if all.isEmpty {
                Card {
                    Text("Say “starting …” in the box once, and it shows up here.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                VStack(spacing: 0) {
                    if shown.isEmpty {
                        Text("Nothing here yet").font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, b in
                        if i > 0 { Divider().padding(.leading, 58) }
                        row(b, usual: filter == .suggested && i == 0)
                    }
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            }
        }
        .sheet(isPresented: $showMore) { MoreButtonsSheet(buttons: ranked.row + ranked.more) }
        .sheet(item: $editing) { b in ButtonEditor(button: b) }
        .sheet(item: $picking) { b in
            StartTimeSheet(title: "Start \(b.title)", initial: Date().addingTimeInterval(-15 * 60)) { model.start(b, at: $0) }
        }
    }

    private func rows(_ all: [QuickStart]) -> [QuickStart] {
        let tree = model.state.categories
        switch filter {
        case .suggested: return Array(all.prefix(4))
        case .work: return Array(all.filter { tree.group($0.category) == .productive }.prefix(6))
        case .essentials: return Array(all.filter { tree.group($0.category) == .essential }.prefix(6))
        case .free: return Array(all.filter { [.rest, .unproductive].contains(tree.group($0.category)) }.prefix(6))
        }
    }

    private func row(_ b: QuickStart, usual: Bool) -> some View {
        let tree = model.state.categories
        return Button { model.start(b) } label: {
            HStack(spacing: 14) {
                IconTile(symbol: b.symbol ?? Theme.symbol(category: b.category, tree: tree),
                         color: Theme.color(category: b.category, tree: tree), size: 30)
                Text(b.title).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 8)
                if usual { Text("Usual now").font(.subheadline).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start \(b.title)")
        .contextMenu {
            Section("Started Earlier") {
                ForEach([5, 10, 15, 30], id: \.self) { m in
                    Button("\(m) min ago", systemImage: "clock.arrow.circlepath") { model.start(b, at: Date().addingTimeInterval(-Double(m) * 60)) }
                }
                Button("Pick a Time…", systemImage: "clock") { picking = b }
            }
            Button("Rename or Change Category", systemImage: "pencil") { editing = b }
            Button("Hide", systemImage: "eye.slash", role: .destructive) { model.hideTile(b) }
        }
    }
}

/// A Home Screen icon: the category's colour, its symbol in white, the name under it (onboarding's activity picker).
struct TileLabel: View {
    let title: String
    let symbol: String
    let color: Color
    let on: Bool
    var pinned = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, options: .repeating, isActive: on)
                .frame(width: 58, height: 58)
                .background(color, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .padding(4)
                .overlay {
                    if on { RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(color, lineWidth: 2.5) }
                }
                .overlay(alignment: .topTrailing) {
                    if pinned {
                        Image(systemName: "pin.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(4).background(Circle().fill(Color(.systemGray)))
                    }
                }
            Text(on ? "Running" : title)
                .font(.caption.weight(on ? .semibold : .regular))
                .foregroundStyle(on ? color : .primary)
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Icons shrink a little under the finger, like the Home Screen.
struct TilePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct MoreButtonsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let buttons: [QuickStart]

    var body: some View {
        let hidden = model.state.quickStarts.buttons.filter(\.removed).sorted { $0.title < $1.title }
        NavigationStack {
            List {
                Section {
                    ForEach(buttons) { b in
                        Button { model.start(b); dismiss() } label: {
                            SettingsLabel(title: b.title, symbol: b.symbol ?? Theme.symbol(category: b.category, tree: model.state.categories),
                                          color: Theme.color(category: b.category, tree: model.state.categories))
                        }
                        .foregroundStyle(.primary)
                        .swipeActions { Button("Hide", role: .destructive) { model.hideTile(b) } }
                    }
                }
                if !hidden.isEmpty {
                    Section("Hidden") {
                        ForEach(hidden) { b in
                            Button { model.state.quickStarts.unhide(b.id); model.save() } label: {
                                Label("Show \(b.title)", systemImage: "eye")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Start")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

struct ButtonEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let button: QuickStart
    @State private var title = ""
    @State private var category: CategoryID = CategoryTree.other

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $title)
                CategoryPicker(selection: $category)
            }
            .navigationTitle("Start Button")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.state.quickStarts.rename(button.id, to: title)
                        model.state.quickStarts.recategorise(button.id, to: category)
                        model.state.categoryRules.correct(title, from: button.category, to: category, at: Date())
                        model.save()
                        dismiss()
                    }
                }
            }
            .onAppear { title = button.title; category = button.category }
        }
    }
}

// MARK: - G.0: mood buttons

struct MoodButtons: View {
    @Environment(AppModel.self) private var model
    let now: Date
    static let faces: [(Int, String)] = [(1, "😞"), (2, "🙁"), (3, "😐"), (4, "🙂"), (5, "😄")]

    var body: some View {
        // Logged in the last 2 hours: nothing to ask (Review shows it).
        if model.todayMood.map({ now.timeIntervalSince($0.at) >= 2 * 3600 }) ?? true {
            Card {
                HStack {
                    Text("How are you feeling?").font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    ForEach(Self.faces, id: \.0) { m, face in
                        Button(face) { withAnimation { model.logMood(m, energy: nil, note: model.running?.title) } }
                            .font(.title2).buttonStyle(TilePress())
                            .accessibilityLabel("Mood \(m) of 5")
                    }
                }
            }
        }
    }
}

/// v1.5: after a stretch of work, how focused it was (time alone doesn't say how much got done).
struct FocusCard: View {
    @Environment(AppModel.self) private var model
    let now: Date
    static let levels: [(Int, String)] = [(1, "Not Very"), (2, "Normal"), (3, "Very")]

    var body: some View {
        if let e = TimeLog.unratedWork(model.state.entries, tree: model.state.categories, now: now) {
            Card {
                HStack {
                    Text("How focused were you on \(e.title)?").font(.subheadline.weight(.semibold)).lineLimit(2)
                    Spacer(minLength: 4)
                    Button { withAnimation { model.rateFocus(e.id, 0) } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Skip")
                }
                HStack(spacing: 8) {
                    ForEach(Self.levels, id: \.0) { f, label in
                        Button(label) { withAnimation { model.rateFocus(e.id, f) } }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule).frame(maxWidth: .infinity)
                    }
                }
                .font(.subheadline.weight(.medium))
            }
        }
    }
}

// MARK: - N7: one question at a time

struct QuestionCard: View {
    @Environment(AppModel.self) private var model
    let question: Inference
    @State private var other = ""
    @State private var typing = false

    var body: some View {
        Card {
            CardHeader(title: question.question ?? "", symbol: "questionmark.bubble.fill", color: .purple)
            ForEach(question.evidence, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            HStack {
                ForEach(question.answers, id: \.self) { a in
                    Button(a) { withAnimation { model.resolveQuestion(question, a) } }.buttonStyle(.bordered)
                }
                Button("Something Else") { typing.toggle() }.buttonStyle(.borderless)
            }
            .font(.subheadline)
            if typing {
                HStack {
                    TextField("What happened?", text: $other).textFieldStyle(.roundedBorder)
                    Button("Send") {
                        let t = other
                        model.resolveQuestion(question, "Something else")
                        Task { await model.submit(t, source: .app, context: question.question) }
                    }
                    .disabled(other.isEmpty)
                }
            }
            Button("Not now") { model.dismissQuestion() }.font(.caption).buttonStyle(.borderless).foregroundStyle(.secondary)
        }
    }
}

struct ScreenshotOfferCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            CardHeader(title: "That screenshot looks like homework", symbol: "doc.text.viewfinder", color: .blue)
            HStack {
                Button("Add It") {
                    guard let img = model.screenshotOffer else { return }
                    model.screenshotOffer = nil
                    Task { await model.submit("Add what's due from this screenshot.", images: [img], source: .share) }
                }
                .buttonStyle(.borderedProminent)
                Button("No") { model.screenshotOffer = nil }.buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - v1.3 C1: what were you doing, and assumed time to confirm (moved from Review)

struct GapsCard: View {
    @Environment(AppModel.self) private var model
    let now: Date

    var body: some View {
        let cal = Calendar.current
        let today = Days.dayInterval(now, cal)
        let slices = model.todaySlices(now)
        // Closed stretches only: the one running up to now is the Now card's question.
        let gaps = Goals.gaps(slices)
            .filter { $0.start >= today.start.addingTimeInterval(6 * 3600) && $0.end < now.addingTimeInterval(-60) }
        if !gaps.isEmpty {
            let tiles = model.startButtons(now: now).row.prefix(5)
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("What Were You Doing?")
                Card {
                    ForEach(Array(gaps.enumerated()), id: \.element.start) { i, g in
                        if i > 0 { Divider() }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("\(g.start.hm) – \(g.end.hm)").font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(durationLabel(g.minutes)).font(.subheadline).foregroundStyle(.secondary)
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(Array(tiles)) { b in
                                        let c = Theme.color(category: b.category, tree: model.state.categories)
                                        Button { model.logStretch(b.title, DateInterval(start: g.start, end: g.end)) } label: {
                                            Label(b.title, systemImage: b.symbol ?? Theme.symbol(category: b.category, tree: model.state.categories))
                                        }
                                        .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(c).font(.caption.weight(.medium))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct AssumedCard: View {
    @Environment(AppModel.self) private var model
    let now: Date
    @State private var editing: DayEntry?

    /// A queue, oldest first: answer the front one and the next slides up.
    var body: some View {
        let cal = Calendar.current
        let today = Days.dayInterval(now, cal)
        let slices = model.todaySlices(now)
        let assumed = TimeLog.assumed(slices).filter { $0.end <= now && !model.state.categories.isUnder($0.category, CategoryTree.sleep) }
        if let d = assumed.first {
            let tree = model.state.categories
            let next = assumed.dropFirst().first
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Did These Happen?", action: assumed.count > 1 ? "Yes to All" : nil) {
                    model.confirmAll(in: DateInterval(start: today.start, end: now))
                }
                PeekStack(remaining: assumed.count, next: next.map { "\($0.title) \($0.start.hm)" }) {
                    HStack(spacing: 12) {
                        IconTile(symbol: Theme.symbol(category: d.category, tree: tree), color: Theme.color(category: d.category, tree: tree))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.title).font(.body).lineLimit(1)
                            Text("\(d.start.hm) – \(d.end.hm)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { editing = d }
                        Spacer(minLength: 4)
                        Button { model.confirm(d) } label: { Image(systemName: "checkmark.circle.fill") }.foregroundStyle(.green)
                            .accessibilityLabel("Yes, \(d.title) happened")
                        Button { model.reject(d) } label: { Image(systemName: "xmark.circle.fill") }.foregroundStyle(Color(.systemGray3))
                            .accessibilityLabel("No, \(d.title) didn't happen")
                    }
                    .font(.title2).buttonStyle(.borderless)
                    .id(d.id)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                }
            }
            .sheet(item: $editing) { EntrySheet(day: $0) }
        }
    }
}

struct Drill: Identifiable { let id: String }

// MARK: - G4: Up Next

struct UpNextCard: View {
    @Environment(AppModel.self) private var model
    let now: Date
    @State private var clearing: WorkItem?
    @State private var showing: WorkItem?

    var body: some View {
        let cal = Calendar.current
        let end = Days.dayInterval(now, cal).end
        let blocks = model.state.plan.blocks.filter { $0.isStudy && $0.end > now && $0.start < end }
        let items = model.state.items
        let atRisk = Set(items.filter { $0.isOpen && model.state.taskHistory.atRisk($0) }.map(\.id))
        // H3: usually-dropped kinds first.
        let ordered = blocks.sorted { (atRisk.contains($0.itemId ?? UUID()) ? 0 : 1, $0.start) < (atRisk.contains($1.itemId ?? UUID()) ? 0 : 1, $1.start) }
        let tree = model.state.categories
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Up Next")
            Card {
                if ordered.isEmpty {
                    Text("Nothing else planned today").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(Array(ordered.enumerated()), id: \.element.id) { i, b in
                    let item = b.itemId.flatMap { id in items.first { $0.id == id } }
                    // Each task keeps the colour and kind symbol it has in Tasks, so two sessions of different tasks never look alike.
                    let color = item.map { Theme.color(for: $0, in: model.state) } ?? Theme.focus
                    if i > 0 { Divider().padding(.leading, 46) }
                    HStack(alignment: .center, spacing: 12) {
                        IconTile(symbol: item?.kind.symbol ?? "pencil.line", color: color, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.title).font(i == 0 ? .headline : .body).lineLimit(1)
                            Text("\(b.start.hm) – \(b.end.hm) · \(minutesLabel(b.minutes))")
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if let item {
                            Button { model.startTask(item) } label: { Image(systemName: "play.fill") }
                                .buttonStyle(.borderedProminent).buttonBorderShape(.circle).tint(color)
                                .accessibilityLabel("Start \(item.title)")
                            Menu {
                                Button("Done", systemImage: "checkmark") { model.complete(item.id) }
                                Button("15 More Minutes", systemImage: "plus") { model.extend(item.id, minutes: 15) }
                                Button("30 More Minutes", systemImage: "plus") { model.extend(item.id, minutes: 30) }
                                Button("Not Today", systemImage: "arrow.uturn.forward") { model.notToday(blockId: b.id) }
                                Button("Clear (not doing it)", systemImage: "xmark.circle") { clearing = item }
                                Button("Delete (made by mistake)", systemImage: "trash", role: .destructive) { model.delete(item.id) }
                            } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture { showing = item }
                }
            }
        }
        .sheet(item: $clearing) { ClearSheet(item: $0) }
        .sheet(item: $showing) { i in NavigationStack { TaskDetailView(itemId: i.id) } }
    }
}

/// B1 / B2: when something started, on a wheel (the last 12 hours), with one-tap offsets.
struct StartTimeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onPick: (Date) -> Void
    @State private var time: Date

    init(title: String, initial: Date, onPick: @escaping (Date) -> Void) {
        self.title = title
        self.onPick = onPick
        _time = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack {
                    ForEach([5, 10, 15, 30], id: \.self) { m in
                        Button("\(m) min ago") { time = Date().addingTimeInterval(-Double(m) * 60) }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule).font(.subheadline)
                    }
                }
                DatePicker("Started", selection: $time, in: Date().addingTimeInterval(-12 * 3600)...Date(), displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel).labelsHidden()
            }
            .padding()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { onPick(time); dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }
}

/// H5: Clear asks one optional why.
struct ClearSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: WorkItem

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(["No time", "Not needed", "Didn't want to"], id: \.self) { why in
                        Button(why) { model.clear(item.id, why: why); dismiss() }
                    }
                    Button("Just clear it") { model.clear(item.id, why: nil); dismiss() }
                } footer: {
                    Text("Cleared tasks are counted, so Productium learns which kinds need a smaller first step. Delete instead if it was made by mistake.")
                }
            }
            .navigationTitle("Clear \(item.title)?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

/// Alerts, most urgent first, as a queue: the free build about to stop opening, then plan warnings (Dismiss shows the next).
struct AlertCard: View {
    @Environment(AppModel.self) private var model
    let now: Date

    var body: some View {
        let warnings = model.activeWarnings.sorted { ($0.level == .info ? 1 : 0) < ($1.level == .info ? 1 : 0) }
        if let expiry = model.signatureExpiry, expiry.timeIntervalSince(now) < 2 * 86400 {
            PeekStack(remaining: 1 + warnings.count, next: warnings.first.map { String($0.message.prefix(60)) }) {
                CardHeader(title: "Refresh Needed", symbol: "exclamationmark.triangle.fill", color: Theme.alert)
                Text("This build stops opening \(expiry.relativeDay) at \(expiry.hm). Refresh or reinstall it before then.")
                    .font(.subheadline)
            }
        } else if let w = warnings.first {
            PeekStack(remaining: warnings.count, next: warnings.dropFirst().first.map { String($0.message.prefix(60)) }) {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(title: "Heads Up", symbol: w.level == .critical ? "exclamationmark.triangle.fill" : "info.circle.fill",
                               color: w.level == .critical ? Theme.alert : .orange)
                    Text(w.message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 16) {
                        if w.shortfall != nil {
                            Button("Shorten") { model.shorten(w) }
                            Button("Move Due") { model.moveDue(w) }
                        }
                        Button(w.shortfall != nil ? "Keep" : "Dismiss") { withAnimation { model.state.dismissed.insert(w.dismissKey) }; model.save() }
                    }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                }
                .id(w.message)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
        }
    }
}

/// The "Pause Before Scrolling" automation lands here (productium://gap): start what's planned, or go back for 10 min.
struct PauseSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let b = model.state.plan.blocks.first(where: { $0.isStudy && $0.end > Date() && $0.itemId != nil }) {
                    Section {
                        Button {
                            model.startNowOrNext()
                            dismiss()
                        } label: { Label("Start \(b.title)", systemImage: "play.fill") }
                    } footer: { Text("Planned \(b.start.relativeDay) at \(b.start.hm).") }
                }
                Section {
                    Button("Go Back to the App Anyway") {
                        Friction.grant(minutes: 10)
                        dismiss()
                    }
                    .foregroundStyle(.secondary)
                } footer: {
                    let mins = Friction.checkInMinutes
                    Text(mins.isEmpty ? "No pause for the next 10 minutes."
                         : "No pause for the next 10 minutes. If you're still in there after \(mins[0]) minutes, Productium will check in.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Paused")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
