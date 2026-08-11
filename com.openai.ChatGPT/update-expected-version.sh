#!/usr/bin/env bash
# Records the ChatGPT build this packaging is tested against.
#
# There are no MSIX checksums to maintain -- the payload is fetched at
# first launch, not pinned as extra-data -- so the only thing tracking
# upstream is this version string. It drives the drift warning in
# chatgpt-fetch and the release version in the metainfo.
#
# OpenAI's blob reports the package version in a response header, so
# checking costs one HEAD request and no download.
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

url=https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix
expected_file=expected-version

remote_version="$(
  curl -fsSIL "$url" \
    | tr -d '\r' \
    | awk 'BEGIN{IGNORECASE=1} $1 == "x-ms-meta-package_version:" {print $2}' \
    | tail -n 1
)"

if [ -z "$remote_version" ]; then
  echo "Error: could not read package version header from $url" >&2
  exit 1
fi

# The version oracle publishes this same value for Renovate to read, and
# reading the header is the whole of it -- so that workflow calls this
# rather than growing a second copy of the curl and the awk.
if [ "${1:-}" = "--print" ]; then
  printf '%s\n' "$remote_version"
  exit 0
fi

current="$(cat "$expected_file" 2>/dev/null || echo "")"

if [ "$current" = "$remote_version" ]; then
  echo "Already current: ChatGPT $remote_version"
  exit 0
fi

printf '%s\n' "$remote_version" > "$expected_file"
echo "Expected version updated: ${current:-none} -> $remote_version"
