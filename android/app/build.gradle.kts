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

android {
    namespace = "dev.bridgey.android"
    compileSdk = 36

    defaultConfig {
        applicationId = editionValue("EDITION_APP_ID")
        minSdk = 26
        targetSdk = 36
        versionCode = editionVersionCode
        versionName = editionVersionName
        buildConfigField("String", "UPDATE_FEED_BASE_URL", "\"${editionValue("UPDATE_FEED_BASE_URL")}\"")
        buildConfigField("String", "UPDATE_ASSET_URL_PREFIX", "\"${editionValue("UPDATE_ASSET_URL_PREFIX")}\"")
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

    buildFeatures {
        compose = true
        buildConfig = true
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
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
    testImplementation("junit:junit:4.13.2")
    // Real org.json for JVM unit tests of the update feed parser (android.jar only has stubs).
    testImplementation("org.json:json:20240303")
}

tasks.withType<org.gradle.api.tasks.testing.Test>().configureEach {
    systemProperty("bridgey.repoRoot", rootProject.projectDir.parentFile.absolutePath)
}
