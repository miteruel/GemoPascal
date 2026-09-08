**🇬🇧 English** | [🇪🇸 Español](README.es.md)

# Gemma on-device chat (Delphi FMX + LiteRT/MediaPipe, Android)

Runs a Gemma model fully on-device on Android - no cloud calls for inference - from a Delphi
FireMonkey app, by wrapping Google's MediaPipe LLM Inference API (which runs the model via the
LiteRT runtime) in a small Kotlin `.aar` and driving it from Delphi over JNI.

```
┌─────────────────────────────┐        JNI        ┌───────────────────────────────────┐
│   Delphi FMX app (Android)  │◄──────────────────►│  Kotlin .aar (android-module/)     │
│   - MainForm.pas (chat UI)  │                     │  com.gemmabridge.llm.GemmaEngine   │
│   - ModelDownloader.pas     │                     │  wraps com.google.mediapipe:        │
│   - GemmaEngineBridge.pas ──┼── only JNI unit ───┼─  tasks-genai (LiteRT runtime)      │
└─────────────────────────────┘                     └───────────────────────────────────┘
```

- **`android-module/`** - Kotlin Android library, builds to a single self-contained
  (`.aar`), see [android-module/README.md](android-module/README.md).
- **`delphi-app/`** - the FMX chat app, see [delphi-app/README.md](delphi-app/README.md).

## Assumed toolchain

- **RAD Studio 12.2 Athens (Release 2) or later recommended.** Confirmed via Embarcadero's own
  release notes that direct `.aar` import in Project Manager was added in 12.2. **12.0/12.1
  also work** but require manually extracting `classes.jar` and the native `.so` libraries out
  of the `.aar` and adding them separately (jar via Project Manager, `.so` files via the
  Deployment Manager) - see the "RAD Studio 12.0 (original Athens) or 12.1" section in
  [delphi-app/README.md](delphi-app/README.md) for the exact steps. None of the Delphi source
  files change either way - this only affects how the compiled artifacts get into the APK.
- JDK 17 + Android SDK Platform 34 for building the Kotlin module.
- Target model: **Gemma 3 1B** (IT, 4-bit quantized), chosen for on-device size/RAM footprint.
  The app itself is not hard-coded to this model - any `.task` bundle compatible with the
  MediaPipe LLM Inference API works, configured via the Settings panel's URL field.

## Quick start

1. Build the native module: see [android-module/README.md](android-module/README.md) ->
   produces `llminference-release.aar`.
2. Open/create the Delphi project and wire in the `.aar`: see
   [delphi-app/README.md](delphi-app/README.md) (covers both the recommended "new blank FMX
   app + add these units" path and the provided best-effort `.dproj`).
3. Get a Gemma `.task` file from Hugging Face (`litert-community` org - gated, needs an
   account + access token) and configure its URL in the app's Settings panel. Same README,
   "Getting a Gemma .task model" section.
4. Deploy to a **real Android device** - RAD Studio's Android target does not support running
   on an emulator at all (it only builds for real ARM hardware, arm64-v8a), which conveniently
   also means you only need to worry about the arm64-v8a native libraries in step 2's manual
   path, and load the model.

## Minimum device RAM

No official Google figure was found for Gemma 3 1B / Gemma 2 2B RAM requirements under this
API. Practical guidance used throughout this project: budget the `.task` file's own size
(roughly 500 MB-1 GB for 4-bit-quantized Gemma 3 1B) plus runtime overhead for
activations/KV-cache, and treat **devices with ≤4 GB RAM as marginal** - verify on real
hardware with the exact quantization you ship before committing to a minimum-spec claim.

## Features

- Chat UI with streaming token-by-token responses, temperature/top-k/top-p/max-tokens controls.
- Model download with resume support (HTTP `Range`) and SHA-256 verification.
- **GPU/CPU backend toggle** - a "Use GPU" checkbox in Settings, **off (CPU) by default**: on
  the primary test device the GPU delegate initialized fine but failed during actual
  generation, so CPU-only is the safer default; GPU is opt-in for devices where it works.
  Whichever mode is active, a generation-time GPU failure is caught and the engine
  automatically rebuilds on CPU rather than hanging or crashing - see `GemmaEngine.kt`.
- **Conversation history** - past conversations are saved as titled JSON files
  (`Documents/conversations/*.json`) and browsable from the "History" button (list, reopen, or
  start a new one). Reopening an old conversation restores the visible transcript but **not**
  the model's own context - see the limitation below.

## Known limitations

- **Android only.** No iOS support in this version - the MediaPipe GenAI Tasks API and the
  entire JNI bridge are Android-specific; iOS would need a separate native module and a
  Swift/Objective-C bridge, which is out of scope here.
- **`com.google.mediapipe:tasks-genai` is in maintenance-only mode upstream** as of the
  research done for this project; Google's current guidance is to migrate to LiteRT-LM
  (`com.google.ai.edge.litertlm`). This project still targets tasks-genai because it's
  documented and functional today - see `android-module/README.md` for the isolation that
  makes a future migration a single-file change.
- **The Delphi `.dproj` is a hand-written, IDE-unverified skeleton** - see the warning at the
  top of `delphi-app/README.md` and prefer creating a fresh Blank Multi-Device Application in
  RAD Studio and adding the provided units to it.
- **Reopening a past conversation doesn't restore the model's context** - only the visible
  transcript. MediaPipe's `LlmInferenceSession` has no supported way to have prior turns
  replayed into its native context without re-generating them, so the model starts that
  conversation fresh. The app tells the user this when loading a past conversation.
- **Single in-flight generation** - the UI blocks sending a new prompt while one is streaming
  rather than queueing it, and also blocks History/New/Reset actions until the current
  response finishes (closing the model session mid-generation was found to hang/crash the
  native side on the test device).
- **GPU delegate fallback is best-effort**: the exact failure mode (init-time vs. invoke-time)
  and the retry-on-CPU pattern are based on direct observation on one test device plus
  community bug reports, not an official Google-documented API contract.
- Several FMX `TVertScrollBox` gotchas were found and worked around during development
  (styled controls must never be direct `Align`-ed children of a scroll box; scroll boxes must
  be recreated rather than `DeleteChildren`-and-refilled to avoid a native crash on this
  device) - see `instrucciones.md` if similar UI crashes reappear when extending the app.

## Design decisions made without asking (and why)

- **Model download/storage lives entirely in Delphi** (`ModelDownloader.pas`), not in the
  Kotlin module - keeps the native module free of networking/permission concerns and keeps
  all download-progress UI in one place. `GemmaEngine.initEngine` only ever receives an
  absolute local file path.
- **The JNI listener interface is a plain 3-method callback** (`onToken`/`onComplete`/
  `onError`, String/void only) rather than exposing MediaPipe's generic `ProgressListener<T>`
  directly - generics are needlessly painful to resolve via JNI method IDs from Delphi.
- **`GemmaEngine` is a Kotlin `object` (static methods only)**, not a class you `NewObject`
  from JNI, wrapped Delphi-side using the `TJavaGenericImport<...>.JavaClass` pattern Delphi's
  own RTL uses for other static-only Java classes - simpler than manual instance lifecycle
  management over JNI for a natural singleton.
