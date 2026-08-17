#!/usr/bin/env python3
"""Drop to a uid and exec a command.

Exists because the flatpak-builder CI image has neither shadow-utils nor
setpriv, so there is no shell tool there that can do this -- and the live
sandbox tests must not run as root, since the broker refuses to serve an app
running as root and bubblewrap would hand the command its capabilities.

python3 is a safe thing to depend on: the same job already runs the unit tests
with it, and the broker itself is written in it.

    python3 host/run-as-uid.py 1001 bash host/test-broker-live.sh

The environment is inherited, so HOME, XDG_RUNTIME_DIR and the rest are set by
the caller. Supplementary groups are cleared first, which has to happen before
the uid changes or the privilege to do it is already gone.
"""
import os
import sys

if len(sys.argv) < 3:
    sys.exit(f"usage: {sys.argv[0]} UID COMMAND [ARGS...]")

uid = int(sys.argv[1])
try:
    os.setgroups([])
    os.setgid(uid)
    os.setuid(uid)
except PermissionError:
    sys.exit(f"cannot drop to uid {uid}: this must be run as root "
             f"(currently uid {os.getuid()})")

if os.getuid() != uid or os.geteuid() != uid:
    sys.exit(f"failed to drop to uid {uid}")

os.execvp(sys.argv[2], sys.argv[2:])
