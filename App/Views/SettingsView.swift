import SwiftUI
import FamilyControls
import UniformTypeIdentifiers
import ProductiumCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showPicker = false
    @State private var selection = FamilyActivitySelection()
    @State private var serverURL = ClaudeClient.shared.baseURL?.absoluteString ?? ""
    @State private var serverKey = ClaudeClient.shared.apiKey ?? ""
    @State private var testing = false
    @State private var importing = false
    @State private var confirmDelete = false
    @State private var interests = ""

    var body: some View {
        @Bindable var m = model
        Form {
            Section("Schedule") {
                NavigationLink { ScheduleEditor() } label: {
                    LabeledContent("Classes & activities", value: "\(model.state.commitments.count)")
                }
                WeekdayToggles(days: $m.state.prefs.schoolDays, label: "School days")
            }

            Section {
                Stepper("Sleep need: \(minutesLabel(model.state.prefs.sleepNeedMinutes))", value: $m.state.prefs.sleepNeedMinutes, in: 450...600, step: 15)
                Toggle("Wake-up worked back from first class", isOn: $m.state.prefs.autoWake)
                TimePicker(label: model.state.prefs.autoWake ? "Latest school-day wake" : "School-day wake", time: $m.state.prefs.schoolDayWake)
                TimePicker(label: "Free-day wake", time: $m.state.prefs.freeDayWake)
                Stepper("Wind-down: \(model.state.prefs.windDownMinutes) min", value: $m.state.prefs.windDownMinutes, in: 15...60, step: 5)
            } header: { Text("Sleep") } footer: {
                Text("Teens need 8–10 h (AASM). Keeping free-day wake within ~1 h of school days avoids “social jet lag”.")
            }

            Section {
                Stepper("Max study, school day: \(minutesLabel(model.state.prefs.maxStudyMinutesSchoolDay))", value: $m.state.prefs.maxStudyMinutesSchoolDay, in: 30...360, step: 15)
                Stepper("Max study, free day: \(minutesLabel(model.state.prefs.maxStudyMinutesFreeDay))", value: $m.state.prefs.maxStudyMinutesFreeDay, in: 30...480, step: 15)
                Stepper("Protected free time: \(minutesLabel(model.state.prefs.minFreeMinutesSchoolDay))", value: $m.state.prefs.minFreeMinutesSchoolDay, in: 30...300, step: 15)
                Toggle("Allow small sleep trade-offs for deadlines", isOn: $m.state.prefs.allowSleepTradeoffs)
            } header: { Text("Study") } footer: {
                Text("Trade-offs are capped at 1 h on rare nights, only for high-stakes writing or projects, and never before a test. Sleep is when studying gets stored.")
            }

            #if FREE_TIER
            Section {
                Text("Blocking and measuring apps uses Apple's Screen Time API, which needs a paid developer account. This build was signed with a free one.")
                    .font(.subheadline)
                Text("Meanwhile you can add friction with Shortcuts: Automation → + → App → pick an app → Is Opened → Run Immediately. Actions: “Should I pause?” (Productium) → If Result is true → Open URLs productium://gap. Opening that app now brings up a short pause with something better to do. “I'll go back anyway” skips the pause for 10 minutes.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Screen time") }
            #else
            Section {
                Toggle("Measure & limit distracting apps", isOn: Binding(get: { model.state.integrations.screenTime }, set: { on in
                    Task {
                        if on { m.state.integrations.screenTime = await ScreenTimeService.shared.requestAuthorization() }
                        else { m.state.integrations.screenTime = false; ScreenTimeService.shared.disable() }
                        model.replan()
                    }
                }))
                if model.state.integrations.screenTime {
                    Button("Choose distracting apps & sites") {
                        selection = ScreenTimeService.shared.selection
                        showPicker = true
                    }
                    Stepper("Goal: \(minutesLabel(model.state.prefs.screenTimeGoalMinutes))/day", value: $m.state.prefs.screenTimeGoalMinutes, in: 0...240, step: 15)
                    Toggle("Offer a short read when blocked", isOn: Binding(
                        get: { SharedConfig.defaults.bool(forKey: SharedConfig.Key.nudgeOnShield) },
                        set: { SharedConfig.defaults.set($0, forKey: SharedConfig.Key.nudgeOnShield) }))
                    if let t = model.state.taper.targetMinutes {
                        LabeledContent("Today's limit", value: minutesLabel(t))
                    }
                }
            } header: { Text("Screen time") } footer: {
                Text("First week: measuring only. Then the daily limit drops about 10% a week, held steady after a tough week, down to your goal. Apps are also paused during focus blocks and wind-down.")
            }

            #endif

            Section("Connections") {
                Toggle("Health (sleep, steps, daylight)", isOn: Binding(get: { model.state.integrations.health }, set: { on in
                    Task {
                        if on { try? await HealthService.shared.requestAuthorization() }
                        m.state.integrations.health = on
                        await model.refresh(full: false)
                    }
                }))
                Toggle("Read calendar", isOn: Binding(get: { model.state.integrations.calendarImport }, set: { on in
                    Task { m.state.integrations.calendarImport = on ? await CalendarService.shared.requestAccess() : false; await model.refresh(full: false) }
                }))
                Toggle("Write plan to “Productium” calendar", isOn: Binding(get: { model.state.integrations.calendarExport }, set: { on in
                    Task { m.state.integrations.calendarExport = on ? await CalendarService.shared.requestAccess() : false; model.replan() }
                }))
                Toggle("Notifications", isOn: Binding(get: { model.state.integrations.notifications }, set: { on in
                    Task { m.state.integrations.notifications = on ? await NotificationService.requestAuthorization() : false; model.replan() }
                }))
                Toggle("Wake-up alarms", isOn: Binding(get: { model.state.integrations.alarms }, set: { on in
                    Task { m.state.integrations.alarms = on ? await AlarmService.requestAuthorization() : false; model.replan() }
                }))
                Toggle("Live Activity for current block", isOn: $m.state.integrations.liveActivities)
            }

            Section {
                Toggle("Auto check-in with places", isOn: Binding(get: { model.state.integrations.location }, set: { on in
                    m.state.integrations.location = on
                    if on { LocationService.shared.requestAlways() }
                    LocationService.shared.monitor(on ? model.state.places : [])
                    model.save()
                }))
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
                        LabeledContent("I'm at \(id) now", value: model.state.places.contains { $0.id == id } ? "Saved" : "Not set")
                    }
                }
            } header: { Text("Places") } footer: {
                Text("Leaving home and arriving at school get logged on their own, so your commute is learned without tapping. Only arrive/leave events are kept, no location history.")
            }

            Section("Routines") {
                ForEach($m.state.routines) { $r in
                    HStack {
                        Toggle(r.name, isOn: $r.enabled)
                        Text(r.isLearned ? "\(r.minutes)m" : "~\(r.defaultMinutes)m").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Button("Re-learn routines") {
                    for i in m.state.routines.indices { m.state.routines[i].samples = [] }
                    model.replan()
                }
            }

            Section {
                TextField("Server URL (https://pi.tailnet.ts.net)", text: $serverURL).textInputAutocapitalization(.never).keyboardType(.URL)
                SecureField("API key", text: $serverKey)
                Button(testing ? "Testing…" : "Save & test") {
                    ClaudeClient.shared.baseURL = URL(string: serverURL.trimmingCharacters(in: .whitespaces))
                    ClaudeClient.shared.apiKey = serverKey.trimmingCharacters(in: .whitespaces)
                    testing = true
                    Task {
                        model.serverOnline = await ClaudeClient.shared.ping()
                        testing = false
                        model.toast = model.serverOnline == true ? "Connected to Claude." : "Couldn't reach it. Is Tailscale on?"
                    }
                }
                if let ok = model.serverOnline {
                    Label(ok ? "Online" : "Offline", systemImage: ok ? "checkmark.circle" : "xmark.circle").foregroundStyle(ok ? .green : .red)
                }
            } header: { Text("Claude") } footer: {
                Text("Your own claude-server (Haiku for quick parsing, Sonnet for planning advice). Planning itself runs on the phone and works offline.")
            }

            Section("Short reads") {
                TextField("Interests (e.g. space, basketball, music)", text: $interests)
                    .onSubmit { m.state.prefs.interests = interests.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }; model.save() }
            }

            Section("Your data") {
                Button("Import backup") { importing = true }
                Button("Delete everything", role: .destructive) { confirmDelete = true }
            }

            Section {
                NavigationLink("Why it works this way") { ScienceView() }
            }
        }
        .navigationTitle("Settings")
        .onChange(of: model.state.prefs) { _, _ in model.replan() }
        .onAppear { interests = model.state.prefs.interests.joined(separator: ", ") }
        .familyActivityPicker(isPresented: $showPicker, selection: $selection)
        .onChange(of: selection) { _, s in ScreenTimeService.shared.selection = s; model.replan() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { r in
            if case .success(let url) = r { try? model.importBackup(from: url) }
        }
        .confirmationDialog("Delete all Productium data on this phone?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { model.deleteEverything() }
        }
    }
}

struct WeekdayToggles: View {
    @Binding var days: Set<Int>
    var label: String
    private let names = ["S", "M", "T", "W", "T", "F", "S"]
    var body: some View {
        VStack(alignment: .leading) {
            Text(label)
            HStack {
                ForEach(1...7, id: \.self) { d in
                    Button {
                        if days.contains(d) { days.remove(d) } else { days.insert(d) }
                    } label: {
                        Text(names[d - 1]).font(.subheadline.weight(.semibold)).frame(width: 34, height: 34)
                            .background(days.contains(d) ? Theme.accent : Color(.tertiarySystemFill), in: Circle())
                            .foregroundStyle(days.contains(d) ? .white : .primary)
                    }
                    .buttonStyle(.plain)
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

struct ScheduleEditor: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Commitment?

    var body: some View {
        @Bindable var m = model
        List {
            ForEach(model.state.commitments) { c in
                Button { editing = c } label: {
                    VStack(alignment: .leading) {
                        Text(c.title).foregroundStyle(.primary)
                        Text("\(c.weekdays.sorted().map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: " ")) · \(c.start.label)–\(c.end.label)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { m.state.commitments.remove(atOffsets: $0); model.replan() }
            Button {
                editing = Commitment(title: "", kind: .extracurricular, weekdays: [2, 4], start: TimeOfDay(16), end: TimeOfDay(17, 30))
            } label: { Label("Add", systemImage: "plus") }
        }
        .navigationTitle("Schedule")
        .sheet(item: $editing) { c in CommitmentEditor(commitment: c) }
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
