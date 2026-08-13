#!/usr/bin/env python3
"""Print the Electron version the current ChatGPT payload is built against.

The value is package.json's devDependencies.electron, and package.json is
inside app.asar inside the MSIX. The point of reading it here is to do so
without the 640 MB download: a zip's central directory is at the end of the
file and an asar carries an index of its contents at the start, so ranged
reads reach package.json after about 8 MB. chatgpt-fetch reads the same
field at run time from the copy already on disk, to warn about drift; this
is the build-time half of that.

The asar index is used rather than searched for. An earlier version looked
for the package name and matched a version declaration near it, which fails
the moment that name appears anywhere earlier in 40 MB of bundled
JavaScript -- and fails by finding nothing rather than by finding the wrong
thing, so it would have blocked every ChatGPT bump until someone noticed.

Bash cannot inflate a zip member from a stream, which is the only reason
this is Python.
"""
import io
import json
import re
import sys
import urllib.request
import zipfile

URL = "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix"
# Cloudflare rejects urllib's default agent on this host.
HEADERS = {"User-Agent": "curl/8.5.0"}
# Two or more dot-separated numbers, and nothing else.
VERSION = re.compile(r"[0-9]+(?:\.[0-9]+)+")


class RangeFile(io.RawIOBase):
    """Enough of a seekable file for zipfile, backed by HTTP range requests."""

    def __init__(self, url):
        self.url = url
        req = urllib.request.Request(url, method="HEAD", headers=HEADERS)
        with urllib.request.urlopen(req, timeout=30) as r:
            self.size = int(r.headers["Content-Length"])
        self.pos = 0

    def readable(self):
        return True

    def seekable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, off, whence=0):
        self.pos = off if whence == 0 else (
            self.pos + off if whence == 1 else self.size + off)
        return self.pos

    def read(self, n=-1):
        if n is None or n < 0:
            n = self.size - self.pos
        if n <= 0 or self.pos >= self.size:
            return b""
        end = min(self.pos + n, self.size) - 1
        req = urllib.request.Request(
            self.url, headers={**HEADERS, "Range": f"bytes={self.pos}-{end}"})
        with urllib.request.urlopen(req, timeout=120) as r:
            # A 200 here means the range was ignored and the body is the
            # whole 640 MB. Nothing downstream would notice: the offsets
            # would simply address the wrong bytes, after transferring
            # everything this class exists to avoid.
            if r.status != 206:
                raise OSError(
                    f"expected a partial response, got HTTP {r.status} -- "
                    "the server is not honouring Range")
            data = r.read()
        self.pos += len(data)
        return data

    def readinto(self, b):
        d = self.read(len(b))
        b[:len(d)] = d
        return len(d)


def read_exact(stream, n):
    """Streams give short reads; every offset here depends on exact counts."""
    out = bytearray()
    while len(out) < n:
        chunk = stream.read(n - len(out))
        if not chunk:
            raise EOFError(f"app.asar ended {n - len(out)} bytes early")
        out += chunk
    return bytes(out)


def asar_package_json(stream):
    """Read package.json out of an asar being streamed from its start."""
    header_size = int.from_bytes(read_exact(stream, 16)[12:16], "little")
    index = json.loads(read_exact(stream, header_size).decode("utf-8"))
    # The header is padded to a 4-byte boundary and the data section starts
    # after the padding. Ignoring it happens to work whenever the header is
    # already aligned, which is why a version that did so passed against
    # this payload and misread another.
    read_exact(stream, -header_size % 4)

    entry = index.get("files", {}).get("package.json")
    if entry is None:
        raise LookupError("package.json is not at the root of app.asar")

    read_exact(stream, int(entry["offset"]))
    return json.loads(read_exact(stream, int(entry["size"])).decode("utf-8"))


def main():
    z = zipfile.ZipFile(io.BufferedReader(RangeFile(URL), buffer_size=1 << 20))
    names = [n for n in z.namelist() if n.endswith("resources/app.asar")]
    if not names:
        print("no app.asar in the payload", file=sys.stderr)
        return 1

    with z.open(names[0]) as f:
        package = asar_package_json(f)

    declared = (package.get("devDependencies") or {}).get("electron")
    if not declared:
        print("app.asar declares no Electron devDependency", file=sys.stderr)
        return 1

    # A caret or tilde range would still name the version it was resolved
    # from, which is the one the app was built against.
    declared = declared.lstrip("^~")

    # This came out of the payload, which is the thing this packaging does
    # not trust -- chatgpt-fetch verifies the MSIX signature before
    # unpacking it, and nothing has verified anything by the time this
    # runs. What is printed here is interpolated into a shell variable, a
    # download URL, and a GitHub Actions workflow command, and a JSON \n
    # decodes to a real newline that survives all three. So it has to look
    # like a version before it leaves this process. The oracle workflow
    # applies the same rule to the value it publishes, for the same reason:
    # a failed run is visible, a bad version is not.
    if not VERSION.fullmatch(declared):
        print(f"payload declares a non-version Electron value: {declared!r}",
              file=sys.stderr)
        return 1

    print(declared)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, LookupError, EOFError) as e:
        print(f"could not read the payload's Electron version: {e}",
              file=sys.stderr)
        sys.exit(1)
