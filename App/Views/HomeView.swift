import SwiftUI
import Charts
import ProductiumCore

// v1.2 G3: Home is only what's needed during the day, top to bottom: the box, what's running (or the start buttons),
// mood, today's ring with the forecast you can beat, then Up Next. A question from what the phone noticed sits above
// the ring (N7). Nothing appears twice; insights and patterns live in Review.

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
                        if let r = model.running { RunningCard(entry: r, now: ctx.date) } else { StartButtons(now: ctx.date) }
                        MoodButtons(now: ctx.date)
                        if let q = model.state.inference.pending.first { QuestionCard(question: q) }
                        if model.screenshotOffer != nil { ScreenshotOfferCard() }
                        TodayRingCard(now: ctx.date).id("ring")
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

// MARK: - D2: start buttons

struct StartButtons: View {
    @Environment(AppModel.self) private var model
    let now: Date
    @State private var showMore = false
    @State private var editing: QuickStart?

    var body: some View {
        let ranked = model.startButtons(now: now)
        if !ranked.row.isEmpty || !ranked.more.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ranked.row) { b in button(b) }
                        if !ranked.more.isEmpty {
                            Button { showMore = true } label: { Label("More", systemImage: "ellipsis") }
                                .buttonStyle(.bordered).buttonBorderShape(.capsule)
                        }
                    }
                }
            }
            .sheet(isPresented: $showMore) { MoreButtonsSheet(buttons: ranked.row + ranked.more) }
            .sheet(item: $editing) { b in ButtonEditor(button: b) }
        } else {
            Text("Say “starting …” in the box once, and it gets a button here.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func button(_ b: QuickStart) -> some View {
        Button { model.start(b) } label: {
            Label(b.title, systemImage: Theme.symbol(category: b.category, tree: model.state.categories))
        }
        .buttonStyle(.bordered).buttonBorderShape(.capsule)
        .tint(Theme.color(category: b.category, tree: model.state.categories))
        .contextMenu {
            Button("Rename or Change Category") { editing = b }
            Button("Remove", role: .destructive) { model.state.quickStarts.remove(b.id); model.save() }
        }
    }
}

struct MoreButtonsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let buttons: [QuickStart]

    var body: some View {
        NavigationStack {
            List(buttons) { b in
                Button { model.start(b); dismiss() } label: {
                    Label(b.title, systemImage: Theme.symbol(category: b.category, tree: model.state.categories))
                }
                .swipeActions { Button("Remove", role: .destructive) { model.state.quickStarts.remove(b.id); model.save() } }
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

// MARK: - G1 / G1a: today's ring

struct TodayRingCard: View {
    @Environment(AppModel.self) private var model
    let now: Date
    @State private var drill: String?

    var body: some View {
        let cal = Calendar.current
        let day = Days.dayInterval(now, cal)
        let f = model.forecast
        let ring = RingModel.make(entries: model.state.entries, tree: model.state.categories, range: day, now: now,
                                  forecast: f?.rest, book: model.state.dayRules, calendar: cal)
        Card {
            CardHeader(title: "Today", symbol: "chart.pie.fill", color: .blue,
                       detail: ring.trackingGaps == 0 ? "No gaps over 30 min" : "\(ring.trackingGaps) gap\(ring.trackingGaps == 1 ? "" : "s") over 30 min")
            TimeRing(ring: ring, tree: model.state.categories, goals: model.goalsAll, selection: $drill,
                     centre: "\(durationLabel(ring.trackedMinutes))", centreCaption: "tracked")
                .frame(height: 230)
            if let f {
                Text(model.verdict(f).line).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                Text("Hatched: how today usually goes from here (\(f.similarDays) similar days).")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("The faint part is what's planned. After 3 similar days it becomes a forecast you can beat.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            RingLegend(ring: ring, tree: model.state.categories)
        }
        .sheet(item: Binding(get: { drill.map(Drill.init) }, set: { drill = $0?.id })) { d in
            DrillSheet(id: d.id, range: day, title: "Today")
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
                if let b = model.state.plan.current(at: Date()) ?? model.state.plan.next(after: Date()), b.isStudy {
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
