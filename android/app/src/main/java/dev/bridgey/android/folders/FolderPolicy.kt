package dev.bridgey.android.folders

/**
 * Who decides where a folder lands and what happens when it exists (3.2, 3.3, D3, D5, D15), as pure
 * functions so every branch is unit tested. The receiving device's own settings decide.
 */
object FolderPolicy {
    /** Where the destination question shows, or that there is none. */
    sealed interface Destination {
        /** Mode (a): the sender picked this destination in its send sheet. */
        data class Offered(val destination: FolderDestination) : Destination

        /** Mode (c): the receiver's default folder. */
        data object Fixed : Destination

        /** The receiver asks its own user (the Save to… sheet), for [reason]. */
        data class AskHere(val reason: AskReason) : Destination
    }

    enum class AskReason {
        /** Mode (b). */
        MODE,

        /** Mode (a), but the offer carries no destination (an older sender, or the sender skipped places). */
        NO_DESTINATION,

        /** Mode (c), but the default folder lost access (D15): never a silent fallback to Download/Bridgey. */
        DEFAULT_UNAVAILABLE,
    }

    fun destination(mode: DestinationMode, offered: FolderDestination?, defaultAvailable: Boolean): Destination = when (mode) {
        DestinationMode.SENDER_PICKS -> offered?.let(Destination::Offered) ?: Destination.AskHere(AskReason.NO_DESTINATION)
        DestinationMode.RECEIVER_ASKS -> Destination.AskHere(AskReason.MODE)
        DestinationMode.FIXED -> if (defaultAvailable) Destination.Fixed else Destination.AskHere(AskReason.DEFAULT_UNAVAILABLE)
    }

    enum class Existing { NONE, FOLDER, FILE }

    enum class Asker { SENDER, RECEIVER }

    sealed interface Conflict {
        data class Proceed(val choice: ConflictChoice) : Conflict
        data class Ask(val where: Asker, val choices: List<ConflictChoice>) : Conflict
    }

    /** The question shows where the destination was chosen (D5): the sender in mode (a), the receiver otherwise. */
    fun askerFor(destination: Destination): Asker = if (destination is Destination.Offered) Asker.SENDER else Asker.RECEIVER

    /**
     * What happens when the destination already has an item named like the folder. An existing file only
     * allows Save as new folder: a preset Merge or Replace becomes Save as new folder. A folder is never
     * replaced by a file or the reverse.
     */
    fun conflict(existing: Existing, policy: ConflictPolicy, asker: Asker): Conflict = when (existing) {
        Existing.NONE -> Conflict.Proceed(ConflictChoice.NONE)
        Existing.FILE -> if (policy == ConflictPolicy.ASK) Conflict.Ask(asker, listOf(ConflictChoice.NEW_FOLDER))
        else Conflict.Proceed(ConflictChoice.NEW_FOLDER)
        Existing.FOLDER -> when (policy) {
            ConflictPolicy.ASK -> Conflict.Ask(asker, listOf(ConflictChoice.MERGE, ConflictChoice.REPLACE, ConflictChoice.NEW_FOLDER))
            ConflictPolicy.MERGE -> Conflict.Proceed(ConflictChoice.MERGE)
            ConflictPolicy.REPLACE -> Conflict.Proceed(ConflictChoice.REPLACE)
            ConflictPolicy.NEW_FOLDER -> Conflict.Proceed(ConflictChoice.NEW_FOLDER)
        }
    }

    /** Whether an answer from the sender is one of the choices it was offered (or cancel). */
    fun isOffered(choice: ConflictChoice, offered: List<ConflictChoice>): Boolean = choice == ConflictChoice.CANCEL || choice in offered

    /**
     * Replace safety (Rahul, 2026-10-25): "Allow other devices to replace files here" is a phone-only switch,
     * off by default. While it is off, a Replace chosen on the other device asks on this phone first. A Replace
     * chosen on this phone (its own question, or its own preset) needs no second question.
     */
    fun replaceNeedsLocalConfirmation(choice: ConflictChoice, chosenBy: Asker, allowOtherDevicesToReplace: Boolean): Boolean =
        choice == ConflictChoice.REPLACE && chosenBy == Asker.SENDER && !allowOtherDevicesToReplace

    /** Seconds left on a question that started at [askedAtMillis]; 0 once it has timed out. */
    fun secondsLeft(askedAtMillis: Long, nowMillis: Long, timeoutSeconds: Int = FolderTimeouts.QUESTION_SECONDS): Int {
        val left = timeoutSeconds * 1000L - (nowMillis - askedAtMillis).coerceAtLeast(0)
        return if (left <= 0) 0 else ((left + 999) / 1000).toInt()
    }

    /** "2:41". */
    fun countdown(seconds: Int): String = "%d:%02d".format(seconds / 60, seconds % 60)
}

/** Recently used destinations for the Save to… sheet, newest first, at most [limit], without repeats. */
fun recentDestinations(previous: List<FolderDestination>, used: FolderDestination, limit: Int = 5): List<FolderDestination> =
    (listOf(used) + previous.filterNot { it == used }).take(limit)
