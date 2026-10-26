package dev.bridgey.android.bench

import java.io.File
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * Runs the official BLAKE3 test vectors against the same C sources and JNI glue the app ships,
 * built for this host with the portable code path (no assembly). Skipped when no C compiler or
 * jni.h is available. The arm64 NEON build is checked on the phone by the app's own self-test.
 */
class Blake3VectorsTest {
    private fun hostLibrary(): File? {
        val javaHome = File(System.getProperty("java.home") ?: return null)
        val jniInclude = listOf(javaHome, javaHome.parentFile).firstNotNullOfOrNull { home ->
            home?.resolve("include")?.takeIf { it.resolve("jni.h").exists() }
        } ?: return null
        val osDir = jniInclude.listFiles()?.firstOrNull { it.isDirectory } ?: return null
        val cpp = File("src/main/cpp")
        val out = File(System.getProperty("java.io.tmpdir"), "bridgey-blake3-test-${System.nanoTime()}")
        out.mkdirs()
        val ext = if (System.getProperty("os.name").lowercase().contains("mac")) "dylib" else "so"
        val lib = File(out, "libbridgeyblake3.$ext")
        val cmd = listOf(
            "cc", "-O2", "-shared", "-fPIC", "-DBLAKE3_USE_NEON=0", "-DBLAKE3_NO_SSE2", "-DBLAKE3_NO_SSE41",
            "-DBLAKE3_NO_AVX2", "-DBLAKE3_NO_AVX512",
            "-I", jniInclude.path, "-I", osDir.path, "-I", cpp.resolve("blake3").path,
            cpp.resolve("blake3/blake3.c").path, cpp.resolve("blake3/blake3_dispatch.c").path,
            cpp.resolve("blake3/blake3_portable.c").path, cpp.resolve("blake3_jni.c").path,
            "-o", lib.path,
        )
        return try {
            val p = ProcessBuilder(cmd).redirectErrorStream(true).start()
            val finished = p.waitFor(120, TimeUnit.SECONDS)
            if (finished && p.exitValue() == 0) lib else null
        } catch (_: Exception) {
            null
        }
    }

    @Test
    fun officialVectorsPassOnTheShippedSources() {
        val lib = hostLibrary()
        assumeTrue("no host C compiler or jni.h", lib != null)
        System.load(lib!!.path)
        // Blake3Native loads by name; call the natives through a hasher built from the loaded library.
        val failures = Blake3Vectors.failures(::loadedHasher)
        assertEquals(emptyList<Int>(), failures)
    }

    private fun loadedHasher(): BlockHasher {
        val m = Blake3Native::class.java
        // The object's own System.loadLibrary fails on the host, so reach the natives reflectively.
        val create = m.getDeclaredMethod("nativeCreate").apply { isAccessible = true }
        val reset = m.getDeclaredMethod("nativeReset", Long::class.java).apply { isAccessible = true }
        val update = m.getDeclaredMethod("nativeUpdateArray", Long::class.java, ByteArray::class.java, Int::class.java, Int::class.java).apply { isAccessible = true }
        val fin = m.getDeclaredMethod("nativeFinalize", Long::class.java).apply { isAccessible = true }
        val destroy = m.getDeclaredMethod("nativeDestroy", Long::class.java).apply { isAccessible = true }
        val handle = create.invoke(null) as Long
        return object : BlockHasher {
            override fun reset() { reset.invoke(null, handle) }
            override fun update(data: ByteArray, offset: Int, length: Int) { update.invoke(null, handle, data, offset, length) }
            override fun digest(): ByteArray = fin.invoke(null, handle) as ByteArray
            override fun close() { destroy.invoke(null, handle) }
        }
    }

    @Test
    fun vectorListMatchesTheOfficialLengths() {
        assertEquals(35, Blake3Vectors.CASES.size)
        assertTrue(Blake3Vectors.CASES.all { it.second.length == 64 })
        assertEquals("af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262", Blake3Vectors.CASES.first { it.first == 0 }.second)
    }
}
