import SwiftUI
import FamilyControls
import ProductiumCore

/// Setup, once. Each page asks for one thing. Your week goes in through the same box
/// you'll use every day, so there are no forms.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var page: Page = .welcome
    @State private var serverURL = ClaudeClient.shared.baseURL?.absoluteString ?? ""
    @State private var serverKey = ClaudeClient.shared.apiKey ?? ""
    @State private var serverState: ServerState = .untested
    @State private var permissionsDone = false
    @State private var workingPermissions = false
    @State private var showPicker = false
    @State private var selection = FamilyActivitySelection()

    enum ServerState { case untested, testing, ok, failed }

    enum Page: Int, CaseIterable {
        case welcome, claude, week, sleep, permissions, scrolling, keepAlive
    }

    private var pages: [Page] {
        Page.allCases.filter { $0 != .keepAlive || Signature.isFreeTier }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Progress as a ruler: one segment per page, filled up to here.
            HStack(spacing: 3) {
                ForEach(pages, id: \.self) { p in
                    Rectangle().fill(p.rawValue <= page.rawValue ? Theme.cobalt : Theme.fog).frame(height: 4)
                }
            }
            .padding(.horizontal, 20).padding(.top, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    content
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)

            HStack {
                if page != .welcome { TextAction("Back", color: .secondary) { move(-1) } }
                Spacer()
                Button(page == pages.last ? "Start" : "Continue") { advance() }
                    .buttonStyle(SlabButtonStyle())
                    .frame(width: 160)
                    .disabled(!canContinue)
                    .opacity(canContinue ? 1 : 0.4)
            }
            .padding(20)
        }
        .familyActivityPicker(isPresented: $showPicker, selection: $selection)
        .onChange(of: selection) { _, s in ScreenTimeService.shared.selection = s }
    }

    private var canContinue: Bool {
        switch page {
        case .claude: return serverState == .ok
        default: return true
        }
    }

    private func move(_ d: Int) {
        guard let i = pages.firstIndex(of: page), pages.indices.contains(i + d) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { page = pages[i + d] }
    }

    private func advance() {
        if page == pages.last {
            model.state.onboarded = true
            model.save()
            Task { await model.refresh() }
        } else {
            move(1)
        }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .welcome: welcome
        case .claude: claude
        case .week: week
        case .sleep: sleep
        case .permissions: permissions
        case .scrolling: scrolling
        case .keepAlive: keepAlive
        }
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Tell it everything.\nIt plans the rest.").font(.display(32, .bold))
            Text("You type what's due, what happened, and what changed, in any order and as messily as you like. Productium works out when to do things, protects your sleep and free time, and learns your routine so you don't have to log it.")
                .font(.body).lineSpacing(3)
            Text("Setup takes about two minutes.").foregroundStyle(.secondary)
        }
    }

    private var claude: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect Claude").font(.display(28, .bold))
            Text("Productium runs on your claude-server. Use the address from Tailscale (it starts with https:// and ends in .ts.net) and the API key you made for Productium. Tailscale needs to be on for this phone.")
                .lineSpacing(3)
            field("https://your-pi.your-tailnet.ts.net", text: $serverURL, secure: false)
            field("API key (starts with cs_)", text: $serverKey, secure: true)
            HStack(spacing: 16) {
                TextAction(serverState == .testing ? "Checking…" : "Check connection") { test() }
                switch serverState {
                case .ok: Text("Connected").foregroundStyle(Theme.cobalt)
                case .failed: Text("No answer. Is Tailscale on, and is the address right?").foregroundStyle(Theme.signal).font(.subheadline)
                default: EmptyView()
                }
            }
        }
    }

    private var week: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your week").font(.display(28, .bold))
            Text("Write your school hours, your activities and anything coming up. A screenshot of your timetable works too. For example: “school mon–fri 8:30 to 3, soccer mon and wed 4–5:30, chem test thursday, college essay due dec 1”.")
                .lineSpacing(3)
            DumpBox()
            let known = model.state.commitments
            if !known.isEmpty || !model.state.items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("So far").font(.subheadline.weight(.semibold))
                    ForEach(known) { c in
                        Text("\(c.title), \(c.weekdays.sorted().map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: " ")), \(c.start.label) to \(c.end.label)")
                            .font(.subheadline)
                    }
                    ForEach(model.state.items.filter { !$0.isDone && $0.parentId == nil }) { i in
                        Text("\(i.title), due \(i.due.relativeDay)").font(.subheadline)
                    }
                }
                Text("Anything wrong? Just write the correction in the box.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var sleep: some View {
        @Bindable var m = model
        let monday = Calendar.current.nextDate(after: Date(), matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) ?? Date()
        let wake = WakePlanner.plan(for: monday, commitments: model.state.commitments, events: [], routines: model.state.routines,
                                    prefs: model.state.prefs, calendar: .current, exceptions: model.state.exceptions)
        return VStack(alignment: .leading, spacing: 18) {
            Text("Sleep").font(.display(28, .bold))
            Text("Teens need 8 to 10 hours. Your bedtime gets worked back from when you have to be up, which comes from your first class and how long it takes you to get there.")
                .lineSpacing(3)
            Stepper(value: $m.state.prefs.sleepNeedMinutes, in: 480...600, step: 15) {
                Text("About \(minutesLabel(model.state.prefs.sleepNeedMinutes)) a night").font(.display(18, .semibold))
            }
            Text("On a school day that means up at \(wake.wake.hm) and in bed by \(wake.wake.addingTimeInterval(-Double(model.state.prefs.sleepNeedMinutes) * 60).hm).")
                .foregroundStyle(.secondary)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Let it see your day").font(.display(28, .bold))
            Text("Each of these saves you from typing something. iOS will ask about each one in turn.")
                .lineSpacing(3)
            VStack(alignment: .leading, spacing: 12) {
                reason("Notifications", "Reply to “how did it go?” from the lock screen.")
                reason("Health", "Sleep, wake-up time and steps, so a short night means a lighter day.")
                reason("Calendar", "So it never plans over things already in there.")
                reason("Location", "Notices when you leave home and get to school, and learns how long it takes. Choose “Always”.")
                reason("Alarms", "Sets your wake-up alarm for you.")
            }
            if permissionsDone {
                Text("All set.").foregroundStyle(Theme.cobalt)
            } else {
                Button(workingPermissions ? "Asking…" : "Turn these on") { Task { await askAll() } }
                    .buttonStyle(SlabButtonStyle())
                    .disabled(workingPermissions)
            }
        }
    }

    @ViewBuilder private var scrolling: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Less scrolling").font(.display(28, .bold))
            #if FREE_TIER
            Text("This build can't block apps (that needs a paid Apple developer account), so two small habits do the job.")
                .lineSpacing(3)
            Text("A pause before the apps you lose time in").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Open the Shortcuts app and go to Automation.")
                step(2, "Tap +, choose App, pick one app (Instagram, TikTok…), select Is Opened, then Run Immediately.")
                step(3, "Add the action “Should I pause?” from Productium.")
                step(4, "Add an If action: If Result is true, add the action Open URLs with productium://gap.")
                step(5, "Repeat for each app (Shortcuts allows one app per automation).")
            }
            TextAction("Open Shortcuts") { if let u = URL(string: "shortcuts://") { UIApplication.shared.open(u) } }
            Text("Opening one of those apps now shows a short pause with something better to do. “Go back anyway” turns the pause off for 10 minutes.")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("One screenshot a week").font(.headline).padding(.top, 8)
            Text("On Sundays, go to Settings → Screen Time → See All App & Website Activity → Week, take a screenshot, and drop it in the box. Claude reads it, and the weekly goal adjusts from there. You'll get a reminder.")
                .lineSpacing(3)
            #else
            Text("Pick the apps and sites you lose time in. For the first week Productium only measures. After that the daily limit drops about 10% a week, and those apps pause during focus blocks and before bed.")
                .lineSpacing(3)
            if model.state.integrations.screenTime {
                TextAction("Choose apps and sites") { selection = ScreenTimeService.shared.selection; showPicker = true }
            } else {
                Button("Allow Screen Time") {
                    Task {
                        model.state.integrations.screenTime = await ScreenTimeService.shared.requestAuthorization()
                        if model.state.integrations.screenTime { showPicker = true }
                    }
                }
                .buttonStyle(SlabButtonStyle())
            }
            #endif
        }
    }

    private var keepAlive: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Keep it installed").font(.display(28, .bold))
            Text("A free Apple account signs apps for 7 days. SideStore re-signs them on your phone over Wi-Fi, so you never need a cable again.")
                .lineSpacing(3)
            VStack(alignment: .leading, spacing: 8) {
                step(1, "On your computer, install SideStore with iloader (it also sets up the pairing file).")
                step(2, "Install LocalDevVPN from the App Store.")
                step(3, "Download Productium-free.ipa on this phone, then open SideStore, tap +, and choose it.")
                step(4, "In Shortcuts, add a daily automation (e.g. 3 am) that runs SideStore's “Refresh All Apps”, set to Run Immediately.")
            }
            if let e = model.signatureExpiry {
                Text("This copy currently works until \(e.formatted(date: .abbreviated, time: .shortened)). Productium will remind you the day before.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Pieces

    private func field(_ prompt: String, text: Binding<String>, secure: Bool) -> some View {
        Group {
            if secure { SecureField(prompt, text: text) } else { TextField(prompt, text: text).keyboardType(.URL) }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .padding(14)
        .background(Theme.fog.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.radius))
    }

    private func reason(_ title: String, _ why: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(why).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(Theme.cobalt).frame(width: 16)
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func test() {
        ClaudeClient.shared.baseURL = URL(string: serverURL.trimmingCharacters(in: .whitespaces))
        ClaudeClient.shared.apiKey = serverKey.trimmingCharacters(in: .whitespaces)
        serverState = .testing
        Task {
            let ok = await ClaudeClient.shared.ping()
            serverState = ok ? .ok : .failed
            model.serverOnline = ok
        }
    }

    private func askAll() async {
        workingPermissions = true
        model.state.integrations.notifications = await NotificationService.requestAuthorization()
        try? await HealthService.shared.requestAuthorization()
        model.state.integrations.health = HealthService.shared.available
        model.state.integrations.calendarImport = await CalendarService.shared.requestAccess()
        model.state.integrations.alarms = await AlarmService.requestAuthorization()
        LocationService.shared.requestAlways()
        if let loc = await LocationService.shared.currentLocation() {
            model.state.places.removeAll { $0.id == "home" }
            model.state.places.append(SavedPlace(id: "home", name: "Home", latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude))
            LocationService.shared.monitor(model.state.places)
            model.state.integrations.location = true
        }
        model.save()
        workingPermissions = false
        permissionsDone = true
    }
}
