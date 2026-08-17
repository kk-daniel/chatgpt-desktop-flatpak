"""Put back the part of flatpak's seccomp filter that bubblewrap does not need.

The broker runs outside flatpak's filter -- that is the entire reason it exists,
since unshare/setns/mount/pivot_root/clone(CLONE_NEWUSER) are what the filter
denies and what bubblewrap requires. But bubblewrap needs *only* those. The rest
of flatpak's blocklist -- the keyring, ptrace, perf_event_open, the NUMA calls,
the odd socket families -- has nothing to do with building a sandbox, and
leaving it off would hand every command a wider kernel surface than any process
inside the app has, for no reason.

So this reinstates the rest of the policy in the broker, immediately before
bubblewrap is exec'd. Seccomp filters survive execve() and are inherited across
fork and namespace creation, so one filter installed here covers bubblewrap, the
codex-linux-sandbox helper and the command itself. Codex's own --seccomp filter
is layered on top by bwrap in the usual way; filters accumulate and the most
restrictive answer wins.

What is deliberately still allowed is the namespace group. That is the
irreducible cost of running bubblewrap at all, and it is described that way
rather than hidden.

The list below is flatpak's as of writing, which is a claim that can rot.
host/test-seccomp-parity.sh checks every entry against the running app rather than
against this comment, in both directions: refusing something flatpak allows
makes a Codex command fail for no visible reason, and allowing something flatpak
refuses widens the sandbox silently.

Syscall numbers are x86_64. The architecture is checked first, so a process that
tries the i386 or x32 entry points to reach a different numbering is killed
rather than let through.
"""

import ctypes
import os
import struct

# --- BPF ------------------------------------------------------------------

BPF_LD = 0x00
BPF_JMP = 0x05
BPF_RET = 0x06
BPF_W = 0x00
BPF_ABS = 0x20
BPF_JEQ = 0x10
BPF_JGE = 0x30
BPF_K = 0x00

SECCOMP_RET_KILL_PROCESS = 0x80000000
SECCOMP_RET_ERRNO = 0x00050000
SECCOMP_RET_ALLOW = 0x7FFF0000

AUDIT_ARCH_X86_64 = 0xC000003E
X32_BIT = 0x40000000

# offsetof(struct seccomp_data, ...)
OFF_NR = 0
OFF_ARCH = 4
OFF_ARG0_LO = 16
OFF_ARG1_LO = 24

PR_SET_NO_NEW_PRIVS = 38
SECCOMP_SET_MODE_FILTER = 1
SYS_seccomp = 317

EPERM = 1
EAFNOSUPPORT = 97


def stmt(code, k):
    return struct.pack("HBBI", code, 0, 0, k)


def jump(code, k, jt, jf):
    return struct.pack("HBBI", code, jt, jf, k)


# --- the policy -----------------------------------------------------------

BLOCKED_EPERM = {
    103: "syslog",           # the kernel ring buffer
    134: "uselib",           # obsolete loader path
    154: "modify_ldt",       # 16-bit code, and a historic info-leak source
    163: "acct",             # switching off process accounting
    179: "quotactl",         # other users' quota usage
    248: "add_key",          # the kernel keyring
    249: "request_key",
    250: "keyctl",
    237: "mbind",            # NUMA and page-migration operations
    238: "set_mempolicy",
    239: "get_mempolicy",
    256: "migrate_pages",
    279: "move_pages",
    # flatpak's non-devel set. The app is not run with --allow=devel, so these
    # are refused for it, and refusing them here keeps the two the same. It
    # does mean a debugger cannot be run inside a Codex sandbox -- which is
    # also true inside the app today.
    101: "ptrace",
    135: "personality",
    298: "perf_event_open",
}

# Absent on purpose, and the only hole this broker opens:
#   56  clone          155 pivot_root     161 chroot        165 mount
#   166 umount2        272 unshare        308 setns         435 clone3
NEEDED_BY_BWRAP = {56, 155, 161, 165, 166, 272, 308, 435}

SYS_socket = 41
ALLOWED_FAMILIES = (1, 2, 10, 16)  # AF_UNIX, AF_INET, AF_INET6, AF_NETLINK

# ioctl is filtered by request rather than refused: both of these are CVE
# fixes flatpak carries, and everything else ioctl does has to keep working.
SYS_ioctl = 16
BLOCKED_IOCTLS = {
    0x5412: "TIOCSTI",    # inject into the terminal input queue, CVE-2017-5226
    0x541C: "TIOCLINUX",  # the same trick by another route, CVE-2023-28100
}

# What flatpak refuses, written from its own blocklists and deliberately *not*
# derived from anything above. That independence is the point: a list computed
# from BLOCKED_EPERM could only ever confirm itself, and the direction that
# matters -- flatpak refuses X and we do not -- would be invisible.
#
# It is a hypothesis about flatpak's source, and it is checked rather than
# trusted. test-broker.py asserts the filter refuses all of it, and
# test-seccomp-parity.sh asserts the running app refuses all of it too, so a
# wrong entry here shows up as a parity failure instead of a silent hole.
# Entries in NEEDED_BY_BWRAP are the documented exception.
FLATPAK_BLOCKLIST = {
    103: "syslog", 134: "uselib", 154: "modify_ldt", 163: "acct",
    179: "quotactl", 248: "add_key", 249: "request_key", 250: "keyctl",
    237: "mbind", 238: "set_mempolicy", 239: "get_mempolicy",
    256: "migrate_pages", 279: "move_pages",
    # "Don't allow subnamespace setups" -- the group this broker exists to open.
    56: "clone", 155: "pivot_root", 161: "chroot", 165: "mount",
    166: "umount2", 272: "unshare", 308: "setns", 435: "clone3",
    # syscall_nondevel_blocklist, which applies because the app has no
    # --allow=devel.
    101: "ptrace", 135: "personality", 298: "perf_event_open",
}


def build_program():
    """Assemble the filter.

    Jump targets in BPF are relative offsets counted in instructions from the
    one after the jump, and an arithmetic slip here fails open rather than
    closed. So the layout is written out with absolute indices and each offset
    is derived from them.
    """
    for nr in BLOCKED_EPERM:
        assert nr not in NEEDED_BY_BWRAP, f"syscall {nr} is needed by bubblewrap"
    # Both are filtered by argument further down, so a flat entry as well would
    # refuse them outright once the argument branch rejoins.
    for nr in (SYS_socket, SYS_ioctl):
        assert nr not in BLOCKED_EPERM, f"syscall {nr} is filtered by argument"

    families = list(ALLOWED_FAMILIES)
    requests = sorted(BLOCKED_IOCTLS)
    n = len(families)
    m = len(requests)

    #   0        load arch
    #   1        arch == x86_64 ? -> 3 : -> 2
    #   2        kill
    #   3        load nr
    #   4        nr >= x32 bit ? -> 5 : -> 6
    #   5        kill
    #   6        nr == socket ? -> 7 : -> after_socket
    #   7        load arg0 (family)
    #   8+k      family == allowed[k] ? -> after_socket : next
    #   8+n      return EAFNOSUPPORT
    #   9+n      load nr                             <- after_socket
    #   10+n     nr == ioctl ? -> 11+n : -> after_ioctl
    #   11+n     load arg1 (request)
    #   12+n+j   request == blocked[j] ? -> 12+n+m : next
    #   12+n+m   return EPERM
    #   13+n+m   load nr                             <- after_ioctl
    #   then the flat blocklist, then allow
    after_socket = 9 + n
    after_ioctl = 13 + n + m

    prog = [
        stmt(BPF_LD | BPF_W | BPF_ABS, OFF_ARCH),
        jump(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_X86_64, 1, 0),
        stmt(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
        stmt(BPF_LD | BPF_W | BPF_ABS, OFF_NR),
        jump(BPF_JMP | BPF_JGE | BPF_K, X32_BIT, 0, 1),
        stmt(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
        jump(BPF_JMP | BPF_JEQ | BPF_K, SYS_socket, 0, after_socket - 7),
        stmt(BPF_LD | BPF_W | BPF_ABS, OFF_ARG0_LO),
    ]
    for k, family in enumerate(families):
        prog.append(jump(BPF_JMP | BPF_JEQ | BPF_K, family,
                         after_socket - (9 + k), 0))
    prog.append(stmt(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EAFNOSUPPORT))
    prog.append(stmt(BPF_LD | BPF_W | BPF_ABS, OFF_NR))
    assert len(prog) == after_socket + 1

    prog.append(jump(BPF_JMP | BPF_JEQ | BPF_K, SYS_ioctl, 0,
                     after_ioctl - (11 + n)))
    prog.append(stmt(BPF_LD | BPF_W | BPF_ABS, OFF_ARG1_LO))
    for j, request in enumerate(requests):
        # The sense is inverted from the socket chain above: there a match means
        # allowed and falling off the end means refused, here a match means
        # refused, so the last comparison has to step *over* the refusal.
        prog.append(jump(BPF_JMP | BPF_JEQ | BPF_K, request,
                         m - j - 1, 1 if j == m - 1 else 0))
    prog.append(stmt(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM))
    prog.append(stmt(BPF_LD | BPF_W | BPF_ABS, OFF_NR))
    assert len(prog) == after_ioctl + 1

    for nr in sorted(BLOCKED_EPERM):
        prog.append(jump(BPF_JMP | BPF_JEQ | BPF_K, nr, 0, 1))
        prog.append(stmt(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM))

    prog.append(stmt(BPF_RET | BPF_K, SECCOMP_RET_ALLOW))
    return b"".join(prog)


def install():
    """Apply the filter to this process and everything it goes on to run."""
    libc = ctypes.CDLL(None, use_errno=True)
    libc.prctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_ulong,
                           ctypes.c_ulong, ctypes.c_ulong]
    libc.syscall.argtypes = [ctypes.c_long, ctypes.c_ulong, ctypes.c_ulong,
                             ctypes.c_void_p]
    libc.syscall.restype = ctypes.c_long

    # An unprivileged process may only install a filter once new privileges are
    # already forbidden. The broker sets this when it drops capabilities; doing
    # it here as well keeps this function usable on its own.
    if libc.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0:
        err = ctypes.get_errno()
        raise OSError(err, f"PR_SET_NO_NEW_PRIVS: {os.strerror(err)}")

    program = build_program()
    count = len(program) // 8
    if count > 0xFFFF:
        raise ValueError("filter too long")

    instructions = ctypes.create_string_buffer(program, len(program))
    # struct sock_fprog { unsigned short len; struct sock_filter *filter; }
    fprog = ctypes.create_string_buffer(
        struct.pack("HxxxxxxP", count, ctypes.addressof(instructions)), 16)

    if libc.syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, 0,
                    ctypes.cast(fprog, ctypes.c_void_p)) != 0:
        err = ctypes.get_errno()
        raise OSError(err, f"seccomp(SET_MODE_FILTER): {os.strerror(err)}")
