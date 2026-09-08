# gemma-llm-bridge (Android native module)

Kotlin Android library that wraps `com.google.mediapipe:tasks-genai` (MediaPipe LLM
Inference API, which runs Gemma via the LiteRT runtime) behind a JNI-friendly public API
(`com.gemmabridge.llm.GemmaEngine`), so it can be driven from a Delphi/FireMonkey app that
has no native Kotlin/Gradle build of its own.

See the Kotlin source (`llminference/src/main/kotlin/com/gemmabridge/llm/GemmaEngine.kt`) for
the full API contract and design rationale. Summary of the public surface:

```kotlin
object GemmaEngine {
    fun initEngine(context: Context, modelPath: String, maxTokens: Int,
                    temperature: Float, topK: Int, topP: Float): Boolean
    fun resetSession(temperature: Float, topK: Int, topP: Float): Boolean
    fun generate(prompt: String, listener: GemmaGenerationListener)
    fun cancelGenerate()
    fun closeEngine()
    fun isInitialized(): Boolean
}

interface GemmaGenerationListener {
    fun onToken(token: String)
    fun onComplete()
    fun onError(message: String)
}
```

## ⚠️ API status

`tasks-genai`'s `LlmInference`/`ProgressListener` classes are currently marked `@Deprecated`
upstream. Google's official guidance is to migrate Android projects to the newer **LiteRT-LM**
Android API (`com.google.ai.edge.litertlm:litertlm-android`, see
https://ai.google.dev/edge/litert-lm/android). This module still targets `tasks-genai` because
it is fully documented, stable, and functional today. If Google removes it, only
`GemmaEngine.kt` and the Gradle dependency need to change — the public API and the entire
Delphi side are unaffected.

## Why a "fat" .aar

RAD Studio does not do Gradle/Maven dependency resolution — it can only import a single
`.aar`/`.jar` per entry in its Project Manager "Libraries" node (and only since **RAD Studio
12.2 Athens, Release 2** — see the top-level README). `tasks-genai` has a large transitive
dependency graph (the LiteRT/TensorFlow Lite runtime, protobuf, Guava, native `.so` libraries
per ABI, etc.). If we shipped a normal "thin" `.aar`, Delphi would never pull in any of those
transitive jars/native libs and the app would crash at runtime (`ClassNotFoundException` /
`UnsatisfiedLinkError`).

**This originally used the [`com.kezong:fat-aar`](https://github.com/kezong/fat-aar-android)
Gradle plugin** to merge `tasks-genai` (and everything it pulls in) into the module's output
`.aar`. That plugin turned out to depend on the Android Gradle Plugin's old Transform API
(`android.registerTransform`), which has since been **removed** from AGP - applying the
plugin now fails immediately with `API 'android.registerTransform' is removed` against AGP
8.5.0, confirmed while building this project. Rather than pin the whole project to an old,
unmaintained AGP/Gradle/plugin combination, `llminference/build.gradle.kts` now does the same
job with a small custom task, `buildFatAar`:

1. It resolves a dedicated `embedded` configuration (declares the same `tasks-genai` dependency
   as `implementation`, just so its resolved artifacts - itself and every transitive
   dependency - can be walked).
2. After the normal `bundleReleaseAar` task produces a "thin" `.aar`, `buildFatAar` unpacks it,
   merges in every dependency's `classes.jar` contents plus the native libraries under each
   dependency's `jni/arm64-v8a/` folder, and re-packs the same `.aar` file in place.
3. It's wired in as `finalizedBy` on `assemble`/`assembleRelease` (inside `afterEvaluate`,
   since AGP registers those per-variant tasks lazily), so a normal
   `gradlew :llminference:assembleRelease` produces the finished fat `.aar` directly - no
   separate task to remember to run.

**Deliberate limitation:** only `classes.jar` contents and `jni/arm64-v8a/*.so` are merged -
not Android resources (`res/`) or manifest entries from dependencies, and only the
`arm64-v8a` ABI (RAD Studio's Android target only runs on real ARM64 devices, never an
emulator - see the top-level README - so no other ABI is needed). The task logs a warning if
any merged dependency turns out to carry real `res/` content, as a signal to investigate
rather than failing silently; in practice `tasks-genai` is a computation library with no UI
resources, so this hasn't come up.

## Prerequisites

- JDK 17+ (verified working with Temurin 21).
- Android SDK with Platform 34 and Build-Tools installed (the same SDK RAD Studio's
  PAClient/SDK Manager points at is fine to reuse, but this build is otherwise fully
  independent of RAD Studio).
- A `local.properties` file in `android-module/` (this file is machine-specific - not meant
  to be committed/shared) pointing at your Android SDK:
  ```
  sdk.dir=C\:/path/to/your/Android/sdk
  ```
  (escape the drive-letter colon as `\:` on Windows; forward slashes for the rest of the path
  avoid Java properties backslash-escaping issues).
- No Gradle install strictly required — this project ships a Gradle wrapper. **The binary
  `gradle/wrapper/gradle-wrapper.jar` is not checked into this repo** (binary files aren't
  something this assistant can author byte-for-byte reliably) — before your first build,
  either run once, from `android-module/`, with a system Gradle install:
  ```
  gradle wrapper --gradle-version 8.7
  ```
  or just download the Gradle 8.7 binary distribution from
  https://services.gradle.org/distributions/gradle-8.7-bin.zip, extract it anywhere, and
  invoke `<extracted>/bin/gradle` directly instead of `gradlew` - this is exactly how this
  module's build was verified (JDK 21, no system Gradle install, Gradle 8.7 downloaded and
  run standalone).

## Build

```
cd android-module
gradlew.bat :llminference:assembleRelease
```

(or `<path-to-gradle-8.7>\bin\gradle.bat :llminference:assembleRelease` if you don't have the
wrapper jar bootstrapped yet - see Prerequisites above)

**Verified working build**, produces a clean 13.4 MB `.aar` containing:
- `com/gemmabridge/llm/*.class` (this module's own classes)
- `com/google/mediapipe/**`, `com/google/protobuf/**`, `androidx/annotation/**`, Guava, etc.
  (tasks-genai's classes and transitive dependencies, merged by `buildFatAar`)
- `jni/arm64-v8a/libllm_inference_engine_jni.so` (the native LiteRT/TFLite runtime)

Output: `llminference/build/outputs/aar/llminference-release.aar`

This is the file you add to the Delphi project (see `../delphi-app/README.md` and the
top-level `../README.md`).

## Verify the dependency version before building

`llminference/build.gradle.kts` pins `com.google.mediapipe:tasks-genai:0.10.35` (the latest
version found at the time this project was put together). Check
https://mvnrepository.com/artifact/com.google.mediapipe/tasks-genai for a newer release
before building, and bump the version in `llminference/build.gradle.kts` if so.

## Testing the module in isolation (optional but recommended)

Before wiring up the Delphi side, sanity-check the `.aar` from a throwaway Android Studio
Kotlin app: add it as a local module/aar dependency, call
`GemmaEngine.initEngine(applicationContext, modelPath, 512, 0.8f, 40, 0.9f)` with a real
`.task` file pushed to the device, and confirm `generate()` streams tokens. This isolates
"is the native module correct" from "is the JNI bridge correct" when debugging later.
