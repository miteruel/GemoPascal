import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.gemmabridge.llm"
    compileSdk = 34

    defaultConfig {
        // com.google.mediapipe:tasks-genai requires API 24+
        // (https://developers.google.com/edge/mediapipe/solutions/setup_android).
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
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

// A resolvable configuration that mirrors `implementation` for tasks-genai, used ONLY to walk
// its resolved artifacts (itself + its transitive deps) in the buildFatAar task below. Kept
// separate from `implementation` so resolving it for merging doesn't affect the compile/runtime
// classpath.
val embedded: Configuration by configurations.creating {
    isCanBeResolved = true
    isCanBeConsumed = false
}

dependencies {
    // Verify this is still the latest published version before building:
    // https://mvnrepository.com/artifact/com.google.mediapipe/tasks-genai
    implementation("com.google.mediapipe:tasks-genai:0.10.35")
    embedded("com.google.mediapipe:tasks-genai:0.10.35")
}

/**
 * Why this task exists (in place of a "fat aar" Gradle plugin):
 *
 * RAD Studio has no Gradle/Maven dependency resolution of its own - it can only import a
 * single, self-contained .aar/.jar per Project Manager library entry. A normal ("thin")
 * library .aar only contains THIS module's own classes; tasks-genai and everything it pulls
 * in (LiteRT/TensorFlow Lite runtime, protobuf, Guava, native .so libraries, ...) would stay
 * as unresolved POM references that Delphi can never fetch, and the app would crash at
 * runtime with ClassNotFoundException / UnsatisfiedLinkError.
 *
 * This module originally used the `com.kezong:fat-aar` Gradle plugin to solve this (merge
 * dependencies into the output .aar). That plugin calls the Android Gradle Plugin's old
 * Transform API (`android.registerTransform`), which was REMOVED in current AGP versions -
 * applying the plugin now fails outright ("API 'android.registerTransform' is removed").
 * Rather than pin this whole project to an old, unmaintained AGP/Gradle/plugin combination,
 * this task does the same job directly: after the normal `bundleReleaseAar` task produces the
 * thin .aar, this task unpacks it, merges in the classes and native libraries from every
 * dependency in the `embedded` configuration, and re-packs the same .aar file in place.
 *
 * Deliberate limitation: only `classes.jar` contents and the .so files under `jni/arm64-v8a`
 * are merged -
 * NOT Android resources (`res/`) or manifest entries from dependencies. This is fine for
 * tasks-genai in practice (it's a computation library, not a UI one) and keeps this task
 * simple; a warning is logged if any dependency turns out to carry real resources, as a
 * signal to investigate rather than fail silently. Only arm64-v8a is merged because RAD
 * Studio's Android target only runs on real ARM64 devices (no emulator/x86_64 support) - see
 * ../README.md.
 */
tasks.register("buildFatAar") {
    group = "build"
    description = "Merges tasks-genai (and its transitive deps) into the release .aar in place, " +
        "since RAD Studio cannot resolve Maven dependencies on its own."
    dependsOn("bundleReleaseAar")

    val aarFile = layout.buildDirectory.file("outputs/aar/llminference-release.aar")
    val workDir = layout.buildDirectory.dir("fatAarWork")

    inputs.files(embedded)
    inputs.file(aarFile)
    outputs.file(aarFile)

    doLast {
        val aar = aarFile.get().asFile
        require(aar.exists()) { "Expected $aar to exist - did bundleReleaseAar run first?" }

        val work = workDir.get().asFile
        work.deleteRecursively()
        work.mkdirs()

        project.copy {
            from(zipTree(aar))
            into(work)
        }

        val classesMergeDir = File(work, "classes-merge").apply { mkdirs() }
        val classesJarFile = File(work, "classes.jar")
        if (classesJarFile.exists()) {
            project.copy {
                from(zipTree(classesJarFile))
                into(classesMergeDir)
            }
        }

        val jniDir = File(work, "jni/arm64-v8a").apply { mkdirs() }

        embedded.resolvedConfiguration.resolvedArtifacts.forEach { artifact ->
            val depFile = artifact.file
            when (depFile.extension) {
                "aar" -> {
                    val extractDir = File(work, "extract-${depFile.nameWithoutExtension}-${depFile.name.hashCode()}")
                    project.copy {
                        from(zipTree(depFile))
                        into(extractDir)
                    }
                    val innerClasses = File(extractDir, "classes.jar")
                    if (innerClasses.exists()) {
                        project.copy {
                            from(zipTree(innerClasses))
                            into(classesMergeDir)
                        }
                    }
                    val innerJni = File(extractDir, "jni/arm64-v8a")
                    if (innerJni.exists()) {
                        project.copy {
                            from(innerJni)
                            into(jniDir)
                        }
                    }
                    val innerRes = File(extractDir, "res")
                    if (innerRes.exists() && (innerRes.listFiles()?.isNotEmpty() == true)) {
                        logger.warn(
                            "buildFatAar: ${depFile.name} contains Android resources under res/ " +
                                "that are NOT being merged into the output .aar (only classes and " +
                                "arm64-v8a native libs are). If the Delphi app fails with a missing " +
                                "resource, this dependency needs manual handling."
                        )
                    }
                }
                "jar" -> {
                    project.copy {
                        from(zipTree(depFile))
                        into(classesMergeDir)
                    }
                }
                else -> {
                    // pom, module metadata, etc. - nothing to merge.
                }
            }
        }

        classesJarFile.delete()
        zipDirectory(classesMergeDir, classesJarFile)

        // classesMergeDir and every per-dependency extract-* directory were staging areas
        // only, used to build classesJarFile above - remove them so the final zip below
        // reflects a normal .aar layout (classes.jar, jni/, AndroidManifest.xml, ...)
        // instead of also including those loose working directories at the top level.
        classesMergeDir.deleteRecursively()
        work.listFiles { f -> f.isDirectory && f.name.startsWith("extract-") }
            ?.forEach { it.deleteRecursively() }

        aar.delete()
        zipDirectory(work, aar)

        logger.lifecycle("buildFatAar: merged fat .aar written to $aar")
    }
}

// Deferred to afterEvaluate: AGP registers per-variant tasks like "assembleRelease" lazily,
// only once the library plugin has finished configuring build variants - looking them up with
// tasks.named(...) at top-level script-evaluation time (before that has happened) throws
// UnknownTaskException. "assemble" itself is registered early by the base lifecycle plugin and
// would work either way, but it's kept in here too for consistency.
afterEvaluate {
    tasks.named("assemble") {
        finalizedBy("buildFatAar")
    }
    tasks.named("assembleRelease") {
        finalizedBy("buildFatAar")
    }
}

fun zipDirectory(sourceDir: File, zipFile: File) {
    zipFile.parentFile.mkdirs()
    ZipOutputStream(BufferedOutputStream(FileOutputStream(zipFile))).use { zos ->
        sourceDir.walkTopDown().filter { it.isFile }.forEach { file ->
            val entryName = file.relativeTo(sourceDir).invariantSeparatorsPath
            zos.putNextEntry(ZipEntry(entryName))
            file.inputStream().use { it.copyTo(zos) }
            zos.closeEntry()
        }
    }
}
