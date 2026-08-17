#!/usr/bin/env python3
"""Tests for the parts of the broker that do not need a flatpak to be running.

The end-to-end behaviour -- joining namespaces, running bubblewrap, what the
command can actually reach -- is measured by test-broker-live.sh against an
installed flatpak, and that is where every bug found while building this
actually was. What is checked here is what can be got wrong silently without a
live app to notice it:

  * the seccomp program's jump offsets, by interpreting it. A filter with a
    miscomputed offset fails *open*, which no amount of manual reading reliably
    catches;
  * the wire protocol, by encoding with the client's code and decoding with the
    broker's;
  * the argument walk that decides which descriptors get forwarded, which is
    the one piece of bwrap semantics the client still has to understand.

Run: python3 host/test-broker.py
"""

import ctypes
import fcntl
import importlib.machinery
import importlib.util
import os
import struct
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
ROOT = os.path.dirname(HERE)

failures = []
checks = 0


def check(condition, description):
    global checks
    checks += 1
    if not condition:
        failures.append(description)
        print(f"FAIL  {description}")
    else:
        print(f"ok    {description}")


def load(path, name):
    spec = importlib.util.spec_from_loader(
        name, importlib.machinery.SourceFileLoader(name, path))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


sys.path.insert(0, HERE)
import seccomp_policy  # noqa: E402

client = load(os.path.join(ROOT, "com.openai.ChatGPT", "bwrap-client.py"),
              "bwrap_client")
broker = load(os.path.join(HERE, "flatpak-bwrap-broker"), "broker")


# --- the seccomp program -------------------------------------------------

BPF_LD, BPF_JMP, BPF_RET = 0x00, 0x05, 0x06
BPF_W, BPF_ABS, BPF_JEQ, BPF_JGE, BPF_K = 0x00, 0x20, 0x10, 0x30, 0x00


def run_filter(program, nr, arch=seccomp_policy.AUDIT_ARCH_X86_64, arg0=0,
               arg1=0):
    """A cBPF interpreter, so the filter is checked by execution not by eye."""
    data = struct.pack("<IIQ6Q", nr & 0xFFFFFFFF, arch, 0,
                       arg0, arg1, 0, 0, 0, 0)
    instructions = [program[i:i + 8] for i in range(0, len(program), 8)]

    acc = 0
    pc = 0
    for _ in range(10000):
        code, jt, jf, k = struct.unpack("HBBI", instructions[pc])
        pc += 1
        if code == (BPF_LD | BPF_W | BPF_ABS):
            acc = struct.unpack_from("<I", data, k)[0]
        elif code == (BPF_JMP | BPF_JEQ | BPF_K):
            pc += jt if acc == k else jf
        elif code == (BPF_JMP | BPF_JGE | BPF_K):
            pc += jt if acc >= k else jf
        elif code == (BPF_RET | BPF_K):
            return k
        else:
            raise AssertionError(f"unhandled BPF code {code:#x}")
        if pc >= len(instructions):
            raise AssertionError("ran off the end of the filter")
    raise AssertionError("filter did not terminate")


def test_seccomp_program():
    print("\n== seccomp program ==")
    prog = seccomp_policy.build_program()
    allow = seccomp_policy.SECCOMP_RET_ALLOW
    eperm = seccomp_policy.SECCOMP_RET_ERRNO | seccomp_policy.EPERM
    eaf = seccomp_policy.SECCOMP_RET_ERRNO | seccomp_policy.EAFNOSUPPORT
    kill = seccomp_policy.SECCOMP_RET_KILL_PROCESS

    for nr, name in sorted(seccomp_policy.BLOCKED_EPERM.items()):
        check(run_filter(prog, nr) == eperm, f"{name} ({nr}) is refused")

    # The hole, stated as a test so that closing it by accident is a failure
    # and widening it is a visible change to this list.
    for nr in sorted(seccomp_policy.NEEDED_BY_BWRAP):
        check(run_filter(prog, nr) == allow,
              f"syscall {nr} stays allowed for bubblewrap")

    for nr in (0, 1, 2, 59, 60, 231, 257):  # read/write/open/execve/exit/openat
        check(run_filter(prog, nr) == allow, f"ordinary syscall {nr} allowed")

    for family in seccomp_policy.ALLOWED_FAMILIES:
        check(run_filter(prog, seccomp_policy.SYS_socket, arg0=family) == allow,
              f"socket family {family} allowed")
    for family in (3, 17, 31, 40, 44):  # AF_AX25, AF_PACKET, AF_BLUETOOTH, ...
        check(run_filter(prog, seccomp_policy.SYS_socket, arg0=family) == eaf,
              f"socket family {family} refused")

    # ioctl is filtered by request, not refused outright: the two terminal
    # requests flatpak blocks are CVE fixes (TIOCSTI CVE-2017-5226, TIOCLINUX
    # CVE-2023-28100) and everything else about ioctl has to keep working.
    for request in sorted(seccomp_policy.BLOCKED_IOCTLS):
        check(run_filter(prog, seccomp_policy.SYS_ioctl, arg1=request) == eperm,
              f"ioctl request {request:#x} is refused")
    for request in (0x5401, 0x541B, 0x5413, 0x00):  # TCGETS, FIONREAD, ...
        check(run_filter(prog, seccomp_policy.SYS_ioctl, arg1=request) == allow,
              f"ioctl request {request:#x} still allowed")

    check(run_filter(prog, 1, arch=0x40000003) == kill,
          "a foreign architecture is killed, not allowed")
    check(run_filter(prog, 0x40000000 | 1) == kill,
          "an x32 syscall number is killed, not allowed")

    # The claim SANDBOXING.md makes is parity with flatpak minus the namespace
    # group. FLATPAK_BLOCKLIST is written from flatpak's source and is
    # deliberately not derived from our own list, so this can catch the one
    # direction that widens the sandbox: flatpak refuses it, we do not.
    for nr, name in sorted(seccomp_policy.FLATPAK_BLOCKLIST.items()):
        if nr in seccomp_policy.NEEDED_BY_BWRAP:
            continue
        check(run_filter(prog, nr) == eperm,
              f"flatpak refuses {name} ({nr}), so this must too")

    # Nothing above reaches the blocklist by accident: verify the socket path
    # rejoins in the right place by checking a blocked syscall still blocks
    # when it follows the socket comparison.
    check(run_filter(prog, 101) == eperm, "ptrace still blocked after the socket branch")


def test_seccomp_install():
    print("\n== seccomp install (live) ==")
    inside_flatpak = os.path.exists("/.flatpak-info")
    if inside_flatpak:
        print("  note: inside a flatpak, whose filter already refuses these,")
        print("        so this only proves the filter installs and allows.")

    reader, writer = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(reader)
        try:
            seccomp_policy.install()
            libc = ctypes.CDLL(None, use_errno=True)
            results = []
            # keyctl(KEYCTL_GET_KEYRING_ID) -- refused by the filter
            results.append(libc.syscall(ctypes.c_long(250), 0, 0, 0) < 0)
            # a plain AF_UNIX socket must still work
            import socket as s
            try:
                s.socket(s.AF_UNIX, s.SOCK_STREAM).close()
                results.append(True)
            except OSError:
                results.append(False)
            os.write(writer, bytes(results))
        except BaseException as e:  # noqa: BLE001
            os.write(writer, b"E" + str(e).encode()[:200])
        os._exit(0)

    os.close(writer)
    out = os.read(reader, 256)
    os.waitpid(pid, 0)

    if out[:1] == b"E":
        check(False, f"filter installs: {out[1:].decode()}")
        return
    check(len(out) == 2, "the filtered child ran to completion")
    if len(out) == 2:
        check(out[0] == 1, "keyctl is refused under the filter")
        check(out[1] == 1, "AF_UNIX sockets still work under the filter")


# --- the wire protocol ---------------------------------------------------


def test_protocol_roundtrip():
    print("\n== protocol ==")
    argv = ["bwrap", "--unshare-all", "--ro-bind", "/", "/", "--", "/bin/true"]
    fds = [0, 1, 2, 15]
    request = client.build_request(argv, fds)
    parsed = broker.parse_exec(request)

    check([a.decode() for a in parsed["argv"]] == argv, "argv survives the hop")
    check(parsed["fds"] == fds, "the descriptor table survives the hop")
    check(parsed["cwd"] == os.getcwdb(), "cwd survives the hop")

    # Arguments are not required to be valid UTF-8, and a client that forced
    # them through a text encoding would corrupt them.
    raw = "\udcff\udcfe".encode("utf-8", "surrogateescape")
    weird = raw.decode("utf-8", "surrogateescape")
    parsed = broker.parse_exec(client.build_request(["bwrap", weird], [0, 1, 2]))
    check(parsed["argv"][1] == raw, "non-UTF-8 arguments pass through intact")

    # The one thing both sides have to agree on, and the previous round-trip
    # test did not pin: who owns position 0. The client encoded options only
    # while the broker dropped position 0 as a program name, so --ro-bind was
    # eaten and bwrap read `/` as the command -- `execvp /: Permission denied`,
    # with nothing pointing at the cause.
    options = ["--ro-bind", "/", "/", "--chdir", "/", "--", "/bin/sh", "-c",
               "echo hello"]
    request = client.build_request(
        client.wire_argv("/app/bin/bwrap", options), [0, 1, 2])
    real = "/app/libexec/flatpak-bwrap-broker/bwrap"
    produced = broker.exec_argv(broker.parse_exec(request)["argv"], real)

    check(produced == [real] + options,
          "the exec argv is the real bwrap plus every option, none dropped")
    check(produced[1] == "--ro-bind",
          "the first option survives: position 0 is the program name")

    for bad, why in (
        (b"XXXX" + bytes([1]), "bad magic"),
        (broker.MAGIC + bytes([99]), "wrong message type"),
        (broker.MAGIC + bytes([1]) + b"\xff\xff\xff\xff", "absurd argv count"),
        (broker.MAGIC + bytes([1]) + struct.pack("<I", 1)
         + struct.pack("<I", 500), "argv longer than the message"),
    ):
        try:
            broker.parse_exec(bad)
            check(False, f"{why} is refused")
        except broker.Refused:
            check(True, f"{why} is refused")


# --- the argument walk ---------------------------------------------------


def test_descriptor_scan():
    print("\n== descriptor scan ==")

    # A value that looks like a flag must not be read as one. This is why the
    # walk uses an arity table instead of scanning for digits.
    argv = ["--setenv", "SECCOMP", "--seccomp", "--ro-bind", "/", "/",
            "--", "/bin/true"]
    check(client.descriptors_in(argv) == [], "a flag-shaped value is not a flag")

    # Codex's real shape: fds named by number after flags that take them.
    with open("/dev/null") as a, open("/dev/null") as b:
        argv = ["--seccomp", str(a.fileno()),
                "--ro-bind-fd", str(b.fileno()), "/x",
                "--", "/bin/true"]
        found = client.descriptors_in(argv)
        check(found == [a.fileno(), b.fileno()],
              "fd-taking flags are found in both positions")

    check(client.descriptors_in(["--", "--seccomp", "9"]) == [],
          "nothing after -- is parsed as a flag")

    every = set(client.FD_ARGUMENT) - {"--args"}
    check(every <= set(client.ARITY),
          "every fd-taking flag has an arity entry")
    for flag, position in client.FD_ARGUMENT.items():
        check(position < client.ARITY[flag],
              f"{flag}: the fd position is within its arity")


def test_args_expansion():
    print("\n== --args expansion ==")
    reader, writer = os.pipe()
    os.write(writer, b"--unshare-net\0--ro-bind\0/\0/\0")
    os.close(writer)
    try:
        out = client.expand_args_fd(["--die-with-parent", "--args", str(reader),
                                     "--", "/bin/true"])
        check(out == ["--die-with-parent", "--unshare-net", "--ro-bind", "/",
                      "/", "--", "/bin/true"],
              "--args is spliced in at the right position")
    finally:
        os.close(reader)


def surviving_fds(wanted, supplied=None, preserve=None):
    """What a command would actually inherit, measured in a forked child.

    install_fds() runs for real and /proc/self/fd is read afterwards. This is
    the layer that could have caught the stdio leak and did not exist: unlike
    the namespace entry, none of it needs an app or a broker.
    """
    # The result cannot come back over a pipe: install_fds() closes every
    # descriptor it was not told to keep, and the pipe would be one of them.
    # So the child reports through a path it opens *after* the shuffle.
    handle, report = tempfile.mkstemp()
    os.close(handle)

    pid = os.fork()
    if pid == 0:
        try:
            # Stand-ins for what the broker holds at this point -- the socket,
            # the pidfd, the namespace descriptors. None of them may survive.
            # A named file rather than /dev/null so that a descriptor the
            # client supplied is distinguishable from one filled in for it.
            received = [os.open(report, os.O_RDONLY) for _ in wanted]
            kept = None
            if preserve is not None:
                kept = fcntl.fcntl(os.open(os.devnull, os.O_RDONLY),
                                   fcntl.F_DUPFD, preserve)
            broker.install_fds(received, wanted, preserve=kept)
            live = sorted(int(n) for n in os.listdir("/proc/self/fd")
                          if n.isdigit())
            # Where 0, 1 and 2 point matters as much as whether they exist:
            # the invariant is that they are the client's or /dev/null, never
            # something inherited.
            where = []
            for fd in (0, 1, 2):
                try:
                    where.append(f"{fd}={os.readlink(f'/proc/self/fd/{fd}')}")
                except OSError:
                    where.append(f"{fd}=absent")
            with open(report, "w") as f:
                f.write(",".join(str(n) for n in live) + "|" + ",".join(where))
        except BaseException as e:  # noqa: BLE001
            try:
                with open(report, "w") as f:
                    f.write(f"E{e}")
            except OSError:
                pass
        os._exit(0)

    os.waitpid(pid, 0)
    with open(report) as f:
        out = f.read()
    os.unlink(report)
    return out


def test_install_fds():
    print("\n== descriptor installation ==")

    # The listing includes the fd os.listdir opened, so compare against a set
    # that tolerates one extra transient number.
    def survives(out):
        if out.startswith("E") or not out:
            return out or "E<no report>", ""
        listing, _, stdio = out.partition("|")
        return {int(n) for n in listing.split(",") if n}, stdio

    got, _ = survives(surviving_fds([0, 1, 2]))
    check(isinstance(got, set) and {0, 1, 2} <= got,
          "the ordinary case installs stdio")

    # The leak this fixes: a client that omits stdio used to leave the broker's
    # own in place, and under systemd that is its journald socket. The command
    # must get /dev/null instead -- and must not get *nothing*, or the next
    # open() lands on fd 0 and a write meant for stdout goes into a file.
    got, stdio = survives(surviving_fds([]))
    check(isinstance(got, set) and {0, 1, 2} <= got,
          "an empty table still leaves 0,1,2 open, not closed")
    check(all(f"{fd}=/dev/null" in stdio for fd in (0, 1, 2)),
          f"an omitted stdio becomes /dev/null, not the broker's ({stdio})")

    # And a partial table: the supplied one is the client's, the rest /dev/null.
    got, stdio = survives(surviving_fds([1]))
    check("1=/dev/null" not in stdio and "0=/dev/null" in stdio
          and "2=/dev/null" in stdio,
          f"a partial table fills only the gaps ({stdio})")

    # Crossed targets: 3->4 and 4->3 in one request must not clobber.
    got, _ = survives(surviving_fds([4, 3]))
    check(isinstance(got, set) and {3, 4} <= got,
          "crossed target numbers both survive")

    # Nothing above the requested set survives, so the socket, pidfd and
    # namespace descriptors cannot reach the command.
    got, _ = survives(surviving_fds([0, 1, 2, 7]))
    check(isinstance(got, set) and not {f for f in got if 7 < f < 100},
          "no descriptor above the requested set survives")

    # The reason pipe is kept but must be beyond anything a client may ask for.
    got, _ = survives(surviving_fds([0, 1, 2], preserve=broker.REASON_FD))
    check(isinstance(got, set) and broker.REASON_FD in got,
          "the reason pipe survives the shuffle")
    check(broker.REASON_FD > broker.MAX_FD_NUMBER,
          "the reason pipe is above every number a client may request")


def test_fd_table_limits():
    print("\n== descriptor table validation ==")
    for table, why in (
        ([0, 1, 2, broker.MAX_FD_NUMBER + 1], "a number above the limit"),
        ([0, 1, 2, 0xFFFFFFFF], "an absurd number"),
        ([0, 1, 1], "a repeated number"),
    ):
        request = client.build_request(["bwrap", "--version"], table)
        try:
            broker.parse_exec(request)
            check(False, f"{why} is refused")
        except broker.Refused:
            check(True, f"{why} is refused")


def main():
    test_seccomp_program()
    test_seccomp_install()
    test_protocol_roundtrip()
    test_install_fds()
    test_fd_table_limits()
    test_descriptor_scan()
    test_args_expansion()

    print(f"\n{checks - len(failures)}/{checks} checks passed")
    for f in failures:
        print(f"  failed: {f}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
