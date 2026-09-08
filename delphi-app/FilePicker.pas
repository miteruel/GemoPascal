unit FilePicker;

{
  Lets the user pick an arbitrary file already on the device (Downloads, a file manager, a
  cloud-storage provider exposed through Android's document picker, ...) via the Storage
  Access Framework, and copies it into the app's private storage so GemmaEngineBridge can load
  it as a normal local file path - MediaPipe's LlmInference needs a real filesystem path, not
  a content:// URI.

  This is the app's second (and only other) unit that talks to Androidapi.JNI.* directly -
  isolated here for the same reason GemmaEngineBridge.pas is isolated: everything else in the
  app only sees the plain TFilePicker class below.

  Design decisions:
   - The picked file is always copied to a FIXED local filename (Documents/picked-model.task),
     mirroring ModelDownloader's DefaultModelFileName convention, rather than preserving the
     original filename - avoids the extra JNI surface (ContentResolver/DocumentsContract
     queries) needed to read a SAF document's real display name, which isn't needed for this
     app's purposes.
   - Uses ACTION_OPEN_DOCUMENT (not ACTION_GET_CONTENT): the modern, Google-recommended SAF
     picker intent, works the same way regardless of Android version/OEM file manager.
   - IMPORTANT: this only helps if the picked file is actually a MediaPipe .task bundle.
     Picking a .gguf (llama.cpp format) or anything else copies fine but fails later when
     GemmaEngineBridge.InitEngine tries to load it - there's no way to validate the model
     format before actually attempting to load it with the engine.

  Threading: PickFile itself is fire-and-forget from the main thread (it just launches an
  Android Activity and returns immediately). Android delivers the result on the main thread
  (onActivityResult), but the file copy that follows is blocking I/O that can take many
  seconds for a large model file, so it runs on a background TTask - OnPicked/OnError are
  then marshaled back onto the main thread via TThread.Queue before firing, the same
  convention GemmaEngineBridge/ModelDownloader use, so callers never need to think about
  threading here either. OnCancelled fires directly (no work to hop threads for).
}

interface

uses
  System.SysUtils, System.Classes, System.IOUtils;

type
  TFilePickedEvent = procedure(Sender: TObject; const LocalFilePath: string) of object;
  TFilePickErrorEvent = procedure(Sender: TObject; const ErrorMessage: string) of object;

  TFilePicker = class
  private
    FOnPicked: TFilePickedEvent;
    FOnError: TFilePickErrorEvent;
    FOnCancelled: TNotifyEvent;
    {$IFDEF ANDROID}
    FImpl: TObject; // actual type TAndroidFilePickerImpl, declared below in this unit
    {$ENDIF}
    procedure DoPicked(const LocalFilePath: string);
    procedure DoError(const ErrorMessage: string);
    procedure DoCancelled;
  public
    constructor Create;
    destructor Destroy; override;

    /// <summary>
    ///   Opens Android's native file picker. Returns immediately; results arrive later via
    ///   OnPicked / OnError / OnCancelled.
    /// </summary>
    procedure PickFile;

    property OnPicked: TFilePickedEvent read FOnPicked write FOnPicked;
    property OnError: TFilePickErrorEvent read FOnError write FOnError;
    property OnCancelled: TNotifyEvent read FOnCancelled write FOnCancelled;
  end;

implementation

{$IFDEF ANDROID}
uses
  System.Messaging, System.Threading,
  Androidapi.Helpers, Androidapi.JNIBridge,
  Androidapi.JNI.JavaTypes, Androidapi.JNI.GraphicsContentViewText,
  Androidapi.JNI.Net, Androidapi.JNI.App,
  FMX.Platform.Android;

const
  // Arbitrary - just needs to be a value this unit recognizes when Android hands the result
  // back, and not collide with request codes used elsewhere in the app (none currently exist).
  PickFileRequestCode = 7734;

type
  TAndroidFilePickerImpl = class
  private
    FOwner: TFilePicker;
    FSubscriptionId: Integer;
    procedure HandleActivityMessage(const Sender: TObject; const M: TMessage);
    procedure CopyUriToLocalFile(const Uri: Jnet_Uri);
  public
    constructor Create(AOwner: TFilePicker);
    destructor Destroy; override;
    procedure PickFile;
  end;

constructor TAndroidFilePickerImpl.Create(AOwner: TFilePicker);
begin
  inherited Create;
  FOwner := AOwner;
  FSubscriptionId := TMessageManager.DefaultManager.SubscribeToMessage(
    TMessageResultNotification, HandleActivityMessage);
end;

destructor TAndroidFilePickerImpl.Destroy;
begin
  TMessageManager.DefaultManager.Unsubscribe(TMessageResultNotification, FSubscriptionId);
  inherited Destroy;
end;

procedure TAndroidFilePickerImpl.PickFile;
var
  Intent: JIntent;
begin
  Intent := TJIntent.Create;
  Intent.setAction(TJIntent.JavaClass.ACTION_OPEN_DOCUMENT);
  Intent.addCategory(TJIntent.JavaClass.CATEGORY_OPENABLE);
  Intent.setType(StringToJString('*/*'));
  TAndroidHelper.Activity.startActivityForResult(Intent, PickFileRequestCode);
end;

procedure TAndroidFilePickerImpl.HandleActivityMessage(const Sender: TObject;
  const M: TMessage);
var
  Notification: TMessageResultNotification;
  Uri: Jnet_Uri;
begin
  if not (M is TMessageResultNotification) then
    Exit;
  Notification := TMessageResultNotification(M);
  if Notification.RequestCode <> PickFileRequestCode then
    Exit; // some other activity result this app triggered elsewhere - not ours

  if Notification.ResultCode <> TJActivity.JavaClass.RESULT_OK then
  begin
    FOwner.DoCancelled;
    Exit;
  end;

  if not Assigned(Notification.Value) then
  begin
    FOwner.DoError('No file was selected.');
    Exit;
  end;

  Uri := Notification.Value.getData;
  if not Assigned(Uri) then
  begin
    FOwner.DoError('No file was selected.');
    Exit;
  end;

  // This message handler runs on the main thread (Android delivers onActivityResult there,
  // and FMX posts this TMessage from within that callback) - the copy below is blocking I/O
  // that can run for many seconds on a large model file, so it must not happen here. Move it
  // to a background task; CopyUriToLocalFile marshals its own completion back to the main
  // thread before calling FOwner.DoPicked/DoError.
  TTask.Run(
    procedure
    begin
      CopyUriToLocalFile(Uri);
    end);
end;

procedure TAndroidFilePickerImpl.CopyUriToLocalFile(const Uri: Jnet_Uri);
const
  BufferSize = 65536;
var
  SourceStream: JInputStream;
  DestStream: JFileOutputStream;
  Buffer: TJavaArray<Byte>;
  BytesRead: Integer;
  DestPath, TempPath: string;
begin
  DestPath := TPath.Combine(TPath.GetDocumentsPath, 'picked-model.task');
  TempPath := DestPath + '.part';
  SourceStream := nil;
  DestStream := nil;
  Buffer := nil;
  try
    SourceStream := TAndroidHelper.Context.getContentResolver.openInputStream(Uri);
    if not Assigned(SourceStream) then
    begin
      TThread.Queue(nil,
        procedure
        begin
          FOwner.DoError('Could not open the selected file.');
        end);
      Exit;
    end;

    DestStream := TJFileOutputStream.JavaClass.init(StringToJString(TempPath));
    Buffer := TJavaArray<Byte>.Create(BufferSize);

    BytesRead := SourceStream.read(Buffer);
    while BytesRead > 0 do
    begin
      DestStream.write(Buffer, 0, BytesRead);
      BytesRead := SourceStream.read(Buffer);
    end;

    DestStream.close;
    DestStream := nil;
    SourceStream.close;
    SourceStream := nil;

    if TFile.Exists(DestPath) then
      TFile.Delete(DestPath);
    TFile.Move(TempPath, DestPath);
    TThread.Queue(nil,
      procedure
      begin
        FOwner.DoPicked(DestPath);
      end);
  except
    on E: Exception do
    begin
      try
        if Assigned(DestStream) then
          DestStream.close;
        if Assigned(SourceStream) then
          SourceStream.close;
      except
        // Best-effort cleanup only.
      end;
      if TFile.Exists(TempPath) then
        TFile.Delete(TempPath);
      TThread.Queue(nil,
        procedure
        begin
          FOwner.DoError('Failed to copy the selected file: ' + E.Message);
        end);
    end;
  end;
  Buffer.Free;
end;

{$ENDIF}

{ TFilePicker }

constructor TFilePicker.Create;
begin
  inherited Create;
  {$IFDEF ANDROID}
  FImpl := TAndroidFilePickerImpl.Create(Self);
  {$ENDIF}
end;

destructor TFilePicker.Destroy;
begin
  {$IFDEF ANDROID}
  FImpl.Free;
  {$ENDIF}
  inherited Destroy;
end;

procedure TFilePicker.PickFile;
begin
  {$IFDEF ANDROID}
  (FImpl as TAndroidFilePickerImpl).PickFile;
  {$ELSE}
  raise ENotImplemented.Create('File picking is only available on Android.');
  {$ENDIF}
end;

procedure TFilePicker.DoPicked(const LocalFilePath: string);
begin
  if Assigned(FOnPicked) then
    FOnPicked(Self, LocalFilePath);
end;

procedure TFilePicker.DoError(const ErrorMessage: string);
begin
  if Assigned(FOnError) then
    FOnError(Self, ErrorMessage);
end;

procedure TFilePicker.DoCancelled;
begin
  if Assigned(FOnCancelled) then
    FOnCancelled(Self);
end;

end.
