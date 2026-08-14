#!/usr/bin/env bash
# Installed as /app/bin/bwrap. Codex sandboxes every command it runs with
# bubblewrap, which needs unprivileged user namespaces -- and Flatpak's
# seccomp policy denies unshare/setns/mount/clone(CLONE_NEWUSER)
# unconditionally, so no bwrap invocation can work inside the sandbox.
#
# Codex looks for bwrap on PATH before falling back to its bundled copy, so
# this script takes its place and re-expresses the request as
# `flatpak-spawn --sandbox`, which the portal executes outside our seccomp
# filter. No extra permission is needed: --sandbox goes through the portal
# and can only drop privileges, unlike --host, which needs
# --talk-name=org.freedesktop.Flatpak and is a full escape.
#
# Safety property: --sandbox starts from nothing and paths are added one at
# a time, so any flag this script fails to translate can only make the
# sandbox tighter, never looser. A bad translation breaks functionality,
# not isolation.
set -euo pipefail

# The build installs this as a symlink into /var/cache. Its target exists
# only when chatgpt.sh saw BWRAP_LOG=1. Codex's filesystem helper drops
# BWRAP_LOG, HOME and the XDG variables, so neither the switch nor the log
# path can depend on that helper environment.
log_file=/app/bin/bwrap.log
orig_argv=("$@")

# Off unless chatgpt.sh created the symlink target. Every command Codex runs
# passes through here and the file has no rotation, so logging by default
# would grow without bound for the sake of the rare session that needs
# explaining. Turn it on with
#
#   flatpak override --user --env=BWRAP_LOG=1 com.openai.ChatGPT
#
# and note that a refusal only reaches stderr otherwise -- which Codex
# swallows when the command fails.
log() {
  [ -f "$log_file" ] || return 0
  printf '%s\n' "$*" >> "$log_file" 2>/dev/null || true
}

# Every invocation is recorded once logging is on, not just the failures:
# an empty log is itself the answer then -- it means Codex never reached
# this shim, which points at PATH rather than at the translation below.
log "CALL[$$] cwd=$(pwd -P 2>/dev/null): $(printf '%q ' "$@")"

# Codex's real command line cannot be read out of its binary, so anything
# untranslatable is refused loudly, and recorded when the log is on. That
# log is how the translation table below gets completed.
refuse() {
  log "REFUSED: $1"
  log "  argv: $(printf '%q ' "${orig_argv[@]}")"
  printf 'bwrap-shim: unsupported: %s\n' "$1" >&2
  exit 1
}

print_help() {
  cat <<'EOF'
usage: bwrap [OPTIONS...] [--] COMMAND [ARGS...]

    --help                       Print this help
    --version                    Print version
    --args FD                    Parse NUL-separated args from FD
    --argv0 VALUE                Set argv[0] to the value VALUE before running the program
    --level-prefix               Prepend e.g. <3> to diagnostic messages
    --unshare-all                Unshare every namespace we support by default
    --share-net                  Retain the network namespace (can only combine with --unshare-all)
    --unshare-user               Create new user namespace (may be automatically implied if not setuid)
    --unshare-user-try           Create new user namespace if possible else continue by skipping it
    --unshare-ipc                Create new ipc namespace
    --unshare-pid                Create new pid namespace
    --unshare-net                Create new network namespace
    --unshare-uts                Create new uts namespace
    --unshare-cgroup             Create new cgroup namespace
    --unshare-cgroup-try         Create new cgroup namespace if possible else continue by skipping it
    --userns FD                  Use this user namespace (cannot combine with --unshare-user)
    --userns2 FD                 After setup switch to this user namespace, only useful with --userns
    --disable-userns             Disable further use of user namespaces inside sandbox
    --assert-userns-disabled     Fail unless further use of user namespace inside sandbox is disabled
    --pidns FD                   Use this pid namespace (as parent namespace if using --unshare-pid)
    --uid UID                    Custom uid in the sandbox (requires --unshare-user or --userns)
    --gid GID                    Custom gid in the sandbox (requires --unshare-user or --userns)
    --hostname NAME              Custom hostname in the sandbox (requires --unshare-uts)
    --chdir DIR                  Change directory to DIR
    --clearenv                   Unset all environment variables
    --setenv VAR VALUE           Set an environment variable
    --unsetenv VAR               Unset an environment variable
    --lock-file DEST             Take a lock on DEST while sandbox is running
    --sync-fd FD                 Keep this fd open while sandbox is running
    --bind SRC DEST              Bind mount the host path SRC on DEST
    --bind-try SRC DEST          Equal to --bind but ignores non-existent SRC
    --dev-bind SRC DEST          Bind mount the host path SRC on DEST, allowing device access
    --dev-bind-try SRC DEST      Equal to --dev-bind but ignores non-existent SRC
    --ro-bind SRC DEST           Bind mount the host path SRC readonly on DEST
    --ro-bind-try SRC DEST       Equal to --ro-bind but ignores non-existent SRC
    --bind-fd FD DEST            Bind open directory or path fd on DEST
    --ro-bind-fd FD DEST         Bind open directory or path fd read-only on DEST
    --remount-ro DEST            Remount DEST as readonly; does not recursively remount
    --overlay-src SRC            Read files from SRC in the following overlay
    --overlay RWSRC WORKDIR DEST Mount overlayfs on DEST, with RWSRC as the host path for writes and
                                 WORKDIR an empty directory on the same filesystem as RWSRC
    --tmp-overlay DEST           Mount overlayfs on DEST, with writes going to an invisible tmpfs
    --ro-overlay DEST            Mount overlayfs read-only on DEST
    --exec-label LABEL           Exec label for the sandbox
    --file-label LABEL           File label for temporary sandbox content
    --proc DEST                  Mount new procfs on DEST
    --dev DEST                   Mount new dev on DEST
    --tmpfs DEST                 Mount new tmpfs on DEST
    --mqueue DEST                Mount new mqueue on DEST
    --dir DEST                   Create dir at DEST
    --file FD DEST               Copy from FD to destination DEST
    --bind-data FD DEST          Copy from FD to file which is bind-mounted on DEST
    --ro-bind-data FD DEST       Copy from FD to file which is readonly bind-mounted on DEST
    --symlink SRC DEST           Create symlink at DEST with target SRC
    --seccomp FD                 Load and use seccomp rules from FD (not repeatable)
    --add-seccomp-fd FD          Load and use seccomp rules from FD (repeatable)
    --block-fd FD                Block on FD until some data to read is available
    --userns-block-fd FD         Block on FD until the user namespace is ready
    --info-fd FD                 Write information about the running container to FD
    --json-status-fd FD          Write container status to FD as multiple JSON documents
    --new-session                Create a new terminal session
    --die-with-parent            Kills with SIGKILL child process (COMMAND) when bwrap or bwrap's parent dies.
    --as-pid-1                   Do not install a reaper process with PID=1
    --cap-add CAP                Add cap CAP when running as privileged user
    --cap-drop CAP               Drop cap CAP when running as privileged user
    --perms OCTAL                Set permissions of next argument (--bind-data, --file, etc.)
    --size BYTES                 Set size of next argument (only for --tmpfs)
    --chmod OCTAL PATH           Change permissions of PATH (must already exist)
EOF
}

# --- expand --args FD ---------------------------------------------------
# bwrap accepts a NUL-separated argument list on a file descriptor. Splice
# it in before parsing; the list may itself contain another --args.
argv=()
pending=("$@")
while [ "${#pending[@]}" -gt 0 ]; do
  arg="${pending[0]}"
  pending=("${pending[@]:1}")
  if [ "$arg" = "--args" ]; then
    fd="${pending[0]:-}"
    pending=("${pending[@]:1}")
    [[ "$fd" =~ ^[0-9]+$ ]] || refuse "--args with non-numeric fd '$fd'"
    [ -r "/proc/self/fd/$fd" ] || refuse "--args fd $fd is not readable"
    spliced=()
    while IFS= read -r -d '' word; do
      spliced+=("$word")
    done < "/proc/self/fd/$fd"
    pending=("${spliced[@]}" "${pending[@]}")
    continue
  fi
  argv+=("$arg")
done

# A normal command receives the user's shell environment. The sandboxed
# filesystem helper does not: exec-server preserves only PATH and temporary
# directory variables before launching codex-linux-sandbox. Reconstruct the
# Flatpak runtime values the portal shim itself needs. Bash resolves a bare
# tilde through passwd when HOME is unset, avoiding another runtime dependency.
uid="$EUID"
if [ -z "${HOME:-}" ]; then
  HOME=~
  [ -n "$HOME" ] && [ "$HOME" != "~" ] ||
    refuse "cannot determine HOME for uid $uid"
  export HOME
fi
export FLATPAK_ID="${FLATPAK_ID:-com.openai.ChatGPT}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$uid}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

# Flatpak maps data, config, cache, tmp and --persist paths from private
# per-app storage to guest names such as /var/data and $HOME/.codex.
# flatpak-spawn opens path exposures in the caller and the portal validates
# that the same absolute host path names the same inode. The guest spelling
# of a remapped mount fails that check, so all child-visible paths use their
# ~/.var/app/<id>/... host spelling.
app_root="$HOME/.var/app/$FLATPAK_ID"
app_root_esc_data="${app_root}/data"
app_root_esc_config="${app_root}/config"
app_root_esc_cache="${app_root}/cache"
app_root_esc_tmp="${app_root}/cache/tmp"
app_root_esc_codex="${app_root}/.codex"
host_path() {
  case "$1" in
    /var/data) printf '%s' "$app_root/data" ;;
    /var/data/*) printf '%s' "$app_root/data/${1#/var/data/}" ;;
    /var/config) printf '%s' "$app_root/config" ;;
    /var/config/*) printf '%s' "$app_root/config/${1#/var/config/}" ;;
    /var/cache) printf '%s' "$app_root/cache" ;;
    /var/cache/*) printf '%s' "$app_root/cache/${1#/var/cache/}" ;;
    /var/tmp) printf '%s' "$app_root/cache/tmp" ;;
    /var/tmp/*) printf '%s' "$app_root/cache/tmp/${1#/var/tmp/}" ;;
    "$HOME/.codex") printf '%s' "$app_root/.codex" ;;
    "$HOME/.codex"/*) printf '%s' "$app_root/.codex/${1#"$HOME"/.codex/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

rewrite_mapped_paths() {
  local value="$1"
  value="${value//\/var\/data/$app_root_esc_data}"
  value="${value//\/var\/config/$app_root_esc_config}"
  value="${value//\/var\/cache/$app_root_esc_cache}"
  value="${value//\/var\/tmp/$app_root_esc_tmp}"
  value="${value//"$HOME"\/.codex/$app_root_esc_codex}"
  printf '%s' "$value"
}

# --- translate ----------------------------------------------------------
spawn=(--sandbox)
cmd=()
exposed=()
have_chdir=0
argv0=""
i=0
n=${#argv[@]}

# $4 = "try": skip silently when the path does not exist. Codex's masks
# and the *-try binds both name paths that may be absent (its own policy
# says missing_path_behavior: skip), and the portal errors out rather than
# ignoring a missing exposure.
expose() {
  local kind="$1" src="$2" dst="$3" tolerate="${4:-}" mapped
  # The portal exposes a path at its own location; it cannot remap.
  [ "$src" = "$dst" ] || refuse "$kind $src -> $dst (portal cannot remap paths)"
  # The portal cannot expose / itself. A read-only root bind does include all
  # of the outer Flatpak's private state, though, so expose its host backing
  # root read-only. More specific writable exposures remain nested overrides.
  if [ "$src" = "/" ]; then
    if [ "$kind" = "--sandbox-expose-path-ro" ] && [ -e "$app_root" ]; then
      spawn+=("$kind=$app_root")
      exposed+=("$app_root")
    fi
    return 0
  fi
  # /tmp cannot be exposed at all -- it is a per-instance tmpfs, so the
  # child always gets a fresh private one. That matches what Codex is
  # after; set exclude_slash_tmp/exclude_tmpdir_env_var under
  # [sandbox_workspace_write] so it stops asking for the shared one.
  case "$src" in /tmp|/tmp/*) return 0 ;; esac
  mapped="$(host_path "$src")"
  if [ ! -e "$mapped" ]; then
    [ -n "$tolerate" ] && return 0
    refuse "$kind $src does not exist"
  fi
  spawn+=("$kind=$mapped")
  exposed+=("$src")
}

# Codex masks a directory inside a writable bind with
# `--perms 555 --tmpfs X --remount-ro X`. A nested read-only exposure
# overrides a writable parent, so this preserves the part that matters --
# the agent cannot write X. It does not hide X's contents the way an empty
# tmpfs does; that difference is documented in SANDBOXING.md.
mask() {
  local path="$1"
  case "$path" in /|/tmp|/tmp/*) return 0 ;; esac
  expose --sandbox-expose-path-ro "$path" "$path" try
}

while [ "$i" -lt "$n" ]; do
  a="${argv[i]}"
  case "$a" in
    --) i=$((i + 1)); break ;;

    # Callers probe these to decide whether bwrap is usable at all. The
    # version is what this shim emulates, not a binary that is present.
    --version) echo "bubblewrap 0.11.0"; exit 0 ;;
    # Codex feature-detects by running `bwrap --help` and looking for
    # --perms; without it the whole shim is rejected with "no system bwrap
    # was found on PATH". So this prints bubblewrap's real option list, not
    # a description of the shim. Flags listed but not translated below are
    # refused at call time and logged, which is louder than failing
    # detection and silently disabling the sandbox.
    --help) print_help; exit 0 ;;

    --ro-bind)
      expose --sandbox-expose-path-ro "${argv[i+1]:-}" "${argv[i+2]:-}"; i=$((i + 3)) ;;
    --ro-bind-try)
      expose --sandbox-expose-path-ro "${argv[i+1]:-}" "${argv[i+2]:-}" try; i=$((i + 3)) ;;
    --bind|--dev-bind)
      expose --sandbox-expose-path "${argv[i+1]:-}" "${argv[i+2]:-}"; i=$((i + 3)) ;;
    --bind-try|--dev-bind-try)
      expose --sandbox-expose-path "${argv[i+1]:-}" "${argv[i+2]:-}" try; i=$((i + 3)) ;;

    --unshare-net|--unshare-all)
      spawn+=(--no-network); i=$((i + 1)) ;;
    # The portal already gives the child its own namespaces.
    --unshare-user|--unshare-user-try|--unshare-ipc|--unshare-pid|--unshare-uts|--unshare-cgroup|--unshare-cgroup-try|--share-net|--new-session|--as-pid-1|--level-prefix|--disable-userns|--assert-userns-disabled)
      i=$((i + 1)) ;;
    # Meaningless in the portal child: it has no capabilities to add or
    # drop, gets its own ids, and permissions/labels are not expressible.
    # Codex re-execs its own binary and dispatches on argv[0]; flatpak-spawn
    # has no equivalent, so this is replayed with `exec -a` below.
    --argv0) argv0="${argv[i+1]:-}"; i=$((i + 2)) ;;
    --uid|--gid|--hostname|--cap-add|--cap-drop|--perms|--size|--lock-file|--exec-label|--file-label)
      i=$((i + 2)) ;;
    --chmod)
      i=$((i + 3)) ;;
    # A tmpfs over an existing path is a mask, not storage: re-express it
    # as a read-only exposure. Ignoring it would leave the path writable,
    # which is looser than Codex asked for.
    --tmpfs) mask "${argv[i+1]:-}"; i=$((i + 2)) ;;
    # The child gets its own /proc and /dev from the runtime, and
    # --remount-ro only ever follows a --tmpfs already handled above.
    --proc|--dev|--mqueue|--dir|--remount-ro)
      i=$((i + 2)) ;;

    --chdir) spawn+=("--directory=$(host_path "${argv[i+1]:-}")"); have_chdir=1; i=$((i + 2)) ;;
    --setenv) spawn+=("--env=${argv[i+1]:-}=$(rewrite_mapped_paths "${argv[i+2]:-}")"); i=$((i + 3)) ;;
    --unsetenv) spawn+=("--unset-env=${argv[i+1]:-}"); i=$((i + 2)) ;;
    --clearenv) spawn+=(--clear-env); i=$((i + 1)) ;;
    --die-with-parent) spawn+=(--watch-bus); i=$((i + 1)) ;;

    -*) refuse "flag $a" ;;
    *) break ;;
  esac
done

cmd=("${argv[@]:i}")
[ "${#cmd[@]}" -gt 0 ] || refuse "no command after the bwrap flags"

# What Codex hands bwrap is not the command it wants run: it is its own
# helper, re-executed under argv[0] codex-linux-sandbox, with the real
# command after a second `--`. By that point the helper's remaining job is
# to apply seccomp and exec -- the mounts were asked for in the bwrap flags
# above, and those flags are the permission profile written in bwrap's
# terms. They are exactly what this script has already turned into portal
# exposures, so the helper is a second enforcement pass over a policy the
# portal is applying anyway.
#
# And it is one that cannot run here. It re-execs through descriptors the
# portal does not carry, which is the "--bind-fd: Not an open file
# descriptor" failure, and its Landlock fallback refuses outright any
# profile whose semantics it cannot reproduce exactly. Neither is
# reachable from this side.
#
# So run what Codex actually asked for. Recognised narrowly, and anything
# that does not match this exact shape is passed through untouched.
if [ "$argv0" = "codex-linux-sandbox" ]; then
  helper=0 sep=-1 command_cwd=""
  for j in "${!cmd[@]}"; do
    case "${cmd[j]}" in
      --apply-seccomp-then-exec) helper=1 ;;
      --command-cwd) command_cwd="${cmd[j+1]:-}" ;;
      # Proxy mode does more than filter: it bridges the child's traffic
      # through a listener this script plays no part in. Running the
      # command without it would drop the network policy silently.
      --allow-network-for-proxy|--proxy-route-spec)
        refuse "codex-linux-sandbox ${cmd[j]} (proxy mode cannot be reproduced)" ;;
      --) [ "$helper" -eq 1 ] && [ "$sep" -lt 0 ] && sep=$j ;;
    esac
  done
  if [ "$helper" -eq 1 ] && [ "$sep" -ge 0 ]; then
    cmd=("${cmd[@]:sep+1}")
    [ "${#cmd[@]}" -gt 0 ] || refuse "nothing after --apply-seccomp-then-exec --"
    # The helper was going to run this under its own name, not ours.
    argv0="${cmd[0]}"
    # It is also told the cwd separately, and that is the authority: it can
    # differ from the policy cwd when the workspace is reached by symlink.
    if [ -n "$command_cwd" ]; then
      spawn+=("--directory=$(host_path "$command_cwd")")
      have_chdir=1
    fi
    log "HELPER[$$]: codex-linux-sandbox dropped, running its inner command"
  fi
fi

# Without --chdir, bwrap keeps the current directory -- but the child only
# sees what we exposed, so an unexposed cwd makes flatpak-spawn fail with
# "Can't chdir". That is what breaks Codex's capability probe, which runs
# `bwrap --unshare-user --unshare-net --ro-bind / / /bin/true` with no
# --chdir and reports "no system bwrap was found on PATH" when it fails.
if [ "$have_chdir" -eq 0 ]; then
  cwd="$(pwd -P 2>/dev/null || echo /)"
  dir=/
  for p in ${exposed[@]+"${exposed[@]}"}; do
    case "$cwd" in "$p"|"$p"/*) dir="$cwd"; break ;; esac
  done
  spawn+=("--directory=$(host_path "$dir")")
fi

# Any fd the command still refers to has to survive the portal hop.
#
# Only the ones named in the command. Forwarding everything inherited was
# tried and reverted: it does not reach the descriptors Codex's helper
# wants -- those are not inherited at all, as the log below shows -- and
# when the app's own process calls in it inherits some seventy, sockets to
# the session bus and the display among them, which the portal would then
# hand to a sandboxed command. That is the one direction this shim must
# never move in.
fds=()
for word in "${cmd[@]}"; do
  while IFS= read -r m; do
    fd="${m#/proc/self/fd/}"
    for seen in ${fds[@]+"${fds[@]}"}; do
      [ "$seen" = "$fd" ] && continue 2
    done
    [ -e "/proc/self/fd/$fd" ] && fds+=("$fd")
  done < <(grep -oE '/proc/self/fd/[0-9]+' <<< "$word" || true)
done
for fd in ${fds[@]+"${fds[@]}"}; do
  spawn+=("--forward-fd=$fd")
done

# Codex names flatpak-mapped directories by their in-sandbox paths, which
# do not exist in the child. Rewriting them here rather than recreating the
# names as symlinks fixes every occurrence at once -- the binary path, the
# paths inside --permission-profile, and the ones embedded in the shell
# script handed to `sh -c`. It is a translation of the same directory to
# its real location, not a change of policy.
for j in "${!cmd[@]}"; do
  cmd[j]="$(rewrite_mapped_paths "${cmd[j]}")"
done

# The command's own binary must be reachable.
case "${cmd[0]}" in
  /*) expose --sandbox-expose-path-ro "$(dirname -- "${cmd[0]}")" "$(dirname -- "${cmd[0]}")" try ;;
esac

# The rewrite above already put cmd[0] in its host form, so this picks up
# the name the child will actually be told to run.
[ -n "$argv0" ] || argv0="${cmd[0]}"

# The only thing still wrapped: flatpak-spawn has no --argv0, and Codex
# re-execs its own binary and dispatches on argv[0].
setup='exec -a "$SHIM_ARGV0" "$@"'

spawn+=("--env=SHIM_ARGV0=$argv0")

log "SPAWN[$$]: $(printf '%q ' "${spawn[@]}")"
# The rewritten command as well as the sandbox flags. When a path inside
# the script Codex hands to `sh -c` comes out wrong, this is the only place
# the final form is visible -- and logging it before the portal call is
# what lets the translation be tested where no portal exists.
log "EXEC[$$]: $(printf '%q ' "${cmd[@]}")"

# Run rather than exec, so a failure gets an exit code and any output
# recorded. Codex swallows the child's stderr when the command fails, which
# leaves nothing to debug from; this is the only place that still sees it.
err="$(mktemp)"
rc=0
# `|| rc=$?`, not a bare call: under set -e a non-zero exit would abort the
# script here and the logging below would never run -- which is exactly the
# silent failure this is meant to explain.
flatpak-spawn "${spawn[@]}" /bin/bash -c "$setup" bwrap-shim "${cmd[@]}" \
  2> >(tee "$err" >&2) || rc=$?
if [ "$rc" -ne 0 ]; then
  log "EXIT[$$] rc=$rc stderr: $(head -c 2000 "$err" 2>/dev/null)"
fi
rm -f "$err"
exit "$rc"
