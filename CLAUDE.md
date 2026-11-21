# Productium

iOS app (SwiftUI) + `Packages/ProductiumCore` (all logic, tests run on Linux) + `Widgets/`. No Mac: the App only
compiles on CI. See `DESIGN.md` (local) and `APP.md`.

- Core tests: `export PATH=$HOME/.local/swift/swift-6.2.1-RELEASE-ubuntu24.04/usr/bin:$PATH; cd Packages/ProductiumCore && swift build --build-tests && swift test --skip-build [--filter X]`
- Box evals without network: `cd scripts/inbox-eval && swift run -q H --v12-reference`
- Branches: push to `dev` for test builds (CI compiles, `dev-build` pre-release, no version change); `main` releases
  `v<VERSION>.n`. Commit / push / merge only when asked.
- Seeing the app: write a command script and run `scripts/test/sim.sh script.txt` (CI simulator, ~10 min), then read
  `test-runs/<time>/out/shots/*.png`, `dumps/*.txt` and `results.txt`. On the user's phone: `scripts/test/device.sh`.
  Commands and scenarios: `scripts/test/README.md`. Add a scenario in `Scenarios.swift` (with a `ScenarioTests` case)
  when a state can't be reached with commands.
- Leaderboard Worker: `scripts/leaderboard` (`node test.mjs`, `./deploy.sh`).
