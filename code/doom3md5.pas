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
  Doom3Lexer;

type
  TD3Joint = record
    Name: String;
    Parent: Integer;
    Position: TVector3;
    Orientation: TQuaternion;
  end;
  TD3JointArray = array of TD3Joint;

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
    Name: String;
    Joints: TD3JointArray;
    Meshes: specialize TObjectList<TD3Md5Mesh>;
    constructor Create;
    destructor Destroy; override;
    function LoadFromText(const Text: String): Boolean;
    function JointIndex(const AName: String): Integer;
    { Skin a mesh with absolute joints into Doom 3 coordinates. }
    procedure SkinMesh(const MeshIndex: Integer; const Pose: TD3JointArray;
      var Positions: array of TVector3);
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
  TD3Md5Instance = class
  strict private
    FModel: TD3Md5Model;
    FScene: TCastleScene;
    FCoords: array of TCoordinateNode;
    FPositions: array of array of TVector3;
    FPose: TD3JointArray;
    FAnim: TD3Md5Anim;
    FAnimTime: Single;
    FLoop: Boolean;
    FAnims: TStringList;
    procedure ApplyPose;
  public
    { Anims: anim name -> md5anim path (from a model decl). }
    constructor Create(const AModel: TD3Md5Model; const AAnims: TStrings;
      const SkinName: String = '');
    destructor Destroy; override;
    { Start an animation by name (from the model decl) or path. False when
      it doesn't exist. }
    function PlayAnim(const AnimName: String; const Loop: Boolean = True): Boolean;
    function HasAnim(const AnimName: String): Boolean;
    function TriangleCount: Integer;
    function AnimFinished: Boolean;
    procedure Update(const SecondsPassed: Single);
    property Scene: TCastleScene read FScene;
    property Model: TD3Md5Model read FModel;
  end;

var
  Md5Cache: TD3Md5Cache;
  { md5 models with more triangles don't cast shadow volumes }
  MaxShadowCastingTriangles: Integer = 1500;

implementation

uses
  Math,
  CastleLog,
  Doom3Files, Doom3Decls, Doom3MapFile, Doom3Materials, Doom3LightEffects;

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
begin
  inherited Create;
  FModel := AModel;
  FAnims := TStringList.Create;
  if AAnims <> nil then
    FAnims.Assign(AAnims);
  SkinDecl := nil;
  if SkinName <> '' then
    SkinDecl := Decls.Skin(SkinName);

  FPose := Copy(FModel.Joints);
  Root := TX3DRootNode.Create;
  SetLength(FCoords, FModel.Meshes.Count);
  SetLength(FPositions, FModel.Meshes.Count);
  for I := 0 to FModel.Meshes.Count - 1 do
  begin
    Mesh := FModel.Meshes[I];
    MaterialName := Mesh.Shader;
    if SkinDecl <> nil then
      MaterialName := SkinDecl.Remap(MaterialName);
    if Decls.Material(MaterialName).IsInvisible or (Length(Mesh.Tris) = 0) then
      Continue;
    SetLength(FPositions[I], Length(Mesh.Verts));
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
    Root.AddChildren(Shape);
  end;

  AddLightLibrary(Root);
  FScene := TCastleScene.Create(nil);
  FScene.Load(Root, True);
  { CGE finds shadow volume silhouettes by comparing every edge with every
    other edge, again whenever the mesh animates: only small meshes cast }
  FScene.CastShadows := TriangleCount <= MaxShadowCastingTriangles;
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
  for I := 0 to High(FCoords) do
    if FCoords[I] <> nil then
    begin
      FModel.SkinMesh(I, FPose, FPositions[I]);
      FCoords[I].SetPoint(FPositions[I]);
    end;
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
  Result := FAnims.IndexOfName(LowerCase(AnimName)) >= 0;
end;

function TD3Md5Instance.PlayAnim(const AnimName: String; const Loop: Boolean): Boolean;
var
  Path: String;
  A: TD3Md5Anim;
begin
  Path := FAnims.Values[LowerCase(AnimName)];
  if (Path = '') and (ExtractFileExt(LowerCase(AnimName)) = '.md5anim') then
    Path := AnimName;
  if Path = '' then
    Exit(False);
  A := Md5Cache.Anim(Path);
  if (A = nil) or (Length(A.Hierarchy) <> Length(FModel.Joints)) then
    Exit(False);
  FAnim := A;
  FAnimTime := 0;
  FLoop := Loop;
  Result := True;
end;

function TD3Md5Instance.AnimFinished: Boolean;
begin
  Result := (FAnim = nil) or (not FLoop and (FAnimTime >= FAnim.Duration));
end;

procedure TD3Md5Instance.Update(const SecondsPassed: Single);
begin
  if FAnim = nil then
    Exit;
  FAnimTime := FAnimTime + SecondsPassed;
  FAnim.PoseAt(FAnimTime, FLoop, FPose);
  ApplyPose;
end;

initialization
  Md5Cache := TD3Md5Cache.Create;
finalization
  FreeAndNil(Md5Cache);
end.
