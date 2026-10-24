// Doom 3 PDA decls (pdas/*.pda): pda, email, audio and video decls
// (idDeclPDA, idDeclEmail, idDeclAudio, idDeclVideo) shown on the player's
// PDA screen.
//
//   pda personal {
//     name "personal"  fullname "..."  icon "..."  id "..."  post "..."
//     title "..."  security "..."
//     pda_email "name"  pda_audio "name"  pda_video "name"
//   }
//   email name { to "" from "" subject "" date "" image "" text { "line" ... } }
//   audio name { name "" audio "sound shader" info "" preview "" }
//   video name { name "" video "" info "" preview "" audio "" }
unit Doom3Pda;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  Doom3Decls;

type
  TD3EmailDecl = class
    Name: String;
    To_, From, Subject, Date, Image, Text: String;
  end;

  TD3AudioDecl = class
    Name: String;
    { the shown name, the sound shader, the description }
    AudioName, Audio, Info, Preview: String;
  end;

  TD3VideoDecl = class
    Name: String;
    VideoName, Video, Info, Preview, Audio: String;
  end;

  TD3PdaDecl = class
    Name: String;
    PdaName, FullName, Icon, Id, Post, Title, Security: String;
    { decl names }
    Emails, Audios, Videos: TStringList;
    constructor Create;
    destructor Destroy; override;
  end;

{ The decls by name (nil when missing); parsed once and cached (the caches
  go with the decls). Names are case-insensitive. }
function PdaDecl(const AName: String): TD3PdaDecl;
function EmailDecl(const AName: String): TD3EmailDecl;
function AudioDecl(const AName: String): TD3AudioDecl;
function VideoDecl(const AName: String): TD3VideoDecl;

implementation

uses
  CastleLog,
  Doom3Lexer;

var
  Pdas: specialize TObjectDictionary<String, TD3PdaDecl>;
  Emails: specialize TObjectDictionary<String, TD3EmailDecl>;
  Audios: specialize TObjectDictionary<String, TD3AudioDecl>;
  Videos: specialize TObjectDictionary<String, TD3VideoDecl>;
  HookAdded: Boolean;

constructor TD3PdaDecl.Create;
begin
  inherited Create;
  Emails := TStringList.Create;
  Audios := TStringList.Create;
  Videos := TStringList.Create;
end;

destructor TD3PdaDecl.Destroy;
begin
  Emails.Free;
  Audios.Free;
  Videos.Free;
  inherited Destroy;
end;

procedure ClearPdaDecls;
begin
  if Pdas <> nil then
    Pdas.Clear;
  if Emails <> nil then
    Emails.Clear;
  if Audios <> nil then
    Audios.Clear;
  if Videos <> nil then
    Videos.Clear;
end;

procedure EnsureHook;
begin
  if not HookAdded and (Decls <> nil) then
  begin
    Decls.AddClearHook(@ClearPdaDecls);
    HookAdded := True;
  end;
end;

{ The body of a decl of a type, '' when missing. }
function Body(const T: TD3DeclType; const AName: String; out S: String): Boolean;
begin
  S := '';
  Result := (Decls <> nil) and Decls.DeclBody(T, LowerCase(AName), S);
end;

{ Doom 3 strings use "\n" for new lines. }
function Unescape(const S: String): String;
begin
  Result := StringReplace(S, '\n', #10, [rfReplaceAll]);
end;

function PdaDecl(const AName: String): TD3PdaDecl;
var
  Key, S, Tok, K: String;
  L: TDoom3Lexer;
begin
  EnsureHook;
  Key := LowerCase(AName);
  if Pdas.TryGetValue(Key, Result) then
    Exit;
  if not Body(dtPda, Key, S) then
    Exit(nil);
  Result := TD3PdaDecl.Create;
  Result.Name := Key;
  L := TDoom3Lexer.Create(S);
  try
    while L.Next(Tok) do
    begin
      K := LowerCase(Tok);
      case K of
        'name': Result.PdaName := L.NextStr;
        'fullname': Result.FullName := L.NextStr;
        'icon': Result.Icon := L.NextStr;
        'id': Result.Id := L.NextStr;
        'post': Result.Post := L.NextStr;
        'title': Result.Title := L.NextStr;
        'security': Result.Security := L.NextStr;
        'pda_email': Result.Emails.Add(LowerCase(L.NextStr));
        'pda_audio': Result.Audios.Add(LowerCase(L.NextStr));
        'pda_video': Result.Videos.Add(LowerCase(L.NextStr));
        '{': L.SkipBracedSection;
      end;
    end;
  finally
    L.Free;
  end;
  if Result.PdaName = '' then
    Result.PdaName := Key;
  Pdas.Add(Key, Result);
end;

function EmailDecl(const AName: String): TD3EmailDecl;
var
  Key, S, Tok, K: String;
  L: TDoom3Lexer;
begin
  EnsureHook;
  Key := LowerCase(AName);
  if Emails.TryGetValue(Key, Result) then
    Exit;
  if not Body(dtEmail, Key, S) then
    Exit(nil);
  Result := TD3EmailDecl.Create;
  Result.Name := Key;
  L := TDoom3Lexer.Create(S);
  try
    while L.Next(Tok) do
    begin
      K := LowerCase(Tok);
      case K of
        'to': Result.To_ := L.NextStr;
        'from': Result.From := L.NextStr;
        'subject': Result.Subject := L.NextStr;
        'date': Result.Date := L.NextStr;
        'image': Result.Image := L.NextStr;
        'text':
          begin
            { text { "line" "line" ... }: the strings are joined }
            if L.Check('{') then
              while L.Next(Tok) and (Tok <> '}') do
                Result.Text := Result.Text + Unescape(Tok)
            else
              Result.Text := Unescape(Tok);
          end;
        '{': L.SkipBracedSection;
      end;
    end;
  finally
    L.Free;
  end;
  Emails.Add(Key, Result);
end;

function AudioDecl(const AName: String): TD3AudioDecl;
var
  Key, S, Tok, K: String;
  L: TDoom3Lexer;
begin
  EnsureHook;
  Key := LowerCase(AName);
  if Audios.TryGetValue(Key, Result) then
    Exit;
  if not Body(dtAudio, Key, S) then
    Exit(nil);
  Result := TD3AudioDecl.Create;
  Result.Name := Key;
  L := TDoom3Lexer.Create(S);
  try
    while L.Next(Tok) do
    begin
      K := LowerCase(Tok);
      case K of
        'name': Result.AudioName := L.NextStr;
        'audio': Result.Audio := L.NextStr;
        'info': Result.Info := Unescape(L.NextStr);
        'preview': Result.Preview := L.NextStr;
        '{': L.SkipBracedSection;
      end;
    end;
  finally
    L.Free;
  end;
  Audios.Add(Key, Result);
end;

function VideoDecl(const AName: String): TD3VideoDecl;
var
  Key, S, Tok, K: String;
  L: TDoom3Lexer;
begin
  EnsureHook;
  Key := LowerCase(AName);
  if Videos.TryGetValue(Key, Result) then
    Exit;
  if not Body(dtVideo, Key, S) then
    Exit(nil);
  Result := TD3VideoDecl.Create;
  Result.Name := Key;
  L := TDoom3Lexer.Create(S);
  try
    while L.Next(Tok) do
    begin
      K := LowerCase(Tok);
      case K of
        'name': Result.VideoName := L.NextStr;
        'video': Result.Video := L.NextStr;
        'info': Result.Info := Unescape(L.NextStr);
        'preview': Result.Preview := L.NextStr;
        'audio': Result.Audio := L.NextStr;
        '{': L.SkipBracedSection;
      end;
    end;
  finally
    L.Free;
  end;
  Videos.Add(Key, Result);
end;

initialization
  Pdas := specialize TObjectDictionary<String, TD3PdaDecl>.Create([doOwnsValues]);
  Emails := specialize TObjectDictionary<String, TD3EmailDecl>.Create([doOwnsValues]);
  Audios := specialize TObjectDictionary<String, TD3AudioDecl>.Create([doOwnsValues]);
  Videos := specialize TObjectDictionary<String, TD3VideoDecl>.Create([doOwnsValues]);
finalization
  FreeAndNil(Pdas);
  FreeAndNil(Emails);
  FreeAndNil(Audios);
  FreeAndNil(Videos);
end.
