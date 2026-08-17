#!/bin/bash
# Live sandbox tests against an installed flatpak. Everything here needs a real
# app instance and a real broker, which is exactly what test-broker.py cannot
# do -- and where all three bugs found during development actually were.
#
# No session bus is needed. That is the reason this can run in CI at all: the
# portal implementation this replaced could not be tested here, because
# flatpak-spawn got as far as "Cannot spawn a message bus without a machine-id"
# and stopped. The broker talks over a unix socket and needs no bus, so the
# only requirements are flatpak, python3, and permission to create user
# namespaces.
#
# systemd is not needed either: the broker binds the socket itself when
# LISTEN_FDS is unset, so this starts it directly.
#
#   APP_ID              default com.openai.ChatGPT
#   BRANCH              flatpak branch to run, if not the default
#   REQUIRE_BROKER_LIVE=1  fail instead of skipping when the environment
#                          cannot support these tests
set -u

APP=${APP_ID:-com.openai.ChatGPT}
HERE=$(cd -- "$(dirname -- "$0")" && pwd)

# APP is the application id -- it names the socket and the broker instance, and
# must stay bare. REF is what flatpak is asked to act on, which may carry a
# branch. The ref form rather than --branch=, because `flatpak info` has no
# --branch option and rejects it, which is a confusing way to be told the app is
# not installed.
REF=$APP
[ -n "${BRANCH:-}" ] && REF="$APP//$BRANCH"

pass=0
fail=0
skipped=0

ok()   { pass=$((pass + 1)); printf 'ok    %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
note() { printf '      %s\n' "$1"; }

skip_all() {
  if [ "${REQUIRE_BROKER_LIVE:-0}" = 1 ]; then
    echo "FAIL  cannot run the live tests and REQUIRE_BROKER_LIVE=1: $1"
    exit 1
  fi
  echo "SKIP  live broker tests: $1"
  exit 0
}

# --- preflight -----------------------------------------------------------

command -v flatpak >/dev/null || skip_all "no flatpak"
command -v python3 >/dev/null || skip_all "no python3 on the host"
flatpak info "$REF" >/dev/null 2>&1 ||
  skip_all "$APP is not installed"

# Both sides must agree on the runtime directory: flatpak binds
# $XDG_RUNTIME_DIR/app/<id> into the sandbox at the same path, and that is
# where the socket lives. A container often has none.
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
  export XDG_RUNTIME_DIR=/run/user/$(id -u)
  mkdir -p "$XDG_RUNTIME_DIR" || skip_all "cannot create $XDG_RUNTIME_DIR"
  chmod 700 "$XDG_RUNTIME_DIR"
  note "XDG_RUNTIME_DIR was unset; using $XDG_RUNTIME_DIR"
fi

# Report the reason rather than swallowing it. "cannot create user namespaces"
# with no errno behind it is not a diagnosis, and the difference between EPERM
# and ENOSPC is the difference between a policy and a spent quota.
if ! userns_err=$(unshare --user --map-root-user true 2>&1); then
  note "max_user_namespaces: $(cat /proc/sys/user/max_user_namespaces 2>&1)"
  note "unprivileged_userns_clone: $(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo 'not present')"
  note "uid=$(id -u) in $(readlink /proc/self/ns/user 2>&1)"
  skip_all "cannot create a user namespace, so no broker can work: $userns_err"
fi

# The broker refuses to serve an app running as root, because bubblewrap then
# hands the command its capabilities. So these tests cannot run as root either,
# and that is a fact about the configuration rather than a missing dependency:
# skipping would leave CI reporting green over a suite that measured nothing.
if [ "$(id -u)" = 0 ]; then
  echo "FAIL  these tests cannot run as root: the broker refuses a root app,"
  echo "      because bubblewrap run as root keeps its capabilities for the"
  echo "      command and would undo the read-only root Codex asked for."
  echo "      Run them as an ordinary user with the flatpak installed for them."
  exit 1
fi

SOCK=$XDG_RUNTIME_DIR/app/$APP/bwrap-broker.sock

# Run bwrap inside the app. Everything below goes through this.
#
# --unshare-user on every call, because Codex passes it on every call and
# without it the shape is ambiguous when the app runs as uid 0, which is what
# CI does. Seeing euid 0, bubblewrap does not create a user namespace of its own
# and expects to mount with root's authority -- but the broker has dropped every
# capability by then, so CLONE_NEWNS is refused and the whole suite fails with
# "Creating new namespace failed: Operation not permitted". At uid 1000
# bubblewrap knows it is unprivileged and creates the namespace first, which is
# why a desktop run does not show this. Asking for the namespace explicitly is
# both what Codex does and unambiguous at either uid.
in_app() { flatpak run --command=bwrap "$REF" --unshare-user "$@" 2>&1; }

# --- the broker is not running yet: check that it fails properly ----------

echo "== without a broker =="
out=$(in_app --ro-bind / / --chdir / -- /bin/true); rc=$?
if [ "$rc" -eq 127 ] && printf '%s' "$out" | grep -q 'broker is not running'; then
  ok "a missing broker fails with 127 and says how to start it"
else
  bad "a missing broker should fail with 127 and an explanation" "rc=$rc: $out"
fi
# Both halves have to be offered: the socket being absent usually means the
# broker was never installed, and "systemctl enable" alone would then answer
# "Unit not found" and leave the user no further forward.
if printf '%s' "$out" | grep -q 'install\.sh' &&
   printf '%s' "$out" | grep -q 'systemctl --user enable'; then
  ok "the message covers both never-installed and installed-but-stopped"
else
  bad "the message should offer install.sh as well as systemctl" "$out"
fi
# The one thing that must never happen: falling back to running the command
# with less isolation than was asked for.
if printf '%s' "$out" | grep -qi 'flatpak-spawn\|--host'; then
  bad "a missing broker must not mention a fallback path" "$out"
else
  ok "a missing broker does not fall back"
fi
# Codex swallows a failing command's stderr, and with no broker there is no
# journal on the other side either, so the reason has to survive somewhere.
logged=$(flatpak run --command=cat "$REF" \
  /var/cache/chatgpt-flatpak/bwrap-error.log 2>/dev/null)
if printf '%s' "$logged" | grep -q 'broker is not running'; then
  ok "the reason is also left in /var/cache/chatgpt-flatpak/bwrap-error.log"
else
  bad "the failure was not recorded where it can be found later" "$logged"
fi

# --- start the broker ----------------------------------------------------

echo
echo "== starting the broker =="
python3 "$HERE/flatpak-bwrap-broker" --app-id="$APP" >"$HERE/.broker.log" 2>&1 &
BROKER=$!
cleanup() {
  kill "$BROKER" 2>/dev/null
  wait "$BROKER" 2>/dev/null
  rm -f "$HERE/.broker.log"
}
trap cleanup EXIT

for _ in $(seq 1 50); do
  [ -S "$SOCK" ] && break
  sleep 0.1
done
if [ ! -S "$SOCK" ]; then
  echo "FAIL  the broker did not create $SOCK"
  cat "$HERE/.broker.log"
  exit 1
fi
ok "the broker is listening on $SOCK"

# --- what the app sees of itself, to compare against ---------------------

app_uid=$(flatpak run --command=id "$REF" -u 2>/dev/null | tr -d '\r')
[ -n "$app_uid" ] || app_uid=$(id -u)
note "the app runs as uid $app_uid"

echo
echo "== the command's own identity =="
# Not a hardcoded 1000: CI runs as root, and the point is that the command
# matches the app rather than the broker's privileged position in namespace A,
# where it arrives as uid 0 with a full capability set.
got=$(in_app --ro-bind / / --chdir / -- /bin/sh -c 'id -u; grep -s ^CapEff /proc/self/status')
cmd_uid=$(printf '%s\n' "$got" | head -1)
caps=$(printf '%s\n' "$got" | grep -o '[0-9a-f]\{16\}' | head -1)
if [ "$cmd_uid" = "$app_uid" ]; then
  ok "the command runs as the app's uid ($app_uid), not the broker's"
else
  bad "uid mismatch: app is $app_uid, command is $cmd_uid"
fi
if [ "$caps" = "0000000000000000" ]; then
  ok "the command has no capabilities"
else
  bad "the command kept capabilities" "CapEff $caps"
fi

echo
echo "== the mount namespace is the app's, with its flags intact =="
out=$(in_app --ro-bind / / --chdir / -- /bin/sh -c '
  grep -sq "^name=" /.flatpak-info && echo has-flatpak-info
  touch /usr/.probe 2>/dev/null && echo usr-WRITABLE || echo usr-ro
  test -e /etc/fedora-release && echo host-etc-VISIBLE || echo host-etc-absent')
for want in has-flatpak-info usr-ro host-etc-absent; do
  if printf '%s' "$out" | grep -qx "$want"; then
    ok "$want"
  else
    bad "expected $want" "$out"
  fi
done

echo
echo "== bubblewrap's own features work =="
out=$(in_app --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp \
  --perms 0700 --dir /tmp/masked --unshare-pid --chdir / -- /bin/sh -c '
  mountpoint -q /tmp && echo tmpfs-ok
  [ "$(stat -c %a /tmp/masked)" = 700 ] && echo perms-ok
  printf x > /tmp/masked/f && echo tmpfs-writable
  : > /dev/null && echo dev-ok
  test -d /proc/1 && echo proc-ok
  [ "$(ls /proc | grep -c "^[0-9]*$")" -le 3 ] && echo pidns-isolated')
for want in tmpfs-ok perms-ok tmpfs-writable dev-ok proc-ok pidns-isolated; do
  if printf '%s' "$out" | grep -qx "$want"; then
    ok "$want"
  else
    bad "expected $want" "$out"
  fi
done

echo
echo "== --unshare-net =="
# /proc/net, not /sys/class/net. sysfs comes in through the bind and reflects
# the namespace it was mounted in, so it would still list eth0 with the
# namespace correctly unshared -- a test that fails while the isolation works.
# /proc/net is a symlink to /proc/self/net, which is per-netns of the reader.
out=$(in_app --ro-bind / / --dev /dev --proc /proc --unshare-net --chdir / -- \
  /bin/sh -c 'awk -F: "NR>2 {gsub(/ /, \"\", \$1); print \$1}" /proc/net/dev | sort | tr "\n" " "')
if [ "$(printf '%s' "$out" | tr -d ' ')" = "lo" ]; then
  ok "only loopback exists under --unshare-net"
else
  bad "--unshare-net left other interfaces in /proc/net/dev" "$out"
fi

echo
echo "== descriptor-passing flags, which the portal could never carry =="
tmp=$(mktemp -d)
python3 -c "import struct,sys; sys.stdout.buffer.write(struct.pack('HBBI', 6, 0, 0, 0x7fff0000))" > "$tmp/allow.bpf"
# --unshare-user inside the list as well, which also proves --args carries a
# flag that changes how the sandbox is built and not just where it looks.
printf '%s\0' --unshare-user --ro-bind / / --chdir / > "$tmp/args"
# Handed in on real descriptors, the way Codex's helper does it.
out=$(flatpak run --filesystem="$tmp:ro" --command=sh "$REF" -c "
  exec 8<'$tmp/allow.bpf'
  bwrap --unshare-user --ro-bind / / --seccomp 8 --chdir / -- /bin/sh -c 'echo seccomp-fd-ok'
  exec 7<'$tmp/args'
  bwrap --args 7 -- /bin/sh -c 'echo args-fd-ok'" 2>&1)
for want in seccomp-fd-ok args-fd-ok; do
  if printf '%s' "$out" | grep -qx "$want"; then
    ok "$want"
  else
    bad "expected $want" "$out"
  fi
done
rm -rf "$tmp"

echo
echo "== exit status and streams =="
in_app --ro-bind / / --chdir / -- /bin/sh -c 'exit 42' >/dev/null 2>&1
[ $? -eq 42 ] && ok "the command's exit status is returned" || bad "exit status was lost"

out=$(printf 'from-stdin' | flatpak run --command=bwrap "$REF" \
  --unshare-user --ro-bind / / --chdir / -- /bin/cat 2>/dev/null)
[ "$out" = "from-stdin" ] && ok "stdin reaches the command" || bad "stdin did not reach the command" "$out"

err=$(in_app --ro-bind / / --chdir / -- /bin/sh -c 'echo to-stderr >&2' 2>&1 >/dev/null)
printf '%s' "$err" | grep -q to-stderr && ok "stderr comes back" || bad "stderr was lost" "$err"

echo
echo "== sequential and concurrent use =="
seq_fail=0
for i in $(seq 1 12); do
  in_app --ro-bind / / --chdir / -- /bin/true >/dev/null 2>&1 || seq_fail=$((seq_fail + 1))
done
[ "$seq_fail" -eq 0 ] && ok "12 sequential sandboxes" || bad "$seq_fail of 12 sequential sandboxes failed"

pids=()
for i in $(seq 1 8); do
  in_app --ro-bind / / --chdir / -- /bin/true >/dev/null 2>&1 &
  pids+=($!)
done
par_fail=0
for p in "${pids[@]}"; do wait "$p" || par_fail=$((par_fail + 1)); done
[ "$par_fail" -eq 0 ] && ok "8 concurrent sandboxes" || bad "$par_fail of 8 concurrent sandboxes failed"

echo
echo "== sandboxes do not nest =="
# From inside a sandbox the broker must refuse, and the client must explain why
# rather than surfacing a bare errno. Whether the refusal comes from the
# caller's own seccomp filter blocking connect() or from the broker's namespace
# check, the message has to be intelligible.
out=$(in_app --ro-bind / / --dev /dev --proc /proc --chdir / -- \
  /app/bin/bwrap --unshare-user --ro-bind / / --chdir / -- /bin/echo should-not-run)
if printf '%s' "$out" | grep -qx 'should-not-run'; then
  bad "a nested sandbox was created; it must be refused" "$out"
elif printf '%s' "$out" | grep -qi 'already.*inside a sandbox\|already running inside'; then
  ok "a nested sandbox is refused with an explanation"
else
  bad "nesting was refused but not explained" "$out"
fi

echo
echo "== seccomp policy parity with the app =="
if bash "$HERE/test-seccomp-parity.sh" "$APP" >/dev/null 2>&1; then
  ok "the broker refuses exactly what the app refuses"
else
  bad "the seccomp policy differs from the app's" "run host/test-seccomp-parity.sh"
fi

echo
echo "$pass passed, $fail failed, $skipped skipped"
if [ "$fail" -gt 0 ]; then
  echo
  echo "broker log:"
  sed 's/^/  /' "$HERE/.broker.log"
  exit 1
fi
