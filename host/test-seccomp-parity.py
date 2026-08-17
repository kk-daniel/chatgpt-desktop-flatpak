#!/usr/bin/env python3
"""Probe: call each syscall the broker's policy refuses and report the errno.

Run inside the app and again on the host under the broker's filter, then
compare. The two must agree, and the comparison is the point: host/seccomp_policy.py
claims to reinstate flatpak's blocklist minus the namespace group, and that
claim is about flatpak's source as it was when the file was written.

Refusing something flatpak allows is a real bug -- a Codex command would fail
for a reason nobody can find. Allowing something flatpak refuses widens the
sandbox silently. Neither is visible by reading.

Arguments are chosen to be inert: every call here either fails on its
arguments or fails on permissions, and none of them change anything.

  --filtered   install the broker's filter first (host side)
"""
import ctypes
import os
import sys

libc = ctypes.CDLL(None, use_errno=True)

# (name, syscall number, arguments). A blocked call returns EPERM from seccomp;
# an allowed one gets as far as the kernel and fails on its arguments instead,
# which is what makes the two distinguishable.
# Written from flatpak's own blocklists, not from host/seccomp_policy.py. A list
# derived from ours could only confirm itself, and the direction that matters --
# flatpak refuses it and we do not -- would never show up.
#
# The namespace group is left out because it is the documented difference:
# host/test-broker.py asserts those stay allowed.
PROBES = [
    ("syslog", 103, (9, None, 0)),            # SYSLOG_ACTION_SIZE_UNREAD
    ("uselib", 134, (0,)),
    ("modify_ldt", 154, (0, 0, 0)),           # func 0 = read, harmless
    ("acct", 163, (0,)),                      # NULL disables accounting
    ("quotactl", 179, (0, 0, 0, 0)),
    ("add_key", 248, (0, 0, 0, 0, 0)),
    ("request_key", 249, (0, 0, 0, 0)),
    ("keyctl", 250, (0, 0, 0, 0, 0)),
    ("mbind", 237, (0, 0, 0, 0, 0, 0)),
    ("set_mempolicy", 238, (0, 0, 0)),
    ("get_mempolicy", 239, (0, 0, 0, 0, 0)),
    ("migrate_pages", 256, (0, 0, 0, 0)),
    ("move_pages", 279, (0, 0, 0, 0, 0, 0)),
    ("ptrace", 101, (2, 0, 0, 0)),            # PTRACE_PEEKTEXT on pid 0
    ("personality", 135, (0xFFFFFFFF,)),      # query, does not change anything
    ("perf_event_open", 298, (0, 0, 0, 0, 0)),
]

# ioctl is filtered by request rather than refused, so it needs its own probes.
# Both are CVE fixes flatpak carries. Sent on a closed descriptor so nothing
# happens even where the request is permitted: an allowed one answers EBADF,
# a filtered one answers EPERM before the descriptor is ever looked at.
SYS_ioctl = 16
IOCTL_PROBES = [
    ("ioctl TIOCSTI", 0x5412),
    ("ioctl TIOCLINUX", 0x541C),
    # A control: this one must stay reachable, or we have broken ioctl wholesale.
    ("ioctl TCGETS", 0x5401),
]

# The socket-family rule, which is an argument check rather than a flat block.
FAMILIES = [("AF_UNIX", 1), ("AF_INET", 2), ("AF_NETLINK", 16),
            ("AF_PACKET", 17), ("AF_BLUETOOTH", 31)]
SYS_socket = 41


def call(nr, args):
    ctypes.set_errno(0)
    rc = libc.syscall(ctypes.c_long(nr), *[ctypes.c_long(a or 0) for a in args])
    return rc, ctypes.get_errno()


def main():
    if "--filtered" in sys.argv:
        sys.path.insert(0, os.path.join(
            os.path.dirname(os.path.realpath(__file__))))
        import seccomp_policy
        seccomp_policy.install()

    for name, nr, args in PROBES:
        _, err = call(nr, args)
        print(f"{name}\t{errno_name(err)}")

    for name, family in FAMILIES:
        _, err = call(SYS_socket, (family, 1, 0))
        print(f"socket({name})\t{errno_name(err)}")

    # 1023 is chosen to be closed: EBADF means the request reached the kernel,
    # EPERM means the filter stopped it first.
    for name, request in IOCTL_PROBES:
        _, err = call(SYS_ioctl, (1023, request, 0))
        print(f"{name}\t{errno_name(err)}")


def errno_name(err):
    if err == 0:
        return "OK"
    # ESOCKTNOSUPPORT from a socket probe means the call reached the kernel and
    # was refused on the socket type, so the family itself was allowed through.
    return {1: "EPERM", 13: "EACCES", 14: "EFAULT", 22: "EINVAL", 3: "ESRCH",
            97: "EAFNOSUPPORT", 94: "ESOCKTNOSUPPORT", 93: "EPROTONOSUPPORT",
            38: "ENOSYS", 9: "EBADF"}.get(err, f"errno {err}")


if __name__ == "__main__":
    main()
