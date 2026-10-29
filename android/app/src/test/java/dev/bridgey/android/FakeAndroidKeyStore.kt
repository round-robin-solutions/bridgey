package dev.bridgey.android

import java.io.InputStream
import java.io.OutputStream
import java.security.Key
import java.security.KeyPair
import java.security.KeyPairGeneratorSpi
import java.security.KeyStoreSpi
import java.security.Provider
import java.security.PublicKey
import java.security.SecureRandom
import java.security.Security
import java.security.cert.Certificate
import java.security.spec.AlgorithmParameterSpec
import java.security.spec.ECGenParameterSpec
import java.util.Collections
import java.util.Date
import java.util.Enumeration

/**
 * An in-memory "AndroidKeyStore" for JVM tests: Robolectric has no Keystore, and PairingCoordinator makes its
 * identity key there. Keys live for the test run only. Install with [FakeAndroidKeyStore.install].
 */
object FakeAndroidKeyStore {
    internal val keys = Collections.synchronizedMap(HashMap<String, KeyPair>())

    @Synchronized fun install() {
        if (Security.getProvider("AndroidKeyStore") != null) return
        // Last, so plain "EC" lookups keep their usual provider; the app names "AndroidKeyStore" explicitly.
        Security.addProvider(Provider)
    }

    private object Provider : java.security.Provider("AndroidKeyStore", 1.0, "Test Keystore") {
        private fun readResolve(): Any = Provider

        init {
            put("KeyStore.AndroidKeyStore", Store::class.java.name)
            put("KeyPairGenerator.EC", Generator::class.java.name)
        }
    }

    class Store : KeyStoreSpi() {
        override fun engineGetKey(alias: String, password: CharArray?): Key? = keys[alias]?.private
        override fun engineGetCertificateChain(alias: String): Array<Certificate>? = engineGetCertificate(alias)?.let { arrayOf(it) }
        override fun engineGetCertificate(alias: String): Certificate? = keys[alias]?.public?.let(::FakeCertificate)
        override fun engineGetCreationDate(alias: String): Date? = if (alias in keys) Date(0) else null
        override fun engineSetKeyEntry(alias: String, key: Key, password: CharArray?, chain: Array<out Certificate>?) = Unit
        override fun engineSetKeyEntry(alias: String, key: ByteArray, chain: Array<out Certificate>?) = Unit
        override fun engineSetCertificateEntry(alias: String, cert: Certificate) = Unit
        override fun engineDeleteEntry(alias: String) { keys.remove(alias) }
        override fun engineAliases(): Enumeration<String> = Collections.enumeration(keys.keys.toList())
        override fun engineContainsAlias(alias: String) = alias in keys
        override fun engineSize() = keys.size
        override fun engineIsKeyEntry(alias: String) = alias in keys
        override fun engineIsCertificateEntry(alias: String) = false
        override fun engineGetCertificateAlias(cert: Certificate): String? = null
        override fun engineStore(stream: OutputStream?, password: CharArray?) = Unit
        override fun engineLoad(stream: InputStream?, password: CharArray?) = Unit
    }

    class Generator : KeyPairGeneratorSpi() {
        private var alias = "default"

        override fun initialize(keysize: Int, random: SecureRandom?) = Unit

        override fun initialize(params: AlgorithmParameterSpec?, random: SecureRandom?) {
            // android.security.keystore.KeyGenParameterSpec, read by reflection so the JVM test needs no Keystore.
            alias = runCatching { params!!.javaClass.getMethod("getKeystoreAlias").invoke(params) as String }.getOrDefault(alias)
        }

        override fun generateKeyPair(): KeyPair {
            val pair = Security.getProviders("KeyPairGenerator.EC").first { it.name != "AndroidKeyStore" }
                .let { java.security.KeyPairGenerator.getInstance("EC", it) }
                .apply { initialize(ECGenParameterSpec("secp256r1")) }
                .generateKeyPair()
            keys[alias] = pair
            return pair
        }
    }

    private class FakeCertificate(private val key: PublicKey) : Certificate("X.509") {
        override fun getEncoded() = key.encoded
        override fun verify(key: PublicKey?) = Unit
        override fun verify(key: PublicKey?, sigProvider: String?) = Unit
        override fun toString() = "FakeCertificate"
        override fun getPublicKey() = key
    }

}
