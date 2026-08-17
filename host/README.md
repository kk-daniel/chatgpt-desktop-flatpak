# flatpak-bwrap-broker

Runs bubblewrap on behalf of a confined flatpak, inside that flatpak's own
namespaces. Packaged separately from the flatpak on purpose: the flatpak cannot
install or update a host service, and should not be able to.

```bash
bash host/install.sh com.openai.ChatGPT
```

Installs into `~/.local/libexec/flatpak-bwrap-broker` and
`~/.config/systemd/user`, then enables the socket. No root, and nothing outside
`$HOME` — the broker needs no privilege beyond the ownership of the namespaces
flatpak already created for this user.

```bash
systemctl --user status flatpak-bwrap-broker@com.openai.ChatGPT.socket
journalctl --user -u flatpak-bwrap-broker@com.openai.ChatGPT.service -f
```

Requires Linux 6.5 or newer for `SO_PEERPIDFD`, systemd's user session, and
**x86_64**. The seccomp policy enforces x86_64 syscall numbers, which mean
different calls on another architecture, so the broker refuses to serve anything
else rather than letting commands die of SIGSYS. The manifest does carry aarch64
sources; on such a build the sandbox will not work until a second syscall table
is added and checked with `host/test-seccomp-parity.sh` **on that architecture**.

**Re-run `install.sh` after every change to the broker.** A flatpak update
replaces the client inside the app but cannot touch a host service, so the two
drift apart. They will not fail silently — the protocol carries a version and a
mismatch is refused with a message naming both sides — but nothing updates the
broker for you.

## Why it exists

Flatpak refuses unprivileged user namespaces to every app it starts. `unshare`,
`setns`, `mount`, `pivot_root` and `clone(CLONE_NEWUSER)` are in its
unconditional seccomp blocklist, and `--allow=devel` does not lift them. That
was measured rather than read off the source: plain, `--allow=devel` and
`--allow=devel --allow=multiarch` all refuse `unshare`, and the app's seccomp
filter is byte-identical with and without `devel`. Codex isolates every command
it runs with bubblewrap, so without a broker every sandboxed command fails.

## How it gets in

Not by rebuilding the app's sandbox. It steps into the real one.

Flatpak runs bwrap with `--disable-userns`, which makes bwrap create user
namespace **A**, set up the mounts there, then nest the app in a second
namespace **B**. `cap_capable()` gives the owner of a user namespace, seen from
that namespace's *parent*, every capability in it — and A was created by this
uid from the initial namespace. So the broker holds `CAP_SYS_ADMIN` in A, may
`setns()` into it, and from there may join the mount namespace A owns.

Joining B instead is useless: capabilities do not flow from a child namespace up
to its parent, which is why the mount namespace refuses. That is the whole
trick, and `host/diagnose-namespaces.sh` is where it was found.

```
Codex -> /app/bin/bwrap (argv passthrough) -> SOCK_SEQPACKET
      -> broker: SO_PEERPIDFD -> mnt ns -> NS_GET_USERNS -> A
      -> setns(A, pid, mnt)   [all namespace fds opened first]
      -> raise max_user_namespaces in A
      -> unshare(CLONE_NEWUSER) mapping 0 -> the app's uid, drop capabilities
      -> install the seccomp policy
      -> exec /app/libexec/flatpak-bwrap-broker/bwrap, argv unchanged
```

Because the command runs in flatpak's actual mount namespace, its filesystem
view is the app's by construction rather than by reconstruction. There is no
path translation, no fidelity gap, and nothing to keep in sync when flatpak
changes how it mounts things.

## What it costs

Two things, and both are consequences of the goal rather than oversights.

**The namespace syscalls.** Commands cannot run under flatpak's seccomp filter,
because that filter is precisely what stops bubblewrap. Everything else in
flatpak's policy is reinstated by `seccomp_policy.py` immediately before exec —
the keyring, `ptrace`, `perf_event_open`, the NUMA calls, `modify_ldt`, the
non-IP socket families, and the terminal `ioctl` requests behind CVE-2017-5226
and CVE-2023-28100. What is actually given up is `clone`, `unshare`, `setns`,
`mount`, `umount2`, `pivot_root`, `chroot` and `clone3`. Any code inside the app
can reach the socket, so the app's effective syscall surface becomes its own
plus that group.

`seccomp_policy.py` keeps flatpak's blocklist as a table of its own, not derived
from the broker's, so the comparison is a comparison: `test-broker.py` asserts
the filter refuses all of it and `test-seccomp-parity.sh` asserts the app does
too. A list computed from our own could only ever confirm itself.

**`max_user_namespaces`.** `--disable-userns` works by exhausting the quota in
A, and the inner bwrap needs two namespaces. The broker raises it and does not
restore it — restoring would break concurrent commands, and it protects nothing,
since the app's own `unshare` is refused by the seccomp filter whatever the
limit says.

## Authorisation

Every decision comes from the kernel, never from the client:

* `SO_PEERPIDFD` pins the calling process, so a pid cannot be reused between
  the credential check and the namespace entry;
* the app id is read from the caller's own `/.flatpak-info`, through a
  `/proc/<pid>` directory descriptor opened once, so a caller that exits makes
  later opens fail rather than silently name a new process;
* the identity must match the systemd instance name — one broker serves one
  app;
* the mount namespace's owning user namespace must be owned by this uid;
* the caller is checked to be alive again after setup and before entry;
* the path to the real bubblewrap is the broker's, not the client's.

## Sandboxes do not nest

A command the broker has already sandboxed can see the socket, and is refused.
The user namespace owning the app's mount namespace is created by flatpak's
bwrap directly from the broker's own, so its parent is the broker's; anything
created inside a sandbox is at least one level deeper and fails that test.

The reason is seccomp. The broker joins the caller's namespaces, so a nested
request's *filesystem* view would be correctly nested — but the new process is
forked from the broker, and seccomp filters are inherited only from a parent.
A command confined by Codex's filter would come out from under it. Since the
broker cannot carry that filter across, it refuses instead.

In practice the caller's own filter usually blocks `connect()` before the
request is even sent, which is why this shows up as `Operation not permitted`
rather than a message from the broker. The client recognises that errno and
explains it.

Argv, environment and paths are never logged: they are the contents of prompts
and files. `BROKER_DEBUG=1` relaxes that and says so in the journal when it
does.

## Adding another app

```bash
systemctl --user enable --now flatpak-bwrap-broker@some.other.App.socket
```

The app needs `/app/bin/bwrap` (the client) and a bubblewrap built for its
runtime at `/app/libexec/flatpak-bwrap-broker/bwrap`. Nothing else in the broker
is specific to ChatGPT.

## Tests

```bash
python3 host/test-broker.py       # no app or broker needed
bash host/test-broker-live.sh     # against an installed flatpak
```

The first checks the seccomp program by interpreting it — a miscomputed BPF jump
offset fails *open*, which reading cannot reliably catch — plus the wire
protocol and the descriptor scan.

The second is the one that matters. Every bug found while building this was in
the namespace entry, which no unit test can reach: the network namespace was not
joined at all, setup failures vanished into the journal, and an off-by-one in
the argv convention silently dropped the first bwrap flag so that sandboxes ran
with one less restriction than asked for and still reported success. So the live
script asserts the properties directly — the command's uid and capabilities,
read-only mounts that really refuse writes, pid and network isolation,
descriptor-passing flags, exit status, twelve sequential and eight concurrent
sandboxes, that nesting is refused with an explanation, and that a missing
broker fails loudly instead of falling back.

Both run in CI, because the broker needs no session bus. That is a change from
the portal implementation this replaced, which could not be tested there at all.

```bash
bash host/test-seccomp-parity.sh    # the policy against the app's own filter
bash host/diagnose-namespaces.sh    # the namespace chain this depends on
```

`test-seccomp-parity.sh` is what keeps `seccomp_policy.py` honest; the live
suite calls it too. `diagnose-namespaces.sh` prints the user-namespace chain and
the ownership of the mount namespace — run it after a flatpak or kernel update,
or whenever the broker starts refusing with something about the namespace
chain, since that means the topology described above has moved.
