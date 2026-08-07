#!/usr/bin/env bash
# Re-pins the Electron archives after a version bump, and drags the node
# headers tarball along with them. The headers are what the native modules
# compile against, so an Electron bump that left them behind would produce
# addons with the wrong ABI -- which fails at dlopen time on the user's
# machine, not in CI.
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

manifest="com.openai.ChatGPT.yaml"

electron_version() {
  sed -n 's#.*releases/download/v\([0-9][0-9.]*\)/electron-v.*-linux-x64\.zip.*#\1#p' "$manifest" | head -n 1
}

version="$(electron_version)"
if [ -z "$version" ]; then
  echo "Error: could not find Electron version in $manifest" >&2
  exit 1
fi

echo "Electron version: $version"

update_zip() {
  local arch="$1"
  local url tmp sha
  url="https://github.com/electron/electron/releases/download/v${version}/electron-v${version}-linux-${arch}.zip"

  tmp="$(mktemp)"
  trap 'rm -f "$tmp" "$tmp.manifest"' RETURN

  echo "Downloading Electron $arch..."
  curl -fL "$url" -o "$tmp"
  sha="$(sha256sum "$tmp" | cut -d' ' -f1)"

  awk -v arch="$arch" -v url="$url" -v sha="$sha" '
    /url: https:\/\/github\.com\/electron\/electron\/releases\/download\// && index($0, "linux-" arch ".zip") {
      in_block = 1
      sub(/url: .*/, "url: " url)
    }
    in_block && /sha256:/ {
      sub(/sha256: .*/, "sha256: " sha)
      in_block = 0
    }
    { print }
  ' "$manifest" > "$tmp.manifest"
  mv "$tmp.manifest" "$manifest"

  echo "Updated Electron $arch: sha256=$sha"
}

update_headers() {
  local url tmp sha
  url="https://artifacts.electronjs.org/headers/dist/v${version}/node-v${version}-headers.tar.gz"

  tmp="$(mktemp)"
  trap 'rm -f "$tmp" "$tmp.manifest"' RETURN

  echo "Downloading Electron node headers..."
  curl -fL "$url" -o "$tmp"
  sha="$(sha256sum "$tmp" | cut -d' ' -f1)"

  awk -v url="$url" -v sha="$sha" '
    /url: https:\/\/artifacts\.electronjs\.org\/headers\/dist\// {
      in_block = 1
      sub(/url: .*/, "url: " url)
    }
    in_block && /sha256:/ {
      sub(/sha256: .*/, "sha256: " sha)
      in_block = 0
    }
    { print }
  ' "$manifest" > "$tmp.manifest"
  mv "$tmp.manifest" "$manifest"

  echo "Updated headers: sha256=$sha"
}

update_zip x64
update_zip arm64
update_headers

echo "Electron checksums updated"
