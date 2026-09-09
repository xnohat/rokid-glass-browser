import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keyPropertiesFile = rootProject.file("key.properties")
val keyProperties = Properties()
val hasKeyProperties = keyPropertiesFile.exists()
if (hasKeyProperties) {
    keyProperties.load(FileInputStream(keyPropertiesFile))
}

android {
    namespace = "com.snorlytics.browser_glasses"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.snorlytics.browser_glasses"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = 28 // targetSdk 28 allows WifiManager.setWifiEnabled() on Android 10+
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // libnode.so (Node 18.20.4 from JaneaSystems/nodejs-mobile v18.20.4, arm64-v8a)
        // is extracted from the official release zip and bundled in the APK automatically.
        // SHA-256: bd7321eaa1a7602fbe0bb87302df2d79d87835cf4363fbdd17c350dbb485c2af
        // Node 18 LTS support extended to April 2025 — see docs/NODE_RUNTIME.md.
        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    lint {
        disable += "ExpiredTargetSdkVersion"
    }

    signingConfigs {
        if (hasKeyProperties) {
            create("release") {
                keyAlias = keyProperties["keyAlias"] as String
                keyPassword = keyProperties["keyPassword"] as String
                storeFile = file(keyProperties["storeFile"] as String)
                storePassword = keyProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasKeyProperties)
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
        }
    }

    // Build the thin JNI shim (node_runner.so) that links against the
    // prebuilt libnode.so (Node 12.19.0 / nodejs-mobile v0.3.3, arm64-v8a).
    // The CMakeLists.txt also marks libnode.so as an IMPORTED target so
    // Gradle knows to package it into the APK alongside node_runner.so.
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    // Restrict CMake to arm64-v8a only (libnode.so is arm64-v8a only).
    defaultConfig {
        externalNativeBuild {
            cmake {
                abiFilters("arm64-v8a")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.webkit:webkit:1.9.0")
}
