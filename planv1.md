# Productium plan v1

Two inputs went into this plan: the feedback from 17 Nov, and the backup `Productium Backup 2026-11-17 2.json` (app 1.0, exported 13:28Z).
Each task is small enough for one agent session. Each one is tagged with:

- **Build:** which coding agent should implement it.
  - **Opus** (`claude-opus-5-5`): structural changes, new data models, cross-cutting refactors, anything that needs judgement about the design.
  - **Sonnet** (`claude-sonnet-5-5`): well-defined changes with a clear spec and acceptance test.
- **Runtime:** which model the *app* calls for that feature. Only listed when the feature uses AI.
  - `sonnet`: the default for every user-facing call (the box, screenshots, follow-ups).
  - `opus·medium`: rare, high-risk calls that change how the app behaves (see §3). The cost is noted on every such task.
  - `none`: deterministic code on the phone.

Rules for every task: keep `swift test` green on Linux, add tests for any new logic in ProductiumCore, and make no commits or pushes unless asked.

**This is pre-v1, so breaking changes are fine.** Change data models, rename or delete fields, drop action types and replace screens freely. There is no migration code, no backward-compatible decoding, no aliases for old actions, and old tests are rewritten or deleted rather than kept passing. The one place old data matters is the **last task, T9.1**: once the app is done, Opus converts your current backup into the new format and corrects everything in it that doesn't make sense.

The B-rows below are the bugs to fix in code. The tests for them are written in the new data model (T0.2), not loaded from the old backup.

---

## 0. What the backup shows (ground truth for the bugs)

| # | Symptom you saw | What's actually in the data / code | Fixed in |
|---|---|---|---|
| B1 | Routine didn't learn the walk to school | Markers today: `to_school start 13:02 (voice)`, two duplicate geofence `left home` at 13:07:58 and 13:08:16, `to_school end 13:16 (voice)`. `RoutineLearner` only runs on **finished days** (`learnFromPastDays`, `1...7`), so today's 14 min isn't learned until tomorrow. The samples `[18,18,18]` are a fake: `.routine` action writes `Array(repeating: m, count: 3)`, which makes a stated guess look "learned". | T4.1, T4.2 |
| B2 | Sleep not updated | `health` has **steps only, no sleep** (nothing on the phone records sleep). Your voice markers `in_bed 00:59` and `sleep end 07:25` are never used for sleep: the AI wrote `activity: "in_bed"` (not `sleep`), category `free`, and the Review sleep card reads only `health.sleepMinutes`. | T4.3, T2.1 |
| B3 | "Health is on but the app thinks it isn't" | Review shows "Turn on Health in Settings" whenever sleep is nil, even though `integrations.health = true`. HealthKit never tells an app whether *read* access was granted, so "no sleep data" ≠ "Health off". Onboarding also sets `health = available`, whatever you actually answered. | T2.1 |
| B4 | No "Always" location prompt | `LocationService.requestAlways()` calls `requestWhenInUse` and then `requestAlways` **immediately**. iOS ignores the second call while the first prompt is up, so you only ever get "While Using". There's no delegate callback to escalate, no status shown in Settings, and no School place (only Home is saved), so arriving at school can't be detected. | T2.2, T2.3 |
| B5 | Work card / Review empty | `outcomes` is empty and `learned.adherenceSamples = 0`. "Planned" is computed from outcomes only, so a day without "how did it go?" answers shows "Nothing planned". Past plans aren't kept, so planned-vs-done can't be computed after the fact. Box progress ("wrote two drafts") updates `completedMinutes` but never counts as work done that day. | T4.4, T4.5 |
| B6 | "Your Week" stale | `lastDays` is `1...7` (excludes today). AI-logged markers default to category `free`, so `to_school` paints as Free, not Travel. An open `in_bed` paints 2 h of "In_bed" free time. Scrolling is never drawn in the strips. | T4.5, T4.6, T2.6 |
| B7 | Screen Time from screenshots is wrong | Stored for 16 Nov: total **202**, but the apps add up to **278** (Firefox 97, Instagram 96, Slack 50, Discord 35). `distractingMinutes` **68**, but Instagram + Discord = **131**. The applier trusts whatever `distractingMinutes` the model sends over the app list, and nothing checks that the numbers agree or what period/day the screenshot shows. | T2.5, T2.6 |
| B8 | Prompts "lost to a void" | `chat` is capped at 12 messages. History is only sent if the last exchange was < 2 h ago, and then only 6 messages. Nothing from a prompt is kept as knowledge about you. | T1.1–T1.4 |
| B9 | Progress double-counted | Chat says "logged about 200 minutes", then "kept your 200 minutes", but the University item has `completedMinutes: 400`. `progressMinutes` is additive, so a re-stated number is added twice. | T0.3 (code), T9.1 (data) |
| B10 | Duplicate school periods | `oneOffs` holds two overlapping sets for 17–20 Nov ("P1 Math" *and* "Math (P1)", "P3 English" *and* "English + Data Mgmt"…), and the labels disagree (Wed/Fri "Math (P2)" vs "P1 Math"). They're one-off events on top of the `School 8:26–14:46` activity. Duplicate checks only match exact title + date. | T0.4 (code), T9.1 (data) |
| B11 | Noise rows | 5 `exceptions` of kind `school` with `cancelled: false` that change nothing. CS club appears twice: the activity Thu 10:56–12:15 and the Google Calendar "CS Club Meeting" Thu 11:10–12:00. | T0.4 (code), T9.1 (data) |
| B12 | Text in the box disappears | `TodayView` holds the draft in `@State text` and `images`, which are lost when the view is rebuilt. | T1.5 |
| B13 | Arbitrary settings | `maxStudyMinutesSchoolDay 180`, `maxStudyMinutesFreeDay 300`, `minFreeMinutes… 60/180`, `focusBlockMinutes`, `breakMinutes`, `dinner`, `chronotype` and `screenTimeGoalMinutes` are steppers you have to guess. The planner uses them directly as caps. | T4.7, T4.8 |
| B15 | Scrolling counted as still going after you lock the phone or go Home | In the free build, sessions come from Shortcuts: "App is opened" calls `Friction.opened()` (sets `openedAt`), and "App is closed" calls `Friction.closed()`. "Is closed" only fires reliably when you switch apps from the app switcher, not when you go Home or lock. Then `openedAt` stays set: the session is counted until the next close or until the 90-min `sessionCap`, so it can over-count by up to 90 min a session. The "still scrolling?" check-ins also keep firing on the lock screen. Sessions don't record *which* app, so Instagram → Discord is one session. | T2.8 |
| B14 | Task you can't do in study time | "Ask psych teacher for recommendation" (10 min, due 3 pm today) raises a *critical* "doesn't fit" warning, because chores that happen **at school** are only placed in study blocks. The warning also says ≈15 min for a 10-minute task. | T0.5 |

---

## 1. Conversations and memory (nothing you type is lost)

The Inbox box is **one ongoing AI session**. Each new prompt continues it, so the AI still has every earlier prompt and reply until you clear it. Your prompts are shown clearly as yours: what you typed, exactly, in the thread, never mixed into the app context the AI also receives. Cleared conversations are archived under "Past prompts", and every prompt also feeds the knowledge layer (§2).

**T1.1 One box = one AI session.** Build: **Opus**. Runtime: `sonnet`.
- New `Conversation { id, messages: [ConversationTurn], startedAt, lastRequestAt, tokenStats }`. Each `ConversationTurn` has the user's text and images, the assistant's reply exactly as returned, what was applied, and the call id. There is also a `ConversationArchive`.
- Delete `state.chat`, `chatAt` and the 2-hour, 6-message window. The whole active conversation is sent every time.
- **Continue the claude-server session exactly** (its rule 3): history goes back byte-for-byte unchanged, including the assistant `content` as it came back, and only the new user turn is appended. The server then continues the same live session and reads the prompt cache instead of re-sending.
- App context: the full context goes in the *first* user turn of a conversation. Later turns carry only a **delta** ("since your last message: task t3 completed, now 15:42, block b7 started…"). That keeps the history stable and the cache valid. If the delta would be bigger than the full context, send the full context instead.
- Thread view on Today: your prompts as right-aligned bubbles with the exact text and thumbnails; the AI's reply under each, with its receipt (changes, Undo, Prompt). Collapsed to the last exchange, expandable to the whole conversation.
- Done when a 20-turn conversation replays exactly, cache reads appear in `UsageRecord` for turns 2 to 20, and the thread shows every prompt verbatim.

**T1.2 Clear button: token count, red when the cache has expired.** Build: **Sonnet**. Runtime: none.
- A Clear button next to the box always shows the conversation's size, e.g. `Clear · 14.2k tokens`. That is the latest request's input + cacheRead + cacheWrite, which is what the next prompt will carry. Its output total is shown under it in small text.
- **It turns red once the prompt cache has expired.** That's 5 minutes after the last request, or 1 hour if the conversation is sent with the `ttl: "1h"` cache marker. Pick the TTL in T1.1 from what claude-server supports; 1 h is the likely choice for a box you come back to. A small line explains what red means: "Cache expired. Your next message re-reads all 14.2k tokens. Clear to start fresh, or keep going to keep the context." The decision stays yours: red is a signal, nothing clears on its own.
- Clearing moves the conversation to the archive with a one-line title and starts a new session.
- Done when the count matches the last `UsageRecord`, the button goes red at the TTL (a test with an injected clock), and clearing starts a new server session.

**T1.3 Past prompts screen.** Build: **Sonnet**. Runtime: none.
- Settings → AI → Past Prompts lists archived conversations, newest first, each with its date, title and token count.
- Open one to read every prompt, reply and applied change. Resume makes it the active conversation again; you can also Delete. Search covers the text.

**T1.4 Every prompt teaches the app.** Build: **Opus**. Runtime: `sonnet` (inside the existing box call, so no extra request).
- Add optional outputs to the box schema:
  - `facts`: new or changed lines for `about-me.md` (T2.0).
  - `evidence`: timestamped observations such as "left 8:02, arrived 8:16", "worked ~200 min on Waterloo drafts", "was at CS club 11:10–12:00".
- The applier routes evidence to markers, routines and work done (T4.x) instead of letting it fall through as reply text.
- Done when "i left at 8:02 and got to school 8:16" adds one routine sample and one Travel segment, and "i've written two drafts" counts as work done today.

**T1.5 Drafts survive navigation.** Build: **Sonnet**. Runtime: none.
- Move the box's text and attached images into `AppModel.draft`, saved with the state (images as files under `drafts/`).
- Restore on appear. Clear only after a successful send.
- Done when you can type, switch tabs, background the app, kill and relaunch, and the text and images are still there.

---

## 2. What the app knows about you

### T2.0 `about-me.md`: user facts. Build: **Opus**. Runtime: `sonnet` writes stated facts; `opus·medium` writes inferred ones.

- A markdown file on the device (`Documents/about-me.md`), included in the export (T0.6). It has sections the AI keeps tidy:
  - `## Stated` (things you said)
  - `## Inferred` (each line ends with `— evidence: …, confidence: low/med/high, since 2026-11-17`)
  - `## Patterns` (behaviour, e.g. "puts off university essays: deferred 3× this week")
  - `## Preferences`
- **Editable in Settings → About You** with a plain text editor. Your edits always win: the AI may append or propose, but a line you changed is marked `(you)` and is never overwritten.
- Every AI request includes it (it goes in the user turn, so caching still works). When the AI is missing information it consults this file first, then asks.
- Sonnet may only append to `Stated` (what you literally said). Writing `Inferred` or `Patterns` lines is reserved for the Opus reflection job (T5.2).
- Seeding it from your current chat happens in the data repair (T9.1).
- Done when: the file round-trips through export and import, a user-edited line survives an AI update, and the box context includes it.

### T2.1 Health status that tells the truth. Build: **Sonnet**. Runtime: none.
- Separate three states:
  - **Not asked**: `getRequestStatusForAuthorization` says it's needed.
  - **Connected, no sleep source**: steps arrive but no sleep samples.
  - **Connected with sleep.**
- Replace "Turn on Health in Settings" with the right message for each state. For yours: "Health is connected, but nothing on your phone records sleep. Productium estimates sleep from your check-ins and phone use (T4.3). For measured sleep, turn on Sleep Schedule in the Health app or wear a Watch."
- Onboarding stores what actually happened, not `available`.
- Done when a test state with steps but no sleep shows the "no sleep source" message, not "turn on Health".

### T2.2 Location "Always", done properly. Build: **Sonnet**. Runtime: none.
- Request When In Use first. Then, in `locationManagerDidChangeAuthorization`, escalate to `requestAlwaysAuthorization` once it's `.authorizedWhenInUse`. Persist that the escalation was asked so it isn't repeated.
- If iOS still reports When In Use, Settings → Places shows "Only While Using. Open Settings → Location → Always" with a deep link.
- Add `location` to `UIBackgroundModes` only if T2.3's visit monitoring needs it. Check Apple's docs first, because region monitoring doesn't.
- Done when a fresh install shows both prompts and Settings displays the real status.

### T2.3 Places that learn themselves. Build: **Sonnet**. Runtime: none.
- When a check-in says "at school" (or any `*_end` marker at a named place) and there's no saved place by that name, take one location fix and offer "Save this as School?". Saying yes creates the geofence.
- Use `CLVisit` monitoring (with Always) to propose frequent places.
- Merge geofence and voice markers for the same transition within 3 min (B1's duplicates) into one marker, keeping the earliest time and the best source.

### T2.4 Motion and transit. Build: **Opus** (new service plus timeline layer). Runtime: none; the AI only sees summaries.
- `MotionService` uses `CMMotionActivityManager.queryActivityStarting` (iOS keeps 7 days of history, so it works even when the app wasn't running) plus `CMPedometer`. It produces `MotionSpan { start, end, kind: walking/running/cycling/automotive/stationary, confidence }`.
- Turn spans into inferred timeline segments: automotive or cycling of 5 min or more becomes **Travel** (category `commute`, label "In a vehicle" / "Cycling"); walking of 5 min or more between places becomes **Walk / Travel**; a long stationary span overnight backs up sleep (T4.3).
- Spans are evidence, not truth. They paint below explicit check-ins and above routine assumptions. A walk that lines up with a school morning is fed to `to_school` as a sample with source `motion`.
- Add `NSMotionUsageDescription` and a Motion toggle in Connections. No entitlement is needed, so this works on the free build.
- Done when a fixture of motion spans plus markers produces the expected segments, and a morning walk teaches `to_school`.

### T2.5 Screen Time screenshots read correctly. Build: **Sonnet**. Runtime: `sonnet` (same box call).
- Extend the `screen_time` action:
  - `period` (day / week / daily average) and `dateLabelShown` ("Today", "Yesterday", "Mon 16 Nov").
  - `totalMinutes`, and per app `{name, minutes, category shown}`.
  - `partial: Bool` (true when the list is cut off).
- Validate in code, not in the prompt:
  - Distracting minutes are always recomputed from the apps × the scrolling-app list (T2.6). The model's number is ignored.
  - If the apps add up to more than the total, the entry is flagged "doesn't add up". The receipt shows the numbers and asks for a correction.
  - A week or average screenshot is stored as an average, never as a single day.
  - Several screenshots of the same day merge per app (max per app), instead of replacing each other.
- The receipt shows exactly what was stored: "Mon 16 Nov: 3 h 22 total, scrolling 2 h 11 (Instagram 1 h 36, Discord 35)".
- Done when the B7 screenshot data re-applied gives scrolling 131, and the 202/278 mismatch is flagged.

### T2.6 Scrolling apps. Build: **Sonnet**. Runtime: none.
- `state.scrollingApps: [String: Bool]` (app name → scrolling or not), editable in Settings → Screen Time → Scrolling Apps. Every app ever seen in a screenshot or Shortcut is listed with a toggle.
- New apps get a default: social, video and games are on; the user decides about browsers.
- This list, not the model's `distracting` flag, decides what counts as scrolling.
- In Your Week, Review and the AI context, scrolling minutes show as their own **Scrolling** category:
  - Shortcuts open/close sessions are time-stamped, so they paint exact segments.
  - Screenshot minutes have no timestamps, so they're carved out of free time and labelled "estimated".
- Done when Instagram and Discord count as scrolling, Firefox and Slack don't, and the week strip shows purple for scrolling.

### T2.8 Scroll sessions that end when you actually stop. Build: **Opus** (the session model and the estimation policy) + **Sonnet** (the Shortcuts recipes and the guide text). Runtime: none.
The free build can't see screen lock or Home directly, so a session has to be ended by any of several signals, and a session with no clear end has to be *estimated*, never assumed to have kept running.
- **Session model:** `ScrollSession { app, openedAt, endedAt?, endSource: closed/otherApp/productium/checkInIgnored/lockProxy/estimated/cap, confirmedUntil? }` replaces the single `openedAt`. It records which app (the intent takes an app parameter, filled per automation). Opening scrolling app B ends app A's session at that moment.
- **More end signals, all through Shortcuts automations that fire reliably** (the guide gets new recipes):
  - "When *[non-scrolling apps you use: Messages, Safari, Camera, Slack…]* is opened → Closed a Distracting App". Opening any other app ends the session.
  - Charger connected, an alarm stopped, and a Sleep, Work or Driving Focus turning on.
  - Productium coming to the foreground, or any Productium intent running.
- **Check-ins as a probe:** the "still scrolling?" check-in gets Yes / No, I stopped buttons.
  - Yes sets `confirmedUntil = now`.
  - No, or no answer before the next check-in, ends the session at the later of the last confirmed time and open + the typical session length.
  - If unanswered, the remaining check-ins for that session are cancelled, so they stop firing on a locked phone.
- **Estimating a missing end:** credit the median length of your sessions with an observed end for that app (prior 8 min, capped at 30 instead of 90). The minutes are marked `estimated` and drawn hatched in Your Week.
- **Calibration:** when a Screen Time screenshot exists for a day (T2.5), it is the truth. Compare it with the Shortcuts total, store a per-app correction factor as a belief ("Shortcuts over-counts Instagram ~1.4×", shown on What Productium Thinks), and apply it to days without screenshots.
- **Guide fix:** the Shortcuts guide says plainly that "is closed" may miss Home and lock, and why the extra automations matter.
- Done when tests cover: a session with no close, then a lock-screen check-in ignored, is credited ≤ the estimate rather than 90 min; opening Messages ends an Instagram session; app A → app B is split correctly; and the screenshot calibration factor is applied.

### T2.7 "What were you doing?" prompts. Build: **Opus** (detection policy plus notification plumbing). Runtime: local parser first, `sonnet` only if it can't parse.
- Detector: a **mystery gap** is 40 min or more with:
  - no observed segment (no marker, no study outcome, no motion span, no scrolling session)
  - no scheduled commitment, and not sleep
  - and you're awake (phone used or steps moving).
- Ask **while it's still fresh**: at gap end + 10 min, or 45 min into a gap that's still going. Never later than 2 h after it started; older gaps stay unknown instead of guessed.
- Limits: at most 4 a day, none in wind-down or sleep, none during focus.
- Delivery: a notification with `UNTextInputNotificationAction` ("What were you doing 3:10–4:05?") so you answer in one line from the lock screen. If the app is open, a small banner over Today does the same.
- The answer becomes a marker pair for that window. Known phrases go through `MarkerParser` on the device; anything else goes to the box as one Sonnet call with the window attached.
- Repeated answers ("gym" on Tuesdays at 4) become a candidate routine group (T4.9).
- Done when tests cover the gap detector (thresholds, freshness limit, daily cap) and a lock-screen reply adds the right segment.

---

## 3. A general AI power model (no more one-off actions)

**T3.1 Capabilities with risk tiers.** Build: **Opus**. Runtime: sets the rules for every AI call.

Today every power is a hand-written action type (`split_activity`, `set_color`, `settings`…). Replace the growing list with three general operations over a typed registry of what the AI is allowed to change:

| Operation | What it does | Examples |
|---|---|---|
| `upsert(entity, id?, fields)` | create or update any registered entity | task, activity, event, day change, marker, place, routine, belief |
| `delete(entity, id)` | remove one | |
| `set(knob, value)` | change a registered tunable | planner, nudge and learning parameters |

Each entity and knob in the registry declares its fields, bounds and a **risk tier**:

| Tier | What | Who may change it | Guard |
|---|---|---|---|
| **0 · data** | tasks, events, markers, progress, colours, stated facts | box (`sonnet`) | applied at once, Undo |
| **1 · learned values** | routine samples, estimate ratios, study capacity, scrolling apps | box (`sonnet`) only from your explicit statement; otherwise the learners | marked `stated` vs `learned` |
| **2 · behaviour** | planner policy (block length, spacing, how hard to push, when to schedule what), nudge rules, new belief groups, plan restructuring for avoided tasks | **`opus·medium` only** | **proposed, never applied until you approve** (T3.3); bounded drift, logged, revertible |

The old action types (`split_activity`, `set_color`, `settings`, `change_day`…) are deleted, along with their prompt text and tests. Only things that really are compound operations, like splitting an activity, stay as registered **macros** that expand into `upsert`/`delete`. The Tier 2 tunables are drawn from what Planner, NudgePlanner and the learners already read, so adding a behaviour later means registering a knob, not writing a new action.

Done when: the box schema is the three operations plus macros, AgentTests are rewritten against them, and a Tier 2 `set` from a Sonnet call is refused with a problem line.

**T3.2 Model routing.** Build: **Sonnet**. Runtime: n/a.
- Add `AIModel.opus = "opus"`, and an `effort` field on `AIRequest` sent as `output_config.effort` (claude-server passes it through).
- A `feature → (model, effort)` table:
  - box, screenshot, flashcards, reads: `sonnet` / low
  - reflection (T5.2) and belief-group creation (T4.9): `opus` / medium
- Opus calls get their own line in AI Usage and the token meter: "Opus · reflection".

**T3.3 Bounded behaviour changes.** Build: **Opus**. Runtime: enforced in code.
- Every Tier 2 knob has a hard range and a **max step per change**, e.g. block length 20–60 min with at most ±10 per change, and the daily study capacity multiplier 0.6–1.3 with at most ±0.1.
- At most 3 Tier 2 changes per reflection run, and at most one change to the same knob per 7 days.
- **Every Tier 2 change waits for your approval.** Opus writes a `BehaviourProposal { knob/entity, from, to, reason, evidence, model, at }`. Nothing about how the app behaves changes until you tap **Approve**.
  - Proposals show as one card on Today ("Productium suggests 2 changes") and in Settings → What Productium Thinks → Changes. Each has Approve, Reject, and "Never change this" to pin a knob.
  - You can approve a run's proposals all at once or one by one. Pending proposals expire after 7 days.
- Approved changes go to the same Changes list with Revert.
- A rejected or reverted proposal is fed back as evidence, so it isn't proposed again.

---

## 4. Learning, shown honestly

**T4.1 Learn routines the same day.** Build: **Sonnet**. Runtime: none.
- Run `RoutineLearner` incrementally as soon as a start/end pair for a routine is complete, not only for finished days. Keep `learnedDays` only to stop the same pair counting twice: store the learned marker ids instead of day keys.
- Pair rules: the earliest `start` of any source is matched with the first `end` after it. Geofence and voice duplicates are merged first (T2.3).
- Done when the B1 markers (voice 13:02 start, two geofence starts, voice 13:16 end) give `to_school` exactly one 14 min sample the same day, and replaying them doesn't add it twice.

**T4.2 Stated vs learned samples.** Build: **Sonnet**. Runtime: none.
- `Routine` gains `stated: Int?` (from "walk to school is 25 min") separate from `samples`. The stated value is the prior until 3 real samples exist, then the median takes over; a "you said 25, it's been 14 lately" note appears.
- The `.routine` action's "write the number three times" behaviour is deleted. Your current fake samples are fixed in T9.1.
- Confidence shown everywhere: **Assumed** (default), **You said**, **Learning** (1–2 samples), **Learned** (3 or more), **Confirmed** (you said it and the data agrees).

**T4.3 Sleep without a sleep tracker.** Build: **Opus**. Runtime: none.
- `SleepEstimator` merges, best source first:
  1. HealthKit sleep samples.
  2. Check-ins: `in_bed` / `sleep start` / `going to bed` → `wake` / `sleep end`. Normalise AI-logged activity names through `MarkerParser`'s vocabulary so `in_bed` means sleep start.
  3. Overnight motion `stationary` plus no phone use (last app use / first unlock comes from the scroll log and the app's own launches).
  4. The plan (assumed).
- Output: `HealthDay.sleepMinutes`, `bedtime` and `wake`, plus a `sleepSource`. The Sleep card says "6 h 26 min · from your check-ins".
- Done when markers `in_bed 00:59` + `sleep end 07:25` produce 6 h 26 for that night, and the planner's short-night logic uses it.

**T4.4 Keep what was planned.** Build: **Sonnet**. Runtime: none.
- When a day ends (or on the first replan after midnight), snapshot that day's study blocks into `state.planHistory[day]`, keeping 60 days.
- The Work card's "planned" reads from it, so days without "how did it go?" answers still show planned minutes.

**T4.5 Work done comes from everything.** Build: **Sonnet**. Runtime: none.
- Work done for a day = focus sessions + block outcomes + progress logged through the box that day (`completedMinutes` deltas with a timestamp, kept as `ProgressEntry`) + study markers.
- Review, Your Week and `DayTotals.doneStudy` use this one source.
- `lastDays` becomes "today so far plus the previous 6", with today's strip ending at the now line.

**T4.6 Markers get the right category.** Build: **Sonnet**. Runtime: none.
- The applier never defaults to `free`. It infers the category from the activity name (`to_school`/`from_school` → commute, `sleep`/`in_bed`/`wake` → sleep, `get_ready` → routine, a commitment's name → that commitment's kind, study words → study), and only then from the model's value.

**T4.7 Remove the arbitrary settings.** Build: **Opus** (touches Planner, settings, AI review schema and prompts). Runtime: none.
- Remove from the UI and from AI control:
  - `maxStudyMinutesSchoolDay`, `maxStudyMinutesFreeDay`, `minFreeMinutesSchoolDay`, `minFreeMinutesFreeDay`
  - `focusBlockMinutes` and `breakMinutes` (the learned `focusMinutes` already exists)
  - `dinner` / `dinnerMinutes` (becomes a learned routine)
  - `chronotype` (inferred: `inferredChronotype` exists)
  - `screenTimeGoalMinutes` (the taper derives it from your baseline)
  - Wake time pickers when Auto Wake is on.
- Keep real preferences and values: nudge level, sleep trade-offs on/off, school days, term dates, colours, and sleep need. Sleep need defaults to 9 h for teens and is only changed by you or by Opus with evidence.
- Replace each removed value with a learned belief (T4.8). Delete the fields from `Preferences` outright.
- Done when StudySettings is gone and the Planner reads capacities from `Beliefs`, with today's defaults as cold-start priors.

**T4.8 Learned capacities.** Build: **Opus**. Runtime: none.
- `CapacityLearner` learns from history (T4.4 and T4.5):
  - school-day and free-day study you actually complete (75th percentile of the last 3 weeks, shrunk toward the prior while there are few days)
  - free time you protect (the evening free time on days you followed the plan)
  - focus length, break length and dinner time.
- Each is a `Belief` with value, confidence, sample count and evidence, and the planner reads these.
- Done when 3 weeks of fixture days produce caps that move toward observed behaviour within bounds.

**T4.9 "What Productium Thinks": one page for every assumption.** Build: **Opus** (generic model) and **Sonnet** (the UI). Runtime: `opus·medium` may create new groups.
- A generic `Belief { group, key, label, value, unit, confidence (assumed/stated/learning/learned/confirmed), samples, evidence: [String], source, updatedAt, bindsTo: knob? }`. Routines become the first group of this model.
- The settings page **Settings → What Productium Thinks** replaces Routines. It has one section per group:
  - **Routines** (get ready, to school, home from school, dinner…)
  - **Sleep** (usual bedtime and wake on school/free days, need, chronotype)
  - **Study** (capacity per day type, focus length, best hours, how much longer each kind of task takes than estimated)
  - **Places**, **Scrolling** (which apps, usual amount)
  - **Patterns** (from `about-me.md`)
  - plus any group Opus creates.
- Each row has the value, a confidence chip, "from 5 check-ins", and, when tapped, the evidence list with Correct… (opens the box pre-filled) and Reset.
- Opus may create a group (e.g. "Thursday lunch: CS club", "After-school slump 3–4 pm") only through the Tier 2 path, at most one new group per week. A group needs at least 3 pieces of evidence.
- Design: Settings-style inset list, the same look as the current Routines rows, with "Learned"/"Learning" chips in the caption.

**T4.10 Today and Review use the same knowledge.** Build: **Sonnet**. Runtime: none.
- The weekly note request and the box context both include a compact summary of beliefs and changes.
- `ReviewChanges` (the old `max…` nudges) is deleted. The weekly note can only make Tier 2 proposals, which wait for approval (T3.3).

---

## 5. Behaviour change

**T5.1 Track avoidance.** Build: **Sonnet**. Runtime: none.
- Per task, count:
  - `deferrals`: In 10 Minutes, Can't Today, a skipped outcome, a block that ended without starting, or the due date moved later
  - `lastDeferredAt` and `deferralReasons`, taken from what you typed.
- Show "Put off 3×" on the task row and in the box context.

**T5.2 Reflection job.** Build: **Opus**. Runtime: **`opus·medium`, rare. This is the main token cost, so keep it gated.**
- Triggers, at most once a day and normally 1–2 times a week:
  - any task deferred 3 or more times
  - planned-vs-done under 50% for 3 days running
  - the weekly review
  - you ask ("why do I keep putting this off?").
- Input: `about-me.md`, beliefs, the deferral table, the last 14 days of planned vs done, recent conversation summaries, and the current Tier 2 knobs.
- Output, all through the T3.1/T3.3 guards, and **all of it waits for your approval**:
  - up to 3 Tier 2 proposals, e.g. split the avoided task into a 15-minute starter step, move it to your best hour, shorter blocks for that subject, an implementation-intention nudge ("When you get home Tuesday, open the Waterloo doc")
  - `Patterns`/`Inferred` lines for `about-me.md`
  - at most one new belief group
  - a two-sentence note shown on the proposal card: "You've put off the Waterloo revision 3 times. Make it a 15-minute first step right after school?"
- Skips when over budget. The token meter shows its cost separately. Tests use a recorded reply.
- Evidence base: implementation intentions and task splitting for procrastination. Add the citations to SOURCES.md.

**T5.3 Guard rails for "not deviating too far".** Build: **Sonnet**. Runtime: none.
- Reflection may never touch Tier 0 data you created (titles, due dates), sleep need, the sleep floor, or the trade-offs toggle.
- Each run's proposals appear together, with Approve All and Reject All.
- If you reject two runs in a row, reflection pauses for a week and says so.

---

## 6. Quick fixes and full export

These change code only. Your current data is corrected at the very end (T9.1).

**T0.1 Baseline.** Build: **Sonnet**. Run `swift test` and fix anything red in the current uncommitted work before starting the rest.

**T0.2 Bug tests.** Build: **Sonnet**.
- Write a test per B-row in §0 in plain Swift fixtures built from the scenario in that row (the markers, the screenshot numbers, the duplicate periods…). Each test fails today, and each later task flips its test to green.
- When a task changes the data model, rewrite its fixtures in the new model. Don't keep old-format fixtures alive.
- Copy the raw backup to `scripts/repair/input/backup-2026-11-17.json` (git-ignored) for T9.1 only.

**T0.3 Idempotent progress.** Build: **Sonnet**.
- Progress is absolute: the box sends `doneMinutes`. Delete `progressMinutes`.
- If you say "I did another hour", the model computes the new total from the context. The applier logs each change as a `ProgressEntry { at, from, to, turnId }`.
- Done when re-stating "200 minutes so far" twice leaves 200.

**T0.4 No duplicates, no no-op rows.** Build: **Sonnet**.
- Treat events as duplicates when they overlap ≥ 80% on the same day with similar titles (normalised: "Math (P1)" ≈ "P1 Math"). The second one becomes an update.
- Calendar events that overlap ≥ 80% with an activity of a similar name (CS club) are shown once, with the activity winning.
- Day changes that change nothing (`cancelled: false` and no time changes) are refused by the applier.
- A school timetable is periods inside the School activity (a `periods` field), never separate one-off events. The prompt and the macro say so.

**T0.5 At-school tasks.** Build: **Sonnet**.
- Tasks of kind `chore` with "ask/email/tell <teacher>" (or a new flag `atSchool`) are placed in a school-hours slot (breaks or lunch) with a reminder, instead of needing a study block.
- The "doesn't fit" estimate uses the same factor the planner used, so the message says 10 min, not ≈15.

**T0.6 Export means everything.** Build: **Opus** (it decides one container for all stored data). Runtime: none.
- A backup is one JSON file holding **every byte the app keeps**. Space doesn't matter, and the file doubles as the debugging dump. It contains:
  - the full app state: tasks, activities, events, day changes, markers, places, routines and beliefs, plan and `planHistory`, outcomes, focus sessions, progress entries, health days, motion spans, screen days, scroll sessions, flashcards, reads, moods, proposals and changes
  - `about-me.md`
  - the active conversation and the **whole archive**: every prompt verbatim with its images (base64, as sent), every reply, and **what was applied for each prompt** (changes, problems, undo)
  - the **whole AI call log**: system prompt, messages, schema, raw reply, status, model, effort, tokens, timing, errors (`last-ai-error.txt` included)
  - all usage records, the daily budget and subscription snapshots
  - App Group `SharedConfig` defaults (scroll log, friction, check-ins, alarm ids, widget snapshot) and other settings kept outside the state
  - pending and delivered notifications at export time
  - permission statuses: Health per type, location level, motion, notifications, calendar
  - app version and build, iOS version, device model, and the timezone.
- Retention caps (the 150-call or two-week call log, 60 days of days) are lifted, so data isn't thrown away before you export it. If the file ever gets genuinely big, add an archive file rather than deleting.
- The only thing left out is the API key, which stays in the Keychain. The export screen says so.
- Import restores all of it (after a preview and confirmation). The format is versioned from `3`, and earlier formats are not read; T9.1 handles your old file.
- Done when export → wipe → import gives an identical file (except `exportedAt`), and a test checks every stored property is in the export (a reflection test over `AppState` plus a list of the non-state stores).

---

## 7. Builds and releases

**T6.1 Only main builds and releases.** Build: **Sonnet**.
- `core-tests` and `ios-compile` run on every push and pull request, as now.
- `ios-free-ipa` and the release run **only on a push to `main`** (a merge or a direct push), after `core-tests` and `ios-compile` pass. No other branch, PR or manual run builds the IPA or makes a release. There are no prereleases.
- Version:
  - If no `v*` tag exists, the version is **`v1.0.0`**, and this release is **v1**.
  - Otherwise bump from the latest tag using Conventional Commits since that tag: `BREAKING CHANGE`/`!:` → major, `feat:` → minor, everything else → patch.
- Pass `MARKETING_VERSION=<x.y.z>` and `CURRENT_PROJECT_VERSION=${{ github.run_number }}` to `xcodebuild`.
- `gh release create v<x.y.z>` with generated notes, marked latest. Attach the IPA as `Productium-free.ipa` (a stable name), so `…/releases/latest/download/Productium-free.ipa` always points to the newest build for SideStore.
- Delete the `free-latest` prerelease and its step.
- Add `concurrency: release` (not cancel-in-progress) so two merges can't race for the same number.

**T6.2 Version shown in the app.** Build: **Sonnet**.
- Settings → Keeping It Installed shows the version and build.
- It checks the GitHub releases API once a day and shows "v1.0.3 is available" with a link. The public endpoint needs no auth and the request sends no personal data.

**T6.3 Docs.** Build: **Sonnet**.
- Update README, DESIGN and DISTRIBUTION for: conversations, `about-me.md`, beliefs, tiers, Opus usage, motion, the release scheme, and the removed settings.

---

## 8. Order of work

| Phase | Tasks | Why this order |
|---|---|---|
| 1 | T0.1, T0.2 | tests that reproduce every bug first |
| 2 | T0.3–T0.5, T1.5, T2.1, T2.2, T4.1, T4.2, T4.6, T6.1 | quick, well-defined fixes (Sonnet) |
| 3 | T1.1, T2.0, T3.1, T3.2, T0.6 | foundations: the box session, user facts, capability registry, routing, full export (Opus) |
| 4 | T1.2–T1.4, T2.3, T2.5, T2.6, T2.8, T4.4, T4.5 | build on the foundations (mostly Sonnet) |
| 5 | T2.4, T2.7, T4.3, T4.7, T4.8, T4.9 | sensing and inference (Opus); then the Thinks page UI (Sonnet) |
| 6 | T3.3, T5.1–T5.3, T4.10 | behaviour change on top of everything |
| 7 | T6.2, T6.3 | polish and docs |
| 8 | **T9.1** | data repair, only once everything above is done |

---

## 9. Data repair (last)

**T9.1 Convert and correct your data.** Build: **Opus**. Runtime: none. It's a one-off script, not an app feature.
- Start only when every other task is finished and the new format (T0.6) is final.
- `scripts/repair/` reads the old backup (`Productium Backup 2026-11-17 2.json`, or a newer export from the old app if you send one) and writes a format-3 export you import on the phone. It never edits the original file.
- It corrects everything that doesn't make sense, at least:
  - **Progress:** the University applications item goes from 400 to 200 completed minutes, as you said.
  - **Routines:** `[35,35,35]` and `[18,18,18]` become `stated` values with no samples. Then the real samples are learned from the markers: `to_school` = 14 min (13:02→13:16).
  - **Markers:** the three "left home" entries merge into one at 13:02 (voice is earliest). `in_bed`/`sleep`/`get_ready`/`to_school` get their proper categories and activity names.
  - **Sleep:** the night into 17 Nov becomes 00:59→07:25 (6 h 26), source check-ins.
  - **School:** the two duplicate period sets (P1 Math / Math (P1)…) are dropped. One timetable goes into the School activity's periods, with any disagreement (Wed/Fri "P2" vs "P1") listed for you to confirm rather than guessed.
  - **CS club:** a single Thursday activity, matched to the calendar event times (11:10–12:00 inside lunch 10:56–12:15), with the duplicate shown once.
  - **Day changes:** the five no-op school rows are removed.
  - **Screen Time, 16 Nov:** recomputed from the app list with your scrolling-app choices (Instagram + Discord = 131 min). The total-vs-apps mismatch (202 vs 278) is kept as flagged, not invented away.
  - **Psych teacher task:** marked `atSchool`, and the bogus critical warning goes.
  - **Prefs:** the removed settings are dropped. The values you had (180/300 study, 60/180 free…) become cold-start priors for the learned beliefs, marked "assumed".
  - **`about-me.md`:** seeded from your chat — universities chosen; Waterloo drafts 1–2 done, waiting on Ms DiFiore's feedback; about 13 Common App responses plus McMaster/UofT/Queen's sub-apps left; CS club Thursdays at lunch; lunch 10:56–12:15; walks to school.
  - **Conversation:** the 12 chat messages become the first archived conversation.
  - **Whatever else** the script finds inconsistent when it runs every validator from the finished app over the data: overlaps, impossible durations, orphaned steps, tasks whose steps add up to more than the parent.
- It prints a report of every change (before → after, and why). It also lists anything it couldn't decide, and those are asked, not guessed.
- Done when the converted file imports cleanly, the app's own validators report nothing, and you've read the report.

Per-task model summary: **Opus** builds T0.6, T1.1, T1.4, T2.0, T2.4, T2.7, T2.8 (session model), T3.1, T3.3, T4.3, T4.7, T4.8, T4.9 (the model), T5.2 and T9.1. **Sonnet** builds everything else.
At runtime, only reflection (T5.2) and belief-group creation (T4.9) call **`opus·medium`**, and everything they produce waits for your approval. Everything else stays on `sonnet` at low effort, or runs on the device.

## Decisions (from your answers)

1. The Inbox box is one continuous AI session until you clear it. Your prompts are shown verbatim. The Clear button always shows the token count and turns red when the cache expires (T1.1, T1.2). There are no per-task boxes.
2. Opus's behaviour changes wait for your approval (T3.3, T5.2).
3. Only a push or merge to `main` builds the IPA and releases it. There are no prereleases (T6.1).
4. All data that doesn't make sense is corrected, as the final Opus task (T9.1). The export contains literally everything (T0.6).
5. Pre-v1, so breaking changes are fine: no migrations or compatibility code anywhere else.
