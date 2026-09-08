{
  Copyright (C) 2026 Antonio Alcázar Ruiz (MiTeruel) <mrgarciagarcia@gmail.com>
  Part of the PluTony project. Licensed under the GNU GPL v3.0 or later;
  see LICENSE for the full text.
}

unit GemmaEngineBridge;

{
  Isolated JNI integration layer for the com.gemmabridge.llm.GemmaEngine Android library
  (see ../android-module). This is the ONLY unit in the app that imports Androidapi.JNI.*
  units. Everything else (MainForm, ModelDownloader) talks to the plain, non-JNI
  TGemmaEngineBridge class declared below.

  Threading contract:
   - InitEngine, Generate, ResetSession, CloseEngine call into the Kotlin module
     synchronously (from the JNI side, generate() *is* asynchronous internally, but the
     Delphi call to trigger it returns immediately). None of them are safe to call from the
     FMX main thread for InitEngine (model load can take seconds) - callers MUST invoke
     InitEngine from a TTask/background thread. Generate returns immediately so it is less
     critical, but for consistency should also be called off the main thread.
   - The Kotlin side invokes our listener callbacks (OnToken/OnComplete/OnError) on a
     MediaPipe-managed worker thread. TGemmaEngineBridge marshals every one of them onto the
     main thread via TThread.Queue BEFORE invoking the OnToken/OnComplete/OnError properties,
     so consumers of this class (MainForm) never need to think about JNI threading - the
     events they subscribe to always fire on the main/UI thread.

  Design decision: model download/storage lives entirely on the Delphi side (see
  ModelDownloader.pas). GemmaEngine.initEngine on the Kotlin side only ever receives an
  absolute filesystem path to an already-downloaded, already-verified .task file. This was
  chosen because it keeps the native module free of networking/permission concerns and
  keeps all download-progress UI logic in one place (Delphi) instead of needing a second,
  differently-shaped JNI callback for download progress.
}

interface

uses
  System.SysUtils, System.Classes;

type
  TGemmaEngineConfig = record
    ModelPath: string;
    MaxTokens: Integer;
    Temperature: Single;
    TopK: Integer;
    TopP: Single;
    /// <summary>
    ///   If False (recommended default), the engine only ever uses the CPU backend - more
    ///   reliable on devices where the GPU delegate initializes fine but fails during actual
    ///   generation. If True, GPU is tried first with automatic fallback to CPU on failure.
    /// </summary>
    UseGpu: Boolean;
  end;

  TGemmaTokenEvent = procedure(Sender: TObject; const Token: string) of object;
  TGemmaCompleteEvent = procedure(Sender: TObject) of object;
  TGemmaErrorEvent = procedure(Sender: TObject; const ErrorMessage: string) of object;

  /// <summary>
  ///   Non-JNI facade over the native com.gemmabridge.llm.GemmaEngine Kotlin singleton.
  ///   Every JNI type (JString, JContext, TJavaLocal, ...) stays inside the implementation
  ///   section of this unit.
  /// </summary>
  TGemmaEngineBridge = class
  private
    FInitialized: Boolean;
    FOnToken: TGemmaTokenEvent;
    FOnComplete: TGemmaCompleteEvent;
    FOnError: TGemmaErrorEvent;
    {$IFDEF ANDROID}
    FListener: TObject; // actual type TGemmaListenerBridge, declared below in this unit
    {$ENDIF}
    procedure DoToken(const Token: string);
    procedure DoComplete;
    procedure DoError(const ErrorMessage: string);
  public
    constructor Create;
    destructor Destroy; override;

    /// <summary>Loads the model. Blocking - call from a background thread/TTask.</summary>
    function InitEngine(const Config: TGemmaEngineConfig): Boolean;

    /// <summary>Clears conversation history without reloading the model.</summary>
    function ResetSession(Temperature: Single; TopK: Integer; TopP: Single): Boolean;

    /// <summary>
    ///   Starts streaming generation for Prompt. Returns immediately; results arrive via the
    ///   OnToken/OnComplete/OnError events, always on the main thread.
    /// </summary>
    procedure Generate(const Prompt: string);

    /// <summary>Cancels an in-flight Generate call, if any.</summary>
    procedure CancelGenerate;

    /// <summary>Releases the model and all native resources.</summary>
    procedure CloseEngine;

    property Initialized: Boolean read FInitialized;

    property OnToken: TGemmaTokenEvent read FOnToken write FOnToken;
    property OnComplete: TGemmaCompleteEvent read FOnComplete write FOnComplete;
    property OnError: TGemmaErrorEvent read FOnError write FOnError;
  end;

implementation

{$IFDEF ANDROID}
uses
  Androidapi.JNIBridge,
  Androidapi.JNI.JavaTypes,
  Androidapi.JNI.GraphicsContentViewText,
  Androidapi.Helpers;

type
  { ---- JNI class binding for com.gemmabridge.llm.GemmaEngine (Kotlin `object`, all members
    exposed as @JvmStatic - modeled the same way Delphi's own RTL wraps static-only Java
    classes such as android.provider.Settings$Secure: a "*Class" interface carrying the
    static methods, accessed through TJavaGenericImport<...>.JavaClass. }

  JGemmaGenerationListener = interface; // forward

  JGemmaEngineClass = interface(JObjectClass)
    ['{E1B2C3D4-5A6B-4C7D-8E9F-0A1B2C3D4E5F}']
    function initEngine(context: JContext; modelPath: JString; maxTokens: Integer;
      temperature: Single; topK: Integer; topP: Single; useGpu: Boolean): Boolean; cdecl;
    function resetSession(temperature: Single; topK: Integer; topP: Single): Boolean; cdecl;
    procedure generate(prompt: JString; listener: JGemmaGenerationListener); cdecl;
    procedure cancelGenerate; cdecl;
    procedure closeEngine; cdecl;
    function isInitialized: Boolean; cdecl;
  end;

  [JavaSignature('com/gemmabridge/llm/GemmaEngine')]
  JGemmaEngine = interface(JObject)
    ['{F2C3D4E5-6B7C-4D8E-9F0A-1B2C3D4E5F6A}']
  end;
  TJGemmaEngine = class(TJavaGenericImport<JGemmaEngineClass, JGemmaEngine>) end;

  { ---- JNI interface Delphi implements so Kotlin can call back into us.
    Method signatures must match com.gemmabridge.llm.GemmaGenerationListener exactly:
      fun onToken(token: String)
      fun onComplete()
      fun onError(message: String) }

  [JavaSignature('com/gemmabridge/llm/GemmaGenerationListener')]
  JGemmaGenerationListener = interface(IJavaInstance)
    ['{A3D4E5F6-7C8D-4E9F-0A1B-2C3D4E5F6A7B}']
    procedure onToken(token: JString); cdecl;
    procedure onComplete; cdecl;
    procedure onError(errorMessage: JString); cdecl;
  end;

  { Delphi-side implementation of the Java listener interface. TJavaLocal generates the JNI
    proxy object that the Kotlin side actually sees; every method below runs on whatever
    thread MediaPipe's generateResponseAsync callback fires on - NOT the main thread and NOT
    necessarily the thread that called Generate(). }
  TGemmaListenerBridge = class(TJavaLocal, JGemmaGenerationListener)
  private
    FOwner: TGemmaEngineBridge;
  public
    constructor Create(AOwner: TGemmaEngineBridge);
    procedure onToken(token: JString); cdecl;
    procedure onComplete; cdecl;
    procedure onError(errorMessage: JString); cdecl;
  end;

constructor TGemmaListenerBridge.Create(AOwner: TGemmaEngineBridge);
begin
  inherited Create;
  FOwner := AOwner;
end;

procedure TGemmaListenerBridge.onToken(token: JString);
var
  TokenStr: string;
begin
  TokenStr := JStringToString(token);
  FOwner.DoToken(TokenStr);
end;

procedure TGemmaListenerBridge.onComplete;
begin
  FOwner.DoComplete;
end;

procedure TGemmaListenerBridge.onError(errorMessage: JString);
var
  MsgStr: string;
begin
  MsgStr := JStringToString(errorMessage);
  FOwner.DoError(MsgStr);
end;

{$ENDIF}

{ TGemmaEngineBridge }

constructor TGemmaEngineBridge.Create;
begin
  inherited Create;
  FInitialized := False;
  {$IFDEF ANDROID}
  FListener := TGemmaListenerBridge.Create(Self);
  {$ENDIF}
end;

destructor TGemmaEngineBridge.Destroy;
begin
  CloseEngine;
  {$IFDEF ANDROID}
  FListener.Free;
  {$ENDIF}
  inherited Destroy;
end;

procedure TGemmaEngineBridge.DoToken(const Token: string);
begin
  TThread.Queue(nil,
    procedure
    begin
      if Assigned(FOnToken) then
        FOnToken(Self, Token);
    end);
end;

procedure TGemmaEngineBridge.DoComplete;
begin
  TThread.Queue(nil,
    procedure
    begin
      if Assigned(FOnComplete) then
        FOnComplete(Self);
    end);
end;

procedure TGemmaEngineBridge.DoError(const ErrorMessage: string);
begin
  TThread.Queue(nil,
    procedure
    begin
      if Assigned(FOnError) then
        FOnError(Self, ErrorMessage);
    end);
end;

function TGemmaEngineBridge.InitEngine(const Config: TGemmaEngineConfig): Boolean;
begin
  {$IFDEF ANDROID}
  Result := TJGemmaEngine.JavaClass.initEngine(
    TAndroidHelper.Context,
    StringToJString(Config.ModelPath),
    Config.MaxTokens,
    Config.Temperature,
    Config.TopK,
    Config.TopP,
    Config.UseGpu);
  FInitialized := Result;
  {$ELSE}
  raise ENotImplemented.Create('GemmaEngine is only available on Android.');
  {$ENDIF}
end;

function TGemmaEngineBridge.ResetSession(Temperature: Single; TopK: Integer;
  TopP: Single): Boolean;
begin
  {$IFDEF ANDROID}
  Result := TJGemmaEngine.JavaClass.resetSession(Temperature, TopK, TopP);
  {$ELSE}
  raise ENotImplemented.Create('GemmaEngine is only available on Android.');
  {$ENDIF}
end;

procedure TGemmaEngineBridge.Generate(const Prompt: string);
begin
  {$IFDEF ANDROID}
  TJGemmaEngine.JavaClass.generate(
    StringToJString(Prompt),
    (FListener as TGemmaListenerBridge));
  {$ELSE}
  raise ENotImplemented.Create('GemmaEngine is only available on Android.');
  {$ENDIF}
end;

procedure TGemmaEngineBridge.CancelGenerate;
begin
  {$IFDEF ANDROID}
  TJGemmaEngine.JavaClass.cancelGenerate;
  {$ENDIF}
end;

procedure TGemmaEngineBridge.CloseEngine;
begin
  {$IFDEF ANDROID}
  if FInitialized then
  begin
    TJGemmaEngine.JavaClass.closeEngine;
    FInitialized := False;
  end;
  {$ENDIF}
end;

end.
