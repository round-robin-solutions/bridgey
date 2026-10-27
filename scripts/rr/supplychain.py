#!/usr/bin/env python3
"""Supply chain files for a Bridgey by Round Robin release: CycloneDX 1.5 SBOMs and a provenance statement.

Android: parsed from `./gradlew :app:dependencies --configuration releaseRuntimeClasspath` output, so the
build itself is untouched (no plugin, no lockfile). macOS: parsed from macos/Package.resolved, the binary
targets in macos/Package.swift and the vendored BLAKE3 source note. The vendored BLAKE3 C code is listed
for both apps. Provenance is an unsigned in-toto statement with a SLSA v1 shaped predicate.

rrrelease.py assemble calls this module; the CLI here is for running a single piece by hand:
  supplychain.py android --deps FILE --version V --out FILE
  supplychain.py macos --version V --out FILE
Standard library only.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import platform
import re
import socket
import subprocess
import sys
import uuid
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
TOOL_NAME = "bridgey-rr-supplychain"
BUILD_TYPE = "https://github.com/round-robin-solutions/bridgey/blob/rr/main/docs/rr-edition.md#releases"
UNKNOWN = "unknown"

GRADLE_LINE = re.compile(r"^(?P<prefix>(?:[| ] {4})*)[+\\]--- (?P<body>.+)$")
GRADLE_FLAG = re.compile(r"\s+(?:\((?P<mark>[*cn])\)|(?P<failed>FAILED))$")
BLAKE3_RELEASE = re.compile(r"release (?P<version>\S+) \(commit (?P<commit>[0-9a-f]{40})\)")
BLAKE3_URL = re.compile(r"https://github\.com/(?P<owner>[^/\s]+)/(?P<repo>[^/\s,]+)")
BLAKE3_LICENCE = re.compile(r"^Licen[cs]e:\s*(?P<text>.+?)\s*\(see", re.MULTILINE)
BINARY_TARGET = re.compile(
    r'\.binaryTarget\(\s*name:\s*"(?P<name>[^"]+)",\s*url:\s*"(?P<url>[^"]+)",\s*checksum:\s*"(?P<sum>[0-9a-fA-F]{64})"'
)
GITHUB_RELEASE_URL = re.compile(r"^https://github\.com/(?P<owner>[^/]+)/(?P<repo>[^/]+)/releases/download/(?P<tag>[^/]+)/")


class SupplyChainError(Exception):
    pass


# ---------------------------------------------------------------- Android dependencies


def parse_gradle_dependencies(text: str) -> tuple[dict[tuple[str, str, str], None], dict[str, set[str]]]:
    """Return (resolved Maven modules, edges). Edges map a parent key to child keys; the key "" is the app.

    Constraint lines (c) are skipped, project dependencies are transparent (their children hang off
    the app), and `a:b:1 -> 2` or `a:b:1 -> c:d:2` take the resolved coordinates."""
    modules: dict[tuple[str, str, str], None] = {}
    edges: dict[str, set[str]] = {"": set()}
    stack: dict[int, str] = {}
    for line in text.splitlines():
        match = GRADLE_LINE.match(line)
        if not match:
            continue
        depth = len(match.group("prefix")) // 5
        body = match.group("body").strip()
        marks: set[str] = set()
        while True:
            flag = GRADLE_FLAG.search(body)
            if not flag:
                break
            marks.add(flag.group("mark") or "FAILED")
            body = body[: flag.start()]
        if marks & {"c", "n", "FAILED"}:
            continue
        parent = stack.get(depth - 1, "") if depth else ""
        if body.startswith("project "):
            stack[depth] = ""
            continue
        left, _, right = body.partition(" -> ")
        parts = left.split(":", 2)
        if len(parts) < 2:
            continue
        group, name = parts[0], parts[1]
        version = parts[2].replace("{", "").replace("}", "").split()[-1] if len(parts) == 3 and parts[2].strip("{} ") else ""
        right = right.strip()
        if right:
            if ":" in right:
                target = right.split(":", 2)
                group, name = target[0], target[1]
                version = target[2] if len(target) == 3 else version
            else:
                version = right
        if not version:
            raise SupplyChainError(f"no resolved version for {group}:{name} in the Gradle output")
        key = f"{group}:{name}:{version}"
        modules[(group, name, version)] = None
        stack[depth] = key
        edges.setdefault(parent, set()).add(key)
        edges.setdefault(key, set())
    if not modules:
        raise SupplyChainError("no dependencies found in the Gradle output")
    return modules, edges


def maven_purl(group: str, name: str, version: str) -> str:
    return f"pkg:maven/{group}/{name}@{version}"


# ---------------------------------------------------------------- vendored and SwiftPM components


def parse_blake3_note(text: str) -> dict:
    release = BLAKE3_RELEASE.search(text)
    if not release:
        raise SupplyChainError("BLAKE3_SOURCE.txt has no release and commit line")
    url = BLAKE3_URL.search(text)
    owner, repo = (url.group("owner"), url.group("repo")) if url else ("BLAKE3-team", "BLAKE3")
    licence = BLAKE3_LICENCE.search(text)
    return {
        "version": release.group("version"),
        "commit": release.group("commit"),
        "owner": owner,
        "repo": repo,
        "licence": re.sub(r"\s+or\s+", " OR ", licence.group("text")) if licence else None,
    }


def blake3_component(note: dict) -> dict:
    purl = f"pkg:github/{note['owner']}/{note['repo']}@{note['version']}"
    component = {
        "type": "library",
        "bom-ref": purl,
        "name": note["repo"],
        "version": note["version"],
        "description": "Official BLAKE3 C implementation, vendored unmodified (directory c/)",
        "purl": purl,
        "pedigree": {"commits": [{"uid": note["commit"]}]},
        "externalReferences": [{"type": "vcs", "url": f"https://github.com/{note['owner']}/{note['repo']}"}],
    }
    if note["licence"]:
        component["licenses"] = [{"expression": note["licence"]}]
    return component


def swift_purl(location: str, version: str) -> tuple[str, str, str]:
    """Return (purl, group, name) for a SwiftPM pin location (https or scp-style git URL)."""
    loc = location.strip()
    scp = re.match(r"^[\w.+-]+@([^:/]+):(.+)$", loc)
    if scp:
        path = f"{scp.group(1)}/{scp.group(2)}"
    else:
        path = re.sub(r"^[^@/]+@", "", re.sub(r"^[a-z+]+://", "", loc))
    path = path.rstrip("/")
    if path.endswith(".git"):
        path = path[:-4]
    group, _, name = path.rpartition("/")
    return f"pkg:swift/{path}@{version}", group, name


def parse_package_resolved(data: dict) -> list[dict]:
    """SwiftPM pins (Package.resolved versions 1, 2 and 3) as CycloneDX components."""
    if data.get("version") == 1:
        pins = [
            {"location": pin.get("repositoryURL", ""), "state": pin.get("state", {})}
            for pin in data.get("object", {}).get("pins", [])
        ]
    else:
        pins = [{"location": pin.get("location", ""), "state": pin.get("state", {})} for pin in data.get("pins", [])]
    components = []
    for pin in pins:
        state = pin["state"]
        revision = state.get("revision", "")
        version = state.get("version") or revision
        if not pin["location"] or not version:
            raise SupplyChainError("Package.resolved has a pin without a location or version")
        purl, group, name = swift_purl(pin["location"], version)
        component = {
            "type": "library",
            "bom-ref": purl,
            "group": group,
            "name": name,
            "version": version,
            "purl": purl,
            "externalReferences": [{"type": "vcs", "url": pin["location"]}],
        }
        if revision:
            component["pedigree"] = {"commits": [{"uid": revision}]}
        components.append(component)
    return components


def parse_binary_targets(package_swift: str) -> list[dict]:
    """Binary targets in Package.swift (url plus SHA-256 checksum of the archive) as components."""
    components = []
    for match in BINARY_TARGET.finditer(package_swift):
        url, checksum = match.group("url"), match.group("sum").lower()
        release = GITHUB_RELEASE_URL.match(url)
        if release:
            purl = f"pkg:github/{release.group('owner')}/{release.group('repo')}@{release.group('tag')}"
            name, version = release.group("repo"), release.group("tag")
        else:
            name, version = match.group("name"), UNKNOWN
            purl = f"pkg:generic/{name}@{version}?download_url={url}"
        components.append(
            {
                "type": "framework",
                "bom-ref": purl,
                "name": name,
                "version": version,
                "description": f"SwiftPM binary target {match.group('name')}",
                "purl": purl,
                "hashes": [{"alg": "SHA-256", "content": checksum}],
                "externalReferences": [{"type": "distribution", "url": url, "hashes": [{"alg": "SHA-256", "content": checksum}]}],
            }
        )
    return components


# ---------------------------------------------------------------- SBOM documents


def serial_number(app_id: str, platform_name: str, version: str, build: str) -> str:
    return "urn:uuid:" + str(uuid.uuid5(uuid.NAMESPACE_URL, f"{app_id}/{platform_name}/{version}/{build}"))


def make_bom(
    *,
    app_name: str,
    app_id: str,
    platform_name: str,
    version: str,
    build: str,
    timestamp: str,
    components: list[dict],
    direct: list[str],
    graph: dict[str, list[str]] | None = None,
) -> dict:
    root_ref = f"pkg:generic/{app_id}@{version}?platform={platform_name}"
    refs = {component["bom-ref"] for component in components}
    graph = graph or {}
    dependencies = [{"ref": root_ref, "dependsOn": sorted(set(direct) & refs)}]
    for component in sorted(components, key=lambda c: c["bom-ref"]):
        ref = component["bom-ref"]
        dependencies.append({"ref": ref, "dependsOn": sorted(set(graph.get(ref, [])) & refs - {ref})})
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "serialNumber": serial_number(app_id, platform_name, version, build),
        "version": 1,
        "metadata": {
            "timestamp": timestamp,
            "tools": {"components": [{"type": "application", "name": TOOL_NAME, "author": "Round Robin"}]},
            "component": {
                "type": "application",
                "bom-ref": root_ref,
                "name": f"{app_name} ({'Android' if platform_name == 'android' else 'macOS'})",
                "version": version,
                "purl": root_ref,
                "properties": [{"name": "bridgey:build", "value": str(build)}],
            },
        },
        "components": sorted(components, key=lambda c: c["bom-ref"]),
        "dependencies": dependencies,
    }


def android_sbom(
    deps_text: str, blake3_text: str, *, app_name: str, app_id: str, version: str, build: str, timestamp: str
) -> dict:
    modules, edges = parse_gradle_dependencies(deps_text)
    components = []
    graph: dict[str, list[str]] = {}
    ref_of = {f"{g}:{n}:{v}": maven_purl(g, n, v) for g, n, v in modules}
    for group, name, ver in modules:
        purl = maven_purl(group, name, ver)
        components.append({"type": "library", "bom-ref": purl, "group": group, "name": name, "version": ver, "purl": purl})
    for parent, children in edges.items():
        if parent:
            graph[ref_of[parent]] = [ref_of[child] for child in children]
    direct = [ref_of[child] for child in edges[""]]
    blake3 = blake3_component(parse_blake3_note(blake3_text))
    components.append(blake3)
    direct.append(blake3["bom-ref"])
    return make_bom(
        app_name=app_name, app_id=app_id, platform_name="android", version=version, build=build,
        timestamp=timestamp, components=components, direct=direct, graph=graph,
    )


def macos_sbom(
    resolved: dict, package_swift: str, blake3_text: str, *, app_name: str, app_id: str, version: str, build: str, timestamp: str
) -> dict:
    components = parse_package_resolved(resolved) + parse_binary_targets(package_swift)
    components.append(blake3_component(parse_blake3_note(blake3_text)))
    return make_bom(
        app_name=app_name, app_id=app_id, platform_name="macos", version=version, build=build,
        timestamp=timestamp, components=components, direct=[c["bom-ref"] for c in components],
    )


def dump_json(document: dict) -> bytes:
    return (json.dumps(document, indent=2, sort_keys=False) + "\n").encode("utf-8")


# ---------------------------------------------------------------- provenance


def run_text(argv: list[str], cwd: Path | None = None) -> str | None:
    try:
        result = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    return (result.stdout or result.stderr).strip() if result.returncode == 0 else None


def git_info(root: Path) -> dict:
    """Commit, describe and dirty flag from read-only git commands; "unknown" outside a checkout.
    Dirty means tracked files differ from HEAD (untracked files, such as dist/, do not count)."""
    commit = run_text(["git", "-C", str(root), "rev-parse", "HEAD"])
    describe = run_text(["git", "-C", str(root), "describe", "--tags", "--always"])
    status = run_text(["git", "-C", str(root), "status", "--porcelain", "--untracked-files=no"])
    return {
        "commit": commit or UNKNOWN,
        "describe": describe or UNKNOWN,
        "dirty": (status != "") if status is not None else UNKNOWN,
    }


def read_build_info(path: Path | None) -> dict[str, str]:
    """key=value lines written by build-android.sh and build-macos.sh next to their artifacts."""
    info: dict[str, str] = {}
    if path and path.is_file():
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                info[key.strip()] = value.strip()
    return info


def android_toolchain(root: Path, info: dict[str, str]) -> dict[str, str]:
    """Gradle, AGP and Kotlin come from the repository files; Java from the build host note, else this host."""
    wrapper = root / "android" / "gradle" / "wrapper" / "gradle-wrapper.properties"
    gradle = UNKNOWN
    if wrapper.is_file():
        found = re.search(r"gradle-([0-9][^/\s]*?)-(?:bin|all)\.zip", wrapper.read_text(encoding="utf-8"))
        gradle = found.group(1) if found else UNKNOWN
    top = root / "android" / "build.gradle.kts"
    text = top.read_text(encoding="utf-8") if top.is_file() else ""
    agp = re.search(r'"com\.android\.application"\)? version "([^"]+)"', text)
    kotlin = re.search(r'"org\.jetbrains\.kotlin\.[a-z.]+"\)? version "([^"]+)"', text)
    java = info.get("java")
    if not java:
        home = os.environ.get("JAVA_HOME")
        java = run_text([f"{home}/bin/java" if home else "java", "-version"])
        java = java.splitlines()[0] if java else UNKNOWN
    return {
        "java": java,
        "gradle": gradle,
        "androidGradlePlugin": agp.group(1) if agp else UNKNOWN,
        "kotlin": kotlin.group(1) if kotlin else UNKNOWN,
    }


def build_record(info: dict[str, str], toolchain: dict[str, str]) -> dict:
    """Where and with what a platform was built. Without a build note, this host stands in."""
    return {
        "host": info.get("host") or socket.gethostname(),
        "os": info.get("os") or platform.platform(),
        "hostSource": "build note" if info.get("host") else "assembly host",
        "toolchain": toolchain,
    }


def build_provenance(
    *,
    app_id: str,
    repo: str,
    channel: str,
    version: str,
    build: int,
    tag: str,
    built_at: str,
    git: dict,
    builds: dict[str, dict],
    assembler: dict[str, str],
    artifacts: dict[str, str],
) -> dict:
    """In-toto statement; `artifacts` maps release file name to sha256."""
    return {
        "_type": "https://in-toto.io/Statement/v1",
        "subject": [{"name": name, "digest": {"sha256": digest}} for name, digest in sorted(artifacts.items())],
        "predicateType": "https://slsa.dev/provenance/v1",
        "predicate": {
            "buildDefinition": {
                "buildType": BUILD_TYPE,
                "externalParameters": {"app": app_id, "channel": channel, "version": version, "buildNumber": build, "tag": tag},
                "internalParameters": {"builds": builds, "dirty": git["dirty"], "describe": git["describe"]},
                "resolvedDependencies": [
                    {"uri": f"git+https://github.com/{repo}", "digest": {"gitCommit": git["commit"]}}
                ],
            },
            "runDetails": {
                "builder": {"id": f"host:{assembler['host']}", "version": {"os": assembler["os"]}},
                "metadata": {"invocationId": tag, "finishedOn": built_at},
            },
        },
        "notes": "Unsigned and self-declared by the release script: it records what was built, it is not a signed attestation.",
    }


def check_provenance(provenance: dict, release_dir: Path, sha256_file) -> list[str]:
    """Every subject must exist in release_dir with the recorded sha256."""
    if provenance.get("_type") != "https://in-toto.io/Statement/v1" or not provenance.get("subject"):
        raise SupplyChainError("provenance is not an in-toto statement with subjects")
    report = []
    for subject in provenance["subject"]:
        local = release_dir / subject["name"]
        if not local.is_file() or sha256_file(local) != subject["digest"]["sha256"]:
            raise SupplyChainError(f"provenance does not match {subject['name']}")
        report.append(f"provenance: {subject['name']} sha256 ok")
    return report


def check_sbom(document: dict, name: str) -> None:
    if document.get("bomFormat") != "CycloneDX" or document.get("specVersion") != "1.5" or not document.get("components"):
        raise SupplyChainError(f"{name} is not a CycloneDX 1.5 SBOM with components")


# ---------------------------------------------------------------- CLI


def main(argv: list[str] | None = None) -> int:
    import rrrelease  # imported late: rrrelease imports this module

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    android = sub.add_parser("android", help="SBOM from Gradle dependency output")
    android.add_argument("--deps", required=True, help="output of ./gradlew :app:dependencies --configuration releaseRuntimeClasspath")
    mac = sub.add_parser("macos", help="SBOM from Package.resolved and Package.swift")
    for each in (android, mac):
        each.add_argument("--version", required=True)
        each.add_argument("--build", default="0")
        each.add_argument("--out", required=True)
        each.add_argument("--root", default=str(REPO_ROOT))
    args = parser.parse_args(argv)
    props = rrrelease.load_properties(Path(args.root) / "rr-edition.properties")
    common = {
        "app_name": props["EDITION_DISPLAY_NAME"],
        "app_id": props["EDITION_APP_ID"],
        "version": args.version,
        "build": args.build,
        "timestamp": rrrelease.iso(dt.datetime.now(dt.timezone.utc)),
    }
    root = Path(args.root)
    try:
        if args.command == "android":
            blake3 = (root / "android/app/src/main/cpp/blake3/BLAKE3_SOURCE.txt").read_text(encoding="utf-8")
            document = android_sbom(Path(args.deps).read_text(encoding="utf-8"), blake3, **common)
        else:
            blake3 = (root / "macos/Sources/CBlake3/BLAKE3_SOURCE.txt").read_text(encoding="utf-8")
            resolved = json.loads((root / "macos/Package.resolved").read_text(encoding="utf-8"))
            document = macos_sbom(resolved, (root / "macos/Package.swift").read_text(encoding="utf-8"), blake3, **common)
    except (SupplyChainError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    Path(args.out).write_bytes(dump_json(document))
    print(f"wrote {args.out} ({len(document['components'])} components)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
