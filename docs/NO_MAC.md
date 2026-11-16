# Building and installing Productium without a Mac

All of this works from Linux. GitHub's macOS runners do the Apple-only build step, and
you install the result on your iPhone over USB.

```
Linux (you)                         GitHub Actions (macOS runner)            iPhone
───────────                         ─────────────────────────────            ──────
edit code ── git push ───────────▶  xcodegen → xcodebuild (compile check)
swift test (core, locally)          Run workflow → signed dev .ipa  ──▶  gh run download
                                                                         pymobiledevice3 install ─▶ 📱
```

## Which path?

- **A. Free Apple ID**: everything except Screen Time blocking. Re-sign every 7 days. No Apple fees.
- **B. Paid Apple Developer Program ($99/yr)**: everything, signed for a year, and the route to TestFlight.

Comparison and research: [DISTRIBUTION.md](DISTRIBUTION.md).

## A. Free Apple ID

1. Push the repo to GitHub (a public repo gets unlimited macOS minutes).
2. Set the Actions **variable** `BUNDLE_PREFIX` (e.g. `com.yourname`). No secrets needed.
3. **Actions → ios → Run workflow** with *free_build* checked → artifact `Productium-free-ipa`.
4. On Linux: `./scripts/install-on-iphone.sh --free`. It downloads the .ipa and walks you through signing it with
   your Apple ID in **Impactor** (open source, Flatpak) over USB.
5. Trust your Apple ID on the phone (Settings → General → VPN & Device Management) and turn on Developer Mode.
6. Every 7 days: sign again, or install **SideStore** once so it refreshes on the phone.

For scrolling, the free build uses a Shortcuts automation instead of Screen Time (Settings explains it).

## B. Paid Apple Developer Program

### What you need (one time)

| | Cost | Why |
|---|---|---|
| Apple Developer Program | $99/yr | Screen Time (FamilyControls) and HealthKit need a paid team. Free accounts can't sign apps with these capabilities. |
| GitHub repo | free | macOS runners. **Public repos have unlimited minutes.** Private repos get 2,000 min/month, and macOS minutes count 10× (≈ 200 macOS minutes, about 15–20 builds). |
| USB cable + `uv` | free | `pymobiledevice3` installs the app from Linux (works with iOS 17+). |

### Step 1: Apple developer account (browser, any OS)

1. Enroll at <https://developer.apple.com/programs/>. Note your **Team ID** (Membership details).
2. Create an **App Store Connect API key**: App Store Connect → Users and Access → Integrations →
   App Store Connect API → Team Keys → **+** (role **Admin**). Download `AuthKey_XXXX.p8` (you only get one chance)
   and note the **Key ID** and **Issuer ID**.

### Step 2: register your iPhone and create a signing certificate (Linux)

```bash
cd productium
# Your iPhone's UDID (plug it in, tap "Trust"):
uvx pymobiledevice3 usbmux list          # → "UniqueDeviceID": "00008110-…"

export ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx ASC_KEY_PATH=~/Downloads/AuthKey_XXXXXXXXXX.p8
alias asc='uv run --with pyjwt --with cryptography --with requests scripts/asc.py'

asc register-device "My iPhone" 00008110-XXXXXXXXXXXXXXXX
asc dev-cert --out ~/productium-signing --password 'pick-a-password'
asc secrets --out ~/productium-signing      # prints the values for step 3
```

`dev-cert` generates the private key on your machine, has Apple sign it as an
**Apple Development** certificate, and packs both into `dev.p12`. Keep `~/productium-signing` private.

### Step 3: GitHub repo settings

Push `productium/` to a GitHub repo (only when you're ready to). Then go to repo → Settings → Secrets and variables → Actions:

**Secrets**

| Name | Value |
|---|---|
| `APPLE_TEAM_ID` | your 10-character Team ID |
| `ASC_KEY_ID` | Key ID |
| `ASC_ISSUER_ID` | Issuer ID |
| `ASC_KEY_P8` | base64 of the .p8 (from `asc secrets`) |
| `DEV_CERT_P12` | base64 of dev.p12 (from `asc secrets`) |
| `DEV_CERT_PASSWORD` | the password you chose |

**Variables**

| Name | Value |
|---|---|
| `BUNDLE_PREFIX` | e.g. `com.yourname` (must be unique to you) |

### Step 4: build

Every push runs `core-tests` (Linux) and `ios-compile` (macOS, unsigned simulator build). That's your
compiler. Read errors in the Actions log, or download the `build-log` artifact.

For an installable build: **Actions → ios → Run workflow** with *device_build* checked. The `ios-device` job:

- generates the Xcode project (XcodeGen),
- imports your certificate into a throwaway keychain,
- uses **automatic signing with your API key**. Xcode registers the App IDs, the App Group, and the
  Family Controls (Development), HealthKit and Time-Sensitive capabilities, then creates the provisioning
  profiles that include your registered iPhone,
- uploads `Productium-ipa` (kept 14 days).

If automatic registration of a capability fails (rare), add it by hand at developer.apple.com →
Identifiers → `<BUNDLE_PREFIX>.productium*`, then re-run.

### Step 5: install on the iPhone (Linux)

```bash
./scripts/install-on-iphone.sh                 # downloads the newest .ipa with gh and installs it
# or: ./scripts/install-on-iphone.sh ~/Downloads/Productium.ipa
```

First time only:
- `uvx pymobiledevice3 amfi reveal-developer-mode`, then **Settings → Privacy & Security → Developer Mode → On**
  (the phone restarts).

Debugging: `uvx pymobiledevice3 syslog live | grep -i productium`.

### Notes

- **Development-signed builds run only on registered devices.** Profiles last a year. Rebuild to renew.
- **Other students' phones:** register each UDID (max 100 iPhones/year), or distribute through TestFlight. TestFlight and
  the App Store need Apple's **Family Controls (Distribution)** entitlement. Request it at
  <https://developer.apple.com/contact/request/family-controls-distribution> (approval takes days to weeks). After that, switch
  the export method to `app-store-connect` and upload with `xcrun altool`/`notarytool` on the runner.
- **Before any distribution:** check whether running the AI on your personal Claude subscription for *other people* is
  allowed under Anthropic's terms. For a multi-user app, the Claude API with a key is the safer route. `claude-server`'s
  `/v1/messages` endpoint is shaped like the API, so swapping it out later is easy.
- **AlarmKit** (iOS 26 wake alarms) is compiled when the `ENABLE_ALARMKIT` flag is set (it is by default). If an older
  Xcode on the runner can't compile it, remove `ENABLE_ALARMKIT` from `project.yml` and the app falls back to
  time-sensitive notifications.
- No simulator is needed. Screen Time and HealthKit don't work properly in the simulator anyway, so test on the device.
