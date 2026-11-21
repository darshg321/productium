# Testing the dev build

Dev builds (`dev` branch → `dev-build` pre-release, "Productium Dev", bundle id `….productium.dev`, scheme
`productium-dev://`) install next to the real app with their own data. They read test scripts from
`Documents/test/commands.txt` (`App/Model/TestHooks.swift`), one command per line:

| Command | Does |
|---|---|
| `scenario <name>` | replace all data with a seeded state: `fresh`, `today`, `history`, `evening`, `alerts`, `leaderboard` (`Scenarios.swift`) |
| `reset` | empty state (onboarding) |
| `tab <today\|schedule\|tasks\|review\|settings>` | switch tab (closes sheets) |
| `scroll <card>` | Review: `today ring goals week work leaderboard metrics mood where note`; Today: `ring upnext` |
| `open <url>` | any link, e.g. `productium-dev://gap` (pause sheet), an invite link |
| `say <text>` | the box (local phrases work offline; anything else needs the Claude server) |
| `start <title>` · `start-next` (what the pause sheet / Control Center do) · `stop` · `mood <1-5>` · `confirm-today` | the log |
| `approve` · `decline` · `answer <yes\|no\|skipped\|sick\|no-school>` · `dismiss` | cards and sheets |
| `refresh` · `replan` · `learn` · `leaderboard` | background work, on demand |
| `wait <s>` · `shot <name>` · `dump <name>` | timing, a screenshot (`shots/`), the state as text + JSON (`dumps/`) |

Results go to `results.txt` (`ok` / `ERR` per line, then `DONE`). Taps and typing aren't simulated: every action has
a command. Not reachable from inside the app: the Lock Screen / Live Activity, Control Center, notifications.

- **Simulator (no phone, ~10 min):** `scripts/test/sim.sh [script.txt]` runs `.github/workflows/ui-test.yml` on a
  macOS runner and downloads everything to `test-runs/<time>/`. Default script: `smoke.txt` (every screen, every scenario).
- **iPhone over USB:** install the `dev-build` IPA with Impactor, open Productium Dev, then
  `scripts/test/device.sh [script.txt]` (pymobiledevice3 pushes the script and pulls the results).
