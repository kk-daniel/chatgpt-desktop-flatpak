#!/usr/bin/env bash
# Renovate can raise the bubblewrap version in the URL but not the digest beside
# it, so post-renovate runs this on the branch before the build ever sees it. A
# stale digest would fail the build, which is the safe direction -- but for the
# one component whose provenance actually matters here, "the build broke" is not
# the failure mode to settle for.
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

manifest="com.openai.ChatGPT.yaml"

url="$(awk '
  /url: https:\/\/github\.com\/containers\/bubblewrap\/releases\/download\// {
    print $2
    exit
  }
' "$manifest")"

if [ -z "$url" ]; then
  echo "Error: could not find the bubblewrap URL in $manifest" >&2
  exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp" "$tmp.manifest"' EXIT

echo "Downloading $url"
curl -fL "$url" -o "$tmp"
sha="$(sha256sum "$tmp" | cut -d' ' -f1)"

# The sha256 belongs to the first one following the bubblewrap URL: the manifest
# has several archive sources and a blind substitution would hit the wrong one.
awk -v sha="$sha" '
  /url: https:\/\/github\.com\/containers\/bubblewrap\/releases\/download\// {
    in_block = 1
  }
  in_block && /sha256:/ {
    sub(/sha256: .*/, "sha256: " sha)
    in_block = 0
  }
  { print }
' "$manifest" > "$tmp.manifest"
mv "$tmp.manifest" "$manifest"

echo "Updated bubblewrap: sha256=$sha"
