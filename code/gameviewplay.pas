{ The game view: a Doom 3 map, the player, HUD and console.
  Its components are designed in data/gameviewplay.castle-user-interface . }
unit GameViewPlay;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils,
  CastleVectors, CastleUIControls, CastleControls, CastleKeysMouse, CastleViewport,
  CastleCameras, CastleTransform, CastleScene, X3DNodes, X3DFields,
  Doom3Level, Doom3World, Doom3Hud, Doom3Console, Doom3Efx, Doom3Particles, Doom3Pda;

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
    { environment probes (r_envProbes): one EnvironmentLight per area,
      baked from the map; nil until baked for the current map }
    FEnvProbes: TCastleScene;
    FEnvProbesOn: Boolean;
    FEnvProbeScale: Single;
    { a cinematic camera has the view: the player's view to go back to }
    FInCinematic: Boolean;
    { the camera before ApplyViewBob }
    FBobApplied: Boolean;
    { seconds walk navigation has been falling (Doom 3's falling speed) }
    FFallTime: Single;
    { double vision (idPlayerView::DoubleVision) as a screen effect }
    FDvEffect: TScreenEffectNode;
    { walk navigation's MoveSpeed of the design (berserk multiplies it) }
    FBaseMoveSpeed: Single;
    { the jump's height (JumpMaxHeight times PreferredHeight, which
      crouching changes) }
    FBaseJump: Single;
    { the console's crouch holds the crouch key }
    FDemoCrouch: Boolean;
    { GO:... crouch holds it while moving }
    FDemoGoCrouch: Boolean;
    FDvShift: TSFFloat;
    FBobSavedPos, FBobSavedDir, FBobSavedUp: TVector3;
    FPlayerEye, FPlayerDir: TVector3;
    FPlayerFov: Single;
    FPlayerFovAxis: TFieldOfViewAxis;
    { the camera's own field of view (target_setfov changes it) }
    FDefaultFov: Single;
    FDefaultFovAxis: TFieldOfViewAxis;
    FFovApplied: Boolean;
    { the PDA screen (Tab): PDAs, emails, objectives }
    FPdaPanel: TCastleRectangleControl;
    FPdaLabel: TCastleLabel;
    FPdaOpen: Boolean;
    FPdaIndex: Integer;
    { after loading a map: the first frames (textures, shaders) are profiled }
    FProfileFrames: Integer;
    { the map's efxs/<map>.efx (nil when missing), the effect in
      SoundEngine.Reverb (nil = reverb off), console s_useEAXReverb }
    FEfx: TD3EfxFile;
    FReverbEffect: TD3ReverbEffect;
    FUseReverb: Boolean;
    procedure LoadReverb;
    procedure UpdateReverb;
    procedure SetReverbEffect(const Effect: TD3ReverbEffect; const Why: String);
    function ReverbStatus: String;
    procedure UpdateCinematic;
    procedure LoadLevel(const AMapName: String);
    procedure SetupSky;
    procedure PlaceCamera(const FeetPos: TVector3; const YawDeg: Single);
    procedure HandleMessage(const Msg: String);
    procedure HandleFlashlight(const Value: Boolean);
    procedure HandleEndLevel(const Msg: String);
    procedure SetPdaOpen(const Value: Boolean);
    procedure UpdatePdaText;
    procedure HandleConsoleCommand(const Cmd, Args: String);
    { fire the weapon: Once from a demo script, else the button is held }
    procedure Fire(const Once: Boolean);
    { the weapon's muzzle flash light (its def's flashColor, flashRadius,
      flashTime), else the built-in pistol's }
    procedure UpdateMuzzleFlash;
    { the HUD's tunnel vision and blood blobs from the game's damage }
    procedure UpdateDamageView;
    { walk navigation falls at Doom 3's speed (TD3Game.FallSpeed) }
    procedure UpdateFallSpeed(const SecondsPassed: Single);
    { knockback moves the camera (with collisions) }
    procedure ApplyKnockback(const SecondsPassed: Single);
    procedure CreateDoubleVision;
    procedure SetFlashlight(const Value: Boolean);
    procedure SetNoclip(const Value: Boolean);
    procedure RunDemoStep(const SecondsPassed: Single);
    procedure ReleaseDemoKeys;
    procedure BakeEnvProbes;
    procedure FreeEnvProbes;
    procedure SetEnvProbeScale(const Value: Single);
    procedure UpdateCrouch(const SecondsPassed: Single);
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
    { the view's bob, only while rendering (walk navigation moves the
      camera without it) }
    procedure Render; override;
    procedure RenderOverChildren; override;
  strict private
    procedure ApplyViewBob;
    procedure RemoveViewBob;
  end;

var
  ViewPlay: TViewPlay;

implementation

uses
  Math, TypInfo,
  CastleWindow, CastleLog, CastleImages, CastleUtils, CastleStringUtils, CastleRenderOptions, CastleTimeUtils,
  CastleSoundEngine, CastleInternalOpenAL, CastleInternalEFX,
  Doom3Sampler,
  CastleShapes, CastleBoxes,
  Doom3MapFile, Doom3Files, Doom3Decls, Doom3LightEffects, Doom3Md5, Doom3Gui, Doom3Images, GameViewMenu,
  Doom3EnvProbes, CastleColors;

constructor TViewPlay.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  DesignUrl := 'castle-data:/gameviewplay.castle-user-interface';
  FDemoCommands := TStringList.Create;
  MapName := 'testmap';
  FUseReverb := True;
  FEnvProbeScale := 0.5;
end;

destructor TViewPlay.Destroy;
begin
  FDemoCommands.Free;
  FreeAndNil(FEfx);
  inherited Destroy;
end;

procedure TViewPlay.Start;
begin
  inherited Start;
  FGame := TD3Game.Create(Map);
  FGame.OnMessage := @HandleMessage;
  FGame.OnFlashlight := @HandleFlashlight;
  FGame.OnEndLevel := @HandleEndLevel;
  FDefaultFov := Camera.Perspective.FieldOfView;
  FDefaultFovAxis := Camera.Perspective.FieldOfViewAxis;
  { the PDA screen }
  FPdaPanel := TCastleRectangleControl.Create(FreeAtStop);
  FPdaPanel.Color := Vector4(0.02, 0.08, 0.12, 0.94);
  FPdaPanel.Width := 1000;
  FPdaPanel.Height := 680;
  FPdaPanel.Anchor(hpMiddle);
  FPdaPanel.Anchor(vpMiddle);
  FPdaPanel.Exists := False;
  InsertFront(FPdaPanel);
  FPdaLabel := TCastleLabel.Create(FreeAtStop);
  FPdaLabel.Color := Vector4(0.75, 0.9, 1, 1);
  FPdaLabel.MaxWidth := 960;
  FPdaLabel.Anchor(hpLeft, 20);
  FPdaLabel.Anchor(vpTop, -20);
  FPdaPanel.InsertFront(FPdaLabel);
  Console.OnCommand := @HandleConsoleCommand;
  FNoclip := False;
  FShots := 0;
  { Doom 3's view bob (TD3Game.ViewBobOffset / ViewBobAngles) instead of
    CGE's head bobbing }
  WalkNavigation.HeadBobbing := 0;
  { Doom 3 steps up at once and smooths only the view (TD3Game's step up),
    and has no falling camera effect (a landing dips the view instead) }
  WalkNavigation.GrowSpeed := 1000;
  FBaseMoveSpeed := WalkNavigation.MoveSpeed;
  FBaseJump := WalkNavigation.JumpMaxHeight * WalkNavigation.PreferredHeight;
  { crouching is TD3Game's (Doom 3's heights and rate): CGE's own crouch
    (Input_Crouch lowering the camera) does nothing, its key is read }
  WalkNavigation.CrouchHeight := 1;
  CreateDoubleVision;
  WalkNavigation.FallingEffect := False;
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

procedure TViewPlay.FreeEnvProbes;
begin
  if FEnvProbes <> nil then
  begin
    MainViewport.Items.Remove(FEnvProbes);
    FreeAndNil(FEnvProbes);
  end;
end;

procedure TViewPlay.BakeEnvProbes;
const
  FaceSize = 32;
  IrradianceSize = 8;
  { the reflection: blurred like a glossy (not mirror) surface reflects }
  SpecularSize = 16;
  SpecularExponent = 32;
var
  BakeViewport: TCastleViewport;
  BakeCamera: TCastleCamera;
  Hidden: TCastleTransformList;
  Root: TX3DRootNode;
  I, Count: Integer;
  Box: TBox3D;
  Faces, Irradiance, Specular: TD3CubeImages;
  SH: TD3SH9;
  SavedPortalCulling: Boolean;
  Child: TCastleTransform;
  StartTime: TTimerResult;
begin
  FreeEnvProbes;
  if not EnvironmentProbesAvailable then
  begin
    Console.Print('r_envProbes: not supported by this CGE (needs EnvironmentLight.influenceSize)');
    WritelnLog('GameViewPlay', 'Environment probes: not supported by this CGE (needs EnvironmentLight.influenceSize, CGE change P)');
    Exit;
  end;
  StartTime := Timer;
  { Bake the map alone: every area visible, its lights on,
    without the weapon, the player's body, creatures and items. }
  SavedPortalCulling := Map.PortalCulling;
  Map.PortalCulling := False;
  Map.UpdateVisibility(nil);
  Hidden := TCastleTransformList.Create(false);
  BakeViewport := TCastleViewport.Create(nil);
  BakeCamera := TCastleCamera.Create(nil);
  Root := TX3DRootNode.Create;
  try
    for I := 0 to MainViewport.Items.Count - 1 do
    begin
      Child := MainViewport.Items[I];
      if (Child <> Map) and Child.Exists then
      begin
        Child.Exists := False;
        Hidden.Add(Child);
      end;
    end;
    BakeViewport.Items := MainViewport.Items;
    MainViewport.Items.Add(BakeCamera);
    BakeViewport.Camera := BakeCamera;
    BakeViewport.BackgroundColor := Black;
    BakeViewport.ShadowVolumes := MainViewport.ShadowVolumes;

    Count := 0;
    for I := 0 to Map.AreaCount - 1 do
    begin
      Box := TBox3D.Empty;
      if Map.AreaScene(I) <> nil then
        Box.Include(Map.AreaScene(I).BoundingBox);
      if Map.AreaNonSolidScene(I) <> nil then
        Box.Include(Map.AreaNonSolidScene(I).BoundingBox);
      if Box.IsEmpty then
        Continue;
      { the probe at the area's center, used by the shapes inside its bounds }
      Faces := CaptureCubeFaces(Container, BakeViewport, Box.Center, FaceSize);
      try
        SH := ProjectSH9(Faces);
        Irradiance := IrradianceFaces(SH, IrradianceSize);
        Specular := BlurredFaces(Faces, SpecularSize, SpecularExponent);
        try
          Root.AddChildren(CreateProbeLight(CubeMapTexture(Irradiance),
            CubeMapTexture(Specular), Box.Center, Box.Size, FEnvProbeScale));
        finally
          FreeCubeImages(Irradiance);
          FreeCubeImages(Specular);
        end;
      finally FreeCubeImages(Faces) end;
      Inc(Count);
    end;
  finally
    MainViewport.Items.Remove(BakeCamera);
    FreeAndNil(BakeCamera);
    FreeAndNil(BakeViewport);
    for I := 0 to Hidden.Count - 1 do
      Hidden[I].Exists := True;
    FreeAndNil(Hidden);
    Map.PortalCulling := SavedPortalCulling;
  end;

  FEnvProbes := TCastleScene.Create(nil);
  FEnvProbes.Name := 'EnvProbes';
  FEnvProbes.Load(Root, True);
  FEnvProbes.CastGlobalLights := True;
  FEnvProbes.Collides := False;
  FEnvProbes.Pickable := False;
  FEnvProbes.Exists := FEnvProbesOn;
  MainViewport.Items.Add(FEnvProbes);
  WritelnLog('GameViewPlay', 'Environment probes: %d areas baked in %.2f s (%d x %d faces)',
    [Count, TimerSeconds(Timer, StartTime), FaceSize, FaceSize]);
end;

procedure TViewPlay.SetEnvProbeScale(const Value: Single);
var
  I: Integer;
  Root: TX3DRootNode;
begin
  FEnvProbeScale := Value;
  if FEnvProbes = nil then
    Exit;
  Root := FEnvProbes.RootNode;
  for I := 0 to Root.FdChildren.Count - 1 do
    if Root.FdChildren[I] is TEnvironmentLightNode then
      TEnvironmentLightNode(Root.FdChildren[I]).Intensity := Value;
end;

procedure TViewPlay.Stop;
begin
  ReleaseDemoKeys;
  FreeEnvProbes;
  SetReverbEffect(nil, 'leaving the game');
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
var
  EyeHeight: Single;
begin
  { crouched, the eye is lower }
  EyeHeight := PlayerEyeHeight;
  if FGame <> nil then
    EyeHeight := FGame.EyeHeight;
  Camera.SetWorldView(FeetPos + Vector3(0, EyeHeight, 0), YawToCgeDir(YawDeg),
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
  FreeEnvProbes;
  FGame.Health := 100;
  FGame.Armor := 0;
  FGame.Spawn;
  PlaceCamera(Map.SpawnOrigin, Map.SpawnAngle);
  LoadReverb;
  SetupSky;
  if FEnvProbesOn then
    BakeEnvProbes;
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

procedure TViewPlay.HandleFlashlight(const Value: Boolean);
begin
  SetFlashlight(Value);
end;

procedure TViewPlay.HandleEndLevel(const Msg: String);
begin
  { idTarget_EndLevel: Doom 3 loads the next map; here the message and
    the log (console "map <name>" loads it) }
  Hud.ShowMessage('End of level: next map ' + Msg, 6);
end;

procedure TViewPlay.SetPdaOpen(const Value: Boolean);
begin
  FPdaOpen := Value and (FGame <> nil);
  FPdaPanel.Exists := FPdaOpen;
  if FPdaOpen then
    UpdatePdaText;
  WritelnLog('GameViewPlay', 'PDA screen %s', [BoolToStr(FPdaOpen, 'open', 'closed')]);
end;

procedure TViewPlay.UpdatePdaText;
var
  T: String;
  I: Integer;
  Pda: TD3PdaDecl;
  Email: TD3EmailDecl;
  Audio: TD3AudioDecl;
  Video: TD3VideoDecl;
  PdaName: String;
begin
  T := 'PDA   (Tab closes, [ and ] switch PDAs)' + LineEnding;
  if FGame.MissionObjective <> '' then
    T := T + LineEnding + 'MISSION OBJECTIVE: ' + FGame.MissionObjective + LineEnding;
  if FGame.ObjectiveCount > 0 then
  begin
    T := T + LineEnding + 'OBJECTIVES' + LineEnding;
    for I := 0 to FGame.ObjectiveCount - 1 do
      T := T + Format('  [%s] %s: %s', [BoolToStr(FGame.Objective(I).Complete, 'x', ' '),
        FGame.Objective(I).Title, FGame.Objective(I).Text]) + LineEnding;
  end;
  T := T + LineEnding + 'PDAs' + LineEnding;
  if FGame.Pdas.Count = 0 then
    T := T + '  (none)' + LineEnding;
  FPdaIndex := EnsureRange(FPdaIndex, 0, Max(0, FGame.Pdas.Count - 1));
  for I := 0 to FGame.Pdas.Count - 1 do
  begin
    Pda := PdaDecl(FGame.Pdas[I]);
    if Pda <> nil then
      PdaName := Pda.FullName
    else
      PdaName := FGame.Pdas[I];
    T := T + Format('  %s %s', [BoolToStr(I = FPdaIndex, '>', ' '), PdaName]) + LineEnding;
  end;
  if FGame.Pdas.Count > 0 then
  begin
    Pda := PdaDecl(FGame.Pdas[FPdaIndex]);
    if Pda <> nil then
    begin
      T := T + LineEnding + Format('%s   %s, %s   security: %s   id %s', [Pda.FullName, Pda.Post, Pda.Title,
        Pda.Security, Pda.Id]) + LineEnding;
      T := T + LineEnding + 'EMAILS' + LineEnding;
      for I := 0 to Pda.Emails.Count - 1 do
      begin
        Email := EmailDecl(Pda.Emails[I]);
        if Email = nil then
          Continue;
        T := T + Format('  %s   from %s, %s', [Email.Subject, Email.From, Email.Date]) + LineEnding +
          '    ' + StringReplace(Email.Text, #10, LineEnding + '    ', [rfReplaceAll]) + LineEnding;
      end;
      { the personal PDA also holds the emails given by target_giveemail }
      if FPdaIndex = 0 then
        for I := 0 to FGame.Emails.Count - 1 do
        begin
          Email := EmailDecl(FGame.Emails[I]);
          if (Email = nil) or (Pda.Emails.IndexOf(FGame.Emails[I]) >= 0) then
            Continue;
          T := T + Format('  %s   from %s, %s', [Email.Subject, Email.From, Email.Date]) + LineEnding +
            '    ' + StringReplace(Email.Text, #10, LineEnding + '    ', [rfReplaceAll]) + LineEnding;
        end;
      if Pda.Audios.Count > 0 then
      begin
        T := T + LineEnding + 'AUDIO LOGS' + LineEnding;
        for I := 0 to Pda.Audios.Count - 1 do
        begin
          Audio := AudioDecl(Pda.Audios[I]);
          if Audio <> nil then
            T := T + Format('  %s: %s', [Audio.AudioName, Audio.Info]) + LineEnding;
        end;
      end;
      if (Pda.Videos.Count > 0) or (FGame.Videos.Count > 0) then
      begin
        T := T + LineEnding + 'VIDEOS' + LineEnding;
        for I := 0 to Pda.Videos.Count - 1 do
        begin
          Video := VideoDecl(Pda.Videos[I]);
          if Video <> nil then
            T := T + Format('  %s: %s', [Video.VideoName, Video.Info]) + LineEnding;
        end;
        for I := 0 to FGame.Videos.Count - 1 do
        begin
          Video := VideoDecl(FGame.Videos[I]);
          if (Video <> nil) and (Pda.Videos.IndexOf(FGame.Videos[I]) < 0) then
            T := T + Format('  %s: %s', [Video.VideoName, Video.Info]) + LineEnding;
        end;
      end;
    end;
  end;
  FPdaLabel.Caption := T;
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

{ The sound engine's information, and whether OpenAL can do reverb: the
  EFX extension (ALC_EXT_EFX), its version and auxiliary sends, and a test
  that an EAX reverb effect and an auxiliary effect slot can be made. }
function SoundInfo: String;
var
  Device: PALCdevice;
  Major, Minor, Sends: TALint;
  Effect, Slot: TALuint;
  Err: TALenum;
begin
  Result := Format('Sound: %s', [SoundEngine.InformationSummary]);
  if not SoundEngine.IsContextOpenSuccess or (alcGetCurrentContext() = nil) then
    Exit(Result + LineEnding + 'No OpenAL context');
  Device := alcGetContextsDevice(alcGetCurrentContext());
  Result := Result + LineEnding + Format('OpenAL device "%s", vendor "%s", renderer "%s", version "%s"', [
    alcGetString(Device, ALC_DEVICE_SPECIFIER), alGetString(AL_VENDOR),
    alGetString(AL_RENDERER), alGetString(AL_VERSION)]);
  if not Load_EFX(Device) then
    Exit(Result + LineEnding + 'EFX (ALC_EXT_EFX): not available');
  alcGetIntegerv(Device, ALC_EFX_MAJOR_VERSION, 1, @Major);
  alcGetIntegerv(Device, ALC_EFX_MINOR_VERSION, 1, @Minor);
  alcGetIntegerv(Device, ALC_MAX_AUXILIARY_SENDS, 1, @Sends);
  Result := Result + LineEnding + Format('EFX (ALC_EXT_EFX): version %d.%d, %d auxiliary sends per source', [
    Major, Minor, Sends]);
  { make an EAX reverb (what Doom 3's .efx files describe), falling back
    to the standard reverb, in an auxiliary effect slot }
  alGetError();
  alGenEffects(1, @Effect);
  alEffecti(Effect, AL_EFFECT_TYPE, AL_EFFECT_EAXREVERB);
  Err := alGetError();
  if Err = AL_NO_ERROR then
    Result := Result + LineEnding + 'EAX reverb effect: OK'
  else
  begin
    alEffecti(Effect, AL_EFFECT_TYPE, AL_EFFECT_REVERB);
    Err := alGetError();
    Result := Result + LineEnding + Format('EAX reverb effect: not supported, standard reverb: %s', [
      Iff(Err = AL_NO_ERROR, 'OK', 'error ' + IntToStr(Err))]);
  end;
  alGenAuxiliaryEffectSlots(1, @Slot);
  alAuxiliaryEffectSloti(Slot, AL_EFFECTSLOT_EFFECT, Effect);
  Err := alGetError();
  Result := Result + LineEnding + Format('Auxiliary effect slot with the reverb: %s', [
    Iff(Err = AL_NO_ERROR, 'OK', 'error ' + IntToStr(Err))]);
  alDeleteAuxiliaryEffectSlots(1, @Slot);
  alDeleteEffects(1, @Effect);
end;

procedure TViewPlay.LoadReverb;
var
  Path: String;
begin
  SetReverbEffect(nil, 'new map');
  if FEfx = nil then
    FEfx := TD3EfxFile.Create;
  Path := EfxPathForMap(MapName);
  if FEfx.LoadFromVfs(Path) then
    WritelnLog('Reverb', 'Found %s: %d effects%s', [Path, FEfx.Effects.Count,
      Iff(SoundEngine.ReverbSupported, '', ' (no reverb with this sound device)')])
  else
  begin
    WritelnLog('Reverb', 'Missing %s', [Path]);
    FreeAndNil(FEfx);
  end;
end;

procedure TViewPlay.SetReverbEffect(const Effect: TD3ReverbEffect; const Why: String);
begin
  if Effect = FReverbEffect then
    Exit;
  FReverbEffect := Effect;
  if Effect <> nil then
  begin
    SoundEngine.Reverb.Assign(Effect.Reverb);
    WritelnLog('Reverb', 'Effect "%s" (%s)', [Effect.Name, Why]);
  end else
  begin
    SoundEngine.Reverb.Enabled := False;
    WritelnLog('Reverb', 'Off (%s)', [Why]);
  end;
end;

{ Like dhewm3: the listener's (camera's) portal area names the effect,
  else its location, else "default"; when none is in the file, the previous
  effect stays. }
procedure TViewPlay.UpdateReverb;
var
  Area: Integer;
  Location: String;
  Effect: TD3ReverbEffect;
begin
  if not FUseReverb then
  begin
    SetReverbEffect(nil, 's_useEAXReverb 0');
    Exit;
  end;
  if (FEfx = nil) or (FGame = nil) then
    Exit;
  Area := Map.AreaAt(Camera.Translation);
  Location := FGame.LocationOfArea(Area);
  Effect := FEfx.Select(Area, Location);
  if Effect <> nil then
    SetReverbEffect(Effect, Format('area %d, location "%s"', [Area, Location]));
end;

function TViewPlay.ReverbStatus: String;
var
  Area: Integer;
  R: TCastleSoundReverb;
begin
  Area := Map.AreaAt(Camera.Translation);
  Result := Format('s_useEAXReverb %s, sound device %s, area %d, location "%s", ', [
    BoolToStr(FUseReverb, '1', '0'),
    Iff(SoundEngine.ReverbSupported, 'supports reverb', 'has no reverb'),
    Area, FGame.LocationOfArea(Area)]);
  if FEfx = nil then
    Result := Result + 'no ' + EfxPathForMap(MapName)
  else
    Result := Result + Format('%d effects in %s', [FEfx.Effects.Count, EfxPathForMap(MapName)]);
  if FReverbEffect = nil then
    Result := Result + ', off'
  else
  begin
    R := FReverbEffect.Reverb;
    Result := Result + Format(', effect "%s": gain %.3f, decay %.2f s, reflections %.3f after %.3f s, late reverb %.3f after %.3f s, density %.2f, diffusion %.2f', [
      FReverbEffect.Name, R.Gain, R.DecayTime, R.ReflectionsGain, R.ReflectionsDelay,
      R.LateReverbGain, R.LateReverbDelay, R.Density, R.Diffusion]);
  end;
end;

procedure TViewPlay.ApplyViewBob;
var
  Angles, Pos, ViewPos: TVector3;
  D: TVector3;
  M: TMatrix3;
begin
  if FBobApplied or (FGame = nil) or FInCinematic then
    Exit;
  FBobSavedPos := Camera.Translation;
  FBobSavedDir := Camera.Direction;
  FBobSavedUp := Camera.Up;
  D := CgeToD3(Camera.Direction);
  Angles := Vector3(D3DirPitch(D), D3DirYaw(D), 0);
  if FGame.PlayerDead then
    { idPlayer::GetViewPos: dead, the view tilts }
    Angles := Vector3(-15, Angles.Y, 40)
  else
    Angles := Angles + FGame.ViewBobAngles;
  Pos := Camera.Translation + FGame.ViewBobOffset;
  { pm_thirdPerson: behind the player (idPlayer::OffsetThirdPersonView) }
  if FGame.ThirdPersonActive then
  begin
    { the plain view angles (no dead tilt) }
    if FGame.PlayerDead then
      Angles := Vector3(D3DirPitch(D), D3DirYaw(D), 0);
    FGame.ThirdPersonView(Pos, Angles, ViewPos);
    Pos := ViewPos;
  end else
  if Angles.IsZero(0.0001) and FGame.ViewBobOffset.IsZero then
    Exit;
  M := AnglesMatrix(Angles);
  Camera.SetView(Pos,
    D3ToCge(Vector3(M.Data[0, 0], M.Data[0, 1], M.Data[0, 2])),
    D3ToCge(Vector3(M.Data[2, 0], M.Data[2, 1], M.Data[2, 2])));
  FBobApplied := True;
end;

procedure TViewPlay.RemoveViewBob;
begin
  if not FBobApplied then
    Exit;
  FBobApplied := False;
  Camera.SetView(FBobSavedPos, FBobSavedDir, FBobSavedUp);
end;

procedure TViewPlay.Render;
begin
  inherited Render;
  { before the children: the viewport renders with the bob }
  ApplyViewBob;
end;

procedure TViewPlay.RenderOverChildren;
begin
  RemoveViewBob;
  inherited RenderOverChildren;
end;

procedure TViewPlay.CreateDoubleVision;
var
  Part: TShaderPartNode;
  Shader: TComposedShaderNode;
begin
  if FDvEffect <> nil then
    Exit;
  { the frame drawn shifted left (opaque), then shifted right at half
    alpha, like idPlayerView::DoubleVision's two stretched pictures }
  Part := TShaderPartNode.Create;
  Part.ShaderType := stFragment;
  Part.Contents :=
    'uniform float shift;' + NL +
    'void main (void)' + NL +
    '{' + NL +
    '  vec2 p = screenf_position();' + NL +
    '  float w = float(screen_width);' + NL +
    '  vec4 a = screenf_get_color(vec2(shift * w + p.x * (1.0 - shift), p.y));' + NL +
    '  vec4 b = screenf_get_color(vec2(p.x * (1.0 - shift), p.y));' + NL +
    '  gl_FragColor = mix(a, b, 0.5);' + NL +
    '}';
  Shader := TComposedShaderNode.Create;
  Shader.SetParts([Part]);
  FDvShift := TSFFloat.Create(Shader, True, 'shift', 0);
  Shader.AddCustomField(FDvShift);
  FDvEffect := TScreenEffectNode.Create;
  FDvEffect.SetShaders([Shader]);
  FDvEffect.Enabled := False;
  MainViewport.AddScreenEffect(FDvEffect);
end;

procedure TViewPlay.ApplyKnockback(const SecondsPassed: Single);
var
  Move, NewPos: TVector3;
begin
  Move := FGame.KnockbackMove(SecondsPassed);
  if Move.IsZero or FNoclip or FInCinematic or FGame.PlayerDead then
    Exit;
  if Map.World.WorldMoveAllowed(Camera.Translation, Camera.Translation + Move, NewPos,
    True, WalkNavigation.Radius, TBox3D.Empty, TBox3D.Empty, False) then
  begin
    { a ceiling or a floor stopped the vertical part }
    if FGame.KnockbackAirborne and (Abs(NewPos.Y - (Camera.Translation.Y + Move.Y)) > 0.01) then
      FGame.KnockbackBlocked;
    Camera.Translation := NewPos;
  end else
  if FGame.KnockbackAirborne then
    FGame.KnockbackBlocked;
end;

procedure TViewPlay.UpdateCrouch(const SecondsPassed: Single);
var
  OldHeight: Single;
begin
  FGame.PlayerCrouchHeld := FDemoCrouch or FDemoGoCrouch or
    (not Console.IsOpen and WalkNavigation.Input_Crouch.IsPressed(Container));
  OldHeight := FGame.EyeHeight;
  FGame.UpdateCrouch(SecondsPassed, Camera.Translation);
  { the eye goes down / up by the change (the feet stay) }
  if (FGame.EyeHeight <> OldHeight) and not FInCinematic then
    Camera.Translation := Camera.Translation + Vector3(0, FGame.EyeHeight - OldHeight, 0);
  if FGame.EyeHeight >= WalkNavigation.Radius then
    WalkNavigation.PreferredHeight := FGame.EyeHeight;
  { crouched: crouch speed, no running, no jumping (idPhysics_Player) }
  if FGame.Crouched then
  begin
    WalkNavigation.MoveSpeed := FBaseMoveSpeed * FGame.CrouchSpeedScale;
    WalkNavigation.RunMultiplier := 1;
    WalkNavigation.JumpMaxHeight := 0;
  end else
    WalkNavigation.JumpMaxHeight := FBaseJump / WalkNavigation.PreferredHeight;
end;

procedure TViewPlay.UpdateFallSpeed(const SecondsPassed: Single);
begin
  { CGE's walk navigation falls at FallSpeedStart times MoveSpeed, growing
    exponentially by FallSpeedIncrease; Doom 3's speed grows linearly
    (gravity 1066). FallSpeedStart is read when a fall starts, so Falling
    is reset every frame to take the speed for the next one. Navigation
    updates before the view: its Falling says whether it fell this frame. }
  if WalkNavigation.Falling then
    FFallTime := FFallTime + SecondsPassed
  else
    FFallTime := 0;
  WalkNavigation.FallSpeedIncrease := 1;
  WalkNavigation.FallSpeedStart := FGame.FallSpeed(FFallTime + SecondsPassed * 0.5) /
    (WalkNavigation.MoveSpeed * WalkNavigation.MoveVerticalSpeed);
  WalkNavigation.Falling := False;
end;

procedure TViewPlay.UpdateDamageView;
var
  Blobs: specialize TArray<TD3ScreenBlob>;
  I: Integer;
  Mat: TD3Material;
  ImageName: String;
begin
  Hud.DamageAge := FGame.SinceDamage;
  Hud.ArmorPulse := FGame.ArmorPulse;
  Hud.TipTitle := FGame.TipTitle;
  Hud.TipText := FGame.TipText;
  Hud.ObjectiveNotice := FGame.ObjectiveNotice;
  Hud.ObjectiveTitle := FGame.ObjectiveNoticeTitle;
  Hud.ObjectiveText := FGame.ObjectiveNoticeText;
  Hud.RadioChatter := FGame.RadioChatter;
  Hud.RadioTime := Hud.RadioTime + Container.Fps.SecondsPassed;
  { target_setfov: Doom 3's fov is horizontal }
  if not FInCinematic then
  begin
    if FGame.ViewFov > 0 then
    begin
      Camera.Perspective.FieldOfViewAxis := faHorizontal;
      Camera.Perspective.FieldOfView := DegToRad(EnsureRange(FGame.ViewFov, 1, 170));
      FFovApplied := True;
    end else
    if FFovApplied then
    begin
      Camera.Perspective.FieldOfViewAxis := FDefaultFovAxis;
      Camera.Perspective.FieldOfView := FDefaultFov;
      FFovApplied := False;
    end;
  end;
  { berserk (idPlayerView: textures/decals/berserk over the screen, fading
    over its last 10 s); the HUD's own red tint without the material }
  if FGame.PowerUpActive(PowerupBerserk) then
    Hud.BerserkAlpha := Min(1, FGame.PowerUpLeft(PowerupBerserk) / 10)
  else
    Hud.BerserkAlpha := 0;
  if Decls.Material('textures/decals/berserk').Defined and
     (Decls.Material('textures/decals/berserk').StageImage <> '') then
    Hud.BerserkImageUrl := ImageProgramUrl(Decls.Material('textures/decals/berserk').StageImage, ikColor)
  else
    Hud.BerserkImageUrl := '';
  Hud.Invisible := FGame.PowerUpActive(PowerupInvisibility);
  { Doom 3's armorViewEffect when the game has it, else the HUD's own }
  if Decls.Material('armorViewEffect').Defined and (Decls.Material('armorViewEffect').StageImage <> '') then
    Hud.ArmorImageUrl := ImageProgramUrl(Decls.Material('armorViewEffect').StageImage, ikColor)
  else
    Hud.ArmorImageUrl := '';
  if FDvEffect <> nil then
  begin
    FDvEffect.Enabled := FGame.DoubleVisionShift > 0;
    if FDvEffect.Enabled then
      FDvShift.Send(FGame.DoubleVisionShift);
  end;
  Blobs := FGame.ScreenBlobs;
  SetLength(Hud.Blobs, 0);
  for I := 0 to High(Blobs) do
  begin
    { the blob material's image (its first plain stage, else its diffuse map) }
    Mat := Decls.Material(Blobs[I].Material);
    ImageName := Mat.StageImage;
    if ImageName = '' then
      ImageName := Mat.DiffuseImage;
    if ImageName = '' then
      Continue;
    SetLength(Hud.Blobs, Length(Hud.Blobs) + 1);
    Hud.Blobs[High(Hud.Blobs)].ImageUrl := ImageProgramUrl(ImageName, ikColor);
    Hud.Blobs[High(Hud.Blobs)].X := Blobs[I].X;
    Hud.Blobs[High(Hud.Blobs)].Y := Blobs[I].Y;
    Hud.Blobs[High(Hud.Blobs)].W := Blobs[I].W;
    Hud.Blobs[High(Hud.Blobs)].H := Blobs[I].H;
    Hud.Blobs[High(Hud.Blobs)].Alpha := EnsureRange((Blobs[I].Finish - FGame.Time) /
      Max(0.001, Blobs[I].Finish - Blobs[I].Start), 0, 1);
  end;
end;

procedure TViewPlay.UpdateMuzzleFlash;
var
  P, C: TVector3;
  R: Single;
begin
  if FGame.MuzzleFlash(P, C, R) then
  begin
    MuzzleFlash.Exists := True;
    MuzzleFlash.Translation := MuzzleFlash.Parent.WorldToLocal(P);
    MuzzleFlash.Color := C;
    MuzzleFlash.Radius := R;
    { Doom 3's light color is the light at its center }
    MuzzleFlash.Intensity := 1;
  end else
  begin
    { the built-in pistol: a short flash in front of the camera }
    MuzzleFlash.Exists := (FGame.SinceFire < 0.07) and
      ((FGame.Weapon = nil) or not FGame.Weapon.Scripted);
    MuzzleFlash.Translation := Vector3(0, 0, -24);
    MuzzleFlash.Color := Vector3(1, 0.8, 0.4);
    MuzzleFlash.Radius := 400;
    MuzzleFlash.Intensity := 2;
  end;
end;

procedure TViewPlay.Fire(const Once: Boolean);
begin
  { the player's weapon script fires on WEAPON_ATTACK; without one, the
    built-in pistol }
  if (FGame.Weapon <> nil) and FGame.Weapon.Scripted then
  begin
    if Once then
      FGame.AttackOnce;
  end else
    FGame.Fire(Camera.Translation, Camera.Direction);
end;

procedure TViewPlay.HandleConsoleCommand(const Cmd, Args: String);
var
  Maps: TStringList;
  P: TVector3;
  I, J: Integer;
  L: TD3LightInfo;
  S: String;
  Words: TStringArray;
  E: TD3MapEntity;
  Dist: Single;
  Gui: TD3Gui;
  GuiImage: TCastleImage;
  Hit: TRayCollision;
  HitDistance: Single;
  HitNormal: TVector3;
begin
  if Cmd = 'help' then
  begin
    Console.Print('map <name>, maps, noclip, god, notarget, flashlight, kill, health <n>,');
    Console.Print('give [all|weapons|<weapon>|<stat> <amount>], inventory, weapon <slot>, weapnext, weapprev, reload, pm_bob [0|1], hurt <damage def> [amount] [up], pos, setviewpos x y z [yaw], fps, lightscale <f>, decls,');
    Console.Print('r_useportals [0|1], r_lightvolumes [0|1], r_shadows [0|1], r_md5ShadowTris <n>, r_md5ShadowClosed [0|1], r_prelightShadows [0|1],');
    Console.Print('portals, lights, lightsat, ent <name>, pick, guidump <gui file>, guis, objectives, pda [name], scripts, g_stopTime [0|1],');
    Console.Print('stamina [n], pm_stamina <s>, pm_staminarate <r>, pm_staminathreshold <s>, pm_thirdPerson [0|1], pm_thirdPersonRange / Height / Angle <n>, pm_thirdPersonClip [0|1], pm_thirdPersonDeath [0|1], crouch [0|1], ragdoll [0|1], g_showBrass [0|1],');
    Console.Print('skipcinematic, actors, near <entity> [distance], activate <entity>, soundinfo, reverb, s_useEAXReverb [0|1], quit');
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
    { like Doom 3: give all, give <stat> [amount] }
    Words := Trim(Args).Split([' '], TStringSplitOptions.ExcludeEmpty);
    if (Length(Words) = 0) or SameText(Words[0], 'all') then
      FGame.GiveAll
    else
    if SameText(Words[0], 'weapons') then
    begin
      for I := 0 to High(FGame.WeaponDefs) do
        if FGame.WeaponDefs[I] <> '' then
          FGame.Give('weapon', FGame.WeaponDefs[I]);
    end else
    if SameText(Words[0], 'weapon') or (Length(Words) = 1) and (FGame.WeaponSlot(Words[0]) >= 0) then
      FGame.Give('weapon', Words[High(Words)])
    else
    if Length(Words) >= 2 then
      FGame.Give(Words[0], Words[1])
    else
      FGame.Give(Words[0], '1000');
    Console.Print(FGame.InventoryStatus);
  end else
  if Cmd = 'weapon' then
  begin
    if Args <> '' then
      FGame.SelectWeapon(StrToIntDef(Args, -1));
    Console.Print(Format('weapon slot %d: %s', [FGame.IdealSlot, FGame.WeaponHudText]));
  end else
  if Cmd = 'hurt' then
  begin
    { hurt <damage def> [amount] [up]: a hit from the front (from below
      with "up"), with the def's effects (kick, blobs, double vision,
      knockback) }
    Words := Trim(Args).Split([' '], TStringSplitOptions.ExcludeEmpty);
    if Length(Words) = 0 then
      Console.Print('hurt <damage def> [amount] [up]')
    else
    begin
      I := 10;
      if Decls.EntityDef(Words[0]) <> nil then
        I := StrToIntDef(Decls.EntityDef(Words[0]).Values['damage'], 10);
      if Length(Words) > 1 then
        I := StrToIntDef(Words[1], I);
      if (Length(Words) > 2) and SameText(Words[2], 'up') then
        FGame.DamagePlayer(I, Words[0], Vector3(0, 1, 0))
      else
        FGame.DamagePlayer(I, Words[0], -Camera.Direction);
    end;
  end else
  if Cmd = 'hurtmonster' then
  begin
    { hurtmonster <name> [damage def] [amount]: hit a monster from the
      camera's direction (its pain, death, gibs) }
    Words := Trim(Args).Split([' '], TStringSplitOptions.ExcludeEmpty);
    if Length(Words) = 0 then
      Console.Print('hurtmonster <name> [damage def] [amount]')
    else
    begin
      S := '';
      if Length(Words) > 1 then
        S := Words[1];
      I := FGame.DamageInfo(S).Damage;
      if Length(Words) > 2 then
        I := StrToIntDef(Words[2], I);
      for J := 0 to FGame.Monsters.Count - 1 do
        if SameText(FGame.Monsters[J].Model.Entity.Name, Words[0]) then
        begin
          FGame.DamageMonster(FGame.Monsters[J], I, S, FGame.Monsters[J].Center - Camera.Translation);
          Console.Print(Format('%s: health %d', [Words[0], FGame.Monsters[J].Health]));
        end;
    end;
  end else
  if Cmd = 'stamina' then
  begin
    if Args <> '' then
      FGame.Stamina := StrToFloatDef(Args, FGame.Stamina);
    S := Format('Stamina %.1f of %.0f (%d%%), running %.2f, speed x%.2f', [FGame.Stamina,
      FGame.StaminaMax, FGame.StaminaPercent, FGame.RunFraction, FGame.RunMultiplier], DefaultFormatSettings);
    Console.Print(S);
    WritelnLog('Console', S);
  end else
  if Cmd = 'pm_stamina' then
  begin
    if Args <> '' then
      FGame.StaminaMax := StrToFloatDef(Args, FGame.StaminaMax);
    Console.Print(Format('pm_stamina %g (seconds of running, 0: no stamina)', [FGame.StaminaMax], DefaultFormatSettings));
  end else
  if Cmd = 'pm_staminarate' then
  begin
    if Args <> '' then
      FGame.StaminaRate := StrToFloatDef(Args, FGame.StaminaRate);
    Console.Print(Format('pm_staminarate %g', [FGame.StaminaRate], DefaultFormatSettings));
  end else
  if Cmd = 'pm_staminathreshold' then
  begin
    if Args <> '' then
      FGame.StaminaThreshold := StrToFloatDef(Args, FGame.StaminaThreshold);
    Console.Print(Format('pm_staminathreshold %g', [FGame.StaminaThreshold], DefaultFormatSettings));
  end else
  if Cmd = 'pm_thirdperson' then
  begin
    if Args <> '' then
      FGame.ThirdPerson := Args <> '0';
    S := Format('pm_thirdPerson %s (player model %s, skin "%s")', [BoolToStr(FGame.ThirdPerson, '1', '0'),
      BoolToStr(FGame.PlayerModel <> nil, 'yes', 'none'), FGame.PlayerSkinName]);
    Console.Print(S);
    WritelnLog('Console', S);
  end else
  if Cmd = 'g_showbrass' then
  begin
    if Args <> '' then
      FGame.ShowBrass := Args <> '0';
    Console.Print('g_showBrass ' + BoolToStr(FGame.ShowBrass, '1', '0'));
  end else
  if Cmd = 'ragdoll' then
  begin
    { ragdoll [0|1]: the dead body falls as a ragdoll (with the player
      def's "ragdoll"), or plays its death anim }
    if Args <> '' then
      FGame.RagdollEnabled := Args <> '0';
    Console.Print('ragdoll ' + BoolToStr(FGame.RagdollEnabled, '1', '0'));
  end else
  if Cmd = 'pm_thirdpersondeath' then
  begin
    if Args <> '' then
      FGame.ThirdPersonDeath := Args <> '0';
    Console.Print('pm_thirdPersonDeath ' + BoolToStr(FGame.ThirdPersonDeath, '1', '0'));
  end else
  if Cmd = 'crouch' then
  begin
    { crouch [0|1]: hold the crouch key (without an argument: the state) }
    if Args <> '' then
      FDemoCrouch := Args <> '0';
    S := Format('crouch %s (crouched %s, eye height %.1f)', [BoolToStr(FDemoCrouch, '1', '0'),
      BoolToStr(FGame.Crouched, 'yes', 'no'), FGame.EyeHeight]);
    Console.Print(S);
    WritelnLog('Console', S);
  end else
  if Cmd = 'pm_thirdpersonrange' then
  begin
    if Args <> '' then
      FGame.ThirdPersonRange := StrToFloatDef(Args, FGame.ThirdPersonRange);
    Console.Print(Format('pm_thirdPersonRange %g', [FGame.ThirdPersonRange], DefaultFormatSettings));
  end else
  if Cmd = 'pm_thirdpersonheight' then
  begin
    if Args <> '' then
      FGame.ThirdPersonHeight := StrToFloatDef(Args, FGame.ThirdPersonHeight);
    Console.Print(Format('pm_thirdPersonHeight %g', [FGame.ThirdPersonHeight], DefaultFormatSettings));
  end else
  if Cmd = 'pm_thirdpersonangle' then
  begin
    if Args <> '' then
      FGame.ThirdPersonAngle := StrToFloatDef(Args, FGame.ThirdPersonAngle);
    Console.Print(Format('pm_thirdPersonAngle %g', [FGame.ThirdPersonAngle], DefaultFormatSettings));
  end else
  if Cmd = 'pm_thirdpersonclip' then
  begin
    if Args <> '' then
      FGame.ThirdPersonClip := Args <> '0';
    Console.Print('pm_thirdPersonClip ' + BoolToStr(FGame.ThirdPersonClip, '1', '0'));
  end else
  if Cmd = 'pm_bob' then
  begin
    if Args <> '' then
      FGame.ViewBobEnabled := Args <> '0';
    Console.Print('pm_bob ' + BoolToStr(FGame.ViewBobEnabled, '1', '0') + ' (the view bobs)');
  end else
  if Cmd = 'weapnext' then
    FGame.NextWeapon(1)
  else
  if Cmd = 'weapprev' then
    FGame.NextWeapon(-1)
  else
  if Cmd = 'reload' then
    FGame.ReloadWeapon
  else
  if Cmd = 'inventory' then
  begin
    S := FGame.InventoryStatus;
    Console.Print(S);
    WritelnLog('Inventory', LineEnding + S);
  end else
  if Cmd = 'pos' then
  begin
    P := CgeToD3(Camera.Translation - Vector3(0, FGame.EyeHeight, 0));
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
  if Cmd = 'r_envprobes' then
  begin
    { environment probes: baked image-based light per area (CGE change P);
      only with physical materials it is the full effect, the classic
      Phong look gets the diffuse and specular light too: off by default }
    if Args <> '' then
      FEnvProbesOn := StrToIntDef(Args, 1) <> 0
    else
      FEnvProbesOn := not FEnvProbesOn;
    if FEnvProbesOn and (FEnvProbes = nil) then
      BakeEnvProbes;
    if FEnvProbes <> nil then
      FEnvProbes.Exists := FEnvProbesOn;
    Console.Print('r_envProbes ' + BoolToStr(FEnvProbesOn, '1', '0') +
      BoolToStr(FEnvProbesOn and (FEnvProbes = nil), ' (not baked)', ''));
  end else
  if Cmd = 'r_envprobebake' then
  begin
    { bake again (e.g. after lights changed) }
    BakeEnvProbes;
    Console.Print('r_envProbeBake: ' + BoolToStr(FEnvProbes <> nil, 'baked', 'not baked'));
  end else
  if Cmd = 'r_envprobescale' then
  begin
    if Args <> '' then
      SetEnvProbeScale(StrToFloatDefDot(Args, 1));
    Console.Print('r_envProbeScale ' + FloatToStrDot(FEnvProbeScale));
  end else
  if Cmd = 'r_shadowmaps' then
  begin
    { the shadow lights cast shadow maps instead of shadow volumes:
      point lights with 6 views in CGE's shadow map atlas (CGE changes B, R) }
    if not TDoom3Map.ShadowMapsAvailable then
    begin
      Console.Print('r_shadowMaps: not supported by this CGE');
      WritelnLog('GameViewPlay', 'Shadow maps: not supported by this CGE (needs point light shadow maps, CGE changes B and R)');
    end else
    begin
      if Args <> '' then
        Map.ShadowMaps := StrToIntDef(Args, 1) <> 0
      else
        Map.ShadowMaps := not Map.ShadowMaps;
      Console.Print('r_shadowMaps ' + BoolToStr(Map.ShadowMaps, '1', '0'));
      WritelnLog('GameViewPlay', 'Shadow maps %s', [BoolToStr(Map.ShadowMaps, 'on', 'off')]);
    end;
  end else
  if Cmd = 'r_skipparticles' then
  begin
    if Args <> '' then
      SkipParticles := StrToIntDef(Args, 1) <> 0
    else
      SkipParticles := not SkipParticles;
    Console.Print('r_skipParticles ' + BoolToStr(SkipParticles, '1', '0'));
  end else
  if Cmd = 'objectives' then
  begin
    { the mission objective, the objectives given, PDAs, emails }
    S := Format('Objectives: %d (mission: "%s"), PDAs: %s, emails: %s, videos: %s', [FGame.ObjectiveCount,
      FGame.MissionObjective, FGame.Pdas.CommaText, FGame.Emails.CommaText, FGame.Videos.CommaText]);
    Console.Print(S);
    WritelnLog('Objectives', S);
    for I := 0 to FGame.ObjectiveCount - 1 do
    begin
      S := Format('  [%s] %s: %s', [BoolToStr(FGame.Objective(I).Complete, 'x', ' '), FGame.Objective(I).Title,
        FGame.Objective(I).Text]);
      Console.Print(S);
      WritelnLog('Objectives', S);
    end;
  end else
  if Cmd = 'pda' then
  begin
    { pda [name]: toggle the PDA screen (or show a PDA by its decl name) }
    if Args <> '' then
    begin
      I := FGame.Pdas.IndexOf(LowerCase(Trim(Args)));
      if I >= 0 then
        FPdaIndex := I
      else
        Console.Print('pda: not carried: ' + Args);
      SetPdaOpen(True);
    end else
      SetPdaOpen(not FPdaOpen);
  end else
  if Cmd = 'guis' then
  begin
    { every live GUI: its file, entity, windows, redraws, interactivity,
      the cursor and transitions }
    for I := 0 to Map.GuiSurfaces.Count - 1 do
    begin
      S := Format('%s (%s): %d windows, %d redraws%s%s%s', [
        Map.GuiSurfaces[I].Gui.Name, Map.GuiSurfaces[I].EntityName, Map.GuiSurfaces[I].Gui.WindowCount,
        Map.GuiSurfaces[I].Renders, BoolToStr(Map.GuiSurfaces[I].Gui.Interactive, ', interactive', ''),
        BoolToStr(Map.GuiSurfaces[I].Gui.CursorShown, Format(', cursor %d %d', [Round(Map.GuiSurfaces[I].Gui.CursorX),
          Round(Map.GuiSurfaces[I].Gui.CursorY)]), ''),
        BoolToStr(Map.GuiSurfaces[I].Gui.TransitionCount > 0, Format(', %d transitions', [Map.GuiSurfaces[I].Gui.TransitionCount]), '')]);
      Console.Print(S);
      WritelnLog('Guis', S);
    end;
    S := Format('GUIs: %d live, %d redraws, %d clicks', [Map.GuiSurfaces.Count, Map.GuiRenders, FGame.GuiClicks]);
    if FGame.GuiFocus <> nil then
      S := S + ', focus ' + FGame.GuiFocus.Gui.Name;
    Console.Print(S);
    WritelnLog('Guis', S);
  end else
  if Cmd = 'particles' then
  begin
    { every particle system: who, the decl, stages and live particles }
    for I := 0 to FGame.Emitters.Count - 1 do
    begin
      S := Format('%s: %s (%d stages, %d particles)%s%s', [
        FGame.Emitters[I].Name, FGame.Emitters[I].Decl.Name, FGame.Emitters[I].Decl.Stages.Count,
        FGame.Emitters[I].Live, BoolToStr(FGame.Emitters[I].Enabled, '', ' off'),
        BoolToStr(FGame.Emitters[I].Stopped, ' stopped', '')]);
      Console.Print(S);
      WritelnLog('Particles', S);
    end;
    for I := 0 to FGame.Fx.Count - 1 do
    begin
      S := Format('fx %s: %d actions, %.1f s', [FGame.Fx[I].Decl.Name,
        Length(FGame.Fx[I].Actions), FGame.Time - FGame.Fx[I].Start]);
      Console.Print(S);
      WritelnLog('Particles', S);
    end;
    Console.Print(Format('%d particle systems, %d fx', [FGame.Emitters.Count, FGame.Fx.Count]));
  end else
  if Cmd = 'r_shadowmapsize' then
  begin
    { size of each shadow map view, for the next map loaded }
    if Args <> '' then
      Map.ShadowMapSize := Max(16, StrToIntDef(Args, 512));
    Console.Print('r_shadowMapSize ' + IntToStr(Map.ShadowMapSize) + ' (used by the next map loaded)');
  end else
  if Cmd = 'r_shadowlights' then
  begin
    { how many lights cast shadow volumes at once (CGE change A) }
    if Args <> '' then
      Map.ShadowLightsMax := Max(1, StrToIntDef(Args, 1));
    MainViewport.ShadowVolumesMaxLights := Map.ShadowLightsMax;
    Console.Print('r_shadowLights ' + IntToStr(Map.ShadowLightsMax));
  end else
  if Cmd = 'r_usescissor' then
  begin
    { limit each shadow light's passes to its screen rectangle, like
      Doom 3's r_useScissor (CGE change A follow-up) }
    if Args <> '' then
      InternalShadowVolumesLightScissor := StrToIntDef(Args, 1) <> 0
    else
      InternalShadowVolumesLightScissor := not InternalShadowVolumesLightScissor;
    Console.Print('r_useScissor ' + BoolToStr(InternalShadowVolumesLightScissor, '1', '0'));
  end else
  if Cmd = 'r_highdynamicrange' then
  begin
    { TCastleViewport.HighDynamicRange (CGE change I): light passes added
      in linear colors. Set by name: older CGE versions don't have it. }
    if IsPublishedProp(MainViewport, 'HighDynamicRange') then
    begin
      if Args <> '' then
        SetOrdProp(MainViewport, 'HighDynamicRange', Ord(StrToIntDef(Args, 1) <> 0))
      else
        SetOrdProp(MainViewport, 'HighDynamicRange', 1 - GetOrdProp(MainViewport, 'HighDynamicRange'));
      Console.Print('r_highDynamicRange ' + IntToStr(GetOrdProp(MainViewport, 'HighDynamicRange')));
    end else
      Console.Print('r_highDynamicRange: not supported by this CGE');
  end else
  if Cmd = 'r_taa' then
  begin
    { TCastleViewport.TemporalAntiAliasing (CGE change Q): each frame jittered
      and blended with the previous ones (like RBDOOM-3-BFG's TAA).
      Set by name: older CGE versions don't have it. }
    if IsPublishedProp(MainViewport, 'TemporalAntiAliasing') then
    begin
      if Args <> '' then
        SetOrdProp(MainViewport, 'TemporalAntiAliasing', Ord(StrToIntDef(Args, 1) <> 0))
      else
        SetOrdProp(MainViewport, 'TemporalAntiAliasing', 1 - GetOrdProp(MainViewport, 'TemporalAntiAliasing'));
      Console.Print('r_taa ' + IntToStr(GetOrdProp(MainViewport, 'TemporalAntiAliasing')));
      WritelnLog('GameViewPlay', 'Temporal anti-aliasing %s',
        [BoolToStr(GetOrdProp(MainViewport, 'TemporalAntiAliasing') <> 0, 'on', 'off')]);
    end else
    begin
      Console.Print('r_taa: not supported by this CGE');
      WritelnLog('GameViewPlay', 'Temporal anti-aliasing: not supported by this CGE (needs TCastleViewport.TemporalAntiAliasing, CGE change Q)');
    end;
  end else
  if Cmd = 'r_sharedlighteffects' then
  begin
    { lights of a kind share one Effect with per-light uniforms (CGE change
      K): fewer shader programs; 0 gives each light its own Effect }
    if Args <> '' then
      SharedLightEffects := StrToIntDef(Args, 1) <> 0
    else
      SharedLightEffects := not SharedLightEffects;
    Console.Print('r_sharedLightEffects ' + BoolToStr(SharedLightEffects, '1', '0') +
      BoolToStr(SharedLightEffectsAvailable, '', ' (not supported by this CGE)') + ', reloading the map');
    LoadLevel(MapName);
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
      Console.Print(Format('r_md5ShadowTris %d (bigger md5 meshes cast with joint boxes, unless closed and r_md5ShadowClosed)',
        [MaxShadowCastingTriangles]));
  end else
  if Cmd = 'r_prelightshadows' then
  begin
    if Args <> '' then
    begin
      Map.PrelightShadows := Args <> '0';
      Console.Print('r_prelightShadows ' + BoolToStr(Map.PrelightShadows, '1', '0') + ', reloading the map');
      LoadLevel(MapName);
    end else
      Console.Print('r_prelightShadows ' + BoolToStr(Map.PrelightShadows, '1', '0') +
        ' (lights also cast the shadow volumes precomputed in the .proc file)');
  end else
  if Cmd = 'r_md5shadowclosed' then
  begin
    if Args <> '' then
      ClosedMeshesCastShadows := Args <> '0';
    Console.Print('r_md5ShadowClosed ' + BoolToStr(ClosedMeshesCastShadows, '1', '0') +
      ' (closed md5 meshes cast with their triangles; r_md5ShadowTris reloads the map)');
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
  if Cmd = 'decal' then
  begin
    { decal <material> [size]: stick a decal where the view's center ray
      hits the world (roadmap item 3) }
    Words := Trim(Args).Split([' '], TStringSplitOptions.ExcludeEmpty);
    if Length(Words) = 0 then
      Console.Print('decal <material> [size]')
    else
    if FGame.WorldHit(Camera.Translation, Camera.Direction, 4096, HitDistance, HitNormal) then
    begin
      I := 16;
      if Length(Words) > 1 then
        I := StrToIntDef(Words[1], I);
      FGame.AddDecal(Words[0], CgeToD3(Camera.Translation + Camera.Direction * HitDistance),
        CgeToD3(HitNormal), I);
      Console.Print(Format('Decal %s, %d decals', [Words[0], FGame.Decals.Decals.Count]));
    end else
      Console.Print('decal: nothing hit');
  end else
  if Cmd = 'pick' then
  begin
    { what the view's center ray hits first (pickable, existing scenes,
      also ones hidden by portal visibility) }
    Hit := Map.World.WorldRay(Camera.Translation, Camera.Direction);
    try
      if (Hit = nil) or (Hit.Count = 0) then
        S := 'nothing'
      else
      begin
        S := Format('%s (visible %s) at %s, distance %.1f', [Hit[0].Item.Name,
          BoolToStr(Hit[0].Item.Visible, '1', '0'), CgeToD3(Hit[0].Point).ToString, Hit.Distance]);
        if Hit[0].Triangle <> nil then
          S := S + Format(', shape %s, geometry %s', [Hit[0].Triangle^.Shape.Node.X3DName,
            Hit[0].Triangle^.Shape.Geometry.X3DName]);
        for I := 1 to Hit.Count - 1 do
          S := S + ' < ' + Hit[I].Item.Name;
      end;
    finally FreeAndNil(Hit) end;
    Console.Print(S);
    WritelnLog('Pick', S);
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
  if Cmd = 'reverb' then
  begin
    S := ReverbStatus;
    Console.Print(S);
    WritelnLog('Reverb', S);
  end else
  if Cmd = 's_useeaxreverb' then
  begin
    if Args <> '' then
      FUseReverb := Args <> '0';
    Console.Print('s_useEAXReverb ' + BoolToStr(FUseReverb, '1', '0') + ' (reverb from efxs/<map>.efx)');
  end else
  if Cmd = 'soundinfo' then
  begin
    S := SoundInfo;
    Console.Print(S);
    WritelnLog('SoundInfo', S);
  end else
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
    { freeze script threads and the entities they move,
      and the map's time (light shaders, animated surfaces) }
    if Args <> '' then
      FGame.ScriptsPaused := StrToIntDef(Args, 1) <> 0
    else
      FGame.ScriptsPaused := not FGame.ScriptsPaused;
    Map.TimePaused := FGame.ScriptsPaused;
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
        BoolToStr(L.Node.IsOn, '', ' off'), BoolToStr(L.Node.ShadowVolumesMain, ' shadows', '')]);
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
  I: Integer;
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
  ShadowName := '';
  for I in Map.ShadowLights do
  begin
    if ShadowName <> '' then
      ShadowName := ShadowName + ' ';
    ShadowName := ShadowName + Map.Light(I).Entity.Name;
  end;
  if ShadowName = '' then
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
  FDemoGoCrouch := False;
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
      { GO:x y seconds run: with the run key held }
      if (Length(Parts) > 3) and SameText(Parts[3], 'run') then
        FDemoHeld := Concat(FDemoHeld, [keyShift]);
      if (Length(Parts) > 3) and SameText(Parts[3], 'crouch') then
        FDemoGoCrouch := True;
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
    Fire(True)
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

  WalkNavigation.Exists := not Console.IsOpen and not FGame.PlayerDead and not FInCinematic and not FPdaOpen;

  if (AutoTestPrefix = '') and not Console.IsOpen then
  begin
    Firing := (buttonLeft in Container.MousePressed) or Container.Pressed[keyCtrl];
    { a scripted weapon reads the held button (WEAPON_ATTACK) }
    FGame.Attack := Firing and not FGame.PlayerDead;
    if Firing then
    begin
      if FGame.PlayerDead then
      begin
        if FGame.DeadTime > 1 then
          LoadLevel(MapName);
      end else
        Fire(False);
    end;
  end;
  FGame.PlayerViewDir := Camera.Direction;
  FGame.PlayerJumping := WalkNavigation.IsJumping;
  FGame.PlayerFlying := FNoclip;
  { berserk runs faster (idPlayer::PowerUpModifier( SPEED )); running
    is as fast as the stamina lets it (idPlayer::AdjustSpeed) }
  WalkNavigation.MoveSpeed := FBaseMoveSpeed * FGame.SpeedModifier;
  FGame.PlayerRunning := WalkNavigation.Input_Run.IsPressed(Container);
  FGame.PlayerMoving := WalkNavigation.Input_Forward.IsPressed(Container) or
    WalkNavigation.Input_Backward.IsPressed(Container) or
    WalkNavigation.Input_LeftStrafe.IsPressed(Container) or
    WalkNavigation.Input_RightStrafe.IsPressed(Container);
  WalkNavigation.RunMultiplier := FGame.RunMultiplier;
  UpdateCrouch(SecondsPassed);
  { thrown up by a knockback: its own arc, no navigation gravity }
  WalkNavigation.Gravity := not FNoclip and not FGame.KnockbackAirborne;
  UpdateFallSpeed(SecondsPassed);
  ApplyKnockback(SecondsPassed);

  { during cinematics the player stays where the camera was }
  if FInCinematic then
    FGame.Update(SecondsPassed, FPlayerEye)
  else
    FGame.Update(SecondsPassed, Camera.Translation);
  UpdateCinematic;
  Map.UpdateVisibility(Camera);
  UpdateReverb;
  UpdateMuzzleFlash;

  Hud.Health := FGame.Health;
  Hud.Armor := FGame.Armor;
  Hud.Stamina := FGame.StaminaPercent;
  Hud.Dead := FGame.PlayerDead;
  UpdateDamageView;
  Hud.FlashlightOn := Flashlight.Exists;
  Hud.AmmoText := Format('%s    KILLS %d', [FGame.WeaponHudText, FGame.Kills]);

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
  if Event.IsKey(keyTab) then
  begin
    SetPdaOpen(not FPdaOpen);
    Exit(True);
  end;
  if FPdaOpen and (Event.IsKey('[') or Event.IsKey(']')) then
  begin
    if Event.IsKey('[') then
      Dec(FPdaIndex)
    else
      Inc(FPdaIndex);
    UpdatePdaText;
    Exit(True);
  end;
  if Event.IsKey(keyE) then
  begin
    FGame.Use(Camera.Translation, Camera.Direction);
    Exit(True);
  end;
  { weapons: 1..0 select slots 0..9 (Doom 3's _impulse0..9), the wheel
    cycles, R reloads }
  if (Event.EventType = itKey) and (Event.Key in [key0..key9]) then
  begin
    if Event.Key = key0 then
      FGame.SelectWeapon(9)
    else
      FGame.SelectWeapon(Ord(Event.Key) - Ord(key1));
    Exit(True);
  end;
  if Event.EventType = itMouseWheel then
  begin
    if Event.MouseWheel in [mwUp, mwLeft] then
      FGame.NextWeapon(-1)
    else
      FGame.NextWeapon(1);
    Exit(True);
  end;
  if Event.IsKey(keyR) then
  begin
    FGame.ReloadWeapon;
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
