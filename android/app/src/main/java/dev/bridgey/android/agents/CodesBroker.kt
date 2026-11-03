package dev.bridgey.android.agents

/** How long a code from a Mac is kept, in memory only. */
const val CODE_KEEP_MILLIS = 15L * 60_000

/** At most this many codes are kept. */
const val CODE_KEEP_MAX = 50

/** Held code queries per agent device. */
const val CODES_HELD_MAX = 2

/** One code the Macs found, folded by service and code: [via] lists every way it came. */
internal class CachedCode(
    val code: String,
    val service: String,
    val serviceKey: String,
    val source: CodeSource,
    val app: String,
    val postedAt: Long,
    /** When this phone first heard of it (its 15 minutes run from here or [postedAt], whichever is later). */
    val heardAt: Long,
    val via: LinkedHashSet<String>,
)

/** A query held until a matching newer code arrives or its wait ends. */
data class HeldQuery(val deviceId: String, val query: CodesQuery, val heldAt: Long)

/** What answering a query gives: the codes for codes.result, and what the audit and codes.read get (never the code). */
data class CodesAnswer(val codes: List<CodeOut>) {
    /** The service shown in the audit: the one asked for, else the newest code's, else empty. */
    fun service(asked: String?): String = asked ?: codes.firstOrNull()?.service.orEmpty()
}

/**
 * The codes broker: codes from the Macs' `codes.found`, kept in memory only (15 minutes, at most 50), folded by
 * serviceKey and code, and answered to agents with Read codes. Codes are never written to disk, logs or diagnostics.
 */
class CodesBroker(private val clock: () -> Long = System::currentTimeMillis) {
    private val codes = ArrayList<CachedCode>()
    private val held = ArrayList<HeldQuery>()

    private fun via(found: CodeFound): String = if (found.source == CodeSource.SMS) "sms" else "email:${found.app}"

    /** Adds a code; returns the held queries it now answers (removed from the held list). */
    @Synchronized fun add(found: CodeFound): List<HeldQuery> {
        val now = clock()
        prune(now)
        val existing = codes.firstOrNull { it.serviceKey.equals(found.serviceKey, ignoreCase = true) && it.code == found.code }
        if (existing != null) {
            existing.via += via(found)
        } else {
            codes += CachedCode(found.code, found.service, found.serviceKey, found.source, found.app, found.postedAt, now, linkedSetOf(via(found)))
            if (codes.size > CODE_KEEP_MAX) {
                codes.sortByDescending { it.postedAt }
                while (codes.size > CODE_KEEP_MAX) codes.removeAt(codes.lastIndex)
            }
        }
        val answered = held.filter { matching(it.query, now).isNotEmpty() }
        held.removeAll(answered.toSet())
        return answered
    }

    private fun prune(now: Long) {
        codes.removeAll { now - maxOf(it.postedAt, it.heardAt) >= CODE_KEEP_MILLIS }
    }

    private fun matching(query: CodesQuery, now: Long): List<CachedCode> = codes.filter { code ->
        (query.service == null || code.service.equals(query.service, ignoreCase = true) || code.serviceKey.equals(query.service, ignoreCase = true)) &&
            code.postedAt >= now - query.sinceMs &&
            (query.newerThan == null || code.postedAt > query.newerThan)
    }

    /** Newest first, with latest and replaced per service; at most 20. Empty when nothing matches. */
    @Synchronized fun answer(query: CodesQuery): CodesAnswer {
        val now = clock()
        prune(now)
        val newestByService = codes.groupBy { it.serviceKey.lowercase() }.mapValues { (_, list) -> list.maxOf { it.postedAt } }
        val matched = matching(query, now).sortedByDescending { it.postedAt }.map { code ->
            val latest = newestByService[code.serviceKey.lowercase()] == code.postedAt
            CodeOut(code.code, code.service, code.source, code.app, code.postedAt, latest = latest, replaced = !latest, via = code.via.toList())
        }
        val shown = if (query.latestOnly) matched.filter { it.latest } else matched
        return CodesAnswer(shown.take(CODES_RESULT_MAX))
    }

    /** Holds [query] for its wait; false when [deviceId] already holds [CODES_HELD_MAX]. */
    @Synchronized fun hold(deviceId: String, query: CodesQuery): Boolean {
        if (held.count { it.deviceId == deviceId } >= CODES_HELD_MAX) return false
        held.removeAll { it.deviceId == deviceId && it.query.queryId == query.queryId }
        held += HeldQuery(deviceId, query, clock())
        return true
    }

    /** Takes a held query out (its wait ended, codes.cancel, or the agent left); null when not held. */
    @Synchronized fun release(deviceId: String, queryId: String): HeldQuery? =
        held.firstOrNull { it.deviceId == deviceId && it.query.queryId == queryId }?.also { held.remove(it) }

    @Synchronized fun releaseAll(deviceId: String): List<HeldQuery> = held.filter { it.deviceId == deviceId }.also { held.removeAll(it.toSet()) }

    @Synchronized fun heldCount(deviceId: String): Int = held.count { it.deviceId == deviceId }

    /** Forgets every code (Codes turned off for every agent, or Bridgey reset). */
    @Synchronized fun clear() {
        codes.clear()
    }

    @Synchronized fun size(): Int {
        prune(clock())
        return codes.size
    }
}
