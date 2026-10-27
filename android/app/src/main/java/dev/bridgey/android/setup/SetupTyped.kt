package dev.bridgey.android.setup

/**
 * "Type what you want": plain keyword rules, on this phone, in English and Russian. No model is
 * used here, even when codes from messages use one. Every match is shown for confirmation before
 * anything changes. A keyword matches the start of a word ("notif" matches "notifications"); a
 * no, not, without (нет, не, без) up to three words before it turns the answer into No. The Mac
 * has the same rules and the same test sentences.
 */
object SetupTyped {
    /** A question, the answer a mention means, and the word stems that mention it. */
    data class Rule(val question: String, val answer: String, val stems: List<String>, val negatable: Boolean = true)

    val rules: List<Rule> = listOf(
        Rule("clipboard", Answers.AUTO, listOf("copy", "copi", "paste", "clipboard", "копир", "скопир", "встав", "буфер")),
        Rule("notifications", Answers.YES, listOf("notif", "alert", "whatsapp", "telegram", "уведомл", "оповещ")),
        Rule("codes", Answers.YES, listOf("code", "otp", "код")),
        Rule("calls", Answers.YES, listOf("call", "звон", "вызов")),
        Rule("files", Answers.YES, listOf("file", "photo", "picture", "folder", "файл", "фото", "папк", "снимк")),
        Rule("remote", Answers.YES, listOf("touchpad", "trackpad", "mouse", "slide", "presentation", "тачпад", "мыш", "слайд", "презентац", "пульт")),
        Rule("mac_actions", Answers.YES, listOf("lock", "sleep", "volume", "блокир", "сон", "громк")),
        Rule("media", Answers.YES, listOf("music", "spotify", "song", "музык", "песн")),
        Rule("camera", Answers.YES, listOf("camera", "камер")),
        Rule("focus", Answers.BOTH, listOf("dnd", "focus", "фокус")),
        Rule("links", Answers.YES, listOf("link", "url", "browser", "ссылк", "браузер")),
        Rule("find", Answers.YES, listOf("find my", "lost", "ring", "найти", "потерял")),
        Rule("battery", Answers.YES, listOf("battery", "батаре", "заряд")),
        Rule("updates", Answers.NEWEST, listOf("nightly", "newest", "every day", "ночн", "каждый день"), negatable = false),
        Rule("updates", Answers.EARLY, listOf("beta", "early", "бета", "раньше"), negatable = false),
        Rule("updates", Answers.STEADY, listOf("stable", "steady", "стабил"), negatable = false),
    )

    private val negations = setOf("no", "not", "don't", "dont", "without", "never", "нет", "не", "без", "никаких")

    /** Names that contain a negation word; read as one word, so they negate nothing. */
    private val names = mapOf("do not disturb" to "dnd", "не беспокоить" to "dnd")

    fun words(text: String): List<String> {
        var lower = text.lowercase().replace('ё', 'е')
        names.forEach { (name, token) -> lower = lower.replace(name, token) }
        return lower.split(Regex("[^\\p{L}\\p{N}']+")).filter { it.isNotEmpty() }
    }

    /**
     * The answers [text] asks for, by question id, in question order, for the questions this
     * device has ([available]). The first matching rule per question wins.
     */
    fun match(text: String, available: Collection<String>): Map<String, String> {
        val tokens = words(text)
        if (tokens.isEmpty()) return emptyMap()
        val found = LinkedHashMap<String, String>()
        for (rule in rules) {
            if (rule.question !in available || rule.question in found) continue
            val hit = rule.stems.firstNotNullOfOrNull { stem -> find(tokens, stem) } ?: continue
            val negated = rule.negatable && tokens.subList((hit - 3).coerceAtLeast(0), hit).any { it in negations }
            found[rule.question] = if (negated) Answers.NO else rule.answer
        }
        return available.filter { it in found }.associateWith { found.getValue(it) }
    }

    /** Where [stem] starts in [tokens]: each of its words must match, the last one as a prefix. */
    private fun find(tokens: List<String>, stem: String): Int? {
        val parts = words(stem)
        if (parts.isEmpty() || parts.size > tokens.size) return null
        return (0..tokens.size - parts.size).firstOrNull { start ->
            parts.indices.all { i -> if (i == parts.lastIndex) tokens[start + i].startsWith(parts[i]) else tokens[start + i] == parts[i] }
        }
    }
}
