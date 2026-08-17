#!/bin/bash
# Does the broker's seccomp policy match flatpak's, apart from the namespace
# group it deliberately leaves open?
#
# Runs the same probe inside the app and on the host under the broker's filter.
# A difference in either direction is a bug worth knowing about:
#
#   app EPERM, broker not   the broker is wider than the flatpak
#   broker EPERM, app not   the broker refuses something the app is allowed,
#                           and a Codex command will fail for no visible reason
set -u
APP=${1:-com.openai.ChatGPT}
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(dirname "$HERE")
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

echo "== inside the app =="
flatpak run --filesystem="$ROOT:ro" --command=python3 "$APP" \
  "$HERE/test-seccomp-parity.py" | tee "$OUT/app" | sed 's/^/  /'

echo
echo "== on the host, under the broker's filter =="
python3 "$HERE/test-seccomp-parity.py" --filtered | tee "$OUT/broker" | sed 's/^/  /'

echo
echo "== differences =="
if diff -u "$OUT/app" "$OUT/broker" > "$OUT/diff"; then
  echo "  none: the broker refuses exactly what the app refuses"
  echo "  (the namespace group is not probed here -- it is the one"
  echo "   documented difference, and host/test-broker.py asserts it)"
else
  sed '1,2d' "$OUT/diff" | sed 's/^/  /'
  echo
  echo "  Each line is a syscall where the two policies disagree."
  echo "  Update BLOCKED_EPERM in host/seccomp_policy.py to match the app."
  exit 1
fi
