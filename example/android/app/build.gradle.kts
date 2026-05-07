plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The `rustls:rustls-platform-verifier` AAR Maven repo, the AAR
// `implementation` dep, and the matching ProGuard / R8 keep rules are
// all contributed by the `nts` plugin's own Android module
// (`<plugin>/android/build.gradle.kts` + `consumer-rules.pro`). Nothing
// more is needed here: the plugin loader picks them up automatically
// from the path `nts: { path: ../ }` declaration in `example/pubspec.yaml`.

android {
    namespace = "com.nts.example"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.nts.example"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")

            // R8 / shrinking is enabled to keep release APKs lean. Keep
            // rules covering the `rustls-platform-verifier` AAR
            // (`org.rustls.platformverifier.**`) and the JNI shim
            // (`com.nllewellyn.nts.PlatformInit`) are auto-merged from
            // the `nts` plugin's `consumer-rules.pro`, so this app's
            // `proguard-rules.pro` only needs to carry rules specific
            // to the example itself (currently none beyond the default
            // optimize file).
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}
