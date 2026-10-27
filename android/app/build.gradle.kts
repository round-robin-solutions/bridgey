import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Round Robin edition: the signing env file uses ANDROID_* names; upstream CI uses BRIDGEY_ANDROID_*.
val releaseStoreFile = System.getenv("BRIDGEY_ANDROID_KEYSTORE")
val releaseStorePassword = System.getenv("BRIDGEY_ANDROID_STORE_PASSWORD") ?: System.getenv("ANDROID_STORE_PASSWORD")
val releaseKeyAlias = System.getenv("BRIDGEY_ANDROID_KEY_ALIAS") ?: System.getenv("ANDROID_KEY_ALIAS")
val releaseKeyPassword = System.getenv("BRIDGEY_ANDROID_KEY_PASSWORD") ?: System.getenv("ANDROID_KEY_PASSWORD")

// Edition settings (app id, update feed) live in rr-edition.properties at the repository root.
val edition = Properties().apply {
    rootProject.projectDir.parentFile.resolve("rr-edition.properties").inputStream().use { load(it) }
}
fun editionValue(key: String): String = requireNotNull(edition.getProperty(key)) { "rr-edition.properties is missing $key" }
// Release builds get BRIDGEY_VERSION_NAME/BRIDGEY_BUILD_NUMBER from scripts/rr; local builds use a dev version.
val editionVersionName = System.getenv("BRIDGEY_VERSION_NAME") ?: "${editionValue("EDITION_NEXT_VERSION")}-dev"
val editionVersionCode = System.getenv("BRIDGEY_BUILD_NUMBER")?.toInt() ?: 1
// Stable releases are "x.y.z-rr.N"; betas, nightlies and local builds are lab builds. Only lab builds
// carry the Code reader test and its READ_SMS permission (src/lab/AndroidManifest.xml), so a stable
// APK never declares SMS access.
val isStableBuild = Regex("""^\d+\.\d+\.\d+-rr\.\d+$""").matches(editionVersionName)

android {
    namespace = "dev.bridgey.android"
    compileSdk = 36

    defaultConfig {
        applicationId = editionValue("EDITION_APP_ID")
        minSdk = 26
        targetSdk = 36
        versionCode = editionVersionCode
        versionName = editionVersionName
        // Performance test: the official BLAKE3 C code through JNI (NEON on arm64).
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        buildConfigField("String", "UPDATE_FEED_BASE_URL", "\"${editionValue("UPDATE_FEED_BASE_URL")}\"")
        buildConfigField("String", "UPDATE_ASSET_URL_PREFIX", "\"${editionValue("UPDATE_ASSET_URL_PREFIX")}\"")
        // Codes from messages: the relay the Code reader test may use (the Mac reads codes in the app).
        buildConfigField("String", "OTP_PROXY_URL", "\"${edition.getProperty("OTP_PROXY_URL").orEmpty()}\"")
        buildConfigField("boolean", "CODE_TEST_AVAILABLE", (!isStableBuild).toString())
    }
    if (!isStableBuild) {
        // Manifest overlays merge on top of main; the build type source sets have none of their own.
        sourceSets.getByName("debug").manifest.srcFile("src/lab/AndroidManifest.xml")
        sourceSets.getByName("release").manifest.srcFile("src/lab/AndroidManifest.xml")
    }

    signingConfigs {
        if (releaseStoreFile != null && releaseStorePassword != null && releaseKeyAlias != null && releaseKeyPassword != null) {
            create("release") {
                storeFile = file(releaseStoreFile)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("release")
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }
    ndkVersion = "27.1.12297006"

    buildFeatures {
        compose = true
        buildConfig = true
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    // Robolectric screenshot tests read the app's fonts, strings and drawables.
    testOptions.unitTests.isIncludeAndroidResources = true
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(project(":core:discovery"))
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.compose.material3:material3:1.3.1")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    // Home-screen widget (Mac actions): Glance, Compose-style RemoteViews.
    implementation("androidx.glance:glance-appwidget:1.1.1")
    testImplementation("junit:junit:4.13.2")
    // Real org.json for JVM unit tests of the update feed parser (android.jar only has stubs).
    testImplementation("org.json:json:20240303")
    // Test only: JVM screenshots of the Stream screens (nothing here ships in the APK).
    testImplementation("org.robolectric:robolectric:4.17")
    testImplementation("io.github.takahirom.roborazzi:roborazzi:1.77.0")
    testImplementation("io.github.takahirom.roborazzi:roborazzi-compose:1.77.0")
    testImplementation("androidx.test:core-ktx:1.7.0")
    testImplementation("androidx.test.ext:junit-ktx:1.3.0")
}

tasks.withType<org.gradle.api.tasks.testing.Test>().configureEach {
    systemProperty("bridgey.repoRoot", rootProject.projectDir.parentFile.absolutePath)
    systemProperty("robolectric.pixelCopyRenderMode", "hardware")
    // ./gradlew :app:testDebugUnitTest -Pscreenshots=<dir> writes the screen PNGs to <dir>.
    (project.findProperty("screenshots") as String?)?.let {
        systemProperty("roborazzi.test.record", "true")
        systemProperty("bridgey.screenshots", it)
    }
}
