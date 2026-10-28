package dev.bridgey.android

/**
 * Which device each file transfer belongs to, so a disconnect interrupts only that
 * device's transfers and a retry goes back to the same device. Bounded: the oldest
 * entries are dropped first, well after their history rows are gone.
 */
internal class TransferOwners(private val limit: Int = 256) {
    private val owners = LinkedHashMap<String, String>()

    @Synchronized fun assign(transferId: String, deviceId: String) {
        owners.remove(transferId)
        owners[transferId] = deviceId
        while (owners.size > limit) owners.remove(owners.keys.first())
    }

    @Synchronized fun owner(transferId: String): String? = owners[transferId]

    @Synchronized fun owns(transferId: String, deviceId: String): Boolean = owners[transferId] == deviceId

    @Synchronized fun transfersOf(deviceId: String): Set<String> =
        owners.filterValues { it == deviceId }.keys.toSet()
}

/**
 * The devices that hear `find.stop` when Find device is stopped here: the selected
 * device, every device that is ringing and every device that made this phone ring.
 */
internal fun findStopTargets(
    connections: List<ConnectedDevice>,
    requesters: Set<String>,
    target: String?,
): List<String> = connections
    .filter { it.id == target || it.link.ringing || it.id in requesters }
    .map(ConnectedDevice::id)

/**
 * Trusted nearby devices this phone dials itself: the side with the lower device ID
 * dials, and a device that is already connected is left alone.
 */
internal fun <P> autoDialTargets(
    peers: List<P>,
    idOf: (P) -> String?,
    localDeviceId: String,
    trustedIds: Set<String>,
    connectedIds: Set<String>,
): List<Pair<P, String>> = peers.mapNotNull { peer ->
    val id = idOf(peer) ?: return@mapNotNull null
    if (id in trustedIds && localDeviceId < id && id !in connectedIds) peer to id else null
}.distinctBy { it.second }
