#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

metainfo="com.openai.ChatGPT.metainfo.xml"
manifest="com.openai.ChatGPT.yaml"

versions="$(sed -n 's#.*linux/rpm/x86_64/chatgpt-\([0-9][0-9.]*-[0-9][0-9]*\)\.x86_64\.rpm.*#\1#p' "$manifest")"
version="$(printf '%s\n' "$versions" | head -n 1)"

if [ -z "$version" ] || [ "$(printf '%s\n' "$versions" | grep -c .)" -ne 1 ]; then
  echo "Error: expected exactly one x86_64 ChatGPT RPM URL in $manifest" >&2
  exit 1
fi

date="$(date +%Y-%m-%d)"

if grep -q "version=\"$version\"" "$metainfo"; then
  sed -i "s/<release version=\"$version\" date=\"[^\"]*\"/<release version=\"$version\" date=\"$date\"/" "$metainfo"
else
  sed -i "/<releases>/a\\    <release version=\"$version\" date=\"$date\"/>" "$metainfo"
fi

echo "Metainfo updated for ChatGPT $version"
