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
        Rule("clipboard", Answers.PICK, listOf("copy", "copi", "paste", "clipboard", "копир", "скопир", "встав", "буфер")),
        Rule("notifications", Answers.PICK, listOf("notif", "alert", "whatsapp", "telegram", "уведомл", "оповещ")),
        Rule("codes", Answers.YES, listOf("code", "otp", "код")),
        Rule("messages", Answers.PICK, listOf("sms", "texts", "texting", "смс", "эсэмэс")),
        Rule("calls", Answers.PICK, listOf("call", "звон", "вызов")),
        Rule("files", Answers.PICK, listOf("file", "photo", "picture", "folder", "файл", "фото", "папк", "снимк")),
        Rule("remote", Answers.PICK, listOf("touchpad", "trackpad", "mouse", "slide", "presentation", "тачпад", "мыш", "слайд", "презентац", "пульт")),
        Rule("mac_actions", Answers.PICK, listOf("lock", "sleep", "volume", "блокир", "сон", "громк")),
        Rule("media", Answers.PICK, listOf("music", "spotify", "song", "музык", "песн")),
        Rule("camera", Answers.PICK, listOf("camera", "камер")),
        // Never plain "screen": "screenshot" is the clipboard's.
        Rule("screen", Answers.PICK, listOf(
            "mirror", "screen shar", "share screen", "share my screen", "share the screen", "see my screen", "phone screen", "phone's screen",
            "трансляц", "показ экран", "показать экран", "демонстрац", "экран телефона",
        )),
        Rule("focus", Answers.BOTH, listOf("dnd", "focus", "фокус")),
        Rule("links", Answers.PICK, listOf("link", "url", "browser", "ссылк", "браузер")),
        Rule("find", Answers.PICK, listOf("find my", "lost", "ring", "найти", "потерял")),
        Rule("battery", Answers.PICK, listOf("battery", "батаре", "заряд")),
        Rule("updates", Answers.NEWEST, listOf("nightly", "newest", "every day", "ночн", "каждый день"), negatable = false),
        Rule("updates", Answers.EARLY, listOf("beta", "early", "бета", "раньше"), negatable = false),
        Rule("updates", Answers.STEADY, listOf("stable", "steady", "стабил"), negatable = false),
    )

    /** Every id typing can answer on this phone: the features, their follow-ups, Focus and updates. */
    val targets: List<String>
        get() = (SetupFeatures.all.map { it.id } + SetupQuestions.all.map { it.id } + SetupQuestions.typedOnly.keys).distinct()

    private val negations = setOf("no", "not", "don't", "dont", "without", "never", "нет", "не", "без", "никаких")

    /** Names that contain a negation word; read as one word, so they negate nothing. */
    private val names = mapOf("do not disturb" to "dnd", "не беспокоить" to "dnd")

    fun words(text: String): List<String> {
        var lower = text.lowercase().replace('ё', 'е')
        names.forEach { (name, token) -> lower = lower.replace(name, token) }
        return lower.split(Regex("[^\\p{L}\\p{N}']+")).filter { it.isNotEmpty() }
    }

    /**
     * The answers [text] asks for, by feature or question id, in rule order, for the ids this device
     * has ([available]). The first matching rule per id wins.
     */
    fun match(text: String, available: Collection<String> = targets): Map<String, String> {
        val tokens = words(text)
        if (tokens.isEmpty()) return emptyMap()
        val found = LinkedHashMap<String, String>()
        for (rule in rules) {
            if (rule.question !in available || rule.question in found) continue
            val hit = rule.stems.firstNotNullOfOrNull { stem -> find(tokens, stem) } ?: continue
            val negated = rule.negatable && tokens.subList((hit - 3).coerceAtLeast(0), hit).any { it in negations }
            found[rule.question] = if (negated) Answers.NO else rule.answer
        }
        return found.filterKeys { it in available }
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
