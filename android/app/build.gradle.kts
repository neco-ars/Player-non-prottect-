plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Постоянный ключ подписи: одна и та же подпись у всех версий, поэтому новая ставится поверх старой.
// На GitHub ключ берётся из секретов (ANDROID_KEYSTORE_BASE64, ANDROID_KEYSTORE_PASSWORD),
// локально — из signing/release.jks (папка в .gitignore). Нет ключа — подписываем отладочным.
val releaseKeystore = System.getenv("ANDROID_KEYSTORE_PATH")?.let { file(it) }
    ?: rootProject.file("../signing/release.jks")
val releasePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
    ?: rootProject.file("../signing/ANDROID_KEYSTORE_PASSWORD.txt").takeIf { it.exists() }?.readText()?.trim()
val hasReleaseKey = releaseKeystore.exists() && !releasePassword.isNullOrEmpty()

android {
    namespace = "com.musicplayer.music_player"

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = releaseKeystore
                storePassword = releasePassword
                keyAlias = "music_player"
                keyPassword = releasePassword
            }
        }
    }
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.musicplayer.music_player"
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
            signingConfig = signingConfigs.getByName(if (hasReleaseKey) "release" else "debug")
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
