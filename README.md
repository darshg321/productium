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
- **One box for everything**: type, or drop screenshots of, anything: deadlines, what you did, how you feel,
  questions, and corrections ("didn't go to school today", "chem test moved to tues", "walk to school is 25 min").
  Claude (Haiku 4.5, the cheapest model on the server) turns it into changes, applies them on the phone, and shows what changed, with Undo.
  Health, Calendar, location and Screen Time fill in the rest.
- **Screen time**: a week of measuring, then a limit that tapers about 10% a week. Calm shields with a deliberate
  "15 more minutes", and apps paused during focus blocks and wind-down.
- **Gap mode**: in a few spare minutes it offers flashcards (Leitner), a 2-minute read, "3 bullets for your next essay
  step", a breathing minute, or a walk instead of a feed.
- **Review**: a weekly note from Claude, the last seven days drawn as they actually went, and three
  sentences (sleep, work done, scrolling). Design notes: [docs/DESIGN.md](docs/DESIGN.md).
- **Your data**: on-device JSON. Settings → Backup & Restore saves *everything* to one file you keep, and restores
  it on this or another phone. There's also CSV and .ics export, and delete-everything.
- **Token meter**: top right on every tab, today's AI tokens against a daily budget, with a breakdown by
  feature. Over budget, background AI waits until tomorrow; the box always works.

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
│   ├── Wellbeing.swift, MicroLearning.swift, Insights.swift, Export.swift
│   └── AI.swift                 server wire format, JSON schemas, prompts, guard rails
├── App/                         SwiftUI app (Today · Week · Review · Settings), services, intents
├── Extensions/                  DeviceActivity monitor, report, shield UI, shield action, widgets/Live Activity
├── Shared/                      App Group config + shield logic shared with extensions
├── project.yml                  XcodeGen spec (project generated on CI)
├── .github/workflows/ios.yml    Linux tests + macOS compile + signed .ipa
├── scripts/                     asc.py (Apple setup from Linux), install-on-iphone.sh, make-free-spec.py
└── docs/                        NO_MAC.md, DISTRIBUTION.md
```

Productium is an AI app and needs **[../claude-server](../claude-server)**, a small API on a Raspberry Pi 5 that
wraps the Claude Code CLI on your subscription and accepts images (default address: `https://raspberrypi.tail29964a.ts.net`).
The app uses its Anthropic-compatible `/v1/messages` API. Haiku 4.5 (`lite`) reads the box and screenshots.
Sonnet breaks down big projects and writes the weekly note. The scheduler itself is deterministic code
on the phone (see SOURCES §1).

## Develop on Linux

```bash
cd Packages/ProductiumCore
swift test            # Swift 6.2 toolchain for Linux: swift.org/install
```

UI and extension code compiles on the `ios-compile` CI job (macOS runner) on every push.

## Permissions used

FamilyControls (individual), DeviceActivity, ManagedSettings · HealthKit (read sleep, steps, daylight,
resting HR; write mindful minutes) · EventKit full access · Location (always, region monitoring only) ·
Notifications (time-sensitive) · AlarmKit · Live Activities · Background refresh.
