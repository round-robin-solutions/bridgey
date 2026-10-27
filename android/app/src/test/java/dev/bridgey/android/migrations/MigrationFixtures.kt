package dev.bridgey.android.migrations

import android.content.Context
import java.io.File

/**
 * The upgrade fixtures in `protocol/test-vectors/migrations/android`: what a phone on an older edition
 * release has on disk. Synthetic only (throwaway keys, made-up names). See docs/upgrade-policy.md.
 */
internal object MigrationFixtures {
    val root: File = File(System.getProperty("bridgey.repoRoot") ?: error("bridgey.repoRoot is not set"), "protocol/test-vectors/migrations/android")

    /** Every edition release whose shared preferences have a snapshot, oldest first. */
    val sharedPrefsReleases = listOf(1, 2, 4, 5, 8, 9, 10, 11, 13)

    /** 2026-10-26T09:00:00Z: the base time of the file fixtures. */
    const val BASE_MILLIS = 1_793_005_200_000L
    const val HOUR = 3_600_000L

    // The throwaway ids used across the fixtures.
    const val PHONE_ID = "0883634b-020c-4865-92f1-b4e8b2bcaa2d"
    const val MAC_A = "e2acaa6d-7980-4e5c-b5cb-9c8742216271"
    const val MAC_B = "95b2dd40-4f91-44e7-9f28-d6655fcbd197"
    const val MAC_C = "6718981b-b9e7-4688-a8c9-9b5a5bb8e3ed"
    const val ORPHAN_NAME_ID = "d5dc899e-aaf6-4196-9ed0-3c1cdb3ea832"
    const val KEY_A = "BBAl8z4gV38J9A9qZ3ytWpBVd9Cs8PS58tGNSCcZqHgwgcwSMonestjOd1d6teJg+Xr3dOyj+EXbmiXNpVLGstA="
    const val KEY_B = "BPLnIdaHWwZpRVUTpTuHGKuh2e4QBB2PHmBSIBs4+wi71fqNHfopx8ZRvVDiNdCD7am8zcQLQ9Afu3RrYJbTJJg="
    const val KEY_C = "BFixS0AdxLGMMkv9/7qbO2HI1XLVaUz923fIZaE5ZKVF2cuyYTH/Gsv0xYva7U/vqdEtju8a/GGoXOZFC/lq2YU="

    fun file(path: String): File = File(root, path).also { require(it.exists()) { "missing fixture $it" } }

    /**
     * Copies the `shared_prefs` snapshot of edition beta [release] into the app's data folder, the way
     * Android keeps them (`<dataDir>/shared_prefs/<name>.xml`). Call before anything opens the preferences.
     */
    fun installSharedPrefs(context: Context, release: Int) = installSharedPrefs(context, "beta.$release")

    /**
     * Files 2.0 (0.8.0-rr.1, not yet released as a tag): only the preferences files it added or changed, in
     * `shared_prefs/0.8.0-rr.1`. Install it on top of the newest beta snapshot.
     */
    const val FILES_2_SNAPSHOT = "0.8.0-rr.1"

    fun installSharedPrefs(context: Context, snapshot: String) {
        val source = file("shared_prefs/$snapshot")
        val target = File(context.dataDir, "shared_prefs").apply { mkdirs() }
        source.listFiles().orEmpty().filter { it.name.endsWith(".xml") }.forEach { it.copyTo(File(target, it.name), overwrite = true) }
    }
}
