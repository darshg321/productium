import SwiftUI
import AppIntents
import ProductiumCore

struct ShortcutsGuideView: View {
    @Environment(\.dismiss) private var dismiss
    var inSheet = false

    var body: some View {
        if inSheet {
            NavigationStack {
                list.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Shortcuts can run a Productium action the moment something happens on your phone: an app opens, you get home, you tap your phone on a sticker on your desk.")
                    Text("Every recipe here is an automation in the Shortcuts app set to **Run Immediately**, so it never asks first.")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .padding(.vertical, 4)
                Button { openShortcuts() } label: { Label("Open Shortcuts", systemImage: "arrow.up.forward.app") }
            }

            Section {
                ForEach(Recipe.scrolling) { r in NavigationLink { RecipeView(recipe: r) } label: { RecipeRow(recipe: r) } }
            } header: { Text("Less Scrolling") } footer: {
                Text("These pause the apps you scroll and count your minutes. Set up the first two together.")
            }

            Section("Starting Work") {
                ForEach(Recipe.starting) { r in NavigationLink { RecipeView(recipe: r) } label: { RecipeRow(recipe: r) } }
            }

            Section {
                ForEach(Recipe.routine) { r in NavigationLink { RecipeView(recipe: r) } label: { RecipeRow(recipe: r) } }
            } header: { Text("Checking In Without Tapping") } footer: {
                Text("Each check-in teaches Productium how long your mornings and commute really take.")
            }

            Section {
                ForEach(Recipe.quick) { r in NavigationLink { RecipeView(recipe: r) } label: { RecipeRow(recipe: r) } }
                ShortcutsLink()
                    .shortcutsLinkStyle(.automaticOutline)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } header: { Text("Quick Input") } footer: {
                Text("Siri already knows these, no setup: “Tell Productium bio quiz Thursday”, “Productium left home”, “Start focus in Productium”, “What's the plan in Productium”.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private func openShortcuts() {
    if let u = URL(string: "shortcuts://") { UIApplication.shared.open(u) }
}

struct RecipeRow: View {
    let recipe: Recipe
    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: recipe.symbol, color: recipe.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.title)
                Text(recipe.trigger).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct RecipeView: View {
    let recipe: Recipe
    @State private var copied: String?

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    IconTile(symbol: recipe.symbol, color: recipe.color, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recipe.title).font(.title3.weight(.bold))
                        Text(recipe.trigger).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                Text(recipe.why).font(.subheadline)
            }
            ForEach(recipe.parts, id: \.title) { part in
                Section {
                    ForEach(Array(part.steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(i + 1)").font(.subheadline.weight(.bold).monospacedDigit())
                                .foregroundStyle(Color.accentColor).frame(width: 18)
                            Text(LocalizedStringKey(step)).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } header: {
                    Text(part.title)
                } footer: {
                    if let n = part.note { Text(n) }
                }
            }
            if !recipe.copy.isEmpty {
                Section("Copy") {
                    ForEach(recipe.copy, id: \.self) { text in
                        Button {
                            UIPasteboard.general.string = text
                            copied = text
                        } label: {
                            LabeledContent {
                                Image(systemName: copied == text ? "checkmark" : "doc.on.doc")
                            } label: {
                                Text(text).font(.subheadline.monospaced()).foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            Section {
                Button { openShortcuts() } label: { Label("Open Shortcuts", systemImage: "arrow.up.forward.app") }
            } footer: {
                if let t = recipe.tip { Text(t) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(recipe.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct Recipe: Identifiable {
    struct Part { var title: String; var steps: [String]; var note: String? = nil }
    var id: String
    var title: String
    var trigger: String
    var symbol: String
    var color: Color
    var why: String
    var parts: [Part]
    var copy: [String] = []
    var tip: String? = nil

    static func start(_ trigger: String) -> [String] {
        ["In Shortcuts, open the **Automation** tab and tap **+** (top right). If you have no automations yet, tap **New Automation**.",
         trigger]
    }
    static let runNow = "Choose **Run Immediately**, turn **Notify When Run** off, and tap **Next**."
    static let blank = "Tap **Create New Shortcut** (some versions call it **New Blank Automation**), then **Add Action**."

    static let scrolling: [Recipe] = [
        Recipe(id: "every", title: "Screen Time for Every App", trigger: "One automation: when any app opens",
               symbol: "apps.iphone", color: .teal,
               why: "Each time you open an app, Shortcuts tells Productium which one. Productium then counts your time in every app and fills in your day: apps you scroll on as Scrolling, messaging apps as Messaging. Anything you track yourself always wins.",
               parts: [
                Part(title: "Make the automation", steps: [
                    "Open the **Shortcuts** app and tap **Automation** at the bottom.",
                    "Tap **+** in the top right (or **New Automation** if it's empty).",
                    "Scroll down to **App** and tap it.",
                    "Tap **Choose**. Tick every app on your phone, one by one. Tap **Done**.",
                    "Make sure **Is Opened** has a tick and **Is Closed** doesn't.",
                    "Tap **Run Immediately**, then turn **Notify When Run** off. Tap **Next**.",
                    "Tap **Create New Shortcut**.",
                ]),
                Part(title: "Add the Productium action", steps: [
                    "In the search bar at the bottom, type **Opened an App** and tap it.",
                    "The action reads **Opened an App App**. Tap the blue word **App**.",
                    "Above the keyboard, tap **Shortcut Input**. The action now reads **Opened an App Shortcut Input**.",
                    "Tap **Done** in the top right.",
                ], note: "No Shortcut Input above the keyboard? Make one automation per app instead, and type the app's name where it says App."),
                Part(title: "Check it works", steps: [
                    "Open any other app for a few seconds, then come back to Productium.",
                    "Go to **Settings → Screen Time**. Under **Working?** it shows the app you just opened.",
                ]),
               ],
               tip: "New apps you install need ticking in the automation too."),
        Recipe(id: "pause", title: "Pause Before Scrolling", trigger: "When Instagram, TikTok… is opened",
               symbol: "hand.raised.fill", color: .purple,
               why: "Opening one of those apps brings up a short pause in Productium with something better to do. Tap “Go back anyway” and there's no pause for 10 minutes. In a study, a pause like this cut how often people opened those apps by more than half.",
               parts: [
                Part(title: "iOS 26 and later: one action", steps: start("Scroll down and tap **App**.") + [
                    "Tap **Choose**, tick every app you lose time in (you can pick several), then tap **Done**.",
                    "Leave **Is Opened** ticked and untick **Is Closed**.",
                    runNow, blank,
                    "Search for **Pause Before Scrolling** (under Productium) and tap it. Tap **Done**.",
                ], note: "The action brings Productium forward only when a pause is due, and stays out of the way during the 10 minutes after “Go back anyway”. If iOS asks whether Productium may open, allow it once."),
                Part(title: "iOS 17 and 18: three actions", steps: [
                    "Make the same automation (steps 1–6 above).",
                    "Add **Should I pause?** (Productium).",
                    "Add **If**. Set it to **If Result is true**.",
                    "Inside the If, add **Open URLs** and type \(AppInfo.scheme)://gap as the URL.",
                    "Delete the empty **Otherwise** part if you like, then tap **Done**.",
                ]),
               ],
               copy: ["\(AppInfo.scheme)://gap"],
               tip: "Make one automation per app and type that app's name in the **App** field of the action. That's how Productium tells Instagram from Discord, and how it ends one session when you switch to the other. Then do “Count Scrolling Time” the same way."),
        Recipe(id: "count", title: "Count Scrolling Time", trigger: "When those apps are closed",
               symbol: "timer", color: .indigo,
               why: "Tells Productium when you leave one of those apps, so it can count your minutes each day. Be aware: iOS's “Is Closed” trigger is unreliable. It fires when you switch apps from the app switcher, but it can miss going Home or locking the phone. That's why the next two recipes exist, and why a session with no clear end is counted as your usual length (marked estimated), never as the whole evening.",
               parts: [
                Part(title: "Steps", steps: start("Tap **App**.") + [
                    "Tap **Choose** and tick one scrolling app. Tap **Done**.",
                    "Untick **Is Opened** and tick **Is Closed**.",
                    runNow, blank,
                    "Search for **Closed a Distracting App** (Productium), tap it, type the app's name in **App**, then **Done**.",
                ], note: "Without this, check-ins arrive on a timer even if you already closed the app."),
               ]),
        Recipe(id: "other", title: "End Scrolling When You Open Another App", trigger: "When Messages, Safari, Camera… is opened",
               symbol: "arrow.left.arrow.right", color: .teal,
               why: "Opening any other app proves you stopped scrolling. Productium ends the session at that moment, so “Is Closed” missing a Home or lock doesn't cost you a long, made-up session. This one matters most.",
               parts: [
                Part(title: "Steps", steps: start("Tap **App**.") + [
                    "Tap **Choose** and tick the apps you use that aren't scrolling: Messages, Safari, Camera, Slack, Notes. Tap **Done**.",
                    "Leave **Is Opened** ticked and untick **Is Closed**.",
                    runNow, blank,
                    "Search for **Closed a Distracting App** (Productium) and tap it. Leave **App** empty, which means any. Tap **Done**.",
                ]),
               ]),
        Recipe(id: "stop", title: "Stop Counting at Night", trigger: "Charger connected, alarm stopped, a Focus turns on",
               symbol: "powerplug.fill", color: .mint,
               why: "Plugging in, stopping your alarm, or turning on a Sleep, Work or Driving Focus almost always means you're done scrolling. Productium ends any open session then, and cancels the “still scrolling?” check-ins that would otherwise keep firing on a locked phone.",
               parts: [
                Part(title: "Make one for each", steps: start("Choose **Charger** → **Is Connected**, or **Alarm** → **Is Stopped**, or **Sleep**, **Work** or **Driving** (Focus) → **Turns On**.") + [
                    runNow, blank,
                    "Search for **Probably Stopped Scrolling** (Productium), tap it, and pick what happened: **Charger connected**, **Alarm stopped** or **A Focus turned on**. Tap **Done**.",
                ], note: "Opening Productium, or running any of its actions, also ends a session."),
               ],
               tip: "When you answer “No, I stopped” to a check-in, the session ends at the later of your last “yes” and your usual session length. No answer ends it the same way."),
        Recipe(id: "gray", title: "Grayscale at Night", trigger: "Add to your pause automation",
               symbol: "circle.lefthalf.filled", color: .gray,
               why: "A gray screen is less rewarding to scroll. This turns it on only when the plan says wind-down or sleep, so it never gets in the way during the day.",
               parts: [
                Part(title: "Once", steps: [
                    "In **Settings**, go to **Accessibility** → **Display & Text Size** → **Color Filters**, choose **Grayscale**, then turn Color Filters back off. Shortcuts uses whichever filter is picked here.",
                ]),
                Part(title: "In the pause automation", steps: [
                    "Open your **Pause Before Scrolling** automation and tap the shortcut to edit it.",
                    "At the top, add **Is It Screens-Off Time?** (Productium).",
                    "Add **If**, set to **If Result is true**.",
                    "Inside the If, add **Set Color Filters** and leave it on **Turn On**.",
                    "In **Otherwise**, add **Set Color Filters** and tap **Turn** to switch it to **Turn Off**.",
                    "Tap **Done**.",
                ]),
               ]),
        Recipe(id: "grayapps", title: "Grayscale While You Scroll", trigger: "When those apps are opened and closed",
               symbol: "circle.lefthalf.filled.inverse", color: .gray,
               why: "In trials, turning the screen gray cut daily screen time (a 2023 randomised field experiment, about 110 people, found a drop right away that outlasted time limits). It's the reverse of the pause: the apps stay, they just feel less rewarding. This turns gray on while one of those apps is open and back off when you leave.",
               parts: [
                Part(title: "Once", steps: [
                    "In **Settings**, go to **Accessibility** → **Display & Text Size** → **Color Filters**, choose **Grayscale**, then turn Color Filters back off.",
                ]),
                Part(title: "When the apps open", steps: start("Tap **App**.") + [
                    "Tap **Choose**, tick the apps you lose time in, then **Done**. Leave **Is Opened** ticked and untick **Is Closed**.",
                    runNow, blank,
                    "Add **Set Color Filters** and leave it on **Turn On**. Tap **Done**.",
                ]),
                Part(title: "When the apps close", steps: start("Tap **App**.") + [
                    "Choose the same apps. Untick **Is Opened** and tick **Is Closed**.",
                    runNow, blank,
                    "Add **Set Color Filters** and tap **Turn** to switch it to **Turn Off**. Tap **Done**.",
                ], note: "“Is Closed” can miss going Home, so the screen may stay gray until you open and leave an app again. Triple-click the side button can turn Color Filters off at any time if you add it under Accessibility Shortcut."),
               ]),
    ]

    static let starting: [Recipe] = [
        Recipe(id: "nfc", title: "Tap Your Desk to Start", trigger: "When an NFC tag is scanned",
               symbol: "wave.3.right", color: .blue,
               why: "Stick a cheap NFC sticker where you work. Touching the top of your phone to it starts the block that's on now, or the next one. Starting is the hard part; this makes it one movement.",
               parts: [
                Part(title: "Steps", steps: start("Tap **NFC**, then **Scan**, and hold the top of your iPhone to the sticker. Name it (e.g. Desk).") + [
                    runNow, blank,
                    "Search for **Start focus** (Productium), tap it, then **Done**.",
                ], note: "Any blank NTAG215 or NTAG213 sticker works."),
               ]),
        Recipe(id: "focus", title: "Start with a Focus", trigger: "When a Focus turns on",
               symbol: "moon.circle.fill", color: .indigo,
               why: "If you already turn on a Study or Work Focus, let it start Productium's focus session at the same time.",
               parts: [
                Part(title: "Steps", steps: start("Tap **Focus**, choose your Study or Work Focus, and pick **When Turning On**.") + [
                    runNow, blank,
                    "Add **Start focus** (Productium), then **Done**.",
                ]),
               ]),
        Recipe(id: "notify", title: "Let Reminders Through Focus", trigger: "Settings, once",
               symbol: "bell.badge.fill", color: .red,
               why: "Block starts, leave-by warnings and bedtime can be silenced by a Focus, so allow Productium in the Focuses you use.",
               parts: [
                Part(title: "For each Focus you use", steps: [
                    "Open **Settings** → **Focus** and tap the Focus (e.g. Sleep, Personal).",
                    "Under **Allow Notifications**, tap **Apps** → **Add**, pick **Productium**, then **Done**.",
                    "Sleep Focus: allow it there too, or bedtime reminders wait until morning.",
                ]),
               ]),
    ]

    static let routine: [Recipe] = [
        Recipe(id: "wifi", title: "Home and Leaving by Wi-Fi", trigger: "When your home Wi-Fi joins or drops",
               symbol: "wifi", color: .blue,
               why: "Checks you in as home or left home without Location. Useful if Places is off.",
               parts: [
                Part(title: "Getting home", steps: start("Tap **Wi-Fi**, then **Choose** and pick your home network. Choose **Joins** (When Joining).") + [
                    runNow, blank,
                    "Add **Check in** (Productium). Tap **Where / what** and choose **Home**. Tap **Done**.",
                ]),
                Part(title: "Leaving", steps: [
                    "Make another Wi-Fi automation for the same network, choosing **Leaves** (When Leaving).",
                    "Add **Check in** with **Left home**.",
                ], note: "If your Wi-Fi drops now and then at home, skip the leaving one: it would log a trip that didn't happen."),
               ]),
        Recipe(id: "wake", title: "Log When You Wake Up", trigger: "When your alarm stops",
               symbol: "alarm.fill", color: .orange,
               why: "Your real wake-up time makes tomorrow's alarm and morning plan more accurate.",
               parts: [
                Part(title: "Steps", steps: start("Tap **Alarm**, choose **Is Stopped**, and pick **Wake-Up** (or Any).") + [
                    runNow, blank,
                    "Add **Check in** with **Woke up**. Tap **Done**.",
                ], note: "Uses the Clock app's alarms. If you use Productium's wake-up alarm instead, use **Sleep** → **Waking Up** as the trigger."),
               ]),
        Recipe(id: "bed", title: "Log Going to Bed", trigger: "When you plug in at night",
               symbol: "bed.double.fill", color: .indigo,
               why: "Plugging in at night is a good sign you're done for the day.",
               parts: [
                Part(title: "Steps", steps: start("Tap **Charger** and choose **Is Connected**.") + [
                    runNow, blank,
                    "Add **Is It Screens-Off Time?** (Productium), then **If** → **If Result is true**.",
                    "Inside the If, add **Check in** with **Going to bed**. Tap **Done**.",
                ], note: "The If stops it logging bedtime when you charge in the afternoon."),
               ]),
    ]

    static let quick: [Recipe] = [
        Recipe(id: "action", title: "Action Button or Back Tap", trigger: "Press or tap to tell Productium",
               symbol: "hand.tap.fill", color: .orange,
               why: "Say anything (“bio quiz Thursday”, “skipped practice”) without opening the app.",
               parts: [
                Part(title: "Action button (iPhone 15 Pro and later)", steps: [
                    "**Settings** → **Action Button**, swipe to **Shortcut**, tap **Choose a Shortcut**.",
                    "Pick **Tell Productium**.",
                ], note: "If it isn't in the list, make a shortcut first: in Shortcuts tap **+**, add **Tell Productium**, and save it. Then pick that shortcut."),
                Part(title: "Back Tap (any iPhone 8 or later)", steps: [
                    "**Settings** → **Accessibility** → **Touch** → **Back Tap** → **Double Tap**.",
                    "Scroll to Shortcuts and pick **Tell Productium**.",
                ], note: "Back Tap lists the shortcuts in your library, so you may need to make the one-action shortcut above first."),
               ]),
    ]
}
