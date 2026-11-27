// The Android glue (AAR): the device key in the Android Keystore, the values in SharedPreferences, live sessions from
// the activities' lifecycle, notifications with their vibration channels and buttons, crashes and ANRs, the icon switch,
// the full-screen block of a stopped phone and of a required update. No Firebase or Play library: the fcm and play
// modules (or the app's own code) hand it what they give.
plugins {
    id("com.android.library")
    kotlin("android")
    `maven-publish`
}

android {
    namespace = "com.drsocial.sdk.android"
    compileSdk = 35

    defaultConfig {
        minSdk = 26
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
    }

    publishing {
        singleVariant("release") { withSourcesJar() }
    }
}

kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11) }
}

dependencies {
    api(project(":core"))
    implementation("androidx.core:core-ktx:1.16.0")

    testImplementation(kotlin("test"))
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.16.1")
    // Maven Central limits downloads of 1.0.18 per address; 1.0.17 is the same native runtime one release back.
    testImplementation("org.robolectric:nativeruntime-dist-compat") { version { strictly("1.0.17") } }
    testImplementation("androidx.test:core:1.7.0")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
}

afterEvaluate {
    publishing {
        publications {
            create<MavenPublication>("release") {
                from(components["release"])
                artifactId = "drsocial-sdk-android"
            }
        }
    }
}
