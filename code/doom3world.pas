{ Doom 3 gameplay on top of TDoom3Map: doors that open when you come near
  (idDoor), func_rotating, speakers playing sound shaders, md5 creatures
  that chase and claw the player (a tiny idAI), the player's pistol, health,
  flashlight and death.

  Entity activation (idEntity::ActivateTargets / Event_Activate): triggers
  touched by the player (trigger_once / trigger_multiple / trigger_hurt,
  their volumes from the .cm models) and trigger_relay / trigger_count fire
  the entities named by their "target", "target1"... keys: lights switch
  on / off, speakers start / stop, hidden entities show, doors unlock or
  open, hidden monsters appear and dormant ones wake up, func_remove removes
  its targets. Firings wait in a queue (their "delay"), processed in Update,
  so chains of relays can't recurse.

  Scripts (Doom3Script): script/doom_main.script and maps/<map>.script are
  compiled when the map spawns; the map script's main, worldspawn's "call"
  keys and triggers' "call" keys start script threads. Their events reach
  the game through TD3GameScriptHost: sys.trigger, lights on / off and
  colors, doors, hide / show, entity keys, bind / unbind, and idMover's
  moves and rotations (TD3ScriptMover) that sys.waitFor waits for.

  Cinematics: activating an idCameraAnim entity plays its .md5camera
  (Doom3Camera) as the view, then fires its targets; idCameraView shows the
  view from an entity; trigger_fade and sys.fadeIn / fadeOut / fadeTo fade
  the screen; info_player_teleport moves the player. TViewPlay applies
  them (CinematicActive, CinematicView, FadeColor, TakeTeleport).

  Everything here is in CGE coordinates (Y up); Doom 3 units are kept
  (1 unit = 1 inch), so speeds and sizes are Doom 3's numbers. }
unit Doom3World;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleVectors, CastleTransform, CastleScene, CastleSoundEngine, CastleBoxes, CastleBehaviors,
  Doom3Level, Doom3MapFile, Doom3Decls, Doom3Script, Doom3Camera;

type
  TD3MessageEvent = procedure (const Msg: String) of object;

  TD3MoverKind = (mkDoor, mkRotating);
  TD3DoorState = (dsClosed, dsOpening, dsOpen, dsClosing);

  TD3Mover = class
    Brush: TD3BrushEntity;
    Kind: TD3MoverKind;
    State: TD3DoorState;
    { doors }
    ClosedPos, MoveDir: TVector3;
    Distance, Speed, Wait, Timer, Progress: Single;
    TriggerBox: TBox3D;
    Locked, NoTouch: Boolean;
    SoundOpen, SoundClose: TCastleSound;
    Sounds: TCastleSoundSource;
    { portals this door closes when it is shut }
    Portals: array of Integer;
    { "team": doors that open and close together (double doors) }
    Team: String;
    { rotating }
    RotAxis: TVector3;
    RotSpeed, Angle: Single;
    { func_rotating turning ("start_on", toggled by activation) }
    Running: Boolean;
    procedure Update(const SecondsPassed: Single);
    procedure Open;
    procedure Close;
  end;

  TD3MonsterState = (msIdle, msChase, msAttack, msDead);

  TD3Monster = class
    Model: TD3ModelEntity;
    State: TD3MonsterState;
    Health: Integer;
    Yaw: Single;
    AttackTimer, StateTime, PainTime: Single;
    Radius, Height: Single;
    { "trigger" "1": doesn't wake up on sight, only when triggered (no
      triggers yet) or hurt }
    Dormant: Boolean;
    function Position: TVector3;
    function Center: TVector3;
  end;

  TD3Speaker = class
    Entity: TD3MapEntity;
    Transform: TCastleTransform;
    Source: TCastleSoundSource;
    Sound: TCastleSound;
    Looping: Boolean;
    destructor Destroy; override;
  end;

  TD3TriggerKind = (tkOnce, tkMultiple, tkHurt);

  { A trigger volume touched by the player (idTrigger_Multiple,
    idTrigger_Hurt; trigger_once is a trigger_multiple firing once). }
  TD3Trigger = class
    Entity: TD3MapEntity;
    Kind: TD3TriggerKind;
    { Volume in CGE coordinates. }
    Box: TBox3D;
    { Seconds before firing the targets ("delay"), between firings ("wait",
      trigger_multiple) or damages (trigger_hurt). }
    Delay, Wait: Single;
    { Game time when it can fire again. }
    NextTime: Single;
    { "triggerFirst": touching does nothing until it was activated once. }
    WaitingForActivation: Boolean;
    { "noTouch": only activation fires it. }
    NoTouch: Boolean;
    { trigger_once already fired, or trigger_hurt switched off ("on" "0"). }
    Disabled: Boolean;
    { trigger_hurt damage per hit }
    Damage: Integer;
  end;

  { An entity bound to a mover ("bind"): it keeps its placement relative
    to the parent (idEntity::Bind). }
  TD3Binding = class
    Child, Parent: TCastleTransform;
    { Child's transformation relative to the parent's (set at bind time,
      changed by script moves of the child). }
    ChildInParent: TMatrix4;
    { Number of bound ancestors (parents are updated before children). }
    Depth: Integer;
  end;

  { An entity moved by script events (idMover's move, moveTo, rotateOnce,
    rotate...). Origin and Angles (pitch, yaw, roll) are Doom 3 ones,
    relative to the master when the entity is bound. }
  TD3ScriptMover = class
    Handle: Integer;
    Transform: TCastleTransform;
    Origin, Angles: TVector3;
    { idMover settings: "time" (seconds), "speed" (units per second, wins
      over time for moves when > 0), "accelTime", "decelTime" }
    MoveTime, MoveSpeed, AccelTime, DecelTime: Single;
    Moving: Boolean;
    MoveFrom, MoveTo: TVector3;
    MoveStart, MoveDuration: Single;
    { rotateOnce / rotateTo (to RotTo) or rotate (RotSpeed per second) }
    Rotating, RotContinuous: Boolean;
    RotFrom, RotTo, RotSpeed: TVector3;
    RotStart, RotDuration: Single;
    { sys.waitFor waits while a move or a single rotation goes on }
    function Busy: Boolean;
  end;

  { A light fading in or out (idLight::FadeIn / FadeOut). }
  TD3LightFade = record
    Light: Integer;
    From, Target, Start, Duration: Single;
  end;

  TD3PendingTargets = record
    Time: Single;
    { activate the targets of this entity }
    Entity: TD3MapEntity;
  end;

  TD3Game = class
  strict private
    FMap: TDoom3Map;
    FMovers: specialize TObjectList<TD3Mover>;
    FMonsters: specialize TObjectList<TD3Monster>;
    FSpeakers: specialize TObjectList<TD3Speaker>;
    FSounds: specialize TObjectDictionary<String, TCastleSound>;
    FTriggers: specialize TObjectList<TD3Trigger>;
    { map entities by lowercase name }
    FEntities: specialize TDictionary<String, TD3MapEntity>;
    FPending: specialize TList<TD3PendingTargets>;
    FBindings: specialize TObjectList<TD3Binding>;
    FBindingsSorted: Boolean;
    FScript: TD3ScriptVM;
    FScriptHost: TD3ScriptHost;
    { entity handles of scripts: index in FMap.MapFile.Entities + 1 }
    FHandles: specialize TDictionary<String, Integer>;
    FScriptMovers: specialize TObjectDictionary<Integer, TD3ScriptMover>;
    { cinematics: the playing camera anim (idCameraAnim) or camera view
      (idCameraView) }
    FCameraAnims: specialize TObjectDictionary<String, TD3CameraAnim>;
    FCameraEntity: TD3MapEntity;
    FCameraAnim: TD3CameraAnim;
    FCameraStart: Single;
    FCameraOffset: TVector3;
    FCameraCycles: Integer;
    { skipping a cinematic also skips the cameras started by it until then }
    FSkipUntil: Single;
    { screen fade (idPlayerView::Fade) }
    FFadeFrom, FFadeTo: TVector4;
    FFadeStart, FFadeTime: Single;
    FTeleportPending: Boolean;
    FTeleportPos: TVector3;
    FTeleportYaw: Single;
    FLightFades: specialize TList<TD3LightFade>;
    { script sounds: sound sources by entity handle, playing sounds by
      "handle:channel" }
    FSoundSources: specialize TDictionary<Integer, TCastleSoundSource>;
    FSoundTransforms: specialize TObjectList<TCastleTransform>;
    FScriptSounds: specialize TObjectDictionary<String, TCastlePlayingSoundSource>;
    { trigger_count activations so far, by lowercase name }
    FCounts: specialize TDictionary<String, Integer>;
    { classes whose activation is not supported yet (logged once) }
    FUnsupported: TStringList;
    FTime: Single;
    FOnMessage: TD3MessageEvent;
    FFireCooldown: Single;
    FDeadTime: Single;
    procedure Message(const S: String);
    function SoundFromShader(const ShaderName: String): TCastleSound;
    procedure SpawnMover(const B: TD3BrushEntity);
    procedure SpawnSpeaker(const E: TD3MapEntity);
    procedure SpawnTrigger(const E: TD3MapEntity);
    function SpawnMonster(const ME: TD3ModelEntity): TD3Monster;
    procedure FireTrigger(const T: TD3Trigger);
    procedure ActivateTargetsNow(const E: TD3MapEntity);
    procedure Unsupported(const What: String);
    { func_remove: remove (hide) an entity for good }
    procedure RemoveEntity(const E: TD3MapEntity);
    procedure UpdateTriggers(const Feet: TVector3);
    procedure SpawnBindings;
    procedure UpdateBindings;
    function TransformOf(const AName: String): TCastleTransform;
    function FindBinding(const Child: TCastleTransform): TD3Binding;
    procedure Bind(const Child, Parent: TCastleTransform);
    procedure Unbind(const Child: TCastleTransform);
    procedure StartScripts;
    procedure CallScript(const FunctionName: String; const Who: String);
    function ScriptMover(const Handle: Integer): TD3ScriptMover;
    procedure ApplyScriptMover(const M: TD3ScriptMover);
    procedure UpdateScriptMovers;
    function HandleEntity(const Handle: Integer): TD3MapEntity;
    procedure StartCamera(const E: TD3MapEntity);
    procedure StopCamera;
    procedure UpdateCamera;
    procedure StartFade(const Target: TVector4; const Seconds: Single);
    procedure FadeLight(const Light: Integer; const Target, Seconds: Single);
    procedure UpdateLightFades;
    function ScriptSoundSource(const Handle: Integer): TCastleSoundSource;
    function StartScriptSound(const Handle: Integer; const ShaderName: String;
      const Channel: Integer): Single;
    procedure StopScriptSound(const Handle, Channel: Integer);
    procedure ClearScriptSounds;
    function EntityHandle(const E: TD3MapEntity): Integer;
    { Doors of the same team as Door (Door itself too). }
    procedure OpenTeam(const Door: TD3Mover);
    procedure CloseTeam(const Door: TD3Mover);
    procedure LockTeam(const Door: TD3Mover; const Value: Boolean);
    procedure UpdateMonster(const M: TD3Monster; const SecondsPassed: Single;
      const PlayerPos: TVector3);
    procedure SetMonsterYaw(const M: TD3Monster; const YawDeg: Single);
    function CanSee(const A, B: TVector3): Boolean;
  public
    { Player state }
    Health, Armor: Integer;
    God, NoTarget: Boolean;
    Kills: Integer;
    { Seconds since the last pistol shot (for the muzzle flash) }
    SinceFire: Single;
    { Entities activated since the map was spawned (statistics, tests). }
    ActivationCount: Integer;
    { Script threads and the entities they move stand still (g_stopTime). }
    ScriptsPaused: Boolean;
    constructor Create(const AMap: TDoom3Map);
    destructor Destroy; override;
    { Create movers, monsters, speakers for the loaded map. }
    procedure Spawn;
    procedure Clear;
    { Per frame. PlayerEye is the camera position. }
    procedure Update(const SecondsPassed: Single; const PlayerEye: TVector3);
    { Fire the pistol. True if a shot was fired. }
    function Fire(const Origin, Dir: TVector3): Boolean;
    { Use: open a door in front of the player. }
    procedure Use(const Origin, Dir: TVector3);
    procedure DamagePlayer(const Amount: Integer);
    function PlayerDead: Boolean;
    { Fire the targets of E after Delay seconds (idEntity::ActivateTargets). }
    procedure ActivateTargets(const E: TD3MapEntity; const Delay: Single = 0);
    { Activate one entity (its Event_Activate), as if a trigger targeted it. }
    procedure Activate(const E: TD3MapEntity);
    { The map entity with this name, nil if none. }
    function FindEntity(const AName: String): TD3MapEntity;
    { For TD3GameScriptHost: scripts' entity handles and events. }
    function ScriptFindEntity(const AName: String): Integer;
    function ScriptEntityName(const Handle: Integer): String;
    function ScriptEntityBusy(const Handle: Integer): Boolean;
    function ScriptEvent(const Target: Integer; const Event: TD3ScriptEvent;
      const Args: TD3ValueArray; var EventResult: TD3Value): Boolean;
    { One line: script threads, moving entities. }
    function ScriptStatus: String;
    { A cinematic camera (idCameraAnim, idCameraView) sets the view. }
    function CinematicActive: Boolean;
    { The cinematic camera's view in CGE coordinates, its horizontal field
      of view in degrees. }
    procedure CinematicView(out Position, Direction, Up: TVector3; out FovDeg: Single);
    { Stop the cinematic camera (its targets fire), like Escape in Doom 3. }
    procedure SkipCinematic;
    { Color over the screen (alpha 0: nothing), from trigger_fade and the
      scripts' fades. }
    function FadeColor: TVector4;
    { info_player_teleport asked to move the player: where (feet). }
    function TakeTeleport(out FeetPos: TVector3; out YawDeg: Single): Boolean;
    { The name of the playing cinematic camera entity, '' if none. }
    function CinematicName: String;
    { The compiled scripts of the map (nil: none, or they don't compile). }
    property Script: TD3ScriptVM read FScript;
    { Seconds the player has been dead. }
    property DeadTime: Single read FDeadTime;
    property Movers: specialize TObjectList<TD3Mover> read FMovers;
    property Monsters: specialize TObjectList<TD3Monster> read FMonsters;
    property Triggers: specialize TObjectList<TD3Trigger> read FTriggers;
    { Game time (seconds since Spawn). }
    property Time: Single read FTime;
    property Map: TDoom3Map read FMap;
    property OnMessage: TD3MessageEvent read FOnMessage write FOnMessage;
  end;

const
  { Doom 3 player: eye at 68 above the feet, bounding box 32 wide }
  PlayerEyeHeight = 68;
  PlayerRadius = 16;

implementation

uses
  Math,
  CastleLog, CastleUtils,
  Generics.Defaults,
  Doom3Files, Doom3Md5, Doom3Collision;

const
  MonsterWalkSpeed = 90;
  MonsterSightRange = 1200;
  MonsterMeleeRange = 64;
  MonsterAttackDelay = 1.1;
  MonsterDamage = 10;
  PistolDamage = 14;
  PistolDelay = 0.35;

{ TD3Mover }

procedure TD3Mover.Open;
begin
  if Locked or (Kind <> mkDoor) then
    Exit;
  if State in [dsClosed, dsClosing] then
  begin
    State := dsOpening;
    if (Sounds <> nil) and (SoundOpen <> nil) then
      Sounds.Play(SoundOpen);
  end;
  Timer := 0;
end;

procedure TD3Mover.Close;
begin
  if State in [dsOpen, dsOpening] then
  begin
    State := dsClosing;
    if (Sounds <> nil) and (SoundClose <> nil) then
      Sounds.Play(SoundClose);
  end;
end;

procedure TD3Mover.Update(const SecondsPassed: Single);
var
  Step: Single;
begin
  case Kind of
    mkRotating:
      if Running then
      begin
        Angle := Angle + RotSpeed * SecondsPassed;
        Brush.Scene.Rotation := Vector4(RotAxis, DegToRad(Angle));
      end;
    mkDoor:
      begin
        if Distance <= 0 then
          Exit;
        Step := Speed * SecondsPassed / Distance;
        case State of
          dsOpening:
            begin
              Progress := Min(1, Progress + Step);
              if Progress >= 1 then
              begin
                State := dsOpen;
                Timer := 0;
              end;
            end;
          dsOpen:
            if Wait >= 0 then
            begin
              Timer := Timer + SecondsPassed;
              if Timer >= Wait then
                Close;
            end;
          dsClosing:
            begin
              Progress := Max(0, Progress - Step);
              if Progress <= 0 then
                State := dsClosed;
            end;
          else ;
        end;
        Brush.Scene.Translation := ClosedPos + MoveDir * (Distance * Progress);
      end;
  end;
end;

{ TD3Monster }

function TD3Monster.Position: TVector3;
begin
  Result := Model.Holder.Translation;
end;

function TD3Monster.Center: TVector3;
begin
  Result := Model.Holder.Translation + Vector3(0, Height / 2, 0);
end;

{ TD3Speaker }

destructor TD3Speaker.Destroy;
begin
  { the transform owns the sound source behavior }
  FreeAndNil(Transform);
  inherited Destroy;
end;

{ TD3Game }

type
  { Scripts' view of the game: forwards to TD3Game. }
  TD3GameScriptHost = class(TD3ScriptHost)
    Game: TD3Game;
    constructor Create(const AGame: TD3Game);
    function FindEntity(const AName: String): Integer; override;
    function EntityName(const E: Integer): String; override;
    function EntityBusy(const E: Integer): Boolean; override;
    function CallEvent(const Thread: TD3ScriptThread; const Target: Integer;
      const Event: TD3ScriptEvent; const Args: TD3ValueArray;
      var EventResult: TD3Value): Boolean; override;
  end;

constructor TD3GameScriptHost.Create(const AGame: TD3Game);
begin
  inherited Create;
  Game := AGame;
end;

function TD3GameScriptHost.FindEntity(const AName: String): Integer;
begin
  Result := Game.ScriptFindEntity(AName);
end;

function TD3GameScriptHost.EntityName(const E: Integer): String;
begin
  Result := Game.ScriptEntityName(E);
end;

function TD3GameScriptHost.EntityBusy(const E: Integer): Boolean;
begin
  Result := Game.ScriptEntityBusy(E);
end;

function TD3GameScriptHost.CallEvent(const Thread: TD3ScriptThread; const Target: Integer;
  const Event: TD3ScriptEvent; const Args: TD3ValueArray; var EventResult: TD3Value): Boolean;
begin
  Result := Game.ScriptEvent(Target, Event, Args, EventResult);
end;

constructor TD3Game.Create(const AMap: TDoom3Map);
begin
  inherited Create;
  FMap := AMap;
  FMovers := specialize TObjectList<TD3Mover>.Create(True);
  FMonsters := specialize TObjectList<TD3Monster>.Create(True);
  FSpeakers := specialize TObjectList<TD3Speaker>.Create(True);
  FSounds := specialize TObjectDictionary<String, TCastleSound>.Create([doOwnsValues]);
  FTriggers := specialize TObjectList<TD3Trigger>.Create(True);
  FEntities := specialize TDictionary<String, TD3MapEntity>.Create;
  FPending := specialize TList<TD3PendingTargets>.Create;
  FBindings := specialize TObjectList<TD3Binding>.Create(True);
  FHandles := specialize TDictionary<String, Integer>.Create;
  FScriptMovers := specialize TObjectDictionary<Integer, TD3ScriptMover>.Create([doOwnsValues]);
  FScriptHost := TD3GameScriptHost.Create(Self);
  FCameraAnims := specialize TObjectDictionary<String, TD3CameraAnim>.Create([doOwnsValues]);
  FLightFades := specialize TList<TD3LightFade>.Create;
  FSoundSources := specialize TDictionary<Integer, TCastleSoundSource>.Create;
  FSoundTransforms := specialize TObjectList<TCastleTransform>.Create(True);
  FScriptSounds := specialize TObjectDictionary<String, TCastlePlayingSoundSource>.Create([doOwnsValues]);
  FCounts := specialize TDictionary<String, Integer>.Create;
  FUnsupported := TStringList.Create;
  FUnsupported.Sorted := True;
  Health := 100;
end;

destructor TD3Game.Destroy;
begin
  Clear;
  FMovers.Free;
  FMonsters.Free;
  FSpeakers.Free;
  FSounds.Free;
  FTriggers.Free;
  FEntities.Free;
  FPending.Free;
  FBindings.Free;
  FCounts.Free;
  FUnsupported.Free;
  FreeAndNil(FScript);
  FScriptHost.Free;
  FHandles.Free;
  FScriptMovers.Free;
  FCameraAnims.Free;
  FLightFades.Free;
  FScriptSounds.Free;
  FSoundSources.Free;
  FSoundTransforms.Free;
  inherited Destroy;
end;

procedure TD3Game.Message(const S: String);
begin
  WritelnLog('Doom3World', 'Message: ' + S);
  if Assigned(FOnMessage) then
    FOnMessage(S);
end;

procedure TD3Game.Clear;
begin
  FMovers.Clear;
  FMonsters.Clear;
  FSpeakers.Clear;
  FTriggers.Clear;
  FEntities.Clear;
  FPending.Clear;
  FBindings.Clear;
  FCounts.Clear;
  FUnsupported.Clear;
  FreeAndNil(FScript);
  FHandles.Clear;
  FScriptMovers.Clear;
  FCameraEntity := nil;
  FCameraAnim := nil;
  FSkipUntil := 0;
  FFadeFrom := Vector4(0, 0, 0, 0);
  FFadeTo := Vector4(0, 0, 0, 0);
  FFadeTime := 0;
  FTeleportPending := False;
  FLightFades.Clear;
  ClearScriptSounds;
  FTime := 0;
  ActivationCount := 0;
end;

function TD3Game.SoundFromShader(const ShaderName: String): TCastleSound;
const
  { Doom 3 sound shader distances are in meters, the world in inches }
  MetersToUnits = 39.37;
var
  Shader: TD3SoundShader;
begin
  Result := nil;
  if ShaderName = '' then
    Exit;
  if FSounds.TryGetValue(LowerCase(ShaderName), Result) then
    Exit;
  Shader := Decls.SoundShader(ShaderName);
  if (Shader <> nil) and (Shader.Files.Count > 0) and D3Fs.FileExists(Shader.Files[0]) then
  begin
    Result := TCastleSound.Create(nil);
    Result.Url := D3FsUrl(Shader.Files[0]);
    Result.ReferenceDistance := Max(1, Shader.MinDistance) * MetersToUnits;
    Result.MaxDistance := Max(Shader.MinDistance + 1, Shader.MaxDistance) * MetersToUnits;
    { volume is in dB }
    Result.Volume := Min(1, Power(10, Shader.Volume / 20));
  end else
    WritelnLog('Doom3World', 'Sound shader "%s" not found', [ShaderName]);
  FSounds.Add(LowerCase(ShaderName), Result);
end;

procedure TD3Game.SpawnMover(const B: TD3BrushEntity);
var
  E: TD3MapEntity;
  M: TD3Mover;
  Cls: String;
  MoveAngle: Single;
  Dir, Size: TVector3;
  TriggerSize: Single;
  Box: TBox3D;
begin
  E := B.Entity;
  Cls := LowerCase(E.ClassName_);
  if Cls = 'func_door' then
  begin
    M := TD3Mover.Create;
    M.Brush := B;
    M.Kind := mkDoor;
    M.ClosedPos := B.Scene.Translation;
    MoveAngle := E.FloatValue('movedir', E.FloatValue('angle', 0));
    if Abs(MoveAngle + 1) < 0.01 then
      Dir := Vector3(0, 0, 1) { up }
    else
    if Abs(MoveAngle + 2) < 0.01 then
      Dir := Vector3(0, 0, -1) { down }
    else
      Dir := Vector3(Cos(DegToRad(MoveAngle)), Sin(DegToRad(MoveAngle)), 0);
    { like idDoor: the size of the door's world bounds along the move
      direction (doors are often rotated: "rotation" on 137 of the demo's
      155 doors), minus "lip" }
    Box := B.Scene.BoundingBox;
    Size := CgeToD3(Box.Size);
    Size := Vector3(Abs(Size.X), Abs(Size.Y), Abs(Size.Z));
    M.Distance := Abs(Dir.X) * Size.X + Abs(Dir.Y) * Size.Y + Abs(Dir.Z) * Size.Z -
      E.FloatValue('lip', 8);
    M.MoveDir := D3ToCge(Dir);
    { defaults of Doom 3's func_door entityDef (used when the data has none) }
    M.Speed := E.FloatValue('speed', 100);
    if E.HasKey('time') and (E.FloatValue('time') > 0) then
      M.Speed := Max(1, M.Distance) / E.FloatValue('time');
    M.Wait := E.FloatValue('wait', 3);
    M.Locked := E.BoolValue('locked');
    M.NoTouch := E.BoolValue('no_touch');
    M.Team := LowerCase(E.Value('team'));
    { Doom 3 doors open when you enter a trigger around them }
    TriggerSize := E.FloatValue('triggersize', 60);
    M.TriggerBox := Box.Grow(TriggerSize);
    M.SoundOpen := SoundFromShader(E.Value('snd_open'));
    M.SoundClose := SoundFromShader(E.Value('snd_close'));
    if (M.SoundOpen <> nil) or (M.SoundClose <> nil) then
    begin
      M.Sounds := TCastleSoundSource.Create(B.Scene);
      M.Sounds.Spatial := True;
      B.Scene.AddBehavior(M.Sounds);
    end;
    if FMap.Portals <> nil then
      M.Portals := FMap.Portals.PortalsInBox(B.Scene.BoundingBox.Grow(16));
    FMovers.Add(M);
  end else
  if (Cls = 'func_rotating') or (Cls = 'func_fx_rotating') then
  begin
    M := TD3Mover.Create;
    M.Brush := B;
    M.Kind := mkRotating;
    M.RotSpeed := E.FloatValue('speed', 100);
    if E.BoolValue('x_axis') then
      M.RotAxis := D3ToCge(Vector3(1, 0, 0))
    else
    if E.BoolValue('y_axis') then
      M.RotAxis := D3ToCge(Vector3(0, 1, 0))
    else
      M.RotAxis := D3ToCge(Vector3(0, 0, 1));
    M.Angle := E.Angle;
    M.Running := E.BoolValue('start_on', True);
    FMovers.Add(M);
  end;
end;

procedure TD3Game.SpawnSpeaker(const E: TD3MapEntity);
var
  S: TD3Speaker;
  Snd: TCastleSound;
  Shader: TD3SoundShader;
begin
  Snd := SoundFromShader(E.Value('s_shader'));
  if Snd = nil then
    Exit;
  S := TD3Speaker.Create;
  S.Entity := E;
  S.Sound := Snd;
  S.Transform := TCastleTransform.Create(nil);
  S.Transform.Name := 'Speaker_' + IntToStr(FSpeakers.Count);
  S.Transform.Translation := D3ToCge(E.Origin);
  S.Source := TCastleSoundSource.Create(S.Transform);
  S.Source.Spatial := not E.BoolValue('s_global');
  S.Transform.AddBehavior(S.Source);
  FMap.Add(S.Transform);
  Shader := Decls.SoundShader(E.Value('s_shader'));
  S.Looping := (Shader <> nil) and (Shader.Looping or E.BoolValue('s_looping'));
  if S.Looping then
  begin
    if not E.BoolValue('s_waitfortrigger') then
      S.Source.Sound := Snd;
  end else
  if not E.BoolValue('s_waitfortrigger') then
    S.Source.Play(Snd);
  FSpeakers.Add(S);
end;

procedure TD3Game.SetMonsterYaw(const M: TD3Monster; const YawDeg: Single);
begin
  M.Yaw := YawDeg;
  SetD3Rotation(M.Model.Holder, YawMatrix(YawDeg));
end;

procedure TD3Game.Spawn;
var
  B: TD3BrushEntity;
  ME: TD3ModelEntity;
  E: TD3MapEntity;
  Hidden, Dormant: Integer;
  Mon: TD3Monster;
  Cls: String;
begin
  Clear;
  FDeadTime := 0;
  for B in FMap.Brushes do
    SpawnMover(B);
  for ME in FMap.Models do
  begin
    Cls := LowerCase(ME.Entity.ClassName_);
    if (Copy(Cls, 1, 8) <> 'monster_') or ME.Hidden then
      Continue;
    SpawnMonster(ME);
  end;
  if FMap.MapFile <> nil then
    for E in FMap.MapFile.Entities do
    begin
      if E.Name <> '' then
        FEntities.AddOrSetValue(LowerCase(E.Name), E);
      Cls := LowerCase(E.ClassName_);
      if Cls = 'speaker' then
        SpawnSpeaker(E)
      else
      if (Cls = 'trigger_once') or (Cls = 'trigger_multiple') or (Cls = 'trigger_hurt') then
        SpawnTrigger(E);
    end;
  SpawnBindings;
  StartScripts;
  Hidden := 0;
  Dormant := 0;
  for ME in FMap.Models do
    if ME.Hidden and (Copy(LowerCase(ME.Entity.ClassName_), 1, 8) = 'monster_') then
      Inc(Hidden);
  for Mon in FMonsters do
    if Mon.Dormant then
      Inc(Dormant);
  WritelnLog('Doom3World', 'Spawned %d movers, %d monsters (%d dormant until triggered, %d hidden), %d speakers, %d triggers, %d bound entities',
    [FMovers.Count, FMonsters.Count, Dormant, Hidden, FSpeakers.Count, FTriggers.Count, FBindings.Count]);
end;

function TD3Game.SpawnMonster(const ME: TD3ModelEntity): TD3Monster;
begin
  Result := TD3Monster.Create;
  Result.Model := ME;
  Result.Health := 50;
  if ME.EntityDef <> nil then
    Result.Health := StrToIntDef(ME.EntityDef.Values['health'], 50);
  Result.Health := ME.Entity.IntValue('health', Result.Health);
  Result.Radius := 20;
  Result.Height := 72;
  Result.Yaw := ME.Entity.Angle;
  Result.Dormant := ME.Entity.BoolValue('trigger');
  if ME.Entity.Value('anim') <> '' then
    ME.Instance.PlayAnim(ME.Entity.Value('anim'));
  FMonsters.Add(Result);
end;

procedure TD3Game.SpawnTrigger(const E: TD3MapEntity);
var
  T: TD3Trigger;
  Model: TD3CollisionModel;
  Rot: TMatrix3;
  V, W, BoxMin, BoxMax: TVector3;
  I, J: Integer;
  DamageDef: TStringList;
begin
  { the volume: the entity's collision model (brush triggers), placed at
    its origin and rotated }
  if FMap.Collision = nil then
    Exit;
  Model := FMap.Collision.FindModel(E.Value('model', E.Name));
  if (Model = nil) or (Length(Model.Vertices) = 0) then
    Exit;
  Rot := E.Rotation;
  BoxMin := Vector3(MaxSingle, MaxSingle, MaxSingle);
  BoxMax := -BoxMin;
  for I := 0 to High(Model.Vertices) do
  begin
    V := Model.Vertices[I];
    { rows of Rot are the rotated axes }
    W := E.Origin + Vector3(
      V.X * Rot.Data[0, 0] + V.Y * Rot.Data[1, 0] + V.Z * Rot.Data[2, 0],
      V.X * Rot.Data[0, 1] + V.Y * Rot.Data[1, 1] + V.Z * Rot.Data[2, 1],
      V.X * Rot.Data[0, 2] + V.Y * Rot.Data[1, 2] + V.Z * Rot.Data[2, 2]);
    W := D3ToCge(W);
    for J := 0 to 2 do
    begin
      BoxMin.Data[J] := Min(BoxMin.Data[J], W.Data[J]);
      BoxMax.Data[J] := Max(BoxMax.Data[J], W.Data[J]);
    end;
  end;

  T := TD3Trigger.Create;
  T.Entity := E;
  T.Box := Box3D(BoxMin, BoxMax);
  if SameText(E.ClassName_, 'trigger_once') then
    T.Kind := tkOnce
  else
  if SameText(E.ClassName_, 'trigger_hurt') then
    T.Kind := tkHurt
  else
    T.Kind := tkMultiple;
  if T.Kind = tkHurt then
  begin
    { idTrigger_Hurt: damage every "delay" seconds while touched }
    T.Wait := E.FloatValue('delay', 1);
    T.Disabled := not E.BoolValue('on', True);
    T.Damage := 10;
    DamageDef := Decls.EntityDef(E.Value('def_damage', 'damage_painTrigger'));
    if DamageDef <> nil then
      T.Damage := StrToIntDef(DamageDef.Values['damage'], T.Damage);
  end else
  begin
    T.Delay := E.FloatValue('delay', 0);
    T.Wait := E.FloatValue('wait', 0.5);
  end;
  T.WaitingForActivation := E.BoolValue('triggerFirst');
  T.NoTouch := E.BoolValue('noTouch');
  FTriggers.Add(T);
end;

function TD3Game.FindEntity(const AName: String): TD3MapEntity;
begin
  if not FEntities.TryGetValue(LowerCase(AName), Result) then
    Result := nil;
end;

procedure TD3Game.Unsupported(const What: String);
begin
  if FUnsupported.IndexOf(What) < 0 then
  begin
    FUnsupported.Add(What);
    WritelnLog('Doom3World', 'Not supported yet: %s', [What]);
  end;
end;

procedure TD3Game.ActivateTargets(const E: TD3MapEntity; const Delay: Single);
var
  P: TD3PendingTargets;
begin
  P.Time := FTime + Max(0, Delay);
  P.Entity := E;
  FPending.Add(P);
end;

procedure TD3Game.ActivateTargetsNow(const E: TD3MapEntity);
var
  I: Integer;
  Key: String;
  Target: TD3MapEntity;
begin
  { idTrigger::CallScript: the "call" function, in a new script thread }
  if E.HasKey('call') then
    CallScript(E.Value('call'), E.Name);
  for I := 0 to E.Pairs.Count - 1 do
  begin
    Key := LowerCase(E.Pairs.Names[I]);
    { "target", "target1", "target2"... (not "targetname" etc.) }
    if (Copy(Key, 1, 6) <> 'target') or
       ((Length(Key) > 6) and not CharInSet(Key[7], ['0'..'9'])) then
      Continue;
    Target := FindEntity(E.Pairs.ValueFromIndex[I]);
    if Target <> nil then
      Activate(Target);
  end;
end;

procedure TD3Game.FireTrigger(const T: TD3Trigger);
begin
  if T.Disabled then
    Exit;
  if T.Kind = tkOnce then
    T.Disabled := True;
  T.NextTime := FTime + T.Wait;
  WritelnLog('Doom3World', 'Trigger %s fired', [T.Entity.Name]);
  ActivateTargets(T.Entity, T.Delay);
end;

procedure TD3Game.RemoveEntity(const E: TD3MapEntity);
var
  I: Integer;
  B: TD3BrushEntity;
  ME: TD3ModelEntity;
  Mon: TD3Monster;
  S: TD3Speaker;
begin
  I := FMap.FindLight(E.Name);
  if I >= 0 then
    FMap.SetLightOn(I, False);
  B := FMap.FindBrush(E.Name);
  if B <> nil then
    B.SetHidden(True);
  ME := FMap.FindModelEntity(E.Name);
  if ME <> nil then
  begin
    ME.Hidden := True;
    ME.Holder.Exists := False;
    for Mon in FMonsters do
      if Mon.Model = ME then
      begin
        Mon.State := msDead;
        Mon.StateTime := 1000;
      end;
  end;
  for S in FSpeakers do
    if S.Entity = E then
    begin
      S.Source.Sound := nil;
    end;
end;

procedure TD3Game.Activate(const E: TD3MapEntity);
var
  Cls: String;
  I, Count: Integer;
  Trig: TD3Trigger;
  Mover: TD3Mover;
  B: TD3BrushEntity;
  ME: TD3ModelEntity;
  Mon: TD3Monster;
  S: TD3Speaker;
  Handled: Boolean;
  SpawnClass: String;
begin
  Inc(ActivationCount);
  Cls := LowerCase(E.ClassName_);
  Handled := False;

  if Cls = 'light' then
  begin
    { idLight::Event_ToggleOnOff }
    I := FMap.FindLight(E.Name);
    if I >= 0 then
    begin
      FMap.SetLightOn(I, not FMap.Light(I).StartOn);
      WritelnLog('Doom3World', 'Light %s %s', [E.Name, BoolToStr(FMap.Light(I).StartOn, 'on', 'off')]);
    end;
    Exit;
  end;

  { by the entityDef's game class }
  SpawnClass := E.Value('spawnclass');
  if (SpawnClass = 'idCameraAnim') or (SpawnClass = 'idCameraView') then
  begin
    { start, or stop when it plays (idCameraAnim::Event_Activate) }
    if FCameraEntity = E then
      StopCamera
    else
      StartCamera(E);
    Exit;
  end;
  if SpawnClass = 'idTrigger_Fade' then
  begin
    StartFade(E.Vector4Value('fadeColor', Vector4(0, 0, 0, 1)), E.FloatValue('fadeTime', 1));
    Exit;
  end;
  if SpawnClass = 'idPlayerStart' then
  begin
    { idPlayerStart::Event_TeleportPlayer }
    FTeleportPending := True;
    FTeleportPos := D3ToCge(E.Origin);
    FTeleportYaw := E.Angle;
    WritelnLog('Doom3World', 'Teleport to %s', [E.Name]);
    Exit;
  end;

  if Cls = 'trigger_relay' then
  begin
    ActivateTargets(E, E.FloatValue('delay', 0));
    Exit;
  end;

  if Cls = 'trigger_count' then
  begin
    { fires its targets every "count" activations }
    if not FCounts.TryGetValue(LowerCase(E.Name), Count) then
      Count := 0;
    Inc(Count);
    if Count >= Max(1, E.IntValue('count', 1)) then
    begin
      Count := 0;
      ActivateTargets(E, E.FloatValue('delay', 0));
    end;
    FCounts.AddOrSetValue(LowerCase(E.Name), Count);
    Exit;
  end;

  if (Cls = 'trigger_once') or (Cls = 'trigger_multiple') or (Cls = 'trigger_hurt') then
  begin
    for Trig in FTriggers do
      if Trig.Entity = E then
      begin
        if Trig.Kind = tkHurt then
          Trig.Disabled := not Trig.Disabled { switched on / off }
        else
        if Trig.WaitingForActivation then
          Trig.WaitingForActivation := False { now it can be touched }
        else
          FireTrigger(Trig);
        Exit;
      end;
    { a trigger without a volume still relays }
    ActivateTargets(E, E.FloatValue('delay', 0));
    Exit;
  end;

  if Cls = 'func_remove' then
  begin
    { removes its targets }
    for I := 0 to E.Pairs.Count - 1 do
      if Copy(LowerCase(E.Pairs.Names[I]), 1, 6) = 'target' then
        if FindEntity(E.Pairs.ValueFromIndex[I]) <> nil then
          RemoveEntity(FindEntity(E.Pairs.ValueFromIndex[I]));
    Exit;
  end;

  if (Cls = 'target_null') or (Copy(Cls, 1, 5) = 'path_') then
    Exit;

  { a speaker whose sound didn't load: nothing to start or stop }
  Handled := Cls = 'speaker';

  for S in FSpeakers do
    if S.Entity = E then
    begin
      { idSound::Event_Trigger: start / stop }
      if S.Looping then
      begin
        if S.Source.Sound <> nil then
          S.Source.Sound := nil
        else
          S.Source.Sound := S.Sound;
      end else
        S.Source.Play(S.Sound);
      Exit;
    end;

  if Cls = 'target_lock' then
  begin
    { idTarget_LockDoor: "locked" 1 locks its target doors, 0 unlocks }
    for I := 0 to E.Pairs.Count - 1 do
      if Copy(LowerCase(E.Pairs.Names[I]), 1, 6) = 'target' then
        for Mover in FMovers do
          if (Mover.Kind = mkDoor) and
             SameText(Mover.Brush.Entity.Name, E.Pairs.ValueFromIndex[I]) then
            LockTeam(Mover, E.IntValue('locked', 1) <> 0);
    Exit;
  end;

  for Mover in FMovers do
    if Mover.Brush.Entity = E then
    begin
      if Mover.Kind = mkDoor then
      begin
        { idDoor::Event_Activate: unlock, else open / close (the team) }
        if Mover.Locked then
          LockTeam(Mover, False)
        else
        if Mover.State in [dsClosed, dsClosing] then
          OpenTeam(Mover)
        else
          CloseTeam(Mover);
      end else
        { idRotater: start / stop }
        Mover.Running := not Mover.Running;
      Exit;
    end;

  ME := FMap.FindModelEntity(E.Name);
  if (ME <> nil) and (Copy(Cls, 1, 8) = 'monster_') then
  begin
    if ME.Hidden then
    begin
      { a hidden monster appears (and is awake) }
      ME.Hidden := False;
      ME.Holder.Exists := True;
      Mon := SpawnMonster(ME);
      Mon.Dormant := False;
    end else
      for Mon in FMonsters do
        if Mon.Model = ME then
          Mon.Dormant := False;
    WritelnLog('Doom3World', 'Monster %s activated', [E.Name]);
    Exit;
  end;

  { func_static, func_animate...: "hide" entities toggle (idStaticEntity) }
  if E.HasKey('hide') then
  begin
    B := FMap.FindBrush(E.Name);
    if B <> nil then
    begin
      B.SetHidden(not B.Hidden);
      Handled := True;
    end;
    if ME <> nil then
    begin
      ME.Hidden := not ME.Hidden;
      ME.Holder.Exists := not ME.Hidden;
      Handled := True;
    end;
  end;
  { func_static without "hide": idStaticEntity only toggles its "active"
    state (for its materials' shader parameters), nothing visible here }
  if Cls = 'func_static' then
    Handled := True;
  if not Handled then
    Unsupported('activating ' + Cls);
end;

procedure TD3Game.UpdateTriggers(const Feet: TVector3);
var
  PlayerBox: TBox3D;
  T: TD3Trigger;
  Steps: Integer;
  P: TD3PendingTargets;
  I: Integer;
begin
  { touches }
  if not PlayerDead then
  begin
    PlayerBox := Box3D(
      Feet - Vector3(PlayerRadius, 0, PlayerRadius),
      Feet + Vector3(PlayerRadius, PlayerEyeHeight + 6, PlayerRadius));
    for T in FTriggers do
      if (not T.Disabled) and (not T.NoTouch) and (not T.WaitingForActivation) and
         (FTime >= T.NextTime) and T.Box.Collision(PlayerBox) then
      begin
        if T.Kind = tkHurt then
        begin
          T.NextTime := FTime + T.Wait;
          DamagePlayer(T.Damage);
        end else
          FireTrigger(T);
      end;
  end;

  { delayed target firings; a bounded number per frame, so a loop of relays
    can't hang the game }
  Steps := 0;
  I := 0;
  while (I < FPending.Count) and (Steps < 1000) do
  begin
    if FPending[I].Time <= FTime then
    begin
      P := FPending[I];
      FPending.Delete(I);
      Inc(Steps);
      ActivateTargetsNow(P.Entity);
      I := 0; // activations may have added (or removed) items
    end else
      Inc(I);
  end;
end;

function TD3Game.CanSee(const A, B: TVector3): Boolean;
begin
  Result := not FMap.World.WorldSegmentCollision(A, B);
end;

procedure TD3Game.UpdateMonster(const M: TD3Monster; const SecondsPassed: Single;
  const PlayerPos: TVector3);
var
  ToPlayer, Step, NewPos, Eye, FloorStart: TVector3;
  Dist, FloorDist: Single;
  Hit: TCastleTransform;
begin
  M.StateTime := M.StateTime + SecondsPassed;
  if M.State = msDead then
  begin
    { sink into the floor, then disappear }
    if M.StateTime > 1.5 then
      M.Model.Holder.Translation := M.Model.Holder.Translation - Vector3(0, 30 * SecondsPassed, 0);
    if M.StateTime > 4 then
      M.Model.Holder.Exists := False;
    Exit;
  end;
  if M.PainTime > 0 then
    M.PainTime := M.PainTime - SecondsPassed;

  Eye := M.Position + Vector3(0, M.Height * 0.8, 0);
  ToPlayer := PlayerPos - M.Position;
  ToPlayer.Y := 0;
  Dist := ToPlayer.Length;

  case M.State of
    msIdle:
      if (not M.Dormant) and (not NoTarget) and not PlayerDead and (Dist < MonsterSightRange) and
         CanSee(Eye, PlayerPos + Vector3(0, PlayerEyeHeight, 0)) then
      begin
        M.State := msChase;
        M.StateTime := 0;
        M.Model.Instance.PlayAnim('walk');
      end;
    msChase:
      begin
        if NoTarget or PlayerDead then
        begin
          M.State := msIdle;
          M.Model.Instance.PlayAnim('idle');
          Exit;
        end;
        if Dist > 0.1 then
          SetMonsterYaw(M, RadToDeg(ArcTan2(-ToPlayer.Z, ToPlayer.X)));
        if Dist <= MonsterMeleeRange then
        begin
          M.State := msAttack;
          M.StateTime := 0;
          M.Model.Instance.PlayAnim('idle');
          Exit;
        end;
        Step := ToPlayer.Normalize * (MonsterWalkSpeed * SecondsPassed);
        NewPos := M.Position + Step;
        { blocked by a wall or a closed door? try sliding along one axis }
        if FMap.World.WorldSegmentCollision(M.Center, NewPos + Vector3(0, M.Height / 2, 0) +
          Step.Normalize * M.Radius) then
        begin
          NewPos := M.Position + Vector3(Step.X, 0, 0);
          if FMap.World.WorldSegmentCollision(M.Center, NewPos + Vector3(0, M.Height / 2, 0) +
            Vector3(Sign(Step.X) * M.Radius, 0, 0)) then
          begin
            NewPos := M.Position + Vector3(0, 0, Step.Z);
            if FMap.World.WorldSegmentCollision(M.Center, NewPos + Vector3(0, M.Height / 2, 0) +
              Vector3(0, 0, Sign(Step.Z) * M.Radius)) then
              NewPos := M.Position;
          end;
        end;
        { follow the floor (steps up to 18, falls) }
        FloorStart := NewPos + Vector3(0, 24, 0);
        Hit := FMap.World.WorldRayCast(FloorStart, Vector3(0, -1, 0), FloorDist);
        if (Hit <> nil) and (FloorDist < 24 + 400) then
          NewPos.Y := FloorStart.Y - FloorDist;
        M.Model.Holder.Translation := NewPos;
      end;
    msAttack:
      begin
        if NoTarget or PlayerDead then
        begin
          M.State := msIdle;
          M.Model.Instance.PlayAnim('idle');
          Exit;
        end;
        if Dist > MonsterMeleeRange * 1.3 then
        begin
          M.State := msChase;
          M.Model.Instance.PlayAnim('walk');
          Exit;
        end;
        if Dist > 0.1 then
          SetMonsterYaw(M, RadToDeg(ArcTan2(-ToPlayer.Z, ToPlayer.X)));
        M.AttackTimer := M.AttackTimer - SecondsPassed;
        if M.AttackTimer <= 0 then
        begin
          M.AttackTimer := MonsterAttackDelay;
          DamagePlayer(MonsterDamage);
        end;
      end;
    else ;
  end;
end;

procedure TD3Game.Update(const SecondsPassed: Single; const PlayerEye: TVector3);
var
  P: Integer;
  Mover: TD3Mover;
  Mon: TD3Monster;
  Feet: TVector3;
begin
  FFireCooldown := Max(0, FFireCooldown - SecondsPassed);
  SinceFire := SinceFire + SecondsPassed;
  FTime := FTime + SecondsPassed;
  if PlayerDead then
    FDeadTime := FDeadTime + SecondsPassed;
  Feet := PlayerEye - Vector3(0, PlayerEyeHeight, 0);
  for Mover in FMovers do
  begin
    if (Mover.Kind = mkDoor) and not Mover.NoTouch and not PlayerDead and
       Mover.TriggerBox.Contains(PlayerEye) then
      OpenTeam(Mover);
    Mover.Update(SecondsPassed);
    { a shut door closes its area portal (like idDoor) }
    if FMap.Portals <> nil then
      for P in Mover.Portals do
        FMap.Portals.PortalClosed[P] := Mover.State = dsClosed;
  end;
  if not ScriptsPaused then
    UpdateScriptMovers;
  UpdateBindings;
  UpdateCamera;
  UpdateLightFades;
  for Mon in FMonsters do
    UpdateMonster(Mon, SecondsPassed, Feet);
  UpdateTriggers(Feet);
  if (FScript <> nil) and not ScriptsPaused then
    FScript.Update(FTime);
end;

procedure TD3Game.StartCamera(const E: TD3MapEntity);
var
  Path: String;
  Anim: TD3CameraAnim;
begin
  FCameraAnim := nil;
  if E.Value('spawnclass') = 'idCameraAnim' then
  begin
    { "anim x" key of the entityDef: the file (x.camera = x.md5camera) }
    Path := D3CameraAnimPath(E.Value('anim ' + E.Value('anim')));
    if not FCameraAnims.TryGetValue(Path, Anim) then
    begin
      Anim := TD3CameraAnim.Create;
      if not Anim.LoadFromVfs(Path) then
      begin
        WritelnWarning('Doom3World', 'Camera anim "%s" of %s not found', [Path, E.Name]);
        FreeAndNil(Anim);
      end;
      FCameraAnims.Add(Path, Anim);
    end;
    if Anim = nil then
    begin
      { nothing to show: go on with what follows it }
      ActivateTargets(E);
      Exit;
    end;
    FCameraAnim := Anim;
    { the anim is in the map's space, moved by origin - old_origin }
    if E.HasKey('old_origin') then
      FCameraOffset := E.Origin - E.VectorValue('old_origin', TVector3.Zero)
    else
      FCameraOffset := TVector3.Zero;
    FCameraCycles := Max(1, E.IntValue('cycle', 1));
  end;
  FCameraEntity := E;
  FCameraStart := FTime;
  WritelnLog('Doom3World', 'Cinematic camera %s', [E.Name]);
  if FTime < FSkipUntil then
  begin
    { the cinematic goes on with this camera: skip it too }
    FSkipUntil := FTime + 1;
    StopCamera;
  end;
end;

procedure TD3Game.StopCamera;
var
  E: TD3MapEntity;
begin
  E := FCameraEntity;
  FCameraEntity := nil;
  FCameraAnim := nil;
  { idCameraAnim::Stop activates its targets }
  if (E <> nil) and (E.Value('spawnclass') = 'idCameraAnim') then
  begin
    WritelnLog('Doom3World', 'Cinematic camera %s done', [E.Name]);
    ActivateTargets(E);
  end;
end;

procedure TD3Game.UpdateCamera;
begin
  if (FCameraAnim = nil) or (FTime - FCameraStart < FCameraAnim.Duration) then
    Exit;
  Dec(FCameraCycles);
  if FCameraCycles > 0 then
    FCameraStart := FCameraStart + FCameraAnim.Duration
  else
    StopCamera;
end;

procedure TD3Game.SkipCinematic;
begin
  if FCameraEntity <> nil then
  begin
    { like gameLocal.SkipCinematic: the cameras the cinematic starts next
      (a chain of shots) are skipped too }
    FSkipUntil := FTime + 1;
    StopCamera;
  end;
end;

function TD3Game.CinematicActive: Boolean;
begin
  Result := FCameraEntity <> nil;
end;

function TD3Game.CinematicName: String;
begin
  if FCameraEntity <> nil then
    Result := FCameraEntity.Name
  else
    Result := '';
end;

procedure TD3Game.CinematicView(out Position, Direction, Up: TVector3; out FovDeg: Single);
var
  Origin, Fwd, U: TVector3;
  M: TMatrix3;
  Target: TD3MapEntity;
begin
  if FCameraAnim <> nil then
  begin
    FCameraAnim.Sample(FTime - FCameraStart, Origin, Fwd, U, FovDeg);
    Origin := Origin + FCameraOffset;
  end else
  if FCameraEntity <> nil then
  begin
    { idCameraView: from the entity, along its axis or at "cameraTarget" }
    Origin := FCameraEntity.Origin;
    M := FCameraEntity.Rotation;
    Fwd := Vector3(M.Data[0, 0], M.Data[0, 1], M.Data[0, 2]);
    U := Vector3(M.Data[2, 0], M.Data[2, 1], M.Data[2, 2]);
    Target := FindEntity(FCameraEntity.Value('cameraTarget'));
    if (Target <> nil) and (Target <> FCameraEntity) and
       not (Target.Origin - Origin).IsZero then
    begin
      Fwd := (Target.Origin - Origin).Normalize;
      U := Vector3(0, 0, 1);
    end;
    FovDeg := FCameraEntity.FloatValue('fov', 90);
  end else
  begin
    Origin := TVector3.Zero;
    Fwd := Vector3(1, 0, 0);
    U := Vector3(0, 0, 1);
    FovDeg := 90;
  end;
  Position := D3ToCge(Origin);
  Direction := D3ToCge(Fwd);
  Up := D3ToCge(U);
end;

procedure TD3Game.StartFade(const Target: TVector4; const Seconds: Single);
begin
  FFadeFrom := FadeColor;
  FFadeTo := Target;
  FFadeStart := FTime;
  FFadeTime := Max(0, Seconds);
end;

function TD3Game.FadeColor: TVector4;
var
  F: Single;
begin
  if FFadeTime <= 0 then
    Exit(FFadeTo);
  F := EnsureRange((FTime - FFadeStart) / FFadeTime, 0, 1);
  Result := FFadeFrom + (FFadeTo - FFadeFrom) * F;
end;

function TD3Game.TakeTeleport(out FeetPos: TVector3; out YawDeg: Single): Boolean;
begin
  Result := FTeleportPending;
  FeetPos := FTeleportPos;
  YawDeg := FTeleportYaw;
  FTeleportPending := False;
end;

procedure TD3Game.FadeLight(const Light: Integer; const Target, Seconds: Single);
var
  F: TD3LightFade;
  I: Integer;
begin
  for I := FLightFades.Count - 1 downto 0 do
    if FLightFades[I].Light = Light then
      FLightFades.Delete(I);
  if Seconds <= 0 then
  begin
    FMap.SetLightFade(Light, Target);
    Exit;
  end;
  F.Light := Light;
  F.From := FMap.Light(Light).Fade;
  F.Target := Target;
  F.Start := FTime;
  F.Duration := Seconds;
  FLightFades.Add(F);
end;

procedure TD3Game.UpdateLightFades;
var
  I: Integer;
  F: TD3LightFade;
  T: Single;
begin
  for I := FLightFades.Count - 1 downto 0 do
  begin
    F := FLightFades[I];
    T := EnsureRange((FTime - F.Start) / F.Duration, 0, 1);
    FMap.SetLightFade(F.Light, F.From + (F.Target - F.From) * T);
    if T >= 1 then
      FLightFades.Delete(I);
  end;
end;

function TD3Game.ScriptSoundSource(const Handle: Integer): TCastleSoundSource;
var
  E: TD3MapEntity;
  T: TCastleTransform;
begin
  if FSoundSources.TryGetValue(Handle, Result) then
    Exit;
  Result := nil;
  E := HandleEntity(Handle);
  if E = nil then
    Exit;
  { the sound follows the entity's scene, or stays at its origin }
  T := TransformOf(E.Name);
  if T = nil then
  begin
    T := TCastleTransform.Create(nil);
    T.Translation := D3ToCge(E.Origin);
    FMap.Add(T);
    FSoundTransforms.Add(T);
  end;
  Result := TCastleSoundSource.Create(T);
  T.AddBehavior(Result);
  FSoundSources.Add(Handle, Result);
end;

function TD3Game.StartScriptSound(const Handle: Integer; const ShaderName: String;
  const Channel: Integer): Single;
var
  Snd: TCastleSound;
  Source: TCastleSoundSource;
  Playing: TCastlePlayingSoundSource;
begin
  Result := 0;
  Snd := SoundFromShader(ShaderName);
  if Snd = nil then
    Exit;
  Source := ScriptSoundSource(Handle);
  if Source = nil then
    Exit;
  { a new sound on a channel replaces the old one (channel 0: any) }
  if Channel <> 0 then
    StopScriptSound(Handle, Channel);
  Playing := TCastlePlayingSoundSource.Create(nil);
  Playing.Sound := Snd;
  Source.Play(Playing);
  if Channel <> 0 then
    FScriptSounds.AddOrSetValue(IntToStr(Handle) + ':' + IntToStr(Channel), Playing)
  else
    Playing.FreeOnStop := True;
  Result := Snd.Duration;
end;

procedure TD3Game.StopScriptSound(const Handle, Channel: Integer);
var
  Key: String;
  Playing: TCastlePlayingSoundSource;
begin
  Key := IntToStr(Handle) + ':' + IntToStr(Channel);
  if FScriptSounds.TryGetValue(Key, Playing) then
  begin
    Playing.Stop;
    FScriptSounds.Remove(Key);
  end;
end;

procedure TD3Game.ClearScriptSounds;
var
  Playing: TCastlePlayingSoundSource;
begin
  for Playing in FScriptSounds.Values do
    Playing.Stop;
  FScriptSounds.Clear;
  FSoundSources.Clear;
  FSoundTransforms.Clear;
end;

function TD3Game.ScriptStatus: String;
var
  M: TD3ScriptMover;
  Moving, Turning: Integer;
begin
  if FScript = nil then
    Exit('No scripts');
  Moving := 0;
  Turning := 0;
  for M in FScriptMovers.Values do
  begin
    if M.Moving then
      Inc(Moving);
    if M.Rotating then
      Inc(Turning);
  end;
  Result := Format('%d script threads, %d script movers (%d moving, %d rotating), %d bound entities%s',
    [FScript.ThreadCount, FScriptMovers.Count, Moving, Turning, FBindings.Count,
     BoolToStr(ScriptsPaused, ', paused', '')]);
end;

procedure TD3Game.OpenTeam(const Door: TD3Mover);
var
  M: TD3Mover;
begin
  if Door.Locked then
    Exit;
  if Door.Team = '' then
    Door.Open
  else
    for M in FMovers do
      if (M.Kind = mkDoor) and (M.Team = Door.Team) then
        M.Open;
end;

procedure TD3Game.CloseTeam(const Door: TD3Mover);
var
  M: TD3Mover;
begin
  if Door.Team = '' then
    Door.Close
  else
    for M in FMovers do
      if (M.Kind = mkDoor) and (M.Team = Door.Team) then
        M.Close;
end;

procedure TD3Game.LockTeam(const Door: TD3Mover; const Value: Boolean);
var
  M: TD3Mover;
begin
  if Door.Team = '' then
    Door.Locked := Value
  else
    for M in FMovers do
      if (M.Kind = mkDoor) and (M.Team = Door.Team) then
        M.Locked := Value;
end;

function TD3Game.TransformOf(const AName: String): TCastleTransform;
var
  B: TD3BrushEntity;
  ME: TD3ModelEntity;
begin
  B := FMap.FindBrush(AName);
  if B <> nil then
    Exit(B.Scene);
  ME := FMap.FindModelEntity(AName);
  if ME <> nil then
    Exit(ME.Holder);
  Result := nil;
end;

function TD3Game.FindBinding(const Child: TCastleTransform): TD3Binding;
begin
  for Result in FBindings do
    if Result.Child = Child then
      Exit;
  Result := nil;
end;

procedure TD3Game.Bind(const Child, Parent: TCastleTransform);
var
  Bnd: TD3Binding;
  P: TCastleTransform;
  Guard: Integer;
begin
  if (Child = nil) or (Parent = nil) or (Child = Parent) then
    Exit;
  { no loops: the parent must not be bound to the child }
  P := Parent;
  Guard := 0;
  while (P <> nil) and (Guard < 100) do
  begin
    if P = Child then
      Exit;
    Bnd := FindBinding(P);
    if Bnd = nil then
      Break;
    P := Bnd.Parent;
    Inc(Guard);
  end;
  Bnd := FindBinding(Child);
  if Bnd = nil then
  begin
    Bnd := TD3Binding.Create;
    Bnd.Child := Child;
    FBindings.Add(Bnd);
  end;
  Bnd.Parent := Parent;
  { both are children of the map (world space): child = parent * relative }
  Bnd.ChildInParent := Parent.InverseTransform * Child.Transform;
  FBindingsSorted := False;
end;

procedure TD3Game.Unbind(const Child: TCastleTransform);
var
  Bnd: TD3Binding;
begin
  Bnd := FindBinding(Child);
  if Bnd <> nil then
    FBindings.Remove(Bnd);
  FBindingsSorted := False;
end;

procedure TD3Game.SpawnBindings;
var
  E: TD3MapEntity;
begin
  if FMap.MapFile = nil then
    Exit;
  { lights and other entities are not bound yet }
  for E in FMap.MapFile.Entities do
    if E.Value('bind') <> '' then
      Bind(TransformOf(E.Name), TransformOf(E.Value('bind')));
end;

function CompareBindingDepth(constref A, B: TD3Binding): Integer;
begin
  Result := A.Depth - B.Depth;
end;

procedure TD3Game.UpdateBindings;
var
  Bnd, P: TD3Binding;
  M: TMatrix4;
  T, Scale: TVector3;
  R: TVector4;
begin
  { parents before their children, so chains (a crane's arm on its
    carrier) follow in the same frame }
  if not FBindingsSorted then
  begin
    for Bnd in FBindings do
    begin
      Bnd.Depth := 0;
      P := FindBinding(Bnd.Parent);
      while (P <> nil) and (Bnd.Depth < 100) do
      begin
        Inc(Bnd.Depth);
        P := FindBinding(P.Parent);
      end;
    end;
    FBindings.Sort(specialize TComparer<TD3Binding>.Construct(@CompareBindingDepth));
    FBindingsSorted := True;
  end;
  for Bnd in FBindings do
  begin
    M := Bnd.Parent.Transform * Bnd.ChildInParent;
    { most parents don't move: don't touch their children's scenes }
    if TMatrix4.Equals(M, Bnd.Child.Transform, 0.01) then
      Continue;
    MatrixDecompose(M, T, R, Scale);
    Bnd.Child.Translation := T;
    Bnd.Child.Rotation := R;
  end;
end;

{ Scripts -------------------------------------------------------------------- }

{ CGE transformation of a Doom 3 origin and idMat3 (rows = axes). }
function D3PlacementMatrix(const Origin: TVector3; const M: TMatrix3): TMatrix4;
var
  C: Integer;
  U, W, Col: TVector3;
begin
  Result := TMatrix4.Identity;
  for C := 0 to 2 do
  begin
    U := CgeToD3(TVector3.One[C]);
    W := Vector3(
      U.X * M.Data[0, 0] + U.Y * M.Data[1, 0] + U.Z * M.Data[2, 0],
      U.X * M.Data[0, 1] + U.Y * M.Data[1, 1] + U.Z * M.Data[2, 1],
      U.X * M.Data[0, 2] + U.Y * M.Data[1, 2] + U.Z * M.Data[2, 2]);
    Col := D3ToCge(W);
    Result.Data[C, 0] := Col.X;
    Result.Data[C, 1] := Col.Y;
    Result.Data[C, 2] := Col.Z;
  end;
  Col := D3ToCge(Origin);
  Result.Data[3, 0] := Col.X;
  Result.Data[3, 1] := Col.Y;
  Result.Data[3, 2] := Col.Z;
end;

{ The Doom 3 origin and angles of a CGE transformation. }
procedure D3PlacementFromMatrix(const T: TMatrix4; out Origin, Angles: TVector3);
var
  M: TMatrix3;
  I: Integer;
  Axis, V: TVector3;
begin
  Origin := CgeToD3(Vector3(T.Data[3, 0], T.Data[3, 1], T.Data[3, 2]));
  for I := 0 to 2 do
  begin
    { the image of Doom 3 local axis I }
    Axis := D3ToCge(TVector3.One[I]);
    V := Vector3(
      T.Data[0, 0] * Axis.X + T.Data[1, 0] * Axis.Y + T.Data[2, 0] * Axis.Z,
      T.Data[0, 1] * Axis.X + T.Data[1, 1] * Axis.Y + T.Data[2, 1] * Axis.Z,
      T.Data[0, 2] * Axis.X + T.Data[1, 2] * Axis.Y + T.Data[2, 2] * Axis.Z);
    V := CgeToD3(V);
    M.Data[I, 0] := V.X;
    M.Data[I, 1] := V.Y;
    M.Data[I, 2] := V.Z;
  end;
  Angles := MatrixAngles(M);
end;

{ Fraction of a move done after T of Total seconds, accelerating for
  Accel and decelerating for Decel seconds (idExtrapolate's
  EXTRAPOLATION_ACCELLINEAR / DECELLINEAR, a trapezoid of speed). }
function MoveFraction(const T, Total, Accel, Decel: Single): Single;
var
  A, D, V: Single;
begin
  if (Total <= 0) or (T >= Total) then
    Exit(1);
  if T <= 0 then
    Exit(0);
  A := Max(0, Accel);
  D := Max(0, Decel);
  if A + D > Total then
  begin
    A := Total * A / (A + D);
    D := Total - A;
  end;
  { top speed so that the whole move covers 1 }
  V := 1 / (Total - A / 2 - D / 2);
  if T < A then
    Result := 0.5 * V * Sqr(T) / A
  else
  if T <= Total - D then
    Result := 0.5 * V * A + V * (T - A)
  else
    Result := 1 - 0.5 * V * Sqr(Total - T) / D;
  Result := EnsureRange(Result, 0, 1);
end;

function TD3ScriptMover.Busy: Boolean;
begin
  Result := Moving or (Rotating and not RotContinuous);
end;

function TD3Game.HandleEntity(const Handle: Integer): TD3MapEntity;
begin
  if (FMap.MapFile = nil) or (Handle < 1) or (Handle > FMap.MapFile.Entities.Count) then
    Exit(nil);
  Result := FMap.MapFile.Entities[Handle - 1];
end;

function TD3Game.EntityHandle(const E: TD3MapEntity): Integer;
begin
  if (E = nil) or not FHandles.TryGetValue(LowerCase(E.Name), Result) then
    Result := 0;
end;

function TD3Game.ScriptFindEntity(const AName: String): Integer;
begin
  if not FHandles.TryGetValue(LowerCase(AName), Result) then
    Result := 0;
end;

function TD3Game.ScriptEntityName(const Handle: Integer): String;
var
  E: TD3MapEntity;
begin
  E := HandleEntity(Handle);
  if E <> nil then
    Result := E.Name
  else
    Result := '';
end;

function TD3Game.ScriptEntityBusy(const Handle: Integer): Boolean;
var
  M: TD3ScriptMover;
  Door: TD3Mover;
  E: TD3MapEntity;
begin
  if FScriptMovers.TryGetValue(Handle, M) and M.Busy then
    Exit(True);
  E := HandleEntity(Handle);
  if E <> nil then
    for Door in FMovers do
      if (Door.Brush.Entity = E) and (Door.Kind = mkDoor) and
         (Door.State in [dsOpening, dsClosing]) then
        Exit(True);
  Result := False;
end;

function TD3Game.ScriptMover(const Handle: Integer): TD3ScriptMover;
var
  E: TD3MapEntity;
  T: TCastleTransform;
  Bnd: TD3Binding;
  Local: TMatrix4;
begin
  if FScriptMovers.TryGetValue(Handle, Result) then
    Exit;
  Result := nil;
  E := HandleEntity(Handle);
  if E = nil then
    Exit;
  T := TransformOf(E.Name);
  if T = nil then
    Exit;
  Result := TD3ScriptMover.Create;
  Result.Handle := Handle;
  Result.Transform := T;
  Bnd := FindBinding(T);
  if Bnd <> nil then
    Local := Bnd.ChildInParent
  else
    Local := T.Transform;
  D3PlacementFromMatrix(Local, Result.Origin, Result.Angles);
  { idMover spawn args: "move_time" (default 1), "move_speed", "accel_time",
    "decel_time" }
  Result.MoveTime := E.FloatValue('move_time', 1);
  Result.MoveSpeed := E.FloatValue('move_speed', 0);
  Result.AccelTime := E.FloatValue('accel_time', 0);
  Result.DecelTime := E.FloatValue('decel_time', 0);
  FScriptMovers.Add(Handle, Result);
end;

procedure TD3Game.ApplyScriptMover(const M: TD3ScriptMover);
var
  Local: TMatrix4;
  Bnd: TD3Binding;
  T, Scale: TVector3;
  R: TVector4;
begin
  Local := D3PlacementMatrix(M.Origin, AnglesMatrix(M.Angles));
  Bnd := FindBinding(M.Transform);
  if Bnd <> nil then
  begin
    { UpdateBindings places it }
    Bnd.ChildInParent := Local;
    Exit;
  end;
  MatrixDecompose(Local, T, R, Scale);
  M.Transform.Translation := T;
  M.Transform.Rotation := R;
end;

procedure TD3Game.UpdateScriptMovers;
var
  M: TD3ScriptMover;
  F: Single;
  Changed: Boolean;
begin
  for M in FScriptMovers.Values do
  begin
    Changed := False;
    if M.Moving then
    begin
      F := MoveFraction(FTime - M.MoveStart, M.MoveDuration, M.AccelTime, M.DecelTime);
      M.Origin := M.MoveFrom + (M.MoveTo - M.MoveFrom) * F;
      if F >= 1 then
        M.Moving := False;
      Changed := True;
    end;
    if M.Rotating then
    begin
      if M.RotContinuous then
        M.Angles := M.RotFrom + M.RotSpeed * (FTime - M.RotStart)
      else
      begin
        F := MoveFraction(FTime - M.RotStart, M.RotDuration, M.AccelTime, M.DecelTime);
        M.Angles := M.RotFrom + (M.RotTo - M.RotFrom) * F;
        if F >= 1 then
          M.Rotating := False;
      end;
      Changed := True;
    end;
    if Changed then
      ApplyScriptMover(M);
  end;
end;

procedure TD3Game.StartScripts;
var
  Base, Key: String;
  Start: QWord;
  I: Integer;
  E: TD3MapEntity;
  F: TD3ScriptFunction;
begin
  FHandles.Clear;
  if FMap.MapFile = nil then
    Exit;
  for I := 0 to FMap.MapFile.Entities.Count - 1 do
    if FMap.MapFile.Entities[I].Name <> '' then
      FHandles.AddOrSetValue(LowerCase(FMap.MapFile.Entities[I].Name), I + 1);
  { like idGameLocal: the game's scripts, then the map's own }
  Base := TDoom3Map.MapBasePath(FMap.MapName);
  if not D3Fs.FileExists('script/doom_main.script') and not D3Fs.FileExists(Base + '.script') then
    Exit;
  Start := GetTickCount64;
  FScript := TD3ScriptVM.Create;
  FScript.Host := FScriptHost;
  try
    if D3Fs.FileExists('script/doom_main.script') then
      FScript.CompileFile('script/doom_main.script');
    if D3Fs.FileExists(Base + '.script') then
      FScript.CompileFile(Base + '.script');
  except
    on Ex: ED3ScriptError do
    begin
      WritelnWarning('Doom3World', 'Script error, scripts are off: %s', [Ex.Message]);
      FreeAndNil(FScript);
      Exit;
    end;
  end;
  WritelnLog('Doom3World', 'Scripts: %d functions from %d files compiled in %.2f s',
    [FScript.FunctionCount, FScript.FileCount, (GetTickCount64 - Start) / 1000]);
  { idWorldspawn: the map script's main, then worldspawn's "call" keys,
    all on the first frame }
  F := FScript.FindFunction('main');
  if F <> nil then
    FScript.QueueThread(F);
  E := FMap.MapFile.Entities[0];
  for I := 0 to E.Pairs.Count - 1 do
  begin
    Key := LowerCase(E.Pairs.Names[I]);
    if Copy(Key, 1, 4) = 'call' then
      CallScript(E.Pairs.ValueFromIndex[I], E.Name);
  end;
end;

procedure TD3Game.CallScript(const FunctionName: String; const Who: String);
var
  F: TD3ScriptFunction;
begin
  if FScript = nil then
  begin
    Unsupported('script function calls without scripts ("call" of ' + Who + ')');
    Exit;
  end;
  F := FScript.FindFunction(FunctionName);
  if F = nil then
  begin
    WritelnWarning('Doom3World', 'Script function "%s" (called by %s) not found', [FunctionName, Who]);
    Exit;
  end;
  FScript.QueueThread(F);
end;

{ idMover::VectorForDir }
function MoveDirVector(const Dir: Single; const Angles: TVector3): TVector3;
var
  Axis: TMatrix3;
  D: Integer;
begin
  D := Round(Dir);
  Axis := AnglesMatrix(Angles);
  case D of
    -1: Result := Vector3(0, 0, 1);   // UP
    -2: Result := Vector3(0, 0, -1);  // DOWN
    -3: Result := Vector3(Axis.Data[1, 0], Axis.Data[1, 1], Axis.Data[1, 2]);   // LEFT
    -4: Result := -Vector3(Axis.Data[1, 0], Axis.Data[1, 1], Axis.Data[1, 2]);  // RIGHT
    -5: Result := Vector3(Axis.Data[0, 0], Axis.Data[0, 1], Axis.Data[0, 2]);   // FORWARD
    -6: Result := -Vector3(Axis.Data[0, 0], Axis.Data[0, 1], Axis.Data[0, 2]);  // BACK
    -7: Result := Vector3(Axis.Data[2, 0], Axis.Data[2, 1], Axis.Data[2, 2]);   // REL_UP
    -8: Result := -Vector3(Axis.Data[2, 0], Axis.Data[2, 1], Axis.Data[2, 2]);  // REL_DOWN
    -9: Result := Vector3(Axis.Data[1, 0], Axis.Data[1, 1], Axis.Data[1, 2]);   // REL_LEFT
    -10: Result := -Vector3(Axis.Data[1, 0], Axis.Data[1, 1], Axis.Data[1, 2]); // REL_RIGHT
    -11: Result := Vector3(Axis.Data[0, 0], Axis.Data[0, 1], Axis.Data[0, 2]);  // REL_FORWARD
    -12: Result := -Vector3(Axis.Data[0, 0], Axis.Data[0, 1], Axis.Data[0, 2]); // REL_BACK
    else
      Result := Vector3(Cos(DegToRad(Dir)), Sin(DegToRad(Dir)), 0);
  end;
end;

function TD3Game.ScriptEvent(const Target: Integer; const Event: TD3ScriptEvent;
  const Args: TD3ValueArray; var EventResult: TD3Value): Boolean;
var
  N, Key: String;
  E, Other: TD3MapEntity;
  M: TD3ScriptMover;
  Light, I, Count: Integer;
  B: TD3BrushEntity;
  ME: TD3ModelEntity;
  Door: TD3Mover;
  Dist: Single;

  function ArgF(const Index: Integer): Single;
  begin
    Result := D3ValueToFloat(Args[Index]);
  end;

  procedure StartMove(const Dest: TVector3);
  begin
    M.MoveFrom := M.Origin;
    M.MoveTo := Dest;
    M.MoveStart := FTime;
    Dist := (Dest - M.Origin).Length;
    if M.MoveSpeed > 0 then
      M.MoveDuration := Dist / M.MoveSpeed
    else
      M.MoveDuration := M.MoveTime;
    M.Moving := True;
  end;

  procedure StartRotation(const Dest: TVector3);
  begin
    M.RotFrom := M.Angles;
    M.RotTo := Dest;
    M.RotStart := FTime;
    M.RotDuration := M.MoveTime;
    M.Rotating := True;
    M.RotContinuous := False;
  end;

  function DoorOf(const AE: TD3MapEntity): TD3Mover;
  begin
    for Result in FMovers do
      if (Result.Brush.Entity = AE) and (Result.Kind = mkDoor) then
        Exit;
    Result := nil;
  end;

begin
  Result := True;
  N := Event.Name;

  { sys events }
  if Target = 0 then
  begin
    if N = 'trigger' then
    begin
      E := HandleEntity(Args[0].E);
      if E <> nil then
        Activate(E);
    end else
    if N = 'getEntity' then
      EventResult := D3EntityValue(ScriptFindEntity(Args[0].S))
    else
    if (N = 'setcvar') or (N = 'getcvar') then
      // cvars are not shared with scripts: getcvar returns ""
    else
    if N = 'fadeIn' then
      StartFade(Vector4(Args[0].V, 0), ArgF(1))
    else
    if N = 'fadeOut' then
      StartFade(Vector4(Args[0].V, 1), ArgF(1))
    else
    if N = 'fadeTo' then
      StartFade(Vector4(Args[0].V, ArgF(1)), ArgF(2))
    else
    if N = 'setCamera' then
    begin
      E := HandleEntity(Args[0].E);
      if E <> nil then
        StartCamera(E);
    end else
    if N = 'firstPerson' then
    begin
      FCameraEntity := nil;
      FCameraAnim := nil;
    end else
      Result := False;
    Exit;
  end;

  E := HandleEntity(Target);
  if E = nil then
    Exit(False);
  Light := -1;
  if SameText(E.ClassName_, 'light') then
    Light := FMap.FindLight(E.Name);

  { all entities }
  if N = 'getName' then
    EventResult := D3StringValue(E.Name)
  else
  if N = 'activate' then
    Activate(E)
  else
  if (N = 'getKey') or (N = 'getFloatKey') or (N = 'getIntKey') or
     (N = 'getBoolKey') or (N = 'getVectorKey') or (N = 'getEntityKey') then
  begin
    Key := Args[0].S;
    case N of
      'getKey': EventResult := D3StringValue(E.Value(Key));
      'getFloatKey': EventResult := D3FloatValue(E.FloatValue(Key));
      'getIntKey': EventResult := D3FloatValue(Trunc(E.FloatValue(Key)));
      'getBoolKey': EventResult := D3FloatValue(Ord(E.FloatValue(Key) <> 0));
      'getVectorKey': EventResult := D3VectorValue(E.VectorValue(Key, TVector3.Zero));
      else EventResult := D3EntityValue(ScriptFindEntity(E.Value(Key)));
    end;
  end else
  if N = 'setKey' then
    E.SetValue(Args[0].S, Args[1].S)
  else
  if (N = 'numTargets') or (N = 'getTarget') then
  begin
    Count := 0;
    for I := 0 to E.Pairs.Count - 1 do
    begin
      Key := LowerCase(E.Pairs.Names[I]);
      if (Copy(Key, 1, 6) <> 'target') or
         ((Length(Key) > 6) and not CharInSet(Key[7], ['0'..'9'])) then
        Continue;
      Other := FindEntity(E.Pairs.ValueFromIndex[I]);
      if Other = nil then
        Continue;
      if (N = 'getTarget') and (Count = Round(ArgF(0))) then
      begin
        EventResult := D3EntityValue(EntityHandle(Other));
        Exit;
      end;
      Inc(Count);
    end;
    if N = 'numTargets' then
      EventResult := D3FloatValue(Count);
  end else
  if (N = 'hide') or (N = 'show') or (N = 'isHidden') or (N = 'remove') then
  begin
    if N = 'remove' then
    begin
      RemoveEntity(E);
      Exit;
    end;
    if Light >= 0 then
    begin
      if N = 'isHidden' then
        EventResult := D3FloatValue(Ord(not FMap.Light(Light).StartOn))
      else
        FMap.SetLightOn(Light, N = 'show');
      Exit;
    end;
    B := FMap.FindBrush(E.Name);
    ME := FMap.FindModelEntity(E.Name);
    if N = 'isHidden' then
    begin
      if B <> nil then
        EventResult := D3FloatValue(Ord(B.Hidden))
      else
      if ME <> nil then
        EventResult := D3FloatValue(Ord(ME.Hidden));
      Exit;
    end;
    if B <> nil then
      B.SetHidden(N = 'hide');
    if ME <> nil then
    begin
      ME.Hidden := N = 'hide';
      ME.Holder.Exists := not ME.Hidden;
    end;
  end else

  { lights }
  if (Light >= 0) and ((N = 'On') or (N = 'Off')) then
    FMap.SetLightOn(Light, N = 'On')
  else
  if (Light >= 0) and (N = 'fadeOutLight') then
    FadeLight(Light, 0, ArgF(0))
  else
  if (Light >= 0) and (N = 'fadeInLight') then
  begin
    { an off light comes on dark, then brightens }
    if not FMap.Light(Light).StartOn then
    begin
      FMap.SetLightFade(Light, 0);
      FMap.SetLightOn(Light, True);
    end;
    FadeLight(Light, 1, ArgF(0));
  end else
  if (N = 'startSoundShader') or (N = 'startSound') then
  begin
    { startSound names an entity key holding the shader (snd_...) }
    if N = 'startSound' then
      Key := E.Value(Args[0].S)
    else
      Key := Args[0].S;
    EventResult := D3FloatValue(StartScriptSound(Target, Key, Round(ArgF(1))));
  end else
  if N = 'stopSound' then
    StopScriptSound(Target, Round(ArgF(0)))
  else
  if (Light >= 0) and (N = 'setColor') then
  begin
    FMap.SetLightParm(Light, 0, ArgF(0));
    FMap.SetLightParm(Light, 1, ArgF(1));
    FMap.SetLightParm(Light, 2, ArgF(2));
  end else
  if (Light >= 0) and ((N = 'setShaderParm') or (N = 'setLightParm')) then
    FMap.SetLightParm(Light, Round(ArgF(0)), ArgF(1))
  else

  { doors (idDoor) }
  if (DoorOf(E) <> nil) and ((N = 'open') or (N = 'close') or (N = 'lock') or
     (N = 'isOpen') or (N = 'isLocked')) then
  begin
    Door := DoorOf(E);
    case N of
      'open': OpenTeam(Door);
      'close': CloseTeam(Door);
      'lock': LockTeam(Door, ArgF(0) <> 0);
      'isOpen': EventResult := D3FloatValue(Ord(Door.State <> dsClosed));
      else EventResult := D3FloatValue(Ord(Door.Locked));
    end;
  end else

  { binding }
  if (N = 'bind') or (N = 'bindPosition') then
  begin
    Other := HandleEntity(Args[0].E);
    if Other <> nil then
    begin
      Bind(TransformOf(E.Name), TransformOf(Other.Name));
      { a script mover's origin and angles become relative to the master }
      if FScriptMovers.TryGetValue(Target, M) and (FindBinding(M.Transform) <> nil) then
        D3PlacementFromMatrix(FindBinding(M.Transform).ChildInParent, M.Origin, M.Angles);
    end;
  end else
  if (N = 'unbind') or (N = 'removeBinds') then
  begin
    if N = 'unbind' then
    begin
      Unbind(TransformOf(E.Name));
      if FScriptMovers.TryGetValue(Target, M) then
        D3PlacementFromMatrix(M.Transform.Transform, M.Origin, M.Angles);
    end;
  end else

  { idMover }
  begin
    M := ScriptMover(Target);
    if M = nil then
      Exit(False);
    case N of
      'time': M.MoveTime := ArgF(0);
      'speed': M.MoveSpeed := ArgF(0);
      'accelTime': M.AccelTime := ArgF(0);
      'decelTime': M.DecelTime := ArgF(0);
      'move': StartMove(M.Origin + MoveDirVector(ArgF(0), M.Angles) * ArgF(1));
      'moveTo':
        begin
          Other := HandleEntity(Args[0].E);
          if Other <> nil then
            StartMove(Other.Origin);
        end;
      'moveToPos': StartMove(Args[0].V);
      'rotateOnce': StartRotation(M.Angles + Args[0].V);
      'rotateTo': StartRotation(Args[0].V);
      'rotateUpTo', 'rotateDownTo':
        begin
          M.RotTo := M.Angles;
          M.RotTo.Data[EnsureRange(Round(ArgF(0)), 0, 2)] := ArgF(1);
          StartRotation(M.RotTo);
        end;
      'rotate':
        begin
          { degrees per second around each axis, until stopped }
          M.RotFrom := M.Angles;
          M.RotSpeed := Args[0].V;
          M.RotStart := FTime;
          M.Rotating := True;
          M.RotContinuous := True;
        end;
      'stopMoving': M.Moving := False;
      'stopRotating': M.Rotating := False;
      'isMoving': EventResult := D3FloatValue(Ord(M.Moving));
      'isRotating': EventResult := D3FloatValue(Ord(M.Rotating));
      'getOrigin': EventResult := D3VectorValue(M.Origin);
      'getWorldOrigin': EventResult := D3VectorValue(CgeToD3(M.Transform.WorldTranslation));
      'getAngles': EventResult := D3VectorValue(M.Angles);
      'setOrigin':
        begin
          M.Moving := False;
          M.Origin := Args[0].V;
          ApplyScriptMover(M);
        end;
      'setAngles':
        begin
          M.Rotating := False;
          M.Angles := Args[0].V;
          ApplyScriptMover(M);
        end;
      else
        Result := False;
    end;
  end;
end;

function TD3Game.Fire(const Origin, Dir: TVector3): Boolean;
var
  WallDist, BestDist, T: Single;
  Mon, Best: TD3Monster;
  Hit: TCastleTransform;
  D, ToCenter, Closest: TVector3;
  HitName: String;
begin
  Result := False;
  if (FFireCooldown > 0) or PlayerDead then
    Exit;
  FFireCooldown := PistolDelay;
  SinceFire := 0;
  Result := True;
  D := Dir.Normalize;
  Hit := FMap.World.WorldRayCast(Origin, D, WallDist);
  if Hit = nil then
    WallDist := MaxSingle;
  { monsters as vertical cylinders }
  Best := nil;
  BestDist := WallDist;
  for Mon in FMonsters do
  begin
    if Mon.State = msDead then
      Continue;
    ToCenter := Mon.Center - Origin;
    T := TVector3.DotProduct(ToCenter, D);
    if (T <= 0) or (T >= BestDist) then
      Continue;
    Closest := Origin + D * T;
    if (Sqr(Closest.X - Mon.Center.X) + Sqr(Closest.Z - Mon.Center.Z) < Sqr(Mon.Radius)) and
       (Abs(Closest.Y - Mon.Center.Y) < Mon.Height / 2) then
    begin
      Best := Mon;
      BestDist := T;
    end;
  end;
  if Best <> nil then
    HitName := 'hit ' + Best.Model.Entity.Name
  else
    HitName := 'missed';
  if Hit <> nil then
    WritelnLog('Doom3World', 'Shot: wall %.0f (%s), monster %s', [WallDist, Hit.Name, HitName])
  else
    WritelnLog('Doom3World', 'Shot: no wall, monster %s', [HitName]);
  if Best <> nil then
  begin
    Dec(Best.Health, PistolDamage);
    Best.PainTime := 0.2;
    Best.Dormant := False;
    if Best.State = msIdle then
    begin
      Best.State := msChase;
      Best.Model.Instance.PlayAnim('walk');
    end;
    if Best.Health <= 0 then
    begin
      Best.State := msDead;
      Best.StateTime := 0;
      Best.Model.Instance.PlayAnim('idle', False);
      Inc(Kills);
      Message('Killed ' + Best.Model.Entity.Name);
    end;
  end;
end;

procedure TD3Game.Use(const Origin, Dir: TVector3);
var
  Mover: TD3Mover;
  Ray: TBox3D;
begin
  Ray := TBox3D.Empty;
  Ray.Include(Origin);
  Ray.Include(Origin + Dir.Normalize * 96);
  for Mover in FMovers do
    if (Mover.Kind = mkDoor) and Mover.Brush.Scene.WorldBoundingBox.Collision(Ray) then
    begin
      if Mover.Locked then
        Message('Locked')
      else
        Mover.Open;
    end;
end;

procedure TD3Game.DamagePlayer(const Amount: Integer);
var
  Absorbed: Integer;
begin
  if God or PlayerDead then
    Exit;
  { Doom 3 armor absorbs 1/3 of the damage }
  Absorbed := Min(Armor, Amount div 3);
  Dec(Armor, Absorbed);
  Dec(Health, Amount - Absorbed);
  if Health <= 0 then
  begin
    Health := 0;
    FDeadTime := 0;
    Message('You died');
  end;
end;

function TD3Game.PlayerDead: Boolean;
begin
  Result := Health <= 0;
end;

end.
