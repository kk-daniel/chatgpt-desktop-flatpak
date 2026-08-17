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
# Compared by direction rather than by diff: the two are not symmetric, and a
# plain diff cannot say which way a difference runs. The namespace group is not
# probed here at all -- it is the one documented difference, and
# host/test-broker.py asserts it stays allowed.
python3 "$HERE/test-seccomp-parity.py" --compare "$OUT/app" "$OUT/broker" |
  sed 's/^/  /'
exit "${PIPESTATUS[0]}"
