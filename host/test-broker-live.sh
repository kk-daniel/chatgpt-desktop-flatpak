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
ROOT=$(dirname "$HERE")
BRANCH_ARGS=()
[ -n "${BRANCH:-}" ] && BRANCH_ARGS=(--branch="$BRANCH")

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
flatpak info "${BRANCH_ARGS[@]}" "$APP" >/dev/null 2>&1 ||
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

if ! unshare --user --map-root-user true 2>/dev/null; then
  skip_all "this host cannot create user namespaces, so no broker can work"
fi

SOCK=$XDG_RUNTIME_DIR/app/$APP/bwrap-broker.sock

# Run bwrap inside the app. Everything below goes through this.
in_app() { flatpak run "${BRANCH_ARGS[@]}" --command=bwrap "$APP" "$@" 2>&1; }

# --- the broker is not running yet: check that it fails properly ----------

echo "== without a broker =="
out=$(in_app --ro-bind / / --chdir / -- /bin/true); rc=$?
if [ "$rc" -eq 127 ] && printf '%s' "$out" | grep -q 'broker is not running'; then
  ok "a missing broker fails with 127 and says how to start it"
else
  bad "a missing broker should fail with 127 and an explanation" "rc=$rc: $out"
fi
# The one thing that must never happen: falling back to running the command
# with less isolation than was asked for.
if printf '%s' "$out" | grep -qi 'flatpak-spawn\|--host'; then
  bad "a missing broker must not mention a fallback path" "$out"
else
  ok "a missing broker does not fall back"
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

app_uid=$(flatpak run "${BRANCH_ARGS[@]}" --command=id "$APP" -u 2>/dev/null | tr -d '\r')
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
out=$(in_app --ro-bind / / --dev /dev --proc /proc --unshare-net --chdir / -- \
  /bin/sh -c 'ls /sys/class/net 2>/dev/null | tr "\n" " "')
if printf '%s' "$out" | grep -q 'lo' && ! printf '%s' "$out" | grep -qE 'eth|wlan|enp|wlp'; then
  ok "only loopback is present under --unshare-net"
else
  bad "--unshare-net left other interfaces visible" "$out"
fi

echo
echo "== descriptor-passing flags, which the portal could never carry =="
tmp=$(mktemp -d)
python3 -c "import struct,sys; sys.stdout.buffer.write(struct.pack('HBBI', 6, 0, 0, 0x7fff0000))" > "$tmp/allow.bpf"
printf '%s\0' --ro-bind / / --chdir / > "$tmp/args"
# Handed in on real descriptors, the way Codex's helper does it.
out=$(flatpak run "${BRANCH_ARGS[@]}" --filesystem="$tmp:ro" --command=sh "$APP" -c "
  exec 8<'$tmp/allow.bpf'
  bwrap --ro-bind / / --seccomp 8 --chdir / -- /bin/sh -c 'echo seccomp-fd-ok'
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

out=$(printf 'from-stdin' | flatpak run "${BRANCH_ARGS[@]}" --command=bwrap "$APP" \
  --ro-bind / / --chdir / -- /bin/cat 2>/dev/null)
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
  /app/bin/bwrap --ro-bind / / --chdir / -- /bin/echo should-not-run)
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
