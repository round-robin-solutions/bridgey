#!/usr/bin/env python3
"""Obtainium links for Bridgey by Round Robin, one per update channel.

Obtainium (https://obtainium.imranr.dev) installs and updates Android apps from GitHub releases. A link
of the form obtainium://app/<URL-encoded JSON> adds this app with the right release filters in one tap.
The Android app builds the same links, so keep this file and the app identical: the JSON keys are in
the fixed order id, url, author, name, additionalSettings (a JSON string, compact separators), and the
JSON is percent-encoded like Dart's Uri.encodeComponent (letters, digits and - _ . ! ~ * ' ( ) stay).

GitHub README pages do not link custom schemes, so web pages use the redirect page
https://apps.obtainium.imranr.dev/redirect?r=<the obtainium:// link, percent-encoded>, which opens Obtainium.

Channels follow the in-app rule (docs/rr-edition.md): Stable reads stable releases, Beta reads Stable and
Beta, Nightly reads all three. Obtainium filters a release by its title (falling back to the tag), and our
titles end in the version name, so the title filters below match that ending:
  Stable   includePrereleases false (beta, nightly, "channels" and "models" releases are all pre-releases)
  Beta     includePrereleases true, title ends in -rr.N or -rr.N-beta.N
  Nightly  includePrereleases true, title ends in -rr.N, -rr.N-beta.N or -rr.N-nightly.N

Usage:
  obtainium.py links [--format plain|markdown|html] [--channels stable,beta,nightly]
  obtainium.py update FILE...   rewrite the blocks between "<!-- obtainium:start markdown -->" (or html)
                                and "<!-- obtainium:end -->" in each file
Standard library only.
"""

import argparse
import json
import re
import sys
from pathlib import Path
from urllib.parse import quote

REPO_ROOT = Path(__file__).resolve().parents[2]
PROPERTIES_PATH = REPO_ROOT / "rr-edition.properties"
REDIRECT_BASE = "https://apps.obtainium.imranr.dev/redirect?r="
DART_SAFE = "!*'()"  # plus the letters, digits and - _ . ~ that quote() never encodes

CHANNELS = ("stable", "beta", "nightly")
LABELS = {"stable": "Stable", "beta": "Beta", "nightly": "Nightly"}
# Obtainium's GitHub source settings: includePrereleases, filterReleaseTitlesByRegEx.
ADDITIONAL_SETTINGS = {
    "stable": {"includePrereleases": False},
    "beta": {"includePrereleases": True, "filterReleaseTitlesByRegEx": "-rr[.][0-9]+(-beta[.][0-9]+)?$"},
    "nightly": {"includePrereleases": True, "filterReleaseTitlesByRegEx": "-rr[.][0-9]+(-(beta|nightly)[.][0-9]+)?$"},
}
AUTHOR = "Round Robin"

BLOCK = re.compile(r"(<!-- obtainium:start (markdown|html) -->\n)(.*?)(<!-- obtainium:end -->)", re.DOTALL)


def load_properties(path: Path = PROPERTIES_PATH) -> dict[str, str]:
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip()
    return values


def app_config(channel: str, props: dict[str, str] | None = None) -> dict:
    """The JSON object Obtainium reads from the link."""
    if channel not in CHANNELS:
        raise ValueError(f"unknown channel {channel!r}; use one of {', '.join(CHANNELS)}")
    props = props or load_properties()
    return {
        "id": props["EDITION_APP_ID"],
        "url": f"https://github.com/{props['GITHUB_REPO']}",
        "author": AUTHOR,
        "name": props["EDITION_DISPLAY_NAME"],
        "additionalSettings": json.dumps(ADDITIONAL_SETTINGS[channel], separators=(",", ":")),
    }


def deep_link(channel: str, props: dict[str, str] | None = None) -> str:
    config = json.dumps(app_config(channel, props), separators=(",", ":"), ensure_ascii=False)
    return "obtainium://app/" + quote(config, safe=DART_SAFE)


def web_link(channel: str, props: dict[str, str] | None = None) -> str:
    return REDIRECT_BASE + quote(deep_link(channel, props), safe="")


def render(fmt: str, channels=("stable", "beta"), props: dict[str, str] | None = None) -> str:
    items = [(LABELS[channel], web_link(channel, props)) for channel in channels]
    if fmt == "plain":
        return "\n".join(f"{label}: {url}" for label, url in items)
    if fmt == "markdown":
        return " | ".join(f"[{label}]({url})" for label, url in items)
    if fmt == "html":
        return " ".join(f'<a class="text-link" href="{url.replace("&", "&amp;")}">{label}</a>' for label, url in items)
    raise ValueError(f"unknown format {fmt!r}")


def update_text(text: str, props: dict[str, str] | None = None) -> str:
    """Replace the content of every obtainium block with freshly generated links."""
    return BLOCK.sub(lambda m: f"{m.group(1)}{render(m.group(2), props=props)}\n{m.group(4)}", text)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Obtainium links for Bridgey by Round Robin.")
    sub = parser.add_subparsers(dest="command", required=True)
    links = sub.add_parser("links")
    links.add_argument("--format", choices=("plain", "markdown", "html"), default="plain")
    links.add_argument("--channels", default="stable,beta")
    links.add_argument("--deep", action="store_true", help="print the obtainium:// links instead of the web redirects")
    update = sub.add_parser("update")
    update.add_argument("files", nargs="+")
    args = parser.parse_args(argv)
    try:
        if args.command == "links":
            channels = [c.strip() for c in args.channels.split(",") if c.strip()]
            if args.deep:
                print("\n".join(f"{LABELS[c]}: {deep_link(c)}" for c in channels))
            else:
                print(render(args.format, channels))
            return 0
        for name in args.files:
            path = Path(name)
            text = path.read_text(encoding="utf-8")
            if not BLOCK.search(text):
                print(f"obtainium: no obtainium block in {path}", file=sys.stderr)
                return 1
            path.write_text(update_text(text), encoding="utf-8")
            print(f"updated {path}")
        return 0
    except (ValueError, KeyError, OSError) as error:
        print(f"obtainium: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
