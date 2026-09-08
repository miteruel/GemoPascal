# Gemma on-device chat (Delphi FMX + LiteRT/MediaPipe, Android)

App Android que ejecuta Gemma en el dispositivo (sin nube) desde Delphi FireMonkey, envolviendo
la MediaPipe LLM Inference API (`com.google.mediapipe:tasks-genai`, que usa LiteRT) en un
módulo Kotlin `.aar` y llamándolo por JNI.

## Estructura

- `android-module/` - librería Android Kotlin (`com.gemmabridge.llm.GemmaEngine`), Gradle.
  Produce `llminference/build/outputs/aar/llminference-release.aar`.
- `delphi-app/` - app FMX (Android). `GemmaEngineBridge.pas` y `FilePicker.pas` son las únicas
  dos unidades con JNI directo; `MainForm.pas` es la UI de chat; `ModelDownloader.pas` gestiona
  descarga+hash del modelo (con reanudación); `FilePicker.pas` deja elegir un `.task` ya
  presente en el dispositivo vía el selector nativo de Android (Storage Access Framework) en
  vez de descargarlo - **NO soporta GGUF** (formato de `llama.cpp`, incompatible con el motor
  de esta app); `ConversationStore.pas` persiste conversaciones como JSON
  (`Documents/conversations/*.json`), con historial navegable desde el botón "History" (borrar
  conversación soportado, renombrar no) - ver limitación en `instrucciones.md` §5.5 (recargar
  una conversación antigua no restaura el contexto del modelo, solo el texto visual). El botón
  Send se convierte en Stop mientras genera (cancela vía `GemmaEngineBridge.CancelGenerate`).
- `initEngine` acepta un parámetro `useGpu` (Kotlin y JNI) - la app expone esto como una
  casilla "Use GPU" en Settings, **desmarcada por defecto** (CPU), porque el delegado GPU
  demostró fallar de forma consistente en el dispositivo de pruebas del usuario.
- `README.md` - arquitectura, requisitos, limitaciones.
- `instrucciones.md` - registro detallado paso a paso + tabla de errores ya resueltos (leer
  antes de repetir trabajo si algo similar vuelve a fallar).

## Entorno del usuario

- Hay **dos instalaciones de RAD Studio** en esta máquina, en paralelo:
  - **RAD Studio 12.0 Athens** (`BDS 23.0`, `C:\Program Files (x86)\Embarcadero\Studio\23.0`) -
    versión original de este proyecto, **sin** soporte de importar `.aar` directamente (eso
    llegó en 12.2 Release 2). El flujo de trabajo documentado en `delphi-app/README.md` e
    `instrucciones.md` asume esta versión: extraer el `.aar` a mano, añadir `classes.jar` como
    librería normal, y desplegar el `.so` nativo vía Deployment Manager.
  - **RAD Studio 37.0** (`C:\Program Files (x86)\Embarcadero\Studio\37.0`) - instalación más
    reciente, es la que normalmente está abierta (`bds.exe`) en esta máquina. El `.dproj` del
    proyecto (`GemmaChatApp.dproj`, `ProjectVersion 20.3`) compila igual en ambas. Desde esta
    versión también funciona compilar/empaquetar/desplegar **por línea de comandos**, sin abrir
    la IDE, con `rsvars.bat` + `msbuild`:
    ```
    call "C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat"
    cd delphi-app
    msbuild GemmaChatApp.dproj /t:Build /p:Config=Debug /p:Platform=Android64
    msbuild GemmaChatApp.dproj /t:Deploy /p:Config=Debug /p:Platform=Android64
    ```
    `/t:Build` solo compila/enlaza el `.so` nativo; `/t:Deploy` es el paso que además empaqueta
    el `.apk` (manifest merge, dex, `paclient.exe --apppackage`) en
    `GemmaChatApp\bin\GemmaChatApp.apk` - hace falta ejecutar los dos, en ese orden. Luego
    `adb install -r` + `adb shell am start -n
    com.embarcadero.GemmaChatApp/com.embarcadero.firemonkey.FMXNativeActivity` para probarlo en
    el dispositivo. Verificado funcionando end-to-end (build limpio, instalación, arranque sin
    crash) en la sesión del 2026-09-08.
- RAD Studio Android **no soporta emulador**, solo dispositivos ARM64 reales - por eso el
  módulo nativo solo empaqueta la ABI `arm64-v8a`.
- Modelo objetivo: **Gemma 3 1B** (IT, `.task` de Hugging Face `litert-community`), aunque la
  app admite cualquier `.task` compatible vía URL configurable.
- SDK de Android del usuario en `H:\android\sdk` (`ANDROID_HOME`/`ANDROID_SDK_ROOT`).
- Build de Gradle verificado en esta máquina sin instalación de Gradle propia: se descargó
  Gradle 8.7 standalone y se invocó directamente (`gradle wrapper` no se había generado porque
  el `.jar` del wrapper es binario).

## Decisiones de diseño ya tomadas (no volver a preguntar)

- Descarga/almacenamiento del modelo vive enteramente en Delphi (`ModelDownloader.pas`); el
  módulo Kotlin solo recibe una ruta de fichero local ya verificada.
- `GemmaEngine` es un `object` Kotlin (métodos estáticos `@JvmStatic`) para simplificar el
  binding JNI desde Delphi (patrón `TJavaGenericImport<...>.JavaClass`, sin `NewObject`).
- El callback JNI (`GemmaGenerationListener`) es deliberadamente `String`/`void` puro, sin
  genéricos, para que sea fácil de resolver por firma desde JNI.
- `com.google.mediapipe:tasks-genai` está en modo mantenimiento upstream (Google recomienda
  LiteRT-LM a futuro); se mantiene por ser la API mejor documentada hoy. Aislado en
  `GemmaEngine.kt` para que una migración futura no toque Delphi.
- El plugin Gradle `com.kezong:fat-aar` **no se usa** (incompatible con AGP 8.x, API eliminada);
  se sustituyó por una tarea Gradle propia `buildFatAar` en `llminference/build.gradle.kts`.

## Errores ya diagnosticados y corregidos (no repetir el diagnóstico, ver `instrucciones.md` §4-5)

Colisión de nombre unidad/variable (`MainForm`), visibilidad `published` requerida para
`FormCreate`/`FormDestroy` (streaming FMX usa RTTI clásica), propiedad `FormFactor.*` inventada
en el `.fmx` (quitada), icono de app no poblado al añadir Android64 tras crear el proyecto,
comentario Kotlin anidado roto por `/*` accidental en un KDoc, `tasks.named("assembleRelease")`
necesita `afterEvaluate`, duplicados de clases al compilar en Delphi (desmarcar la librería del
sistema correspondiente una por una), y el delegado GPU (`ML_DRIFT_CL`) fallando en tiempo de
**generación** (no de carga) en el dispositivo de pruebas - `ProgressListener` de MediaPipe no
tiene callback de error, así que había que vigilar también el `ListenableFuture` devuelto por
`generateResponseAsync` para detectarlo; ya corregido con reconstrucción automática a CPU.

## Depuración en dispositivo real

Hay un Android SDK con `adb` en `H:\android\sdk\platform-tools\adb.exe` y, si el móvil del
usuario está conectado por USB a esta misma máquina, `adb logcat` (y `adb exec-out screencap -p
> file.png` para capturas de pantalla, leíbles luego con Read) es la vía más fiable para
diagnosticar fallos que solo se ven como "error genérico" en la UI de Delphi - así se
diagnosticó tanto el fallo del delegado GPU como el bug de las burbujas en blanco (ver
`instrucciones.md` §5.3-5.4). Package de la app: `com.embarcadero.GemmaChatApp`.

`TLabel.AutoSize` + `WordWrap` en FMX no es fiable con texto que se actualiza muy rápido
(streaming token a token) - produjo burbujas enormes y en blanco. La solución correcta es medir
el texto explícitamente con `FMX.TextLayout` (`TTextLayoutManager.DefaultTextLayout`) en vez de
confiar en el autosize del control. Ver `MeasureWrappedHeight` en `MainForm.pas`.

**Evitar `TComparer<TRecord>.Construct` + `TList<T>.Sort` con records genéricos** en este
proyecto: causó una recursión infinita real (SIGTRAP en `_DbgExcNotify` tras ~250 frames
repetidos, visto en `adb logcat`) al ordenar `TList<TConversationMeta>` en
`ConversationStore.ListConversations`. Arreglado ordenando el array de nombres de fichero
(`TArray.Sort<string>`) en su lugar, aprovechando que los ids ya son timestamps ordenables como
texto - ver `instrucciones.md` §5.6.

**Regla de oro en este proyecto para `TVertScrollBox`/`TScrollBox`:** nunca poner `Align`
directamente sobre un control con estilo propio (`TLabel`, `TButton`, `TEdit`...) que sea hijo
*inmediato* del scrollbox - provoca un crash nativo silencioso en el dispositivo de pruebas
(sin excepción Delphi, sin log, sin tombstone - "exited cleanly (1)" y ya está). Interponer
siempre un `TLayout` (Align=Top) como hijo directo del scrollbox, con el control real dentro de
ese `TLayout`. Es el patrón que ya usa `AddBubble` (burbujas de chat) y que `RefreshHistoryList`
tuvo que adoptar tras el diagnóstico - ver `instrucciones.md` §5.8, incluye la técnica de
`adb shell screenrecord` + `ffmpeg` usada para depurarlo cuando el log no daba pistas.

**Regla relacionada, también confirmada por crash real:** un `TVertScrollBox` que se vacía con
`DeleteChildren` y se rellena de nuevo (para refrescar una lista) puede quedar con estado interno
inconsistente y crashear la SEGUNDA vez que se reutiliza (la primera vez, recién creada,
funciona bien). Afectó a `FHistoryScrollBox` y también a `FChatScrollBox` (al cargar una
conversación antigua o pulsar "New conversation"/"Reset"). Solución aplicada en todo el
proyecto: **destruir y recrear el `TVertScrollBox` entero** en vez de `DeleteChildren` - ver
`ClearChatScrollBox` en `MainForm.pas` y el mismo patrón en `RefreshHistoryList`.
