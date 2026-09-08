{
  Copyright (C) 2026 Antonio Alcázar Ruiz (MiTeruel) <mrgarciagarcia@gmail.com>
  Part of the PluTony project. Licensed under the GNU GPL v3.0 or later;
  see LICENSE for the full text.
}

unit MainForm;

{
  Chat UI for the Gemma on-device demo app. This unit has NO direct dependency on any
  Androidapi.JNI.* unit - all native/JNI concerns are isolated in GemmaEngineBridge.pas and
  ModelDownloader.pas, which this form only talks to through their plain Pascal APIs.

  The whole UI is built in code (FormCreate) rather than declared in MainForm.fmx, to avoid
  hand-authoring a large, error-prone hierarchy of FMX form-file property blocks; MainForm.fmx
  only declares the bare TForm shell. This is a deliberate simplicity/robustness trade-off -
  functionally equivalent to a designer-built form.
}

interface

uses
  System.SysUtils, System.Classes, System.Threading, System.UITypes, System.IOUtils,
  System.Types, System.Generics.Collections, System.Rtti,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs,
  FMX.StdCtrls, FMX.Edit, FMX.Layouts, FMX.Objects, FMX.ScrollBox, FMX.TextLayout,
  FMX.DialogService, FMX.Platform,
  GemmaEngineBridge, ModelDownloader, ConversationStore, FilePicker;

type
  TMainForm = class(TForm)
  private
    { Engine / model state }
    FBridge: TGemmaEngineBridge;
    FDownloader: TModelDownloader;
    FFilePicker: TFilePicker;
    FModelLocalPath: string;
    FGenerating: Boolean;
    FCurrentAssistantBubble: TLabel;
    // Raw, untrimmed accumulator for the in-progress assistant response - kept separate from
    // FCurrentAssistantBubble.Text (which always shows TrimRight(this)) so trailing whitespace/
    // blank lines the model streams out don't inflate the measured bubble height (see
    // HandleToken), while still concatenating tokens correctly (a token that is just a space
    // must not be lost before the next token arrives).
    FCurrentAssistantRawText: string;

    { Conversation persistence - see ConversationStore.pas }
    FMessages: TList<TChatMessage>;
    FCurrentConversationId: string;
    FCurrentConversationTitle: string;

    { Chrome }
    FToolBar: TToolBar;
    FTitleLabel: TLabel;
    FHistoryButton: TButton;
    FSettingsButton: TButton;
    FResetButton: TButton;
    FBusyIndicator: TAniIndicator;

    { History panel }
    FHistoryPanel: TLayout;
    FNewConversationButton: TButton;
    FHistoryScrollBox: TVertScrollBox;

    { Settings panel }
    FSettingsPanel: TLayout;
    FModelUrlEdit: TEdit;
    FHFTokenEdit: TEdit;
    FMaxTokensTrack: TTrackBar;
    FMaxTokensLabel: TLabel;
    FTemperatureTrack: TTrackBar;
    FTemperatureLabel: TLabel;
    FTopKTrack: TTrackBar;
    FTopKLabel: TLabel;
    FTopPTrack: TTrackBar;
    FTopPLabel: TLabel;
    FUseGpuCheckBox: TCheckBox;
    FDownloadButton: TButton;
    FBrowseButton: TButton;
    FLoadEngineButton: TButton;
    FDownloadProgressBar: TProgressBar;
    FStatusLabel: TLabel;

    { Chat }
    FChatScrollBox: TVertScrollBox;
    FInputPanel: TLayout;
    FPromptEdit: TEdit;
    FSendButton: TButton;

    procedure BuildUI;
    function AddBubble(const AText: string; IsUser: Boolean;
      MessageIndex: Integer = -1): TLabel;
    function MeasureWrappedHeight(const AText: string; AFont: TFont; AWidth: Single): Single;
    procedure ResizeBubbleToLabel(ALabel: TLabel);
    procedure ScrollChatToBottom;
    procedure ClearChatScrollBox;
    procedure RenderChatMessages;
    procedure CopyToClipboard(const AText: string);
    procedure BubbleTextClick(Sender: TObject);
    procedure DeleteBubbleClick(Sender: TObject);
    procedure SetBusy(ABusy: Boolean; const AStatusText: string = '');

    procedure MaxTokensTrackChange(Sender: TObject);
    procedure TemperatureTrackChange(Sender: TObject);
    procedure TopKTrackChange(Sender: TObject);
    procedure TopPTrackChange(Sender: TObject);

    procedure SettingsButtonClick(Sender: TObject);
    procedure HistoryButtonClick(Sender: TObject);
    procedure NewConversationButtonClick(Sender: TObject);
    procedure ConversationRowClick(Sender: TObject);
    procedure DeleteConversationClick(Sender: TObject);
    procedure ResetButtonClick(Sender: TObject);
    procedure DownloadButtonClick(Sender: TObject);
    procedure BrowseButtonClick(Sender: TObject);
    procedure LoadEngineButtonClick(Sender: TObject);
    procedure SendButtonClick(Sender: TObject);
    procedure CancelGeneration;

    procedure HandleFilePicked(Sender: TObject; const LocalFilePath: string);
    procedure HandleFilePickError(Sender: TObject; const ErrorMessage: string);
    procedure HandleFilePickCancelled(Sender: TObject);

    procedure RefreshHistoryList;
    procedure StartNewConversation;
    procedure LoadConversation(const Id: string);
    procedure PersistCurrentConversation;
    procedure ResetEngineSessionAsync(const OnDone: TProc);

    procedure HandleDownloadProgress(Sender: TObject; BytesReceived, TotalBytes: Int64);
    procedure HandleDownloadComplete(Sender: TObject; const LocalFilePath: string);
    procedure HandleDownloadError(Sender: TObject; const ErrorMessage: string);

    procedure HandleToken(Sender: TObject; const Token: string);
    procedure HandleComplete(Sender: TObject);
    procedure HandleGenerateError(Sender: TObject; const ErrorMessage: string);

    function CurrentMaxTokens: Integer;
    function CurrentTemperature: Single;
    function CurrentTopK: Integer;
    function CurrentTopP: Single;
  published
    // Must be `published`, not `private`: the .fmx streaming system that resolves
    // OnCreate = FormCreate / OnDestroy = FormDestroy at runtime uses classic RTTI, which
    // only sees published members. A private method here compiles fine but fails at
    // startup with "Error reading MainForm.OnCreate: Invalid property value".
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  end;

var
  // Deliberately not named "MainForm" - that would collide with this unit's own name
  // (unit MainForm; ... var MainForm: ...), which the compiler resolves inconsistently.
  MainAppForm: TMainForm;

implementation

{$R *.fmx}

const
  // Default local filename the downloaded model is stored under. Kept independent of the
  // source URL's filename so switching URLs in Settings does not orphan old downloads.
  DefaultModelFileName = 'gemma-model.task';

  // Default points at the smallest 4-bit-quantized Gemma 3 1B build in the
  // litert-community/Gemma3-1B-IT repo (verified to exist - HEAD returns 401 Unauthorized,
  // not 404 - confirming the filename, since the repo is gated and requires a token either
  // way). The repo's license must still be accepted and a personal access token supplied by
  // the user in the Settings panel - neither of those can or should be hard-coded here. If
  // you want a different quantization variant, just change this URL (and DefaultModelFileName
  // below if you want distinct downloads to coexist) - see ../README.md.
  DefaultModelUrl =
    'https://huggingface.co/litert-community/Gemma3-1B-IT/resolve/main/gemma3-1b-it-int4.task';

  // Left blank deliberately: computing this requires downloading the file (which requires a
  // token this project must never embed). Fill it in yourself once you've downloaded the file
  // once - see ../delphi-app/README.md "Getting a Gemma .task model" step 5 - so future
  // downloads are verified against it instead of trusted unconditionally.
  DefaultExpectedSha256 = '';

  // Fixed height of the Copy/Delete action strip rendered below every chat bubble - see
  // AddBubble and ResizeBubbleToLabel.
  ChatActionsRowHeight = 32;

{ TMainForm }

procedure TMainForm.FormCreate(Sender: TObject);
begin
  FBridge := TGemmaEngineBridge.Create;
  FBridge.OnToken := HandleToken;
  FBridge.OnComplete := HandleComplete;
  FBridge.OnError := HandleGenerateError;

  FDownloader := TModelDownloader.Create;
  FDownloader.OnProgress := HandleDownloadProgress;
  FDownloader.OnComplete := HandleDownloadComplete;
  FDownloader.OnError := HandleDownloadError;

  FFilePicker := TFilePicker.Create;
  FFilePicker.OnPicked := HandleFilePicked;
  FFilePicker.OnError := HandleFilePickError;
  FFilePicker.OnCancelled := HandleFilePickCancelled;

  FModelLocalPath := TModelDownloader.GetLocalModelPath(DefaultModelFileName);

  FMessages := TList<TChatMessage>.Create;
  FCurrentConversationId := TConversationStore.NewConversationId;
  FCurrentConversationTitle := '';

  BuildUI;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  FDownloader.Free;
  FFilePicker.Free;
  FBridge.Free; // TGemmaEngineBridge.Destroy calls CloseEngine
  FMessages.Free;
end;

{ ---------------------------------------------------------------- UI construction }

procedure TMainForm.BuildUI;
var
  LabelRow: TLayout;
begin
  { Toolbar }
  FToolBar := TToolBar.Create(Self);
  FToolBar.Parent := Self;
  FToolBar.Align := TAlignLayout.Top;
  FToolBar.Height := 48;

  FTitleLabel := TLabel.Create(Self);
  FTitleLabel.Parent := FToolBar;
  FTitleLabel.Align := TAlignLayout.Client;
  FTitleLabel.Margins.Left := 12;
  FTitleLabel.Text := 'Gemma Chat';
  FTitleLabel.TextSettings.Font.Size := 18;
  FTitleLabel.TextSettings.VertAlign := TTextAlign.Center;

  FResetButton := TButton.Create(Self);
  FResetButton.Parent := FToolBar;
  FResetButton.Align := TAlignLayout.Right;
  FResetButton.Width := 44;
  FResetButton.Text := 'Reset';
  FResetButton.OnClick := ResetButtonClick;

  FSettingsButton := TButton.Create(Self);
  FSettingsButton.Parent := FToolBar;
  FSettingsButton.Align := TAlignLayout.Right;
  FSettingsButton.Width := 44;
  FSettingsButton.Text := 'Settings';
  FSettingsButton.OnClick := SettingsButtonClick;

  FHistoryButton := TButton.Create(Self);
  FHistoryButton.Parent := FToolBar;
  FHistoryButton.Align := TAlignLayout.Right;
  FHistoryButton.Width := 52;
  FHistoryButton.Text := 'History';
  FHistoryButton.OnClick := HistoryButtonClick;

  { Busy indicator, overlaid top-right under the toolbar }
  FBusyIndicator := TAniIndicator.Create(Self);
  FBusyIndicator.Parent := Self;
  FBusyIndicator.Position.X := 8;
  FBusyIndicator.Position.Y := 56;
  FBusyIndicator.Width := 24;
  FBusyIndicator.Height := 24;
  FBusyIndicator.Enabled := False;
  FBusyIndicator.Visible := False;

  FStatusLabel := TLabel.Create(Self);
  FStatusLabel.Parent := Self;
  FStatusLabel.Position.X := 40;
  FStatusLabel.Position.Y := 58;
  FStatusLabel.Width := 400;
  FStatusLabel.Height := 20;
  FStatusLabel.Text := '';

  { Input panel (bottom) }
  FInputPanel := TLayout.Create(Self);
  FInputPanel.Parent := Self;
  FInputPanel.Align := TAlignLayout.Bottom;
  FInputPanel.Height := 56;
  FInputPanel.Margins.Left := 8;
  FInputPanel.Margins.Right := 8;
  FInputPanel.Margins.Bottom := 8;

  FSendButton := TButton.Create(Self);
  FSendButton.Parent := FInputPanel;
  FSendButton.Align := TAlignLayout.Right;
  FSendButton.Width := 72;
  FSendButton.Text := 'Send';
  FSendButton.OnClick := SendButtonClick;

  FPromptEdit := TEdit.Create(Self);
  FPromptEdit.Parent := FInputPanel;
  FPromptEdit.Align := TAlignLayout.Client;
  FPromptEdit.Margins.Right := 8;
  FPromptEdit.TextPrompt := 'Type a message...';

  { Settings panel (collapsible, hidden by default) }
  FSettingsPanel := TLayout.Create(Self);
  FSettingsPanel.Parent := Self;
  FSettingsPanel.Align := TAlignLayout.Top;
  FSettingsPanel.Height := 500;
  FSettingsPanel.Visible := False;
  FSettingsPanel.Padding.Left := 12;
  FSettingsPanel.Padding.Right := 12;
  FSettingsPanel.Padding.Top := 8;

  FModelUrlEdit := TEdit.Create(Self);
  FModelUrlEdit.Parent := FSettingsPanel;
  FModelUrlEdit.Align := TAlignLayout.MostTop;
  FModelUrlEdit.Height := 32;
  FModelUrlEdit.TextPrompt := 'Model .task download URL (Hugging Face)';
  FModelUrlEdit.Text := DefaultModelUrl;

  FHFTokenEdit := TEdit.Create(Self);
  FHFTokenEdit.Parent := FSettingsPanel;
  FHFTokenEdit.Align := TAlignLayout.MostTop;
  FHFTokenEdit.Margins.Top := 4;
  FHFTokenEdit.Height := 32;
  FHFTokenEdit.Password := True;
  FHFTokenEdit.TextPrompt := 'Hugging Face access token (optional, for gated models)';

  FDownloadButton := TButton.Create(Self);
  FDownloadButton.Parent := FSettingsPanel;
  FDownloadButton.Align := TAlignLayout.MostTop;
  FDownloadButton.Margins.Top := 4;
  FDownloadButton.Height := 36;
  FDownloadButton.Text := 'Download model';
  FDownloadButton.OnClick := DownloadButtonClick;

  FBrowseButton := TButton.Create(Self);
  FBrowseButton.Parent := FSettingsPanel;
  FBrowseButton.Align := TAlignLayout.MostTop;
  FBrowseButton.Margins.Top := 4;
  FBrowseButton.Height := 36;
  FBrowseButton.Text := 'Or pick a .task file already on this device...';
  FBrowseButton.OnClick := BrowseButtonClick;

  FDownloadProgressBar := TProgressBar.Create(Self);
  FDownloadProgressBar.Parent := FSettingsPanel;
  FDownloadProgressBar.Align := TAlignLayout.MostTop;
  FDownloadProgressBar.Margins.Top := 4;
  FDownloadProgressBar.Height := 8;
  FDownloadProgressBar.Min := 0;
  FDownloadProgressBar.Max := 100;
  FDownloadProgressBar.Value := 0;

  // MaxTokens
  LabelRow := TLayout.Create(Self);
  LabelRow.Parent := FSettingsPanel;
  LabelRow.Align := TAlignLayout.MostTop;
  LabelRow.Margins.Top := 8;
  LabelRow.Height := 24;
  FMaxTokensLabel := TLabel.Create(Self);
  FMaxTokensLabel.Parent := LabelRow;
  FMaxTokensLabel.Align := TAlignLayout.Client;
  FMaxTokensLabel.Text := 'Max tokens: 512';
  FMaxTokensTrack := TTrackBar.Create(Self);
  FMaxTokensTrack.Parent := FSettingsPanel;
  FMaxTokensTrack.Align := TAlignLayout.MostTop;
  FMaxTokensTrack.Height := 24;
  FMaxTokensTrack.Min := 64;
  FMaxTokensTrack.Max := 2048;
  FMaxTokensTrack.Value := 512;
  FMaxTokensTrack.Frequency := 1;
  FMaxTokensTrack.OnChange := MaxTokensTrackChange;

  // Temperature
  LabelRow := TLayout.Create(Self);
  LabelRow.Parent := FSettingsPanel;
  LabelRow.Align := TAlignLayout.MostTop;
  LabelRow.Margins.Top := 8;
  LabelRow.Height := 24;
  FTemperatureLabel := TLabel.Create(Self);
  FTemperatureLabel.Parent := LabelRow;
  FTemperatureLabel.Align := TAlignLayout.Client;
  FTemperatureLabel.Text := 'Temperature: 0.80';
  FTemperatureTrack := TTrackBar.Create(Self);
  FTemperatureTrack.Parent := FSettingsPanel;
  FTemperatureTrack.Align := TAlignLayout.MostTop;
  FTemperatureTrack.Height := 24;
  FTemperatureTrack.Min := 0;
  FTemperatureTrack.Max := 100;
  FTemperatureTrack.Value := 80;
  FTemperatureTrack.OnChange := TemperatureTrackChange;

  // Top-K
  LabelRow := TLayout.Create(Self);
  LabelRow.Parent := FSettingsPanel;
  LabelRow.Align := TAlignLayout.MostTop;
  LabelRow.Margins.Top := 8;
  LabelRow.Height := 24;
  FTopKLabel := TLabel.Create(Self);
  FTopKLabel.Parent := LabelRow;
  FTopKLabel.Align := TAlignLayout.Client;
  FTopKLabel.Text := 'Top-K: 40';
  FTopKTrack := TTrackBar.Create(Self);
  FTopKTrack.Parent := FSettingsPanel;
  FTopKTrack.Align := TAlignLayout.MostTop;
  FTopKTrack.Height := 24;
  FTopKTrack.Min := 1;
  FTopKTrack.Max := 100;
  FTopKTrack.Value := 40;
  FTopKTrack.OnChange := TopKTrackChange;

  // Top-P
  LabelRow := TLayout.Create(Self);
  LabelRow.Parent := FSettingsPanel;
  LabelRow.Align := TAlignLayout.MostTop;
  LabelRow.Margins.Top := 8;
  LabelRow.Height := 24;
  FTopPLabel := TLabel.Create(Self);
  FTopPLabel.Parent := LabelRow;
  FTopPLabel.Align := TAlignLayout.Client;
  FTopPLabel.Text := 'Top-P: 0.90';
  FTopPTrack := TTrackBar.Create(Self);
  FTopPTrack.Parent := FSettingsPanel;
  FTopPTrack.Align := TAlignLayout.MostTop;
  FTopPTrack.Height := 24;
  FTopPTrack.Min := 0;
  FTopPTrack.Max := 100;
  FTopPTrack.Value := 90;
  FTopPTrack.OnChange := TopPTrackChange;

  FUseGpuCheckBox := TCheckBox.Create(Self);
  FUseGpuCheckBox.Parent := FSettingsPanel;
  FUseGpuCheckBox.Align := TAlignLayout.MostTop;
  FUseGpuCheckBox.Margins.Top := 8;
  FUseGpuCheckBox.Height := 24;
  FUseGpuCheckBox.Text := 'Use GPU (faster, but less reliable on some devices)';
  // Off by default: on at least one real test device, the GPU delegate initialized fine but
  // failed during actual generation (recoverable automatically if enabled - see
  // GemmaEngine.kt's handleGenerationFailure - but CPU-first avoids hitting that at all).
  FUseGpuCheckBox.IsChecked := False;

  FLoadEngineButton := TButton.Create(Self);
  FLoadEngineButton.Parent := FSettingsPanel;
  FLoadEngineButton.Align := TAlignLayout.MostTop;
  FLoadEngineButton.Margins.Top := 12;
  FLoadEngineButton.Height := 36;
  FLoadEngineButton.Text := 'Load engine';
  FLoadEngineButton.OnClick := LoadEngineButtonClick;

  { History panel (collapsible, hidden by default) - lists saved conversations (see
    ConversationStore.pas) and lets the user start a new one or reopen an old one. }
  FHistoryPanel := TLayout.Create(Self);
  FHistoryPanel.Parent := Self;
  FHistoryPanel.Align := TAlignLayout.Top;
  FHistoryPanel.Height := 320;
  FHistoryPanel.Visible := False;
  FHistoryPanel.Padding.Left := 12;
  FHistoryPanel.Padding.Right := 12;
  FHistoryPanel.Padding.Top := 8;
  FHistoryPanel.Padding.Bottom := 8;

  FNewConversationButton := TButton.Create(Self);
  FNewConversationButton.Parent := FHistoryPanel;
  FNewConversationButton.Align := TAlignLayout.Top;
  FNewConversationButton.Height := 36;
  FNewConversationButton.Text := 'New conversation';
  FNewConversationButton.OnClick := NewConversationButtonClick;

  FHistoryScrollBox := TVertScrollBox.Create(Self);
  FHistoryScrollBox.Parent := FHistoryPanel;
  FHistoryScrollBox.Align := TAlignLayout.Client;
  FHistoryScrollBox.Margins.Top := 8;

  { Chat area (fills remaining space between toolbar/settings and input panel).
    Bubble rows are parented directly to the scroll box with Align = Top, which is enough
    for FMX to stack them top-to-bottom in creation order and for TVertScrollBox to compute
    its scrollable content extent from their bounds - no extra content-holder layout needed. }
  FChatScrollBox := TVertScrollBox.Create(Self);
  FChatScrollBox.Parent := Self;
  FChatScrollBox.Align := TAlignLayout.Client;
end;

function TMainForm.AddBubble(const AText: string; IsUser: Boolean;
  MessageIndex: Integer = -1): TLabel;
var
  Row: TLayout;
  BubbleWrap: TLayout;
  ActionsWrap: TLayout;
  Bubble: TRectangle;
  TextLabel: TLabel;
  DelBtn: TButton;
  BubbleSide: TAlignLayout;
begin
  Row := TLayout.Create(Self);
  Row.Parent := FChatScrollBox;
  Row.Align := TAlignLayout.Top;
  Row.Height := 44 + ChatActionsRowHeight;
  Row.Margins.Top := 4;
  Row.Margins.Left := 8;
  Row.Margins.Right := 8;

  { BubbleWrap separates the bubble's own content-driven height from the fixed action strip
    below it (see ActionsWrap), and gives ResizeBubbleToLabel an unambiguous place to set the
    height that actually drives Bubble's size - Bubble.Align is Left/Right, which in FMX
    stretches a control's Height to match its immediate PARENT's, so BubbleWrap.Height (not
    Bubble.Height itself) is the real control point. See ResizeBubbleToLabel for why this
    separation matters (it's what fixed bubbles growing on every streamed token). }
  BubbleWrap := TLayout.Create(Self);
  BubbleWrap.Parent := Row;
  BubbleWrap.Align := TAlignLayout.Top;
  BubbleWrap.Height := 36;

  if IsUser then
    BubbleSide := TAlignLayout.Right
  else
    BubbleSide := TAlignLayout.Left;

  Bubble := TRectangle.Create(Self);
  Bubble.Parent := BubbleWrap;
  Bubble.XRadius := 12;
  Bubble.YRadius := 12;
  Bubble.Stroke.Kind := TBrushKind.None;
  Bubble.Width := 300;
  Bubble.Align := BubbleSide;
  if IsUser then
    Bubble.Fill.Color := $FF2B6CB0
  else
    Bubble.Fill.Color := $FFE2E8F0;

  { AutoSize deliberately NOT used here: TLabel.AutoSize + WordWrap is unreliable in FMX when
    Text is updated many times in rapid succession (as happens with token-by-token streaming) -
    in practice this produced huge, completely blank bubbles, because the label's own Height
    never correctly reflected its wrapped content. ResizeBubbleToLabel instead measures the
    wrapped text explicitly via TTextLayout (the same engine FMX itself uses to render text)
    and sets Height directly, which is immune to that timing issue. }
  TextLabel := TLabel.Create(Self);
  TextLabel.Parent := Bubble;
  TextLabel.Position.Point := TPointF.Create(12, 8);
  TextLabel.Width := 276;
  TextLabel.WordWrap := True;
  TextLabel.AutoSize := False;
  TextLabel.Text := AText;
  TextLabel.HitTest := True; // TLabel defaults to no hit-testing; needed for OnClick below
  TextLabel.OnClick := BubbleTextClick; // tap a bubble's text to copy it to the clipboard
  if IsUser then
    TextLabel.TextSettings.FontColor := TAlphaColors.White
  else
    TextLabel.TextSettings.FontColor := TAlphaColors.Black;

  { Action strip (Delete) below the bubble. Every row gets one, even transient bubbles that
    have no message index yet (the in-progress streaming reply, the "Model loaded" notice) -
    those just render it empty rather than skipping it, so ResizeBubbleToLabel's height math
    doesn't need to special-case which kind of row it's looking at. MessageIndex is only >= 0
    for bubbles that already correspond to a real FMessages entry - see AddBubble's call sites
    (SendButtonClick, LoadConversation, RenderChatMessages). }
  ActionsWrap := TLayout.Create(Self);
  ActionsWrap.Parent := Row;
  ActionsWrap.Align := TAlignLayout.Top;
  ActionsWrap.Height := ChatActionsRowHeight;
  ActionsWrap.Margins.Top := 2;

  if MessageIndex >= 0 then
  begin
    DelBtn := TButton.Create(Self);
    DelBtn.Parent := ActionsWrap;
    DelBtn.Align := BubbleSide;
    DelBtn.Width := 60;
    DelBtn.Text := 'Delete';
    DelBtn.Tag := MessageIndex;
    DelBtn.OnClick := DeleteBubbleClick;
  end;

  ResizeBubbleToLabel(TextLabel);
  ScrollChatToBottom;
  Result := TextLabel;
end;

function TMainForm.MeasureWrappedHeight(const AText: string; AFont: TFont; AWidth: Single): Single;
var
  Layout: TTextLayout;
begin
  Layout := TTextLayoutManager.DefaultTextLayout.Create;
  try
    Layout.BeginUpdate;
    try
      Layout.WordWrap := True;
      Layout.Font := AFont;
      Layout.MaxSize := TPointF.Create(AWidth, 100000);
      Layout.Text := AText;
    finally
      Layout.EndUpdate;
    end;
    Result := Layout.Height;
  finally
    Layout.Free;
  end;
end;

procedure TMainForm.ResizeBubbleToLabel(ALabel: TLabel);
var
  Bubble: TRectangle;
  BubbleWrap: TControl;
  Row: TControl;
  NeededHeight, BubbleHeight: Single;
begin
  NeededHeight := MeasureWrappedHeight(ALabel.Text, ALabel.TextSettings.Font, ALabel.Width);
  if NeededHeight < 20 then
    NeededHeight := 20; // keep a visible minimum even for very short/empty text
  ALabel.Height := NeededHeight;

  // Set BubbleWrap.Height (not Bubble.Height, and never read Bubble.Height back afterward):
  // Bubble.Align is Left/Right, which in FMX stretches a control's Height to match its
  // immediate PARENT's (BubbleWrap's) CURRENT height - so an assignment to Bubble.Height
  // itself gets silently reverted by FMX's own realign as a side effect of this very call.
  // Reading Bubble.Height back afterward (as an earlier version of this code did, driving
  // Row.Height straight off Bubble.Parent) therefore captured that stale, pre-resize value
  // instead of the freshly measured one - and since this runs on every streamed token, the
  // visible bubble grew by a fixed amount on every single token regardless of actual text
  // length, producing huge bubbles with a lot of trailing blank space on longer responses.
  // Driving BubbleWrap.Height/Row.Height directly from NeededHeight avoids that feedback loop.
  BubbleHeight := NeededHeight + 16;
  Bubble := ALabel.Parent as TRectangle;
  BubbleWrap := Bubble.Parent as TControl;
  BubbleWrap.Height := BubbleHeight;

  Row := BubbleWrap.Parent as TControl;
  Row.Height := BubbleHeight + ChatActionsRowHeight;
end;

procedure TMainForm.ScrollChatToBottom;
begin
  // TVertScrollBox clamps ViewportPosition to the valid content range, so an
  // intentionally oversized Y reliably scrolls to the bottom without needing to track the
  // total content height ourselves.
  FChatScrollBox.ViewportPosition := TPointF.Create(0, MaxInt);
end;

procedure TMainForm.ClearChatScrollBox;
begin
  // Same fix as FHistoryScrollBox in RefreshHistoryList: DeleteChildren + re-adding rows
  // (via AddBubble) crashed this TVertScrollBox on reuse on this device (silent native
  // crash). Recreating the scroll box itself avoids whatever stale internal content-bounds
  // state DeleteChildren was leaving behind.
  FChatScrollBox.Free;
  FChatScrollBox := TVertScrollBox.Create(Self);
  FChatScrollBox.Parent := Self;
  FChatScrollBox.Align := TAlignLayout.Client;
end;

/// <summary>
///   Rebuilds every visible chat bubble from FMessages, with correct Delete-button indices.
///   Used instead of adding/removing a single bubble in place, both because a lone message
///   might shift every later message's index and because this reuses the recreate-the-
///   scrollbox pattern (via ClearChatScrollBox) already proven safe on this device, rather
///   than mutating FChatScrollBox's children directly.
/// </summary>
procedure TMainForm.RenderChatMessages;
var
  I: Integer;
begin
  ClearChatScrollBox;
  for I := 0 to FMessages.Count - 1 do
    AddBubble(FMessages[I].Text, FMessages[I].IsUser, I);
  ScrollChatToBottom;
end;

procedure TMainForm.CopyToClipboard(const AText: string);
var
  ClipboardService: IFMXClipboardService;
begin
  if TPlatformServices.Current.SupportsPlatformService(IFMXClipboardService, ClipboardService) then
    ClipboardService.SetClipboard(TValue.From<string>(AText));
end;

procedure TMainForm.BubbleTextClick(Sender: TObject);
var
  BubbleText: string;
begin
  BubbleText := (Sender as TLabel).Text;
  if BubbleText = '' then
    Exit;
  CopyToClipboard(BubbleText);
  ShowMessage('Copied to clipboard.');
end;

procedure TMainForm.DeleteBubbleClick(Sender: TObject);
var
  Index: Integer;
begin
  Index := (Sender as TButton).Tag;
  if (Index < 0) or (Index >= FMessages.Count) then
    Exit; // stale tag from a since-rebuilt chat view - ignore rather than delete the wrong item

  TDialogService.MessageDialog(
    'Delete this message? This cannot be undone.',
    TMsgDlgType.mtConfirmation,
    [TMsgDlgBtn.mbYes, TMsgDlgBtn.mbNo],
    TMsgDlgBtn.mbNo,
    0,
    procedure(const AResult: TModalResult)
    begin
      if AResult <> mrYes then
        Exit;

      FMessages.Delete(Index);
      RenderChatMessages;

      if FMessages.Count = 0 then
        // Nothing left to save - remove the on-disk file too, instead of leaving it holding
        // the just-deleted message behind (PersistCurrentConversation itself declines to
        // write an empty conversation, so it would otherwise go stale rather than updating).
        TConversationStore.DeleteConversation(FCurrentConversationId)
      else
        PersistCurrentConversation;
    end);
end;

procedure TMainForm.SetBusy(ABusy: Boolean; const AStatusText: string);
begin
  FBusyIndicator.Visible := ABusy;
  FBusyIndicator.Enabled := ABusy;
  FStatusLabel.Text := AStatusText;
  FSendButton.Enabled := not ABusy;
  FLoadEngineButton.Enabled := not ABusy;
  FDownloadButton.Enabled := not ABusy;
  FBrowseButton.Enabled := not ABusy;
end;

{ ---------------------------------------------------------------- Settings helpers }

function TMainForm.CurrentMaxTokens: Integer;
begin
  Result := Round(FMaxTokensTrack.Value);
end;

function TMainForm.CurrentTemperature: Single;
begin
  Result := FTemperatureTrack.Value / 100;
end;

function TMainForm.CurrentTopK: Integer;
begin
  Result := Round(FTopKTrack.Value);
end;

function TMainForm.CurrentTopP: Single;
begin
  Result := FTopPTrack.Value / 100;
end;

{ ---------------------------------------------------------------- Event handlers }

procedure TMainForm.MaxTokensTrackChange(Sender: TObject);
begin
  FMaxTokensLabel.Text := Format('Max tokens: %d', [Round(FMaxTokensTrack.Value)]);
end;

procedure TMainForm.TemperatureTrackChange(Sender: TObject);
begin
  FTemperatureLabel.Text := Format('Temperature: %.2f', [FTemperatureTrack.Value / 100]);
end;

procedure TMainForm.TopKTrackChange(Sender: TObject);
begin
  FTopKLabel.Text := Format('Top-K: %d', [Round(FTopKTrack.Value)]);
end;

procedure TMainForm.TopPTrackChange(Sender: TObject);
begin
  FTopPLabel.Text := Format('Top-P: %.2f', [FTopPTrack.Value / 100]);
end;

procedure TMainForm.SettingsButtonClick(Sender: TObject);
begin
  FHistoryPanel.Visible := False;
  FSettingsPanel.Visible := not FSettingsPanel.Visible;
end;

procedure TMainForm.HistoryButtonClick(Sender: TObject);
begin
  FSettingsPanel.Visible := False;
  FHistoryPanel.Visible := not FHistoryPanel.Visible;
  if FHistoryPanel.Visible then
    RefreshHistoryList;
end;

procedure TMainForm.RefreshHistoryList;
var
  Conversations: TArray<TConversationMeta>;
  Meta: TConversationMeta;
  Row: TLayout;
  Btn, DelBtn: TButton;
  Lbl: TLabel;
begin
  // IMPORTANT (found via step-through debugging): a styled control (TLabel/TButton) added
  // as a DIRECT child of a TVertScrollBox with Align := TAlignLayout.Top crashes the app on
  // this device (silent native crash, no Delphi exception dialog, no logcat message - just
  // an immediate process exit). AddBubble's chat-bubble code never hit this because it always
  // interposes a plain TLayout (Align := Top) between the scroll box and the actual styled
  // content, which itself uses Align := Client (or explicit Position, for the innermost
  // label) - never Align directly on a styled control that is the scroll box's own child.
  // Every row below follows that same ScrollBox -> TLayout -> styled-control nesting.
  //
  // ALSO IMPORTANT: reusing FHistoryScrollBox via DeleteChildren + re-adding rows crashed the
  // SECOND time History was opened (worked fine the first time, when there was nothing to
  // delete). TVertScrollBox appears to be left with inconsistent internal content-bounds
  // state after DeleteChildren on this device. Recreating the scroll box itself from scratch
  // every time avoids that - cheap for a small list, and guarantees the same "freshly
  // created" state that's already confirmed to work.
  FHistoryScrollBox.Free;
  FHistoryScrollBox := TVertScrollBox.Create(Self);
  FHistoryScrollBox.Parent := FHistoryPanel;
  FHistoryScrollBox.Align := TAlignLayout.Client;
  FHistoryScrollBox.Margins.Top := 8;

  Conversations := TConversationStore.ListConversations;
  for Meta in Conversations do
  begin
    Row := TLayout.Create(Self);
    Row.Parent := FHistoryScrollBox;
    Row.Align := TAlignLayout.Top;
    Row.Height := 40;
    Row.Margins.Top := 4;

    // Create the Right-aligned delete button before the Client-aligned title button, so
    // Client correctly fills whatever width Right doesn't claim (standard dock-layout order).
    DelBtn := TButton.Create(Self);
    DelBtn.Parent := Row;
    DelBtn.Align := TAlignLayout.Right;
    DelBtn.Width := 44;
    DelBtn.Text := 'Delete';
    DelBtn.TagString := Meta.Id;
    DelBtn.OnClick := DeleteConversationClick;

    Btn := TButton.Create(Self);
    Btn.Parent := Row;
    Btn.Align := TAlignLayout.Client;
    Btn.Margins.Right := 4;
    Btn.Text := Meta.Title;
    Btn.TagString := Meta.Id;
    Btn.OnClick := ConversationRowClick;
  end;
  if Length(Conversations) = 0 then
  begin
    Row := TLayout.Create(Self);
    Row.Parent := FHistoryScrollBox;
    Row.Align := TAlignLayout.Top;
    Row.Height := 32;

    Lbl := TLabel.Create(Self);
    Lbl.Parent := Row;
    Lbl.Align := TAlignLayout.Client;
    Lbl.Text := 'No saved conversations yet.';
  end;
end;

procedure TMainForm.ConversationRowClick(Sender: TObject);
var
  Id: string;
begin
  Id := (Sender as TButton).TagString;
  LoadConversation(Id);
end;

procedure TMainForm.DeleteConversationClick(Sender: TObject);
var
  Id: string;
begin
  Id := (Sender as TButton).TagString;
  TDialogService.MessageDialog(
    'Delete this conversation? This cannot be undone.',
    TMsgDlgType.mtConfirmation,
    [TMsgDlgBtn.mbYes, TMsgDlgBtn.mbNo],
    TMsgDlgBtn.mbNo,
    0,
    procedure(const AResult: TModalResult)
    begin
      if AResult <> mrYes then
        Exit;

      TConversationStore.DeleteConversation(Id);

      if Id = FCurrentConversationId then
      begin
        // The conversation currently shown in the chat view was deleted. The live chat
        // itself (messages, engine session) is untouched - just detach it from the deleted
        // file so the next turn saves under a fresh id instead of recreating what was just
        // deleted.
        FCurrentConversationId := TConversationStore.NewConversationId;
        FCurrentConversationTitle := '';
      end;

      RefreshHistoryList;
    end);
end;

procedure TMainForm.NewConversationButtonClick(Sender: TObject);
begin
  ResetEngineSessionAsync(
    procedure
    begin
      StartNewConversation;
      FHistoryPanel.Visible := False;
    end);
end;

procedure TMainForm.PersistCurrentConversation;
begin
  if FMessages.Count = 0 then
    Exit; // nothing to save yet
  if FCurrentConversationTitle = '' then
    FCurrentConversationTitle := TConversationStore.DeriveTitle(FMessages[0].Text);
  TConversationStore.SaveConversation(FCurrentConversationId, FCurrentConversationTitle,
    FMessages.ToArray);
end;

/// <summary>
///   Resets the engine's conversation session (JNI call - always run off the main thread) and
///   invokes OnDone on the main thread afterward, whether or not an engine is even loaded yet.
///   Shared by Reset, New conversation, and loading a past conversation, since all three need
///   the model's context cleared before showing different visual state.
/// </summary>
procedure TMainForm.ResetEngineSessionAsync(const OnDone: TProc);
var
  Temperature, TopP: Single;
  TopK: Integer;
begin
  if FGenerating then
  begin
    // Closing/replacing the session while GemmaEngine.generate() still has a response
    // in flight on the old session can hang or crash the native side - block this rather
    // than race it. The user just needs to wait a moment or use Send's own cancel path.
    ShowMessage('Please wait for the current response to finish first.');
    Exit;
  end;

  if not FBridge.Initialized then
  begin
    if Assigned(OnDone) then
      OnDone;
    Exit;
  end;

  Temperature := CurrentTemperature;
  TopK := CurrentTopK;
  TopP := CurrentTopP;

  SetBusy(True, 'Resetting conversation...');
  TTask.Run(
    procedure
    var
      OK: Boolean;
    begin
      OK := FBridge.ResetSession(Temperature, TopK, TopP);
      TThread.Queue(nil,
        procedure
        begin
          SetBusy(False);
          if not OK then
            ShowMessage('Could not reset the conversation.');
          if Assigned(OnDone) then
            OnDone;
        end);
    end);
end;

procedure TMainForm.StartNewConversation;
begin
  FCurrentConversationId := TConversationStore.NewConversationId;
  FCurrentConversationTitle := '';
  FMessages.Clear;
  ClearChatScrollBox;
end;

procedure TMainForm.LoadConversation(const Id: string);
begin
  ResetEngineSessionAsync(
    procedure
    var
      LoadedMessages: TArray<TChatMessage>;
      Msg: TChatMessage;
    begin
      LoadedMessages := TConversationStore.LoadMessages(Id);

      FCurrentConversationId := Id;
      FCurrentConversationTitle := '';
      FMessages.Clear;
      ClearChatScrollBox;

      for Msg in LoadedMessages do
      begin
        FMessages.Add(Msg);
        AddBubble(Msg.Text, Msg.IsUser, FMessages.Count - 1);
      end;
      if FMessages.Count > 0 then
        FCurrentConversationTitle := TConversationStore.DeriveTitle(FMessages[0].Text);

      FHistoryPanel.Visible := False;

      // The model's own session has no supported way to have this history replayed into its
      // native context (see the limitation note at the top of ConversationStore.pas) - a
      // fresh session is the honest choice rather than silently pretending the model
      // remembers this.
      if FBridge.Initialized then
        ShowMessage('Loaded "' + FCurrentConversationTitle + '". You can see the earlier ' +
          'messages above, but the model itself starts this conversation fresh - it does ' +
          'not remember them.');
    end);
end;

procedure TMainForm.ResetButtonClick(Sender: TObject);
begin
  ResetEngineSessionAsync(
    procedure
    begin
      StartNewConversation;
    end);
end;

procedure TMainForm.DownloadButtonClick(Sender: TObject);
var
  Url, Token: string;
begin
  Url := FModelUrlEdit.Text.Trim;
  if Url = '' then
  begin
    ShowMessage('Enter a model download URL first (see README for where to get one).');
    Exit;
  end;
  Token := FHFTokenEdit.Text.Trim;

  SetBusy(True, 'Downloading model...');
  FDownloadProgressBar.Value := 0;

  TTask.Run(
    procedure
    begin
      // DefaultExpectedSha256 is intentionally blank in this template - see README for how
      // to fill in a real hash once you've picked a specific model file.
      FDownloader.DownloadModel(Url, DefaultModelFileName, DefaultExpectedSha256, Token);
    end);
end;

procedure TMainForm.BrowseButtonClick(Sender: TObject);
begin
  // FilePicker.PickFile launches Android's native file picker and returns immediately -
  // HandleFilePicked/HandleFilePickError/HandleFilePickCancelled fire later, on the main
  // thread, once the user has chosen something (or backed out).
  FFilePicker.PickFile;
end;

procedure TMainForm.HandleFilePicked(Sender: TObject; const LocalFilePath: string);
begin
  FModelLocalPath := LocalFilePath;
  ShowMessage('File copied. Tap "Load engine" to try loading it.' + sLineBreak + sLineBreak +
    'Note: this only works if the file is actually a MediaPipe .task bundle - picking a ' +
    '.gguf or other incompatible format will fail when you tap Load engine, since there is ' +
    'no way to check the format before actually attempting to load it.');
end;

procedure TMainForm.HandleFilePickError(Sender: TObject; const ErrorMessage: string);
begin
  ShowMessage('Could not use the selected file: ' + ErrorMessage);
end;

procedure TMainForm.HandleFilePickCancelled(Sender: TObject);
begin
  // Nothing to do - the user just backed out of the picker.
end;

procedure TMainForm.LoadEngineButtonClick(Sender: TObject);
var
  Config: TGemmaEngineConfig;
begin
  if not TFile.Exists(FModelLocalPath) then
  begin
    ShowMessage('No model downloaded yet. Use "Download model" first.');
    Exit;
  end;

  Config.ModelPath := FModelLocalPath;
  Config.MaxTokens := CurrentMaxTokens;
  Config.Temperature := CurrentTemperature;
  Config.TopK := CurrentTopK;
  Config.TopP := CurrentTopP;
  Config.UseGpu := FUseGpuCheckBox.IsChecked;

  SetBusy(True, 'Loading model (this can take a while)...');
  TTask.Run(
    procedure
    var
      OK: Boolean;
    begin
      OK := FBridge.InitEngine(Config);
      TThread.Queue(nil,
        procedure
        begin
          SetBusy(False);
          if OK then
          begin
            FSettingsPanel.Visible := False;
            AddBubble('Model loaded. Ask me anything.', False);
          end
          else
            ShowMessage('Failed to load the model. Check that the file is a valid ' +
              '.task bundle and that the device has enough free RAM.');
        end);
    end);
end;

procedure TMainForm.SendButtonClick(Sender: TObject);
var
  Prompt: string;
begin
  if FGenerating then
  begin
    // Button doubles as "Stop" while a response is streaming - see the Text/Enabled flip
    // right after SetBusy(True, 'Generating...') below.
    CancelGeneration;
    Exit;
  end;

  if not FBridge.Initialized then
  begin
    ShowMessage('Load the model first (Settings > Load engine).');
    Exit;
  end;

  Prompt := FPromptEdit.Text.Trim;
  if Prompt = '' then
    Exit;

  FMessages.Add(TChatMessage.Create(True, Prompt));
  AddBubble(Prompt, True, FMessages.Count - 1);
  FPromptEdit.Text := '';
  FCurrentAssistantRawText := '';
  FCurrentAssistantBubble := AddBubble('', False);
  FGenerating := True;
  SetBusy(True, 'Generating...');
  // SetBusy disables FSendButton by default (right for Download/Load/Reset), but here it
  // needs to stay enabled and become the Stop button instead.
  FSendButton.Enabled := True;
  FSendButton.Text := 'Stop';

  TTask.Run(
    procedure
    begin
      FBridge.Generate(Prompt);
    end);
end;

{ ---------------------------------------------------------------- Download callbacks
  (already marshaled to the main thread by TModelDownloader) }

procedure TMainForm.HandleDownloadProgress(Sender: TObject; BytesReceived, TotalBytes: Int64);
begin
  if TotalBytes > 0 then
  begin
    FDownloadProgressBar.Value := (BytesReceived / TotalBytes) * 100;
    FStatusLabel.Text := Format('Downloading: %.1f MB / %.1f MB',
      [BytesReceived / 1048576, TotalBytes / 1048576]);
  end
  else
    FStatusLabel.Text := Format('Downloading: %.1f MB', [BytesReceived / 1048576]);
end;

procedure TMainForm.HandleDownloadComplete(Sender: TObject; const LocalFilePath: string);
begin
  FModelLocalPath := LocalFilePath;
  SetBusy(False);
  ShowMessage('Model downloaded. You can now tap "Load engine".');
end;

procedure TMainForm.HandleDownloadError(Sender: TObject; const ErrorMessage: string);
begin
  SetBusy(False);
  ShowMessage('Download error: ' + ErrorMessage);
end;

{ ---------------------------------------------------------------- Generation callbacks
  (already marshaled to the main thread by TGemmaEngineBridge) }

procedure TMainForm.HandleToken(Sender: TObject; const Token: string);
begin
  if Assigned(FCurrentAssistantBubble) then
  begin
    // Display (and measure) TrimRight(raw) rather than the raw accumulator itself: the model
    // frequently streams trailing whitespace/blank lines at the end of its response, which
    // would otherwise get counted by MeasureWrappedHeight and show up as dead space at the
    // bottom of the bubble. Keeping the untrimmed text in FCurrentAssistantRawText (rather than
    // trimming in place) means a token that is only whitespace is not lost before the next
    // token arrives to follow it.
    FCurrentAssistantRawText := FCurrentAssistantRawText + Token;
    FCurrentAssistantBubble.Text := TrimRight(FCurrentAssistantRawText);
    ResizeBubbleToLabel(FCurrentAssistantBubble);
    ScrollChatToBottom;
  end;
end;

procedure TMainForm.HandleComplete(Sender: TObject);
begin
  FGenerating := False;
  if Assigned(FCurrentAssistantBubble) then
  begin
    FMessages.Add(TChatMessage.Create(False, FCurrentAssistantBubble.Text));
    PersistCurrentConversation;
    // Rebuild the chat view so the reply that just finished gets a proper Delete button with a
    // correct index - it was rendered without one while still streaming, since it wasn't in
    // FMessages yet (see AddBubble's MessageIndex parameter).
    RenderChatMessages;
  end;
  FCurrentAssistantBubble := nil;
  SetBusy(False);
  FSendButton.Text := 'Send';
end;

procedure TMainForm.HandleGenerateError(Sender: TObject; const ErrorMessage: string);
begin
  FGenerating := False;
  if Assigned(FCurrentAssistantBubble) and (FCurrentAssistantBubble.Text = '') then
    FCurrentAssistantBubble.Text := '[error]';
  FCurrentAssistantBubble := nil;
  SetBusy(False);
  FSendButton.Text := 'Send';
  ShowMessage('Generation error: ' + ErrorMessage);
end;

procedure TMainForm.CancelGeneration;
begin
  // Optimistic/immediate: reset our own UI state right away rather than waiting for Kotlin's
  // cancelGenerateResponseAsync to take effect and (maybe) call back - MediaPipe's exact
  // cancellation completion semantics aren't documented, so relying on a callback to unstick
  // the UI risked leaving it stuck on "Generating..." forever. Any tokens/completion/error
  // that still arrive afterward are harmless no-ops: HandleToken/HandleComplete/
  // HandleGenerateError all guard on Assigned(FCurrentAssistantBubble), which is nil by then.
  FGenerating := False;
  if Assigned(FCurrentAssistantBubble) then
  begin
    // Keep whatever partial response had streamed in so far - matches how most chat apps
    // treat a user-initiated Stop (partial answer kept, not discarded).
    if FCurrentAssistantBubble.Text <> '' then
    begin
      FMessages.Add(TChatMessage.Create(False, FCurrentAssistantBubble.Text));
      PersistCurrentConversation;
    end;
    // Rebuild so a kept partial reply gets a Delete button with a correct index, and any
    // leftover empty placeholder bubble (cancelled before any token arrived) is dropped from
    // view instead of lingering as a stray empty bubble.
    RenderChatMessages;
  end;
  FCurrentAssistantBubble := nil;
  SetBusy(False);
  FSendButton.Text := 'Send';

  TTask.Run(
    procedure
    begin
      FBridge.CancelGenerate;
    end);
end;

end.
