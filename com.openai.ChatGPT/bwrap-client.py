#!/usr/bin/env python3
"""Installed as /app/bin/bwrap. Hands the request to the host broker.

Codex looks for bwrap on PATH before falling back to its own copy, so this takes
its place. It does not translate anything: flatpak denies the namespace syscalls
bubblewrap needs, the broker runs the real bubblewrap inside this sandbox's own
namespaces, and the arguments Codex wrote reach it unchanged. What used to be a
translation table here -- path rewriting, tmpfs refusals, dropping the
codex-linux-sandbox helper -- is gone, because the descriptors and the mount
namespace both survive the hop now.

The only real work is descriptors. bubblewrap's fd-taking flags name
descriptors by number, so this finds them, sends them over SCM_RIGHTS, and tells
the broker which numbers to put them back on before exec.

There is no fallback. If the broker is not running, this fails and says so; it
never runs the command with less isolation than Codex asked for.
"""

import array
import errno
import os
import select
import signal
import socket
import struct
import sys
import time

REAL_BWRAP = "/app/libexec/flatpak-bwrap-broker/bwrap"

# Must match host/flatpak-bwrap-broker exactly. The version is a separate byte
# so a broker installed from a different checkout can say what it speaks instead
# of rejecting the message as unrecognisable -- this client updates with the
# flatpak, the broker does not.
MAGIC_TAG = b"FBB"
PROTOCOL_VERSION = 1
MAGIC = MAGIC_TAG + bytes([PROTOCOL_VERSION])
MSG_EXEC = 1
MSG_SIGNAL = 2
MSG_RESULT = 3
RESULT_EXITED = 0
RESULT_SIGNALLED = 1
RESULT_ERROR = 2
MAX_FDS = 64

FORWARDED_SIGNALS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP,
                     signal.SIGQUIT, signal.SIGUSR1, signal.SIGUSR2)


# A fixed path, because Codex re-executes filesystem operations with only PATH
# and the temporary-directory variables: HOME and XDG_CACHE_HOME are not there
# to derive one from. /var/cache is flatpak's own mapping of
# ~/.var/app/<id>/cache, so it exists whatever the environment says.
ERROR_LOG = "/var/cache/chatgpt-flatpak/bwrap-error.log"


def record(message):
    """Leave the last failure somewhere it can be found afterwards.

    Codex swallows a command's stderr when the command fails, so the most
    important message this program produces is also the one most likely to be
    lost -- and if the broker is not running there is no journal on the other
    side either. Truncated rather than appended: one file holding the most
    recent reason is bounded, and a client that cannot reach the broker would
    otherwise grow it on every command Codex tries.
    """
    try:
        os.makedirs(os.path.dirname(ERROR_LOG), mode=0o700, exist_ok=True)
        stamp = time.strftime("%Y-%m-%d %H:%M:%S")
        with open(ERROR_LOG, "w") as f:
            f.write(f"{stamp} bwrap: {message}\n")
    except OSError:
        pass


def die(message, code=1):
    print(f"bwrap: {message}", file=sys.stderr, flush=True)
    record(message)
    sys.exit(code)


# --- argument walk --------------------------------------------------------
# Only to locate descriptors. The arguments themselves are passed through
# untouched, including anything this table does not understand the meaning of.

ARITY = {
    "--args": 1, "--argv0": 1, "--level-prefix": 0, "--unshare-all": 0,
    "--share-net": 0, "--unshare-user": 0, "--unshare-user-try": 0,
    "--unshare-ipc": 0, "--unshare-pid": 0, "--unshare-net": 0,
    "--unshare-uts": 0, "--unshare-cgroup": 0, "--unshare-cgroup-try": 0,
    "--userns": 1, "--userns2": 1, "--disable-userns": 0,
    "--assert-userns-disabled": 0, "--pidns": 1, "--uid": 1, "--gid": 1,
    "--hostname": 1, "--chdir": 1, "--clearenv": 0, "--setenv": 2,
    "--unsetenv": 1, "--lock-file": 1, "--sync-fd": 1, "--bind": 2,
    "--bind-try": 2, "--dev-bind": 2, "--dev-bind-try": 2, "--ro-bind": 2,
    "--ro-bind-try": 2, "--bind-fd": 2, "--ro-bind-fd": 2, "--remount-ro": 1,
    "--overlay-src": 1, "--overlay": 3, "--tmp-overlay": 1, "--ro-overlay": 1,
    "--exec-label": 1, "--file-label": 1, "--proc": 1, "--dev": 1,
    "--tmpfs": 1, "--mqueue": 1, "--dir": 1, "--file": 2, "--bind-data": 2,
    "--ro-bind-data": 2, "--symlink": 2, "--seccomp": 1,
    "--add-seccomp-fd": 1, "--block-fd": 1, "--userns-block-fd": 1,
    "--info-fd": 1, "--json-status-fd": 1, "--new-session": 0,
    "--die-with-parent": 0, "--as-pid-1": 0, "--cap-add": 1, "--cap-drop": 1,
    "--perms": 1, "--size": 1, "--chmod": 2,
}

# Which argument of the flag is a descriptor number.
FD_ARGUMENT = {
    "--args": 0, "--userns": 0, "--userns2": 0, "--pidns": 0, "--sync-fd": 0,
    "--seccomp": 0, "--add-seccomp-fd": 0, "--block-fd": 0,
    "--userns-block-fd": 0, "--info-fd": 0, "--json-status-fd": 0,
    "--bind-fd": 0, "--ro-bind-fd": 0, "--file": 0, "--bind-data": 0,
    "--ro-bind-data": 0,
}


def expand_args_fd(argv):
    """Splice in any NUL-separated argument list given with --args.

    The list has to be flattened here rather than forwarded, because arguments
    inside it can name descriptors of their own and the broker would have no
    way to see them. A spliced list may contain a further --args.
    """
    out = []
    pending = list(argv)
    budget = 64
    while pending:
        arg = pending.pop(0)
        if arg != "--args":
            out.append(arg)
            continue
        if not pending:
            die("--args needs a file descriptor")
        fd = pending.pop(0)
        if not fd.isdigit():
            die(f"--args with a non-numeric descriptor '{fd}'")
        budget -= 1
        if budget < 0:
            die("--args nested too deeply")
        try:
            with open(f"/proc/self/fd/{int(fd)}", "rb") as f:
                blob = f.read()
        except OSError as e:
            die(f"--args descriptor {fd} is not readable: {e}")
        words = blob.split(b"\0")
        if words and words[-1] == b"":
            words.pop()
        pending = [w.decode("utf-8", "surrogateescape") for w in words] + pending
    return out


def descriptors_in(argv):
    """Every descriptor the arguments refer to, with the number they use.

    Walking with an arity table rather than scanning for digits, because a
    value can look like anything: `--setenv SECCOMP --seccomp` would otherwise
    be read as naming a descriptor.
    """
    wanted = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--":
            break
        if not arg.startswith("-"):
            break
        if arg not in ARITY:
            die(f"unrecognised option {arg}: this client must be updated "
                f"before it can forward it safely")

        count = ARITY[arg]
        if i + count > len(argv) - 1:
            die(f"{arg} is missing an argument")

        position = FD_ARGUMENT.get(arg)
        if position is not None:
            value = argv[i + 1 + position]
            if not value.isdigit():
                die(f"{arg} expects a descriptor number, got '{value}'")
            number = int(value)
            if not os.path.exists(f"/proc/self/fd/{number}"):
                die(f"{arg}: descriptor {number} is not open")
            if number not in wanted:
                wanted.append(number)
        i += 1 + count
    return wanted


# --- request --------------------------------------------------------------


def blob(data):
    return struct.pack("<I", len(data)) + data


def blob_list(items):
    return struct.pack("<I", len(items)) + b"".join(blob(i) for i in items)


def wire_argv(program, options):
    """A full argv, position 0 included, the way execve() takes one.

    The broker substitutes the real bubblewrap path for position 0 and passes
    the rest through. Sending only the options would make it drop the first
    one, and bwrap would then read that option's value as the command to run --
    `execvp /: Permission denied` and nothing else to go on.
    """
    return [program] + options


def build_request(argv, fds):
    argv_bytes = [a.encode("utf-8", "surrogateescape") for a in argv]
    env_bytes = [k + b"=" + v for k, v in os.environb.items()]
    try:
        cwd = os.getcwdb()
    except OSError:
        cwd = b"/"
    return (MAGIC + bytes([MSG_EXEC])
            + blob_list(argv_bytes)
            + blob_list(env_bytes)
            + blob(cwd)
            + struct.pack("<I", len(fds))
            + b"".join(struct.pack("<I", f) for f in fds))


def app_id():
    """From .flatpak-info, not from the environment.

    Codex re-executes filesystem operations with only PATH and the temporary
    directory variables, so FLATPAK_ID is not there to be read.
    """
    try:
        with open("/.flatpak-info") as f:
            section = None
            for line in f:
                line = line.strip()
                if line.startswith("[") and line.endswith("]"):
                    section = line[1:-1]
                elif section == "Application" and line.startswith("name="):
                    return line[5:]
    except OSError:
        pass
    return os.environ.get("FLATPAK_ID")


def socket_path():
    name = app_id()
    if not name:
        die("cannot determine the flatpak application id")
    runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    return os.path.join(runtime, "app", name, "bwrap-broker.sock"), name


def connect():
    path, name = socket_path()
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    try:
        sock.connect(path)
    except OSError as e:
        if e.errno in (errno.ENOENT, errno.ECONNREFUSED):
            # Both halves are offered because this cannot tell them apart from
            # in here: a socket that is missing usually means the broker was
            # never installed, but it means the same thing to connect() as one
            # whose service has died.
            die(f"the sandbox broker is not running on the host.\n"
                f"  This command was not run. Codex cannot sandbox anything "
                f"until the broker is up.\n"
                f"\n"
                f"  Install it on the host with:\n"
                f"      \"$(flatpak info {name} -l)/files/extra/chatgpt/"
                f"sandbox-host/install.sh\"\n"
                f"  If it is installed:\n"
                f"      systemctl --user enable --now "
                f"flatpak-bwrap-broker@{name}.socket\n"
                f"      journalctl --user -u "
                f"flatpak-bwrap-broker@{name}.service -e\n"
                f"\n"
                f"  Socket looked for: {path}\n"
                f"  This message is also written to {ERROR_LOG}", 127)
        if e.errno in (errno.EPERM, errno.EACCES):
            # Almost always this: a command that is already sandboxed has a
            # seccomp filter of its own, and connect() is one of the calls it
            # refuses. Nesting is refused by the broker too, for a related
            # reason -- it could not carry that filter into the new sandbox.
            die(f"cannot reach the bwrap broker: {e}\n"
                f"  This usually means the command is already running inside a "
                f"sandbox.\n"
                f"  Sandboxes cannot be nested here: the broker cannot inherit "
                f"the\n"
                f"  seccomp filter this command is under, so the inner sandbox "
                f"would be\n"
                f"  less confined than the one asking for it.", 127)
        die(f"cannot reach the bwrap broker at {path}: {e}", 127)
    return sock


def main():
    options = sys.argv[1:]
    argv = options  # kept for the --help/--version check below

    # Codex feature-detects by running `bwrap --help` and looking for --perms,
    # and reads --version. Neither needs a namespace, so the real binary can
    # answer them here and the option list never has to be kept in sync by
    # hand.
    if argv and argv[0] in ("--help", "--version"):
        try:
            os.execv(REAL_BWRAP, [REAL_BWRAP, argv[0]])
        except OSError as e:
            die(f"{REAL_BWRAP}: {e}")

    options = expand_args_fd(options)
    fds = [0, 1, 2] + [f for f in descriptors_in(options) if f > 2]
    if len(fds) > MAX_FDS:
        die(f"too many descriptors to forward ({len(fds)})")

    request = build_request(wire_argv(sys.argv[0], options), fds)
    sock = connect()

    try:
        sock.sendmsg([request],
                     [(socket.SOL_SOCKET, socket.SCM_RIGHTS,
                       array.array("i", fds))])
    except OSError as e:
        die(f"cannot send the request to the broker: {e}", 127)

    # A signal cannot be delivered across the pid namespace boundary, so it is
    # relayed as a message. The wakeup pipe keeps the handler itself trivial.
    reader, writer = os.pipe()
    os.set_blocking(writer, False)
    signal.set_wakeup_fd(writer)
    received = []
    for signo in FORWARDED_SIGNALS:
        signal.signal(signo, lambda number, frame: received.append(number))

    while True:
        try:
            ready, _, _ = select.select([sock, reader], [], [])
        except InterruptedError:
            continue

        if reader in ready:
            try:
                os.read(reader, 4096)
            except OSError:
                pass
            while received:
                signo = received.pop(0)
                try:
                    sock.sendmsg([MAGIC + bytes([MSG_SIGNAL])
                                  + struct.pack("<I", signo)])
                except OSError:
                    pass

        if sock in ready:
            try:
                reply = sock.recv(65536)
            except OSError as e:
                die(f"lost the connection to the broker: {e}", 127)
            if not reply:
                die("the broker closed the connection without a result", 127)
            if len(reply) < 14 or reply[:4] != MAGIC or reply[4] != MSG_RESULT:
                die("malformed reply from the broker", 127)

            kind = reply[5]
            value = struct.unpack("<I", reply[6:10])[0]
            length = struct.unpack("<I", reply[10:14])[0]
            text = reply[14:14 + length].decode("utf-8", "replace")

            if kind == RESULT_EXITED:
                return value
            if kind == RESULT_SIGNALLED:
                # Die the same way the command did, so a caller reading the
                # wait status sees what it would have seen natively.
                signal.signal(value, signal.SIG_DFL)
                os.kill(os.getpid(), value)
                return 128 + value
            die(f"broker refused the request: {text}", 127)


if __name__ == "__main__":
    sys.exit(main())
