import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing comes from android/key.properties (never committed) or the
// equivalent ELEPHANT_* environment variables in CI. Without either, release
// builds are unsigned, which is what F-Droid expects: it signs with its own key.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

fun signingValue(key: String, env: String): String? =
    keystoreProperties.getProperty(key) ?: System.getenv(env)

val releaseStoreFile = signingValue("storeFile", "ELEPHANT_KEYSTORE_PATH")

// Keep Google Play libraries out of the dependency graph (F-Droid inclusion policy).
configurations.all {
    exclude(group = "com.google.android.play", module = "core")
    exclude(group = "com.google.android.play", module = "core-common")
    exclude(group = "com.google.android.play", module = "feature-delivery")
    exclude(group = "com.google.android.play", module = "app-update")
    exclude(group = "com.google.android.play", module = "tasks")
    exclude(group = "com.google.android.play", module = "split-install")
}

android {
    namespace = "in.commandlinecoding.elephant"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        if (releaseStoreFile != null) {
            create("release") {
                storeFile = file(releaseStoreFile)
                storePassword = signingValue("storePassword", "ELEPHANT_KEYSTORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "ELEPHANT_KEY_ALIAS")
                keyPassword = signingValue("keyPassword", "ELEPHANT_KEY_PASSWORD")
            }
        }
    }

    // AGP otherwise embeds a dependency report encrypted with Google's key,
    // which F-Droid's scanner rejects and which breaks reproducible builds.
    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }

    defaultConfig {
        applicationId = "in.commandlinecoding.elephant"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        getByName("release") {
            // Kept on one line: F-Droid's build strips `signingConfig` lines.
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug").takeIf { System.getenv("ELEPHANT_ALLOW_DEBUG_SIGNING") == "true" }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}

tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

// Per-ABI versionCodes come from Flutter itself with --split-per-abi:
// 1000 + base (armeabi-v7a), 2000 + base (arm64-v8a), 4000 + base (x86_64).
// fdroid/in.commandlinecoding.elephant.yml depends on this scheme.

dependencies {}