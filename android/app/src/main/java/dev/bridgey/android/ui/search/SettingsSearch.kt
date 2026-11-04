package dev.bridgey.android.ui.search

import java.text.Normalizer

/**
 * One searchable row, its text already in the app's language. [title] is the row's own name; the
 * other fields only help find it. [keywords] are hand-written synonyms in English and Russian.
 */
data class SearchDoc(
    val title: String,
    val subtitle: String? = null,
    val section: String? = null,
    val page: String? = null,
    val keywords: List<String> = emptyList(),
)

/** A match: the row's index in the list searched, its score, and what to mark in its title and subtitle. */
data class SearchHit(val index: Int, val score: Int, val titleRanges: List<IntRange>, val subtitleRanges: List<IntRange>)

/**
 * Settings search: the same rules as the Mac (SettingsSearch.swift). Text is folded (case, accents, ё as е,
 * punctuation as spaces); every word typed must match some field of a row. Within a word: whole word, then
 * word start, then anywhere, then one typo (in a whole word, then in a word's start), the row's title always
 * counting more than its other fields.
 * The whole query earns one bonus on top (the title itself, a title that starts with it, a synonym). Pure,
 * so the unit tests pin it.
 */
object SettingsSearch {
    private const val TITLE_WORD = 140
    private const val TITLE_PREFIX = 100
    private const val TITLE_SUBSTRING = 40
    private const val TITLE_TYPO = 24
    private const val OTHER_WORD = 90
    private const val OTHER_PREFIX = 70
    private const val OTHER_SUBSTRING = 30
    private const val OTHER_TYPO = 20

    /** One character folded to one character, so positions in the folded text match the original. */
    private fun foldChar(c: Char): Char {
        val lower = c.lowercaseChar()
        val base = Normalizer.normalize(lower.toString(), Normalizer.Form.NFD).firstOrNull() ?: lower
        return when {
            base == 'ё' -> 'е'
            base.isLetterOrDigit() -> base
            else -> ' '
        }
    }

    /** Folded text with the original's length: lower case, no accents, ё as е, anything else a space. */
    private fun foldAligned(text: String): String = buildString(text.length) { text.forEach { append(foldChar(it)) } }

    /** Folded text with single spaces and no spaces at the ends. */
    fun fold(text: String): String = foldAligned(text).split(' ').filter { it.isNotEmpty() }.joinToString(" ")

    private class Field(val text: String, val primary: Boolean) {
        val words: List<String> = text.split(' ').filter { it.isNotEmpty() }
    }

    private class Prepared(val title: Field, val others: List<Field>, val subtitle: String, val keywords: List<String>)

    private fun prepare(doc: SearchDoc): Prepared {
        val title = fold(doc.title)
        val subtitle = doc.subtitle?.let(::fold).orEmpty()
        val keywords = doc.keywords.map(::fold).filter { it.isNotEmpty() }
        val others = buildList {
            if (subtitle.isNotEmpty()) add(Field(subtitle, false))
            doc.section?.let(::fold)?.takeIf { it.isNotEmpty() }?.let { add(Field(it, false)) }
            doc.page?.let(::fold)?.takeIf { it.isNotEmpty() }?.let { add(Field(it, false)) }
            keywords.forEach { add(Field(it, false)) }
        }
        return Prepared(Field(title, true), others, subtitle, keywords)
    }

    private fun tokenScore(token: String, field: Field): Int {
        val word = if (field.primary) TITLE_WORD else OTHER_WORD
        val prefix = if (field.primary) TITLE_PREFIX else OTHER_PREFIX
        val substring = if (field.primary) TITLE_SUBSTRING else OTHER_SUBSTRING
        val typo = if (field.primary) TITLE_TYPO else OTHER_TYPO
        var best = 0
        for (w in field.words) {
            if (w == token) return word
            if (w.startsWith(token)) best = maxOf(best, prefix)
        }
        if (best > 0) return best
        if (token.length >= 2 && field.text.contains(token)) return substring
        if (token.length >= 4 && token.any { !it.isDigit() }) {
            if (field.words.any { isTypo(token, it) }) return typo
            // A typo in a word still being typed is weaker evidence than one in a whole word.
            if (field.words.any { it.length > token.length && isTypo(token, it.take(token.length)) }) return typo / 2
        }
        return 0
    }

    /** One insertion, deletion, substitution or swap of neighbours; the first letter stays unless it was swapped. */
    internal fun isTypo(token: String, word: String): Boolean {
        if (token == word) return false
        if (osaDistance(token, word) != 1) return false
        if (token.length == word.length && token.length >= 2) {
            val diff = token.indices.filter { token[it] != word[it] }
            if (diff.size == 2 && diff[1] == diff[0] + 1 && token[diff[0]] == word[diff[1]] && token[diff[1]] == word[diff[0]]) return true
        }
        return token.firstOrNull() == word.firstOrNull()
    }

    /** Optimal string alignment distance (Levenshtein plus swaps of neighbours). */
    internal fun osaDistance(a: String, b: String): Int {
        if (a == b) return 0
        if (a.isEmpty()) return b.length
        if (b.isEmpty()) return a.length
        val d = Array(a.length + 1) { IntArray(b.length + 1) }
        for (i in 0..a.length) d[i][0] = i
        for (j in 0..b.length) d[0][j] = j
        for (i in 1..a.length) {
            for (j in 1..b.length) {
                val cost = if (a[i - 1] == b[j - 1]) 0 else 1
                var v = minOf(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) v = minOf(v, d[i - 2][j - 2] + 1)
                d[i][j] = v
            }
        }
        return d[a.length][b.length]
    }

    private fun phraseBonus(query: String, p: Prepared): Int {
        val title = p.title.text
        return when {
            title == query -> 1200
            title.startsWith(query) -> 900
            title.contains(" $query") -> 700
            p.keywords.any { it == query } -> 600
            p.keywords.any { it.startsWith(query) } -> 500
            p.subtitle.contains(query) -> 200
            else -> 0
        }
    }

    /** The score of [doc] for an already folded query, or null when a word of it matches nothing. */
    private fun score(query: String, tokens: List<String>, p: Prepared): Int? {
        var total = 0
        for (token in tokens) {
            val best = maxOf(tokenScore(token, p.title), p.others.maxOfOrNull { tokenScore(token, it) } ?: 0)
            if (best == 0) return null
            total += best
        }
        return total + phraseBonus(query, p)
    }

    /** The rows matching [query], best first; equal scores keep the order of [docs]. An empty query finds nothing. */
    fun search(query: String, docs: List<SearchDoc>): List<SearchHit> {
        val folded = fold(query)
        if (folded.isEmpty()) return emptyList()
        val tokens = folded.split(' ')
        return docs.mapIndexedNotNull { index, doc ->
            val p = prepare(doc)
            score(folded, tokens, p)?.let { s ->
                SearchHit(index, s, highlight(doc.title, query), doc.subtitle?.let { highlight(it, query) }.orEmpty())
            }
        }.sortedWith(compareByDescending<SearchHit> { it.score }.thenBy { it.index })
    }

    /**
     * Where each typed word literally appears in [text]: its first match at a word start, else its first
     * match anywhere. Words that only matched with a typo mark nothing; a guess has no honest range.
     */
    fun highlight(text: String, query: String): List<IntRange> {
        val folded = foldAligned(text)
        val ranges = mutableListOf<IntRange>()
        for (token in fold(query).split(' ').filter { it.isNotEmpty() }) {
            var start = -1
            var from = folded.indexOf(token)
            while (from >= 0) {
                if (from == 0 || folded[from - 1] == ' ') {
                    start = from
                    break
                }
                from = folded.indexOf(token, from + 1)
            }
            if (start < 0) start = folded.indexOf(token)
            if (start >= 0) ranges += start until start + token.length
        }
        return merge(ranges)
    }

    private fun merge(ranges: List<IntRange>): List<IntRange> {
        val sorted = ranges.sortedBy { it.first }
        val out = mutableListOf<IntRange>()
        for (r in sorted) {
            val last = out.lastOrNull()
            if (last != null && r.first <= last.last + 1) out[out.lastIndex] = last.first..maxOf(last.last, r.last) else out += r
        }
        return out
    }

    /**
     * For "No results": the [count] rows whose title, a title word or a synonym is the fewest edits away from
     * the query. Always offers [count] rows when there are that many.
     */
    fun closest(query: String, docs: List<SearchDoc>, count: Int = 3): List<Int> {
        val q = fold(query)
        if (q.isEmpty()) return emptyList()
        return docs.mapIndexed { index, doc ->
            val p = prepare(doc)
            val candidates = buildList {
                add(p.title.text)
                addAll(p.title.words)
                p.keywords.forEach { k -> add(k); addAll(k.split(' ')) }
            }.filter { it.isNotEmpty() }
            index to (candidates.minOfOrNull { osaDistance(q, it) } ?: Int.MAX_VALUE)
        }.sortedWith(compareBy<Pair<Int, Int>> { it.second }.thenBy { it.first })
            .map { it.first }
            .distinctBy { docs[it].title }
            .take(count)
    }
}
