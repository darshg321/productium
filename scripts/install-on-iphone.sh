#!/usr/bin/env bash
# Get the CI-built app onto a USB-connected iPhone, from Linux.
#
#   ./scripts/install-on-iphone.sh --free          # free Apple ID: download the unsigned-for-you .ipa, sign with Impactor
#   ./scripts/install-on-iphone.sh                 # paid account: download the signed dev .ipa and install it
#   ./scripts/install-on-iphone.sh path/to/app.ipa # install an already-signed .ipa
#
# Uses the GitHub CLI (gh) to fetch artifacts and pymobiledevice3 (through uvx) to install.
set -euo pipefail

FREE=0
[[ "${1:-}" == "--free" ]] && { FREE=1; shift; }
IPA="${1:-}"

fetch() {  # $1 = artifact name
  command -v gh >/dev/null || { echo "install the GitHub CLI (gh), or pass an .ipa path"; exit 1; }
  local dir run
  dir=$(mktemp -d)
  run=$(gh run list --workflow ios.yml --status success --limit 20 --json databaseId,event \
        --jq 'map(select(.event=="workflow_dispatch"))[0].databaseId')
  [[ -n "$run" && "$run" != "null" ]] || { echo "no successful manual ios run found"; exit 1; }
  gh run download "$run" -n "$1" -D "$dir"
  ls "$dir"/*.ipa | head -1
}

if [[ $FREE == 1 ]]; then
  IPA="${IPA:-$(fetch Productium-free-ipa)}"
  cat <<MSG
Downloaded: $IPA

This .ipa still needs signing with your (free) Apple ID. On Linux:
  1. Install Impactor (open source):  flatpak install flathub dev.khcrysalis.PlumeImpactor
     (needs usbmuxd: sudo apt install usbmuxd. If the phone isn't seen:
      flatpak override --user --device=all dev.khcrysalis.PlumeImpactor)
  2. flatpak run dev.khcrysalis.PlumeImpactor → sign in with your Apple ID → choose the .ipa above → Install.
  3. On the phone: Settings → General → VPN & Device Management → trust your Apple ID.
     Then turn on Developer Mode: Settings → Privacy & Security (or: uvx pymobiledevice3 amfi reveal-developer-mode).

Free signing expires after 7 days. Re-run step 2, or install SideStore once and let it refresh on the phone.
MSG
  exit 0
fi

IPA="${IPA:-$(fetch Productium-ipa)}"
echo "==> device"
uvx pymobiledevice3 usbmux list
echo "==> installing $IPA"
uvx pymobiledevice3 apps install "$IPA"
cat <<MSG
Installed. If iOS says "Developer Mode required":
  uvx pymobiledevice3 amfi reveal-developer-mode
  then Settings → Privacy & Security → Developer Mode → On (phone restarts).
Logs while testing:  uvx pymobiledevice3 syslog live | grep -i productium
MSG
