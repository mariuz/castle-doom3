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
  CastleUtils, CastleFilesUtils, CastleUriUtils, CastleSoundEngine, CastleTimeUtils, CastleGLShaders, CastleGLImages, CastleInternalRenderer,
  Doom3Files, Doom3Images, Doom3Decls, Doom3Gui, Doom3Level, Doom3LightEffects, Doom3Installs
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
  SavedBasePath, SavedGameDir: String;
  Pk4s: TStringList;
  LoadedGame, Mute, UseDataConfig, ClassicFromCommandLine, SavedClassic: Boolean;
begin
  { OpenGLES: highp fragment shaders. With mediump (16-bit floats on Mesa
    and many mobile GPUs) light distances overflow past 256 units, so
    Doom 3's lights don't reach most walls. No effect on desktop OpenGL. }
  FragmentShaderHighPrecision := True;
  { env CD3_LIMIT_FPS=3: long frames like CI's software rendering, to test
    the game with them on a fast machine }
  if StrToFloatDef(GetEnvironmentVariable('CD3_LIMIT_FPS'), 0) > 0 then
    ApplicationProperties.LimitFps := StrToFloatDef(GetEnvironmentVariable('CD3_LIMIT_FPS'), 0);

  AutoTestMap := '';
  Mute := false;
  CmdMap := '';
  BasePath := '';
  GameDir := '';
  UseDataConfig := False;
  ClassicFromCommandLine := False;
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
      end else
      { --mute (or env CD3_MUTE=1): no sound out, for test runs; the sounds
        still play (their lengths, the speakers' state) at volume 0 }
      if Parameters[I] = '--mute' then
        Mute := true
      else
      { --data-config: autotests use the data chosen in the menu too
        (without it they use only -basepath ..., to stay reproducible) }
      if Parameters[I] = '--data-config' then
        UseDataConfig := true
      else
      { --classic / --no-classic: classic mode on or off (Doom 3 BFG's data
        with the 2004 game's light scale and field of view; D3ClassicMode),
        over data.cfg's choice }
      if (Parameters[I] = '--classic') or (Parameters[I] = '-classic') or
         (Parameters[I] = '--no-classic') then
      begin
        D3ClassicMode := Parameters[I] <> '--no-classic';
        ClassicFromCommandLine := true;
      end else
      { --minimized: the window starts minimized (for runs started by
        another program, like RenderDoc's renderdoccmd); screenshots then
        render offscreen }
      if Parameters[I] = '--minimized' then
        StartMinimized := true;
      Inc(I);
    end;

    Window.Container.LoadSettings('castle-data:/CastleSettings.xml');
    D3Fs.RegisterProtocol;
    RegisterImageProtocol;
    RegisterGuiProtocol;
    if SoundEngine <> nil then
    begin
      SoundEngine.DistanceModel := dmLinear;
      { CGE plays 16 sounds at once by default, and a new sound takes the
        source of the oldest one of the same priority: with footsteps,
        machines and speakers, characters' voice lines were cut off. Not
        64: then Creative's OpenAL ("Generic Software") has no memory left
        for the reverb's effect slot (console soundinfo). }
      SoundEngine.MaxAllocatedSources := 32;
      if Mute or (GetEnvironmentVariable('CD3_MUTE') = '1') then
      begin
        SoundEngine.Volume := 0;
        WritelnLog('Sound muted (--mute)');
      end;
    end;

    { Data: the bundled test level first, then a Doom 3 install (later
      sources override earlier ones, like idFileSystem's search path). }
    LoadProfileStart;
    { CD3_CGE_PROFILE: CGE's profiler too (loading images, preparing scenes) }
    Profiler.Enabled := GetEnvironmentVariable('CD3_CGE_PROFILE') <> '';
    if UriFileExists(DefaultTestPk4) then
      D3Fs.AddPk4(DefaultTestPk4);
    LoadedGame := False;
    { the data chosen in the title menu (data.cfg), unless the command line
      or a base/ or demo/ next to the exe gives data (they win), or it's an
      autotest without --data-config }
    DataFromCommandLine := (BasePath <> '') or (Pk4s.Count > 0) or
      DirectoryExists('base') or DirectoryExists('demo');
    DataChoiceSaved := LoadDataChoice(SavedBasePath, SavedGameDir);
    if DataChoiceSaved and not DataFromCommandLine and
       ((AutoTestMap = '') or UseDataConfig) then
    begin
      WritelnLog('GameInitialize', 'Data chosen in the menu (%s): basepath "%s", game "%s"',
        [DataConfigFileName, SavedBasePath, SavedGameDir]);
      if SavedBasePath <> '' then
      begin
        BasePath := SavedBasePath;
        if GameDir = '' then
          GameDir := SavedGameDir;
      end;
    end;
    { classic mode: the command line, else env CD3_CLASSIC, else the
      menu's choice (data.cfg; autotests only with --data-config) }
    if not ClassicFromCommandLine then
    begin
      if GetEnvironmentVariable('CD3_CLASSIC') <> '' then
        D3ClassicMode := GetEnvironmentVariable('CD3_CLASSIC') = '1'
      else
      if ((AutoTestMap = '') or UseDataConfig) and LoadClassicChoice(SavedClassic) then
        D3ClassicMode := SavedClassic;
    end;
    WritelnLog('GameInitialize', 'Classic mode %s', [BoolToStr(D3ClassicMode, 'on', 'off')]);
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
    if LoadedGame and (BasePath <> '') then
    begin
      DataBasePathInUse := BasePath;
      DataGameDirInUse := GameDir;
    end;
    if not LoadedGame then
      WritelnLog('GameInitialize', 'No Doom 3 data found, using the bundled test level. ' +
        'Choose Doom 3 data in the title menu (Doom 3 data...), or pass -basepath "<Doom 3 dir>" (with base/pak000.pk4 ...).');
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
    ViewMenu.AutoTestDemo := AutoTestDemo;
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
  { keep the shader programs no shape uses now (a monster that moved away
    from a light, the last projectile of a kind): the next one needs them
    again, and linking them again stalls (CD3_KEEP_PROGRAMS=0 compares) }
  { CD3_KEEP_PROGRAMS=<n>: keep that many (0: none) }
  if GetEnvironmentVariable('CD3_KEEP_PROGRAMS') <> '' then
    InternalKeepUnusedShaderPrograms := StrToIntDef(GetEnvironmentVariable('CD3_KEEP_PROGRAMS'), 8192)
  else
    InternalKeepUnusedShaderPrograms := 8192;
  { CD3_TEXMEM=1: CGE counts the textures' GPU memory (the Memory log
    line, console "meminfo full" lists them) }
  if GetEnvironmentVariable('CD3_TEXMEM') <> '' then
    TextureMemoryProfiler.Enabled := True;
  { the driver compiles the shader programs on its own threads
    (GL_ARB_parallel_shader_compile): a shape is drawn once its program is
    ready, instead of a stall (a new program took up to a second; on a
    first play game/hell1's route compiled 207, 33 s);
    CD3_PARALLEL_SHADERS=0 waits for each like before }
  InternalParallelShaderCompile := GetEnvironmentVariable('CD3_PARALLEL_SHADERS') <> '0';
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
