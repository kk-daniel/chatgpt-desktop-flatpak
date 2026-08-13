#!/usr/bin/env bash
# Points the bundled Electron at whatever the current ChatGPT payload is
# built against.
#
# Electron is not a dependency this packaging chooses. The app is built
# against one exact version, its native modules compile against that
# version's headers, and across a major Electron removes APIs the bundle
# calls -- so the only correct value is the one the payload declares. It
# was tracked by Renovate for a while, which meant Renovate proposing
# upgrades the app cannot use: an Electron 43 bump sat green in CI because
# the end-to-end test that would have caught it does not run on pull
# requests.
#
# So it follows the payload instead, and runs where the payload version
# changes. Reading the declaration costs a couple of seconds and about 8 MB
# rather than the 640 MB download -- see read-payload-electron.py.
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

manifest="com.openai.ChatGPT.yaml"

# Both archives, not just x64: update-electron-checksum.sh writes them from
# one version so these scripts cannot make them disagree, but a hand edit
# can -- and nothing else in this repo looks at the aarch64 one.
pinned() {
  sed -n "s#.*releases/download/v\([0-9][0-9.]*\)/electron-v.*-linux-$1\.zip.*#\1#p" \
    "$manifest" | head -n 1
}
current="$(pinned x64)"
current_arm="$(pinned arm64)"
[ -n "$current" ] && [ -n "$current_arm" ] \
  || { echo "Error: no Electron version in $manifest" >&2; exit 1; }
if [ "$current" != "$current_arm" ]; then
  echo "Error: $manifest pins Electron $current for x64 and $current_arm for arm64." >&2
  echo "Reconcile them before this can tell what is bundled." >&2
  exit 1
fi

# No guard on the result: under set -e a failing command substitution in an
# assignment already aborts, so a check here would never run.
declared="$(./read-payload-electron.py)"

if [ "$current" = "$declared" ]; then
  echo "Already current: Electron $current"
  exit 0
fi

# A major bump drags the node headers the native modules compile against,
# and an addon built against the wrong ABI fails at dlopen on the user's
# machine rather than here. Stopping is the point: this script runs on a
# branch that automerges, and a failure blocks that -- build only proceeds
# when post-renovate is skipped, and nothing merges a red pull request.
if [ "${current%%.*}" != "${declared%%.*}" ]; then
  echo "Error: ChatGPT now targets Electron $declared, this bundles $current." >&2
  echo "Crossing a major needs a human: the native modules and the Electron" >&2
  echo "BaseApp both have to be checked against it. Run" >&2
  echo "  ./update-electron-checksum.sh $declared" >&2
  echo "and verify the build before merging." >&2
  exit 1
fi

echo "ChatGPT targets Electron $declared, bundling $current -- updating"
./update-electron-checksum.sh "$declared"
