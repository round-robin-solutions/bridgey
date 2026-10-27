package dev.bridgey.android

import android.content.Context
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.ContentValues
import android.os.PersistableBundle
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.provider.MediaStore
import android.os.SystemClock
import android.media.AudioAttributes
import android.media.Ringtone
import android.media.RingtoneManager
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import dev.bridgey.core.discovery.DiscoveredPeer
import java.io.BufferedWriter
import java.io.BufferedInputStream
import java.io.OutputStreamWriter
import java.io.OutputStream
import java.math.BigInteger
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.ensureActive
import kotlin.coroutines.coroutineContext
import org.json.JSONObject
import org.json.JSONArray

sealed interface PairingState {
    data object Idle : PairingState
    data class Connecting(val peerName: String) : PairingState
    data class Verification(val peerName: String, val code: String) : PairingState
    data class Connected(val deviceId: String, val peerName: String) : PairingState
    data class Failed(val message: String, val reason: PairingFailure? = null) : PairingState
}

enum class ClipboardSendResult {
    DELIVERED,
    EMPTY,
    DISABLED,
    NOT_CONNECTED,
    CONNECTION_LOST,
    NO_ACKNOWLEDGEMENT,
    TOO_LARGE,
}

/** A screenshot whose send ended like this did not reach the Mac, so a later tap may send it again. */
internal val SCREENSHOT_NOT_SENT = setOf(
    ClipboardSendResult.EMPTY,
    ClipboardSendResult.DISABLED,
    ClipboardSendResult.NOT_CONNECTED,
    ClipboardSendResult.CONNECTION_LOST,
    ClipboardSendResult.TOO_LARGE,
)

data class FileTransferState(
    val id: String,
    val name: String,
    val status: String,
    val active: Boolean,
    val progressPercent: Int?,
    val startedAtMillis: Long = System.currentTimeMillis(),
    val retryable: Boolean = false,
    /** The device on the other end of the transfer. */
    val deviceId: String? = null,
    val deviceName: String = "",
    /** Waiting in the send queue; not offered to the device yet. */
    val queued: Boolean = false,
    /** A file, or a whole folder in one row (6.5). */
    val kind: TransferKind = TransferKind.FILE,
    /** Folders: files and bytes, destination, waiting state, current file, failures and the last names. */
    val folder: dev.bridgey.android.folders.FolderSnapshot? = null,
    /** How it ended, set where it ends; the activity stream reads this instead of the status text. */
    val outcome: TransferEnd? = null,
)

enum class TransferKind { FILE, FOLDER }

/** How a transfer ended. Folders keep the details in [FileTransferState.folder]. */
enum class TransferEnd { SENT, RECEIVED, FAILED, CANCELLED, INTERRUPTED }

data class TrustedDevice(val id: String, val name: String)

/** "Look for devices again": running, or done with who answered and who did not. */
sealed interface RediscoverState {
    data object Running : RediscoverState
    data class Done(val found: List<String>, val stillMissing: List<String>) : RediscoverState
}

/** Events reported to the activity stream. Only clipboard events carry text, for the stream's preview. */
enum class PeerActivity {
    CLIPBOARD_SENT, CLIPBOARD_RECEIVED, CLIPBOARD_RECEIVE_FAILED, PING_RECEIVED, CALL_STARTED,
    CLIP_OFFER_SENT, CLIP_OFFER_RECEIVED, CLIP_PASTED, CLIP_PASTE_FAILED,
    PING_SENT, FIND_REMOTE_STARTED, FIND_PHONE_STARTED,
}

data class PeerEvent(
    val activity: PeerActivity,
    val deviceId: String,
    val deviceName: String,
    /** Clipboard text (plain text of rich clips); the stream keeps a short preview only. */
    val clipboardText: String? = null,
    /** The clip was marked sensitive (ClipDescription.EXTRA_IS_SENSITIVE). */
    val sensitive: Boolean = false,
    /** Automatic clipboard moved this, rather than a manual Send. */
    val automatic: Boolean = false,
    /** Clipboard offers: "text", "image" or "file", how many items, total bytes, a single file's name. */
    val clipContent: String? = null,
    val clipCount: Int = 1,
    val clipBytes: Long? = null,
    val clipName: String? = null,
)

data class RemoteBatteryStatus(val level: Int, val isCharging: Boolean)

/**
 * Multi-device sessions: one authenticated session per trusted device (several Macs at once), plus
 * pending sessions that are still handshaking or pairing. Pairing a new device never touches the
 * others. Outgoing actions go to the selected device; broadcasts (notifications, calls, battery,
 * automatic clipboard) go to every connected device that has the feature on.
 */
class PairingCoordinator(
    context: Context,
    private val localDeviceId: String,
    localDeviceName: String,
    private val port: Int = 42_458,
    private val settings: BridgeySettings,
) {
    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    val quickActions = QuickActions(appContext, scope, { isFeatureAvailable(it) }, ::sendQuickPayload, ::linksOpenSupported)
    private val registry = SessionRegistry<Session>(localDeviceId)

    /** Mac actions (draft `mac_actions_draft1`): each Mac's list, runs and results. */
    val macActions = dev.bridgey.android.actions.MacActionsClient(
        store = dev.bridgey.android.actions.SharedPreferencesCatalogStore(appContext),
        timer = { delayMillis, block -> scope.launch { delay(delayMillis); block() }.let { job -> { job.cancel() } } },
        available = { id -> registry.session(id) != null && isFeatureAvailable(BridgeyFeature.MAC_ACTIONS, id) },
        send = ::sendActionsPayload,
    )

    /**
     * Focus and Do Not Disturb sync (draft `focus_sync_draft1`): this phone's Do Not Disturb to the
     * Macs, and the Macs' Focus to Do Not Disturb, each direction its own opt-in.
     */
    val focusSync = dev.bridgey.android.focus.FocusSync(
        quiet = dev.bridgey.android.focus.AndroidQuietMode(appContext),
        clock = System::currentTimeMillis,
        shareOn = { settings.state.value.focusShare },
        followOn = { settings.state.value.focusFollow },
        peers = { registry.connectedIds().filter { registry.state(it)?.remoteFocusSync == true } },
        send = ::sendFocusState,
    )
    /** Phone camera to Mac (draft `camera_draft1`): each Mac's open photo request. */
    val camera = dev.bridgey.android.camera.CameraRequests(System::currentTimeMillis)

    /** Set by the application: a Mac's photo request was accepted; show the camera or its notification. */
    @Volatile var cameraRequested: (dev.bridgey.android.camera.CameraRequest) -> Unit = {}

    /** Set by the application: a request ended without a photo (expired, Mac gone, feature off). */
    @Volatile var cameraEnded: (dev.bridgey.android.camera.CameraRequest) -> Unit = {}

    /** Camera photos being sent: transfer ID to request ID, and what to do when the transfer ends. */
    private val cameraTransfers = ConcurrentHashMap<String, String>()
    private val cameraTransferDone = ConcurrentHashMap<String, (Boolean) -> Unit>()
    private val cameraTransferSent = ConcurrentHashMap.newKeySet<String>()
    private var lastFocusShare = settings.state.value.focusShare
    private var lastFocusFollow = settings.state.value.focusFollow

    /** Connection health per device: route class, round trip, drops, reconnects. Never addresses. */
    val health = dev.bridgey.android.health.ConnectionHealthBook()

    /**
     * Reconnects. Both sides keep trying a dropped trusted device at its known addresses, whoever
     * dialled before; the session registry keeps one socket when both dial at once.
     */
    private val reconnectClock = AndroidReconnectClock()
    internal val reconnect = ReconnectEngine(KnownAddressBook(SharedPreferencesAddressBookStore(context.applicationContext)), reconnectClock)
    private val linkDebouncer = EventDebouncer(reconnectClock) { reasons -> linkChanged(reasons) }

    /** Set by the application: restarts NSD (re-register and browse) with a reason. */
    @Volatile var restartDiscovery: (String) -> Unit = {}

    /** Set by the application: the Wi-Fi and Ethernet networks this phone is on. */
    @Volatile var localNetworks: () -> List<LocalIPv4Network> = { emptyList() }
    @Volatile private var reconnecting = false
    @Volatile private var lastPeers: List<DiscoveredPeer> = emptyList()
    private val discoveryLock = Any()
    private var discoveryRestartTask: ScheduledTask? = null
    private var lastDiscoveryRestart = 0L
    private var discoveryWindowStart: Long? = null
    private val mutableReconnectStates = MutableStateFlow<Map<String, ReconnectDisplay>>(emptyMap())

    /** Each disconnected trusted device's reconnect state, for the rings. */
    val reconnectStates: StateFlow<Map<String, ReconnectDisplay>> = mutableReconnectStates.asStateFlow()
    private val mutableRediscover = MutableStateFlow<RediscoverState?>(null)

    /** "Look for devices again" feedback. */
    val rediscover: StateFlow<RediscoverState?> = mutableRediscover.asStateFlow()
    private var rediscoverRun: Triple<Map<String, String>, Set<String>, ScheduledTask>? = null
    private val publishLock = Any()
    private var publishedTarget: String? = null

    /** Aggregate: Connected (to the selected device) while any device is connected, else the pairing flow. */
    private val mutableState = MutableStateFlow<PairingState>(PairingState.Idle)
    val state: StateFlow<PairingState> = mutableState.asStateFlow()

    /** The pairing in progress only: Connecting, Verification or Failed, else Idle. Owns the prompt. */
    private val mutablePairingFlow = MutableStateFlow<PairingState>(PairingState.Idle)
    val pairingFlow: StateFlow<PairingState> = mutablePairingFlow.asStateFlow()
    @Volatile private var pairingSession: Session? = null

    private val mutableConnections = MutableStateFlow<List<DeviceConnection>>(emptyList())

    /** Every connected device with its own features, battery and ringing state, in connection order. */
    val connections: StateFlow<List<DeviceConnection>> = mutableConnections.asStateFlow()
    @Volatile private var selectedDeviceId: String? = null

    private val identity = AndroidIdentity(context.applicationContext)
    private val trust = AndroidTrustRegistry(context.applicationContext)
    val trustedDeviceIds: StateFlow<Set<String>> = trust.trustedDeviceIds
    val trustedDevices: StateFlow<List<TrustedDevice>> = trust.trustedDevices
    @Volatile private var localDeviceName = localDeviceName
    private val mutableClipboardStatus = MutableStateFlow<String?>(null)
    val clipboardStatus: StateFlow<String?> = mutableClipboardStatus.asStateFlow()
    private val pendingClipboardSends = ConcurrentHashMap<String, (ClipboardSendResult) -> Unit>()
    private val autoClipboardTracker = AutoClipboardTracker()
    private val pendingFileAccepts = ConcurrentHashMap<String, CompletableDeferred<Boolean>>()
    private val pendingFileCompletions = ConcurrentHashMap<String, CompletableDeferred<Boolean>>()
    private val mutableFileTransferStatus = MutableStateFlow<String?>(null)
    val fileTransferStatus: StateFlow<String?> = mutableFileTransferStatus.asStateFlow()
    private val mutableFileTransferActive = MutableStateFlow(false)
    val fileTransferActive: StateFlow<Boolean> = mutableFileTransferActive.asStateFlow()
    private val mutableFileTransfers = MutableStateFlow<Map<String, FileTransferState>>(emptyMap())
    val fileTransfers: StateFlow<Map<String, FileTransferState>> = mutableFileTransfers.asStateFlow()
    private val mutablePhoneRinging = MutableStateFlow(false)
    val phoneRinging: StateFlow<Boolean> = mutablePhoneRinging.asStateFlow()
    @Volatile private var phoneRingingFrom: String? = null
    private val mutableMacRinging = MutableStateFlow(false)

    /** Any connected device is ringing. Per device: [connections]. */
    val macRinging: StateFlow<Boolean> = mutableMacRinging.asStateFlow()
    private val mutableRemoteBattery = MutableStateFlow<RemoteBatteryStatus?>(null)

    /** The selected device's battery. Per device: [connections]. */
    val remoteBattery: StateFlow<RemoteBatteryStatus?> = mutableRemoteBattery.asStateFlow()
    private val mutablePingStatus = MutableStateFlow<String?>(null)
    val pingStatus: StateFlow<String?> = mutablePingStatus.asStateFlow()
    @Volatile private var pendingPing: Pair<String, String>? = null
    private val mutableRemoteFeatures = MutableStateFlow(defaultFeatureState())

    /** The selected device's features. Per device: [connections]. */
    val remoteFeatures: StateFlow<Map<BridgeyFeature, Boolean>> = mutableRemoteFeatures.asStateFlow()
    private val incomingFiles = ConcurrentHashMap<String, IncomingFileTransfer>()
    private val cancelledTransferIds = ConcurrentHashMap.newKeySet<String>()
    private val outgoingFileJobs = ConcurrentHashMap<String, Job>()
    private val outgoingFileSources = ConcurrentHashMap<String, Uri>()

    /** Which device each file transfer belongs to. */
    private val transferDevices = ConcurrentHashMap<String, String>()

    /** One sequential send queue per device: a device gets one file at a time. */
    private val fileSendQueues = ConcurrentHashMap<String, FileSendQueue<Uri>>()
    val deviceId: String get() = localDeviceId
    private var server: ServerSocket? = null
    private var acceptJob: Job? = null
    private var findRingtone: Ringtone? = null
    /** Kept on disk, so the night's drops and retries are still in a report exported next morning. */
    private val diagnostics = BridgeyDiagnostics(limit = 1_000, file = java.io.File(appContext.noBackupFilesDir, "diagnostics.json"))
    private val remoteCallRequest = RemoteCallRequest(appContext)
    private var lastRemoteCallRequestAt = 0L
    private val clipboardCache = ClipboardCache(java.io.File(appContext.noBackupFilesDir, CLIPBOARD_CACHE_DIRECTORY))

    /** Clips from the Macs: offers, the cache and the content provider's backend. */
    internal val clipboardInbox = ClipboardInbox(clipboardCache, AndroidClipWriter(appContext))
    private val clipboardOutbox = ClipboardOutbox(scope, ContentClipSourceOpener(appContext.contentResolver))
    private val mutableRemoteClipboardFiles = MutableStateFlow(false)

    /** The selected device takes clipboard offers (it advertised clipboard_files_draft1). */
    val remoteClipboardFiles: StateFlow<Boolean> = mutableRemoteClipboardFiles.asStateFlow()

    /** Activity stream hook. Never logged or added to diagnostics. */
    @Volatile
    var activityListener: ((PeerEvent) -> Unit)? = null

    /** Places on this phone (granted folders plus Download/Bridgey). */
    val placesStore = dev.bridgey.android.folders.PlacesStore(appContext)
    val placeDirectory = dev.bridgey.android.folders.AndroidPlaceDirectory(appContext.contentResolver, placesStore)
    private val folderJournals = dev.bridgey.android.folders.FolderJournals(java.io.File(appContext.noBackupFilesDir, FOLDER_JOURNAL_DIRECTORY))
    private val folderTimers = java.util.concurrent.Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "bridgey-folder-timers").apply { isDaemon = true }
    }

    /** Folders sent to this phone (draft folders protocol): sessions, places serving and the phone's questions. */
    internal val folders = dev.bridgey.android.folders.FolderReceiver(
        places = placeDirectory,
        settings = { settings.state.value.folderReceiveSettings.copy(allowBrowse = browseAllowedHere()) },
        journals = folderJournals,
        listener = FolderEvents(),
        newWorker = { id -> dev.bridgey.android.folders.ThreadFolderWorker("bridgey-folder-${id.take(8)}") },
        scheduler = dev.bridgey.android.folders.ExecutorFolderScheduler(folderTimers),
        runPlaces = { task -> scope.launch { task() } },
        log = { BridgeyLogging.i(LogCategory.FILES, it) },
    )

    /** Files 2.0: folders sent from this phone (phone to Mac, and downloads the Mac asked for). */
    private val folderSendJournals = dev.bridgey.android.folders.FolderSendJournals(java.io.File(appContext.noBackupFilesDir, FOLDER_SEND_JOURNAL_DIRECTORY))
    internal val folderSender = dev.bridgey.android.folders.FolderSender(
        journals = folderSendJournals,
        listener = FolderSendEvents(),
        linkFor = { id -> registry.session(id)?.takeIf { sendsFoldersTo(id) && it.pairingKey != null }?.let(::FolderSendSessionLink) },
        newWorker = { id -> dev.bridgey.android.folders.ThreadFolderWorker("bridgey-folder-send-${id.take(8)}") },
        scheduler = dev.bridgey.android.folders.ExecutorFolderScheduler(folderTimers),
        prepare = { task -> scope.launch { task() } },
        openUri = { uri -> appContext.contentResolver.openInputStream(Uri.parse(uri)) ?: throw java.io.IOException("open failed") },
        log = { BridgeyLogging.i(LogCategory.FILES, it) },
    )

    /** Files 2.0: browse servers, one per device session; thumbnails and previews on a small pool. */
    private val browseServers = ConcurrentHashMap<String, dev.bridgey.android.browse.BrowseServer>()
    private val thumbnailPool = java.util.concurrent.Executors.newFixedThreadPool(3) { runnable ->
        Thread(runnable, "bridgey-thumbnails").apply {
            isDaemon = true
            priority = Thread.NORM_PRIORITY - 1
        }
    }
    private val mediaCoordinators = java.util.concurrent.Executors.newCachedThreadPool { runnable ->
        Thread(runnable, "bridgey-media-lane").apply { isDaemon = true }
    }
    private val thumbnailMaker: dev.bridgey.android.browse.ThumbnailMaker =
        dev.bridgey.android.browse.AndroidThumbnails(appContext.contentResolver, appContext)

    /** Questions this phone asks its user about folders (Save to…, conflicts), oldest first. */
    val folderQuestions: StateFlow<List<dev.bridgey.android.folders.FolderQuestion>> = folders.questions

    /** Remote input (draft): decrypted input.* messages from a device, for the remote input controller. */
    @Volatile
    var remoteInputListener: ((deviceId: String, kind: String, payload: ByteArray) -> Unit)? = null

    init {
        reconnect.isTrusted = { reconnecting && it in trust.trustedDeviceIds.value }
        reconnect.isConnected = { registry.session(it) != null }
        reconnect.networks = { localNetworks() }
        reconnect.dial = ::dialTrusted
        reconnect.onEvent = ::recordReconnect
        reconnect.onChange = ::publishReconnectStates
        clipboardInbox.listener = ::onClipboardInboxEvent
        clipboardInbox.linkFor = { id -> registry.session(id)?.takeIf { it.pairingKey != null }?.let(::SessionClipLink) }
        scope.launch {
            runCatching {
                clipboardCache.removePartials()
                clipboardCache.evict()
            }
        }
        // Folder journals (6.6): drop the stale ones, delete part files, finish interrupted replaces.
        scope.launch {
            runCatching {
                folderJournals.recover(::journalStore).forEach { record -> record.header.oneOffTree?.let(placesStore::releaseOneOff) }
            }
            // Folders this phone was sending come back as interrupted rows and resume when their Mac connects.
            runCatching { folderSender.loadJournals() }
        }
        scope.launch {
            settings.state.collect {
                if (!clipboardOffersEnabledLocally()) clipboardOutbox.supersede(currentClipLink())
                if (!featureEnabled(BridgeyFeature.CLIPBOARD)) mutableClipboardStatus.value = null
                registry.connectedIds().forEach { id ->
                    if (!settings.isEnabled(BridgeyFeature.BATTERY, id)) registry.update(id) { it.copy(battery = null) }
                }
                if (!featureEnabled(BridgeyFeature.PING)) clearPingStatus()
                publish()
                quickActions.policyChanged()
                // Mac actions turned off here for a Mac: its list goes, so controls stop offering it.
                trust.trustedDeviceIds.value.filter { !settings.isEnabled(BridgeyFeature.MAC_ACTIONS, it) }.forEach(macActions::revoked)
                registry.connectedIds().forEach { id -> registry.session(id)?.let(::sendFeatureState) }
                focusSettingsChanged(it.focusShare, it.focusFollow)
                registry.connectedIds().filter { id -> !isFeatureAvailable(BridgeyFeature.CAMERA, id) }.forEach(::endCameraRequest)
            }
        }
    }

    fun start() {
        if (acceptJob != null) return
        diagnostics.record("transport", "listener_started")
        startReconnecting()
        acceptJob = scope.launch {
            runCatching {
                ServerSocket(port).also { server = it }.use { listener ->
                    while (!listener.isClosed) {
                        val socket = listener.accept()
                        // Each connection reads on its own coroutine: a pairing in progress and any
                        // number of trusted reconnects run side by side.
                        scope.launch { handle(socket, initiatedLocally = false, peerHint = null) }
                    }
                }
            }.onFailure { if (server?.isClosed == false) failPairing(null, PairingFailure.COULD_NOT_CONNECT, "Pairing listener failed") }
        }
    }

    /** A pairing (or reconnect) the user started. Never disturbs other connected devices. */
    fun pair(host: String, port: Int, peerName: String) {
        diagnostics.record("pairing", "connection_started")
        BridgeyLogging.i(LogCategory.CONNECTION, "PAIRING started peer=$peerName")
        pairingSession?.let { previous ->
            pairingSession = null
            previous.send(Message(kind = "pairing.cancel", sessionId = previous.id))
            previous.close()
        }
        mutablePairingFlow.value = PairingState.Connecting(peerName)
        publish()
        scope.launch {
            runCatching { Socket().apply { connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MILLIS) } }
                .onSuccess { handle(it, initiatedLocally = true, peerHint = peerName, manual = true) }
                .onFailure {
                    if (mutablePairingFlow.value == PairingState.Connecting(peerName)) {
                        failPairing(null, PairingFailure.COULD_NOT_CONNECT, "Could not connect to $peerName")
                    }
                }
        }
    }

    // region Reconnect

    /** NSD's current list: the engine remembers trusted devices' addresses and tries new arrivals. */
    fun discoveryChanged(peers: List<DiscoveredPeer>) {
        lastPeers = peers
        reconnect.discoveryChanged(
            peers.mapNotNull { peer ->
                val id = peer.deviceIdHint ?: return@mapNotNull null
                // IP addresses work when mDNS lookups do not; the host only when there is no IP.
                val hosts = peer.addresses.ifEmpty { listOfNotNull(peer.host) }
                LivePeer(id, hosts, peer.port ?: ReconnectPolicy.LISTENING_PORT)
            },
        )
    }

    /** Every trusted device that is not connected is tried straight away at its last known addresses. */
    private fun startReconnecting() {
        reconnecting = true
        reconnect.addressBook.retain(trust.trustedDeviceIds.value)
        val ids = disconnectedTrustedIds()
        ids.forEach { reconnect.disconnected(it, seenNow = false) }
        reconnect.resetAll(ids)
        synchronized(discoveryLock) {
            discoveryWindowStart = if (ids.isEmpty()) null else SystemClock.elapsedRealtime()
            // NSD has only just started; the first periodic restart is five minutes away.
            lastDiscoveryRestart = SystemClock.elapsedRealtime()
        }
        armDiscoveryRestart()
    }

    private fun disconnectedTrustedIds(): List<String> =
        trust.trustedDeviceIds.value.filter { registry.session(it) == null }.sorted()

    private fun trustedName(id: String): String =
        trust.trustedDevices.value.firstOrNull { it.id == id }?.name
            ?: lastPeers.firstOrNull { it.deviceIdHint == id }?.deviceNameHint
            ?: "Mac"

    /** The engine's dial: a socket to [address]; [handle] reports the outcome back to the engine. */
    private fun dialTrusted(id: String, address: KnownAddress) {
        scope.launch {
            runCatching {
                Socket().apply { connect(InetSocketAddress(address.host, address.port), ReconnectPolicy.CONNECT_TIMEOUT_MILLIS) }
            }.onSuccess { socket ->
                handle(socket, initiatedLocally = true, peerHint = trustedName(id), dialDeviceId = id)
            }.onFailure { error ->
                val reason = socketDropReason(error)
                BridgeyLogging.i(LogCategory.CONNECTION, "RECONNECT dial failed peer=${id.take(8)} reason=$reason")
                diagnostics.record("reconnect", "dial_failed", reason, device = id)
                reconnect.dialEnded(id)
            }
        }
    }

    private fun recordReconnect(event: ReconnectEvent) {
        when (event) {
            is ReconnectEvent.Dial -> {
                val tag = addressTag(event.address.host)
                BridgeyLogging.i(LogCategory.CONNECTION, "RECONNECT dial peer=${event.deviceId.take(8)} attempt=${event.attempt} reason=${event.reason} source=${event.address.source.key} address=$tag")
                diagnostics.record("reconnect", "dial", event.reason, device = event.deviceId, detail = "n${event.attempt}_${event.address.source.key}_$tag")
                health.dialAttempt(event.deviceId, System.currentTimeMillis())
            }
            is ReconnectEvent.NoAddress -> {
                BridgeyLogging.i(LogCategory.CONNECTION, "RECONNECT no dialable address peer=${event.deviceId.take(8)} attempt=${event.attempt} reason=${event.reason}")
                diagnostics.record("reconnect", "no_address", event.reason, device = event.deviceId, detail = "n${event.attempt}")
            }
            is ReconnectEvent.FoundByDiscovery -> {
                BridgeyLogging.i(LogCategory.CONNECTION, "RECONNECT discovery found peer=${event.deviceId.take(8)} addresses=${event.addresses}")
                diagnostics.record("discovery", "found_trusted", device = event.deviceId, detail = "${event.addresses}_addresses")
            }
        }
    }

    /** NSD trouble (publish or browse failed) or a restart, for diagnostics. */
    fun discoveryEvent(event: String, detail: String) {
        diagnostics.record("discovery", event, detail)
    }

    /** "Retry now" on a disconnected device: every known address at once. */
    fun retryNow(deviceId: String) {
        BridgeyLogging.i(LogCategory.CONNECTION, "RECONNECT retry now peer=${deviceId.take(8)}")
        reconnect.dialEverywhere(deviceId, "retry_now")
    }

    private fun publishReconnectStates() {
        val states = trust.trustedDeviceIds.value.mapNotNull { id -> reconnect.display(id)?.let { id to it } }.toMap()
        if (mutableReconnectStates.value != states) mutableReconnectStates.value = states
    }

    /** A network, Doze or screen event from the application: recovery runs once the burst settles. */
    fun linkEvent(reason: String) {
        BridgeyLogging.i(LogCategory.CONNECTION, "RECONNECT link event $reason")
        diagnostics.record("link", reason, detail = PowerFacts.summary(appContext))
        linkDebouncer.note(reason)
    }

    /** A power change worth seeing next to a drop in diagnostics (screen off, Doze entered). */
    fun observe(event: String) {
        diagnostics.record("power", event, detail = PowerFacts.summary(appContext))
    }

    /** The network changed, the phone left Doze or the screen came on: look again and try every dropped device now. */
    private fun linkChanged(reasons: List<String>) {
        if (!reconnecting) return
        val reason = reasons.joinToString("+")
        val ids = disconnectedTrustedIds()
        // A new network needs this phone announced on it; screen on and Doze exit matter only
        // while a device is away (they happen dozens of times a day).
        val networkChanged = reasons.any { it != "screen_on" && it != "doze_exit" }
        if (ids.isEmpty() && !networkChanged) return
        BridgeyLogging.i(LogCategory.CONNECTION, "RECONNECT recovering after $reason disconnected=${ids.size}")
        val sinceRestart = SystemClock.elapsedRealtime() - synchronized(discoveryLock) { lastDiscoveryRestart }
        if (sinceRestart >= ReconnectPolicy.EVENT_RESTART_SPACING_MILLIS) restartDiscoveryNow(reason)
        reconnect.resetAll(ids)
        synchronized(discoveryLock) { discoveryWindowStart = if (ids.isEmpty()) null else SystemClock.elapsedRealtime() }
        armDiscoveryRestart()
    }

    private fun restartDiscoveryNow(reason: String) {
        synchronized(discoveryLock) { lastDiscoveryRestart = SystemClock.elapsedRealtime() }
        diagnostics.record("discovery", "restart", reason)
        restartDiscovery(reason)
    }

    /** Every five minutes while a trusted device is away, for the first hour; after a drop the first waits 30 s. */
    private fun armDiscoveryRestart() {
        synchronized(discoveryLock) {
            discoveryRestartTask?.cancel()
            discoveryRestartTask = null
            val start = discoveryWindowStart ?: return
            val now = SystemClock.elapsedRealtime()
            if (!reconnecting || disconnectedTrustedIds().isEmpty() || now - start >= ReconnectPolicy.DISCOVERY_RESTART_WINDOW_MILLIS) return
            val next = maxOf(lastDiscoveryRestart + ReconnectPolicy.DISCOVERY_RESTART_INTERVAL_MILLIS, now + 30_000)
            discoveryRestartTask = reconnectClock.schedule(next - now) {
                val due = synchronized(discoveryLock) {
                    discoveryRestartTask = null
                    val windowStart = discoveryWindowStart
                    reconnecting && windowStart != null && disconnectedTrustedIds().isNotEmpty() &&
                        SystemClock.elapsedRealtime() - windowStart < ReconnectPolicy.DISCOVERY_RESTART_WINDOW_MILLIS
                }
                if (due) {
                    restartDiscoveryNow("periodic")
                    armDiscoveryRestart()
                }
            }
        }
    }

    /**
     * "Look for devices again": restarts NSD, re-announces this phone, resets every backoff and
     * dials every known address of each disconnected trusted device. One run at a time.
     */
    fun lookForDevices() {
        val missing: Map<String, String>
        synchronized(discoveryLock) {
            if (rediscoverRun != null) return
            missing = disconnectedTrustedIds().associateWith(::trustedName)
            val nearbyBefore = lastPeers.mapNotNullTo(HashSet()) { it.deviceIdHint }
            val finish = reconnectClock.schedule(ReconnectPolicy.REDISCOVER_WINDOW_MILLIS) { finishRediscover() }
            rediscoverRun = Triple(missing, nearbyBefore, finish)
            discoveryWindowStart = if (missing.isEmpty()) null else SystemClock.elapsedRealtime()
        }
        mutableRediscover.value = RediscoverState.Running
        BridgeyLogging.i(LogCategory.CONNECTION, "RECONNECT look for devices again disconnected=${missing.size}")
        diagnostics.record("discovery", "manual", detail = "${missing.size}_disconnected")
        restartDiscoveryNow("manual")
        missing.keys.sorted().forEach { reconnect.dialEverywhere(it, "manual") }
        armDiscoveryRestart()
    }

    private fun finishRediscoverIfEveryoneAnswered() {
        val everyone = synchronized(discoveryLock) {
            val run = rediscoverRun ?: return
            run.first.isNotEmpty() && run.first.keys.all { registry.session(it) != null }
        }
        if (everyone) finishRediscover()
    }

    private fun finishRediscover() {
        val run = synchronized(discoveryLock) {
            val current = rediscoverRun ?: return
            rediscoverRun = null
            current
        }
        run.third.cancel()
        val (missing, nearbyBefore, _) = run
        val found = missing.filterKeys { registry.session(it) != null }.values.sorted()
        val stillMissing = missing.filterKeys { registry.session(it) == null }.values.sorted()
        val trusted = trust.trustedDeviceIds.value
        val newNearby = lastPeers.filter { peer -> peer.deviceIdHint?.let { it !in trusted && it !in nearbyBefore } == true }.map { it.deviceNameHint }
        mutableRediscover.value = RediscoverState.Done(found + newNearby, stillMissing)
        diagnostics.record("discovery", "manual_done", detail = "${found.size}_found_${stillMissing.size}_missing")
    }

    /** The UI showed the result. */
    fun clearRediscover() {
        if (mutableRediscover.value is RediscoverState.Done) mutableRediscover.value = null
    }

    /** Per trusted device, for the diagnostics report: no names and no addresses. */
    private fun diagnosticDevices(): JSONArray = JSONArray().apply {
        trust.trustedDeviceIds.value.sorted().forEach { id ->
            val addresses = reconnect.addressBook.addresses(id)
            put(JSONObject().apply {
                put("device", id.take(8))
                put("connected", registry.session(id) != null)
                put("knownAddresses", addresses.size)
                put("addressSources", JSONArray(addresses.map { it.source.key }))
                put("reconnectAttempts", reconnect.entry(id)?.attempts ?: 0)
                reconnect.addressBook.lastConnected(id)?.let { put("lastConnectedAt", java.time.Instant.ofEpochMilli(it).toString()) }
                put("health", healthOf(id).toJson())
            })
        }
    }

    // endregion

    /** The send bar's device picker. Outgoing actions without an explicit device go here. */
    fun selectDevice(deviceId: String?) {
        selectedDeviceId = deviceId
        publish()
    }

    fun confirm() {
        scope.launch {
            val current = pairingSession ?: return@launch
            if (current.code == null || current.pairingKey == null) return@launch
            confirm(current)
        }
    }

    /** Cancels the pairing in progress (or clears its failure). Connected devices stay connected. */
    fun cancel() {
        val current = pairingSession
        pairingSession = null
        if (current != null) {
            current.failure = PairingFailure.CANCELLED_REMOTE // never shown: the flow is already idle
            current.send(Message(kind = "pairing.cancel", sessionId = current.id))
            current.close()
        }
        mutablePairingFlow.value = PairingState.Idle
        publish()
    }

    /** Clears a pairing failure, as [cancel]. */
    fun dismiss() = cancel()

    /** Disconnects one device; the others stay connected. The link comes back through the normal reconnect, as before. */
    fun disconnect(deviceId: String) {
        val current = registry.session(deviceId) ?: return
        registry.remove(current)
        current.dropReason = "user_disconnect"
        current.close()
        deviceDisconnected(deviceId, "user_disconnect")
    }

    fun forget(deviceId: String) {
        folderJournals.deleteForPeer(deviceId).forEach { record -> record.header.oneOffTree?.let(placesStore::releaseOneOff) }
        folderSender.forget(deviceId)
        mutableFileTransfers.update { transfers -> transfers.filterValues { it.kind != TransferKind.FOLDER || it.active || it.deviceId != deviceId } }
        trust.remove(deviceId)
        reconnect.forget(deviceId)
        settings.removeDevice(deviceId)
        macActions.forget(deviceId)
        health.forget(deviceId)
        recordFocus(focusSync.forget(deviceId))
        autoClipboardTracker.clear(deviceId)
        clearClipboardCache()
        disconnect(deviceId)
        BridgeyLogging.i(LogCategory.CONNECTION, "PAIRING revoked peerId=${deviceId.take(8)}")
    }

    fun updateDeviceName(value: String) {
        localDeviceName = value.trim().take(64).ifBlank { "Android device" }
    }

    /** The session outgoing actions use: [deviceId] when given (null if it is not connected), else the selected device. */
    private fun sessionFor(deviceId: String?): Session? =
        if (deviceId != null) registry.session(deviceId) else registry.target(selectedDeviceId)?.let(registry::session)

    private fun featureEnabled(feature: BridgeyFeature, current: Session? = sessionFor(null)): Boolean =
        settings.isEnabled(feature, current?.remoteDeviceId?.takeIf(String::isNotEmpty))

    /** Local setting and the device's own setting both allow [feature]; [deviceId] null means the selected device. */
    fun isFeatureAvailable(feature: BridgeyFeature, deviceId: String? = null): Boolean {
        val current = sessionFor(deviceId)
        val remote = current?.let { registry.state(it.remoteDeviceId)?.remoteFeatures?.get(feature) }
            ?: defaultFeatureState()[feature]
        return effectiveFeatureAvailable(featureEnabled(feature, current), remote != false)
    }

    /**
     * Send clipboard (Home, a device page): the whole clip, images and files included when the Mac
     * takes them, or a screenshot from the last minute when Send a fresh screenshot is on.
     */
    fun sendClipboard(deviceId: String? = null) {
        val clip = readLocalClip(appContext, clipboardOffersAvailable(deviceId), includeHtml = true)
        sendCopiedItem(readClipTimestamp(appContext), deviceId, sendClipboard = {
            if (clip == null || clip == LocalClip.Own) {
                mutableClipboardStatus.value = if (clip == LocalClip.Own) {
                    "This clip came from your Mac"
                } else {
                    "Clipboard unavailable. Copy text, return to Bridgey, and try again."
                }
            } else {
                sendClip(clip, deviceId = deviceId)
            }
        }) { result, peerName ->
            if (result == ClipboardSendResult.DELIVERED) {
                mutableClipboardStatus.value = appContext.getString(R.string.screenshot_sent, peerName)
            }
        }
    }

    private val freshScreenshots = FreshScreenshots(appContext, { settings.state.value.screenshotSendEnabled })

    /**
     * Send copied item (notification button, Quick Settings tile, in-app send). With Clipboard > Send
     * a fresh screenshot on and access to all photos, a screenshot taken in the last minute, after
     * the clip on the clipboard ([clipTimestamp]), goes as an image offer and [onScreenshot] gets the
     * result and the device's name. Otherwise [sendClipboard] runs as before, on the main thread. The
     * device follows the usual rules: [deviceId], else the selected device.
     */
    fun sendCopiedItem(
        clipTimestamp: Long,
        deviceId: String?,
        sendClipboard: () -> Unit,
        onScreenshot: (ClipboardSendResult, String) -> Unit,
    ) {
        val target = sessionFor(deviceId)
        if (target == null || !freshScreenshots.active() || !clipboardOffersAvailable(target.remoteDeviceId)) {
            sendClipboard()
            return
        }
        scope.launch {
            val shot = runCatching { freshScreenshots.find(clipTimestamp) }.getOrNull()
            withContext(Dispatchers.Main) {
                if (shot == null) {
                    sendClipboard()
                    return@withContext
                }
                freshScreenshots.markSent(shot.id)
                diagnostics.record("clipboard", "screenshot_sent")
                sendClip(shot.asClip(), target.remoteDeviceId) { result ->
                    if (result in SCREENSHOT_NOT_SENT) freshScreenshots.unmarkSent(shot.id)
                    onScreenshot(result, target.peerName)
                }
            }
        }
    }

    fun sendText(text: String, sensitive: Boolean = false, deviceId: String? = null, onResult: (ClipboardSendResult) -> Unit = {}) =
        sendClip(LocalClip.Text(text, null, sensitive), deviceId, onResult)

    /** A manual send of [clip] to one device: text as before, or an offer for images, files and long text. */
    fun sendClip(clip: LocalClip, deviceId: String? = null, onResult: (ClipboardSendResult) -> Unit = {}) {
        val target = sessionFor(deviceId)
        if (target == null) {
            mutableClipboardStatus.value = "Not connected, so the clip was not sent"
            onResult(ClipboardSendResult.NOT_CONNECTED)
            return
        }
        val id = target.remoteDeviceId
        when (clip) {
            LocalClip.Own -> onResult(ClipboardSendResult.EMPTY)
            is LocalClip.Text -> if (clipboardOffersAvailable(id) && clip.text.isNotEmpty() && !textFitsLegacy(clip.text, clip.html)) {
                sendClipOffer(clip, automatic = false, targets = listOf(target), onResult = onResult)
            } else {
                sendClipboardContent(clip.text, clip.html, sensitive = clip.sensitive, target = target, onResult = onResult)
            }
            is LocalClip.Items -> if (clipboardOffersAvailable(id)) {
                sendClipOffer(clip, automatic = false, targets = listOf(target), onResult = onResult)
            } else {
                mutableClipboardStatus.value = "Images and files need Bridgey by Round Robin on your Mac, with Copy images and files on"
                onResult(ClipboardSendResult.DISABLED)
            }
        }
    }

    /** Reads the clipboard for an automatic send; call only while Bridgey may read it. */
    fun readClipForAutomaticSend(): LocalClip? =
        readLocalClip(appContext, registry.connectedIds().any(::clipboardOffersAvailable), includeHtml = false)

    /** Reads the clipboard for a manual send; call only while Bridgey may read it. */
    fun readClipForManualSend(): LocalClip? = readLocalClip(appContext, clipboardOffersAvailable(), includeHtml = true)

    /** Copy images and files is on here and Clipboard is on for the device. */
    private fun clipboardOffersEnabledLocally(current: Session? = sessionFor(null)): Boolean =
        settings.state.value.clipboardFilesEnabled && featureEnabled(BridgeyFeature.CLIPBOARD, current)

    /** Clipboard offers can be used with [deviceId] (null: the selected device): both sides advertise them. */
    fun clipboardOffersAvailable(deviceId: String? = null): Boolean {
        val current = sessionFor(deviceId) ?: return false
        return clipboardOffersEnabledLocally(current) &&
            registry.state(current.remoteDeviceId)?.remoteClipboardFiles == true &&
            isFeatureAvailable(BridgeyFeature.CLIPBOARD, current.remoteDeviceId)
    }

    /**
     * Automatic clipboard: offered the current clipboard after a copy (listener, resume, tile or
     * notification). Goes to every connected device with automatic clipboard on, so a copy on the
     * phone can be pasted on any Mac. Applies the skip rules, de-duplication and loop prevention
     * per device. Silent except for the size limit, which shows one quiet status and is not retried.
     */
    fun autoSendClipboard(text: String?, sensitive: Boolean) =
        autoSendClip(text?.takeIf(String::isNotEmpty)?.let { LocalClip.Text(it, null, sensitive) })

    fun autoSendClip(clip: LocalClip?) {
        val devices = registry.connectedIds()
        if (devices.isEmpty()) {
            clipboardOutbox.noteLocalClip(clip?.hash())
            return
        }
        val offerTargets = mutableListOf<Session>()
        var invalidate = false
        devices.forEach { deviceId ->
            val current = registry.session(deviceId) ?: return@forEach
            val available = settings.isAutoClipboardEnabled(deviceId) && isFeatureAvailable(BridgeyFeature.CLIPBOARD, deviceId)
            when (autoClipDecision(clip, available, clipboardOffersAvailable(deviceId), autoClipboardTracker.lastHash(deviceId))) {
                ClipboardAutoDecision.SEND -> {
                    val text = clip as LocalClip.Text
                    autoClipboardTracker.record(deviceId, clipboardHash(text.text))
                    sendClipboardContent(text.text, html = null, sensitive = text.sensitive, automatic = true, target = current)
                }
                ClipboardAutoDecision.SEND_OFFER -> {
                    clip!!.hash()?.let { autoClipboardTracker.record(deviceId, it) }
                    offerTargets += current
                }
                ClipboardAutoDecision.SKIP_TOO_LARGE ->
                    mutableClipboardStatus.value = "Clipboard exceeds 32 KiB. Send large text or diagnostics as a file."
                ClipboardAutoDecision.SKIP_SENSITIVE, ClipboardAutoDecision.SKIP_EMPTY -> invalidate = true
                else -> Unit
            }
        }
        // Something else is on the clipboard now: the last offer no longer matches it.
        if (invalidate) clipboardOutbox.invalidate(currentClipLink())
        if (offerTargets.isNotEmpty()) sendClipOffer(clip!!, automatic = true, targets = offerTargets)
    }

    /** Resume path: only offer a clip that is fresh (copied within the last 10 minutes). */
    fun autoSendClipboardOnResume(text: String?, sensitive: Boolean, timestampMillis: Long) {
        if (!clipIsFresh(timestampMillis, System.currentTimeMillis())) return
        autoSendClipboard(text, sensitive)
    }

    fun autoSendClipOnResume(clip: LocalClip?, timestampMillis: Long) {
        if (!clipIsFresh(timestampMillis, System.currentTimeMillis())) return
        autoSendClip(clip)
    }

    /** Clear activity and Forget device: the clipboard cache goes too. */
    fun clearClipboardCache() {
        scope.launch { clipboardInbox.clearAll() }
    }

    /** Offers [clip] to [targets] (one offer, the same id for each), then pushes small items straight away. */
    private fun sendClipOffer(clip: LocalClip, automatic: Boolean, targets: List<Session>, onResult: (ClipboardSendResult) -> Unit = {}) {
        if (targets.none(registry::isActive)) {
            mutableClipboardStatus.value = "Not connected, so the clip was not sent"
            onResult(ClipboardSendResult.NOT_CONNECTED)
            return
        }
        scope.launch {
            val live = targets.filter { registry.isActive(it) && clipboardOffersAvailable(it.remoteDeviceId) }
            if (live.isEmpty()) {
                onResult(ClipboardSendResult.NOT_CONNECTED)
                return@launch
            }
            val (offer, sources) = buildClipOffer(clip) ?: run {
                mutableClipboardStatus.value = "Clipboard is empty"
                onResult(ClipboardSendResult.EMPTY)
                return@launch
            }
            val summary = offer.summary()
            // This phone's clipboard now holds a local copy: what came from the Mac is superseded.
            clipboardInbox.supersede()
            val sent = mutableListOf<SessionClipLink>()
            val messageIds = mutableListOf<String>()
            var reported = false
            live.forEach { current ->
                val link = SessionClipLink(current)
                val messageId = UUID.randomUUID().toString()
                pendingClipboardSends[messageId] = { result ->
                    if (result == ClipboardSendResult.DELIVERED) {
                        activityListener?.invoke(
                            PeerEvent(
                                PeerActivity.CLIP_OFFER_SENT, current.remoteDeviceId, current.peerName,
                                sensitive = offer.sensitive, automatic = automatic,
                                clipContent = summary.content, clipCount = summary.count, clipBytes = summary.bytes, clipName = summary.name,
                            ),
                        )
                    }
                    // One result per send: the first device's answer (manual sends have one device).
                    if (!reported) {
                        reported = true
                        onResult(result)
                    }
                }
                if (link.sendWithId("clipboard.offer", messageId, offer.encode())) {
                    sent += link
                    messageIds += messageId
                } else {
                    pendingClipboardSends.remove(messageId)
                }
            }
            if (sent.isEmpty()) {
                if (!reported) onResult(ClipboardSendResult.CONNECTION_LOST)
                mutableClipboardStatus.value = "Connection lost"
                return@launch
            }
            clipboardOutbox.publish(
                OutgoingClip(offer, sources, sent.first().deviceId, clip.hash(), sent.mapTo(LinkedHashSet()) { it.deviceId }),
                sent,
                settings.state.value.clipboardEagerLimit,
            )
            diagnostics.record("clipboard", "offer_sent")
            if (!automatic) mutableClipboardStatus.value = "Sending…"
            delay(6_000)
            messageIds.forEach { messageId ->
                pendingClipboardSends.remove(messageId)?.let { callback ->
                    if (!automatic) mutableClipboardStatus.value = "No delivery acknowledgement"
                    callback(ClipboardSendResult.NO_ACKNOWLEDGEMENT)
                }
            }
        }
    }

    private fun currentClipLink(): ClipboardLink? = sessionFor(null)?.takeIf { it.pairingKey != null }?.let(::SessionClipLink)

    private fun clipboardSessionEnded(deviceId: String?) {
        clipboardInbox.disconnected(deviceId)
        clipboardOutbox.disconnected(deviceId)
    }

    /** Clipboard offer messages on one device's session: encrypted payloads, unique message IDs. */
    private inner class SessionClipLink(private val target: Session) : ClipboardLink {
        override val deviceId: String get() = target.remoteDeviceId
        override val peerName: String get() = target.peerName

        override fun send(kind: String, transferId: String?, payload: ByteArray?, sequence: Long?): Boolean =
            sendWithId(kind, UUID.randomUUID().toString(), payload, transferId, sequence)

        fun sendWithId(kind: String, messageId: String, payload: ByteArray?, transferId: String? = null, sequence: Long? = null): Boolean {
            if (!registry.isActive(target)) return false
            val key = target.pairingKey ?: return false
            val encrypted = payload?.let { Crypto.encrypt(key, it) }
            return target.send(
                Message(
                    kind = kind,
                    sessionId = target.id,
                    messageId = messageId,
                    nonce = encrypted?.nonce,
                    ciphertext = encrypted?.ciphertext,
                    transferId = transferId,
                    sequence = sequence,
                ),
            )
        }
    }

    /** Clips from the Mac reach the stream, loop prevention and diagnostics (event names only). */
    private fun onClipboardInboxEvent(event: ClipInboxEvent) {
        when (event) {
            is ClipInboxEvent.Received -> {
                val summary = event.received.offer.summary()
                diagnostics.record("clipboard", "offer_received")
                activityListener?.invoke(
                    PeerEvent(
                        PeerActivity.CLIP_OFFER_RECEIVED, event.received.deviceId, event.received.peerName,
                        sensitive = event.received.offer.sensitive, automatic = true,
                        clipContent = summary.content, clipCount = summary.count, clipBytes = summary.bytes, clipName = summary.name,
                    ),
                )
            }
            is ClipInboxEvent.Pasted -> {
                diagnostics.record("clipboard", "item_pasted")
                val content = when (event.item.kind) {
                    ClipItemKind.IMAGE -> "image"
                    ClipItemKind.FILE -> "file"
                    else -> "text"
                }
                activityListener?.invoke(
                    PeerEvent(
                        PeerActivity.CLIP_PASTED, event.deviceId, event.peerName,
                        clipContent = content, clipBytes = event.item.size, clipName = event.item.name,
                    ),
                )
            }
            is ClipInboxEvent.PasteFailed -> {
                diagnostics.record("clipboard", "paste_failed", event.code)
                activityListener?.invoke(PeerEvent(PeerActivity.CLIP_PASTE_FAILED, event.deviceId, event.peerName))
            }
            is ClipInboxEvent.TextWritten -> {
                // Our own clip-change event and the next resume read must not bounce it back.
                recordIncomingClip(event.deviceId, event.text)
                diagnostics.record("clipboard", "long_text_received")
            }
            is ClipInboxEvent.WriteFailed -> {
                diagnostics.record("clipboard", "offer_received", "write_failed")
                activityListener?.invoke(PeerEvent(PeerActivity.CLIPBOARD_RECEIVE_FAILED, event.deviceId, event.peerName, automatic = true))
            }
        }
    }

    /**
     * A clip from [deviceId] is now on the phone's clipboard. Loop prevention records it for every
     * connected device: the phone's own clip-change event must not bounce it back to the sender,
     * and other Macs get it only from an explicit send (the copy happened on a Mac, not here).
     */
    private fun recordIncomingClip(deviceId: String, text: String) {
        val hash = clipboardHash(text)
        (registry.connectedIds() + deviceId).toSet().forEach { autoClipboardTracker.record(it, hash) }
    }

    private fun sendClipboardContent(
        text: String,
        html: String?,
        sensitive: Boolean = false,
        automatic: Boolean = false,
        target: Session,
        onResult: (ClipboardSendResult) -> Unit = {},
    ) {
        if (!isFeatureAvailable(BridgeyFeature.CLIPBOARD, target.remoteDeviceId)) {
            mutableClipboardStatus.value = "Clipboard is turned off on one of your devices"
            onResult(ClipboardSendResult.DISABLED)
            return
        }
        if (text.isEmpty()) {
            mutableClipboardStatus.value = "Clipboard is empty"
            onResult(ClipboardSendResult.EMPTY)
            return
        }
        if (!clipboardTextFits(text)) {
            mutableClipboardStatus.value = "Clipboard exceeds 32 KiB. Send large text or diagnostics as a file."
            onResult(ClipboardSendResult.TOO_LARGE)
            return
        }
        if (!registry.isActive(target)) {
            mutableClipboardStatus.value = "Not connected — clipboard was not sent"
            onResult(ClipboardSendResult.NOT_CONNECTED)
            return
        }
        scope.launch {
            val current = target
            if (!registry.isActive(current)) {
                mutableClipboardStatus.value = "Not connected — clipboard was not sent"
                onResult(ClipboardSendResult.NOT_CONNECTED)
                return@launch
            }
            val messageId = UUID.randomUUID().toString()
            pendingClipboardSends[messageId] = { result ->
                if (result == ClipboardSendResult.DELIVERED) {
                    activityListener?.invoke(PeerEvent(PeerActivity.CLIPBOARD_SENT, current.remoteDeviceId, current.peerName, text, sensitive, automatic))
                }
                onResult(result)
            }
            clipboardOutbox.supersede(SessionClipLink(current))
            clipboardInbox.supersede()
            val richContent = RichClipboardContent.create(text, html)
            val plaintext = richContent?.encode() ?: text.toByteArray(Charsets.UTF_8)
            val encrypted = Crypto.encrypt(current.pairingKey!!, plaintext)
            val message = Message(
                kind = if (richContent == null) "clipboard.update" else "clipboard.rich",
                sessionId = current.id,
                messageId = messageId,
                nonce = encrypted.nonce,
                ciphertext = encrypted.ciphertext,
            )
            if (!current.send(message)) {
                pendingClipboardSends.remove(messageId)?.invoke(ClipboardSendResult.CONNECTION_LOST)
                mutableClipboardStatus.value = "Connection lost"
                current.close()
                return@launch
            }
            mutableClipboardStatus.value = "Sending…"
            BridgeyLogging.line(LogLines.clipboard(BridgeyLogging.policy, "sent", text.takeUnless { sensitive }))
            delay(3_000)
            if (pendingClipboardSends.containsKey(messageId) && registry.isActive(current)) {
                if (!current.send(message)) {
                    pendingClipboardSends.remove(messageId)?.invoke(ClipboardSendResult.CONNECTION_LOST)
                    mutableClipboardStatus.value = "Connection lost"
                    current.close()
                    return@launch
                }
                delay(3_000)
                pendingClipboardSends.remove(messageId)?.let { callback ->
                    mutableClipboardStatus.value = "No delivery acknowledgement"
                    callback(ClipboardSendResult.NO_ACKNOWLEDGEMENT)
                }
            }
        }
    }

    /** Sends one encrypted message to [current] if it is still a live device session. */
    private fun sendEncrypted(
        current: Session,
        kind: String,
        payload: ByteArray,
        messageId: String = UUID.randomUUID().toString(),
        transferId: String? = null,
    ): Boolean {
        if (!registry.isActive(current)) return false
        val key = current.pairingKey ?: return false
        val encrypted = Crypto.encrypt(key, payload)
        return current.send(
            Message(kind = kind, sessionId = current.id, messageId = messageId, nonce = encrypted.nonce, ciphertext = encrypted.ciphertext, transferId = transferId),
        )
    }

    /** This phone receives folders from [deviceId]: Files on for it, Android 10 or newer (what it advertised). */
    private fun receivesFolders(deviceId: String): Boolean =
        settings.isEnabled(BridgeyFeature.FILES, deviceId) && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    /** A folder session's way back to its device. */
    private inner class FolderSessionLink(private val current: Session) : dev.bridgey.android.folders.FolderLink {
        override fun send(kind: String, payload: JSONObject, outerTransferId: String?) {
            sendEncrypted(current, kind, payload.toString().toByteArray(Charsets.UTF_8), transferId = outerTransferId)
        }

        override fun sendOuter(kind: String, transferId: String, sequence: Long?) {
            if (registry.isActive(current)) current.send(Message(kind = kind, sessionId = current.id, transferId = transferId, sequence = sequence))
        }
    }

    /** A sending folder session's way to its device (phone to Mac). */
    private inner class FolderSendSessionLink(private val current: Session) : dev.bridgey.android.folders.FolderSendLink {
        override fun send(kind: String, payload: JSONObject, outerTransferId: String?): Boolean =
            sendEncrypted(current, kind, payload.toString().toByteArray(Charsets.UTF_8), transferId = outerTransferId)

        override fun sendChunk(transferId: String, sequence: Long, bytes: ByteArray): Boolean {
            if (!registry.isActive(current)) return false
            val key = current.pairingKey ?: return false
            val encrypted = Crypto.encrypt(key, bytes)
            return current.send(
                Message(kind = "files.chunk", sessionId = current.id, messageId = UUID.randomUUID().toString(), transferId = transferId,
                    sequence = sequence, nonce = encrypted.nonce, ciphertext = encrypted.ciphertext),
            )
        }

        override fun sendOuter(kind: String, transferId: String): Boolean =
            registry.isActive(current) && current.send(Message(kind = kind, sessionId = current.id, transferId = transferId))
    }

    /** Rows for folders this phone sends; the one-off "Browse…" grant goes when the folder ends. */
    private inner class FolderSendEvents : dev.bridgey.android.folders.FolderSenderListener {
        override fun snapshot(snapshot: dev.bridgey.android.folders.FolderSnapshot) = updateFolderTransfer(snapshot)

        override fun finished(snapshot: dev.bridgey.android.folders.FolderSnapshot) {
            updateFolderTransfer(snapshot)
            diagnostics.record("folder_send", snapshot.end?.name?.lowercase() ?: "ended", snapshot.endCode ?: "none")
        }

        override fun releaseTree(treeUri: String) {
            if (placesStore.places.value.any { it.treeUri == treeUri } || placesStore.defaultTree.value == treeUri) return
            runCatching { appContext.contentResolver.releasePersistableUriPermission(Uri.parse(treeUri), android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION) }
        }
    }

    /** The browse server of a device session (created on its first browse request). */
    private fun browseServer(current: Session): dev.bridgey.android.browse.BrowseServer {
        val deviceId = current.remoteDeviceId
        return browseServers.getOrPut(deviceId) {
            val env = dev.bridgey.android.browse.BrowseEnvironment(
                places = placeDirectory,
                media = { mediaLibrary },
                documents = { documentIndex },
                thumbnails = thumbnailMaker,
                settings = {
                    dev.bridgey.android.browse.BrowseSettings(browseAllowedFor(deviceId), settings.state.value.allowReplaceFromOtherDevices)
                },
                folderSettings = { settings.state.value.folderReceiveSettings },
                download = { requestId, roots ->
                    val session = registry.session(deviceId) ?: throw dev.bridgey.android.folders.DownloadRefused(dev.bridgey.android.folders.FolderCodes.POLICY)
                    if (!sendsFoldersTo(deviceId)) throw dev.bridgey.android.folders.DownloadRefused(dev.bridgey.android.folders.FolderCodes.UNSUPPORTED)
                    folderSender.download(deviceId, session.peerName, requestId, roots).also { transferDevices[it.folderTransferId] = deviceId }
                },
                runBrowse = { task -> scope.launch { task() } },
                runMedia = { task -> mediaCoordinators.execute(task) },
                mediaPool = thumbnailPool,
                log = { BridgeyLogging.i(LogCategory.FILES, it) },
            )
            dev.bridgey.android.browse.BrowseServer(
                env,
                send = { kind, payload -> registry.session(deviceId)?.let { sendEncrypted(it, kind, payload.toString().toByteArray(Charsets.UTF_8)) } },
                sendLow = { kind, payload -> registry.session(deviceId)?.let { sendEncryptedLow(it, kind, payload.toString().toByteArray(Charsets.UTF_8)) } },
            )
        }
    }

    /** A media-lane answer: written only while nothing else waits for the socket (Session.sendLowPriority). */
    private fun sendEncryptedLow(current: Session, kind: String, payload: ByteArray): Boolean {
        if (!registry.isActive(current)) return false
        val key = current.pairingKey ?: return false
        val encrypted = Crypto.encrypt(key, payload)
        return current.sendLowPriority(
            Message(kind = kind, sessionId = current.id, messageId = UUID.randomUUID().toString(), nonce = encrypted.nonce, ciphertext = encrypted.ciphertext),
        )
    }

    /** Files 2.0 browse requests (draft files_browse_draft1). Decrypted here; the browse server answers. */
    private fun receiveBrowseMessage(current: Session, message: Message) {
        if (!registry.isActive(current) || message.sessionId != current.id) return
        val messageId = message.messageId ?: return
        if (!current.acceptMessageId(messageId)) return
        val plaintext = Crypto.decrypt(
            current.pairingKey ?: return,
            message.nonce ?: return fail(current, "Invalid encrypted browse message"),
            message.ciphertext ?: return fail(current, "Invalid encrypted browse message"),
        ) ?: return fail(current, "Invalid encrypted browse message")
        if (message.kind in dev.bridgey.android.browse.BrowseKinds.answers) return
        // Strict JSON, as the Mac writes it (docs/protocol-contract.md): org.json alone also takes comments and quotes.
        val json = plaintext.takeIf { it.size <= dev.bridgey.android.browse.BrowseKinds.requestPlaintextLimit(message.kind) }
            ?.let(::strictJsonObject) ?: return
        browseServer(current).handle(message.kind, json)
    }

    /**
     * folders.* and places.* (draft). A device whose Files is off here gets an outer-only folders.rejected for an
     * offer, without decrypting, then the feature state again. A payload that fails decryption closes the
     * session as before; one that decrypts but is invalid is answered and the session stays.
     */
    private fun receiveFolderMessage(current: Session, message: Message) {
        if (!registry.isActive(current) || message.sessionId != current.id) return
        val deviceId = current.remoteDeviceId
        val allowed = receivesFolders(deviceId)
        val kinds = dev.bridgey.android.folders.FolderKinds
        // Outer-only answers to a folder this phone sends: folders.rejected (Files off there), folders.cancel.ack.
        if (message.ciphertext == null && message.transferId != null && folderSender.owns(message.transferId)) {
            folderSender.handleOuter(deviceId, message.kind, message.transferId, message.sequence)
            return
        }
        if (message.kind == kinds.OFFER && !allowed) {
            message.transferId?.let { current.send(Message(kind = kinds.REJECTED, sessionId = current.id, transferId = it)) }
            BridgeyLogging.i(LogCategory.FILES, "FOLDER offer rejected code=policy")
            sendFeatureState(current)
            return
        }
        val messageId = message.messageId ?: return
        if (!current.acceptMessageId(messageId)) return
        val plaintext = Crypto.decrypt(
            current.pairingKey ?: return,
            message.nonce ?: return fail(current, "Invalid encrypted folder message"),
            message.ciphertext ?: return fail(current, "Invalid encrypted folder message"),
        ) ?: return fail(current, "Invalid encrypted folder message")
        val json = plaintext.takeIf { it.size <= kinds.plaintextLimit(message.kind) }
            ?.let { runCatching { JSONObject(it.toString(Charsets.UTF_8)) }.getOrNull() }
        val link = FolderSessionLink(current)
        if (json == null) {
            BridgeyLogging.i(LogCategory.FILES, "FOLDER invalid payload kind=${message.kind}")
            val id = message.transferId?.takeIf { dev.bridgey.android.folders.isWireId(it) }
            when {
                message.kind == kinds.OFFER && id != null ->
                    link.send(kinds.REJECTED, dev.bridgey.android.folders.foldersRejectedJson(id, dev.bridgey.android.folders.FolderCodes.INVALID_MESSAGE), id)
                id != null -> folders.invalid(deviceId, JSONObject().put("folderTransferId", id))
            }
            return
        }
        // Answers to a folder this phone sends (phone to Mac).
        if (message.kind in SENDER_ANSWER_KINDS || (message.kind == kinds.CANCEL && folderSender.owns(json.optString("folderTransferId")))) {
            folderSender.handle(deviceId, message.kind, json)
            return
        }
        // places.list for browsing (Files 2.0): every place whatever the folder mode.
        if (message.kind == kinds.PLACES_LIST && json.optString("purpose") == "browse") {
            browseServer(current).placesForBrowsing(json)
            return
        }
        when (message.kind) {
            kinds.PLACES_LIST, kinds.PLACES_BROWSE, kinds.PLACES_CREATE_FOLDER -> if (allowed) {
                folders.places(deviceId, link, message.kind, json)
            } else {
                json.optString("requestId").takeIf { dev.bridgey.android.folders.isWireId(it) }?.let {
                    link.send(kinds.PLACES_ERROR, dev.bridgey.android.folders.placesErrorJson(it, dev.bridgey.android.folders.FolderCodes.POLICY))
                }
                sendFeatureState(current)
            }
            kinds.OFFER -> folders.offer(deviceId, current.peerName, link, json)
            kinds.MANIFEST -> folders.manifest(deviceId, json, plaintext.size)
            kinds.RESOLVE -> folders.resolve(deviceId, json)
            kinds.COMPLETE -> folders.complete(deviceId, json)
            kinds.CANCEL -> folders.cancel(deviceId, link, json)
        }
    }

    private fun receiveFolderChunk(current: Session, message: Message) {
        if (!registry.isActive(current) || message.sessionId != current.id) return
        val messageId = message.messageId ?: return
        if (!current.acceptMessageId(messageId)) return
        val transferId = message.transferId ?: return
        val chunk = Crypto.decrypt(
            current.pairingKey!!,
            message.nonce ?: return fail(current, "Invalid encrypted file chunk"),
            message.ciphertext ?: return fail(current, "Invalid encrypted file chunk"),
        ) ?: return fail(current, "Invalid encrypted file chunk")
        folders.chunk(current.remoteDeviceId, transferId, message.sequence ?: -1, chunk)
    }

    /** The journal's storage, for recovery on start: its place, or the one-off tree it used. */
    private fun journalStore(record: dev.bridgey.android.folders.FolderJournals.Record): dev.bridgey.android.folders.TreeStore? {
        record.header.oneOffTree?.let { tree ->
            return if (placesStore.hasGrant(tree)) dev.bridgey.android.folders.SafTreeStore(appContext.contentResolver, Uri.parse(tree)) else null
        }
        return placeDirectory.place(record.header.placeId)?.takeIf { it.available }?.open()
    }

    /** Folder sessions report here: the transfer row, recent destinations, one-off grants, lost access. */
    private inner class FolderEvents : dev.bridgey.android.folders.FolderReceiverListener {
        override fun snapshot(snapshot: dev.bridgey.android.folders.FolderSnapshot) = updateFolderTransfer(snapshot)

        override fun finished(snapshot: dev.bridgey.android.folders.FolderSnapshot) {
            updateFolderTransfer(snapshot)
            diagnostics.record("folder", snapshot.end?.name?.lowercase() ?: "ended", snapshot.endCode ?: "none")
            FolderNotifier.finished(appContext, snapshot)
        }

        override fun usedDestination(destination: dev.bridgey.android.folders.FolderDestination) = settings.addRecentFolderDestination(destination)
        override fun releaseOneOff(treeUri: String) = placesStore.releaseOneOff(treeUri)
        override fun lostAccess(placeLabel: String) = FolderNotifier.lostAccess(appContext, placeLabel)
    }

    /** One row per folder (6.5): the coordinator's transfer list carries the folder summary. */
    private fun updateFolderTransfer(folder: dev.bridgey.android.folders.FolderSnapshot) {
        val id = folder.folderTransferId
        transferDevices[id] = folder.deviceId
        mutableFileTransfers.update { transfers ->
            val previous = transfers[id]
            val percent = if (folder.bytesTotal > 0) ((folder.bytesDone * 100) / folder.bytesTotal).toInt().coerceIn(0, 100) else null
            transfers + (id to FileTransferState(
                id = id,
                name = folder.rootName,
                status = folderStatus(folder),
                active = folder.active,
                progressPercent = percent.takeIf { folder.active && folder.waiting == null },
                startedAtMillis = previous?.startedAtMillis ?: System.currentTimeMillis(),
                retryable = folder.end == dev.bridgey.android.folders.FolderEnd.INTERRUPTED && folder.resumable,
                deviceId = folder.deviceId,
                deviceName = folder.deviceName,
                kind = TransferKind.FOLDER,
                folder = folder,
                outcome = when (folder.end) {
                    dev.bridgey.android.folders.FolderEnd.COMPLETE -> if (folder.outgoing) TransferEnd.SENT else TransferEnd.RECEIVED
                    dev.bridgey.android.folders.FolderEnd.INCOMPLETE, dev.bridgey.android.folders.FolderEnd.TIMED_OUT -> TransferEnd.FAILED
                    dev.bridgey.android.folders.FolderEnd.CANCELLED -> TransferEnd.CANCELLED
                    dev.bridgey.android.folders.FolderEnd.INTERRUPTED -> TransferEnd.INTERRUPTED
                    null -> null
                },
            ))
        }
        pruneTransferHistory()
        refreshFileTransferSummary()
    }

    /** The plain status behind the folder row (summary only; the UI builds its own text from the summary). */
    private fun folderStatus(folder: dev.bridgey.android.folders.FolderSnapshot): String = when {
        folder.waiting != null -> "Waiting"
        folder.end == null && folder.outgoing -> "Sending folder: ${folder.filesDone} of ${folder.filesTotal} files"
        folder.end == null -> "Receiving folder: ${folder.filesDone} of ${folder.filesTotal} files"
        else -> "Folder ${folder.end.name.lowercase()}"
    }

    /** Connected devices where [feature] is on at both ends: the targets of a broadcast. */
    private fun broadcastTargets(feature: BridgeyFeature): List<Session> =
        registry.broadcastTargets { id, state ->
            effectiveFeatureAvailable(settings.isEnabled(feature, id), state.remoteFeatures[feature] != false)
        }.map { it.second }

    /** Battery goes to every connected device that shows it. */
    fun sendBattery(level: Int, isCharging: Boolean) {
        val targets = broadcastTargets(BridgeyFeature.BATTERY)
        if (targets.isEmpty()) return
        val payload = JSONObject()
            .put("level", level.coerceIn(0, 100))
            .put("isCharging", isCharging)
            .toString()
            .toByteArray()
        scope.launch {
            targets.forEach { current ->
                if (sendEncrypted(current, "battery.update", payload)) {
                    BridgeyLogging.i(LogCategory.GENERAL, "PLUGIN battery sent level=$level charging=$isCharging")
                }
            }
        }
    }

    fun sendPing(deviceId: String? = null) {
        val current = sessionFor(deviceId)
        if (current == null) {
            mutablePingStatus.value = "Mac is not connected"
            return
        }
        if (!isFeatureAvailable(BridgeyFeature.PING, current.remoteDeviceId)) {
            mutablePingStatus.value = "Ping requires Bridgey 0.6 on both devices"
            return
        }
        val messageId = UUID.randomUUID().toString()
        pendingPing = current.remoteDeviceId to messageId
        mutablePingStatus.value = "Pinging ${current.peerName}…"
        scope.launch {
            if (!sendEncrypted(current, "ping.request", JSONObject().put("version", 1).toString().toByteArray(), messageId)) {
                if (pendingPing?.second == messageId) {
                    pendingPing = null
                    mutablePingStatus.value = "Ping could not be sent"
                }
                return@launch
            }
            delay(5_000)
            if (pendingPing?.second == messageId) {
                pendingPing = null
                mutablePingStatus.value = "${current.peerName} did not acknowledge the ping"
            }
        }
    }

    private fun receivePing(current: Session, message: Message) {
        if (!featureEnabled(BridgeyFeature.PING, current)) {
            sendFeatureState(current)
            return
        }
        if (!registry.isActive(current) || message.sessionId != current.id) return
        val messageId = message.messageId ?: return
        if (!current.acceptMessageId(messageId)) return
        val plaintext = Crypto.decrypt(
            current.pairingKey!!,
            message.nonce ?: return fail(current, "Invalid encrypted ping"),
            message.ciphertext ?: return fail(current, "Invalid encrypted ping"),
        ) ?: return fail(current, "Invalid encrypted ping")
        if (runCatching { JSONObject(plaintext.toString(Charsets.UTF_8)).getInt("version") }.getOrNull() != 1) {
            return fail(current, "Invalid ping")
        }
        Handler(Looper.getMainLooper()).post {
            android.widget.Toast.makeText(appContext, "Ping from ${current.peerName}", android.widget.Toast.LENGTH_SHORT).show()
            RingtoneManager.getRingtone(appContext, RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION))?.play()
        }
        current.send(Message(kind = "ping.ack", sessionId = current.id, messageId = messageId))
        BridgeyLogging.i(LogCategory.GENERAL, "PLUGIN ping received")
        activityListener?.invoke(PeerEvent(PeerActivity.PING_RECEIVED, current.remoteDeviceId, current.peerName))
    }

    private fun clearPingStatus() {
        pendingPing = null
        mutablePingStatus.value = null
    }

    /**
     * Sends one encrypted input.* message to [deviceId]. The controller numbers and orders them;
     * blocking, so call it off the main thread.
     */
    fun sendRemoteInput(deviceId: String, kind: String, payload: ByteArray): Boolean =
        registry.session(deviceId)?.let { sendEncrypted(it, kind, payload) } == true

    /** Input messages skip the shared message-ID window: their encrypted sequence guards replays. */
    private fun receiveRemoteInput(current: Session, message: Message) {
        if (!registry.isActive(current) || message.sessionId != current.id) return
        val key = current.pairingKey ?: return
        val data = Crypto.decrypt(key, message.nonce ?: return, message.ciphertext ?: return) ?: return
        if (data.size > REMOTE_INPUT_MAX_BYTES) return
        remoteInputListener?.invoke(current.remoteDeviceId, message.kind, data)
    }

    /** Reset > Activity and logs: connection health counters and history (no addresses were ever kept). */
    fun clearConnectionHealth() = health.clearHistory()

    /** Reset > Settings: hands back the Do Not Disturb that Follow turned on, before the Focus settings go. */
    fun releaseFocus() = recordFocus(focusSync.release())

    /** Connection health of [deviceId] now. Holds no address, name or content. */
    fun healthOf(deviceId: String): dev.bridgey.android.health.DeviceHealth = health.snapshot(
        deviceId,
        discoverySeesNow = lastPeers.any { it.deviceIdHint == deviceId },
        batteryOptimisationExempt = PowerFacts.ignoringBatteryOptimizations(appContext),
        nowMillis = System.currentTimeMillis(),
    )

    /** The selected device (or [deviceId]) understands Web links `open` (draft `links_open_draft1`). */
    fun linksOpenSupported(deviceId: String? = null): Boolean {
        val current = sessionFor(deviceId) ?: return false
        return registry.state(current.remoteDeviceId)?.remoteLinksOpen == true
    }

    /** Share or Follow changed: the Macs hear the state, or Bridgey hands back its Do Not Disturb. */
    @Synchronized private fun focusSettingsChanged(share: Boolean, follow: Boolean) {
        if (share != lastFocusShare) {
            lastFocusShare = share
            focusSync.shareChanged()
        }
        if (follow != lastFocusFollow) {
            lastFocusFollow = follow
            recordFocus(focusSync.followChanged())
        }
    }

    /** Android changed Do Not Disturb (the application's receiver calls this). */
    fun interruptionFilterChanged() = focusSync.localChanged()

    /** focus.state to one Mac, only while its latest map shows focus_sync_draft1. */
    private fun sendFocusState(deviceId: String, active: Boolean): Boolean {
        val current = registry.session(deviceId) ?: return false
        if (current.pairingKey == null || registry.state(deviceId)?.remoteFocusSync != true) return false
        val data = dev.bridgey.android.focus.focusStatePayload(active).toString().toByteArray(Charsets.UTF_8)
        scope.launch { sendEncrypted(current, "focus.state", data) }
        return true
    }

    /** focus.state from a Mac: decrypted, replay-checked, bounded; applied only when Follow is on. */
    private fun receiveFocusMessage(current: Session, message: Message) {
        if (!registry.isActive(current) || message.sessionId != current.id) return
        val key = current.pairingKey ?: return
        val id = message.messageId ?: return
        if (!current.acceptMessageId(id)) return
        val data = Crypto.decrypt(key, message.nonce ?: return, message.ciphertext ?: return) ?: return
        // Strict JSON at most 256 bytes, as the Mac writes it (docs/protocol-contract.md).
        val active = dev.bridgey.android.focus.decodeFocusState(data) ?: return
        recordFocus(focusSync.remote(current.remoteDeviceId, active), current.remoteDeviceId)
    }

    private fun recordFocus(outcome: dev.bridgey.android.focus.FocusApply, deviceId: String? = null) {
        if (outcome == dev.bridgey.android.focus.FocusApply.IGNORED || outcome == dev.bridgey.android.focus.FocusApply.NO_CHANGE) return
        diagnostics.record("notifications", "focus_follow", outcome.name.lowercase(), device = deviceId)
    }

    /** camera.request from a Mac: decrypted, replay-checked, bounded, then one open request per Mac. */
    private fun receiveCameraMessage(current: Session, message: Message) {
        if (!registry.isActive(current) || message.sessionId != current.id) return
        val key = current.pairingKey ?: return
        val id = message.messageId ?: return
        if (!current.acceptMessageId(id)) return
        val data = Crypto.decrypt(key, message.nonce ?: return, message.ciphertext ?: return) ?: return
        if (data.size > dev.bridgey.android.camera.CAMERA_MESSAGE_MAX_BYTES) return
        val payload = strictJsonObject(data) ?: return
        val deviceId = current.remoteDeviceId
        when (val decision = camera.receive(deviceId, current.peerName, payload, isFeatureAvailable(BridgeyFeature.CAMERA, deviceId))) {
            dev.bridgey.android.camera.CameraDecision.Drop -> Unit
            is dev.bridgey.android.camera.CameraDecision.Refuse -> sendCameraStatus(deviceId, decision.requestId, decision.status)
            is dev.bridgey.android.camera.CameraDecision.Accept -> {
                val request = decision.request
                diagnostics.record("transfer", "camera_request", device = deviceId)
                scope.launch {
                    delay(dev.bridgey.android.camera.CAMERA_REQUEST_LIFETIME_MILLIS)
                    if (camera.finish(deviceId, request.requestId)) {
                        sendCameraStatus(deviceId, request.requestId, dev.bridgey.android.camera.CameraStatus.CANCELLED)
                        cameraEnded(request)
                    }
                }
                cameraRequested(request)
            }
        }
    }

    /** camera.status to the Mac that asked. */
    fun sendCameraStatus(deviceId: String, requestId: String, status: dev.bridgey.android.camera.CameraStatus): Boolean {
        val current = registry.session(deviceId) ?: return false
        if (current.pairingKey == null) return false
        val data = dev.bridgey.android.camera.cameraStatusPayload(requestId, status).toString().toByteArray(Charsets.UTF_8)
        scope.launch { sendEncrypted(current, "camera.status", data) }
        return true
    }

    /** The Mac's request ends without a photo (it disconnected, or the feature went off). */
    private fun endCameraRequest(deviceId: String) {
        camera.ended(deviceId)?.let { cameraEnded(it) }
    }

    /**
     * Sends the photo for an open request as an ordinary file, marked with `cameraRequestId`.
     * [onDone] runs once the transfer ends (true when the Mac saved it). False if nothing was queued.
     */
    fun sendCameraPhoto(request: dev.bridgey.android.camera.CameraRequest, uri: Uri, onDone: (Boolean) -> Unit): Boolean {
        if (camera.current(request.deviceId, request.requestId) == null) return false
        val transferId = queueFiles(listOf(uri), request.deviceId) { id ->
            cameraTransfers[id] = request.requestId
            cameraTransferDone[id] = onDone
        } ?: return false
        camera.finish(request.deviceId, request.requestId)
        return transferId.isNotEmpty()
    }

    /** A camera transfer ended: its callback runs once. */
    private fun cameraTransferEnded(transferId: String) {
        cameraTransfers.remove(transferId)
        val sent = cameraTransferSent.remove(transferId)
        cameraTransferDone.remove(transferId)?.invoke(sent)
    }

    /** actions.run to one Mac, only while its latest map shows mac_actions_draft1. */
    private fun sendActionsPayload(deviceId: String, kind: String, payload: JSONObject): Boolean {
        val current = registry.session(deviceId) ?: return false
        if (current.pairingKey == null || !isFeatureAvailable(BridgeyFeature.MAC_ACTIONS, deviceId)) return false
        val data = payload.toString().toByteArray(Charsets.UTF_8)
        if (data.size > dev.bridgey.android.actions.MacActionsClient.MAX_RESULT_BYTES) return false
        scope.launch { sendEncrypted(current, kind, data) }
        return true
    }

    /** actions.catalog and actions.result (draft mac_actions_draft1): decrypted, replay-checked, bounded. */
    private fun receiveActionsMessage(current: Session, message: Message) {
        if (!registry.isActive(current) || message.sessionId != current.id) return
        val key = current.pairingKey ?: return
        val id = message.messageId ?: return
        if (!current.acceptMessageId(id)) return
        val data = Crypto.decrypt(key, message.nonce ?: return, message.ciphertext ?: return) ?: return
        val limit = if (message.kind == "actions.catalog") {
            dev.bridgey.android.actions.MacActionsClient.MAX_CATALOG_BYTES
        } else {
            dev.bridgey.android.actions.MacActionsClient.MAX_RESULT_BYTES
        }
        if (data.size > limit) return
        // Strict JSON, as the Mac writes it (docs/protocol-contract.md).
        val payload = strictJsonObject(data) ?: return
        macActions.receive(current.remoteDeviceId, message.kind, payload)
    }

    /** Quick actions (links, media) go to the selected device. */
    private fun sendQuickPayload(kind: String, payload: JSONObject): Boolean {
        val current = sessionFor(null) ?: return false
        if (current.pairingKey == null) return false
        val data = payload.toString().toByteArray(Charsets.UTF_8)
        scope.launch { sendEncrypted(current, kind, data) }
        return true
    }

    private fun receiveQuickPayload(current: Session, message: Message) {
        if (!registry.isActive(current) || message.sessionId != current.id) return
        val key = current.pairingKey ?: return
        val id = message.messageId ?: return
        if (!current.acceptMessageId(id)) return
        val data = Crypto.decrypt(key, message.nonce ?: return, message.ciphertext ?: return) ?: return
        if (data.size > if (message.kind == "media.state") 32768 else 8192) return
        val payload = runCatching { JSONObject(data.toString(Charsets.UTF_8)) }.getOrNull() ?: return
        if (message.kind == "quick.request") {
            val raw = payload.opt("sequence")
            if (raw !is Int && raw !is Long) return
            val sequence = (raw as Number).toLong()
            if (!current.quickSequence.accept(payload.optString("feature"), sequence)) return
        }
        if (message.kind == "media.state") {
            // Each Mac has its own player: keep its state, show the selected device's.
            current.media = payload
            if (registry.target(selectedDeviceId) != current.remoteDeviceId) return
        }
        quickActions.receive(message.kind, payload)
    }

    /**
     * Forwards a notification (and call state, which rides on notifications) to every connected
     * device with notifications on. Returns the devices it went to, for the activity stream.
     */
    fun sendNotification(
        packageName: String,
        applicationName: String,
        notificationId: String,
        title: String,
        text: String,
        timestamp: Long,
        actions: List<ForwardedNotificationAction> = emptyList(),
        applicationIcon: String? = null,
        callType: String? = null,
        smsDefaultApp: Boolean = false,
        redacted: Boolean? = null,
    ): List<DeviceConnection> {
        val targets = broadcastTargets(BridgeyFeature.NOTIFICATIONS)
        if (targets.isEmpty()) return emptyList()
        // A Mac with Calls off still sees the call, but gets no Answer, Decline or Hang Up.
        fun payload(callsEnabled: Boolean) = JSONObject()
            .put("packageName", packageName.take(256))
            .put("applicationName", applicationName.take(128))
            .put("notificationId", notificationId.take(512))
            .put("title", title.take(1_024))
            .put("text", text.take(8_192))
            .put("timestamp", timestamp)
            .apply {
                if (applicationIcon != null && applicationIcon.length <= MAX_NOTIFICATION_ICON_BASE64_LENGTH) {
                    put("applicationIcon", applicationIcon)
                }
                if (callType in setOf("incoming", "ongoing", "screening", "unknown")) {
                    put("callType", callType)
                }
                // Draft sms_codes_draft1: lets the Mac look for a code, or say Android hid the text.
                put("smsDefaultApp", smsDefaultApp)
                if (smsDefaultApp && redacted != null) put("redacted", redacted)
            }
            .put("actions", JSONArray().apply {
                forwardedActionsFor(actions, callType != null, callsEnabled).take(4).forEach { action ->
                    put(JSONObject()
                        .put("actionToken", action.token)
                        .put("title", action.title.take(64))
                        .put("allowsReply", action.allowsReply))
                }
            })
            .toString()
            .toByteArray()
        val withCalls by lazy { payload(callsEnabled = true) }
        val withoutCalls by lazy { payload(callsEnabled = false) }
        scope.launch {
            targets.forEach { current ->
                val callsEnabled = callType == null || settings.isEnabled(BridgeyFeature.CALLS, current.remoteDeviceId)
                if (sendEncrypted(current, "notifications.post", if (callsEnabled) withCalls else withoutCalls)) {
                    // Text messages can carry codes: their content never reaches the log, whatever Logging says.
                    BridgeyLogging.line(
                        LogLines.notification(
                            BridgeyLogging.policy, "sent", applicationName,
                            if (smsDefaultApp) null else title, if (smsDefaultApp) null else text,
                        ),
                    )
                }
            }
        }
        val ids = targets.mapTo(HashSet()) { it.remoteDeviceId }
        return registry.connections().filter { it.deviceId in ids }
    }

    /**
     * Retracts a mirrored notification on every Mac. [callEnded] marks a call the phone saw end, so
     * the Mac drops its call card at once instead of waiting for a re-post.
     */
    fun sendNotificationRemoved(notificationId: String, callEnded: Boolean = false) {
        sendNotificationReference("notifications.remove", notificationId, callEnded)
    }

    /** Call lifecycle event for the exported diagnostics: public tokens only, never caller or app. */
    fun recordCallDiagnostic(event: String, reason: String) {
        diagnostics.record("call", event, detail = reason)
    }

    /** Remote control session start or end, for Logcat and diagnostics (category remote). */
    fun recordRemoteControlEvent(event: String, deviceId: String, detail: String) {
        BridgeyLogging.i(LogCategory.REMOTE_CONTROL, "REMOTE $event peer=${deviceId.take(8)} detail=$detail")
        diagnostics.record("remote", event, device = deviceId, detail = detail)
    }

    /** Settings > Privacy > Logging > Clear logs: the diagnostics log on this phone. */
    fun clearDiagnostics() {
        diagnostics.clear()
    }

    private fun sendNotificationReference(kind: String, notificationId: String, callEnded: Boolean = false) {
        if (notificationId.isBlank()) return
        val targets = broadcastTargets(BridgeyFeature.NOTIFICATIONS)
        if (targets.isEmpty()) return
        val payload = JSONObject()
            .put("notificationId", notificationId.take(512))
            .apply { if (callEnded) put("callEnded", true) }
            .toString()
            .toByteArray()
        scope.launch { targets.forEach { sendEncrypted(it, kind, payload) } }
    }

    /** Find device: rings [deviceId] (null: the selected device). */
    fun findMac(deviceId: String? = null) {
        val current = sessionFor(deviceId) ?: return
        if (!isFeatureAvailable(BridgeyFeature.FIND_DEVICE, current.remoteDeviceId)) return
        scope.launch { sendFindCommand(current, "find.start") }
    }

    /** Stops this phone ringing and every device that rings. */
    fun stopFinding() {
        stopPhoneRinging()
        scope.launch {
            registry.connectedIds().forEach { id -> registry.session(id)?.let { sendFindCommand(it, "find.stop") } }
        }
    }

    /** Stops [deviceId] ringing (and this phone, when that device rang it). */
    fun stopFinding(deviceId: String) {
        if (phoneRingingFrom == deviceId) stopPhoneRinging()
        val current = registry.session(deviceId) ?: return
        scope.launch { sendFindCommand(current, "find.stop") }
    }

    private fun sendFindCommand(current: Session, kind: String): Boolean {
        if (kind == "find.start" && !isFeatureAvailable(BridgeyFeature.FIND_DEVICE, current.remoteDeviceId)) return false
        return sendEncrypted(current, kind, JSONObject().put("alertId", "active").toString().toByteArray())
    }

    private fun receiveFindCommand(current: Session, message: Message, start: Boolean) {
        if (start && !settings.isEnabled(BridgeyFeature.FIND_DEVICE, current.remoteDeviceId)) return
        if (!registry.isActive(current) || message.sessionId != current.id) return
        val messageId = message.messageId ?: return
        if (!current.acceptMessageId(messageId)) return
        val plaintext = Crypto.decrypt(
            current.pairingKey!!,
            message.nonce ?: return fail(current, "Invalid encrypted find-device message"),
            message.ciphertext ?: return fail(current, "Invalid encrypted find-device message"),
        ) ?: return fail(current, "Invalid encrypted find-device message")
        if (runCatching { JSONObject(plaintext.toString(Charsets.UTF_8)).getString("alertId") }.isFailure) {
            return fail(current, "Invalid find-device message")
        }
        if (start) {
            val wasRinging = mutablePhoneRinging.value
            startPhoneRinging(current.remoteDeviceId)
            if (!wasRinging && mutablePhoneRinging.value) {
                activityListener?.invoke(PeerEvent(PeerActivity.FIND_PHONE_STARTED, current.remoteDeviceId, current.peerName))
            }
            sendFindCommand(current, if (mutablePhoneRinging.value) "find.started" else "find.stopped")
        } else {
            stopPhoneRinging()
            registry.update(current.remoteDeviceId) { it.copy(ringing = false) }
            publish()
            sendFindCommand(current, "find.stopped")
        }
        BridgeyLogging.i(LogCategory.GENERAL, "PLUGIN find-device ${if (start) "started" else "stopped"}")
    }

    private fun startPhoneRinging(fromDeviceId: String) {
        if (mutablePhoneRinging.value) return
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        val ringtone = RingtoneManager.getRingtone(appContext, uri) ?: return
        ringtone.audioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) ringtone.isLooping = true
        findRingtone = ringtone
        phoneRingingFrom = fromDeviceId
        mutablePhoneRinging.value = true
        ringtone.play()
    }

    private fun stopPhoneRinging() {
        runCatching { findRingtone?.stop() }
        findRingtone = null
        phoneRingingFrom = null
        mutablePhoneRinging.value = false
    }

    /** Sends a file to [deviceId] (null: the selected device). */
    fun sendFile(uri: Uri, deviceId: String? = null) = sendFiles(listOf(uri), deviceId)

    /**
     * Files 2.0: whether [deviceId] (null: the selected device) receives folders from this phone (it advertised
     * folders_receive_draft1). The attach sheet's Folders tab and "Send folder" use it.
     */
    fun canSendFolders(deviceId: String? = null): Boolean {
        val target = sessionFor(deviceId)?.remoteDeviceId ?: return false
        return sendsFoldersTo(target)
    }

    /** Files 2.0: sends a whole folder to [deviceId] (null: the selected device), phone to Mac. */
    fun sendFolder(source: dev.bridgey.android.browse.FolderSource, deviceId: String? = null) {
        val connectedSession = sessionFor(deviceId)
        if (connectedSession == null) {
            mutableFileTransferStatus.value = appContext.getString(R.string.folder_send_not_connected)
            return
        }
        val target = connectedSession.remoteDeviceId
        if (!sendsFoldersTo(target)) {
            mutableFileTransferStatus.value = appContext.getString(R.string.folder_send_unsupported, connectedSession.peerName)
            return
        }
        val peerName = connectedSession.peerName
        scope.launch {
            val (root, releaseTree) = when (source) {
                is dev.bridgey.android.browse.FolderSource.Tree -> {
                    val tree = Uri.parse(source.treeUri)
                    // A one-off grant: kept for resume after a restart, released when the folder ends.
                    val persisted = runCatching {
                        appContext.contentResolver.takePersistableUriPermission(tree, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        true
                    }.getOrDefault(false)
                    val store = runCatching { dev.bridgey.android.folders.SafTreeStore(appContext.contentResolver, tree) }.getOrNull()
                    if (store == null) {
                        mutableFileTransferStatus.value = appContext.getString(R.string.folder_send_unreadable)
                        return@launch
                    }
                    val name = store.rootName() ?: "Folder"
                    dev.bridgey.android.folders.TreeSendNode.folder(store, store.rootId, name) to
                        source.treeUri.takeIf { persisted && placesStore.places.value.none { it.treeUri == source.treeUri } }
                }
                is dev.bridgey.android.browse.FolderSource.Place -> {
                    val place = placeDirectory.place(source.placeId)?.takeIf { it.available }
                    val store = place?.let { runCatching { it.open() }.getOrNull() }
                    val dirId = store?.let { runCatching { dev.bridgey.android.folders.resolveExistingPath(it, source.path) }.getOrNull() }
                    if (place == null || store == null || dirId == null) {
                        mutableFileTransferStatus.value = appContext.getString(R.string.folder_send_unreadable)
                        return@launch
                    }
                    val name = if (source.path.isEmpty()) place.label.substringAfterLast('/') else dev.bridgey.android.folders.FolderPaths.leaf(source.path)
                    dev.bridgey.android.folders.TreeSendNode.folder(store, dirId, name) to null
                }
            }
            transferDevices[folderSender.send(target, peerName, root, releaseTree)] = target
        }
    }

    /** The device accepts folders from this phone: it advertised folders_receive_draft1, and Files is on at both ends. */
    private fun sendsFoldersTo(deviceId: String): Boolean =
        registry.state(deviceId)?.remoteFoldersReceive == true && isFeatureAvailable(BridgeyFeature.FILES, deviceId)

    /** "Let other devices browse this phone" and Android 10 or newer (Files is checked per device). */
    private fun browseAllowedHere(): Boolean =
        settings.state.value.allowBrowseFromOtherDevices && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    /** files_browse_draft1 for [deviceId]. */
    private fun browseAllowedFor(deviceId: String): Boolean = browseAllowedHere() && settings.isEnabled(BridgeyFeature.FILES, deviceId)

    /** Files 2.0: the phone's photos and videos and its recent documents, for the attach sheet and the Mac. */
    var mediaLibrary: dev.bridgey.android.browse.MediaLibrary = dev.bridgey.android.browse.EmptyMediaLibrary
    var documentIndex: dev.bridgey.android.browse.DocumentIndex = dev.bridgey.android.browse.EmptyDocumentIndex

    /**
     * Adds files to [deviceId]'s outgoing queue (null: the selected device). Files are offered one
     * after another, each as its own transfer, so a failure or cancellation affects only that file.
     */
    fun sendFiles(uris: List<Uri>, deviceId: String? = null) {
        queueFiles(uris, deviceId)
    }

    /** Queues [uris]; [beforeStart] sees the first transfer ID before it can start. Returns that ID, or null. */
    private fun queueFiles(uris: List<Uri>, deviceId: String?, beforeStart: ((String) -> Unit)? = null): String? {
        if (uris.isEmpty()) return null
        val connectedSession = sessionFor(deviceId)
        if (connectedSession == null) {
            mutableFileTransferStatus.value = "Not connected — file was not sent"
            return null
        }
        val target = connectedSession.remoteDeviceId
        if (!isFeatureAvailable(BridgeyFeature.FILES, target)) {
            mutableFileTransferStatus.value = "File transfer is turned off on one of your devices"
            return null
        }
        val queuedAt = System.currentTimeMillis()
        val status = appContext.getString(R.string.file_queued)
        val queued = uris.distinct().mapIndexed { index, uri ->
            val transferId = UUID.randomUUID().toString()
            outgoingFileSources[transferId] = uri
            transferDevices[transferId] = target
            FileTransferState(
                id = transferId,
                name = "Selected file",
                status = status,
                active = true,
                progressPercent = null,
                startedAtMillis = queuedAt + index,
                deviceId = target,
                deviceName = connectedSession.peerName,
                queued = true,
            ) to uri
        }
        mutableFileTransfers.update { transfers -> transfers + queued.associate { (transfer, _) -> transfer.id to transfer } }
        queued.firstOrNull()?.let { (transfer, _) -> beforeStart?.invoke(transfer.id) }
        val queue = fileSendQueues.getOrPut(target) { FileSendQueue() }
        queued.forEach { (transfer, uri) -> queue.enqueue(transfer.id, uri) }
        pruneTransferHistory()
        refreshFileTransferSummary(status)
        scope.launch {
            queued.forEach { (transfer, uri) ->
                val name = runCatching { displayName(uri) }.getOrNull() ?: return@forEach
                mutableFileTransfers.update { transfers ->
                    val current = transfers[transfer.id]?.takeIf(FileTransferState::queued) ?: return@update transfers
                    transfers + (transfer.id to current.copy(name = name))
                }
            }
        }
        startNextQueuedFile(target)
        return queued.firstOrNull()?.first?.id
    }

    private fun displayName(uri: Uri): String? =
        appContext.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (!cursor.moveToFirst()) return@use null
            cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { it >= 0 }?.let(cursor::getString)?.take(255)
        }

    private fun startNextQueuedFile(deviceId: String) {
        val queue = fileSendQueues[deviceId] ?: return
        if (registry.session(deviceId) == null) return
        if (!isFeatureAvailable(BridgeyFeature.FILES, deviceId)) {
            stopFileQueue(deviceId, "File transfer is turned off on one of your devices")
            return
        }
        val (transferId, uri) = queue.startNext() ?: return
        startFile(transferId, uri, deviceId)
    }

    private fun finishQueuedFile(transferId: String) {
        val deviceId = transferDevices[transferId] ?: return
        if (fileSendQueues[deviceId]?.finish(transferId) == true) startNextQueuedFile(deviceId)
    }

    /** Ends every file of [deviceId] that has not started yet with the given status. They remain retryable. */
    private fun stopFileQueue(deviceId: String, status: String) {
        fileSendQueues[deviceId]?.removeAllPending()?.forEach {
            removeFileTransfer(it, status, if (status.contains("cancel", ignoreCase = true)) TransferEnd.CANCELLED else TransferEnd.FAILED)
        }
    }

    private fun startFile(transferId: String, uri: Uri, deviceId: String) {
        val connectedSession = registry.session(deviceId)
        if (connectedSession == null) {
            removeFileTransfer(transferId, "Transfer interrupted — reconnect to retry", TransferEnd.INTERRUPTED)
            finishQueuedFile(transferId)
            return
        }
        val peer = connectedSession.peerName
        diagnostics.record("transfer", "send_started")
        updateFileTransfer(transferId, mutableFileTransfers.value[transferId]?.name ?: "Selected file", "Preparing…", true)
        val job = scope.launch {
            val resolver = appContext.contentResolver
            val metadata = runCatching {
                var name = "file"
                var size = -1L
                resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { it >= 0 }?.let { name = cursor.getString(it) ?: name }
                        cursor.getColumnIndex(OpenableColumns.SIZE).takeIf { it >= 0 && !cursor.isNull(it) }?.let { size = cursor.getLong(it) }
                    }
                }
                Triple(name.take(255), resolver.getType(uri) ?: "application/octet-stream", size)
            }.getOrElse {
                updateFileTransfer(transferId, "Selected file", "Could not read the selected file", false)
                return@launch
            }
            if (metadata.third < 0) {
                mutableFileTransferStatus.value = "This file provider did not report a file size"
                updateFileTransfer(transferId, metadata.first, mutableFileTransferStatus.value!!, false)
                return@launch
            }
            if (metadata.third > MAX_FILE_SIZE) {
                mutableFileTransferStatus.value = "File is larger than 10 GB"
                updateFileTransfer(transferId, metadata.first, mutableFileTransferStatus.value!!, false)
                return@launch
            }

            updateFileTransfer(transferId, metadata.first, "Preparing ${metadata.first}…", true)
            val digest = MessageDigest.getInstance("SHA-256")
            val hash = runCatching {
                resolver.openInputStream(uri)?.use { input ->
                    val buffer = ByteArray(FILE_CHUNK_SIZE)
                    while (true) {
                        coroutineContext.ensureActive()
                        val count = input.read(buffer)
                        if (count < 0) break
                        digest.update(buffer, 0, count)
                    }
                } ?: error("File unavailable")
                Base64.encodeToString(digest.digest(), Base64.NO_WRAP)
            }.getOrElse {
                mutableFileTransferStatus.value = "Could not read the selected file"
                updateFileTransfer(transferId, metadata.first, mutableFileTransferStatus.value!!, false)
                return@launch
            }

            val offerPayload = fileOfferPayload(transferId, metadata.first, metadata.second, metadata.third, hash, cameraTransfers[transferId])
                .toString().toByteArray()
            val offer = Crypto.encrypt(connectedSession.pairingKey!!, offerPayload)
            val accepted = CompletableDeferred<Boolean>()
            pendingFileAccepts[transferId] = accepted
            if (!registry.isActive(connectedSession) || !connectedSession.send(Message(
                    kind = "files.offer",
                    sessionId = connectedSession.id,
                    messageId = UUID.randomUUID().toString(),
                    transferId = transferId,
                    nonce = offer.nonce,
                    ciphertext = offer.ciphertext,
                ))) {
                pendingFileAccepts.remove(transferId)
                mutableFileTransferStatus.value = "Connection lost — file was not sent"
                updateFileTransfer(transferId, metadata.first, mutableFileTransferStatus.value!!, false)
                return@launch
            }
            updateFileTransfer(transferId, metadata.first, "Waiting for $peer…", true)
            if (withTimeoutOrNull(10_000) { accepted.await() } != true) {
                pendingFileAccepts.remove(transferId)
                if (transferId in cancelledTransferIds || outgoingFileJobs[transferId] == null) return@launch
                updateFileTransfer(transferId, metadata.first, "$peer did not accept the file", false)
                return@launch
            }

            val completed = CompletableDeferred<Boolean>()
            pendingFileCompletions[transferId] = completed
            val sent = runCatching {
                resolver.openInputStream(uri)?.use { input ->
                    val buffer = ByteArray(FILE_CHUNK_SIZE)
                    var total = 0L
                    var sequence = 0L
                    val progress = TransferProgress(metadata.third)
                    while (true) {
                        coroutineContext.ensureActive()
                        val count = input.read(buffer)
                        if (count < 0) break
                        val encrypted = Crypto.encrypt(connectedSession.pairingKey!!, buffer.copyOf(count))
                        check(connectedSession.send(Message(
                            kind = "files.chunk",
                            sessionId = connectedSession.id,
                            messageId = UUID.randomUUID().toString(),
                            transferId = transferId,
                            sequence = sequence++,
                            nonce = encrypted.nonce,
                            ciphertext = encrypted.ciphertext,
                        )))
                        total += count
                        progress.status(total)?.let {
                            updateFileTransfer(transferId, metadata.first, "Sending ${metadata.first}: $it", true)
                        }
                    }
                    updateFileTransfer(transferId, metadata.first, "Verifying ${metadata.first} on $peer…", true)
                } ?: error("File unavailable")
                val completionPayload = Crypto.encrypt(
                    connectedSession.pairingKey!!,
                    JSONObject().put("transferId", transferId).put("sha256", hash).toString().toByteArray(),
                )
                check(connectedSession.send(Message(
                    kind = "files.complete",
                    sessionId = connectedSession.id,
                    messageId = UUID.randomUUID().toString(),
                    nonce = completionPayload.nonce,
                    ciphertext = completionPayload.ciphertext,
                )))
            }.isSuccess
            if (!sent) {
                pendingFileCompletions.remove(transferId)
                if (transferId in cancelledTransferIds || outgoingFileJobs[transferId] == null) return@launch
                updateFileTransfer(transferId, metadata.first, "File transfer failed", false)
                return@launch
            }
            if (withTimeoutOrNull(15_000) { completed.await() } == true) {
                outgoingFileSources.remove(transferId)
                if (cameraTransfers.containsKey(transferId)) cameraTransferSent.add(transferId)
                updateFileTransfer(transferId, metadata.first, "${metadata.first} saved on $peer", false, TransferEnd.SENT)
                diagnostics.record("transfer", "send_completed")
            } else {
                pendingFileCompletions.remove(transferId)
                if (transferId in cancelledTransferIds || outgoingFileJobs[transferId] == null) return@launch
                updateFileTransfer(transferId, metadata.first, "$peer did not confirm the saved file", false)
            }
        }
        outgoingFileJobs[transferId] = job
        job.invokeOnCompletion {
            outgoingFileJobs.remove(transferId, job)
            cameraTransferEnded(transferId)
            finishQueuedFile(transferId)
        }
    }

    /** The Save to… answer for a waiting folder. */
    fun answerFolderDestination(folderTransferId: String, answer: dev.bridgey.android.folders.DestinationAnswer) =
        folders.answerDestination(folderTransferId, answer)

    /** The conflict answer for a waiting folder (Merge, Replace, New folder or Cancel). */
    fun answerFolderConflict(folderTransferId: String, choice: dev.bridgey.android.folders.ConflictChoice) =
        folders.answerConflict(folderTransferId, choice)

    fun cancelFileTransfer(transferId: String) {
        if (folders.cancel(transferId)) return
        if (folderSender.cancel(transferId)) return
        if (mutableFileTransfers.value[transferId]?.kind == TransferKind.FOLDER) {
            // An interrupted folder: cancel means it no longer resumes. Completed files stay.
            folderJournals.read(transferId)?.header?.oneOffTree?.let(placesStore::releaseOneOff)
            folderJournals.delete(transferId)
            mutableFileTransfers.update { it - transferId }
            transferDevices.remove(transferId)
            refreshFileTransferSummary()
            return
        }
        val queueDevice = transferDevices[transferId]
        if (queueDevice != null && fileSendQueues[queueDevice]?.removePending(transferId) == true) {
            removeFileTransfer(transferId, "Transfer cancelled")
            diagnostics.record("transfer", "cancelled")
            return
        }
        val current = transferDevices[transferId]?.let(registry::session)
        markTransferCancelled(transferId)
        if (current != null) {
            scope.launch {
                repeat(3) { attempt ->
                    if (registry.isActive(current)) current.send(Message(kind = "files.cancel", sessionId = current.id, transferId = transferId))
                    if (attempt < 2) delay(250)
                }
            }
        }
        outgoingFileJobs.remove(transferId)?.cancel()
        incomingFiles.remove(transferId)?.cancel()
        pendingFileAccepts.remove(transferId)?.complete(false)
        pendingFileCompletions.remove(transferId)?.complete(false)
        removeFileTransfer(transferId, "Transfer cancelled")
        diagnostics.record("transfer", "cancelled")
    }

    fun cancelFileTransfer() {
        fileSendQueues.keys.forEach { stopFileQueue(it, "Transfer cancelled") }
        mutableFileTransfers.value.values.filter { it.active }.forEach { cancelFileTransfer(it.id) }
    }

    /** Retries to the same device the file first went to. */
    fun retryFileTransfer(transferId: String) {
        // An interrupted folder sent from here resumes as soon as its device takes folders again.
        if (folderSender.owns(transferId)) {
            mutableFileTransfers.value[transferId]?.deviceId?.takeIf(::sendsFoldersTo)?.let(folderSender::deviceReady)
            return
        }
        val uri = outgoingFileSources[transferId] ?: return
        val deviceId = transferDevices[transferId] ?: mutableFileTransfers.value[transferId]?.deviceId
        if (deviceId == null || registry.session(deviceId) == null) {
            removeFileTransfer(transferId, "Reconnect before retrying", TransferEnd.FAILED)
            return
        }
        if (!isFeatureAvailable(BridgeyFeature.FILES, deviceId)) {
            removeFileTransfer(transferId, "File transfer is turned off on one of your devices", TransferEnd.FAILED)
            return
        }
        mutableFileTransfers.value = mutableFileTransfers.value.toMutableMap().apply { remove(transferId) }
        outgoingFileSources.remove(transferId)
        transferDevices.remove(transferId)
        diagnostics.record("transfer", "retry_started")
        sendFile(uri, deviceId)
    }

    fun diagnosticsReport(): String {
        val stateName = when (mutableState.value) {
            PairingState.Idle -> "idle"
            is PairingState.Connecting -> "connecting"
            is PairingState.Verification -> "verification"
            is PairingState.Connected -> "connected"
            is PairingState.Failed -> "failed"
        }
        val localFeatures = BridgeyFeature.entries.associateWith { settings.isEnabled(it, null) }
        return diagnostics.report(
            appContext, stateName, mutableFileTransfers.value.values, localFeatures, mutableRemoteFeatures.value,
            devices = diagnosticDevices(),
            power = PowerFacts.summary(appContext),
        )
    }

    fun clearTransferHistory() {
        val inactiveIds = mutableFileTransfers.value.values.filterNot(FileTransferState::active).map(FileTransferState::id)
        inactiveIds.forEach {
            outgoingFileSources.remove(it)
            transferDevices.remove(it)
        }
        mutableFileTransfers.value = mutableFileTransfers.value.filterValues(FileTransferState::active)
        refreshFileTransferSummary()
    }

    fun stop() {
        pause()
        scope.cancel()
    }

    /** Bridgey turned off: every session closes and nothing redials. */
    fun pause() {
        reconnecting = false
        synchronized(discoveryLock) {
            discoveryRestartTask?.cancel()
            discoveryRestartTask = null
            discoveryWindowStart = null
        }
        pairingSession = null
        registry.clear().forEach(Session::close)
        stopPhoneRinging()
        clearPingStatus()
        quickActions.reset()
        macActions.reset()
        clipboardSessionEnded(null)
        server?.close()
        server = null
        acceptJob?.cancel()
        acceptJob = null
        pendingClipboardSends.values.forEach { it(ClipboardSendResult.NOT_CONNECTED) }
        pendingClipboardSends.clear()
        pendingFileAccepts.values.forEach { it.complete(false) }
        pendingFileAccepts.clear()
        pendingFileCompletions.values.forEach { it.complete(false) }
        pendingFileCompletions.clear()
        incomingFiles.values.forEach(IncomingFileTransfer::cancel)
        incomingFiles.clear()
        folders.deviceGone(null)
        interruptFileQueue()
        outgoingFileJobs.values.forEach(Job::cancel)
        outgoingFileJobs.clear()
        mutableFileTransfers.value = recoverInterruptedTransfers(mutableFileTransfers.value)
        refreshFileTransferSummary("File transfer interrupted")
        mutablePairingFlow.value = PairingState.Idle
        publish()
    }

    /** Recomputes the per-device list and the aggregate flows (selected device, any ringing). */
    private fun publish() {
        synchronized(publishLock) {
            val list = registry.connections()
            mutableConnections.value = list
            val targetId = registry.target(selectedDeviceId)
            val target = list.firstOrNull { it.deviceId == targetId }
            mutableState.value = target?.let { PairingState.Connected(it.deviceId, it.peerName) } ?: mutablePairingFlow.value
            mutableRemoteFeatures.value = target?.state?.remoteFeatures ?: defaultFeatureState()
            mutableRemoteBattery.value = target?.state?.battery
            mutableRemoteClipboardFiles.value = target?.state?.remoteClipboardFiles == true
            mutableMacRinging.value = list.any { it.state.ringing }
            if (targetId != publishedTarget) {
                publishedTarget = targetId
                quickActions.targetChanged(targetId?.let(registry::session)?.media)
            }
        }
    }

    /** One device's session ended: only its state, transfers and clipboard fetches go, and its reconnect starts. */
    private fun deviceDisconnected(deviceId: String, reason: String) {
        cancelTransfers(deviceId)
        clipboardSessionEnded(deviceId)
        if (phoneRingingFrom == deviceId) stopPhoneRinging()
        if (pendingPing?.first == deviceId) clearPingStatus()
        macActions.sessionEnded(deviceId)
        focusSync.sessionEnded(deviceId)
        endCameraRequest(deviceId)
        health.disconnected(deviceId, reason, System.currentTimeMillis())
        // The power state at the moment of the drop: Doze, screen, saver, standby bucket, exemption.
        diagnostics.record("transport", "disconnected", reason, device = deviceId, detail = PowerFacts.summary(appContext))
        BridgeyLogging.i(LogCategory.CONNECTION, "TRANSPORT disconnected peerId=${deviceId.take(8)} reason=$reason")
        publish()
        if (!reconnecting || deviceId !in trust.trustedDeviceIds.value) return
        reconnect.disconnected(deviceId)
        synchronized(discoveryLock) { discoveryWindowStart = SystemClock.elapsedRealtime() }
        armDiscoveryRestart()
    }

    private fun handle(socket: Socket, initiatedLocally: Boolean, peerHint: String?, manual: Boolean = false, dialDeviceId: String? = null) {
        val current = runCatching {
            socket.keepAlive = true
            socket.tcpNoDelay = true
            socket.soTimeout = ReconnectPolicy.HEARTBEAT_INTERVAL_MILLIS.toInt()
            Session(socket)
        }.getOrElse {
            runCatching { socket.close() }
            dialDeviceId?.let(reconnect::dialEnded)
            return
        }
        current.initiatedLocally = initiatedLocally
        current.dialDeviceId = dialDeviceId
        // Where the other end is: once it authenticates, the next reconnect can dial it there.
        current.remoteHost = socket.inetAddress?.hostAddress?.let(::normalizedHost)
        current.remotePort = socket.port
        if (!initiatedLocally) {
            BridgeyLogging.i(LogCategory.CONNECTION, "TRANSPORT inbound connection address=${current.remoteHost?.let(::addressTag) ?: "unknown"}")
        }
        registry.addPending(current, initiatedLocally)
        if (manual) pairingSession = current
        if (initiatedLocally) {
            current.peerName = peerHint ?: "Mac"
            current.keyPair = Crypto.generateKeyPair()
            current.localEphemeralKey = Crypto.encodePublicKey(current.keyPair!!)
            current.id = UUID.randomUUID().toString()
            current.send(
                Message(
                    kind = "pairing.offer",
                    sessionId = current.id,
                    deviceId = localDeviceId,
                    deviceName = localDeviceName,
                    publicKey = current.localEphemeralKey,
                    targetDeviceId = dialDeviceId,
                ),
            )
        }
        val result = runCatching {
            while (true) {
                try {
                    val line = current.input.readProtocolLine() ?: break
                    current.lastReceivedAtMillis = SystemClock.elapsedRealtime()
                    receive(current, Message.decode(line))
                } catch (_: SocketTimeoutException) {
                    if (current.closed) break
                    val now = SystemClock.elapsedRealtime()
                    if (registry.isActive(current)) {
                        if (heartbeatExpired(
                                supported = current.heartbeatSupported,
                                lastReceivedAtMillis = current.lastReceivedAtMillis,
                                nowMillis = now,
                            )
                        ) {
                            BridgeyLogging.w(LogCategory.CONNECTION, "TRANSPORT heartbeat timed out peerId=${current.remoteDeviceId.take(8)}")
                            current.dropReason = "heartbeat_timeout"
                            break
                        }
                        val pingId = UUID.randomUUID().toString()
                        health.heartbeatSent(current.remoteDeviceId, pingId, SystemClock.elapsedRealtime())
                        if (!current.send(Message(
                                kind = "heartbeat.ping",
                                sessionId = current.id,
                                messageId = pingId,
                            ))
                        ) {
                            current.dropReason = "send_failed"
                            break
                        }
                        reconnect.stillConnected(current.remoteDeviceId)
                    } else if (pendingExpired(current, now)) {
                        current.failure = PairingFailure.TIMEOUT
                        current.dropReason = "handshake_timeout"
                        BridgeyLogging.w(LogCategory.CONNECTION, "PAIRING timed out")
                        break
                    }
                }
            }
        }
        // Why it ended: set on purpose (heartbeat, replaced, user), else from the socket.
        val reason = current.dropReason ?: result.exceptionOrNull()?.let(::socketDropReason) ?: if (current.closed) "closed" else "closed_by_peer"
        current.close()
        dialFinished(current)
        val deviceId = registry.remove(current)
        when {
            deviceId != null -> deviceDisconnected(deviceId, reason)
            pairingSession === current -> {
                if (result.exceptionOrNull() != null) BridgeyLogging.w(LogCategory.CONNECTION, "PAIRING disconnected before confirmation")
                failPairing(current, current.failure ?: PairingFailure.CONNECTION_LOST)
            }
            current.dialDeviceId != null && !current.authenticated && reason != "duplicate" -> {
                // A reconnect that never authenticated: the schedule tries again.
                val dialed = current.dialDeviceId!!
                BridgeyLogging.i(LogCategory.CONNECTION, "RECONNECT dial failed peer=${dialed.take(8)} reason=$reason")
                diagnostics.record("reconnect", "dial_failed", reason, device = dialed)
            }
        }
    }

    /** A dial is over (connected, lost the duplicate rule or failed): it no longer blocks the next attempt. */
    private fun dialFinished(current: Session) {
        val dialed = current.dialDeviceId ?: return
        if (current.dialFinished.getAndSet(true)) return
        reconnect.dialEnded(dialed)
    }

    /** A pending session waits 20 s for the handshake, or two minutes for the user to confirm the code. */
    private fun pendingExpired(current: Session, now: Long): Boolean {
        val limit = if (current.code != null && trust.identityKey(current.remoteDeviceId) == null) {
            VERIFICATION_TIMEOUT_MILLIS
        } else {
            HANDSHAKE_TIMEOUT_MILLIS
        }
        return now - current.createdAtMillis >= limit
    }

    private fun receive(current: Session, message: Message) {
        when (message.kind) {
            "quick.request", "quick.result", "media.state" -> receiveQuickPayload(current, message)
            "heartbeat.ping" -> {
                if (message.sessionId != current.id || !registry.isActive(current)) return
                current.heartbeatSupported = true
                current.send(Message(kind = "heartbeat.pong", sessionId = current.id, messageId = message.messageId))
            }
            "heartbeat.pong" -> {
                if (message.sessionId == current.id && registry.isActive(current)) {
                    current.heartbeatSupported = true
                    health.heartbeatAnswered(current.remoteDeviceId, message.messageId, SystemClock.elapsedRealtime())
                }
            }
            "pairing.offer" -> {
                if (current.initiatedLocally || current.pairingKey != null) return
                // A reconnect meant for another device (it dialled an address that is now ours):
                // close without a pairing prompt.
                if (message.targetDeviceId != null && !message.targetDeviceId.equals(localDeviceId, ignoreCase = true)) {
                    current.dropReason = "not_for_this_device"
                    current.close()
                    return
                }
                current.id = message.sessionId
                current.peerName = message.deviceName ?: "Android device"
                current.remoteDeviceId = message.deviceId ?: return
                current.remoteEphemeralKey = message.publicKey ?: return
                current.keyPair = Crypto.generateKeyPair()
                current.localEphemeralKey = Crypto.encodePublicKey(current.keyPair!!)
                val material = Crypto.pairingMaterial(current.keyPair!!, current.remoteEphemeralKey, current.id)
                current.code = material.code
                current.pairingKey = material.key
                current.send(
                    Message(
                        kind = "pairing.answer",
                        sessionId = current.id,
                        deviceId = localDeviceId,
                        deviceName = localDeviceName,
                        publicKey = current.localEphemeralKey,
                    ),
                )
                authenticateOrPrompt(current)
            }
            "pairing.answer" -> {
                if (message.sessionId != current.id || current.pairingKey != null) return
                // A reconnect reached some other device at the old address: never prompt to pair it.
                val expected = current.dialDeviceId
                if (expected != null && !expected.equals(message.deviceId, ignoreCase = true)) {
                    current.dropReason = "wrong_device"
                    current.close()
                    return
                }
                current.peerName = message.deviceName ?: current.peerName
                current.remoteDeviceId = message.deviceId ?: return
                current.remoteEphemeralKey = message.publicKey ?: return
                val material = Crypto.pairingMaterial(current.keyPair!!, current.remoteEphemeralKey, current.id)
                current.code = material.code
                current.pairingKey = material.key
                authenticateOrPrompt(current)
            }
            "pairing.confirm" -> {
                if (message.sessionId != current.id || current.pairingKey == null) return
                val remoteId = message.deviceId ?: return failHandshake(current, PairingFailure.INVALID, "Invalid pairing confirmation")
                val identityKey = message.identityKey ?: return failHandshake(current, PairingFailure.INVALID, "Invalid pairing confirmation")
                val proof = message.proof ?: return failHandshake(current, PairingFailure.INVALID, "Invalid pairing confirmation")
                val signature = message.signature ?: return failHandshake(current, PairingFailure.INVALID, "Invalid pairing confirmation")
                val pinnedKey = trust.identityKey(remoteId)
                if (pinnedKey != null && pinnedKey != identityKey) {
                    return failHandshake(current, PairingFailure.IDENTITY_CHANGED, "Pinned identity changed")
                }
                if (
                    remoteId != current.remoteDeviceId || !Crypto.verifyConfirmationProof(
                        current.pairingKey!!,
                        current.id,
                        remoteId,
                        identityKey,
                        proof,
                    ) || !Crypto.verifySignature(identityKey, authTranscript(current), signature)
                ) return failHandshake(current, PairingFailure.CODE_REJECTED, "Pairing authentication failed")
                current.remoteIdentityKey = identityKey
                current.remoteConfirmed = true
                completeIfConfirmed(current)
            }
            // Only ever ends the session it arrived on: never another device's.
            "pairing.cancel" -> {
                if (message.sessionId != current.id && current.id.isNotEmpty()) return
                current.failure = PairingFailure.CANCELLED_REMOTE
                current.dropReason = "cancelled_remote"
                current.close()
            }
            "features.update" -> receiveFeatureState(current, message)
            "clipboard.update" -> receiveClipboard(current, message, rich = false)
            "clipboard.rich" -> receiveClipboard(current, message, rich = true)
            "clipboard.offer" -> receiveClipboardOffer(current, message)
            "clipboard.fetch" -> receiveClipboardFetch(current, message)
            "clipboard.error" -> receiveClipboardError(current, message)
            "clipboard.ack" -> {
                val messageId = message.messageId ?: return
                pendingClipboardSends.remove(messageId)?.let { callback ->
                    mutableClipboardStatus.value = "Delivered"
                    callback(ClipboardSendResult.DELIVERED)
                    BridgeyLogging.line(LogLines.clipboard(BridgeyLogging.policy, "acknowledged"))
                }
            }
            "clipboard.rejected" -> {
                val messageId = message.messageId ?: return
                pendingClipboardSends.remove(messageId)?.let { callback ->
                    mutableClipboardStatus.value = "Clipboard is turned off on ${current.peerName}"
                    callback(ClipboardSendResult.DISABLED)
                }
            }
            "notifications.dismiss" -> receiveNotificationDismiss(current, message)
            "codes.advertise_result", "codes.link_request" -> receiveCodesMessage(current, message)
            "actions.catalog", "actions.result" -> receiveActionsMessage(current, message)
            "focus.state" -> receiveFocusMessage(current, message)
            "camera.request" -> receiveCameraMessage(current, message)
            "notifications.action" -> receiveNotificationAction(current, message)
            "calls.request" -> receiveCallRequest(current, message)
            "find.start" -> receiveFindCommand(current, message, start = true)
            "find.stop" -> receiveFindCommand(current, message, start = false)
            "find.started" -> receiveFindAcknowledgement(current, message, started = true)
            "find.stopped" -> receiveFindAcknowledgement(current, message, started = false)
            "ping.request" -> receivePing(current, message)
            "ping.ack" -> {
                if (!registry.isActive(current) || message.sessionId != current.id) return
                val messageId = message.messageId ?: return
                if (pendingPing == (current.remoteDeviceId to messageId)) {
                    pendingPing = null
                    mutablePingStatus.value = "Ping delivered"
                    activityListener?.invoke(PeerEvent(PeerActivity.PING_SENT, current.remoteDeviceId, current.peerName))
                }
            }
            "battery.update" -> receiveBattery(current, message)
            "files.accept" -> message.transferId?.let {
                if (folderSender.ownsFile(it)) folderSender.handleOuter(current.remoteDeviceId, message.kind, it, message.sequence)
                else if (clipboardOutbox.handles(it)) clipboardOutbox.onAccepted(it)
                else if (ownsTransfer(current, it)) pendingFileAccepts.remove(it)?.complete(true)
            }
            "files.chunk.ack" -> message.transferId?.let {
                if (folderSender.ownsFile(it) && registry.isActive(current) && message.sessionId == current.id) {
                    folderSender.handleOuter(current.remoteDeviceId, message.kind, it, message.sequence)
                }
            }
            "files.complete.ack" -> message.transferId?.let {
                if (folderSender.ownsFile(it)) folderSender.handleOuter(current.remoteDeviceId, message.kind, it, message.sequence)
                else if (clipboardOutbox.handles(it)) clipboardOutbox.onCompleteAcknowledged(it)
                else if (ownsTransfer(current, it)) pendingFileCompletions.remove(it)?.complete(true)
            }
            "files.offer" -> {
                if (receiveClipboardTransferOffer(current, message)) return
                // A folder that was accepted finishes even if Files is turned off meanwhile (receiveFileOffer routes it).
                if (settings.isEnabled(BridgeyFeature.FILES, current.remoteDeviceId) || folders.activeFor(current.remoteDeviceId) != null) {
                    receiveFileOffer(current, message)
                } else {
                    current.send(Message(kind = "files.rejected", sessionId = current.id, transferId = message.transferId))
                    sendFeatureState(current)
                }
            }
            "files.rejected" -> message.transferId?.let { transferId ->
                if (folderSender.ownsFile(transferId)) return folderSender.handleOuter(current.remoteDeviceId, message.kind, transferId, null).let { }
                if (clipboardOutbox.handles(transferId)) return clipboardOutbox.onCancelled(transferId)
                if (!ownsTransfer(current, transferId)) return
                stopFileQueue(current.remoteDeviceId, "File transfer is turned off on ${current.peerName}")
                pendingFileAccepts.remove(transferId)?.complete(false)
                outgoingFileJobs.remove(transferId)?.cancel()
                removeFileTransfer(transferId, "File transfer is turned off on ${current.peerName}", TransferEnd.FAILED)
            }
            // Once an offer has been accepted, let that transfer finish even if the
            // setting changes. Disabling Files blocks the next offer instead.
            "files.chunk" -> when {
                clipboardInbox.handles(message.transferId) -> receiveClipboardChunk(current, message)
                folders.handles(message.transferId) -> receiveFolderChunk(current, message)
                else -> receiveFileChunk(current, message)
            }
            "files.complete" -> if (clipboardInbox.handles(message.transferId)) receiveClipboardComplete(current, message) else receiveFileComplete(current, message)
            "files.cancel" -> when {
                folderSender.ownsFile(message.transferId) -> {
                    if (registry.isActive(current) && message.sessionId == current.id) {
                        folderSender.handleOuter(current.remoteDeviceId, message.kind, message.transferId!!, null)
                    }
                }
                folders.handles(message.transferId) -> {
                    if (registry.isActive(current) && message.sessionId == current.id) {
                        folders.fileCancel(current.remoteDeviceId, message.transferId!!, FolderSessionLink(current))
                    }
                }
                clipboardInbox.handles(message.transferId) || clipboardOutbox.handles(message.transferId) -> {
                    val transferId = message.transferId!!
                    clipboardInbox.onCancelled(transferId)
                    clipboardOutbox.onCancelled(transferId)
                    current.send(Message(kind = "files.cancel.ack", sessionId = current.id, transferId = transferId))
                }
                else -> receiveFileCancel(current, message.transferId)
            }
            "files.cancel.ack" -> message.transferId?.let {
                if (folderSender.ownsFile(it)) return@let
                if (ownsTransfer(current, it)) removeFileTransfer(it, "Transfer cancelled")
            }
            dev.bridgey.android.folders.FolderKinds.PLACES_LIST, dev.bridgey.android.folders.FolderKinds.PLACES_BROWSE,
            dev.bridgey.android.folders.FolderKinds.PLACES_CREATE_FOLDER, dev.bridgey.android.folders.FolderKinds.OFFER,
            dev.bridgey.android.folders.FolderKinds.MANIFEST, dev.bridgey.android.folders.FolderKinds.RESOLVE,
            dev.bridgey.android.folders.FolderKinds.COMPLETE, dev.bridgey.android.folders.FolderKinds.CANCEL,
            dev.bridgey.android.folders.FolderKinds.WAITING, dev.bridgey.android.folders.FolderKinds.CONFLICT,
            dev.bridgey.android.folders.FolderKinds.ACCEPT, dev.bridgey.android.folders.FolderKinds.REJECTED,
            dev.bridgey.android.folders.FolderKinds.ENTRY_FAILED, dev.bridgey.android.folders.FolderKinds.RESULT,
            -> receiveFolderMessage(current, message)
            // Only folders this phone sends wait for a cancel acknowledgement.
            dev.bridgey.android.folders.FolderKinds.CANCEL_ACK -> message.transferId?.let {
                if (registry.isActive(current) && message.sessionId == current.id) folderSender.handleOuter(current.remoteDeviceId, message.kind, it, null)
            }
            in dev.bridgey.android.browse.BrowseKinds.requests, in dev.bridgey.android.browse.BrowseKinds.answers -> receiveBrowseMessage(current, message)
            else -> if (message.kind.startsWith("input.")) receiveRemoteInput(current, message)
        }
    }

    /** File transfer messages only count from the device the transfer belongs to. */
    private fun ownsTransfer(current: Session, transferId: String): Boolean =
        transferDevices[transferId]?.let { it == current.remoteDeviceId } ?: true

    private fun receiveNotificationDismiss(current: Session, message: Message) {
        if (!settings.isEnabled(BridgeyFeature.NOTIFICATIONS, current.remoteDeviceId)) {
            sendFeatureState(current)
            return
        }
        if (!registry.isActive(current) || message.sessionId != current.id) return
        val messageId = message.messageId ?: return
        if (!current.acceptMessageId(messageId)) return
        val plaintext = Crypto.decrypt(
            current.pairingKey!!,
            message.nonce ?: return fail(current, "Invalid encrypted notification command"),
            message.ciphertext ?: return fail(current, "Invalid encrypted notification command"),
        ) ?: return fail(current, "Invalid encrypted notification command")
        val notificationId = runCatching {
            JSONObject(plaintext.toString(Charsets.UTF_8)).getString("notificationId")
        }.getOrNull()?.takeIf { it.isNotBlank() && it.length <= 512 }
            ?: return fail(current, "Invalid notification command")
        BridgeyNotificationListenerService.dismiss(notificationId)
        diagnostics.record("notification", "dismiss_requested")
    }

    private fun receiveCallRequest(current: Session, message: Message) {
        val messageId = message.messageId ?: return
        if (!registry.isActive(current) || message.sessionId != current.id || !current.acceptMessageId(messageId)) return
        if (!settings.isEnabled(BridgeyFeature.CALLS, current.remoteDeviceId)) {
            current.send(Message(kind = "calls.rejected", sessionId = current.id, messageId = messageId))
            sendFeatureState(current)
            return
        }
        val now = SystemClock.elapsedRealtime()
        if (lastRemoteCallRequestAt != 0L && now - lastRemoteCallRequestAt < 3_000) {
            current.send(Message(kind = "calls.rejected", sessionId = current.id, messageId = messageId))
            return
        }
        val nonce = message.nonce ?: return fail(current, "Invalid encrypted call request")
        val ciphertext = message.ciphertext ?: return fail(current, "Invalid encrypted call request")
        val plaintext = Crypto.decrypt(
            current.pairingKey!!,
            nonce,
            ciphertext,
        ) ?: return fail(current, "Invalid encrypted call request")
        val number = runCatching {
            JSONObject(plaintext.toString(Charsets.UTF_8)).getString("number")
        }.getOrNull()?.let(::normalizedPhoneNumber)
        if (number == null) {
            current.send(Message(kind = "calls.rejected", sessionId = current.id, messageId = messageId))
            return
        }
        lastRemoteCallRequestAt = now
        val result = remoteCallRequest.execute(number, settings.state.value.directCallsEnabled)
        current.send(Message(kind = result.wireKind, sessionId = current.id, messageId = messageId))
        diagnostics.record("calls", "request", outcome = result.name.lowercase())
        if (result == RemoteCallResult.STARTED) {
            activityListener?.invoke(PeerEvent(PeerActivity.CALL_STARTED, current.remoteDeviceId, current.peerName))
        }
    }

    private fun receiveNotificationAction(current: Session, message: Message) {
        if (!settings.isEnabled(BridgeyFeature.NOTIFICATIONS, current.remoteDeviceId)) {
            sendFeatureState(current)
            return
        }
        if (!registry.isActive(current) || message.sessionId != current.id) return
        val messageId = message.messageId ?: return
        if (!current.acceptMessageId(messageId)) return
        val plaintext = Crypto.decrypt(
            current.pairingKey!!,
            message.nonce ?: return fail(current, "Invalid encrypted notification action"),
            message.ciphertext ?: return fail(current, "Invalid encrypted notification action"),
        ) ?: return fail(current, "Invalid encrypted notification action")
        val payload = runCatching { JSONObject(plaintext.toString(Charsets.UTF_8)) }.getOrNull()
            ?: return fail(current, "Invalid notification action")
        val notificationId = payload.optString("notificationId")
        val actionToken = payload.optString("actionToken")
        val replyText = payload.optString("replyText").takeIf { payload.has("replyText") }
        if (notificationId.isBlank() || notificationId.length > 512 ||
            !actionToken.matches(Regex("[0-9a-f]{64}")) ||
            (replyText?.length ?: 0) > 4_096) return fail(current, "Invalid notification action")
        BridgeyNotificationListenerService.perform(
            notificationId, actionToken, replyText,
            callsEnabled = settings.isEnabled(BridgeyFeature.CALLS, current.remoteDeviceId),
        )
        diagnostics.record("notification", if (replyText == null) "action_requested" else "reply_requested")
    }

    private fun receiveClipboard(current: Session, message: Message, rich: Boolean) {
        if (!settings.isEnabled(BridgeyFeature.CLIPBOARD, current.remoteDeviceId)) {
            current.send(Message(kind = "clipboard.rejected", sessionId = current.id, messageId = message.messageId))
            sendFeatureState(current)
            return
        }
        if (!registry.isActive(current) || message.sessionId != current.id) return
        val messageId = message.messageId ?: return
        if (!current.acceptMessageId(messageId)) return
        val plaintext = Crypto.decrypt(
            current.pairingKey!!,
            message.nonce ?: return,
            message.ciphertext ?: return,
        ) ?: return fail(current, "Invalid encrypted clipboard message")
        // The Mac may one day flag a clip as sensitive in the rich JSON; it does not today, so
        // we read it only if present and otherwise treat the clip as not sensitive.
        val text: String
        val sensitive: Boolean
        val clip = if (rich) {
            val content = RichClipboardContent.decode(plaintext)
                ?: return fail(current, "Invalid rich clipboard message")
            text = content.text
            sensitive = runCatching { JSONObject(plaintext.toString(Charsets.UTF_8)).optBoolean("sensitive", false) }.getOrDefault(false)
            ClipData.newHtmlText("Bridgey", content.text, content.html)
        } else {
            text = plaintext.toString(Charsets.UTF_8)
            if (!clipboardTextFits(text)) return fail(current, "Invalid clipboard message")
            sensitive = false
            ClipData.newPlainText("Bridgey", text)
        }
        if (sensitive && android.os.Build.VERSION.SDK_INT >= 33) {
            clip.description.extras = (clip.description.extras ?: PersistableBundle())
                .apply { putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true) }
        }
        // Writing to the clipboard is allowed from the background and while the screen is off;
        // only reading is restricted. A write can still fail on some OEMs, so record it, don't swallow.
        val written = runCatching { appContext.getSystemService(ClipboardManager::class.java).setPrimaryClip(clip) }.isSuccess
        if (!written) {
            diagnostics.record("clipboard", if (rich) "rich_received" else "text_received", "write_failed")
            BridgeyLogging.w(LogCategory.CLIPBOARD, "CLIPBOARD write failed")
            activityListener?.invoke(PeerEvent(PeerActivity.CLIPBOARD_RECEIVE_FAILED, current.remoteDeviceId, current.peerName, automatic = true))
            current.send(Message(kind = "clipboard.ack", sessionId = current.id, messageId = messageId))
            return
        }
        // Remember what we wrote so our own clip-change event and the next resume read do not bounce it back.
        recordIncomingClip(current.remoteDeviceId, text)
        // Text replaces any clip offer, in both directions.
        clipboardInbox.supersede()
        clipboardOutbox.supersede(SessionClipLink(current))
        diagnostics.record("clipboard", if (rich) "rich_received" else "text_received")
        BridgeyLogging.line(LogLines.clipboard(BridgeyLogging.policy, "received", text.takeUnless { sensitive }))
        activityListener?.invoke(
            PeerEvent(PeerActivity.CLIPBOARD_RECEIVED, current.remoteDeviceId, current.peerName, text, sensitive, automatic = true),
        )
        current.send(Message(kind = "clipboard.ack", sessionId = current.id, messageId = messageId))
    }

    /** Decrypts an encrypted clipboard offer message; null (ignored, session kept) when it does not check out. */
    private fun clipboardPlaintext(current: Session, message: Message, consumeId: Boolean = true): ByteArray? {
        if (!registry.isActive(current) || message.sessionId != current.id) return null
        val key = current.pairingKey ?: return null
        val messageId = message.messageId ?: return null
        val plaintext = Crypto.decrypt(key, message.nonce ?: return null, message.ciphertext ?: return null) ?: return null
        if (consumeId && !current.acceptMessageId(messageId)) return null
        return plaintext
    }

    private fun receiveClipboardOffer(current: Session, message: Message) {
        if (!clipboardOffersEnabledLocally(current)) {
            current.send(Message(kind = "clipboard.rejected", sessionId = current.id, messageId = message.messageId))
            sendFeatureState(current)
            return
        }
        val plaintext = clipboardPlaintext(current, message) ?: return
        val offer = ClipOffer.decode(plaintext) ?: return diagnostics.record("clipboard", "offer_rejected", "invalid")
        if (clipboardInbox.currentOfferId != offer.offerId) {
            // The Mac's copy replaces whatever this phone offered.
            clipboardOutbox.supersede(SessionClipLink(current))
            clipboardInbox.link = SessionClipLink(current)
            clipboardInbox.accept(offer, SessionClipLink(current))
        }
        current.send(Message(kind = "clipboard.ack", sessionId = current.id, messageId = message.messageId))
        BridgeyLogging.line(LogLines.clipboard(BridgeyLogging.policy, "offer received"))
    }

    private fun receiveClipboardFetch(current: Session, message: Message) {
        val plaintext = clipboardPlaintext(current, message) ?: return
        val request = parseClipReference(plaintext, message.transferId) ?: return
        val link = SessionClipLink(current)
        if (!clipboardOffersEnabledLocally(current)) {
            link.send("clipboard.error", request.transferId, clipErrorPayload(request.offerId, request.index, request.transferId, ClipErrorCode.DISABLED))
            return
        }
        clipboardOutbox.onFetch(link, request)
    }

    private fun receiveClipboardError(current: Session, message: Message) {
        val plaintext = clipboardPlaintext(current, message) ?: return
        val reference = parseClipReference(plaintext, message.transferId) ?: return
        val code = runCatching { JSONObject(plaintext.toString(Charsets.UTF_8)).optString("code") }.getOrNull()
            ?.takeIf { it in ClipErrorCode.all } ?: ClipErrorCode.UNAVAILABLE
        clipboardInbox.onError(reference.transferId, code)
    }

    /** A files.offer marked for the clipboard: never the Files path, prompt or Downloads. True when handled. */
    private fun receiveClipboardTransferOffer(current: Session, message: Message): Boolean {
        val transferId = message.transferId ?: return false
        if (!clipboardInbox.handles(transferId) && registry.state(current.remoteDeviceId)?.remoteClipboardFiles != true) return false
        val plaintext = clipboardPlaintext(current, message, consumeId = false) ?: return false
        val payload = runCatching { JSONObject(plaintext.toString(Charsets.UTF_8)) }.getOrNull() ?: return false
        if (payload.optString("purpose") != "clipboard") return false
        if (!current.acceptMessageId(message.messageId ?: return true)) return true
        val offer = parseClipTransferOffer(payload)
        if (offer == null || offer.transferId != transferId || !clipboardOffersEnabledLocally(current)) {
            current.send(Message(kind = "files.cancel", sessionId = current.id, transferId = transferId))
            return true
        }
        clipboardInbox.onTransferOffer(SessionClipLink(current), offer)
        return true
    }

    private fun receiveClipboardChunk(current: Session, message: Message) {
        if (!registry.isActive(current) || message.sessionId != current.id) return
        val transferId = message.transferId ?: return
        val messageId = message.messageId ?: return
        if (!current.acceptMessageId(messageId)) return
        val chunk = Crypto.decrypt(current.pairingKey ?: return, message.nonce ?: return, message.ciphertext ?: return)
        if (chunk == null || !clipboardInbox.onChunk(transferId, message.sequence ?: -1, chunk)) return
        current.send(Message(kind = "files.chunk.ack", sessionId = current.id, transferId = transferId, sequence = message.sequence))
    }

    private fun receiveClipboardComplete(current: Session, message: Message) {
        val transferId = message.transferId ?: return
        val plaintext = clipboardPlaintext(current, message) ?: return
        val payload = runCatching { JSONObject(plaintext.toString(Charsets.UTF_8)) }.getOrNull() ?: return
        val sha256 = parseClipCompletion(payload, transferId) ?: return clipboardInbox.onError(transferId, ClipErrorCode.INVALID)
        clipboardInbox.onComplete(SessionClipLink(current), transferId, sha256)
    }

    private fun receiveFindAcknowledgement(current: Session, message: Message, started: Boolean) {
        if (!registry.isActive(current) || message.sessionId != current.id) return
        val messageId = message.messageId ?: return
        if (!current.acceptMessageId(messageId)) return
        val plaintext = Crypto.decrypt(
            current.pairingKey!!,
            message.nonce ?: return fail(current, "Invalid encrypted find-device acknowledgement"),
            message.ciphertext ?: return fail(current, "Invalid encrypted find-device acknowledgement"),
        ) ?: return fail(current, "Invalid encrypted find-device acknowledgement")
        if (runCatching { JSONObject(plaintext.toString(Charsets.UTF_8)).getString("alertId") }.getOrNull() != "active") {
            return fail(current, "Invalid find-device acknowledgement")
        }
        val wasRinging = registry.state(current.remoteDeviceId)?.ringing == true
        registry.update(current.remoteDeviceId) { it.copy(ringing = started) }
        if (started && !wasRinging) {
            activityListener?.invoke(PeerEvent(PeerActivity.FIND_REMOTE_STARTED, current.remoteDeviceId, current.peerName))
        }
        publish()
    }

    private fun receiveFileOffer(current: Session, message: Message) {
        if (!registry.isActive(current) || message.sessionId != current.id) return
        val messageId = message.messageId ?: return
        if (!current.acceptMessageId(messageId)) return
        val plaintext = Crypto.decrypt(
            current.pairingKey!!,
            message.nonce ?: return fail(current, "Invalid encrypted file offer"),
            message.ciphertext ?: return fail(current, "Invalid encrypted file offer"),
        ) ?: return fail(current, "Invalid encrypted file offer")
        val payload = runCatching { JSONObject(plaintext.toString(Charsets.UTF_8)) }.getOrNull()
            ?: return fail(current, "Invalid file offer")
        // A file inside a folder transfer (4.6): the folder session checks it against the manifest.
        if (payload.has("folderTransferId")) {
            val folderFileId = payload.optString("transferId").takeIf { dev.bridgey.android.folders.isWireId(it) } ?: return
            if (message.transferId != null && message.transferId != folderFileId) return
            folders.fileOffer(current.remoteDeviceId, folderFileId, payload)
            return
        }
        if (!settings.isEnabled(BridgeyFeature.FILES, current.remoteDeviceId)) {
            current.send(Message(kind = "files.rejected", sessionId = current.id, transferId = message.transferId))
            sendFeatureState(current)
            return
        }
        val transferId = payload.optString("transferId")
        val name = payload.optString("name")
        val mimeType = payload.optString("mimeType", "application/octet-stream")
        val size = payload.optLong("size", -1)
        val hash = payload.optString("sha256")
        if (runCatching { UUID.fromString(transferId) }.isFailure || name.isBlank() || size !in 0..MAX_FILE_SIZE ||
            runCatching { Base64.decode(hash, Base64.DEFAULT).size == 32 }.getOrDefault(false).not() ||
            incomingFiles.containsKey(transferId)
        ) return fail(current, "Invalid file offer")
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return fail(current, "Receiving files requires Android 10 or newer")
        }
        // Single files land in Download/Bridgey through MediaStore: refuse up front when the file plus 64 MiB does
        // not fit, instead of failing when the disk fills mid-way. The answer is the existing outer files.cancel
        // (the Mac ends the file and moves on), with an encrypted {transferId, code, neededBytes, freeBytes} a newer
        // Mac can read; older Macs ignore it.
        val free = runCatching { dev.bridgey.android.folders.MediaStoreTreeStore(appContext.contentResolver).freeBytes() }.getOrNull()
        val needed = size + dev.bridgey.android.folders.FolderLimits.SPACE_MARGIN
        if (free != null && free < needed) {
            val detail = JSONObject().put("version", 1).put("transferId", transferId)
                .put("code", dev.bridgey.android.folders.FolderCodes.INSUFFICIENT_SPACE).put("neededBytes", needed).put("freeBytes", free)
            val encrypted = Crypto.encrypt(current.pairingKey!!, detail.toString().toByteArray(Charsets.UTF_8))
            current.send(Message(kind = "files.cancel", sessionId = current.id, messageId = UUID.randomUUID().toString(), transferId = transferId,
                nonce = encrypted.nonce, ciphertext = encrypted.ciphertext))
            markTransferCancelled(transferId)
            mutableFileTransferStatus.value = appContext.getString(R.string.file_receive_no_space)
            diagnostics.record("transfer", "receive_refused", "insufficient_space")
            BridgeyLogging.i(LogCategory.FILES, "FILE refused code=insufficient_space transfer=${transferId.take(8)}")
            return
        }
        val transfer = runCatching {
            IncomingFileTransfer(appContext, transferId, name, mimeType, size, hash)
        }.getOrElse { return fail(current, "Could not create file in Downloads") }
        incomingFiles[transferId] = transfer
        transferDevices[transferId] = current.remoteDeviceId
        updateFileTransfer(transferId, transfer.displayName, "Receiving ${transfer.displayName}: ${transfer.progress.status(0, force = true)}", true)
        current.send(Message(kind = "files.accept", sessionId = current.id, transferId = transferId))
        BridgeyLogging.i(LogCategory.FILES, LogLines.file(BridgeyLogging.policy, "accepted", transferId, transfer.displayName, "size=$size"))
    }

    private fun receiveFileChunk(current: Session, message: Message) {
        if (!registry.isActive(current) || message.sessionId != current.id) return
        val messageId = message.messageId ?: return
        if (!current.acceptMessageId(messageId)) return
        val transferId = message.transferId ?: return
        if (!ownsTransfer(current, transferId)) return
        val transfer = incomingFiles[transferId] ?: run {
            if (transferId in cancelledTransferIds) return
            return fail(current, "Unknown file transfer")
        }
        val chunk = Crypto.decrypt(
            current.pairingKey!!,
            message.nonce ?: return fail(current, "Invalid encrypted file chunk"),
            message.ciphertext ?: return fail(current, "Invalid encrypted file chunk"),
        ) ?: return fail(current, "Invalid encrypted file chunk")
        if (!runCatching { transfer.append(chunk, message.sequence ?: -1) }.isSuccess) {
            incomingFiles.remove(transfer.transferId)?.cancel()
            return fail(current, "Invalid file data")
        }
        transfer.progress.status(transfer.receivedSize)?.let {
            updateFileTransfer(transferId, transfer.displayName, "Receiving ${transfer.displayName}: $it", true)
        }
        current.send(
            Message(
                kind = "files.chunk.ack",
                sessionId = current.id,
                transferId = transferId,
                sequence = message.sequence,
            ),
        )
    }

    private fun receiveFileComplete(current: Session, message: Message) {
        if (!registry.isActive(current) || message.sessionId != current.id) return
        val messageId = message.messageId ?: return
        if (!current.acceptMessageId(messageId)) return
        val plaintext = Crypto.decrypt(
            current.pairingKey!!,
            message.nonce ?: return fail(current, "Invalid encrypted file completion"),
            message.ciphertext ?: return fail(current, "Invalid encrypted file completion"),
        ) ?: return fail(current, "Invalid encrypted file completion")
        val payload = runCatching { JSONObject(plaintext.toString(Charsets.UTF_8)) }.getOrNull()
            ?: return fail(current, "Invalid file completion")
        val transferId = payload.optString("transferId")
        if (folders.handles(transferId)) return folders.fileComplete(current.remoteDeviceId, transferId, payload.optString("sha256"))
        if (!ownsTransfer(current, transferId)) return
        val transfer = incomingFiles.remove(transferId) ?: run {
            if (transferId in cancelledTransferIds) return
            return fail(current, "Unknown file transfer")
        }
        val savedUri = runCatching { transfer.finish(payload.optString("sha256")) }.getOrNull()
        if (savedUri == null) {
            transfer.cancel()
            mutableFileTransferStatus.value = "File verification failed"
            return fail(current, "File verification failed")
        }
        updateFileTransfer(transferId, transfer.displayName, "${transfer.displayName} saved to Download/Bridgey", false, TransferEnd.RECEIVED)
        ReceivedFileNotifier.show(appContext, transfer.displayName, transfer.mimeType, savedUri)
        current.send(Message(kind = "files.complete.ack", sessionId = current.id, transferId = transferId))
        BridgeyLogging.i(LogCategory.FILES, LogLines.file(BridgeyLogging.policy, "received", transferId, transfer.displayName))
    }

    private fun receiveFileCancel(current: Session, transferId: String?) {
        if (transferId == null || !ownsTransfer(current, transferId)) return
        markTransferCancelled(transferId)
        incomingFiles.remove(transferId)?.cancel()
        outgoingFileJobs.remove(transferId)?.cancel()
        pendingFileAccepts.remove(transferId)?.complete(false)
        pendingFileCompletions.remove(transferId)?.complete(false)
        removeFileTransfer(transferId, "Transfer cancelled by ${current.peerName}")
        current.send(Message(kind = "files.cancel.ack", sessionId = current.id, transferId = transferId))
        BridgeyLogging.i(LogCategory.FILES, LogLines.file(BridgeyLogging.policy, "cancellation received", transferId))
    }

    /** Ends the current and waiting outgoing files of [deviceId] (null: all) after the session is lost. They remain retryable. */
    private fun interruptFileQueue(deviceId: String? = null) {
        val queues = if (deviceId == null) fileSendQueues.values.toList() else listOfNotNull(fileSendQueues[deviceId])
        queues.flatMap { it.removeAll() }.forEach { removeFileTransfer(it, "Transfer interrupted — reconnect to retry", TransferEnd.INTERRUPTED) }
    }

    private fun markTransferCancelled(transferId: String) {
        cancelledTransferIds += transferId
        while (cancelledTransferIds.size > 64) cancelledTransferIds.firstOrNull()?.let(cancelledTransferIds::remove)
    }

    private fun updateFileTransfer(id: String, name: String, status: String, active: Boolean, outcome: TransferEnd? = if (active) null else TransferEnd.FAILED) {
        val deviceId = transferDevices[id]
        val deviceName = deviceId?.let { device ->
            registry.connections().firstOrNull { it.deviceId == device }?.peerName
                ?: trust.trustedDevices.value.firstOrNull { it.id == device }?.name
        }
        mutableFileTransfers.value = mutableFileTransfers.value.toMutableMap().apply {
            val percent = Regex("(\\d{1,3})%").find(status)?.groupValues?.get(1)?.toIntOrNull()?.coerceIn(0, 100)
            val previous = get(id)
            put(id, FileTransferState(
                id = id,
                name = name,
                status = status,
                active = active,
                progressPercent = percent,
                startedAtMillis = previous?.startedAtMillis ?: System.currentTimeMillis(),
                retryable = !active && outgoingFileSources.containsKey(id),
                deviceId = deviceId ?: previous?.deviceId,
                deviceName = deviceName ?: previous?.deviceName.orEmpty(),
                outcome = outcome,
            ))
        }
        pruneTransferHistory()
        refreshFileTransferSummary(status)
    }

    private fun removeFileTransfer(id: String, status: String, outcome: TransferEnd = TransferEnd.CANCELLED) {
        // A camera photo that never started (queue stopped, disconnected): its request learns now.
        if (outgoingFileJobs[id] == null) cameraTransferEnded(id)
        mutableFileTransfers.value[id]?.let { previous ->
            mutableFileTransfers.value = mutableFileTransfers.value.toMutableMap().apply {
                put(id, previous.copy(
                    status = status,
                    active = false,
                    progressPercent = null,
                    retryable = outgoingFileSources.containsKey(id),
                    queued = false,
                    outcome = outcome,
                ))
            }
        }
        pruneTransferHistory()
        refreshFileTransferSummary(status)
    }

    private fun pruneTransferHistory() {
        val active = mutableFileTransfers.value.values.filter(FileTransferState::active)
        val history = mutableFileTransfers.value.values.filterNot(FileTransferState::active)
            .sortedByDescending(FileTransferState::startedAtMillis)
            .take(MAX_TRANSFER_HISTORY)
        mutableFileTransfers.value = (active + history).associateBy(FileTransferState::id)
    }

    private fun refreshFileTransferSummary(fallback: String? = null) {
        val activeTransfers = mutableFileTransfers.value.values.filter { it.active }
        mutableFileTransferActive.value = activeTransfers.isNotEmpty()
        mutableFileTransferStatus.value = (activeTransfers.firstOrNull { !it.queued } ?: activeTransfers.firstOrNull())?.status ?: fallback
    }

    private fun authenticateOrPrompt(current: Session) {
        if (trust.identityKey(current.remoteDeviceId) != null) {
            confirm(current)
            return
        }
        // A new device: it needs the code prompt, which belongs to one pairing at a time.
        val existing = pairingSession
        if (existing != null && existing !== current && existing.code != null && !existing.closed) {
            BridgeyLogging.w(LogCategory.CONNECTION, "PAIRING rejected: another pairing is waiting for confirmation")
            current.failure = PairingFailure.BUSY
            current.send(Message(kind = "pairing.cancel", sessionId = current.id))
            current.close()
            return
        }
        pairingSession = current
        mutablePairingFlow.value = PairingState.Verification(current.peerName, current.code!!)
        publish()
    }

    private fun confirm(current: Session) {
        if (current.localConfirmed || current.closed) return
        current.localConfirmed = true
        val identityKey = identity.publicKey()
        current.send(
            Message(
                kind = "pairing.confirm",
                sessionId = current.id,
                deviceId = localDeviceId,
                identityKey = identityKey,
                proof = Crypto.confirmationProof(current.pairingKey!!, current.id, localDeviceId, identityKey),
                signature = identity.sign(authTranscript(current)),
            ),
        )
        completeIfConfirmed(current)
    }

    private fun authTranscript(current: Session): ByteArray {
        val fields = if (current.initiatedLocally) {
            listOf(localDeviceId, current.remoteDeviceId, current.localEphemeralKey, current.remoteEphemeralKey)
        } else {
            listOf(current.remoteDeviceId, localDeviceId, current.remoteEphemeralKey, current.localEphemeralKey)
        }
        return (listOf("bridgey-auth-v1", current.id) + fields).joinToString("\u0000").toByteArray()
    }

    @Synchronized private fun completeIfConfirmed(current: Session) {
        if (!current.localConfirmed || !current.remoteConfirmed || current.authenticated) return
        trust.save(current.remoteDeviceId, current.peerName, current.remoteIdentityKey!!)
        when (val admission = registry.authenticate(current, current.remoteDeviceId, current.peerName)) {
            SessionRegistry.Admission.Rejected -> {
                // A live session for this device wins the duplicate rule; this socket closes quietly.
                BridgeyLogging.i(LogCategory.CONNECTION, "TRANSPORT duplicate session closed peerId=${current.remoteDeviceId.take(8)}")
                diagnostics.record("transport", "duplicate_closed", device = current.remoteDeviceId)
                if (pairingSession === current) {
                    pairingSession = null
                    mutablePairingFlow.value = PairingState.Idle
                }
                current.dropReason = "duplicate"
                dialFinished(current)
                current.close()
                publish()
                return
            }
            is SessionRegistry.Admission.Accepted -> admission.replaced?.let {
                BridgeyLogging.i(LogCategory.CONNECTION, "TRANSPORT duplicate session replaced peerId=${current.remoteDeviceId.take(8)}")
                diagnostics.record("transport", "duplicate_replaced", device = current.remoteDeviceId)
                it.dropReason = "replaced"
                it.close()
            }
        }
        current.authenticated = true
        dialFinished(current)
        val source = if (current.initiatedLocally) AddressSource.OUTBOUND else AddressSource.INBOUND
        val port = if (current.initiatedLocally) current.remotePort else ReconnectPolicy.LISTENING_PORT
        val attempts = reconnect.entry(current.remoteDeviceId)?.attempts ?: 0
        reconnect.connected(current.remoteDeviceId, current.remoteHost, port, source)
        health.connected(current.remoteDeviceId, current.remoteHost, current.initiatedLocally, System.currentTimeMillis())
        BridgeyLogging.i(LogCategory.CONNECTION, "RECONNECT connected peer=${current.remoteDeviceId.take(8)} via=${source.key} address=${current.remoteHost?.let(::addressTag) ?: "unknown"} attempts=$attempts")
        diagnostics.record("transport", "connected", source.key, device = current.remoteDeviceId, detail = "after_${attempts}_attempts")
        if (pairingSession === current) {
            pairingSession = null
            mutablePairingFlow.value = PairingState.Idle
        }
        // A device that just connected becomes the selection only when nothing was picked.
        publish()
        diagnostics.record("pairing", "connected")
        sendFeatureState(current)
        BridgeyNotificationListenerService.resendActiveCalls()
        BridgeyLogging.i(LogCategory.CONNECTION, "PAIRING verified peerId=${current.remoteDeviceId.take(8)}")
        finishRediscoverIfEveryoneAnswered()
    }

    private fun sendFeatureState(current: Session) {
        if (!registry.isActive(current) || current.pairingKey == null) return
        val featureValues = JSONObject()
        BridgeyFeature.entries.forEach { feature ->
            featureValues.put(feature.key, settings.isEnabled(feature, current.remoteDeviceId))
        }
        // Draft, edition only: images, files and long text through clipboard offers.
        featureValues.put(
            CLIPBOARD_FILES_FEATURE_KEY,
            settings.isEnabled(BridgeyFeature.CLIPBOARD, current.remoteDeviceId) && settings.state.value.clipboardFilesEnabled,
        )
        // Draft, edition only: this phone receives folders and serves its places. Both mirror Files;
        // receiving needs Android 10 (scoped storage), like receiving files.
        val receivesFolders = settings.isEnabled(BridgeyFeature.FILES, current.remoteDeviceId) &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
        featureValues.put(dev.bridgey.android.folders.FOLDERS_FEATURE_KEY, receivesFolders)
        featureValues.put(dev.bridgey.android.folders.PLACES_FEATURE_KEY, receivesFolders)
        // Files 2.0 (draft): this phone accepts folders (the same rule), and serves browsing while its
        // "Let other devices browse this phone" switch is on.
        featureValues.put(dev.bridgey.android.folders.FOLDERS_RECEIVE_FEATURE_KEY, receivesFolders)
        featureValues.put(dev.bridgey.android.folders.FILES_BROWSE_FEATURE_KEY, browseAllowedFor(current.remoteDeviceId))
        // Draft, edition only: SMS notifications are marked for the Mac's code reader, and this phone
        // reports code access and makes the companion link.
        featureValues.put(dev.bridgey.android.codes.SMS_CODES_FEATURE_KEY, settings.isEnabled(BridgeyFeature.NOTIFICATIONS, current.remoteDeviceId))
        // Draft, edition only: Focus and Do Not Disturb sync, while either direction is on.
        featureValues.put(dev.bridgey.android.focus.FOCUS_SYNC_FEATURE_KEY, focusSync.advertised())
        val payload = JSONObject()
            .put("version", 1)
            .put("features", featureValues)
            .toString()
            .toByteArray()
        sendEncrypted(current, "features.update", payload)
    }

    private fun receiveFeatureState(current: Session, message: Message) {
        if (!registry.isActive(current) || message.sessionId != current.id) return
        val messageId = message.messageId ?: return
        if (!current.acceptMessageId(messageId)) return
        val plaintext = Crypto.decrypt(
            current.pairingKey!!,
            message.nonce ?: return,
            message.ciphertext ?: return,
        ) ?: return fail(current, "Invalid encrypted feature state")
        // Unknown keys are ignored; an unknown version keeps the previous state (docs/protocol-contract.md).
        val decoded = when (val state = decodeFeatureState(plaintext)) {
            FeatureStateDecoding.Invalid -> return fail(current, "Invalid feature state")
            FeatureStateDecoding.Ignored -> return
            is FeatureStateDecoding.State -> state
        }
        val received = decoded.features
        val drafts = decoded.drafts
        val deviceId = current.remoteDeviceId
        registry.update(deviceId) { state ->
            state.copy(
                remoteFeatures = received,
                remoteClipboardFiles = drafts[CLIPBOARD_FILES_FEATURE_KEY] == true,
                remoteFolders = drafts[dev.bridgey.android.folders.FOLDERS_FEATURE_KEY] == true,
                remotePlaces = drafts[dev.bridgey.android.folders.PLACES_FEATURE_KEY] == true,
                remoteFoldersReceive = drafts[dev.bridgey.android.folders.FOLDERS_RECEIVE_FEATURE_KEY] == true,
                remoteSmsCodes = drafts[dev.bridgey.android.codes.SMS_CODES_FEATURE_KEY] == true,
                remoteLinksOpen = drafts[dev.bridgey.android.actions.LINKS_OPEN_FEATURE_KEY] == true,
                remoteFocusSync = drafts[dev.bridgey.android.focus.FOCUS_SYNC_FEATURE_KEY] == true,
                battery = state.battery.takeIf { received[BridgeyFeature.BATTERY] != false },
                ringing = state.ringing && received[BridgeyFeature.FIND_DEVICE] != false,
            )
        }
        if (!clipboardOffersAvailable(deviceId)) clipboardOutbox.disconnected(deviceId)
        if (received[BridgeyFeature.FILES] == false) stopFileQueue(deviceId, "File transfer is turned off on ${current.peerName}")
        if (received[BridgeyFeature.FIND_DEVICE] == false && phoneRingingFrom == deviceId) stopPhoneRinging()
        val isTarget = registry.target(selectedDeviceId) == deviceId
        if (isTarget && received[BridgeyFeature.CLIPBOARD] == false) mutableClipboardStatus.value = null
        if (received[BridgeyFeature.PING] == false && pendingPing?.first == deviceId) clearPingStatus()
        publish()
        quickActions.policyChanged()
        // The Mac (or this phone) no longer allows Mac actions: its list goes.
        if (!isFeatureAvailable(BridgeyFeature.MAC_ACTIONS, deviceId)) macActions.revoked(deviceId)
        if (drafts[dev.bridgey.android.codes.SMS_CODES_FEATURE_KEY] == true) sendCodeStatus(current)
        // Folders waiting for this device (queued, or interrupted within 24 hours) start or resume now.
        if (sendsFoldersTo(deviceId)) folderSender.deviceReady(deviceId)
        // Focus sync: a Mac that understands it hears this phone's Do Not Disturb once per map.
        if (drafts[dev.bridgey.android.focus.FOCUS_SYNC_FEATURE_KEY] == true && focusSync.advertised()) focusSync.peerReady(deviceId)
        if (!isFeatureAvailable(BridgeyFeature.CAMERA, deviceId)) endCameraRequest(deviceId)
    }

    // MARK: Codes from messages (draft sms_codes_draft1)

    /** Set by the application: the current code access status, sent to each Mac that reads codes. */
    @Volatile var codeAccessStatus: () -> dev.bridgey.android.codes.CodeAccessStatus? = { null }

    /** Set by the application: a Mac asked this phone to start the companion link (its Settings button). */
    @Volatile var codeLinkRequested: (deviceId: String, peerName: String) -> Unit = { _, _ -> }

    private val pendingAdvertising = java.util.concurrent.ConcurrentHashMap<String, (Boolean, String?) -> Unit>()
    private val mainHandler by lazy { android.os.Handler(android.os.Looper.getMainLooper()) }

    /** codes.status to every connected Mac that reads codes. */
    fun sendCodeStatus() {
        registry.broadcastTargets { _, state -> state.remoteSmsCodes }.forEach { (_, current) -> sendCodeStatus(current) }
    }

    private fun sendCodeStatus(current: Session) {
        val status = codeAccessStatus() ?: return
        val payload = JSONObject().put("version", 1).put("status", status.wire).toString().toByteArray()
        scope.launch { sendEncrypted(current, "codes.status", payload) }
    }

    /** The Mac "Link this phone to the Mac" talks to: the selected one if it reads codes, else any that does. */
    fun companionLinkTarget(): String? {
        val connections = registry.connections()
        val selected = registry.target(selectedDeviceId)
        return connections.firstOrNull { it.deviceId == selected && it.state.remoteSmsCodes }?.deviceId
            ?: connections.firstOrNull { it.state.remoteSmsCodes }?.deviceId
    }

    /** Connected, but no Mac speaks sms_codes_draft1 (an older Bridgey). */
    fun companionLinkMacTooOld(): Boolean {
        val connections = registry.connections()
        return connections.isNotEmpty() && connections.none { it.state.remoteSmsCodes }
    }

    /** codes.advertise: the Mac advertises [serviceUuid] over Bluetooth LE for a minute. */
    fun requestCompanionAdvertising(deviceId: String, serviceUuid: java.util.UUID, onResult: (Boolean, String?) -> Unit) {
        val current = registry.session(deviceId)
        if (current == null) {
            mainHandler.post { onResult(false, null) }
            return
        }
        val key = serviceUuid.toString()
        pendingAdvertising[key] = onResult
        val payload = JSONObject().put("version", 1).put("serviceUuid", key).toString().toByteArray()
        scope.launch {
            if (!sendEncrypted(current, "codes.advertise", payload)) {
                pendingAdvertising.remove(key)?.let { callback -> mainHandler.post { callback(false, null) } }
            }
        }
        // The Mac may first ask for Bluetooth permission; give the person time to answer it.
        mainHandler.postDelayed({ pendingAdvertising.remove(key)?.invoke(false, null) }, COMPANION_ADVERTISE_TIMEOUT_MS)
    }

    fun stopCompanionAdvertising(deviceId: String, serviceUuid: java.util.UUID, linked: Boolean) {
        pendingAdvertising.remove(serviceUuid.toString())
        val current = registry.session(deviceId) ?: return
        val payload = JSONObject().put("version", 1).put("serviceUuid", serviceUuid.toString()).put("linked", linked).toString().toByteArray()
        scope.launch { sendEncrypted(current, "codes.advertise_stop", payload) }
    }

    private fun receiveCodesMessage(current: Session, message: Message) {
        if (!registry.isActive(current) || message.sessionId != current.id) return
        val key = current.pairingKey ?: return
        val id = message.messageId ?: return
        if (!current.acceptMessageId(id)) return
        val data = Crypto.decrypt(key, message.nonce ?: return, message.ciphertext ?: return) ?: return
        if (data.size > 1024) return
        val payload = runCatching { JSONObject(data.toString(Charsets.UTF_8)) }.getOrNull() ?: return
        if (payload.optInt("version") != 1) return
        when (message.kind) {
            "codes.advertise_result" -> {
                val uuid = payload.optString("serviceUuid")
                val ok = payload.opt("ok") == true
                val reason = payload.optString("reason").takeIf { it.isNotEmpty() }
                pendingAdvertising.remove(uuid)?.let { callback -> mainHandler.post { callback(ok, reason ?: if (ok) null else "failed") } }
            }
            "codes.link_request" -> {
                if (!settings.isEnabled(BridgeyFeature.NOTIFICATIONS, current.remoteDeviceId)) return
                val deviceId = current.remoteDeviceId
                val name = current.peerName
                mainHandler.post { codeLinkRequested(deviceId, name) }
            }
        }
    }

    private fun receiveBattery(current: Session, message: Message) {
        if (!featureEnabled(BridgeyFeature.BATTERY, current)) return
        if (!registry.isActive(current) || message.sessionId != current.id) return
        val messageId = message.messageId ?: return
        if (!current.acceptMessageId(messageId)) return
        val plaintext = Crypto.decrypt(
            current.pairingKey!!,
            message.nonce ?: return fail(current, "Invalid encrypted battery status"),
            message.ciphertext ?: return fail(current, "Invalid encrypted battery status"),
        ) ?: return fail(current, "Invalid encrypted battery status")
        val battery = decodeBatteryStatus(plaintext) ?: return fail(current, "Invalid battery status")
        registry.update(current.remoteDeviceId) { it.copy(battery = battery) }
        publish()
        BridgeyLogging.i(LogCategory.GENERAL, "PLUGIN battery received level=${battery.level}")
    }

    /** A protocol error on one session: that session closes (and reconnects); nothing else changes. */
    private fun fail(current: Session, message: String) {
        BridgeyLogging.w(LogCategory.CONNECTION, "PROTOCOL session closed: $message")
        diagnostics.record("protocol", "session_failed", "rejected")
        if (current.failure == null) current.failure = PairingFailure.INVALID
        if (current.dropReason == null) current.dropReason = "protocol_error"
        current.close()
    }

    /** The handshake on [current] failed with [reason]; the pairing flow shows it if it was the user's pairing. */
    private fun failHandshake(current: Session, reason: PairingFailure, message: String) {
        BridgeyLogging.w(LogCategory.CONNECTION, "PAIRING failed: $message")
        diagnostics.record("protocol", "session_failed", "rejected")
        current.failure = reason
        if (current.dropReason == null) current.dropReason = "handshake_failed"
        current.close()
    }

    /** Shows [reason] for the user's pairing; never touches connected devices. */
    private fun failPairing(current: Session?, reason: PairingFailure, detail: String? = null) {
        if (current != null && pairingSession !== current) return
        pairingSession = null
        mutablePairingFlow.value = PairingState.Failed(detail?.let { "$it. ${reason.message}" } ?: reason.message, reason)
        diagnostics.record("pairing", "failed", reason.name.lowercase())
        publish()
    }

    /** Cancels the file transfers of [deviceId] (null: all). */
    private fun cancelTransfers(deviceId: String?) {
        // Folders: the session deletes the file in progress and keeps its journal, so the folder resumes.
        folders.deviceGone(deviceId)
        folderSender.deviceGone(deviceId)
        if (deviceId == null) {
            browseServers.values.forEach { it.close() }
            browseServers.clear()
        } else {
            browseServers.remove(deviceId)?.close()
        }
        val ids = if (deviceId == null) null else transferDevices.filterValues { it == deviceId }.keys
        fun mine(transferId: String) = (ids == null || transferId in ids) && mutableFileTransfers.value[transferId]?.kind != TransferKind.FOLDER
        val hadActiveTransfers = mutableFileTransfers.value.values.any { it.active && mine(it.id) }
        interruptFileQueue(deviceId)
        incomingFiles.entries.filter { mine(it.key) }.forEach { (id, transfer) ->
            transfer.cancel()
            incomingFiles.remove(id)
        }
        outgoingFileJobs.entries.filter { mine(it.key) }.forEach { (id, job) ->
            job.cancel()
            outgoingFileJobs.remove(id)
        }
        pendingFileAccepts.entries.filter { mine(it.key) }.forEach { (id, deferred) ->
            deferred.complete(false)
            pendingFileAccepts.remove(id)
        }
        pendingFileCompletions.entries.filter { mine(it.key) }.forEach { (id, deferred) ->
            deferred.complete(false)
            pendingFileCompletions.remove(id)
        }
        val (affected, others) = mutableFileTransfers.value.entries.partition { mine(it.key) }
        mutableFileTransfers.value = recoverInterruptedTransfers(affected.associate { it.key to it.value }) +
            others.associate { it.key to it.value }
        pruneTransferHistory()
        refreshFileTransferSummary(if (hadActiveTransfers) "File transfer interrupted" else null)
        if (hadActiveTransfers) diagnostics.record("transfer", "interrupted", "retry_available")
    }

    private companion object {
        fun defaultFeatureState(): Map<BridgeyFeature, Boolean> = BridgeyFeature.entries.associateWith(::featureEnabledByLegacyPeer)
        const val FILE_CHUNK_SIZE = 24 * 1024
        const val MAX_FILE_SIZE = 10L * 1024 * 1024 * 1024
        const val MAX_NOTIFICATION_ICON_BASE64_LENGTH = 28 * 1024
        const val CONNECT_TIMEOUT_MILLIS = ReconnectPolicy.CONNECT_TIMEOUT_MILLIS
        const val HANDSHAKE_TIMEOUT_MILLIS = 20_000L
        const val COMPANION_ADVERTISE_TIMEOUT_MS = 45_000L
        const val VERIFICATION_TIMEOUT_MILLIS = 120_000L
        const val CLIPBOARD_CACHE_DIRECTORY = "clipboard-cache"
        const val FOLDER_JOURNAL_DIRECTORY = "folder-transfers"
        const val FOLDER_SEND_JOURNAL_DIRECTORY = "folder-sends"

        /** Answers from a device to a folder this phone sends. */
        val SENDER_ANSWER_KINDS = setOf(
            dev.bridgey.android.folders.FolderKinds.WAITING, dev.bridgey.android.folders.FolderKinds.CONFLICT,
            dev.bridgey.android.folders.FolderKinds.ACCEPT, dev.bridgey.android.folders.FolderKinds.REJECTED,
            dev.bridgey.android.folders.FolderKinds.ENTRY_FAILED, dev.bridgey.android.folders.FolderKinds.RESULT,
        )
        const val REMOTE_INPUT_MAX_BYTES = 2_048
        const val LOW_PRIORITY_MAX_WAIT_MILLIS = 2_000
        const val LOW_PRIORITY_CHUNK_GAP_MILLIS = 2L
    }

    private class Session(private val socket: Socket) {
        val input = BufferedInputStream(socket.getInputStream())
        private val writer = BufferedWriter(OutputStreamWriter(socket.getOutputStream(), Charsets.UTF_8))
        var id = ""
        var peerName = "Device"
        var remoteDeviceId = ""
        var remoteIdentityKey: String? = null
        var initiatedLocally = false
        var localEphemeralKey = ""
        var remoteEphemeralKey = ""
        var keyPair: KeyPair? = null
        var code: String? = null
        var pairingKey: ByteArray? = null
        @Volatile var localConfirmed = false
        @Volatile var remoteConfirmed = false

        /** Authenticated and registered as its device's session. */
        @Volatile var authenticated = false
        @Volatile var closed = false

        /** Why the session ended, for the pairing flow. */
        @Volatile var failure: PairingFailure? = null

        /** Why the socket ended, for logs and diagnostics ("reset_by_peer", "heartbeat_timeout"). */
        @Volatile var dropReason: String? = null

        /** A reconnect to this trusted device; null for pairings and incoming sessions. */
        @Volatile var dialDeviceId: String? = null
        val dialFinished = java.util.concurrent.atomic.AtomicBoolean(false)

        /** The other end's address (normalized) and port. */
        @Volatile var remoteHost: String? = null
        @Volatile var remotePort: Int = ReconnectPolicy.LISTENING_PORT
        val createdAtMillis = SystemClock.elapsedRealtime()

        /** The device's last media.state, replayed when it becomes the selected device. */
        @Volatile var media: JSONObject? = null
        @Volatile var lastReceivedAtMillis = SystemClock.elapsedRealtime()
        @Volatile var heartbeatSupported = false
        private val seenMessageIds = ReplayWindow()

        private val writeLock = Any()

        /** Senders waiting for, or holding, the socket (everything but the media lane). */
        private val urgentSenders = java.util.concurrent.atomic.AtomicInteger(0)
        @Volatile private var lastChunkAtMillis = 0L

        fun send(message: Message): Boolean {
            urgentSenders.incrementAndGet()
            try {
                if (message.kind == "files.chunk") lastChunkAtMillis = SystemClock.elapsedRealtime()
                return write(message)
            } finally {
                urgentSenders.decrementAndGet()
            }
        }

        /**
         * Media-lane answers (thumbnails, previews, ranges): written only while no other message waits for the
         * socket and no file chunk went out in the last 2 ms, so they never get ahead of chunks, acknowledgements
         * or control messages. They wait at most 2 seconds per message, so a long transfer cannot starve them.
         */
        fun sendLowPriority(message: Message): Boolean {
            var waited = 0
            while (waited < LOW_PRIORITY_MAX_WAIT_MILLIS &&
                (urgentSenders.get() > 0 || SystemClock.elapsedRealtime() - lastChunkAtMillis < LOW_PRIORITY_CHUNK_GAP_MILLIS)
            ) {
                Thread.sleep(1)
                waited++
            }
            return write(message)
        }

        private fun write(message: Message): Boolean = synchronized(writeLock) {
            val result = runCatching {
                writer.write(message.encode())
                writer.newLine()
                writer.flush()
            }
            result.exceptionOrNull()?.let {
                BridgeyLogging.w(LogCategory.CONNECTION, "TRANSPORT send failed kind=${message.kind}", it)
            }
            result.isSuccess
        }

        fun close() {
            closed = true
            runCatching { socket.close() }
        }

        val quickSequence = QuickRequestSequence()

        fun acceptMessageId(id: String): Boolean = seenMessageIds.accept(id)
    }
}

private class TransferProgress(private val totalBytes: Long) {
    private var lastUpdateAt = SystemClock.elapsedRealtime()
    private var lastBytes = 0L
    private var smoothedBytesPerSecond = 0.0

    fun status(transferred: Long, force: Boolean = false): String? {
        val now = SystemClock.elapsedRealtime()
        val elapsedMs = now - lastUpdateAt
        if (!force && elapsedMs < 250 && transferred < totalBytes) return null
        if (elapsedMs > 0) {
            val sample = (transferred - lastBytes).coerceAtLeast(0) * 1000.0 / elapsedMs
            smoothedBytesPerSecond = if (smoothedBytesPerSecond == 0.0) sample else smoothedBytesPerSecond * 0.7 + sample * 0.3
        }
        lastUpdateAt = now
        lastBytes = transferred
        val percent = if (totalBytes == 0L) 100 else ((transferred * 100) / totalBytes).coerceIn(0, 100)
        val remaining = (totalBytes - transferred).coerceAtLeast(0)
        val eta = if (smoothedBytesPerSecond >= 1 && remaining > 0) formatDuration((remaining / smoothedBytesPerSecond).toLong()) else "calculating…"
        return "$percent% · ${formatBytes(transferred)} / ${formatBytes(totalBytes)} · ${formatBytes(smoothedBytesPerSecond.toLong())}/s · $eta left"
    }

    private fun formatBytes(bytes: Long): String {
        if (bytes < 1024) return "$bytes B"
        val units = arrayOf("KB", "MB", "GB", "TB")
        var value = bytes.toDouble()
        var unit = -1
        while (value >= 1024 && unit < units.lastIndex) {
            value /= 1024
            unit++
        }
        return if (value >= 10) "%.0f %s".format(java.util.Locale.US, value, units[unit])
        else "%.1f %s".format(java.util.Locale.US, value, units[unit])
    }

    private fun formatDuration(seconds: Long): String = when {
        seconds < 1 -> "<1 sec"
        seconds < 60 -> "$seconds sec"
        seconds < 3600 -> "${seconds / 60} min ${seconds % 60} sec"
        else -> "${seconds / 3600} h ${(seconds % 3600) / 60} min"
    }
}

@android.annotation.TargetApi(Build.VERSION_CODES.Q)
private class IncomingFileTransfer(
    private val context: Context,
    val transferId: String,
    offeredName: String,
    val mimeType: String,
    val expectedSize: Long,
    private val expectedHash: String,
) {
    val displayName = sanitize(offeredName)
    val progress = TransferProgress(expectedSize)
    private val resolver = context.contentResolver
    private val uri: Uri
    private val output: OutputStream
    private val digest = MessageDigest.getInstance("SHA-256")
    var receivedSize = 0L
        private set
    private var nextSequence = 0L

    init {
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, displayName)
            put(MediaStore.Downloads.MIME_TYPE, mimeType.take(255))
            put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/Bridgey")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: error("Could not allocate download")
        output = resolver.openOutputStream(uri, "w") ?: run {
            resolver.delete(uri, null, null)
            error("Could not open download")
        }
    }

    @Synchronized fun append(bytes: ByteArray, sequence: Long) {
        check(sequence == nextSequence)
        check(bytes.size <= 24 * 1024)
        check(receivedSize + bytes.size <= expectedSize)
        output.write(bytes)
        digest.update(bytes)
        receivedSize += bytes.size
        nextSequence++
    }

    @Synchronized fun finish(completionHash: String): Uri? {
        output.flush()
        output.close()
        val actual = Base64.encodeToString(digest.digest(), Base64.NO_WRAP)
        if (receivedSize != expectedSize || completionHash != expectedHash || actual != expectedHash) {
            resolver.delete(uri, null, null)
            return null
        }
        resolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
        return uri
    }

    @Synchronized fun cancel() {
        runCatching { output.close() }
        resolver.delete(uri, null, null)
    }

    private fun sanitize(name: String): String {
        val leaf = name.substringAfterLast('/').substringAfterLast('\\')
            .replace(Regex("[\\u0000-\\u001f:]"), "_")
            .take(255)
        return leaf.ifBlank { "file" }
    }
}

internal data class Message(
    val kind: String,
    val sessionId: String,
    val deviceId: String? = null,
    val deviceName: String? = null,
    val publicKey: String? = null,
    val identityKey: String? = null,
    val proof: String? = null,
    val signature: String? = null,
    val messageId: String? = null,
    val nonce: String? = null,
    val ciphertext: String? = null,
    val transferId: String? = null,
    val sequence: Long? = null,
    /** On a reconnect offer: the trusted device it is meant for. Any other device declines quietly. */
    val targetDeviceId: String? = null,
) {
    fun encode(): String = JSONObject().apply {
        put("kind", kind)
        put("sessionId", sessionId)
        deviceId?.let { put("deviceId", it) }
        deviceName?.let { put("deviceName", it) }
        publicKey?.let { put("publicKey", it) }
        identityKey?.let { put("identityKey", it) }
        proof?.let { put("proof", it) }
        signature?.let { put("signature", it) }
        messageId?.let { put("messageId", it) }
        nonce?.let { put("nonce", it) }
        ciphertext?.let { put("ciphertext", it) }
        transferId?.let { put("transferId", it) }
        sequence?.let { put("sequence", it) }
        targetDeviceId?.let { put("targetDeviceId", it) }
    }.toString()

    companion object {
        /** Strict: see [decodeProtocolMessage] and docs/protocol-contract.md. */
        fun decode(value: String): Message = decodeProtocolMessage(value)
    }
}

internal object Crypto {
    data class PairingMaterial(val code: String, val key: ByteArray)
    data class EncryptedPayload(val nonce: String, val ciphertext: String)

    fun generateKeyPair(): KeyPair = KeyPairGenerator.getInstance("EC").apply {
        initialize(ECGenParameterSpec("secp256r1"))
    }.generateKeyPair()

    fun encodePublicKey(pair: KeyPair): String {
        val public = pair.public as java.security.interfaces.ECPublicKey
        val raw = byteArrayOf(4) + fixed(public.w.affineX) + fixed(public.w.affineY)
        return java.util.Base64.getEncoder().encodeToString(raw)
    }

    fun pairingMaterial(pair: KeyPair, remoteBase64: String, sessionId: String): PairingMaterial {
        val agreement = KeyAgreement.getInstance("ECDH")
        agreement.init(pair.private)
        agreement.doPhase(decodePublicKey(java.util.Base64.getDecoder().decode(remoteBase64)), true)
        val sharedSecret = agreement.generateSecret()
        val salt = MessageDigest.getInstance("SHA-256").digest(sessionId.toByteArray())
        val extract = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(salt, "HmacSHA256")) }
        val prk = extract.doFinal(sharedSecret)
        val expand = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(prk, "HmacSHA256")) }
        val output = expand.doFinal("bridgey-pairing-v1".toByteArray() + byteArrayOf(1))
        val number = ((output[0].toLong() and 0xff) shl 24) or
            ((output[1].toLong() and 0xff) shl 16) or
            ((output[2].toLong() and 0xff) shl 8) or (output[3].toLong() and 0xff)
        return PairingMaterial((number % 1_000_000).toString().padStart(6, '0'), output)
    }

    fun confirmationProof(key: ByteArray, sessionId: String, deviceId: String, identityKey: String): String {
        val data = "bridgey-confirm-v1\u0000$sessionId\u0000$deviceId\u0000$identityKey".toByteArray()
        val proof = Mac.getInstance("HmacSHA256").apply {
            init(SecretKeySpec(key, "HmacSHA256"))
        }.doFinal(data)
        return java.util.Base64.getEncoder().encodeToString(proof)
    }

    fun verifyConfirmationProof(
        key: ByteArray,
        sessionId: String,
        deviceId: String,
        identityKey: String,
        proof: String,
    ): Boolean = runCatching {
        MessageDigest.isEqual(
            java.util.Base64.getDecoder().decode(proof),
            java.util.Base64.getDecoder().decode(confirmationProof(key, sessionId, deviceId, identityKey)),
        )
    }.getOrDefault(false)

    fun encrypt(key: ByteArray, plaintext: ByteArray): EncryptedPayload {
        val nonce = ByteArray(12).also(SecureRandom()::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        }
        return EncryptedPayload(
            java.util.Base64.getEncoder().encodeToString(nonce),
            java.util.Base64.getEncoder().encodeToString(cipher.doFinal(plaintext)),
        )
    }

    fun decrypt(key: ByteArray, nonce: String, ciphertext: String): ByteArray? = runCatching {
        Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(
                Cipher.DECRYPT_MODE,
                SecretKeySpec(key, "AES"),
                GCMParameterSpec(128, java.util.Base64.getDecoder().decode(nonce)),
            )
        }.doFinal(java.util.Base64.getDecoder().decode(ciphertext))
    }.getOrNull()

    fun verifySignature(identityKey: String, data: ByteArray, signature: String): Boolean = runCatching {
        Signature.getInstance("SHA256withECDSA").apply {
            initVerify(decodePublicKey(java.util.Base64.getDecoder().decode(identityKey)))
            update(data)
        }.verify(java.util.Base64.getDecoder().decode(signature))
    }.getOrDefault(false)

    private fun decodePublicKey(raw: ByteArray): java.security.PublicKey {
        require(raw.size == 65 && raw[0] == 4.toByte())
        val parameters = AlgorithmParameters.getInstance("EC").apply {
            init(ECGenParameterSpec("secp256r1"))
        }.getParameterSpec(ECParameterSpec::class.java)
        val point = ECPoint(BigInteger(1, raw.copyOfRange(1, 33)), BigInteger(1, raw.copyOfRange(33, 65)))
        return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(point, parameters))
    }

    private fun fixed(value: BigInteger): ByteArray {
        val raw = value.toByteArray()
        return when {
            raw.size == 32 -> raw
            raw.size > 32 -> raw.copyOfRange(raw.size - 32, raw.size)
            else -> ByteArray(32 - raw.size) + raw
        }
    }
}

private class AndroidIdentity(context: Context) {
    private val alias = "bridgey.identity.p256.v1"
    private val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    init {
        if (!store.containsAlias(alias)) {
            KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore").apply {
                initialize(
                    KeyGenParameterSpec.Builder(
                        alias,
                        KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY,
                    )
                        .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                        .setDigests(KeyProperties.DIGEST_SHA256)
                        .build(),
                )
            }.generateKeyPair()
        }
    }

    fun publicKey(): String {
        val public = store.getCertificate(alias).publicKey as java.security.interfaces.ECPublicKey
        val raw = byteArrayOf(4) + fixed(public.w.affineX) + fixed(public.w.affineY)
        return Base64.encodeToString(raw, Base64.NO_WRAP)
    }

    fun sign(data: ByteArray): String {
        val privateKey = store.getKey(alias, null) as java.security.PrivateKey
        val signature = Signature.getInstance("SHA256withECDSA").apply {
            initSign(privateKey)
            update(data)
        }.sign()
        return Base64.encodeToString(signature, Base64.NO_WRAP)
    }

    private fun fixed(value: BigInteger): ByteArray {
        val raw = value.toByteArray()
        return when {
            raw.size == 32 -> raw
            raw.size > 32 -> raw.copyOfRange(raw.size - 32, raw.size)
            else -> ByteArray(32 - raw.size) + raw
        }
    }
}

private class AndroidTrustRegistry(context: Context) {
    private val preferences = context.getSharedPreferences("bridgey.trust", Context.MODE_PRIVATE)
    private val mutableIds = MutableStateFlow(loadIds())
    val trustedDeviceIds: StateFlow<Set<String>> = mutableIds.asStateFlow()
    private val mutableDevices = MutableStateFlow(loadDevices())
    val trustedDevices: StateFlow<List<TrustedDevice>> = mutableDevices.asStateFlow()

    fun save(deviceId: String, name: String, identityKey: String) {
        preferences.edit()
            .putString("peer.$deviceId.name", name)
            .putString("peer.$deviceId.identityKey", identityKey)
            .apply()
        mutableIds.value = loadIds()
        mutableDevices.value = loadDevices()
    }

    fun remove(deviceId: String) {
        preferences.edit()
            .remove("peer.$deviceId.name")
            .remove("peer.$deviceId.identityKey")
            .apply()
        mutableIds.value = loadIds()
        mutableDevices.value = loadDevices()
    }

    fun identityKey(deviceId: String): String? = preferences.getString("peer.$deviceId.identityKey", null)

    private fun loadIds(): Set<String> = preferences.all.keys
        .asSequence()
        .filter { it.startsWith("peer.") && it.endsWith(".identityKey") }
        .map { it.removePrefix("peer.").removeSuffix(".identityKey") }
        .toSet()

    private fun loadDevices(): List<TrustedDevice> = loadIds().map { id ->
        TrustedDevice(id, preferences.getString("peer.$id.name", null) ?: "Unknown device")
    }.sortedBy { it.name.lowercase() }
}

/** The encrypted files.offer payload; a camera photo adds `cameraRequestId` (draft camera_draft1). */
internal fun fileOfferPayload(transferId: String, name: String, mimeType: String, size: Long, sha256: String, cameraRequestId: String? = null): JSONObject =
    JSONObject()
        .put("transferId", transferId)
        .put("name", name)
        .put("mimeType", mimeType)
        .put("size", size)
        .put("sha256", sha256)
        .apply { cameraRequestId?.let { put("cameraRequestId", it) } }
