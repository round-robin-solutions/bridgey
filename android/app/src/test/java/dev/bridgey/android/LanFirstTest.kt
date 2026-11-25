package dev.bridgey.android

import dev.bridgey.android.connect.ConnectAddress
import dev.bridgey.android.connect.LearnedAddress
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** LAN first (LanFirst.kt): the tier table, the duplicate rule, active transfers and the upgrade loop. */
class LanFirstTest {
    // region Tier

    @Test fun tierTable() {
        val lan = listOf(
            "10.0.0.5", "172.16.0.1", "172.31.255.254", "192.168.29.10", "169.254.3.4", "127.0.0.1",
            "fe80::1", "fe80::1%wlan0", "[fe80::abcd]", "fd12:3456::1", "fc00::1", "::1",
            "::ffff:192.168.1.5", "::ffff:10.1.2.3",
        )
        val socket = listOf(
            "100.64.0.1", "100.101.1.2", "100.127.255.255", "8.8.8.8", "172.32.0.1", "172.15.0.1", "192.169.0.1",
            "fd7a:115c:a1e0::1", "fd7a:115c:a1e0:ab12::5", "2409:4040::1", "::ffff:100.101.1.2", "::ffff:8.8.8.8",
            "printer.local", "", "not an address",
        )
        lan.forEach { assertTrue(it, isLanAddress(it)) }
        socket.forEach { assertFalse(it, isLanAddress(it)) }
        assertEquals(SessionTier.LAN, sessionTier(tunnel = false, remoteAddress = "192.168.29.10"))
        assertEquals(SessionTier.SOCKET, sessionTier(tunnel = false, remoteAddress = "100.101.1.2"))
        assertEquals(SessionTier.SOCKET, sessionTier(tunnel = false, remoteAddress = null))
        // A tunnel is tier 0 whatever its route or its loopback bridge says.
        assertEquals(SessionTier.TUNNEL, sessionTier(tunnel = true, remoteAddress = "127.0.0.1"))
        assertEquals(listOf(0, 1, 2), listOf(SessionTier.TUNNEL, SessionTier.SOCKET, SessionTier.LAN).map { it.rank })
    }

    @Test fun virtualInterfaceRangesAreNeverAdvertised() {
        assertTrue(isVirtualInterfaceAddress("192.168.139.3"))
        assertTrue(isVirtualInterfaceAddress("192.168.215.0"))
        assertFalse(isVirtualInterfaceAddress("192.168.29.10"))
        assertFalse(isVirtualInterfaceAddress("fd12::1"))
        val advertised = advertisedConnectAddresses(
            listOf(
                ConnectAddress("192.168.29.10", "lan"), ConnectAddress("192.168.139.3", "lan"),
                ConnectAddress("192.168.215.1", "lan"), ConnectAddress("100.101.1.2", "vpn", "tailscale"),
            ),
        )
        assertEquals(listOf("192.168.29.10", "100.101.1.2"), advertised.map { it.a })
    }

    @Test fun lanFirstFlagIsReadOutsideTheDraftList() {
        assertFalse(LAN_FIRST_FEATURE_KEY in KNOWN_DRAFT_FEATURE_KEYS)
        assertFalse(LAN_FIRST_DRAFT2_FEATURE_KEY in KNOWN_DRAFT_FEATURE_KEYS)
        assertTrue(decodeFeatureFlag("""{"version":1,"features":{"lan_first_draft1":true}}""".toByteArray(), LAN_FIRST_FEATURE_KEY))
        assertFalse(decodeFeatureFlag("""{"version":1,"features":{"lan_first_draft1":"true"}}""".toByteArray(), LAN_FIRST_FEATURE_KEY))
        assertFalse(decodeFeatureFlag("""{"version":1,"features":{}}""".toByteArray(), LAN_FIRST_FEATURE_KEY))
        assertFalse(decodeFeatureFlag("not json".toByteArray(), LAN_FIRST_FEATURE_KEY))
    }

    @Test fun rememberedOnlyWithBothKeys() {
        fun remembered(features: String): Boolean {
            val plaintext = """{"version":1,"features":{$features}}""".toByteArray()
            return lanFirstRemembered(decodeFeatureFlag(plaintext, LAN_FIRST_FEATURE_KEY), decodeFeatureFlag(plaintext, LAN_FIRST_DRAFT2_FEATURE_KEY))
        }
        assertTrue(remembered(""""lan_first_draft1":true,"lan_first_draft2":true"""))
        assertFalse("Beta 2 to 4", remembered(""""lan_first_draft1":true"""))
        assertFalse("never without the first key", remembered(""""lan_first_draft2":true"""))
        assertFalse(remembered(""""lan_first_draft1":true,"lan_first_draft2":"true""""))
    }

    // endregion

    // region Duplicate rule

    @Test fun duplicateVerdictMatrix() {
        fun verdict(
            stale: Boolean = false, key: Boolean = true, transfer: Boolean = false,
            new: SessionTier = SessionTier.LAN, old: SessionTier = SessionTier.TUNNEL,
            newLower: Boolean = false, oldLower: Boolean = true, remembered: Boolean = false,
        ) = duplicateVerdict(stale, key, remembered, transfer, new, old, newLower, oldLower)

        // 1. Stale beats everything, a transfer and the tiers included.
        assertEquals(DuplicateVerdict.STALE, verdict(stale = true, transfer = true, new = SessionTier.TUNNEL, old = SessionTier.LAN))
        assertEquals(DuplicateVerdict.STALE, verdict(stale = true, key = false))
        // 2. A peer without the key: exactly the old rule, tiers and transfers ignored.
        assertEquals(DuplicateVerdict.DIALLED_EXISTING, verdict(key = false, transfer = true))
        assertEquals(DuplicateVerdict.DIALLED_EXISTING, verdict(key = false, new = SessionTier.LAN, old = SessionTier.TUNNEL))
        assertEquals(DuplicateVerdict.DIALLED_NEW, verdict(key = false, transfer = true, new = SessionTier.TUNNEL, old = SessionTier.LAN, newLower = true, oldLower = false))
        assertEquals(DuplicateVerdict.DIALLED_NEW, verdict(key = false, newLower = true, oldLower = true))
        // 3. An active transfer keeps the live session, even against a better tier.
        assertEquals(DuplicateVerdict.TRANSFER, verdict(transfer = true, new = SessionTier.LAN, old = SessionTier.TUNNEL, newLower = true, oldLower = false))
        assertEquals(DuplicateVerdict.TRANSFER, verdict(transfer = true, new = SessionTier.LAN, old = SessionTier.LAN))
        // 4. The higher tier wins whoever dialled; equal tiers use the old rule.
        assertEquals(DuplicateVerdict.TIER_NEW, verdict(new = SessionTier.LAN, old = SessionTier.TUNNEL))
        assertEquals(DuplicateVerdict.TIER_NEW, verdict(new = SessionTier.LAN, old = SessionTier.SOCKET))
        assertEquals(DuplicateVerdict.TIER_NEW, verdict(new = SessionTier.SOCKET, old = SessionTier.TUNNEL))
        assertEquals(DuplicateVerdict.TIER_EXISTING, verdict(new = SessionTier.TUNNEL, old = SessionTier.LAN, newLower = true, oldLower = false))
        assertEquals(DuplicateVerdict.TIER_EXISTING, verdict(new = SessionTier.SOCKET, old = SessionTier.LAN))
        assertEquals(DuplicateVerdict.DIALLED_EXISTING, verdict(new = SessionTier.LAN, old = SessionTier.LAN, newLower = false, oldLower = true))
        assertEquals(DuplicateVerdict.DIALLED_NEW, verdict(new = SessionTier.LAN, old = SessionTier.LAN, newLower = true, oldLower = false))
        assertEquals(DuplicateVerdict.DIALLED_NEW, verdict(new = SessionTier.TUNNEL, old = SessionTier.TUNNEL, newLower = false, oldLower = false))
        // 2 again, features not yet received on the live session: a remembered peer (lan_first_draft2) gets rules 3
        // and 4 exactly as with them; one that is not remembered gets the old rule.
        val tiers = SessionTier.entries
        for (stale in listOf(false, true)) for (transfer in listOf(false, true)) for (new in tiers) for (old in tiers) {
            for (newLower in listOf(false, true)) for (oldLower in listOf(false, true)) {
                assertEquals(
                    verdict(stale, key = true, transfer = transfer, new = new, old = old, newLower = newLower, oldLower = oldLower),
                    verdict(stale, key = false, transfer = transfer, new = new, old = old, newLower = newLower, oldLower = oldLower, remembered = true),
                )
            }
        }
        // 24 Nov: a new LAN session dialled by the higher ID, then a tunnel (always the lower ID's), no features yet.
        assertEquals(DuplicateVerdict.DIALLED_NEW, verdict(key = false, new = SessionTier.TUNNEL, old = SessionTier.LAN, newLower = true, oldLower = false))
        assertEquals(DuplicateVerdict.TIER_EXISTING, verdict(key = false, remembered = true, new = SessionTier.TUNNEL, old = SessionTier.LAN, newLower = true, oldLower = false))
        assertTrue(DuplicateVerdict.TIER_NEW.newWins)
        assertFalse(DuplicateVerdict.TRANSFER.newWins)
        assertEquals("tier", DuplicateVerdict.TIER_EXISTING.detail)
        assertEquals("transfer", DuplicateVerdict.TRANSFER.detail)
        assertNull(DuplicateVerdict.DIALLED_NEW.detail)
    }

    /** A session in a registry test: identity and tier are all the rule reads. */
    private class Fake(val name: String, val tier: SessionTier) {
        override fun toString() = name
    }

    private val phone = "m-phone"
    private val mac = "z-mac" // a higher ID: the phone is the lower dialler
    private val lowMac = "a-mac" // a lower ID: the Mac is the lower dialler

    private fun SessionRegistry<Fake>.join(
        session: Fake, deviceId: String, dialledHere: Boolean, lanFirst: Boolean = true, transfer: Boolean = false,
        verdicts: MutableList<DuplicateVerdict>? = null,
    ): SessionRegistry.Admission<Fake> {
        addPending(session, dialledHere)
        val admission = authenticate(session, deviceId, session.name, tierOf = { it.tier }, activeTransfer = transfer, onVerdict = { verdicts?.add(it) })
        if (admission is SessionRegistry.Admission.Accepted) update(deviceId) { it.copy(remoteLanFirst = lanFirst) }
        return admission
    }

    @Test fun lanSessionReplacesTheTunnelInBothDialDirections() {
        for (remote in listOf(mac, lowMac)) {
            for (dialledHere in listOf(true, false)) {
                val registry = SessionRegistry<Fake>(phone)
                val tunnel = Fake("tunnel", SessionTier.TUNNEL)
                val lan = Fake("lan", SessionTier.LAN)
                // The tunnel was dialled by the lower ID, so the old rule alone would keep it.
                registry.join(tunnel, remote, dialledHere = remote > phone)
                val verdicts = mutableListOf<DuplicateVerdict>()
                assertEquals("$remote dialledHere=$dialledHere", SessionRegistry.Admission.Accepted(tunnel), registry.join(lan, remote, dialledHere, verdicts = verdicts))
                assertSame(lan, registry.session(remote))
                assertEquals(listOf(DuplicateVerdict.TIER_NEW), verdicts)
                // The survivor keeps what the device reported, the key included.
                assertTrue(registry.state(remote)!!.remoteLanFirst)
                // A tunnel that comes back later never replaces the LAN session.
                val again = Fake("tunnel again", SessionTier.TUNNEL)
                assertEquals(SessionRegistry.Admission.Rejected, registry.join(again, remote, dialledHere = remote > phone))
                assertSame(lan, registry.session(remote))
            }
        }
    }

    @Test fun anActiveTransferKeepsTheLiveSession() {
        val registry = SessionRegistry<Fake>(phone)
        val tunnel = Fake("tunnel", SessionTier.TUNNEL)
        registry.join(tunnel, mac, dialledHere = true)
        val verdicts = mutableListOf<DuplicateVerdict>()
        assertEquals(SessionRegistry.Admission.Rejected, registry.join(Fake("lan", SessionTier.LAN), mac, dialledHere = true, transfer = true, verdicts = verdicts))
        assertSame(tunnel, registry.session(mac))
        assertEquals(listOf(DuplicateVerdict.TRANSFER), verdicts)
        // Stale still wins: the transfer on a dead session is gone anyway.
        val stale = SessionRegistry<Fake>(phone)
        stale.join(tunnel, mac, dialledHere = true)
        val lan = Fake("lan", SessionTier.LAN)
        stale.addPending(lan, true)
        assertEquals(SessionRegistry.Admission.Accepted(tunnel), stale.authenticate(lan, mac, "lan", isStale = { it === tunnel }, tierOf = { it.tier }, activeTransfer = true))
    }

    @Test fun aPeerWithoutTheKeyKeepsTheOldRule() {
        // Without lan_first_draft1 the tunnel dialled by the lower ID stays, as older builds expect.
        val registry = SessionRegistry<Fake>(phone)
        val tunnel = Fake("tunnel", SessionTier.TUNNEL)
        registry.join(tunnel, mac, dialledHere = true, lanFirst = false)
        val verdicts = mutableListOf<DuplicateVerdict>()
        assertEquals(SessionRegistry.Admission.Rejected, registry.join(Fake("lan", SessionTier.LAN), mac, dialledHere = false, lanFirst = false, verdicts = verdicts))
        assertSame(tunnel, registry.session(mac))
        assertEquals(listOf(DuplicateVerdict.DIALLED_EXISTING), verdicts)
        // And a transfer does not hold back a replacement the old rule makes (the peer would not hold it back either).
        val lan = Fake("lan", SessionTier.LAN)
        assertEquals(SessionRegistry.Admission.Accepted(tunnel), registry.join(lan, mac, dialledHere = true, lanFirst = false, transfer = true))
        assertSame(lan, registry.session(mac))
    }

    @Test fun bothEndsKeepTheSameSession() {
        // The phone and the Mac each see a tunnel and two LAN sockets (both dialled at once) in different orders.
        val tiers = mapOf("tunnel" to SessionTier.TUNNEL, "phone-lan" to SessionTier.LAN, "mac-lan" to SessionTier.LAN)
        for (order in listOf(listOf("phone-lan", "mac-lan"), listOf("mac-lan", "phone-lan"))) {
            val atPhone = SessionRegistry<String>(phone)
            val atMac = SessionRegistry<String>(mac)
            fun SessionRegistry<String>.add(name: String, here: Boolean, id: String) {
                addPending(name, here)
                if (authenticate(name, id, name, tierOf = { tiers.getValue(it) }) is SessionRegistry.Admission.Accepted) update(id) { it.copy(remoteLanFirst = true) }
            }
            atPhone.add("tunnel", here = true, id = mac)
            atMac.add("tunnel", here = false, id = phone)
            order.forEach { name -> atPhone.add(name, here = name == "phone-lan", id = mac) }
            order.reversed().forEach { name -> atMac.add(name, here = name == "mac-lan", id = phone) }
            // The phone has the lower ID, so of two LAN sockets both keep the one it dialled.
            assertEquals("phone-lan", atPhone.session(mac))
            assertEquals("phone-lan", atMac.session(phone))
        }
    }

    /**
     * One end of a phone (m-phone) and Mac pair, as a registry: the live session [existing] then [candidate], each with
     * whether the Mac dialled it. [fixed]: a build with lan_first_draft2, else 1.0 Beta 2 to 4 (never remembers, never
     * remembered). [featuresHere]: this end has the peer's features.update on the live session. [exchanged]: an earlier
     * session exchanged features, so a fixed end remembers what the peer's build sent.
     */
    private fun end(
        atPhone: Boolean, macId: String, fixed: Boolean, peerFixed: Boolean, exchanged: Boolean, featuresHere: Boolean,
        existing: Pair<SessionTier, Boolean>, candidate: Pair<SessionTier, Boolean>,
    ): String {
        val peerSent = (if (peerFixed) """{"version":1,"features":{"lan_first_draft1":true,"lan_first_draft2":true}}""" else """{"version":1,"features":{"lan_first_draft1":true}}""").toByteArray()
        val remembered = fixed && exchanged && lanFirstRemembered(decodeFeatureFlag(peerSent, LAN_FIRST_FEATURE_KEY), decodeFeatureFlag(peerSent, LAN_FIRST_DRAFT2_FEATURE_KEY))
        val registry = SessionRegistry<Fake>(if (atPhone) phone else macId)
        val remote = if (atPhone) macId else phone
        val old = Fake("existing", existing.first)
        val new = Fake("candidate", candidate.first)
        registry.addPending(old, initiatedLocally = existing.second != atPhone)
        registry.authenticate(old, remote, "Peer", tierOf = { it.tier })
        registry.update(remote) { it.copy(remoteLanFirst = featuresHere) }
        registry.addPending(new, initiatedLocally = candidate.second != atPhone)
        registry.authenticate(new, remote, "Peer", tierOf = { it.tier }, rememberedLanFirst = remembered)
        return registry.session(remote)!!.name
    }

    private fun forEveryPair(body: (String, Pair<SessionTier, Boolean>, Pair<SessionTier, Boolean>, Boolean, Boolean) -> Unit) {
        val directions = listOf(true to true, true to false, false to true, false to false)
        for (macId in listOf(mac, lowMac)) for (existingTier in SessionTier.entries) for (candidateTier in SessionTier.entries) {
            for ((macDialledExisting, macDialledCandidate) in directions) for ((featuresAtPhone, featuresAtMac) in directions) {
                body(macId, existingTier to macDialledExisting, candidateTier to macDialledCandidate, featuresAtPhone, featuresAtMac)
            }
        }
    }

    @Test fun rememberedPeerKeepsTheLanSessionBeforeItsFeaturesArrive() {
        // 24 Nov: the Mac (z-mac, the higher ID, so the phone owns the tunnel) redialled over the LAN after a restart, and
        // the tunnel authenticated before any features.update.
        val lanByMac = SessionTier.LAN to true
        val tunnelByPhone = SessionTier.TUNNEL to false
        assertEquals("tunnel replaced LAN, as in Beta 2 to 4", "candidate",
            end(atPhone = true, macId = mac, fixed = true, peerFixed = true, exchanged = false, featuresHere = false, existing = lanByMac, candidate = tunnelByPhone))
        for (atPhone in listOf(true, false)) {
            assertEquals("existing", end(atPhone, mac, fixed = true, peerFixed = true, exchanged = true, featuresHere = false, existing = lanByMac, candidate = tunnelByPhone))
        }
        // The registry carries the verdict for diagnostics.
        val registry = SessionRegistry<Fake>(phone)
        val lan = Fake("lan", SessionTier.LAN)
        registry.addPending(lan, false)
        registry.authenticate(lan, mac, "lan", tierOf = { it.tier })
        val verdicts = mutableListOf<DuplicateVerdict>()
        val tunnel = Fake("tunnel", SessionTier.TUNNEL)
        registry.addPending(tunnel, true)
        assertEquals(SessionRegistry.Admission.Rejected, registry.authenticate(tunnel, mac, "tunnel", tierOf = { it.tier }, rememberedLanFirst = true, onVerdict = { verdicts += it }))
        assertEquals(listOf(DuplicateVerdict.TIER_EXISTING), verdicts)
        assertSame(lan, registry.session(mac))
    }

    @Test fun fixedEndsAgreeWhateverFeaturesHaveArrived() {
        forEveryPair { macId, existing, candidate, featuresAtPhone, featuresAtMac ->
            val atPhone = end(true, macId, fixed = true, peerFixed = true, exchanged = true, featuresHere = featuresAtPhone, existing = existing, candidate = candidate)
            val atMac = end(false, macId, fixed = true, peerFixed = true, exchanged = true, featuresHere = featuresAtMac, existing = existing, candidate = candidate)
            assertEquals("$macId $existing then $candidate features phone=$featuresAtPhone mac=$featuresAtMac", atPhone, atMac)
        }
    }

    @Test fun mixedVersionsBehaveAsBefore() {
        // One end on Beta 2 to 4, or the first session after both updated: each end decides exactly as Beta 2 to 4 does,
        // so the pair agrees whenever both ends have the same features state, as before.
        forEveryPair { macId, existing, candidate, featuresAtPhone, featuresAtMac ->
            for ((phoneFixed, macFixed, exchanged) in listOf(Triple(true, false, true), Triple(false, true, true), Triple(true, true, false))) {
                for (atPhone in listOf(true, false)) {
                    val features = if (atPhone) featuresAtPhone else featuresAtMac
                    val now = end(atPhone, macId, if (atPhone) phoneFixed else macFixed, if (atPhone) macFixed else phoneFixed, exchanged, features, existing, candidate)
                    val before = end(atPhone, macId, fixed = false, peerFixed = false, exchanged = exchanged, featuresHere = features, existing = existing, candidate = candidate)
                    assertEquals("$macId phone fixed=$phoneFixed mac fixed=$macFixed at phone=$atPhone", before, now)
                }
                if (featuresAtPhone != featuresAtMac) continue
                assertEquals(
                    end(true, macId, phoneFixed, macFixed, exchanged, featuresAtPhone, existing, candidate),
                    end(false, macId, macFixed, phoneFixed, exchanged, featuresAtMac, existing, candidate),
                )
            }
        }
    }

    @Test fun rememberingTheFirstKeyAloneWouldSplitAMixedPair() {
        // A fixed Mac that remembered a Beta 2 to 4 phone's lan_first_draft1 would keep the LAN session while the phone,
        // still waiting for features, keeps its tunnel: both sessions would close.
        val registry = SessionRegistry<Fake>(mac)
        val lan = Fake("lan", SessionTier.LAN)
        registry.addPending(lan, true)
        registry.authenticate(lan, phone, "lan", tierOf = { it.tier })
        val tunnel = Fake("tunnel", SessionTier.TUNNEL)
        registry.addPending(tunnel, false)
        registry.authenticate(tunnel, phone, "tunnel", tierOf = { it.tier }, rememberedLanFirst = true)
        val atPhone = end(true, mac, fixed = false, peerFixed = true, exchanged = true, featuresHere = false,
            existing = SessionTier.LAN to true, candidate = SessionTier.TUNNEL to false)
        assertEquals("lan", registry.session(phone)!!.name)
        assertEquals("candidate", atPhone)
    }

    // endregion

    // region Active transfer

    @Test fun activeTransferCountsWhatThePeerKnowsAbout() {
        var rows = emptyList<FileTransferState>()
        var folder = false
        var clip = false
        var speed = false
        val devices = mapOf("file-1" to mac, "file-2" to lowMac)
        val activity = TransferActivity({ rows }, { devices[it] }, { folder && it == mac }, { clip && it == mac }, { speed && it == mac })
        assertFalse(activity.hasActiveTransfer(mac))
        rows = listOf(FileTransferState("file-1", "a.mov", "Sending", active = true, progressPercent = 10))
        assertTrue(activity.hasActiveTransfer(mac))
        assertFalse(activity.hasActiveTransfer(lowMac))
        // Queued, finished and folder rows do not count (folders answer for themselves).
        rows = listOf(
            FileTransferState("file-1", "a.mov", "Waiting", active = true, progressPercent = null, queued = true),
            FileTransferState("file-2", "b.mov", "Sent", active = false, progressPercent = 100),
            FileTransferState("folder-1", "Photos", "Sending", active = true, progressPercent = 5, deviceId = mac, kind = TransferKind.FOLDER),
        )
        assertFalse(activity.hasActiveTransfer(mac))
        // A row with no mapping falls back to its own device.
        rows = listOf(FileTransferState("file-9", "c.pdf", "Receiving", active = true, progressPercent = 1, deviceId = mac))
        assertTrue(activity.hasActiveTransfer(mac))
        rows = emptyList()
        folder = true
        assertTrue(activity.hasActiveTransfer(mac))
        folder = false
        clip = true
        assertTrue(activity.hasActiveTransfer(mac))
        clip = false
        speed = true
        assertTrue(activity.hasActiveTransfer(mac))
        assertFalse(activity.hasActiveTransfer(lowMac))
    }

    // endregion

    // region Upgrade candidates

    private val home = listOf(LocalIPv4Network(parseIPv4("192.168.29.40")!!, 24))

    @Test fun candidatesAreLanAddressesOnThisNetwork() {
        val learned = listOf(
            LearnedAddress("192.168.29.10", 42_459, "lan", null, 2),
            LearnedAddress("192.168.139.3", 42_459, "lan", null, 3), // OrbStack, never
            LearnedAddress("10.0.0.7", 42_459, "lan", null, 4), // another network
            LearnedAddress("100.101.1.2", 42_459, "vpn", "tailscale", 5),
            LearnedAddress("fd12::7", 42_459, "lan", null, 6), // learned IPv6: no subnet to check
        )
        val candidates = lanUpgradeCandidates(listOf("192.168.29.10", "fd12::5", "fe80::1", "2409:4040::1", "mac.local"), 42_458, learned, home)
        // NSD first (its own port), then learned at Bridgey's TCP port, each address once.
        assertEquals(listOf(LanCandidate("192.168.29.10", 42_458, "nsd"), LanCandidate("fd12::5", 42_458, "nsd")), candidates)
        val onlyLearned = lanUpgradeCandidates(emptyList(), null, learned, home)
        assertEquals(listOf(LanCandidate("192.168.29.10", ReconnectPolicy.LISTENING_PORT, "learned")), onlyLearned)
        // NSD's IPv4 from another network (a stale sighting) is not dialled; on mobile data nothing is.
        assertEquals(emptyList<LanCandidate>(), lanUpgradeCandidates(listOf("10.0.0.7"), 42_458, emptyList(), home))
        assertEquals(emptyList<LanCandidate>(), lanUpgradeCandidates(listOf("192.168.29.10"), 42_458, learned, emptyList()))
    }

    // endregion

    // region Upgrade loop

    private class Loop(val clock: ManualClock = ManualClock()) {
        val engine = LanUpgradeEngine(clock)
        val connected = mutableSetOf("mac")
        var check = LanUpgradeCheck.READY
        var candidates = listOf(LanCandidate("192.168.29.10", 42_458, "nsd"))
        var network = "home"
        val dials = mutableListOf<Pair<String, LanCandidate>>()
        val events = mutableListOf<LanUpgradeEvent>()

        init {
            engine.connectedIds = { connected }
            engine.check = { if (it in connected) check else LanUpgradeCheck.NOT_NEEDED }
            engine.candidates = { candidates }
            engine.network = { network }
            engine.dial = { id, address -> dials += id to address }
            engine.onEvent = { events += it }
        }

        fun fail() = engine.dialEnded("mac", upgraded = false, reason = "refused")
    }

    @Test fun dialsAtOnceWhenAnUpgradeIsPossible() {
        val loop = Loop()
        loop.engine.poke("session")
        loop.clock.advance(0)
        assertEquals(listOf("mac" to LanCandidate("192.168.29.10", 42_458, "nsd")), loop.dials)
        assertTrue(loop.engine.isDialing("mac"))
        assertEquals(LanUpgradeEvent.Dial("mac", loop.candidates.single(), 1, "session"), loop.events.single())
        // One dial in flight: pokes and time do not start another.
        loop.engine.poke("discovery")
        loop.clock.advance(20_000)
        assertEquals(1, loop.dials.size)
        // It won: the device is on the LAN, and the loop stops.
        loop.engine.dialEnded("mac", upgraded = true, reason = "accepted")
        assertEquals(LanUpgradeEvent.Won("mac", loop.candidates.single(), "accepted"), loop.events.last())
        loop.check = LanUpgradeCheck.NOT_NEEDED
        loop.clock.advance(3_600_000)
        assertEquals(1, loop.dials.size)
    }

    @Test fun backsOffAfterFailuresUntilTheNetworkChanges() {
        val loop = Loop()
        loop.engine.poke("session")
        loop.clock.advance(0)
        loop.fail()
        // Every 30 s while it fails.
        loop.clock.advance(29_999)
        assertEquals(1, loop.dials.size)
        loop.clock.advance(1)
        assertEquals(2, loop.dials.size)
        loop.fail()
        loop.clock.advance(30_000)
        assertEquals(3, loop.dials.size)
        loop.fail()
        assertEquals(3, loop.engine.failures("mac"))
        // After 3 failures on this network: every 5 minutes, and a poke does not bring it forward.
        loop.engine.poke("discovery")
        loop.clock.advance(299_999)
        assertEquals(3, loop.dials.size)
        loop.clock.advance(1)
        assertEquals(4, loop.dials.size)
        loop.fail()
        // A new network starts over: a try at once.
        loop.network = "office"
        loop.engine.poke("network")
        loop.clock.advance(0)
        assertEquals(5, loop.dials.size)
        assertEquals(0, loop.engine.failures("mac"))
        val failed = loop.events.filterIsInstance<LanUpgradeEvent.Failed>()
        assertEquals(listOf(1, 2, 3, 4), failed.map { it.failures })
    }

    @Test fun waitsWhileATransferRuns() {
        val loop = Loop()
        loop.check = LanUpgradeCheck.TRANSFER
        loop.engine.poke("session")
        loop.clock.advance(0)
        loop.clock.advance(120_000)
        assertTrue(loop.dials.isEmpty())
        // Logged once for the whole transfer, not every 30 s.
        assertEquals(listOf<LanUpgradeEvent>(LanUpgradeEvent.SkippedTransfer("mac")), loop.events)
        // The transfer ends: the next check (at most 30 s later, or at once on a poke) dials.
        loop.check = LanUpgradeCheck.READY
        loop.engine.poke("transfer_finished")
        loop.clock.advance(0)
        assertEquals(1, loop.dials.size)
    }

    @Test fun noAddressMeansNoTimer() {
        val loop = Loop()
        loop.candidates = emptyList()
        loop.engine.poke("session")
        loop.clock.advance(0)
        var checks = 0
        loop.engine.check = { checks++; LanUpgradeCheck.READY }
        // Away from home: nothing wakes up for the upgrade.
        loop.clock.advance(3_600_000)
        assertEquals(0, checks)
        assertTrue(loop.dials.isEmpty())
        assertNull(loop.engine.nextAt("mac"))
        // NSD finds it on this network: tried at once.
        loop.candidates = listOf(LanCandidate("192.168.29.10", 42_458, "nsd"))
        loop.engine.poke("discovery")
        loop.clock.advance(0)
        assertEquals(1, loop.dials.size)
    }

    @Test fun rotatesAddressesAndGivesUpOnALostOutcome() {
        val loop = Loop()
        loop.candidates = listOf(LanCandidate("192.168.29.10", 42_458, "nsd"), LanCandidate("192.168.29.11", 42_458, "learned"))
        loop.engine.poke("session")
        loop.clock.advance(0)
        // No outcome ever comes back: after a minute it counts as a failure and the next address is tried.
        loop.clock.advance(LanUpgradePolicy.DIAL_GIVE_UP_MILLIS)
        assertFalse(loop.engine.isDialing("mac"))
        assertEquals("no_outcome", (loop.events.last() as LanUpgradeEvent.Failed).reason)
        loop.clock.advance(LanUpgradePolicy.RETRY_MILLIS)
        assertEquals(listOf("192.168.29.10", "192.168.29.11"), loop.dials.map { it.second.host })
    }

    @Test fun aDeviceThatLeftIsForgotten() {
        val loop = Loop()
        loop.engine.poke("session")
        loop.clock.advance(0)
        loop.fail()
        loop.connected.clear()
        loop.clock.advance(30_000)
        assertEquals(1, loop.dials.size)
        assertEquals(0, loop.engine.failures("mac"))
    }

    // endregion
}
