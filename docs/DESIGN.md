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
7-day chart, tokens by feature, recent requests, the server's own count for the key, and the budget
settings. Over budget, background AI (flashcards, reads, project steps, weekly note) waits until
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

## AI cost (v3)

- Only output tokens are counted (meter, budget, chart, receipts).
- Everything runs on Sonnet at the server's default low effort, through claude-server's Anthropic-compatible
  `/v1/messages`, with structured output as one forced tool call. Measured on the app's own prompts
  (16 Inbox messages, a breakdown, flashcards, reads, the weekly note), Sonnet 5.5 wrote 8.1k output tokens
  and Haiku 5.5 wrote 14.4k, with every case right on both. Haiku 5.5's thinking can't be turned off and it
  thinks more than Sonnet does, so a second model would only add cost. Haiku 4.5 isn't used.
- The Inbox's fixed prompt + schema went from ~5.5k to ~3.9k characters, the context it sends is
  compacted (one line per section, only today's past segments, 20 open tasks), and chat history is only
  the last exchange, and only within 30 minutes.
- System prompts are constants; variable data goes in the user turn.
- Flashcards and short reads are generated when gap mode opens, not on every launch, in small batches.
- Screenshots are sent at ≤1280 px (image tokens scale with pixels).
- Every request has a `max_tokens` close to what it needs.

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

Settings → Backup & Restore → Back Up All Data writes one JSON file (`format: productium-backup`,
version 2) holding the entire app state plus the server address and the few settings kept outside it.
The API key stays in the Keychain and is never written out. Restore reads v2 and the older partial
backups, says what's in the file, and asks before replacing anything; the current data is saved as
`state-before-restore.json` first. Permissions stay with the phone.

## What changed from v1 to v2 (and why)

- Cards, pill chips, capsule toasts, a floating + button, rings and segmented pickers: removed. They're the
  generic "SaaS kit" look, and each was a decision or a thing to look at.
- Insights went from six chart panes plus a range picker to one screen (note, strips, three sentences).
- Quick-add sheet, coach chat, mood picker and forms: removed. The box does all of them, including questions.
- Editing forms are gone. Corrections are typed ("move the essay to friday", "didn't go to school today"),
  and every change shows what it did, with Undo.
