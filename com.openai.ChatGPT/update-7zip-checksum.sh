#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

manifest="com.openai.ChatGPT.yaml"

manifest_url() {
  local arch="$1"
  awk -v arch="$arch" '
    /url: https:\/\/github\.com\/ip7z\/7zip\/releases\/download\// && index($0, "linux-" arch ".tar.xz") {
      print $2
      exit
    }
  ' "$manifest"
}

update_arch() {
  local arch="$1"
  local url tmp sha
  url="$(manifest_url "$arch")"
  if [ -z "$url" ]; then
    echo "Error: could not find 7-Zip $arch URL in $manifest" >&2
    exit 1
  fi

  tmp="$(mktemp)"
  trap 'rm -f "$tmp" "$tmp.manifest"' RETURN

  echo "Downloading 7-Zip $arch..."
  curl -fL "$url" -o "$tmp"
  sha="$(sha256sum "$tmp" | cut -d' ' -f1)"

  awk -v arch="$arch" -v sha="$sha" '
    /url: https:\/\/github\.com\/ip7z\/7zip\/releases\/download\// && index($0, "linux-" arch ".tar.xz") {
      in_block = 1
    }
    in_block && /sha256:/ {
      sub(/sha256: .*/, "sha256: " sha)
      in_block = 0
    }
    { print }
  ' "$manifest" > "$tmp.manifest"
  mv "$tmp.manifest" "$manifest"

  echo "Updated 7-Zip $arch: sha256=$sha"
}

update_arch x64
update_arch arm64

echo "7-Zip checksums updated"
