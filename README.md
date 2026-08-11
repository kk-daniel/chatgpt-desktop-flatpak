# version-oracle

This branch is not source. It holds one generated file, `chatgpt-version.json`,
and shares no history with `main`.

Renovate needs a version it can read out of a response **body**. OpenAI
publishes two numbers and neither fits:

- `windows-store-update.json` reports the **Microsoft Store** build, which
  runs ahead of the direct download and is not what `chatgpt-fetch`
  compares against. Pointing Renovate at it left `expected-version` naming
  a build nobody could install.
- the build actually served is reported only in an HTTP header,
  `x-ms-meta-package_version`, which a custom datasource cannot reach.

So `.github/workflows/version-oracle.yaml` on `main` reads that header once
a day and writes it here, and Renovate's `chatgpt-desktop` datasource reads
this file. Everything after that is ordinary: Renovate opens the PR,
`post-renovate` derives the metainfo, automerge lands it, `auto-release`
tags it.

`checked` changes on every run even when `version` does not. A silently
stale oracle looks exactly like "OpenAI has not shipped anything", and
GitHub disables scheduled workflows after 60 days of repository inactivity
— which would cause precisely that.

Nothing reads this branch except Renovate. Edit it by hand only to recover
from a bad publish; the next scheduled run overwrites it.
