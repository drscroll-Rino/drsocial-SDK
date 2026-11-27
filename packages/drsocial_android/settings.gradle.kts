pluginManagement {
    repositories {
        google()
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "drsocial-android"

// core: pure Kotlin (API v1, every rule, no Android) · android: the Android glue (AAR) · fcm: Firebase Cloud Messaging
// service · play: Google Play's install referrer, in-app review and Play Integrity. Huawei Push Kit: see README.
include(":core", ":android", ":fcm", ":play")
