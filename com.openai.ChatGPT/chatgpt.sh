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

# The bwrap shim cannot hand a sandboxed command the caller's /tmp: the
# portal always gives the child a fresh private tmpfs. Left unset, Codex
# keeps declaring a policy the sandbox does not implement. Only ever adds --
# an existing setting of either key is left alone, including an explicit
# false, and any failure here costs the setting, not the launch.
ensure_codex_sandbox_config() {
  local cfg="$HOME/.codex/config.toml"
  local section='[sandbox_workspace_write]'
  local tmp

  grep -qs 'exclude_slash_tmp\|exclude_tmpdir_env_var' "$cfg" && return 0

  if [ ! -f "$cfg" ]; then
    printf '%s\nexclude_slash_tmp = true\nexclude_tmpdir_env_var = true\n' \
      "$section" > "$cfg" 2>/dev/null && log "Created $cfg with sandbox tmp settings"
    return 0
  fi

  if grep -qsF "$section" "$cfg"; then
    tmp="$cfg.chatgpt-new"
    awk -v sec="$section" '
      { print }
      index($0, sec) == 1 && !done {
        print "exclude_slash_tmp = true"
        print "exclude_tmpdir_env_var = true"
        done = 1
      }
    ' "$cfg" > "$tmp" 2>/dev/null &&
      mv "$tmp" "$cfg" 2>/dev/null &&
      log "Added sandbox tmp settings under existing $section"
    rm -f "$tmp" 2>/dev/null
  else
    # A table header at end of file is always valid TOML and cannot land
    # inside another table's scope.
    printf '\n%s\nexclude_slash_tmp = true\nexclude_tmpdir_env_var = true\n' \
      "$section" >> "$cfg" 2>/dev/null && log "Appended $section to $cfg"
  fi
  return 0
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
ensure_codex_sandbox_config

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
# of our shim and then die on the blocked namespace syscalls.
PATH="/app/bin:$PATH"
export PATH
log "PATH=$PATH"
log "bwrap resolves to: $(command -v bwrap || echo '<none>')"

exec /app/bin/zypak-wrapper.sh /app/electron/electron "${electron_args[@]}" "$@"
