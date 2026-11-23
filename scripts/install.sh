#!/usr/bin/env bash
# Install the latest Productium release on an iPhone (USB or Wi-Fi), from Linux, with a free Apple ID.
#
#   curl -fsSL https://raw.githubusercontent.com/darshg321/productium/main/scripts/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/darshg321/productium/main/scripts/install.sh | bash -s -- --dev
#
# --dev installs the latest dev build instead (Productium Dev, a separate app with its own data).
#
# Installs what's missing (flatpak, usbmuxd and Impactor), signs you in to your Apple ID the first time,
# downloads the latest build from GitHub releases, then signs it and installs it on the phone. Wi-Fi works once the
# phone has had one USB install from this computer (that install turns Wi-Fi installs on).
# Run it again any time to update, or to refresh the app before its 7 days run out.
set -euo pipefail

APP=dev.khcrysalis.PlumeImpactor
RELEASES=https://github.com/darshg321/productium/releases
TTY=/dev/tty  # prompts still work when the script itself comes in through a pipe

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

NAME=Productium IPA_URL=$RELEASES/latest/download/Productium-free.ipa
for arg in "$@"; do
  case "$arg" in
    --dev) NAME="Productium Dev" IPA_URL=$RELEASES/download/dev-build/Productium-dev.ipa ;;
    -h|--help) echo "usage: install.sh [--dev]   (--dev: the latest dev build, Productium Dev)"; exit 0 ;;
    *) die "unknown option: $arg (try --dev)" ;;
  esac
done

[[ "$(uname -s)" == Linux ]] || die "this script is for Linux. on Windows or macOS, use Impactor or SideStore (see the README)"

# 1. system packages: flatpak (to run Impactor) and usbmuxd (to talk to the phone over USB)
install_pkgs() {
  local sudo=""; [[ $EUID -ne 0 ]] && sudo=sudo
  if command -v apt-get >/dev/null; then $sudo apt-get update && $sudo apt-get install -y "$@"
  elif command -v dnf >/dev/null; then $sudo dnf install -y "$@"
  elif command -v pacman >/dev/null; then $sudo pacman -S --needed --noconfirm "$@"
  elif command -v zypper >/dev/null; then $sudo zypper install -y "$@"
  else die "couldn't find a package manager. install these yourself and run again: $*"
  fi
}

need=()
command -v flatpak >/dev/null || need+=(flatpak)
command -v usbmuxd >/dev/null || [[ -x /usr/sbin/usbmuxd ]] || need+=(usbmuxd)
command -v curl >/dev/null || need+=(curl)
if ((${#need[@]})); then
  say "installing ${need[*]}"
  install_pkgs "${need[@]}"
fi

# 2. Impactor, which signs the app with your Apple ID and installs it
if ! flatpak info "$APP" >/dev/null 2>&1; then
  say "installing Impactor"
  flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
  flatpak install --user -y flathub "$APP"
fi
flatpak override --user --device=all "$APP"  # let it see the phone over USB

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
plumesign() { flatpak run --env=RUST_LOG=error,plumesign=info --filesystem="$WORK" --command=plumesign "$APP" "$@" < "$TTY"; }

# 3. Apple ID, only the first time (any free one works, it's what the app gets signed with)
accounts="$(plumesign account list 2>&1 || true)"
if [[ "$accounts" != *@* ]]; then
  say "sign in with your Apple ID"
  read -rp "Apple ID email: " email < "$TTY"
  plumesign account login -u "$email"
fi

# pymobiledevice3 (through uv) talks to the phone over Wi-Fi, and turns Wi-Fi installs on after a USB one
pmd3() { uvx -q pymobiledevice3 "$@" < "$TTY"; }
ensure_uv() {
  command -v uvx >/dev/null && return
  [[ -x "$HOME/.local/bin/uvx" ]] || { say "installing uv (for Wi-Fi installs)"; curl -LsSf https://astral.sh/uv/install.sh | sh; }
  export PATH="$HOME/.local/bin:$PATH"
}

# 4. the phone: USB, or Wi-Fi if it's been installed over USB from here before
say "how should it go on the phone?"
echo "  1) USB cable"
echo "  2) Wi-Fi (same network as this computer; needs one USB install from here first)"
read -rp "choose 1 or 2 [1]: " how < "$TTY"
case "${how:-1}" in
  1) VIA=usb ;;
  2) VIA=wifi ;;
  *) die "pick 1 or 2" ;;
esac

if [[ $VIA == usb ]]; then
  say "plug in your iPhone, unlock it and tap Trust if it asks"
else
  ensure_uv
  say "unlock your iPhone and keep it on the same Wi-Fi as this computer"
fi
read -rp "press enter when it's ready " _ < "$TTY"

# 5. download the latest release, sign it and install it
say "downloading the latest $NAME"
curl -fL --progress-bar -o "$WORK/app.ipa" "$IPA_URL"

if [[ $VIA == usb ]]; then
  say "signing and installing"
  plumesign sign -p "$WORK/app.ipa" --apple-id --register-and-install
  # so the next run can use Wi-Fi
  ensure_uv
  pmd3 lockdown wifi-connections on >/dev/null 2>&1 && echo "Wi-Fi installs are on for this phone (option 2 next time)" \
    || echo "couldn't turn on Wi-Fi installs; option 2 may not find the phone"
else
  say "signing"
  plumesign sign -p "$WORK/app.ipa" --apple-id -o "$WORK/signed.ipa"
  say "installing over Wi-Fi"
  pmd3 apps install "$WORK/signed.ipa" --mobdev2 \
    || die "couldn't reach the phone over Wi-Fi. check it's unlocked and on the same network, or install once over USB (option 1)"
fi

cat <<'MSG'

done! if it's the first time on this phone:
  - Settings → General → VPN & Device Management → trust your Apple ID
  - Settings → Privacy & Security → Developer Mode → On (the phone restarts)

a free Apple ID's signature lasts 7 days, so run this again within a week (with the same options) to keep the app opening.
MSG
