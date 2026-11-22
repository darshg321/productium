import SwiftUI
import Charts
import ProductiumCore

// v1.3 C1: Home is "now", top to bottom: the box, what's running and the activity grid, mood, a question from what the
// phone noticed (N7), "What were you doing?" for today's untracked stretches, assumed time to confirm, today's rings,
// then Up Next. Nothing appears twice; how the day and week went lives in Review.

struct TodayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(ctx.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        DumpBox()
                        AlertCard(now: ctx.date)
                        ForEach(model.approvals.filter { $0.turnId == nil }) { a in Card { ApprovalRow(approval: a) } }
                        if let r = model.running { RunningCard(entry: r, now: ctx.date) }
                        ActivityGrid(now: ctx.date).id("grid")
                        MoodButtons(now: ctx.date)
                        if let q = model.state.inference.pending.first { QuestionCard(question: q) }
                        if model.screenshotOffer != nil { ScreenshotOfferCard() }
                        GapsCard(now: ctx.date).id("gaps")
                        AssumedCard(now: ctx.date).id("assumed")
                        RingsCard(now: ctx.date).id("ring")
                        UpNextCard(now: ctx.date).id("upnext")
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.scrollTarget) { _, t in if let t { proxy.scrollTo(t, anchor: .top) } }
                }
            }
            .background(Theme.background)
            .refreshable { await model.refresh() }
            .navigationTitle("Today")
            .usageMeter()
        }
    }
}

// MARK: - D1 / D6: what's running

struct RunningCard: View {
    @Environment(AppModel.self) private var model
    let entry: Entry
    let now: Date
    @State private var switching = false
    @State private var next = ""

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Label(entry.title, systemImage: Theme.symbol(category: entry.category, tree: model.state.categories))
                    .font(.headline)
                    .foregroundStyle(Theme.color(category: entry.category, tree: model.state.categories))
                Spacer()
                Text(timerInterval: entry.start...Date.distantFuture, countsDown: false)
                    .font(.title3.monospacedDigit().weight(.semibold))
            }
            Text(model.state.categories.pathText(entry.category) + (model.placeName(entry.placeId).map { " · \($0)" } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
            if let g = model.goalLine(for: entry) { Text(g).font(.caption).foregroundStyle(Theme.focus) }
            if switching {
                HStack {
                    TextField("What now?", text: $next).textFieldStyle(.roundedBorder).onSubmit(doSwitch)
                    Button("Start", action: doSwitch).disabled(next.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            HStack {
                Button { model.stopRunning(source: "home") } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.borderedProminent)
                if let t = entry.taskId, model.state.items.contains(where: { $0.id == t && $0.isOpen }) {
                    Button { model.complete(t) } label: { Label("Done", systemImage: "checkmark") }.buttonStyle(.bordered)
                }
                Button { withAnimation { switching.toggle() } } label: { Label("Switch", systemImage: "arrow.left.arrow.right") }
                    .buttonStyle(.bordered)
            }
            .font(.subheadline)
        }
    }

    private func doSwitch() {
        let t = next.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        model.start(title: t, source: "switch")
        next = ""
        switching = false
    }
}

// MARK: - v1.3 A2: the activity grid

struct ActivityGrid: View {
    @Environment(AppModel.self) private var model
    let now: Date
    @State private var showMore = false
    @State private var editing: QuickStart?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        let ranked = model.startButtons(now: now)
        let running = model.running.map { CategoryRules.key($0.title) }
        if ranked.row.isEmpty && ranked.more.isEmpty {
            Text("Say “starting …” in the box once, and it gets a tile here.")
                .font(.footnote).foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(ranked.row.enumerated()), id: \.element.id) { i, b in tile(b, slot: i, running: b.keys.contains(running ?? "")) }
                Button { showMore = true } label: {
                    TileLabel(title: "More", symbol: "ellipsis", color: .secondary, on: false)
                }
                .buttonStyle(.plain)
            }
            .sheet(isPresented: $showMore) { MoreButtonsSheet(buttons: ranked.row + ranked.more) }
            .sheet(item: $editing) { b in ButtonEditor(button: b) }
        }
    }

    private func tile(_ b: QuickStart, slot: Int, running: Bool) -> some View {
        let color = Theme.color(category: b.category, tree: model.state.categories)
        return Button { if !running { model.start(b) } } label: {
            TileLabel(title: b.title, symbol: b.symbol ?? Theme.symbol(category: b.category, tree: model.state.categories),
                      color: color, on: running, pinned: b.isPinned)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(running ? "\(b.title), running" : "Start \(b.title)")
        .contextMenu {
            Button("Rename or Change Category", systemImage: "pencil") { editing = b }
            if b.isPinned {
                Button("Unpin", systemImage: "pin.slash") { model.pinTile(b, at: nil) }
            } else {
                Button("Pin Here", systemImage: "pin") { model.pinTile(b, at: slot) }
            }
            Button("Hide", systemImage: "eye.slash", role: .destructive) { model.hideTile(b) }
        }
    }
}

/// Symbol over a word, Fitness-tile style. The running one is filled; colour is never the only cue (its label says so).
struct TileLabel: View {
    let title: String
    let symbol: String
    let color: Color
    let on: Bool
    var pinned = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.title3)
            Text(title).font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .foregroundStyle(on ? Color.white : color)
        .background(on ? AnyShapeStyle(color) : AnyShapeStyle(color.opacity(0.13)),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if pinned { Image(systemName: "pin.fill").font(.system(size: 8)).padding(5).foregroundStyle(.secondary) }
        }
        .overlay {
            if on { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.4), lineWidth: 1.5) }
        }
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
                            Label(b.title, systemImage: b.symbol ?? Theme.symbol(category: b.category, tree: model.state.categories))
                        }
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
        if let m = model.todayMood, now.timeIntervalSince(m.at) < 2 * 3600 {
            HStack {
                Text("\(Self.faces.first { $0.0 == m.mood }?.1 ?? "🙂") at \(m.at.hm)").font(.subheadline)
                Spacer()
                Button("Change") { model.state.moods.removeAll { $0.id == m.id }; model.save() }.font(.subheadline).buttonStyle(.borderless)
            }
            .padding(.horizontal, 4)
        } else {
            HStack {
                Text("How are you?").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                ForEach(Self.faces, id: \.0) { m, face in
                    Button(face) { withAnimation { model.logMood(m, energy: nil, note: model.running?.title) } }
                        .font(.title2).buttonStyle(.borderless)
                        .accessibilityLabel("Mood \(m) of 5")
                }
            }
            .padding(.horizontal, 4)
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
        let slices = TimeLog.past(model.state.entries, in: today, now: now, book: model.state.dayRules, calendar: cal)
        // Closed stretches only: the one running up to now is the Now card's question.
        let gaps = TimeLog.untracked(slices, atLeast: 15)
            .filter { $0.start >= today.start.addingTimeInterval(6 * 3600) && $0.end < now.addingTimeInterval(-60) }
        if !gaps.isEmpty {
            let tiles = model.startButtons(now: now).row.prefix(4)
            Card {
                CardHeader(title: "What Were You Doing?", symbol: "questionmark.circle", color: .orange)
                ForEach(gaps, id: \.start) { g in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(g.start.hm)–\(g.end.hm) · \(durationLabel(g.minutes))").font(.subheadline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(Array(tiles)) { b in
                                    Button(b.title) { model.logStretch(b.title, DateInterval(start: g.start, end: g.end)) }
                                        .buttonStyle(.bordered).buttonBorderShape(.capsule).font(.caption)
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

    var body: some View {
        let cal = Calendar.current
        let today = Days.dayInterval(now, cal)
        let slices = TimeLog.past(model.state.entries, in: today, now: now, book: model.state.dayRules, calendar: cal)
        let assumed = TimeLog.assumed(slices).filter { $0.end <= now && !model.state.categories.isUnder($0.category, CategoryTree.sleep) }
        if !assumed.isEmpty {
            Card {
                HStack {
                    CardHeader(title: "Did These Happen?", symbol: "checkmark.circle", color: .green)
                    Button("Yes to All") { model.confirmAll(in: DateInterval(start: today.start, end: now)) }.font(.subheadline)
                }
                ForEach(assumed) { d in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(d.title).font(.subheadline)
                            Text("\(d.start.hm)–\(d.end.hm)").font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { editing = d }
                        Spacer()
                        Button { model.confirm(d) } label: { Image(systemName: "checkmark.circle.fill") }.foregroundStyle(.green)
                            .accessibilityLabel("Yes, \(d.title) happened")
                        Button { model.reject(d) } label: { Image(systemName: "xmark.circle.fill") }.foregroundStyle(.secondary)
                            .accessibilityLabel("No, \(d.title) didn't happen")
                    }
                    .font(.title3).buttonStyle(.borderless)
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
        Card {
            CardHeader(title: "Up Next", symbol: "list.bullet", color: .blue)
            Text(UpNext.summary(plan: model.state.plan, items: items, entries: model.state.entries, goals: model.state.goals,
                                tree: model.state.categories, now: now, book: model.state.dayRules, calendar: cal))
                .font(.subheadline).fixedSize(horizontal: false, vertical: true)
            ForEach(ordered) { b in
                let item = b.itemId.flatMap { id in items.first { $0.id == id } }
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.title).font(.subheadline.weight(.semibold))
                        Text("\(b.start.hm) · \(durationLabel(b.minutes))" + (item?.firstStep.map { " · \($0)" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    if let item {
                        Button { model.startTask(item) } label: { Image(systemName: "play.fill") }
                            .buttonStyle(.borderedProminent).accessibilityLabel("Start \(item.title)")
                        Menu {
                            Button("Done", systemImage: "checkmark") { model.complete(item.id) }
                            Button("Not Today", systemImage: "arrow.uturn.forward") { model.notToday(blockId: b.id) }
                            Button("Clear (not doing it)", systemImage: "xmark.circle") { clearing = item }
                            Button("Delete (made by mistake)", systemImage: "trash", role: .destructive) { model.delete(item.id) }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { showing = item }
            }
        }
        .sheet(item: $clearing) { ClearSheet(item: $0) }
        .sheet(item: $showing) { i in NavigationStack { TaskDetailView(itemId: i.id) } }
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

/// At most one alert, most urgent first: the free build about to stop opening, then a plan warning.
struct AlertCard: View {
    @Environment(AppModel.self) private var model
    let now: Date

    var body: some View {
        if let expiry = model.signatureExpiry, expiry.timeIntervalSince(now) < 2 * 86400 {
            Card {
                CardHeader(title: "Refresh Needed", symbol: "exclamationmark.triangle.fill", color: Theme.alert)
                Text("This build stops opening \(expiry.relativeDay) at \(expiry.hm). Refresh it in SideStore.")
                    .font(.subheadline)
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
