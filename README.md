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
- **Minimal input**: one line of text, Siri, or lock-screen taps ("left home", "bio quiz thursday",
  "essay done", 😐). Health, Calendar, Screen Time and geofences fill in the rest.
- **Screen time**: a week of measuring, then a limit that tapers about 10% a week. Calm shields with a deliberate
  "15 more minutes", and apps paused during focus blocks and wind-down.
- **Gap mode**: in a few spare minutes it offers flashcards (Leitner), a 2-minute read, "3 bullets for your next essay
  step", a breathing minute, or a walk instead of a feed.
- **Insights**: where your time went (stacked by category), a reconstructed day timeline (observed vs. assumed),
  sleep, mood vs. study, screen vs. limit, peak hours, learned routines, and a weekly Sonnet review.
- **Your data**: on-device JSON, with export to CSV, JSON backup and .ics, plus restore and delete-everything.

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
├── App/                         SwiftUI app (Today · Plan · Insights), services, intents
├── Extensions/                  DeviceActivity monitor, report, shield UI, shield action, widgets/Live Activity
├── Shared/                      App Group config + shield logic shared with extensions
├── project.yml                  XcodeGen spec (project generated on CI)
├── .github/workflows/ios.yml    Linux tests + macOS compile + signed .ipa
├── scripts/                     asc.py (Apple setup from Linux), install-on-iphone.sh, make-free-spec.py
└── docs/                        NO_MAC.md, DISTRIBUTION.md
```

AI runs through **[../claude-server](../claude-server)**, a small API on a Raspberry Pi 5 that wraps the
Claude Code CLI on your subscription. Haiku handles parsing and short generation. Sonnet handles breaking
down big tasks, weekly reviews and "Ask". Planning itself never needs the server.

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
