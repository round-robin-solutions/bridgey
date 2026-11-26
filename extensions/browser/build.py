#!/usr/bin/env python3
"""Builds Bridgey's browser extension for Chrome, Edge and Firefox from extensions/browser/src (docs/browser-extensions.md).

  python3 extensions/browser/build.py --version 1.0.0-beta.7 --out dist/browser
      writes Bridgey-RR-1.0.0-beta.7-Chrome.zip, -Edge.zip and -Firefox.zip: the release assets for installing by hand
      (Chrome and Edge: unzip, then Load unpacked; Firefox: Load Temporary Add-on, or permanently once signed).
  --store             packages for a store's first upload instead (-Chrome-store.zip, -Edge-store.zip): no "key",
                      since the stores assign the ID; add the store's ID to native-host.json before shipping it
  --unpacked DIR      also writes each browser's unpacked folder to DIR/<browser>
  --browsers LIST     a comma-separated subset of chrome,edge,firefox
  --test-host-permission ORIGIN
                      adds a host permission (end-to-end tests read a test page's address without a click); never in
                      a release

One source, three manifests: Chrome and Edge run the background as a service worker with a fixed "key" (so an unpacked
install has the ID the native host allows); Firefox runs it as an event page with a fixed add-on ID. The zips are
reproducible: sorted entries, fixed times and modes. Standard library only.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SOURCE = HERE / "src"
REPO = HERE.parent.parent
BROWSERS = ("chrome", "edge", "firefox")
LABELS = {"chrome": "Chrome", "edge": "Edge", "firefox": "Firefox"}
# Files that go into every package, relative to src/ (the background and popup scripts, styles, locales, fonts, icons).
SHARED = ("lib.js", "background.js", "popup.html", "popup.css", "popup.js")
ZIP_TIME = (2026, 1, 1, 0, 0, 0)
FIREFOX_MIN = "115.0"
CHROME_MIN = "116"


class BuildError(Exception):
    pass


def properties() -> dict[str, str]:
    values = {}
    for line in (REPO / "rr-edition.properties").read_text(encoding="utf-8").splitlines():
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values


def native_host() -> dict:
    return json.loads((HERE / "native-host.json").read_text(encoding="utf-8"))


def manifest_version(name: str) -> str:
    """The dotted version browsers and stores accept (up to four numbers, each at most 65535 for Chrome).

    1.0.0 -> 1.0.0.1000, 1.0.0-beta.6 -> 1.0.0.6, 1.0.0-nightly.20261126 and 1.0.0-dev -> 1.0.0.0. Betas of a
    version sort below its Stable, and every Stable below the next version's betas.
    """
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:-(beta|nightly)\.(\d+)|-dev)?", name)
    if not match:
        raise BuildError(f"{name!r} is not a Bridgey version name")
    major, minor, patch, kind, number = match.groups()
    if any(int(part) > 65535 for part in (major, minor, patch)):
        raise BuildError(f"{name!r} has a part above 65535")
    if kind == "beta":
        if not 1 <= int(number) <= 999:
            raise BuildError(f"beta number in {name!r} must be 1 to 999")
        build = int(number)
    elif kind == "nightly" or name.endswith("-dev"):
        build = 0
    else:
        build = 1000
    return f"{int(major)}.{int(minor)}.{int(patch)}.{build}"


def manifest(browser: str, version_name: str, *, store: bool = False, host_permissions: list[str] | None = None) -> dict:
    if browser not in BROWSERS:
        raise BuildError(f"unknown browser {browser!r}")
    host = native_host()
    data: dict = {
        "manifest_version": 3,
        "name": "__MSG_extName__",
        "short_name": "__MSG_extShortName__",
        "description": "__MSG_extDescription__",
        "default_locale": "en",
        "version": manifest_version(version_name),
        "homepage_url": "https://roundrobin.in/bridgey",
        "icons": {size: f"icons/icon-{size}.png" for size in ("16", "32", "48", "128")},
        "action": {
            "default_title": "__MSG_actionTitle__",
            "default_popup": "popup.html",
            "default_icon": {size: f"icons/icon-{size}.png" for size in ("16", "32")},
        },
        # activeTab: the page's address only when the person clicks the button, a menu item or the shortcut.
        "permissions": ["nativeMessaging", "contextMenus", "activeTab", "storage"],
        "commands": {
            "_execute_action": {"suggested_key": {"default": "Alt+Shift+B"}},
            "send-page": {"suggested_key": {"default": "Alt+Shift+S"}, "description": "__MSG_commandSendPage__"},
        },
    }
    if host_permissions:
        data["host_permissions"] = list(host_permissions)
    if browser == "firefox":
        data["background"] = {"scripts": ["lib.js", "background.js"]}
        data["browser_specific_settings"] = {
            "gecko": {
                "id": host["firefoxExtensionIds"][0],
                "strict_min_version": FIREFOX_MIN,
                # Nothing leaves this computer except to the Bridgey app (addons.mozilla.org asks every add-on).
                "data_collection_permissions": {"required": ["none"]},
            }
        }
    else:
        data["background"] = {"service_worker": "background.js"}
        data["minimum_chrome_version"] = CHROME_MIN
        data["version_name"] = version_name
        if not store:
            data["key"] = host["chromiumPublicKey"]
    return data


def files(browser: str, version_name: str, *, store: bool, host_permissions: list[str] | None) -> dict[str, bytes]:
    """Every file of one browser's package, by its path in the package."""
    out: dict[str, bytes] = {}
    for name in SHARED:
        out[name] = (SOURCE / name).read_bytes()
    for folder in ("_locales", "fonts", "icons"):
        for path in sorted((SOURCE / folder).rglob("*")):
            if path.is_file():
                out[path.relative_to(SOURCE).as_posix()] = path.read_bytes()
    out["LICENSE.txt"] = (REPO / "LICENSE").read_bytes()
    text = json.dumps(manifest(browser, version_name, store=store, host_permissions=host_permissions), indent=2, ensure_ascii=False)
    out["manifest.json"] = (text + "\n").encode("utf-8")
    check(out)
    return out


def check(package: dict[str, bytes]) -> None:
    """Every __MSG_x__ in the manifest and every message key the scripts use exists in each locale; no em dashes."""
    locales = {path.split("/")[1]: json.loads(data) for path, data in package.items() if path.startswith("_locales/")}
    if set(locales) != {"en", "ru"}:
        raise BuildError(f"locales must be en and ru, found {sorted(locales)}")
    keys = set(locales["en"])
    for code, messages in locales.items():
        if set(messages) != keys:
            raise BuildError(f"_locales/{code} differs from en: {sorted(set(messages) ^ keys)}")
    used = set(re.findall(r"__MSG_(\w+)__", package["manifest.json"].decode()))
    for name in ("popup.js", "background.js", "popup.html"):
        text = package[name].decode()
        used |= set(re.findall(r"""\bt\(\s*'(\w+)'""", text)) | set(re.findall(r'data-i18n="(\w+)"', text))
    missing = used - keys
    if missing:
        raise BuildError(f"message keys used but not defined: {sorted(missing)}")
    for path, data in package.items():
        if path.endswith((".js", ".json", ".html", ".css")) and "\u2014" in data.decode("utf-8"):
            raise BuildError(f"{path} contains an em dash")


def write_zip(path: Path, package: dict[str, bytes]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in sorted(package):
            info = zipfile.ZipInfo(name, date_time=ZIP_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            info.create_system = 3
            archive.writestr(info, package[name])


def write_folder(folder: Path, package: dict[str, bytes]) -> None:
    for name, data in package.items():
        target = folder / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)


def asset_name(prefix: str, version_name: str, browser: str, store: bool = False) -> str:
    return f"{prefix}-{version_name}-{LABELS[browser]}{'-store' if store else ''}.zip"


def build(version_name: str, out: Path, *, browsers=BROWSERS, store: bool = False, unpacked: Path | None = None,
          host_permissions: list[str] | None = None) -> list[Path]:
    prefix = properties()["EDITION_ASSET_PREFIX"]
    written = []
    for browser in browsers:
        if store and browser == "firefox":
            # addons.mozilla.org takes the same package as the release asset.
            continue
        package = files(browser, version_name, store=store, host_permissions=host_permissions)
        path = out / asset_name(prefix, version_name, browser, store)
        write_zip(path, package)
        written.append(path)
        if unpacked is not None:
            write_folder(unpacked / browser, package)
    return written


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--version", help="version name (default: EDITION_NEXT_VERSION-dev)")
    parser.add_argument("--out", required=True)
    parser.add_argument("--browsers", default=",".join(BROWSERS))
    parser.add_argument("--store", action="store_true")
    parser.add_argument("--unpacked")
    parser.add_argument("--test-host-permission", action="append", default=[])
    args = parser.parse_args(argv)
    version = args.version or properties()["EDITION_NEXT_VERSION"] + "-dev"
    browsers = tuple(b.strip() for b in args.browsers.split(",") if b.strip())
    try:
        for browser in browsers:
            if browser not in BROWSERS:
                raise BuildError(f"unknown browser {browser!r}")
        paths = build(version, Path(args.out), browsers=browsers, store=args.store,
                      unpacked=Path(args.unpacked) if args.unpacked else None, host_permissions=args.test_host_permission or None)
    except BuildError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    for path in paths:
        print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
