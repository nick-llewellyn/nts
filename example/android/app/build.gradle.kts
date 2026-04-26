import groovy.json.JsonSlurper
import java.io.File

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Locate the on-disk Maven repository that ships inside the
// `rustls-platform-verifier-android` companion crate. The crate publishes a
// pre-built AAR (`rustls:rustls-platform-verifier`) that contains the Kotlin
// glue `org.rustls.platformverifier.CertificateVerifier` invoked over JNI by
// the Rust verifier on Android. We resolve the path by asking `cargo` for
// the resolved package metadata of the `nts_rust` crate (which transitively
// pulls in `rustls-platform-verifier-android`) and walking to the `maven/`
// directory next to its `Cargo.toml`. Done this way so that crate version
// bumps need no manual Gradle edit.
fun findRustlsPlatformVerifierMaven(): String {
    val proc = ProcessBuilder(
        "cargo",
        "metadata",
        "--format-version",
        "1",
        "--manifest-path",
        rootProject.layout.projectDirectory.file("../../rust/Cargo.toml").asFile.absolutePath,
    ).redirectErrorStream(false).start()
    val stdout = proc.inputStream.bufferedReader().readText()
    proc.waitFor()
    @Suppress("UNCHECKED_CAST")
    val json = JsonSlurper().parseText(stdout) as Map<String, Any>
    @Suppress("UNCHECKED_CAST")
    val packages = json["packages"] as List<Map<String, Any>>
    val pkg = packages.first { it["name"] == "rustls-platform-verifier-android" }
    val manifestPath = pkg["manifest_path"] as String
    return File(manifestPath).parentFile.resolve("maven").absolutePath
}

repositories {
    maven {
        url = uri(findRustlsPlatformVerifierMaven())
        // The crate ships the AAR + POM but no Maven metadata index file;
        // tell Gradle to discover artifacts directly off the filesystem.
        metadataSources { artifact() }
    }
}

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

            // R8 / shrinking is enabled to keep release APKs lean. The
            // companion ProGuard rules in `proguard-rules.pro` preserve the
            // `org.rustls.platformverifier.*` classes shipped by the
            // `rustls:rustls-platform-verifier` AAR — those are reachable
            // only via JNI lookups from the `nts` Rust crate and would
            // otherwise be dead-code-eliminated, breaking the NTS-KE TLS
            // handshake on every fresh install. See `proguard-rules.pro`
            // for the full rationale.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

dependencies {
    // Companion AAR for `rustls-platform-verifier`. Provides the Kotlin
    // glue (`org.rustls.platformverifier.*`) that the Rust crate invokes
    // over JNI to delegate X.509 chain validation to Android's
    // `X509TrustManager`. Pinned to the version that ships alongside
    // `rustls-platform-verifier 0.5.3` in our `Cargo.lock`. The `@aar`
    // classifier is required because the on-disk Maven layout produced
    // by `rustls-platform-verifier-android` only ships the AAR + POM and
    // Gradle defaults to looking for a JAR otherwise.
    implementation("rustls:rustls-platform-verifier:0.1.1@aar")
}

flutter {
    source = "../.."
}
