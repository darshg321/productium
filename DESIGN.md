# Productium: architecture (read this first)

Productium is a calm iOS life planner for a high-school student. They tell it what is due (one Inbox box,
text or screenshots); a deterministic planner places study around school, sleep and free time; it learns the
student's routines and capacity; and it quiets scrolling. Claude interprets language and proposes behaviour
changes; **all scheduling is deterministic code on the phone**.

## 0. Working on this repo (rules for people and AI agents)

- **Branches:** make every change on `dev` first and commit as you go (small commits, pushed to `dev` so CI compiles
  it and builds the `dev-build` pre-release; no version change). Merge `dev` into `main` (which releases
  `v<VERSION>.n`) only once the `dev` build is green and the change has been checked with `scripts/test`.
- **User data must migrate.** v1.2.2 (`AppState.schema = 4`) is the first version with real data. Any change to
  stored data after it (AppState fields, Codable types, backups) bumps `schema`, adds a migration step from the
  previous schema, and a test that decodes a saved 1.2.2 `state.json` fixture without losing anything. Never fall back
  to a fresh state for an older schema. Restores from backup files go through the same migrations.
- **Docs:** only `README.md` (for people installing the app) and this file are in the repo. Plans (`*plan.md`) stay
  local and untracked.
- Core tests: `export PATH=$HOME/.local/swift/swift-6.2.1-RELEASE-ubuntu24.04/usr/bin:$PATH; cd Packages/ProductiumCore
  && swift build --build-tests && swift test --skip-build [--filter X]`. The App only compiles on CI (no Mac).
- Box evals without network: `cd scripts/inbox-eval && swift run -q H --v12-reference`.
- Leaderboard Worker: `scripts/leaderboard` (`node test.mjs`, `./deploy.sh`).
- Dev app on the phone: Productium Dev (`com.darshg321.productium.dev.573BBB2JRN` once signed). Install / update over
  USB: download the `dev-build` IPA, sign with `flatpak run --filesystem=<dir> --command=plumesign
  dev.khcrysalis.PlumeImpactor sign --package <ipa> --apple-id --output <signed.ipa>` (the saved account and key are
  reused; don't use `--register-and-install`, it fails to find the phone), then `uvx pymobiledevice3 apps install
  <signed.ipa>`. Connect it to claude-server with `scripts/test/connect-server.sh` (app open, Tailscale on).

### 0.1 Seeing the app: the test runner

Write a command script and run `scripts/test/sim.sh script.txt` (CI simulator, ~10 min) or
`scripts/test/device.sh script.txt` (the phone over USB, Productium Dev open), then read `shots/*.png`,
`dumps/*.txt` and `results.txt` under `test-runs/<time>/`. Add a scenario in `Scenarios.swift` (with a
`ScenarioTests` case) when a state can't be reached with commands.

Dev builds (`dev` branch → `dev-build` pre-release, "Productium Dev", bundle id `….productium.dev`, scheme
`productium-dev://`) install next to the real app with their own data. They read test scripts from
`Documents/test/commands.txt` (`App/Model/TestHooks.swift`), one command per line:

| Command | Does |
|---|---|
| `scenario <name>` | replace all data with a seeded state: `fresh`, `today`, `history`, `evening`, `alerts`, `leaderboard` (`Scenarios.swift`) |
| `reset` | empty state (onboarding) |
| `tab <today\|schedule\|tasks\|review\|settings>` | switch tab (closes sheets) |
| `scroll <card>` | Review: `recap today stats week time screen goals work mood metrics pinned leaderboard note`; Today: `grid gaps assumed ring upnext` |
| `review [recap]` | the Review tab; `recap` opens Your Week |
| `now <action>` | a Now Live Activity button: `stop`, `start:<title>`, `answer:<id>:<answer>`, `yes:<ref>`, `no:<ref>`, `task:<id>` |
| `backup` | write the daily backup now (needs a folder picked) |
| `open <url>` | any link, e.g. `productium-dev://gap` (pause sheet), an invite link |
| `say <text>` | the box (local phrases work offline; anything else needs the Claude server) |
| `start <title>` · `start-next` (what the pause sheet / Control Center do) · `stop` · `mood <1-5>` · `confirm-today` | the log |
| `approve` · `decline` · `answer <yes\|no\|skipped\|sick\|no-school>` · `dismiss` | cards and sheets |
| `refresh` · `replan` · `learn` · `leaderboard` | background work, on demand |
| `server [url]` | Claude server key from `Documents/test/server-key.txt` (`connect-server.sh`) into the Keychain |
| `wait <s>` · `shot <name>` · `dump <name>` | timing, a screenshot (`shots/`), the state as text + JSON (`dumps/`) |

Results go to `results.txt` (`ok` / `ERR` per line, then `DONE`). Taps and typing aren't simulated: every action has
a command. Not reachable from inside the app: the Lock Screen / Live Activity, Control Center, notifications.

- **Setup after updates:** `AppModel.setupVersion` (standard defaults `setup.version`). When an update adds setup steps
  it's bumped, and onboarding runs once in `updating` mode with only the new pages (v1.4: what's new, scrolling apps and
  the every-app automation, backups). Test scenarios mark setup done.
- **Simulator (no phone, ~10 min):** `scripts/test/sim.sh [script.txt]` runs `.github/workflows/ui-test.yml` on a
  macOS runner and downloads everything to `test-runs/<time>/`. Default script: `smoke.txt` (every screen, every scenario).
- **iPhone over USB:** install the `dev-build` IPA with Impactor, open Productium Dev, then
  `scripts/test/device.sh [script.txt]` (pymobiledevice3 pushes the script and pulls the results).

## 1. Repo layout

```
Packages/ProductiumCore/   Pure Swift engine + tests. Builds and tests on Linux (swift test). ALL logic lives here.
  Sources/ProductiumCore/  see §3
  Tests/ProductiumCoreTests/  Fixtures.swift (Fx: Toronto-like calendar, Monday 2026-11-16, school 8:30-15:00, soccer)
App/                       SwiftUI app (iOS 17+, XcodeGen). Thin: views, services, intents, AppModel.
  Model/AppModel.swift     the one @Observable @MainActor model; owns AppState, calls core, persists, schedules
  Model/AppState.swift     Persistence (state.json), AboutMeStore, CallLogStore, RestorePreview
  Model/ExportService.swift builds/restores the format-3 export (permissions, notifications, files)
  Services/                ClaudeClient, HealthService, CalendarService, LocationService, MotionService,
                           NotificationService, SystemServices (AlarmScheduler, background refresh), UpdateChecker
  Intents/AppIntents.swift App Intents + `Friction` (Shortcuts-driven scroll sessions, standard defaults)
  Views/                   Today, Schedule(WeekView), Tasks, Review, Settings, Thinks, PastPrompts, Gap, Focus, Onboarding…
Shared/                    LocalStore (standard defaults, Application Support, friction keys)
project.yml                XcodeGen spec: one app target, free Apple ID, HealthKit the only capability
.github/workflows/ios.yml  CI (see §10)
scripts/                   install.sh (latest release or `--dev`, with Impactor), make-source.py
                           (SideStore source), inbox-eval (runs the real box prompt against a claude-server)
source.json                static SideStore source; CI attaches a fresh one to each release
```

Rules of thumb: put logic in ProductiumCore with a test; views only render and call `AppModel`. The iOS target
cannot be compiled on Linux, so UI changes are verified only by the `ios-compile` CI job. Avoid mutating captured
`var`s inside `Task {}` (Swift concurrency errors); adding an enum case (e.g. `AIFeature`, `BlockKind`) means fixing
every exhaustive `switch` in `App/Views/Theme.swift` and core.

## 2. Data model (`AppState`, one Codable struct, persisted as `state.json` in Application Support)

`AppState.schema = 6` (v1.3: 5 = grid templates and prompt severities, 6 = seed category colours, Transition and
Messaging, `feedback`). Schema 4 (v1.2.2) and later migrate: `AppState.init(from:)` decodes leniently, then
`Migrations.upgrade` runs one step per bump (state.json, restores and backups all go through it; the app keeps the old
file as `state-schema-<n>.json`). Below 4 decodes as fresh; a format-3 export is refused. `MigrationTests` decode the
1.2.2 fixture (`Tests/…/Fixtures/state-1.2.2.json`, the `history` scenario saved by the phone) and check every field
survives. Main parts:

- **Time (Part 0 / B):** `entries: [Entry]` is everything timed: classes (repeating, `School › class`, spares and lunch
  `open`), calendar events (`source calendar`, id from the EventKit id), the planner's future blocks (`source plan`,
  renewed each replan, past ones kept), what you said live or afterwards (`source you`), Health sleep and workouts
  (`health`), and what the phone inferred (`sensor`: scroll sessions, walks, drives, estimated nights, phone use after
  bedtime). One-day edits of a series are `marks[day] = skipped` plus a detached one-off. `Days.expand` is the one
  view of time; `TimeLog.past` is the one "what happened" (resolved by `DayEntry.rank`: told > Health > scheduled >
  sensor > planned routine; Untracked fills the rest). `rules: [Rule]` change the planner for a while (`PlannerLimits`).
- **Tasks:** `items: [WorkItem]` (`state` open / done / dropped, `notBefore`, `maxMinutesPerDay`, `firstStep`,
  `category`), `taskHistory` (every ending: done / dropped / partly, kept after delete), `dayPlans` (what each day's
  first plan asked per task, for `Accountability`), `plan`, `planHistory`.
- **Categories (C):** `categories: CategoryTree` (stable ids, ≤3 levels, `group`, `yours`), `categoryRules` (learned
  title → category, your corrections win), `taxonomy: TaxonomyLog` (the tidy-up runs, revertible).
- **Places (E):** `trace: LocationTrace` (visits + coarse points, 180 days), `placeBook` (clustered places, names from
  you / entries / the map), entries' `placeId`. `places` / `visits` remain for the home geofence.
- **Sensing (N, A):** `inference: InferenceState` (learner, what was asked / applied, answers, alarm stops, the pending
  question), `health` (nights from `SleepNights`, merged field by field), `healthReads`, `motion`, `screen`,
  `screenAverages`, `scrollingApps`.
- **Doing (D, I):** `quickStarts` (the activity grid: templates, yours, the AI's; pins, aliases), `goals` (the tracking goal is built in), `prompts: PromptLog`, `outbox`, `approvals`.
- **Learning:** `learned`, `beliefs`, `policy`, `taper`, `changes: ChangeLog`, `patterns`.
- **Backup (v1.3 H):** `backup` (folder name, last write, last error); the folder's bookmark is in the Keychain.
- **Feedback:** `feedback` (notes typed in Settings → Backup & Restore; they travel in every export and backup).
- **AI / misc:** `conversation`, `archive`, `usage`, `draft`, `review`, `pinnedCharts`, `telemetry`, `prefs`,
  `integrations` (health, calendar, location, motion, alarms, notifications, reminders, photos), `rewards`.
- **Before you used it:** `AppState.trackingSince` (the first entry you told or the planner made, message, app open or
  task). Days before it keep Health and Screen Time (sleep and screenshots compare fine) but have no log: day scores,
  usuals, the week chart, the recap, goals' days met, the leaderboard and Where Your Time Went skip them
  (`AppModel.isTracked`, `trackedScore`).
- Outside state: `about-me.md`, `ai-calls.json`, `UserDefaults` (scroll log, `alarms.ledger`, charger times, the
  Reminders list id, the last screenshot seen), `drafts/` images, Keychain (API key, never exported).
- Gone in v1.2 (do not reintroduce): commitments, one-offs, events, exceptions, situations, markers, outcomes, the
  focus session, gap notes and `GapLog`, stored routines (read from the log by `Routine.fromLog`), `AlarmRule`,
  flashcards, reads.

## 3. ProductiumCore modules

| Area | Files | Role |
|---|---|---|
| Time | `Entry.swift`, `Days.swift`, `TimeLog.swift`, `Rules.swift`, `Timetable.swift`, `CalendarEntries.swift`, `EntryBuilder.swift`, `SleepNights.swift`, `CheckIns.swift` | entries, occurrences, the resolved log, sensor-built entries, nights from Health samples. |
| Planner | `Planner.swift`, `Routines.swift`, `SleepPolicy.swift`, `Palette.swift`, `Accountability.swift` | the plan from entries, rules, habits and at-risk tasks; day accounts and `DayScore`. |
| The box | `Box.swift`, `BoxOps.swift`, `BoxSideOps.swift`, `QuickParse.swift`, `Outbox.swift`, `Approvals.swift`, `Conversation.swift`, `Query.swift`, `Reply.swift`, `AI.swift`, `Usage.swift`, `AboutMe.swift` | prompt, context, schema, applier (risk → Approve), the local fast path, the outbox, queries. |
| Categories | `Categories.swift`, `CategoryRules.swift`, `Taxonomy.swift`, `CategoryPalette.swift` | the tree, filing rules, the tidy-up pass. |
| Doing and seeing | `QuickStart.swift` (grid, templates, ranking, + `Habits`), `GridTidy.swift`, `Goals.swift`, `Ring.swift` (`RingModel`, `DayForecast`, `ForecastVerdict`, `UpNext`, `MoodMap`), `DayRings.swift` (+ `DayCompare`), `NowActivity.swift`, `TrackPrompts.swift`, `PromptSettings.swift`, `Nudges.swift`, `Alarms.swift`, `Rewards.swift`, `Metrics.swift` | the activity grid, goals, the three rings, the Now activity, prompts and their severities, notifications, alarms, celebrations. |
| Learning | `TaskHistory.swift`, `Patterns.swift`, `InsightPass.swift`, `ChangeLog.swift`, `Avoidance.swift`, `CapacityLearner.swift`, `Personalization.swift`, `Beliefs.swift` | track record, patterns, the quiet weekly pass. |
| Sensing | `Inference.swift`, `Places.swift`, `Motion.swift`, `Sleep.swift`, `Scrolling.swift`, `ScreenTime.swift`, `ScreenOCR.swift` (+ `ReminderMirror`, `ActivityToggle`), `HealthStatus.swift` | signals → inferences, places, Screen Time from OCR. |
| Review | `Recap.swift` (`PlannedShare`: how much of a day is planned; `WeekRecap`: Your Week; `OCRLines`: Vision boxes to rows), `DayRings.swift`, `Ring.swift` | |
| Support | `Models.swift`, `AppState.swift`, `Migrations.swift`, `Backup.swift`, `Export.swift`, `Telemetry.swift`, `Timeline.swift` (segments for the CSV), `TaskBoard.swift`, `Agenda.swift`, `Util.swift` | |

### 3.1 Planner (`Planner.swift`)

Deterministic earliest-deadline-first allocation into real free time. Steps: `buildDays` (per day: wake from
`WakePlanner`, bedtime = next wake − sleep need, work end = bedtime − wind-down, busy = routines, activities
(+buffer), events, locked blocks, dinner; free intervals; study cap and free-time floor from `Beliefs`
× `BehaviourPolicy` multipliers × today modifiers for short sleep/low mood) → `buildDemands` → `allocate`
(modes `.normal(span 3)`, `.wide`, `.crunch` (uses free time), then `borrowSleep`, then `displace` low-importance
work) → `finish` (adds wind-down, sleep, free/gap blocks, warnings, shortfalls).
- Tests/quizzes (`isMemoryBased`) become spaced retrieval sessions at expanding offsets (1,2,3,5,7,10,14,21 days
  before); long work is paced chunks released over days with a buffer before the due date.
- Estimates are multiplied by the learned per-kind factor (`LearnedModel.estimateFactor`). `remainingMinutes`
  floors at 10 (15 if unfinished). `Planner.shownMinutes` converts back to the student's terms for warnings.
- Hard work scores into the student's real peak hours (`EnergyModel` alertness × learned hour reliability).
- Block length ≤ `BehaviourPolicy.maxBlockMinutes`; a break (`study.breakMinutes`) follows each block.
- At-school errands (`WorkItem.isAtSchoolErrand`: `atSchool` flag, or chore starting ask/email/tell… with a
  teacher word) are not study: `placeErrands` puts one `.event` block (with `itemId`) inside school hours (a
  Lunch/break period if the timetable has one, else 10 min after school starts), before the due time, and
  `NudgePlanner` sends an "At school: …" reminder.
- Sleep is never traded for tests; small capped trades only for deadline-critical production work
  (`SleepPolicy.allowance`, `Preferences.allowSleepTradeoffs`, floor `sleepFloorMinutes`).
- `Planner.merge` keeps today's past blocks. Block ids are stable hashes (`stableUUID`) so replans don't churn.
- `PlanHistory.record` (called from `AppModel.replan` before replacing the plan) snapshots finished days.

### 3.2 Learning and beliefs

- `Beliefs` (items + groups, defaults in `Beliefs.priors`): `study.schoolDayCapacity` 180, `freeDayCapacity` 300,
  `schoolDayFreeTime` 60, `freeDayFreeTime` 180, `focusMinutes` 40, `breakMinutes` 10, `routines.dinnerTime`
  18:30, `dinnerMinutes` 30, `sleep.chronotype`. Each `Belief`: value, `stated?`, samples, evidence, source,
  `prior`, `bindsTo` knob. Confidence: assumed → learning (1-2 samples) → learned (3+); stated; confirmed when
  stated ≈ learned. `effective` = stated until 3 samples. `CapacityLearner.learn` (75th percentile of the last 3
  weeks, shrunk toward the prior; focus length from finished blocks; dinner from markers).
- Routines are the first belief group but remain `Routine` structs: `minutes` = stated until 3 samples, then the
  median; `safeMinutes` (80th percentile) for wake planning; `RoutineLearner.learn` pairs the earliest start with
  the next end (marker ids in `learnedFrom` stop recounting) and runs the moment a pair completes
  (`AppModel.logMarker`, evidence routing, refresh).
- `MarkerLog.add` merges repeat markers (same activity+phase within 3 min: earliest time, best source);
  `MarkerCategory.infer` assigns categories from the activity name (never a blanket free).
- `LearnedModel`: Beta/EWMA stats from `BlockOutcome`s: adherence → `loadFactor`, per-hour reliability, focus
  minutes, chronotype from free-day sleep midpoints.
- `WorkDone.minutes` is THE work-done source (outcomes ∪ study check-in spans, overlap counted once, plus
  progress entries). Used by Review, `DayTotals.doneStudy`, `CapacityLearner.records`.

### 3.3 Sleep (A5–A7)

`SleepNights.build` picks one source per night (most asleep minutes; `inBed` when there are no stages: an iPhone
without a Watch); the longest cluster 18:00–15:00 is the night, other clusters ≥20 min are naps. `HealthDay.merged`
never clears a value (a locked-phone read comes back empty). Nights become `health` Sleep entries (estimates:
`sensor`), which outrank the planned Sleep. Phone use after bedtime becomes sensor Scrolling and moves the planned
Sleep's start. At 10:00, if nothing measured the night: "Slept about 23:20–7:05?" (`TrackPrompts.sleepQuestion`).

### 3.4 The log, the ring, the forecast

`TimeLog.past` resolves a range; an Untracked slice of 15 minutes or less with something on both sides becomes Transition
(Essentials › Transition, already confirmed, not editable). The tracking goal is no untracked waking stretch over 15
minutes (`TrackPrompts.goalMinutes`: the Tracked ring's gaps, Goals, Schedule's Untracked rows; "What are you up to?"
first asks at 12). `RingModel` sums it by group and level-2 category (actual + a forecast for the rest,
previous-period deltas, tracking gaps). `DayForecast`: the last 4 same weekdays + the last 7 days of the same type
(≥3 tracked days, or nothing), the median per category from this time of day on, today's fixed time (school,
calendar, the planned Sleep) as planned, the rest Untracked. `ForecastVerdict` names the 2 biggest differences that
have a direction (productive and at-least goals up; unproductive, at-most goals and Untracked down; free time and
essentials neither; Untracked never offsets a worse category). `DayScore` = tracked 30 + work 40 + deadlines 30 −
scrolling, always shown with its parts and your usual day.

v1.3 D: `DayRings` are three goals that close, drawn like Activity's rings (Work red, Tracked green, Limit cyan; thick,
nearly touching, shaded arcs): Work (task minutes vs `Accountability.asked`), Tracked
(share of waking time that's an entry; closes with ≤5 min missing) and Limit (unproductive minutes vs a daily at-most
goal, else the taper's limit, else 60; good when not closed). Same numbers as `DayScore`. `DayRings.usual` is the
median of the last 4 days of the same kind; `DayCompare` gives Review → Day's "Studying +40 min, Scrolling −25 min"
and the best / hardest hour.

### 3.4a The activity grid and the Now activity (v1.3 A, B)

- `QuickStartTemplate.all` (20) seed the grid (onboarding unticks; the 4 → 5 migration adds them). Tiles have `origin`
  (template / you / ai), `symbol`, `pin` (a slot), `edited` (you renamed / recategorised / pinned: the AI leaves it),
  `aliases` (titles merged in). `ranked` scores each past start by time of day (σ 45 min), same kind of day (school /
  free + labels; other kinds ×0.25), weekday, place, "after what just ended", halving every 21 days; ties in template
  order; pinned tiles keep their slot; `top` = the 3 likeliest (notification actions, the Now activity, gap answers).
- `GridTidy` (A4): the insight pass's `grid` lines (add / merge / rename / hide) become `InsightChange.grid` in the
  `ChangeLog` (own cap 5 a run), refused for pinned or edited tiles, over 40 live tiles, or hiding one used in 30 days.
- `NowActivity.make`: running > question > untracked (≥10 min, awake) > assumed (a series occurrence now: "Still at
  School until 15:00?", with `then` = untracked from its end, shown once stale) > up next. A kind shows only when its
  severity is Live Activity. The app mirrors it into `NowAttributes` (Shared) and the widget draws it; buttons are
  `NowActionIntent(action:)` run in the app (`AppModel.nowAction`). Synced after every replan and on going inactive;
  renewed after 7 h in the foreground (iOS ends it at 8).

### 3.5 Notifications and prompts

v1.3 E: `PromptSettings` (`Preferences.prompts`) gives each `PromptKind` a `Severity` (off, quiet, Live Activity,
notification, alarm; any kind can be any). `effective` turns
Alarm into a notification without `Integrations.alarms` ("Alarms Allowed") and Live Activity into a notification when
the Now activity isn't showing. `NudgePlanner.plan` and the app's final list are filtered by it; `NudgePlanner.alarms`
rings bedtime / leave / missed start only when set to Alarm; the wake alarm when `.wake` is Alarm; any other
notification whose kind is Alarm also rings (`PromptSettings.alarms(from:)`, `PlannedAlarm.Kind.prompt`). `NudgeSettings`
keeps only `level` and `arrivingHome` in use (the toggles are migrated). The box sets one with `prompt.<kind>`.
`NudgePlanner.plan`: task starts (H4: first step · minutes, sessions done, what it leads to), one lead-up, at most
one follow-up (none while you track something else), wind-down, bedtime, leave, deadlines, check-in, intentions. No
"How did it go?". `TrackPrompts`: "What are you up to?" at 25 min untracked then every 30; quiet in sleep, wind-down,
planned study and before wake; stops after 2 ignored that day; past stretches asked once in the past tense; the top 3
start buttons are its actions. The running entry's passive notification every 10 min. Categories live in core
(`NotificationCategory`); copy may invite a reply only with a text field (`testReplyCopyHasTextField`). Alarms:
`AlarmPlanner.desired` = entries' approved alarm alerts (the wake alarm is the planned Sleep's end, titled "Leave by …"
on school mornings) + bedtime / leave / missed start; the reconciler diffs with the device.

## 4. The box (Part 0, O6–O8)

- Everything said goes through `AppModel.submit`: saved to the `Outbox` (and disk) first, then `QuickParse` (start,
  "I'm showering (now)" → the tile whose name matches the -ing word, stop / done, "X from A to B", mood, "school as usual"; certain or pass, no network), then Sonnet inside a
  background task. A reply from a notification always gets a quiet receipt; unsent ones retry on launch and refresh.
- Sonnet: `BoxPrompt.system()` (fixed, < 6,500 characters, cached), `BoxContext.make` (Settings, About Me, the
  running entry, the series, yesterday … +7 days with refs and flags, open tasks, track record, goals, places, rules,
  the category tree), forced tool `BoxSchema.result` (`ops`, `reply`, `gap`, `queries`, `facts`), lenient
  `BoxResult.read`. Later turns send a context delta (`ConversationPolicy`).
- Ops: nouns entry, task, rule, setting, mood, screen_time, goal, place, category; verbs add, change, remove, start,
  stop, skip, confirm, done, drop. Refs `e…`, `e…@day`, `t…`, `u…`, `g…`, `p…`, category ids. Editing a planned block
  makes it yours. `BoxApplier.risk` holds (never refuses) removing a whole series, ≥1 h of your own logged time, or
  a new alarm: one Approve / Decline (`AppState.approvals`). Receipts are day by day; Undo restores the snapshot.
- Queries (F): `TimeQuery` run on the phone; `{q1.total}` etc. filled by code; `ChartCard`; Pin to Review re-runs live.
- Evals (`scripts/inbox-eval/run.sh`): `--v12` 40 cases (14 real prompts + everyday, A1–A3, nouns, warnings, K1
  actions, exceptions), each with a reference answer (`--v12-reference` 40/40) and a check that fails when nothing is
  done (`--v12-nothing` 0/40); `--v12q` 6 query cases; `--taxonomy`; `--insight`.

## 5. Behaviour change (Sonnet insight pass, applied quietly)

- `InsightPass.trigger` (`AppModel.insightPass(force:asked:)`): weekly with the review, or ≤1/day when a task is put
  off ≥3× or <50% of planned is done 3 days running, or when the student asks ("Why do I keep putting things
  off?"). One Sonnet call at low effort returns the Weekly Note (the only visible output), changes, and about-me
  Inferred/Patterns lines. There is no approval step, no Today card and no toast.
- `ChangeLog` (`AppState.changes`): each change (knob, starter step, if-then intention, ≤1 belief group, about-me
  line) is applied at once and logged with reason, evidence, from → to and model. Settings → What Productium Thinks
  → Changes lists them with **Revert**, **Never Change This** (pin) and **Allow** (undo a pin). Safety is in code:
  Registry ranges and max steps, ≤1 change per target per 7 days, ≤3 per run, never sleep need/floor/trade-offs,
  never `(you)` lines or student-written data, no retry for 30 days after a revert. v1.0 `proposals` migrate
  (approved → applied, rejected → declined).
- `Avoidance`: `WorkItem.deferralLog` events (snoozed, cantToday, skipped, neverStarted, dueMoved with the
  student's words); "Put off 3×" on rows and in the box context.
- `BehaviourPolicy` (Tier 2 values): maxBlockMinutes, capacityMultiplier, freeTimeMultiplier,
  followUpShiftMinutes, intentions.

## 6. Scrolling and Screen Time

- Shortcuts drive `Friction` (App Intents: Pause Before Scrolling / Should I pause? / Closed a
  Distracting App / Probably Stopped Scrolling / plan queries). `ScrollLog` (`Scrolling.swift`, stored in
  standard defaults) keeps `ScrollSession{app, openedAt, endedAt, endSource, confirmedUntil, checkInAt}`. Opening a
  scrolling app ends another's session; other signals end it (`closed`, `otherApp`, `productium`, `lockProxy`:
  charger/alarm/Focus, `checkIn`, `checkInIgnored`, `estimated`). A session with no end is credited the median of
  that app's observed sessions (prior 8 min, cap 30), marked estimated. `calibrate` stores per-app over-count
  factors from screenshots ("Shortcuts over-counts Instagram ~1.4×").
- v1.3 every app: the "Opened an App" intent (`OpenedAppIntent`, an "App is opened" automation with every app ticked
  and App = Shortcut Input) calls `AppModel.appOpened`: `ScrollLog.seen` ends what was open and starts that app's
  session (`ScrollSession.scrolling` false for apps not on the list; the pause automation's repeat within 15 s is the same
  opening). Every app is registered in `scrollingApps` (Settings → Screen Time → Scrolling Apps lists them; onboarding
  ticks the common ones). `AppKinds.category` files a session: your own filing of that title, else Scrolling › the app
  (a node per app, created as needed), else Messaging (`AppKinds.messaging`), else no entry (it still counts as
  screen time). `EntryBuilder.apps` writes them as `sensor` entries (assumed until confirmed; anything told wins), and
  runs on every open / close / stop intent and on foreground, so the log is current. `screenDays` gives each finished
  day every app (total when every app is logged); sessions are kept 35 days (`prune`).
- `ScrollingApps` (`ScreenTime.swift`): `state.scrollingApps` decides what counts; defaults social/video/games on.
  `ScreenDay.recomputed`, `addsUp`, `mismatch`, `merged(with:)`; `ScreenReceipt` formats receipts.
- `ScreenTaper`: week 1 measures; then the limit drops ~10% a week toward a goal derived from the baseline
  (Mondays, held after a tough week).
- There is no app blocking or Screen Time API use (needs a paid account, see §14): Shortcuts and screenshots only.

## 7. Places, signals, inferences (E, N)

- `LocationService`: visits and significant changes always (Always permission, `location` background mode), a
  `CLBackgroundActivitySession` while an entry runs, coarse points ≤1 per 5 min into `LocationTrace`, reverse geocoding
  to name new places (a landmark iOS knows there, else the street address; never the nearest business). `PlaceBook.cluster`
  (150 m, centre = mean of its visits); names: yours > what you logged there (≥3, ≥60%) > the address. Settings → Places
  lists every place with where its name came from; tap to rename. `EntryBuilder.places` gives each one-off entry the place of the visit covering most of it.
- `Signals.make`: visits, motion spans, pedometer counts per walk, pickups, the charger, alarm stops (the alarm's Stop
  runs `AlarmStoppedIntent`), workouts, Health nights. `InferenceEngine.run`: plan vs reality ("You're at home, but
  school's on until 3. What happened?" Sick · No school today · Skipped), left early, missing the usual, walks
  (cadence → band), drives, wake (first of alarm stop, Health, first pickup, unplug, first movement), arrival (a place
  where one activity dominates), workouts. Bands: ≥0.8 logs itself as `sensor` time, ≥0.5 asks (one at a time,
  contradictions first; a Home card and a notification with one-tap answers + text), else a hint.
  `InferenceLearner`: 5 yeses move a kind up a band, 3 noes down. Answers go through the box's applier and the
  Weekly Note.

## 8. Export / backup (`Export.swift`, `ExportService.swift`)

v1.3 H: once a day (refresh, launch) `AppModel.backupIfDue` writes the export to a folder: with none picked, the app's
own Documents/Backups (Files → On My iPhone, `UIFileSharingEnabled`; kept out of the export's `files`; lost if the app
is deleted); or a folder you pick (iCloud Drive; `BackupService`, security-scoped bookmark in the Keychain so a
reinstall can find it), `Productium-YYYY-MM-DD.json`,
newest 3 kept (`BackupFiles`). Onboarding offers "Restore from Friday's backup" when the remembered folder has one,
else a file picker. Restores go through the migrations.

One JSON file, `format: productium-export`, `version: 4` (format 3 and older are refused): full `AppState` (with your
feedback), `aboutMe`,
`callLog`, `sharedDefaults`, `appDefaults`, `files` (every file in the container/Documents not otherwise
represented, base64, includes `drafts/` and `last-ai-error.txt`), pending/delivered notifications, permission
statuses, device info, server snapshots. Nothing is pruned before export. API key excluded. A test checks every
`AppState` property is exported (`ExportTests.populated()` must set any new field) and that round-trip is
identical except `exportedAt`. Restore previews, then replaces (saving `state-before-restore.json`).

## 9. AI routing, cost, server

- Server: claude-server on a Raspberry Pi over Tailscale (separate repo `../claude-server`), Anthropic-compatible
  `/v1/messages` with images, `output_config.effort`, `cache_control ttl 1h`, `/v1/subscription`, usage endpoint.
  `ClaudeClient` (App) sends, retries once, logs every call (`AICall`) to `AICallLog` (kept in full).
- `AIFeature.route`: box, project steps (breakdown), the weekly note / insight pass and the category tidy-up → Sonnet /
  low effort. Only output tokens count toward the daily budget (`UsageLedger`, default 10k); over budget, background
  AI waits (the box always works). Screenshots ≤1280 px.
- Everything user-facing the model returns is validated by code; never trust model numbers over data (e.g.
  scrolling minutes).

## 10. Build, CI, release, install

- `core-tests` (Linux `swift:6.2-noble`, `swift test` in the package) and `ios-compile` (macOS, XcodeGen,
  unsigned simulator build) run on every push/PR and on manual dispatch.
- `ios-free-ipa` runs on a push to **main** or **dev** after both pass. Version = `v<VERSION>.0` if there's no
  `v<VERSION>.*` tag, else the last patch + 1 (`VERSION` holds major.minor; bump it by hand for v1.3).
  main: `gh release create v<x.y.z>`, marked latest, and source.json updated. dev: replaces the `dev-build` pre-release
  (`Productium-dev.ipa`), no tag, no source.json. `MARKETING_VERSION`=version, `CURRENT_PROJECT_VERSION`=run number; `project.yml` is the free spec;
  unsigned device build; the widget extension, then the app (with the HealthKit entitlement), ad-hoc signed.
  `concurrency: release-<branch>`. Local toolchain: `export PATH=$HOME/.local/swift/swift-6.2.1-RELEASE-ubuntu24.04/usr/bin:$PATH`.
- Variable `BUNDLE_PREFIX` (currently `com.darshg321`) forms bundle ids `<prefix>.productium[.extension]`.
- Install (free Apple ID, Linux): `scripts/install.sh` (latest release, or `--dev`, signed with Impactor), or SideStore
  with the source `https://github.com/darshg321/productium/releases/latest/download/source.json` (needs a public
  repo). Free signing lasts 7 days; SideStore refreshes it; the app reads its own expiry (`Signature`). Free
  account limits: 3 apps, 10 App IDs / 7 days, no Family Controls, no time-sensitive entitlement, App Groups fail in
  Impactor (so none are used: the widget extension takes a second App ID and gets its data from the Live Activity).
- `AppUpdate`: `UpdateChecker` asks the public GitHub releases API once a day; Settings → Keeping It Installed shows
  version/build and "vX is available".
- Permissions: HealthKit (read sleep/steps/daylight/resting HR/workouts, write State of Mind), EventKit, Location (Always),
  Motion, Notifications, AlarmKit, background refresh.

## 11. UI structure (iOS design language, no custom chrome)

Tabs: Today · Schedule · Tasks · Review · Settings; token meter top right.
- **Today (v1.3 C1, "now"):** the box (a compose field; thread with receipts, Approve / Decline, Undo, charts; typing
  stays in the view and is saved when it pauses, and Today's 30 s clock holds while the box has the keyboard), alerts,
  the question card. The running entry is one row above the box (round icon, "Started h:mm" or its goal line, elapsed,
  Done for a task, red Stop). Below: Start / Switch To, a segmented Suggested · Work · Essentials · Free over a list of
  start buttons (Suggested = the 4 likeliest, the first marked "Usual now"; the others by category group, 6 each; All
  opens every button and the hidden ones; long press: rename / recategorise, hide), mood, "What were you doing?" (closed untracked
  stretches today, tiles as answers), "Did these happen?" (assumed time, the last 5, Yes to All), Rings (tap: the
  day's categories), Up Next. Section titles sit above their cards (Health / Fitness style, `SectionHeader`,
  `TitledCard`). Seed categories have colours (School orange, Essentials green, Travel brown, Scrolling pink…).
- **Schedule:** week strip + the day as Calendar draws it: blocks to scale on an hour grid (overlaps side by side), a
  red now line, scrolled to the hour before now. Past = tinted with a colour bar, assumed = paler, planned = dashed
  outline, untracked stretches = dashed gray (tap: pick what it was). Due items in a card above. Tap a block for the
  entry sheet; long press: It Happened / Everything Until Here / Start / Edit / Didn't Happen.
- **Tasks:** smart list; swipes Done / Start / Clear (asks why) / Delete; a read-only task sheet (first step, the
  track-record warning) with Start / Done / Clear / Delete. No "+" or forms: the box does it (K1).
- **Review (v1.3):** one page, every stat, no drilling in: Your Week (a banner opening `RecapView`, full-screen cards
  for the last 7 days from `WeekRecap`, Wrapped style, any time), Today (rings beside your usual, the day score in one
  line, what changed, best / hardest hour, patterns), At a Glance (`StatTile`s: tomorrow planned (`PlannedShare`), work,
  tracked, unproductive, screen time, deadlines, sleep, mood), This Week (scores, rings per day, vs the last 4 weeks),
  Where Your Time Went (Day / Week / Month, `TimeBreakdown`: a Screen Time–style bar and rows; tap for entries), Screen
  Time (today per app, grouped Scrolling / Messaging / Other), Goals, How You Work, Mood by Time of Day, Life Metrics,
  Pinned, Leaderboard, the Weekly Note (+ alarm proposals to Allow).
- **Entry sheet (C4 / O11):** title, times, category picker (+ New), topics, note, place; Yes / No for assumed time;
  delete; "also move similar".
- **Settings (K4):** Claude · Past Prompts · AI Usage | Sleep · Screen Time · Notifications (every prompt kind with its
  severity, Alarms Allowed, how much to interrupt, your alarms) | Goals · Categories · Celebrations | Connections ·
  Shortcuts · Places (where the week went, named places) · What Productium Thinks (Changes with evidence and Revert,
  tidy-ups, routines) · About You | Backup & Restore (the daily folder, export, restore, feedback) · Keeping It
  Installed. There's no Debug screen: the telemetry and diagnostics are in every export.
  There's no Privacy screen.
- Colour is never the only cue: each category has a symbol and a word; each ring has its word and number; forecast /
  planned time is faint.

## 11b. Follow-through, good hours and the leaderboard

- `AdherenceLearner` (in `Personalization.swift`) reads each finished day once (`LearnedModel.learnedThrough`): every
  planned work session in `planHistory` against the time logged on its task that day (handed out to the task's
  sessions in order, so a different order isn't a miss) → done (≥80%) / partial / skipped → `adherence`, `focusMinutes`.
  The hour learns from how much happened in the session's window (30 min early to 2 h late, `onTimeScore`); work at
  hours nothing was planned for adds success to those hours (`recordWork`). `goodHours()` feeds the planner's
  energy curve, the weekly note's context ("Most reliable hours", adherence) and Review → How You Work.
- Leaderboard: `Leaderboard.swift` (payload, ranking, invite links) and the Worker in `scripts/leaderboard`
  (`worker.js`, one KV namespace; `node test.mjs`; `./deploy.sh` after `npx wrangler login`, which also sets the repo
  variable `LEADERBOARD_URL` that CI writes into Info.plist). A group is a random id carried by the invite link
  (`productium://join?s=&g=&n=`); each member writes only their own row (random key, SHA-256 stored); rows expire
  after 60 days. Shared: a display name and, per day for 7 days, score, tracked %, work minutes, deadlines met /
  missed, scrolling minutes, plus your usual (median score of the 4 weeks before). Measures: Score, vs Usual, Work,
  Tracked, Least Scrolling. Posts only when changed, at most every 15 min (KV free tier: 1,000 writes a day).

## 11c. Dev builds and the test runner

- `dev` builds are a separate app: `<prefix>.productium.dev`, "Productium Dev", `AppIconDev`, scheme `productium-dev`
  (`AppInfo`: links, the Reminders list and calendar are named after the build; dev never writes to Health). CI sets
  APP_ID / APP_NAME / APP_SCHEME / APP_ICON from the branch.
- `TestHooks` (dev only) runs `Documents/test/commands.txt`: scenarios (`Scenarios.swift`, tested in `ScenarioTests`),
  tabs, links, box text, start / stop, approvals, questions, scrolling to cards, screenshots and text dumps.
  `scripts/test/sim.sh` runs a script on a CI simulator (`ui-test.yml`, under lldb so a crash leaves a backtrace) and
  downloads `test-runs/<time>/`; `scripts/test/device.sh` does the same on a USB iPhone. See §0.1.

## 12. Evidence the design rests on (one line each)

Spaced retrieval beats cramming (Cepeda 2006). Unpacking tasks reduces underestimation (Kruger & Evans 2004), so
estimates are corrected per kind. Teens need 8-10 h (AASM); study time bought with sleep hurts next-day
performance, so sleep is borrowed only for deadline-critical production work. Implementation intentions ~double
follow-through (Gollwitzer & Sheeran 2006). Plans that are repeatedly missed erode self-efficacy, so the app
plans less after misses and never uses streaks. Breaks help (Biwer 2023). Scheduled leisure feels like work, so
free time is a floor, not a block. Friction cuts app opens (Grüning 2023), taper gradually. Procrastination is
mood repair (Sirois & Pychyl 2013), so respond with easier entry, not pressure. Ariely & Wertenbroch 2002
(imposed deadlines) is deliberately not relied on (replication failed).

### F. Evidence for the rewards (v1.1 F1: checked on 2026-11-18; keep = use, weaker = use lightly, drop = not used)

- Immediate rewards raise intrinsic motivation (Woolley & Fishbach, JPSP 2016): **keep, weaker**. A 2022 follow-up
  (Liu et al., Frontiers in Psychology) re-ran it and found the effect, but by the same line of authors; it also raised
  a misattribution concern. Celebrations fire at the moment of Done, but nothing depends on the effect being large.
- Motivating uncertainty (Shen, Fishbach & Hsee, JCR 2015): **weaker**. Only the original (four studies, a
  water-drinking task) was found; no replication. The seeded surprise stays small (15% of small moments become
  medium) and can be turned down (F6).
- Peak-end rule (Kahneman et al. 1993), progress principle (Amabile & Kramer 2011), goal gradient (Kivetz, Urminsky &
  Zheng, JMR 2006), endowed progress (Nunes & Drèze, JCR 2006): **keep, weaker**. Original studies, mostly consumer
  settings; no replication found by search. Used as framing (what moved, what's left, free time next), never as a hook.
- Fresh start effect (Dai, Milkman & Riis, Management Science 2014): **keep, weaker**. Archival field studies; a
  2015 Psychological Science follow-up (five studies) supports it. No independent replication found.
- Temptation bundling (Milkman, Minson & Volpp, Management Science 2014): **weaker**. Effect faded over the study
  (N = 226); a later, larger study (N = 6,792) found a smaller effect. "After this: 2 h free" is shown, no more.
- Self-monitoring helps goal attainment (Harkin et al., Psychological Bulletin 2016): **keep**. Meta-analysis of 138
  RCTs (N = 19,951), d+ = 0.40; larger when progress is recorded physically or made public. The Life Metrics dashboard.
- Expected tangible rewards undermine intrinsic motivation, informational praise doesn't (Deci, Koestner & Ryan,
  Psychological Bulletin 1999, 128 studies): **keep (contested)**. Cameron & Pierce dispute it. No points or coins;
  celebrations say what you did.
- Broken streaks reduce later engagement (Silverman & Barasch, JCR 2023, seven studies): **keep**. No consecutive
  streaks; counts that can't break ("focused on 14 days this month") and cumulative milestones.
- The Zeigarnik memory effect does not hold (Ghibellini & Meier 2025 meta-analysis, 37 studies, recall ratio 0.99);
  the Ovsiankina resumption tendency does (about 67% resume): **drop Zeigarnik, keep Ovsiankina**. The next step is
  named and "resume" is offered; nothing relies on unfinished tasks nagging.
- Identity messages (Bryan et al. 2011): **drop**. Gerber et al. 2016 found no difference between noun and verb wording
  in a large field experiment (the original authors dispute the test). Not used.
- Comparing with others: **drop**. Only comparisons with your own past.
- Grayscale cuts screen time: **keep**. A pre-registered randomised field experiment (Zimmermann & Sobolev 2023,
  Cyberpsychology, Behavior, and Social Networking, N = 112) found an immediate drop in measured screen time, larger
  early than time limits. Other trials exist (a 2024 study, N = 84, and a medical-student crossover whose reporting
  couldn't be verified). Shortcuts' **Set Color Filters** action exists, so the recipe "Grayscale While You Scroll" is
  in `ShortcutsGuideView` (turn on when the apps open, off when they close; "Is Closed" can miss Home).
- Breaking up sitting (v1.1 H6 stand-up breaks): **weaker**. A 2022 meta-analysis of in-class activity-break RCTs
  (nine studies) found more movement but **no effect on cognition**, so the reminder is framed as a short walk and is
  optional (Settings → Notifications), not as a focus booster.
- Morning light (H6 daylight nudge): **weaker for this use**. A 2026 JAMA Pediatrics RCT (16-19 year olds, two
  weeks of bright-light glasses in the morning plus evening blue-blocking and a sleep schedule) shifted circadian
  timing earlier and added about 47 min of weeknight sleep, but it was a package with devices, so the nudge only
  suggests ten minutes outside on days with nothing fixed.

## 13. Status and known loose ends (2026-11-22)

- v1.3 / v1.4 are released: core for M, A, B, D, E, H and the C2 comparisons is done with tests;
  the app side is written but only compiles on CI. To check on the phone: the Now activity from the Lock Screen
  (including starting it from a `LiveActivityIntent` in the background) and uninstall → reinstall → restore.

- v1.2 is built end to end and released as v1.2.x. Versions: `VERSION` holds major.minor, main releases
  v<VERSION>.<n>; the `dev` branch builds a rolling `dev-build` pre-release without touching the version. Core tests green on Linux; the box evals
  pass on Sonnet (40/40, queries 6/6, the taxonomy and insight passes). App code compiles only on CI.
- **D5 Live Activity and M10 controls** are in the `ProductiumWidgets` extension (a second free App ID; no App Group,
  so the activity carries its own state). The running entry shows on the Lock Screen and in the Dynamic Island with a
  Stop button; Control Center / Action button controls: Stop tracking, Start next, Tell Productium (iOS 18). The
  running notification (D6) is only scheduled when Live Activities are off. Check on the phone after a SideStore install.
- Not done, and why: **M1 Focus filter**: the Shortcuts "When Focus turns on → Start Activity" automation is the path.
  **M7** is wired only for entries that `CategoryRules` leaves in Other: on iOS 26 with Apple Intelligence on,
  `OnDeviceModel.categorise` files them (not into School) and teaches `CategoryRules` the answer; otherwise they stay in
  Other until the box or the taxonomy pass files them.
- ScreenOCR reads the iOS 18 layouts (written by hand) and iOS 26's Week view (from real screenshots, 1.4.1): "Last
  Week's Average", "Total Screen Time" (a week view's apps are weekly totals, scaled to a day by average ÷ total,
  `ScreenDay.dailyFactor`; averages saved wrongly by 1.4.0 are repaired on load), Pickups' average, and "First Used
  After Pickup" counts ignored. Vision boxes are joined into rows (`OCRLines`).

## 14. If there is a paid Apple Developer account (not planned; what it would add and simplify)

v1.1 builds for a free Apple ID only. The last paid-capable code is in git history: tag `paid-build-final` (local; push it to keep it on GitHub). If a paid account ($99/yr Apple Developer Program) is ever
available, this is what it unlocks, roughly in order of value.

**Screen Time measured instead of reported (Family Controls; development entitlement is automatic on a paid team.
TestFlight / App Store also need Apple's Family Controls Distribution approval for each target).**
- `DeviceActivityMonitor` threshold events give per-app minutes without screenshots, e.g. one event every 5 min per
  selected app, written to shared storage. Note: `DeviceActivityReport` views can show exact usage, but their data
  can't leave the report extension, so numbers for the planner come from threshold events, not the report.
- `ManagedSettings` shields: real blocking during focus blocks and wind-down. A shield action ("Go back anyway") can
  replace the Shortcuts "Pause Before Scrolling" automation.
- Unlock limits and the `ScreenTaper` daily limit can be enforced, not just suggested.
- **Simplifies (could delete or demote):**
  - the Shortcuts-driven `Friction` session inference: `ScrollLog`, `endSource` guessing, `estimated` sessions,
    per-app `calibrate` factors
  - most of `ShortcutsGuideView`
  - screenshot parsing for screen time (keep only as a fallback)
  - the `syncScreen` merge rules between screenshots, Shortcuts estimates and measured data, which become one
    source
- Needs back: the 4 extensions (Monitor, Report, Shield, ShieldAction), the App Group, `ScreenTimeService`,
  `Shared/ScreenShield.swift`.

**App Groups → widgets, Live Activities, Control Center controls.**
- Home / Lock Screen widgets (now / next block, today's progress) and interactive widget buttons (Start Focus,
  Done) through App Intents.
- Live Activity + Dynamic Island for the focus timer and "leave by" countdown (`Shared/BlockActivity.swift`).
  (Likely doable free (v1.2 M.0a): a Live Activity needs only the widget extension and its own App ID; untested here,
  see §13. The v1.2 build ships the passive running notification instead.)
- Control Center / Action button controls (iOS 18+) for "Tell Productium" and Start Focus.

**Time-sensitive notifications.** Block starts, leave-by and bedtime break through Focus without asking the student
to allow Productium in each Focus. That simplifies onboarding and the Focus recipe in `ShortcutsGuideView`.

**No 7-day signing.**
- **Delete:** `Signature` expiry tracking, the onboarding `keepAlive` page, expiry housekeeping notifications
  (`NotificationService.scheduleHousekeeping`), and the SideStore / Impactor refresh instructions.
- **Distribution:** TestFlight (90-day builds, install with a link) or the App Store replaces SideStore and
  `source.json`.
- **App limits:** no 3-app / 10-App-ID limit, so a UI test runner and extensions are easy to install.
- **CI:** one signed CI job using the App Store Connect API (`scripts/asc.py` in git history registers devices and
  certs from Linux). The free-spec rewrite isn't needed.

**Other capabilities a paid team gets.**
- **iCloud / CloudKit:** automatic backup and sync of `state.json` and about-me across devices. This replaces the
  manual export / import as the main backup.
- **Push notifications (APNs):** the claude-server can wake the app for reliable rescheduling of alarms and nudges
  (helps the v1.1 alarm issues) and deliver server-side nudges.
- **Associated domains:** universal links (shared deep links), and Sign in with Apple for the server instead of a key.
- **Critical alerts** need a further, separate Apple approval. Not expected.

**Unchanged either way:** HealthKit, EventKit, Location, Motion, AlarmKit, App Intents / Shortcuts, background
refresh and local notifications all work with a free Apple ID.

## 15. Day rules and alarms (v1.2)

- `DayRule` is unchanged and lives inside `Repeat` and `Rule.days`; `DayRuleBook` keeps sequences (A/B over school
  days) and labels (`no-school` is set by `Days.skip` on School).
- Alarms are entries' `alert`s (`Alert.alarm`, `approved`). The box's new alarms wait for Allow; the insight pass can
  only propose one (`InsightPass.proposals` → `AppState.approvals`, in the Weekly Note and Settings → Alarms).
  Turning one off never needs approval. Allow turns Full-Screen Alarms on if it was off.
