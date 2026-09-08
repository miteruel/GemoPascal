# Instrucciones - Gemma on-device chat (Delphi FMX + LiteRT/MediaPipe)

Registro completo de pasos y problemas resueltos durante el montaje de este proyecto, para
RAD Studio **12.0 Athens** (versión original, sin soporte de importación de `.aar`).

Ver también:
- `README.md` (raíz) - arquitectura general, requisitos, limitaciones.
- `android-module/README.md` - detalle del build Kotlin/Gradle.
- `delphi-app/README.md` - detalle del proyecto Delphi (incluye la sección específica de 12.0/12.1).

---

## 1. Compilar el módulo Kotlin (`android-module/`)

```
cd android-module
gradlew.bat :llminference:assembleRelease
```

Si no tienes el wrapper (`gradle/wrapper/gradle-wrapper.jar` no está versionado por ser
binario), o no tienes Gradle instalado: descarga
https://services.gradle.org/distributions/gradle-8.7-bin.zip, extráelo en cualquier carpeta y
usa `<extraido>\bin\gradle.bat` en vez de `gradlew.bat`.

Necesitas un `local.properties` en `android-module/` apuntando a tu SDK de Android:
```
sdk.dir=C\:/ruta/a/tu/Android/sdk
```
(la barra `\:` escapa los dos puntos de la letra de unidad; el resto de la ruta con `/`).

**Resultado esperado:** `android-module/llminference/build/outputs/aar/llminference-release.aar`
(~13 MB), con `com/gemmabridge/llm/*.class`, todas las clases de `tasks-genai` y
`jni/arm64-v8a/libllm_inference_engine_jni.so`.

### Bugs reales encontrados y corregidos al compilar (ya están arreglados en el repo)

1. **`Unresolved reference: embed`** - el plugin `fat-aar` añade la configuración `embed` al
   estilo Groovy dinámico; en Kotlin DSL (`build.gradle.kts`) no existe como función tipada.
   Arreglo: usar `"embed"("...")` (invocación por nombre de configuración) en vez de `embed("...")`.
2. **`API 'android.registerTransform' is removed'`** - el plugin `com.kezong:fat-aar` (probado
   por sus autores solo hasta AGP 7.1) usa una API de AGP que ya no existe en AGP 8.5. Arreglo
   definitivo: se eliminó el plugin por completo y se sustituyó por una tarea Gradle propia
   (`buildFatAar` en `llminference/build.gradle.kts`) que hace el mismo trabajo (fusionar
   `classes.jar` + `.so` de arm64-v8a de todas las dependencias) sin depender de esa API.
3. **Comentario de bloque roto (`/** ... */`)** - un comentario KDoc contenía el texto
   `jni/arm64-v8a/*.so`, y esa combinación de caracteres forma un `/*` que Kotlin interpreta
   como apertura de un comentario anidado (Kotlin sí soporta comentarios anidados). Esto hizo
   que todo el código posterior (el registro de la tarea `buildFatAar`) quedara silenciosamente
   convertido en comentario, sin ningún error de compilación. Diagnosticado insertando
   `println(...)` en varios puntos del script para ver hasta dónde llegaba la ejecución.
4. **`Task with name 'assembleRelease' not found'`** - `tasks.named("assembleRelease")` se
   ejecutaba antes de que AGP registrase esa tarea (la crea de forma perezosa, tras evaluar el
   proyecto). Arreglo: envolver esas llamadas en `afterEvaluate { ... }`.
5. **Carpetas de trabajo temporales coladas en el `.aar` final** (`classes-merge/`,
   `extract-tasks-genai-.../`) que inflaban el archivo a 59 MB. Arreglo: borrar esas carpetas
   de la zona de trabajo antes del empaquetado final (quedó en 13.4 MB).

---

## 2. Extraer el `.aar` a mano (obligatorio en RAD Studio 12.0/12.1)

12.0/12.1 no soportan importar `.aar` directamente (eso llegó en 12.2 Athens Release 2,
confirmado en las release notes oficiales de Embarcadero). Pasos:

1. Renombra `llminference-release.aar` a `.zip` y extráelo.
2. Verás: `classes.jar`, `jni/arm64-v8a/libllm_inference_engine_jni.so`, `AndroidManifest.xml`,
   `R.txt`, `proguard.txt`. El `res/` debería estar vacío o casi (es una librería de cómputo,
   no de UI) - si tiene contenido real, es señal para valorar actualizar a 12.2.

---

## 3. Crear/configurar el proyecto Delphi

**Opción recomendada:** `File > New > Multi-Device Application - Delphi > Blank Application`,
guardar como `GemmaChatApp`, borrar el form/unit por defecto, `Project > Add To Project...` y
añadir `MainForm.pas` (+ `.fmx`), `GemmaEngineBridge.pas`, `ModelDownloader.pas` de
`delphi-app/`. Luego `Project > Platforms...` para añadir **Android64**.

> Nota: si añades Android64 **después** de crear el proyecto (en vez de seleccionarlo ya en el
> asistente inicial), es probable que los iconos de la app no se rellenen automáticamente - ver
> el punto 6 más abajo.

### Añadir `classes.jar`
Project Manager > expandir **Android64** > clic derecho en **Libraries** > **Add...** >
seleccionar el `classes.jar` extraído en el paso 2.

### Desplegar el `.so` nativo (Deployment Manager)
1. Con **Android64** como plataforma activa, `Project > Deployment...` (o `View > Deployment
   Manager` si no aparece ahí).
2. Confirma que el desplegable "Target Platform" del propio panel está en **Android64**.
3. Botón **"Add Files..."** en la barra del panel > navega a `jni\arm64-v8a\` (de lo extraído
   en el paso 2) > selecciona `libllm_inference_engine_jni.so` > Aceptar.
4. En la fila nueva, edita la columna **Remote Path** (doble clic) y escribe exactamente:
   ```
   library\lib\arm64-v8a\
   ```
5. Verifica que esa fila queda marcada para la plataforma Android64.
6. Cierra el panel (los cambios quedan en el `.dproj`).

### Permisos
`Project > Options > Application > Uses Permissions` (con Android64 activo) > marcar
**Internet** (necesario para `TNetHTTPClient` al descargar el modelo).

---

## 4. Errores de compilación/ejecución que ya salieron y cómo se arreglaron

Todos estos ya están corregidos en los fuentes del repo - se listan por si vuelven a aparecer
al reconstruir desde cero o si algo se deshace por error:

| Síntoma | Causa | Arreglo |
|---|---|---|
| `Propiedad no existe: FormFactor.Devices` (o similar) al abrir `MainForm.fmx` | Propiedad `FormFactor.*` escrita a mano sin verificar contra esa versión concreta del IDE | Se quitó del `.fmx`; no hace falta, toda la UI se construye por código en `BuildUI` |
| Error de compilación por variable `MainForm` | La unidad se llama `MainForm` (`unit MainForm;`) y la variable global también se llamaba `MainForm` - colisión de identificador | Variable global renombrada a `MainAppForm` (en `MainForm.pas` y `GemmaChatApp.dpr`) |
| `EReadError: Error reading MainForm.OnCreate: Invalid property value` al arrancar la app | `FormCreate`/`FormDestroy` estaban declarados `private`; el streaming del `.fmx` (`OnCreate = FormCreate`) usa RTTI clásica, que solo ve miembros `published` | Se movieron a una sección `published` en `MainForm.pas` |
| `[PAClient Error] E8200 ... resource drawable/ic_launcher ... not found` al compilar | Al añadir Android64 después de crear el proyecto, el IDE no rellenó los iconos de la app | `Project > Options > Application > Icons` (con Android64 activo) - asignar un PNG cuadrado a cada tamaño requerido |
| `EJNIFatal: Java type com/gemmabridge/llm/GemmaGenerationListener could not be found` al abrir la app | El `classes.jar` usado no era el correcto/completo (fase en la que el `.aar` fusionado todavía no compilaba bien) | Resuelto reconstruyendo el módulo Kotlin correctamente (ver sección 1) y usando el `.aar` verificado |
| `E7688 Type ... is defined multiple times` (varias veces, distinto paquete cada vez: `androidx.annotation.AnimRes`, `ListenableFuture`, `CanIgnoreReturnValue`...) al compilar en Delphi | El `classes.jar` fusionado trae clases (Guava, AndroidX annotations, error-prone) que RAD Studio ya incluye como librerías del sistema por defecto | Por cada `.dex.jar` que menciona el error, desmarcarlo en Project Manager > Android64 > Libraries, `Project > Clean`, recompilar. Se repite varias veces hasta que no queden duplicados |
| Primer mensaje no responde nada (se queda colgado); segundo mensaje da un error largo | Confirmado por `adb logcat`: el delegado GPU (`ML_DRIFT_CL`) inicializa bien pero **falla al invocar la inferencia real** (`Node number N (ML_DRIFT_CL) failed to invoke` / `Please create a new Session and start over`). La API `ProgressListener` de MediaPipe no tiene callback de error, así que ese fallo se perdía en silencio la primera vez; la segunda vez la sesión ya estaba rota y lanzaba una excepción real | Se reescribió `GemmaEngine.kt`: ahora se vigila también el `ListenableFuture` que devuelve `generateResponseAsync` (que sí falla de forma detectable), y si falla, se reconstruye automáticamente el motor completo en CPU y se pide al usuario reenviar el mensaje |

---

## 5. Obtener el modelo Gemma

La app ya trae **precargada por defecto** la URL de `gemma3-1b-it-int4.task` (555 MB, la
variante int4 más pequeña de `litert-community/Gemma3-1B-IT` - comprobado que existe, un HEAD
sin token devuelve 401 en vez de 404). Solo falta lo que no se puede incrustar en el código:

1. Cuenta en Hugging Face + aceptar licencia en `litert-community/Gemma3-1B-IT`.
2. Token de acceso (read) en `huggingface.co/settings/tokens`.
3. En la app (Settings): la URL ya está puesta - solo pega tu token > **Download model** >
   cuando termine, **Load engine**.
4. Si quieres otra variante (más pequeña/rápida o más grande/calidad), en la pestaña "Files and
   versions" del repo hay varias `.task` distintas - sustituye la URL precargada por la que
   quieras, o cambia `DefaultModelUrl` en `MainForm.pas` para que sea la nueva por defecto.

---

## 5.1 Reanudación de descargas interrumpidas

Se añadió soporte de reanudación en `ModelDownloader.pas` (peticiones HTTP `Range`): si la
descarga se corta (red, app en segundo plano, cancelación manual), la próxima vez que pulses
"Download model" continúa desde donde se quedó en vez de volver a bajar el fichero entero,
siempre que el servidor lo soporte (Hugging Face sí). Si no lo soporta, descarta el trozo
parcial y descarga completo, sin quedarse colgado.

## 5.2 Duplicados de librerías al compilar en Delphi

Como el `classes.jar` fusionado trae de todo (Guava, AndroidX annotations, protobuf...), es
normal que al compilar en RAD Studio salgan varios errores seguidos de tipo:
```
E7688 Type X.Y.Z is defined multiple times: ...\Debug\<algo>.dex.jar:classes.dex, ...classes-dexed.jar:classes.dex
```
Ya salieron y se resolvieron: `annotation-jvm-1.8.1`, `listenablefuture-1.0`,
`error_prone_annotations-2.9.0`. Cada vez que salga uno nuevo: localizar ese `.dex.jar` exacto
en Project Manager > Android64 > Libraries, desmarcarlo, `Project > Clean`, recompilar.

## 5.3 Fallo del delegado GPU durante la generación (ya corregido)

En el dispositivo de pruebas, el log (`adb logcat`) mostró que el delegado GPU de MediaPipe
(`ML_DRIFT_CL`) cargaba el modelo sin problema pero fallaba al generar texto de verdad
(`Node number N (ML_DRIFT_CL) failed to invoke`). Como la API `ProgressListener` de MediaPipe
no tiene callback de error, este fallo no llegaba nunca a `onError` - de ahí que el primer
mensaje no respondiera nada. `GemmaEngine.kt` se corrigió para vigilar también el
`ListenableFuture` (Guava) que devuelve `generateResponseAsync`, y reconstruir el motor en CPU
automáticamente si detecta un fallo así. Si vuelve a pasar tras este fix, la app debería mostrar
un aviso claro ("switched to CPU mode") en vez de quedarse colgada.

## 5.4 Burbujas de respuesta en blanco (ya corregido)

Síntoma: las burbujas del asistente aparecían como rectángulos grises enormes y totalmente en
blanco, sin texto visible. Diagnóstico: capturando el log del dispositivo (`adb logcat`) con un
`Log.d` temporal en `GemmaEngine.kt`, se confirmó que el modelo generaba texto perfectamente
correcto token a token - el problema no era el motor. Una captura de pantalla del dispositivo
(vía `adb exec-out screencap -p`) confirmó visualmente el bug: burbujas enormes sin texto.

Causa real: en `MainForm.pas`, `TLabel.AutoSize` combinado con `WordWrap` no es fiable en FMX
cuando el `Text` se actualiza muchas veces por segundo (streaming token a token) - la altura
calculada por el label no reflejaba el contenido real.

Arreglo: se sustituyó por una medición explícita del texto envuelto usando `FMX.TextLayout`
(`TTextLayoutManager.DefaultTextLayout`, el mismo motor que usa FMX para pintar texto), que
calcula la altura real y la aplica directamente al label y a la burbuja - ver
`MeasureWrappedHeight`/`ResizeBubbleToLabel` en `MainForm.pas`.

## 5.5 GPU opcional (casilla) + historial de conversaciones (añadido)

A petición del usuario, tras confirmar que GPU seguía fallando de forma consistente en el
dispositivo de pruebas:

- **CPU por defecto, GPU opcional**: nueva casilla "Use GPU" en Settings (desmarcada por
  defecto). `GemmaEngine.kt` ahora recibe `useGpu` en `initEngine` y, si está desmarcada, ni
  siquiera intenta el delegado GPU.
- **Historial de conversaciones**: nueva unidad `ConversationStore.pas` (JSON en
  `Documents/conversations/<id>.json`, título auto-generado del primer mensaje). Botón
  "History" en la toolbar → lista conversaciones guardadas + "New conversation". Se guarda
  automáticamente tras cada respuesta completa.
  - **Limitación conocida y deliberada**: al reabrir una conversación antigua se restaura el
    texto visual, pero el modelo (`LlmInferenceSession`) **no recupera su contexto** - la API
    de MediaPipe no tiene forma soportada de reinyectar turnos ya conocidos sin volver a
    generarlos. Se avisa al usuario con un mensaje al cargar una conversación antigua, en vez
    de fingir continuidad real.

Para aplicar: añadir `ConversationStore.pas` al proyecto Delphi (`Project > Add To Project`),
sustituir `classes.jar` (nuevo parámetro `useGpu` en la firma JNI de `initEngine`), `Clean`,
recompilar.

## 5.6 EAccessViolation al pulsar "History" (ya corregido)

Síntoma: `EAccessViolation` al pulsar el botón History, con la app cerrándose. Diagnóstico vía
`adb logcat`: el volcado nativo mostraba la señal SIGTRAP en `_DbgExcNotify` (el propio
notificador de excepciones de Delphi) precedida de ~250 repeticiones de la misma dirección de
retorno - la firma clásica de una **recursión infinita** agotando la pila, no un simple puntero
nulo.

Causa: `TConversationStore.ListConversations` ordenaba la lista con
`MetaList.Sort(TComparer<TConversationMeta>.Construct(...))` - un comparador anónimo sobre un
tipo `record` genérico. Esa combinación desencadenó la recursión infinita en el dispositivo de
pruebas (posible problema de los internals de `TList<T>.Sort`/RTTI genérica en ARM64, no
investigado más a fondo).

Arreglo: se eliminó el comparador personalizado por completo. Como los ids de conversación son
timestamps con formato `yyyymmdd_hhnnsszzz` (ver `NewConversationId`), basta con ordenar
alfabéticamente el array de nombres de fichero (`TArray.Sort<string>`) y recorrerlo al revés
para tener las más recientes primero - sin necesidad de ordenar records ni fechas. Solo afecta
a `ConversationStore.pas` (Delphi puro) - **no hace falta reconstruir el `.aar`/módulo Kotlin
para este fix**, solo recompilar el proyecto Delphi.

## 5.7 Congelación + SIGABRT al tocar History/New/Reset durante una generación (arreglo preventivo)

Tras el fix de la recursión infinita (§5.6), apareció otro fallo distinto: la app se quedaba
congelada 35-45s (Android registraba "waited for MotionEvent") y terminaba en `SIGABRT`.
Diagnóstico por `adb logcat`: el usuario tocó History poco después de interactuar con el chat -
posible carrera si tocó una acción que cierra/reemplaza la sesión (`ResetSession`) **mientras el
motor seguía generando una respuesta** en la sesión antigua. No hay guardas contra esto en el
código original.

Arreglo (preventivo, doble capa, sin confirmación 100% del root cause exacto por falta de log
más preciso):
- **Delphi** (`MainForm.pas`, `ResetEngineSessionAsync`): si `FGenerating` es `True`, se bloquea
  la acción con un aviso ("Please wait for the current response to finish first.") en vez de
  proceder.
- **Kotlin** (`GemmaEngine.kt`, `resetSession` y `closeEngineInternal`): se llama a
  `session?.cancelGenerateResponseAsync()` antes de `session?.close()`, como red de seguridad
  adicional por si algo más en el futuro llega a cerrar la sesión con una generación en curso.

Si la app se sigue colgando o crasheando en las mismas condiciones tras este cambio, hace falta
volver a `adb logcat` para diagnóstico más fino - avisar en próxima sesión con `instrucciones.md`
actualizado hasta aquí como contexto.

## 5.8 Causa real encontrada: crash silencioso al abrir History (RESUELTO)

Tras varias rondas de captura de log/vídeo sin encontrar ni un solo mensaje de error (el
proceso simplemente moría con "exited cleanly (1)", sin señal nativa, sin ANR reproducible, sin
diálogo visible en ningún fotograma del vídeo grabado), el usuario hizo **depuración paso a
paso en RAD Studio** y localizó la línea exacta: `Align := TAlignLayout.Top;` sobre un `TLabel`
recién creado con `Parent := FHistoryScrollBox` (un `TVertScrollBox`).

**Causa confirmada:** un control con estilo propio (`TLabel`, `TButton`...) añadido como hijo
**directo** de un `TVertScrollBox` con `Align := TAlignLayout.Top` provoca un crash nativo
silencioso en este dispositivo - sin excepción Delphi capturable, sin log, sin tombstone. El
código de las burbujas de chat (`AddBubble`) nunca lo sufrió porque siempre interpone un
`TLayout` sencillo entre el scrollbox y el control con estilo real: `ScrollBox -> TLayout
(Align=Top) -> control con estilo (Align=Client o Position explícita)`. El historial nuevo
saltaba ese nivel intermedio.

**Arreglo:** `RefreshHistoryList` reescrito para seguir el mismo anidamiento probado - cada fila
(tanto el mensaje "No saved conversations yet." como cada botón de conversación) va dentro de
su propio `TLayout` intermedio, nunca directamente `Align`-eado como hijo del scrollbox.

**Lección para el futuro en este proyecto:** nunca poner `Align` directamente sobre un
`TLabel`/`TButton`/`TEdit`/etc. que sea hijo inmediato de un `TVertScrollBox`/`TScrollBox`.
Interponer siempre un `TLayout` (Align=Top) como hijo directo del scrollbox, y meter el control
con estilo dentro de ese `TLayout` (con Align=Client o posición explícita).

**Segunda vuelta del mismo bug:** con ese arreglo, History funcionaba la primera vez pero
crasheaba la segunda (abrir > Settings > abrir History otra vez). La diferencia: la segunda vez
`FHistoryScrollBox.DeleteChildren` sí tenía algo que borrar antes de reconstruir la lista.
Conclusión: reutilizar un `TVertScrollBox` con `DeleteChildren` dejaba estado interno
inconsistente en este dispositivo. Arreglo definitivo: en `RefreshHistoryList`, en vez de
`DeleteChildren`, se **destruye y recrea el `TVertScrollBox` entero** cada vez que se abre el
historial (barato para una lista pequeña, y garantiza el mismo estado "recién creado" que ya
sabíamos que funcionaba).

**Tercera vuelta (mismo bug, otro control):** al probar los botones de dentro de History (abrir
una conversación) y "New conversation", crasheaban igual. Causa: `StartNewConversation` y
`LoadConversation` hacían `FChatScrollBox.DeleteChildren` para vaciar el chat - **el mismo
patrón peligroso**, esta vez sobre el scrollbox del chat en vez del historial. Se añadió un
helper `ClearChatScrollBox` (misma técnica: destruir y recrear el `TVertScrollBox`) y se
sustituyeron ambos usos. Regla general para el resto del proyecto: **cualquier
`TVertScrollBox`/`TScrollBox` que se vacíe y se rellene más de una vez en la vida de la app
debe recrearse, no usar `DeleteChildren`** - se revisó todo el fichero (`grep DeleteChildren`)
para confirmar que no quedan más usos sin corregir.

**Cómo se diagnosticó (por si vuelve a hacer falta esta técnica):**
1. `adb logcat` no mostró nada útil - ni señal fatal, ni ANR consistente, ni mensaje JNI.
2. Se grabó la pantalla con `adb shell screenrecord` (cuidado: en Git Bash hace falta
   `//sdcard/archivo.mp4` con doble barra para evitar que MSYS reescriba la ruta remota como
   si fuera de Windows) y se extrajeron fotogramas con `ffmpeg -vf fps=4` - confirmó que no
   aparecía ningún diálogo, solo un salto directo a la pantalla de inicio.
3. Ante la falta de pistas en log/vídeo, se aisló el problema con un "stub" temporal que
   quitaba toda la lógica de `ConversationStore` de `RefreshHistoryList`, dejando solo la
   construcción de UI - seguía crasheando, así que el problema NO estaba en el JSON/ficheros.
4. Con eso acotado a "es la UI", el usuario hizo depuración paso a paso (F7/F8 en RAD Studio)
   y encontró la línea exacta.

## 5.9 Añadido: botón Stop y borrar conversaciones (a petición del usuario)

Tras estabilizar todo, se añadieron dos mejoras sugeridas en la revisión general:

- **Cancelar generación**: el botón "Send" pasa a mostrar "Stop" mientras el modelo está
  generando. Al pulsarlo, `CancelGeneration` en `MainForm.pas` resetea la UI de forma
  **inmediata/optimista** (no espera confirmación de Kotlin, ya que la semántica exacta de
  `cancelGenerateResponseAsync` de MediaPipe no está documentada y podría dejar la UI colgada
  esperando una confirmación que no llega) y en paralelo manda `FBridge.CancelGenerate` en
  background. El texto parcial ya generado se conserva y se guarda, igual que hacen otros
  chats al pulsar "Stop".
- **Borrar conversación**: cada fila del historial tiene ahora un botón "Delete" con diálogo
  de confirmación (`TDialogService.MessageDialog`), que llama a
  `TConversationStore.DeleteConversation`. Si se borra la conversación que está abierta en ese
  momento en el chat, no se toca el chat visible ni la sesión del motor - solo se le asigna un
  id nuevo para que el siguiente turno no reescriba el fichero que se acaba de borrar.

Ambos cambios son solo Delphi (`MainForm.pas`) - no requieren recompilar el módulo Kotlin ni
sustituir `classes.jar`.

## 5.10 Añadido: selector de fichero local (Storage Access Framework)

El usuario tenía modelos `.gguf` descargados en la carpeta de Descargas del móvil y pidió un
selector para cargarlos directamente. **Aviso importante que se le dio antes de implementar
nada**: GGUF es el formato de `llama.cpp`, completamente incompatible con el motor de esta app
(MediaPipe LLM Inference / LiteRT, que usa el formato `.task`). Dar soporte real a GGUF
significaría integrar `llama.cpp` como un segundo motor nativo completo - un proyecto mucho
más grande. Se le preguntó y eligió la opción intermedia: un selector de ficheros que funciona
con el motor actual (para `.task` que ya tenga descargados por otra vía), dejando claro que
elegir un `.gguf` copiará el fichero pero fallará al cargar el motor (no hay forma de validar
el formato antes de intentar cargarlo de verdad).

Implementación: nueva unidad `FilePicker.pas` (segunda y única otra unidad del proyecto que
toca `Androidapi.JNI.*` directamente, aislada igual que `GemmaEngineBridge.pas`). Usa el patrón
estándar de Delphi para Storage Access Framework: `Intent.ACTION_OPEN_DOCUMENT` +
`startActivityForResult` + suscripción a `TMessageResultNotification` vía `TMessageManager`
(unidad `FMX.Platform.Android`) para recibir el resultado, y copia el fichero elegido
(`content://` URI) a almacenamiento privado de la app leyendo con `JInputStream` y escribiendo
con `JFileOutputStream` (patrón verificado contra un proyecto real de ejemplo en GitHub,
`emozgun/delphi-android-SAF`, antes de escribir el código, para no inventar nombres de clases).

**Bug real evitado antes de que ocurriera** (por aprender de los sustos anteriores con
congelaciones/ANR): `onActivityResult` en Android se entrega en el hilo principal, así que
copiar un fichero de potencialmente cientos de MB directamente ahí habría congelado la UI
igual que los ANR que ya sufrimos con el historial. Se movió la copia a un `TTask.Run` en
background, con `TThread.Queue` para devolver el resultado (`OnPicked`/`OnError`) al hilo
principal - mismo patrón que `ModelDownloader`/`GemmaEngineBridge` ya usan.

Nuevo botón "Or pick a .task file already on this device..." en el panel de Settings, junto a
"Download model". No hace falta ningún permiso nuevo en el manifest - SAF no lo requiere.

## 6. Recordatorios generales

- RAD Studio Android **no soporta emulador** - solo dispositivos ARM reales (arm64-v8a). Por
  eso solo hace falta desplegar esa única ABI de `.so`.
- Tras añadir/cambiar librerías o deployment, conviene `Project > Clean` + desinstalar la app
  vieja del móvil antes de `Project > Build`, para evitar quedarse con un `.dex`/APK cacheado.
- Ninguno de los bugs de arriba afecta a la lógica de `GemmaEngineBridge.pas`,
  `ModelDownloader.pas` ni al módulo Kotlin en sí - todos eran de empaquetado/proyecto.
