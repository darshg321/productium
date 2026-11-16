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

**Free variant (default)**: `Actions → ios → Run workflow` with *free_build* checked. CI runs
`scripts/make-free-spec.py`, which drops the 4 Screen Time extensions, the widget extension and the App Group,
removes the paid-only entitlements, and sets `FREE_TIER`. It builds for device and ad-hoc signs with the HealthKit
entitlement, so a re-signer keeps it. Output: `Productium-free-ipa`.

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
  3. On the phone, open the repo's **free-latest** release page (CI publishes it), download `Productium-free.ipa`,
     then SideStore → **+** → pick the file. Apps SideStore installs are the ones it can refresh, so install
     Productium this way rather than with Impactor.
  4. Shortcuts → Automation → Time of Day (daily, e.g. 3 am) → Run Immediately → SideStore **Refresh All Apps**.
     If the shortcut says it "took too long", check SideStore → Settings → Refresh Attempts. It usually still worked.
  The app reads its own expiry date, warns on Today two days ahead, and sends a notification the day before.
  The pairing file breaks if you update or reset the phone. Re-run iloader if refreshes start failing.
  With a free account SideStore uses one of your 3 app slots.

**Screen time in the free build** is measured from screenshots: drop a Screen Time "Week" screenshot in
the box (a Sunday reminder asks for it) and Claude reads per-day and per-app minutes into the same
weekly taper. **Friction**: a Shortcuts automation (iOS 17+ can "Run Immediately"):
*When Instagram is opened → Productium "Should I pause?" → if true, open `productium://gap`*. Opening the
app brings up a short pause with flashcards, a read or a breathing minute. "I'll go back anyway" gives a
10-minute grace window so it doesn't loop. This is how the one sec app worked before Screen Time APIs,
and it's the friction mechanism behind its 57% drop in openings (Grüning et al., 2023). One automation per
app. Settings in the free build walks you through it. You lose the measured usage and the tapering limit.
The app also counts pauses.

**Paid variant**: unchanged (`device_build`, see `NO_MAC.md` part B).

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

## Sources

- Apple, *Supported capabilities (iOS)*: per-membership capability table (developer.apple.com/help/account/reference/supported-capabilities-ios)
- Apple, *Choosing a membership*: free App IDs: 10, expiring after 7 days
- Apple Developer Forums: "Personal development teams do not support the Family Controls (Development) capability" (threads 803362, 764682)
- Apple Developer Forums: TestFlight requires Family Controls (Distribution), per target (threads 796550, 824726, 844623)
- AltStore FAQ: App IDs needed per app extension. Sideloadly FAQ: 3-app limit on free accounts
- Impactor: github.com/khcrysalis/impactor (Flathub `dev.khcrysalis.PlumeImpactor`). SideStore: github.com/SideStore/SideStore
- one sec Shortcuts setup; iOS 17 "Run Immediately" for personal automations
- Apple fee waiver: nonprofits, accredited educational institutions, government entities only
