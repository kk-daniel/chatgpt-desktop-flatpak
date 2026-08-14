#!/bin/sh
# Checks how /app/bin/bwrap translates Codex's bubblewrap command lines
# into `flatpak-spawn --sandbox` arguments.
#
# The shim logs the translation just before it spawns. The installed
# /app/bin/bwrap.log symlink is enabled by creating its writable target,
# which also works when Codex strips BWRAP_LOG and HOME from a filesystem
# helper. Reading that log exercises the parser in its real environment --
# real $HOME, real FLATPAK_ID and real /var/data mapping. Translation cases
# assert on the log even where no portal is reachable. When a session bus is
# available, the test additionally requires a minimal-environment portal call
# to succeed and runs the packaged apply_patch create/update/delete cycle
# through that portal. A headless CI container has no session bus, so those
# two desktop-only assertions are reported as skipped there.
#
# Not covered, so that this file is not mistaken for the whole story:
#
#   - whether the child is actually confined. This needs a desktop session;
#     check it by hand there with
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
mkdir -p "${log%/*}"
fail=0
log_was_present=0
[ -f "$log" ] && log_was_present=1

# The shim only emits an exposure for a path that exists, so the cases
# below need something real to name. It goes in the app data dir, which is
# what /var/data resolves to inside the sandbox -- naming it both ways is how
# the mapping gets tested. The attachment fixture does the same for the
# --persist=.codex mapping.
work="$app/data/shimtest"
attachments="$app/.codex/attachments"
mkdir -p "$attachments"
attachment_dir="$(mktemp -d "$attachments/bwrap-shim-test.XXXXXX")"
attachment="$attachment_dir/pasted-text.txt"
rm -rf "$work"
mkdir -p "$work/work/.git" "$work/bin"
touch "$attachment"
# rmdir leaves a pre-existing attachments directory alone. Restore whether
# logging was enabled before the test; the translation checks intentionally
# replace the old log contents.
cleanup() {
  rm -rf "$work" "$attachment_dir"
  rmdir "$attachments" 2>/dev/null || true
  if [ "$log_was_present" -eq 1 ]; then
    mkdir -p "${log%/*}"
    : > "$log"
  else
    rm -f "$log"
  fi
}
trap cleanup EXIT

status=0
run() {
  # Truncate first: a refused call writes no SPAWN line, and without this
  # it would silently be checked against the previous case's translation.
  : > "$log"
  status=0
  flatpak run --branch="$BRANCH" --command=bwrap "$APP_ID" "$@" \
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

# Exercise the launcher-level switch, the installed read-only symlink and
# the shim together. The test-only launcher argument exits before payload
# fetching or Electron startup, so this is safe in both CI and a live app.
rm -f "$log"
launcher_status=0
flatpak run --branch="$BRANCH" --env=BWRAP_LOG=1 --command=chatgpt \
  "$APP_ID" --test-bwrap-logging >/dev/null 2>&1 || launcher_status=$?
if [ "$launcher_status" -eq 0 ] && [ -f "$log" ]; then
  echo "ok: launcher enables bwrap logging"
else
  echo "FAIL: launcher did not enable bwrap logging" >&2
  fail=1
fi

: > "$log"
flatpak run --branch="$BRANCH" --command=bwrap "$APP_ID" --version \
  >/dev/null 2>&1 || true
if grep -q '^CALL\[[0-9][0-9]*\] ' "$log"; then
  echo "ok: installed bwrap log link reaches writable target"
else
  echo "FAIL: enabled bwrap shim wrote no CALL line through /app/bin/bwrap.log" >&2
  fail=1
fi

launcher_status=0
flatpak run --branch="$BRANCH" --env=BWRAP_LOG= --command=chatgpt \
  "$APP_ID" --test-bwrap-logging >/dev/null 2>&1 || launcher_status=$?
if [ "$launcher_status" -eq 0 ] && [ ! -e "$log" ]; then
  echo "ok: launcher disables bwrap logging"
else
  echo "FAIL: launcher did not disable bwrap logging" >&2
  fail=1
fi

flatpak run --branch="$BRANCH" --command=bwrap "$APP_ID" --version \
  >/dev/null 2>&1 || true
if [ ! -e "$log" ]; then
  echo "ok: disabled bwrap logging stays off"
else
  echo "FAIL: bwrap recreated a disabled log target" >&2
  fail=1
fi

# The remaining translation assertions need logging on.
launcher_status=0
flatpak run --branch="$BRANCH" --env=BWRAP_LOG=1 --command=chatgpt \
  "$APP_ID" --test-bwrap-logging >/dev/null 2>&1 || launcher_status=$?
if [ "$launcher_status" -ne 0 ] || [ ! -f "$log" ]; then
  echo "FAIL: could not re-enable bwrap logging for translation tests" >&2
  exit 1
fi

# Codex decides whether a system bwrap is usable by running exactly this,
# and falls back to "no system bwrap was found on PATH" -- disabling its
# sandbox altogether -- if it fails. Note the missing --chdir: the child
# inherits a cwd it cannot see unless the shim picks one for it.
run --unshare-user --unshare-net --ro-bind / / /bin/true
# Everything below reads the log, so a log that never appeared at all means
# the installed /app/bin/bwrap.log link did not reach its target -- a broken
# harness, not a translation that changed. Say which one it is instead of
# failing every case.
if [ ! -f "$log" ]; then
  echo "FAIL: nothing logged to $log -- check the installed bwrap.log link" >&2
  exit 1
fi
check "capability probe" \
  "--sandbox --no-network --sandbox-expose-path-ro=$app --directory=/ --sandbox-expose-path-ro=/bin --env=SHIM_ARGV0=/bin/true" \
  "$(logged SPAWN)"

# Reproduce exec-server's filesystem-helper environment: it clears the
# process environment and preserves only PATH and temporary-directory vars.
# The call must get past HOME/app-root initialization and reach the same
# translation even though the portal itself may be unavailable in CI.
: > "$log"
status=0
flatpak run --branch="$BRANCH" --command=env "$APP_ID" \
  -i PATH=/app/bin:/usr/bin TMPDIR=/tmp \
  /app/bin/bwrap --unshare-user --unshare-net --ro-bind / / /bin/true \
  >/dev/null 2>&1 || status=$?
check "filesystem-helper environment" \
  "--sandbox --no-network --sandbox-expose-path-ro=$app --directory=/ --sandbox-expose-path-ro=/bin --env=SHIM_ARGV0=/bin/true" \
  "$(logged SPAWN)"

# Translation alone would miss a reconstructed session-bus address that is
# syntactically plausible but unusable. On a desktop, require the same
# minimal environment to reach the portal and execute the child. Headless CI
# may opt in with REQUIRE_BWRAP_PORTAL=1 when it gains a usable session bus.
portal_ok=0
portal_status=0
flatpak run --branch="$BRANCH" --command=env "$APP_ID" \
  -i PATH=/app/bin:/usr/bin TMPDIR=/tmp \
  /app/bin/bwrap --unshare-user --unshare-net --ro-bind / / /bin/true \
  >/dev/null 2>&1 || portal_status=$?
if [ "$portal_status" -eq 0 ]; then
  echo "ok: filesystem-helper environment reaches portal"
  portal_ok=1
elif [ "${REQUIRE_BWRAP_PORTAL:-auto}" = 1 ] || \
     { [ "${REQUIRE_BWRAP_PORTAL:-auto}" = auto ] && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; }; then
  echo "FAIL: filesystem-helper environment could not execute through portal (status $portal_status)" >&2
  fail=1
else
  echo "skip: portal execution needs a desktop session bus"
fi

# Reproduce the real operation that exposed the intermittent failure: invoke
# the packaged Codex binary under argv[0] apply_patch, through the minimal-env
# bwrap shim and portal, and make three consecutive writes in one workspace.
codex_host="$app/data/chatgpt/resources/codex"
patch_work="$work/apply-patch"
patch_guest=/var/data/shimtest/apply-patch
patch_file="$patch_work/probe.txt"
mkdir -p "$patch_work"

run_apply_patch() {
  flatpak run --branch="$BRANCH" --command=env "$APP_ID" \
    -i PATH=/app/bin:/usr/bin TMPDIR=/tmp \
    /app/bin/bwrap --ro-bind / / \
      --bind "$patch_guest" "$patch_guest" \
      --unshare-net --chdir "$patch_guest" -- \
      /bin/bash -c 'exec -a apply_patch /var/data/chatgpt/resources/codex "$1"' \
      apply_patch "$1" >/dev/null 2>&1
}

add_patch='*** Begin Patch
*** Add File: probe.txt
+created
*** End Patch'
update_patch='*** Begin Patch
*** Update File: probe.txt
@@
-created
+updated
*** End Patch'
delete_patch='*** Begin Patch
*** Delete File: probe.txt
*** End Patch'

if [ "$portal_ok" -eq 1 ] && [ -x "$codex_host" ]; then
  apply_patch_ok=1
  run_apply_patch "$add_patch" || apply_patch_ok=0
  [ "$apply_patch_ok" -eq 1 ] && [ "$(cat "$patch_file" 2>/dev/null)" = created ] \
    || apply_patch_ok=0
  [ "$apply_patch_ok" -eq 1 ] && run_apply_patch "$update_patch" \
    || apply_patch_ok=0
  [ "$apply_patch_ok" -eq 1 ] && [ "$(cat "$patch_file" 2>/dev/null)" = updated ] \
    || apply_patch_ok=0
  [ "$apply_patch_ok" -eq 1 ] && run_apply_patch "$delete_patch" \
    || apply_patch_ok=0
  [ "$apply_patch_ok" -eq 1 ] && [ ! -e "$patch_file" ] \
    || apply_patch_ok=0

  if [ "$apply_patch_ok" -eq 1 ]; then
    echo "ok: packaged apply_patch create/update/delete through portal"
  else
    echo "FAIL: packaged apply_patch create/update/delete through portal" >&2
    [ -f "$log" ] && sed 's/^/  log: /' "$log" >&2
    fail=1
  fi
elif [ "${REQUIRE_CODEX_APPLY_PATCH:-0}" = 1 ]; then
  echo "FAIL: packaged apply_patch test requires both portal and $codex_host" >&2
  fail=1
else
  echo "skip: packaged apply_patch needs a desktop portal and downloaded payload"
fi

# A workspace-write invocation in the shape Codex builds them: the whole
# root read-only, the workspace bound writable, .git masked back to
# read-only with a tmpfs, and every path named the way it appears inside
# the Flatpak sandbox rather than on the host.
run --unshare-all --ro-bind / / \
  --bind /var/data/shimtest/work /var/data/shimtest/work \
  --perms 555 --tmpfs /var/data/shimtest/work/.git \
  --remount-ro /var/data/shimtest/work/.git \
  --setenv FOO bar \
  --setenv MAPPED /var/config/tool:/var/cache/tool:/var/tmp/tool --unsetenv BAZ --die-with-parent \
  --chdir /var/data/shimtest/work \
  --argv0 codex \
  -- /var/data/shimtest/bin/tool --flag /var/data/shimtest/work/file \
     /var/config/tool /var/cache/tool /var/tmp/tool
# Exposures, cwd, environment values and command arguments all use the host
# spelling in the portal child.
check "workspace-write translation" \
  "--sandbox --no-network --sandbox-expose-path-ro=$app --sandbox-expose-path=$work/work --sandbox-expose-path-ro=$work/work/.git --env=FOO=bar --env=MAPPED=$app/config/tool:$app/cache/tool:$app/cache/tmp/tool --unset-env=BAZ --watch-bus --directory=$work/work --sandbox-expose-path-ro=$work/bin --env=SHIM_ARGV0=codex" \
  "$(logged SPAWN)"
# Paths reach the child rewritten, which is what makes the binary and the
# arguments inside a `sh -c` script resolve there.
check "workspace-write command rewrite" \
  "$work/bin/tool --flag $work/work/file $app/config/tool $app/cache/tool $app/cache/tmp/tool" \
  "$(logged EXEC)"

# A read-only root exposes the complete private app root, while the command
# still has to use the host spelling for the persistent ~/.codex mapping.
# This covers attachments without giving that one subdirectory special
# treatment.
run --ro-bind / / --chdir / -- /bin/sh -c \
  "test -r $HOME/.codex/attachments/${attachment#"$attachments/"}"
check "attachment exposed read-only" \
  "--sandbox --sandbox-expose-path-ro=$app --directory=/ --sandbox-expose-path-ro=/bin --env=SHIM_ARGV0=/bin/sh" \
  "$(logged SPAWN)"
check "attachment command rewrite" \
  "/bin/sh -c test\\ -r\\ $attachment" \
  "$(logged EXEC)"

# The desktop may also hand a tool the already translated host spelling.
# It must request the same exposure without rewriting the path a second time.
run --ro-bind / / --chdir / -- /bin/sh -c "test -r $attachment"
check "host attachment path exposed read-only" \
  "--sandbox --sandbox-expose-path-ro=$app --directory=/ --sandbox-expose-path-ro=/bin --env=SHIM_ARGV0=/bin/sh" \
  "$(logged SPAWN)"
check "host attachment path preserved" "/bin/sh -c test\\ -r\\ $attachment" "$(logged EXEC)"

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
  "--sandbox --watch-bus --sandbox-expose-path-ro=$app --sandbox-expose-path=$work/work --sandbox-expose-path-ro=$work/work/.git --no-network --directory=$work/work --sandbox-expose-path-ro=/bin --env=SHIM_ARGV0=/bin/sh" \
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
  "--sandbox --directory=/ --sandbox-expose-path-ro=/bin --env=SHIM_ARGV0=/bin/true" \
  "$(logged SPAWN)"

# Codex's own policy skips paths that are not there, and the portal errors
# out on a missing exposure instead of ignoring it.
run --ro-bind-try /var/data/shimtest/nope /var/data/shimtest/nope --chdir / -- /bin/true
check "missing -try path skipped" \
  "--sandbox --directory=/ --sandbox-expose-path-ro=/bin --env=SHIM_ARGV0=/bin/true" \
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

if flatpak run --branch="$BRANCH" --command=env "$APP_ID" \
     -i PATH=/app/bin:/usr/bin TMPDIR=/tmp /app/bin/bwrap --help 2>/dev/null \
     | grep -q -- '--perms'; then
  echo "ok: --help advertises --perms without HOME"
else
  echo "FAIL: --help must work without HOME or Codex rejects the shim" >&2
  fail=1
fi

[ "$fail" -eq 0 ] && echo "bwrap shim tests passed"
exit "$fail"
