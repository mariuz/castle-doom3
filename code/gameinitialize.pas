{ Game initialization: window, views, Doom 3 data sources and command line.
  This unit is cross-platform.
  It will be used by the platform-specific program or library file. }
unit GameInitialize;

{$mode objfpc}{$H+}

interface

implementation

uses
  SysUtils, Classes,
  CastleWindow, CastleLog, CastleUIControls, CastleApplicationProperties, CastleParameters,
  CastleUtils, CastleFilesUtils, CastleUriUtils, CastleSoundEngine, CastleTimeUtils, CastleGLShaders,
  Doom3Files, Doom3Images, Doom3Decls, Doom3Gui, Doom3Level, Doom3LightEffects
  {$region 'Castle Initialization Uses'}
  // The content here may be automatically updated by CGE editor.
  , GameViewMenu
  , GameViewPlay
  {$endregion 'Castle Initialization Uses'};

var
  Window: TCastleWindow;

procedure ApplicationInitialize;
var
  I: Integer;
  AutoTestMap, AutoTestPrefix, AutoTestDemo, CmdMap, BasePath, GameDir: String;
  Pk4s: TStringList;
  LoadedGame: Boolean;
begin
  AutoTestMap := '';
  CmdMap := '';
  BasePath := '';
  GameDir := '';
  Pk4s := TStringList.Create;
  try
    I := 1;
    while I <= Parameters.High do
    begin
      if (Parameters[I] = '--autotest') and (I + 2 <= Parameters.High) then
      begin
        AutoTestMap := Parameters[I + 1];
        AutoTestPrefix := Parameters[I + 2];
        Inc(I, 2);
      end else
      if (Parameters[I] = '--demo') and (I + 1 <= Parameters.High) then
      begin
        AutoTestDemo := Parameters[I + 1];
        Inc(I);
      end else
      if ((Parameters[I] = '+map') or (Parameters[I] = '-map') or (Parameters[I] = '--map') or
          (Parameters[I] = '+devmap')) and (I + 1 <= Parameters.High) then
      begin
        CmdMap := Parameters[I + 1];
        Inc(I);
      end else
      if ((Parameters[I] = '-basepath') or (Parameters[I] = '--basepath') or
          (Parameters[I] = '+set') and (I + 2 <= Parameters.High) and
          (Parameters[I + 1] = 'fs_basepath')) and (I + 1 <= Parameters.High) then
      begin
        if Parameters[I] = '+set' then
          Inc(I);
        BasePath := Parameters[I + 1];
        Inc(I);
      end else
      if ((Parameters[I] = '-game') or (Parameters[I] = '--game')) and (I + 1 <= Parameters.High) then
      begin
        GameDir := Parameters[I + 1];
        Inc(I);
      end else
      if ((Parameters[I] = '-pk4') or (Parameters[I] = '--pk4')) and (I + 1 <= Parameters.High) then
      begin
        Pk4s.Add(Parameters[I + 1]);
        Inc(I);
      end;
      Inc(I);
    end;

    Window.Container.LoadSettings('castle-data:/CastleSettings.xml');
    D3Fs.RegisterProtocol;
    RegisterImageProtocol;
    RegisterGuiProtocol;
    if SoundEngine <> nil then
      SoundEngine.DistanceModel := dmLinear;

    { Data: the bundled test level first, then a Doom 3 install (later
      sources override earlier ones, like idFileSystem's search path). }
    LoadProfileStart;
    { CD3_CGE_PROFILE: CGE's profiler too (loading images, preparing scenes) }
    Profiler.Enabled := GetEnvironmentVariable('CD3_CGE_PROFILE') <> '';
    if UriFileExists(DefaultTestPk4) then
      D3Fs.AddPk4(DefaultTestPk4);
    LoadedGame := False;
    if BasePath = '' then
    begin
      { a Doom 3 "base" directory next to the executable,
        or the Doom 3 demo's "demo" directory (demo00.pk4) }
      if DirectoryExists('base') then
        LoadedGame := D3Fs.AddGameDirectory('base');
      if (not LoadedGame) and DirectoryExists('demo') then
        LoadedGame := D3Fs.AddGameDirectory('demo');
    end else
    begin
      LoadedGame := D3Fs.AddGameDirectory(IncludeTrailingPathDelimiter(BasePath) + 'base');
      if not LoadedGame then
        LoadedGame := D3Fs.AddGameDirectory(IncludeTrailingPathDelimiter(BasePath) + 'demo');
      if not LoadedGame then
        LoadedGame := D3Fs.AddGameDirectory(BasePath);
      if (GameDir <> '') and D3Fs.AddGameDirectory(IncludeTrailingPathDelimiter(BasePath) + GameDir) then
        LoadedGame := True;
    end;
    for I := 0 to Pk4s.Count - 1 do
      if D3Fs.AddPk4(Pk4s[I]) then
        LoadedGame := True;
    if not LoadedGame then
      WritelnLog('GameInitialize', 'No Doom 3 data found, using the bundled test level. ' +
        'Pass -basepath "<Doom 3 dir>" (with base/pak000.pk4 ...) to play Doom 3 maps.');
    LoadProfileStep('pk4s');
    Decls.LoadAll;
    LoadProfileStep('decls');
    LoadProfileLog('Data');
  finally
    Pk4s.Free;
  end;

  { Create views (see https://castle-engine.io/views ). }
  {$region 'Castle View Creation'}
  // The content here may be automatically updated by CGE editor.
  ViewMenu := TViewMenu.Create(Application);
  ViewPlay := TViewPlay.Create(Application);
  {$endregion 'Castle View Creation'}

  if SameText(AutoTestMap, 'MENU') then
  begin
    ViewMenu.AutoTestPrefix := AutoTestPrefix;
    Window.Container.View := ViewMenu;
  end else
  if AutoTestMap <> '' then
  begin
    ViewPlay.MapName := AutoTestMap;
    ViewPlay.AutoTestPrefix := AutoTestPrefix;
    ViewPlay.AutoTestDemo := AutoTestDemo;
    Window.Container.View := ViewPlay;
  end else
  if CmdMap <> '' then
  begin
    ViewPlay.MapName := CmdMap;
    Window.Container.View := ViewPlay;
  end else
    Window.Container.View := ViewMenu;
end;

initialization
  ApplicationProperties.ApplicationName := 'castle-doom3';
  ApplicationProperties.Version := '0.12.0';
  LogFileName := 'castle-doom3.log';
  InitializeLog;
  { CD3_LOGSHADERS: log every GLSL program CGE links (counts the programs
    a map needs, e.g. with and without r_sharedLightEffects) }
  if GetEnvironmentVariable('CD3_LOGSHADERS') <> '' then
    LogShaders := True;
  { CD3_SHARED_LIGHT_EFFECTS=0: start with r_sharedLightEffects 0 (programs
    stay cached across map reloads, so compare in separate runs) }
  if GetEnvironmentVariable('CD3_SHARED_LIGHT_EFFECTS') = '0' then
    SharedLightEffects := False;
  { OpenGL ES: highp fragment shaders (CGE change S, see ROADMAP.md). With
    mediump (16-bit floats on Mesa and many GPUs) the squared distance to
    a light overflows past 256 units and Doom 3's big rooms go dark.
    CD3_FRAGMENT_HIGHP=0 compares. Desktop OpenGL ignores it. }
  {$if declared(FragmentShaderHighPrecision)}
  FragmentShaderHighPrecision := GetEnvironmentVariable('CD3_FRAGMENT_HIGHP') <> '0';
  {$endif}
  Application.OnInitialize := @ApplicationInitialize;

  Window := TCastleWindow.Create(Application);
  Window.Caption := 'Castle Doom 3';
  Window.Width := 1600;
  Window.Height := 900;
  Application.MainWindow := Window;
  Window.ParseParameters;

finalization
  { Stop the current view before the Doom3* units finalize (they finalize
    before CastleWindow, which frees the views): this frees the map and its
    scenes while the decl / md5 caches still exist. }
  if (Window <> nil) and (Window.Container <> nil) then
    Window.Container.View := nil;
end.
