**🇪🇸 Español** | [🇬🇧 English](README.md)

# Gemma on-device chat (Delphi FMX + LiteRT/MediaPipe, Android)

Ejecuta un modelo Gemma completamente en el dispositivo Android - sin llamadas a la nube para la
inferencia - desde una app Delphi FireMonkey, envolviendo la API MediaPipe LLM Inference de
Google (que ejecuta el modelo con el runtime LiteRT) en un pequeño `.aar` de Kotlin y
manejándola desde Delphi por JNI.

```
┌─────────────────────────────┐        JNI        ┌───────────────────────────────────┐
│   App Delphi FMX (Android)  │◄──────────────────►│  .aar Kotlin (android-module/)     │
│   - MainForm.pas (UI chat)  │                     │  com.gemmabridge.llm.GemmaEngine   │
│   - ModelDownloader.pas     │                     │  envuelve com.google.mediapipe:     │
│   - GemmaEngineBridge.pas ──┼── única unidad JNI ┼─  tasks-genai (runtime LiteRT)      │
└─────────────────────────────┘                     └───────────────────────────────────┘
```

- **`android-module/`** - librería Android en Kotlin, compila a un único `.aar`
  autocontenido, ver [android-module/README.md](android-module/README.md).
- **`delphi-app/`** - la app de chat FMX, ver [delphi-app/README.md](delphi-app/README.md).

## Toolchain asumido

- **Se recomienda RAD Studio 12.2 Athens (Release 2) o posterior.** Confirmado en las notas de
  versión de Embarcadero que la importación directa de `.aar` en el Project Manager se añadió en
  la 12.2. **12.0/12.1 también funcionan**, pero requieren extraer manualmente `classes.jar` y
  las librerías nativas `.so` del `.aar` y añadirlas por separado (el jar vía Project Manager,
  los `.so` vía el Deployment Manager) - ver la sección "RAD Studio 12.0 (Athens original) o
  12.1" en [delphi-app/README.md](delphi-app/README.md) para los pasos exactos. Los fuentes
  Delphi no cambian en ningún caso - esto solo afecta a cómo llegan los artefactos compilados al
  APK.
- JDK 17 + Android SDK Platform 34 para compilar el módulo Kotlin.
- Modelo objetivo: **Gemma 3 1B** (IT, cuantizado a 4 bits), elegido por su huella de
  tamaño/RAM en el dispositivo. La app en sí no está atada a este modelo - cualquier bundle
  `.task` compatible con la API MediaPipe LLM Inference funciona, configurable desde el campo de
  URL del panel de Settings.

## Puesta en marcha rápida

1. Compila el módulo nativo: ver [android-module/README.md](android-module/README.md) -> genera
   `llminference-release.aar`.
2. Abre/crea el proyecto Delphi e integra el `.aar`: ver
   [delphi-app/README.md](delphi-app/README.md) (cubre tanto la vía recomendada de "nueva app
   FMX en blanco + añadir estas unidades" como el `.dproj` best-effort ya incluido).
3. Consigue un fichero `.task` de Gemma desde Hugging Face (org `litert-community` - con acceso
   restringido, requiere cuenta + token de acceso) y configura su URL en el panel de Settings de
   la app. Mismo README, sección "Getting a Gemma .task model".
4. Despliega en un **dispositivo Android real** - el target Android de RAD Studio no admite
   ejecutar en emulador en absoluto (solo compila para hardware ARM real, arm64-v8a), lo que de
   paso significa que en el paso 2 (vía manual) solo hace falta preocuparse de las librerías
   nativas arm64-v8a, y carga el modelo.

## RAM mínima del dispositivo

No se ha encontrado una cifra oficial de Google para los requisitos de RAM de Gemma 3 1B /
Gemma 2 2B bajo esta API. Guía práctica usada en todo este proyecto: presupuesta el tamaño del
propio fichero `.task` (aproximadamente 500 MB-1 GB para Gemma 3 1B cuantizado a 4 bits) más el
overhead de runtime para activaciones/KV-cache, y trata los **dispositivos con ≤4 GB de RAM como
marginales** - verifica en hardware real con la cuantización exacta que vayas a distribuir antes
de comprometerte con una cifra mínima.

## Funcionalidades

- UI de chat con respuestas en streaming token a token, controles de
  temperature/top-k/top-p/max-tokens.
- Descarga del modelo con soporte de reanudación (HTTP `Range`) y verificación SHA-256.
- **Selector de backend GPU/CPU** - una casilla "Use GPU" en Settings, **desactivada (CPU) por
  defecto**: en el dispositivo de pruebas principal el delegado GPU inicializaba bien pero
  fallaba durante la generación real, así que CPU por defecto es la opción segura; GPU es
  opcional para los dispositivos donde sí funciona. Sea cual sea el modo activo, un fallo del
  GPU en tiempo de generación se detecta y el motor se reconstruye automáticamente en CPU en vez
  de quedarse colgado o crashear - ver `GemmaEngine.kt`.
- **Historial de conversaciones** - las conversaciones pasadas se guardan como ficheros JSON con
  título (`Documents/conversations/*.json`) y son navegables desde el botón "History" (listar,
  reabrir, o empezar una nueva). Reabrir una conversación antigua restaura la transcripción
  visual pero **no** el contexto propio del modelo - ver la limitación más abajo.
- **Copiar y borrar mensajes** - toca el texto de cualquier burbuja del chat para copiarlo al
  portapapeles, o usa el botón "Delete" bajo cada burbuja (con confirmación) para eliminar ese
  mensaje de la conversación guardada.

## Limitaciones conocidas

- **Solo Android.** Sin soporte iOS en esta versión - la API MediaPipe GenAI Tasks y todo el
  puente JNI son específicos de Android; iOS necesitaría un módulo nativo aparte y un puente en
  Swift/Objective-C, lo cual queda fuera del alcance de este proyecto.
- **`com.google.mediapipe:tasks-genai` está en modo solo-mantenimiento** en upstream según la
  investigación hecha para este proyecto; la recomendación actual de Google es migrar a
  LiteRT-LM (`com.google.ai.edge.litertlm`). Este proyecto sigue usando tasks-genai porque está
  documentado y funciona hoy - ver `android-module/README.md` para el aislamiento que convierte
  una futura migración en un cambio de un solo fichero.
- **El `.dproj` de Delphi es un esqueleto escrito a mano, no verificado por la IDE** - ver el
  aviso al principio de `delphi-app/README.md` y prefiere crear una nueva Blank Multi-Device
  Application en RAD Studio y añadirle las unidades proporcionadas.
- **Reabrir una conversación pasada no restaura el contexto del modelo** - solo la transcripción
  visual. `LlmInferenceSession` de MediaPipe no tiene ninguna forma soportada de reinyectar
  turnos previos en su contexto nativo sin volver a generarlos, así que el modelo empieza esa
  conversación de cero. La app avisa de esto al usuario al cargar una conversación pasada.
- **Una sola generación en curso a la vez** - la UI bloquea el envío de un nuevo prompt mientras
  otro está en streaming en vez de encolarlo, y también bloquea las acciones de
  History/New/Reset hasta que la respuesta actual termina (cerrar la sesión del modelo a mitad
  de generación provocaba cuelgues/crashes en el lado nativo en el dispositivo de pruebas).
- **El fallback del delegado GPU es best-effort**: el modo exacto de fallo (en tiempo de init vs.
  de invoke) y el patrón de reintento en CPU se basan en observación directa en un dispositivo de
  pruebas más reportes de la comunidad, no en un contrato de API documentado oficialmente por
  Google.
- Se encontraron y sortearon varias peculiaridades de `TVertScrollBox` de FMX durante el
  desarrollo (los controles con estilo propio nunca deben ser hijos directos `Align`-eados de un
  scroll box; los scroll boxes deben recrearse en vez de vaciarse con `DeleteChildren` y
  rellenarse de nuevo, para evitar un crash nativo en este dispositivo) - ver `instrucciones.md`
  si reaparecen crashes de UI similares al extender la app.

## Decisiones de diseño tomadas sin preguntar (y por qué)

- **La descarga/almacenamiento del modelo vive enteramente en Delphi** (`ModelDownloader.pas`),
  no en el módulo Kotlin - mantiene el módulo nativo libre de preocupaciones de
  red/permisos y centraliza toda la UI de progreso de descarga en un solo sitio.
  `GemmaEngine.initEngine` solo recibe una ruta de fichero local absoluta.
- **La interfaz del listener JNI es un callback plano de 3 métodos**
  (`onToken`/`onComplete`/`onError`, solo String/void) en vez de exponer directamente el
  `ProgressListener<T>` genérico de MediaPipe - los genéricos son innecesariamente dolorosos de
  resolver por ID de método vía JNI desde Delphi.
- **`GemmaEngine` es un `object` de Kotlin (solo métodos estáticos)**, no una clase que se
  instancia con `NewObject` desde JNI, envuelto en el lado Delphi con el patrón
  `TJavaGenericImport<...>.JavaClass` que la propia RTL de Delphi usa para otras clases Java
  solo-estáticas - más simple que gestionar manualmente el ciclo de vida de una instancia vía
  JNI para lo que en la práctica es un singleton.
