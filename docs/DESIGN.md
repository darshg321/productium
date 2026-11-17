# Design

**Subject:** a high-school student's day, measured in time. **Primary job:** get everything out of
their head into one box, then see what to do now. **Principle:** the fewest decisions and the least on
screen, for the most help.

## Plan (v3: native iOS)

The app now looks like it ships with the phone, taking its cues from Health and Settings: their
informative simplicity is one number, one comparison, one small chart, and a row per thing.

**Structure.** Five tabs: Today · Schedule · Tasks · Review · Settings. Every tab has the AI token meter at the
top right.

**Schedule** is the Calendar app's day view: day chips for the next two weeks along the top (a blue dot
when work is planned, a red one when something's due), a row of four numbers (up, leave, work, bed), what's
due, then the day to scale (1.2 pt a minute) from wake-up to bedtime with overlapping things side by side and
a red now line. Study blocks open their task. A Day | Week switch gives the old seven-day list; tapping a day
there opens it as a timeline.

**Tasks** is a Reminders-style smart list: three numbers (open, due this week, past due) and work left
against work planned, then sections by due date (Past Due, Today, Tomorrow, Next 7 Days, Later), subject or
type, with Done hidden unless asked for. Each row has a check circle, due date and subject, the next planned
session (or "Not planned yet"), and work left. Swipe right to finish, left to delete, edit or start now.
Search covers titles, subjects, topics, notes and a project's steps. Adding and editing is a form on the phone,
so it costs no tokens; the Inbox still takes plain words.

**Surfaces.** `systemGroupedBackground` with `secondarySystemGroupedBackground` cards (16 pt continuous
corners) on Today and Review, the Health summary layout. Week, task detail, day detail and all of
Settings are `insetGrouped` lists. Liquid Glass bars, sheets and controls come from the system
components, so nothing is custom-drawn.

**Colour.** System colours only (they adapt to dark mode and Increase Contrast), each meaning one thing:

| colour | means |
|---|---|
| blue | focus work; also the accent |
| orange | free time |
| indigo | sleep, wind-down |
| gray (`systemGray3`) | fixed time: school, travel, routines, meals |
| purple | screen time |
| red | something needs attention (overdue, doesn't fit, build expiring) |

**Cards (Health).** A tinted header line (symbol + category name in its colour, a quiet detail on the right),
then one big rounded-digit value with a small grey unit ("7 hr 32 min", "82 % of planned"), then one line
of comparison and, where it helps, a small Swift Charts bar chart.

**Rows (Settings).** White SF Symbols on coloured continuous-corner squares (`IconTile`), with the current
value right-aligned in grey. Each top-level row opens one page.

```
Today                                   ◔ 4.2k   ← token meter
MONDAY, NOVEMBER 16
┌ ⬇ Inbox ─────────────────────────────┐
│ What's due, what happened, what      │
│ changed?                    🖼     ⬆ │
└──────────────────────────────────────┘
┌ ✏ Now                    until 4:30 ┐
│ Chem test review                     │
│ 34 min left · Retrieval practice     │
│ ━━━━━━━━━━━░░░░░░                    │
│ [         Start Focus              ] │
│ ● Next: Soccer               4:30 PM │
└──────────────────────────────────────┘
Rest of Today
[ Work 1 hr 30 ] [ Free 2 hr ] [ Bed 10:15 ]
┌ ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬ (to scale)        ┐
│ ▍ Soccer practice   4:30 – 6:00 PM   │
│ ▍ English essay 2/6 6:20 – 7:05 PM   │
└──────────────────────────────────────┘
```

**Type.** SF Pro at the system text styles, so Dynamic Type works; SF Rounded for big values. Title
case for buttons and navigation, sentence case for prose.

**The token meter.** A small ring that fills toward the daily budget (green, then orange from 80 %,
red when spent) with today's count beside it. It counts output tokens only: what Claude wrote, including
its hidden thinking. Tapping it opens AI Usage: today against the budget, a
7-day chart, tokens by feature, the subscription's limits (percent used of the 5-hour session and the
week, with reset times, polled every minute while open), the server's own count for the key, recent
requests and the budget settings. Every request is kept in full on the phone (`AICallLog`, its own file,
last 150 calls or two weeks): tapping one shows the system prompt, each message, the schema and the raw
reply, with copy and share. Failed requests are kept too, and a receipt has a Prompt button for its own. Over budget, background AI (flashcards, reads, project steps, weekly note) waits until
tomorrow; the Inbox always works.

## Interruptions

`NudgePlanner` (ProductiumCore, tested on Linux) decides every notification for the next 24 hours from the
plan; the app only turns them into requests, rebuilt on each replan. iOS holds 64 pending, so the planner
keeps the soonest 52 and leaves room for wake-ups, housekeeping, snoozes and scrolling check-ins. Two in the
same minute become one (the more useful), except "how did it go?", whose buttons are the point.

| | Gentle | Standard | Persistent |
|---|---|---|---|
| block start (Start Focus · In 10 Minutes · Can't Today) | ✓ | ✓ | ✓ |
| "how did it go?" (Done · Partly · Didn't get to it) | ✓ | ✓ | ✓ |
| 10-minute heads-up (not for back-to-back blocks) | | ✓ | ✓ |
| follow-ups if focus hasn't started | | +7 min | +5, +12, +20 min |
| wind-down, evening check-in, morning brief | ✓ | ✓ | ✓ |
| bedtime | | ✓ | ✓ |
| "still up?" 20 minutes after bedtime | | | ✓ |
| leave in 10 minutes / time to go | go only | ✓ | ✓ |
| due tomorrow (6 pm the day before) | ✓ | ✓ | ✓ |
| due in 3 hours | | | ✓ |
| arriving home (Places) | | ✓ | ✓ |
| scrolling check-ins after "Go back anyway" | 15 | 10, 20 | 10, 20, 30 |

Starting focus, snoozing or answering a block cancels what's left for it, pending and delivered. Snoozed
blocks are remembered so a replan doesn't bring their follow-ups back. Starts, follow-ups on Persistent,
leave-by and bedtime are Time Sensitive in the paid build; the free build can't be, so Settings tells you to
allow Productium in your Focuses. Opt-in AlarmKit alarms (iOS 26.1) cover bedtime, time to leave, and a work
block 10 minutes in that hasn't started, with a Start button that runs `StartFocusIntent`. Settings →
Notifications shows the next ten that will actually arrive.

## Shortcuts

Shortcuts can do what an app can't: notice another app opening or closing, react to Wi-Fi, NFC, a Focus or
an alarm, and run system actions (Color Filters, Set Focus). Productium supplies small intents for that:
**Pause Before Scrolling** (iOS 26: background, foregrounds itself only when a pause is due), **Should I
pause?** (the iOS 17–18 form with If + Open URLs), **Closed a Distracting App** (ends the scroll session,
counts the minutes), **What's the Plan Now?** (Focus, Break, Busy, Free, Wind-down, Sleep), **Is It
Screens-Off Time?** (a yes/no for If), plus Check in, Start focus, Tell Productium and Log mood. Settings →
Shortcuts & Automations has each recipe as numbered taps with the exact Shortcuts wording in bold.

## AI cost

- Only output tokens are counted (meter, budget, chart, receipts).
- One table decides model and effort per feature (`AIFeature.route`): the Inbox, screenshots, flashcards, short
  reads, project steps and the weekly note run on **Sonnet at low effort**; the **reflection** (and the belief
  groups it may propose) runs on **Opus at medium effort**. Effort is sent as `output_config.effort`. Opus calls
  have their own line in AI Usage ("Opus · reflection") and the meter.
- Reflection is the one expensive call, so it's gated: at most once a day, normally one or two a week, only on
  a trigger (a task put off three times, under 50% of planned work done three days running, the weekly review, or
  you asking "why do I keep putting things off?"), skipped over budget, and paused for a week after you reject two
  runs. Everything it produces is a proposal that waits for your approval.
- Measured on the app's own prompts, Sonnet 5.5 wrote 8.1k output tokens against Haiku 5.5's 14.4k, because
  Haiku's thinking can't be turned off. Haiku 4.5 isn't used.
- The Inbox is one conversation (below), so the prompt cache carries most of its input.
- System prompts are constants; variable data goes in the user turn.
- Flashcards and short reads are generated when gap mode opens, not on every launch, in small batches.
- Screenshots are sent at ≤1280 px (image tokens scale with pixels).
- Every request has a `max_tokens` close to what it needs.

## The Inbox is one conversation

The Inbox is a single ongoing AI session until you press Clear (`Conversation.swift`). Every prompt continues
it, so the AI still has every earlier prompt and reply.

- Each turn keeps what you typed and attached **verbatim** (shown as your bubble), the assistant's reply exactly
  as returned, and what was applied (changes, problems, Undo). History is resent byte for byte, and the last
  answer is a forced tool call, so claude-server continues the live session and reads the prompt cache.
- The **full app context goes in the first user turn**. Later turns carry only a delta ("since your last
  message: …"), or the full context if the delta would be bigger.
- **Clear · 14.2k tokens** always shows what the next prompt will carry (latest request's input + cache read +
  cache write), with the output total in small text. It turns **red once the cache has expired** (15 minutes, the
  server's tool-session TTL) and says what that costs. Nothing clears on its own. Clearing archives the
  conversation; Settings → Past Prompts lists, searches, resumes and deletes them.
- The **draft** (text and images) survives tab changes, backgrounding and relaunch: text in the app state,
  images as files under `drafts/`. It clears only after a successful send.

## What it knows about you

- **`about-me.md`** (Documents, included in backups) has Stated, Inferred, Patterns and Preferences sections.
  Settings → About You is a plain text editor, and a line you edit is marked `(you)` and never overwritten. The box
  may only append to Stated. Inferred and Patterns lines come from the reflection job. Every request includes it.
- **Beliefs** (`Beliefs.swift`, shown in Settings → What Productium Thinks) hold every assumption the planner
  uses: routine durations, sleep, study capacities, focus and break length, dinner. Each has a value, a
  confidence (**Assumed**, **You said**, **Learning** 1–2 samples, **Learned** 3+, **Confirmed** when what you said
  matches the data), a sample count and its evidence, with Correct… (opens the Inbox pre-filled) and Reset. What you
  say is the prior until three real samples exist, then the median takes over, and a "you said 25, it's been 14
  lately" note appears. The arbitrary steppers that used to feed the planner (max study minutes, minimum free
  time, block and break length, dinner, chronotype, screen-time goal) were removed; `CapacityLearner` learns
  them from planned-vs-done history, shrunk toward cold-start priors.
- **Routines learn the moment a pair completes**, not the next day. Repeat markers for the same transition
  within three minutes (a voice "left home" and two geofence ones) merge into one, keeping the earliest time and
  best source. Marker categories come from the activity name (`to_school` is travel, `in_bed` is sleep), never a
  blanket "free".
- **Sleep without a tracker** (`SleepEstimator`): Health samples first, then check-ins (`in_bed`/`sleep start` to
  `wake`), then overnight stillness plus no phone use, then the plan. The Sleep card says where the number
  came from. Health status is three states (not asked, connected with no sleep source, connected with
  sleep) because HealthKit never reveals whether read access was granted.
- **Motion** (`MotionService`, the free build too): `CMMotionActivityManager` history becomes spans, and
  vehicle/cycling/walking spans of five minutes or more become Travel in the day, below explicit check-ins and
  above routine assumptions. A morning walk teaches `to_school`. Only how long you moved is kept, never where.
- **Mystery gaps**: 40+ minutes with nothing explaining them are asked about while still fresh, in one line from
  the lock screen, at most four a day and never in wind-down or focus.
- **Places learn themselves**: saying you're at school offers to save it; repeat visits (`CLVisit`, with Always)
  propose a place and ask what it's called. Location asks for When In Use first and escalates to Always once.
- **Scrolling** has its own category. Which apps count is your list (Settings → Screen Time → Scrolling Apps),
  never the model's guess. Shortcuts sessions are exact; Screen Time screenshot minutes are carved out of free time
  as estimates. A screenshot is validated in code: scrolling is recomputed from the apps, a total that the apps
  exceed is flagged "doesn't add up", a week view is stored as an average, and several screenshots of one day
  merge per app. Sessions record which app, end on any of several signals (another app opens, charger,
  alarm, Focus, Productium opening, a "no, I stopped" check-in), and an open session with no signal is credited
  your median length for that app (capped at 30 minutes), marked estimated. Screenshots calibrate a per-app
  over-count factor.

## Three operations, three risk tiers

The box no longer has a hand-written action per power. It has three operations over a typed registry
(`Capabilities.swift`): `upsert(entity, id?, fields)`, `delete(entity, id)` and `set(knob, value)`, plus
macros that expand into them (splitting an activity). Each entity and knob declares its fields, bounds and a tier:

| Tier | What | Who may change it | Guard |
|---|---|---|---|
| 0 · data | tasks, events, markers, progress, colours, stated facts | the box (Sonnet) | applied at once, Undo |
| 1 · learned values | routine samples and stated values, study capacity, scrolling apps | the box only from your explicit statement; otherwise the learners | marked stated vs learned |
| 2 · behaviour | planner policy, nudge rules, new belief groups, restructuring avoided tasks | the Opus reflection only | **proposed, never applied until you approve**; bounded, logged, revertible |

Every Tier 2 knob has a hard range and a maximum step per change, at most three change per reflection and one per
knob per week. Proposals appear as one card on Today ("Productium suggests 2 changes") with Approve, Reject and
"Never change this", and Approve All / Reject All per run. Rejected or reverted proposals are fed back so they
aren't proposed again. Reflection can't touch what you wrote (titles, due dates), sleep need, the sleep floor
or the trade-offs toggle. Progress is absolute (`doneMinutes`), so re-stating "200 minutes so far" twice leaves 200.
Each task counts how often it was put off (snoozed, can't today, skipped, never started, due date moved later)
and shows "Put off 3×".

## What gets planned

- **Work done** has one source: finished blocks and focus sessions, study check-ins, and progress told to the
  box, with overlapping time counted once. What was planned for each finished day is kept (`planHistory`, 60 days)
  so planned-vs-done works without "how did it go?" answers. Review covers today so far plus the previous six days.
- **At-school errands** ("ask psych teacher…", or the `atSchool` flag) get a slot inside school hours (a lunch or
  break period if the timetable names one) and a reminder, not a study block.
- **A school timetable is the periods of the School activity**, never separate one-off events. Events that overlap
  80% on the same day with a similar title are one event; a calendar event that is one of your activities (CS club)
  shows once, as the activity; a day change that changes nothing is refused.

## Colours

Stored as strings (a system colour name or `#RRGGBB`) on tasks, activities and events, with category
defaults in `Preferences.colors` (`study`, `free`, `school`, `subject:math`, `task:test`…). The planner
stamps each block with its resolved colour (`Palette.paint`), most specific first: the task's own, its
project's, its subject's, its type's, then the category; for activities their own, then their kind's.

## Reading replies

A reply is read in three layers (`Reply.swift`), each accepting anything the one before can produce:
the message in any shape (text, a tool call's arguments, a bare string); the JSON wherever it is and
however it's written (fences, prose, single or curly quotes, unescaped quotes, trailing commas, a reply
cut off mid-way, where half-written actions are left out); then the value fitted to the schema (keys in
any spelling, values converted to the declared type or dropped, required fields filled, wrappers
removed). The fitted value always decodes; fuzz tests hold that for every schema. The Inbox also takes
a list of actions, one action on its own, or plain prose, which becomes the reply. A reply with nothing
usable at all (empty) is asked for once more before the receipt reports it.

## Backup

Settings → Backup & Restore writes one JSON file (`format: productium-export`, version 3) holding **every byte the
app keeps**: the full state (including plan history, motion spans, scroll sessions, draft), `about-me.md`, the
active conversation and the whole archive with images and what was applied for each prompt, the whole AI call
log, usage records, Shared defaults (scroll log, friction, check-ins), other stored files, pending and delivered
notifications, permission statuses, and the app version, iOS version, device and time zone. Nothing is pruned
before export. The API key stays in the Keychain and is never written out. Restore previews the file and asks
before replacing anything; the current data is saved as `state-before-restore.json` first. Earlier formats are
not read. A test checks every stored property of `AppState` is in the export.

## Builds and releases

`core-tests` and `ios-compile` run on every push and pull request. The free-account IPA and the GitHub release
are made **only on a push to `main`**, after both pass, by one job with `concurrency: release` so two merges
can't race. The version is `v1.0.0` when no `v*` tag exists; otherwise it's bumped from the latest tag using the
commits since (Conventional Commits: `BREAKING CHANGE` or `!:` is major, `feat:` is minor, anything else patch).
`MARKETING_VERSION` is that version and `CURRENT_PROJECT_VERSION` is the run number. The IPA is attached as
`Productium-free.ipa`, so `…/releases/latest/download/Productium-free.ipa` always points to the newest build.
The app shows its version and build under Settings → Keeping It Installed and checks the public releases API once
a day (nothing about you is sent).

## What changed from v1 to v2 (and why)

- Cards, pill chips, capsule toasts, a floating + button, rings and segmented pickers: removed. They're the
  generic "SaaS kit" look, and each was a decision or a thing to look at.
- Insights went from six chart panes plus a range picker to one screen (note, strips, three sentences).
- Quick-add sheet, coach chat, mood picker and forms: removed. The box does all of them, including questions.
- Editing forms are gone. Corrections are typed ("move the essay to friday", "didn't go to school today"),
  and every change shows what it did, with Undo.
