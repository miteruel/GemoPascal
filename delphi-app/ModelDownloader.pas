unit ModelDownloader;

{
  Downloads a Gemma .task model file to the app's private storage
  (TPath.GetDocumentsPath, which on Android maps to the app's internal
  files directory - not shared/external storage, so no storage permission is
  needed) and verifies its SHA-256 hash before handing the path to GemmaEngineBridge.

  Design decision: this unit owns ALL model acquisition (download, storage location, hash
  check). GemmaEngine (Kotlin) never talks to the network and never sees a URL - see
  GemmaEngineBridge.pas for why.

  Threading: DownloadModel is BLOCKING (it drives TNetHTTPRequest synchronously so progress
  can be reported deterministically via OnReceiveData). Callers MUST invoke it from a
  background thread/TTask. As with TGemmaEngineBridge, all of this unit's events
  (OnProgress/OnComplete/OnError) are marshaled onto the main thread internally, so UI code
  never has to call TThread.Queue itself.

  Resume support: if a previous call was interrupted (network drop, app backgrounded and the
  OS killed the connection, user cancelled), the partially-downloaded ".part" file is left on
  disk. The next DownloadModel call for the same DestFileName detects it and, if the server
  advertises Range support (checked with a cheap HEAD request first), resumes from the byte
  offset already on disk via a "Range: bytes=<offset>-" request instead of starting over. If
  the server doesn't advertise range support, the partial file is discarded and the download
  restarts from scratch - large model files otherwise mean re-downloading hundreds of MB after
  every interruption, which is exactly what was happening before this was added.
}

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Hash,
  System.Net.HttpClient, System.Net.HttpClientComponent, System.Net.URLClient;

type
  TDownloadProgressEvent = procedure(Sender: TObject; BytesReceived, TotalBytes: Int64) of object;
  TDownloadCompleteEvent = procedure(Sender: TObject; const LocalFilePath: string) of object;
  TDownloadErrorEvent = procedure(Sender: TObject; const ErrorMessage: string) of object;

  TModelDownloader = class
  private
    FHttpClient: TNetHTTPClient;
    FCancelled: Boolean;
    FResumeOffset: Int64;
    FOnProgress: TDownloadProgressEvent;
    FOnComplete: TDownloadCompleteEvent;
    FOnError: TDownloadErrorEvent;
    procedure HandleReceiveData(const Sender: TObject; AContentLength, AReadCount: Int64;
      var AAbort: Boolean);
    procedure DoProgress(BytesReceived, TotalBytes: Int64);
    procedure DoComplete(const LocalFilePath: string);
    procedure DoError(const ErrorMessage: string);
  public
    constructor Create;
    destructor Destroy; override;

    /// <summary>Returns the full path a model file with FileName would be stored at.</summary>
    class function GetLocalModelPath(const FileName: string): string; static;

    /// <summary>True if a file already exists at the given path and matches the hash.</summary>
    class function IsModelReady(const FilePath, ExpectedSha256Hex: string): Boolean; static;

    /// <summary>
    ///   Downloads Url to Documents/DestFileName, then verifies its SHA-256 against
    ///   ExpectedSha256Hex (hex, case-insensitive). Deletes the file and fires OnError on
    ///   mismatch. Pass an empty ExpectedSha256Hex to skip verification (not recommended).
    ///   Blocking - call from a background thread.
    ///
    ///   For gated models (e.g. Hugging Face's litert-community Gemma repositories require
    ///   an authenticated, license-accepted account), pass a pre-formatted BearerToken - see
    ///   the top-level README for how to obtain one. Never hard-code a token here.
    /// </summary>
    procedure DownloadModel(const Url, DestFileName, ExpectedSha256Hex: string;
      const BearerToken: string = '');

    /// <summary>Requests cancellation of an in-progress DownloadModel call.</summary>
    procedure Cancel;

    property OnProgress: TDownloadProgressEvent read FOnProgress write FOnProgress;
    property OnComplete: TDownloadCompleteEvent read FOnComplete write FOnComplete;
    property OnError: TDownloadErrorEvent read FOnError write FOnError;
  end;

implementation

{ TModelDownloader }

constructor TModelDownloader.Create;
begin
  inherited Create;
  FHttpClient := TNetHTTPClient.Create(nil);
  FHttpClient.OnReceiveData := HandleReceiveData;
end;

destructor TModelDownloader.Destroy;
begin
  FHttpClient.Free;
  inherited Destroy;
end;

class function TModelDownloader.GetLocalModelPath(const FileName: string): string;
begin
  Result := TPath.Combine(TPath.GetDocumentsPath, FileName);
end;

class function TModelDownloader.IsModelReady(const FilePath, ExpectedSha256Hex: string): Boolean;
begin
  Result := TFile.Exists(FilePath) and
    ((ExpectedSha256Hex = '') or
     SameText(THashSHA2.GetHashStringFromFile(FilePath), ExpectedSha256Hex));
end;

procedure TModelDownloader.HandleReceiveData(const Sender: TObject; AContentLength,
  AReadCount: Int64; var AAbort: Boolean);
begin
  AAbort := FCancelled;
  // AReadCount/AContentLength describe only the CURRENT request/response - when resuming,
  // that's just the remaining tail of the file, so FResumeOffset (0 for a non-resumed
  // download) is added to report progress against the file's true total size.
  if AContentLength > 0 then
    DoProgress(FResumeOffset + AReadCount, FResumeOffset + AContentLength)
  else
    DoProgress(FResumeOffset + AReadCount, 0);
end;

procedure TModelDownloader.DoProgress(BytesReceived, TotalBytes: Int64);
begin
  TThread.Queue(nil,
    procedure
    begin
      if Assigned(FOnProgress) then
        FOnProgress(Self, BytesReceived, TotalBytes);
    end);
end;

procedure TModelDownloader.DoComplete(const LocalFilePath: string);
begin
  TThread.Queue(nil,
    procedure
    begin
      if Assigned(FOnComplete) then
        FOnComplete(Self, LocalFilePath);
    end);
end;

procedure TModelDownloader.DoError(const ErrorMessage: string);
begin
  TThread.Queue(nil,
    procedure
    begin
      if Assigned(FOnError) then
        FOnError(Self, ErrorMessage);
    end);
end;

procedure TModelDownloader.DownloadModel(const Url, DestFileName, ExpectedSha256Hex: string;
  const BearerToken: string);
var
  DestPath, TempPath: string;
  FileStream: TFileStream;
  Response, HeadResponse: IHTTPResponse;
  ActualHash: string;
  ServerSupportsRanges: Boolean;
begin
  FCancelled := False;
  FResumeOffset := 0;
  DestPath := GetLocalModelPath(DestFileName);
  TempPath := DestPath + '.part';

  if IsModelReady(DestPath, ExpectedSha256Hex) then
  begin
    DoComplete(DestPath);
    Exit;
  end;

  TDirectory.CreateDirectory(TPath.GetDirectoryName(DestPath));

  if BearerToken <> '' then
    FHttpClient.CustomHeaders['Authorization'] := 'Bearer ' + BearerToken
  else
    FHttpClient.CustomHeaders['Authorization'] := '';

  // Resume detection: a leftover .part file from a previous interrupted attempt (network
  // drop, app backgrounded, manual cancel) means we can potentially continue instead of
  // re-downloading everything. A HEAD request is a cheap way to check whether the server
  // will actually honor a ranged GET before committing to one.
  if TFile.Exists(TempPath) and (TFile.GetSize(TempPath) > 0) then
  begin
    ServerSupportsRanges := False;
    try
      HeadResponse := FHttpClient.Head(Url);
      ServerSupportsRanges := SameText(HeadResponse.HeaderValue['Accept-Ranges'], 'bytes');
    except
      // Network hiccup on the HEAD probe itself - fall through and restart from scratch
      // below rather than fail the whole download over a preliminary check.
    end;
    if ServerSupportsRanges then
      FResumeOffset := TFile.GetSize(TempPath)
    else
      TFile.Delete(TempPath); // can't resume - discard the partial file, start clean
  end;

  if FResumeOffset > 0 then
  begin
    FileStream := TFileStream.Create(TempPath, fmOpenReadWrite or fmShareExclusive);
    FHttpClient.CustomHeaders['Range'] := Format('bytes=%d-', [FResumeOffset]);
  end
  else
  begin
    FileStream := TFileStream.Create(TempPath, fmCreate);
    FHttpClient.CustomHeaders['Range'] := '';
  end;
  try
    try
      FileStream.Seek(0, soEnd);

      Response := FHttpClient.Get(Url, FileStream);

      if FCancelled then
      begin
        DoError('Download cancelled.');
        Exit;
      end;

      if (FResumeOffset > 0) and (Response.StatusCode <> 206) then
      begin
        // The server advertised range support on the HEAD probe but didn't actually honor
        // the ranged GET (returned 200 with the full body instead of 206 with just the
        // tail) - the file stream now has stale bytes followed by a full duplicate, which
        // is corrupt. Discard it; the next attempt will start a clean full download.
        // FreeAndNil, not Free: the outer finally block below still runs Free on
        // FileStream unconditionally, which would double-free this same instance otherwise.
        FreeAndNil(FileStream);
        TFile.Delete(TempPath);
        DoError('The server did not resume this download as expected; the partial file ' +
          'was discarded. Tap Download model again to restart it from the beginning.');
        Exit;
      end;

      if not (Response.StatusCode in [200, 206]) then
      begin
        DoError(Format('Download failed: HTTP %d %s', [Response.StatusCode, Response.StatusText]));
        Exit;
      end;
    except
      on E: Exception do
      begin
        DoError('Download failed: ' + E.Message);
        Exit;
      end;
    end;
  finally
    FileStream.Free;
  end;

  if ExpectedSha256Hex <> '' then
  begin
    ActualHash := THashSHA2.GetHashStringFromFile(TempPath);
    if not SameText(ActualHash, ExpectedSha256Hex) then
    begin
      TFile.Delete(TempPath);
      DoError(Format('Model hash mismatch. Expected %s, got %s. The download may be ' +
        'corrupt or the URL may point to the wrong file.', [ExpectedSha256Hex, ActualHash]));
      Exit;
    end;
  end;

  if TFile.Exists(DestPath) then
    TFile.Delete(DestPath);
  TFile.Move(TempPath, DestPath);
  DoComplete(DestPath);
end;

procedure TModelDownloader.Cancel;
begin
  FCancelled := True;
end;

end.
