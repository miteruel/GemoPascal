{
  Copyright (C) 2026 Antonio Alcázar Ruiz (MiTeruel) <mrgarciagarcia@gmail.com>
  Part of the PluTony project. Licensed under the GNU GPL v3.0 or later;
  see LICENSE for the full text.
}

unit ConversationStore;

{
  Persists chat conversations as one JSON file per conversation under
  Documents/conversations/<id>.json, so past chats can be listed (with an auto-derived title)
  and reopened later from MainForm's History panel.

  IMPORTANT LIMITATION: reopening a past conversation restores the VISIBLE message log only.
  The underlying GemmaEngine/MediaPipe session has no supported way to have prior turns
  replayed into its native context (LlmInferenceSession's history is built exclusively through
  live generate calls, not by injecting already-known text) - so continuing an old conversation
  means the model starts with a FRESH context, even though earlier messages remain visible
  above for the user's own reference. MainForm surfaces this to the user when loading a past
  conversation rather than silently pretending full continuity.
}

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.JSON, System.DateUtils,
  System.Generics.Collections, System.Generics.Defaults;

type
  TChatMessage = record
    IsUser: Boolean;
    Text: string;
    constructor Create(AIsUser: Boolean; const AText: string);
  end;

  TConversationMeta = record
    Id: string;
    Title: string;
    UpdatedAt: TDateTime;
  end;

  TConversationStore = class
  private
    class function ConversationsDir: string; static;
    class function FilePath(const Id: string): string; static;
  public
    /// <summary>Generates a new, sortable, collision-safe conversation id.</summary>
    class function NewConversationId: string; static;

    /// <summary>Derives a short display title from a conversation's first user message.</summary>
    class function DeriveTitle(const FirstUserMessage: string): string; static;

    /// <summary>All saved conversations, most recently updated first.</summary>
    class function ListConversations: TArray<TConversationMeta>; static;

    /// <summary>Loads a conversation's messages. Returns an empty array if not found/corrupt.</summary>
    class function LoadMessages(const Id: string): TArray<TChatMessage>; static;

    /// <summary>Writes (overwrites) a conversation's title and full message list.</summary>
    class procedure SaveConversation(const Id, Title: string;
      const Messages: TArray<TChatMessage>); static;

    /// <summary>Permanently deletes a saved conversation, if it exists.</summary>
    class procedure DeleteConversation(const Id: string); static;
  end;

implementation

{ TChatMessage }

constructor TChatMessage.Create(AIsUser: Boolean; const AText: string);
begin
  IsUser := AIsUser;
  Text := AText;
end;

{ TConversationStore }

class function TConversationStore.ConversationsDir: string;
begin
  Result := TPath.Combine(TPath.GetDocumentsPath, 'conversations');
  if not TDirectory.Exists(Result) then
    TDirectory.CreateDirectory(Result);
end;

class function TConversationStore.FilePath(const Id: string): string;
begin
  Result := TPath.Combine(ConversationsDir, Id + '.json');
end;

class function TConversationStore.NewConversationId: string;
begin
  // Sortable by construction (matches file/UpdatedAt ordering) and unique enough for a
  // single-user local app - collisions would require two conversations starting in the same
  // millisecond.
  Result := FormatDateTime('yyyymmdd_hhnnsszzz', Now);
end;

class function TConversationStore.DeriveTitle(const FirstUserMessage: string): string;
var
  S: string;
begin
  S := FirstUserMessage.Trim;
  S := S.Replace(#13, ' ').Replace(#10, ' ');
  while S.Contains('  ') do
    S := S.Replace('  ', ' ');
  if S = '' then
    Exit('New conversation');
  if S.Length > 40 then
    S := S.Substring(0, 40) + '...';
  Result := S;
end;

class function TConversationStore.ListConversations: TArray<TConversationMeta>;
var
  Files: TArray<string>;
  I: Integer;
  FileName: string;
  JsonText: string;
  RootValue: TJSONValue;
  RootObj: TJSONObject;
  TitleValue: TJSONValue;
  Meta: TConversationMeta;
  MetaList: TList<TConversationMeta>;
begin
  MetaList := TList<TConversationMeta>.Create;
  try
    Files := TDirectory.GetFiles(ConversationsDir, '*.json');
    // Conversation ids are zero-padded "yyyymmdd_hhnnsszzz" timestamps (see
    // NewConversationId), so a plain ascending string sort of the filenames already sorts
    // them chronologically - walking the sorted array backwards below gives newest-first
    // without needing a custom per-record comparator. (A TComparer<TConversationMeta>.Construct
    // + TList<T>.Sort version of this crashed - EAccessViolation / native SIGTRAP from
    // infinite recursion in RTL sort internals on this device - so that approach is
    // deliberately avoided here.)
    TArray.Sort<string>(Files);
    for I := High(Files) downto Low(Files) do
    begin
      FileName := Files[I];
      try
        JsonText := TFile.ReadAllText(FileName, TEncoding.UTF8);
        RootValue := TJSONObject.ParseJSONValue(JsonText);
        if not (RootValue is TJSONObject) then
        begin
          RootValue.Free;
          Continue;
        end;
        RootObj := TJSONObject(RootValue);
        try
          Meta.Id := TPath.GetFileNameWithoutExtension(FileName);
          TitleValue := RootObj.Values['title'];
          if Assigned(TitleValue) then
            Meta.Title := TitleValue.Value
          else
            Meta.Title := 'Untitled';
          Meta.UpdatedAt := TFile.GetLastWriteTime(FileName);
          MetaList.Add(Meta);
        finally
          RootObj.Free;
        end;
      except
        // Skip unreadable/corrupt conversation files rather than fail the whole listing.
      end;
    end;
    Result := MetaList.ToArray;
  finally
    MetaList.Free;
  end;
end;

class function TConversationStore.LoadMessages(const Id: string): TArray<TChatMessage>;
var
  JsonText: string;
  RootValue: TJSONValue;
  RootObj: TJSONObject;
  MessagesValue: TJSONValue;
  MsgArray: TJSONArray;
  I: Integer;
  MsgObj: TJSONObject;
  RoleValue, TextValue: TJSONValue;
  Msg: TChatMessage;
  List: TList<TChatMessage>;
  Path: string;
begin
  List := TList<TChatMessage>.Create;
  try
    Path := FilePath(Id);
    if not TFile.Exists(Path) then
      Exit(List.ToArray);
    try
      JsonText := TFile.ReadAllText(Path, TEncoding.UTF8);
      RootValue := TJSONObject.ParseJSONValue(JsonText);
      if not (RootValue is TJSONObject) then
      begin
        RootValue.Free;
        Exit(List.ToArray);
      end;
      RootObj := TJSONObject(RootValue);
      try
        MessagesValue := RootObj.Values['messages'];
        if MessagesValue is TJSONArray then
        begin
          MsgArray := TJSONArray(MessagesValue);
          for I := 0 to MsgArray.Count - 1 do
          begin
            if not (MsgArray.Items[I] is TJSONObject) then
              Continue;
            MsgObj := TJSONObject(MsgArray.Items[I]);
            RoleValue := MsgObj.Values['role'];
            TextValue := MsgObj.Values['text'];
            if not Assigned(TextValue) then
              Continue;
            Msg.IsUser := Assigned(RoleValue) and SameText(RoleValue.Value, 'user');
            Msg.Text := TextValue.Value;
            List.Add(Msg);
          end;
        end;
      finally
        RootObj.Free;
      end;
    except
      // Corrupt file - treat as empty rather than propagate an exception to the UI thread.
    end;
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

class procedure TConversationStore.SaveConversation(const Id, Title: string;
  const Messages: TArray<TChatMessage>);
var
  RootObj: TJSONObject;
  MsgArray: TJSONArray;
  Msg: TChatMessage;
  MsgObj: TJSONObject;
begin
  RootObj := TJSONObject.Create;
  try
    RootObj.AddPair('title', Title);
    MsgArray := TJSONArray.Create;
    for Msg in Messages do
    begin
      MsgObj := TJSONObject.Create;
      if Msg.IsUser then
        MsgObj.AddPair('role', 'user')
      else
        MsgObj.AddPair('role', 'assistant');
      MsgObj.AddPair('text', Msg.Text);
      MsgArray.AddElement(MsgObj);
    end;
    RootObj.AddPair('messages', MsgArray);
    TFile.WriteAllText(FilePath(Id), RootObj.ToJSON, TEncoding.UTF8);
  finally
    RootObj.Free;
  end;
end;

class procedure TConversationStore.DeleteConversation(const Id: string);
begin
  if TFile.Exists(FilePath(Id)) then
    TFile.Delete(FilePath(Id));
end;

end.
