"""Tests for scripts/rr/obtainium.py (Obtainium links for the README and website).
Run: python3 -m unittest discover -s scripts/rr/tests
"""

import json
import re
import sys
import unittest
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

RR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RR))

import obtainium  # noqa: E402

PROPS = {
    "EDITION_APP_ID": "in.roundrobin.bridgey",
    "EDITION_DISPLAY_NAME": "Bridgey by Round Robin",
    "GITHUB_REPO": "round-robin-solutions/bridgey",
}
# Release titles as publish.sh writes them: "<display name> <version>".
TITLES = {
    "stable": "Bridgey by Round Robin 0.6.0-rr.1",
    "beta": "Bridgey by Round Robin 0.6.0-rr.1-beta.13",
    "nightly": "Bridgey by Round Robin 0.6.0-rr.1-nightly.20261025",
    "models": "Bridgey code model (on-device)",
    "channels": "Update channels",
}


def decode(link: str) -> dict:
    assert link.startswith("obtainium://app/")
    return json.loads(unquote(link[len("obtainium://app/"):]))


class LinkTests(unittest.TestCase):
    def test_keys_and_values(self):
        config = decode(obtainium.deep_link("stable", PROPS))
        self.assertEqual(list(config), ["id", "url", "author", "name", "additionalSettings"])
        self.assertEqual(config["id"], "in.roundrobin.bridgey")
        self.assertEqual(config["url"], "https://github.com/round-robin-solutions/bridgey")
        self.assertEqual(config["author"], "Round Robin")
        self.assertEqual(config["name"], "Bridgey by Round Robin")

    def test_additional_settings_is_a_json_string(self):
        for channel, include in (("stable", False), ("beta", True), ("nightly", True)):
            settings = decode(obtainium.deep_link(channel, PROPS))["additionalSettings"]
            self.assertIsInstance(settings, str)
            self.assertEqual(json.loads(settings)["includePrereleases"], include)
        self.assertEqual(decode(obtainium.deep_link("stable", PROPS))["additionalSettings"], '{"includePrereleases":false}')

    def test_encoding_matches_dart_encode_component(self):
        link = obtainium.deep_link("beta", PROPS)
        self.assertRegex(link, r"^obtainium://app/[A-Za-z0-9\-_.!~*'()%]+$")
        self.assertNotIn(" ", link)
        self.assertIn("%20", link)  # spaces as %20, not +

    def test_unknown_channel(self):
        with self.assertRaises(ValueError):
            obtainium.deep_link("alpha", PROPS)

    def test_real_properties_file_is_used_by_default(self):
        config = decode(obtainium.deep_link("stable"))
        self.assertEqual(config["id"], obtainium.load_properties()["EDITION_APP_ID"])


class FilterTests(unittest.TestCase):
    def matching(self, channel: str) -> set:
        settings = json.loads(decode(obtainium.deep_link(channel, PROPS))["additionalSettings"])
        pattern = re.compile(settings["filterReleaseTitlesByRegEx"])
        return {name for name, title in TITLES.items() if pattern.search(title)}

    def test_beta_takes_stable_and_beta(self):
        self.assertEqual(self.matching("beta"), {"stable", "beta"})

    def test_nightly_takes_every_build_but_nothing_else(self):
        self.assertEqual(self.matching("nightly"), {"stable", "beta", "nightly"})

    def test_stable_has_no_title_filter_and_excludes_prereleases(self):
        settings = json.loads(decode(obtainium.deep_link("stable", PROPS))["additionalSettings"])
        self.assertEqual(settings, {"includePrereleases": False})

    def test_filters_need_no_backslashes(self):
        # Keeps the doubly nested JSON readable and easy to match in the Android app.
        for channel in ("beta", "nightly"):
            self.assertNotIn("\\", obtainium.ADDITIONAL_SETTINGS[channel]["filterReleaseTitlesByRegEx"])


class WebLinkTests(unittest.TestCase):
    def test_redirect_carries_exactly_the_deep_link(self):
        for channel in obtainium.CHANNELS:
            url = obtainium.web_link(channel, PROPS)
            parsed = urlparse(url)
            self.assertEqual(f"{parsed.scheme}://{parsed.netloc}{parsed.path}", "https://apps.obtainium.imranr.dev/redirect")
            self.assertEqual(parse_qs(parsed.query)["r"], [obtainium.deep_link(channel, PROPS)])


class RenderTests(unittest.TestCase):
    def test_formats(self):
        self.assertRegex(obtainium.render("markdown", props=PROPS), r"^\[Stable\]\(https://apps\.obtainium\.imranr\.dev/redirect\?r=[^)\s]+\) \| \[Beta\]\(")
        self.assertIn('class="text-link" href="https://apps.obtainium.imranr.dev/redirect?r=', obtainium.render("html", props=PROPS))
        self.assertEqual(obtainium.render("plain", ("beta",), PROPS).split(": ", 1)[0], "Beta")
        with self.assertRaises(ValueError):
            obtainium.render("pdf", props=PROPS)

    def test_update_replaces_blocks_and_is_idempotent(self):
        text = "before\n<!-- obtainium:start markdown -->\nstale\n<!-- obtainium:end -->\nafter\n"
        once = obtainium.update_text(text, PROPS)
        self.assertNotIn("stale", once)
        self.assertTrue(once.startswith("before\n<!-- obtainium:start markdown -->\n[Stable]("))
        self.assertTrue(once.endswith("<!-- obtainium:end -->\nafter\n"))
        self.assertEqual(obtainium.update_text(once, PROPS), once)

    def test_links_in_the_repository_are_current(self):
        root = RR.parents[1]
        for name in ("README.md", "website/index.html", "docs/user-guide.md"):
            text = (root / name).read_text(encoding="utf-8")
            if obtainium.BLOCK.search(text):
                self.assertEqual(obtainium.update_text(text), text, f"{name} has stale Obtainium links; run scripts/rr/obtainium.py update {name}")


if __name__ == "__main__":
    unittest.main()
