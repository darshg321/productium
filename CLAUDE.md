# Productium

iOS app (SwiftUI) + `Packages/ProductiumCore` (all logic, tests run on Linux) + `Widgets/`. No Mac: the App only
compiles on CI. See `DESIGN.md` (local), `APP.md` and the current plan (`v1.3_plan.md`).

- Core tests: `export PATH=$HOME/.local/swift/swift-6.2.1-RELEASE-ubuntu24.04/usr/bin:$PATH; cd Packages/ProductiumCore && swift build --build-tests && swift test --skip-build [--filter X]`
- Box evals without network: `cd scripts/inbox-eval && swift run -q H --v12-reference`
- **Branches:** make every change on `dev` first and commit as you go (small commits, pushed to `dev` so CI compiles
  it and builds the `dev-build` pre-release; no version change). Merge `dev` into `main` (which releases
  `v<VERSION>.n`) only once the `dev` build is green and the change has been checked with `scripts/test`.
- **User data must migrate.** v1.2.2 (`AppState.schema = 4`) is the first version with real data. Any change to
  stored data after it (AppState fields, Codable types, backups) bumps `schema`, adds a migration step from the
  previous schema, and a test that decodes a saved 1.2.2 `state.json` fixture without losing anything. Never fall back
  to a fresh state for an older schema. Restores from backup files go through the same migrations.
- Seeing the app: write a command script and run `scripts/test/sim.sh script.txt` (CI simulator, ~10 min), then read
  `test-runs/<time>/out/shots/*.png`, `dumps/*.txt` and `results.txt`. On the user's phone: `scripts/test/device.sh`.
  Commands and scenarios: `scripts/test/README.md`. Add a scenario in `Scenarios.swift` (with a `ScenarioTests` case)
  when a state can't be reached with commands.
- Leaderboard Worker: `scripts/leaderboard` (`node test.mjs`, `./deploy.sh`).
- Dev app on the phone: Productium Dev (`com.darshg321.productium.dev.573BBB2JRN` once signed). Install / update over
  USB: download the `dev-build` IPA, sign with `flatpak run --filesystem=<dir> --command=plumesign
  dev.khcrysalis.PlumeImpactor sign --package <ipa> --apple-id --output <signed.ipa>` (the saved account and key are
  reused; don't use `--register-and-install`, it fails to find the phone), then `uvx pymobiledevice3 apps install
  <signed.ipa>`. Connect it to claude-server with `scripts/test/connect-server.sh`.
