#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

metainfo="com.openai.ChatGPT.metainfo.xml"

version="$(cat expected-version 2>/dev/null || echo "")"

if [ -z "$version" ]; then
  echo "Error: expected-version is missing or empty" >&2
  echo "Run update-expected-version.sh first." >&2
  exit 1
fi

date="$(date +%Y-%m-%d)"

if grep -q "version=\"$version\"" "$metainfo"; then
  sed -i "s/<release version=\"$version\" date=\"[^\"]*\"/<release version=\"$version\" date=\"$date\"/" "$metainfo"
else
  sed -i "/<releases>/a\\    <release version=\"$version\" date=\"$date\"/>" "$metainfo"
fi

echo "Metainfo updated for ChatGPT $version"
