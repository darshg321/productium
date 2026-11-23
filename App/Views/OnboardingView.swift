import SwiftUI
import ProductiumCore
import UniformTypeIdentifiers

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    /// An update with new setup steps: only what's new, then back to the app.
    var updating = false
    @State private var page: Page = .welcome
    @State private var serverURL = ClaudeClient.shared.baseURL?.absoluteString ?? ClaudeClient.defaultURL.absoluteString
    @State private var serverKey = ClaudeClient.shared.apiKey ?? ""
    @State private var serverState: ServerState = .untested
    @State private var permissionsDone = false
    @State private var workingPermissions = false
    @State private var showGuide = false
    /// A1: templates you unticked (title keys).
    @State private var unticked: Set<String> = []
    /// The apps you scroll on (ticked on the Less Scrolling page).
    @State private var scrollApps: Set<String> = []
    @State private var otherApp = ""
    /// H2: a backup found in the folder remembered from before a reinstall.
    @State private var offer: RestorePreview?
    @State private var importing = false
    @State private var restoreError: String?

    enum ServerState { case untested, testing, ok, badKey, failed }

    enum Page: Int, CaseIterable {
        case welcome, claude, week, activities, sleep, permissions, scrolling, backup, keepAlive
    }

    private var pages: [Page] {
        updating ? [.welcome, .scrolling, .backup] : Page.allCases
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(pages, id: \.self) { p in
                    Capsule().fill(p.rawValue <= page.rawValue ? Color.accentColor : Color(.tertiarySystemFill)).frame(height: 4)
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
                if page != .welcome {
                    Button("Back") { move(-1) }.buttonStyle(.bordered).controlSize(.large)
                }
                Spacer()
                Button { advance() } label: {
                    Text(page == pages.last ? "Get Started" : "Continue").frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canContinue)
            }
            .padding(20)
        }
        .background(Theme.background)
        .sheet(isPresented: $showGuide) { ShortcutsGuideView(inSheet: true) }
        .onAppear {
            if offer == nil && !updating { offer = model.backupToOffer() }
            scrollApps = Set(model.state.scrollingApps.filter { $0.value && ScrollingApps.common.contains($0.key) }.map(\.key))
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { r in
            guard case .success(let url) = r else { return }
            do { model.applyRestore(try model.readBackup(from: url)) } catch {
                restoreError = (error as? ExportBundle.ReadError)?.description ?? error.localizedDescription
            }
        }
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
        if page == pages.last, updating {
            model.setScrollingApps(scrollApps)
            model.finishSetup()
        } else if page == pages.last {
            model.seedGrid(skipping: unticked)
            model.setScrollingApps(scrollApps)
            model.state.onboarded = true
            model.finishSetup()
            model.save()
            Task { await model.refresh(force: true) }
        } else {
            move(1)
        }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .welcome: welcome
        case .claude: claude
        case .week: week
        case .activities: activities
        case .sleep: sleep
        case .permissions: permissions
        case .scrolling: scrolling
        case .backup: backup
        case .keepAlive: keepAlive
        }
    }

    @ViewBuilder private var welcome: some View {
        if updating { whatsNew } else { firstWelcome }
    }

    private var whatsNew: some View {
        VStack(alignment: .leading, spacing: 20) {
            IconTile(symbol: "sparkles", color: .purple, size: 72)
            Text("New in Productium").font(.largeTitle.weight(.bold))
            VStack(alignment: .leading, spacing: 14) {
                reason("Screen Time for every app", "One Shortcuts automation, and your day fills itself in with the apps you use.", "apps.iphone", .teal)
                reason("Your scrolling apps", "Pick the apps you scroll on. Each gets its own place under Scrolling.", "hourglass", .pink)
                reason("Backups by themselves", "A backup is saved every day, with nothing to set up.", "externaldrive.fill", .blue)
            }
        }
    }

    private var firstWelcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            IconTile(symbol: "calendar.badge.clock", color: .blue, size: 72)
            Text("Tell it everything.\nIt plans the rest.").font(.largeTitle.weight(.bold))
            Text("You type what's due, what happened, and what changed, in any order and as messily as you like. Productium works out when to do things, protects your sleep and free time, and learns your routine so you don't have to log it.")
                .font(.body).lineSpacing(3)
            Text("Setup takes about two minutes.").foregroundStyle(.secondary)
            if let o = offer {
                Button { model.applyRestore(o) } label: { Label(o.summary, systemImage: "clock.arrow.circlepath") }
                    .buttonStyle(.borderedProminent)
            }
            Button("Restore from a Backup File") { importing = true }.buttonStyle(.bordered)
            if let e = restoreError { Text(e).font(.footnote).foregroundStyle(Theme.alert) }
        }
    }

    /// A1: the activity grid starts full; untick what doesn't apply.
    private var activities: some View {
        VStack(alignment: .leading, spacing: 16) {
            IconTile(symbol: "square.grid.3x3.fill", color: .orange, size: 56)
            Text("What do you do?").font(.largeTitle.weight(.bold))
            Text("Untick what doesn't apply.").lineSpacing(3)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(QuickStartTemplate.all, id: \.title) { t in
                    let key = CategoryRules.key(t.title)
                    let on = !unticked.contains(key)
                    Button {
                        if on { unticked.insert(key) } else { unticked.remove(key) }
                    } label: {
                        TileLabel(title: t.title, symbol: t.symbol,
                                  color: on ? Theme.color(category: t.category, tree: model.state.categories) : Color(.systemGray4), on: false)
                            .opacity(on ? 1 : 0.6)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? Color.accentColor : .secondary)
                                    .background(Circle().fill(Theme.background)).offset(x: -6, y: -4)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    /// H1: a daily backup outside the app.
    private var backup: some View {
        VStack(alignment: .leading, spacing: 16) {
            IconTile(symbol: "externaldrive.fill", color: .blue, size: 56)
            Text("Daily Backups").font(.largeTitle.weight(.bold))
            Text("Productium saves a backup every day by itself. To keep them even if the app is deleted, pick a folder in iCloud Drive.").lineSpacing(3)
            List { DailyBackupSection() }
                .listStyle(.insetGrouped)
                .scrollDisabled(true)
                .frame(height: 230)
        }
    }

    private var claude: some View {
        VStack(alignment: .leading, spacing: 18) {
            IconTile(symbol: "sparkles", color: .teal, size: 56)
            Text("Connect Claude").font(.largeTitle.weight(.bold))
            Text("Productium runs on your claude-server over Tailscale. The address is filled in; add the API key you made for Productium (it starts with cs_). Tailscale needs to be on for this phone.")
                .lineSpacing(3)
            field("https://your-pi.your-tailnet.ts.net", text: $serverURL, secure: false)
            field("API key (starts with cs_)", text: $serverKey, secure: true)
            HStack(spacing: 16) {
                Button(serverState == .testing ? "Checking…" : "Check Connection") { test() }
                    .buttonStyle(.bordered)
                    .disabled(serverState == .testing)
                switch serverState {
                case .ok: Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .badKey: Text("The server is there, but it didn't accept that key.").foregroundStyle(Theme.alert).font(.subheadline)
                case .failed: Text("No answer. Is Tailscale on, and is the address right?").foregroundStyle(Theme.alert).font(.subheadline)
                default: EmptyView()
                }
            }
        }
    }

    private var week: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your Week").font(.largeTitle.weight(.bold))
            Text("Write your school hours, your activities and anything coming up. A screenshot of your timetable works too. For example: “school mon–fri 8:30 to 3, soccer mon and wed 4–5:30, chem test thursday, college essay due dec 1”.")
                .lineSpacing(3)
            DumpBox()
            let known = model.legacyCommitments
            if !known.isEmpty || !model.state.items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("So far").font(.subheadline.weight(.semibold))
                    ForEach(known) { c in
                        Text("\(c.title), \(c.weekdays.sorted().map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: " ")), \(c.start.label) to \(c.end.label)")
                            .font(.subheadline)
                    }
                    ForEach(model.state.items.filter { $0.isOpen && $0.parentId == nil }) { i in
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
        let wake = WakePlanner.plan(for: monday, events: model.legacyCommitments.compactMap { c in
                                        Calendar.current.date(bySettingHour: c.start.hour, minute: c.start.minute, second: 0, of: monday)
                                            .map { FixedEvent(id: c.id.uuidString, title: c.title, start: $0, end: $0.addingTimeInterval(3600), kind: c.kind) }
                                    }, routines: model.routines,
                                    prefs: model.state.prefs, calendar: .current)
        return VStack(alignment: .leading, spacing: 18) {
            IconTile(symbol: "bed.double.fill", color: Theme.sleep, size: 56)
            Text("Sleep").font(.largeTitle.weight(.bold))
            Text("Teens need 8 to 10 hours. Your bedtime gets worked back from when you have to be up, which comes from your first class and how long it takes you to get there.")
                .lineSpacing(3)
            Stepper(value: $m.state.prefs.sleepNeedMinutes, in: 480...600, step: 15) {
                Text("About \(durationLabel(model.state.prefs.sleepNeedMinutes)) a night").font(.headline)
            }
            Text("On a school day that means up at \(wake.wake.hm) and in bed by \(wake.wake.addingTimeInterval(-Double(model.state.prefs.sleepNeedMinutes) * 60).hm).")
                .foregroundStyle(.secondary)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Let It See Your Day").font(.largeTitle.weight(.bold))
            Text("Each of these saves you from typing something. iOS will ask about each one in turn.")
                .lineSpacing(3)
            VStack(alignment: .leading, spacing: 12) {
                reason("Notifications", "Reply to “how did it go?” from the lock screen.", "bell.badge.fill", .red)
                reason("Health", "Sleep, wake-up time and steps, so a short night means a lighter day.", "heart.fill", .pink)
                reason("Calendar", "So it never plans over things already in there.", "calendar", .red)
                reason("Location", "Notices when you leave home and get to school, and learns how long it takes. Choose “Always”.", "location.fill", .blue)
                reason("Alarms", "Sets your wake-up alarm for you.", "alarm.fill", .orange)
            }
            if permissionsDone {
                Label("All set.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button { Task { await askAll() } } label: {
                    Text(workingPermissions ? "Asking…" : "Turn These On").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(workingPermissions)
            }
        }
    }

    @ViewBuilder private var scrolling: some View {
        VStack(alignment: .leading, spacing: 18) {
            IconTile(symbol: "hourglass", color: .pink, size: 56)
            Text("Less Scrolling").font(.largeTitle.weight(.bold))
            Text("Which apps do you scroll on?").font(.headline)
            Text("Their time counts as Scrolling, each app on its own. Messaging apps like Discord count as Messaging. Change it any time in Settings → Screen Time.")
                .font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                ForEach(ScrollingApps.common + scrollApps.filter { !ScrollingApps.common.contains($0) }.sorted(), id: \.self) { app in
                    let on = scrollApps.contains(app)
                    Button {
                        if on { scrollApps.remove(app) } else { scrollApps.insert(app) }
                    } label: {
                        Label(app, systemImage: on ? "checkmark.circle.fill" : "circle")
                            .font(.subheadline.weight(.medium)).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 10)
                            .background(on ? Color.pink.opacity(0.15) : Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .foregroundStyle(on ? Color.pink : .primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            HStack {
                TextField("Another app", text: $otherApp).textFieldStyle(.roundedBorder).onSubmit(addOther)
                Button("Add", action: addOther).buttonStyle(.bordered).disabled(otherApp.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Let Productium see your apps").font(.headline).padding(.top, 8)
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Shortcuts → Automation → + → App.")
                step(2, "Choose: tick every app. Is Opened on, Is Closed off.")
                step(3, "Run Immediately → Next → Create New Shortcut.")
                step(4, "Search for Opened an App and tap it.")
                step(5, "Tap the blue word App, then Shortcut Input above the keyboard. Done.")
            }
            HStack {
                Button("Open Shortcuts") { if let u = URL(string: "shortcuts://") { UIApplication.shared.open(u) } }
                    .buttonStyle(.bordered)
                Button("Full Guide") { showGuide = true }
                    .buttonStyle(.bordered)
            }
            Text("Productium then counts screen time for every app and fills your day with it as assumed time: one tap confirms it, and whatever you track yourself always wins.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func addOther() {
        let t = otherApp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        scrollApps.insert(t)
        otherApp = ""
    }

    private var keepAlive: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Keep It Installed").font(.largeTitle.weight(.bold))
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

    private func field(_ prompt: String, text: Binding<String>, secure: Bool) -> some View {
        Group {
            if secure { SecureField(prompt, text: text) } else { TextField(prompt, text: text).keyboardType(.URL) }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func reason(_ title: String, _ why: String, _ symbol: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(why).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(Color.accentColor).frame(width: 16)
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func test() {
        ClaudeClient.shared.baseURL = URL(string: serverURL.trimmingCharacters(in: .whitespaces))
        ClaudeClient.shared.apiKey = serverKey.trimmingCharacters(in: .whitespaces)
        serverState = .testing
        Task {
            switch await ClaudeClient.shared.verify() {
            case .ok: serverState = .ok
            case .badKey: serverState = .badKey
            case .unreachable: serverState = .failed
            }
            model.serverOnline = serverState != .failed
        }
    }

    private func askAll() async {
        workingPermissions = true
        model.state.integrations.notifications = await NotificationService.requestAuthorization()
        var healthAnswered = false
        do { try await HealthService.shared.requestAuthorization(); healthAnswered = true } catch {}
        model.state.integrations.health = HealthService.shared.available && healthAnswered
        model.state.integrations.healthNeedsRequest = await HealthService.shared.requestNeeded()
        model.state.integrations.calendarImport = await CalendarService.shared.requestAccess()
        model.state.integrations.alarms = await AlarmService.requestAuthorization()
        LocationService.shared.requestAlways()
        var waited = 0
        while LocationService.shared.status == .notDetermined, waited < 120 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            waited += 1
        }
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
