import SwiftUI
import FamilyControls
import UniformTypeIdentifiers
import Charts
import ProductiumCore

/// Settings, laid out like the iOS Settings app: the account-style Claude row on top,
/// then coloured icon rows that each open one page.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.state.prefs
        List {
            Section {
                NavigationLink { ClaudeSettings() } label: {
                    HStack(spacing: 14) {
                        IconTile(symbol: "sparkles", color: .teal, size: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Claude").font(.title3.weight(.semibold))
                            Text(claudeStatus).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                NavigationLink { UsageView(inSheet: false) } label: {
                    LabeledContent { Text("\(tokensLabel(model.tokensToday)) today") } label: {
                        SettingsLabel(title: "AI Usage", symbol: "gauge.with.dots.needle.33percent", color: Theme.meter(model.usageFraction))
                    }
                }
            }

            Section {
                row("Schedule", "calendar", .red, "\(model.state.commitments.count)") { ScheduleSettings() }
                row("Sleep", "bed.double.fill", Theme.sleep, durationLabel(p.sleepNeedMinutes)) { SleepSettings() }
                row("Study", "book.fill", .blue, nil) { StudySettings() }
                row("Screen Time", "hourglass", Theme.screen, model.state.taper.targetMinutes.map { durationLabel($0) }) { ScreenTimeSettings() }
            }

            Section {
                row("Notifications", "bell.badge.fill", .red, model.state.integrations.notifications ? p.nudges.level.title : "Off") { NudgeSettingsView() }
                row("Shortcuts & Automations", "square.stack.3d.up.fill", .indigo, nil) { ShortcutsGuideView() }
            }

            Section {
                row("Connections", "link", .green, nil) { ConnectionSettings() }
                row("Places", "location.fill", .blue, model.state.integrations.location ? "On" : "Off") { PlacesSettings() }
                row("Routines", "figure.walk", .orange, nil) { RoutineSettings() }
                row("About You", "person.text.rectangle.fill", .teal, nil) { AboutYouView() }
            }

            Section {
                row("Backup & Restore", "externaldrive.fill", .gray, nil) { BackupSettings() }
                if Signature.isFreeTier || model.signatureExpiry != nil {
                    row("Keeping It Installed", "arrow.clockwise", .indigo,
                        model.signatureExpiry.map { $0.formatted(.dateTime.month(.abbreviated).day()) }) { InstallSettings() }
                }
            }

            Section {
                row("Why It Works This Way", "lightbulb.fill", .yellow, nil) { ScienceView() }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .usageMeter()
    }

    private var claudeStatus: String {
        guard ClaudeClient.shared.isConfigured else { return "Not connected" }
        switch model.serverOnline {
        case true?: return "Connected · \(ClaudeClient.shared.baseURL?.host ?? "")"
        case false?: return "Offline. Is Tailscale on?"
        case nil: return ClaudeClient.shared.baseURL?.host ?? "Server"
        }
    }

    private func row<D: View>(_ title: String, _ symbol: String, _ color: Color, _ value: String?,
                              @ViewBuilder _ dest: @escaping () -> D) -> some View {
        NavigationLink { dest() } label: {
            LabeledContent { Text(value ?? "") } label: { SettingsLabel(title: title, symbol: symbol, color: color) }
        }
    }
}

// MARK: - Claude

struct ClaudeSettings: View {
    @Environment(AppModel.self) private var model
    @State private var serverURL = ClaudeClient.shared.baseURL?.absoluteString ?? ClaudeClient.defaultURL.absoluteString
    @State private var serverKey = ClaudeClient.shared.apiKey ?? ""
    @State private var check: ClaudeClient.Check?
    @State private var testing = false

    var body: some View {
        List {
            Section {
                TextField("Server URL", text: $serverURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                SecureField("API key (cs_…)", text: $serverKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("Server") } footer: {
                Text("Your claude-server on Tailscale. Tailscale needs to be on for this phone.")
            }

            Section {
                Button {
                    ClaudeClient.shared.baseURL = URL(string: serverURL.trimmingCharacters(in: .whitespaces))
                    ClaudeClient.shared.apiKey = serverKey.trimmingCharacters(in: .whitespaces)
                    testing = true
                    Task {
                        check = await ClaudeClient.shared.verify()
                        model.serverOnline = check != .unreachable
                        testing = false
                        await model.refreshServerUsage()
                    }
                } label: {
                    HStack {
                        Text("Save & Test")
                        Spacer()
                        if testing { ProgressView() }
                    }
                }
                .disabled(testing)
                if let c = check {
                    switch c {
                    case .ok: Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .badKey: Label("The server didn't accept that key", systemImage: "key.slash").foregroundStyle(Theme.alert)
                    case .unreachable: Label("Couldn't reach the server", systemImage: "wifi.exclamationmark").foregroundStyle(Theme.alert)
                    }
                }
            } footer: {
                Text("Testing uses no tokens.")
            }

            Section {
                LabeledContent("Model", value: "Sonnet")
                LabeledContent("Effort", value: "Low")
            } header: { Text("Model") } footer: {
                Text("Everything uses Sonnet at low effort. On this app's own requests it wrote a little over half the tokens Haiku 5.5 did, because Haiku's thinking can't be turned off. Flashcards and short reads are made in small batches, only when you open a gap.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Claude")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - AI usage

/// The detail behind the toolbar meter: today against the budget, where tokens went,
/// the last week, and what the server itself counted.
struct UsageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var inSheet = true

    var body: some View {
        if inSheet {
            NavigationStack {
                content
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
            .presentationDetents([.medium, .large])
        } else {
            content
        }
    }

    private var content: some View {
        @Bindable var m = model
        let cal = Calendar.current
        let now = Date()
        let ledger = model.state.usage
        let today = ledger.total(on: now, calendar: cal)
        let f = ledger.fractionUsed(now: now, calendar: cal)
        let week = ledger.daily(lastDays: 7, now: now, calendar: cal)
        return List {
            Section {
                HStack(spacing: 18) {
                    ZStack {
                        Circle().stroke(Color(.tertiarySystemFill), lineWidth: 8)
                        Circle().trim(from: 0, to: min(1, max(0.001, f)))
                            .stroke(Theme.meter(f), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(Int((f * 100).rounded()))%").font(.subheadline.weight(.semibold).monospacedDigit())
                    }
                    .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        BigValue(value: tokensLabel(today.counted), unit: "output tokens today")
                        Text("of a \(tokensLabel(ledger.dailyBudget)) daily budget").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                Chart {
                    ForEach(week, id: \.day) { d in
                        BarMark(x: .value("Day", d.day, unit: .day), y: .value("Tokens", d.tokens))
                            .foregroundStyle(Theme.meter(Double(d.tokens) / Double(max(1, ledger.dailyBudget))).gradient)
                            .cornerRadius(3)
                    }
                    RuleMark(y: .value("Budget", ledger.dailyBudget))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
                .frame(height: 120)
                .padding(.vertical, 4)
            } footer: {
                Text("Counts the tokens Claude writes, including its hidden thinking. Last 7 days: "
                     + "\(tokensLabel(ledger.total(lastDays: 7, now: now, calendar: cal).counted)).")
            }

            Section {
                let parts = ledger.byFeature(on: now, calendar: cal)
                if parts.isEmpty {
                    Text("No AI used yet today.").foregroundStyle(.secondary)
                }
                ForEach(parts, id: \.feature) { p in
                    LabeledContent {
                        Text("\(tokensLabel(p.tokens)) · \(p.requests)×").monospacedDigit()
                    } label: {
                        SettingsLabel(title: p.feature.title, symbol: Theme.symbol(for: p.feature), color: Theme.color(for: p.feature))
                    }
                }
            } header: { Text("Today") }

            Section {
                Stepper(value: $m.state.usage.dailyBudget, in: 1_000...100_000, step: 1_000) {
                    LabeledContent("Daily budget", value: tokensLabel(model.state.usage.dailyBudget))
                }
                Toggle("Pause background AI over budget", isOn: $m.state.usage.pauseBackgroundOverBudget)
            } header: { Text("Budget") } footer: {
                Text("The Inbox always works. Flashcards, short reads, project steps and the weekly note wait until tomorrow once the budget is spent.")
            }

            SubscriptionSection()

            Section {
                if let u = model.serverUsage {
                    LabeledContent("Today (server day, UTC)", value: "\(tokensLabel(u.todayTokens)) · \(u.todayRequests)×")
                    LabeledContent("Last 7 days", value: tokensLabel(u.weekTokens))
                    if let d = u.key?.daily, let r = u.key?.rpm {
                        LabeledContent("Key limits", value: "\(r)/min · \(d)/day")
                    }
                } else {
                    Text(ClaudeClient.shared.isConfigured ? "Loading…" : "Connect Claude to see the server's count.")
                        .foregroundStyle(.secondary)
                }
            } header: { Text("Server") } footer: {
                Text("Output tokens claude-server counted for this key. Cached answers count there but use no subscription tokens.")
            }

            let recent = Array(ledger.records.suffix(8).reversed())
            Section {
                ForEach(recent, id: \.at) { r in
                    NavigationLink {
                        if let c = model.call(r.callId) { AICallDetailView(call: c) }
                        else { ContentUnavailableView("Not kept", systemImage: "doc.text.magnifyingglass",
                                                      description: Text("This request is older than the saved log, or from before it existed.")) }
                    } label: {
                        HStack(spacing: 12) {
                            IconTile(symbol: Theme.symbol(for: r.feature), color: Theme.color(for: r.feature), size: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.feature.title).font(.subheadline)
                                Text("\(r.at.relativeDay.capitalized), \(r.at.hm) · \(r.model)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(tokensLabel(r.tokens.counted)).font(.subheadline.monospacedDigit())
                                Text("out").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                NavigationLink {
                    AICallListView()
                } label: {
                    LabeledContent("All Requests", value: "\(model.callLog.calls.count)")
                }
            } header: { Text("Recent Requests") } footer: {
                Text("Tap one to see the exact prompt that was sent and the reply that came back, failed ones included.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("AI Usage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refreshServerUsage() }
        .task {
            // The subscription moves while you watch (other apps use it too): poll while open.
            while !Task.isCancelled {
                await model.refreshSubscription()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        .onChange(of: model.state.usage.dailyBudget) { _, _ in model.save() }
        .onChange(of: model.state.usage.pauseBackgroundOverBudget) { _, _ in model.save() }
    }
}

// MARK: - Schedule, sleep, study

struct ScheduleSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Commitment?

    var body: some View {
        @Bindable var m = model
        List {
            Section {
                WeekdayToggles(days: $m.state.prefs.schoolDays, label: "School Days")
            }
            Section {
                let sorted = model.state.commitments.sorted { ($0.kind == .school ? 0 : 1, $0.start, $0.title) < ($1.kind == .school ? 0 : 1, $1.start, $1.title) }
                ForEach(sorted) { c in
                    Button { editing = c } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Circle().fill(Theme.named(Palette.color(for: c, colors: model.state.prefs.colors)) ?? Theme.fixed)
                                    .frame(width: 8, height: 8)
                                Text(c.title).foregroundStyle(.primary)
                            }
                            Text("\(c.weekdays.sorted().map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: " ")), \(c.start.label) to \(c.end.label)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    let ids = Set(offsets.map { sorted[$0].id })
                    m.state.commitments.removeAll { ids.contains($0.id) }
                    m.state.exceptions.removeAll { $0.commitmentId.map(ids.contains) ?? false }
                    model.replan()
                }
                Button {
                    editing = Commitment(title: "", kind: .extracurricular, weekdays: [2, 4], start: TimeOfDay(16), end: TimeOfDay(17, 30))
                } label: { Label("Add Class or Activity", systemImage: "plus") }
            } header: { Text("Classes & Activities") } footer: {
                Text("Or just tell the Inbox: “soccer mon and wed 4 to 5:30”, or “split school into my periods” with your timetable.")
            }
            Section {
                NavigationLink { ColorSettings() } label: { Label("Colours", systemImage: "paintpalette") }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Schedule")
        .sheet(item: $editing) { c in CommitmentEditor(commitment: c) }
        .onChange(of: model.state.prefs) { _, _ in model.replan() }
    }
}

struct SleepSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        List {
            Section {
                Stepper(value: $m.state.prefs.sleepNeedMinutes, in: 450...600, step: 15) {
                    LabeledContent("Sleep need", value: durationLabel(model.state.prefs.sleepNeedMinutes))
                }
                Stepper(value: $m.state.prefs.windDownMinutes, in: 15...60, step: 5) {
                    LabeledContent("Wind-down", value: "\(model.state.prefs.windDownMinutes) min")
                }
            } footer: {
                Text("Teens need 8–10 hours (AASM).")
            }
            Section {
                Toggle("Work Back from First Class", isOn: $m.state.prefs.autoWake)
                TimePicker(label: model.state.prefs.autoWake ? "Latest School-Day Wake" : "School-Day Wake", time: $m.state.prefs.schoolDayWake)
                TimePicker(label: "Free-Day Wake", time: $m.state.prefs.freeDayWake)
            } header: { Text("Wake Up") } footer: {
                Text("Keeping free-day wake within about an hour of school days avoids “social jet lag”.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Sleep")
        .onChange(of: model.state.prefs) { _, _ in model.replan() }
    }
}

struct StudySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        List {
            Section {
                Stepper(value: $m.state.prefs.maxStudyMinutesSchoolDay, in: 30...360, step: 15) {
                    LabeledContent("Most on a school day", value: durationLabel(model.state.prefs.maxStudyMinutesSchoolDay))
                }
                Stepper(value: $m.state.prefs.maxStudyMinutesFreeDay, in: 30...480, step: 15) {
                    LabeledContent("Most on a free day", value: durationLabel(model.state.prefs.maxStudyMinutesFreeDay))
                }
                Stepper(value: $m.state.prefs.minFreeMinutesSchoolDay, in: 30...300, step: 15) {
                    LabeledContent("Protected free time", value: durationLabel(model.state.prefs.minFreeMinutesSchoolDay))
                }
            }
            Section {
                Toggle("Small Sleep Trade-offs for Deadlines", isOn: $m.state.prefs.allowSleepTradeoffs)
            } footer: {
                Text("Capped at 1 hour on rare nights, only for high-stakes writing or projects, and never before a test. Sleep is when studying gets stored.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Study")
        .onChange(of: model.state.prefs) { _, _ in model.replan() }
    }
}

struct ScreenTimeSettings: View {
    @Environment(AppModel.self) private var model
    @State private var showPicker = false
    @State private var selection = FamilyActivitySelection()

    var body: some View {
        @Bindable var m = model
        List {
            #if FREE_TIER
            Section {
                Text("Blocking and measuring apps uses Apple's Screen Time API, which needs a paid developer account. This build was signed with a free one.")
            }
            Section {
                NavigationLink { RecipeView(recipe: Recipe.scrolling[0]) } label: { RecipeRow(recipe: Recipe.scrolling[0]) }
                NavigationLink { RecipeView(recipe: Recipe.scrolling[1]) } label: { RecipeRow(recipe: Recipe.scrolling[1]) }
                NavigationLink { RecipeView(recipe: Recipe.scrolling[2]) } label: { RecipeRow(recipe: Recipe.scrolling[2]) }
            } header: { Text("Add a Pause Instead") } footer: {
                Text("Opening one of those apps brings up a short pause with something better to do. “Go back anyway” skips it for 10 minutes. With the second automation, Productium also counts your minutes.")
            }
            let log = Friction.log
            if let d = log.today(Date(), calendar: .current) {
                Section {
                    LabeledContent("Opened", value: "\(d.opens)×")
                    LabeledContent("Paused", value: "\(d.pauses)×")
                    if log.measuresClosing {
                        let mins = log.minutes(on: Date(), calendar: .current).values.reduce(0, +)
                        LabeledContent("Time in those apps", value: durationLabel(mins))
                    }
                } header: { Text("Today") } footer: {
                    Text("“App is closed” can miss going Home or locking the phone, so a session with no clear end counts as your usual length (marked estimated), never the whole evening.")
                }
            }
            #else
            Section {
                Toggle("Measure & Limit Apps", isOn: Binding(get: { model.state.integrations.screenTime }, set: { on in
                    Task {
                        if on { m.state.integrations.screenTime = await ScreenTimeService.shared.requestAuthorization() }
                        else { m.state.integrations.screenTime = false; ScreenTimeService.shared.disable() }
                        model.replan()
                    }
                }))
                if model.state.integrations.screenTime {
                    Button("Choose Distracting Apps & Sites") {
                        selection = ScreenTimeService.shared.selection
                        showPicker = true
                    }
                }
            } footer: {
                Text("First week: measuring only. Then the daily limit drops about 10% a week, held steady after a tough week, down to your goal. Apps also pause during focus blocks and wind-down.")
            }
            if model.state.integrations.screenTime {
                Section {
                    Stepper(value: $m.state.prefs.screenTimeGoalMinutes, in: 0...240, step: 15) {
                        LabeledContent("Daily goal", value: durationLabel(model.state.prefs.screenTimeGoalMinutes))
                    }
                    if let t = model.state.taper.targetMinutes {
                        LabeledContent("Today's limit", value: durationLabel(t))
                    }
                    Toggle("Offer a Short Read When Blocked", isOn: Binding(
                        get: { SharedConfig.defaults.bool(forKey: SharedConfig.Key.nudgeOnShield) },
                        set: { SharedConfig.defaults.set($0, forKey: SharedConfig.Key.nudgeOnShield) }))
                }
            }
            #endif
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Screen Time")
        .familyActivityPicker(isPresented: $showPicker, selection: $selection)
        .onChange(of: selection) { _, s in ScreenTimeService.shared.selection = s; model.replan() }
        .onChange(of: model.state.prefs) { _, _ in model.replan() }
    }
}

// MARK: - Notifications

/// How much the phone interrupts, what with, and a preview of what's actually coming.
struct NudgeSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        let on = model.state.integrations.notifications
        List {
            if !on {
                Section {
                    Button {
                        Task {
                            m.state.integrations.notifications = await NotificationService.requestAuthorization()
                            model.replan()
                        }
                    } label: { SettingsLabel(title: "Turn On Notifications", symbol: "bell.badge.fill", color: .red) }
                } footer: {
                    Text("Nothing below is sent until notifications are on. If you said no before, turn them on in Settings → Notifications → Productium.")
                }
            }

            Section {
                ForEach(NudgeLevel.allCases, id: \.self) { level in
                    Button { m.state.prefs.nudges.level = level } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: model.state.prefs.nudges.level == level ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(model.state.prefs.nudges.level == level ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(level.title).foregroundStyle(.primary)
                                Text(level.summary).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .accessibilityAddTraits(model.state.prefs.nudges.level == level ? .isSelected : [])
                }
            } header: { Text("How Much to Interrupt") } footer: {
                Text("Every start notification has Start Focus, In 10 Minutes and Can't Today buttons. Starting focus, or answering, stops the rest for that block.")
            }

            Section {
                Toggle(isOn: $m.state.prefs.nudges.deadlines) {
                    SettingsLabel(title: "Deadline Reminders", symbol: "flag.fill", color: .red)
                }
                Toggle(isOn: $m.state.prefs.nudges.arrivingHome) {
                    SettingsLabel(title: "When You Get Home", symbol: "house.fill", color: .blue)
                }
                .disabled(!model.state.integrations.location)
                Toggle(isOn: $m.state.prefs.nudges.scrollCheckIns) {
                    SettingsLabel(title: "Scrolling Check-ins", symbol: "hand.raised.fill", color: .purple)
                }
            } footer: {
                Text("“When you get home” needs Places. Scrolling check-ins come after “Go back anyway” in a pause: \(model.state.prefs.nudges.level.scrollCheckIns.map { "\($0)" }.joined(separator: ", ")) minutes in, and the next only comes if you answer Yes, so they stop on a locked phone.")
            }

            Section {
                Toggle(isOn: Binding(get: { model.state.prefs.nudges.alarms }, set: { v in
                    Task {
                        let ok = v ? await AlarmService.requestAuthorization() : false
                        m.state.prefs.nudges.alarms = v && ok
                        if v && !ok { model.toast = "Alarms aren't allowed. Settings → Productium → Alarms." }
                    }
                })) {
                    SettingsLabel(title: "Alarms for the Important Ones", symbol: "alarm.waves.left.and.right.fill", color: .orange)
                }
                .disabled(!alarmKitAvailable)
            } footer: {
                Text(alarmKitAvailable
                     ? "A real alarm, through silent mode and Focus, at bedtime, when it's time to leave, and 10 minutes into a work block you haven't started (with a Start button). Starting focus cancels that one."
                     : "Needs iOS 26.1 or later. Until then the notifications above do the job.")
            }

            if on {
                Section {
                    let upcoming = NudgePlanner.plan(model.nudgeInput()).prefix(10)
                    if upcoming.isEmpty { Text("Nothing in the next 24 hours.").foregroundStyle(.secondary) }
                    ForEach(Array(upcoming), id: \.id) { n in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(n.at.hm).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(n.title).font(.subheadline).lineLimit(1)
                                Text(n.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                } header: { Text("Coming Up") } footer: {
                    Text(Signature.isFreeTier
                         ? "This build can't mark notifications Time Sensitive, so a Focus can hold them back. Settings → Focus → each Focus → Apps → Add Productium."
                         : "Starts, leave-by and bedtime are Time Sensitive, so they get through most Focuses.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Notifications")
        .onChange(of: model.state.prefs.nudges) { _, _ in model.replan() }
    }

    private var alarmKitAvailable: Bool {
        #if canImport(AlarmKit) && ENABLE_ALARMKIT
        if #available(iOS 26.1, *) { return true }
        #endif
        return false
    }
}

// MARK: - Connections, places, routines

struct ConnectionSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        List {
            Section {
                toggle("Health", "heart.fill", .pink, model.state.integrations.health) { on in
                    if on { try? await HealthService.shared.requestAuthorization() }
                    m.state.integrations.health = on
                    await model.refresh(full: false)
                }
                toggle("Read Calendar", "calendar", .red, model.state.integrations.calendarImport) { on in
                    m.state.integrations.calendarImport = on ? await CalendarService.shared.requestAccess() : false
                    await model.refresh(full: false)
                }
                toggle("Write Plan to Calendar", "calendar.badge.plus", .red, model.state.integrations.calendarExport) { on in
                    m.state.integrations.calendarExport = on ? await CalendarService.shared.requestAccess() : false
                    model.replan()
                }
            } footer: {
                Text("Health brings in sleep, steps and daylight. The plan is written to a separate “Productium” calendar.")
            }
            Section {
                toggle("Notifications", "bell.badge.fill", .red, model.state.integrations.notifications) { on in
                    m.state.integrations.notifications = on ? await NotificationService.requestAuthorization() : false
                    model.replan()
                }
                toggle("Wake-Up Alarms", "alarm.fill", .orange, model.state.integrations.alarms) { on in
                    m.state.integrations.alarms = on ? await AlarmService.requestAuthorization() : false
                    model.replan()
                }
                #if !FREE_TIER
                Toggle(isOn: $m.state.integrations.liveActivities) {
                    SettingsLabel(title: "Live Activity", symbol: "platter.filled.top.iphone", color: .blue)
                }
                #endif
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Connections")
    }

    private func toggle(_ title: String, _ symbol: String, _ color: Color, _ value: Bool,
                        _ set: @escaping @MainActor (Bool) async -> Void) -> some View {
        Toggle(isOn: Binding(get: { value }, set: { on in Task { await set(on) } })) {
            SettingsLabel(title: title, symbol: symbol, color: color)
        }
    }
}

struct PlacesSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        List {
            Section {
                Toggle("Auto Check-in with Places", isOn: Binding(get: { model.state.integrations.location }, set: { on in
                    m.state.integrations.location = on
                    if on { LocationService.shared.requestAlways() }
                    LocationService.shared.monitor(on ? model.state.places : [])
                    model.save()
                }))
            } footer: {
                Text("Leaving home and arriving at school get logged on their own, so your commute is learned without tapping. Only arrive/leave events are kept, never a location history.")
            }
            Section("Saved Places") {
                ForEach(["home", "school"], id: \.self) { id in
                    Button {
                        Task {
                            guard let loc = await LocationService.shared.currentLocation() else { model.toast = "Couldn't get your location."; return }
                            m.state.places.removeAll { $0.id == id }
                            m.state.places.append(SavedPlace(id: id, name: id.capitalized, latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude))
                            LocationService.shared.monitor(model.state.places)
                            model.toast = "\(id.capitalized) saved."
                            model.save()
                        }
                    } label: {
                        LabeledContent {
                            Text(model.state.places.contains { $0.id == id } ? "Saved" : "Not Set")
                        } label: {
                            SettingsLabel(title: "I'm at \(id.capitalized) Now", symbol: id == "home" ? "house.fill" : "graduationcap.fill",
                                          color: id == "home" ? .blue : .orange)
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Places")
    }
}

struct RoutineSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        List {
            Section {
                ForEach($m.state.routines) { $r in
                    Toggle(isOn: $r.enabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name)
                            Text(r.isLearned ? "Usually \(r.minutes) min (learned)" : "About \(r.defaultMinutes) min (still learning)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Durations are learned from your check-ins and places.")
            }
            Section {
                Button("Re-learn Routines", role: .destructive) {
                    for i in m.state.routines.indices { m.state.routines[i].samples = [] }
                    model.replan()
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Routines")
        .onChange(of: model.state.routines) { _, _ in model.replan() }
    }
}

// MARK: - Backup & restore

/// The backup as a document, so the system save sheet can put it anywhere (Files, iCloud Drive…).
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct BackupSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("backup.lastAt") private var lastBackup: Double = 0
    @State private var document: BackupDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var pending: RestorePreview?
    @State private var errorText: String?
    @State private var confirmDelete = false
    @State private var exportURLs: [URL] = []

    var body: some View {
        List {
            Section {
                Button {
                    Task {
                        do {
                            document = BackupDocument(data: try await model.backupData())
                            exporting = true
                        } catch {
                            errorText = error.localizedDescription
                        }
                    }
                } label: {
                    SettingsLabel(title: "Back Up All Data", symbol: "square.and.arrow.down.fill", color: .blue)
                }
                if lastBackup > 0 {
                    LabeledContent("Last Backup", value: Date(timeIntervalSince1970: lastBackup).formatted(date: .abbreviated, time: .shortened))
                }
            } footer: {
                Text("Saves every byte Productium keeps to one file you choose where to keep: tasks, schedule, check-ins, sleep and screen-time history, flashcards, what it has learned about you, About You, every prompt you've sent (with its screenshots) and every AI reply, AI usage, all settings, and a snapshot of notifications and permissions for debugging. Your API key isn't included: it stays in the Keychain.")
            }

            Section {
                Button { importing = true } label: {
                    SettingsLabel(title: "Restore from Backup…", symbol: "arrow.counterclockwise", color: .green)
                }
            } footer: {
                Text("Replaces everything on this phone with the backup. What's here now is set aside first, so nothing is lost by picking the wrong file.")
            }

            Section {
                if exportURLs.isEmpty {
                    Button { exportURLs = (try? model.exportFiles()) ?? [] } label: {
                        SettingsLabel(title: "Export Spreadsheets & Calendar", symbol: "tablecells.fill", color: .green)
                    }
                } else {
                    ShareLink(items: exportURLs) {
                        SettingsLabel(title: "Share \(exportURLs.count) Files", symbol: "square.and.arrow.up.fill", color: .blue)
                    }
                }
            } footer: {
                Text("CSV files for your own analysis, plus your plan as an .ics calendar.")
            }

            Section {
                Button("Delete All Data", role: .destructive) { confirmDelete = true }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Backup & Restore")
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: model.backupFilename) { r in
            switch r {
            case .success:
                lastBackup = Date().timeIntervalSince1970
                model.toast = "Backup saved."
            case .failure(let e):
                errorText = e.localizedDescription
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { r in
            switch r {
            case .success(let url):
                do { pending = try model.readBackup(from: url) } catch { errorText = (error as? ExportBundle.ReadError)?.description ?? "That file isn't a Productium export." }
            case .failure(let e):
                errorText = e.localizedDescription
            }
        }
        .alert("Restore This Backup?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { p in
            Button("Replace All Data", role: .destructive) { model.applyRestore(p) }
            Button("Cancel", role: .cancel) {}
        } message: { p in
            Text((p.exportedAt.map { "Made \($0.formatted(date: .abbreviated, time: .shortened)). " } ?? "") + p.summary
                 + " Everything on this phone will be replaced.")
        }
        .alert("Couldn't Do That", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .confirmationDialog("Delete all Productium data on this phone?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete All Data", role: .destructive) { model.deleteEverything() }
        } message: {
            Text("Back up first if you might want it again.")
        }
    }
}

/// about-me.md in a plain text editor. Whatever the student writes or changes is marked "(you)"
/// and the AI never overwrites it.
struct AboutYouView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .padding(.horizontal, 12)
            Text("What Productium knows about you. Lines you write or change end in (you), and the AI never overwrites them. Stated lines come from what you tell the Inbox; Inferred and Patterns lines come from the weekly reflection.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(16)
        }
        .navigationTitle("About You")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { model.saveAboutMe(editedText: text); text = model.aboutMe.markdown }
                    .disabled(text == model.aboutMe.markdown)
            }
        }
        .onAppear {
            guard !loaded else { return }
            text = model.aboutMe.markdown
            loaded = true
        }
    }
}

struct InstallSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if let e = model.signatureExpiry {
                Section { LabeledContent("Works Until", value: e.formatted(date: .abbreviated, time: .shortened)) }
            }
            Section {
                Text("Free signing lasts 7 days. SideStore re-signs it on your phone over Wi-Fi: open SideStore, connect LocalDevVPN, tap Refresh All.")
                Text("To make it automatic, add a daily Shortcuts automation with SideStore's “Refresh All Apps” action.")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Keeping It Installed")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct WeekdayToggles: View {
    @Binding var days: Set<Int>
    var label: String
    private let names = ["S", "M", "T", "W", "T", "F", "S"]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
            HStack(spacing: 0) {
                ForEach(1...7, id: \.self) { d in
                    Button {
                        if days.contains(d) { days.remove(d) } else { days.insert(d) }
                    } label: {
                        Text(names[d - 1]).font(.subheadline.weight(.semibold)).frame(width: 36, height: 36)
                            .background(days.contains(d) ? Color.accentColor : Color(.tertiarySystemFill), in: Circle())
                            .foregroundStyle(days.contains(d) ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(Calendar.current.weekdaySymbols[d - 1])
                    .accessibilityAddTraits(days.contains(d) ? .isSelected : [])
                }
            }
        }
    }
}

struct TimePicker: View {
    var label: String
    @Binding var time: TimeOfDay
    var body: some View {
        DatePicker(label, selection: Binding(
            get: { Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date() },
            set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); time = TimeOfDay(c.hour ?? 0, c.minute ?? 0) }),
                   displayedComponents: .hourAndMinute)
    }
}

struct CommitmentEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var commitment: Commitment

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name (e.g. Soccer)", text: $commitment.title)
                Picker("Type", selection: $commitment.kind) {
                    ForEach(CommitmentKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                WeekdayToggles(days: $commitment.weekdays, label: "Days")
                TimePicker(label: "Starts", time: $commitment.start)
                TimePicker(label: "Ends", time: $commitment.end)
                Stepper("Travel buffer: \(commitment.bufferMinutes) min", value: $commitment.bufferMinutes, in: 0...60, step: 5)
                ColorChoice(color: $commitment.color, automatic: Theme.fixed)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.state.commitments.removeAll { $0.id == commitment.id }
                        model.state.commitments.append(commitment)
                        model.replan()
                        dismiss()
                    }
                    .disabled(commitment.title.isEmpty || commitment.weekdays.isEmpty || commitment.end <= commitment.start)
                }
            }
        }
    }
}

struct ScienceView: View {
    private let points: [(String, String)] = [
        ("Spaced, not crammed", "Test prep is spread over expanding gaps before the test, and sessions use retrieval (self-testing). These are the two highest-rated study techniques (Dunlosky et al. 2013; Cepeda et al. 2008)."),
        ("Sleep is protected", "Trading sleep for study backfires for high schoolers (Gillen-O'Neel et al. 2013). Small trade-offs are allowed only for deadline-driven writing, never before tests."),
        ("Estimates get corrected", "Everyone underestimates (planning fallacy). Productium learns how long your tasks really take and plans for that."),
        ("Plans fit you", "If you complete less than planned, it plans less. Achievable plans build self-efficacy. Hard work goes in the hours you actually get work done."),
        ("Big tasks become small steps", "Applications and essays are broken into steps with their own dates and paced in brief regular sessions (Boice 1989)."),
        ("Free time stays free", "Free time is protected, and loosely labelled, since over-scheduling leisure makes it feel like work (Tonietto & Malkoc 2016)."),
        ("Friction, not willpower", "A pause before a distracting app cut openings by more than half (Grüning et al. 2023). Limits taper ~10% a week so they stay achievable."),
        ("No guilt", "Missed blocks get moved, not counted against you. Self-forgiveness reduces future procrastination (Wohl et al. 2010)."),
    ]
    var body: some View {
        List(points, id: \.0) { p in
            VStack(alignment: .leading, spacing: 4) {
                Text(p.0).font(.headline)
                Text(p.1).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("The science")
    }
}
