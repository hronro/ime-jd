import org.gradle.api.tasks.Exec

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// In-app updater (update/): a daily check of the GitHub release feed plus
// download-and-install of the new APK. It needs INTERNET and
// REQUEST_INSTALL_PACKAGES, which an app-store build must not carry — stores
// update apps themselves, and Play rejects the install permission — so the
// updater is a build flag, OFF by default (android/gradle.properties):
//   ./gradlew assembleRelease -PjdAutoUpdate=true     # what release.yml ships
// Off, the APK is the store build exactly as before the updater existed: no
// permissions, no receiver (src/autoUpdate/AndroidManifest.xml is not
// merged), and R8 strips update/ behind the false BuildConfig.AUTO_UPDATE.
val autoUpdate = (findProperty("jdAutoUpdate") as String?)?.toBoolean() ?: false

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
        // The code-side switch for the updater (see `autoUpdate` above).
        buildConfigField("boolean", "AUTO_UPDATE", autoUpdate.toString())
    }

    buildFeatures {
        buildConfig = true
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
            // calls (dex 5.5 MB -> 0.6 MB). The classes the JNI shim builds
            // from C, out of R8's sight, are kept by rules the jd binding's jar
            // carries (bindings/java: META-INF/proguard/jd.pro), which R8
            // reads on its own: the app needs no rules of its own.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
        // The jd binding marks what can be null with JSpecify annotations.
        // Strict makes Kotlin 2.0 type those values `T?` instead of warning.
        freeCompilerArgs += "-Xjspecify-annotations=strict"
    }
}

// The manifest side of the updater flag: its permissions + receiver are a
// separate manifest fragment that only self-updating builds merge in.
androidComponents {
    onVariants { variant ->
        if (autoUpdate) {
            variant.sources.manifests.addStaticManifestFile("src/autoUpdate/AndroidManifest.xml")
        }
    }
}

dependencies {
    // The engine: the Java binding over libjd (../bindings/java), compiled
    // from source as an included build (settings.gradle.kts).
    implementation("com.hronro:jd")
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    // Container-app widgets only (MaterialButton, M3 theming); the IME draws
    // itself. Pinned to 1.12: 1.13+ inflates the release APK by ~0.7 MB of
    // resource table alone (expressive-token style graph is reachable from the
    // theme, so shrinkResources cannot drop it) and drags in more transitive
    // deps. 1.12's lack of a materialButtonTonalStyle attr is worked around in
    // MainActivity with two theme colors.
    implementation("com.google.android.material:material:1.12.0")
    // The user dictionary's list (app/UserDictActivity): the versions material
    // 1.12 already resolves, declared because the screen uses them directly.
    implementation("androidx.recyclerview:recyclerview:1.1.0")
    implementation("androidx.coordinatorlayout:coordinatorlayout:1.1.0")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    // JVM unit tests (src/test): the update feed model. The unit-test
    // android.jar stubs org.json, so the real implementation rides along.
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}

// --- Native build ----------------------------------------------------------
// Mirrors ios/scripts/build-libjd.sh: cross-compile the Zig core per ABI and
// link the jd binding's C JNI shim (../bindings/java/src/main/c/jd_jni.c)
// against it with the NDK clang, dropping libjd.so + libjdjni.so into
// src/main/jniLibs/<abi>/. No CMake/externalNativeBuild — the shim links the
// *dynamic* libjd.so (the static .a uses local-exec TLS that ld rejects in a
// shared object), so a plain script is enough and Gradle just packages the
// resulting jniLibs. The shim is compiled against the C declarations javac -h
// writes as the binding compiles, hence the binding's compileJava first.
val buildLibjd by tasks.registering(Exec::class) {
    dependsOn(gradle.includedBuild("jd").task(":compileJava"))
    workingDir = rootProject.projectDir
    commandLine("bash", "scripts/build-libjd.sh", "arm64-v8a", "x86_64")
}

tasks.named("preBuild") {
    dependsOn(buildLibjd)
}
