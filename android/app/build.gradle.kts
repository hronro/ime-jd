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
        // Placeholders; release CI overrides both from the version tag
        // (which create-release verifies against core/build.zig.zon):
        //   ./gradlew assembleRelease -PjdVersionName=X.Y.Z -PjdVersionCode=N
        versionCode = (findProperty("jdVersionCode") as String?)?.toInt() ?: 1
        versionName = (findProperty("jdVersionName") as String?) ?: "0.0.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    // One APK per ABI, shipped as separate downloads like every other
    // platform's per-arch packages. This list must stay in sync with the
    // ABIs the buildLibjd task below passes to build-libjd.sh.
    // MVP: real phones (arm64-v8a) + emulator (x86_64). Add armeabi-v7a / x86 later.
    splits {
        abi {
            isEnable = true
            reset()
            include("arm64-v8a", "x86_64")
            isUniversalApk = false
        }
    }

    buildTypes {
        release {
            // R8 strips the ~90% of appcompat/kotlin-stdlib this app never
            // calls (dex 5.5 MB -> 0.6 MB). Safe ONLY together with
            // proguard-rules.pro: QuerySnapshot/Candidate are constructed from
            // C code (FindClass in jd_jni.c), a reference R8 cannot see.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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
