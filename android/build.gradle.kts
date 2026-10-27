buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath("com.android.tools.build:gradle:8.7.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.2.20")
        classpath("com.google.gms:google-services:4.4.1")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Redirects every project's build output to <repo>/build, which is where the
// Flutter tooling looks for `app/outputs/bundle/release/app-release.aab`.
//
// The eager `.get()` and `value(...)` here are load-bearing, not incidental:
//
//   * without the assignment the redirect is a silent no-op, the AAB is written
//     to `android/build/`, and the build fails with the misleading "Gradle build
//     failed to produce an .aab file ... generated under <repo>/build, but the
//     tool couldn't find it";
//   * deriving a child's directory from the property *after* re-assigning it
//     trips "Circular evaluation detected", so the base directory has to be
//     resolved to a concrete `Directory` first.
//
// Do not "simplify" this to `rootProject.layout.buildDirectory.dir("../../build")`
// or to a lazy `DirectoryProperty` chain — both forms have been tried and both
// break the build.
val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
