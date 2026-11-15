package dev.bridgey.android

import java.io.File
import java.nio.file.Files
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** The build of 0.11.0-rr.1 Beta 3, on every device when the 1.0 versions started. */
private const val BETA3_BUILD = 263_191_654L

class UpdateLogicTest {
    private val appId = "in.roundrobin.bridgey"
    private val prefix = "https://github.com/round-robin-solutions/bridgey/releases/download/"
    private val base = "https://github.com/round-robin-solutions/bridgey/releases/download/channels"

    private fun feed(
        channel: String = "beta",
        versionName: String = "0.6.0-rr.2-beta.1",
        versionCode: Long = 262_981_315,
        url: String = "${prefix}v0.6.0-rr.2-beta.1/Bridgey-RR-0.6.0-rr.2-beta.1-Android.apk",
        sha256: String = "a".repeat(64),
        size: Long = 12_345,
        app: String = appId,
        schema: Int = 1,
        minSdk: Int = 26,
    ): String = JSONObject()
        .put("schema", schema)
        .put("app", app)
        .put("channel", channel)
        .put("version", versionName)
        .put("build", versionCode)
        .put("notesUrl", "https://github.com/round-robin-solutions/bridgey/releases/tag/v$versionName")
        .put("notes", "Fixes")
        .put(
            "android",
            JSONObject()
                .put("versionName", versionName)
                .put("versionCode", versionCode)
                .put("url", url)
                .put("sha256", sha256)
                .put("size", size)
                .put("minSdk", minSdk),
        )
        .toString()

    private fun update(code: Long, channel: UpdateChannel = UpdateChannel.STABLE, minSdk: Int = 26) = AndroidUpdate(
        channel, "0.6.0-rr.1", code, "", "", "${prefix}x.apk", "a".repeat(64), 1, minSdk,
    )

    @Test fun channelsReadTheirOwnFeedAndEveryMoreStableFeed() {
        assertEquals(listOf(UpdateChannel.STABLE), UpdateChannel.STABLE.feedChannels)
        assertEquals(listOf(UpdateChannel.STABLE, UpdateChannel.BETA), UpdateChannel.BETA.feedChannels)
        assertEquals(UpdateChannel.entries.toList(), UpdateChannel.NIGHTLY.feedChannels)
        assertEquals(UpdateChannel.STABLE, UpdateChannel.fromKey(null))
        assertEquals(UpdateChannel.STABLE, UpdateChannel.fromKey("canary"))
        assertEquals(UpdateChannel.NIGHTLY, UpdateChannel.fromKey("nightly"))
    }

    @Test fun feedUrlsUseTheConfiguredHttpsBase() {
        assertEquals("$base/stable.json", UpdateFeeds.feedUrl(base, UpdateChannel.STABLE))
        assertEquals("$base/nightly.json", UpdateFeeds.feedUrl("$base/", UpdateChannel.NIGHTLY))
        assertThrows(IllegalArgumentException::class.java) { UpdateFeeds.feedUrl("http://example.com", UpdateChannel.BETA) }
    }

    @Test fun parsesAValidFeed() {
        val parsed = UpdateFeeds.parseAndroid(feed(), UpdateChannel.BETA, appId, prefix)!!
        assertEquals("0.6.0-rr.2-beta.1", parsed.versionName)
        assertEquals(262_981_315L, parsed.versionCode)
        assertEquals(12_345L, parsed.size)
        assertEquals("Fixes", parsed.notes)
    }

    @Test fun feedWithoutAndroidEntryHasNoUpdate() {
        val json = JSONObject(feed()).apply { remove("android") }.toString()
        assertNull(UpdateFeeds.parseAndroid(json, UpdateChannel.BETA, appId, prefix))
    }

    @Test fun rejectsInvalidFeeds() {
        val invalid = listOf(
            "not json",
            feed(schema = 2),
            feed(app = "dev.bridgey.android"),
            feed(channel = "stable"),
            feed(versionName = "0.6.0-rr.2"),
            feed(versionName = "0.6.0-rr.2-nightly.20261025"),
            feed(url = "https://evil.example/Bridgey.apk"),
            feed(url = "http://github.com/round-robin-solutions/bridgey/releases/download/x.apk"),
            feed(sha256 = "xyz"),
            feed(sha256 = "a".repeat(63)),
            feed(size = 0),
            feed(size = UpdateFeeds.MAX_APK_BYTES + 1),
            feed(versionCode = 0),
            JSONObject(feed()).apply { getJSONObject("android").remove("sha256") }.toString(),
            " ".repeat(UpdateFeeds.MAX_FEED_BYTES + 1),
        )
        invalid.forEach { json ->
            assertThrows(json.take(80), UpdateFeedException::class.java) {
                UpdateFeeds.parseAndroid(json, UpdateChannel.BETA, appId, prefix)
            }
        }
    }

    @Test fun versionNamesMustMatchTheirChannel() {
        assertTrue(UpdateFeeds.versionNameMatchesChannel("0.6.0-rr.1", UpdateChannel.STABLE))
        assertTrue(UpdateFeeds.versionNameMatchesChannel("0.6.0-rr.2-beta.3", UpdateChannel.BETA))
        assertTrue(UpdateFeeds.versionNameMatchesChannel("0.6.0-rr.2-nightly.20261025", UpdateChannel.NIGHTLY))
        assertFalse(UpdateFeeds.versionNameMatchesChannel("0.6.0-rr.2-beta.3", UpdateChannel.STABLE))
        assertFalse(UpdateFeeds.versionNameMatchesChannel("0.6.0-rc.2", UpdateChannel.STABLE))
        assertFalse(UpdateFeeds.versionNameMatchesChannel("0.6.0-rr.2-nightly.2026", UpdateChannel.NIGHTLY))
        // From 1.0 the edition has its own semver; the names from before it stay valid.
        assertTrue(UpdateFeeds.versionNameMatchesChannel("1.0.0", UpdateChannel.STABLE))
        assertTrue(UpdateFeeds.versionNameMatchesChannel("1.0.0-beta.2", UpdateChannel.BETA))
        assertTrue(UpdateFeeds.versionNameMatchesChannel("1.1.0-nightly.20261116", UpdateChannel.NIGHTLY))
        assertFalse(UpdateFeeds.versionNameMatchesChannel("1.0.0-beta.2", UpdateChannel.STABLE))
        assertFalse(UpdateFeeds.versionNameMatchesChannel("1.0.0", UpdateChannel.BETA))
        assertFalse(UpdateFeeds.versionNameMatchesChannel("1.0.0-rc.1", UpdateChannel.STABLE))
        assertFalse(UpdateFeeds.versionNameMatchesChannel("1.0.0-dev", UpdateChannel.STABLE))
    }

    @Test fun neverOffersADowngradeOrTheInstalledBuild() {
        val installed = 262_990_000L
        assertNull(UpdateFeeds.selectUpdate(installed, listOf(update(262_980_000), update(installed)), 34))
        val newer = UpdateFeeds.selectUpdate(installed, listOf(update(262_980_000), update(263_000_000), update(262_995_000)), 34)
        assertEquals(263_000_000L, newer?.versionCode)
    }

    @Test fun switchingFromNightlyToStableWaitsForANewerStableBuild() {
        val installedNightly = 263_011_200L
        val stable = update(263_000_000, UpdateChannel.STABLE)
        assertNull(UpdateFeeds.selectUpdate(installedNightly, listOf(stable), 34))
        val laterStable = update(263_051_200, UpdateChannel.STABLE)
        assertEquals(laterStable, UpdateFeeds.selectUpdate(installedNightly, listOf(stable, laterStable), 34))
    }

    @Test fun skipsBuildsThatNeedANewerAndroid() {
        assertNull(UpdateFeeds.selectUpdate(1, listOf(update(5, minSdk = 35)), 34))
    }

    @Test fun checkIntervalHandlesFirstRunAndClockChanges() {
        val day = UpdateFeeds.CHECK_INTERVAL_MILLIS
        assertTrue(UpdateFeeds.isCheckDue(0, 1_000, day))
        assertFalse(UpdateFeeds.isCheckDue(1_000, 1_000 + day - 1, day))
        assertTrue(UpdateFeeds.isCheckDue(1_000, 1_000 + day, day))
        assertTrue(UpdateFeeds.isCheckDue(10_000, 5_000, day))
    }

    @Test fun sha256CheckDetectsTampering() {
        val file = Files.createTempFile("bridgey-update", ".apk").toFile()
        try {
            file.writeText("abc")
            val abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
            assertTrue(UpdateFeeds.sha256Matches(file, abc))
            assertTrue(UpdateFeeds.sha256Matches(file, abc.uppercase()))
            file.writeText("abd")
            assertFalse(UpdateFeeds.sha256Matches(file, abc))
            assertFalse(UpdateFeeds.sha256Matches(File(file.path + ".missing"), abc))
        } finally {
            file.delete()
        }
    }

    @Test fun signersMustBeIdentical() {
        assertTrue(UpdateFeeds.signersMatch(setOf("aa"), setOf("aa")))
        assertFalse(UpdateFeeds.signersMatch(setOf("aa"), setOf("bb")))
        assertFalse(UpdateFeeds.signersMatch(setOf("aa"), setOf("aa", "bb")))
        assertFalse(UpdateFeeds.signersMatch(emptySet(), emptySet()))
    }

    private fun fixture(name: String): String {
        val repoRoot = File(requireNotNull(System.getProperty("bridgey.repoRoot")))
        return File(repoRoot, "scripts/rr/testdata/feed-sample/$name").readText()
    }

    /** Fixtures written by scripts/rr/rrrelease.py; keep the Python generator and the app parser in step. */
    @Test fun parsesTheCommittedGeneratorFixtures() {
        val expected = mapOf(
            UpdateChannel.STABLE to ("1.0.0" to 263_241_200L),
            UpdateChannel.BETA to ("1.0.0-beta.1" to 263_201_200L),
            UpdateChannel.NIGHTLY to ("1.0.0-nightly.20261116" to 263_200_900L),
        )
        expected.forEach { (channel, version) ->
            val parsed = UpdateFeeds.parseAndroid(fixture("${channel.key}.json"), channel, appId, prefix)!!
            assertEquals(version.first, parsed.versionName)
            assertEquals(version.second, parsed.versionCode)
        }
        // The feed as it was published for 0.11.0-rr.1 Beta 3 (no "version" field) still parses.
        val legacy = UpdateFeeds.parseAndroid(fixture("legacy-0.11-beta.json"), UpdateChannel.BETA, appId, prefix)!!
        assertEquals("0.11.0-rr.1-beta.3", legacy.versionName)
        assertEquals(BETA3_BUILD, legacy.versionCode)
    }

    /**
     * Every device ran 0.11.0-rr.1 Beta 3 when 1.0 started. [Beta3Feeds] is its parser, copied from
     * UpdateLogic.kt at v0.11.0-rr.1-beta.3: it checks `versionName` against the pre-1.0 pattern, skips a
     * feed that fails (AppUpdater.fetchCandidates) and installs the highest versionCode.
     */
    @Test fun aBeta3PhoneSeesAndInstallsThe1_0Releases() {
        val beta3OnBeta = listOf(UpdateChannel.STABLE, UpdateChannel.BETA).mapNotNull { channel ->
            runCatching { Beta3Feeds.parseAndroid(fixture("${channel.key}.json"), channel, appId, prefix) }.getOrNull()
        }
        assertEquals(listOf("1.0.0-rr.1", "1.0.0-rr.1-beta.1"), beta3OnBeta.map { it.first })
        assertEquals(263_241_200L, Beta3Feeds.selectUpdate(BETA3_BUILD, beta3OnBeta.map { it.second }))
        val nightly = Beta3Feeds.parseAndroid(fixture("nightly.json"), UpdateChannel.NIGHTLY, appId, prefix)!!
        assertEquals("1.0.0-rr.1-nightly.20261116" to 263_200_900L, nightly)
        // The plain 1.0 name in versionName would have been skipped: that is why the feeds keep the old form there.
        val plain = JSONObject(fixture("beta.json")).apply { getJSONObject("android").put("versionName", "1.0.0-beta.1") }.toString()
        assertThrows(UpdateFeedException::class.java) { Beta3Feeds.parseAndroid(plain, UpdateChannel.BETA, appId, prefix) }
        // The 1.0 app reads the real name from "version" in the same feed.
        assertEquals("1.0.0-beta.1", UpdateFeeds.parseAndroid(fixture("beta.json"), UpdateChannel.BETA, appId, prefix)!!.versionName)
    }

    private object Beta3Feeds {
        private val versionPattern = Regex("""^\d+\.\d+\.\d+-rr\.\d+(-(beta\.\d+|nightly\.\d{8}))?$""")

        fun versionNameMatchesChannel(versionName: String, channel: UpdateChannel): Boolean {
            if (!versionPattern.matches(versionName)) return false
            return when (channel) {
                UpdateChannel.STABLE -> !versionName.contains("-beta.") && !versionName.contains("-nightly.")
                UpdateChannel.BETA -> versionName.contains("-beta.")
                UpdateChannel.NIGHTLY -> versionName.contains("-nightly.")
            }
        }

        /** (versionName, versionCode) as Beta 3's parseAndroid accepts them. */
        fun parseAndroid(json: String, expectedChannel: UpdateChannel, appId: String, assetUrlPrefix: String): Pair<String, Long>? {
            val root = JSONObject(json)
            if (root.getInt("schema") != 1 || root.getString("app") != appId || root.getString("channel") != expectedChannel.key) {
                throw UpdateFeedException("Wrong feed")
            }
            val android = root.optJSONObject("android") ?: return null
            val versionName = android.getString("versionName")
            if (!versionNameMatchesChannel(versionName, expectedChannel)) throw UpdateFeedException("Version $versionName does not belong to ${expectedChannel.title}")
            val versionCode = android.getLong("versionCode")
            if (versionCode <= 0 || versionCode > Int.MAX_VALUE) throw UpdateFeedException("Invalid version code")
            if (!android.getString("url").startsWith(assetUrlPrefix)) throw UpdateFeedException("APK URL is outside the release repository")
            if (!Regex("^[0-9a-f]{64}$").matches(android.getString("sha256").lowercase())) throw UpdateFeedException("Invalid SHA-256")
            return versionName to versionCode
        }

        fun selectUpdate(installed: Long, codes: List<Long>): Long? = codes.filter { it > installed }.maxOrNull()
    }

    /**
     * End-to-end dry run: set BRIDGEY_RR_FEED_DIR to a dist/<tag>/channels directory
     * produced by scripts/rr/release.sh and every feed there must parse, and its APK
     * (when present next to it in ../release) must match the published SHA-256.
     */
    @Test fun parsesGeneratedFeedsWhenProvided() {
        val directory = System.getenv("BRIDGEY_RR_FEED_DIR")?.let(::File) ?: return
        val feeds = UpdateChannel.entries.mapNotNull { channel ->
            File(directory, "${channel.key}.json").takeIf(File::isFile)?.let { channel to it }
        }
        assertTrue("No feeds in $directory", feeds.isNotEmpty())
        feeds.forEach { (channel, file) ->
            val parsed = UpdateFeeds.parseAndroid(file.readText(), channel, appId, prefix)
                ?: return@forEach
            val apk = File(directory.parentFile, "release/${parsed.apkUrl.substringAfterLast('/')}")
            if (apk.isFile) {
                assertEquals(parsed.size, apk.length())
                assertTrue("SHA-256 of ${apk.name}", UpdateFeeds.sha256Matches(apk, parsed.sha256))
            }
        }
    }
}
