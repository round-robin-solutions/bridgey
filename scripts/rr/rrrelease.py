#!/usr/bin/env python3
"""Bridgey by Round Robin release helper: versions, channel feeds and the Sparkle appcast.

Subcommands
  version   Print VERSION_NAME, BUILD_NUMBER, TAG and PRERELEASE for a channel (shell KEY=value lines).
  assemble  Copy built artifacts into <dist>/release with release file names, write SHA256SUMS,
            <dist>/channels/<channel>.json and the merged, EdDSA-signed <dist>/channels/appcast.xml.
  verify    Validate every feed and appcast item in <dist>/channels against the files in <dist>/release.
  rebase    Re-merge an assembled release into feeds downloaded just now (publish.sh runs it under the
            channels lock, so a beta and a nightly published together never drop each other's item).

Settings come from rr-edition.properties; the Sparkle public key from macos/Resources/Info.plist.
Nothing here talks to GitHub except an optional read-only download of the current feeds
(--fetch-previous). Publishing lives in publish.sh.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import email.utils
import hashlib
import html
import json
import plistlib
import re
import shutil
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PROPERTIES_PATH = REPO_ROOT / "rr-edition.properties"
INFO_PLIST_PATH = REPO_ROOT / "macos" / "Resources" / "Info.plist"

SCHEMA = 1
CHANNELS = ("stable", "beta", "nightly")
ANDROID_MIN_SDK = 26
MACOS_MINIMUM_SYSTEM_VERSION = "13.0"
# Appcast items kept per channel. Nightly matches the number of nightly releases kept on GitHub.
APPCAST_RETENTION = {"stable": 5, "beta": 5, "nightly": 10}
MAX_NOTES_LENGTH = 4000

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC_NS = "http://purl.org/dc/elements/1.1/"
ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("dc", DC_NS)

STABLE_VERSION = re.compile(r"^\d+\.\d+\.\d+-rr\.\d+$")
VERSION_BY_CHANNEL = {
    "stable": STABLE_VERSION,
    "beta": re.compile(r"^\d+\.\d+\.\d+-rr\.\d+-beta\.\d+$"),
    "nightly": re.compile(r"^\d+\.\d+\.\d+-rr\.\d+-nightly\.\d{8}$"),
}
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")


class ReleaseError(Exception):
    pass


class Superseded(ReleaseError):
    """A newer build of the channel was published while this one was being prepared."""


# ---------------------------------------------------------------- settings


def load_properties(path: Path = PROPERTIES_PATH) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def sparkle_public_key(path: Path = INFO_PLIST_PATH) -> str:
    with path.open("rb") as handle:
        return plistlib.load(handle)["SUPublicEDKey"]


# ---------------------------------------------------------------- versions


def build_number(moment: dt.datetime) -> int:
    """YYDDDHHMM in UTC: grows with time across every channel and fits Android's versionCode limit."""
    moment = moment.astimezone(dt.timezone.utc)
    day_of_year = moment.timetuple().tm_yday
    return (moment.year % 100) * 10_000_000 + day_of_year * 10_000 + moment.hour * 100 + moment.minute


def resolve_version(channel: str, next_version: str, requested: str | None, moment: dt.datetime) -> tuple[str, str]:
    """Return (version name, tag) for a channel."""
    if channel not in CHANNELS:
        raise ReleaseError(f"Unknown channel {channel!r}; use one of {', '.join(CHANNELS)}")
    if not STABLE_VERSION.match(next_version):
        raise ReleaseError(f"EDITION_NEXT_VERSION {next_version!r} must look like 0.6.0-rr.1")
    if channel == "nightly":
        if requested:
            raise ReleaseError("Nightly versions are generated; do not pass --version")
        moment = moment.astimezone(dt.timezone.utc)
        date = moment.strftime("%Y%m%d")
        # Every build gets its own tag (UTC minute, like the build number). The version name keeps the
        # date only: the apps accept "-nightly.YYYYMMDD" and order builds by build number.
        return f"{next_version}-nightly.{date}", f"nightly-{date}.{moment.strftime('%H%M')}"
    version = requested or (next_version if channel == "stable" else None)
    if not version:
        raise ReleaseError(f"Pass --version for {channel}, for example {next_version}-beta.1")
    if not VERSION_BY_CHANNEL[channel].match(version):
        raise ReleaseError(f"{version!r} is not a valid {channel} version")
    if not version.startswith(next_version):
        raise ReleaseError(f"{version!r} must build towards EDITION_NEXT_VERSION {next_version!r}")
    return version, f"v{version}"


# ---------------------------------------------------------------- helpers


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_private_key(path: Path):
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    raw = base64.b64decode(path.read_text(encoding="utf-8").strip())
    if len(raw) not in (32, 64):
        raise ReleaseError("Sparkle private key must be a base64 32-byte seed (or legacy 64-byte key)")
    return Ed25519PrivateKey.from_private_bytes(raw[:32])


def public_key_b64(private_key) -> str:
    from cryptography.hazmat.primitives import serialization

    raw = private_key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return base64.b64encode(raw).decode("ascii")


def ed_sign(private_key, path: Path) -> str:
    return base64.b64encode(private_key.sign(path.read_bytes())).decode("ascii")


def ed_verify(public_key: str, path: Path, signature: str) -> bool:
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

    key = Ed25519PublicKey.from_public_bytes(base64.b64decode(public_key))
    try:
        key.verify(base64.b64decode(signature), path.read_bytes())
        return True
    except (InvalidSignature, ValueError):
        return False


def fetch(url: str) -> bytes | None:
    request = urllib.request.Request(url, headers={"User-Agent": "bridgey-rr-release"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read(4 * 1024 * 1024)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def iso(moment: dt.datetime) -> str:
    return moment.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


# ---------------------------------------------------------------- feed validation


def validate_feed(feed: dict, channel: str, app_id: str, asset_prefix: str) -> None:
    """Same rules as the Android and macOS parsers (UpdateLogic.kt / UpdateLogic.swift)."""

    def require(condition: bool, message: str) -> None:
        if not condition:
            raise ReleaseError(f"{channel}.json: {message}")

    def check_asset(asset: dict, label: str) -> None:
        require(str(asset.get("url", "")).startswith(asset_prefix), f"{label} URL is outside the release repository")
        require(bool(SHA256_PATTERN.match(str(asset.get("sha256", "")))), f"{label} SHA-256 is invalid")
        require(isinstance(asset.get("size"), int) and 0 < asset["size"] <= 150 * 1024 * 1024, f"{label} size is invalid")

    require(feed.get("schema") == SCHEMA, "unsupported schema")
    require(feed.get("app") == app_id, "wrong app id")
    require(feed.get("channel") == channel, "wrong channel")
    require(asset_prefix.startswith("https://"), "asset prefix must use HTTPS")
    notes_url = feed.get("notesUrl") or ""
    require(not notes_url or notes_url.startswith("https://"), "release notes must use HTTPS")
    android = feed.get("android")
    if android is not None:
        require(bool(VERSION_BY_CHANNEL[channel].match(android.get("versionName", ""))), "Android version does not match channel")
        require(isinstance(android.get("versionCode"), int) and 0 < android["versionCode"] <= 2**31 - 1, "Android versionCode is invalid")
        check_asset(android, "APK")
    macos = feed.get("macos")
    if macos is not None:
        require(bool(VERSION_BY_CHANNEL[channel].match(macos.get("shortVersion", ""))), "macOS version does not match channel")
        require(isinstance(macos.get("build"), int) and macos["build"] > 0, "macOS build is invalid")
        check_asset(macos.get("dmg", {}), "DMG")
        check_asset(macos.get("zip", {}), "ZIP")
        try:
            signature = base64.b64decode(macos.get("edSignature", ""), validate=True)
        except ValueError:
            signature = b""
        require(len(signature) == 64, "macOS EdDSA signature is invalid")
    require(android is not None or macos is not None, "feed has no platform entry")


# ---------------------------------------------------------------- appcast


def parse_appcast(xml_bytes: bytes | None) -> list[dict]:
    if not xml_bytes:
        return []
    root = ET.fromstring(xml_bytes)
    items = []
    for item in root.iter("item"):
        enclosure = item.find("enclosure")
        if enclosure is None:
            continue
        items.append(
            {
                "title": item.findtext("title", ""),
                "pubDate": item.findtext("pubDate", ""),
                "version": item.findtext(f"{{{SPARKLE_NS}}}version", ""),
                "shortVersion": item.findtext(f"{{{SPARKLE_NS}}}shortVersionString", ""),
                "channel": item.findtext(f"{{{SPARKLE_NS}}}channel") or "stable",
                "minimumSystemVersion": item.findtext(f"{{{SPARKLE_NS}}}minimumSystemVersion", MACOS_MINIMUM_SYSTEM_VERSION),
                "fullReleaseNotesLink": item.findtext(f"{{{SPARKLE_NS}}}fullReleaseNotesLink", ""),
                "description": item.findtext("description", ""),
                "url": enclosure.get("url", ""),
                "length": enclosure.get("length", "0"),
                "edSignature": enclosure.get(f"{{{SPARKLE_NS}}}edSignature", ""),
            }
        )
    return items


def merge_appcast_items(existing: list[dict], new_item: dict) -> list[dict]:
    """Replace the item of the same build in the same channel (and, for beta and stable, the same
    version name), then keep the newest N per channel. Nightly builds of one day share a version
    name, so they are told apart by build, like the nightly releases kept on GitHub."""
    def same(item):
        if item["channel"] != new_item["channel"]:
            return False
        return item["version"] == new_item["version"] or (new_item["channel"] != "nightly" and item["shortVersion"] == new_item["shortVersion"])
    kept = [item for item in existing if not same(item)]
    kept.append(new_item)
    kept.sort(key=lambda item: int(item["version"]), reverse=True)
    counts: dict[str, int] = {}
    result = []
    for item in kept:
        counts[item["channel"]] = counts.get(item["channel"], 0) + 1
        if counts[item["channel"]] <= APPCAST_RETENTION.get(item["channel"], 5):
            result.append(item)
    return result


def render_appcast(items: list[dict], title: str, feed_url: str) -> bytes:
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = title
    ET.SubElement(channel, "link").text = feed_url
    ET.SubElement(channel, "description").text = f"{title} updates. Beta and Nightly items carry sparkle:channel."
    ET.SubElement(channel, "language").text = "en"
    for item in items:
        node = ET.SubElement(channel, "item")
        ET.SubElement(node, "title").text = item["title"]
        ET.SubElement(node, "pubDate").text = item["pubDate"]
        ET.SubElement(node, f"{{{SPARKLE_NS}}}version").text = item["version"]
        ET.SubElement(node, f"{{{SPARKLE_NS}}}shortVersionString").text = item["shortVersion"]
        if item["channel"] != "stable":
            ET.SubElement(node, f"{{{SPARKLE_NS}}}channel").text = item["channel"]
        ET.SubElement(node, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = item["minimumSystemVersion"]
        if item["fullReleaseNotesLink"]:
            ET.SubElement(node, f"{{{SPARKLE_NS}}}fullReleaseNotesLink").text = item["fullReleaseNotesLink"]
        if item["description"]:
            ET.SubElement(node, "description").text = item["description"]
        ET.SubElement(
            node,
            "enclosure",
            {
                "url": item["url"],
                "length": str(item["length"]),
                "type": "application/octet-stream",
                f"{{{SPARKLE_NS}}}edSignature": item["edSignature"],
            },
        )
    ET.indent(rss, space="  ")
    return b'<?xml version="1.0" encoding="utf-8"?>\n' + ET.tostring(rss, encoding="utf-8") + b"\n"


def notes_html(version: str, notes: str) -> str:
    paragraphs = [f"<p>{html.escape(line)}</p>" for line in notes.splitlines() if line.strip()]
    return f"<h2>{html.escape(version)}</h2>" + "".join(paragraphs)


# ---------------------------------------------------------------- assemble


def assemble(args: argparse.Namespace, props: dict[str, str]) -> Path:
    channel = args.channel
    version = args.version
    build = int(args.build)
    tag = args.tag
    dist = Path(args.dist)
    if not VERSION_BY_CHANNEL[channel].match(version):
        raise ReleaseError(f"{version!r} is not a valid {channel} version")
    if not args.apk and not args.zip:
        raise ReleaseError("Nothing to release: pass --apk and/or --dmg and --zip")
    if bool(args.dmg) != bool(args.zip):
        raise ReleaseError("macOS needs both --dmg and --zip")

    app_id = props["EDITION_APP_ID"]
    prefix = props["EDITION_ASSET_PREFIX"]
    repo = props["GITHUB_REPO"]
    feed_base = props["UPDATE_FEED_BASE_URL"].rstrip("/")
    asset_prefix = props["UPDATE_ASSET_URL_PREFIX"]
    download_base = f"https://github.com/{repo}/releases/download/{tag}/"
    if not download_base.startswith(asset_prefix):
        raise ReleaseError("UPDATE_ASSET_URL_PREFIX does not cover this repository's release downloads")
    notes_url = f"https://github.com/{repo}/releases/tag/{tag}"
    notes = Path(args.notes_file).read_text(encoding="utf-8").strip()[:MAX_NOTES_LENGTH] if args.notes_file else ""
    published = dt.datetime.fromisoformat(args.published.replace("Z", "+00:00")) if args.published else dt.datetime.now(dt.timezone.utc)

    release_dir = dist / "release"
    channels_dir = dist / "channels"
    for directory in (release_dir, channels_dir):
        if directory.exists():
            shutil.rmtree(directory)
        directory.mkdir(parents=True)

    previous_feed = None
    previous_appcast = None
    if args.previous_channels:
        previous_dir = Path(args.previous_channels)
        feed_path = previous_dir / f"{channel}.json"
        previous_feed = json.loads(feed_path.read_text()) if feed_path.is_file() else None
        appcast_path = previous_dir / "appcast.xml"
        previous_appcast = appcast_path.read_bytes() if appcast_path.is_file() else None
    elif args.fetch_previous:
        raw = fetch(f"{feed_base}/{channel}.json")
        previous_feed = json.loads(raw) if raw else None
        previous_appcast = fetch(f"{feed_base}/appcast.xml")

    if previous_feed and (int(previous_feed.get("build", 0)) > build or (int(previous_feed.get("build", 0)) == build and previous_feed.get("tag") != tag)):
        raise ReleaseError(f"Build {build} is not newer than the published {channel} build {previous_feed['build']}")

    feed: dict = {
        "schema": SCHEMA,
        "app": app_id,
        "channel": channel,
        "version": version,
        "build": build,
        "published": iso(published),
        "tag": tag,
        "notesUrl": notes_url,
        "notes": notes,
    }
    sums: list[tuple[str, str]] = []

    def stage(source: str, name: str) -> tuple[Path, str, int]:
        target = release_dir / name
        shutil.copyfile(source, target)
        digest = sha256_file(target)
        sums.append((digest, name))
        return target, digest, target.stat().st_size

    if args.apk:
        _, digest, size = stage(args.apk, f"{prefix}-{version}-Android.apk")
        feed["android"] = {
            "versionName": version,
            "versionCode": build,
            "url": download_base + f"{prefix}-{version}-Android.apk",
            "sha256": digest,
            "size": size,
            "minSdk": ANDROID_MIN_SDK,
        }
    elif previous_feed and previous_feed.get("android"):
        print(f"note: no APK in this release; {channel}.json keeps Android {previous_feed['android']['versionName']}", file=sys.stderr)
        feed["android"] = previous_feed["android"]

    new_item = None
    if args.zip:
        if not args.ed_key:
            raise ReleaseError("--ed-key is required to sign the macOS update")
        private_key = load_private_key(Path(args.ed_key))
        expected_public = args.ed_public_key or sparkle_public_key()
        if public_key_b64(private_key) != expected_public:
            raise ReleaseError("Sparkle private key does not match SUPublicEDKey in Info.plist")
        _, dmg_digest, dmg_size = stage(args.dmg, f"{prefix}-{version}-macOS.dmg")
        zip_path, zip_digest, zip_size = stage(args.zip, f"{prefix}-{version}-macOS.zip")
        signature = ed_sign(private_key, zip_path)
        feed["macos"] = {
            "shortVersion": version,
            "build": build,
            "minimumSystemVersion": MACOS_MINIMUM_SYSTEM_VERSION,
            "dmg": {"url": download_base + f"{prefix}-{version}-macOS.dmg", "sha256": dmg_digest, "size": dmg_size},
            "zip": {"url": download_base + f"{prefix}-{version}-macOS.zip", "sha256": zip_digest, "size": zip_size},
            "edSignature": signature,
        }
        new_item = {
            "title": version,
            "pubDate": email.utils.format_datetime(published.astimezone(dt.timezone.utc)),
            "version": str(build),
            "shortVersion": version,
            "channel": channel,
            "minimumSystemVersion": MACOS_MINIMUM_SYSTEM_VERSION,
            "fullReleaseNotesLink": notes_url,
            "description": notes_html(version, notes) if notes else "",
            "url": feed["macos"]["zip"]["url"],
            "length": zip_size,
            "edSignature": signature,
        }
    elif previous_feed and previous_feed.get("macos"):
        print(f"note: no macOS build in this release; {channel}.json keeps macOS {previous_feed['macos']['shortVersion']}", file=sys.stderr)
        feed["macos"] = previous_feed["macos"]

    validate_feed(feed, channel, app_id, asset_prefix)
    (release_dir / "SHA256SUMS").write_text("".join(f"{digest}  {name}\n" for digest, name in sorted(sums, key=lambda s: s[1])))
    (channels_dir / f"{channel}.json").write_text(json.dumps(feed, indent=2) + "\n", encoding="utf-8")

    items = parse_appcast(previous_appcast)
    if new_item:
        items = merge_appcast_items(items, new_item)
    if items or previous_appcast is not None:
        title = props["EDITION_DISPLAY_NAME"]
        (channels_dir / "appcast.xml").write_bytes(render_appcast(items, title, f"{feed_base}/appcast.xml"))
    (dist / "release.env").write_text(
        f"CHANNEL={channel}\nVERSION_NAME={version}\nBUILD_NUMBER={build}\nTAG={tag}\n", encoding="utf-8"
    )
    if notes:
        (dist / "notes.md").write_text(notes + "\n", encoding="utf-8")
    return dist


# ---------------------------------------------------------------- verify


def verify(dist: Path, props: dict[str, str], public_key: str) -> list[str]:
    channels_dir = dist / "channels"
    release_dir = dist / "release"
    app_id = props["EDITION_APP_ID"]
    asset_prefix = props["UPDATE_ASSET_URL_PREFIX"]
    report = []
    found = False
    for channel in CHANNELS:
        path = channels_dir / f"{channel}.json"
        if not path.is_file():
            continue
        found = True
        feed = json.loads(path.read_text(encoding="utf-8"))
        validate_feed(feed, channel, app_id, asset_prefix)
        assets = []
        if feed.get("android"):
            assets.append(feed["android"])
        if feed.get("macos"):
            assets += [feed["macos"]["dmg"], feed["macos"]["zip"]]
        for asset in assets:
            local = release_dir / asset["url"].rsplit("/", 1)[-1]
            if local.is_file():
                if sha256_file(local) != asset["sha256"] or local.stat().st_size != asset["size"]:
                    raise ReleaseError(f"{local.name} does not match {channel}.json")
                report.append(f"{channel}: {local.name} sha256 ok")
        if feed.get("macos"):
            local_zip = release_dir / feed["macos"]["zip"]["url"].rsplit("/", 1)[-1]
            if local_zip.is_file():
                if not ed_verify(public_key, local_zip, feed["macos"]["edSignature"]):
                    raise ReleaseError(f"EdDSA signature in {channel}.json does not verify")
                report.append(f"{channel}: {local_zip.name} EdDSA ok")
    if not found:
        raise ReleaseError(f"No channel feeds in {channels_dir}")
    appcast = channels_dir / "appcast.xml"
    if appcast.is_file():
        items = parse_appcast(appcast.read_bytes())
        builds = [int(item["version"]) for item in items]
        if builds != sorted(builds, reverse=True):
            raise ReleaseError("appcast items are not sorted newest first")
        for item in items:
            if item["channel"] not in CHANNELS or not VERSION_BY_CHANNEL[item["channel"]].match(item["shortVersion"]):
                raise ReleaseError(f"appcast item {item['shortVersion']} has a bad channel or version")
            if not item["url"].startswith(asset_prefix):
                raise ReleaseError(f"appcast item {item['shortVersion']} points outside the release repository")
            local = release_dir / item["url"].rsplit("/", 1)[-1]
            if local.is_file():
                if not ed_verify(public_key, local, item["edSignature"]):
                    raise ReleaseError(f"appcast signature for {local.name} does not verify")
                report.append(f"appcast: {local.name} EdDSA ok")
        report.append(f"appcast: {len(items)} item(s)")
    sums = release_dir / "SHA256SUMS"
    if sums.is_file():
        for line in sums.read_text().splitlines():
            digest, name = line.split("  ", 1)
            if sha256_file(release_dir / name) != digest:
                raise ReleaseError(f"SHA256SUMS mismatch for {name}")
        report.append("SHA256SUMS ok")
    return report


# ---------------------------------------------------------------- rebase


def rebase(dist: Path, previous_dir: Path, props: dict[str, str]) -> list[str]:
    """Merge the assembled release into the feeds published right now. The channel feed takes the
    fresh feed's entry for a platform this release does not include; the appcast gets this release's
    item added to the fresh items. Refuses (Superseded) when the channel already has a newer build."""
    env = dict(line.split("=", 1) for line in (dist / "release.env").read_text(encoding="utf-8").splitlines() if "=" in line)
    channel, build, tag = env["CHANNEL"], int(env["BUILD_NUMBER"]), env["TAG"]
    channels_dir, release_dir = dist / "channels", dist / "release"
    feed_path = channels_dir / f"{channel}.json"
    feed = json.loads(feed_path.read_text(encoding="utf-8"))
    fresh_path = previous_dir / f"{channel}.json"
    fresh = json.loads(fresh_path.read_text(encoding="utf-8")) if fresh_path.is_file() else None
    if fresh and (int(fresh.get("build", 0)) > build or (int(fresh.get("build", 0)) == build and fresh.get("tag") != tag)):
        raise Superseded(f"{channel} already has build {fresh['build']} ({fresh.get('tag')}), newer than {build}")
    names = {path.name for path in release_dir.iterdir()} if release_dir.is_dir() else set()
    included = {"android": any(n.endswith("-Android.apk") for n in names), "macos": any(n.endswith("-macOS.zip") for n in names)}
    for platform, present in included.items():
        if present:
            continue
        if fresh and fresh.get(platform):
            feed[platform] = fresh[platform]
        else:
            feed.pop(platform, None)
    validate_feed(feed, channel, props["EDITION_APP_ID"], props["UPDATE_ASSET_URL_PREFIX"])
    feed_path.write_text(json.dumps(feed, indent=2) + "\n", encoding="utf-8")
    report = [f"{channel}.json rebased on the published feed" + (f" (build {fresh['build']})" if fresh else " (none published yet)")]
    appcast = channels_dir / "appcast.xml"
    fresh_appcast_path = previous_dir / "appcast.xml"
    fresh_appcast = fresh_appcast_path.read_bytes() if fresh_appcast_path.is_file() else None
    if included["macos"]:
        ours = [item for item in parse_appcast(appcast.read_bytes() if appcast.is_file() else None) if item["version"] == str(build)]
        if not ours:
            raise ReleaseError("the assembled appcast has no item for this build")
        items = merge_appcast_items(parse_appcast(fresh_appcast), ours[0])
        appcast.write_bytes(render_appcast(items, props["EDITION_DISPLAY_NAME"], props["UPDATE_FEED_BASE_URL"].rstrip("/") + "/appcast.xml"))
        report.append(f"appcast.xml: {len(items)} item(s) after adding build {build}")
    elif appcast.is_file():
        # Nothing to add: leave the published appcast alone.
        appcast.unlink()
        report.append("appcast.xml unchanged (no macOS build in this release)")
    return report


# ---------------------------------------------------------------- CLI


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    version_parser = sub.add_parser("version", help="print version, build number and tag for a channel")
    version_parser.add_argument("channel", choices=CHANNELS)
    version_parser.add_argument("--version")
    version_parser.add_argument("--now", help="ISO time (UTC) to derive the build number from; default now")

    assemble_parser = sub.add_parser("assemble", help="stage assets and write feeds into a dist directory")
    assemble_parser.add_argument("--channel", required=True, choices=CHANNELS)
    assemble_parser.add_argument("--version", required=True)
    assemble_parser.add_argument("--build", required=True, type=int)
    assemble_parser.add_argument("--tag", required=True)
    assemble_parser.add_argument("--dist", required=True)
    assemble_parser.add_argument("--apk")
    assemble_parser.add_argument("--dmg")
    assemble_parser.add_argument("--zip")
    assemble_parser.add_argument("--notes-file")
    assemble_parser.add_argument("--ed-key", help="file with the base64 Sparkle EdDSA private key")
    assemble_parser.add_argument("--ed-public-key", help=argparse.SUPPRESS)
    assemble_parser.add_argument("--published", help="ISO publish time; default now")
    previous = assemble_parser.add_mutually_exclusive_group()
    previous.add_argument("--previous-channels", help="directory with the currently published <channel>.json/appcast.xml")
    previous.add_argument("--fetch-previous", action="store_true", help="download the published feeds (read-only)")

    verify_parser = sub.add_parser("verify", help="validate feeds, checksums and signatures in a dist directory")
    verify_parser.add_argument("--dist", required=True)
    verify_parser.add_argument("--ed-public-key", help=argparse.SUPPRESS)

    rebase_parser = sub.add_parser("rebase", help="re-merge an assembled release into freshly downloaded feeds")
    rebase_parser.add_argument("--dist", required=True)
    rebase_parser.add_argument("--previous-channels", required=True, help="directory with the feeds published right now")

    args = parser.parse_args(argv)
    props = load_properties()
    try:
        if args.command == "version":
            moment = dt.datetime.fromisoformat(args.now.replace("Z", "+00:00")) if args.now else dt.datetime.now(dt.timezone.utc)
            if moment.tzinfo is None:
                moment = moment.replace(tzinfo=dt.timezone.utc)
            name, tag = resolve_version(args.channel, props["EDITION_NEXT_VERSION"], args.version, moment)
            print(f"CHANNEL={args.channel}")
            print(f"VERSION_NAME={name}")
            print(f"BUILD_NUMBER={build_number(moment)}")
            print(f"TAG={tag}")
            print(f"PRERELEASE={'false' if args.channel == 'stable' else 'true'}")
        elif args.command == "assemble":
            dist = assemble(args, props)
            print(f"assembled {dist}")
        elif args.command == "verify":
            for line in verify(Path(args.dist), props, args.ed_public_key or sparkle_public_key()):
                print(line)
        elif args.command == "rebase":
            for line in rebase(Path(args.dist), Path(args.previous_channels), props):
                print(line)
    except Superseded as error:
        print(f"superseded: {error}", file=sys.stderr)
        return 3
    except ReleaseError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
