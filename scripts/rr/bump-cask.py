#!/usr/bin/env python3
"""Update the Homebrew cask for Bridgey by Round Robin after a release.

The cask lives in the public tap round-robin-solutions/homebrew-tap (Casks/bridgey-rr.rb). This script
rewrites its `version` and `sha256` for a release and, with --push, commits and pushes that change.

Usage:
  bump-cask.py --version V --dmg FILE [--push]       use a DMG already on disk (release.sh does this)
  bump-cask.py --tag TAG [--push]                    download the DMG of a published release first
  bump-cask.py --version V --dmg FILE --cask-file F  edit a local copy of the cask, no git

Options:
  --cask-file F   edit this file in place (default with --push: a fresh clone of the tap)
  --push          clone the tap, edit, commit and push; the token comes from GH_TOKEN (or GITHUB_TOKEN)
  --tap-repo R    tap repository (default round-robin-solutions/homebrew-tap)
  --dry-run       print the new cask lines and change nothing
  --force         also accept a version that is not newer than the cask's

Standard library only. The token is passed to git through the environment, never on a command line,
and is never printed.
"""

import argparse
import base64
import hashlib
import os
import re
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PROPERTIES_PATH = REPO_ROOT / "rr-edition.properties"
DEFAULT_TAP = "round-robin-solutions/homebrew-tap"
CASK_PATH_IN_TAP = "Casks/bridgey-rr.rb"
GIT_AUTHOR_NAME = "Rahul Bansal"
GIT_AUTHOR_EMAIL = "50016724+rbansal42@users.noreply.github.com"

# Stable (0.6.0-rr.1) or beta (0.6.0-rr.1-beta.3). Nightly builds are never put in the cask.
VERSION_PATTERN = re.compile(r"^(\d+)\.(\d+)\.(\d+)-rr\.(\d+)(?:-beta\.(\d+))?$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
VERSION_LINE = re.compile(r'^(\s*version\s+)"([^"]*)"(\s*)$', re.MULTILINE)
SHA256_LINE = re.compile(r'^(\s*sha256\s+)"([^"]*)"(\s*)$', re.MULTILINE)


class BumpError(Exception):
    pass


def version_key(version: str) -> tuple:
    """Sort key: a beta sorts before the stable release it leads to."""
    match = VERSION_PATTERN.match(version)
    if not match:
        raise BumpError(f"{version!r} is not a stable or beta version (for example 0.6.0-rr.1 or 0.6.0-rr.1-beta.3)")
    major, minor, patch, rr, beta = match.groups()
    base = (int(major), int(minor), int(patch), int(rr))
    return base + ((0, int(beta)) if beta is not None else (1, 0))


def current_cask_version(text: str) -> str:
    matches = VERSION_LINE.findall(text)
    if len(matches) != 1:
        raise BumpError(f"expected exactly one version line in the cask, found {len(matches)}")
    return matches[0][1]


def rewrite_cask(text: str, version: str, sha256: str) -> str:
    """Return the cask text with `version` and `sha256` replaced. Pure: no I/O. Anything else is untouched."""
    version_key(version)
    if not SHA256_PATTERN.match(sha256):
        raise BumpError("sha256 must be 64 lowercase hex digits")
    for pattern, name in ((VERSION_LINE, "version"), (SHA256_LINE, "sha256")):
        if len(pattern.findall(text)) != 1:
            raise BumpError(f"expected exactly one {name} line in the cask, found {len(pattern.findall(text))}")
    text = VERSION_LINE.sub(lambda m: f'{m.group(1)}"{version}"{m.group(3)}', text)
    return SHA256_LINE.sub(lambda m: f'{m.group(1)}"{sha256}"{m.group(3)}', text)


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_properties(path: Path = PROPERTIES_PATH) -> dict[str, str]:
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, _, value = line.partition("=")
            values[key] = value
    return values


def version_from_tag(tag: str) -> str:
    version = tag[1:] if tag.startswith("v") else tag
    version_key(version)
    return version


def release_dmg_url(props: dict[str, str], tag: str, version: str) -> str:
    return f"https://github.com/{props['GITHUB_REPO']}/releases/download/{tag}/{props['EDITION_ASSET_PREFIX']}-{version}-macOS.dmg"


def download(url: str, target: Path) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": "bridgey-rr-bump-cask"})
    with urllib.request.urlopen(request, timeout=120) as response, open(target, "wb") as out:
        while True:
            chunk = response.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)


def git(args: list[str], cwd: Path | None = None, token: str | None = None) -> str:
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    if token:
        header = "Authorization: Basic " + base64.b64encode(f"x-access-token:{token}".encode()).decode()
        env.update(GIT_CONFIG_COUNT="2", GIT_CONFIG_KEY_0="http.extraheader", GIT_CONFIG_VALUE_0=header,
                   GIT_CONFIG_KEY_1="credential.helper", GIT_CONFIG_VALUE_1="")
    result = subprocess.run(["git", *args], cwd=cwd, env=env, capture_output=True, text=True)
    if result.returncode != 0:
        message = (result.stderr or result.stdout).strip()
        if token:
            message = message.replace(token, "***")
        raise BumpError(f"git {args[0]} failed: {message}")
    return result.stdout


def tap_url(tap: str) -> str:
    return f"https://github.com/{tap}.git"


def apply_to_text(text: str, version: str, sha256: str, force: bool) -> str | None:
    """Return the new cask text, or None when it already matches. Refuses a version older than the cask's."""
    current = current_cask_version(text)
    if not force and version_key(version) < version_key(current):
        raise BumpError(f"the cask is already at {current}, which is newer than {version}; use --force to go back")
    new_text = rewrite_cask(text, version, sha256)
    return None if new_text == text else new_text


def push_to_tap(tap: str, version: str, sha256: str, token: str, force: bool) -> bool:
    with tempfile.TemporaryDirectory(prefix="bridgey-tap-") as tmp:
        clone = Path(tmp) / "tap"
        git(["clone", "--quiet", "--depth", "1", tap_url(tap), str(clone)], token=token)
        cask = clone / CASK_PATH_IN_TAP
        if not cask.is_file():
            raise BumpError(f"{CASK_PATH_IN_TAP} not found in {tap}")
        new_text = apply_to_text(cask.read_text(encoding="utf-8"), version, sha256, force)
        if new_text is None:
            return False
        cask.write_text(new_text, encoding="utf-8")
        git(["add", CASK_PATH_IN_TAP], cwd=clone)
        git(["-c", f"user.name={GIT_AUTHOR_NAME}", "-c", f"user.email={GIT_AUTHOR_EMAIL}", "commit", "--quiet", "-m",
             f"bridgey-rr {version}\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"], cwd=clone)
        git(["push", "--quiet", "origin", "HEAD"], cwd=clone, token=token)
        return True


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Update the bridgey-rr Homebrew cask for a release.")
    parser.add_argument("--version", help="release version, for example 0.6.0-rr.1")
    parser.add_argument("--dmg", help="the release's macOS DMG on disk")
    parser.add_argument("--tag", help="a published release tag; its DMG is downloaded")
    parser.add_argument("--cask-file", help="edit this local cask file in place")
    parser.add_argument("--push", action="store_true", help="clone the tap, commit and push")
    parser.add_argument("--tap-repo", default=DEFAULT_TAP)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args(argv)
    try:
        if not args.push and not args.cask_file and not args.dry_run:
            raise BumpError("pass --push (clone the tap) or --cask-file (edit a local file)")
        if bool(args.dmg) == bool(args.tag):
            raise BumpError("pass exactly one of --dmg and --tag")
        version = args.version or (version_from_tag(args.tag) if args.tag else None)
        if not version:
            raise BumpError("--version is required with --dmg")
        version_key(version)
        if args.tag and args.version and version_from_tag(args.tag) != args.version:
            raise BumpError(f"tag {args.tag} does not match version {args.version}")
        with tempfile.TemporaryDirectory(prefix="bridgey-dmg-") as tmp:
            if args.dmg:
                dmg = Path(args.dmg)
                if not dmg.is_file():
                    raise BumpError(f"{dmg} not found")
            else:
                dmg = Path(tmp) / "release.dmg"
                download(release_dmg_url(load_properties(), args.tag, version), dmg)
            sha256 = sha256_of(dmg)
        print(f"cask bridgey-rr: version {version}, sha256 {sha256}")
        if args.dry_run:
            return 0
        if args.cask_file:
            path = Path(args.cask_file)
            new_text = apply_to_text(path.read_text(encoding="utf-8"), version, sha256, args.force)
            if new_text is None:
                print("cask already up to date")
            else:
                path.write_text(new_text, encoding="utf-8")
                print(f"updated {path}")
        if args.push:
            token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
            if not token:
                raise BumpError("--push needs GH_TOKEN (or GITHUB_TOKEN) in the environment")
            changed = push_to_tap(args.tap_repo, version, sha256, token, args.force)
            print(f"pushed bridgey-rr {version} to {args.tap_repo}" if changed else "tap already up to date")
        return 0
    except (BumpError, OSError) as error:
        print(f"bump-cask: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
