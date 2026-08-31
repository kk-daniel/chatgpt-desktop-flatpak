# Sandboxing

No access to the home directory is granted. The app gets `--persist=.codex`,
which gives it a private `~/.codex` for config, skills, plugins and its
session databases, stored on the host at
`~/.var/app/com.openai.ChatGPT/.codex`. That state is **not** shared with a
host-installed `codex` CLI — the two keep separate configuration and
history. Files reach the app through the file-chooser portal.

`--talk-name=org.freedesktop.secrets` is not granted, so Electron's
`safeStorage` cannot reach the login keyring and falls back to a key built into
Chromium, with the token under `~/.var/app/com.openai.ChatGPT`. The reason is
that the Secret Service specification does not require per-application
isolation, and the usual implementations do not provide it — an app that can
talk to the service can read every unlocked secret of every other application.
The token is therefore about as protected as any file in your home directory,
which is where it already lived, and nothing else on the system is exposed to
this app. README.md has the override for anyone who prefers the keyring.

## Codex's own sandbox

Codex isolates every command it runs with **bubblewrap**, which needs
unprivileged user namespaces — and Flatpak denies those unconditionally.
`unshare`, `setns`, `mount`, `pivot_root` and `clone(CLONE_NEWUSER)` are all
in flatpak's `syscall_blocklist[]`, not the `nondevel` one, so `--allow=devel`
does not lift them either. Left alone, every sandboxed command fails.

Measured rather than assumed:

```
plain                     unshare: Operation not permitted
--allow=devel             unshare: Operation not permitted
--allow=devel+multiarch   unshare: Operation not permitted
```

The app's seccomp filter is byte-identical with and without `devel`, so there is
no flatpak option that makes bubblewrap work from inside.

## The broker

`/app/bin/bwrap` takes bubblewrap's place on `PATH` — Codex looks there before
falling back to its own copy — and hands the request to a small service running
on the host. That service steps into this sandbox's **own** namespaces and runs
the real bubblewrap there, with the arguments Codex wrote, unchanged.

```
Codex -> /app/bin/bwrap -> SOCK_SEQPACKET in $XDG_RUNTIME_DIR/app/<id>/
      -> flatpak-bwrap-broker on the host
      -> setns into this sandbox's user, pid, net, ipc, uts and mount namespaces
      -> /app/libexec/flatpak-bwrap-broker/bwrap
      -> Codex's command
```

All of them, not only the mount namespace. The network one matters
independently: an app without `--share=network` gets its own, and a command
left in the broker's would have host network — an escape that would not show up
on this app, which has `--share=network` anyway.

It is installed separately, because a flatpak cannot install a host service and
should not be able to:

```bash
"$(flatpak info com.openai.ChatGPT -l)/files/extra/chatgpt/sandbox-host/install.sh"
```

Without it, sandboxed commands fail with a message naming what to run — both
the packaged `install.sh` and `systemctl --user enable`, because from inside the
sandbox a missing socket cannot be told apart from a stopped service. There is
deliberately no fallback to `flatpak-spawn --host` or to running unsandboxed: a
missing broker means less isolation than Codex asked for, and that is a thing to
report, not to work around.

That message is also written to
`~/.var/app/com.openai.ChatGPT/cache/chatgpt-flatpak/bwrap-error.log`, which is
`/var/cache/chatgpt-flatpak/bwrap-error.log` from inside. It has to be, because
Codex swallows a command's stderr when the command fails, and a broker that is
not running has no journal to write to either — so the case where the message
matters most is the one where it would otherwise vanish. The file holds only the
most recent failure, so it cannot grow while Codex retries.

### How it can step in without root

Flatpak runs bwrap with `--disable-userns`, which makes bwrap create user
namespace **A**, set up the mounts there, and then nest the app in a second
namespace **B**. `cap_capable()` grants the owner of a user namespace, seen from
that namespace's parent, every capability in it. A was created by this uid from
the initial namespace, so the broker — an ordinary process of the same user —
holds `CAP_SYS_ADMIN` in A and may `setns()` into it, and from there into the
mount namespace A owns.

Joining B, the app's own namespace, is not enough and looks like a permissions
bug until the topology is visible: capabilities do not flow from a child
namespace up to its parent, so a process in B has none in A, and the mount
namespace refuses. `host/diagnose-namespaces.sh` prints the chain.

### Why the mounts are not copied

An earlier design built an outer bwrap around a clone of `/proc/<pid>/root`.
It cannot work, and the reasons are worth recording because both failures look
like something fixable.

`bwrap --bind /proc/<pid>/root /` fails with `Permission denied` even though a
plain shell can read that path. bwrap resolves its source paths *after*
unsharing its own user namespace, and the app's `mm` is not dumpable, so access
needs capabilities in the namespace the `mm` belongs to. From the initial
namespace this uid has them; from bwrap's sibling namespace it does not.

`--bind-fd` is worse. bwrap resolves the descriptor back to a path — and
`readlink /proc/<pid>/root` is `/` — so it bind-mounted the **host** root and
then caught the mismatch in its own sanity check — the host root is mode 0555
and the descriptor it was handed was mode 0755. That check is the only thing
that stopped it.

Stepping into the real mount namespace avoids the question entirely. The
filesystem the command sees is flatpak's because it *is* flatpak's: same
namespace, not a reconstruction of one. Nothing here has to track how flatpak
mounts things.

### What this costs

Two things, both consequences of the goal rather than oversights.

**The namespace syscalls.** Commands do not run under flatpak's seccomp filter,
because that filter is exactly what stops bubblewrap. Most of the policy is put
back by the broker immediately before exec — the kernel keyring, `ptrace`,
`perf_event_open`, the NUMA calls, `modify_ldt`, the non-IP socket families, and
the two terminal `ioctl` requests behind CVE-2017-5226 and CVE-2023-28100 —
and seccomp filters survive `execve` and namespace creation, so one filter
covers bubblewrap, Codex's helper and the command. What is actually given up is
the namespace group: `clone`, `unshare`, `setns`, `mount`, `umount2`,
`pivot_root`, `chroot`, `clone3`.

That list is a claim about flatpak's source, so it is checked rather than
trusted, in both directions. `host/seccomp_policy.py` carries flatpak's
blocklist as a separate table that is deliberately not derived from the
broker's own; `host/test-broker.py` asserts the filter refuses all of it, and
`host/test-seccomp-parity.sh` asserts the running app refuses all of it too.
Refusing something flatpak allows would break a Codex command for no visible
reason, and allowing something flatpak refuses would widen the sandbox
silently — neither is apparent by reading.

Any code inside the app can reach the broker's socket, so the app's effective
syscall surface becomes its own plus that group. That is the honest statement
of what installing the broker changes, and it is why it is opt-in and separately
installed. The filesystem view and the network are unchanged, because they come
from the same namespaces the app already has.

**`max_user_namespaces`.** `--disable-userns` works by exhausting the quota in
A, and the inner bwrap needs two namespaces. The broker raises it and leaves it
raised. Restoring it would break commands running concurrently, and it protects
nothing: the app's own `unshare` is refused by the seccomp filter whatever the
limit says.

### Sandboxes do not nest

A command Codex has already sandboxed can see the broker's socket. It is
refused, and the refusal is deliberate rather than incidental.

The broker joins the *caller's* namespaces, so a nested request's filesystem
view would be correctly nested — a command restricted to a read-only workspace
could not ask for a writable one. What it could shed is seccomp. The broker's
child is forked from the broker, and a seccomp filter is inherited only from a
parent, so Codex's own filter would not come along. A command confined by it
would end up less confined than the one that asked, which is backwards.

The broker therefore checks the shape of the namespace chain: the user
namespace owning the app's mount namespace is created by flatpak's bwrap
directly from the broker's own, so its parent is the broker's, and anything
created inside a sandbox is at least one level deeper.

Usually the caller's own filter refuses `connect()` first, so this appears as
`Operation not permitted` from the client rather than a message from the
broker. The client recognises that errno and says what it means.

### The uid, which is easy to get wrong

The broker arrives in A as uid 0 with a full capability set, and bubblewrap
passes that straight to the command — measured, `child uid=0 CapEff
000001ffffffffff`, which is a great deal more than Codex asked for. So before
exec the broker creates one more user namespace **C** mapping that 0 back to the
app's own uid, and sets `no_new_privs`. Doing it there rather than by adding
`--uid` to the command line is what lets Codex's arguments reach bubblewrap
literally unmodified.

C is where the boundary is, not the capability set. Capabilities held in C are
not capabilities in A or on the host, and mounting in the app's own mount
namespace stays refused whatever is held, because `may_mount()` asks for
`CAP_SYS_ADMIN` in the namespace that *owns* that mount namespace — A — where a
process in C has none. bubblewrap therefore has to unshare its own mount
namespace under C, which is what it does.

The capabilities are dropped in C as well at any normal uid, which is defence in
depth and not the load-bearing control. The exception is an app running as
root: bubblewrap then reads euid 0 as privileged and takes a path needing
`CAP_SYS_ADMIN` to unshare its mount namespace and `CAP_SETUID` to write its id
maps, so dropping them leaves it unable to build a sandbox at all. They are kept
in that case, scoped to C, and bubblewrap drops privileges for the command
either way — which `host/test-broker-live.sh` checks by reading the command's
`CapEff`.

## What disappeared with the portal

The previous implementation re-expressed each call as `flatpak-spawn --sandbox`.
The portal is *additive* — start from the runtime with nothing of the host and
expose paths one at a time — where Codex is *subtractive*, so the two never
matched, and a translation table stood between them. All of it is gone:

* **Path rewriting.** Flatpak maps `/var/data`, `/var/config`, `/var/cache`,
  `/var/tmp` and `$HOME/.codex` into private per-app storage, and the portal
  only accepted the host spelling. Inside the app's own mount namespace the
  guest spelling is the real one.
* **`--tmpfs` refusals.** The portal could not mount a tmpfs at an arbitrary
  destination, so masks were refused outright. Real bubblewrap does them.
* **`/tmp`.** The portal always gave the child a fresh private tmpfs, so the
  launcher wrote `exclude_slash_tmp` and `exclude_tmpdir_env_var` into
  `config.toml`. No longer needed; an existing setting from an older install is
  harmless and is left alone.
* **Dropping `codex-linux-sandbox`.** Codex's helper re-execs through file
  descriptors the portal did not carry, which surfaced as `--bind-fd: Not an
  open file descriptor: 15`. Descriptors cross the broker's socket over
  `SCM_RIGHTS` and are restored to their original numbers before exec, so the
  helper runs as Codex intended and its seccomp filter is applied.
* **The fidelity gap.** Under the portal, `/etc`, `/var`, `/run`, `/home` and
  `/tmp` were writable but discarded, so a command that wrote there and checked
  only the exit status believed it had succeeded. The mounts are flatpak's now,
  so a write that should fail does.

## What can be tested where

Both layers run in CI, and that is new. The portal implementation could not be
tested there at all — reaching the portal needs a session bus and the build
container has none, so `flatpak-spawn` got as far as `Cannot spawn a message bus
without a machine-id` and everything about what a sandboxed command could reach
was left to manual desktop runs. The broker talks over a unix socket and needs
no bus, and binds its own socket when systemd is not there, so the real
properties are now asserted on every build.

`python3 host/test-broker.py` needs neither an app nor a broker. It interprets
the seccomp program rather than reading it, because a miscomputed BPF jump offset
fails *open*; it round-trips the wire protocol between the client's encoder and
the broker's decoder, including non-UTF-8 arguments; and it checks the argument
walk that decides which descriptors are forwarded.

`bash host/test-broker-live.sh` runs against an installed flatpak with a live
broker, and it is the one that earns trust. Every bug found while building this
was in the namespace entry, where unit tests cannot go:

* the network namespace was not joined, so a command would have had host network
  on any app without `--share=network`;
* setup failures were written to the journal by a child with no connection to
  the client, so a broken sandbox looked like empty output;
* an off-by-one in the argv convention dropped the first bwrap flag, so
  sandboxes ran with one less restriction than Codex asked for **and reported
  success**.

That last one is the reason the live tests are required rather than
best-effort. It passed every unit test, and it passed a manual `apply_patch`
run too.

Two smaller scripts back specific claims made above.
`host/test-seccomp-parity.sh` compares the broker's policy against the app's own
filter in both directions, so the syscall list is not merely a claim about
flatpak's source; the live suite runs it too.
`host/diagnose-namespaces.sh` prints the user-namespace chain and the ownership
of the mount namespace. Run it after a flatpak or kernel update, or whenever the
broker refuses with something about the namespace chain: that means the topology
this whole approach rests on has moved.

## Reach

The runtime is the freedesktop **Sdk**, so `git`, `gcc`, `make` and `python3`
are present, and `node`/`npx` come from the node24 extension — but the agent can
only see the sandbox, not your checkouts. The broker runs commands inside the
app's mount namespace, so it cannot show Codex a directory the flatpak itself
cannot reach. Grant one explicitly if you want the agent to work on it:

```bash
flatpak override --user --filesystem=~/src com.openai.ChatGPT
```

Otherwise the host `codex` CLI remains the right tool for local work.

### Adding toolchains

What the runtime ships is not the limit. Two kinds of Flatpak extension can be
mounted into the sandbox, and neither requires rebuilding the app.

**Tool extensions** are the ones built for VS Code. The manifest declares the
`com.visualstudio.code.tool` extension point, deliberately borrowing that ID
prefix so the extensions already published on Flathub install here unmodified.
Installing one is all there is to it — it unpacks to `/app/tools/<name>` and the
launcher puts its `bin` on PATH and its Python user-site directory, when present,
on `PYTHONPATH`:

```bash
flatpak install flathub com.visualstudio.code.tool.podman//25.08
```

The `//25.08` is not optional. An extension is only mounted when its branch
matches the `version:` pinned in the manifest, and a mismatched one installs
cleanly and then does nothing. `podman`, `fish` and `git-lfs` are what Flathub
currently has.

**SDK extensions** are the language toolchains — `golang`, `dotnet`, `llvm`,
`php`, `rust-stable` and the rest. The runtime here is `org.freedesktop.Sdk`, so
its own extension point mounts any installed one at `/usr/lib/sdk/<name>`
already; the missing half is putting it on PATH, which is opt-in per launch
through `FLATPAK_ENABLE_SDK_EXT`:

```bash
flatpak install flathub org.freedesktop.Sdk.Extension.golang//25.08
```

```bash
flatpak run --env=FLATPAK_ENABLE_SDK_EXT=golang com.openai.ChatGPT
```

The variable takes short names — `golang`, not
`org.freedesktop.Sdk.Extension.golang` — comma-separated for several, or `*` for
everything installed. The launcher prefers the extension's own `enable.sh`, which
sets up `GOROOT` and friends rather than just PATH, and says on stderr which
extensions it enabled and which were asked for but not installed. To stop passing
it every time:

```bash
flatpak override --user --env=FLATPAK_ENABLE_SDK_EXT=golang com.openai.ChatGPT
```

Leaving it unset enables nothing, which is the intended default: these are
toolchains the agent can then run, so they should be present because someone
asked for them.

Neither mechanism covers `node` — the node24 extension is auto-installed and
symlinked into `/app/bin`, so `node`, `npm` and `npx` work out of the box and MCP
servers launched as `npx -y …` resolve without any of this.

One trap when checking your work: `flatpak run --command=…` bypasses the
launcher entirely, so nothing it exports is visible there.
`flatpak run --command=ls com.openai.ChatGPT /usr/lib/sdk` proves the extension
is *mounted*, but it will never show the PATH wiring. For that, look at the
launcher's stderr, or at `PATH=` in
`~/.var/app/com.openai.ChatGPT/cache/chatgpt-flatpak/launcher.log`.
