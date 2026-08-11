# Sandboxing

No access to the home directory is granted. The app gets `--persist=.codex`,
which gives it a private `~/.codex` for config, skills, plugins and its
session databases, stored on the host at
`~/.var/app/com.openai.ChatGPT/.codex`. That state is **not** shared with a
host-installed `codex` CLI — the two keep separate configuration and
history. Files reach the app through the file-chooser portal.

## Codex's own sandbox

Codex isolates every command it runs with **bubblewrap**, which needs
unprivileged user namespaces — and Flatpak denies those unconditionally.
`unshare`, `setns`, `mount`, `pivot_root` and `clone(CLONE_NEWUSER)` are all
in flatpak's `syscall_blocklist[]`, not the `nondevel` one, so `--allow=devel`
does not lift them either. Left alone, every sandboxed command fails.

`/app/bin/bwrap` is a shim that takes bubblewrap's place on `PATH` (Codex
looks there before falling back to its bundled copy) and re-expresses the
request as `flatpak-spawn --sandbox`, which the portal runs outside our
seccomp filter. Isolation is preserved rather than disabled.

This needs **no extra permission**. `--sandbox` goes through the portal and
can only drop privileges; `--host` would need
`--talk-name=org.freedesktop.Flatpak` and is a full sandbox escape, which is
why it is not used. Untranslatable flags are refused outright rather than
silently dropped.

The refusal reaches stderr, which Codex swallows when a command fails, so
there is a log for the sessions that need explaining — off by default,
because every command Codex runs passes through the shim and the file has
no rotation:

```bash
flatpak override --user --env=BWRAP_LOG=1 com.openai.ChatGPT
```

Each invocation then appends its original argv, the translated
`flatpak-spawn` arguments and the rewritten command to
`~/.var/app/com.openai.ChatGPT/cache/chatgpt-flatpak/bwrap.log`. With it on,
an empty log is itself an answer: it means Codex never reached the shim,
which points at `PATH` rather than at the translation.

The two models differ in shape, so the translation is not literal. Codex is
*subtractive* — bind the whole root read-only, then carve out writable spots
and mask directories with an empty tmpfs. The portal is *additive* — start
from the runtime with nothing of the host, then expose paths one at a time.
The mapping that follows from that:

| Codex | Shim |
| --- | --- |
| `--bind X X` / `--ro-bind X X` | `--sandbox-expose-path[-ro]=X` |
| `--perms 555 --tmpfs X --remount-ro X` (mask) | `--sandbox-expose-path-ro=X` |
| `--ro-bind / /` | dropped; the child gets the runtime root |
| `--bind /tmp /tmp` and `/tmp` masks | dropped; the child has its own tmpfs |
| `--argv0 NAME` | replayed with `exec -a` |

Two things to know about that table. A nested read-only exposure does
override a writable parent, so masking still prevents writes — the agent
cannot plant a `.git/hooks/pre-commit` that would later run outside the
sandbox. What it no longer does is *hide* the directory: masked paths are
readable where Codex made them disappear.

And `/tmp` cannot be exposed at all — it is a per-instance tmpfs, so the
child always gets a fresh private one. Codex has to be told to stop asking
for the shared one, or it keeps declaring a policy the sandbox does not
implement. The launcher writes this into `~/.codex/config.toml` on start if
neither key is set:

```toml
[sandbox_workspace_write]
exclude_slash_tmp = true
exclude_tmpdir_env_var = true
```

It only ever adds. An existing value of either key is left alone — including
an explicit `false` — and any other settings in the file are preserved.

Flatpak also maps some directories to paths that do not exist on the host —
`/var/data`, and `$HOME/.codex` under `--persist`. The portal resolves
exposures against the real `~/.var/app/<id>/…` location, so the shim exposes
them there and rewrites the same paths throughout the command it hands over.
One pass fixes the binary's own path, the paths inside
`--permission-profile`, and the ones embedded in the shell script Codex
hands to `sh -c`.

The shim also exposes `~/.codex/shell_snapshots` read-only. Codex's
generated script sources the session snapshot from there, and `sh` is bash
in POSIX mode, where a failed `.` is a special-builtin error that kills the
shell outright -- inside the `if` the script wraps it in, and with the error
redirected to `/dev/null`. A missing snapshot therefore exits 1 with no
output at all.

## What the child can actually reach

Measured, not assumed:

| | Result |
| --- | --- |
| path with no exposure | not present at all -- `/mnt` lists empty |
| `--sandbox-expose-path-ro` | readable, writes refused |
| `--sandbox-expose-path` | writable, and the writes persist |
| a nested `-ro` inside a writable exposure | writes refused (this is what makes masking work) |
| `/etc`, `/var`, `/run`, `/home`, `/mnt`, `/tmp` | writable, but **discarded** when the command exits |

Only an explicitly exposed path persists to the host. Everything else the
child can write belongs to its own throwaway root, including the parent
directory of an exposed workspace.

That last row is a fidelity gap rather than a leak, and it cannot be closed:
`--sandbox-expose-path-ro=/etc` is a no-op, because exposures resolve
against the caller's instance tree and hand over open file descriptors --
they can add paths to the child, never change the mounts it gets from the
runtime. So a command that writes `/etc/something` and checks only the exit
status believes it succeeded, where Codex's own bwrap policy would have
returned `Permission denied`. Nothing reaches the host either way.

Each command starts a fresh Flatpak instance, costing a few hundred
milliseconds, and the child has no session bus (flatpak disables it for
`--sandbox`), so commands needing D-Bus will not work.

That table is also the part CI cannot check. Reaching the portal needs a
session bus, and the build container has none — `flatpak-spawn` gets as far
as `Cannot spawn a message bus without a machine-id` and stops. So
`test-bwrap-shim.sh` asserts the *translation* instead: it runs the
installed shim with `BWRAP_LOG=1` and compares the line logged just before
the spawn against the expected arguments. That reaches most of the parser
in its real environment, but stops at the portal's door — and the flags
carrying a file descriptor stay out of reach too, since `flatpak run` has
nowhere to hand one in. Whether the child is actually confined has to be
re-measured on a desktop after any change to the translation:

```bash
flatpak run --command=bwrap com.openai.ChatGPT --unshare-user --unshare-net --ro-bind / / --chdir / -- /bin/sh -c 'echo ok; ls /mnt'
```

which must print `ok` and fail to list `/mnt`.

The practical limit is reach, not tooling. The runtime is the freedesktop
**Sdk**, so `git`, `gcc`, `make` and `python3` are present, and `node`/`npx`
come from the node24 extension — but the agent can only see the sandbox, not
your checkouts. The portal can only expose paths **this app already has**, so
the shim cannot hand Codex a directory the Flatpak itself cannot reach. Grant
one explicitly if you want the agent to work on it:

```bash
flatpak override --user --filesystem=~/src com.openai.ChatGPT
```

Otherwise the host `codex` CLI remains the right tool for local work.
