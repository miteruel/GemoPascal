/*
 * Copyright (C) 2026 Antonio Alcázar Ruiz (MiTeruel) <mrgarciagarcia@gmail.com>
 * Part of the PluTony project. Licensed under the GNU GPL v3.0 or later;
 * see LICENSE for the full text.
 */

package com.gemmabridge.llm

/**
 * Callback interface exposed across the JNI boundary.
 *
 * Deliberately narrower than MediaPipe's own generic `ProgressListener<String>`: JNI method
 * resolution from Delphi (GetMethodID with an explicit signature string) is far simpler and
 * more robust against parameterized/generic types, so [GemmaEngine] adapts MediaPipe's
 * listener internally and only ever calls back through this plain, JNI-friendly interface
 * (String/primitive parameters only, no generics, no coroutines).
 *
 * Delphi implements this by declaring a matching `JGemmaGenerationListener` interface with
 * `[JavaSignature('com/gemmabridge/llm/GemmaGenerationListener')]` and a class descending
 * from `TJavaLocal` that implements it. See GemmaEngineBridge.pas on the Delphi side.
 *
 * All three methods are invoked on a MediaPipe-managed background thread, never the calling
 * thread and never the Android main thread. The Delphi-side implementation MUST marshal to
 * the main thread (TThread.Queue) before touching any FMX UI control.
 */
interface GemmaGenerationListener {
    /** Called one or more times as new output text becomes available. */
    fun onToken(token: String)

    /** Called exactly once after the last [onToken], on successful completion. */
    fun onComplete()

    /**
     * Called at most once instead of [onComplete] if generation fails. [message] is a
     * human-readable diagnostic (exception message), safe to show to the user or log.
     */
    fun onError(message: String)
}
