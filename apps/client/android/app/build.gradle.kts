plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "top.frewily.rainclient"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "top.frewily.rainclient.dev"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// Both JNI libraries default to API 35. Compile their source against the already
// installed project SDK; its minimum runtime API remains unchanged.
val sharedCompileSdk = flutter.compileSdkVersion
val existingCmakeVersion = providers.gradleProperty("rainclient.cmakeVersion").orNull
rootProject.subprojects {
    if (name in setOf("jni", "jni_flutter")) {
        val libraryProject = this
        pluginManager.withPlugin("com.android.library") {
            val components = libraryProject.extensions.getByType<
                com.android.build.api.variant.LibraryAndroidComponentsExtension
            >()
            components.finalizeDsl { library ->
                library.compileSdk = sharedCompileSdk
                if (libraryProject.name == "jni" && existingCmakeVersion != null) {
                    library.externalNativeBuild.cmake.version = existingCmakeVersion
                }
            }
        }
    }
}
