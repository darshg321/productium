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
                row("Connections", "link", .green, nil) { ConnectionSettings() }
                row("Places", "location.fill", .blue, model.state.integrations.location ? "On" : "Off") { PlacesSettings() }
                row("Routines", "figure.walk", .orange, nil) { RoutineSettings() }
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
                LabeledContent("Inbox, flashcards, reads", value: "Haiku 4.5")
                LabeledContent("Project steps, weekly note", value: "Sonnet")
            } header: { Text("Models") } footer: {
                Text("Everyday jobs use Haiku 4.5 with thinking off, the cheapest model on the server. Sonnet only runs for the two rare jobs that need reasoning. Flashcards and short reads are made in small batches, only when you open a gap.")
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
                        BigValue(value: tokensLabel(today.total), unit: "tokens today")
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
                Text("Last 7 days: \(tokensLabel(ledger.total(lastDays: 7, now: now, calendar: cal).total)) tokens. "
                     + "In \(tokensLabel(today.prompt)), out \(tokensLabel(today.output)) today.")
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
                Stepper(value: $m.state.usage.dailyBudget, in: 5_000...200_000, step: 5_000) {
                    LabeledContent("Daily budget", value: tokensLabel(model.state.usage.dailyBudget))
                }
                Toggle("Pause background AI over budget", isOn: $m.state.usage.pauseBackgroundOverBudget)
            } header: { Text("Budget") } footer: {
                Text("The Inbox always works. Flashcards, short reads, project steps and the weekly note wait until tomorrow once the budget is spent.")
            }

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
                Text("What claude-server counted for this key. Cached answers count there but use no subscription tokens.")
            }

            let recent = Array(ledger.records.suffix(8).reversed())
            if !recent.isEmpty {
                Section("Recent Requests") {
                    ForEach(recent, id: \.at) { r in
                        HStack(spacing: 12) {
                            IconTile(symbol: Theme.symbol(for: r.feature), color: Theme.color(for: r.feature), size: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.feature.title).font(.subheadline)
                                Text("\(r.at.relativeDay.capitalized), \(r.at.hm) · \(r.model)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(tokensLabel(r.tokens.total)).font(.subheadline.monospacedDigit())
                                Text("\(tokensLabel(r.tokens.prompt)) in · \(tokensLabel(r.tokens.output)) out")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("AI Usage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refreshServerUsage() }
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
                ForEach(model.state.commitments) { c in
                    Button { editing = c } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).foregroundStyle(.primary)
                            Text("\(c.weekdays.sorted().map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: " ")), \(c.start.label) to \(c.end.label)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { m.state.commitments.remove(atOffsets: $0); model.replan() }
                Button {
                    editing = Commitment(title: "", kind: .extracurricular, weekdays: [2, 4], start: TimeOfDay(16), end: TimeOfDay(17, 30))
                } label: { Label("Add Class or Activity", systemImage: "plus") }
            } header: { Text("Classes & Activities") } footer: {
                Text("Or just tell the Inbox: “soccer mon and wed 4 to 5:30”.")
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
                Text("Shortcuts → Automation → + → App → pick an app → Is Opened → Run Immediately. Add “Should I pause?” (Productium), then If Result is true → Open URLs productium://gap.")
                    .font(.subheadline)
            } header: { Text("Add a Pause Instead") } footer: {
                Text("Opening that app brings up a short pause with something better to do. “Go back anyway” skips it for 10 minutes.")
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
                    do {
                        document = BackupDocument(data: try model.backupData())
                        exporting = true
                    } catch {
                        errorText = error.localizedDescription
                    }
                } label: {
                    SettingsLabel(title: "Back Up All Data", symbol: "square.and.arrow.down.fill", color: .blue)
                }
                if lastBackup > 0 {
                    LabeledContent("Last Backup", value: Date(timeIntervalSince1970: lastBackup).formatted(date: .abbreviated, time: .shortened))
                }
            } footer: {
                Text("Saves everything in Productium to one file you choose where to keep: tasks, schedule, check-ins, sleep and screen-time history, flashcards, what it has learned about you, AI usage and all settings. Your API key isn't included.")
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
                do { pending = try model.readBackup(from: url) } catch { errorText = "That file isn't a Productium backup." }
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
