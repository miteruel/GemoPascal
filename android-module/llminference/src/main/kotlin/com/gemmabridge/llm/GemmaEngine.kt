/*
 * Copyright (C) 2026 Antonio Alcázar Ruiz (MiTeruel) <mrgarciagarcia@gmail.com>
 * Part of the PluTony project. Licensed under the GNU GPL v3.0 or later;
 * see LICENSE for the full text.
 */

package com.gemmabridge.llm

import android.content.Context
import com.google.common.util.concurrent.MoreExecutors
import com.google.mediapipe.tasks.genai.llminference.LlmInference
import com.google.mediapipe.tasks.genai.llminference.LlmInference.LlmInferenceOptions
import com.google.mediapipe.tasks.genai.llminference.LlmInferenceSession
import com.google.mediapipe.tasks.genai.llminference.LlmInferenceSession.LlmInferenceSessionOptions
import com.google.mediapipe.tasks.genai.llminference.ProgressListener

/**
 * Minimal, JNI-friendly facade over the MediaPipe LLM Inference API
 * (`com.google.mediapipe:tasks-genai`, which runs Gemma via the LiteRT runtime).
 *
 * NOTE on API status: as of this writing, `tasks-genai`'s `LlmInference`/`ProgressListener`
 * classes are marked `@Deprecated` upstream — Google's current guidance is to migrate to the
 * newer LiteRT-LM Android API (`com.google.ai.edge.litertlm:litertlm-android`). This module
 * still targets tasks-genai because it is the API this project was scoped against and it
 * remains functional; if/when tasks-genai is removed upstream, only this file and its Gradle
 * dependency need to change — the public surface (GemmaEngine / GemmaGenerationListener) and
 * everything on the Delphi side stay the same.
 *
 * Design notes (JNI-facing contract):
 *  - Every public member is `@JvmStatic` on a Kotlin `object`: from Delphi this means a
 *    single global class `com/gemmabridge/llm/GemmaEngine` with static methods, reachable via
 *    `TJNIResolver.GetJNIEnv.GetStaticMethodID` — no `NewObject`/instance juggling needed.
 *  - Only primitives, `String`, and the single-purpose [GemmaGenerationListener] interface
 *    cross the boundary. No generics, no Kotlin coroutines/suspend functions, no data classes.
 *  - `modelPath` is an absolute filesystem path. Model download, storage location, and hash
 *    verification are handled entirely on the Delphi side (see TModelDownloader in the FMX
 *    app) — this keeps the native module simple and keeps all networking/UI-progress logic in
 *    one place (Delphi) instead of having to expose a second, download-progress-shaped JNI
 *    callback from Kotlin. This was a deliberate simplicity trade-off; revisit only if a
 *    future requirement needs the download to survive the Delphi process being killed.
 *  - The engine (model weights) and the session (conversation history + sampling params) are
 *    kept as two separate MediaPipe objects internally, per the current recommended API
 *    pattern, but only ONE session is ever active at a time from this facade's point of view.
 *    [resetSession] recreates just the session (cheap: no model reload), which is what backs
 *    the app's "restart conversation" button.
 */
object GemmaEngine {

    private const val TAG = "GemmaEngine"

    @Volatile
    private var llmInference: LlmInference? = null

    @Volatile
    private var session: LlmInferenceSession? = null

    // Remembered so a GENERATION-time GPU failure (see handleGenerationFailure) can trigger a
    // full engine rebuild on CPU without requiring the Delphi side to call initEngine again.
    @Volatile private var appContext: Context? = null
    @Volatile private var currentModelPath: String? = null
    @Volatile private var currentMaxTokens: Int = 512
    @Volatile private var currentTemperature: Float = 0.8f
    @Volatile private var currentTopK: Int = 40
    @Volatile private var currentTopP: Float = 0.9f

    // Set once a generation-time GPU failure forces a CPU rebuild, so we don't keep retrying
    // GPU (which would just fail the same way again) for the rest of this process's lifetime.
    @Volatile private var forcedCpuAfterGpuFailure: Boolean = false

    // User's explicit preference, passed in via initEngine's useGpu parameter. Defaults to
    // false (CPU) at the type level, but initEngine always sets this explicitly - Delphi's UI
    // has its own default (unchecked = CPU) that drives this. Kept separate from
    // forcedCpuAfterGpuFailure so re-loading the engine always re-honors the user's checkbox
    // rather than being stuck on CPU forever after one earlier GPU failure this process.
    @Volatile private var allowGpu: Boolean = false

    /**
     * Loads the model at [modelPath] and prepares a fresh conversation session.
     *
     * If [useGpu] is true, tries the GPU delegate first and transparently falls back to CPU if
     * GPU initialization throws (MediaPipe surfaces delegate failures as a runtime
     * `MediaPipeException` from `LlmInference.createFromOptions`, not as a return value). If
     * [useGpu] is false, CPU is used directly - GPU is never attempted. CPU is the more
     * reliable choice on devices where the GPU delegate initializes fine but fails during
     * actual inference (observed in practice - see [handleGenerationFailure]), so the Delphi
     * side defaults its "Use GPU" checkbox to off.
     *
     * Safe to call again to reload with a different model/config: any previously loaded
     * engine/session is closed first.
     *
     * @return true on success. On failure, [onError] via a subsequent [generate] call is NOT
     *   raised (there is no listener yet at this point) — the boolean return is the only
     *   signal; the Delphi caller is expected to show a generic "failed to load model" error.
     */
    @JvmStatic
    @Synchronized
    fun initEngine(
        context: Context,
        modelPath: String,
        maxTokens: Int,
        temperature: Float,
        topK: Int,
        topP: Float,
        useGpu: Boolean,
    ): Boolean {
        closeEngineInternal()
        appContext = context.applicationContext
        currentModelPath = modelPath
        currentMaxTokens = maxTokens
        currentTemperature = temperature
        currentTopK = topK
        currentTopP = topP
        allowGpu = useGpu
        forcedCpuAfterGpuFailure = false
        return try {
            val engine = createEngineWithFallback(context, modelPath, maxTokens, topK)
            val newSession = createSession(engine, temperature, topK, topP)
            llmInference = engine
            session = newSession
            true
        } catch (t: Throwable) {
            closeEngineInternal()
            false
        }
    }

    private fun createEngineWithFallback(
        context: Context,
        modelPath: String,
        maxTokens: Int,
        topK: Int,
    ): LlmInference {
        if (!allowGpu || forcedCpuAfterGpuFailure) {
            return createEngine(context, modelPath, maxTokens, topK, LlmInference.Backend.CPU)
        }
        return try {
            createEngine(context, modelPath, maxTokens, topK, LlmInference.Backend.GPU)
        } catch (gpuFailure: Throwable) {
            // GPU delegate init (driver/OOM/unsupported-op) failed - retry on CPU.
            createEngine(context, modelPath, maxTokens, topK, LlmInference.Backend.CPU)
        }
    }

    private fun createEngine(
        context: Context,
        modelPath: String,
        maxTokens: Int,
        topK: Int,
        backend: LlmInference.Backend,
    ): LlmInference {
        val options = LlmInferenceOptions.builder()
            .setModelPath(modelPath)
            .setMaxTokens(maxTokens)
            .setMaxTopK(topK)
            .setPreferredBackend(backend)
            .build()
        return LlmInference.createFromOptions(context, options)
    }

    private fun createSession(
        engine: LlmInference,
        temperature: Float,
        topK: Int,
        topP: Float,
    ): LlmInferenceSession {
        val sessionOptions = LlmInferenceSessionOptions.builder()
            .setTemperature(temperature)
            .setTopK(topK)
            .setTopP(topP)
            .build()
        return LlmInferenceSession.createFromOptions(engine, sessionOptions)
    }

    /**
     * Recreates the conversation session (clears history) without reloading the model.
     * Backs the app's "restart conversation" button. Returns false if no engine is currently
     * loaded (call [initEngine] first).
     *
     * Defensive: cancels any in-flight generateResponseAsync on the current session before
     * closing it. The Delphi side is expected to never call this while FGenerating is true
     * (see MainForm.pas's ResetEngineSessionAsync), but this is cheap insurance against
     * closing a session out from under an active native call, which could otherwise hang or
     * crash rather than fail cleanly.
     */
    @JvmStatic
    @Synchronized
    fun resetSession(temperature: Float, topK: Int, topP: Float): Boolean {
        val engine = llmInference ?: return false
        return try {
            try {
                session?.cancelGenerateResponseAsync()
            } catch (t: Throwable) {
                // Nothing in-flight, or already closing - safe to ignore.
            }
            session?.close()
            session = createSession(engine, temperature, topK, topP)
            true
        } catch (t: Throwable) {
            session = null
            false
        }
    }

    /**
     * Streams a response to [prompt] via [listener]. Returns immediately; [listener] methods
     * are invoked asynchronously on a MediaPipe worker thread (never the calling thread).
     *
     * If no engine/session is loaded, calls [GemmaGenerationListener.onError] synchronously
     * on the calling thread instead (cheap precondition failure, no need to hop threads).
     *
     * IMPORTANT: MediaPipe's `ProgressListener` has no error callback - if native inference
     * fails mid-generation, `run()` is simply never called again, which silently hangs the
     * caller forever (observed in practice: a GPU/ML_DRIFT_CL delegate can initialize
     * successfully at engine-creation time but still fail at *invoke* time on some devices,
     * logged natively as "Node number N (ML_DRIFT_CL) failed to invoke" / "Please create a
     * new Session and start over"). To catch that, this also watches the `ListenableFuture`
     * `generateResponseAsync` returns, which DOES complete exceptionally on such failures.
     */
    @JvmStatic
    fun generate(prompt: String, listener: GemmaGenerationListener) {
        val activeSession = session
        if (activeSession == null) {
            listener.onError("Engine not initialized. Call initEngine() first.")
            return
        }
        try {
            activeSession.addQueryChunk(prompt)
            val future = activeSession.generateResponseAsync(object : ProgressListener<String> {
                override fun run(partialResult: String, done: Boolean) {
                    // `partialResult` is the incremental text chunk to append, matching the
                    // official MediaPipe sample app's accumulation pattern (not the full
                    // text-so-far) - confirmed against the LLM Inference sample's usage.
                    if (partialResult.isNotEmpty()) {
                        listener.onToken(partialResult)
                    }
                    if (done) {
                        listener.onComplete()
                    }
                }
            })
            future.addListener(
                {
                    try {
                        future.get()
                    } catch (t: Throwable) {
                        handleGenerationFailure(prompt, listener, t)
                    }
                },
                MoreExecutors.directExecutor(),
            )
        } catch (t: Throwable) {
            handleGenerationFailure(prompt, listener, t)
        }
    }

    /**
     * Called when generation fails, either synchronously (exception thrown directly) or
     * asynchronously (the `ListenableFuture` from `generateResponseAsync` completed
     * exceptionally). The first time this happens, assumes a GPU delegate invoke-time failure,
     * rebuilds the whole engine on the CPU backend (a session-only rebuild would stay bound to
     * the same GPU-backed engine and fail again identically), and asks the caller to resend -
     * automatically retrying the same prompt here would risk recursing through this same
     * failure path again if CPU generation also fails for an unrelated reason.
     */
    @Synchronized
    private fun handleGenerationFailure(prompt: String, listener: GemmaGenerationListener, error: Throwable) {
        val context = appContext
        val modelPath = currentModelPath
        // Only worth rebuilding on CPU if GPU was actually in play - if the user's checkbox
        // already had GPU off, this failure has nothing to do with the delegate and a rebuild
        // would just recreate the same CPU engine for no reason.
        if (allowGpu && !forcedCpuAfterGpuFailure && context != null && modelPath != null) {
            forcedCpuAfterGpuFailure = true
            try {
                closeEngineInternal()
                val engine = createEngine(
                    context, modelPath, currentMaxTokens, currentTopK, LlmInference.Backend.CPU
                )
                val newSession = createSession(engine, currentTemperature, currentTopK, currentTopP)
                llmInference = engine
                session = newSession
                listener.onError(
                    "The GPU accelerator failed during generation, so this device has been " +
                        "switched to CPU mode (slower, but reliable). Please send your message again."
                )
                return
            } catch (rebuildFailure: Throwable) {
                closeEngineInternal()
            }
        }
        listener.onError(error.message ?: error.javaClass.simpleName)
    }

    /** Cancels an in-flight [generate] call, if any. Safe to call when idle. */
    @JvmStatic
    @Synchronized
    fun cancelGenerate() {
        try {
            session?.cancelGenerateResponseAsync()
        } catch (t: Throwable) {
            // Nothing in-flight, or session already closing - safe to ignore.
        }
    }

    /** Releases the model and all native resources. Safe to call multiple times. */
    @JvmStatic
    @Synchronized
    fun closeEngine() {
        closeEngineInternal()
    }

    private fun closeEngineInternal() {
        try {
            session?.cancelGenerateResponseAsync()
        } catch (t: Throwable) {
            // Nothing in-flight, or session already closing - safe to ignore.
        }
        try {
            session?.close()
        } catch (t: Throwable) {
            // Ignore - best-effort cleanup.
        }
        try {
            llmInference?.close()
        } catch (t: Throwable) {
            // Ignore - best-effort cleanup.
        }
        session = null
        llmInference = null
    }

    @JvmStatic
    @Synchronized
    fun isInitialized(): Boolean = llmInference != null && session != null
}
