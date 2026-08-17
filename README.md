# Flatpak for ChatGPT Desktop

Unofficial Flatpak packaging for OpenAI's ChatGPT desktop app on Linux.

It repackages the official Store-signed Windows MSIX — the same one OpenAI
documents for enterprise deployment — around a stock Linux Electron, in the
spirit of [johnohhh1/chatgpt_desktop_ubuntu](https://github.com/johnohhh1/chatgpt_desktop_ubuntu),
which does the equivalent as a `.deb`.

One deviation is worth knowing before you install: **Codex's own sandbox
cannot run inside a Flatpak, and this package substitutes its own
arrangement for it.** See [Sandboxing](#sandboxing).

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

Codex can only run what is inside the sandbox, but that set is extensible
without rebuilding: the VS Code tool extensions (`podman`, `fish`, `git-lfs`)
install straight in, and the `org.freedesktop.Sdk.Extension.*` toolchains
(`golang`, `dotnet`, `llvm`, …) are enabled per launch with
`FLATPAK_ENABLE_SDK_EXT`. See
[Adding toolchains](SANDBOXING.md#adding-toolchains).

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

### The login keyring

The app is **not** given `--talk-name=org.freedesktop.secrets`. Electron's
`safeStorage` would use it to keep the session token in the login keyring, but
the Secret Service specification does not require per-application isolation and
neither gnome-keyring nor KWallet provides it: an app that can talk to the
service can read every unlocked secret belonging to every other application.
That is a lot of access in exchange for not re-entering one login.

Without it the token is encrypted with a key built into Chromium and stored
under `~/.var/app/com.openai.ChatGPT`. Treat it as a file in your home
directory, because that is what it is — anyone who can read that directory can
recover the token. Nothing else on the system can.

If you would rather have the keyring, grant it back:

```sh
flatpak override --user --talk-name=org.freedesktop.secrets com.openai.ChatGPT
```

On a desktop Chromium does not recognise, backend detection will still not find
it, so name the backend too:

```sh
flatpak override --user --env=ELECTRON_EXTRA_LAUNCH_ARGS=--password-store=gnome-libsecret com.openai.ChatGPT
```

Use `--password-store=kwallet6` on KDE. To undo either:

```sh
flatpak override --user --no-talk-name=org.freedesktop.secrets --unset-env=ELECTRON_EXTRA_LAUNCH_ARGS com.openai.ChatGPT
```

An existing login does not survive the switch in either direction: the token was
encrypted with whichever backend was in use, so expect to sign in once more.

> [!IMPORTANT]
> **Codex's sandbox needs a small service on the host, installed separately.**
>
> Codex isolates every command it runs with **bubblewrap**, which needs user
> namespaces — and nothing inside a Flatpak can create one. `unshare`,
> `setns`, `mount` and `clone(CLONE_NEWUSER)` are in flatpak's unconditional
> seccomp blocklist, and `--allow=devel` does not lift them. Left alone,
> every sandboxed command fails.
>
> ```sh
> bash host/install.sh com.openai.ChatGPT
> ```
>
> `/app/bin/bwrap` takes bubblewrap's place on `PATH` and hands each request
> to that service, which steps into the app's **own** namespaces and runs the
> real bubblewrap there with Codex's arguments unchanged. Nothing is
> translated and nothing is dropped: the command's filesystem view is the
> app's because it is literally the same mount namespace.
>
> The cost is one group of syscalls. Commands cannot run under flatpak's
> seccomp filter, since that filter is exactly what stops bubblewrap; the
> broker puts back everything in flatpak's policy except `clone`, `unshare`,
> `setns`, `mount`, `umount2`, `pivot_root`, `chroot` and `clone3`. Any code
> in the app can reach the broker, so the app's effective syscall surface
> grows by that group. That is why it is opt-in and not part of the Flatpak.
>
> Read [SANDBOXING.md](SANDBOXING.md) before trusting this with anything you
> would not hand a process confined only by this Flatpak, and
> [host/README.md](host/README.md) for how the broker authorises callers.

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

That leaves the trust anchor, and a checksum is not the only way to have
one. The MSIX is signed through the Microsoft Store, so `chatgpt-fetch`
verifies **the signature** before anything is unpacked — which is the
better fit here anyway: a pinned hash goes stale on OpenAI's next release,
authenticity does not.

What that check is worth, precisely:

| | |
| --- | --- |
| binds the signature to these bytes | yes — the Appx content digests are recomputed and compared |
| trust anchors | Microsoft's 2011 root for the signature, its 2010 root for the timestamp, both shipped in this repo |
| binds the package to *OpenAI* | yes — the signer's subject is taken from the **verified certificate**, not from the manifest inside the archive |
| revocation | checked; the CRL for each chain is fetched and verified |
| on failure | nothing is unpacked, and the launch stops with a dialog |

The identity greps over `AppxManifest.xml` are still there, but they are
sanity checks now, not the guarantee: a substituted payload would carry a
substituted manifest saying exactly the same thing. Only the signature
comes from somewhere the archive cannot reach.

Two details are worth knowing because they look wrong at first. The Store
signs with a certificate valid for **three days**, so it has long expired
by the time you install — the signature is timestamped, and verification
happens at signing time. And nothing off-the-shelf verifies these packages
on Linux: Store leaf certificates carry a critical Application Policies
extension OpenSSL does not parse, so `osslsigncode` rejects the chain
before comparing any digest. This repo carries a small patch that tolerates
that one extension and nothing else.

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

Renovate keeps it current on its own, through a value this repo publishes
for it. The build OpenAI actually serves is reported only in an HTTP header,
which no custom datasource can read, so a scheduled workflow writes it to
the `version-oracle` branch and the datasource reads that. A ChatGPT bump
then lands on `renovate/chatgpt`, where CI fills in what the version
implies before the build sees it. `update-expected-version.sh` does the
same by hand (one HEAD request, no download) if you would rather not wait.

**Electron is not tracked by Renovate**, because it is not a choice: the app
is built against one exact version and its native modules compile against
that version's headers. So the payload decides it.
`update-electron-version.sh` reads the declaration out of the payload —
about 8 MB of ranged reads rather than the 640 MB download — and re-pins the
archives and the node headers to match, as part of the same ChatGPT bump. It
refuses to cross a major on its own: that needs the native modules and the
Electron BaseApp checked by hand, and failing there is what keeps the branch
from merging.

Renovate still handles 7-Zip and the runtime.

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
