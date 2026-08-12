allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// agora_rtc_engine's own Android module defaults its compileSdkVersion to
// 31 unless the root project provides this ext property (Groovy
// safeExtGet pattern) - without it, checkDebugAarMetadata fails because
// agora's transitive androidx deps require compileSdk 33/34+.
rootProject.extra["compileSdkVersion"] = 36

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
