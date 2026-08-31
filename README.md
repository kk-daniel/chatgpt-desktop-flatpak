# Flatpak for ChatGPT Desktop

Unofficial Flatpak packaging for OpenAI's native ChatGPT desktop app on Linux.

The Flatpak uses OpenAI's official, versioned RPM builds for x86_64 and aarch64.
Those packages include the Owl app shell, Linux native modules, Codex CLI,
plugins, skills, and browser automation runtime. The earlier Windows MSIX plus
stock Electron compatibility layer is no longer used.

One deviation is worth knowing before installation: **Codex's own sandbox
cannot create a nested user namespace inside Flatpak, so this package uses an
optional host broker.** See [Sandboxing](#sandboxing).

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

The Flatpak repository contains no OpenAI application code. Flatpak downloads
the architecture-specific RPM directly from OpenAI as `extra-data` during
installation, verifies its pinned SHA-256, and runs `apply_extra` locally.

The extractor streams the RPM's CPIO payload into `/app/extra/chatgpt`, avoiding
a second full-size staging copy. The resulting tree is OpenAI's native Linux
layout and is started with its own `ChatGPT` Owl binary through Zypak.

## Upstream verification

OpenAI publishes standard signed RPM-MD repositories:

- `https://persistent.oaistatic.com/codex-app-prod/linux/rpm/x86_64/`
- `https://persistent.oaistatic.com/codex-app-prod/linux/rpm/aarch64/`

The RPM URLs contain the version and are immutable. The manifest pins the URL,
SHA-256, and byte size for each architecture. `update-rpm-metadata.py` refreshes
those pins through the repository's signed metadata rather than trusting an
unsigned download:

1. It requires the vendored key to contain exactly fingerprint
   `3BFA 0E4A E8B8 CC16 A2D9 BA68 4A3B 4A56 6C46 60E4`.
2. `gpgv` verifies each architecture's `repomd.xml.asc`.
3. The updater verifies the signed SHA-256 of `primary.xml.gz`.
4. It resolves the requested `chatgpt` version from that verified index and
   writes its URL, SHA-256, and size into the manifest.
5. It refuses architecture version skew and unexpected repository paths.

Flatpak then independently checks that SHA-256 when installing the RPM. The RPM
also carries an OpenPGP package signature from the same key; the metadata hash
chain is used here because it supplies all three fields Flatpak needs without
downloading both large RPMs in CI.

The vendored public key comes from the official RPM's repository-installation
script. Pinning the full fingerprint is what turns “a key verified this index”
into “the expected OpenAI repository key verified this index.”

## Sandboxing

The app has no access to the real home directory. `--persist=.codex` gives it a
private `~/.codex`, stored on the host at
`~/.var/app/com.openai.ChatGPT/.codex`. This state is not shared with a
host-installed Codex CLI. Files reach the app through the file chooser portal.

### Login keyring

The app is not granted `--talk-name=org.freedesktop.secrets`. Electron/Owl's
safe storage can use that service, but Secret Service does not provide
per-application isolation: a client allowed onto the service can read other
unlocked secrets too.

Without the grant, Chromium falls back to its built-in local encryption under
the Flatpak's private data directory. Treat the stored token like any other
file in your home directory.

To opt into the login keyring:

```sh
flatpak override --user --talk-name=org.freedesktop.secrets com.openai.ChatGPT
```

If backend detection still misses it, select one explicitly:

```sh
flatpak override --user --env=ELECTRON_EXTRA_LAUNCH_ARGS=--password-store=gnome-libsecret com.openai.ChatGPT
```

Use `--password-store=kwallet6` on KDE. Undo both overrides with:

```sh
flatpak override --user --no-talk-name=org.freedesktop.secrets --unset-env=ELECTRON_EXTRA_LAUNCH_ARGS com.openai.ChatGPT
```

Expect to sign in again after switching storage backends.

### Codex sandbox broker

> [!IMPORTANT]
> Codex's bubblewrap sandbox needs a small, separately installed host service.

```sh
bash host/install.sh com.openai.ChatGPT
```

Flatpak unconditionally blocks the namespace syscalls nested bubblewrap needs.
`/app/bin/bwrap` therefore hands Codex's request to the host broker, which
enters the application's existing namespaces and executes the manifest-pinned
bubblewrap there with the arguments unchanged.

This expands the app's effective syscall surface and is intentionally opt-in.
Read [SANDBOXING.md](SANDBOXING.md) and [host/README.md](host/README.md) before
using it with sensitive workspaces.

## Adding tools

VS Code tool extensions such as `podman`, `fish`, and `git-lfs` are detected
automatically under `/app/tools`. SDK extensions are opt-in through
`FLATPAK_ENABLE_SDK_EXT`:

```sh
flatpak install flathub org.freedesktop.Sdk.Extension.golang//25.08
flatpak run --env=FLATPAK_ENABLE_SDK_EXT=golang com.openai.ChatGPT
```

Use a comma-separated list or `*` for all installed SDK extensions. See
[Adding toolchains](SANDBOXING.md#adding-toolchains) for details.

## Updating ChatGPT

Renovate uses its native [`rpm` datasource](https://docs.renovatebot.com/modules/datasource/rpm/)
against each architecture's `repodata/` directory. It updates both versioned
URLs in one `chatgpt` group. The post-Renovate workflow then verifies the signed
metadata and fills in the new checksums and sizes:

```sh
./com.openai.ChatGPT/update-rpm-metadata.py
./com.openai.ChatGPT/update-metainfo.sh
```

The updater needs `gpg`, `gpgv`, and Python 3 with PyYAML. It does not download
the RPM payloads.

Renovate also tracks 7-Zip, bubblewrap, and the Freedesktop runtime. Their
existing checksum updaters remain separate because they use different upstream
trust and release mechanisms.

## CI

`.github/workflows/flatpak-build.yaml` expects:

- variables `GPG_KEY_ID`, `GPG_KEY_GREP`, and `APP_CLIENT_ID`
- secrets `GPG_PRIVATE_KEY`, `GPG_PASSPHRASE`, and `APP_PRIVATE_KEY`
- GitHub Pages enabled with GitHub Actions as its source
- `repo.gpg`, the Flatpak repository signing public key, committed at the root

The build installs the Flatpak, which also downloads and runs `apply_extra`,
then checks the Owl runtime and the essential Linux ELF payloads before running
the broker tests.

## Licence

MIT for the packaging in this repository. ChatGPT Desktop itself is proprietary
and covered by [OpenAI's terms of use](https://openai.com/policies/terms-of-use/).
OpenAI's application is downloaded directly from its repository at Flatpak
installation time and is not redistributed by this source repository.
