{ Doom 3 gameplay on top of TDoom3Map: doors that open when you come near
  (idDoor), func_rotating, speakers playing sound shaders, md5 creatures
  that chase and claw the player (a tiny idAI), the player's pistol, health,
  flashlight and death.

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
    function Position: TVector3;
    function Center: TVector3;
  end;

  TD3Speaker = class
    Transform: TCastleTransform;
    Source: TCastleSoundSource;
    destructor Destroy; override;
  end;

  TD3Game = class
  strict private
    FMap: TDoom3Map;
    FMovers: specialize TObjectList<TD3Mover>;
    FMonsters: specialize TObjectList<TD3Monster>;
    FSpeakers: specialize TObjectList<TD3Speaker>;
    FSounds: specialize TObjectDictionary<String, TCastleSound>;
    FOnMessage: TD3MessageEvent;
    FFireCooldown: Single;
    FDeadTime: Single;
    procedure Message(const S: String);
    function SoundFromShader(const ShaderName: String): TCastleSound;
    procedure SpawnMover(const B: TD3BrushEntity);
    procedure SpawnSpeaker(const E: TD3MapEntity);
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
    { Seconds the player has been dead. }
    property DeadTime: Single read FDeadTime;
    property Movers: specialize TObjectList<TD3Mover> read FMovers;
    property Monsters: specialize TObjectList<TD3Monster> read FMonsters;
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
  Doom3Files, Doom3Md5;

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
  Health := 100;
end;

destructor TD3Game.Destroy;
begin
  Clear;
  FMovers.Free;
  FMonsters.Free;
  FSpeakers.Free;
  FSounds.Free;
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
  S.Transform := TCastleTransform.Create(nil);
  S.Transform.Name := 'Speaker_' + IntToStr(FSpeakers.Count);
  S.Transform.Translation := D3ToCge(E.Origin);
  S.Source := TCastleSoundSource.Create(S.Transform);
  S.Source.Spatial := not E.BoolValue('s_global');
  S.Transform.AddBehavior(S.Source);
  FMap.Add(S.Transform);
  Shader := Decls.SoundShader(E.Value('s_shader'));
  if (Shader <> nil) and (Shader.Looping or E.BoolValue('s_looping')) then
  begin
    if not E.BoolValue('s_waitfortrigger') then
      S.Source.Sound := Snd;
  end else
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
    if (Copy(Cls, 1, 8) <> 'monster_') then
      Continue;
    Mon := TD3Monster.Create;
    Mon.Model := ME;
    Mon.Health := 50;
    if ME.EntityDef <> nil then
      Mon.Health := StrToIntDef(ME.EntityDef.Values['health'], 50);
    Mon.Health := ME.Entity.IntValue('health', Mon.Health);
    Mon.Radius := 20;
    Mon.Height := 72;
    Mon.Yaw := ME.Entity.Angle;
    if ME.Entity.Value('anim') <> '' then
      ME.Instance.PlayAnim(ME.Entity.Value('anim'));
    FMonsters.Add(Mon);
  end;
  if FMap.MapFile <> nil then
    for E in FMap.MapFile.Entities do
      if SameText(E.ClassName_, 'speaker') then
        SpawnSpeaker(E);
  WritelnLog('Doom3World', 'Spawned %d movers, %d monsters, %d speakers',
    [FMovers.Count, FMonsters.Count, FSpeakers.Count]);
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
      if (not NoTarget) and not PlayerDead and (Dist < MonsterSightRange) and
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
