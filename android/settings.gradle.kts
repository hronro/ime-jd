pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "JdIME"
include(":app")

// The engine's Java binding (../bindings/java) is a build of its own; including
// it compiles the app's com.hronro:jd dependency from its sources.
includeBuild("../bindings/java") {
    name = "jd"
    dependencySubstitution {
        substitute(module("com.hronro:jd")).using(project(":"))
    }
}
