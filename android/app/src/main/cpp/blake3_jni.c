#include <jni.h>
#include <stdlib.h>
#include <stdint.h>
#include "blake3.h"

/* JNI glue for dev.bridgey.android.bench.Blake3Native. One hasher per handle. */

JNIEXPORT jlong JNICALL Java_dev_bridgey_android_bench_Blake3Native_nativeCreate(JNIEnv *env, jclass cls) {
    blake3_hasher *h = (blake3_hasher *)malloc(sizeof(blake3_hasher));
    if (h != NULL) blake3_hasher_init(h);
    return (jlong)(intptr_t)h;
}

JNIEXPORT void JNICALL Java_dev_bridgey_android_bench_Blake3Native_nativeReset(JNIEnv *env, jclass cls, jlong handle) {
    blake3_hasher_reset((blake3_hasher *)(intptr_t)handle);
}


JNIEXPORT void JNICALL Java_dev_bridgey_android_bench_Blake3Native_nativeUpdateArray(
    JNIEnv *env, jclass cls, jlong handle, jbyteArray array, jint offset, jint length) {
    jbyte *data = (*env)->GetPrimitiveArrayCritical(env, array, NULL);
    if (data == NULL) return;
    blake3_hasher_update((blake3_hasher *)(intptr_t)handle, (const uint8_t *)data + offset, (size_t)length);
    (*env)->ReleasePrimitiveArrayCritical(env, array, data, JNI_ABORT);
}

JNIEXPORT jbyteArray JNICALL Java_dev_bridgey_android_bench_Blake3Native_nativeFinalize(JNIEnv *env, jclass cls, jlong handle) {
    uint8_t out[BLAKE3_OUT_LEN];
    blake3_hasher_finalize((const blake3_hasher *)(intptr_t)handle, out, BLAKE3_OUT_LEN);
    jbyteArray result = (*env)->NewByteArray(env, BLAKE3_OUT_LEN);
    if (result != NULL) (*env)->SetByteArrayRegion(env, result, 0, BLAKE3_OUT_LEN, (const jbyte *)out);
    return result;
}

JNIEXPORT void JNICALL Java_dev_bridgey_android_bench_Blake3Native_nativeDestroy(JNIEnv *env, jclass cls, jlong handle) {
    free((void *)(intptr_t)handle);
}
