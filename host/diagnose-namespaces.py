#!/usr/bin/env python3
"""Print the namespace topology the broker depends on, and try to enter it.

Run this when the broker starts refusing with something about the namespace
chain, or after a flatpak or kernel update. It reports what the broker looks for
and where it would stop, which is otherwise invisible: a single EPERM from
setns() with nothing to say which namespace refused or why.

The rest of this comment is the reasoning it was written to establish, kept
because the failure it describes is the one that will come back if flatpak
changes how it nests namespaces.

Joining the app's own user namespace succeeds while the mount namespace refuses,
and that pairing is the signature of flatpak running
bwrap with --disable-userns: bwrap creates user namespace A, does the mounts
there, then nests the app in a second user namespace B. mntns_install() wants
CAP_SYS_ADMIN in the namespace that *owns* the mount namespace -- A -- and
capabilities do not flow from a child namespace up to its parent.

So: map the topology, then aim setns() at the owner of the mount namespace
rather than at the app's own user namespace.

The second thing this measures is whether the attempt is worth anything even
if it succeeds. --disable-userns works by exhausting max_user_namespaces, and
if that limit is spent then the inner bwrap cannot create the user namespace it
needs no matter where we stand.

Raising that limit would weaken the confinement of the app that is running
right now, so it is only attempted when BROKER_RAISE_LIMIT=1 is set.
"""
import ctypes
import os
import sys

CLONE_NEWNS = 0x00020000
CLONE_NEWUTS = 0x04000000
CLONE_NEWIPC = 0x08000000
CLONE_NEWUSER = 0x10000000
CLONE_NEWPID = 0x20000000

NS_GET_USERNS = 0xB701
NS_GET_PARENT = 0xB702
NS_GET_OWNER_UID = 0xB704

SYS_setns = 308

libc = ctypes.CDLL(None, use_errno=True)


def syscall(nr, *args):
    rc = libc.syscall(ctypes.c_long(nr), *[ctypes.c_long(a) for a in args])
    if rc < 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err))
    return rc


def ioctl_fd(fd, req):
    rc = libc.ioctl(fd, ctypes.c_ulong(req))
    if rc < 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err))
    return rc


def owner_uid(fd):
    uid = ctypes.c_uint()
    if libc.ioctl(fd, ctypes.c_ulong(NS_GET_OWNER_UID), ctypes.byref(uid)) < 0:
        return None
    return uid.value


def ino(fd):
    return os.fstat(fd).st_ino


def topology(pid):
    print("== namespace topology ==")
    me_user = os.open("/proc/self/ns/user", os.O_RDONLY)
    print(f"  broker userns          {ino(me_user)}")

    app_user = os.open(f"/proc/{pid}/ns/user", os.O_RDONLY)
    print(f"  app userns (B)         {ino(app_user)} owner uid {owner_uid(app_user)}")

    fd = app_user
    while True:
        try:
            parent = ioctl_fd(fd, NS_GET_PARENT)
        except OSError as e:
            print(f"  parent of {ino(fd)}: {e} (top of what we can see)")
            break
        print(f"  parent -> userns       {ino(parent)} owner uid {owner_uid(parent)}")
        if ino(parent) == ino(me_user):
            print("    ^ this is the broker's own namespace, chain complete")
            break
        fd = parent

    app_mnt = os.open(f"/proc/{pid}/ns/mnt", os.O_RDONLY)
    print(f"  app mnt ns             {ino(app_mnt)}")
    try:
        mnt_owner = ioctl_fd(app_mnt, NS_GET_USERNS)
        print(f"  mnt ns owned by userns {ino(mnt_owner)} owner uid {owner_uid(mnt_owner)}")
        if ino(mnt_owner) == ino(app_user):
            print("    ^ same as the app's own userns -- the --disable-userns theory is wrong")
        else:
            print("    ^ NOT the app's own userns: this is the namespace to join")
    except OSError as e:
        print(f"  NS_GET_USERNS failed: {e}")
        mnt_owner = None

    return app_user, app_mnt, mnt_owner


PROBE = r'''
echo "  uid=$(id -u) $(grep -s ^CapEff /proc/self/status)"
echo -n "  .flatpak-info: "; grep -s "^name=" /.flatpak-info || echo "ABSENT (not the app view)"
echo -n "  /usr writable: "; touch /usr/.probe 2>/dev/null && { rm -f /usr/.probe; echo "FAIL yes"; } || echo no
echo -n "  host /etc/fedora-release: "; test -e /etc/fedora-release && echo "FAIL visible" || echo "absent (PASS)"
echo -n "  max_user_namespaces: "; cat /proc/sys/user/max_user_namespaces 2>&1
echo -n "  unshare -m: "; unshare --mount true 2>&1 && echo OK || true
echo -n "  unshare -U: "; unshare --user --map-root-user true 2>&1 && echo "OK (inner bwrap is possible)" || true
if [ "${BROKER_RAISE_LIMIT:-}" = 1 ]; then
  echo -n "  raising max_user_namespaces: "
  if echo 100 > /proc/sys/user/max_user_namespaces 2>/dev/null; then
    echo "written, retrying"
    echo -n "  unshare -U after raise: "; unshare --user --map-root-user true 2>&1 && echo OK || true
  else
    echo "refused"
  fi
fi
'''


def join(pid, mnt_owner_fd, app_mnt_fd, with_pid):
    # Every descriptor first, in the same order the broker uses. Once the mount
    # namespace is joined, /proc is the app's own procfs, which belongs to the
    # app's pid namespace, and the host pid being chased does not exist there --
    # so opening ns/pid afterwards fails with ENOENT.
    pidns_fd = None
    if with_pid:
        try:
            pidns_fd = os.open(f"/proc/{pid}/ns/pid", os.O_RDONLY)
        except OSError as e:
            print(f"  cannot open the app's pid namespace: {e}")

    child = os.fork()
    if child:
        _, status = os.waitpid(child, 0)
        if pidns_fd is not None:
            os.close(pidns_fd)
        return status == 0

    try:
        syscall(SYS_setns, mnt_owner_fd, CLONE_NEWUSER)
        print("  setns -> owner userns: ok")
    except OSError as e:
        print(f"  setns -> owner userns: {e}")
        os._exit(1)

    if pidns_fd is not None:
        # Before the mount namespace, so /proc/self resolves afterwards.
        try:
            syscall(SYS_setns, pidns_fd, CLONE_NEWPID)
            print("  setns -> app pid ns:   ok")
        except OSError as e:
            print(f"  setns -> app pid ns:   {e} (/proc/self may not resolve)")

    try:
        syscall(SYS_setns, app_mnt_fd, CLONE_NEWNS)
        print("  setns -> app mnt ns:   ok")
    except OSError as e:
        print(f"  setns -> app mnt ns:   {e}")
        os._exit(1)

    grand = os.fork()
    if grand:
        _, status = os.waitpid(grand, 0)
        os._exit(0)
    os.execv("/bin/sh", ["/bin/sh", "-c", PROBE])


def main():
    pid = int(sys.argv[1])
    app_user, app_mnt, mnt_owner = topology(pid)

    print()
    print("== join the owner of the mount namespace ==")
    if mnt_owner is None:
        print("  skipped: could not find the owner")
        return
    join(pid, mnt_owner, app_mnt, with_pid=True)

    print()
    print("== for contrast: join the app's own userns which is what fails, and why ==")
    join(pid, app_user, app_mnt, with_pid=True)


if __name__ == "__main__":
    main()
