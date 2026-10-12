{ The game view: a Doom 3 map, the player, HUD and console.
  Its components are designed in data/gameviewplay.castle-user-interface . }
unit GameViewPlay;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils,
  CastleVectors, CastleUIControls, CastleControls, CastleKeysMouse, CastleViewport,
  CastleCameras, CastleTransform, CastleScene,
  Doom3Level, Doom3World, Doom3Hud, Doom3Console;

type
  TViewPlay = class(TCastleView)
  published
    { Components designed using CGE editor.
      These fields will be automatically initialized at Start. }
    MainViewport: TCastleViewport;
    Camera: TCastleCamera;
    WalkNavigation: TCastleWalkNavigation;
    Map: TDoom3Map;
    Flashlight: TCastleSpotLight;
    MuzzleFlash: TCastlePointLight;
    Hud: TDoom3Hud;
    LabelFps: TCastleLabel;
    Console: TDoom3Console;
    FadeRect: TCastleRectangleControl;
  private
    FGame: TD3Game;
    FSky: TCastleBackground;
    FNoclip: Boolean;
    { autotest / demo scripts }
    FDemoCommands: TStringList;
    FDemoIndex: Integer;
    FDemoTimer: Single;
    FDemoHeld: array of TKey;
    FShots: Integer;
    FQuitting: Boolean;
    { a cinematic camera has the view: the player's view to go back to }
    FInCinematic: Boolean;
    FPlayerEye, FPlayerDir: TVector3;
    FPlayerFov: Single;
    FPlayerFovAxis: TFieldOfViewAxis;
    { after loading a map: the first frames (textures, shaders) are profiled }
    FProfileFrames: Integer;
    procedure UpdateCinematic;
    procedure LoadLevel(const AMapName: String);
    procedure SetupSky;
    procedure PlaceCamera(const FeetPos: TVector3; const YawDeg: Single);
    procedure HandleMessage(const Msg: String);
    procedure HandleConsoleCommand(const Cmd, Args: String);
    procedure SetFlashlight(const Value: Boolean);
    procedure SetNoclip(const Value: Boolean);
    procedure RunDemoStep(const SecondsPassed: Single);
    procedure ReleaseDemoKeys;
    procedure CaptureScreenshot;
    function CameraYaw: Single;
  public
    MapName: String;
    AutoTestPrefix: String;
    AutoTestDemo: String;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Start; override;
    procedure Stop; override;
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
    function Press(const Event: TInputPressRelease): Boolean; override;
  end;

var
  ViewPlay: TViewPlay;

implementation

uses
  Math,
  CastleWindow, CastleLog, CastleImages, CastleUtils, CastleStringUtils, CastleRenderOptions, CastleTimeUtils,
  Doom3Sampler,
  Doom3MapFile, Doom3Files, Doom3Decls, Doom3LightEffects, Doom3Md5, Doom3Gui, GameViewMenu;

constructor TViewPlay.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  DesignUrl := 'castle-data:/gameviewplay.castle-user-interface';
  FDemoCommands := TStringList.Create;
  MapName := 'testmap';
end;

destructor TViewPlay.Destroy;
begin
  FDemoCommands.Free;
  inherited Destroy;
end;

procedure TViewPlay.Start;
begin
  inherited Start;
  FGame := TD3Game.Create(Map);
  FGame.OnMessage := @HandleMessage;
  Console.OnCommand := @HandleConsoleCommand;
  FNoclip := False;
  FShots := 0;
  if AutoTestPrefix <> '' then
  begin
    { results must not depend on the desktop mouse }
    WalkNavigation.MouseLook := False;
    FDemoCommands.Clear;
    FDemoCommands.AddStrings(AutoTestDemo.Split([',']));
    FDemoIndex := 0;
    FDemoTimer := 0;
  end;
  LoadLevel(ViewPlay.MapName);
end;

procedure TViewPlay.Stop;
begin
  ReleaseDemoKeys;
  FreeAndNil(FGame);
  inherited Stop;
end;

function TViewPlay.CameraYaw: Single;
var
  D: TVector3;
begin
  D := CgeToD3(Camera.Direction);
  Result := RadToDeg(ArcTan2(D.Y, D.X));
end;

procedure TViewPlay.PlaceCamera(const FeetPos: TVector3; const YawDeg: Single);
begin
  Camera.SetWorldView(FeetPos + Vector3(0, PlayerEyeHeight, 0), YawToCgeDir(YawDeg),
    Vector3(0, 1, 0));
end;

procedure TViewPlay.UpdateCinematic;
var
  P, D, U: TVector3;
  Fov, Yaw: Single;
  C: TVector4;
begin
  if FGame.CinematicActive then
  begin
    if not FInCinematic then
    begin
      FInCinematic := True;
      FPlayerEye := Camera.Translation;
      FPlayerDir := Camera.Direction;
      FPlayerFov := Camera.Perspective.FieldOfView;
      FPlayerFovAxis := Camera.Perspective.FieldOfViewAxis;
    end;
    FGame.CinematicView(P, D, U, Fov);
    Camera.SetWorldView(P, D, U);
    { Doom 3's fov is horizontal }
    Camera.Perspective.FieldOfViewAxis := faHorizontal;
    Camera.Perspective.FieldOfView := DegToRad(EnsureRange(Fov, 1, 170));
  end else
  if FInCinematic then
  begin
    FInCinematic := False;
    Camera.SetWorldView(FPlayerEye, FPlayerDir, Vector3(0, 1, 0));
    Camera.Perspective.FieldOfViewAxis := FPlayerFovAxis;
    Camera.Perspective.FieldOfView := FPlayerFov;
  end;
  { info_player_teleport }
  if FGame.TakeTeleport(P, Yaw) then
  begin
    if FInCinematic then
    begin
      FPlayerEye := P + Vector3(0, PlayerEyeHeight, 0);
      FPlayerDir := YawToCgeDir(Yaw);
    end else
      PlaceCamera(P, Yaw);
  end;
  Hud.Exists := not FInCinematic;
  C := FGame.FadeColor;
  FadeRect.Exists := C.W > 0.002;
  FadeRect.Color := C;
end;

procedure TViewPlay.LoadLevel(const AMapName: String);
begin
  WritelnLog('GameViewPlay', 'Loading map "%s"', [AMapName]);
  LoadProfileStart;
  if SamplerWanted then
    SamplerStart;
  { keep the current level when the new one doesn't exist }
  if not TDoom3Map.MapExists(AMapName) then
  begin
    WritelnWarning('GameViewPlay', 'No map "%s"', [AMapName]);
    Hud.ShowMessage('No map ' + AMapName, 6);
    Console.Print('No map ' + AMapName + ' (type "maps" for the list)');
    Exit;
  end;
  FGame.Clear;
  if FInCinematic then
  begin
    FInCinematic := False;
    Camera.Perspective.FieldOfViewAxis := FPlayerFovAxis;
    Camera.Perspective.FieldOfView := FPlayerFov;
  end;
  if not Map.LoadMap(AMapName) then
  begin
    Hud.ShowMessage('Cannot load map ' + AMapName, 6);
    Console.Print('Cannot load map ' + AMapName);
    Exit;
  end;
  MapName := AMapName;
  FGame.Health := 100;
  FGame.Armor := 0;
  FGame.Spawn;
  PlaceCamera(Map.SpawnOrigin, Map.SpawnAngle);
  SetupSky;
  Hud.ShowMessage(AMapName, 4);
  LoadProfileStep('sky');
  FProfileFrames := 1;
end;

procedure TViewPlay.SetupSky;
var
  Urls: TCastleStringArray6;
begin
  if not Map.SkyboxUrls(Urls) then
  begin
    MainViewport.Background := nil;
    Exit;
  end;
  if FSky = nil then
    FSky := TCastleBackground.Create(Self);
  FSky.TexturePositiveX := Urls[0];
  FSky.TextureNegativeX := Urls[1];
  FSky.TexturePositiveY := Urls[2];
  FSky.TextureNegativeY := Urls[3];
  FSky.TexturePositiveZ := Urls[4];
  FSky.TextureNegativeZ := Urls[5];
  MainViewport.Background := FSky;
  WritelnLog('GameViewPlay', 'Sky "%s"', [Map.SkyMaterial]);
end;

procedure TViewPlay.HandleMessage(const Msg: String);
begin
  Hud.ShowMessage(Msg);
  Console.Print(Msg);
end;

procedure TViewPlay.SetFlashlight(const Value: Boolean);
begin
  Flashlight.Exists := Value;
end;

procedure TViewPlay.SetNoclip(const Value: Boolean);
begin
  FNoclip := Value;
  WalkNavigation.Gravity := not Value;
  WalkNavigation.CheckCollisions := not Value;
end;

procedure TViewPlay.HandleConsoleCommand(const Cmd, Args: String);
var
  Maps: TStringList;
  P: TVector3;
  I: Integer;
  L: TD3LightInfo;
  S: String;
  Words: TStringArray;
  E: TD3MapEntity;
  Dist: Single;
  Gui: TD3Gui;
  GuiImage: TCastleImage;
begin
  if Cmd = 'help' then
  begin
    Console.Print('map <name>, maps, noclip, god, notarget, flashlight, kill, health <n>,');
    Console.Print('give armor, pos, setviewpos x y z [yaw], fps, lightscale <f>, decls,');
    Console.Print('r_useportals [0|1], r_lightvolumes [0|1], r_shadows [0|1], r_md5ShadowTris <n>,');
    Console.Print('portals, lights, lightsat, ent <name>, guidump <gui file>, scripts, g_stopTime [0|1],');
    Console.Print('skipcinematic, actors, near <entity> [distance], activate <entity>, quit');
  end else
  if (Cmd = 'map') or (Cmd = 'devmap') then
    LoadLevel(Args)
  else
  if Cmd = 'maps' then
  begin
    Maps := ListMaps;
    try
      Console.Print(Maps.CommaText);
    finally
      Maps.Free;
    end;
  end else
  if Cmd = 'noclip' then
  begin
    SetNoclip(not FNoclip);
    Console.Print('noclip ' + BoolToStr(FNoclip, 'ON', 'OFF'));
  end else
  if Cmd = 'god' then
  begin
    FGame.God := not FGame.God;
    Console.Print('godmode ' + BoolToStr(FGame.God, 'ON', 'OFF'));
  end else
  if Cmd = 'notarget' then
  begin
    FGame.NoTarget := not FGame.NoTarget;
    Console.Print('notarget ' + BoolToStr(FGame.NoTarget, 'ON', 'OFF'));
  end else
  if Cmd = 'flashlight' then
    SetFlashlight(not Flashlight.Exists)
  else
  if Cmd = 'kill' then
    FGame.DamagePlayer(1000)
  else
  if Cmd = 'health' then
    FGame.Health := StrToIntDef(Args, 100)
  else
  if Cmd = 'give' then
  begin
    FGame.Health := 100;
    FGame.Armor := 125;
  end else
  if Cmd = 'pos' then
  begin
    P := CgeToD3(Camera.Translation - Vector3(0, PlayerEyeHeight, 0));
    Console.Print(Format('origin %.0f %.0f %.0f  yaw %.0f  area %d',
      [P.X, P.Y, P.Z, CameraYaw, Map.AreaAt(Camera.Translation)]));
  end else
  if Cmd = 'setviewpos' then
  begin
    P := ParseVector3(Args, CgeToD3(Camera.Translation));
    PlaceCamera(D3ToCge(P), StrToFloatDef(Copy(Args, LastDelimiter(' ', Args) + 1, MaxInt), CameraYaw));
  end else
  if Cmd = 'r_useportals' then
  begin
    if Args <> '' then
      Map.PortalCulling := StrToIntDef(Args, 1) <> 0
    else
      Map.PortalCulling := not Map.PortalCulling;
    Console.Print('r_usePortals ' + BoolToStr(Map.PortalCulling, '1', '0'));
  end else
  if Cmd = 'r_shadows' then
  begin
    if Args <> '' then
      Map.Shadows := StrToIntDef(Args, 1) <> 0
    else
      Map.Shadows := not Map.Shadows;
    MainViewport.ShadowVolumes := Map.Shadows;
    Console.Print('r_shadows ' + BoolToStr(Map.Shadows, '1', '0'));
  end else
  if Cmd = 'r_lightvolumes' then
  begin
    if Args <> '' then
      LightVolumes := StrToIntDef(Args, 1) <> 0
    else
      LightVolumes := not LightVolumes;
    Console.Print('r_lightVolumes ' + BoolToStr(LightVolumes, '1', '0') + ', reloading the map');
    LoadLevel(MapName);
  end else
  if Cmd = 'r_md5shadowtris' then
  begin
    if Args <> '' then
    begin
      MaxShadowCastingTriangles := StrToIntDef(Args, MaxShadowCastingTriangles);
      Console.Print(Format('r_md5ShadowTris %d, reloading the map', [MaxShadowCastingTriangles]));
      LoadLevel(MapName);
    end else
      Console.Print(Format('r_md5ShadowTris %d (bigger md5 meshes cast with joint boxes)',
        [MaxShadowCastingTriangles]));
  end else
  if Cmd = 'guidump' then
  begin
    { draw a GUI file (no state) and save it next to the screenshots }
    Gui := TD3Gui.Create;
    try
      if Gui.LoadFromVfs(Args) then
      begin
        GuiImage := RenderGui(Gui, nil);
        try
          { back to the GUI's 640 x 480 shape }
          GuiImage.Resize(GuiWidth, GuiHeight, riBilinear);
          S := Iff(AutoTestPrefix <> '', AutoTestPrefix, 'castle-doom3') + '_gui.png';
          SaveImage(GuiImage, S);
          Console.Print('Saved ' + S);
          WritelnLog('GuiDump', '%s (%d windows) -> %s', [Args, Gui.WindowCount, S]);
        finally FreeAndNil(GuiImage) end;
      end else
        Console.Print('Cannot load GUI ' + Args);
    finally FreeAndNil(Gui) end;
  end else
  if Cmd = 'ent' then
  begin
    { a built entity (brush entity or static model): scene state }
    S := 'not built (no brush or static model entity named ' + Args + ')';
    for I := 0 to Map.Brushes.Count - 1 do
      if SameText(Map.Brushes[I].Entity.Name, Args) then
      begin
        S := Format('%s %s exists=%s visible=%s areas=%d box=%s', [Args, Map.Brushes[I].Entity.ClassName_,
          BoolToStr(Map.Brushes[I].Scene.Exists, '1', '0'), BoolToStr(Map.Brushes[I].Scene.Visible, '1', '0'),
          Length(Map.Brushes[I].Areas), Map.Brushes[I].Scene.WorldBoundingBox.ToString]);
        Break;
      end;
    Console.Print(S);
    WritelnLog('Ent', S);
  end else
  if Cmd = 'activate' then
  begin
    { as if a trigger targeted it }
    if FGame.FindEntity(Args) <> nil then
      FGame.Activate(FGame.FindEntity(Args))
    else
      Console.Print('activate: no entity ' + Args);
  end else
  if Cmd = 'near' then
  begin
    { stand in front of an entity, facing it: near <name> [distance] }
    Words := Args.Split([' '], TStringSplitOptions.ExcludeEmpty);
    if (Length(Words) > 0) and (FGame.FindEntity(Words[0]) <> nil) then
    begin
      E := FGame.FindEntity(Words[0]);
      Dist := 100;
      if Length(Words) > 1 then
        Dist := StrToFloatDef(Words[1], 100);
      P := E.Origin + Vector3(Cos(DegToRad(E.Angle)), Sin(DegToRad(E.Angle)), 0) * Dist;
      PlaceCamera(D3ToCge(P), E.Angle + 180);
      Console.Print(Format('near %s at %s', [E.Name, P.ToString]));
    end else
      Console.Print('near: no entity ' + Args);
  end else
  if Cmd = 'actors' then
  begin
    S := FGame.ActorStatus;
    Console.Print(S);
    WritelnLog('Actors', LineEnding + S);
  end else
  if Cmd = 'skipcinematic' then
    FGame.SkipCinematic
  else
  if Cmd = 'aas' then
  begin
    { the player's AAS area; with an entity, its route to the player }
    S := FGame.RouteStatus(Args);
    Console.Print(S);
    WritelnLog('AAS', S);
  end else
  if Cmd = 'sample' then
  begin
    { the sampling profiler (Doom3Sampler): "sample start", "sample stop"
      writes samples.txt next to the exe (tools/resolve_samples.py) }
    if Args = 'start' then
    begin
      SamplerStart;
      Console.Print('Sampling');
    end else
    begin
      SamplerStopAndReport('Sample of ' + MapName);
      Console.Print('Samples written (samples.txt)');
    end;
  end else
  if Cmd = 'scripts' then
  begin
    S := FGame.ScriptStatus;
    Console.Print(S);
    WritelnLog('Scripts', S);
  end else
  if Cmd = 'g_stoptime' then
  begin
    { freeze script threads and the entities they move }
    if Args <> '' then
      FGame.ScriptsPaused := StrToIntDef(Args, 1) <> 0
    else
      FGame.ScriptsPaused := not FGame.ScriptsPaused;
    Console.Print('g_stopTime ' + BoolToStr(FGame.ScriptsPaused, '1', '0'));
  end else
  if Cmd = 'lightsat' then
  begin
    { lights reaching the player: Doom 3 light texture coordinates (s, t, q)
      and strength at the floor below the eye and at the eye }
    P := Camera.Translation - Vector3(0, PlayerEyeHeight - 1, 0);
    for I := 0 to Map.LightCount - 1 do
    begin
      L := Map.Light(I);
      if (Map.LightStrengthAt(I, P) > 0) or (Map.LightStrengthAt(I, Camera.Translation) > 0) then
      begin
        S := Format('%s %s on=%s floor %.2f eye %.2f stq %s', [L.Entity.Name, L.Entity.Value('texture', '(default)'),
          BoolToStr(L.Node.IsOn, '1', '0'), Map.LightStrengthAt(I, P), Map.LightStrengthAt(I, Camera.Translation),
          LightTexCoord(L.Matrix, P).ToString]);
        Console.Print(S);
        WritelnLog('LightsAt', S);
      end;
    end;
  end else
  if Cmd = 'lights' then
  begin
    for I := 0 to Map.LightCount - 1 do
    begin
      L := Map.Light(I);
      S := Format('%s %s color %.2f %.2f %.2f%s%s%s', [L.Entity.Name, L.Entity.Value('texture', '(default)'),
        L.Color.X, L.Color.Y, L.Color.Z, BoolToStr(L.Animated, ' animated', ''),
        BoolToStr(L.Node.IsOn, '', ' off'), BoolToStr(I = Map.ShadowLight, ' shadows', '')]);
      Console.Print(S);
      WritelnLog('Lights', S);
    end;
  end else
  if Cmd = 'portals' then
  begin
    Console.Print(Format('area %d, %d of %d areas visible, %d portals',
      [Map.AreaAt(Camera.Translation), Map.VisibleAreaCount, Map.AreaCount,
       Map.Portals.PortalCount]));
    WritelnLog('Portals', 'area %d, %d of %d areas visible',
      [Map.AreaAt(Camera.Translation), Map.VisibleAreaCount, Map.AreaCount]);
  end else
  if Cmd = 'fps' then
    LabelFps.Exists := not LabelFps.Exists
  else
  if Cmd = 'lightscale' then
  begin
    Map.LightScale := StrToFloatDef(Args, 1);
    LoadLevel(MapName);
  end else
  if Cmd = 'decls' then
    Console.Print(Format('%d materials, %d entityDefs, %d models, %d skins, %d sound shaders',
      [Decls.DeclCount(dtMaterial), Decls.DeclCount(dtEntityDef), Decls.DeclCount(dtModel),
       Decls.DeclCount(dtSkin), Decls.DeclCount(dtSound)]))
  else
  if Cmd = 'quit' then
    Application.Terminate
  else
    Console.Print('Unknown command "' + Cmd + '"');
end;

procedure TViewPlay.CaptureScreenshot;
var
  Path, ShadowName: String;
  Img: TCastleImage;
begin
  Inc(FShots);
  if AutoTestPrefix <> '' then
    Path := AutoTestPrefix + '_' + IntToStr(FShots) + '.png'
  else
    Path := FormatDateTime('"castle-doom3-"yyyymmdd-hhnnss', Now) + '.png';
  Img := Container.SaveScreen;
  try
    SaveImage(Img, Path);
  finally
    Img.Free;
  end;
  if Map.ShadowLight >= 0 then
    ShadowName := Map.Light(Map.ShadowLight).Entity.Name
  else
    ShadowName := 'none';
  WritelnLog('GameViewPlay', 'Screenshot "%s" (%.1f FPS, eye %s, yaw %.0f, area %d, visible areas %d, shadows %s%s)',
    [Path, Container.Fps.RealFps, CgeToD3(Camera.Translation).ToString, CameraYaw,
     Map.AreaAt(Camera.Translation), Map.VisibleAreaCount, ShadowName,
     Iff(FGame.CinematicName <> '', ', cinematic ' + FGame.CinematicName, '')]);
end;

procedure TViewPlay.ReleaseDemoKeys;
var
  K: TKey;
  KeyString: String;
begin
  if Container <> nil then
    for K in FDemoHeld do
      Container.Pressed.KeyUp(K, KeyString);
  FDemoHeld := nil;
end;

{ Demo script commands (comma separated):
  W:sec wait, S screenshot, T:deg turn left, A:deg absolute yaw (Doom 3),
  P:deg pitch up, G:x y z go to Doom 3 coordinates (feet), F flashlight,
  X fire, U use, GO:forward side seconds hold movement keys (1 / -1 / 0),
  N:i stand 150 units in front of monster i facing it, Y god mode,
  O:command console command, L:map load a map, Q quit. }
procedure TViewPlay.RunDemoStep(const SecondsPassed: Single);
var
  Cmd, Action, Param: String;
  P, I: Integer;
  Parts: TStringArray;
  Mon: TD3Monster;
  Dir: TVector3;
begin
  if FQuitting then
    Exit;
  if FDemoIndex >= FDemoCommands.Count then
  begin
    WritelnLog('AutoTest', 'Demo finished');
    FQuitting := True;
    Application.Terminate;
    Exit;
  end;
  Cmd := Trim(FDemoCommands[FDemoIndex]);
  P := Pos(':', Cmd);
  if P > 0 then
  begin
    Action := UpperCase(Copy(Cmd, 1, P - 1));
    Param := Copy(Cmd, P + 1, MaxInt);
  end else
  begin
    Action := UpperCase(Cmd);
    Param := '';
  end;

  if Action = 'W' then
  begin
    FDemoTimer := FDemoTimer + SecondsPassed;
    if FDemoTimer < StrToFloatDef(Param, 1) then
      Exit;
    FDemoTimer := 0;
  end else
  if Action = 'GO' then
  begin
    Parts := Param.Split([' '], TStringSplitOptions.ExcludeEmpty);
    if FDemoTimer = 0 then
    begin
      ReleaseDemoKeys;
      if (Length(Parts) > 0) and (StrToFloatDef(Parts[0], 0) > 0) then
        FDemoHeld := Concat(FDemoHeld, [keyW]);
      if (Length(Parts) > 0) and (StrToFloatDef(Parts[0], 0) < 0) then
        FDemoHeld := Concat(FDemoHeld, [keyS]);
      if (Length(Parts) > 1) and (StrToFloatDef(Parts[1], 0) > 0) then
        FDemoHeld := Concat(FDemoHeld, [keyD]);
      if (Length(Parts) > 1) and (StrToFloatDef(Parts[1], 0) < 0) then
        FDemoHeld := Concat(FDemoHeld, [keyA]);
      for I := 0 to High(FDemoHeld) do
        Container.Pressed.KeyDown(FDemoHeld[I], '');
    end;
    FDemoTimer := FDemoTimer + SecondsPassed;
    if (Length(Parts) > 2) and (FDemoTimer < StrToFloatDef(Parts[2], 1)) then
      Exit;
    ReleaseDemoKeys;
    FDemoTimer := 0;
  end else
  if Action = 'S' then
    CaptureScreenshot
  else
  if Action = 'T' then
    Camera.Direction := RotatePointAroundAxisDeg(StrToFloatDef(Param, 0), Camera.Direction,
      Vector3(0, 1, 0))
  else
  if Action = 'A' then
    Camera.SetWorldView(Camera.Translation, YawToCgeDir(StrToFloatDef(Param, 0)), Vector3(0, 1, 0))
  else
  if Action = 'P' then
  begin
    Dir := Camera.Direction;
    Dir := RotatePointAroundAxisDeg(StrToFloatDef(Param, 0), Dir,
      TVector3.CrossProduct(Dir, Vector3(0, 1, 0)));
    Camera.SetWorldView(Camera.Translation, Dir, Vector3(0, 1, 0));
  end else
  if Action = 'G' then
    PlaceCamera(D3ToCge(ParseVector3(Param, TVector3.Zero)), CameraYaw)
  else
  if Action = 'F' then
    SetFlashlight(not Flashlight.Exists)
  else
  if Action = 'X' then
    FGame.Fire(Camera.Translation, Camera.Direction)
  else
  if Action = 'U' then
    FGame.Use(Camera.Translation, Camera.Direction)
  else
  if Action = 'Y' then
    FGame.God := True
  else
  if Action = 'N' then
  begin
    I := StrToIntDef(Param, 0);
    if (I >= 0) and (I < FGame.Monsters.Count) then
    begin
      Mon := FGame.Monsters[I];
      { 150 units from the monster, the first free direction from where it looks }
      for P := 0 to 7 do
      begin
        Dir := YawToCgeDir(Mon.Yaw + P * 45);
        if not MainViewport.Items.WorldSegmentCollision(Mon.Center,
          Mon.Center + Dir * (150 + PlayerRadius)) then
          Break;
      end;
      PlaceCamera(Mon.Position + Dir * 150, 0);
      Dir := Mon.Center - Camera.Translation;
      Dir.Y := 0;
      Camera.SetWorldView(Camera.Translation, Dir.Normalize, Vector3(0, 1, 0));
    end;
  end else
  if Action = 'O' then
    HandleConsoleCommand(LowerCase(Trim(Copy(Param, 1, Pos(' ', Param + ' ') - 1))),
      Trim(Copy(Param, Pos(' ', Param + ' ') + 1, MaxInt)))
  else
  if Action = 'L' then
    LoadLevel(Param)
  else
  if Action = 'Q' then
  begin
    FQuitting := True;
    Application.Terminate;
    Exit;
  end else
    WritelnWarning('AutoTest', 'Unknown demo command "%s"', [Cmd]);
  Inc(FDemoIndex);
end;

procedure TViewPlay.Update(const SecondsPassed: Single; var HandleInput: Boolean);
var
  Firing: Boolean;
begin
  inherited Update(SecondsPassed, HandleInput);
  if FGame = nil then
    Exit;
  if FProfileFrames > 0 then
  begin
    { the time since the last step: the previous frame (its render) }
    LoadProfileStep('frame ' + IntToStr(FProfileFrames));
    Inc(FProfileFrames);
    if FProfileFrames > 5 then
    begin
      FProfileFrames := 0;
      LoadProfileLog(Format('Map "%s"', [MapName]));
      if Profiler.Enabled then
        WritelnLogMultiline('Time Profile', Profiler.Summary);
      SamplerStopAndReport(Format('Map "%s"', [MapName]));
    end;
  end;
  LabelFps.Caption := 'FPS: ' + Container.Fps.ToString;

  WalkNavigation.Exists := not Console.IsOpen and not FGame.PlayerDead and not FInCinematic;

  if (AutoTestPrefix = '') and not Console.IsOpen then
  begin
    Firing := (buttonLeft in Container.MousePressed) or Container.Pressed[keyCtrl];
    if Firing then
    begin
      if FGame.PlayerDead then
      begin
        if FGame.DeadTime > 1 then
          LoadLevel(MapName);
      end else
        FGame.Fire(Camera.Translation, Camera.Direction);
    end;
  end;

  { during cinematics the player stays where the camera was }
  if FInCinematic then
    FGame.Update(SecondsPassed, FPlayerEye)
  else
    FGame.Update(SecondsPassed, Camera.Translation);
  UpdateCinematic;
  Map.UpdateVisibility(Camera);
  MuzzleFlash.Exists := FGame.SinceFire < 0.07;

  Hud.Health := FGame.Health;
  Hud.Armor := FGame.Armor;
  Hud.Dead := FGame.PlayerDead;
  Hud.FlashlightOn := Flashlight.Exists;
  Hud.AmmoText := Format('PISTOL      KILLS %d', [FGame.Kills]);

  if AutoTestPrefix <> '' then
    RunDemoStep(SecondsPassed);
end;

function TViewPlay.Press(const Event: TInputPressRelease): Boolean;
begin
  Result := inherited Press(Event);
  if Result then
    Exit;

  if Console.Press(Event) then
    Exit(True);

  if Event.IsKey(keyEscape) then
  begin
    { Escape skips a cinematic, like in Doom 3 }
    if FInCinematic then
      FGame.SkipCinematic
    else
      Container.View := ViewMenu;
    Exit(True);
  end;
  if Event.IsKey(keyF) then
  begin
    SetFlashlight(not Flashlight.Exists);
    Exit(True);
  end;
  if Event.IsKey(keyE) then
  begin
    FGame.Use(Camera.Translation, Camera.Direction);
    Exit(True);
  end;
  if Event.IsKey(keyF5) then
  begin
    LabelFps.Exists := not LabelFps.Exists;
    Exit(True);
  end;
  if Event.IsKey(keyF12) then
  begin
    CaptureScreenshot;
    Exit(True);
  end;
end;

end.
