# GemmaChatApp (Delphi FMX, Android)

Chat UI that drives the on-device Gemma model through the native module in `../android-module`
via JNI. See `GemmaEngineBridge.pas` for the JNI layer (the only unit that imports any
`Androidapi.JNI.*` unit) and `MainForm.pas` for the UI (no JNI dependency at all).

`ModelDownloader.pas` resumes an interrupted model download automatically (HTTP `Range`
requests) instead of restarting a multi-hundred-MB file from zero every time - see the comment
block at the top of that file for how.

`ConversationStore.pas` persists each chat as a titled JSON file under
`Documents/conversations/`, browsable from the "History" toolbar button. **Reopening a past
conversation restores the visible message log only** - the underlying MediaPipe session has no
supported way to have prior turns replayed into its native context, so the model starts that
conversation fresh. The UI tells the user this when they load a past conversation.

`FilePicker.pas` opens Android's native Storage Access Framework picker (a "Browse..." button
in Settings) so you can point the app at a `.task` file already on the device (e.g. one you
downloaded straight from a browser into Downloads) instead of re-downloading it through the
app. It copies the picked file into the app's private storage - it does **not** validate the
format, so picking anything other than a real MediaPipe `.task` bundle (a `.gguf` file, for
instance - that's `llama.cpp`'s format, not compatible with this app's engine at all) will
copy fine but fail when you tap "Load engine".

The **Send** button doubles as **Stop** while a response is streaming - tapping it cancels
generation (`GemmaEngineBridge.CancelGenerate`), keeping whatever partial text had already
streamed in. Each conversation row in History has its own **Delete** button (with a confirm
dialog) backed by `TConversationStore.DeleteConversation`.

The Settings panel's "Use GPU" checkbox is **off by default** - `GemmaEngine.kt` only attempts
the GPU delegate when explicitly asked to, since it demonstrably fails during generation (not
model loading) on at least one real test device. See `android-module/README.md` and
`GemmaEngine.kt`'s `handleGenerationFailure` for the automatic CPU-rebuild safety net that
still applies if GPU is enabled and does fail.

## ⚠️ About the included `.dproj`

`GemmaChatApp.dproj` in this folder is a **minimal, Win32-only skeleton**, hand-written
without a RAD Studio instance to verify it against. The Android64-specific parts of a real
`.dproj` (SDK/NDK paths, per-file deployment classes for the `.aar`, manifest permissions, app
icons, `versionCode`, etc.) are numerous, version-specific, and normally maintained by the IDE
itself — hand-typing them with confidence isn't realistic. Two ways to get a working project,
in order of safety:

**Option A - safest (recommended):**
1. In RAD Studio 12.2 Athens (Release 2) or later: `File > New > Multi-Device Application -
   Delphi > Blank Application`. Save the project as `GemmaChatApp`.
2. In Project Manager, remove the generated default unit/form.
3. `Project > Add To Project...` and add the three files in this folder: `MainForm.pas`
   (+ its `MainForm.fmx`), `GemmaEngineBridge.pas`, `ModelDownloader.pas`.
4. `Project > Platforms...` (or right-click the project > `Add Platform`) and add **Android64**
   (Android 32-bit has been unsupported for new Play Store submissions for several years; RAD
   Studio 12's default Android target is Android64).

**Option B - try the provided `.dproj` as-is:**
Open `GemmaChatApp.dproj` directly. It should load as a Win32 FMX app referencing the three
units. Then do step 4 from Option A to add Android64. If the IDE reports any project-file
error on open, fall back to Option A - it costs one extra minute and guarantees a
clean project.

Either way, once Android64 is added as a target platform you still need to do the two steps
below (they're IDE actions, not something a project file can pre-configure reliably).

## Adding the native module (.aar)

### If you're on RAD Studio 12.2 Athens (Release 2) or later

1. Build `llminference-release.aar` from `../android-module` (see its README).
2. In Project Manager, expand the project's **Android64** target platform node.
3. Right-click **Libraries** > **Add...** and select `llminference-release.aar`.
4. Deploy: RAD Studio should now package the `.aar`'s classes and native libraries into the
   APK automatically. If a class from the module is reported missing at runtime, double check
   the module was actually built as the "fat" aar (see `../android-module/README.md`) and not
   accidentally as the thin default.

### If you're on RAD Studio 12.0 (original Athens) or 12.1

**12.0/12.1 cannot import `.aar` files at all** - direct AAR import (and the `rclasser` tool
that compiles an AAR's Android resources into an `R.jar`) was added in 12.2. Confirmed via
Embarcadero's own 12.2 release notes, which list "Added support for importing Android
libraries (.aar files)" as a 12.2-only feature - it's absent from the 12.0 and 12.1 release
notes. On 12.0/12.1 you extract the `.aar` by hand and add its two kinds of content
separately:

1. **Extract the `.aar`.** It's a plain zip. Rename `llminference-release.aar` to
   `llminference-release.zip` and extract it (Windows `Expand-Archive`, 7-Zip, etc.). You get:
   - `classes.jar` - all the merged Kotlin/Java classes (ours + tasks-genai's + its own
     transitive jars, already merged in by the `fat-aar` Gradle plugin at build time).
   - `jni/<abi>/*.so` - native libraries (the LiteRT/TensorFlow Lite runtime, etc.).
   - `res/`, `AndroidManifest.xml` - almost certainly near-empty/trivial for this module
     (`tasks-genai` is a computation library, not a UI one), but open them and check; if `res/`
     contains real resources, 12.0/12.1 has no automated way to compile them into a usable
     `R.jar` and you'd need a separate `aapt`-based step (out of scope here - if you hit this,
     it's a strong signal to upgrade to 12.2 instead of continuing manually).

2. **Add `classes.jar` as a plain `.jar` library** - this part of the workflow is unchanged
   across all 12.x versions: Project Manager > expand **Android64** > right-click
   **Libraries** > **Add...** > select `classes.jar`.
   ([Embarcadero docs](https://docwiki.embarcadero.com/RADStudio/Athens/en/Adding_A_Java_Library_to_Your_Application_Using_the_Project_Manager))

3. **Deploy the native `.so` files by hand** via `Project > Deployment` (Deployment Manager):
   - Click **Add Files**, browse to each `.so` under the extracted `jni\arm64-v8a\` folder,
     and add it.
   - Set each file's **Remote Path** to `library\lib\arm64-v8a\` (mirrors Android's standard
     `jniLibs` folder layout - this is the same convention Embarcadero's own docs show for a
     native `.so` example, just for the `armeabi` ABI instead of `arm64-v8a`).
   - Set **Platform** to Android64 for each entry.
   - **You only need the `arm64-v8a` variant.** RAD Studio's Android target only runs on real
     ARM devices - there is no supported x86_64/emulator target - so any `jni/x86_64/` folder
     in the extracted AAR can be ignored.
   - The Deployment Manager UI doesn't expose a named "deployment class" dropdown for this;
     you just add each file, set its Remote Path and Platform as above. This part is
     genuinely more fiddly than 12.2's one-click `.aar` import, but for `tasks-genai` it
     should only be a handful of `.so` files (open `jni/arm64-v8a/` after extracting to see
     exactly how many).

4. **Duplicate class errors:** if the build reports a duplicate class, it means one of the
   jars bundled inside `classes.jar` overlaps a library RAD Studio already ships by default
   (e.g. an AndroidX support jar). Fix: in the Libraries node, find and uncheck/disable the
   conflicting built-in default library
   ([Embarcadero docs on built-in libraries](https://docwiki.embarcadero.com/RADStudio/Athens/en/Using_the_Built-in_RAD_Studio_Java_Libraries_for_Android)).

**None of this touches `GemmaEngineBridge.pas`, `MainForm.pas`, `ModelDownloader.pas`, or the
Kotlin module** - the JNI binding code is identical regardless of how the classes/native libs
got into the APK. If step 1 turns up real Android resources in the AAR, or the manual `.so`
wiring gets unwieldy, upgrading to 12.2+ removes all of this and reduces the whole section
back to the four steps above it.

## Required Android permissions

Model download uses plain HTTPS via `TNetHTTPClient`, so the app needs the `INTERNET`
permission. In RAD Studio: **Project > Options > Application > Uses Permissions** (per
platform: Android64) and enable **Internet**. No storage permission is needed - the model is
saved to the app's private `TPath.GetDocumentsPath` (internal storage), not shared storage.

## Getting a Gemma `.task` model

The MediaPipe LLM Inference API consumes a self-contained `.task` bundle (LiteRT model +
tokenizer + metadata). Official Gemma `.task` builds for Android are distributed from Hugging
Face's gated `litert-community` repositories, e.g.
https://huggingface.co/litert-community/Gemma3-1B-IT (accept the Gemma license there first).

The app's Settings panel comes **pre-filled** with a default URL pointing at
`gemma3-1b-it-int4.task` (555 MB, the smallest 4-bit-quantized Gemma 3 1B build in that repo -
verified to exist, see `DefaultModelUrl` in `MainForm.pas`). You still need your own account,
license acceptance, and access token - none of that can be baked into the app:

1. Create a Hugging Face account and accept the Gemma license on the model repo above.
2. Create a **read-scoped access token**: https://huggingface.co/settings/tokens.
3. In the app's Settings panel, the URL field already has a value - paste your token into the
   token field and tap **Download model**. `ModelDownloader` sends the token as an
   `Authorization: Bearer <token>` header - **never hard-code a token in source**.
4. Want a different quantization variant instead (smaller/faster vs. larger/better quality)?
   Open the repo's "Files and versions" tab, pick another `.task` file, and paste its
   `resolve/main/<filename>.task` URL over the pre-filled one - or change `DefaultModelUrl` in
   `MainForm.pas` if you want that variant to be the new default.
5. (Recommended) Compute the file's SHA-256 once you know exactly which file you're shipping
   against, and put it in `DefaultExpectedSha256` in `MainForm.pas`, so future downloads are
   verified automatically instead of trusting the network unconditionally.

Do not commit a personal access token to source control; the Settings field is the only place
it should ever live (in memory, for the duration of one download).

## Minimum device RAM

No official Google-published minimum RAM figure was found for Gemma 3 1B / Gemma 2 2B under
the MediaPipe LLM Inference API. As a practical baseline: budget for the `.task` file's own
size (roughly 500 MB-1 GB for a 4-bit-quantized Gemma 3 1B, see `../README.md`) plus runtime
overhead for activations/KV-cache - devices with **4 GB RAM or less should be treated as
marginal**; prefer testing on real hardware with the specific quantization you ship rather
than trusting a fixed number.

## Known limitations

- Android only - no iOS support in this version (LiteRT/MediaPipe's GenAI Tasks API used here
  is Android-specific; an iOS port would need a different native module and Objective-C/Swift
  bridge entirely).
- `com.google.mediapipe:tasks-genai` is in maintenance-only mode upstream (see
  `../android-module/README.md`); expect to eventually port `GemmaEngine.kt` to LiteRT-LM.
- The `.dproj` in this repo is a best-effort minimal skeleton, not IDE-verified - see the
  warning above.
- Conversations ARE persisted to disk (see `ConversationStore.pas` / the "History" section
  above), but reopening one only restores the visible transcript, not the model's own context -
  `Reset`/"New conversation" always start the model with a fresh `LlmInferenceSession`.
- Single in-flight generation at a time; sending a new prompt while one is streaming is
  blocked by the UI (`FGenerating` flag) rather than queued. History/New conversation/Reset are
  also blocked while generating, since closing the session mid-generation was found to hang or
  crash the native side on the test device.
- No way to rename a saved conversation's auto-derived title from the UI yet (deleting is
  supported - see below).
