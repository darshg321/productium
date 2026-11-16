# Design

**Subject:** a high-school student's day, measured in time. **Primary job:** get everything out of
their head into one box, then see what to do now. **Principle:** the fewest decisions and the least on
screen, for the most help.

## Plan (v3: native iOS)

The app now looks like it ships with the phone, taking its cues from Health and Settings: their
informative simplicity is one number, one comparison, one small chart, and a row per thing.

**Structure.** Four tabs: Today · Week · Review · Settings. Every tab has a large navigation title and
the AI token meter at the top right.

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
red when spent) with today's count beside it. Tapping it opens AI Usage: today against the budget, a
7-day chart, tokens by feature, recent requests, the server's own count for the key, and the budget
settings. Over budget, background AI (flashcards, reads, project steps, weekly note) waits until
tomorrow; the Inbox always works.

## AI cost (v3)

- Everything frequent runs on `lite` (Haiku 4.5, thinking off) through claude-server's Anthropic-compatible
  `/v1/messages`, with structured output as one forced tool call. Haiku 5.5 thinks on every request,
  which costs hundreds of output tokens even for a one-line extraction.
- Sonnet only runs for project breakdowns (rare, automatic for big projects) and the weekly note (once a week).
- The Inbox's fixed prompt + schema went from ~5.5k to ~3.9k characters, the context it sends is
  compacted (one line per section, only today's past segments, 20 open tasks), and chat history is only
  the last exchange, and only within 30 minutes.
- System prompts are constants; variable data goes in the user turn.
- Flashcards and short reads are generated when gap mode opens, not on every launch, in small batches.
- Screenshots are sent at ≤1280 px (image tokens scale with pixels).
- Every request has a `max_tokens` close to what it needs.

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
