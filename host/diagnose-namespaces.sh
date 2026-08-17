#!/bin/bash
set -u
APP=${1:-com.openai.ChatGPT}
HERE=$(cd -- "$(dirname -- "$0")" && pwd)

echo "== what the app sees of the userns limit =="
flatpak run --command=sh "$APP" -c '
  echo -n "  max_user_namespaces inside: "; cat /proc/sys/user/max_user_namespaces 2>&1
  echo -n "  writable: "; test -w /proc/sys/user/max_user_namespaces && echo yes || echo no'

echo -n "  on the host: "; cat /proc/sys/user/max_user_namespaces

echo
echo "== does flatpak pass --disable-userns to bwrap? =="
pgrep -a bwrap 2>/dev/null | head -3 || echo "  (no bwrap in ps -- flatpak may have exec'd past it)"

flatpak run --command=sh "$APP" -c 'exec sleep 600' &
HOLDER=$!
trap 'kill $HOLDER 2>/dev/null' EXIT
sleep 3

PID=$(flatpak ps --columns=application,child-pid 2>/dev/null | awk -v a="$APP" '$1==a{print $2; exit}')
if [ -z "${PID:-}" ]; then
  for p in $(pgrep -x sleep); do
    grep -qs "^name=$APP" "/proc/$p/root/.flatpak-info" && PID=$p && break
  done
fi
[ -n "${PID:-}" ] || { echo "FAIL: no sandbox pid"; exit 1; }
echo
echo "sandbox pid: $PID"
echo

# BROKER_RAISE_LIMIT=1 also tries to raise max_user_namespaces from inside, which
# weakens the confinement of the instance this script started. It is a throwaway
# `sleep` instance, not your real ChatGPT session, but it is still off unless
# asked for.
python3 "$HERE/diagnose-namespaces.py" "$PID"
