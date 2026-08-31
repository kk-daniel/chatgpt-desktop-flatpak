#!/bin/bash
# Install the broker into the user's own systemd session. No root, and nothing
# outside $HOME: the broker needs no privilege beyond the ownership of the
# namespaces flatpak created for this user.
set -euo pipefail

APP=${1:-com.openai.ChatGPT}
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
LIBEXEC=${XDG_DATA_HOME:-$HOME/.local}/libexec/flatpak-bwrap-broker
UNITS=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user

# The service template hardcodes %h/.local/libexec, so keep the two agreed even
# when XDG_DATA_HOME says otherwise.
LIBEXEC=$HOME/.local/libexec/flatpak-bwrap-broker

case "$APP" in
  -h|--help|help)
    echo "usage: $0 [APP_ID]"
    echo "  installs and starts the broker for APP_ID (default com.openai.ChatGPT)"
    exit 0 ;;
esac

command -v systemctl >/dev/null || { echo "systemd --user is required"; exit 1; }

kernel=$(uname -r | cut -d. -f1,2)
case "$kernel" in
  [0-5].*|6.[0-4]) echo "warning: SO_PEERPIDFD needs Linux 6.5+, found $kernel" ;;
esac

echo "installing to $LIBEXEC"
install -d "$LIBEXEC" "$UNITS"
install -Dm755 "$HERE/flatpak-bwrap-broker" "$LIBEXEC/flatpak-bwrap-broker"
install -Dm644 "$HERE/seccomp_policy.py" "$LIBEXEC/seccomp_policy.py"
install -Dm644 "$HERE/flatpak-bwrap-broker@.socket" "$UNITS/flatpak-bwrap-broker@.socket"
install -Dm644 "$HERE/flatpak-bwrap-broker@.service" "$UNITS/flatpak-bwrap-broker@.service"

systemctl --user daemon-reload
systemctl --user enable --now "flatpak-bwrap-broker@$APP.socket"

# The service is socket-activated but long-lived: it accepts in a loop rather
# than per connection, so an already-running instance keeps the code that was
# installed before this run. Reinstalling has to replace it, or the change
# being installed is not the one being tested.
if systemctl --user --quiet is-active "flatpak-bwrap-broker@$APP.service"; then
  echo "restarting the running broker so it picks up this build"
  systemctl --user restart "flatpak-bwrap-broker@$APP.service"
fi

echo
systemctl --user --no-pager status "flatpak-bwrap-broker@$APP.socket" || true
echo
echo "protocol version: $(python3 -c "
import re
src = open('$LIBEXEC/flatpak-bwrap-broker').read()
print(re.search(r'PROTOCOL_VERSION = (\d+)', src).group(1))" 2>/dev/null || echo unknown)"
echo "Re-run this installed Flatpak's sandbox-host/install.sh after every update:"
echo "the update replaces the client but cannot touch an existing host service."
echo
echo "socket: ${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/app/$APP/bwrap-broker.sock"
echo "logs:   journalctl --user -u flatpak-bwrap-broker@$APP.service -f"
echo
echo "to remove:"
echo "  systemctl --user disable --now flatpak-bwrap-broker@$APP.socket"
echo "  rm -rf $LIBEXEC $UNITS/flatpak-bwrap-broker@.{socket,service}"
