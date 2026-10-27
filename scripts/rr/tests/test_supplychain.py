"""Tests for scripts/rr/supplychain.py and its use by rrrelease.py assemble.
Run: python3 -m unittest discover -s scripts/rr/tests
"""

import json
import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import rrrelease  # noqa: E402
import supplychain  # noqa: E402
from test_rrrelease import ReleaseFixture  # noqa: E402

RR = Path(__file__).resolve().parents[1]
DATA = RR / "testdata" / "supplychain"
COMMON = {"app_name": "Bridgey by Round Robin", "app_id": "in.roundrobin.bridgey", "version": "0.6.0-rr.1", "build": "262981315", "timestamp": "2026-10-25T13:15:00Z"}
PURL = re.compile(r"^pkg:[a-z]+/\S+@\S+$")


def android_bom():
    return supplychain.android_sbom((DATA / "gradle-dependencies.txt").read_text(), (DATA / "BLAKE3_SOURCE.txt").read_text(), **COMMON)


def macos_bom():
    resolved = json.loads((DATA / "macos" / "Package.resolved").read_text())
    return supplychain.macos_sbom(
        resolved, (DATA / "macos" / "Package.swift").read_text(), (DATA / "BLAKE3_SOURCE.txt").read_text(), **COMMON
    )


class GradleParserTests(unittest.TestCase):
    def test_resolved_versions_and_substitutions(self):
        modules, edges = supplychain.parse_gradle_dependencies((DATA / "gradle-dependencies.txt").read_text())
        found = {(g, n): v for g, n, v in modules}
        self.assertEqual(found[("androidx.annotation", "annotation")], "1.9.1")  # 1.8.1 -> 1.9.1
        self.assertEqual(found[("org.jetbrains.kotlin", "kotlin-stdlib")], "2.4.10")  # versionless and 1.7.10 -> 2.4.10
        self.assertEqual(found[("com.example", "new-name")], "2.0")  # a:b:1 -> c:d:2
        self.assertNotIn(("com.example", "old-name"), found)
        self.assertEqual(found[("com.example", "noversion")], "3.1")  # a:b -> 3.1
        self.assertEqual(found[("com.example", "strict")], "1.4")  # {strictly 1.4} -> 1.4

    def test_constraints_are_skipped_and_projects_are_transparent(self):
        modules, edges = supplychain.parse_gradle_dependencies(
            "+--- project ':core:x'\n|    \\--- a.b:c:1.0\n+--- a.b:d:2.0\n|    \\--- a.b:e:3.0 (c)\n\\--- a.b:f:4.0 (*)\n"
        )
        self.assertEqual({n for _, n, _ in modules}, {"c", "d", "f"})
        self.assertEqual(edges[""], {"a.b:c:1.0", "a.b:d:2.0", "a.b:f:4.0"})

    def test_children_hang_off_their_parent(self):
        _, edges = supplychain.parse_gradle_dependencies("+--- a.b:c:1.0\n|    \\--- a.b:d:2.0\n\\--- a.b:e:3.0\n")
        self.assertEqual(edges["a.b:c:1.0"], {"a.b:d:2.0"})
        self.assertEqual(edges["a.b:e:3.0"], set())

    def test_empty_or_unresolved_output_is_an_error(self):
        with self.assertRaises(supplychain.SupplyChainError):
            supplychain.parse_gradle_dependencies("FAILURE: Build failed\n")
        with self.assertRaises(supplychain.SupplyChainError):
            supplychain.parse_gradle_dependencies("+--- a.b:c\n")


class SbomTests(unittest.TestCase):
    def check_cyclonedx(self, bom):
        self.assertEqual((bom["bomFormat"], bom["specVersion"], bom["version"]), ("CycloneDX", "1.5", 1))
        self.assertTrue(re.match(r"^urn:uuid:[0-9a-f-]{36}$", bom["serialNumber"]))
        refs = [component["bom-ref"] for component in bom["components"]]
        self.assertEqual(len(refs), len(set(refs)))
        for component in bom["components"]:
            self.assertRegex(component["purl"], PURL)
            self.assertEqual(component["bom-ref"], component["purl"])
            self.assertTrue(component["name"] and component["version"])
        root = bom["metadata"]["component"]["bom-ref"]
        graph = {entry["ref"]: entry["dependsOn"] for entry in bom["dependencies"]}
        self.assertEqual(set(graph), set(refs) | {root})
        for children in graph.values():
            self.assertTrue(set(children) <= set(refs))
        return refs, graph, root

    def test_android_sbom(self):
        refs, graph, root = self.check_cyclonedx(android_bom())
        self.assertIn("pkg:maven/org.jetbrains.kotlin/kotlin-stdlib@2.4.10", refs)
        self.assertIn("pkg:maven/androidx.annotation/annotation@1.9.1", refs)
        self.assertIn("pkg:github/BLAKE3-team/BLAKE3@1.8.7", refs)
        self.assertIn("pkg:maven/org.jetbrains.kotlinx/kotlinx-coroutines-android@1.11.0", graph[root])
        self.assertIn("pkg:github/BLAKE3-team/BLAKE3@1.8.7", graph[root])
        self.assertIn("pkg:maven/org.jetbrains.kotlinx/kotlinx-coroutines-core@1.11.0", graph["pkg:maven/org.jetbrains.kotlinx/kotlinx-coroutines-android@1.11.0"])
        self.assertEqual(root, "pkg:generic/in.roundrobin.bridgey@0.6.0-rr.1?platform=android")

    def test_macos_sbom(self):
        bom = macos_bom()
        refs, _, root = self.check_cyclonedx(bom)
        by_ref = {component["bom-ref"]: component for component in bom["components"]}
        sparkle = by_ref["pkg:swift/github.com/sparkle-project/Sparkle@2.10.0"]
        self.assertEqual(sparkle["pedigree"]["commits"][0]["uid"], "eef1a539a373c1f1a320624b1130fc5de7b2e100")
        llama = by_ref["pkg:github/ggml-org/llama.cpp@b11899"]
        self.assertEqual(llama["hashes"], [{"alg": "SHA-256", "content": "500a6b8953d10542514daccccd8261e4522e3275692984aa53a380475ee0e625"}])
        self.assertTrue(llama["externalReferences"][0]["url"].endswith("llama-b11899-xcframework.zip"))
        blake3 = by_ref["pkg:github/BLAKE3-team/BLAKE3@1.8.7"]
        self.assertEqual(blake3["pedigree"]["commits"][0]["uid"], "f3149ec5bb5449af877ba20377a11008ff499fa2")
        self.assertEqual(blake3["licenses"], [{"expression": "CC0-1.0 OR Apache-2.0"}])
        self.assertEqual(len(refs), 3)
        self.assertEqual(root, "pkg:generic/in.roundrobin.bridgey@0.6.0-rr.1?platform=macos")

    def test_sbom_is_deterministic(self):
        self.assertEqual(supplychain.dump_json(android_bom()), supplychain.dump_json(android_bom()))
        self.assertEqual(supplychain.dump_json(macos_bom()), supplychain.dump_json(macos_bom()))

    def test_package_resolved_versions_and_scp_urls(self):
        v1 = {"version": 1, "object": {"pins": [{"package": "X", "repositoryURL": "git@github.com:o/x.git", "state": {"branch": None, "revision": "ab" * 20, "version": "1.2.3"}}]}}
        component = supplychain.parse_package_resolved(v1)[0]
        self.assertEqual(component["purl"], "pkg:swift/github.com/o/x@1.2.3")
        branch = {"version": 3, "pins": [{"identity": "y", "location": "https://example.com/o/y", "state": {"branch": "main", "revision": "cd" * 20}}]}
        self.assertEqual(supplychain.parse_package_resolved(branch)[0]["version"], "cd" * 20)

    def test_repository_files_produce_sboms(self):
        # The real checkout: guards the parsers against format changes in Package.swift and BLAKE3_SOURCE.txt.
        root = rrrelease.REPO_ROOT
        resolved = json.loads((root / "macos" / "Package.resolved").read_text())
        bom = supplychain.macos_sbom(
            resolved, (root / "macos" / "Package.swift").read_text(), (root / "macos/Sources/CBlake3/BLAKE3_SOURCE.txt").read_text(), **COMMON
        )
        names = {component["name"] for component in bom["components"]}
        self.assertTrue({"Sparkle", "llama.cpp", "BLAKE3"} <= names)
        blake3 = (root / "android/app/src/main/cpp/blake3/BLAKE3_SOURCE.txt").read_text()
        self.assertEqual(supplychain.parse_blake3_note(blake3)["version"], supplychain.parse_blake3_note((root / "macos/Sources/CBlake3/BLAKE3_SOURCE.txt").read_text())["version"])


class ProvenanceTests(unittest.TestCase):
    def test_statement_shape(self):
        statement = supplychain.build_provenance(
            app_id="in.roundrobin.bridgey", repo="o/r", channel="beta", version="0.6.0-rr.1-beta.1", build=262981315,
            tag="v0.6.0-rr.1-beta.1", built_at="2026-10-25T13:15:00Z",
            git={"commit": "a" * 40, "describe": "v0.6.0-3-gaaaaaaa", "dirty": False},
            builds={"android": {"host": "h", "toolchain": {"java": "17"}}}, assembler={"host": "rr-dev-1", "os": "Linux"},
            artifacts={"b.zip": "2" * 64, "a.apk": "1" * 64},
        )
        self.assertEqual(statement["_type"], "https://in-toto.io/Statement/v1")
        self.assertEqual([s["name"] for s in statement["subject"]], ["a.apk", "b.zip"])
        self.assertEqual(statement["subject"][0]["digest"], {"sha256": "1" * 64})
        definition = statement["predicate"]["buildDefinition"]
        self.assertEqual(definition["externalParameters"]["channel"], "beta")
        self.assertEqual(definition["externalParameters"]["buildNumber"], 262981315)
        self.assertEqual(definition["resolvedDependencies"][0]["digest"]["gitCommit"], "a" * 40)
        self.assertIs(definition["internalParameters"]["dirty"], False)
        self.assertEqual(statement["predicate"]["runDetails"]["builder"]["id"], "host:rr-dev-1")

    def test_android_toolchain_reads_repository_versions(self):
        toolchain = supplychain.android_toolchain(rrrelease.REPO_ROOT, {"java": "openjdk version \"17.0.1\""})
        self.assertEqual(toolchain["java"], 'openjdk version "17.0.1"')
        for key in ("gradle", "androidGradlePlugin", "kotlin"):
            self.assertRegex(toolchain[key], r"^\d+\.\d+")

    def test_git_info_outside_a_checkout_is_unknown(self):
        with tempfile.TemporaryDirectory() as temp:
            info = supplychain.git_info(Path(temp))
        self.assertEqual(info, {"commit": "unknown", "describe": "unknown", "dirty": "unknown"})

    def test_build_info_file(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "x.build-info"
            path.write_text("host=mac-1\nos=Darwin 24\nswift=Apple Swift version 6.0\n")
            info = supplychain.read_build_info(path)
        record = supplychain.build_record(info, {"swift": info["swift"]})
        self.assertEqual((record["host"], record["hostSource"]), ("mac-1", "build note"))
        self.assertEqual(supplychain.read_build_info(None), {})


class AssembleSupplyChainTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.fixture = ReleaseFixture(self.root)
        self.props = rrrelease.load_properties()
        self.deps = self.root / "deps.txt"
        shutil.copy(DATA / "gradle-dependencies.txt", self.deps)
        self.android_info = self.root / "app-release.apk.build-info"
        self.android_info.write_text("host=ci-android\nos=Linux 6.8\njava=openjdk version \"17.0.12\"\n")
        self.mac_info = self.root / "mac.build-info"
        self.mac_info.write_text("host=mac-1\nos=Darwin 24.1\nswift=Apple Swift version 6.0.2\nxcode=Xcode 16.1\n")

    def tearDown(self):
        self.temp.cleanup()

    def assemble(self, dist, *, apk=True, mac=True, deps=True, version="0.6.0-rr.1-beta.1", tag="v0.6.0-rr.1-beta.1"):
        argv = [
            "assemble", "--channel", "beta", "--version", version, "--build", "262981315", "--tag", tag, "--dist", str(dist),
            "--published", "2026-10-25T13:15:00Z", "--ed-key", str(self.fixture.key_file), "--ed-public-key", self.fixture.public,
            "--android-build-info", str(self.android_info), "--mac-build-info", str(self.mac_info),
        ]
        if apk:
            argv += ["--apk", str(self.fixture.apk)]
            if deps:
                argv += ["--android-deps", str(self.deps)]
        if mac:
            argv += ["--dmg", str(self.fixture.dmg), "--zip", str(self.fixture.zip)]
        self.assertEqual(rrrelease.main(argv), 0)

    def test_release_assets_include_sboms_and_provenance(self):
        dist = self.root / "dist"
        self.assemble(dist)
        names = sorted(path.name for path in (dist / "release").iterdir())
        prefix = "Bridgey-RR-0.6.0-rr.1-beta.1"
        self.assertEqual(
            names,
            sorted([
                f"{prefix}-Android.apk", f"{prefix}-Android.sbom.cdx.json", f"{prefix}-macOS.dmg", f"{prefix}-macOS.sbom.cdx.json",
                f"{prefix}-macOS.zip", f"{prefix}-provenance.json", "SHA256SUMS",
            ]),
        )
        listed = {line.split("  ", 1)[1] for line in (dist / "release" / "SHA256SUMS").read_text().splitlines()}
        self.assertEqual(listed, set(names) - {"SHA256SUMS"})
        report = rrrelease.verify(dist, self.props, self.fixture.public)
        self.assertIn("SHA256SUMS ok", report)
        self.assertIn(f"{prefix}-Android.sbom.cdx.json CycloneDX ok", report)
        self.assertIn(f"provenance: {prefix}-macOS.zip sha256 ok", report)

    def test_provenance_hashes_every_artifact_and_names_the_builders(self):
        dist = self.root / "dist"
        self.assemble(dist)
        release = dist / "release"
        provenance = json.loads((release / "Bridgey-RR-0.6.0-rr.1-beta.1-provenance.json").read_text())
        subjects = {s["name"]: s["digest"]["sha256"] for s in provenance["subject"]}
        self.assertEqual(len(subjects), 5)
        for name, digest in subjects.items():
            self.assertEqual(rrrelease.sha256_file(release / name), digest)
        self.assertEqual(subjects["Bridgey-RR-0.6.0-rr.1-beta.1-Android.apk"], rrrelease.sha256_file(self.fixture.apk))
        parameters = provenance["predicate"]["buildDefinition"]["externalParameters"]
        self.assertEqual((parameters["version"], parameters["buildNumber"], parameters["tag"]), ("0.6.0-rr.1-beta.1", 262981315, "v0.6.0-rr.1-beta.1"))
        builds = provenance["predicate"]["buildDefinition"]["internalParameters"]["builds"]
        self.assertEqual(builds["android"]["host"], "ci-android")
        self.assertEqual(builds["android"]["toolchain"]["java"], 'openjdk version "17.0.12"')
        self.assertEqual(builds["macos"]["toolchain"], {"swift": "Apple Swift version 6.0.2", "xcode": "Xcode 16.1"})
        self.assertEqual(provenance["predicate"]["runDetails"]["metadata"]["finishedOn"], "2026-10-25T13:15:00Z")

    def test_verify_catches_a_tampered_sbom_and_provenance(self):
        dist = self.root / "dist"
        self.assemble(dist)
        sbom = dist / "release" / "Bridgey-RR-0.6.0-rr.1-beta.1-macOS.sbom.cdx.json"
        original = sbom.read_bytes()
        sbom.write_bytes(original.replace(b"2.10.0", b"2.10.1"))
        with self.assertRaises(rrrelease.ReleaseError):
            rrrelease.verify(dist, self.props, self.fixture.public)

    def test_android_only_and_mac_only_releases(self):
        android_dist = self.root / "android"
        self.assemble(android_dist, mac=False)
        names = {path.name for path in (android_dist / "release").iterdir()}
        self.assertTrue(any(n.endswith("-Android.sbom.cdx.json") for n in names))
        self.assertFalse(any(n.endswith("-macOS.sbom.cdx.json") for n in names))
        mac_dist = self.root / "mac"
        self.assemble(mac_dist, apk=False)
        names = {path.name for path in (mac_dist / "release").iterdir()}
        self.assertTrue(any(n.endswith("-macOS.sbom.cdx.json") for n in names))
        self.assertTrue(any(n.endswith("-provenance.json") for n in names))
        self.assertFalse(any("Android" in n for n in names))

    def test_android_sbom_needs_the_dependency_listing(self):
        dist = self.root / "dist"
        self.assemble(dist, deps=False, mac=False)
        names = {path.name for path in (dist / "release").iterdir()}
        self.assertFalse(any(n.endswith("-Android.sbom.cdx.json") for n in names))

    def test_a_bad_dependency_listing_stops_the_release(self):
        self.deps.write_text("FAILURE: Build failed\n")
        argv = ["assemble", "--channel", "beta", "--version", "0.6.0-rr.1-beta.1", "--build", "1", "--tag", "t", "--dist", str(self.root / "bad"),
                "--apk", str(self.fixture.apk), "--android-deps", str(self.deps)]
        self.assertEqual(rrrelease.main(argv), 1)

    def test_publish_uploads_everything_in_the_release_directory(self):
        publish = (RR / "publish.sh").read_text()
        self.assertIn('set -- "$DIST"/release/*', publish)


class ScriptWiringTests(unittest.TestCase):
    def test_release_sh_passes_the_new_inputs(self):
        release = (RR / "release.sh").read_text()
        for flag in ("--android-deps", "--android-build-info", "--mac-build-info"):
            self.assertIn(flag, release)
        self.assertIn("android-deps.sh", release)
        self.assertTrue((RR / "android-deps.sh").is_file())

    def test_no_em_dashes_in_the_new_files(self):
        for path in (RR / "supplychain.py", RR / "android-deps.sh", Path(__file__)):
            self.assertNotIn(chr(0x2014), path.read_text(), path.name)


if __name__ == "__main__":
    unittest.main()
