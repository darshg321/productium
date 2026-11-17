# Productium

A calm, minimal iOS life planner for high-school students. You tell it what's due. It plans when
to do it, protects your sleep and free time, learns your routine, quiets distracting apps a little more each
week, and adapts when the plan doesn't go to plan.

The research behind each behaviour is in **[SOURCES.md](SOURCES.md)**.
There's no Mac in this workflow: see **[docs/NO_MAC.md](docs/NO_MAC.md)**. It runs on a free Apple ID too (no Screen Time
blocking): see **[docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)**.

## What it does

- **Live plan**: tests become spaced retrieval sessions, essays and applications become paced steps with buffers,
  and everything is placed earliest-deadline-first into your real free time, with hard work in your best hours.
  It replans whenever something changes.
- **Sleep-aware**: wake-up is worked back from your first class plus your learned commute, with real alarms on
  iOS 26. Sleep is never traded for test prep. Small, capped trade-offs are allowed only for high-stakes deadline
  writing (see SOURCES §5).
- **Adapts to you**: learns how long your tasks really take, which hours you actually get work done in, your
  focus length, and your commute. If you complete less than planned, it plans less.
- **One box, one conversation**: type, or drop screenshots of, anything: deadlines, what you did, how you feel,
  questions, and corrections ("didn't go to school today", "chem test moved to tues", "walk to school is 25 min").
  The Inbox is a single ongoing Claude (Sonnet) session until you press **Clear**, which shows how many tokens
  the next prompt will carry and turns red when the prompt cache has expired. Your prompts are kept verbatim,
  your draft survives leaving the app, and cleared conversations are under Settings → Past Prompts. Claude turns
  what you say into changes (three operations over a typed registry: upsert, delete, set), applies them on the
  phone, and shows what changed, with Undo. It sees the whole app by id, so it updates instead of duplicating.
- **It learns about you, and shows it**: Settings → What Productium Thinks lists every assumption (routines,
  sleep, study capacity, focus and break length, scrolling) with how sure it is (Assumed, You said, Learning,
  Learned, Confirmed) and the evidence. Settings → About You is a plain-text file of what you've told it, which
  your edits always win. The old guessed steppers (max study minutes, minimum free time, block length, dinner,
  chronotype, screen-time goal) are gone: they're learned from what you actually do.
- **Behaviour changes need your OK**: rarely, a reflection on **Claude Opus** (medium effort, the one expensive
  call) looks at what you keep putting off and *proposes* small changes (a 15-minute first step, shorter blocks, an
  if-then reminder). Nothing changes until you tap Approve; every change is bounded, logged and revertible.
- **Sleep, scrolling and places without extra hardware**: sleep is estimated from your check-ins, motion and phone
  use when nothing records it; walks and rides come from Motion; scrolling is its own category, counted per app from
  Shortcuts sessions and Screen Time screenshots against your own list of scrolling apps; places offer to save
  themselves.
- **Colours**: every task, activity and event can have its own colour, and categories (study, free time,
  school, a subject…) have defaults in Settings → Schedule → Colours, or by asking the Inbox.
- **Screen time**: a week of measuring, then a limit that tapers about 10% a week. Calm shields with a deliberate
  "15 more minutes", and apps paused during focus blocks and wind-down.
- **Tasks and Schedule tabs**: every task in one searchable list (by due date, subject or type) with work left,
  the next planned session, swipe to finish or start, and an add/edit form that costs no tokens. The schedule shows a
  day to scale with a now line, or the next seven days as a list.
- **Interruptions you choose**: Gentle, Standard or Persistent. A heads-up before work, Start Focus / In 10 Minutes /
  Can't Today on the lock screen, follow-ups that stop the moment you start, wind-down, bedtime, leave-by and deadline
  reminders, a note when you get home, and (opt-in, iOS 26.1) real alarms for bedtime, leaving and missed starts.
- **Shortcuts recipes**: Settings → Shortcuts & Automations walks through each automation tap by tap: a one-action
  pause before scrolling (iOS 26), counting scrolling minutes when those apps close, grayscale at night, an NFC tag
  on your desk that starts focus, Wi-Fi and alarm check-ins, and the Action button.
- **Gap mode**: in a few spare minutes it offers flashcards (Leitner), a 2-minute read, "3 bullets for your next essay
  step", a breathing minute, or a walk instead of a feed.
- **Review**: a weekly note from Claude, the last seven days drawn as they actually went, and three
  sentences (sleep, work done, scrolling). Design notes: [docs/DESIGN.md](docs/DESIGN.md).
- **Your data**: on-device JSON. Settings → Backup & Restore saves *every byte the app keeps* (state, About You, every prompt and reply, the AI call log, settings, notifications and permissions snapshot) to one file you keep, and restores
  it on this or another phone. There's also CSV and .ics export, and delete-everything.
- **Token meter**: top right on every tab, today's AI output tokens against a daily budget, with a breakdown by
  feature. Over budget, background AI waits until tomorrow; the box always works. AI Usage also shows how much of
  the Claude subscription is left (5-hour and weekly limits, from claude-server's `/v1/subscription`), and every
  request in full: tap one to read the exact prompt sent and the reply that came back.

## Layout

```
productium/
├── Packages/ProductiumCore/     Pure-Swift engine (builds & tests on Linux)
│   ├── Planner.swift            deterministic scheduler (spacing, pacing, triage, sleep policy)
│   ├── SleepPolicy.swift        when (rarely) sleep may be borrowed
│   ├── Personalization.swift    learned model: estimate factors, adherence, peak hours, focus length
│   ├── Routines.swift           learned commute/get-ready + wake-up planning
│   ├── Timeline.swift           check-in parsing, routine learning, day reconstruction
│   ├── ScreenTaper.swift        adaptive weekly screen-time limit
│   ├── Nudges.swift             which notifications and alarms to send, and when; scroll-session log
│   ├── TaskBoard.swift          task list grouping, search, work left; timeline lanes
│   ├── Conversation.swift       the Inbox as one continuous session, Clear size and cache expiry
│   ├── Capabilities.swift       upsert/delete/set over a tiered registry; Proposals.swift, Reflection.swift
│   ├── Beliefs.swift            every assumption with confidence and evidence; CapacityLearner.swift
│   ├── AboutMe.swift, Avoidance.swift, WorkDone.swift, ScreenTime.swift, Places.swift, Sleep.swift, Motion.swift
│   ├── Wellbeing.swift, MicroLearning.swift, Insights.swift, Export.swift (format 3: everything)
│   └── AI.swift                 server wire format, JSON schemas, prompts, model routing, guard rails
├── App/                         SwiftUI app (Today · Schedule · Tasks · Review · Settings), services, intents
├── Extensions/                  DeviceActivity monitor, report, shield UI, shield action, widgets/Live Activity
├── Shared/                      App Group config + shield logic shared with extensions
├── project.yml                  XcodeGen spec (project generated on CI)
├── .github/workflows/ios.yml    Linux tests + macOS compile on every push; IPA + release only on push to main
├── scripts/                     asc.py (Apple setup from Linux), install-on-iphone.sh, make-free-spec.py
└── docs/                        NO_MAC.md, DISTRIBUTION.md
```

Productium is an AI app and needs **[../claude-server](../claude-server)**, a small API on a Raspberry Pi 5 that
wraps the Claude Code CLI on your subscription and accepts images (default address: `https://raspberrypi.tail29964a.ts.net`).
The app uses its Anthropic-compatible `/v1/messages` API. Sonnet at low effort does everything user-facing (the box
and screenshots, project breakdowns, flashcards, short reads, the weekly note); Opus at medium effort does only the
rare, approval-gated reflection. The scheduler itself is deterministic code on the phone (see SOURCES §1).

## Releases

Pushing or merging to `main` builds the free-account IPA and publishes a GitHub release (`v1.0.0` first, then
bumped from Conventional Commits) with `Productium-free.ipa` attached, so
`…/releases/latest/download/Productium-free.ipa` is always the newest build for SideStore. Other branches and
pull requests only run the tests and the compile check. Settings → Keeping It Installed shows the version and
says when a newer release exists.

## Develop on Linux

```bash
cd Packages/ProductiumCore
swift test            # Swift 6.2 toolchain for Linux: swift.org/install
```

UI and extension code compiles on the `ios-compile` CI job (macOS runner) on every push.

## Permissions used

FamilyControls (individual), DeviceActivity, ManagedSettings · HealthKit (read sleep, steps, daylight,
resting HR; write mindful minutes) · EventKit full access · Location (always: region monitoring and visits, no history kept) · Motion & Fitness (walk/ride durations only) ·
Notifications (time-sensitive) · AlarmKit · Live Activities · Background refresh.
