#!/usr/bin/env python3
"""Print the Electron version the current ChatGPT payload is built against.

The value lives in package.json inside app.asar inside the MSIX, and the
whole point of reading it here is to do so without the 640 MB download:
a zip's central directory is at the end of the file and an asar's header is
at the start of its data, so ranged reads get to package.json after about
8 MB. chatgpt-fetch reads the same field at run time, from the copy already
on disk, to warn about drift -- this is the build-time half of that.

Bash cannot inflate a zip member from a stream, which is the only reason
this is Python.
"""
import io
import json
import re
import sys
import urllib.request
import zipfile

URL = ("https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix")
# Cloudflare rejects urllib's default agent on this host.
HEADERS = {"User-Agent": "curl/8.5.0"}
# package.json sits about 20 MB into the asar; stop well after that rather
# than stream the whole 226 MB if the layout ever changes.
LIMIT = 40_000_000
DECL = re.compile(rb'"electron"\s*:\s*"[\^~]?([0-9][^"]*)"')


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
            data = r.read()
        self.pos += len(data)
        return data

    def readinto(self, b):
        d = self.read(len(b))
        b[:len(d)] = d
        return len(d)


def main():
    z = zipfile.ZipFile(io.BufferedReader(RangeFile(URL), buffer_size=1 << 20))
    try:
        name = next(n for n in z.namelist() if n.endswith("resources/app.asar"))
    except StopIteration:
        print("no app.asar in the payload", file=sys.stderr)
        return 1

    with z.open(name) as f:
        buf = bytearray()
        while len(buf) < LIMIT:
            chunk = f.read(1 << 20)
            if not chunk:
                break
            buf += chunk
            # The declaration is matched near the package name rather than
            # anywhere in 40 MB of bundled JavaScript, which mentions
            # "electron" constantly.
            i = buf.find(b"openai-codex-electron")
            if i == -1:
                continue
            m = DECL.search(bytes(buf[max(0, i - 2000):i + 4000]))
            if m:
                print(m.group(1).decode())
                return 0

    print("could not find the Electron declaration in app.asar", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
