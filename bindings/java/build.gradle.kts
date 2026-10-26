import org.gradle.api.tasks.testing.logging.TestExceptionFormat

// A plain Java library over libjd's C ABI. Its JNI shim, src/main/c/jd_jni.c,
// is compiled per platform by whoever ships it: android/scripts/build-libjd.sh
// for the Android app, and scripts/build-host.sh for this build's own tests,
// which therefore run on the JVM running Gradle, no emulator needed.
plugins {
    `java-library`
}

group = "com.hronro"

dependencies {
    // The package is @NullMarked, so Kotlin sees `String?` exactly where a
    // value can be null (android/ compiles with -Xjspecify-annotations=strict).
    // Annotations only.
    api("org.jspecify:jspecify:1.0.0")

    testImplementation(platform("org.junit:junit-bom:5.14.4"))
    testImplementation("org.junit.jupiter:junit-jupiter")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks.withType<JavaCompile>().configureEach {
    // Java 17's language, records included, which Android's D8 desugars down
    // to the app's minSdk. The JDK *library* calls stay within what Android 7
    // (API 24) has, though: no List.of, no java.lang.ref.Cleaner (README).
    options.release.set(17)
    options.encoding = "UTF-8"
    options.compilerArgs.addAll(listOf("-Xlint:all", "-Werror"))
}

// javac -h: the C declarations of Jni's native methods. jd_jni.c includes them
// and both native builds compile it with -Werror=missing-prototypes, so a C
// function that no longer matches its Java declaration fails the build
// instead of the first call at runtime.
val jniHeaders = layout.buildDirectory.dir("generated/jni")

tasks.compileJava {
    options.headerOutputDirectory.set(jniHeaders)
}

tasks.javadoc {
    // The docs are prose, not a @param and @return on every method: doclint
    // checks everything else (references, HTML).
    (options as StandardJavadocDocletOptions).addBooleanOption("Xdoclint:all,-missing", true)
}

// libjd and the shim, built for this machine.
val hostLibs = layout.buildDirectory.dir("host")

val buildHostLibs by tasks.registering(Exec::class) {
    description = "Builds libjd and the JNI shim for this machine, for the tests."
    dependsOn(tasks.compileJava)
    inputs.files("scripts/build-host.sh", "src/main/c/jd_jni.c")
    inputs.dir(jniHeaders)
    inputs.files(fileTree("../../core") { exclude(".zig-cache/**", "zig-out/**") })
    outputs.dir(hostLibs)
    commandLine("sh", "scripts/build-host.sh", jniHeaders.get().asFile.path, hostLibs.get().asFile.path)
}

tasks.test {
    useJUnitPlatform()
    // HotSpot's JNI checker: it reports misuse (a call made with an exception
    // pending, a wrong reference type) that a passing test would hide.
    jvmArgs("-Xcheck:jni")
    // The tests load these libraries, so rebuilt ones rerun the tests.
    inputs.files(buildHostLibs).withPropertyName("hostLibs")
    systemProperty("java.library.path", hostLibs.get().asFile.path)
    testLogging {
        events("failed")
        exceptionFormat = TestExceptionFormat.FULL
    }
}
