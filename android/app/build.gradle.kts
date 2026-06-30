import org.gradle.api.tasks.Exec

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.hronro.imejd"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.hronro.imejd"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        // Placeholder; CI can override from core/build.zig.zon's .version (like macOS/iOS).
        versionName = "0.2.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        ndk {
            // MVP: real phones (arm64-v8a) + emulator (x86_64). Add armeabi-v7a / x86 later.
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
}

// --- Native build ----------------------------------------------------------
// Mirrors ios/scripts/build-libjd.sh: cross-compile the Zig core per ABI and
// link the C JNI shim against it with the NDK clang, dropping libjd.so +
// libjdjni.so into src/main/jniLibs/<abi>/. No CMake/externalNativeBuild — the
// shim links the *dynamic* libjd.so (the static .a uses local-exec TLS that ld
// rejects in a shared object), so a plain script is enough and Gradle just
// packages the resulting jniLibs.
val buildLibjd by tasks.registering(Exec::class) {
    workingDir = rootProject.projectDir
    commandLine("bash", "scripts/build-libjd.sh", "arm64-v8a", "x86_64")
}

tasks.named("preBuild") {
    dependsOn(buildLibjd)
}
