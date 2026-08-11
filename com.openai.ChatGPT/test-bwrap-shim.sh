#!/bin/sh
# Checks how /app/bin/bwrap translates Codex's bubblewrap command lines
# into `flatpak-spawn --sandbox` arguments.
#
# The shim logs the translation just before it spawns, so running the
# installed shim with BWRAP_LOG=1 and reading that log exercises the parser
# in its real environment -- real $HOME, real FLATPAK_ID, real /var/data
# mapping -- without the portal that would execute the result. The spawn
# itself then fails wherever no portal is reachable, which is the case in a
# CI container: it has no session bus, and flatpak-spawn gives up with
# "Cannot spawn a message bus without a machine-id". Every case therefore
# ignores the exit status and asserts on the log.
#
# Not covered, so that this file is not mistaken for the whole story:
#
#   - whether the portal accepts these arguments, and whether the child is
#     actually confined. Both need a desktop session; check them by hand
#     there with
#
#       flatpak run --command=bwrap com.openai.ChatGPT \
#         --unshare-user --unshare-net --ro-bind / / --chdir / -- \
#         /bin/sh -c 'echo ok; ls /mnt'
#
#     which must print ok and fail to list /mnt.
#
#   - --args, and the --forward-fd derivation that scans the command for
#     /proc/self/fd/N. Both need a file descriptor open in the shim's own
#     process, and `flatpak run` has nowhere to hand one in.
#
#   - the half of the fallback for a missing --chdir that finds the cwd
#     under an exposure. `flatpak run` fixes the cwd, so only the half that
#     falls back to / is reachable here.
#
#   - --clearenv.
set -eu

APP_ID="${APP_ID:-com.openai.ChatGPT}"
BRANCH="${BRANCH:-main}"

app="$HOME/.var/app/$APP_ID"
log="$app/cache/chatgpt-flatpak/bwrap.log"
fail=0

# The shim only emits an exposure for a path that exists, so the cases
# below need something real to name. It goes in the app data dir, which is
# what /var/data resolves to inside the sandbox -- naming it both ways is
# how the mapping gets tested. shell_snapshots is created for the same
# reason: the shim exposes it when present, and a case that depends on
# whether Codex has ever run is not a test.
work="$app/data/shimtest"
snapshots="$app/.codex/shell_snapshots"
rm -rf "$work"
mkdir -p "$work/work/.git" "$work/bin" "$snapshots"
# rmdir, not rm -rf: it removes the directory only if this script is what
# created it, and leaves a real Codex session's snapshots alone.
trap 'rm -rf "$work"; rmdir "$snapshots" 2>/dev/null || true' EXIT

status=0
run() {
  # Truncate first: a refused call writes no SPAWN line, and without this
  # it would silently be checked against the previous case's translation.
  rm -f "$log"
  status=0
  flatpak run --env=BWRAP_LOG=1 --branch="$BRANCH" --command=bwrap "$APP_ID" "$@" \
    >/dev/null 2>&1 || status=$?
}

# The shim logs each argv with `printf '%q '`, so plain arguments come back
# unquoted and the trailing separator is the only thing to strip.
logged() {
  [ -f "$log" ] || return 0
  sed -n "s/^$1\[[0-9]*\]: //p" "$log" | tail -1 | sed 's/ *$//'
}

check() {
  if [ "$2" = "$3" ]; then
    echo "ok: $1"
  else
    echo "FAIL: $1" >&2
    echo "  expected: $2" >&2
    echo "  actual:   $3" >&2
    if [ -f "$log" ]; then sed 's/^/  log: /' "$log" >&2; fi
    fail=1
  fi
}

# Codex decides whether a system bwrap is usable by running exactly this,
# and falls back to "no system bwrap was found on PATH" -- disabling its
# sandbox altogether -- if it fails. Note the missing --chdir: the child
# inherits a cwd it cannot see unless the shim picks one for it.
run --unshare-user --unshare-net --ro-bind / / /bin/true
# Everything below reads the log, so a log that never appeared at all means
# BWRAP_LOG did not reach the shim -- a broken harness, not a translation
# that changed. Say which one it is instead of failing every case.
if [ ! -f "$log" ]; then
  echo "FAIL: nothing logged to $log -- BWRAP_LOG=1 did not reach the shim" >&2
  exit 1
fi
check "capability probe" \
  "--sandbox --no-network --directory=/ --sandbox-expose-path-ro=$app/.codex/shell_snapshots --sandbox-expose-path-ro=/bin --env=SHIM_ARGV0=/bin/true" \
  "$(logged SPAWN)"

# A workspace-write invocation in the shape Codex builds them: the whole
# root read-only, the workspace bound writable, .git masked back to
# read-only with a tmpfs, and every path named the way it appears inside
# the Flatpak sandbox rather than on the host.
run --unshare-all --ro-bind / / \
  --bind /var/data/shimtest/work /var/data/shimtest/work \
  --perms 555 --tmpfs /var/data/shimtest/work/.git \
  --remount-ro /var/data/shimtest/work/.git \
  --setenv FOO bar --unsetenv BAZ --die-with-parent \
  --chdir /var/data/shimtest/work \
  --argv0 codex \
  -- /var/data/shimtest/bin/tool --flag /var/data/shimtest/work/file
# --directory is the one path in here left in its in-sandbox form; the
# exposures and the command's own argv are both rewritten to the host
# location the portal resolves against. It is pinned the way the shim
# behaves today, not because that is known to be right -- if the child sees
# host paths, which rewriting the binary's own path implies, this one is
# wrong too. Changing it should change this expectation, deliberately.
check "workspace-write translation" \
  "--sandbox --no-network --sandbox-expose-path=$work/work --sandbox-expose-path-ro=$work/work/.git --env=FOO=bar --unset-env=BAZ --watch-bus --directory=/var/data/shimtest/work --sandbox-expose-path-ro=$app/.codex/shell_snapshots --sandbox-expose-path-ro=$work/bin --env=SHIM_ARGV0=codex" \
  "$(logged SPAWN)"
# Paths reach the child rewritten, which is what makes the binary and the
# arguments inside a `sh -c` script resolve there.
check "workspace-write command rewrite" \
  "$work/bin/tool --flag $work/work/file" \
  "$(logged EXEC)"

# Codex does not hand bwrap the command it wants run. It hands its own
# helper, re-executed under argv[0] codex-linux-sandbox, with the real
# command after a second --. The helper cannot run on this side: it
# re-execs through descriptors the portal does not carry, and its Landlock
# fallback refuses outright any profile whose semantics it cannot
# reproduce. So it is dropped and the inner command runs directly. The
# policy does not go with it -- the exposures asserted here come from the
# same bwrap flags Codex built out of the permission profile.
run --new-session --die-with-parent --ro-bind / / --dev /dev \
  --bind /var/data/shimtest/work /var/data/shimtest/work \
  --ro-bind /var/data/shimtest/work/.git /var/data/shimtest/work/.git \
  --unshare-user --unshare-pid --unshare-net --proc /proc \
  --argv0 codex-linux-sandbox \
  -- /var/data/shimtest/bin/tool --sandbox-policy-cwd /var/data/shimtest/work \
     --command-cwd /var/data/shimtest/work \
     --permission-profile '{"type":"managed"}' \
     --apply-seccomp-then-exec -- /bin/sh -c true
check "codex helper dropped" \
  "--sandbox --watch-bus --sandbox-expose-path=$work/work --sandbox-expose-path-ro=$work/work/.git --no-network --directory=$work/work --sandbox-expose-path-ro=$app/.codex/shell_snapshots --sandbox-expose-path-ro=/bin --env=SHIM_ARGV0=/bin/sh" \
  "$(logged SPAWN)"
check "codex helper inner command runs" "/bin/sh -c true" "$(logged EXEC)"

# Proxy mode does more than filter: it bridges the child's traffic through
# a listener the shim plays no part in. Dropping the helper there would
# drop the network policy with it, so the whole call is refused instead.
run --ro-bind / / --unshare-net --chdir / --argv0 codex-linux-sandbox \
  -- /var/data/shimtest/bin/tool --allow-network-for-proxy \
     --apply-seccomp-then-exec -- /bin/true
check "codex helper proxy mode refused" "1" "$status"

# /tmp is a per-instance tmpfs the portal will not expose, and the child
# gets a fresh private one regardless. Asking for it is dropped rather
# than refused, or every sandboxed command Codex runs would fail.
run --ro-bind /tmp /tmp --chdir / -- /bin/true
check "/tmp exposure dropped" \
  "--sandbox --directory=/ --sandbox-expose-path-ro=$app/.codex/shell_snapshots --sandbox-expose-path-ro=/bin --env=SHIM_ARGV0=/bin/true" \
  "$(logged SPAWN)"

# Codex's own policy skips paths that are not there, and the portal errors
# out on a missing exposure instead of ignoring it.
run --ro-bind-try /var/data/shimtest/nope /var/data/shimtest/nope --chdir / -- /bin/true
check "missing -try path skipped" \
  "--sandbox --directory=/ --sandbox-expose-path-ro=$app/.codex/shell_snapshots --sandbox-expose-path-ro=/bin --env=SHIM_ARGV0=/bin/true" \
  "$(logged SPAWN)"

# Anything untranslatable has to fail loudly. Dropping it would hand Codex
# a sandbox that differs from the one it asked for, and the log line is
# the only record of what the real command line was.
run --ro-bind /var/data/shimtest/nope /var/data/shimtest/nope --chdir / -- /bin/true
check "missing path refused" "1" "$status"
check "missing path spawns nothing" "" "$(logged SPAWN)"

# The portal exposes a path at its own location and cannot put it
# somewhere else, so a bind that remaps cannot be honoured at all.
run --ro-bind /var/data/shimtest/bin /var/data/shimtest/elsewhere --chdir / -- /bin/true
check "remapping bind refused" "1" "$status"

run --overlay-src /var/data/shimtest/bin --chdir / -- /bin/true
check "untranslatable flag refused" "1" "$status"

# Both probes callers use to decide whether bwrap works at all. Codex
# feature-detects on --perms appearing in the help text and rejects the
# whole shim without it.
out="$(flatpak run --branch="$BRANCH" --command=bwrap "$APP_ID" --version 2>/dev/null || true)"
# The shape is the contract -- callers parse "bubblewrap <version>" -- so
# match that rather than the number the shim happens to emulate, which is
# free to move without breaking anyone.
case "$out" in
  'bubblewrap '[0-9]*.[0-9]*.[0-9]*) echo "ok: --version" ;;
  *) echo "FAIL: --version answered '$out'" >&2; fail=1 ;;
esac

if flatpak run --branch="$BRANCH" --command=bwrap "$APP_ID" --help 2>/dev/null \
     | grep -q -- '--perms'; then
  echo "ok: --help advertises --perms"
else
  echo "FAIL: --help must list --perms or Codex rejects the shim" >&2
  fail=1
fi

[ "$fail" -eq 0 ] && echo "bwrap shim translates correctly"
exit "$fail"
