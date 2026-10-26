// The jd Java binding: a build of its own (`./gradlew test` here), which
// android/ also includes, so the app's com.hronro:jd dependency is compiled
// from these sources (android/settings.gradle.kts).
rootProject.name = "jd"

dependencyResolutionManagement {
    repositories {
        mavenCentral()
    }
}
