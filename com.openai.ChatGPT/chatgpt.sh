#!/usr/bin/env bash
set -euo pipefail
# The extension mount points below are empty unless the user installed
# something, and a loop over a literal `*` is never what is wanted here.
shopt -s nullglob

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

# Extension diagnostics go to stderr rather than the launcher log, because a
# misspelled extension name has to be visible to whoever typed it -- the log is
# for the post-mortem, not for the one line that says why nothing happened.
msg() {
  printf '%s\n' "$*" >&2
}

# Opt-in SDK extensions. Nothing is declared in the manifest for these: the
# runtime is org.freedesktop.Sdk, whose own extension point already mounts any
# installed org.freedesktop.Sdk.Extension.* at /usr/lib/sdk/<name>.
# FLATPAK_ENABLE_SDK_EXT takes a comma-separated list of short names -- golang,
# not org.freedesktop.Sdk.Extension.golang -- or "*" for everything installed:
#
#   flatpak install flathub org.freedesktop.Sdk.Extension.golang//25.08
#   flatpak run --env=FLATPAK_ENABLE_SDK_EXT=golang com.openai.ChatGPT
#
# Unset enables nothing, which is the right default: these are toolchains the
# agent can run, and they should be there because someone asked for them.
enable_sdk_extensions() {
  local spec="${FLATPAK_ENABLE_SDK_EXT:-}"
  local sdk=() dir ext
  [ -n "$spec" ] || return 0
  if [ "$spec" = "*" ]; then
    for dir in /usr/lib/sdk/*; do
      sdk+=("${dir##*/}")
    done
  else
    IFS=',' read -ra sdk <<< "$spec"
  fi
  for ext in "${sdk[@]}"; do
    [ -n "$ext" ] || continue
    if [ ! -d "/usr/lib/sdk/$ext" ]; then
      msg "Requested SDK extension \"$ext\" is not installed"
      continue
    fi
    msg "Enabling SDK extension \"$ext\""
    if [ -f "/usr/lib/sdk/$ext/enable.sh" ]; then
      # Third-party script we do not control: drop errexit and nounset so a
      # stray unset variable or failing command in it cannot take the launcher
      # down before the app ever starts. pipefail is left alone.
      set +eu
      # shellcheck source=/dev/null
      . "/usr/lib/sdk/$ext/enable.sh"
      set -eu
    else
      export PATH="$PATH:/usr/lib/sdk/$ext/bin"
    fi
  done
}

# Codex used to need exclude_slash_tmp/exclude_tmpdir_env_var written into
# config.toml, because the portal could never hand a sandboxed command the
# caller's /tmp. The broker runs bubblewrap inside this sandbox's own mount
# namespace, so /tmp is simply there and Codex's default policy works. An
# existing setting from an older install is harmless and is left alone.

browser_args=()
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
  browser_args+=("--enable-features=UseOzonePlatform,WaylandWindowDecorations" --enable-wayland-ime --wayland-text-input-version=3)
fi

if [ -n "${XRDP_SESSION:-}" ]; then
  browser_args+=(--disable-gpu --disable-software-rasterizer)
fi

ensure_codex_dir
export CHROME_DESKTOP=com.openai.ChatGPT.desktop
export ELECTRON_OZONE_PLATFORM_HINT="${ELECTRON_OZONE_PLATFORM_HINT:-wayland}"

# Tool extensions (com.visualstudio.code.tool.*) each unpack under
# /app/tools/<name>. Globbed rather than hardcoded so installing one is all a
# user has to do to make its binaries and Python packages reachable.
python_sitedir="$(python3 - <<'PY'
import os
import site

print(os.path.relpath(site.getusersitepackages(), site.getuserbase()))
PY
)"
for tool_dir in /app/tools/*; do
  tool_bin="$tool_dir/bin"
  [ -d "$tool_bin" ] && PATH="$tool_bin:$PATH"

  tool_pythondir="$tool_dir/$python_sitedir"
  if [ -d "$tool_pythondir" ]; then
    if [ -n "${PYTHONPATH:-}" ]; then
      PYTHONPATH="$PYTHONPATH:$tool_pythondir"
    else
      PYTHONPATH="$tool_pythondir"
    fi
    export PYTHONPATH
  fi
done

# Before the /app/bin prepend below, deliberately: an enable.sh is free to put
# itself at the front of PATH, and /app/bin has to end up ahead of it anyway.
enable_sdk_extensions

# /app/bin last, so it wins outright. Codex picks the first bwrap on PATH,
# and a real one there -- from a tool extension, or a host install visible
# through a --filesystem override, e.g. Homebrew's -- would be used instead
# of the broker client and then die on the blocked namespace syscalls.
PATH="/app/bin:$PATH"
export PATH
log "PATH=$PATH"
log "bwrap resolves to: $(command -v bwrap || echo '<none>')"

# OpenAI's native package supplies the Owl app shell as well as the application
# and its Linux native modules. Zypak integrates its Chromium sandbox with
# Flatpak in the same way it does for Electron-based applications.
exec /app/bin/zypak-wrapper.sh /app/extra/chatgpt/ChatGPT "${browser_args[@]}" "$@"
