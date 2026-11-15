#!/usr/bin/env python3
"""Version names of Bridgey by Round Robin, shared by the release scripts.

From 1.0 the edition has its own semver (docs/rr-edition.md, "Versions"):
  1.0.0                     Stable
  1.0.0-beta.2              Beta
  1.0.0-nightly.20261116    Nightly (UTC date; several nightlies a day share it, the build number orders them)
Before 1.0 the names carried the upstream roadmap milestone and a Round Robin count (the "legacy" scheme):
  0.11.0-rr.1, 0.11.0-rr.1-beta.3, 0.10.0-rr.1-nightly.20261108
New releases always use the first form. The legacy form is still read (published feeds, appcast items,
tags and casks from before 1.0) and written in one place only: the feeds' `versionName` and
`shortVersion` fields, which 0.x apps (up to 0.11.0-rr.1 Beta 3) check against the legacy pattern.
See `legacy_name`.

The Android (UpdateLogic.kt) and macOS (UpdateLogic.swift) apps follow the same rules.
Standard library only.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

CHANNELS = ("stable", "beta", "nightly")

CURRENT = {
    "stable": re.compile(r"^\d+\.\d+\.\d+$"),
    "beta": re.compile(r"^\d+\.\d+\.\d+-beta\.\d+$"),
    "nightly": re.compile(r"^\d+\.\d+\.\d+-nightly\.\d{8}$"),
}
LEGACY = {
    "stable": re.compile(r"^\d+\.\d+\.\d+-rr\.\d+$"),
    "beta": re.compile(r"^\d+\.\d+\.\d+-rr\.\d+-beta\.\d+$"),
    "nightly": re.compile(r"^\d+\.\d+\.\d+-rr\.\d+-nightly\.\d{8}$"),
}
NEXT_VERSION = CURRENT["stable"]

_PARTS = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:-rr\.(\d+))?(?:-(beta|nightly)\.(\d+))?$")
_MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")


@dataclass(frozen=True)
class Version:
    major: int
    minor: int
    patch: int
    rr: int | None  # the Round Robin count of a legacy name, None for 1.0 and later
    channel: str
    number: int | None  # beta number or nightly date (YYYYMMDD); None for stable

    @property
    def core(self) -> str:
        return f"{self.major}.{self.minor}.{self.patch}"

    @property
    def legacy(self) -> bool:
        return self.rr is not None


def parse(name: str) -> Version | None:
    """A Stable, Beta or Nightly name in either scheme, else None (dev builds, typos)."""
    match = _PARTS.match(name or "")
    if not match:
        return None
    major, minor, patch, rr, pre, number = match.groups()
    if pre == "nightly" and len(number) != 8:
        return None
    return Version(int(major), int(minor), int(patch), int(rr) if rr else None, pre or "stable", int(number) if number else None)


def channel_of(name: str) -> str | None:
    version = parse(name)
    return version.channel if version else None


def matches_channel(name: str, channel: str, *, legacy: bool = True) -> bool:
    """True when `name` is a version of `channel` in the current scheme (or, with legacy, the 0.x one)."""
    if CURRENT[channel].match(name or ""):
        return True
    return legacy and bool(LEGACY[channel].match(name or ""))


def legacy_name(name: str) -> str:
    """The name 0.x apps accept for a version: `-rr.1` after the numbers (1.0.0-beta.2 -> 1.0.0-rr.1-beta.2).
    0.11.0-rr.1 Beta 3 and older check feed names against the legacy pattern and skip a feed that
    fails, so the feeds keep this form in `versionName` / `shortVersion`. Those apps only show it; they
    order and verify updates by build number. Legacy names come back unchanged."""
    version = parse(name)
    if version is None:
        raise ValueError(f"{name!r} is not a Stable, Beta or Nightly version")
    if version.legacy:
        return name
    suffix = "" if version.channel == "stable" else f"-{version.channel}.{version.number}"
    return f"{version.core}-rr.1{suffix}"


def store_version(name: str) -> str:
    """Plain numbers for Google Play's versionName and the Mac App Store's CFBundleShortVersionString:
    1.0.0-beta.3 -> 1.0.0. The build number stays the store's build (versionCode, CFBundleVersion)."""
    version = parse(name)
    if version is None:
        dev = re.match(r"^(\d+\.\d+\.\d+)(?:-rr\.\d+)?-dev\d*$", name or "")
        if dev:
            return dev.group(1)
        raise ValueError(f"{name!r} is not a version")
    return version.core


def display(name: str) -> str:
    """The short label people see: 1.0.0 -> 1.0, 1.0.1 -> 1.0.1, 1.1.0-beta.2 -> 1.1 Beta 2,
    1.0.0-nightly.20261116 -> 1.0 Nightly 16 Nov. A pre-1.0 name keeps its base: 0.11.0-rr.1 Beta 3.
    Anything else comes back unchanged."""
    version = parse(name)
    if version is None:
        return name
    if version.legacy:
        base = f"{version.core}-rr.{version.rr}"
    else:
        base = f"{version.major}.{version.minor}" if version.patch == 0 else version.core
    if version.channel == "beta":
        return f"{base} Beta {version.number}"
    if version.channel == "nightly":
        day, month = version.number % 100, (version.number // 100) % 100
        if 1 <= month <= 12 and 1 <= day <= 31:
            return f"{base} Nightly {day} {_MONTHS[month - 1]}"
        return f"{base} Nightly {version.number}"
    return base


def sort_key(name: str) -> tuple:
    """Orders versions across both schemes: 0.11.0-rr.1-beta.3 < 1.0.0-beta.1 < 1.0.0-beta.2 < 1.0.0 < 1.0.1-beta.1.
    A pre-release sorts before the Stable it leads to; nightlies sort by date before betas of the same core."""
    version = parse(name)
    if version is None:
        raise ValueError(f"{name!r} is not a Stable, Beta or Nightly version")
    rank = {"nightly": 0, "beta": 1, "stable": 2}[version.channel]
    # The Round Robin count orders releases before 1.0 (0.6.0-rr.1 < 0.6.0-rr.2-beta.1). From 1.0 a legacy name
    # is only the feeds' alias of the real one (1.0.0-rr.1-beta.1 is 1.0.0-beta.1), so the count is ignored.
    rr = (version.rr or 0) if version.major == 0 else 0
    return (version.major, version.minor, version.patch, rr, rank, version.number or 0)


def next_minor(core: str) -> str:
    major, minor, _ = (int(part) for part in core.split("."))
    return f"{major}.{minor + 1}.0"


def next_patch(core: str) -> str:
    major, minor, patch = (int(part) for part in core.split("."))
    return f"{major}.{minor}.{patch + 1}"
