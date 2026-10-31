package dev.bridgey.android

import dev.bridgey.android.codes.EMAIL_CODES_FEATURE_KEY
import dev.bridgey.android.codes.SMS_CODES_FEATURE_KEY
import dev.bridgey.android.folders.FOLDERS_FEATURE_KEY
import dev.bridgey.android.folders.PLACES_FEATURE_KEY
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * protocol/messages.json lists every message kind this app sends or handles (docs/protocol-contract.md).
 * Adding a message without documenting it fails here; so does documenting one the code never uses.
 * The macOS suite runs the same scan (ProtocolContractTests.swift), and so does
 * scripts/rr/tests/test_protocol_contract.py.
 */
class ProtocolContractTest {
    private val root = File(System.getProperty("bridgey.repoRoot") ?: "../..")
    private val contract = JSONObject(File(root, "protocol/messages.json").readText())
    private val messages = contract.getJSONArray("messages").let { array -> (0 until array.length()).map { array.getJSONObject(it) } }
    private val listed = messages.associateBy { it.getString("kind") }

    @Test fun everyKindTheCodeUsesIsListed() {
        val found = scanKinds(sources())
        assertTrue("the scan found nothing; did the sources move?", found.size > 50)
        val problems = mutableListOf<String>()
        found.forEach { (kind, file) ->
            val entry = listed[kind]
            when {
                entry == null -> problems += "$kind (in $file) is not in protocol/messages.json"
                !entry.implementedOn("android") -> problems += "$kind (in $file) is used but messages.json does not list android"
            }
        }
        listed.forEach { (kind, entry) ->
            if (entry.implementedOn("android") && kind !in found) problems += "messages.json lists $kind for android, but the sources never use it"
        }
        assertEquals("Document new messages in docs/protocol.md and protocol/messages.json:\n" + problems.joinToString("\n"), emptyList<String>(), problems)
    }

    @Test fun everyFeatureKeyThisAppAdvertisesIsListed() {
        val keys = contract.getJSONArray("features").let { array -> (0 until array.length()).map { array.getJSONObject(it).getString("key") }.toSet() }
        // Every switch and every draft key the shared decoder reads (Files 2.0 and automation keys included), as on the Mac.
        val advertised = BridgeyFeature.entries.map(BridgeyFeature::key) +
            listOf(CLIPBOARD_FILES_FEATURE_KEY, FOLDERS_FEATURE_KEY, PLACES_FEATURE_KEY, SMS_CODES_FEATURE_KEY, EMAIL_CODES_FEATURE_KEY) +
            KNOWN_DRAFT_FEATURE_KEYS
        assertEquals(emptyList<String>(), advertised.filterNot(keys::contains))
        // The original keys are the ones a peer must send; the decoder and the contract agree on them.
        val required = contract.getJSONArray("features").let { array ->
            (0 until array.length()).map(array::getJSONObject).filter { it.getBoolean("requiredInMap") }.map { it.getString("key") }.toSet()
        }
        assertEquals(required, BridgeyFeature.entries.filter(::featureEnabledByLegacyPeer).map(BridgeyFeature::key).toSet())
    }

    @Test fun transportLimitsMatchTheContract() {
        val transport = contract.getJSONObject("transport")
        assertEquals(MAX_PROTOCOL_FRAME_BYTES, transport.getInt("maxFrameBytes"))
        assertEquals(MAX_PROTOCOL_JSON_DEPTH, transport.getInt("maxJsonDepth"))
        assertEquals(ReconnectPolicy.LISTENING_PORT, transport.getInt("port"))
    }

    @Test fun scanFindsEveryStyleTheCodeUses() {
        val dir = kotlin.io.path.createTempDirectory("contract").toFile()
        try {
            File(dir, "A.kt").writeText(
                """
                send(Message(kind = "a.one"))
                            "a.two", "a.three" -> x()
                object FooKinds {
                    const val X = "a.four"
                }
                    FIVE("a.five"),
                link.sendWithId("a.six", id)
                if (message.kind == "a.seven") return
                    override val kind get() = "a.eight"
                val file = "notes.txt"
                """.trimIndent(),
            )
            assertEquals((listOf("one", "two", "three", "four", "five", "six", "seven", "eight").map { "a.$it" }).toSet(), scanKinds(listOf(dir)).keys)
        } finally {
            dir.deleteRecursively()
        }
    }

    private fun JSONObject.implementedOn(platform: String): Boolean {
        val array = getJSONArray("implemented")
        return (0 until array.length()).any { array.getString(it) == platform }
    }

    private fun sources(): List<File> =
        File(root, "android").walkTopDown().filter { it.isDirectory && it.name == "main" && it.parentFile.name == "src" }.toList()

    companion object {
        private const val K = """[a-z][a-z0-9]*(?:\.[a-z0-9_]+)+"""
        private val patterns = listOf(
            Regex("""kind\s*=\s*"($K)""""),
            Regex("""kind\s*==\s*"($K)""""),
            Regex("""kind get\(\)\s*=\s*"($K)""""),
            Regex("""\bsend\w*\((?:[^()"]*,\s*)?"($K)""""),
            Regex("""^\s*[A-Z_]+\("($K)"\)"""),
        )
        private val branch = Regex("""^\s*((?:"$K"\s*,\s*)*"$K")\s*->""")
        private val literal = Regex(""""($K)"""")
        private val kindsBlock = Regex("""object \w*Kinds\s*\{(.*?)\n\}""", RegexOption.DOT_MATCHES_ALL)
        private val constant = Regex("""const val \w+ = "($K)"""")

        /** Kinds used as a message kind in Kotlin sources, with the first file that uses each. */
        fun scanKinds(roots: List<File>): Map<String, String> {
            val found = sortedMapOf<String, String>()
            roots.flatMap { root -> root.walkTopDown().filter { it.extension == "kt" }.toList() }.sortedBy(File::getPath).forEach { file ->
                val text = file.readText()
                text.lineSequence().forEach { line ->
                    patterns.forEach { pattern -> pattern.findAll(line).forEach { found.putIfAbsent(it.groupValues[1], file.name) } }
                    branch.find(line)?.let { match -> literal.findAll(match.groupValues[1]).forEach { found.putIfAbsent(it.groupValues[1], file.name) } }
                }
                kindsBlock.findAll(text).forEach { block -> constant.findAll(block.groupValues[1]).forEach { found.putIfAbsent(it.groupValues[1], file.name) } }
            }
            return found
        }
    }
}
