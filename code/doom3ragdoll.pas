{
  Copyright 2026 Castle Doom 3 contributors.

  Ragdolls of md5 models (the dead player's body, monsters' corpses): a
  position based (verlet) simulation at Doom 3's 60 Hz and gravity, its
  particles kept apart by links and stopped by the world.

  With an articulated figure (Doom3AF) every body is a rigid frame of its
  center and the anchors of its constraints; constraints share their
  anchor (a ball joint) and limit how far the second body bends from the
  first (cone, pyramid, hinge limit) through the distance of the bodies'
  centers. Each body's turn (from its anchors) moves its contained joints;
  other joints follow their parent. Without one every joint is a particle
  linked to its parent (rigid), siblings and grandparent (some give).
  Doom 3's rigid body solver (idPhysics_AF: masses, friction, contacts) is
  not reproduced.
}
unit Doom3Ragdoll;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  CastleVectors, CastleQuaternions,
  Doom3Md5, Doom3AF;

type
  { The world along a segment (TD3Game.WorldHit). }
  TD3WorldHitFunc = function (const From, Dir: TVector3; const MaxDist: Single;
    out Distance: Single; out N: TVector3): Boolean of object;

  { Two particles' distance kept within MinLength..MaxLength. }
  TD3RagdollLink = record
    A, B: Integer;
    MinLength, MaxLength: Single;
  end;

  TD3Ragdoll = class
  strict private
    FInstance: TD3Md5Instance;
    FWorldHit: TD3WorldHitFunc;
    FAF: TD3ArticulatedFigure;
    { particles: CGE, world }
    FPos, FPrev: array of TVector3;
    FRadius: array of Single;
    { particles' start positions (Doom 3, model space) }
    FStartPos: array of TVector3;
    FLinks: array of TD3RagdollLink;
    { the pose it started from (model space) }
    FStart: TD3JointArray;
    { skeleton: each joint's first child }
    FChild: array of Integer;
    { articulated figure: each body's center particle (-1: its joint is
      missing), its other particles (anchors), each joint's body }
    FBodyCenter: array of Integer;
    FBodyPoints: array of array of Integer;
    FJointBody: array of Integer;
    FStill, FTime, FLeft: Single;
    FSettled: Boolean;
    function AddParticle(const ModelPos: TVector3; const Radius: Single): Integer;
    procedure LinkRange(const A, B: Integer; const MinLength, MaxLength: Single);
    procedure LinkScaled(const A, B: Integer; const MinScale, MaxScale: Single);
    procedure SetupSkeleton;
    procedure SetupFigure;
    procedure Step;
    procedure WritePose;
    function ModelPos(const Particle: Integer): TVector3;
  public
    { AF nil: the skeleton ragdoll. Starts from the instance's current pose
      (its scene placed in the world); locks the instance's pose. }
    constructor Create(const AInstance: TD3Md5Instance; const AAF: TD3ArticulatedFigure;
      const AWorldHit: TD3WorldHitFunc);
    destructor Destroy; override;
    { The start velocity (CGE) of every particle: Velocity, plus Push
      growing with the particle's height over FloorY (to Height). }
    procedure Launch(const Velocity, Push: TVector3; const FloorY, Height: Single);
    procedure Update(const SecondsPassed: Single);
    { One line for the log: what it simulates. }
    function Description: String;
    property Settled: Boolean read FSettled;
    property SimulatedTime: Single read FTime;
    property Figure: TD3ArticulatedFigure read FAF;
    function ParticleCount: Integer;
    function LinkCount: Integer;
  end;

{ the shortest arc turning unit A to unit B }
function QuatFromTo(const A, B: TVector3): TQuaternion;

implementation

uses
  Math,
  CastleUtils,
  Doom3MapFile;

const
  Dt = 1 / 60;
  Gravity = 1066;
  Iterations = 8;

function QuatFromTo(const A, B: TVector3): TQuaternion;
var
  D: Single;
  Axis: TVector3;
begin
  D := TVector3.DotProduct(A, B);
  if D < -0.9999 then
  begin
    Axis := TVector3.CrossProduct(A, Vector3(1, 0, 0));
    if Axis.Length < 0.01 then
      Axis := TVector3.CrossProduct(A, Vector3(0, 1, 0));
    Result.Data.Vector := Axis.Normalize;
    Result.Data.Real := 0;
    Exit;
  end;
  Result.Data.Vector := TVector3.CrossProduct(A, B);
  Result.Data.Real := 1 + D;
  Result := QuatNormalize(Result);
end;

function IdentityQuat: TQuaternion;
begin
  Result.Data.Vector := TVector3.Zero;
  Result.Data.Real := 1;
end;

{ TD3Ragdoll }

constructor TD3Ragdoll.Create(const AInstance: TD3Md5Instance; const AAF: TD3ArticulatedFigure;
  const AWorldHit: TD3WorldHitFunc);
begin
  inherited Create;
  FInstance := AInstance;
  FAF := AAF;
  FWorldHit := AWorldHit;
  FStart := Copy(FInstance.Pose);
  if FAF <> nil then
    SetupFigure;
  { a figure without one usable body: the skeleton }
  if (FAF = nil) or (Length(FPos) = 0) then
  begin
    FAF := nil;
    SetupSkeleton;
  end;
  FInstance.PoseLocked := True;
end;

destructor TD3Ragdoll.Destroy;
begin
  inherited Destroy;
end;

function TD3Ragdoll.AddParticle(const ModelPos: TVector3; const Radius: Single): Integer;
begin
  Result := Length(FPos);
  SetLength(FPos, Result + 1);
  SetLength(FPrev, Result + 1);
  SetLength(FRadius, Result + 1);
  SetLength(FStartPos, Result + 1);
  FStartPos[Result] := ModelPos;
  FPos[Result] := FInstance.Scene.LocalToWorld(D3ToCge(ModelPos));
  FPrev[Result] := FPos[Result];
  FRadius[Result] := Radius;
end;

procedure TD3Ragdoll.LinkRange(const A, B: Integer; const MinLength, MaxLength: Single);
var
  L: TD3RagdollLink;
begin
  L.A := A;
  L.B := B;
  L.MinLength := MinLength;
  L.MaxLength := MaxLength;
  FLinks := Concat(FLinks, [L]);
end;

procedure TD3Ragdoll.LinkScaled(const A, B: Integer; const MinScale, MaxScale: Single);
var
  D: Single;
begin
  D := (FPos[A] - FPos[B]).Length;
  LinkRange(A, B, D * MinScale, D * MaxScale);
end;

procedure TD3Ragdoll.SetupSkeleton;
var
  I, J, N: Integer;
begin
  N := Length(FStart);
  SetLength(FChild, N);
  for I := 0 to N - 1 do
  begin
    AddParticle(FStart[I].Position, 3);
    FChild[I] := -1;
  end;
  for I := N - 1 downto 0 do
    if FStart[I].Parent >= 0 then
      FChild[FStart[I].Parent] := I;
  for I := 0 to N - 1 do
  begin
    if FStart[I].Parent >= 0 then
    begin
      LinkScaled(I, FStart[I].Parent, 1, 1);
      if FStart[FStart[I].Parent].Parent >= 0 then
        LinkScaled(I, FStart[FStart[I].Parent].Parent, 0.6, 1);
    end;
    for J := I + 1 to N - 1 do
      if (FStart[J].Parent = FStart[I].Parent) and (FStart[I].Parent >= 0) then
        LinkScaled(I, J, 0.8, 1.2);
  end;
end;

procedure TD3Ragdoll.SetupFigure;
var
  Bind: TD3JointArray;
  BodyJoint: array of Integer;
  I, J, K, B1, B2, P: Integer;
  C: TD3AFConstraint;
  Ok: Boolean;
  V, C1, C2: TVector3;
  A, B, Bend, MaxBend: Single;
  Joints: specialize TArray<Integer>;

  function JointIndex(const JointName: String): Integer;
  var
    N: Integer;
  begin
    for N := 0 to High(FStart) do
      if SameText(FStart[N].Name, JointName) then
        Exit(N);
    Result := -1;
  end;

  { a bind pose point moved like joint J moved from the bind pose }
  function FromBind(const J: Integer; const X: TVector3): TVector3;
  var
    Q: TQuaternion;
  begin
    if (J < 0) or (J > High(Bind)) then
      Exit(X);
    Q := QuatMultiply(FStart[J].Orientation, QuatConjugate(Bind[J].Orientation));
    Result := FStart[J].Position + QuatRotate(Q, X - Bind[J].Position);
  end;

begin
  { AF vectors are in the af_pose; the bind pose stands in for it, and
    each body's points move with its joint into the current pose }
  Bind := FInstance.BindPose;
  SetLength(BodyJoint, FAF.Bodies.Count);
  SetLength(FBodyCenter, FAF.Bodies.Count);
  SetLength(FBodyPoints, FAF.Bodies.Count);
  for I := 0 to FAF.Bodies.Count - 1 do
  begin
    BodyJoint[I] := JointIndex(FAF.Bodies[I].JointName);
    FBodyCenter[I] := -1;
    FBodyPoints[I] := nil;
    if BodyJoint[I] < 0 then
      Continue;
    V := FAF.Bodies[I].Origin.Evaluate(Bind, Ok);
    if not Ok then
      V := Bind[BodyJoint[I]].Position;
    FBodyCenter[I] := AddParticle(FromBind(BodyJoint[I], V), EnsureRange(FAF.Bodies[I].Radius, 1, 16));
  end;
  for K := 0 to FAF.Constraints.Count - 1 do
  begin
    C := FAF.Constraints[K];
    B1 := FAF.BodyIndex(C.Body1);
    B2 := FAF.BodyIndex(C.Body2);
    { body2 may be "world": not simulated }
    if (B1 < 0) or (B2 < 0) or (FBodyCenter[B1] < 0) or (FBodyCenter[B2] < 0) then
      Continue;
    case C.Kind of
      acFixed, acSlider:
        LinkScaled(FBodyCenter[B1], FBodyCenter[B2], 1, 1);
      acSpring:
        LinkScaled(FBodyCenter[B1], FBodyCenter[B2], 0.5, 1.5);
      acBallAndSocket, acUniversal, acHinge:
        begin
          if C.HasAnchor then
          begin
            V := C.Anchor.Evaluate(Bind, Ok);
            if not Ok then
              V := Bind[BodyJoint[B2]].Position;
          end else
            V := Bind[BodyJoint[B2]].Position;
          P := AddParticle(FromBind(BodyJoint[B1], V), 1.5);
          FBodyPoints[B1] := Concat(FBodyPoints[B1], [P]);
          FBodyPoints[B2] := Concat(FBodyPoints[B2], [P]);
          { the bend at the anchor, from straight on (0): body2 may bend up
            to its limit past how it is now }
          C1 := FStartPos[FBodyCenter[B1]];
          C2 := FStartPos[FBodyCenter[B2]];
          A := (FStartPos[P] - C1).Length;
          B := (C2 - FStartPos[P]).Length;
          if (A > 0.01) and (B > 0.01) then
          begin
            Bend := RadToDeg(ArcCos(EnsureRange(TVector3.DotProduct((FStartPos[P] - C1) / A,
              (C2 - FStartPos[P]) / B), -1, 1)));
            if C.LimitAngle > 0 then
              MaxBend := Min(180, Bend + C.LimitAngle)
            else
              MaxBend := 180;
            LinkRange(FBodyCenter[B1], FBodyCenter[B2],
              Sqrt(Max(0, A * A + B * B + 2 * A * B * Cos(DegToRad(MaxBend)))), A + B);
          end;
        end;
    end;
  end;
  { every body rigid: its center and anchors keep their distances }
  for I := 0 to High(FBodyCenter) do
  begin
    if FBodyCenter[I] < 0 then
      Continue;
    for J := 0 to High(FBodyPoints[I]) do
    begin
      LinkScaled(FBodyCenter[I], FBodyPoints[I][J], 1, 1);
      for K := J + 1 to High(FBodyPoints[I]) do
        LinkScaled(FBodyPoints[I][J], FBodyPoints[I][K], 1, 1);
    end;
  end;
  { the joints each body moves (the first body naming a joint wins) }
  SetLength(FJointBody, Length(FStart));
  for J := 0 to High(FJointBody) do
    FJointBody[J] := -1;
  for I := 0 to FAF.Bodies.Count - 1 do
  begin
    if FBodyCenter[I] < 0 then
      Continue;
    Joints := FAF.Bodies[I].JointList(FStart);
    for J in Joints do
      if FJointBody[J] < 0 then
        FJointBody[J] := I;
  end;
end;

procedure TD3Ragdoll.Launch(const Velocity, Push: TVector3; const FloorY, Height: Single);
var
  I: Integer;
  H: Single;
begin
  for I := 0 to High(FPos) do
  begin
    H := EnsureRange((FPos[I].Y - FloorY) / Max(1, Height), 0, 1.2);
    FPrev[I] := FPos[I] - (Velocity + Push * H) * Dt;
  end;
end;

function TD3Ragdoll.ParticleCount: Integer;
begin
  Result := Length(FPos);
end;

function TD3Ragdoll.LinkCount: Integer;
begin
  Result := Length(FLinks);
end;

function TD3Ragdoll.Description: String;
var
  Bodies, I: Integer;
begin
  if FAF <> nil then
  begin
    Bodies := 0;
    for I := 0 to High(FBodyCenter) do
      if FBodyCenter[I] >= 0 then
        Inc(Bodies);
    Result := Format('articulated figure "%s": %d bodies, %d constraints, %d particles, %d links',
      [FAF.Name, Bodies, FAF.Constraints.Count, Length(FPos), Length(FLinks)]);
  end else
    Result := Format('%d joints, %d links', [Length(FPos), Length(FLinks)]);
end;

procedure TD3Ragdoll.Step;
var
  I, K: Integer;
  Old: array of TVector3;
  D, Corr, Move, Dir, N: TVector3;
  L, Target, Dist, MaxMove: Single;
begin
  SetLength(Old, Length(FPos));
  for I := 0 to High(FPos) do
  begin
    Old[I] := FPos[I];
    D := (FPos[I] - FPrev[I]) * 0.99;
    FPrev[I] := FPos[I];
    FPos[I] := FPos[I] + D - Vector3(0, Gravity * Dt * Dt, 0);
  end;
  for K := 1 to Iterations do
    for I := 0 to High(FLinks) do
    begin
      D := FPos[FLinks[I].B] - FPos[FLinks[I].A];
      L := D.Length;
      if L < 0.0001 then
        Continue;
      Target := EnsureRange(L, FLinks[I].MinLength, FLinks[I].MaxLength);
      if Target = L then
        Continue;
      Corr := D * ((L - Target) / L * 0.5);
      FPos[FLinks[I].A] := FPos[FLinks[I].A] + Corr;
      FPos[FLinks[I].B] := FPos[FLinks[I].B] - Corr;
    end;
  { the world stops a particle at its radius (no sliding: it lies still) }
  MaxMove := 0;
  for I := 0 to High(FPos) do
  begin
    Move := FPos[I] - Old[I];
    L := Move.Length;
    if L > 0.0001 then
    begin
      Dir := Move / L;
      if Assigned(FWorldHit) and FWorldHit(Old[I], Dir, L + FRadius[I], Dist, N) then
      begin
        FPos[I] := Old[I] + Dir * Max(0, Dist - FRadius[I]);
        FPrev[I] := FPos[I];
      end;
    end;
    MaxMove := Max(MaxMove, (FPos[I] - Old[I]).Length);
  end;
  if MaxMove < 0.05 then
    FStill := FStill + Dt
  else
    FStill := 0;
  FTime := FTime + Dt;
  if (FStill > 0.5) or (FTime > 10) then
    FSettled := True;
end;

function TD3Ragdoll.ModelPos(const Particle: Integer): TVector3;
begin
  Result := CgeToD3(FInstance.Scene.WorldToLocal(FPos[Particle]));
end;

procedure TD3Ragdoll.WritePose;
var
  Pose: TD3JointArray;
  I, C, B, P, P2, K: Integer;
  R: array of TQuaternion;
  BodyR: array of TQuaternion;
  Local: array of TVector3;
  A, V, S1, S2, N1, N2, U: TVector3;
  Twist: TQuaternion;
  Ang: Single;
begin
  Pose := Copy(FStart);
  SetLength(R, Length(Pose));
  if FAF = nil then
  begin
    { skeleton: each joint at its particle, turned by the arc of its first
      child's direction; leaves turn with their parent }
    SetLength(Local, Length(Pose));
    for I := 0 to High(Pose) do
      Local[I] := ModelPos(I);
    for I := 0 to High(Pose) do
    begin
      C := FChild[I];
      R[I] := IdentityQuat;
      if C >= 0 then
      begin
        A := FStart[C].Position - FStart[I].Position;
        V := Local[C] - Local[I];
        if (A.Length > 0.01) and (V.Length > 0.01) then
          R[I] := QuatFromTo(A.Normalize, V.Normalize)
        else
        if Pose[I].Parent >= 0 then
          R[I] := R[Pose[I].Parent];
      end else
      if Pose[I].Parent >= 0 then
        R[I] := R[Pose[I].Parent];
      Pose[I].Position := Local[I];
      Pose[I].Orientation := QuatNormalize(QuatMultiply(R[I], FStart[I].Orientation));
    end;
  end else
  begin
    { each body's turn: its first anchor's direction from the center, then
      the twist about it that brings the next anchor around }
    SetLength(BodyR, Length(FBodyCenter));
    for B := 0 to High(FBodyCenter) do
    begin
      BodyR[B] := IdentityQuat;
      C := FBodyCenter[B];
      if (C < 0) or (Length(FBodyPoints[B]) = 0) then
        Continue;
      P := FBodyPoints[B][0];
      S1 := FStartPos[P] - FStartPos[C];
      N1 := ModelPos(P) - ModelPos(C);
      if (S1.Length < 0.01) or (N1.Length < 0.01) then
        Continue;
      S1 := S1.Normalize;
      N1 := N1.Normalize;
      BodyR[B] := QuatFromTo(S1, N1);
      for K := 1 to High(FBodyPoints[B]) do
      begin
        P2 := FBodyPoints[B][K];
        S2 := QuatRotate(BodyR[B], FStartPos[P2] - FStartPos[C]);
        N2 := ModelPos(P2) - ModelPos(C);
        S2 := S2 - N1 * TVector3.DotProduct(S2, N1);
        N2 := N2 - N1 * TVector3.DotProduct(N2, N1);
        if (S2.Length < 0.5) or (N2.Length < 0.5) then
          Continue;
        S2 := S2.Normalize;
        N2 := N2.Normalize;
        Ang := ArcTan2(TVector3.DotProduct(TVector3.CrossProduct(S2, N2), N1), TVector3.DotProduct(S2, N2));
        Twist.Data.Vector := N1 * Sin(Ang / 2);
        Twist.Data.Real := Cos(Ang / 2);
        BodyR[B] := QuatNormalize(QuatMultiply(Twist, BodyR[B]));
        Break;
      end;
    end;
    { joints: their body's turn about its center; the rest follow their
      parent (parents come first) }
    for I := 0 to High(Pose) do
    begin
      B := FJointBody[I];
      if B >= 0 then
      begin
        R[I] := BodyR[B];
        U := ModelPos(FBodyCenter[B]);
        Pose[I].Position := U + QuatRotate(R[I], FStart[I].Position - FStartPos[FBodyCenter[B]]);
      end else
      if Pose[I].Parent >= 0 then
      begin
        R[I] := R[Pose[I].Parent];
        Pose[I].Position := Pose[Pose[I].Parent].Position +
          QuatRotate(R[I], FStart[I].Position - FStart[Pose[I].Parent].Position);
      end else
        R[I] := IdentityQuat;
      Pose[I].Orientation := QuatNormalize(QuatMultiply(R[I], FStart[I].Orientation));
    end;
  end;
  FInstance.SetPose(Pose);
end;

procedure TD3Ragdoll.Update(const SecondsPassed: Single);
begin
  if FSettled then
    Exit;
  FLeft := FLeft + SecondsPassed;
  while (FLeft >= Dt) and not FSettled do
  begin
    FLeft := FLeft - Dt;
    Step;
  end;
  WritePose;
end;

end.
