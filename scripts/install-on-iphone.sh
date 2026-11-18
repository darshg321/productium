#!/usr/bin/env bash
# Get the CI-built app onto a USB-connected iPhone, from Linux.
#
#   ./scripts/install-on-iphone.sh                 # download the latest release's .ipa, sign it with Impactor (free Apple ID)
#   ./scripts/install-on-iphone.sh path/to/app.ipa # install an already-signed .ipa
#
# Uses the GitHub CLI (gh) to fetch artifacts and pymobiledevice3 (through uvx) to install.
set -euo pipefail

IPA="${1:-}"

fetch_release() {  # the latest GitHub release's stable asset name
  command -v gh >/dev/null || { echo "install the GitHub CLI (gh), or pass an .ipa path"; exit 1; }
  local dir
  dir=$(mktemp -d)
  gh release download --pattern Productium-free.ipa -D "$dir" >&2
  echo "$dir/Productium-free.ipa"
}

if [[ -z "$IPA" ]]; then
  IPA="$(fetch_release)"
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
