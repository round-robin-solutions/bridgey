#!/usr/bin/env python3
"""Russian strings for the iOS app: every user-facing string has a translation.

  ios-l10n.py export <dir>            xcodebuild -exportLocalizations for ru into <dir> (on a Mac)
  ios-l10n.py check <xliff>           fails listing strings without a Russian translation
  ios-l10n.py missing <xliff> <json>  writes the untranslated sources to <json> as {"source": ""}, to fill in
  ios-l10n.py fill <xliff> <json>     puts the translations from <json> into the XLIFF (then import it with
                                      xcodebuild -importLocalizations, which writes the String Catalogs)
  ios-l10n.py merge <a> <b> <out>     unions two String Catalogs (for restacking branches that both added strings)

The catalogs are ios/Shared/Resources/Localizable.xcstrings and ios/Config/InfoPlist.xcstrings, written by Xcode.
scripts/rr/build-ios.sh runs export and check, so a string added without its Russian fails the ios lane.
"""
import json
import os
import subprocess
import sys
import xml.etree.ElementTree as ET

NS = {"x": "urn:oasis:names:tc:xliff:document:1.2"}
ET.register_namespace("", NS["x"])
# Names and symbols that stay as they are.
UNCHANGED = {"Bridgey", "Bridgey by Round Robin", "Bridgey Share", "roundrobin.in/bridgey", "%@", "%lld", "·", "%@ · %@"}


def units(xliff):
    tree = ET.parse(xliff)
    for f in tree.getroot().findall("x:file", NS):
        for u in f.iter(f"{{{NS['x']}}}trans-unit"):
            if u.get("translate") == "no":
                continue
            yield tree, f, u


def source(u):
    s = u.find("x:source", NS)
    return "" if s is None or s.text is None else s.text


def target(u):
    t = u.find("x:target", NS)
    return None if t is None else t.text


def needs(u):
    src = source(u)
    if not src.strip() or src in UNCHANGED:
        return False
    t = target(u)
    return not t or not t.strip()


def export(out):
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    subprocess.run(["xcodebuild", "-exportLocalizations", "-project", os.path.join(root, "ios", "Bridgey.xcodeproj"),
                    "-localizationPath", out, "-exportLanguage", "ru", "-sdk", "iphonesimulator"], check=True)
    print(os.path.join(out, "ru.xcloc", "Localized Contents", "ru.xliff"))


def check(xliff):
    missing = sorted({source(u) for _, _, u in units(xliff) if needs(u)})
    if missing:
        print(f"{len(missing)} strings have no Russian translation:", file=sys.stderr)
        for m in missing:
            print(f"  {m!r}", file=sys.stderr)
        sys.exit(1)
    print(f"Russian: every string translated ({sum(1 for _ in units(xliff))} units)")


def missing(xliff, out):
    todo = {source(u): "" for _, _, u in units(xliff) if needs(u)}
    json.dump(todo, open(out, "w"), ensure_ascii=False, indent=1, sort_keys=True)
    print(f"{len(todo)} to translate in {out}")


def fill(xliff, table):
    tr = json.load(open(table))
    tree = None
    done = 0
    for tree, _, u in units(xliff):
        src = source(u)
        if src in tr and tr[src]:
            t = u.find("x:target", NS)
            if t is None:
                t = ET.SubElement(u, f"{{{NS['x']}}}target")
            t.text = tr[src]
            t.set("state", "translated")
            done += 1
    if tree is not None:
        tree.write(xliff, encoding="UTF-8", xml_declaration=True)
    print(f"filled {done} units")


def merge(a, b, out):
    ca, cb = json.load(open(a)), json.load(open(b))
    strings = dict(ca.get("strings", {}))
    for k, v in cb.get("strings", {}).items():
        if k not in strings:
            strings[k] = v
            continue
        # Both have it: keep every language either has.
        locs = dict(strings[k].get("localizations", {}))
        locs.update({lang: val for lang, val in v.get("localizations", {}).items() if lang not in locs})
        merged = dict(strings[k])
        if locs:
            merged["localizations"] = locs
        strings[k] = merged
    ca["strings"] = dict(sorted(strings.items()))
    with open(out, "w") as f:
        json.dump(ca, f, ensure_ascii=False, indent=2, separators=(",", " : "))
        f.write("\n")


if __name__ == "__main__":
    cmd, args = sys.argv[1], sys.argv[2:]
    {"export": export, "check": check, "missing": missing, "fill": fill, "merge": merge}[cmd](*args)
