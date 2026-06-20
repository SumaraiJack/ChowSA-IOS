import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── Release keystore (gitignored) ────────────────────────────────────────────
// Drop a key.properties file alongside android/app/ with the following keys
// to produce a Play-Store-signed AAB:
//
//   storeFile=../keystores/chowsa-release.jks
//   storePassword=••••
//   keyAlias=chowsa
//   keyPassword=••••
//
// If the file is missing (e.g. during local dev) we fall back to the debug
// keystore so `flutter run` keeps working — production CI MUST supply
// key.properties.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "za.co.chowsa.app"

    // SDK 36 required — geolocator, image_picker, shared_preferences, app_links,
    // flutter_plugin_android_lifecycle, and url_launcher all compile against SDK 36.
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // Production Play-Store package id. Google Play permanently blocks
        // any applicationId starting with `com.example.*`, so this had to
        // change before the first AAB upload. Once published it can never
        // be changed again — locking it down here at the source.
        applicationId = "za.co.chowsa.app"
        minSdk = flutter.minSdkVersion                         // Android 6.0 — covers ~99% of SA devices.
        targetSdk = 36                      // Latest, required by Play from Aug 2025.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }

        // ── AdMob App ID — injected into AndroidManifest at build time ────
        //
        // Mirrors lib/config/env_config.dart's `isProduction` switch on the
        // Gradle side so the native AdMob SDK init reads the matching ID.
        // The Flutter Gradle plugin forwards `--dart-define=FOO=bar` to
        // Gradle as `dart-defines` base64-encoded blobs, so the simplest
        // and most reliable bridge is a plain Gradle `-P` property that
        // the release command sets alongside the dart-define:
        //
        //   flutter build appbundle --release \
        //       --dart-define=IS_PRODUCTION=true \
        //       -PIS_PRODUCTION=true
        //
        // Default is the AdMob Android Test App ID — safe for local dev,
        // CI, and any accidental release that forgot the flag.
        val isProductionBuild =
            (project.findProperty("IS_PRODUCTION") as String?)?.toBoolean() ?: false
        val admobAppId = if (isProductionBuild) {
            // Real ChowSA AdMob App ID. KEEP IN SYNC with EnvConfig._kProdAdMobAppId.
            "ca-app-pub-4825357853521156~9984542080"
        } else {
            // Google's official Android Test App ID — always-on test ads.
            "ca-app-pub-3940256099942544~3347511713"
        }
        manifestPlaceholders["admobAppId"] = admobAppId
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias      = keystoreProperties.getProperty("keyAlias")
                keyPassword   = keystoreProperties.getProperty("keyPassword")
                storeFile     = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // Production builds shrink + obfuscate code with R8 so the
            // delivered AAB is smaller and harder to reverse-engineer.
            // ProGuard rules live in proguard-rules.pro alongside this file.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            // Use the real release keystore when present; otherwise fall back
            // to the debug signature so local `flutter run --release` still
            // works. CI MUST supply key.properties before invoking `flutter
            // build appbundle`.
            signingConfig = if (hasReleaseKeystore)
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    // Backports java.time APIs to API 21-25 (used by supabase_flutter + google_generative_ai).
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
