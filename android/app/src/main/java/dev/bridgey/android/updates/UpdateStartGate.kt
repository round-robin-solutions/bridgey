package dev.bridgey.android.updates

/** At most one updates.start from a device every 30 seconds. */
const val UPDATE_START_SPACING_MILLIS = 30_000L

/** And at most five an hour from that device. */
const val UPDATE_START_HOURLY_LIMIT = 5
const val UPDATE_START_WINDOW_MILLIS = 60L * 60 * 1000

/** What this device knows when an updates.start arrives. */
data class UpdateGateFacts(
    /** "Let paired devices start updates on this device". */
    val remoteStartOn: Boolean,
    /** The updater can run (false in a build without feeds). */
    val updaterAvailable: Boolean,
    /** The updater cannot start a check right now (for example its feed is being written). */
    val busy: Boolean,
    /** The version this device handed to its installer and then started again without, if any. */
    val notApplied: NotApplied?,
    /** The newest build the last check offered, or null when none is known. */
    val offeredBuild: Long?,
    /** What the person is doing here: an automatic start (updates.start auto) waits for them. */
    val personBusy: UpdateBusy? = null,
)

/** A version that did not apply: this device installed it and came back on its old build. */
data class NotApplied(val build: Long, val version: String)

/**
 * Decides each updates.start (docs/protocol.md "Update all"). Pure apart from its per-device memory
 * of recent starts, so it is unit tested; the receiver answers exactly one updates.result.
 */
class UpdateStartGate(private val clock: () -> Long) {
    private val accepted = mutableMapOf<String, ArrayDeque<Long>>()

    /** Null means accepted. A start refused for its rate does not count toward the rate. */
    @Synchronized fun decide(deviceId: String, start: UpdateStart, facts: UpdateGateFacts): UpdateRefusal? {
        if (!facts.remoteStartOn) return UpdateRefusal.DISABLED
        if (!facts.updaterAvailable) return UpdateRefusal.MANUAL
        val now = clock()
        val history = accepted.getOrPut(deviceId) { ArrayDeque() }
        while (history.isNotEmpty() && now - history.first() >= UPDATE_START_WINDOW_MILLIS) history.removeFirst()
        val last = history.lastOrNull()
        if ((last != null && now - last < UPDATE_START_SPACING_MILLIS && now >= last) || history.size >= UPDATE_START_HOURLY_LIMIT) {
            return UpdateRefusal.RATE_LIMITED
        }
        val failed = facts.notApplied
        if (failed != null && !start.retry && (facts.offeredBuild == null || facts.offeredBuild == failed.build)) {
            history.addLast(now)
            return UpdateRefusal.NOT_APPLIED
        }
        if (facts.busy || AutoStartRule.refusesBusy(start, facts.personBusy)) {
            history.addLast(now)
            return UpdateRefusal.BUSY
        }
        history.addLast(now)
        return null
    }

    @Synchronized fun forget(deviceId: String) {
        accepted.remove(deviceId)
    }
}

/** A build handed to the installer, written right before the session commits. */
data class PendingInstall(val build: Long, val version: String, val at: Long)

/** The pending install counts as not applied only if Bridgey starts again within this time. */
const val NOT_APPLIED_WINDOW_MILLIS = 60L * 60 * 1000

/**
 * At process start: what a pending install means. Null pending means nothing to decide. The
 * returned marker is null when the install applied (the build is at least the pending one) or the
 * pending install is too old to say.
 */
fun settlePendingInstall(pending: PendingInstall?, installedBuild: Long, now: Long): NotApplied? {
    pending ?: return null
    if (installedBuild >= pending.build) return null
    if (now < pending.at || now - pending.at >= NOT_APPLIED_WINDOW_MILLIS) return null
    return NotApplied(pending.build, pending.version)
}

/** A known not-applied marker stays only while the feed still offers that same build (or nothing newer is known). */
fun notAppliedStillMatches(marker: NotApplied?, offeredBuild: Long?): NotApplied? =
    marker?.takeIf { offeredBuild == null || offeredBuild == it.build }
