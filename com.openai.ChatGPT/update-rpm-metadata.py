#!/usr/bin/env python3
"""Refresh ChatGPT RPM hashes and sizes from OpenAI's signed RPM-MD index."""

from __future__ import annotations

import gzip
import hashlib
import os
import re
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import NoReturn

try:
    import yaml
except ModuleNotFoundError:
    sys.exit(
        f"Error: PyYAML is required but is not available to {sys.executable}.\n"
        "Install it with dnf install python3-pyyaml or apt install python3-yaml."
    )


HERE = Path(__file__).resolve().parent
MANIFEST = HERE / "com.openai.ChatGPT.yaml"
KEY = HERE / "openai-rpm-key.asc"

PACKAGE = "chatgpt"
MODULE = "chatgpt"
REPO_ROOT = "https://persistent.oaistatic.com/codex-app-prod/linux/rpm"
HOST = "persistent.oaistatic.com"
ARCHES = {"x86_64": "x86_64", "aarch64": "aarch64"}
FILENAME = "chatgpt-{arch}.rpm"
FINGERPRINT = "3BFA0E4AE8B8CC16A2D9BA684A3B4A566C4660E4"

RPM_URL = re.compile(
    re.escape(REPO_ROOT)
    + r"/(?P<arch>x86_64|aarch64)/chatgpt-"
    + r"(?P<version>[0-9]+(?:\.[0-9]+)+-[0-9]+)\.(?P=arch)\.rpm\Z"
)
REPO_NS = {"repo": "http://linux.duke.edu/metadata/repo"}
COMMON_NS = {"common": "http://linux.duke.edu/metadata/common"}


def die(message: str) -> NoReturn:
    sys.exit(f"Error: {message}")


def run(argv):
    return subprocess.run(argv, capture_output=True, text=True, check=False)


class StrictRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parsed = urllib.parse.urlparse(newurl)
        if parsed.scheme != "https" or parsed.hostname != HOST:
            die(f"refusing repository redirect to {newurl}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


OPENER = urllib.request.build_opener(StrictRedirect())


def download(url: str, destination: Path) -> None:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or parsed.hostname != HOST:
        die(f"refusing non-OpenAI repository URL {url}")
    request = urllib.request.Request(url, headers={"User-Agent": "chatgpt-flatpak-updater/1"})
    try:
        with OPENER.open(request, timeout=30) as response, destination.open("wb") as output:
            if response.geturl() != url:
                redirected = urllib.parse.urlparse(response.geturl())
                if redirected.scheme != "https" or redirected.hostname != HOST:
                    die(f"refusing repository redirect to {response.geturl()}")
            while chunk := response.read(1024 * 1024):
                output.write(chunk)
    except OSError as exc:
        die(f"cannot download {url}: {exc}")


def pinned_keyring(work: Path) -> Path:
    gnupg = work / "gnupg"
    gnupg.mkdir(mode=0o700)
    keyring = work / "openai-rpm.gpg"
    result = run([
        "gpg", "--homedir", str(gnupg), "--batch", "--yes", "--dearmor",
        "-o", str(keyring), str(KEY),
    ])
    if result.returncode != 0:
        die(f"cannot dearmor {KEY.name}:\n{result.stderr.strip()}")

    listing = run([
        "gpg", "--homedir", str(gnupg), "--batch", "--with-colons",
        "--show-keys", str(keyring),
    ])
    if listing.returncode != 0:
        die(f"cannot read {KEY.name}:\n{listing.stderr.strip()}")

    primaries, want = [], False
    for line in listing.stdout.splitlines():
        fields = line.split(":")
        if fields[0] == "pub":
            want = True
        elif want and fields[0] == "fpr":
            primaries.append(fields[9])
            want = False
    if primaries != [FINGERPRINT]:
        die(
            f"{KEY.name} must contain exactly {FINGERPRINT}, found "
            f"{', '.join(primaries) or 'none'}"
        )
    return keyring


def verify_signature(keyring: Path, signature: Path, document: Path) -> None:
    result = run(["gpgv", "--keyring", str(keyring), str(signature), str(document)])
    if result.returncode != 0:
        die(f"OpenAI repository signature verification failed:\n{result.stderr.strip()}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def safe_repo_url(base: str, href: str) -> str:
    if not href or href.startswith("/"):
        die(f"unsafe RPM-MD location {href!r}")
    url = urllib.parse.urljoin(base + "/", href)
    parsed = urllib.parse.urlparse(url)
    base_path = urllib.parse.urlparse(base).path.rstrip("/") + "/"
    if parsed.scheme != "https" or parsed.hostname != HOST or not parsed.path.startswith(base_path):
        die(f"RPM-MD location escapes its repository: {href}")
    return url


def one(element, path: str, namespaces: dict, description: str):
    found = element.findall(path, namespaces)
    if len(found) != 1:
        die(f"expected one {description}, found {len(found)}")
    return found[0]


def resolve(arch: str, version: str, work: Path, keyring: Path) -> dict[str, str]:
    base = f"{REPO_ROOT}/{arch}"
    repomd = work / f"repomd-{arch}.xml"
    signature = work / f"repomd-{arch}.xml.asc"
    download(f"{base}/repodata/repomd.xml", repomd)
    download(f"{base}/repodata/repomd.xml.asc", signature)
    verify_signature(keyring, signature, repomd)

    try:
        root = ET.parse(repomd).getroot()
    except ET.ParseError as exc:
        die(f"invalid signed repomd.xml for {arch}: {exc}")
    primary = [item for item in root.findall("repo:data", REPO_NS) if item.get("type") == "primary"]
    if len(primary) != 1:
        die(f"signed {arch} repomd.xml has {len(primary)} primary indexes")
    location = one(primary[0], "repo:location", REPO_NS, f"{arch} primary location")
    checksum = one(primary[0], "repo:checksum", REPO_NS, f"{arch} primary checksum")
    if checksum.get("type") != "sha256" or not checksum.text:
        die(f"signed {arch} repomd.xml does not carry a SHA-256 primary checksum")

    primary_url = safe_repo_url(base, location.get("href", ""))
    compressed = work / f"primary-{arch}.xml.gz"
    download(primary_url, compressed)
    if sha256(compressed) != checksum.text.strip().lower():
        die(f"primary metadata checksum mismatch for {arch}")
    try:
        primary_xml = gzip.decompress(compressed.read_bytes())
        packages = ET.fromstring(primary_xml)
    except (OSError, ET.ParseError) as exc:
        die(f"invalid verified primary metadata for {arch}: {exc}")

    matches = []
    for package in packages.findall("common:package", COMMON_NS):
        name = package.findtext("common:name", namespaces=COMMON_NS)
        package_arch = package.findtext("common:arch", namespaces=COMMON_NS)
        version_node = package.find("common:version", COMMON_NS)
        if name != PACKAGE or package_arch != arch or version_node is None:
            continue
        candidate = f"{version_node.get('ver')}-{version_node.get('rel')}"
        if candidate == version:
            matches.append(package)
    if len(matches) != 1:
        die(f"signed {arch} index contains {len(matches)} copies of {PACKAGE}-{version}")

    package = matches[0]
    package_checksum = one(package, "common:checksum", COMMON_NS, f"{arch} package checksum")
    package_size = one(package, "common:size", COMMON_NS, f"{arch} package size")
    package_location = one(package, "common:location", COMMON_NS, f"{arch} package location")
    if package_checksum.get("type") != "sha256" or not package_checksum.text:
        die(f"signed {arch} index does not carry a package SHA-256")
    size = package_size.get("package", "")
    if not size.isdigit() or int(size) <= 0:
        die(f"signed {arch} index carries an invalid package size {size!r}")

    url = safe_repo_url(base, package_location.get("href", ""))
    match = RPM_URL.fullmatch(url)
    if match is None or match.group("arch") != arch or match.group("version") != version:
        die(f"signed {arch} index resolves {PACKAGE}-{version} to unexpected URL {url}")
    return {"url": url, "sha256": package_checksum.text.strip().lower(), "size": size}


def field(mapping, key):
    for field_key, value in mapping.value:
        if getattr(field_key, "value", None) == key:
            return value
    return None


def manifest_sources(node) -> dict:
    modules = field(node, "modules")
    if modules is None:
        die(f"{MANIFEST.name} has no modules")
    found = [module for module in modules.value if getattr(field(module, "name"), "value", None) == MODULE]
    if len(found) != 1:
        die(f"{MANIFEST.name} has {len(found)} modules named {MODULE}, expected one")
    sources = field(found[0], "sources")
    if sources is None:
        die(f"the {MODULE} module has no sources")

    by_arch = {}
    for source in sources.value:
        if getattr(field(source, "type"), "value", None) != "extra-data":
            continue
        url_node = field(source, "url")
        match = RPM_URL.fullmatch(getattr(url_node, "value", ""))
        if match is None:
            die(f"the {MODULE} module has an unexpected extra-data URL")
        arch = match.group("arch")
        if arch in by_arch:
            die(f"{MANIFEST.name} has two {arch} RPM sources")

        only = field(source, "only-arches")
        listed = [getattr(item, "value", item) for item in only.value] if only is not None else None
        if listed != [ARCHES[arch]]:
            die(f"the {arch} RPM has only-arches {listed}, expected [{ARCHES[arch]}]")
        filename = field(source, "filename")
        expected_filename = FILENAME.format(arch=arch)
        if filename is None or filename.value != expected_filename:
            die(f"the {arch} RPM filename must be {expected_filename}")
        for key in ("sha256", "size"):
            if field(source, key) is None:
                die(f"the {arch} RPM source has no {key}")
        by_arch[arch] = {
            "url": url_node.value,
            "version": match.group("version"),
            "sha256": field(source, "sha256"),
            "size": field(source, "size"),
        }

    missing = [arch for arch in ARCHES if arch not in by_arch]
    if missing:
        die(f"the {MODULE} module has no RPM source for {', '.join(missing)}")
    return by_arch


def value_span(text: str, node) -> tuple[int, int]:
    start, end = node.start_mark.index, node.end_mark.index
    while start < end and text[start] in "!&":
        while start < end and not text[start].isspace():
            start += 1
        while start < end and text[start].isspace():
            start += 1
    return start, end


def write_manifest(text: str, sources: dict, resolved: dict) -> str:
    edits = []
    for arch in ARCHES:
        for key in ("sha256", "size"):
            node = sources[arch][key]
            value = resolved[arch][key]
            style = node.style or None
            if style in ("'", '"'):
                value = f"{style}{value}{style}"
            elif style is not None:
                die(f"cannot rewrite {arch} {key} block scalar")
            edits.append((node, value))
    for node, value in sorted(edits, key=lambda edit: edit[0].start_mark.index, reverse=True):
        start, end = value_span(text, node)
        text = text[:start] + value + text[end:]
    return text


def check_written(text: str, resolved: dict) -> None:
    document = yaml.safe_load(text)
    modules = [module for module in document.get("modules", []) if module.get("name") == MODULE]
    if len(modules) != 1:
        die(f"rewritten manifest has {len(modules)} modules named {MODULE}")
    seen = {}
    for source in modules[0].get("sources", []):
        if source.get("type") != "extra-data":
            continue
        match = RPM_URL.fullmatch(str(source.get("url", "")))
        if match is None:
            die("rewritten manifest has an unexpected extra-data source")
        seen[match.group("arch")] = source
    for arch, expected in resolved.items():
        source = seen.get(arch)
        if source is None:
            die(f"rewritten manifest has no {arch} RPM")
        for key in ("url", "sha256", "size"):
            if str(source.get(key)) != expected[key]:
                die(f"rewritten {arch} {key} is {source.get(key)}, expected {expected[key]}")


def main() -> None:
    if sys.argv[1:]:
        die(f"usage: {Path(sys.argv[0]).name}")

    text = MANIFEST.read_text(encoding="utf-8")
    sources = manifest_sources(yaml.compose(text))
    versions = {source["version"] for source in sources.values()}
    if len(versions) != 1:
        die("manifest architecture versions disagree: " + ", ".join(
            f"{arch}={source['version']}" for arch, source in sources.items()
        ))
    version = next(iter(versions))

    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        keyring = pinned_keyring(work)
        resolved = {arch: resolve(arch, version, work, keyring) for arch in ARCHES}
        for arch in ARCHES:
            if resolved[arch]["url"] != sources[arch]["url"]:
                die(f"signed index resolves {arch} to {resolved[arch]['url']}, manifest has {sources[arch]['url']}")

        updated = write_manifest(text, sources, resolved)
        check_written(updated, resolved)
        mode = MANIFEST.stat().st_mode
        handle = tempfile.NamedTemporaryFile(
            "w", dir=MANIFEST.parent, prefix=MANIFEST.name + ".", delete=False, encoding="utf-8"
        )
        try:
            handle.write(updated)
            handle.close()
            os.chmod(handle.name, mode)
            os.replace(handle.name, MANIFEST)
        except BaseException:
            os.unlink(handle.name)
            raise

    print(f"Verified {PACKAGE} {version} against OpenAI's signed RPM-MD indexes")
    for arch in ARCHES:
        print(f"  {arch} sha256={resolved[arch]['sha256']} size={resolved[arch]['size']}")


if __name__ == "__main__":
    main()
