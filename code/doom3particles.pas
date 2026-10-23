{ Doom 3 particle systems (particles/*.prt, idDeclParticle) and FX decls
  (fx/*.fx, idDeclFX).

  A particle decl has stages; each stage emits Count particles of a
  material, each living Time seconds, spread over the stage's cycle
  (Bunching) and repeating every Time + DeadTime seconds (Cycles times,
  0 = forever). A particle's state at an age is a pure function of its
  index, cycle and the stage's random distribution, like Doom 3 computes
  it every frame (nothing is simulated): its origin (the distribution
  box / cylinder / sphere, plus the direction cone times the integrated
  speed, plus gravity), its size, aspect, rotation and color (fading in,
  out and by index), its texture frame. Particles live in their emitter's
  space (origin and axis in Doom 3 coordinates); view-oriented ones face
  the camera.

  TD3ParticleEmitter draws a decl as a scene: a two-sided quad set per
  stage, rebuilt every frame in world space (CGE coordinates), with the
  material's blended stage and per-vertex colors. Doom 3's smoke streams
  (a projectile's trail, muzzle smoke) come from recording where a
  particle was spawned: a moving emitter leaves its particles behind.

  Not done: custom paths other than the standard one are approximated
  (helix, flies, orbit, drip), depthHack, boundsExpansion, decals. }
unit Doom3Particles;

{$mode objfpc}{$H+}{$modeswitch advancedrecords}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleVectors, CastleScene, CastleTransform, CastleRenderOptions, X3DNodes,
  Doom3Expressions;

type
  TD3ParticleDistribution = (pdRect, pdCylinder, pdSphere);
  TD3ParticleDirection = (pdirCone, pdirOutward);
  TD3ParticleOrientation = (poView, poAimed, poX, poY, poZ);
  TD3ParticlePath = (ppStandard, ppHelix, ppFlies, ppOrbit, ppDrip);

  { idParticleParm: a value changing over a particle's life ("from" to
    "to"), or a table of the life's fraction. }
  TD3ParticleParm = record
    From, To_: Single;
    Table: TD3Table; { owned by Decls, nil for from / to }
    TableName: String;
    function Eval(const Frac: Single): Single;
    { The integral from 0 to Frac (normalized time); tables can't be
      integrated (Doom 3 warns), 0. }
    function Integrate(const Frac: Single): Single;
  end;

  TD3ParticleStage = class
    Material: String;
    Count: Integer;
    { seconds: a particle's life, the dead time after the cycle, the stage's
      delay }
    Time, DeadTime, TimeOffset: Single;
    { 0: repeat forever }
    Cycles: Integer;
    { 1: spawns spread over the life, 0: all at once }
    Bunching: Single;
    Gravity: Single;
    WorldGravity: Boolean;
    Color, FadeColor: TVector4;
    FadeIn, FadeOut, FadeIndex: Single;
    Offset: TVector3;
    Speed, Rotation, Size, Aspect: TD3ParticleParm;
    { 0: random }
    InitialAngle: Single;
    Distribution: TD3ParticleDistribution;
    DistParms: array [0..3] of Single;
    Direction: TD3ParticleDirection;
    DirParm: Single;
    Orientation: TD3ParticleOrientation;
    { aimed: trail count, trail time }
    OrientParms: array [0..1] of Single;
    Path: TD3ParticlePath;
    PathParms: array [0..7] of Single;
    EntityColor, RandomDistribution: Boolean;
    BoundsExpansion: Single;
    AnimationFrames: Integer;
    AnimationRate: Single;
    constructor Create;
    { Time + DeadTime (at least a millisecond). }
    function CycleTime: Single;
  end;

  TD3ParticleDecl = class
    Name: String;
    DepthHack: Single;
    Stages: specialize TObjectList<TD3ParticleStage>;
    constructor Create;
    destructor Destroy; override;
    { Parse a particle decl body (the text between the braces). }
    procedure Parse(const Body: String);
    { The particles' total count over all stages. }
    function TotalCount: Integer;
  end;

  { A Doom 3 axis: the rows are the forward, left and up vectors. }
  TD3Axis = TMatrix3;

  { A particle system drawn in the world. Its Scene is a child of the
    transform it was created for (the map's root), at identity; the
    emitter's Origin and Axis (Doom 3 coordinates) place the particles. }
  TD3ParticleEmitter = class
  private
    type
      TStageState = record
        Shape: TShapeNode;
        Coord: TCoordinateNode;
        TexCoord: TTextureCoordinateNode;
        Colors: TColorRGBANode;
        { per index: the cycle it was spawned for (-1: never), and where }
        SpawnCycle: array of Integer;
        SpawnOrigin: array of TVector3;
        SpawnAxis: array of TD3Axis;
        Coords: TVector3List;
        UVs: TVector2List;
        ColorList: TVector4List;
      end;
    var
      FDecl: TD3ParticleDecl;
      FScene: TCastleScene;
      FStages: array of TStageState;
      FLive: Integer;
      FSeed: Cardinal;
      FEnabled: Boolean;
    procedure BuildScene;
    procedure SetEnabled(const Value: Boolean);
  public
    { Doom 3 coordinates. }
    Origin: TVector3;
    Axis: TD3Axis;
    { The game time the stages count from. }
    StartTime: Single;
    { The entity's color (shader parms 0..3) for stages with entityColor. }
    EntityColor: TVector4;
    { No new particles spawn: the live ones finish, then the emitter is
      Finished. }
    Stopped: Boolean;
    { Every stage plays one cycle (Doom 3's smoke systems), whatever its
      cycles say; Finished after the last particle. }
    OneShot: Boolean;
    { Who it belongs to (logs). }
    Name: String;
    { An entity's emitter: kept when Finished (it may be activated again). }
    Persistent: Boolean;
    constructor Create(const ADecl: TD3ParticleDecl; const AStartTime: Single);
    destructor Destroy; override;
    { Rebuild the particles for this game time, seen along ViewAxis
      (the camera's Doom 3 axis). }
    procedure Update(const Time: Single; const ViewAxis: TD3Axis);
    { Nothing left to show (and no more to come). }
    function Finished(const Time: Single): Boolean;
    { Forget where the particles were spawned (restarting an emitter). }
    procedure Reset;
    { Off: not drawn nor updated (an emitter entity turned off). }
    property Enabled: Boolean read FEnabled write SetEnabled;
    { Particles drawn by the last Update. }
    property Live: Integer read FLive;
    property Decl: TD3ParticleDecl read FDecl;
    property Scene: TCastleScene read FScene;
  end;

  TD3FxActionKind = (fxLight, fxParticle, fxModel, fxSound, fxDecal, fxShake, fxOther);

  { One action of an FX decl. }
  TD3FxAction = class
    Kind: TD3FxActionKind;
    { seconds after the FX starts, how long it lasts (0: the particle's
      own length), repeats every Duration when Restart <> 0 }
    Delay, Duration, Restart: Single;
    { random extra delay, min and max }
    RandomMin, RandomMax: Single;
    { the light's material, color and radius; the particle / model /
      sound / decal name }
    Data: String;
    LightColor: TVector3;
    LightRadius: Single;
    FadeIn, FadeOut: Single;
    Offset: TVector3;
    { the shake's time, amplitude, distance, falloff, impulse }
    ShakeParms: array [0..4] of Single;
    { the decal's size (0: Doom 3's default, 8) }
    Size: Single;
    { "trackorigin": follows the entity }
    TrackOrigin: Boolean;
    Name, Fire: String;
    constructor Create;
  end;

  TD3FxDecl = class
    Name: String;
    BindTo: String;
    Actions: specialize TObjectList<TD3FxAction>;
    constructor Create;
    destructor Destroy; override;
    procedure Parse(const Body: String);
  end;

{ A particle decl by name (particles/*.prt; "name.prt" works too, like
  Doom 3 strips the extension), cached; nil when missing. }
function ParticleDecl(const AName: String): TD3ParticleDecl;
{ An FX decl by name (fx/*.fx), cached; nil when missing. }
function FxDecl(const AName: String): TD3FxDecl;
{ Forget the cached decls (after Decls reload). }
procedure ClearParticleDecls;

{ The axis facing a direction (Doom 3 idVec3::ToMat3). }
function AxisFromDirection(const Dir: TVector3): TD3Axis;
{ A local vector in the axis' space (v * axis in Doom 3). }
function AxisToWorld(const A: TD3Axis; const V: TVector3): TVector3;
{ The axis whose rows are the identity. }
function IdentityAxis: TD3Axis;

var
  { Skip drawing particles (console r_skipParticles). }
  SkipParticles: Boolean = False;

implementation

uses
  Math,
  CastleLog, CastleUtils,
  Doom3Lexer, Doom3Decls, Doom3Materials, Doom3MapFile;

{ TD3ParticleParm }

function TD3ParticleParm.Eval(const Frac: Single): Single;
begin
  if Table <> nil then
    Result := Table.Lookup(Frac)
  else
    Result := From + Frac * (To_ - From);
end;

function TD3ParticleParm.Integrate(const Frac: Single): Single;
begin
  if Table <> nil then
    Exit(0);
  Result := (From + Frac * (To_ - From) * 0.5) * Frac;
end;

{ TD3ParticleStage }

constructor TD3ParticleStage.Create;
begin
  inherited;
  { idParticleStage::Default }
  Count := 100;
  Time := 1.5;
  Bunching := 1;
  Color := Vector4(1, 1, 1, 1);
  FadeColor := Vector4(0, 0, 0, 0);
  FadeIn := 0.1;
  FadeOut := 0.25;
  Speed.From := 150;
  Speed.To_ := 150;
  Size.From := 4;
  Size.To_ := 4;
  Aspect.From := 1;
  Aspect.To_ := 1;
  Distribution := pdRect;
  DistParms[0] := 8;
  DistParms[1] := 8;
  DistParms[2] := 8;
  Direction := pdirCone;
  DirParm := 90;
  Orientation := poView;
  AnimationFrames := 0;
  RandomDistribution := True;
  Gravity := 1;
end;

function TD3ParticleStage.CycleTime: Single;
begin
  Result := Max(0.001, Time + DeadTime);
end;

{ TD3ParticleDecl }

constructor TD3ParticleDecl.Create;
begin
  inherited;
  Stages := specialize TObjectList<TD3ParticleStage>.Create(True);
end;

destructor TD3ParticleDecl.Destroy;
begin
  FreeAndNil(Stages);
  inherited;
end;

function TD3ParticleDecl.TotalCount: Integer;
var
  S: TD3ParticleStage;
begin
  Result := 0;
  for S in Stages do
    Inc(Result, S.Count);
end;

procedure ParseParm(const Lexer: TDoom3Lexer; var P: TD3ParticleParm);
var
  T: String;
begin
  T := Lexer.NextStr;
  P.Table := nil;
  P.TableName := '';
  if (T <> '') and ((T[1] in ['0'..'9', '-', '.']) or (T = '-')) then
  begin
    if T = '-' then
      P.From := -D3StrToFloat(Lexer.NextStr)
    else
      P.From := D3StrToFloat(T);
  end else
  begin
    P.TableName := T;
    P.Table := Decls.Table(T);
    if P.Table = nil then
      WritelnWarning('Doom3Particles', 'Table "%s" not found', [T]);
    P.From := 0;
  end;
  if SameText(Lexer.Peek, 'to') then
  begin
    Lexer.NextStr;
    P.To_ := Lexer.ReadFloat;
  end else
    P.To_ := P.From;
end;

procedure ParseStage(const Lexer: TDoom3Lexer; const S: TD3ParticleStage);
var
  Tok: String;
  V: array [0..7] of Single;
  I: Integer;
begin
  while Lexer.Next(Tok) do
  begin
    if Tok = '}' then
      Exit;
    Tok := LowerCase(Tok);
    case Tok of
      'material': S.Material := Lexer.NextStr;
      'count': S.Count := Max(0, Lexer.ReadInt);
      'time': S.Time := Max(0.001, Lexer.ReadFloat);
      'cycles': S.Cycles := Max(0, Round(Lexer.ReadFloat));
      'timeoffset': S.TimeOffset := Lexer.ReadFloat;
      'deadtime': S.DeadTime := Max(0, Lexer.ReadFloat);
      'bunching': S.Bunching := EnsureRange(Lexer.ReadFloat, 0, 1);
      'color':
        begin
          Lexer.ReadVector(@V[0], 4);
          S.Color := Vector4(V[0], V[1], V[2], V[3]);
        end;
      'fadecolor':
        begin
          Lexer.ReadVector(@V[0], 4);
          S.FadeColor := Vector4(V[0], V[1], V[2], V[3]);
        end;
      'fadein': S.FadeIn := Lexer.ReadFloat;
      'fadeout': S.FadeOut := Lexer.ReadFloat;
      'fadeindex': S.FadeIndex := Lexer.ReadFloat;
      'offset':
        begin
          Lexer.ReadVector(@V[0], 3);
          S.Offset := Vector3(V[0], V[1], V[2]);
        end;
      'speed': ParseParm(Lexer, S.Speed);
      'rotation': ParseParm(Lexer, S.Rotation);
      'size': ParseParm(Lexer, S.Size);
      'aspect': ParseParm(Lexer, S.Aspect);
      'initialangle': S.InitialAngle := Lexer.ReadFloat;
      'gravity':
        begin
          S.WorldGravity := SameText(Lexer.Peek, 'world');
          if S.WorldGravity then
            Lexer.NextStr;
          S.Gravity := Lexer.ReadFloat;
        end;
      'entitycolor': S.EntityColor := Lexer.ReadFloat <> 0;
      'randomdistribution': S.RandomDistribution := Lexer.ReadFloat <> 0;
      'boundsexpansion': S.BoundsExpansion := Lexer.ReadFloat;
      'animationframes': S.AnimationFrames := Lexer.ReadInt;
      'animationrate': S.AnimationRate := Lexer.ReadFloat;
      'distribution':
        begin
          Tok := LowerCase(Lexer.NextStr);
          for I := 0 to 3 do
            S.DistParms[I] := 0;
          if Tok = 'rect' then
          begin
            S.Distribution := pdRect;
            Lexer.ReadVector(@S.DistParms[0], 3);
          end else
          if Tok = 'cylinder' then
          begin
            S.Distribution := pdCylinder;
            Lexer.ReadVector(@S.DistParms[0], 3);
            if (Lexer.Peek <> '') and (Lexer.Peek[1] in ['0'..'9', '-', '.']) then
              S.DistParms[3] := Lexer.ReadFloat;
          end else
          if Tok = 'sphere' then
          begin
            S.Distribution := pdSphere;
            Lexer.ReadVector(@S.DistParms[0], 3);
            if (Lexer.Peek <> '') and (Lexer.Peek[1] in ['0'..'9', '-', '.']) then
              S.DistParms[3] := Lexer.ReadFloat;
          end else
            WritelnWarning('Doom3Particles', 'Unknown distribution "%s"', [Tok]);
        end;
      'direction':
        begin
          Tok := LowerCase(Lexer.NextStr);
          if Tok = 'cone' then
            S.Direction := pdirCone
          else
          if Tok = 'outward' then
            S.Direction := pdirOutward
          else
            WritelnWarning('Doom3Particles', 'Unknown direction "%s"', [Tok]);
          S.DirParm := Lexer.ReadFloat;
        end;
      'orientation':
        begin
          Tok := LowerCase(Lexer.NextStr);
          S.OrientParms[0] := 0;
          S.OrientParms[1] := 0;
          if Tok = 'view' then
            S.Orientation := poView
          else
          if Tok = 'aimed' then
          begin
            S.Orientation := poAimed;
            for I := 0 to 1 do
              if (Lexer.Peek <> '') and (Lexer.Peek[1] in ['0'..'9', '-', '.']) then
                S.OrientParms[I] := Lexer.ReadFloat;
          end else
          if Tok = 'x' then
            S.Orientation := poX
          else
          if Tok = 'y' then
            S.Orientation := poY
          else
          if Tok = 'z' then
            S.Orientation := poZ
          else
            WritelnWarning('Doom3Particles', 'Unknown orientation "%s"', [Tok]);
        end;
      'custompath':
        begin
          Tok := LowerCase(Lexer.NextStr);
          for I := 0 to 7 do
            S.PathParms[I] := 0;
          if Tok = 'standard' then
            S.Path := ppStandard
          else
          if Tok = 'helix' then
          begin
            S.Path := ppHelix;
            Lexer.ReadVector(@S.PathParms[0], 5);
          end else
          if Tok = 'flies' then
          begin
            S.Path := ppFlies;
            Lexer.ReadVector(@S.PathParms[0], 3);
          end else
          if Tok = 'orbit' then
          begin
            S.Path := ppOrbit;
            Lexer.ReadVector(@S.PathParms[0], 2);
          end else
          if Tok = 'drip' then
          begin
            S.Path := ppDrip;
            Lexer.ReadVector(@S.PathParms[0], 2);
          end else
            WritelnWarning('Doom3Particles', 'Unknown customPath "%s"', [Tok]);
        end;
      else
        WritelnWarning('Doom3Particles', 'Unknown particle stage keyword "%s"', [Tok]);
    end;
  end;
end;

procedure TD3ParticleDecl.Parse(const Body: String);
var
  Lexer: TDoom3Lexer;
  Tok: String;
  S: TD3ParticleStage;
begin
  Stages.Clear;
  Lexer := TDoom3Lexer.Create(Body);
  try
    while Lexer.Next(Tok) do
    begin
      if Tok = '{' then
      begin
        S := TD3ParticleStage.Create;
        Stages.Add(S);
        ParseStage(Lexer, S);
      end else
      if SameText(Tok, 'depthHack') then
        DepthHack := Lexer.ReadFloat
      else
      if Tok = '}' then
        Break;
    end;
  finally
    Lexer.Free;
  end;
end;

{ Deterministic random numbers per particle (Doom 3 seeds idRandom by the
  particle's index and cycle, so a particle looks the same every frame). }
type
  TParticleRandom = record
    State: Cardinal;
    procedure Seed(const A, B, C: Cardinal);
    { 0 .. 1 }
    function Next: Single;
    { -1 .. 1 }
    function CNext: Single;
  end;

procedure TParticleRandom.Seed(const A, B, C: Cardinal);
begin
  { wrapping 32 bit arithmetic (also with range checks on) }
  State := Cardinal((QWord(A) * 2654435761) and $FFFFFFFF) xor
    Cardinal((QWord(B) * 40503 + 7919) and $FFFFFFFF) xor
    Cardinal((QWord(C) * 104729 + 1) and $FFFFFFFF);
  if State = 0 then
    State := 1;
  Next;
end;

function TParticleRandom.Next: Single;
begin
  { xorshift32 }
  State := State xor (State shl 13);
  State := State xor (State shr 17);
  State := State xor (State shl 5);
  Result := (State and $FFFFFF) / $1000000;
end;

function TParticleRandom.CNext: Single;
begin
  Result := 2 * Next - 1;
end;

{ Helpers }

function IdentityAxis: TD3Axis;
begin
  Result := TMatrix3.Identity;
end;

function AxisFromDirection(const Dir: TVector3): TD3Axis;
begin
  if Dir.IsZero then
    Exit(TMatrix3.Identity);
  Result := AnglesMatrix(Vector3(
    -RadToDeg(ArcTan2(Dir.Z, Sqrt(Sqr(Dir.X) + Sqr(Dir.Y)))),
    RadToDeg(ArcTan2(Dir.Y, Dir.X)), 0));
end;

{ A local vector in the axis' space (v * axis in Doom 3). }
function AxisToWorld(const A: TD3Axis; const V: TVector3): TVector3;
begin
  Result := Vector3(
    V.X * A.Data[0, 0] + V.Y * A.Data[1, 0] + V.Z * A.Data[2, 0],
    V.X * A.Data[0, 1] + V.Y * A.Data[1, 1] + V.Z * A.Data[2, 1],
    V.X * A.Data[0, 2] + V.Y * A.Data[1, 2] + V.Z * A.Data[2, 2]);
end;

{ A world vector in the axis' space (axis.ProjectVector). }
function WorldToAxis(const A: TD3Axis; const V: TVector3): TVector3;
begin
  Result := Vector3(
    V.X * A.Data[0, 0] + V.Y * A.Data[0, 1] + V.Z * A.Data[0, 2],
    V.X * A.Data[1, 0] + V.Y * A.Data[1, 1] + V.Z * A.Data[1, 2],
    V.X * A.Data[2, 0] + V.Y * A.Data[2, 1] + V.Z * A.Data[2, 2]);
end;

function AxisRow(const A: TD3Axis; const Row: Integer): TVector3;
begin
  Result := Vector3(A.Data[Row, 0], A.Data[Row, 1], A.Data[Row, 2]);
end;

{ idParticleStage::ParticleOrigin: a particle's position in the emitter's
  space at Age (seconds) / Frac of its life, from its random numbers. }
function ParticleOrigin(const S: TD3ParticleStage; const Seed: TParticleRandom;
  const Age, Frac: Single; const SpawnAxis: TD3Axis): TVector3;
var
  R: TParticleRandom;
  Origin, Dir, G: TVector3;
  Angle1, Angle2, RadiusSqr, F, S1, C1, S2, C2, ISpeed: Single;
  I: Integer;
begin
  R := Seed;
  Origin := TVector3.Zero;
  if S.Path = ppStandard then
  begin
    case S.Distribution of
      pdRect:
        for I := 0 to 2 do
          if S.RandomDistribution then
            Origin.Data[I] := R.CNext * S.DistParms[I]
          else
            Origin.Data[I] := S.DistParms[I];
      pdCylinder:
        begin
          if S.RandomDistribution then
            Angle1 := R.CNext * 2 * Pi
          else
            Angle1 := 2 * Pi;
          SinCos(Angle1, Origin.Data[0], Origin.Data[1]);
          if S.RandomDistribution then
            Origin.Z := R.CNext
          else
            Origin.Z := 1;
          { Doom 3 puts them on the cylinder's wall: the ring fraction has
            nothing to push outward }
          for I := 0 to 2 do
            Origin.Data[I] := Origin.Data[I] * S.DistParms[I];
        end;
      pdSphere:
        begin
          if S.RandomDistribution then
          begin
            repeat
              Origin := Vector3(R.CNext, R.CNext, R.CNext);
              RadiusSqr := Origin.LengthSqr;
            until RadiusSqr <= 1;
          end else
          begin
            Origin := Vector3(1, 1, 1);
            RadiusSqr := 3;
          end;
          if (S.DistParms[3] > 0) and (RadiusSqr < Sqr(S.DistParms[3])) and (RadiusSqr > 0) then
          begin
            { inside the ring: pushed out to it }
            F := Sqrt(RadiusSqr) / S.DistParms[3];
            Origin := Origin * (1 / F);
          end;
          for I := 0 to 2 do
            Origin.Data[I] := Origin.Data[I] * S.DistParms[I];
        end;
    end;
    Origin := Origin + S.Offset;
    case S.Direction of
      pdirCone:
        begin
          Angle1 := DegToRad(R.CNext * S.DirParm);
          Angle2 := R.CNext * Pi;
          SinCos(Angle1, S1, C1);
          SinCos(Angle2, S2, C2);
          Dir := Vector3(S1 * C2, S1 * S2, C1);
        end;
      else
        begin
          Dir := Origin;
          if not Dir.IsZero then
            Dir := Dir.Normalize;
          Dir.Z := Dir.Z + S.DirParm;
        end;
    end;
    ISpeed := S.Speed.Integrate(Frac);
    Origin := Origin + Dir * (ISpeed * S.Time);
  end else
  begin
    { custom paths, approximately }
    case S.Path of
      ppHelix:
        begin
          { sizeX sizeY sizeZ radialSpeed axialSpeed }
          Angle1 := R.Next * 2 * Pi + DegToRad(S.PathParms[3]) * Age;
          Origin := Vector3(Cos(Angle1) * S.PathParms[0], Sin(Angle1) * S.PathParms[1],
            R.CNext * S.PathParms[2] + S.PathParms[4] * Age);
        end;
      ppFlies:
        begin
          { radialSpeed axialSpeed size }
          Angle1 := R.Next * 2 * Pi + DegToRad(S.PathParms[0]) * Age;
          Angle2 := R.Next * 2 * Pi + DegToRad(S.PathParms[1]) * Age;
          Origin := Vector3(Cos(Angle1) * Sin(Angle2), Sin(Angle1) * Sin(Angle2), Cos(Angle2)) * S.PathParms[2];
        end;
      ppOrbit:
        begin
          { radius speed }
          Angle1 := R.Next * 2 * Pi + DegToRad(S.PathParms[1]) * Age;
          Origin := Vector3(Cos(Angle1) * S.PathParms[0], Sin(Angle1) * S.PathParms[0], 0);
        end;
      ppDrip:
        begin
          { speed size }
          Origin := Vector3(R.CNext * S.PathParms[1], R.CNext * S.PathParms[1], -S.PathParms[0] * Age);
        end;
      else ;
    end;
    Origin := Origin + S.Offset;
  end;
  if S.Gravity <> 0 then
  begin
    if S.WorldGravity then
    begin
      G := WorldToAxis(SpawnAxis, Vector3(0, 0, -S.Gravity));
      Origin := Origin + G * (Age * Age);
    end else
      Origin.Z := Origin.Z - S.Gravity * Age * Age;
  end;
  Result := Origin;
end;

{ TD3ParticleEmitter }

constructor TD3ParticleEmitter.Create(const ADecl: TD3ParticleDecl; const AStartTime: Single);
begin
  inherited Create;
  FDecl := ADecl;
  StartTime := AStartTime;
  Axis := TMatrix3.Identity;
  EntityColor := Vector4(1, 1, 1, 1);
  FSeed := Random($7FFFFFFF);
  FEnabled := True;
  BuildScene;
end;

procedure TD3ParticleEmitter.SetEnabled(const Value: Boolean);
begin
  FEnabled := Value;
  if not Value then
  begin
    FScene.Exists := False;
    FLive := 0;
  end;
end;

procedure TD3ParticleEmitter.Reset;
var
  I, J: Integer;
begin
  for I := 0 to High(FStages) do
    for J := 0 to High(FStages[I].SpawnCycle) do
      FStages[I].SpawnCycle[J] := -1;
end;

destructor TD3ParticleEmitter.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FStages) do
  begin
    FreeAndNil(FStages[I].Coords);
    FreeAndNil(FStages[I].UVs);
    FreeAndNil(FStages[I].ColorList);
  end;
  if (FScene <> nil) and (FScene.Parent <> nil) then
    FScene.Parent.Remove(FScene);
  FreeAndNil(FScene);
  inherited;
end;

procedure TD3ParticleEmitter.BuildScene;
var
  Root: TX3DRootNode;
  I, J: Integer;
  S: TD3ParticleStage;
  Quads: TQuadSetNode;
  App: TAppearanceNode;
begin
  Root := TX3DRootNode.Create;
  SetLength(FStages, FDecl.Stages.Count);
  for I := 0 to FDecl.Stages.Count - 1 do
  begin
    S := FDecl.Stages[I];
    FStages[I].Coords := TVector3List.Create;
    FStages[I].UVs := TVector2List.Create;
    FStages[I].ColorList := TVector4List.Create;
    SetLength(FStages[I].SpawnCycle, S.Count);
    SetLength(FStages[I].SpawnOrigin, S.Count);
    SetLength(FStages[I].SpawnAxis, S.Count);
    for J := 0 to S.Count - 1 do
      FStages[I].SpawnCycle[J] := -1;
    FStages[I].Coord := TCoordinateNode.Create;
    FStages[I].TexCoord := TTextureCoordinateNode.Create;
    FStages[I].Colors := TColorRGBANode.Create;
    { the stage's color registers still apply (animated materials) }
    FStages[I].Colors.Mode := cmModulate;
    Quads := TQuadSetNode.Create;
    Quads.Coord := FStages[I].Coord;
    Quads.TexCoord := FStages[I].TexCoord;
    Quads.Color := FStages[I].Colors;
    Quads.Solid := False;
    Quads.Ccw := True;
    App := MaterialAppearance(S.Material);
    App.ShadowCaster := False;
    FStages[I].Shape := TShapeNode.Create;
    FStages[I].Shape.Geometry := Quads;
    FStages[I].Shape.Appearance := App;
    Root.AddChildren(FStages[I].Shape);
  end;
  FScene := TCastleScene.Create(nil);
  FScene.Name := 'Particles';
  FScene.Load(Root, True);
  FScene.Collides := False;
  FScene.Pickable := False;
  FScene.CastShadows := False;
end;

procedure TD3ParticleEmitter.Update(const Time: Single; const ViewAxis: TD3Axis);
var
  I, Index, PCycle, EffCycles, Trail, NumTrails, IntFrame, K: Integer;
  S: TD3ParticleStage;
  St: ^TStageState;
  StageAge, PAge, PCycleTime, Frac, Fade, IndexFrac, BunchOffset: Single;
  PSize, PAspect, Angle, AngleMove, C, SinA, CosA, TexS, TexWidth, TexT, TexHeight, TrailTime: Single;
  Color: TVector4;
  R, AngleR: TParticleRandom;
  POrigin, OldOrigin, StepOrigin, Left, Up, Fwd, ViewLeft, ViewUp, LocalLeft, LocalUp: TVector3;
  SpawnAxis: TD3Axis;
  SpawnOrigin: TVector3;

  procedure AddVertex(const Local: TVector3; const U, V: Single);
  begin
    St^.Coords.Add(D3ToCge(SpawnOrigin + AxisToWorld(SpawnAxis, Local)));
    St^.UVs.Add(Vector2(U, 1 - V));
    St^.ColorList.Add(Color);
  end;

  { a quad: top-left, bottom-left, bottom-right, top-right (facing the
    viewer counter-clockwise, two-sided anyway) }
  procedure AddQuad(const A, B, C, D: TVector3; const S0, T0, S1, T1: Single);
  begin
    AddVertex(A, S0, T0);
    AddVertex(C, S0, T1);
    AddVertex(D, S1, T1);
    AddVertex(B, S1, T0);
  end;

begin
  FLive := 0;
  if SkipParticles or not FEnabled then
  begin
    FScene.Exists := False;
    Exit;
  end;
  FScene.Exists := True;
  for I := 0 to FDecl.Stages.Count - 1 do
  begin
    S := FDecl.Stages[I];
    St := @FStages[I];
    St^.Coords.Clear;
    St^.UVs.Clear;
    St^.ColorList.Clear;
    StageAge := Time - StartTime - S.TimeOffset;
    EffCycles := S.Cycles;
    if OneShot and (EffCycles = 0) then
      EffCycles := 1;
    if (StageAge >= 0) and (S.Count > 0) then
    begin
      for Index := 0 to S.Count - 1 do
        begin
          BunchOffset := S.Time * S.Bunching * Index / S.Count;
          PAge := StageAge - BunchOffset;
          PCycle := Floor(PAge / S.CycleTime);
          if PCycle < 0 then
            Continue;
          if (EffCycles > 0) and (PCycle >= EffCycles) then
            Continue;
          PCycleTime := PAge - PCycle * S.CycleTime;
          if PCycleTime > S.Time then
            Continue;
          Frac := PCycleTime / S.Time;
          { where it was spawned (a moving emitter leaves a trail) }
          if St^.SpawnCycle[Index] <> PCycle then
          begin
            if Stopped then
              Continue;
            St^.SpawnCycle[Index] := PCycle;
            St^.SpawnOrigin[Index] := Origin;
            St^.SpawnAxis[Index] := Axis;
          end;
          SpawnOrigin := St^.SpawnOrigin[Index];
          SpawnAxis := St^.SpawnAxis[Index];
          R.Seed(FSeed + Cardinal(I) * 977, Cardinal(Index), Cardinal(PCycle));

          { color }
          Fade := 1;
          if (S.FadeIn > 0) and (Frac < S.FadeIn) then
            Fade := Fade * (Frac / S.FadeIn);
          if (S.FadeOut > 0) and (1 - Frac < S.FadeOut) then
            Fade := Fade * ((1 - Frac) / S.FadeOut);
          if S.FadeIndex > 0 then
          begin
            IndexFrac := (S.Count - Index) / S.Count;
            if IndexFrac < S.FadeIndex then
              Fade := Fade * (IndexFrac / S.FadeIndex);
          end;
          if S.EntityColor then
            Color := EntityColor * Fade + S.FadeColor * (1 - Fade)
          else
            Color := S.Color * Fade + S.FadeColor * (1 - Fade);
          for K := 0 to 3 do
            Color.Data[K] := EnsureRange(Color.Data[K], 0, 1);
          if Color.IsZero then
            Continue;

          POrigin := ParticleOrigin(S, R, PCycleTime, Frac, SpawnAxis);

          { texture frame }
          if S.AnimationFrames > 1 then
          begin
            TexWidth := 1 / S.AnimationFrames;
            if S.AnimationRate <> 0 then
              IntFrame := Trunc(PCycleTime * S.AnimationRate)
            else
              IntFrame := Trunc(Frac * S.AnimationFrames);
            IntFrame := IntFrame mod S.AnimationFrames;
            TexS := TexWidth * IntFrame;
          end else
          begin
            TexS := 0;
            TexWidth := 1;
          end;

          PSize := S.Size.Eval(Frac);
          PAspect := S.Aspect.Eval(Frac);
          Fwd := WorldToAxis(SpawnAxis, AxisRow(ViewAxis, 0));
          if S.Orientation = poAimed then
          begin
            { a strip along the direction of travel, over the trails }
            NumTrails := Trunc(S.OrientParms[0]);
            TrailTime := S.OrientParms[1];
            if TrailTime = 0 then
              TrailTime := 0.5;
            TexHeight := 1 / (1 + NumTrails);
            TexT := 0;
            StepOrigin := POrigin;
            for Trail := 0 to NumTrails do
            begin
              PAge := PCycleTime - (Trail + 1) * TrailTime / (NumTrails + 1);
              OldOrigin := ParticleOrigin(S, R, PAge, PAge / S.Time, SpawnAxis);
              Up := StepOrigin - OldOrigin;
              Up := Up - Fwd * TVector3.DotProduct(Up, Fwd);
              if Up.IsZero then
                Up := Vector3(0, 0, 1)
              else
                Up := Up.Normalize;
              Left := TVector3.CrossProduct(Up, Fwd) * PSize;
              AddQuad(StepOrigin - Left, StepOrigin + Left, OldOrigin - Left, OldOrigin + Left,
                TexS, TexT, TexS + TexWidth, TexT + TexHeight);
              TexT := TexT + TexHeight;
              StepOrigin := OldOrigin;
            end;
          end else
          begin
            AngleR.Seed(FSeed + Cardinal(I) * 977 + 31337, Cardinal(Index), Cardinal(PCycle));
            if S.InitialAngle <> 0 then
              Angle := S.InitialAngle
            else
              Angle := 360 * AngleR.Next;
            AngleMove := S.Rotation.Integrate(Frac) * S.Time;
            { half the particles turn each way }
            if Index and 1 = 1 then
              Angle := Angle + AngleMove
            else
              Angle := Angle - AngleMove;
            SinCos(DegToRad(Angle), SinA, CosA);
            C := CosA;
            case S.Orientation of
              poZ:
                begin
                  Left := Vector3(SinA, C, 0);
                  Up := Vector3(C, -SinA, 0);
                end;
              poX:
                begin
                  Left := Vector3(0, C, SinA);
                  Up := Vector3(0, -SinA, C);
                end;
              poY:
                begin
                  Left := Vector3(C, 0, SinA);
                  Up := Vector3(-SinA, 0, C);
                end;
              else
                begin
                  ViewLeft := AxisRow(ViewAxis, 1);
                  ViewUp := AxisRow(ViewAxis, 2);
                  LocalLeft := WorldToAxis(SpawnAxis, ViewLeft);
                  LocalUp := WorldToAxis(SpawnAxis, ViewUp);
                  Left := LocalLeft * C + LocalUp * SinA;
                  Up := LocalUp * C - LocalLeft * SinA;
                end;
            end;
            Left := Left * PSize;
            Up := Up * (PSize * PAspect);
            AddQuad(POrigin - Left + Up, POrigin + Left + Up, POrigin - Left - Up, POrigin + Left - Up,
              TexS, 0, TexS + TexWidth, 1);
          end;
          Inc(FLive);
        end;
    end;
    St^.Coord.SetPoint(St^.Coords);
    St^.TexCoord.SetPoint(St^.UVs);
    St^.Colors.SetColor(St^.ColorList);
  end;
end;

function TD3ParticleEmitter.Finished(const Time: Single): Boolean;
var
  S: TD3ParticleStage;
  I: Integer;
  EffCycles: Integer;
  StageAge, LastEnd: Single;
begin
  if Stopped then
    Exit(FLive = 0);
  for I := 0 to FDecl.Stages.Count - 1 do
  begin
    S := FDecl.Stages[I];
    EffCycles := S.Cycles;
    if OneShot and (EffCycles = 0) then
      EffCycles := 1;
    if EffCycles = 0 then
      Exit(False);
    { the last particle of the last cycle dies at }
    LastEnd := S.TimeOffset + (EffCycles - 1) * S.CycleTime + S.Time * S.Bunching + S.Time;
    StageAge := Time - StartTime;
    if StageAge <= LastEnd then
      Exit(False);
  end;
  Result := True;
end;

{ TD3FxAction }

constructor TD3FxAction.Create;
begin
  inherited;
  Kind := fxOther;
  LightColor := Vector3(1, 1, 1);
end;

{ TD3FxDecl }

constructor TD3FxDecl.Create;
begin
  inherited;
  Actions := specialize TObjectList<TD3FxAction>.Create(True);
end;

destructor TD3FxDecl.Destroy;
begin
  FreeAndNil(Actions);
  inherited;
end;

procedure ParseFxAction(const Lexer: TDoom3Lexer; const A: TD3FxAction);
var
  Tok: String;
  V: array [0..4] of Single;
  I: Integer;
begin
  while Lexer.Next(Tok) do
  begin
    if Tok = '}' then
      Exit;
    case LowerCase(Tok) of
      'delay': A.Delay := Lexer.ReadFloat;
      'duration': A.Duration := Lexer.ReadFloat;
      'restart': A.Restart := Lexer.ReadFloat;
      'random':
        begin
          A.RandomMin := Lexer.ReadFloat;
          A.RandomMax := Lexer.ReadFloat;
        end;
      'name': A.Name := Lexer.NextStr;
      'fire': A.Fire := Lexer.NextStr;
      'fadein': A.FadeIn := Lexer.ReadFloat;
      'fadeout': A.FadeOut := Lexer.ReadFloat;
      'offset':
        begin
          Lexer.ReadVector(@V[0], 3);
          A.Offset := Vector3(V[0], V[1], V[2]);
        end;
      'trackorigin': A.TrackOrigin := Lexer.ReadFloat <> 0;
      'light':
        begin
          A.Kind := fxLight;
          A.Data := Lexer.NextStr;
          Lexer.Check(',');
          for I := 0 to 3 do
          begin
            V[I] := Lexer.ReadFloat;
            Lexer.Check(',');
          end;
          A.LightColor := Vector3(V[0], V[1], V[2]);
          A.LightRadius := V[3];
        end;
      'model':
        begin
          A.Data := Lexer.NextStr;
          if SameText(ExtractFileExt(A.Data), '.prt') then
            A.Kind := fxModel
          else
            A.Kind := fxOther;
        end;
      'particle':
        begin
          A.Kind := fxParticle;
          A.Data := Lexer.NextStr;
        end;
      'sound':
        begin
          A.Kind := fxSound;
          A.Data := Lexer.NextStr;
        end;
      'decal':
        begin
          A.Kind := fxDecal;
          A.Data := Lexer.NextStr;
        end;
      'shake':
        begin
          A.Kind := fxShake;
          for I := 0 to 4 do
          begin
            A.ShakeParms[I] := Lexer.ReadFloat;
            Lexer.Check(',');
          end;
        end;
      'size':
        A.Size := Lexer.ReadFloat;
      { known keywords without an effect here }
      'attenuate', 'axis', 'angle', 'shockwave', 'uselight', 'usemodel',
      'attachlight', 'attachentity', 'launch', 'ignoremaster', 'shakestart',
      'shakeignoremaster', 'rotate', 'particletrackvelocity', 'bindto', 'nolightshadows':
        begin
          { skip its arguments: the rest of the line }
          Lexer.SkipLine;
        end;
      else
        Lexer.SkipLine;
    end;
  end;
end;

procedure TD3FxDecl.Parse(const Body: String);
var
  Lexer: TDoom3Lexer;
  Tok: String;
  A: TD3FxAction;
begin
  Actions.Clear;
  Lexer := TDoom3Lexer.Create(Body);
  try
    while Lexer.Next(Tok) do
    begin
      if Tok = '{' then
      begin
        A := TD3FxAction.Create;
        Actions.Add(A);
        ParseFxAction(Lexer, A);
      end else
      if SameText(Tok, 'bindto') then
        BindTo := Lexer.NextStr
      else
      if Tok = '}' then
        Break;
    end;
  finally
    Lexer.Free;
  end;
end;

{ caches }

var
  ParticleCache: specialize TObjectDictionary<String, TD3ParticleDecl>;
  FxCache: specialize TObjectDictionary<String, TD3FxDecl>;
  ClearHookAdded: Boolean;

procedure EnsureClearHook;
begin
  if (not ClearHookAdded) and (Decls <> nil) then
  begin
    ClearHookAdded := True;
    Decls.AddClearHook(@ClearParticleDecls);
  end;
end;

function CanonicalName(const AName: String): String;
var
  P: Integer;
begin
  Result := LowerCase(StringReplace(AName, '\', '/', [rfReplaceAll]));
  { Doom 3 strips the extension from decl names (x.prt) }
  P := LastDelimiter('.', Result);
  if (P > 0) and (P > LastDelimiter('/', Result)) then
    Result := Copy(Result, 1, P - 1);
end;

function ParticleDecl(const AName: String): TD3ParticleDecl;
var
  Key, Body: String;
begin
  Key := CanonicalName(AName);
  if Key = '' then
    Exit(nil);
  EnsureClearHook;
  if ParticleCache.TryGetValue(Key, Result) then
    Exit;
  Result := nil;
  if (Decls <> nil) and (Decls.DeclBody(dtParticle, Key, Body) or Decls.DeclBody(dtParticle, Key + '.prt', Body)) then
  begin
    Result := TD3ParticleDecl.Create;
    Result.Name := Key;
    Result.Parse(Body);
  end;
  ParticleCache.Add(Key, Result);
end;

function FxDecl(const AName: String): TD3FxDecl;
var
  Key, Body: String;
begin
  Key := LowerCase(StringReplace(AName, '\', '/', [rfReplaceAll]));
  if Key = '' then
    Exit(nil);
  EnsureClearHook;
  if FxCache.TryGetValue(Key, Result) then
    Exit;
  Result := nil;
  if (Decls <> nil) and Decls.DeclBody(dtFx, Key, Body) then
  begin
    Result := TD3FxDecl.Create;
    Result.Name := Key;
    Result.Parse(Body);
  end;
  FxCache.Add(Key, Result);
end;

procedure ClearParticleDecls;
begin
  { Decls may clear after this unit's finalization }
  if ParticleCache <> nil then
    ParticleCache.Clear;
  if FxCache <> nil then
    FxCache.Clear;
end;

initialization
  ParticleCache := specialize TObjectDictionary<String, TD3ParticleDecl>.Create([doOwnsValues]);
  FxCache := specialize TObjectDictionary<String, TD3FxDecl>.Create([doOwnsValues]);
finalization
  FreeAndNil(ParticleCache);
  FreeAndNil(FxCache);
end.
