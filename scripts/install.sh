#!/usr/bin/env bash
# Install the latest Productium release on a USB-connected iPhone, from Linux, with a free Apple ID.
#
#   curl -fsSL https://raw.githubusercontent.com/darshg321/productium/main/scripts/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/darshg321/productium/main/scripts/install.sh | bash -s -- --dev
#
# --dev installs the latest dev build instead (Productium Dev, a separate app with its own data).
#
# Installs what's missing (flatpak, usbmuxd and Impactor), signs you in to your Apple ID the first time,
# downloads the latest build from GitHub releases, then signs it and installs it on the phone.
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

# 4. the phone
say "plug in your iPhone, unlock it and tap Trust if it asks"
read -rp "press enter when it's ready " _ < "$TTY"

# 5. download the latest release, sign it and install it
say "downloading the latest $NAME"
curl -fL --progress-bar -o "$WORK/app.ipa" "$IPA_URL"

say "signing and installing"
plumesign sign -p "$WORK/app.ipa" --apple-id --register-and-install

cat <<'MSG'

done! if it's the first time on this phone:
  - Settings → General → VPN & Device Management → trust your Apple ID
  - Settings → Privacy & Security → Developer Mode → On (the phone restarts)

a free Apple ID's signature lasts 7 days, so run this again within a week (with the same options) to keep the app opening.
MSG
