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

  Everything here is in CGE coordinates (Y up); Doom 3 units are kept
  (1 unit = 1 inch), so speeds and sizes are Doom 3's numbers. }
unit Doom3World;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleVectors, CastleTransform, CastleScene, CastleSoundEngine, CastleBoxes, CastleBehaviors,
  Doom3Level, Doom3MapFile, Doom3Decls;

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
    { rotating }
    RotAxis: TVector3;
    RotSpeed, Angle: Single;
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
  FCounts.Free;
  FUnsupported.Free;
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
  FCounts.Clear;
  FUnsupported.Clear;
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
    Size := B.LocalMax - B.LocalMin;
    M.Distance := Abs(Dir.X) * Size.X + Abs(Dir.Y) * Size.Y + Abs(Dir.Z) * Size.Z -
      E.FloatValue('lip', 8);
    M.MoveDir := D3ToCge(Dir);
    M.Speed := E.FloatValue('speed', 400);
    if E.HasKey('time') and (E.FloatValue('time') > 0) then
      M.Speed := Max(1, M.Distance) / E.FloatValue('time');
    M.Wait := E.FloatValue('wait', 3);
    M.Locked := E.BoolValue('locked');
    M.NoTouch := E.BoolValue('no_touch');
    { Doom 3 doors open when you enter a trigger around them }
    TriggerSize := E.FloatValue('triggersize', 120);
    Box := Box3D(D3ToCge(E.Origin + B.LocalMin), D3ToCge(E.Origin + B.LocalMax));
    M.TriggerBox := Box.Grow(TriggerSize * 0.5);
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
  Hidden := 0;
  Dormant := 0;
  for ME in FMap.Models do
    if ME.Hidden and (Copy(LowerCase(ME.Entity.ClassName_), 1, 8) = 'monster_') then
      Inc(Hidden);
  for Mon in FMonsters do
    if Mon.Dormant then
      Inc(Dormant);
  WritelnLog('Doom3World', 'Spawned %d movers, %d monsters (%d dormant until triggered, %d hidden), %d speakers, %d triggers',
    [FMovers.Count, FMonsters.Count, Dormant, Hidden, FSpeakers.Count, FTriggers.Count]);
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
  if E.HasKey('call') then
    Unsupported('script function calls ("call" key of ' + E.ClassName_ + ')');
end;

procedure TD3Game.ActivateTargetsNow(const E: TD3MapEntity);
var
  I: Integer;
  Key: String;
  Target: TD3MapEntity;
begin
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

  for Mover in FMovers do
    if (Mover.Brush.Entity = E) and (Mover.Kind = mkDoor) then
    begin
      { idDoor::Event_Activate: unlock, else open / close }
      if Mover.Locked then
        Mover.Locked := False
      else
      if Mover.State in [dsClosed, dsClosing] then
        Mover.Open
      else
        Mover.Close;
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
      Mover.Open;
    Mover.Update(SecondsPassed);
    { a shut door closes its area portal (like idDoor) }
    if FMap.Portals <> nil then
      for P in Mover.Portals do
        FMap.Portals.PortalClosed[P] := Mover.State = dsClosed;
  end;
  for Mon in FMonsters do
    UpdateMonster(Mon, SecondsPassed, Feet);
  UpdateTriggers(Feet);
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
