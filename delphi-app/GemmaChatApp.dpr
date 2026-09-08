program GemmaChatApp;

uses
  System.StartUpCopy,
  FMX.Forms,
  MainForm in 'MainForm.pas' {MainForm},
  GemmaEngineBridge in 'GemmaEngineBridge.pas',
  ModelDownloader in 'ModelDownloader.pas',
  ConversationStore in 'ConversationStore.pas',
  FilePicker in 'FilePicker.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TMainForm, MainAppForm);
  Application.Run;
end.
