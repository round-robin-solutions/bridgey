package dev.bridgey.android.folders

import java.text.Normalizer
import java.util.Locale

/**
 * Draft folders protocol (docs/folders-and-settings-sync.md, protocol.md "Draft: folders, places and
 * settings sync"): names, paths, limits and the manifest digest. Pure code, no Android types, so the
 * shared vectors in protocol/test-vectors/folders-v1.json run on the JVM. macOS has the same rules in
 * FolderCore.swift.
 */
object FolderLimits {
    const val MAX_FILES = 10_000
    const val MAX_FOLDERS = 2_000
    const val MAX_DEPTH = 32
    const val MAX_NAME_BYTES = 220
    const val MAX_PATH_BYTES = 1_024
    const val MAX_EXISTING_COMPONENT_BYTES = 255
    const val MAX_FILE_SIZE = 10L * 1024 * 1024 * 1024
    const val MAX_TOTAL_SIZE = 1L shl 40
    const val MAX_PAGES = 128
    const val MAX_ENTRIES_PER_PAGE = 256
    const val MAX_PAGE_BYTES = 32 * 1024
    const val MAX_MANIFEST_BYTES = 4 * 1024 * 1024
    const val MAX_PLACES = 16
    const val MAX_BROWSE_NAMES = 500
    const val MAX_LABEL_CHARS = 64
    const val MAX_DESTINATION_LABEL_CHARS = 128
    const val MAX_REPORTED_FAILURES = 500
    const val MAX_FAILURES_BEFORE_CANCEL = 50
    const val PLACES_IN_FLIGHT = 4
    const val PLACES_PER_WINDOW = 20
    const val PLACES_WINDOW_MILLIS = 10_000L
    const val SMALL_PLAINTEXT = 8 * 1024
    const val LARGE_PLAINTEXT = 32 * 1024

    /** Free space must cover the folder plus this margin. */
    const val SPACE_MARGIN = 64L * 1024 * 1024

    /** Files above this size, and every replaced file, are written as a hidden part file first. */
    const val PART_FILE_THRESHOLD = 1L * 1024 * 1024
}

object FolderTimeouts {
    /** A question to a person (destination or conflict), counted by the device that asks. */
    const val QUESTION_SECONDS = 180

    /** The sender's own wait on a remote question: the question plus a margin. */
    const val SENDER_QUESTION_WAIT_MILLIS = 195_000L

    /** First answer after the last manifest page. */
    const val FIRST_ANSWER_MILLIS = 15_000L

    /** Answer to a places request. */
    const val PLACES_ANSWER_MILLIS = 8_000L

    /** folders.result after folders.complete. */
    const val RESULT_MILLIS = 30_000L

    /**
     * Resume (Rahul, transfer engine A4/A5, 2026-10-26): an interrupted folder resumes by itself whenever
     * both devices can reach each other, until 24 hours after its last progress. Then the journal is deleted
     * and the folder stays incomplete.
     */
    const val RESUME_WINDOW_MILLIS = 24L * 60 * 60 * 1000

    fun canResume(lastProgressAtMillis: Long, nowMillis: Long): Boolean =
        nowMillis >= lastProgressAtMillis && nowMillis - lastProgressAtMillis < RESUME_WINDOW_MILLIS
}

/** Draft feature keys (D20): advertised instead of the final keys until upstream accepts the design. */
const val FOLDERS_FEATURE_KEY = "folders_draft1"
const val PLACES_FEATURE_KEY = "places_draft1"

/** Section 5.1: names that are safe on FAT-style storage, Android shared storage and macOS. */
object PortableName {
    private const val PART_SUFFIX = ".bridgey-part"
    private const val MAX_EXTENSION_BYTES = 16
    private val reserved = setOf("CON", "PRN", "AUX", "NUL") + (1..9).flatMap { listOf("COM$it", "LPT$it") }
    private const val replaced = "\"*/:<>?\\|"

    /** Steps 1 to 6. Null when [name] holds an unpaired surrogate. */
    fun normalize(name: String): String? {
        if (hasUnpairedSurrogate(name)) return null
        var value = Normalizer.normalize(name, Normalizer.Form.NFC)
        value = buildString(value.length) {
            value.forEach { char -> append(if (char.code < 0x20 || char.code == 0x7f || char in replaced) '_' else char) }
        }
        value = trim(value)
        val head = value.substringBefore('.')
        if (head.uppercase(Locale.ROOT) in reserved) value = head + "_" + value.substring(head.length)
        if (value.endsWith(PART_SUFFIX, ignoreCase = true)) value += "_"
        return value
    }

    /** The sender's conversion, steps 1 to 7. Null when [name] holds an unpaired surrogate. */
    fun convert(name: String): String? {
        val value = normalize(name) ?: return null
        if (utf8Length(value) <= FolderLimits.MAX_NAME_BYTES) return value
        val dot = value.lastIndexOf('.')
        val extension = if (dot > 0 && utf8Length(value.substring(dot)) <= MAX_EXTENSION_BYTES) value.substring(dot) else ""
        val stem = value.substring(0, value.length - extension.length)
        val shortened = truncateUtf8(stem, FolderLimits.MAX_NAME_BYTES - utf8Length(extension)) + extension
        return trim(shortened)
    }

    /** The receiver's check: the name does not change under steps 1 to 6 and fits in 220 bytes. */
    fun isPortable(name: String): Boolean =
        name.isNotEmpty() && normalize(name) == name && utf8Length(name) <= FolderLimits.MAX_NAME_BYTES

    private fun trim(value: String): String = value.trimStart(' ').trimEnd(' ', '.').ifEmpty { "_" }

    private fun hasUnpairedSurrogate(value: String): Boolean {
        var index = 0
        while (index < value.length) {
            val char = value[index]
            if (Character.isHighSurrogate(char)) {
                if (index + 1 >= value.length || !Character.isLowSurrogate(value[index + 1])) return true
                index += 2
                continue
            }
            if (Character.isLowSurrogate(char)) return true
            index++
        }
        return false
    }

    private fun truncateUtf8(value: String, maxBytes: Int): String {
        val out = StringBuilder()
        var bytes = 0
        var index = 0
        while (index < value.length) {
            val codePoint = value.codePointAt(index)
            val size = utf8Length(String(Character.toChars(codePoint)))
            if (bytes + size > maxBytes) break
            out.appendCodePoint(codePoint)
            bytes += size
            index += Character.charCount(codePoint)
        }
        return out.toString()
    }
}

fun utf8Length(value: String): Int = value.toByteArray(Charsets.UTF_8).size

/** The key two names clash under: NFC, then Unicode default lowercase. */
fun caseKey(name: String): String = Normalizer.normalize(name, Normalizer.Form.NFC).lowercase(Locale.ROOT)

/** Sections 5.2 and 5.3: paths inside a manifest, and paths of folders that already exist on the receiver. */
object FolderPaths {
    /** A manifest path: portable components joined by "/", at most 32 components and 1,024 bytes. */
    fun isValidManifestPath(path: String): Boolean {
        if (path.isEmpty() || utf8Length(path) > FolderLimits.MAX_PATH_BYTES) return false
        val components = path.split('/')
        if (components.size > FolderLimits.MAX_DEPTH) return false
        return components.all(PortableName::isPortable)
    }

    /**
     * A path of existing folders (browse, destination). Other apps may have named them anything, so only
     * separators, NUL, control characters, "." and ".." are refused. "" is the place itself.
     */
    fun isValidExistingPath(path: String): Boolean {
        if (path.isEmpty()) return true
        if (utf8Length(path) > FolderLimits.MAX_PATH_BYTES) return false
        val components = path.split('/')
        if (components.size > FolderLimits.MAX_DEPTH) return false
        return components.all { component ->
            component.isNotEmpty() && component != "." && component != ".." &&
                utf8Length(component) <= FolderLimits.MAX_EXISTING_COMPONENT_BYTES &&
                component.none { it.code < 0x20 || it.code == 0x7f }
        }
    }

    fun components(path: String): List<String> = if (path.isEmpty()) emptyList() else path.split('/')

    fun parent(path: String): String = path.substringBeforeLast('/', "")

    fun leaf(path: String): String = path.substringAfterLast('/')

    /** Manifest order: depth-first pre-order, siblings by the UTF-8 bytes of their names. */
    val manifestOrder: Comparator<String> = Comparator { a, b ->
        val left = components(a)
        val right = components(b)
        for (index in 0 until minOf(left.size, right.size)) {
            val compared = compareUtf8(left[index], right[index])
            if (compared != 0) return@Comparator compared
        }
        left.size.compareTo(right.size)
    }

    fun compareUtf8(a: String, b: String): Int {
        val left = a.toByteArray(Charsets.UTF_8)
        val right = b.toByteArray(Charsets.UTF_8)
        for (index in 0 until minOf(left.size, right.size)) {
            val compared = (left[index].toInt() and 0xff).compareTo(right[index].toInt() and 0xff)
            if (compared != 0) return compared
        }
        return left.size.compareTo(right.size)
    }
}

/** D17: "Photos (1)" for folders, "name (1).ext" for files, the first free number. Comparison ignores case. */
object ConflictNames {
    fun numbered(name: String, number: Int, isDirectory: Boolean): String {
        if (isDirectory) return "$name ($number)"
        val dot = name.lastIndexOf('.')
        return if (dot > 0) "${name.substring(0, dot)} ($number)${name.substring(dot)}" else "$name ($number)"
    }

    /** [name] itself when free, otherwise the first free numbered name. [taken] receives case keys. */
    fun firstFree(name: String, isDirectory: Boolean, taken: (String) -> Boolean): String {
        if (!taken(caseKey(name))) return name
        for (number in 1..9_999) {
            val candidate = numbered(name, number, isDirectory)
            if (!taken(caseKey(candidate))) return candidate
        }
        return numbered(name, 10_000 + (System.nanoTime() and 0xffff).toInt(), isDirectory)
    }

    /**
     * Section 5.2, sender side: siblings sorted by UTF-8 bytes, each later clashing sibling renamed with the
     * smallest free number. Returns the final names in that order, paired with the original index.
     */
    fun resolveSiblings(names: List<Pair<String, Boolean>>): List<Pair<Int, String>> {
        val order = names.indices.sortedWith { a, b -> FolderPaths.compareUtf8(names[a].first, names[b].first) }
        val originalKeys = names.map { caseKey(it.first) }.toSet()
        val assigned = HashSet<String>()
        return order.map { index ->
            val (name, isDirectory) = names[index]
            val final = if (caseKey(name) !in assigned) name
            else firstFree(name, isDirectory) { key -> key in assigned || key in originalKeys }
            assigned += caseKey(final)
            index to final
        }
    }
}

/**
 * The confirmed hidden and system file rules (Rahul, 2026-10-25). System files are matched by exact name
 * (plus the AppleDouble "._" prefix), never by a broad pattern, and are skipped unless "Include system
 * files" is on, even when hidden files are included.
 */
object SystemFiles {
    val NAMES: Set<String> = linkedSetOf(
        ".DS_Store", ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems", ".DocumentRevisions-V100",
        ".VolumeIcon.icns", ".localized", "Icon\r", "Thumbs.db", "ehthumbs.db", "desktop.ini", "\$RECYCLE.BIN",
        "System Volume Information",
    )
    const val APPLE_DOUBLE_PREFIX = "._"

    enum class Kind { NORMAL, HIDDEN, SYSTEM, PARTIAL }

    fun classify(name: String, hiddenFlag: Boolean = false): Kind = when {
        name.endsWith(".bridgey-part", ignoreCase = true) -> Kind.PARTIAL
        name in NAMES || name.startsWith(APPLE_DOUBLE_PREFIX) -> Kind.SYSTEM
        name.startsWith(".") || hiddenFlag -> Kind.HIDDEN
        else -> Kind.NORMAL
    }

    /** Whether an item is sent: partial files never; system files only with their option; hidden ones with theirs. */
    fun included(kind: Kind, includeHidden: Boolean, includeSystem: Boolean): Boolean = when (kind) {
        Kind.NORMAL -> true
        Kind.HIDDEN -> includeHidden
        Kind.SYSTEM -> includeSystem
        Kind.PARTIAL -> false
    }
}

data class ManifestEntry(
    val type: Type,
    val path: String,
    val size: Long = 0,
    val sha256: String? = null,
    val modified: Long? = null,
) {
    enum class Type(val wire: String) { DIR("dir"), FILE("file") }

    val isDirectory: Boolean get() = type == Type.DIR
}

object ManifestDigest {
    /** Section 4.5.1. */
    fun compute(rootName: String, entries: List<ManifestEntry>): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        digest.update("folder-manifest-v1\n$rootName\n".toByteArray(Charsets.UTF_8))
        entries.forEach { entry ->
            val size = if (entry.isDirectory) "0" else entry.size.toString()
            digest.update("${entry.type.wire}\u0000${entry.path}\u0000$size\u0000${entry.sha256.orEmpty()}\n".toByteArray(Charsets.UTF_8))
        }
        return java.util.Base64.getEncoder().encodeToString(digest.digest())
    }
}

/** folders.accept completedBitmap: bit i (least significant bit first) set when entry i is done. */
object CompletedBitmap {
    fun encode(size: Int, done: (Int) -> Boolean): String {
        val bytes = ByteArray((size + 7) / 8)
        for (index in 0 until size) if (done(index)) bytes[index / 8] = (bytes[index / 8].toInt() or (1 shl (index % 8))).toByte()
        return java.util.Base64.getEncoder().encodeToString(bytes)
    }

    /** Null when [value] is not base64 or too short for [size] entries. */
    fun decode(value: String, size: Int): Set<Int>? {
        val bytes = runCatching { java.util.Base64.getDecoder().decode(value) }.getOrNull() ?: return null
        if (bytes.size < (size + 7) / 8) return null
        return (0 until size).filterTo(LinkedHashSet()) { index -> (bytes[index / 8].toInt() shr (index % 8)) and 1 == 1 }
    }
}

/** Error codes of section 4.8. */
object FolderCodes {
    const val UNSUPPORTED = "unsupported"
    const val POLICY = "policy"
    const val BUSY = "busy"
    const val INVALID_MESSAGE = "invalid_message"
    const val INVALID_MANIFEST = "invalid_manifest"
    const val LIMIT_EXCEEDED = "limit_exceeded"
    const val INSUFFICIENT_SPACE = "insufficient_space"
    const val PLACE_UNAVAILABLE = "place_unavailable"
    const val NOT_FOUND = "not_found"
    const val EXISTS = "exists"
    const val INVALID_NAME = "invalid_name"
    const val TIMEOUT = "timeout"
    const val DECLINED = "declined"
    const val IO_ERROR = "io_error"
    const val VERIFICATION_FAILED = "verification_failed"
    const val SOURCE_CHANGED = "source_changed"
    const val UNREADABLE = "unreadable"
    const val RESUME_UNAVAILABLE = "resume_unavailable"
    const val TOO_MANY_FAILURES = "too_many_failures"
    const val CANCELLED = "cancelled"
}
