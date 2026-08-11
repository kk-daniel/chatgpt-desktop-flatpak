# Flatpak for ChatGPT Desktop

Unofficial Flatpak packaging for OpenAI's ChatGPT desktop app on Linux.

It repackages the official Store-signed Windows MSIX — the same one OpenAI
documents for enterprise deployment — around a stock Linux Electron, in the
spirit of [johnohhh1/chatgpt_desktop_ubuntu](https://github.com/johnohhh1/chatgpt_desktop_ubuntu),
which does the equivalent as a `.deb`.

## What is actually inside the package

Worth knowing before you build: the Windows "ChatGPT" package is now the
merged **ChatGPT + Codex** app. Its MSIX identity is `OpenAI.Codex`, the
Electron app is `openai-codex-electron`, and it registers the `codex:` URL
scheme. It ships a bundled Codex CLI, a plugin/skills tree, and a browser
automation runtime alongside the chat UI.

Two consequences:

- It runs on OpenAI's own Chromium fork ("owl", Chromium 151), which is not
  distributed for Linux. This package boots the app on upstream Electron
  42.3.0 (Chromium 148) instead — the version the app's own `package.json`
  is built against.
- Handily, the Windows package already contains **Linux ELF builds** of
  `codex`, `codex-code-mode-host` and `ripgrep` (they are what the Windows
  app runs under WSL). Those are kept; the Windows `.exe`/`.dll`/`.cmd`/`.ps1`
  copies are discarded during the first-launch unpack, which is most of
  ~290 MB.

The app's own Linux code paths are intact — no patching of `app.asar` is
needed, unlike the older Electron build the `.deb` script targets.

## Building and installing

```sh
flatpak remote-add --if-not-exists --user flathub https://dl.flathub.org/repo/flathub.flatpakrepo
```

```sh
flatpak-builder --force-clean --user --install-deps-from=flathub --repo=repo --install builddir com.openai.ChatGPT/com.openai.ChatGPT.yaml
```

```sh
flatpak run com.openai.ChatGPT
```

The Flatpak itself contains no OpenAI code. The ~700 MB package is fetched
from OpenAI on **first launch**, not at install time — see below.

## The parts that need work on Linux

Four things are wrong with the official payload on Linux:

**Native modules are Windows DLLs.** `better-sqlite3` and `node-pty` ship as
PE binaries. Left alone the app starts and then fails every session store
with *"SQLite database is inaccessible"*. The `native-modules` manifest
module compiles both against the pinned Electron headers at build time, and
`chatgpt-fetch` swaps them in when it unpacks.

The manifest pins `better-sqlite3` **12.11.1**, not the 12.9.0 the app
declares: 12.9.0 predates the V8 `External::Value()` signature change in
Electron 42 and does not compile. Its `lib/*.js` is byte-identical to
12.9.0's, so only the compiled binary differs from what the app expects.

**One Linux-only module is missing outright.** The app's file watcher does
`await import("@parcel/watcher")` with a hardcoded `backend: "inotify"` — a
branch only Linux ever takes, so the Windows package has no reason to carry
it, and does not: it is in neither `app.asar` nor `app.asar.unpacked`. Left
alone, every watch dies at startup with

```
[git-repo-watcher] Failed to watch git path errorCode=ERR_MODULE_NOT_FOUND
  Cannot find package '@parcel/watcher' imported from
  /var/data/chatgpt/resources/app.asar/.vite/build/worker.js
```

and the app never notices changes made on disk — a git branch switched, or a
file written by anything other than the app itself.

Unlike the two above, there is nothing to swap: the `native-modules` module
compiles `@parcel/watcher` against the same pinned Electron headers and
installs it whole, with its four runtime dependencies, into
`/app/share/chatgpt/node_modules`. `chatgpt-fetch` then symlinks that into
the payload directory, one level above `resources/`, which is the next place
node looks when it walks `node_modules` upwards from
`resources/app.asar/.vite/build/worker.js`. Sitting *outside* `resources/`
means it survives a payload refresh and stays clear of the swap — and if a
future payload ever ships its own copy, that one resolves first and this
becomes dead weight rather than a conflict.

**MSIX percent-encodes path names.** Scoped npm packages arrive as
`%40scope`, so `require('@scope/pkg')` misses. `chatgpt-fetch` decodes the
names depth-first.

**Electron thinks it is unpackaged.** The binary is named `electron`, which
is exactly what `app.isPackaged` treats as a dev checkout — the app then
picks development state paths (`codex-dev.vdb`). The launcher sets
`ELECTRON_FORCE_IS_PACKAGED=true`. It also creates `~/.codex`, because the
app creates its state files with a non-recursive `mkdir` and fails with
`ENOENT` if the parent is missing.

## Sandboxing

No access to the home directory is granted. The app gets `--persist=.codex`,
which gives it a private `~/.codex` for config, skills, plugins and its
session databases, stored on the host at
`~/.var/app/com.openai.ChatGPT/.codex`. That state is **not** shared with a
host-installed `codex` CLI — the two keep separate configuration and
history. Files reach the app through the file-chooser portal.

### Codex's own sandbox

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
why it is not used. Untranslatable flags are refused outright and logged to
`~/.var/app/com.openai.ChatGPT/cache/chatgpt-flatpak/bwrap.log` rather than
silently dropped.

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

### What the child can actually reach

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
`test-bwrap-shim.sh` asserts the *translation* instead, reading the line the
shim logs just before it spawns; it covers the parser in its real
environment but stops at the portal's door. Whether the child is actually
confined has to be re-measured on a desktop after any change to the
translation:

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

## Why the payload is fetched at first launch

The obvious way to package this is flatpak `extra-data`: flatpak downloads
the MSIX on the user's machine at install time and verifies it against a
`sha256` pinned in the manifest. That is safe only when the upstream URL is
immutable. OpenAI's is not — the package is served solely from
`codex-app-prod/ChatGPT-{x64,arm64}.msix`, which always returns the newest
build. The moment OpenAI republishes, the pinned checksum stops matching and
every fresh `flatpak install` fails until this repo is re-pinned.

There is no versioned endpoint to pin instead. What was checked:

| Source | Result |
| --- | --- |
| CDN path patterns (`-<version>-`, `/<version>/`, the `Codex-<channel>-<version>-<arch>` shape their macOS DMG hints at) | all 404 |
| Blob container listing | disabled |
| Azure blob `?versionId=` | versioning not enabled; no `x-ms-version-id` |
| `codex-app-prod/windows-store-update.json` | build version + Store product ID, no URL |
| Store `packageManifests` API | `InstallerType: msstore`, no URL |
| Store delivery service (FE3) | reachable, but returns no package files without a Microsoft account entitlement ticket |

The FE3 route would not help even if driven with a real account: it hands
back `*.dl.delivery.mp.microsoft.com/filestreamingservice/files/<guid>` URLs
carrying signed, expiring query parameters, which are no more pinnable than
the OpenAI one. (That shape is documented behaviour, not something this
repo was able to observe directly.)

So the package carries no checksum to go stale: `chatgpt-fetch` downloads
and unpacks the MSIX on first launch, into `/var/data/chatgpt` (the app's
own data directory — `~/.var/app/com.openai.ChatGPT/data/chatgpt` on the
host), which `/app/electron/resources` points at. A zenity dialog shows
download and unpack progress; without a display it falls back to stderr, so
`flatpak run` from a terminal still works.

What it does on each start, where *expected* is the build the packaging was
tested against (`expected-version`) and *local* is what is unpacked:

| State | Action |
| --- | --- |
| no local payload | download |
| local **==** expected | launch immediately — **no network request at all** |
| local **newer** than expected | warn once, launch what is on disk |
| local **older** than expected | ask OpenAI for the current build and download it |

So the usual start costs nothing: no HEAD request, no latency. Users also
get new OpenAI builds without waiting for this repo to catch up.

The trade-off is the trust anchor. `extra-data` would verify a checksum;
here the guarantees are HTTPS to `persistent.oaistatic.com` plus an
identity check on the downloaded `AppxManifest.xml` (package name
`OpenAI.Codex` and the expected publisher CN) before anything is unpacked.
That is the same trust model the app's own updater uses, but it is weaker
than a pinned hash, and worth knowing about.

Cost: ~700 MB downloaded on first launch and ~730 MB kept unpacked in the
app's data directory.

## Updating ChatGPT

```sh
./com.openai.ChatGPT/update-expected-version.sh
./com.openai.ChatGPT/update-metainfo.sh
```

There are no MSIX checksums to maintain. The only thing tracking upstream is
`expected-version`, which drives the drift warning above and the metainfo
release entry.

Renovate keeps it current on its own: OpenAI publish
`codex-app-prod/windows-store-update.json`, whose `buildVersion` field is
used as a custom datasource, and a custom manager matches the bare version
in `expected-version`. A ChatGPT bump lands on `renovate/chatgpt`, where
CI adds the metainfo release entry before the build sees it.
`update-expected-version.sh` does the same thing by hand (one HEAD request,
no download) if you want to bump it without waiting for Renovate.

Renovate still handles 7-Zip, Electron and the runtime. An Electron bump
must go through `update-electron-checksum.sh`, which re-pins the node
headers alongside the archives — native modules built against mismatched
headers fail at `dlopen` on the user's machine rather than in CI.

### Which Electron to bundle

The MSIX contains no Linux Electron — its Chromium (`chrome.dll` and
friends) is Windows-only, and OpenAI's own runtime, "owl", is not published
for Linux. What is portable is `app.asar`, so a Linux Electron is supplied
from outside. The pin follows the app's own
`devDependencies.electron`, currently 42.3.0.

That is checked rather than assumed. `chatgpt-fetch` reads the declared
version out of the downloaded `app.asar` — asar stores contents
uncompressed, so it is a `grep`, and an ambiguous match is ignored rather
than trusted — and records it as `electron-target` beside the payload. Each
launch compares that against `/app/electron/version`: a major gap warns the
user once, a minor gap is a stderr note. CI does the same comparison and
**fails** on a major gap, which is the signal that the `electron` module
needs bumping.

That check is also why Electron is not capped with Renovate
`allowedVersions`. Bundling something newer is not inherently wrong — owl
is Chromium 151 while Electron 42 is Chromium 148, so a newer Electron is
arguably closer to the target — and Electron only receives Chromium
security fixes for the latest three majors. Bumps stay `automerge: false`
and get reviewed, with CI reporting when one is genuinely needed.

## CI

`.github/workflows/flatpak-build.yaml` mirrors the sibling
`claude-desktop-flatpak` setup and expects the same repository
configuration:

- vars `GPG_KEY_ID`, `GPG_KEY_GREP`, `APP_CLIENT_ID`
- secrets `GPG_PRIVATE_KEY`, `GPG_PASSPHRASE`, `APP_PRIVATE_KEY`
- GitHub Pages enabled, with "GitHub Actions" as the source, to serve the
  signed Flatpak repo
- `repo.gpg`, the exported public half of the signing key, committed at the
  repository root — it is what `flatpak remote-add` verifies against

## Licence

MIT for the packaging in this repository. ChatGPT Desktop itself is
proprietary and covered by [OpenAI's terms of use](https://openai.com/policies/terms-of-use/);
nothing from OpenAI is redistributed here — the MSIX is downloaded from
OpenAI on first launch.
