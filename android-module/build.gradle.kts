// Root build file. Individual module configuration lives in llminference/build.gradle.kts.
//
// tasks-genai and its transitive dependencies (TensorFlow Lite / LiteRT runtime, protobuf,
// etc.) get merged into llminference's output .aar by a plain custom Gradle task
// (`buildFatAar` in llminference/build.gradle.kts), not by a third-party "fat aar" plugin -
// see that file for why (the obvious plugin choice, com.kezong:fat-aar, turned out to depend
// on an Android Gradle Plugin API that has since been removed).
buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath("com.android.tools.build:gradle:8.5.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:1.9.24")
    }
}
