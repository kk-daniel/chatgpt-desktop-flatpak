#!/usr/bin/env bash
# Not extra-data: OpenAI serves only a mutable "latest" URL, so a pinned
# sha256 would break every fresh install on their next release. apply_extra
# could not do this anyway -- flatpak runs it with no network. See README.
set -euo pipefail

payload_dir=/var/data/chatgpt
state_file="$payload_dir/version"
warned_file="$payload_dir/warned-version"
# Recorded at unpack time so the per-launch check is a file read, not a
# grep over a 200 MB asar.
electron_target_file="$payload_dir/electron-target"
electron_warned_file="$payload_dir/warned-electron"
lock_file="$payload_dir/.lock"
expected_file=/app/share/chatgpt/expected-version
base_url=https://persistent.oaistatic.com/codex-app-prod

case "$(uname -m)" in
  x86_64) msix_name=ChatGPT-x64.msix ;;
  aarch64) msix_name=ChatGPT-arm64.msix ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

url="$base_url/$msix_name"
expected_version="$(cat "$expected_file" 2>/dev/null || echo "")"
local_version="$(cat "$state_file" 2>/dev/null || echo "")"

# curl is the only thing standing between the user and a substituted
# payload, so never let a redirect drop it to cleartext. The timeouts stop
# a captive portal or half-open socket hanging the launcher forever behind
# a progress dialog that has no cancel button.
curl_opts=(--proto '=https' --proto-redir '=https'
           --connect-timeout 20 --speed-limit 1024 --speed-time 60)

has_gui() {
  command -v zenity >/dev/null 2>&1 &&
    { [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]; }
}

die() {
  printf '%b\n' "$1" >&2
  if has_gui; then
    zenity --error --title="ChatGPT Desktop" --width=440 \
      --text="$(printf '%b' "$1")" 2>/dev/null || true
  fi
  exit 1
}

warn() {
  printf '%b\n' "$1" >&2
  if has_gui; then
    zenity --warning --title="ChatGPT Desktop" --width=460 \
      --text="$(printf '%b' "$1")" 2>/dev/null || true
  fi
}

version_gt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

# Never let a failed marker write abort the launch: the payload is fine,
# and the caller treats any non-zero exit as fatal.
warn_once() {
  local marker="$1" token="$2" message="$3"
  [ "$(cat "$marker" 2>/dev/null || echo "")" = "$token" ] && return 0
  warn "$message"
  mkdir -p "$payload_dir" 2>/dev/null || true
  printf '%s\n' "$token" > "$marker" 2>/dev/null || true
  return 0
}

# One HEAD, not two: with a mutable URL, separate requests for version and
# size can straddle a republish.
remote_meta() {
  curl -fsSIL "${curl_opts[@]}" "$url" 2>/dev/null \
    | tr -d '\r' \
    | awk 'BEGIN{IGNORECASE=1}
           $1 == "x-ms-meta-package_version:" {v=$2}
           $1 == "content-length:" {s=$2}
           END {if (v != "") print v, (s+0)}'
}

# %XX only. printf '%b' alone would also eat backslashes and \c already in
# the name, silently mangling or truncating it.
percent_decode() {
  local s="${1//\\/\\\\}" out='' i=0 n
  n=${#s}
  while [ "$i" -lt "$n" ]; do
    if [ "${s:i:1}" = "%" ] && [[ "${s:i+1:2}" =~ ^[0-9A-Fa-f]{2}$ ]]; then
      out+="\\x${s:i+1:2}"
      i=$((i + 3))
    else
      out+="${s:i:1}"
      i=$((i + 1))
    fi
  done
  printf '%b' "$out"
}

# asar stores contents uncompressed, so package.json is greppable without
# parsing it. Bail on multiple matches: a vendored package.json would give
# a wrong version, and that is worse than no check.
record_electron_target() {
  local asar="$1" matches declared
  matches="$(grep -aoE '"electron": "[0-9][^"]*"' "$asar" 2>/dev/null | sort -u || true)"
  [ "$(printf '%s' "$matches" | grep -c . || true)" = "1" ] || return 0
  declared="$(printf '%s' "$matches" | sed 's/^"electron": "//; s/"$//')"
  [ -n "$declared" ] && printf '%s\n' "$declared" > "$electron_target_file"
  return 0
}

# Across a major, Electron removes APIs the bundle calls; a minor gap is
# routine and only worth a log line.
check_electron_drift() {
  local ours declared
  ours="$(tr -d '[:space:]' < /app/electron/version 2>/dev/null || echo "")"
  declared="$(tr -d '[:space:]' < "$electron_target_file" 2>/dev/null || echo "")"
  [ -n "$ours" ] && [ -n "$declared" ] || return 0
  [ "$ours" = "$declared" ] && return 0

  if [ "${ours%%.*}" = "${declared%%.*}" ]; then
    echo "note: payload targets Electron $declared, bundled $ours" >&2
    return 0
  fi

  warn_once "$electron_warned_file" "$declared-$ours" \
    "This ChatGPT build targets Electron $declared, but the Flatpak bundles Electron $ours.\n\nAcross a major version Electron removes APIs, so parts of the app may not work. The packaging needs updating."
}

# @parcel/watcher is absent from the MSIX entirely -- see the manifest. The
# app imports it by bare specifier from
# resources/app.asar/.vite/build/worker.js, so node walks node_modules
# upwards from there and this directory, one level above resources/, is on
# that path.
#
# Deliberately not inside resources/: there it would be destroyed by every
# payload swap, and a future payload that ships its own @parcel/watcher
# resolves from resources/ and app.asar first, so ours is shadowed rather
# than fought over.
#
# A symlink, not a copy, so a Flatpak update ships a new module without
# refetching 700 MB. Never fatal: a failure here costs the watcher, not the
# launch.
link_node_modules() {
  local target=/app/share/chatgpt/node_modules
  local link="$payload_dir/node_modules"

  [ -d "$target" ] || return 0

  # Nested rather than `[ ... ] && return 0`, which under errexit reads as a
  # deliberate fall-through only if you know the && exemption by heart.
  if [ -L "$link" ]; then
    if [ "$(readlink "$link" 2>/dev/null)" = "$target" ]; then
      return 0
    fi
    # Ours but stale -- ln -n replaces the link itself, not its target.
  elif [ -e "$link" ]; then
    # A real directory is not ours to replace.
    return 0
  fi

  ln -sfn "$target" "$link" 2>/dev/null || true
  return 0
}

# errexit does NOT apply inside this function: both call sites test its
# status (`if unpack` / `unpack || rc=$?`), which suspends errexit for the
# whole dynamic extent. Every failure that matters must be checked by hand
# or a broken payload gets marked as successfully installed.
unpack() {
  local msix="$1" work_dir="$2"
  local pkg="$work_dir/pkg"

  # The MSIX is a plain zip.
  7z x -y "$msix" -o"$pkg" 'app/resources/*' 'assets/*' AppxManifest.xml >/dev/null || return 1

  local manifest="$pkg/AppxManifest.xml"
  [ -f "$manifest" ] || return 1

  # Not signature verification -- these are greps over bytes that came out
  # of the archive under test. It catches a wrong or truncated artifact at
  # the end of the URL, nothing adversarial.
  grep -q 'Name="OpenAI.Codex"' "$manifest" || return 2
  grep -q 'Publisher="CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B"' "$manifest" || return 2

  # Authoritative version: taken from the bytes on disk rather than the
  # HEAD, which could describe a different build after a republish.
  local version
  version="$(sed -n 's/.*<Identity[^>]*Version="\([0-9][0-9.]*\)".*/\1/p' "$manifest" | head -n 1)"
  [ -n "$version" ] || return 1

  [ -f "$pkg/app/resources/app.asar" ] || return 1
  [ -d "$pkg/assets" ] || return 1

  record_electron_target "$pkg/app/resources/app.asar"

  rm -f "$msix"
  cd "$pkg" || return 1

  # MSIX percent-encodes OPC-illegal characters, so scoped packages arrive
  # as %40scope and require('@scope/pkg') misses. Depth-first, so a
  # directory is renamed only after its children.
  local encoded dir base decoded
  while IFS= read -r -d '' encoded; do
    dir="$(dirname -- "$encoded")"
    base="$(basename -- "$encoded")"
    decoded="$(percent_decode "$base")"
    [ "$base" = "$decoded" ] && continue
    # A decoded name is a name, never a path: %2e%2e%2f would otherwise
    # walk mv out of the extraction directory.
    case "$decoded" in */*|.|..|'') continue ;; esac
    mv -T -- "$dir/$base" "$dir/$decoded" || return 1
  done < <(find . -depth -name '*%*' -print0)

  # Safe to drop: OpenAI ships Linux ELF codex/codex-code-mode-host/rg in
  # the same package (they are what the Windows app runs under WSL).
  find app/resources \
    \( -name '*.exe' -o -name '*.dll' -o -name '*.cmd' -o -name '*.ps1' \) \
    -type f -delete || return 1

  local helper
  for helper in codex codex-code-mode-host rg; do
    if [ -f "app/resources/$helper" ]; then
      chmod +x "app/resources/$helper" || return 1
    fi
  done

  # A missing slot is fatal rather than skipped: without the Linux
  # better-sqlite3 the app starts and then fails every session store.
  local unpacked="app/resources/app.asar.unpacked/node_modules"
  local pair src dest
  for pair in \
    "better_sqlite3.node:$unpacked/better-sqlite3/build/Release/better_sqlite3.node" \
    "pty.node:$unpacked/node-pty/build/Release/pty.node"
  do
    src="/app/share/chatgpt/native/${pair%%:*}"
    dest="${pair#*:}"
    [ -f "$src" ] || return 3
    [ -f "$dest" ] || return 3
    install -Dm755 "$src" "$dest" || return 3
  done

  rm -f "$unpacked/node-pty/build/Release/conpty.node" \
        "$unpacked/node-pty/build/Release/conpty_console_list.node"

  # Version marker dropped first, so an interrupted swap never leaves
  # something that later looks installed.
  rm -f "$state_file"
  rm -rf "$payload_dir/resources.old" "$payload_dir/assets.old"
  [ -d "$payload_dir/resources" ] && { mv -T "$payload_dir/resources" "$payload_dir/resources.old" || return 1; }
  [ -d "$payload_dir/assets" ] && { mv -T "$payload_dir/assets" "$payload_dir/assets.old" || return 1; }
  mv -T app/resources "$payload_dir/resources" || return 1
  mv -T assets "$payload_dir/assets" || return 1
  rm -rf "$payload_dir/resources.old" "$payload_dir/assets.old"

  printf '%s\n' "$version" > "$state_file" || return 1
  printf '%s' "$version"
}

fetch() {
  local version="$1" size="$2"

  mkdir -p "$payload_dir"

  # Needs the download plus the extracted tree plus the outgoing payload
  # all at once. Without this the extraction dies half-way, and because
  # errexit is off in unpack() that used to be recorded as a good install.
  local need_kb avail_kb
  need_kb=$(( (size / 1024) + 1600000 ))
  avail_kb="$(df -Pk "$payload_dir" | awk 'NR==2 {print $4}')"
  if [ -n "$avail_kb" ] && [ "$avail_kb" -lt "$need_kb" ]; then
    die "Not enough disk space to install ChatGPT.\n\nAbout $(( need_kb / 1024 )) MB is needed in $payload_dir but only $(( avail_kb / 1024 )) MB is free."
  fi

  # Only safe under the lock: another instance's in-flight directory would
  # otherwise be deleted out from under it.
  rm -rf "$payload_dir"/.fetch.*
  local work_dir
  work_dir="$(mktemp -d "$payload_dir/.fetch.XXXXXX")" || die "Could not create a working directory in $payload_dir."
  # No RETURN trap: it is not function-local, so it would fire again when
  # the caller returns, with work_dir out of scope. die() exits without
  # cleaning up; the lock-guarded sweep above catches that next run.

  local msix="$work_dir/$msix_name"
  echo "Downloading ChatGPT $version ($(( size / 1048576 )) MiB)..." >&2

  if has_gui; then
    curl -fL "${curl_opts[@]}" --silent --show-error "$url" -o "$msix" &
    local curl_pid=$!
    # curl's progress output is not machine-readable; drive zenity from
    # the growing file instead.
    (
      while kill -0 "$curl_pid" 2>/dev/null; do
        now="$(stat -c %s "$msix" 2>/dev/null || echo 0)"
        if [ "$size" -gt 0 ]; then
          printf '%s\n' "$(( now * 100 / size ))"
          printf '# Downloading ChatGPT %s — %s / %s MiB\n' \
            "$version" "$(( now / 1048576 ))" "$(( size / 1048576 ))"
        fi
        sleep 0.5
      done
      printf '100\n'
    ) | zenity --progress --title="ChatGPT Desktop" \
          --text="Contacting OpenAI..." --percentage=0 --auto-close \
          --width=460 2>/dev/null || true
    wait "$curl_pid" || die "Download failed.\n\nCheck your network connection and try again."
  else
    curl -fL "${curl_opts[@]}" --progress-bar "$url" -o "$msix" \
      || die "Download failed.\n\nCheck your network connection and try again."
  fi

  echo "Unpacking..." >&2
  local rc=0 installed=""
  if has_gui; then
    # Redirect scoped to the status echo alone: covering the whole `if`
    # would prepend anything unpack writes to stdout to the exit code.
    ( if installed="$(unpack "$msix" "$work_dir")"; then
        printf '0\n%s\n' "$installed" > "$work_dir/rc"
      else
        printf '%s\n' "$?" > "$work_dir/rc"
      fi ) &
    local unpack_pid=$!
    (
      while kill -0 "$unpack_pid" 2>/dev/null; do
        printf '# Unpacking ChatGPT %s...\n' "$version"
        sleep 0.5
      done
    ) | zenity --progress --title="ChatGPT Desktop" --text="Unpacking..." \
          --pulsate --auto-close --width=460 2>/dev/null || true
    wait "$unpack_pid" || true
    rc="$(head -n 1 "$work_dir/rc" 2>/dev/null || echo 1)"
    installed="$(sed -n 2p "$work_dir/rc" 2>/dev/null || echo "")"
  else
    installed="$(unpack "$msix" "$work_dir")" || rc=$?
  fi

  case "$rc" in
    0) ;;
    2) die "The downloaded package is not OpenAI's ChatGPT package.\n\nRefusing to install it." ;;
    3) die "The package layout changed and this Flatpak's Linux native modules no longer fit it.\n\nThe packaging needs updating." ;;
    *) die "Unpacking the ChatGPT package failed.\n\nThere may not be enough disk space." ;;
  esac

  rm -rf "$work_dir"
  echo "ChatGPT ${installed:-$version} installed to $payload_dir" >&2
}

ensure_payload() {
  local meta version size

  # Both directories, because /app/electron symlinks to each of them.
  if [ -z "$local_version" ] || [ ! -d "$payload_dir/resources" ] || [ ! -d "$payload_dir/assets" ]; then
    meta="$(remote_meta)"
    [ -n "$meta" ] || die "Could not reach OpenAI to download ChatGPT, and no copy is installed yet.\n\nCheck your network connection and try again."
    fetch "${meta% *}" "${meta#* }"
    return 0
  fi

  [ "$local_version" = "$expected_version" ] && return 0

  if version_gt "$local_version" "$expected_version"; then
    warn_once "$warned_file" "$local_version" \
      "ChatGPT $local_version is installed, which is newer than the build this Flatpak was tested against ($expected_version).\n\nIt will be used as-is. The Linux-specific fixes in this package are not verified against it, so if something misbehaves, that is the likely reason."
    return 0
  fi

  # Older than expected: usually after a Flatpak update.
  meta="$(remote_meta)"
  if [ -z "$meta" ]; then
    echo "Offline; continuing with installed ChatGPT $local_version" >&2
    return 0
  fi
  version="${meta% *}"
  size="${meta#* }"

  if [ "$version" = "$local_version" ]; then
    echo "OpenAI still serves $version; continuing with what is installed" >&2
    return 0
  fi

  if version_gt "$local_version" "$version"; then
    echo "OpenAI serves older ChatGPT $version; continuing with installed $local_version" >&2
    return 0
  fi

  fetch "$version" "$size"
}

# The url-handler .desktop entry means a codex:// login link starts another
# instance, so two of these can run at once. Serialise: concurrent fetches
# would delete each other's work directories and interleave the swap.
mkdir -p "$payload_dir"
exec 9>"$lock_file"
flock 9

ensure_payload
# Both outside ensure_payload: drift can appear because the Flatpak's
# Electron moved, not because the payload did, and the link has to be
# re-checked on a payload that was already installed by an earlier build.
check_electron_drift
link_node_modules
