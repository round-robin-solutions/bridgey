package dev.bridgey.android

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/**
 * The string resources and the code that shows text: English and Russian hold the same keys with the same arguments,
 * Russian plurals have every form, English copy is British with no em dashes, and no screen, notification, toast or
 * snackbar takes a string literal instead of a resource. Plain JVM, no Robolectric: it reads the files.
 */
class StringResourcesTest {
    private val root = File(System.getProperty("bridgey.repoRoot") ?: "../..")
    private val res = File(root, "android/app/src/main/res")
    private val sources = File(root, "android/app/src/main/java")

    private sealed interface Entry {
        val file: String

        data class Text(override val file: String, val value: String) : Entry
        data class Plural(override val file: String, val items: Map<String, String>) : Entry
        data class Array(override val file: String, val items: List<String>) : Entry
    }

    /** name -> entry, from every strings*.xml in [folder] (translatable entries only). */
    private fun load(folder: String): Map<String, Entry> {
        val files = File(res, folder).listFiles { file -> file.name.startsWith("strings") && file.name.endsWith(".xml") }.orEmpty()
        assertTrue("no strings in $folder", files.isNotEmpty())
        val entries = linkedMapOf<String, Entry>()
        val builder = DocumentBuilderFactory.newInstance().newDocumentBuilder()
        for (file in files.sortedBy { it.name }) {
            val nodes = builder.parse(file).documentElement.childNodes
            for (i in 0 until nodes.length) {
                val element = nodes.item(i) as? Element ?: continue
                if (element.getAttribute("translatable") == "false") continue
                val name = element.getAttribute("name")
                val children = (0 until element.childNodes.length).mapNotNull { element.childNodes.item(it) as? Element }
                val entry = when (element.tagName) {
                    "string" -> Entry.Text(file.name, element.textContent)
                    "plurals" -> Entry.Plural(file.name, children.associate { it.getAttribute("quantity") to it.textContent })
                    "string-array" -> Entry.Array(file.name, children.map { it.textContent })
                    else -> continue
                }
                assertTrue("$name is defined twice in $folder", entries.put(name, entry) == null)
            }
        }
        return entries
    }

    private val english by lazy { load("values") }
    private val russian by lazy { load("values-ru") }

    private val argument = Regex("""%(\d+\$)?[-#+ 0,(]*\d*(\.\d+)?[sdfxXc]""")
    private fun arguments(text: String) = argument.findAll(text.replace("%%", "")).map { it.value }.sorted().toList()

    @Test fun russianHasEveryEnglishKeyAndNoOthers() {
        val missing = english.keys - russian.keys
        val extra = russian.keys - english.keys
        assertTrue("missing in values-ru: $missing", missing.isEmpty())
        assertTrue("only in values-ru: $extra", extra.isEmpty())
        val moved = english.filter { (name, entry) -> russian[name]?.let { it.file != entry.file || it::class != entry::class } == true }
        assertTrue("same name, different file or kind: ${moved.keys}", moved.isEmpty())
    }

    @Test fun argumentsMatch() {
        val wrong = english.mapNotNull { (name, entry) ->
            val other = russian[name] ?: return@mapNotNull null
            when {
                entry is Entry.Text && other is Entry.Text ->
                    name.takeIf { arguments(entry.value) != arguments(other.value) }
                entry is Entry.Plural && other is Entry.Plural -> {
                    // Every Russian form may use the arguments English uses, and no others (one may drop the count).
                    val allowed = entry.items.values.flatMap(::arguments).toSet()
                    name.takeIf { other.items.values.any { (arguments(it).toSet() - allowed).isNotEmpty() } }
                }
                else -> null
            }
        }
        assertTrue("format arguments differ between English and Russian: $wrong", wrong.isEmpty())
    }

    @Test fun pluralsHaveTheirForms() {
        val englishForms = english.filterValues { it is Entry.Plural }.filter { (_, entry) ->
            !(entry as Entry.Plural).items.keys.containsAll(listOf("one", "other"))
        }
        assertTrue("English plurals need one and other: ${englishForms.keys}", englishForms.isEmpty())
        val russianForms = russian.filterValues { it is Entry.Plural }.filter { (_, entry) ->
            !(entry as Entry.Plural).items.keys.containsAll(listOf("one", "few", "many", "other"))
        }
        assertTrue("Russian plurals need one, few, many and other: ${russianForms.keys}", russianForms.isEmpty())
    }

    /** All English copy, every form and item. */
    private fun englishTexts(): List<Pair<String, String>> = english.flatMap { (name, entry) ->
        when (entry) {
            is Entry.Text -> listOf(name to entry.value)
            is Entry.Plural -> entry.items.values.map { name to it }
            is Entry.Array -> entry.items.map { name to it }
        }
    }

    @Test fun englishHasNoEmDashes() {
        val dashed = englishTexts().filter { (_, text) -> '—' in text }.map { it.first }
        assertTrue("em dashes in English copy: $dashed", dashed.isEmpty())
    }

    @Test fun englishIsBritish() {
        // Whole words; product and protocol names (ColorOS, MIT License) are not copy.
        val american = Regex(
            """\b(colors?|colored|canceled|canceling|behaviors?|centers?|centered|favorites?|gray|""" +
                """optimiz\w*|organiz\w*|recogniz\w*|customiz\w*|synchroniz\w*|authoriz\w*|minimiz\w*|maximiz\w*|""" +
                """initializ\w*|analyz\w*|catalogs?)\b""",
            RegexOption.IGNORE_CASE,
        )
        val found = englishTexts().mapNotNull { (name, text) -> american.find(text)?.let { "$name: ${it.value}" } }
        assertTrue("American spelling in English copy: $found", found.isEmpty())
    }

    /**
     * Places where text reaches people (screens, notifications, toasts, snackbars, window titles). A literal with
     * words in one of them is copy that skipped the resources, so Russian never sees it.
     */
    @Test fun noHardCodedCopyInTheCode() {
        val sinks = listOf(
            """\bText\(\s*"""", """contentDescription\s*=\s*"""", """set(ContentTitle|ContentText|SubText|Ticker)\(\s*"""",
            """Toast\.makeText\([^,()]+,\s*"""", """NotificationChannel\([^,()]+,\s*"""", """showSnackbar\(\s*"""",
            """\.addAction\([^,]+,\s*"""", """[Ss]tatus\.value\s*=\s*"""", """\bsubtitle\s*=\s*"""", """onClickLabel\s*=\s*"""",
            """stateDescription\s*=\s*"""", """\btitle\s*=\s*"""", """createChooser\([^"]*,\s*"""",
        ).map(::Regex)
        val literal = Regex(""""((?:[^"\\]|\\.)*)"""")
        val channelDescription = Regex("""NotificationChannel\([^)]*\)\s*\.apply\s*\{[^}]*?description\s*=\s*"([^"]*)"""")
        fun hasWords(text: String) = Regex("""[A-Za-zА-Яа-я]{2,}""").containsMatchIn(text.replace(Regex("""\$\{[^}]*}|\$[A-Za-z_]\w*"""), ""))
        val found = mutableListOf<String>()
        sources.walkTopDown().filter { it.extension == "kt" }.forEach { file ->
            val relative = file.relativeTo(sources).path
            val text = file.readText()
            text.lines().forEachIndexed { index, line ->
                val code = line.substringBefore("//")
                sinks.forEach { sink ->
                    sink.findAll(code).forEach { match ->
                        literal.matchAt(code, match.range.last)?.groupValues?.get(1)?.takeIf(::hasWords)?.let { value ->
                            if ("$relative:$value" !in Allowed) found += "$relative:${index + 1}: \"$value\""
                        }
                    }
                }
            }
            channelDescription.findAll(text).forEach { found += "$relative: channel description \"${it.groupValues[1]}\"" }
        }
        assertTrue("copy written in code instead of strings.xml:\n" + found.joinToString("\n"), found.isEmpty())
    }

    private companion object {
        /** Literals in those places that are not copy. */
        val Allowed = setOf(
            // The folder received files go to, a path on every phone.
            "dev/bridgey/android/ReceivedFileNotifier.kt:Download/Bridgey",
        )
    }
}
