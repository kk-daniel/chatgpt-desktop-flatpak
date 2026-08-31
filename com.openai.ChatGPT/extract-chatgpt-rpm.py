#!/usr/bin/env python3
"""Extract usr/lib/chatgpt from a newc CPIO stream without a staging copy."""

from __future__ import annotations

import os
import stat
import sys
from pathlib import Path, PurePosixPath
from typing import NoReturn


HEADER_SIZE = 110
PREFIX = ("usr", "lib", "chatgpt")
TRAILER = "TRAILER!!!"


def die(message: str) -> NoReturn:
    raise SystemExit(f"Error: {message}")


def read_exact(stream, size: int) -> bytes:
    chunks = []
    remaining = size
    while remaining:
        chunk = stream.read(remaining)
        if not chunk:
            die("truncated CPIO stream")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def discard(stream, size: int) -> None:
    while size:
        chunk = stream.read(min(size, 1024 * 1024))
        if not chunk:
            die("truncated CPIO stream")
        size -= len(chunk)


def pad(stream, size: int) -> None:
    discard(stream, (-size) % 4)


def safe_target(root: Path, parts: tuple[str, ...]) -> Path:
    current = root
    for part in parts[:-1]:
        current /= part
        if current.is_symlink():
            die(f"archive path traverses a symlink: {'/'.join(parts)}")
        current.mkdir(mode=0o755, exist_ok=True)
        if not current.is_dir():
            die(f"archive parent is not a directory: {current}")
    return root.joinpath(*parts)


def main() -> None:
    if len(sys.argv) != 2:
        die(f"usage: {Path(sys.argv[0]).name} OUTPUT-DIRECTORY")

    root = Path(sys.argv[1])
    if root.exists() and any(root.iterdir()):
        die(f"output directory is not empty: {root}")
    root.mkdir(parents=True, exist_ok=True)

    stream = sys.stdin.buffer
    directory_modes: list[tuple[Path, int]] = []
    hardlinks: dict[tuple[int, int, int], Path] = {}
    pending: dict[tuple[int, int, int], list[Path]] = {}
    found_trailer = False

    while True:
        header = stream.read(HEADER_SIZE)
        if not header:
            break
        if len(header) != HEADER_SIZE:
            die("truncated CPIO header")
        if header[:6] not in (b"070701", b"070702"):
            die(f"unsupported CPIO magic {header[:6]!r}")

        try:
            fields = [int(header[offset : offset + 8], 16) for offset in range(6, 110, 8)]
        except ValueError:
            die("invalid hexadecimal field in CPIO header")

        (
            inode,
            mode,
            _uid,
            _gid,
            nlink,
            _mtime,
            size,
            dev_major,
            dev_minor,
            _rdev_major,
            _rdev_minor,
            name_size,
            expected_sum,
        ) = fields
        if name_size < 1:
            die("CPIO entry has an empty name")

        raw_name = read_exact(stream, name_size)
        if raw_name[-1:] != b"\0":
            die("CPIO entry name is not NUL-terminated")
        name = raw_name[:-1].decode("utf-8", "surrogateescape")
        pad(stream, HEADER_SIZE + name_size)

        if name == TRAILER:
            discard(stream, size)
            pad(stream, size)
            found_trailer = True
            break

        path = PurePosixPath(name)
        parts = path.parts
        selected = len(parts) >= len(PREFIX) and parts[: len(PREFIX)] == PREFIX
        relative = parts[len(PREFIX) :] if selected else ()
        target = safe_target(root, relative) if relative else root
        kind = stat.S_IFMT(mode)

        if not selected or not relative:
            discard(stream, size)
        elif stat.S_ISDIR(kind):
            if size:
                die(f"directory has data: {name}")
            target.mkdir(mode=0o755, exist_ok=True)
            directory_modes.append((target, stat.S_IMODE(mode)))
        elif stat.S_ISREG(kind):
            if target.exists() or target.is_symlink():
                die(f"duplicate archive path: {name}")
            link_key = (inode, dev_major, dev_minor)
            if nlink > 1 and size == 0 and link_key in hardlinks:
                os.link(hardlinks[link_key], target)
            elif nlink > 1 and size == 0:
                pending.setdefault(link_key, []).append(target)
            else:
                checksum = 0
                with target.open("xb") as output:
                    remaining = size
                    while remaining:
                        chunk = read_exact(stream, min(remaining, 1024 * 1024))
                        output.write(chunk)
                        if header[:6] == b"070702":
                            checksum = (checksum + sum(chunk)) & 0xFFFFFFFF
                        remaining -= len(chunk)
                if header[:6] == b"070702" and checksum != expected_sum:
                    die(f"CPIO checksum mismatch for {name}")
                os.chmod(target, stat.S_IMODE(mode))
                if nlink > 1:
                    hardlinks[link_key] = target
                    for other in pending.pop(link_key, []):
                        os.link(target, other)
            if size == 0:
                # No bytes were consumed by the hard-link branches above.
                pass
        elif stat.S_ISLNK(kind):
            if target.exists() or target.is_symlink():
                die(f"duplicate archive path: {name}")
            link = read_exact(stream, size).decode("utf-8", "surrogateescape")
            os.symlink(link, target)
        else:
            die(f"unsupported file type in ChatGPT payload: {name}")

        # Regular-file and symlink data was consumed in their branches. All
        # other selected or skipped entries reach here with no data left.
        pad(stream, size)

    if not found_trailer:
        die("CPIO trailer not found")
    if pending:
        die("unresolved hard links in CPIO payload")

    for directory, mode in reversed(directory_modes):
        os.chmod(directory, mode)


if __name__ == "__main__":
    main()
