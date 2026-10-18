{ Doom 3 skeletal models: .md5mesh (joints, meshes with weighted vertexes)
  and .md5anim (per frame joint transforms), MD5Version 10.

  TD3Md5Instance builds an X3D scene (one shape per mesh, Doom 3 materials
  through Doom3Materials) and skins it on the CPU every frame: positions are
  written to the TCoordinateNode and normals are recomputed by CGE. }
unit Doom3Md5;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleVectors, CastleQuaternions, CastleTransform, CastleScene, X3DNodes,
  Doom3Lexer, Doom3Scene;

type
  TD3Joint = record
    Name: String;
    Parent: Integer;
    Position: TVector3;
    Orientation: TQuaternion;
  end;
  TD3JointArray = array of TD3Joint;

  { A joint's transformation as rows of a 3 x 4 matrix (rotation and
    position), for skinning many vertexes. }
  TD3JointMatrix = record
    Rows: array [0..2] of TVector4;
  end;
  TD3JointMatrixArray = array of TD3JointMatrix;

  TD3Md5Vert = record
    ST: TVector2;
    StartWeight, WeightCount: Integer;
  end;

  TD3Md5Weight = record
    Joint: Integer;
    Bias: Single;
    Position: TVector3;
  end;

  TD3Md5Mesh = class
    Shader: String;
    Verts: array of TD3Md5Vert;
    Tris: array of Int32;
    Weights: array of TD3Md5Weight;
  end;

  TD3Md5Model = class
  strict private
    { per mesh: 0 not checked yet, 1 closed, 2 open }
    FMeshClosed: array of Byte;
  public
    Name: String;
    Joints: TD3JointArray;
    Meshes: specialize TObjectList<TD3Md5Mesh>;
    constructor Create;
    destructor Destroy; override;
    function LoadFromText(const Text: String): Boolean;
    function JointIndex(const AName: String): Integer;
    { Skin a mesh with absolute joints into Doom 3 coordinates. }
    { The joints of a pose as matrices (for SkinMeshTo). }
    class procedure PoseMatrices(const Pose: TD3JointArray; var Matrices: TD3JointMatrixArray); static;
    { Skin a mesh with PoseMatrices into Dest (CGE coordinates, one per
      vertex). }
    procedure SkinMeshTo(const MeshIndex: Integer; const Matrices: TD3JointMatrixArray; const Dest: PVector3);
    procedure SkinMesh(const MeshIndex: Integer; const Pose: TD3JointArray;
      var Positions: array of TVector3);
    { Is the mesh closed (2-manifold) in the bind pose: every edge between
      two triangles going opposite ways? Only closed meshes cast shadow
      volumes in CGE. Cached. }
    function MeshClosed(const MeshIndex: Integer): Boolean;
  end;

  TD3Md5Anim = class
    Name: String;
    NumFrames, FrameRate, NumAnimatedComponents: Integer;
    Hierarchy: array of record
      Name: String;
      Parent, Flags, StartIndex: Integer;
    end;
    BaseFrame: array of record
      Position: TVector3;
      Orientation: TVector3; { quaternion x y z }
    end;
    Frames: array of array of Single;
    constructor Create;
    function LoadFromText(const Text: String): Boolean;
    function Duration: Single;
    { Absolute (model space) joints of a frame. }
    procedure FramePose(const Frame: Integer; var Pose: TD3JointArray);
    { Interpolated pose at a time (seconds), looping or clamped. }
    procedure PoseAt(const Time: Single; const Loop: Boolean; var Pose: TD3JointArray);
  end;

  { Caches parsed models and animations by path. }
  TD3Md5Cache = class
  strict private
    FModels: specialize TObjectDictionary<String, TD3Md5Model>;
    FAnims: specialize TObjectDictionary<String, TD3Md5Anim>;
  public
    constructor Create;
    destructor Destroy; override;
    function Model(const Path: String): TD3Md5Model;
    function Anim(const Path: String): TD3Md5Anim;
    procedure Clear;
  end;

  { An animated instance: a TCastleScene skinned from a model and anims. }
  TD3Md5Instance = class;
  TD3FrameCommandEvent = procedure (const Sender: TD3Md5Instance; const Command: String) of object;

  { A joint of another instance (the body) whose local rotation a joint of
    this one (the head) takes (idActor's copy_joint, JOINTMOD_LOCAL_OVERRIDE). }
  TD3CopyJoint = record
    Source: TD3Md5Instance;
    FromJoint, ToJoint: Integer;
  end;

  TD3Md5Instance = class
  strict private
    FModel: TD3Md5Model;
    FScene: TCastleScene;
    FCoords: array of TCoordinateNode;
    FMatrices: TD3JointMatrixArray;
    { the pose changed since the meshes were last skinned }
    FSkinPending, FShown: Boolean;
    { the animation's pose, and the one shown (FPose with the joint mods
      and copied joints) }
    FPose, FFinalPose: TD3JointArray;
    { JOINTMOD_WORLD rotations (model space) by joint, FHasMod when set }
    FJointMods: array of TQuaternion;
    FHasMod: array of Boolean;
    FModCount: Integer;
    { mods were cleared: show the plain pose again }
    FModsCleared: Boolean;
    FCopyJoints: array of TD3CopyJoint;
    FAnim: TD3Md5Anim;
    FAnimTime: Single;
    FLoop: Boolean;
    { the origin joint's position after the last Update (before
      LockOrigin), for LastOriginDelta }
    FPrevOrigin: TVector3;
    FHasPrevOrigin: Boolean;
    FAnims: TStringList;
    { shadow casting boxes, one per joint, for meshes too big to cast }
    FHullJoints: array of Integer;
    FHullTransforms: array of TMatrixTransformNode;
    procedure SetShown(const Value: Boolean);
    procedure ApplyPose;
    procedure FinishPose;
    procedure LockPoseOrigin;
    procedure FireFrameCommands(const FromTime, ToTime: Single);
    procedure BuildShadowHulls(const Root: TX3DRootNode);
  public
    { The animation stands still (SetFrame). }
    Paused: Boolean;
    { The model decl's frame commands (not owned; "animname=frame command"). }
    FrameCommands: TStrings;
    { Called for each frame command the playing animation passes. }
    OnFrameCommand: TD3FrameCommandEvent;
    { The anim playing (its name in the decl, e.g. "idle2"). }
    PlayingAnim: String;
    { The meshes' shapes and their materials (after the skin) }
    MeshShapes: array of TShapeNode;
    MeshMaterials: array of String;
    { Keep the skeleton's origin joint where the animation starts in X / Y
      (Doom 3 coordinates): the game moves the entity instead, like idAI
      moving by the animation's delta. }
    LockOrigin: Boolean;
    { How far the origin joint moved in X / Y (Doom 3 model space) during
      the last Update: what an entity moved by its animation moves
      (idAnimator::GetDelta). }
    LastOriginDelta: TVector3;
    { The decl's anim for a name: itself, or one of name1, name2... at
      random (idDeclModelDef::GetAnim). '' if none. }
    function ResolveAnim(const AName: String): String;
    { Seconds of an anim (0 if there's no such anim). }
    function AnimDurationOf(const AName: String): Single;
    { How far an anim's origin joint moves from its first to its last frame
      (Doom 3 model space; zero if there's no such anim):
      idAnimator::TotalMovementDelta. }
    function AnimMovementDelta(const AName: String): TVector3;
    { Anims: anim name -> md5anim path (from a model decl). }
    constructor Create(const AModel: TD3Md5Model; const AAnims: TStrings;
      const SkinName: String = '');
    destructor Destroy; override;
    { Start an animation by name (from the model decl) or path. False when
      it doesn't exist. }
    function PlayAnim(const AnimName: String; const Loop: Boolean = True): Boolean;
    function HasAnim(const AnimName: String): Boolean;
    function TriangleCount: Integer;
    { Joints casting shadows with a box (0 when the mesh itself casts). }
    function ShadowHullCount: Integer;
    function AnimFinished: Boolean;
    procedure Update(const SecondsPassed: Single);
    { Show one frame (1 = the first) of an animation, holding it
      (idAnimator::SetFrame). False if there's no such animation. }
    function SetFrame(const AnimName: String; const Frame: Integer): Boolean;
    { Seconds of the playing animation (0 if none). }
    function AnimLength: Single;
    { Horizontal speed (units per second) of the playing animation's origin
      joint, from its first to its last frame (walk / run cycles). }
    function AnimSpeed: Single;
    { Where to attach a model (a head) to a joint, in the scene's
      coordinates (CGE): at the joint, turned by the joint's rotation since
      the bind pose (an attachment is upright when the body is in its bind
      pose). False if there's no such joint. }
    function JointTransform(const JointName: String; out M: TMatrix4): Boolean;
    { Where a joint is now, in the scene's coordinates (CGE). }
    function JointPosition(const JointName: String; out P: TVector3): Boolean;
    { Turn a joint and everything under it by Q (Doom 3 model space, about
      the joint) after the animation, like idAnimator::SetJointAxis with
      JOINTMOD_WORLD (heads looking at something). Shown at the next
      Update. }
    procedure SetJointMod(const Joint: Integer; const Q: TQuaternion);
    procedure ClearJointMods;
    { Each Update, joint ToName (of this model) takes the local rotation of
      Source's joint FromName (copy_joint: a head following the body's
      neck). False if a joint is missing. }
    function AddCopyJoint(const Source: TD3Md5Instance; const FromName, ToName: String): Boolean;
    { The shown pose (with joint mods and copied joints). }
    function Pose: TD3JointArray;
    { Whether it can be seen (the map's portal visibility): only then are
      its meshes skinned (the slow part); its animation, frame commands and
      joints go on anyway. True at first. }
    property Shown: Boolean read FShown write SetShown;
    property Scene: TCastleScene read FScene;
    property Model: TD3Md5Model read FModel;
  end;

type
  TD3IndexArray = array of Int32;

{ Rotate a Doom 3 vector by an md5 joint orientation. }
function QuatRotate(const Q: TQuaternion; const V: TVector3): TVector3;
{ Doom 3 quaternion from its stored x y z (md5 files). }
function QuatFromXYZ(const V: TVector3): TQuaternion;
{ Normalized linear interpolation along the shortest arc. }
function QuatNlerp(const A, B: TQuaternion; const T: Single): TQuaternion;
{ The rotation of Doom 3 angles (degrees; pitch down, yaw left, roll) like
  idAngles::ToMat3: roll, then pitch about Y, then yaw about Z. }
function QuatFromAngles(const Pitch, Yaw, Roll: Single): TQuaternion;
function QuatMultiply(const A, B: TQuaternion): TQuaternion;
function QuatConjugate(const Q: TQuaternion): TQuaternion;

{ The transformation of a joint's space, in CGE coordinates. }
function JointMatrix(const Joint: TD3Joint): TMatrix4;
{ The 12 triangles of a box from its 8 corners (index bits: x, y, z),
  counter-clockwise seen from outside. }
function BoxTriangles(const Corners: array of TVector3): TD3IndexArray;

var
  Md5Cache: TD3Md5Cache;
  { md5 models with more triangles cast shadow volumes from a box per joint
    instead of their mesh, unless their meshes are closed and
    ClosedMeshesCastShadows (console r_md5ShadowTris) }
  MaxShadowCastingTriangles: Integer = 1500;
  { Closed md5 meshes cast shadow volumes with their own triangles,
    whatever their size (console r_md5ShadowClosed). Animated casters are
    cheap since CGE moves the same triangles when only the coordinates
    change (mariuz/castle-engine#4); meshes that aren't closed don't cast
    at all in CGE, so the joint boxes stay for them. }
  ClosedMeshesCastShadows: Boolean = True;
  { Size of the joint boxes relative to the box of the joint's vertexes:
    smaller than the mesh, so they stay inside it. }
  ShadowHullScale: Single = 0.6;

implementation

uses
  Math,
  CastleLog,
  Doom3Files, Doom3Decls, Doom3MapFile, Doom3Materials, Doom3LightEffects,
  Doom3Collision;

{ Doom 3 stores unit quaternions as x y z, w = -sqrt(1 - x2 - y2 - z2). }
function QuatFromXYZ(const V: TVector3): TQuaternion;
var
  T: Single;
begin
  Result.Data.Vector := V;
  T := 1 - V.X * V.X - V.Y * V.Y - V.Z * V.Z;
  if T < 0 then
    Result.Data.Real := 0
  else
    Result.Data.Real := -Sqrt(T);
end;

{ q * v * q^-1 for a unit quaternion }
function QuatRotate(const Q: TQuaternion; const V: TVector3): TVector3;
var
  U, T: TVector3;
begin
  U := Q.Data.Vector;
  T := TVector3.CrossProduct(U, V) * 2;
  Result := V + T * Q.Data.Real + TVector3.CrossProduct(U, T);
end;

function QuatMultiply(const A, B: TQuaternion): TQuaternion;
begin
  Result.Data.Real := A.Data.Real * B.Data.Real - TVector3.DotProduct(A.Data.Vector, B.Data.Vector);
  Result.Data.Vector := B.Data.Vector * A.Data.Real + A.Data.Vector * B.Data.Real +
    TVector3.CrossProduct(A.Data.Vector, B.Data.Vector);
end;

function QuatConjugate(const Q: TQuaternion): TQuaternion;
begin
  Result.Data.Real := Q.Data.Real;
  Result.Data.Vector := -Q.Data.Vector;
end;

function QuatFromAngles(const Pitch, Yaw, Roll: Single): TQuaternion;

  function AxisQuat(const Axis: TVector3; const Degrees: Single): TQuaternion;
  begin
    Result.Data.Real := Cos(DegToRad(Degrees) / 2);
    Result.Data.Vector := Axis * Sin(DegToRad(Degrees) / 2);
  end;

begin
  Result := QuatMultiply(AxisQuat(Vector3(0, 0, 1), Yaw),
    QuatMultiply(AxisQuat(Vector3(0, 1, 0), Pitch), AxisQuat(Vector3(1, 0, 0), Roll)));
end;

function QuatNormalize(const Q: TQuaternion): TQuaternion;
var
  L: Single;
begin
  L := Sqrt(Sqr(Q.Data.Real) + Q.Data.Vector.LengthSqr);
  if L < 1e-8 then
    Exit(Q);
  Result.Data.Real := Q.Data.Real / L;
  Result.Data.Vector := Q.Data.Vector / L;
end;

function QuatNlerp(const A, B: TQuaternion; const T: Single): TQuaternion;
var
  BB: TQuaternion;
begin
  BB := B;
  if A.Data.Real * B.Data.Real + TVector3.DotProduct(A.Data.Vector, B.Data.Vector) < 0 then
  begin
    BB.Data.Real := -B.Data.Real;
    BB.Data.Vector := -B.Data.Vector;
  end;
  Result.Data.Real := A.Data.Real + (BB.Data.Real - A.Data.Real) * T;
  Result.Data.Vector := A.Data.Vector + (BB.Data.Vector - A.Data.Vector) * T;
  Result := QuatNormalize(Result);
end;

{ TD3Md5Model }

constructor TD3Md5Model.Create;
begin
  inherited Create;
  Meshes := specialize TObjectList<TD3Md5Mesh>.Create(True);
end;

destructor TD3Md5Model.Destroy;
begin
  Meshes.Free;
  inherited Destroy;
end;

function TD3Md5Model.LoadFromText(const Text: String): Boolean;
var
  Lexer: TDoom3Lexer;
  Tok: String;
  NumJoints, I, N: Integer;
  V: TVector3;
  Mesh: TD3Md5Mesh;
begin
  Result := False;
  Lexer := TDoom3Lexer.Create(Text);
  try
    NumJoints := 0;
    while Lexer.Next(Tok) do
    begin
      if SameText(Tok, 'MD5Version') then
      begin
        if Lexer.ReadInt <> 10 then
        begin
          WritelnWarning('Doom3Md5', 'Unsupported MD5 version in "%s"', [Name]);
          Exit;
        end;
      end else
      if SameText(Tok, 'commandline') then
        Lexer.NextStr
      else
      if SameText(Tok, 'numJoints') then
      begin
        NumJoints := Lexer.ReadInt;
        SetLength(Joints, NumJoints);
      end else
      if SameText(Tok, 'numMeshes') then
        Lexer.ReadInt
      else
      if SameText(Tok, 'joints') then
      begin
        Lexer.Expect('{');
        for I := 0 to NumJoints - 1 do
        begin
          Joints[I].Name := Lexer.NextStr;
          Joints[I].Parent := Lexer.ReadInt;
          Lexer.ReadVector(@Joints[I].Position.X, 3);
          Lexer.ReadVector(@V.X, 3);
          Joints[I].Orientation := QuatFromXYZ(V);
        end;
        Lexer.Expect('}');
      end else
      if SameText(Tok, 'mesh') then
      begin
        Lexer.Expect('{');
        Mesh := TD3Md5Mesh.Create;
        Meshes.Add(Mesh);
        while Lexer.Next(Tok) and (Tok <> '}') do
        begin
          if SameText(Tok, 'shader') then
            Mesh.Shader := Lexer.NextStr
          else
          if SameText(Tok, 'numverts') then
            SetLength(Mesh.Verts, Lexer.ReadInt)
          else
          if SameText(Tok, 'vert') then
          begin
            N := Lexer.ReadInt;
            Lexer.ReadVector(@Mesh.Verts[N].ST.X, 2);
            Mesh.Verts[N].StartWeight := Lexer.ReadInt;
            Mesh.Verts[N].WeightCount := Lexer.ReadInt;
          end else
          if SameText(Tok, 'numtris') then
            SetLength(Mesh.Tris, Lexer.ReadInt * 3)
          else
          if SameText(Tok, 'tri') then
          begin
            N := Lexer.ReadInt;
            Mesh.Tris[N * 3] := Lexer.ReadInt;
            Mesh.Tris[N * 3 + 1] := Lexer.ReadInt;
            Mesh.Tris[N * 3 + 2] := Lexer.ReadInt;
          end else
          if SameText(Tok, 'numweights') then
            SetLength(Mesh.Weights, Lexer.ReadInt)
          else
          if SameText(Tok, 'weight') then
          begin
            N := Lexer.ReadInt;
            Mesh.Weights[N].Joint := Lexer.ReadInt;
            Mesh.Weights[N].Bias := Lexer.ReadFloat;
            Lexer.ReadVector(@Mesh.Weights[N].Position.X, 3);
          end;
        end;
      end;
    end;
    Result := (Length(Joints) > 0) and (Meshes.Count > 0);
  finally
    Lexer.Free;
  end;
end;

function TD3Md5Model.JointIndex(const AName: String): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Joints) do
    if SameText(Joints[I].Name, AName) then
      Exit(I);
  Result := -1;
end;

function TD3Md5Model.MeshClosed(const MeshIndex: Integer): Boolean;
var
  Positions: array of TVector3;
begin
  if Length(FMeshClosed) <> Meshes.Count then
    SetLength(FMeshClosed, Meshes.Count);
  if FMeshClosed[MeshIndex] = 0 then
  begin
    SetLength(Positions, Length(Meshes[MeshIndex].Verts));
    SkinMesh(MeshIndex, Joints, Positions);
    if TrianglesClosed(Positions, Meshes[MeshIndex].Tris) then
      FMeshClosed[MeshIndex] := 1
    else
      FMeshClosed[MeshIndex] := 2;
  end;
  Result := FMeshClosed[MeshIndex] = 1;
end;

procedure TD3Md5Model.SkinMesh(const MeshIndex: Integer; const Pose: TD3JointArray;
  var Positions: array of TVector3);
var
  Mesh: TD3Md5Mesh;
  I, W: Integer;
  P: TVector3;
  Weight: TD3Md5Weight;
begin
  Mesh := Meshes[MeshIndex];
  for I := 0 to High(Mesh.Verts) do
  begin
    P := TVector3.Zero;
    for W := Mesh.Verts[I].StartWeight to Mesh.Verts[I].StartWeight + Mesh.Verts[I].WeightCount - 1 do
      if W <= High(Mesh.Weights) then
      begin
        Weight := Mesh.Weights[W];
        if Weight.Joint <= High(Pose) then
          P := P + (Pose[Weight.Joint].Position +
            QuatRotate(Pose[Weight.Joint].Orientation, Weight.Position)) * Weight.Bias;
      end;
    Positions[I] := D3ToCge(P);
  end;
end;

class procedure TD3Md5Model.PoseMatrices(const Pose: TD3JointArray; var Matrices: TD3JointMatrixArray);
var
  I: Integer;
  X, Y, Z, W: Single;
begin
  if Length(Matrices) <> Length(Pose) then
    SetLength(Matrices, Length(Pose));
  for I := 0 to High(Pose) do
  begin
    { the rotation matrix of a unit quaternion (QuatRotate's) }
    X := Pose[I].Orientation.Data.Vector.X;
    Y := Pose[I].Orientation.Data.Vector.Y;
    Z := Pose[I].Orientation.Data.Vector.Z;
    W := Pose[I].Orientation.Data.Real;
    Matrices[I].Rows[0] := Vector4(1 - 2 * (Y * Y + Z * Z), 2 * (X * Y - Z * W), 2 * (X * Z + Y * W), Pose[I].Position.X);
    Matrices[I].Rows[1] := Vector4(2 * (X * Y + Z * W), 1 - 2 * (X * X + Z * Z), 2 * (Y * Z - X * W), Pose[I].Position.Y);
    Matrices[I].Rows[2] := Vector4(2 * (X * Z - Y * W), 2 * (Y * Z + X * W), 1 - 2 * (X * X + Y * Y), Pose[I].Position.Z);
  end;
end;

procedure TD3Md5Model.SkinMeshTo(const MeshIndex: Integer; const Matrices: TD3JointMatrixArray; const Dest: PVector3);
var
  Mesh: TD3Md5Mesh;
  I, W, WEnd: Integer;
  PX, PY, PZ, B: Single;
  Weight: ^TD3Md5Weight;
  M: ^TD3JointMatrix;
  D: PVector3;
begin
  Mesh := Meshes[MeshIndex];
  D := Dest;
  for I := 0 to High(Mesh.Verts) do
  begin
    PX := 0;
    PY := 0;
    PZ := 0;
    WEnd := Min(Mesh.Verts[I].StartWeight + Mesh.Verts[I].WeightCount, Length(Mesh.Weights)) - 1;
    for W := Mesh.Verts[I].StartWeight to WEnd do
    begin
      Weight := @Mesh.Weights[W];
      if Weight^.Joint > High(Matrices) then
        Continue;
      M := @Matrices[Weight^.Joint];
      B := Weight^.Bias;
      PX := PX + (M^.Rows[0].X * Weight^.Position.X + M^.Rows[0].Y * Weight^.Position.Y +
        M^.Rows[0].Z * Weight^.Position.Z + M^.Rows[0].W) * B;
      PY := PY + (M^.Rows[1].X * Weight^.Position.X + M^.Rows[1].Y * Weight^.Position.Y +
        M^.Rows[1].Z * Weight^.Position.Z + M^.Rows[1].W) * B;
      PZ := PZ + (M^.Rows[2].X * Weight^.Position.X + M^.Rows[2].Y * Weight^.Position.Y +
        M^.Rows[2].Z * Weight^.Position.Z + M^.Rows[2].W) * B;
    end;
    { D3ToCge }
    D^ := Vector3(PX, PZ, -PY);
    Inc(D);
  end;
end;

{ TD3Md5Anim }

constructor TD3Md5Anim.Create;
begin
  inherited Create;
  FrameRate := 24;
end;

function TD3Md5Anim.LoadFromText(const Text: String): Boolean;
var
  Lexer: TDoom3Lexer;
  Tok: String;
  NumJoints, I, J: Integer;
  Bounds: array [0..5] of Single;
begin
  Lexer := TDoom3Lexer.Create(Text);
  try
    NumJoints := 0;
    while Lexer.Next(Tok) do
    begin
      if SameText(Tok, 'MD5Version') then
        Lexer.ReadInt
      else
      if SameText(Tok, 'commandline') then
        Lexer.NextStr
      else
      if SameText(Tok, 'numFrames') then
      begin
        NumFrames := Lexer.ReadInt;
        SetLength(Frames, NumFrames);
      end else
      if SameText(Tok, 'numJoints') then
      begin
        NumJoints := Lexer.ReadInt;
        SetLength(Hierarchy, NumJoints);
        SetLength(BaseFrame, NumJoints);
      end else
      if SameText(Tok, 'frameRate') then
        FrameRate := Max(1, Lexer.ReadInt)
      else
      if SameText(Tok, 'numAnimatedComponents') then
        NumAnimatedComponents := Lexer.ReadInt
      else
      if SameText(Tok, 'hierarchy') then
      begin
        Lexer.Expect('{');
        for I := 0 to NumJoints - 1 do
        begin
          Hierarchy[I].Name := Lexer.NextStr;
          Hierarchy[I].Parent := Lexer.ReadInt;
          Hierarchy[I].Flags := Lexer.ReadInt;
          Hierarchy[I].StartIndex := Lexer.ReadInt;
        end;
        Lexer.Expect('}');
      end else
      if SameText(Tok, 'bounds') then
      begin
        Lexer.Expect('{');
        for I := 0 to NumFrames - 1 do
        begin
          Lexer.ReadVector(@Bounds[0], 3);
          Lexer.ReadVector(@Bounds[3], 3);
        end;
        Lexer.Expect('}');
      end else
      if SameText(Tok, 'baseframe') then
      begin
        Lexer.Expect('{');
        for I := 0 to NumJoints - 1 do
        begin
          Lexer.ReadVector(@BaseFrame[I].Position.X, 3);
          Lexer.ReadVector(@BaseFrame[I].Orientation.X, 3);
        end;
        Lexer.Expect('}');
      end else
      if SameText(Tok, 'frame') then
      begin
        I := Lexer.ReadInt;
        Lexer.Expect('{');
        if (I >= 0) and (I < NumFrames) then
        begin
          SetLength(Frames[I], NumAnimatedComponents);
          for J := 0 to NumAnimatedComponents - 1 do
            Frames[I][J] := Lexer.ReadFloat;
        end;
        Lexer.Expect('}');
      end;
    end;
    Result := (NumFrames > 0) and (NumJoints > 0);
  finally
    Lexer.Free;
  end;
end;

function TD3Md5Anim.Duration: Single;
begin
  Result := NumFrames / FrameRate;
end;

procedure TD3Md5Anim.FramePose(const Frame: Integer; var Pose: TD3JointArray);
var
  I, K, F: Integer;
  P, O: TVector3;
  Comp: array of Single;
begin
  if Length(Pose) <> Length(Hierarchy) then
    SetLength(Pose, Length(Hierarchy));
  F := Frame;
  if F >= NumFrames then
    F := NumFrames - 1;
  if F < 0 then
    F := 0;
  Comp := Frames[F];
  for I := 0 to High(Hierarchy) do
  begin
    P := BaseFrame[I].Position;
    O := BaseFrame[I].Orientation;
    K := Hierarchy[I].StartIndex;
    if (Hierarchy[I].Flags and 1) <> 0 then begin P.X := Comp[K]; Inc(K); end;
    if (Hierarchy[I].Flags and 2) <> 0 then begin P.Y := Comp[K]; Inc(K); end;
    if (Hierarchy[I].Flags and 4) <> 0 then begin P.Z := Comp[K]; Inc(K); end;
    if (Hierarchy[I].Flags and 8) <> 0 then begin O.X := Comp[K]; Inc(K); end;
    if (Hierarchy[I].Flags and 16) <> 0 then begin O.Y := Comp[K]; Inc(K); end;
    if (Hierarchy[I].Flags and 32) <> 0 then begin O.Z := Comp[K]; end;
    Pose[I].Name := Hierarchy[I].Name;
    Pose[I].Parent := Hierarchy[I].Parent;
    Pose[I].Orientation := QuatFromXYZ(O);
    if Hierarchy[I].Parent >= 0 then
    begin
      { parents come first in the hierarchy }
      Pose[I].Position := Pose[Hierarchy[I].Parent].Position +
        QuatRotate(Pose[Hierarchy[I].Parent].Orientation, P);
      Pose[I].Orientation := QuatNormalize(
        QuatMultiply(Pose[Hierarchy[I].Parent].Orientation, Pose[I].Orientation));
    end else
      Pose[I].Position := P;
  end;
end;

procedure TD3Md5Anim.PoseAt(const Time: Single; const Loop: Boolean; var Pose: TD3JointArray);
var
  FrameF, T: Single;
  F0, F1, I: Integer;
  PoseB: TD3JointArray;
begin
  FrameF := Time * FrameRate;
  if Loop and (NumFrames > 1) then
    FrameF := FrameF - Floor(FrameF / NumFrames) * NumFrames
  else
    FrameF := Min(FrameF, NumFrames - 1);
  F0 := Trunc(FrameF);
  T := FrameF - F0;
  F1 := F0 + 1;
  if F1 >= NumFrames then
  begin
    if Loop then
      F1 := 0
    else
      F1 := NumFrames - 1;
  end;
  FramePose(F0, Pose);
  if (T < 0.001) or (F1 = F0) then
    Exit;
  PoseB := nil;
  FramePose(F1, PoseB);
  for I := 0 to High(Pose) do
  begin
    Pose[I].Position := Lerp(T, Pose[I].Position, PoseB[I].Position);
    Pose[I].Orientation := QuatNlerp(Pose[I].Orientation, PoseB[I].Orientation, T);
  end;
end;

{ TD3Md5Cache }

constructor TD3Md5Cache.Create;
begin
  inherited Create;
  FModels := specialize TObjectDictionary<String, TD3Md5Model>.Create([doOwnsValues]);
  FAnims := specialize TObjectDictionary<String, TD3Md5Anim>.Create([doOwnsValues]);
end;

destructor TD3Md5Cache.Destroy;
begin
  FModels.Free;
  FAnims.Free;
  inherited Destroy;
end;

procedure TD3Md5Cache.Clear;
begin
  FModels.Clear;
  FAnims.Clear;
end;

function TD3Md5Cache.Model(const Path: String): TD3Md5Model;
var
  Key, Text: String;
begin
  Key := NormalizeD3Path(Path);
  if FModels.TryGetValue(Key, Result) then
    Exit;
  Result := nil;
  Text := D3Fs.ReadText(Key);
  if Text <> '' then
  begin
    Result := TD3Md5Model.Create;
    Result.Name := Key;
    if not Result.LoadFromText(Text) then
    begin
      WritelnWarning('Doom3Md5', 'Invalid md5mesh "%s"', [Key]);
      FreeAndNil(Result);
    end;
  end else
    WritelnWarning('Doom3Md5', 'Missing md5mesh "%s"', [Key]);
  FModels.Add(Key, Result);
end;

function TD3Md5Cache.Anim(const Path: String): TD3Md5Anim;
var
  Key, Text: String;
begin
  Key := NormalizeD3Path(Path);
  if FAnims.TryGetValue(Key, Result) then
    Exit;
  Result := nil;
  Text := D3Fs.ReadText(Key);
  if Text <> '' then
  begin
    Result := TD3Md5Anim.Create;
    Result.Name := Key;
    if not Result.LoadFromText(Text) then
    begin
      WritelnWarning('Doom3Md5', 'Invalid md5anim "%s"', [Key]);
      FreeAndNil(Result);
    end;
  end;
  FAnims.Add(Key, Result);
end;

{ The transformation of a joint's space, in CGE coordinates: D3ToCge of
  position + rotation of a Doom 3 vector. }
function JointMatrix(const Joint: TD3Joint): TMatrix4;
var
  K: Integer;
  Axis: TVector3;
begin
  Result := TMatrix4.Identity;
  for K := 0 to 2 do
  begin
    Axis := TVector3.Zero;
    Axis.Data[K] := 1;
    Result.Columns[K] := Vector4(D3ToCge(QuatRotate(Joint.Orientation, CgeToD3(Axis))), 0);
  end;
  Result.Columns[3] := Vector4(D3ToCge(Joint.Position), 1);
end;

{ The 12 triangles of a box from its corners (index bits: x, y, z), counter-
  clockwise seen from outside. }
function BoxTriangles(const Corners: array of TVector3): TD3IndexArray;
const
  Faces: array [0..5, 0..3] of Integer = (
    (0, 2, 6, 4), (1, 3, 7, 5), (0, 1, 5, 4), (2, 3, 7, 6), (0, 1, 3, 2), (4, 5, 7, 6));
var
  F: Integer;
  Center, Normal, FaceCenter: TVector3;
  Q: array [0..3] of Integer;
begin
  SetLength(Result, 36);
  Center := (Corners[0] + Corners[7]) / 2;
  for F := 0 to 5 do
  begin
    Q[0] := Faces[F, 0];
    Q[1] := Faces[F, 1];
    Q[2] := Faces[F, 2];
    Q[3] := Faces[F, 3];
    FaceCenter := (Corners[Q[0]] + Corners[Q[2]]) / 2;
    Normal := TVector3.CrossProduct(Corners[Q[1]] - Corners[Q[0]], Corners[Q[2]] - Corners[Q[0]]);
    if TVector3.DotProduct(Normal, FaceCenter - Center) < 0 then
    begin
      Q[1] := Faces[F, 3];
      Q[3] := Faces[F, 1];
    end;
    Result[F * 6] := Q[0];
    Result[F * 6 + 1] := Q[1];
    Result[F * 6 + 2] := Q[2];
    Result[F * 6 + 3] := Q[0];
    Result[F * 6 + 4] := Q[2];
    Result[F * 6 + 5] := Q[3];
  end;
end;

{ TD3Md5Instance }

constructor TD3Md5Instance.Create(const AModel: TD3Md5Model; const AAnims: TStrings;
  const SkinName: String);
var
  Root: TX3DRootNode;
  I, J: Integer;
  Mesh: TD3Md5Mesh;
  Geometry: TIndexedTriangleSetNode;
  TexCoord: TTextureCoordinateNode;
  UVs: array of TVector2;
  Shape: TShapeNode;
  SkinDecl: TD3Skin;
  MaterialName: String;
  AllClosed, UseHulls: Boolean;
begin
  inherited Create;
  FShown := True;
  FModel := AModel;
  AllClosed := True;
  MeshShapes := nil;
  FAnims := TStringList.Create;
  if AAnims <> nil then
    FAnims.Assign(AAnims);
  SkinDecl := nil;
  if SkinName <> '' then
    SkinDecl := Decls.Skin(SkinName);

  FPose := Copy(FModel.Joints);
  Root := TX3DRootNode.Create;
  SetLength(FCoords, FModel.Meshes.Count);
  for I := 0 to FModel.Meshes.Count - 1 do
  begin
    Mesh := FModel.Meshes[I];
    MaterialName := Mesh.Shader;
    if SkinDecl <> nil then
      MaterialName := SkinDecl.Remap(MaterialName);
    if Decls.Material(MaterialName).IsInvisible or (Length(Mesh.Tris) = 0) then
      Continue;
    FCoords[I] := TCoordinateNode.Create;
    SetLength(UVs, Length(Mesh.Verts));
    for J := 0 to High(Mesh.Verts) do
      UVs[J] := Vector2(Mesh.Verts[J].ST.X, 1 - Mesh.Verts[J].ST.Y);
    TexCoord := TTextureCoordinateNode.Create;
    TexCoord.SetPoint(UVs);
    Geometry := TIndexedTriangleSetNode.Create;
    Geometry.Coord := FCoords[I];
    Geometry.TexCoord := TexCoord;
    Geometry.SetIndex(Mesh.Tris);
    { Doom 3 triangles are clockwise from the front }
    Geometry.Ccw := False;
    Geometry.NormalPerVertex := True;
    Shape := TShapeNode.Create;
    Shape.Geometry := Geometry;
    Shape.Appearance := MaterialAppearance(MaterialName);
    MeshShapes := Concat(MeshShapes, [Shape]);
    MeshMaterials := Concat(MeshMaterials, [MaterialName]);
    if not FModel.MeshClosed(I) then
      AllClosed := False;
    Root.AddChildren(Shape);
  end;
  { big meshes that aren't closed cast with joint boxes: the open shapes
    wouldn't cast at all (CGE skips them) }
  UseHulls := (TriangleCount > MaxShadowCastingTriangles) and
    not (ClosedMeshesCastShadows and AllClosed);
  if UseHulls then
  begin
    for Shape in MeshShapes do
      Shape.Appearance.ShadowCaster := False;
    BuildShadowHulls(Root);
  end else
  if TriangleCount > MaxShadowCastingTriangles then
    WritelnLog('Doom3Md5', 'Shadows: "%s" has %d triangles, closed: casts with its triangles',
      [FModel.Name, TriangleCount]);

  AddLightLibrary(Root);
  FScene := TD3Scene.Create(nil);
  FScene.Load(Root, True);
  FScene.CastShadows := (not UseHulls) or (ShadowHullCount > 0);
  ApplyPose;
  { prefer an idle animation, as the game does }
  if not PlayAnim('idle') then
    if not PlayAnim('stand') then
      if FAnims.Count > 0 then
        PlayAnim(FAnims.Names[0]);
end;

destructor TD3Md5Instance.Destroy;
begin
  FreeAndNil(FScene);
  FAnims.Free;
  inherited Destroy;
end;

procedure TD3Md5Instance.ApplyPose;
var
  I: Integer;
begin
  FinishPose;
  { out of sight: skin it when it shows again }
  if not FShown then
  begin
    FSkinPending := True;
    Exit;
  end;
  FSkinPending := False;
  TD3Md5Model.PoseMatrices(FFinalPose, FMatrices);
  for I := 0 to High(FCoords) do
    if FCoords[I] <> nil then
    begin
      { straight into the coordinate node's list: no copies }
      FCoords[I].FdPoint.Items.Count := Length(FModel.Meshes[I].Verts);
      if FCoords[I].FdPoint.Items.Count > 0 then
        FModel.SkinMeshTo(I, FMatrices, PVector3(FCoords[I].FdPoint.Items.L));
      FCoords[I].FdPoint.Changed;
    end;
  for I := 0 to High(FHullTransforms) do
    FHullTransforms[I].Matrix := JointMatrix(FFinalPose[FHullJoints[I]]);
end;

procedure TD3Md5Instance.FinishPose;
var
  Under: array of Boolean;

  { turn joint J and the joints under it by R about J }
  procedure TurnSubtree(const J: Integer; const R: TQuaternion);
  var
    I: Integer;
    Pivot: TVector3;
  begin
    if Length(Under) <> Length(FFinalPose) then
      SetLength(Under, Length(FFinalPose));
    Pivot := FFinalPose[J].Position;
    for I := 0 to High(FFinalPose) do
    begin
      { parents come first }
      Under[I] := (I = J) or ((I > J) and (FFinalPose[I].Parent >= 0) and Under[FFinalPose[I].Parent]);
      if not Under[I] then
        Continue;
      FFinalPose[I].Position := Pivot + QuatRotate(R, FFinalPose[I].Position - Pivot);
      FFinalPose[I].Orientation := QuatNormalize(QuatMultiply(R, FFinalPose[I].Orientation));
    end;
  end;

var
  I, J, P: Integer;
  Local, ParentO: TQuaternion;
  Src: TD3JointArray;
begin
  FModsCleared := False;
  FFinalPose := Copy(FPose);
  if FModCount > 0 then
    for J := 0 to High(FFinalPose) do
      if FHasMod[J] then
        TurnSubtree(J, FJointMods[J]);
  for I := 0 to High(FCopyJoints) do
  begin
    { the source's local rotation (relative to its parent), set as this
      joint's local rotation }
    Src := FCopyJoints[I].Source.FFinalPose;
    if Length(Src) = 0 then
      Src := FCopyJoints[I].Source.FPose;
    J := FCopyJoints[I].FromJoint;
    if J > High(Src) then
      Continue;
    P := Src[J].Parent;
    if P >= 0 then
      Local := QuatMultiply(QuatConjugate(Src[P].Orientation), Src[J].Orientation)
    else
      Local := Src[J].Orientation;
    J := FCopyJoints[I].ToJoint;
    P := FFinalPose[J].Parent;
    if P >= 0 then
      ParentO := FFinalPose[P].Orientation
    else
      ParentO := Quaternion(Vector4(0, 0, 0, 1));
    TurnSubtree(J, QuatNormalize(QuatMultiply(QuatMultiply(ParentO, Local),
      QuatConjugate(FFinalPose[J].Orientation))));
  end;
end;

procedure TD3Md5Instance.SetShown(const Value: Boolean);
begin
  if FShown = Value then
    Exit;
  FShown := Value;
  if FShown and FSkinPending then
    ApplyPose;
end;

function TD3Md5Instance.Pose: TD3JointArray;
begin
  if Length(FFinalPose) = Length(FPose) then
    Result := FFinalPose
  else
    Result := FPose;
end;

procedure TD3Md5Instance.SetJointMod(const Joint: Integer; const Q: TQuaternion);
begin
  if (Joint < 0) or (Joint > High(FModel.Joints)) then
    Exit;
  if Length(FHasMod) <> Length(FModel.Joints) then
  begin
    SetLength(FHasMod, Length(FModel.Joints));
    SetLength(FJointMods, Length(FModel.Joints));
  end;
  if not FHasMod[Joint] then
    Inc(FModCount);
  FHasMod[Joint] := True;
  FJointMods[Joint] := Q;
end;

procedure TD3Md5Instance.ClearJointMods;
var
  I: Integer;
begin
  if FModCount > 0 then
    FModsCleared := True;
  for I := 0 to High(FHasMod) do
    FHasMod[I] := False;
  FModCount := 0;
end;

function TD3Md5Instance.AddCopyJoint(const Source: TD3Md5Instance; const FromName, ToName: String): Boolean;
var
  C: TD3CopyJoint;
begin
  C.Source := Source;
  C.FromJoint := Source.Model.JointIndex(FromName);
  C.ToJoint := FModel.JointIndex(ToName);
  Result := (C.FromJoint >= 0) and (C.ToJoint >= 0);
  if not Result then
    Exit;
  SetLength(FCopyJoints, Length(FCopyJoints) + 1);
  FCopyJoints[High(FCopyJoints)] := C;
end;

function TD3Md5Instance.ShadowHullCount: Integer;
begin
  Result := Length(FHullJoints);
end;

procedure TD3Md5Instance.BuildShadowHulls(const Root: TX3DRootNode);
var
  J, W, I, K, Count: Integer;
  Mesh: TD3Md5Mesh;
  BoxMin, BoxMax, Center, Half: TVector3;
  Corners: array [0..7] of TVector3;
  Shape: TShapeNode;
  Geometry: TIndexedTriangleSetNode;
  Coord: TCoordinateNode;
  Unlit: TUnlitMaterialNode;
  Transform: TMatrixTransformNode;
begin
  for J := 0 to High(FModel.Joints) do
  begin
    { the joint-space positions of the weights the joint dominates }
    Count := 0;
    BoxMin := Vector3(MaxSingle, MaxSingle, MaxSingle);
    BoxMax := -BoxMin;
    for Mesh in FModel.Meshes do
      for W := 0 to High(Mesh.Weights) do
        if (Mesh.Weights[W].Joint = J) and (Mesh.Weights[W].Bias >= 0.5) then
        begin
          for K := 0 to 2 do
          begin
            BoxMin.Data[K] := Min(BoxMin.Data[K], Mesh.Weights[W].Position.Data[K]);
            BoxMax.Data[K] := Max(BoxMax.Data[K], Mesh.Weights[W].Position.Data[K]);
          end;
          Inc(Count);
        end;
    if Count < 4 then
      Continue;
    Center := (BoxMin + BoxMax) / 2;
    Half := (BoxMax - BoxMin) * (ShadowHullScale / 2);
    { a flat box would be degenerate (CGE skips such casters) }
    for K := 0 to 2 do
      Half.Data[K] := Max(Half.Data[K], 1);
    for I := 0 to 7 do
      Corners[I] := D3ToCge(Center + Vector3(
        Half.X * (2 * (I and 1) - 1),
        Half.Y * (2 * ((I shr 1) and 1) - 1),
        Half.Z * (2 * ((I shr 2) and 1) - 1)));
    Coord := TCoordinateNode.Create;
    Coord.SetPoint(Corners);
    Geometry := TIndexedTriangleSetNode.Create;
    Geometry.Coord := Coord;
    Geometry.SetIndex(BoxTriangles(Corners));
    Geometry.Ccw := True;
    Geometry.Solid := True;
    Unlit := TUnlitMaterialNode.Create;
    Unlit.EmissiveColor := TVector3.Zero;
    Shape := TShapeNode.Create;
    Shape.Geometry := Geometry;
    Shape.Material := Unlit;
    { a shadow-only caster: not rendered (it would show where the body is
      thinner than the box), CGE still casts its shadow volumes }
    Shape.Visible := False;
    Transform := TMatrixTransformNode.Create;
    Transform.AddChildren(Shape);
    Root.AddChildren(Transform);
    SetLength(FHullJoints, Length(FHullJoints) + 1);
    FHullJoints[High(FHullJoints)] := J;
    SetLength(FHullTransforms, Length(FHullTransforms) + 1);
    FHullTransforms[High(FHullTransforms)] := Transform;
  end;
  WritelnLog('Doom3Md5', 'Shadow hulls: "%s" has %d triangles, casts with %d joint boxes',
    [FModel.Name, TriangleCount, Length(FHullJoints)]);
end;

function TD3Md5Instance.TriangleCount: Integer;
var
  M: TD3Md5Mesh;
begin
  Result := 0;
  for M in FModel.Meshes do
    Inc(Result, Length(M.Tris) div 3);
end;

function TD3Md5Instance.HasAnim(const AnimName: String): Boolean;
begin
  Result := ResolveAnim(AnimName) <> '';
end;

function TD3Md5Instance.ResolveAnim(const AName: String): String;
var
  Base, Key: String;
  I, Count: Integer;
begin
  Base := LowerCase(AName);
  if FAnims.IndexOfName(Base) >= 0 then
    Exit(Base);
  if ExtractFileExt(Base) = '.md5anim' then
    Exit(AName);
  { name1, name2...: one of them at random }
  Result := '';
  Count := 0;
  for I := 0 to FAnims.Count - 1 do
  begin
    Key := FAnims.Names[I];
    if (Length(Key) > Length(Base)) and (Copy(Key, 1, Length(Base)) = Base) and
       (StrToIntDef(Copy(Key, Length(Base) + 1, MaxInt), -1) >= 0) then
    begin
      Inc(Count);
      if Random(Count) = 0 then
        Result := Key;
    end;
  end;
end;

function TD3Md5Instance.AnimDurationOf(const AName: String): Single;
var
  Path: String;
  A: TD3Md5Anim;
begin
  Result := 0;
  Path := FAnims.Values[LowerCase(AName)];
  if (Path = '') and (ExtractFileExt(LowerCase(AName)) = '.md5anim') then
    Path := AName;
  if Path = '' then
    Exit;
  A := Md5Cache.Anim(Path);
  if A <> nil then
    Result := A.Duration;
end;

function TD3Md5Instance.AnimMovementDelta(const AName: String): TVector3;
var
  Path: String;
  A: TD3Md5Anim;
  First, Last: TD3JointArray;
begin
  Result := TVector3.Zero;
  Path := FAnims.Values[LowerCase(AName)];
  if (Path = '') and (ExtractFileExt(LowerCase(AName)) = '.md5anim') then
    Path := AName;
  if Path = '' then
    Exit;
  A := Md5Cache.Anim(Path);
  if (A = nil) or (A.NumFrames < 2) then
    Exit;
  First := nil;
  Last := nil;
  A.FramePose(0, First);
  A.FramePose(A.NumFrames - 1, Last);
  Result := Last[0].Position - First[0].Position;
end;

function TD3Md5Instance.PlayAnim(const AnimName: String; const Loop: Boolean): Boolean;
var
  Path, Resolved: String;
  A: TD3Md5Anim;
  First: TD3JointArray;
begin
  Resolved := ResolveAnim(AnimName);
  Path := FAnims.Values[Resolved];
  if (Path = '') and (ExtractFileExt(LowerCase(Resolved)) = '.md5anim') then
    Path := Resolved;
  if Path = '' then
    Exit(False);
  A := Md5Cache.Anim(Path);
  if (A = nil) or (Length(A.Hierarchy) <> Length(FModel.Joints)) then
    Exit(False);
  FAnim := A;
  FAnimTime := 0;
  FLoop := Loop;
  Paused := False;
  { its origin moves from the first frame }
  First := nil;
  FAnim.FramePose(0, First);
  FHasPrevOrigin := Length(First) > 0;
  if FHasPrevOrigin then
    FPrevOrigin := First[0].Position;
  LastOriginDelta := TVector3.Zero;
  PlayingAnim := Resolved;
  Result := True;
end;


function TD3Md5Instance.AnimFinished: Boolean;
begin
  Result := (FAnim = nil) or (not FLoop and (FAnimTime >= FAnim.Duration));
end;

procedure TD3Md5Instance.LockPoseOrigin;
var
  First: TD3JointArray;
  D: TVector3;
  I: Integer;
begin
  First := nil;
  FAnim.FramePose(0, First);
  D := Vector3(FPose[0].Position.X - First[0].Position.X, FPose[0].Position.Y - First[0].Position.Y, 0);
  for I := 0 to High(FPose) do
    FPose[I].Position := FPose[I].Position - D;
end;

function TD3Md5Instance.SetFrame(const AnimName: String; const Frame: Integer): Boolean;
begin
  Result := PlayAnim(AnimName, False);
  if not Result then
    Exit;
  FAnim.FramePose(Max(0, Frame - 1), FPose);
  ApplyPose;
  Paused := True;
end;

function TD3Md5Instance.AnimSpeed: Single;
var
  A, B: TD3JointArray;
begin
  Result := 0;
  if (FAnim = nil) or (FAnim.Duration <= 0) or (FAnim.NumFrames < 2) then
    Exit;
  A := nil;
  B := nil;
  FAnim.FramePose(0, A);
  FAnim.FramePose(FAnim.NumFrames - 1, B);
  Result := Sqrt(Sqr(B[0].Position.X - A[0].Position.X) + Sqr(B[0].Position.Y - A[0].Position.Y)) /
    FAnim.Duration;
end;

function TD3Md5Instance.AnimLength: Single;
begin
  if FAnim <> nil then
    Result := FAnim.Duration
  else
    Result := 0;
end;

function TD3Md5Instance.JointPosition(const JointName: String; out P: TVector3): Boolean;
var
  I: Integer;
begin
  I := FModel.JointIndex(JointName);
  Result := I >= 0;
  if Result then
    P := D3ToCge(Pose[I].Position)
  else
    P := TVector3.Zero;
end;

function TD3Md5Instance.JointTransform(const JointName: String; out M: TMatrix4): Boolean;
var
  I: Integer;
  Bind: TMatrix4;
begin
  I := FModel.JointIndex(JointName);
  Result := I >= 0;
  if not Result then
  begin
    M := TMatrix4.Identity;
    Exit;
  end;
  { current joint * inverse of the bind pose rotation (a transpose) }
  Bind := JointMatrix(FModel.Joints[I]);
  Bind.Columns[3] := Vector4(0, 0, 0, 1);
  M := JointMatrix(Pose[I]) * Bind.Transpose;
end;

procedure TD3Md5Instance.FireFrameCommands(const FromTime, ToTime: Single);
var
  I, K, KF, Frame, F0, F1, N: Integer;
  Line: String;
begin
  { the frames (0-based) entered in (FromTime, ToTime], looping like PoseAt }
  N := FAnim.NumFrames;
  if N <= 0 then
    Exit;
  F0 := Trunc(FromTime * FAnim.FrameRate);
  F1 := Trunc(ToTime * FAnim.FrameRate);
  if FromTime <= 0 then
    F0 := -1;
  for K := F0 + 1 to Min(F1, F0 + N) do
  begin
    if FLoop then
      KF := K mod N
    else
    begin
      if K > N - 1 then
        Break;
      KF := K;
    end;
    for I := 0 to FrameCommands.Count - 1 do
    begin
      if FrameCommands.Names[I] <> PlayingAnim then
        Continue;
      Line := FrameCommands.ValueFromIndex[I];
      Frame := StrToIntDef(Copy(Line, 1, Pos(' ', Line) - 1), 1) - 1;
      if Frame = KF then
        OnFrameCommand(Self, Copy(Line, Pos(' ', Line) + 1, MaxInt));
    end;
  end;
end;


procedure TD3Md5Instance.Update(const SecondsPassed: Single);
var
  OldTime: Single;
  First, Last: TD3JointArray;
begin
  if (FAnim = nil) or Paused then
  begin
    LastOriginDelta := TVector3.Zero;
    { a held pose still turns with its joint mods and copied joints }
    if (FModCount > 0) or FModsCleared or (Length(FCopyJoints) > 0) or (Length(FFinalPose) <> Length(FPose)) then
      ApplyPose;
    Exit;
  end;
  OldTime := FAnimTime;
  FAnimTime := FAnimTime + SecondsPassed;
  if Assigned(OnFrameCommand) and (FrameCommands <> nil) then
    FireFrameCommands(OldTime, FAnimTime);
  FAnim.PoseAt(FAnimTime, FLoop, FPose);
  { the origin's move since the last update (across a cycle's wrap: to
    the last frame, then from the first) }
  LastOriginDelta := TVector3.Zero;
  if FHasPrevOrigin and (Length(FPose) > 0) then
  begin
    if FLoop and (FAnim.Duration > 0) and
       (Floor(FAnimTime / FAnim.Duration) <> Floor(OldTime / FAnim.Duration)) then
    begin
      First := nil;
      Last := nil;
      FAnim.FramePose(0, First);
      FAnim.FramePose(FAnim.NumFrames - 1, Last);
      LastOriginDelta := (Last[0].Position - FPrevOrigin) + (FPose[0].Position - First[0].Position);
    end else
      LastOriginDelta := FPose[0].Position - FPrevOrigin;
    LastOriginDelta.Z := 0;
  end;
  if Length(FPose) > 0 then
  begin
    FPrevOrigin := FPose[0].Position;
    FHasPrevOrigin := True;
  end;
  if LockOrigin then
    LockPoseOrigin;
  ApplyPose;
end;

initialization
  Md5Cache := TD3Md5Cache.Create;
finalization
  FreeAndNil(Md5Cache);
end.
