# Do you need the $99 Apple Developer Program?

Researched November 2026. Sources are linked at the bottom.

## Short answer

| Goal | Free Apple ID | Paid ($99/yr) |
|---|---|---|
| Run Productium on **your own** iPhone | ✅ everything **except Screen Time blocking/measuring**. Re-sign every 7 days. | ✅ everything |
| Screen Time API (shields, limits, taper) | ❌ Apple doesn't give Family Controls to free teams | ✅ on your own registered devices (development) |
| **TestFlight** (friends / testers) | ❌ TestFlight needs a paid membership | ✅ but Screen Time needs extra Apple approval (below) |
| App Store | ❌ | ✅ + Family Controls approval |

**There's no free route to TestFlight.** TestFlight is part of the paid program. If your membership lapses,
all builds stop.

## The catch with TestFlight even when you pay

TestFlight uses **distribution** signing, the same as the App Store. Paying gets you only the
*development* version of Family Controls. For TestFlight you have to request
**Family Controls (Distribution)** from Apple, and developers report:

- the request has to be made **for every target that uses it**: the app plus the monitor, report,
  shield and shield-action extensions (5 approvals);
- approvals can take **weeks to ~2 months**, sometimes arriving for the app before the extensions.

Until approved, a TestFlight build has to ship without Screen Time features. That's exactly what the
free variant below already does, so the same build works for both.

## What a free Apple ID allows (Apple's capability table)

| Capability Productium uses | Free (Personal Team) |
|---|---|
| App Groups (app ↔ widget data) | ✅ |
| HealthKit (sleep, steps, daylight) | ✅ |
| Background modes (refresh) | ✅ |
| Family Controls (Screen Time) | ❌ |
| Time-Sensitive Notifications | ❌ (notifications still work, they just don't break through Focus) |
| Calendar, Location, local notifications, Live Activities, widgets, App Intents/Siri Shortcuts, AlarmKit | ✅ (no paid capability needed) |

Limits of free signing: apps **expire after 7 days**; at most **3 sideloaded apps** active; **10 App IDs per
7 days**, and each app extension uses one. The full Productium has 6 bundle IDs, the free variant 1.

## What's built in this repo

**Free variant (default)**: every push to `main` (a merge or a direct push) that passes `core-tests` and
`ios-compile` builds it and publishes a release (`v1.0.0` first, then bumped from Conventional Commits). No other
branch, pull request or manual run builds an IPA, and there are no prereleases. CI runs
`scripts/make-free-spec.py`, which drops the 4 Screen Time extensions, the widget extension and the App Group,
removes the paid-only entitlements, and sets `FREE_TIER`. It builds for device and ad-hoc signs with the HealthKit
entitlement, so a re-signer keeps it. Output: the release asset `Productium-free.ipa`, at a stable URL
(`https://github.com/<you>/productium/releases/latest/download/Productium-free.ipa`).

Why no widget: Impactor 2.7 failed with *"An Application Group with Identifier 'group.….<TEAMID>' is not
available"* when registering the App Group on a free account (tested 2026-11-16). Only the widget and Live
Activity needed the App Group, so the free build goes without them. Planning, Health, calendar, notifications,
alarms, Siri and location all still work.

You sign it on Linux with your Apple ID:

- **Impactor** (open-source, MIT, Flatpak `dev.khcrysalis.PlumeImpactor`): sign and install over USB.
  It needs `usbmuxd`. → `./scripts/install-on-iphone.sh --free`
- **SideStore**: refreshes the 7-day signature on the phone over Wi-Fi, so after setup you never plug in:
  1. Install SideStore with **iloader** (github.com/nab138/iloader, Linux AppImage or .deb). It also installs the
     pairing file SideStore needs. iloader asks for your Apple ID.
  2. Install **LocalDevVPN** from the App Store (SideStore talks to the phone through it).
  3. On the phone, open the repo's latest release page (CI publishes one for every merge to `main`), download `Productium-free.ipa`,
     then SideStore → **+** → pick the file. Apps SideStore installs are the ones it can refresh, so install
     Productium this way rather than with Impactor.
  4. Shortcuts → Automation → Time of Day (daily, e.g. 3 am) → Run Immediately → SideStore **Refresh All Apps**.
     If the shortcut says it "took too long", check SideStore → Settings → Refresh Attempts. It usually still worked.
  The app reads its own expiry date, warns on Today two days ahead, and sends a notification the day before.
  The pairing file breaks if you update or reset the phone. Re-run iloader if refreshes start failing.
  With a free account SideStore uses one of your 3 app slots.

**Screen time in the free build** is measured from screenshots: drop a Screen Time "Week" screenshot in
the box (a Sunday reminder asks for it) and Claude reads per-day and per-app minutes into the same
weekly taper. **Friction**: Shortcuts automations (iOS 17+ can "Run Immediately"). On iOS 26+ it's one action:
*When Instagram or TikTok is opened → Productium "Pause Before Scrolling"*. The intent declares
`supportedModes = [.background, .foreground(.dynamic)]` and calls `continueInForeground(alwaysConfirm: false)` only
when a pause is due, so it stays in the background during the grace window. On iOS 17–18 the older form still works:
*"Should I pause?" → If true → Open URLs `productium://gap`*. Opening the app brings up a short pause with
flashcards, a read or a breathing minute. "I'll go back anyway" gives a 10-minute grace window so it doesn't loop,
plus "still scrolling?" check-ins (10/20/30 min depending on Settings → Notifications). This is how the one sec app
worked before Screen Time APIs, and it's the friction mechanism behind its 57% drop in openings (Grüning et al.,
2023). Make one automation per app and type its name in the action's **App** field, so Productium can tell
Instagram from Discord. A second automation, *that app → Is Closed → "Closed a Distracting App"*, ends the
session. iOS's "Is Closed" can miss going Home or locking the phone, so the guide adds automations that end a
session reliably: opening any other app, charger connected, an alarm stopped, or a Sleep/Work/Driving Focus turning
on. A session with no clear end is credited your usual length for that app (marked estimated), never the whole
evening. The minutes go into the same weekly taper as screenshots (a screenshot for a day wins over the count,
and calibrates the count). Settings → Shortcuts & Automations walks through every recipe tap by tap.

**Paid variant**: unchanged (manual `device_build` run, see `NO_MAC.md` part B).

## Recommendation

1. **Now:** use the free variant on your own phone. Everything except Screen Time works, and Shortcuts
   friction covers the scrolling part.
2. **When you want testers:** pay the $99 and **request Family Controls (Distribution) for all 5 targets
   right away**, because that's the slow step. Meanwhile ship TestFlight builds without the Screen Time
   targets (the free spec). Once approved, switch to the full spec.
3. Fee waivers exist only for nonprofits, schools and government entities, not individuals. If a school
   club or the school itself published the app, it could apply.

## To verify on the first real install

Not confirmed in testing yet (I haven't signed a build myself):
- that Impactor/SideStore carry the **HealthKit** entitlement through on a free account. If Health permission
  never appears, that's the reason. Everything else still runs.
- AlarmKit's authorization prompt with free signing (it isn't a listed paid capability).
- that `continueInForeground(alwaysConfirm: false)` brings the app forward from an "App is opened" automation
  without a confirmation prompt. Apple's docs say the system may still ask; if it does every time, use the
  iOS 17–18 recipe (If + Open URLs), which is known to work.
- that the Shortcuts App trigger's multi-select works; Productium's guide says one automation per app because its
  action needs to know which app a session belongs to.

## Sources

- Apple, *Supported capabilities (iOS)*: per-membership capability table (developer.apple.com/help/account/reference/supported-capabilities-ios)
- Apple, *Choosing a membership*: free App IDs: 10, expiring after 7 days
- Apple Developer Forums: "Personal development teams do not support the Family Controls (Development) capability" (threads 803362, 764682)
- Apple Developer Forums: TestFlight requires Family Controls (Distribution), per target (threads 796550, 824726, 844623)
- AltStore FAQ: App IDs needed per app extension. Sideloadly FAQ: 3-app limit on free accounts
- Impactor: github.com/khcrysalis/impactor (Flathub `dev.khcrysalis.PlumeImpactor`). SideStore: github.com/SideStore/SideStore
- one sec Shortcuts setup; iOS 17 "Run Immediately" for personal automations
- Apple, App Intents: `supportedModes`, `IntentModes.ForegroundMode.dynamic`, `continueInForeground(_:alwaysConfirm:)` (iOS 26)
- Apple, AlarmKit: `AlarmPresentation.Alert(title:secondaryButton:secondaryButtonBehavior:)` (iOS 26.1), `AlarmConfiguration.alarm(schedule:attributes:stopIntent:secondaryIntent:sound:)` with a `LiveActivityIntent`
- Apple fee waiver: nonprofits, accredited educational institutions, government entities only
