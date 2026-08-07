#!/usr/bin/env bash
set -euo pipefail

log_dir="${XDG_CACHE_HOME:-$HOME/.cache}/chatgpt-flatpak"
mkdir -p "$log_dir"
log_file="$log_dir/launcher.log"

log() {
  printf '%s\n' "$*" >> "$log_file"
}

# The app mkdirs its state dir non-recursively, so a missing ~/.codex makes
# the first session store fail with ENOENT.
ensure_codex_dir() {
  if [ ! -d "$HOME/.codex" ]; then
    mkdir -p "$HOME/.codex"
    log "Created $HOME/.codex"
  fi
}

electron_args=()
# Chromium picks its safeStorage backend from XDG_CURRENT_DESKTOP and falls
# back to a hardcoded key on unrecognised desktops, which silently defeats
# the --talk-name=org.freedesktop.secrets grant and loses the login.
electron_args+=(--password-store=gnome-libsecret)

if [ -n "${WAYLAND_DISPLAY:-}" ] && [ "${ELECTRON_OZONE_PLATFORM_HINT:-wayland}" = "wayland" ]; then
  electron_args+=("--enable-features=UseOzonePlatform,WaylandWindowDecorations" --enable-wayland-ime --wayland-text-input-version=3)
fi

if [ -n "${XRDP_SESSION:-}" ]; then
  electron_args+=(--disable-gpu --disable-software-rasterizer)
fi

ensure_codex_dir

# Populates /var/data/chatgpt, which /app/electron/{resources,assets}
# symlink to.
/app/bin/chatgpt-fetch || exit $?

# Our Electron binary is literally named "electron", which is exactly the
# name app.isPackaged uses to decide it is running from a dev checkout.
# Left unset, the app picks its development state paths (codex-dev.vdb)
# and skips packaged-only startup work.
export ELECTRON_FORCE_IS_PACKAGED=true
export CHROME_DESKTOP=com.openai.ChatGPT.desktop
export ELECTRON_OZONE_PLATFORM_HINT="${ELECTRON_OZONE_PLATFORM_HINT:-wayland}"

# Tool extensions (com.visualstudio.code.tool.*) each unpack to
# /app/tools/<name>/bin. Globbed rather than hardcoded so installing one is
# all a user has to do to make it reachable from the app.
for tool_bin in /app/tools/*/bin; do
  [ -d "$tool_bin" ] && PATH="$tool_bin:$PATH"
done
export PATH

exec /app/bin/zypak-wrapper.sh /app/electron/electron "${electron_args[@]}" "$@"
