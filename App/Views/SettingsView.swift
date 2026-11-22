import SwiftUI
import UniformTypeIdentifiers
import Charts
import ProductiumCore

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
                NavigationLink { PastPromptsView() } label: {
                    LabeledContent { Text("\(model.state.archive.conversations.count)") } label: {
                        SettingsLabel(title: "Past Prompts", symbol: "tray.full.fill", color: .blue)
                    }
                }
                NavigationLink { UsageView(inSheet: false) } label: {
                    LabeledContent { Text("\(tokensLabel(model.tokensToday)) today") } label: {
                        SettingsLabel(title: "AI Usage", symbol: "gauge.with.dots.needle.33percent", color: Theme.meter(model.usageFraction))
                    }
                }
            }

            Section {
                row("Sleep", "bed.double.fill", Theme.sleep, durationLabel(p.sleepNeedMinutes)) { SleepSettings() }
                row("Screen Time", "hourglass", Theme.screen, model.state.taper.targetMinutes.map { durationLabel($0) }) { ScreenTimeSettings() }
                row("Notifications", "bell.badge.fill", .red, model.state.integrations.notifications ? p.nudges.level.title : "Off") { NotificationsSettings() }
            }

            Section {
                row("Goals", "target", .orange, "\(model.goalsAll.count)") { GoalsSettings() }
                row("Categories", "square.grid.2x2.fill", .blue, "\(model.state.categories.nodes.count)") { CategoriesSettings() }
                row("Celebrations", "party.popper.fill", .pink, model.state.rewardSettings.level.title) { CelebrationSettings() }
            }

            Section {
                row("Connections", "link", .green, nil) { ConnectionSettings() }
                row("Shortcuts & Automations", "square.stack.3d.up.fill", .indigo, nil) { ShortcutsGuideView() }
                row("Places", "mappin.and.ellipse", .red, "\(model.state.placeBook.places.filter { $0.name != nil }.count)") { PlacesSettings() }
                row("What Productium Thinks", "brain.head.profile", .orange, nil) { ThinksView() }
                row("About You", "person.text.rectangle.fill", .teal, nil) { AboutYouView() }
            }

            Section {
                row("Backup & Restore", "externaldrive.fill", .gray, nil) { BackupSettings() }
                row("Keeping It Installed", "arrow.clockwise", .indigo,
                    UpdateChecker.shared.available.map { "\($0) available" } ?? "v\(UpdateChecker.installed)") { InstallSettings() }
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
                LabeledContent("Everything", value: AIFeature.box.route.title)
            } header: { Text("Model") } footer: {
                Text("The box, screenshots and the weekly note all use Sonnet at low effort. On this app's own requests it wrote a little over half the tokens Haiku 5.5 did, because Haiku's thinking can't be turned off.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Claude")
        .navigationBarTitleDisplayMode(.inline)
    }
}

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
                Text("The box always works. Project steps and the weekly note wait until tomorrow once the budget is spent.")
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
            while !Task.isCancelled {
                await model.refreshSubscription()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        .onChange(of: model.state.usage.dailyBudget) { _, _ in model.save() }
        .onChange(of: model.state.usage.pauseBackgroundOverBudget) { _, _ in model.save() }
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
                if !model.state.prefs.autoWake {
                    TimePicker(label: "School-Day Wake", time: $m.state.prefs.schoolDayWake)
                    TimePicker(label: "Free-Day Wake", time: $m.state.prefs.freeDayWake)
                }
            } header: { Text("Wake Up") } footer: {
                Text("Keeping free-day wake within about an hour of school days avoids “social jet lag”.")
            }
            Section {
                let r = model.state.healthReads
                LabeledContent("Source", value: r.lastSleepSource ?? "Nothing measured yet")
                LabeledContent("Last read", value: r.lastSuccess.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                if let n = r.lastSleepSamples { LabeledContent("Sleep samples", value: "\(n)") }
                if let e = r.lastError, let at = r.lastErrorAt, at > (r.lastSuccess ?? .distantPast) {
                    Label("Last read failed \(at.formatted(date: .omitted, time: .shortened)): \(e)", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
            } header: { Text("Where Sleep Comes From") } footer: {
                Text("An Apple Watch gives sleep stages; an iPhone alone gives time in bed (Sleep schedule). With neither, sleep is estimated from when the phone went still, and you're asked to confirm it in the morning. A read that finds nothing never wipes a night.")
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
                Toggle("Small Sleep Trade-offs for Deadlines", isOn: $m.state.prefs.allowSleepTradeoffs)
            } footer: {
                Text("Capped at 1 hour on rare nights, only for high-stakes writing or projects, and never before a test. Sleep is when studying gets stored.")
            }
            Section {
                NavigationLink { ThinksView() } label: { Label("How Much You Study, Learned", systemImage: "brain.head.profile") }
            } footer: {
                Text("Productium learns how much you actually get done on school and free days, the free time you keep, and your focus length. Tell the Inbox if it's wrong (“I can do about 2 hours on school days”).")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Study")
        .onChange(of: model.state.prefs) { _, _ in model.replan() }
    }
}

struct ScreenTimeSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            Section {
                ForEach(Recipe.scrolling) { r in NavigationLink { RecipeView(recipe: r) } label: { RecipeRow(recipe: r) } }
            } header: { Text("Add a Pause Instead") } footer: {
                Text("Opening one of those apps brings up a short pause with something better to do. “Go back anyway” skips it for 10 minutes. With the others, Productium counts your minutes and notices when you stop, even if iOS misses you going Home or locking the phone.")
            }
            let log = Friction.log
            if let d = log.today(Date(), calendar: .current) {
                Section {
                    LabeledContent("Opened", value: "\(d.opens)×")
                    LabeledContent("Paused", value: "\(d.pauses)×")
                    if log.measuresClosing || !model.appMinutesToday().isEmpty {
                        let apps = model.appMinutesToday()
                        let scrolling = apps.filter { model.appKind($0.app) == CategoryTree.scrolling }.reduce(0) { $0 + $1.minutes }
                        LabeledContent("Scrolling", value: durationLabel(scrolling))
                        LabeledContent("All apps", value: durationLabel(apps.reduce(0) { $0 + $1.minutes }))
                    }
                } header: { Text("Today") } footer: {
                    Text("“App is closed” can miss going Home or locking the phone, so a session with no clear end counts as your usual length (marked estimated), never the whole evening.")
                }
            }
            Section {
                NavigationLink { ScrollingAppsView() } label: {
                    LabeledContent("Scrolling Apps", value: "\(model.state.scrollingApps.values.filter { $0 }.count) on")
                }
            } footer: {
                Text("This list, not a guess, decides what counts as scrolling in Review, the rings and the plan. Each scrolling app gets its own category under Scrolling; messaging apps go under Messaging.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Screen Time")
        .onChange(of: model.state.prefs) { _, _ in model.replan() }
    }
}

struct ScrollingAppsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let apps = model.state.scrollingApps.keys.sorted { a, b in
            let x = model.state.scrollingApps[a] == true, y = model.state.scrollingApps[b] == true
            return x != y ? x : a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        List {
            if apps.isEmpty {
                Section { Text("Apps show up here once they appear in a Screen Time screenshot you send the Inbox, or in a Shortcuts automation.") }
            } else {
                Section {
                    ForEach(apps, id: \.self) { name in
                        Toggle(isOn: Binding(get: { model.state.scrollingApps[name] ?? false }, set: { model.setScrolling(name, $0) })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(name)
                                if model.state.scrollingApps[name] != true && AppKinds.isMessaging(name) {
                                    Text("Messaging").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("On means it counts as scrolling (Scrolling › the app). Social and video start on; messaging apps count as Messaging; you decide about browsers. Every app you open shows up here once “Screen Time for Every App” is set up.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Scrolling Apps")
    }
}

/// v1.3 E: every kind of prompt in one list, each with a severity (Off, Quiet, Live Activity, Notification, Alarm).
struct NotificationsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        let on = model.state.integrations.notifications
        let alarms = model.state.integrations.alarms
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
                Toggle(isOn: Binding(get: { alarms }, set: { v in
                    Task {
                        m.state.integrations.alarms = v ? await AlarmService.requestAuthorization() : false
                        model.log(.alarm, "master", ["on": "\(m.state.integrations.alarms)"])
                        model.replan()
                        if v && !m.state.integrations.alarms { model.toast = "Alarms aren't allowed. Settings → Productium → Alarms." }
                    }
                })) {
                    SettingsLabel(title: "Alarms Allowed", symbol: "alarm.waves.left.and.right.fill", color: .orange)
                }
                .disabled(!alarmKitAvailable)
            }

            Section {
                ForEach(PromptKind.allCases, id: \.self) { k in
                    Picker(selection: Binding(get: { model.state.prefs.prompts[k] }, set: { m.state.prefs.prompts[k] = $0 })) {
                        ForEach(Severity.allCases, id: \.self) { sev in Text(sev.title).tag(sev) }
                    } label: {
                        Label(k.title, systemImage: k.symbol)
                    }
                    .pickerStyle(.menu)
                }
            } header: { Text("Each Kind") }

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
                Toggle(isOn: $m.state.prefs.nudges.arrivingHome) {
                    SettingsLabel(title: "When You Get Home", symbol: "house.fill", color: .blue)
                }
                .disabled(!model.state.integrations.location)
            } header: { Text("How Much to Interrupt") }

            Section {
                if model.entryAlarmList.isEmpty { Text("None yet. Ask the box: “alarm at 6:40 on school days”.").foregroundStyle(.secondary) }
                ForEach(model.entryAlarmList) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title)
                        Text(e.start.hm + (e.repeats.map { " · " + $0.days.text(.current) } ?? "") + (e.alert?.approved == true ? "" : " · waiting for Allow"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions { Button("Turn Off", role: .destructive) { model.removeAlarm(e) } }
                }
                ForEach(model.approvals.filter(\.addsAlarm)) { ApprovalRow(approval: $0) }
            } header: { Text("Your Alarms") }

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
                } header: { Text("Coming Up") }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Notifications")
        .onChange(of: model.state.prefs) { _, _ in model.replan() }
    }

    private var alarmKitAvailable: Bool {
        #if canImport(AlarmKit) && ENABLE_ALARMKIT
        if #available(iOS 26.1, *) { return true }
        #endif
        return false
    }
}

struct ConnectionSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        List {
            Section {
                toggle("Health", "heart.fill", .pink, model.state.integrations.health) { on in
                    var answered = !on
                    if on { do { try await HealthService.shared.requestAuthorization(); answered = true } catch {} }
                    m.state.integrations.health = on && answered
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
                toggle("Motion", "figure.walk.motion", .green, model.state.integrations.motion) { on in
                    m.state.integrations.motion = on ? await MotionService.shared.requestAccess() : false
                    await model.refresh(full: false)
                }
                toggle("Location", "location.fill", .blue, model.state.integrations.location) { on in
                    m.state.integrations.location = on
                    LocationService.shared.visitsWanted = on
                    if on { LocationService.shared.requestAlways() }
                    LocationService.shared.monitorVisits(on)
                    model.save()
                }
                toggle("Reminders", "checklist", .orange, model.state.integrations.reminders) { on in
                    m.state.integrations.reminders = on ? await ReminderService.shared.requestAccess() : false
                    await ReminderService.shared.sync(model)
                }
                toggle("Screenshots", "photo.on.rectangle", .purple, model.state.integrations.photos) { on in
                    m.state.integrations.photos = on ? await ScreenshotWatcher.shared.requestAccess() : false
                    if m.state.integrations.photos { ScreenshotWatcher.shared.start() }
                    model.save()
                }
                if model.state.integrations.health {
                    LabeledContent("Health Status", value: model.healthStatus.title)
                }
            } footer: {
                Text("""
                Health: sleep (Watch or iPhone), workouts, steps, heart rate. Calendar: events become time the plan works around. \
                Motion: walks and rides log themselves. Location: each entry knows where it happened, places name themselves, and \
                Productium notices when your day differs from the plan. Reminders: your open tasks in a “Productium” list (its \
                widget, your Watch and Siri show them). Screenshots: Screen Time screenshots are read on the phone by themselves.
                """)
            }
            Section {
                toggle("Notifications", "bell.badge.fill", .red, model.state.integrations.notifications) { on in
                    m.state.integrations.notifications = on ? await NotificationService.requestAuthorization() : false
                    model.replan()
                }
            } footer: {
                Text("Full-screen alarms are in Settings → Alarms.")
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
            DailyBackupSection()

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
                Text("Saves every byte Productium keeps to one file you choose where to keep: tasks, your time log, sleep and screen-time history, places, goals, what it has learned about you, About You, every prompt you've sent (with its screenshots) and every AI reply, AI usage, all settings, and a snapshot of notifications and permissions for debugging. Your API key isn't included: it stays in the Keychain.")
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

            FeedbackSection()

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

/// Notes for whoever builds Productium. Kept in the app's data, so they travel in every backup and export.
struct FeedbackSection: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Section {
            TextField("What's working, what isn't, what you'd change…", text: $text, axis: .vertical)
                .lineLimit(3...8)
                .focused($focused)
            Button("Save Feedback") {
                model.addFeedback(text)
                text = ""
                focused = false
                model.toast = "Saved. It's in your next backup."
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ForEach(model.state.feedback.suffix(3).reversed()) { f in
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.text).font(.subheadline).lineLimit(3)
                    Text(f.at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: { Text("Feedback") } footer: {
            Text("Goes into your backups and exports, nowhere else. Send the export file to share it.")
        }
    }
}

/// v1.3 H1: a file a day in a folder outside the app, so an uninstall doesn't take everything with it.
struct DailyBackupSection: View {
    @Environment(AppModel.self) private var model
    @State private var picking = false

    var body: some View {
        let b = model.state.backup
        Section {
            Button { picking = true } label: {
                LabeledContent {
                    Text(b.folderName ?? "Not set")
                } label: {
                    SettingsLabel(title: BackupService.hasFolder ? "Daily Backup Folder" : "Choose a Daily Backup Folder",
                                  symbol: "folder.fill.badge.gearshape", color: .blue)
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { r in
                if case .success(let url) = r { model.chooseBackupFolder(url) }
            }
            if let w = b.lastWrite {
                LabeledContent("Last Daily Backup", value: w.formatted(date: .abbreviated, time: .shortened))
            }
            if b.failing, let e = b.lastError {
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.alert).font(.subheadline)
            }
            if BackupService.hasFolder {
                Button("Back Up Now") { Task { await model.backupIfDue(force: true) } }
            }
        } header: { Text("Every Day") }
    }
}

struct AboutYouView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .padding(.horizontal, 12)
            Text("What Productium knows about you. Lines you write or change end in (you), and the AI never overwrites them. Stated lines come from what you tell the Inbox; Inferred and Patterns lines come from the weekly note, and are listed under What Productium Thinks → Changes.")
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
    @State private var updates = UpdateChecker.shared

    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: "\(UpdateChecker.installed) (\(UpdateChecker.build))")
                if let v = updates.available, let url = updates.latest.flatMap({ URL(string: $0.url) }) {
                    Link(destination: url) { Label("\(v.description) is available", systemImage: "arrow.down.circle.fill") }
                } else if updates.latest != nil {
                    Label("You're up to date", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
            } footer: {
                Text("Checked once a day against this app's public GitHub releases. Nothing about you is sent.")
            }
            if let e = model.signatureExpiry {
                Section { LabeledContent("Works Until", value: e.formatted(date: .abbreviated, time: .shortened)) }
            }
            do {
            Section {
                Text("Free signing lasts 7 days. SideStore re-signs it on your phone over Wi-Fi: open SideStore, connect LocalDevVPN, tap Refresh All.")
                Text("To make it automatic, add a daily Shortcuts automation with SideStore's “Refresh All Apps” action.")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Keeping It Installed")
        .navigationBarTitleDisplayMode(.inline)
        .task { await updates.checkIfDue() }
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

struct CelebrationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        List {
            Section {
                Picker("Celebrations", selection: $m.state.rewardSettings.level) {
                    ForEach(CelebrationLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Toggle("Sound", isOn: $m.state.rewardSettings.sound)
            } footer: {
                Text("Full: a banner when you finish focus, a task or the day's plan, and a bigger one for milestones and personal bests. Subtle: a light tap only. Off: nothing. There are never points or streaks that can break, and nothing for just opening the app.")
            }
            let recent = model.state.rewards.moments.suffix(8).reversed()
            if !recent.isEmpty {
                Section("Lately") {
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, r in
                        LabeledContent(r.title, value: r.at.formatted(.dateTime.month(.abbreviated).day()))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Celebrations")
        .onChange(of: model.state.rewardSettings) { _, _ in model.save() }
    }
}
