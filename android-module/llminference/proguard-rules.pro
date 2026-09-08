# This module is consumed as a pre-built .aar by a non-Gradle (Delphi/JNI) build, so we
# never want R8/ProGuard renaming the public surface Delphi resolves method IDs against
# at runtime via JNI, nor the MediaPipe/TFLite classes it calls into internally.
-keep class com.gemmabridge.llm.** { *; }
-keep class com.google.mediapipe.** { *; }
-keep class com.google.protobuf.** { *; }
-dontwarn com.google.mediapipe.**
