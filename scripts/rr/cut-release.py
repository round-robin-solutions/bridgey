#!/usr/bin/env python3
"""Cut a Bridgey by Round Robin release: tag a beta, or promote a published beta to Stable.

  cut-release.py beta --notes-file notes.md [--commit SHA] [--push]
      Tags the next beta of EDITION_NEXT_VERSION (v1.0.0-beta.N, N one higher than the newest tag) on
      the head of rr/main (or --commit, which must be on rr/main), with the notes as the tag message.

  cut-release.py promote [--from v1.0.0-beta.N] [--notes-file notes.md] [--next minor|patch|X.Y.Z] [--push]
      Stable, only when Rahul says so. Tags v1.0.0 on the exact commit of the newest published beta of
      EDITION_NEXT_VERSION (or --from). RR CI then rebuilds that commit as 1.0.0 with a new build number.
      Then moves EDITION_NEXT_VERSION on rr/main to the next minor version (or --next).

Both add an entry at the top of CHANGELOG.md on rr/main. A beta of the head of rr/main commits the entry first
and tags that commit, so RR CI verifies it once and builds no nightly for it. A promotion tags the beta's own
commit, then commits the entry and the next version on top (that commit starts the next version's nightlies).
Pushing the tag is what starts the release: RR CI runs scripts/rr/ci-release.sh tag, which builds, publishes
and updates the feeds.
Without --push nothing is created: the plan, the tag message and the changelog entry are printed.

Why promotion rebuilds instead of relabelling the beta's files: a build carries its version inside it.
The Android app turns off lab-only parts in a stable build at compile time (isStableBuild in
android/app/build.gradle.kts), and the version people see in About and the Mac's CFBundleShortVersionString
come from the build. A beta's APK and DMG on the Stable channel would keep saying "1.0 Beta 3". The rebuild
is the same source, tagged on the same commit, and its newer build number moves the beta users to 1.0 too.

Needs git with push access to origin, and gh (GH_TOKEN) to check that the beta was published.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import versions  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
BRANCH = "rr/main"
CHANGELOG = "CHANGELOG.md"
PROPERTIES = "rr-edition.properties"
CHANGELOG_HEADER = "# Changelog\n"
MONTHS = ("January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December")


class CutError(Exception):
    pass


def git(*args: str, cwd: Path = REPO_ROOT, check: bool = True) -> str:
    result = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise CutError(f"git {' '.join(args[:2])} failed: {(result.stderr or result.stdout).strip()}")
    return result.stdout.strip()


def properties_at(revision: str, root: Path = REPO_ROOT) -> dict[str, str]:
    text = git("show", f"{revision}:{PROPERTIES}", cwd=root)
    values = {}
    for line in text.splitlines():
        if line and not line.startswith("#") and "=" in line:
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip()
    return values


def remote_tags(root: Path, remote: str) -> dict[str, str]:
    """Tag name -> commit, as the remote has them (peeled)."""
    tags: dict[str, str] = {}
    for line in git("ls-remote", "--tags", remote, cwd=root).splitlines():
        sha, _, ref = line.partition("\t")
        name = ref.removeprefix("refs/tags/")
        if name.endswith("^{}"):
            tags[name[:-3]] = sha
        else:
            tags.setdefault(name, sha)
    return tags


def published_releases(repo: str) -> set[str]:
    """Tags of the fork's published (not draft) releases, read with gh."""
    result = subprocess.run(
        ["gh", "release", "list", "-R", repo, "--limit", "200", "--exclude-drafts", "--json", "tagName"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise CutError(f"gh could not list the releases of {repo}: {result.stderr.strip()}")
    return {item["tagName"] for item in json.loads(result.stdout or "[]")}


def next_beta(next_version: str, tags: dict[str, str]) -> str:
    numbers = [versions.parse(t[1:]).number for t in tags if t.startswith(f"v{next_version}-beta.") and versions.CURRENT["beta"].match(t[1:])]
    return f"{next_version}-beta.{max(numbers, default=0) + 1}"


def newest_beta(next_version: str, tags: dict[str, str], published: set[str]) -> str:
    betas = [t for t in tags if t in published and t.startswith(f"v{next_version}-beta.") and versions.CURRENT["beta"].match(t[1:])]
    if not betas:
        raise CutError(f"no published beta of {next_version} to promote")
    return max(betas, key=lambda t: versions.sort_key(t[1:]))


def resolve_next(current: str, choice: str) -> str:
    if choice == "minor":
        return versions.next_minor(current)
    if choice == "patch":
        return versions.next_patch(current)
    if not versions.NEXT_VERSION.match(choice) or versions.sort_key(choice) <= versions.sort_key(current):
        raise CutError(f"--next {choice!r} must be minor, patch or a version above {current}, like 1.1.0")
    return choice


def long_date(day: dt.date) -> str:
    return f"{day.day} {MONTHS[day.month - 1]} {day.year}"


def notes_body(notes: str) -> str:
    """The notes without a first line that only names the release ("Bridgey by Round Robin 1.0 Beta 2")."""
    lines = notes.strip().splitlines()
    if lines and lines[0].lower().startswith("bridgey"):
        lines = lines[1:]
    return "\n".join(lines).strip()


def changelog_entry(version: str, body: str, day: dt.date) -> str:
    return f"## {versions.display(version)} ({version}), {long_date(day)}\n\n{body.strip()}\n"


def add_entry(text: str, entry: str) -> str:
    """Put `entry` above the newest entry, below the title and the short introduction."""
    if not text.strip():
        text = CHANGELOG_HEADER + "\n"
    index = text.find("\n## ")
    if index < 0:
        return text.rstrip("\n") + "\n\n" + entry
    return text[: index + 1] + entry + "\n" + text[index + 1 :]


def set_next_version(text: str, value: str) -> str:
    new, count = re.subn(r"(?m)^EDITION_NEXT_VERSION=.*$", f"EDITION_NEXT_VERSION={value}", text)
    if count != 1:
        raise CutError(f"{PROPERTIES} must have exactly one EDITION_NEXT_VERSION line")
    return new


def commit_on_branch(root: Path, remote: str, message: str, edit, push: bool, attempts: int = 3) -> str:
    """Apply `edit(worktree)` on a fresh checkout of <remote>/rr/main, commit, and push. Retries when the
    branch moved meanwhile. Returns the new commit. Never touches the caller's working tree."""
    for attempt in range(attempts):
        git("fetch", "--quiet", remote, BRANCH, cwd=root)
        work = Path(tempfile.mkdtemp(prefix="bridgey-cut-"))
        try:
            git("worktree", "add", "--quiet", "--detach", str(work), "FETCH_HEAD", cwd=root)
            edit(work)
            git("add", "-A", cwd=work)
            git("commit", "--quiet", "-m", message, cwd=work)
            sha = git("rev-parse", "HEAD", cwd=work)
            if not push:
                return sha
            result = subprocess.run(["git", "push", "--quiet", remote, f"HEAD:refs/heads/{BRANCH}"], cwd=work, capture_output=True, text=True)
            if result.returncode == 0:
                return sha
            if attempt == attempts - 1:
                raise CutError(f"could not push to {BRANCH}: {result.stderr.strip()}")
        finally:
            subprocess.run(["git", "worktree", "remove", "--force", str(work)], cwd=root, capture_output=True)
            shutil.rmtree(work, ignore_errors=True)
    raise CutError("unreachable")


def push_tag(root: Path, remote: str, tag: str, commit: str, message: str) -> None:
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as handle:
        handle.write(message.strip() + "\n")
        notes_path = handle.name
    try:
        git("tag", "-a", tag, commit, "-F", notes_path, cwd=root)
        result = subprocess.run(["git", "push", "--quiet", remote, f"refs/tags/{tag}"], cwd=root, capture_output=True, text=True)
        if result.returncode != 0:
            git("tag", "-d", tag, cwd=root, check=False)
            raise CutError(f"could not push {tag}: {result.stderr.strip()}")
    finally:
        os.unlink(notes_path)


def cut(args: argparse.Namespace, root: Path = REPO_ROOT, published=published_releases, today: dt.date | None = None) -> dict:
    remote = args.remote
    today = today or dt.datetime.now(dt.timezone.utc).date()
    git("fetch", "--quiet", "--tags", remote, BRANCH, cwd=root)
    head = git("rev-parse", "FETCH_HEAD", cwd=root)
    head_props = properties_at(head, root)
    next_version = head_props["EDITION_NEXT_VERSION"]
    if not versions.NEXT_VERSION.match(next_version):
        raise CutError(f"EDITION_NEXT_VERSION {next_version!r} on {BRANCH} must look like 1.0.0")
    tags = remote_tags(root, remote)
    notes_file = Path(args.notes_file).read_text(encoding="utf-8").strip() if args.notes_file else ""

    if args.command == "beta":
        if not notes_file:
            raise CutError("a beta needs --notes-file: the release notes people read in the app and on GitHub")
        version = next_beta(next_version, tags)
        commit = git("rev-parse", f"{args.commit}^{{commit}}", cwd=root) if args.commit else head
        if subprocess.run(["git", "merge-base", "--is-ancestor", commit, head], cwd=root).returncode != 0:
            raise CutError(f"{commit[:7]} is not on {BRANCH}")
        if properties_at(commit, root)["EDITION_NEXT_VERSION"] != next_version:
            raise CutError(f"{commit[:7]} builds towards another version than {next_version}")
        message = notes_file
        body = notes_body(notes_file)
        next_after = None
    else:
        source = args.source or newest_beta(next_version, tags, published(head_props["GITHUB_REPO"]))
        if source not in tags:
            raise CutError(f"{source} is not a tag on {remote}")
        if args.source and source not in published(head_props["GITHUB_REPO"]):
            raise CutError(f"{source} has no published release; promote only a beta people already have")
        source_version = source[1:]
        if versions.channel_of(source_version) != "beta" or versions.parse(source_version).legacy:
            raise CutError(f"{source} is not a beta of the 1.0 scheme (v1.0.0-beta.N)")
        version = versions.parse(source_version).core
        commit = tags[source]
        if properties_at(commit, root)["EDITION_NEXT_VERSION"] != version:
            raise CutError(f"{source} does not build towards {version}")
        if f"v{version}" in tags:
            raise CutError(f"v{version} already exists")
        beta_label = versions.display(source_version)
        if notes_file:
            message = notes_file
            body = notes_body(notes_file)
        else:
            beta_notes = notes_body(git("tag", "-l", "--format=%(contents)", source, cwd=root))
            body = f"The same code as {beta_label}, now on Stable.\n\n{beta_notes}".strip()
            message = f"Bridgey by Round Robin {versions.display(version)}\n\n{body}"
        next_after = resolve_next(version, args.next)

    tag = f"v{version}"
    if tag in tags:
        raise CutError(f"{tag} already exists")
    entry = changelog_entry(version, body, today)
    # A beta of the head of rr/main tags its own changelog commit: RR CI verifies that commit once and,
    # because it is tagged, builds no nightly for it. A promotion (or a beta of an older commit) tags that
    # commit as it is and adds the changelog commit on top afterwards.
    tags_changelog_commit = args.command == "beta" and commit == head
    plan = {"tag": tag, "commit": commit, "version": version, "message": message, "changelog": entry, "next": next_after,
            "tags_changelog_commit": tags_changelog_commit}

    if not args.push:
        return plan

    def edit(work: Path) -> None:
        path = work / CHANGELOG
        path.write_text(add_entry(path.read_text(encoding="utf-8") if path.is_file() else "", entry), encoding="utf-8")
        if next_after:
            props = work / PROPERTIES
            props.write_text(set_next_version(props.read_text(encoding="utf-8"), next_after), encoding="utf-8")

    subject = f"Changelog: {versions.display(version)}"
    if next_after:
        subject += f"; next version {next_after}"
    if tags_changelog_commit:
        plan["changelog_commit"] = commit_on_branch(root, remote, subject, edit, push=True)
        plan["commit"] = plan["changelog_commit"]
        git("fetch", "--quiet", remote, BRANCH, cwd=root)
        push_tag(root, remote, tag, plan["commit"], message)
    else:
        push_tag(root, remote, tag, commit, message)
        plan["changelog_commit"] = commit_on_branch(root, remote, subject, edit, push=True)
    return plan


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    beta = sub.add_parser("beta", help="tag the next beta")
    beta.add_argument("--notes-file", required=True)
    beta.add_argument("--commit", help="commit on rr/main to release (default: its head)")
    promote = sub.add_parser("promote", help="promote a published beta to Stable (only when Rahul says so)")
    promote.add_argument("--from", dest="source", help="beta tag to promote (default: the newest published beta)")
    promote.add_argument("--notes-file", help="Stable release notes (default: the beta's notes)")
    promote.add_argument("--next", default="minor", help="EDITION_NEXT_VERSION afterwards: minor (default), patch or X.Y.Z")
    for command in (beta, promote):
        command.add_argument("--push", action="store_true", help="create and push the tag and the changelog commit")
        command.add_argument("--remote", default="origin")
    args = parser.parse_args(argv)
    try:
        plan = cut(args)
    except (CutError, OSError, KeyError) as error:
        print(f"cut-release: {error}", file=sys.stderr)
        return 1
    where = "the new changelog commit on top of " + plan["commit"][:7] if plan["tags_changelog_commit"] and not args.push else plan["commit"][:7]
    print(f"{'Pushed' if args.push else 'Would push'} {plan['tag']} at {where} ({versions.display(plan['version'])})")
    if plan["next"]:
        print(f"EDITION_NEXT_VERSION on {BRANCH} afterwards: {plan['next']}")
    print("\nTag message (the release notes):\n" + plan["message"])
    print("\nCHANGELOG.md entry:\n" + plan["changelog"])
    if args.push:
        print(f"Changelog commit {plan['changelog_commit'][:7]} on {BRANCH}. RR CI builds and publishes {plan['tag']} now.")
    else:
        print("Dry run: nothing was created. Add --push to tag and release.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
