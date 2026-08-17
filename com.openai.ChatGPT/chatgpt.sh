#!/usr/bin/env bash
set -euo pipefail

log_dir="${XDG_CACHE_HOME:-$HOME/.cache}/chatgpt-flatpak"
mkdir -p "$log_dir"
log_file="$log_dir/launcher.log"

log() {
  printf '%s\n' "$*" >> "$log_file"
}

# Sandbox diagnostics live on the host now. Every bwrap call is handled by
# flatpak-bwrap-broker, which logs to the journal:
#
#   journalctl --user -u flatpak-bwrap-broker@com.openai.ChatGPT.service -f
#
# so there is no in-sandbox log file to switch on, and no BWRAP_LOG.

# The app mkdirs its state dir non-recursively, so a missing ~/.codex makes
# the first session store fail with ENOENT.
ensure_codex_dir() {
  if [ ! -d "$HOME/.codex" ]; then
    mkdir -p "$HOME/.codex"
    log "Created $HOME/.codex"
  fi
}

# Codex used to need exclude_slash_tmp/exclude_tmpdir_env_var written into
# config.toml, because the portal could never hand a sandboxed command the
# caller's /tmp. The broker runs bubblewrap inside this sandbox's own mount
# namespace, so /tmp is simply there and Codex's default policy works. An
# existing setting from an older install is harmless and is left alone.

electron_args=()
# No --password-store here on purpose. The app has no route to the Secret
# Service -- see the manifest for why that grant is not given -- and forcing
# gnome-libsecret with nothing to talk to makes safeStorage fail rather than
# fall back, which loses the login instead of degrading it. Left unset,
# Chromium detects that no keyring is reachable and encrypts the token with a
# built-in key under the app's own data directory.
#
# Anyone who would rather have the keyring can grant it back; README.md has the
# two override commands, and ELECTRON_EXTRA_LAUNCH_ARGS is how the switch comes
# back without editing this file.

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

# /app/bin last, so it wins outright. Codex picks the first bwrap on PATH,
# and a real one there -- from a tool extension, or a host install visible
# through a --filesystem override, e.g. Homebrew's -- would be used instead
# of the broker client and then die on the blocked namespace syscalls.
PATH="/app/bin:$PATH"
export PATH
log "PATH=$PATH"
log "bwrap resolves to: $(command -v bwrap || echo '<none>')"

exec /app/bin/zypak-wrapper.sh /app/electron/electron "${electron_args[@]}" "$@"
