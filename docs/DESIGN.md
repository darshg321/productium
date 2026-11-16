# Design

**Subject:** a high-school student's day, measured in time. **Primary job:** get everything out of
their head into one box, then see what to do now. **Principle:** the fewest decisions and the least on
screen, for the most help.

## Plan

**Colour.** Five named colours, each meaning one thing, so colour is information rather than decoration:

| name | hex | means |
|---|---|---|
| cobalt | `#2340F5` | focus work; also the only interactive accent |
| daylight | `#F5A623` | free time |
| night | `#1A2350` | sleep, wind-down |
| fog | `#E4E6EB` / dark `#2C2E35` | fixed time: school, travel, routines, meals |
| signal | `#E5482D` | something needs attention (overdue, doesn't fit, build expiring) |

Backgrounds are the system's white/black.

**Type.** One family, SF Pro. Width is the voice: **expanded** for one or two display lines per screen
(the day name, what to do now, a timer), regular for everything else. Times use SF's tabular digits,
not a monospace face. Sentence case everywhere. No all-caps labels, no eyebrow text, no "A · B · C" meta strings.

**Layout.** The characteristic element is *the day drawn to scale*: flat bars whose length is their duration.

```
Monday  Nov 16                         ⚙
┌──────────────────────────────────────┐
▌ What's due, what happened, what      │   ← the box: the hero
│ changed?                             │
│ Screenshot                    [Send] │
└──────────────────────────────────────┘
Chem test                                  ← now (expanded)
34 min left. Retrieval practice…
[ Start                               ]
Did you get to Math HW?  Yes  Partly  No   ← at most one question
16:00 ▌ Soccer practice                    ← the rest of the day, to scale
      ▌
17:40 ▌ English essay 2/6
19:00 ▌ Free
22:20 ▌ Bed
```

Week: seven rows, each a horizontal 06:00–24:00 strip plus what's due that day. Review: a note from
Claude, the last seven days as strips of what the time actually went to, and three sentences.

Left-aligned throughout. Corners: 3 pt on fields and buttons, square on bars. No cards, shadows,
gradients or capsules. Motion: one moment only. The day re-flows (spring) when the box changes the plan,
and it's off under Reduce Motion.

## What changed from v1 (and why)

- Cards, pill chips, capsule toasts, a floating + button, rings and segmented pickers: removed. They're the
  generic "SaaS kit" look, and each was a decision or a thing to look at.
- Insights went from six chart panes plus a range picker to one screen (note, strips, three sentences).
- Quick-add sheet, coach chat, mood picker and forms: removed. The box does all of them, including questions.
- Editing forms are gone. Corrections are typed ("move the essay to friday", "didn't go to school today"),
  and every change shows what it did, with Undo.
