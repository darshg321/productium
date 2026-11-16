# SOURCES: why Productium works the way it does

Every behaviour in Productium traces back to a published finding. For each one, this file gives:

- **the evidence** behind it,
- **where it lives** in the code,
- **how it adapts to the individual student**,
- **the caveats**, including findings that failed to replicate.

Three ground rules shaped the design:

1. **Population research supplies the priors. The student's own data decides.** Each learned quantity starts at a research-backed default and shrinks toward that student's observed behaviour as evidence builds up (§16). People differ a lot in chronotype, how long tasks take them, how they respond to breaks, how much scrolling bothers them, and how mood interacts with work.
2. **Effects that have replicated get weight. Shaky ones are flagged.** Where a well-known result has failed to replicate, this file says so and the app doesn't depend on it.
3. **The model doesn't schedule.** A deterministic planner does the constraint solving. Claude (Haiku/Sonnet) parses language, breaks down goals, and explains (§1).

---

## 1. Deterministic planner, LLM as interpreter

| | |
|---|---|
| **Decision** | `Planner.plan()` is a pure function: same inputs, same plan, in milliseconds, offline. Claude never places blocks. Haiku turns "chem test fri ch 4-5" into a structured item. Sonnet breaks a college essay into dated steps and writes the weekly review. |
| **Why** | Scheduling around hard constraints (classes, sleep, deadlines) is constraint satisfaction. LLMs are unreliable at it and can't be unit-tested. A deterministic engine can be (`Packages/ProductiumCore/Tests`, 29 tests on Linux), and it explains itself through warnings. Any AI-suggested setting change is clamped (`AIMapper.apply`: at most ±10 min per change, and sleep settings can never be touched). |
| **Code** | `Planner.swift`, `AI.swift` (`Prompts`, `Schemas`, `AIMapper`) |

## 2. Test prep: spaced retrieval, never cramming

| | |
|---|---|
| **Evidence** | Distributed practice beats massed practice for retention (Cepeda et al., 2006, meta-analysis of 317 experiments). The best gap between sessions grows with how long you need to remember: about 10–20% of the retention interval (Cepeda et al., 2008). Self-testing produces more durable learning than restudying (Roediger & Karpicke, 2006). In Dunlosky et al.'s (2013) review of ten study techniques, only **practice testing** and **distributed practice** got a "high utility" rating. Rereading and highlighting rated low. |
| **Implementation** | Each test or quiz becomes several sessions on expanding day offsets before the test (1, 2, 3, 5, 7, 10, 14, 21 days, picked to spread across the lead time and always including the day before). Session hints are retrieval tasks: the first is "close your notes and write everything you remember", the last is a timed practice test. Topics become flashcards on a Leitner schedule (1→2→4→8→16 days), capped at the test date. |
| **Code** | `Planner.spacedSessions`, `MicroLearning.swift` (`Leitner`) |
| **Personal** | Minutes per session use the student's learned estimate factor for tests and quizzes (§4). |
| **Caveats** | The offsets approximate Cepeda's ridgeline. They aren't fitted to the individual, and the evidence for exact gaps is coarse. |

## 3. Long-term work (applications, essays, projects)

| | |
|---|---|
| **Evidence** | Breaking a task into its parts reduces underestimation (Kruger & Evans, 2004, "unpacking"). Concrete when-and-where plans roughly double follow-through (implementation intentions, d≈0.65; Gollwitzer & Sheeran, 2006). Brief, regular writing sessions produced more output and less procrastination than binge writing (Boice, 1989). Making a specific plan reduces the intrusive thoughts unfinished goals cause (Masicampo & Baumeister, 2011). |
| **Implementation** | Big items (essay, application, project due in more than 10 days) are automatically broken down by Sonnet into 3–8 dated steps. The first step is tiny and starts within 2 days, and the draft is done well before the deadline. The planner paces chunks evenly up to a **buffered target date**: 2 days early for work over 4 h, 1 day early for over 1.5 h. Steps are focus-length blocks, so writing happens in regular brief sessions instead of a final binge. Gap mode offers "write 3 bullets for the next part", which is plan-making in 2 minutes. |
| **Code** | `Planner.pacedChunks`, `Prompts.decomposition`, `GapPlanner` |
| **Caveat** | **Not relied on:** Ariely & Wertenbroch (2002) found externally imposed, evenly spaced deadlines reduced procrastination. A recent registered replication didn't reproduce it, and the authors have asked for a retraction. Pacing here rests on Boice and Kruger & Evans instead. |

## 4. Durations: correcting the planning fallacy, per student and task type

| | |
|---|---|
| **Evidence** | People consistently underestimate how long their own tasks will take, even when they know similar tasks ran late (Buehler, Griffin & Ross, 1994; Kahneman & Tversky, 1979). |
| **Implementation** | The planner multiplies every estimate by a **per-kind correction factor**. It starts at 1.3, updated as a running mean of actual/estimated whenever an item is completed (weighted toward recent tasks, clamped to 0.6–3). Insights shows the student "essays take you ~60% longer than estimated". |
| **Code** | `LearnedModel.estimateFactor`, `recordCompletion` |
| **Personal** | Fully individual and per task type. A fast quiz-preparer who's slow at essays gets both handled correctly. |

## 5. Sleep: protected by default, traded only under strict rules

| | |
|---|---|
| **Need** | Teens 13–18 need **8–10 h** a night (AASM consensus; Paruthi et al., 2016). The default is 9 h and the setting can't go below 7.5 h. |
| **Studying vs. sleeping** | In a longitudinal daily-diary study of high schoolers, extra study time bought with sleep led to *more* academic problems the next day (Gillen-O'Neel, Huynh & Fuligni, 2013). Sleep consolidates newly learned material (Diekelmann & Born, 2010). Chronic restriction builds cumulative deficits that people don't notice in themselves (Van Dongen et al., 2003). |
| **Policy** (`SleepPolicy.swift`) | Sleep is borrowed only when **all** of these hold: the task is *production* work (essay, application, project, not test prep); it's high-stakes (importance ≥ 4); it's due within 72 h; it still doesn't fit after free time has been squeezed; the next day has no test or quiz; last night wasn't already short. Even then: max 60 min, never under the 7 h floor, never two nights in a row, at most two nights a week, and it comes with recovery advice (on-time bedtime the next night; a ≤20-min nap, which helps without grogginess, Lovato & Lack, 2010). The student can switch trade-offs off. **Sleep is never traded for test prep**, because the trade-off is net negative there. |
| **Wake-up planning** | The wake time is worked back from the first commitment: start − commute (80th percentile of learned durations, since arriving late costs more than arriving early) − 5 min slack − learned getting-ready time. Bedtime = next wake − sleep need. Free-day wake defaults close to school days to limit **social jet lag** (Wittmann et al., 2006). Real alarms use AlarmKit (iOS 26). |
| **Short night** | If HealthKit shows last night ≥ 60 min short, today's load drops (0.9×, or 0.8× if ≥ 2 h short) and no sleep can be borrowed. |
| **Wind-down** | 30 min before bed, distracting apps are shielded. Evening screen use is consistently linked to later sleep onset and shorter sleep (Hale & Guan, 2015; Carter et al., 2016, meta-analysis). |
| **Caveat** | The app shows sleep duration and regularity, **not a sleep score**. Over-focusing on tracker metrics can itself worsen sleep ("orthosomnia"; Baron et al., 2017). |

## 6. Time of day: hard work in the student's real peak hours

| | |
|---|---|
| **Evidence** | Cognitive performance follows circadian rhythms. People do better at their preferred time of day (the "synchrony effect"; May, Hasher & Stoltzfus, 1993; review: Schmidt et al., 2007). Adolescents' rhythms shift later (Carskadon, 2011; Roenneberg et al., 2004). |
| **Implementation** | An alertness curve (morning peak, post-lunch dip, late-afternoon peak, falling at night) is shifted by chronotype. Chronotype is inferred from HealthKit as the median sleep midpoint on free days, the MCTQ method (Roenneberg et al., 2003). Hard tasks score higher in peak slots. |
| **Personal** | The circadian prior is blended with **observed per-hour follow-through** (Beta(success, fail) per hour). Once ~20 blocks have resolved at an hour, the student's actual record outweighs the textbook curve (up to 60% weight). |
| **Code** | `EnergyModel`, `LearnedModel.hourReliability`, `LearnedModel.chronotype` |

## 7. When the student doesn't follow the plan

| | |
|---|---|
| **Evidence** | Plans that are repeatedly missed erode self-efficacy (Bandura, 1977) and invite "what-the-hell" abandonment once a goal feels blown (Polivy & Herman, 1985; Cochran & Tesser, 1996). Specific, challenging *but attainable* goals perform best (Locke & Latham, 2002). Forgiving yourself for procrastinating reduces procrastination on the next task (Wohl, Pychyl & Bennett, 2010). Procrastination is largely short-term mood repair (Sirois & Pychyl, 2013; Steel, 2007). |
| **Implementation** | (a) **Rolling replanning**: any skipped or partial block puts its remaining minutes back into the pool and the plan is rebuilt. Nothing is "failed", it's moved. (b) **Load follows reality**: daily study capacity × `loadFactor`, which comes from an EWMA of block completion (from 1.0 down to a 0.6 floor, phased in over the first ~14 blocks), so plans get achievable again. (c) **Focus length adapts**: abandoned blocks shrink the default block length (min 20 min), completed full blocks grow it slowly (max 55). (d) Messages are self-compassionate ("No problem. It's been moved to a better slot."). (e) The block in progress is never yanked by a replan. |
| **No streaks** | Broken streaks reduce people's motivation to continue a behaviour (Silverman & Barasch, 2023). Productium shows follow-through percentages, never a streak that can break. |
| **Fresh starts** | Screen limits step on Mondays. Temporal landmarks raise goal motivation (Dai, Milkman & Riis, 2014). |
| **Code** | `LearnedModel.record`, `loadFactor`, `AppModel.logOutcome`, `AppModel.replan` |

## 8. Breaks

| | |
|---|---|
| **Evidence** | Students given systematic short breaks (Pomodoro-style 24/6) reported less fatigue and distraction, and more concentration and motivation, than students who chose their own breaks. They finished the same tasks in less time (Biwer et al., 2023). Brief diversions keep vigilance from decaying (Ariga & Lleras, 2011). Interruptions and task-switching leave "attention residue" (Leroy, 2009) and raise stress (Mark, Gudith & Klocke, 2008). |
| **Implementation** | A 10-min break after each focus block, with a hint to move, drink water and look away, *not* scroll. Default block 40 min, learned per student (§7c). Distracting apps are shielded during focus. |
| **Caveat** | Biwer et al. studied university students in a lab-like self-study setting. The block length is learned per student because the right rhythm varies. |

## 9. Free time is protected, and left loose

| | |
|---|---|
| **Evidence** | Scheduling leisure makes it feel more like work and less enjoyable (Tonietto & Malkoc, 2016; 13 studies). |
| **Implementation** | Each day keeps a free-time floor (60 min on school days, 3 h on free days by default). Only "crunch mode" (a deadline that can't otherwise be met) cuts into it, never below 30 min, and the block is flagged. Free time shows up as "Free" with no suggested activity. Planned study is capped per day (3 h school day / 5 h free day by default, × the adherence factor). |
| **Code** | `Planner` (`freeFloor`, `Mode.crunch`) |

## 10. Screen time: measure, add friction, taper gradually

| | |
|---|---|
| **Evidence** | In a large field experiment, self-control problems accounted for ~31% of social media use. Self-set limits reduced use, and temporary incentives had **persistent** effects, a sign of habit formation (Allcott, Gentzkow & Song, 2022). Deactivating Facebook for 4 weeks improved subjective well-being (Allcott et al., 2020). A brief delay plus the option to back out cut target-app openings by **57%** over 6 weeks. 36% of attempts were dismissed at the pause (Grüning, Riedel & Lorenz-Spreen, 2023). |
| **Implementation** | Week 1 only measures: the baseline is the median of real daily minutes (DeviceActivity threshold events, 15-min resolution). After that the daily limit steps down ~10% a week (15% after an easy week). It's **held** after a hard week and **loosened slightly** after a very hard one, because an unreachable limit gets ignored. It stops at the student's own goal, not zero. Hitting the limit shows a calm shield with a deliberate "15 more minutes" option. The number of those unlocks per day also tapers. Optionally, the shield offers a 2-minute read instead (§11). Distracting apps are also shielded during focus blocks and wind-down. |
| **Code** | `ScreenTaper.swift`, `Shared/ScreenShield.swift`, `Extensions/Monitor`, `Extensions/Shield*`, `ScreenTimeService.swift` |
| **Personal** | The baseline and every step come from the student's own usage. The taper rate depends on how they did last week. The student picks which apps and sites count as distracting. |
| **Caveats** | Across populations, the average association between adolescents' digital technology use and well-being is **small** (Orben & Przybylski, 2019). The goal isn't zero screens. It's time the student chooses, which is why the floor is theirs to set. Apple's privacy design keeps per-app Screen Time data inside the report extension, so the planner sees daily totals only. **Not relied on:** "the mere presence of your phone drains cognitive capacity" (Ward et al., 2017). A pre-registered direct replication found no effect (Ruiz Pardo & Minda, 2022). |

## 11. Gap mode: short windows, better than scrolling

| | |
|---|---|
| **Evidence** | Retrieval practice and spacing work in small doses (§2). Answering "why/how" questions improves learning from text (elaborative interrogation; Dunlosky et al., 2013, moderate utility). Writing a concrete next step reduces the cost of starting and quiets the unfinished task (Masicampo & Baumeister, 2011). Five minutes a day of cyclic sighing improved mood more than mindfulness meditation (Balban et al., 2023). Even short bouts of physical activity support attention and executive function (Hillman, Erickson & Kramer, 2008). |
| **Implementation** | Free windows of 5–25 min become "gaps". In a gap, the shield nudge, or a tap on Now, offers 2–3 options: due flashcards, a short read (120–220 words generated by Haiku from the student's subjects and interests, ending with one "why/how" question), "3 bullets for your next essay step", a 1-minute breathing exercise (logged to Health as Mindful Minutes), or a walk. |
| **Choice** | It offers 2–3 options, not one prescribed task (autonomy, a core need in self-determination theory; Ryan & Deci, 2000), and never a feed. The often-cited "choice overload" effect (Iyengar & Lepper, 2000) averages near zero in meta-analysis (Scheibehenne, Greifeneder & Todd, 2010), so the limit of three is about keeping the screen calm, not a strong claim about choice. |
| **Code** | `MicroLearning.swift` (`GapPlanner`), `GapView.swift` |

## 12. Mood

| | |
|---|---|
| **Evidence** | Putting feelings into words lowers amygdala response (affect labelling; Lieberman et al., 2007). Momentary self-report is most valid when it's brief and low-burden (Stone & Shiffman, 1994). Behavioural activation, meaning doing small valued actions before motivation shows up, is effective for low mood (Ekers et al., 2014). Procrastination is often mood repair (Sirois & Pychyl, 2013), so low mood calls for *easier entry*, not more pressure. |
| **Implementation** | One tap a day (five faces), plus optional lock-screen check-ins. A low mood today scales planned work to 0.75× and adds "start with 5 minutes of the smallest step". Low energy scales it a further 0.9×. Insights shows gentle correlations (sleep↔mood, scrolling↔mood, steps↔mood) only after ≥7 paired days and |r| > 0.3, worded as patterns, not verdicts. |
| **Safety** | If mood averages ≤ 2/5 over the past two weeks (≥4 entries), or ≥4 entries are at the lowest level, the app suggests talking to a trusted person and shows crisis resources (988 in the US, findahelpline.com). It never diagnoses. The AI prompts forbid diagnosis and require gentle referral if someone seems in distress. |
| **Code** | `Wellbeing.swift`, `Planner.computeTodayModifiers` |

## 13. Minimal input: learn, don't ask

| | |
|---|---|
| **Evidence** | Monitoring goal progress improves attainment, especially when it's recorded (Harkin et al., 2016; 138 studies). But logging burden is the main reason people stop self-tracking, and EMA validity drops as burden rises (Stone & Shiffman, 1994). |
| **Implementation** | Data comes in passively wherever it can: HealthKit (sleep, wake, steps, daylight), the calendar (events, plus deadlines detected from titles like "Bio test"), Screen Time thresholds, and geofences ("left home", "at school" logged automatically). Manual input is one line of free text, a one-tap chip, a lock-screen action, or Siri. **Routines are learned**: commute and getting-ready times are the median of observed samples, robust to the one day you stopped for coffee, with outliers rejected. Once a routine has ~5 samples, the check-in prompts stop and the time is filled in automatically ("assumed" in the timeline until a check-in corrects it). |
| **Code** | `Routines.swift`, `Timeline.swift` (`MarkerParser`, `RoutineLearner`, `TimelineBuilder`, `CheckInSuggester`) |

## 14. Triage when there isn't enough time

| | |
|---|---|
| **Idea** | Earliest-deadline-first placement (optimal for meeting deadlines when everything fits), with importance as the tie-breaker. When it doesn't all fit: squeeze free time, then (rarely) sleep under §5, then **take slots from low-stakes work** (importance at least 2 lower) and say so plainly. ("Moved 40 min from 'Worksheet' to 'Application'. Do a quick, good-enough version of Worksheet.") Anything still unplaced is reported honestly as a shortfall, with concrete advice: aim for a complete solid version; for tests, focus on the highest-weight topics; ask for extensions early. |
| **Why** | The best result across short- and long-term work comes from protecting high-stakes items without silently dropping low-stakes ones. The student always sees what was traded and why (autonomy). |
| **Code** | `Planner.allocate`, `displace` |

## 15. Interface

Few elements per screen. One accent colour. One primary action (Today answers "what now?"). Fixed time is visually dimmed so attention lands on study and free time. Every number is something you can act on. The rationale is cognitive load (Sweller, 1988): a planner shouldn't add to the load it's meant to reduce. There are no points, badges, leaderboards or streaks (§7).

## 16. What adapts to each student (priors → learned)

| Quantity | Research prior | Learned from | Update rule |
|---|---|---|---|
| Duration correction per task kind | ×1.3 (planning fallacy) | completed items: actual vs. estimate | running mean, weight ≤12, clamp 0.6–3 |
| Daily load | 1.0 | every resolved block (done 1 / partial ½ / skipped 0) | EWMA (α .25 → .12), confidence-phased, floor 0.6 |
| Peak hours | circadian curve shifted by chronotype | per-hour block outcomes | Beta per hour, decays at n>30, blended up to 60% |
| Chronotype | adolescent "late" | HealthKit free-day sleep midpoint | MCTQ median (≥3 nights) |
| Focus block length | 40 min | completed vs. abandoned blocks | +0.5 / −1.5 min, 20–55 |
| Commute / get-ready | 20 / 40 min | check-ins, geofences, wake time | median of last 15, outlier rejection; planning uses 80th pct |
| Sleep need | 9 h (AASM 8–10) | student setting (7.5–10 h) | — |
| Screen limit | baseline (median week 1) | DeviceActivity thresholds | weekly −10/−15%, hold or loosen after hard weeks |
| Today's load | — | mood (1–5), energy, last night's sleep | ×0.75 low mood, ×0.9 low energy, ×0.8–0.9 short sleep |
| Settings | defaults above | Sonnet weekly review | suggestions only, user-approved, ±10 min, never sleep |

## 17. Deliberately not done

- **No AI-generated schedules.** These can't be verified (§1).
- **No streaks, points or social comparison** (§7, §15).
- **No sleep score** (orthosomnia, §5).
- **No sleep traded for test study, ever** (§5).
- **No total lockout.** The student keeps a deliberate exit, because autonomy-preserving friction beats hard bans that get worked around (§10).
- **No location history.** Only enter/exit events for places the student saved.

---

## References

- Allcott, H., Braghieri, L., Eichmeyer, S., & Gentzkow, M. (2020). The welfare effects of social media. *American Economic Review, 110*(3), 629–676.
- Allcott, H., Gentzkow, M., & Song, L. (2022). Digital addiction. *American Economic Review, 112*(7), 2424–2463.
- Ariely, D., & Wertenbroch, K. (2002). Procrastination, deadlines, and performance. *Psychological Science, 13*(3), 219–224. **(replication failed; retraction requested. Cited only to explain why it isn't used.)**
- Ariga, A., & Lleras, A. (2011). Brief and rare mental "breaks" keep you focused. *Cognition, 118*(3), 439–443.
- Balban, M. Y., et al. (2023). Brief structured respiration practices enhance mood and reduce physiological arousal. *Cell Reports Medicine, 4*(1), 100895.
- Bandura, A. (1977). Self-efficacy: Toward a unifying theory of behavioral change. *Psychological Review, 84*(2), 191–215.
- Baron, K. G., Abbott, S., Jao, N., Manalo, N., & Mullen, R. (2017). Orthosomnia: Are some patients taking the quantified self too far? *Journal of Clinical Sleep Medicine, 13*(2), 351–354.
- Biwer, F., Wiradhany, W., oude Egbrink, M. G. A., & de Bruin, A. B. H. (2023). Understanding effort regulation: Comparing 'Pomodoro' breaks and self-regulated breaks. *British Journal of Educational Psychology, 93*(S2), 353–367.
- Boice, R. (1989). Procrastination, busyness and bingeing. *Behaviour Research and Therapy, 27*(6), 605–611.
- Buehler, R., Griffin, D., & Ross, M. (1994). Exploring the "planning fallacy". *Journal of Personality and Social Psychology, 67*(3), 366–381.
- Carskadon, M. A. (2011). Sleep in adolescents: The perfect storm. *Pediatric Clinics of North America, 58*(3), 637–647.
- Carter, B., Rees, P., Hale, L., Bhattacharjee, D., & Paradkar, M. S. (2016). Association between portable screen-based media device access or use and sleep outcomes. *JAMA Pediatrics, 170*(12), 1202–1208.
- Cepeda, N. J., Pashler, H., Vul, E., Wixted, J. T., & Rohrer, D. (2006). Distributed practice in verbal recall tasks. *Psychological Bulletin, 132*(3), 354–380.
- Cepeda, N. J., Vul, E., Rohrer, D., Wixted, J. T., & Pashler, H. (2008). Spacing effects in learning: A temporal ridgeline of optimal retention. *Psychological Science, 19*(11), 1095–1102.
- Cochran, W., & Tesser, A. (1996). The "what the hell" effect. In L. Martin & A. Tesser (Eds.), *Striving and Feeling*. Erlbaum.
- Dai, H., Milkman, K. L., & Riis, J. (2014). The fresh start effect. *Management Science, 60*(10), 2563–2582.
- Diekelmann, S., & Born, J. (2010). The memory function of sleep. *Nature Reviews Neuroscience, 11*(2), 114–126.
- Dunlosky, J., Rawson, K. A., Marsh, E. J., Nathan, M. J., & Willingham, D. T. (2013). Improving students' learning with effective learning techniques. *Psychological Science in the Public Interest, 14*(1), 4–58.
- Ekers, D., et al. (2014). Behavioural activation for depression; an update of meta-analysis of effectiveness and sub group analysis. *PLoS ONE, 9*(6), e100100.
- Gillen-O'Neel, C., Huynh, V. W., & Fuligni, A. J. (2013). To study or to sleep? The academic costs of extra studying at the expense of sleep. *Child Development, 84*(1), 133–142.
- Gollwitzer, P. M., & Sheeran, P. (2006). Implementation intentions and goal achievement: A meta-analysis. *Advances in Experimental Social Psychology, 38*, 69–119.
- Grüning, D. J., Riedel, F., & Lorenz-Spreen, P. (2023). Directing smartphone use through the self-nudge app one sec. *PNAS, 120*(8), e2213114120.
- Hale, L., & Guan, S. (2015). Screen time and sleep among school-aged children and adolescents. *Sleep Medicine Reviews, 21*, 50–58.
- Harkin, B., et al. (2016). Does monitoring goal progress promote goal attainment? A meta-analysis. *Psychological Bulletin, 142*(2), 198–229.
- Hillman, C. H., Erickson, K. I., & Kramer, A. F. (2008). Be smart, exercise your heart. *Nature Reviews Neuroscience, 9*(1), 58–65.
- Iyengar, S. S., & Lepper, M. R. (2000). When choice is demotivating. *Journal of Personality and Social Psychology, 79*(6), 995–1006.
- Kahneman, D., & Tversky, A. (1979). Intuitive prediction: Biases and corrective procedures. *TIMS Studies in Management Science, 12*, 313–327.
- Kruger, J., & Evans, M. (2004). If you don't want to be late, enumerate: Unpacking reduces the planning fallacy. *Journal of Experimental Social Psychology, 40*(5), 586–598.
- Leroy, S. (2009). Why is it so hard to do my work? The challenge of attention residue when switching between work tasks. *Organizational Behavior and Human Decision Processes, 109*(2), 168–181.
- Lieberman, M. D., et al. (2007). Putting feelings into words. *Psychological Science, 18*(5), 421–428.
- Locke, E. A., & Latham, G. P. (2002). Building a practically useful theory of goal setting and task motivation. *American Psychologist, 57*(9), 705–717.
- Lovato, N., & Lack, L. (2010). The effects of napping on cognitive functioning. *Progress in Brain Research, 185*, 155–166.
- Mark, G., Gudith, D., & Klocke, U. (2008). The cost of interrupted work: More speed and stress. *Proc. CHI 2008*, 107–110.
- Masicampo, E. J., & Baumeister, R. F. (2011). Consider it done! Plan making can eliminate the cognitive effects of unfulfilled goals. *Journal of Personality and Social Psychology, 101*(4), 667–683.
- May, C. P., Hasher, L., & Stoltzfus, E. R. (1993). Optimal time of day and the magnitude of age differences in memory. *Psychological Science, 4*(5), 326–330.
- Orben, A., & Przybylski, A. K. (2019). The association between adolescent well-being and digital technology use. *Nature Human Behaviour, 3*(2), 173–182.
- Paruthi, S., et al. (2016). Consensus statement of the American Academy of Sleep Medicine on the recommended amount of sleep for healthy children. *Journal of Clinical Sleep Medicine, 12*(11), 1549–1561.
- Polivy, J., & Herman, C. P. (1985). Dieting and binging: A causal analysis. *American Psychologist, 40*(2), 193–201.
- Roediger, H. L., & Karpicke, J. D. (2006). Test-enhanced learning. *Psychological Science, 17*(3), 249–255.
- Roenneberg, T., Wirz-Justice, A., & Merrow, M. (2003). Life between clocks: Daily temporal patterns of human chronotypes. *Journal of Biological Rhythms, 18*(1), 80–90.
- Roenneberg, T., et al. (2004). A marker for the end of adolescence. *Current Biology, 14*(24), R1038–R1039.
- Ruiz Pardo, A. C., & Minda, J. P. (2022). Reexamining the "brain drain" effect: A replication of Ward et al. (2017). *Acta Psychologica, 230*, 103717.
- Ryan, R. M., & Deci, E. L. (2000). Self-determination theory and the facilitation of intrinsic motivation. *American Psychologist, 55*(1), 68–78.
- Scheibehenne, B., Greifeneder, R., & Todd, P. M. (2010). Can there ever be too many options? A meta-analytic review of choice overload. *Journal of Consumer Research, 37*(3), 409–425.
- Schmidt, C., Collette, F., Cajochen, C., & Peigneux, P. (2007). A time to think: Circadian rhythms in human cognition. *Cognitive Neuropsychology, 24*(7), 755–789.
- Silverman, J., & Barasch, A. (2023). On or off track: How (broken) streaks affect consumer decisions. *Journal of Consumer Research, 49*(6), 1095–1117.
- Sirois, F., & Pychyl, T. (2013). Procrastination and the priority of short-term mood regulation. *Social and Personality Psychology Compass, 7*(2), 115–127.
- Steel, P. (2007). The nature of procrastination. *Psychological Bulletin, 133*(1), 65–94.
- Stone, A. A., & Shiffman, S. (1994). Ecological momentary assessment (EMA) in behavioral medicine. *Annals of Behavioral Medicine, 16*(3), 199–202.
- Sweller, J. (1988). Cognitive load during problem solving. *Cognitive Science, 12*(2), 257–285.
- Tonietto, G. N., & Malkoc, S. A. (2016). The calendar mindset: Scheduling takes the fun out and puts the work in. *Journal of Marketing Research, 53*(6), 922–936.
- Van Dongen, H. P. A., Maislin, G., Mullington, J. M., & Dinges, D. F. (2003). The cumulative cost of additional wakefulness. *Sleep, 26*(2), 117–126.
- Ward, A. F., Duke, K., Gneezy, A., & Bos, M. W. (2017). Brain drain. *Journal of the Association for Consumer Research, 2*(2), 140–154. **(failed pre-registered replication; not relied on)**
- Wittmann, M., Dinich, J., Merrow, M., & Roenneberg, T. (2006). Social jetlag. *Chronobiology International, 23*(1–2), 497–509.
- Wohl, M. J. A., Pychyl, T. A., & Bennett, S. H. (2010). I forgive myself, now I can study. *Personality and Individual Differences, 48*(7), 803–808.
