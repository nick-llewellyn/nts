import com.android.build.api.dsl.ApplicationExtension
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// AGP 9.0 ships built-in Kotlin support and applies it automatically; the
// standalone `kotlin-android` plugin is incompatible with AGP 9's
// built-in Kotlin, so it is only applied on AGP < 9. See NTS-161 (the
// same gate on the `nts` plugin's own `android/build.gradle.kts`).
val agpMajor = com.android.Version.ANDROID_GRADLE_PLUGIN_VERSION.substringBefore('.').toInt()
if (agpMajor < 9) {
    pluginManager.apply("kotlin-android")
}

// The `rustls:rustls-platform-verifier` AAR Maven repo, the AAR
// `implementation` dep, and the matching ProGuard / R8 keep rules are
// all contributed by the `nts` plugin's own Android module
// (`<plugin>/android/build.gradle.kts` + `consumer-rules.pro`). Nothing
// more is needed here: the plugin loader picks them up automatically
// from the path `nts: { path: ../ }` declaration in `example/pubspec.yaml`.

// `android { ... }` is the classic extension-function accessor; it is
// deprecated once `android.newDsl=true` (the AGP 9 default). See
// NTS-161.
configure<ApplicationExtension> {
    namespace = "com.nts.example"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
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

// `android.kotlinOptions { jvmTarget = ... }` had its deprecation level
// raised to ERROR in Kotlin 2.2.0. `kotlin.compilerOptions` is the
// replacement, but only applies when the standalone Kotlin plugin is
// present -- on AGP 9's built-in Kotlin, `jvmTarget` already defaults
// from `compileOptions.targetCompatibility` above. See NTS-161.
plugins.withId("kotlin-android") {
    configure<KotlinAndroidProjectExtension> {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_17)
        }
    }
}

flutter {
    source = "../.."
}
