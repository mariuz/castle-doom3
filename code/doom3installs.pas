{ Finding Doom 3 data on this computer, and remembering the player's choice.

  Detected: GOG (its registry keys, the GOG Galaxy default folders), Steam
  (its install path in the registry, the libraries of
  steamapps/libraryfolders.vdf, steamapps/common/Doom 3 and DOOM 3 BFG
  Edition), the Doom 3 BFG edition, Resurrection of Evil (d3xp) next to
  Doom 3, and the free Doom 3 demo (demo/demo00.pk4), also the one
  downloaded by the menu into <config dir>/demo.

  The choice is saved in <config dir>/data.cfg (%LOCALAPPDATA%\castle-doom3
  on Windows) as "basepath=" and "game=" lines; -basepath, -game, -pk4 and
  a base/ or demo/ directory next to the executable win over it. }
unit Doom3Installs;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Classes, Generics.Collections;

type
  TD3InstallKind = (ikDoom3, ikRoe, ikBfg, ikDemo);

  TD3Install = record
    Kind: TD3InstallKind;
    { where it was found: GOG, Steam, Downloaded, Folder }
    Source: String;
    { the -basepath (the folder with base/ or demo/) }
    BasePath: String;
    { the -game: d3xp for Resurrection of Evil, else empty }
    GameDir: String;
    { "Doom 3 (GOG)" ... }
    function Title: String;
  end;

  TD3InstallList = specialize TList<TD3Install>;

const
  InstallKindNames: array [TD3InstallKind] of String =
    ('Doom 3', 'Doom 3: Resurrection of Evil', 'Doom 3 BFG Edition', 'Doom 3 demo');

{ Add the installs in Dir (a Doom 3, BFG or demo folder) to List, if it has
  any and they aren't there yet. Result: how many were added. }
function AddInstallsIn(const Dir, Source: String; const List: TD3InstallList): Integer;

{ Every install found on this computer (see the unit's comment). }
function DetectInstalls: TD3InstallList;

{ The library folders listed in Steam's libraryfolders.vdf ("path" keys). }
function SteamLibraryPaths(const VdfText: String): TStringList;

{ <config dir>: %LOCALAPPDATA%\castle-doom3 on Windows. }
function ConfigDir: String;
{ <config dir>/data.cfg }
function DataConfigFileName: String;
{ where the menu downloads the demo to: <config dir>/demo (with demo/demo00.pk4 in it) }
function DownloadedDemoBasePath: String;

{ The saved choice: False when there is none. BasePath empty: the test level only. }
function LoadDataChoice(out BasePath, GameDir: String): Boolean;
procedure SaveDataChoice(const BasePath, GameDir: String);
{ the same with another file (tests) }
function LoadDataChoiceFrom(const FileName: String; out BasePath, GameDir: String): Boolean;
procedure SaveDataChoiceTo(const FileName, BasePath, GameDir: String);
{ data.cfg's classic=0|1 (classic mode, the title menu's button): False
  when it has none. Saving keeps the data choice, and the data choice
  keeps it. }
function LoadClassicChoice(out Classic: Boolean): Boolean;
procedure SaveClassicChoice(const Classic: Boolean);
function LoadClassicChoiceFrom(const FileName: String; out Classic: Boolean): Boolean;
procedure SaveClassicChoiceTo(const FileName: String; const Classic: Boolean);

var
  { set by GameInitialize: the -basepath / -game loaded (empty: the
    test level only, or a base/ next to the exe) }
  DataBasePathInUse, DataGameDirInUse: String;
  { the command line (-basepath, -pk4) or a base/ or demo/ next to the exe
    gives the data: the menu's choice is not used }
  DataFromCommandLine: Boolean;
  { data.cfg has a choice }
  DataChoiceSaved: Boolean;

{ Same folder (case-insensitive on Windows, trailing delimiters ignored). }
function SamePath(const A, B: String): Boolean;

implementation

uses
  {$ifdef MSWINDOWS} Registry, Windows, {$endif}
  CastleLog;

function TD3Install.Title: String;
begin
  Result := InstallKindNames[Kind];
  if Source <> '' then
    Result := Result + ' (' + Source + ')';
end;

function NormPath(const S: String): String;
begin
  Result := ExcludeTrailingPathDelimiter(ExpandFileName(Trim(S)));
  {$ifdef MSWINDOWS}
  Result := LowerCase(StringReplace(Result, '/', '\', [rfReplaceAll]));
  {$endif}
end;

function SamePath(const A, B: String): Boolean;
begin
  Result := NormPath(A) = NormPath(B);
end;

function InList(const List: TD3InstallList; const BasePath, GameDir: String): Boolean;
var
  I: TD3Install;
begin
  for I in List do
    if SamePath(I.BasePath, BasePath) and SameText(I.GameDir, GameDir) then
      Exit(True);
  Result := False;
end;

function HasPk4(const Dir: String): Boolean;
var
  SR: TSearchRec;
begin
  Result := FileExists(Dir + PathDelim + 'pak000.pk4');
  if Result then
    Exit;
  if FindFirst(Dir + PathDelim + 'pak*.pk4', faAnyFile, SR) = 0 then
  try
    Result := True;
  finally
    SysUtils.FindClose(SR);
  end;
end;

function AddInstallsIn(const Dir, Source: String; const List: TD3InstallList): Integer;
var
  Added: Integer;

  procedure Add(const Kind: TD3InstallKind; const GameDir: String);
  var
    I: TD3Install;
  begin
    if InList(List, Dir, GameDir) then
      Exit;
    I.Kind := Kind;
    I.Source := Source;
    I.BasePath := ExcludeTrailingPathDelimiter(Dir);
    I.GameDir := GameDir;
    List.Add(I);
    Inc(Added);
  end;

var
  D: String;
begin
  Added := 0;
  Result := 0;
  D := ExcludeTrailingPathDelimiter(Trim(Dir));
  if (D = '') or not DirectoryExists(D) then
    Exit;
  if FileExists(D + PathDelim + 'base' + PathDelim + '_common.resources') then
    Add(ikBfg, '')
  else
  if DirectoryExists(D + PathDelim + 'base') and HasPk4(D + PathDelim + 'base') then
  begin
    Add(ikDoom3, '');
    if DirectoryExists(D + PathDelim + 'd3xp') and HasPk4(D + PathDelim + 'd3xp') then
      Add(ikRoe, 'd3xp');
  end;
  if FileExists(D + PathDelim + 'demo' + PathDelim + 'demo00.pk4') then
    Add(ikDemo, '');
  Result := Added;
end;

{ Steam's .vdf: "key" "value" pairs and blocks in braces; the libraries are the
  "path" values (backslashes doubled) }
function SteamLibraryPaths(const VdfText: String): TStringList;
var
  Tokens: TStringList;
  I: Integer;
  Tok: String;
begin
  Result := TStringList.Create;
  Tokens := TStringList.Create;
  try
    I := 1;
    while I <= Length(VdfText) do
    begin
      if VdfText[I] = '"' then
      begin
        Tok := '';
        Inc(I);
        while (I <= Length(VdfText)) and (VdfText[I] <> '"') do
        begin
          if (VdfText[I] = '\') and (I < Length(VdfText)) then
            Inc(I);
          Tok := Tok + VdfText[I];
          Inc(I);
        end;
        Tokens.Add(Tok);
      end else
      if VdfText[I] in ['{', '}'] then
        Tokens.Add(VdfText[I]);
      Inc(I);
    end;
    for I := 0 to Tokens.Count - 2 do
      if SameText(Tokens[I], 'path') and (Tokens[I + 1] <> '{') and (Tokens[I + 1] <> '}') then
        Result.Add(Tokens[I + 1]);
  finally
    Tokens.Free;
  end;
end;

function ReadTextFile(const FileName: String): String;
var
  S: TStringList;
begin
  Result := '';
  if not FileExists(FileName) then
    Exit;
  S := TStringList.Create;
  try
    try
      S.LoadFromFile(FileName);
      Result := S.Text;
    except
      on E: Exception do
        WritelnWarning('Doom3Installs', 'Cannot read "%s": %s', [FileName, E.Message]);
    end;
  finally
    S.Free;
  end;
end;

{$ifdef MSWINDOWS}
function RegString(const Root: HKEY; const Key, Name: String): String;
var
  R: TRegistry;
begin
  Result := '';
  R := TRegistry.Create(KEY_READ);
  try
    R.RootKey := Root;
    if R.OpenKeyReadOnly(Key) then
    try
      if R.ValueExists(Name) then
        Result := R.ReadString(Name);
    finally
      R.CloseKey;
    end;
  finally
    R.Free;
  end;
end;

{ every GOG game's "path" (HKLM\SOFTWARE\[WOW6432Node\]GOG.com\Games\<id>) }
procedure AddGogRegistry(const Paths: TStringList);
const
  Keys: array [0..1] of String = ('SOFTWARE\WOW6432Node\GOG.com\Games', 'SOFTWARE\GOG.com\Games');
var
  R: TRegistry;
  Ids: TStringList;
  K, Id, P: String;
begin
  Ids := TStringList.Create;
  R := TRegistry.Create(KEY_READ);
  try
    R.RootKey := HKEY_LOCAL_MACHINE;
    for K in Keys do
    begin
      Ids.Clear;
      if R.OpenKeyReadOnly(K) then
      try
        R.GetKeyNames(Ids);
      finally
        R.CloseKey;
      end;
      for Id in Ids do
      begin
        P := RegString(HKEY_LOCAL_MACHINE, K + '\' + Id, 'path');
        if P <> '' then
          Paths.Add(P);
      end;
    end;
  finally
    R.Free;
    Ids.Free;
  end;
end;
{$endif}

function DetectInstalls: TD3InstallList;
const
  SteamFolders: array [0..2] of String = ('Doom 3', 'DOOM 3 BFG Edition', 'Doom 3 Demo');
  GogFolders: array [0..1] of String = ('DOOM 3', 'DOOM 3 BFG');
var
  Gog, Steams, Libs: TStringList;
  P, L, F, Home: String;
begin
  Result := TD3InstallList.Create;
  Gog := TStringList.Create;
  Steams := TStringList.Create;
  Libs := TStringList.Create;
  try
    { GOG }
    {$ifdef MSWINDOWS}
    AddGogRegistry(Gog);
    for F in GogFolders do
    begin
      Gog.Add('C:\GOG Games\' + F);
      Gog.Add('C:\Program Files (x86)\GOG Galaxy\Games\' + F);
      Gog.Add('C:\Program Files\GOG Galaxy\Games\' + F);
    end;
    {$else}
    Home := GetUserDir;
    for F in GogFolders do
      Gog.Add(Home + 'GOG Games' + PathDelim + F);
    {$endif}
    for P in Gog do
      AddInstallsIn(P, 'GOG', Result);

    { Steam: its folder, then its libraries }
    {$ifdef MSWINDOWS}
    Steams.Add(RegString(HKEY_CURRENT_USER, 'Software\Valve\Steam', 'SteamPath'));
    Steams.Add(RegString(HKEY_LOCAL_MACHINE, 'SOFTWARE\WOW6432Node\Valve\Steam', 'InstallPath'));
    Steams.Add(RegString(HKEY_LOCAL_MACHINE, 'SOFTWARE\Valve\Steam', 'InstallPath'));
    Steams.Add('C:\Program Files (x86)\Steam');
    {$else}
    Home := GetUserDir;
    Steams.Add(Home + '.steam/steam');
    Steams.Add(Home + '.local/share/Steam');
    {$endif}
    for P in Steams do
    begin
      if Trim(P) = '' then
        Continue;
      L := StringReplace(Trim(P), '/', PathDelim, [rfReplaceAll]);
      Libs.Add(L);
      Libs.AddStrings(SteamLibraryPaths(ReadTextFile(IncludeTrailingPathDelimiter(L) +
        'steamapps' + PathDelim + 'libraryfolders.vdf')));
    end;
    for L in Libs do
      for F in SteamFolders do
        AddInstallsIn(IncludeTrailingPathDelimiter(L) + 'steamapps' + PathDelim + 'common' + PathDelim + F,
          'Steam', Result);

    { the demo downloaded by the menu }
    AddInstallsIn(DownloadedDemoBasePath, 'downloaded', Result);
  finally
    Gog.Free;
    Steams.Free;
    Libs.Free;
  end;
end;

function ConfigDir: String;
begin
  Result := IncludeTrailingPathDelimiter(GetAppConfigDir(False));
end;

function LoadClassicChoice(out Classic: Boolean): Boolean;
begin
  Result := LoadClassicChoiceFrom(DataConfigFileName, Classic);
end;

procedure SaveClassicChoice(const Classic: Boolean);
begin
  SaveClassicChoiceTo(DataConfigFileName, Classic);
end;

function LoadClassicChoiceFrom(const FileName: String; out Classic: Boolean): Boolean;
var
  S: TStringList;
begin
  Classic := False;
  Result := False;
  if not FileExists(FileName) then
    Exit;
  S := TStringList.Create;
  try
    try
      S.LoadFromFile(FileName);
    except
      Exit;
    end;
    if S.IndexOfName('classic') < 0 then
      Exit;
    Classic := Trim(S.Values['classic']) = '1';
    Result := True;
  finally
    S.Free;
  end;
end;

procedure SaveClassicChoiceTo(const FileName: String; const Classic: Boolean);
var
  S: TStringList;
begin
  ForceDirectories(ExtractFileDir(FileName));
  S := TStringList.Create;
  try
    if FileExists(FileName) then
      S.LoadFromFile(FileName);
    S.Values['classic'] := BoolToStr(Classic, '1', '0');
    S.SaveToFile(FileName);
  finally
    S.Free;
  end;
  WritelnLog('Doom3Installs', 'Classic mode %s saved in "%s"', [BoolToStr(Classic, 'on', 'off'), FileName]);
end;

function DataConfigFileName: String;
begin
  Result := ConfigDir + 'data.cfg';
end;

function DownloadedDemoBasePath: String;
begin
  Result := ConfigDir + 'demo';
end;

function LoadDataChoice(out BasePath, GameDir: String): Boolean;
begin
  Result := LoadDataChoiceFrom(DataConfigFileName, BasePath, GameDir);
end;

procedure SaveDataChoice(const BasePath, GameDir: String);
begin
  SaveDataChoiceTo(DataConfigFileName, BasePath, GameDir);
end;

function LoadDataChoiceFrom(const FileName: String; out BasePath, GameDir: String): Boolean;
var
  S: TStringList;
begin
  BasePath := '';
  GameDir := '';
  Result := False;
  if not FileExists(FileName) then
    Exit;
  S := TStringList.Create;
  try
    try
      S.LoadFromFile(FileName);
    except
      on E: Exception do
      begin
        WritelnWarning('Doom3Installs', 'Cannot read "%s": %s', [FileName, E.Message]);
        Exit;
      end;
    end;
    if S.IndexOfName('basepath') < 0 then
      Exit;
    BasePath := Trim(S.Values['basepath']);
    GameDir := Trim(S.Values['game']);
    Result := True;
  finally
    S.Free;
  end;
end;

procedure SaveDataChoiceTo(const FileName, BasePath, GameDir: String);
var
  S: TStringList;
  Classic: Boolean;
  HasClassic: Boolean;
begin
  HasClassic := LoadClassicChoiceFrom(FileName, Classic);
  ForceDirectories(ExtractFileDir(FileName));
  S := TStringList.Create;
  try
    S.Add('# Castle Doom 3''s data: the folder with base/ (or demo/), and the mod (d3xp). Empty: the test level.');
    S.Add('basepath=' + BasePath);
    S.Add('game=' + GameDir);
    if HasClassic then
      S.Add('classic=' + BoolToStr(Classic, '1', '0'));
    S.SaveToFile(FileName);
  finally
    S.Free;
  end;
  WritelnLog('Doom3Installs', 'Data choice saved in "%s": basepath "%s", game "%s"',
    [FileName, BasePath, GameDir]);
end;

end.
