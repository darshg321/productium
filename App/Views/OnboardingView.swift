import SwiftUI
import FamilyControls
import ProductiumCore

/// Two minutes, once. After this the app learns rather than asks.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    @State private var schoolStart = TimeOfDay(8, 30)
    @State private var schoolEnd = TimeOfDay(15, 0)
    @State private var schoolDays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var activityText = ""
    @State private var editing: Commitment?
    @State private var showPicker = false
    @State private var selection = FamilyActivitySelection()
    @State private var serverURL = ""
    @State private var serverKey = ""

    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: Double(step), total: 5).tint(Theme.accent).padding()
            TabView(selection: $step) {
                welcome.tag(0)
                school.tag(1)
                activities.tag(2)
                sleep.tag(3)
                connect.tag(4)
                server.tag(5)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut, value: step)
            HStack {
                if step > 0 { Button("Back") { step -= 1 }.foregroundStyle(.secondary) }
                Spacer()
                Button(step == 5 ? "Start" : "Next") { advance() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding()
        }
        .sheet(item: $editing) { c in CommitmentEditor(commitment: c) }
        .familyActivityPicker(isPresented: $showPicker, selection: $selection)
        .onChange(of: selection) { _, s in ScreenTimeService.shared.selection = s }
    }

    private func advance() {
        if step == 1 {
            model.state.commitments.removeAll { $0.kind == .school && $0.title == "School" }
            model.state.commitments.append(Commitment(title: "School", kind: .school, weekdays: schoolDays, start: schoolStart, end: schoolEnd))
            model.state.prefs.schoolDays = schoolDays
        }
        if step == 5 {
            if !serverURL.isEmpty {
                ClaudeClient.shared.baseURL = URL(string: serverURL.trimmingCharacters(in: .whitespaces))
                ClaudeClient.shared.apiKey = serverKey.trimmingCharacters(in: .whitespaces)
            }
            model.state.onboarded = true
            model.save()
            Task { await model.refresh() }
            return
        }
        step += 1
    }

    private func page<C: View>(_ title: String, _ subtitle: String, @ViewBuilder _ content: () -> C) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(title).font(.largeTitle.bold())
                Text(subtitle).foregroundStyle(.secondary)
                content()
            }
            .padding(24)
        }
    }

    private var welcome: some View {
        page("Productium", "A calm planner that does the planning for you.") {
            VStack(alignment: .leading, spacing: 16) {
                Label("Tell it what's due. It plans when to do it.", systemImage: "calendar.badge.clock")
                Label("Test prep is spaced out. Sleep is protected.", systemImage: "moon.stars")
                Label("It learns your routine, so you don't log it.", systemImage: "figure.walk")
                Label("Scrolling gets gradually quieter.", systemImage: "hourglass")
                Label("Your data stays on your phone.", systemImage: "lock")
            }
            .font(.body)
            .padding(.top, 8)
        }
    }

    private var school: some View {
        page("School", "Just the outline. Classes don't need to be listed one by one.") {
            WeekdayToggles(days: $schoolDays, label: "School days")
            TimePicker(label: "Starts", time: $schoolStart)
            TimePicker(label: "Ends", time: $schoolEnd)
        }
    }

    private var activities: some View {
        page("Activities", "Sports, clubs, a job, anything that repeats every week.") {
            HStack {
                TextField("e.g. soccer mon wed 4–6", text: $activityText).textFieldStyle(.roundedBorder)
                Button {
                    let t = activityText
                    activityText = ""
                    Task { await model.submit(t) }
                } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(activityText.isEmpty || !ClaudeClient.shared.isConfigured)
            }
            if !ClaudeClient.shared.isConfigured {
                Text("Typing needs your Claude server (last step). Add them by hand for now:").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.state.commitments.filter { $0.kind != .school }) { c in
                HStack {
                    Text(c.title)
                    Spacer()
                    Text("\(c.start.label)–\(c.end.label)").foregroundStyle(.secondary)
                }
            }
            Button {
                editing = Commitment(title: "", kind: .extracurricular, weekdays: [2, 4], start: TimeOfDay(16), end: TimeOfDay(17, 30))
            } label: { Label("Add activity", systemImage: "plus") }
        }
    }

    private var sleep: some View {
        @Bindable var m = model
        let wake = WakePlanner.plan(for: Calendar.current.nextDate(after: Date(), matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) ?? Date(),
                                    commitments: model.state.commitments, events: [], routines: model.state.routines,
                                    prefs: model.state.prefs, calendar: .current)
        return page("Sleep", "Teens need 8–10 hours. Productium works your bedtime back from when you need to be up.") {
            Stepper("I need about \(minutesLabel(model.state.prefs.sleepNeedMinutes))", value: $m.state.prefs.sleepNeedMinutes, in: 480...600, step: 15)
            TimePicker(label: "Free-day wake", time: $m.state.prefs.freeDayWake)
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    Text("School days: up at \(wake.wake.hm)").font(.headline)
                    Text(wake.reason).font(.caption).foregroundStyle(.secondary)
                    Text("Bedtime ≈ \(wake.wake.addingTimeInterval(-Double(model.state.prefs.sleepNeedMinutes) * 60).hm)").font(.subheadline)
                }
            }
            Text("Your commute and morning routine are learned from your first few days, then the wake-up time adjusts itself.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var connect: some View {
        @Bindable var m = model
        return page("Connect", "Each one means less typing. All optional, all changeable later.") {
            PermissionRow(title: "Notifications", detail: "Reply from the lock screen", on: model.state.integrations.notifications) {
                m.state.integrations.notifications = await NotificationService.requestAuthorization()
            }
            PermissionRow(title: "Health", detail: "Sleep, wake time, steps", on: model.state.integrations.health) {
                try? await HealthService.shared.requestAuthorization()
                m.state.integrations.health = true
            }
            PermissionRow(title: "Calendar", detail: "Events and tests already in it", on: model.state.integrations.calendarImport) {
                m.state.integrations.calendarImport = await CalendarService.shared.requestAccess()
            }
            #if !FREE_TIER
            PermissionRow(title: "Screen Time", detail: "Measure and quiet distracting apps", on: model.state.integrations.screenTime) {
                m.state.integrations.screenTime = await ScreenTimeService.shared.requestAuthorization()
                if m.state.integrations.screenTime { showPicker = true }
            }
            #endif
            PermissionRow(title: "Wake-up alarms", detail: "Alarm set to your planned wake time", on: model.state.integrations.alarms) {
                m.state.integrations.alarms = await AlarmService.requestAuthorization()
            }
            PermissionRow(title: "Places", detail: "Auto check-in at home and school", on: model.state.integrations.location) {
                LocationService.shared.requestAlways()
                if let loc = await LocationService.shared.currentLocation() {
                    m.state.places.removeAll { $0.id == "home" }
                    m.state.places.append(SavedPlace(id: "home", name: "Home", latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude))
                    LocationService.shared.monitor(m.state.places)
                }
                m.state.integrations.location = true
            }
            Text("Places saves where you are now as Home. Set School from Settings when you're there.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var server: some View {
        page("Claude", "Optional. Your claude-server lets you type naturally, breaks big tasks into steps, and writes weekly reviews.") {
            TextField("https://your-pi.tailnet.ts.net", text: $serverURL).textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never).keyboardType(.URL)
            SecureField("API key (cs_…)", text: $serverKey).textFieldStyle(.roundedBorder)
            Text("Without it everything still works. You just add tasks with a form instead of a sentence.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let on: Bool
    let action: @MainActor () async -> Void
    @State private var working = false

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if on {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
            } else {
                Button(working ? "…" : "Allow") {
                    working = true
                    Task { await action(); working = false }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}
