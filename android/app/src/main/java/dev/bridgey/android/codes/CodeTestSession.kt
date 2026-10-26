package dev.bridgey.android.codes

import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.provider.Telephony
import java.net.HttpURLConnection
import java.net.URL
import kotlin.random.Random
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/** What the Code reader test screen shows. */
sealed interface CodeTestState {
    data object Idle : CodeTestState
    data class Reading(val read: Int) : CodeTestState
    /** The cloud extractor is working through [total] messages, about [secondsLeft] to go. */
    data class Cloud(val done: Int, val total: Int, val secondsLeft: Int) : CodeTestState
    /** One message to confirm: its text and the candidates. Shown under FLAG_SECURE. */
    data class Review(val position: Int, val count: Int, val messageId: Int, val body: String, val candidates: List<String>) : CodeTestState
    data class Report(val report: CodeTestReport) : CodeTestState
    data class Failed(val reason: Reason) : CodeTestState

    enum class Reason { NO_PERMISSION, READ_FAILED, EMPTY }
}

/**
 * One run of the Code reader test, kept in this process only. Messages live in memory until the
 * report is made, then they are dropped; nothing is written to disk. Delete clears everything.
 */
object CodeTestSession {
    const val DEFAULT_LIMIT = 2_000
    /** Cloud requests stay under the relay's 10 a minute for one install. */
    const val CLOUD_LIMIT = 120
    private const val CLOUD_SPACING_MS = 7_000L

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutableState = MutableStateFlow<CodeTestState>(CodeTestState.Idle)
    val state: StateFlow<CodeTestState> = mutableState.asStateFlow()
    private var job: Job? = null
    private var run: CodeTestRun? = null
    private var queue: List<Int> = emptyList()
    private var position = 0
    private val labels = mutableMapOf<Int, Label>()
    private var startSeen = 0
    private var startHidden = 0
    private var startFacts: (() -> PlatformFacts)? = null
    private var device: DeviceFacts? = null

    /** The cloud extractor needs the edition's relay; null when this build has none. */
    fun cloudAvailable(relayUrl: String): Boolean = relayUrl.startsWith("https://")

    fun start(context: Context, limit: Int, useCloud: Boolean, relayUrl: String, appVersion: String, access: CodeAccessMonitor) {
        if (job?.isActive == true) return
        clear()
        val appContext = context.applicationContext
        startSeen = access.smsSeen.get()
        startHidden = access.smsHidden.get()
        device = DeviceFacts(Build.MANUFACTURER, Build.MODEL, Build.VERSION.RELEASE, appVersion)
        startFacts = {
            access.refresh()
            PlatformFacts(
                sdkInt = Build.VERSION.SDK_INT,
                codeAccess = access.status.value,
                companionLinked = access.isLinked(),
                appOpAllowed = access.appOpAllowed(),
                smsNotificationsSeen = access.smsSeen.get() - startSeen,
                smsNotificationsHidden = access.smsHidden.get() - startHidden,
            )
        }
        mutableState.value = CodeTestState.Reading(0)
        job = scope.launch {
            val messages = runCatching { readInbox(appContext, limit) }.getOrElse { error ->
                mutableState.value = CodeTestState.Failed(
                    if (error is SecurityException) CodeTestState.Reason.NO_PERMISSION else CodeTestState.Reason.READ_FAILED,
                )
                return@launch
            }
            if (messages.isEmpty()) {
                mutableState.value = CodeTestState.Failed(CodeTestState.Reason.EMPTY)
                return@launch
            }
            val pattern = messages.associate { message ->
                val started = SystemClock.elapsedRealtimeNanos()
                val code = PatternBaseline.extract(message.body)?.let { CodeGuard.accept(it, message.body) ?: it }
                message.id to ExtractorAnswer(code, (SystemClock.elapsedRealtimeNanos() - started) / 1_000_000)
            }
            val answers = mutableMapOf<Extractor, Map<Int, ExtractorAnswer>>(Extractor.PATTERN to pattern)
            if (useCloud && cloudAvailable(relayUrl)) {
                val random = Random(SystemClock.elapsedRealtimeNanos())
                val selection = cloudSelection(messages, pattern.filterValues { it.code != null }.keys, CLOUD_LIMIT, random)
                val byId = messages.associateBy { it.id }
                val installId = CodeRelay.newInstallId()
                val cloud = mutableMapOf<Int, ExtractorAnswer>()
                selection.forEachIndexed { index, id ->
                    if (!isActive) return@launch
                    mutableState.value = CodeTestState.Cloud(index, selection.size, ((selection.size - index) * CLOUD_SPACING_MS / 1000).toInt())
                    val began = SystemClock.elapsedRealtime()
                    cloud[id] = askRelay(relayUrl, installId, byId.getValue(id).body)
                    val waited = SystemClock.elapsedRealtime() - began
                    if (index < selection.lastIndex) delay((CLOUD_SPACING_MS - waited).coerceAtLeast(0))
                }
                answers[Extractor.CLOUD] = cloud
            }
            val built = CodeTestRun(messages, answers)
            run = built
            queue = built.reviewQueue(Random(SystemClock.elapsedRealtimeNanos()))
            position = 0
            showCurrent()
        }
    }

    /** The person's answer for the message on screen. */
    fun label(label: Label) {
        val id = queue.getOrNull(position) ?: return
        labels[id] = label
        position++
        showCurrent()
    }

    /** Stop reviewing; the rest stays provisional or unknown. */
    fun finishReview() {
        position = queue.size
        showCurrent()
    }

    private fun showCurrent() {
        val current = run ?: return
        val id = queue.getOrNull(position)
        if (id == null) {
            val facts = startFacts?.invoke() ?: return
            val report = CodeTestReport.build(current, labels.toMap(), facts, device ?: return, System.currentTimeMillis())
            // The report holds totals only; the messages go now.
            run = null
            queue = emptyList()
            labels.clear()
            mutableState.value = CodeTestState.Report(report)
            return
        }
        val message = current.messages.first { it.id == id }
        mutableState.value = CodeTestState.Review(position + 1, queue.size, id, message.body, current.candidates(id))
    }

    fun cancel() {
        job?.cancel()
        clear()
    }

    /** Delete this run: messages, labels and results. */
    fun delete() = cancel()

    private fun clear() {
        job = null
        run = null
        queue = emptyList()
        labels.clear()
        position = 0
        mutableState.value = CodeTestState.Idle
    }

    /** The inbox, newest first, at most [limit]; text in memory only, the address reduced to its kind. */
    private fun readInbox(context: Context, limit: Int): List<TestMessage> {
        val messages = ArrayList<TestMessage>()
        context.contentResolver.query(
            Telephony.Sms.Inbox.CONTENT_URI,
            arrayOf(Telephony.Sms.BODY, Telephony.Sms.ADDRESS),
            null, null, Telephony.Sms.Inbox.DEFAULT_SORT_ORDER,
        )?.use { cursor ->
            val body = cursor.getColumnIndexOrThrow(Telephony.Sms.BODY)
            val address = cursor.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)
            while (cursor.moveToNext() && messages.size < limit) {
                val text = cursor.getString(body)?.takeIf { it.isNotBlank() } ?: continue
                messages += TestMessage(messages.size, text, senderKind(cursor.getString(address)), scriptOf(text))
                if (messages.size % 200 == 0) mutableState.value = CodeTestState.Reading(messages.size)
            }
        } ?: throw IllegalStateException("no cursor")
        return messages
    }

    /** One request to the relay, guarded like the Mac does; any failure counts as a failure. */
    private fun askRelay(relayUrl: String, installId: String, text: String): ExtractorAnswer {
        val body = CodeRelay.requestBody(text, null) ?: return ExtractorAnswer(null, 0)
        val started = SystemClock.elapsedRealtime()
        return runCatching {
            val connection = URL(relayUrl.trimEnd('/') + "/v1/extract").openConnection() as HttpURLConnection
            try {
                connection.requestMethod = "POST"
                connection.connectTimeout = CodeRelay.TIMEOUT_MS
                connection.readTimeout = CodeRelay.TIMEOUT_MS
                connection.useCaches = false
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                connection.setRequestProperty("X-Bridgey-Install", installId)
                connection.setRequestProperty("User-Agent", "BridgeyRR/1 (Android)")
                connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
                val status = connection.responseCode
                val stream = if (status in 200..299) connection.inputStream else connection.errorStream
                val reply = stream?.use { it.readBytes().toString(Charsets.UTF_8) }.orEmpty()
                val elapsed = SystemClock.elapsedRealtime() - started
                when (val answer = CodeRelay.parse(status, reply)) {
                    is CodeRelay.Answer.Candidate -> ExtractorAnswer(CodeGuard.accept(answer.code, text), elapsed)
                    CodeRelay.Answer.NoCode -> ExtractorAnswer(null, elapsed)
                    is CodeRelay.Answer.Failed -> ExtractorAnswer(null, elapsed, failed = true)
                }
            } finally {
                connection.disconnect()
            }
        }.getOrElse { ExtractorAnswer(null, SystemClock.elapsedRealtime() - started, failed = true) }
    }
}
