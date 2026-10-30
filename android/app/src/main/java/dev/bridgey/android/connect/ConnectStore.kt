package dev.bridgey.android.connect

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import org.json.JSONArray
import org.json.JSONObject
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** An address learned from a peer's connect.addresses, with when it was last reported. */
data class LearnedAddress(val a: String, val port: Int, val kind: String, val vpn: String?, val seenAtMillis: Long)

/**
 * What Connect anywhere keeps per paired device: the pair secret (wrapped by a Keystore key, so it
 * never sits in the clear on disk) and the addresses it reported (at most 16, for 30 days). Forget
 * device and Reset away-from-home identity delete them.
 */
interface ConnectStore {
    fun pairSecret(deviceId: String): ByteArray?
    fun setPairSecret(deviceId: String, secret: ByteArray)
    fun addresses(deviceId: String, nowMillis: Long): List<LearnedAddress>
    fun setAddresses(deviceId: String, addresses: List<LearnedAddress>)
    fun forget(deviceId: String)
    fun forgetAll()
}

/** Learned addresses older than this are dropped (spec 4.5). */
const val LEARNED_ADDRESS_TTL_MILLIS = 30L * 24 * 3_600_000

internal fun encodeAddresses(addresses: List<LearnedAddress>): String = JSONArray(addresses.map {
    JSONObject().put("a", it.a).put("p", it.port).put("kind", it.kind).put("seen", it.seenAtMillis).apply { it.vpn?.let { vpn -> put("vpn", vpn) } }
}).toString()

internal fun decodeAddresses(text: String?, nowMillis: Long): List<LearnedAddress> = runCatching {
    val list = JSONArray(text ?: return emptyList())
    (0 until list.length()).mapNotNull { index ->
        val entry = list.optJSONObject(index) ?: return@mapNotNull null
        LearnedAddress(entry.getString("a"), entry.getInt("p"), entry.getString("kind"), entry.optString("vpn").ifEmpty { null }, entry.getLong("seen"))
    }.filter { nowMillis - it.seenAtMillis < LEARNED_ADDRESS_TTL_MILLIS }.take(CONNECT_MAX_ADDRESSES)
}.getOrDefault(emptyList())

class AndroidConnectStore(context: Context) : ConnectStore {
    private val preferences = context.getSharedPreferences("bridgey.connect", Context.MODE_PRIVATE)
    private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun wrappingKey(): SecretKey {
        (keyStore.getKey(WRAP_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(
                KeyGenParameterSpec.Builder(WRAP_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build(),
            )
        }.generateKey()
    }

    @Synchronized override fun pairSecret(deviceId: String): ByteArray? = runCatching {
        val stored = preferences.getString("secret.$deviceId", null) ?: return null
        val raw = Base64.getDecoder().decode(stored)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, wrappingKey(), GCMParameterSpec(128, raw.copyOfRange(0, 12)))
        cipher.updateAAD(deviceId.toByteArray())
        cipher.doFinal(raw.copyOfRange(12, raw.size))
    }.getOrNull()

    @Synchronized override fun setPairSecret(deviceId: String, secret: ByteArray) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, wrappingKey())
        cipher.updateAAD(deviceId.toByteArray())
        val sealed = cipher.iv + cipher.doFinal(secret)
        preferences.edit().putString("secret.$deviceId", Base64.getEncoder().encodeToString(sealed)).apply()
    }

    @Synchronized override fun addresses(deviceId: String, nowMillis: Long): List<LearnedAddress> =
        decodeAddresses(preferences.getString("addresses.$deviceId", null), nowMillis)

    @Synchronized override fun setAddresses(deviceId: String, addresses: List<LearnedAddress>) {
        preferences.edit().putString("addresses.$deviceId", encodeAddresses(addresses.take(CONNECT_MAX_ADDRESSES))).apply()
    }

    @Synchronized override fun forget(deviceId: String) {
        preferences.edit().remove("secret.$deviceId").remove("addresses.$deviceId").apply()
    }

    @Synchronized override fun forgetAll() {
        preferences.edit().clear().apply()
    }

    private companion object {
        const val WRAP_ALIAS = "bridgey.connect.wrap.v1"
    }
}

/**
 * The node key: authenticates this phone to the control service (spec 6.2). A P-256 key in the
 * Android Keystore, separate from the identity key so the service cannot link it to pairings.
 */
class ConnectNodeKey {
    private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun ensure() {
        if (keyStore.containsAlias(ALIAS)) return
        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore").apply {
            initialize(
                KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_SHA256)
                    .build(),
            )
        }.generateKeyPair()
    }

    /** SEC1 uncompressed public key, base64url without padding (the rendezvous `node`). */
    @Synchronized fun publicKey(): String {
        ensure()
        val public = keyStore.getCertificate(ALIAS).publicKey as java.security.interfaces.ECPublicKey
        val raw = byteArrayOf(4) + fixed(public.w.affineX) + fixed(public.w.affineY)
        return Base64.getUrlEncoder().withoutPadding().encodeToString(raw)
    }

    /** DER ECDSA-P256-SHA256. */
    @Synchronized fun sign(data: ByteArray): ByteArray {
        ensure()
        return Signature.getInstance("SHA256withECDSA").apply {
            initSign(keyStore.getKey(ALIAS, null) as java.security.PrivateKey)
            update(data)
        }.sign()
    }

    /** Reset away-from-home identity: a new key next time. */
    @Synchronized fun reset() {
        if (keyStore.containsAlias(ALIAS)) keyStore.deleteEntry(ALIAS)
    }

    private fun fixed(value: BigInteger): ByteArray {
        val raw = value.toByteArray()
        return when {
            raw.size == 32 -> raw
            raw.size > 32 -> raw.copyOfRange(raw.size - 32, raw.size)
            else -> ByteArray(32 - raw.size) + raw
        }
    }

    private companion object {
        const val ALIAS = "bridgey.connect.node.p256.v1"
    }
}
