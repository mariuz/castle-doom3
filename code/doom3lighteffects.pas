// Doom 3 light volumes as Castle Game Engine light shader effects.
//
// Doom 3 doesn't attenuate lights by distance. A light is a volume: a box
// (point lights, light_radius) or a frustum (projected lights, light_target
// / light_up / light_right / light_start / light_end). Every lit point is
// mapped into the light's texture space (s, t, q): Doom 3 samples the
// projection image (the light shader's stage map, e.g. lights/round.tga) at
// (s, t) and the falloff image (lightFalloffImage) at (q, 0.5); nothing
// outside 0..1 is lit (R_DeriveLightData's lightProject).
//
// Each X3D light gets an Effect plugging PLUG_light_scale. It needs the
// fragment's world position: castle_vertex_eye (the Phong shader's varying)
// times castle_CameraInverseMatrix (CGE's EyeWorldSpace shader library).
// Shader libraries are enabled by appearance / group effects only, so every
// scene the map builds adds LightLibraryEffect to its root (AddLightLibrary).
//
// The light matrix maps CGE world coordinates to (s * w, t * w, q, w);
// point lights have w = 1, projected lights divide by depth.
//
// The projection / falloff images are approximated analytically (a soft
// disc or square, Doom 3's default falloff curves): textures referenced only
// by light effects aren't bound by CGE's renderer (they read as black).
unit Doom3LightEffects;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  CastleVectors, X3DNodes, X3DFields, CastleRenderOptions;

{ Texture space of a point light: a box of half sizes Radius around Origin
  rotated by Rot (Doom 3 coordinates). }
function PointLightMatrix(const Origin: TVector3; const Rot: TMatrix3;
  const Radius: TVector3): TMatrix4;

{ Texture space of a projected light: a pyramid from Origin towards Target,
  Right and Up being half its width and height at Target (local Doom 3
  vectors, rotated by Rot); falloff from Start to End along the target. }
function ProjectedLightMatrix(const Origin: TVector3; const Rot: TMatrix3;
  const Target, Up, Right, Start, End_: TVector3; const HasStartEnd: Boolean): TMatrix4;

{ Doom 3 texture space (s, t, q) of a CGE world point, -1 values when the
  projective w is not positive. }
function LightTexCoord(const M: TMatrix4; const WorldCge: TVector3): TVector3;

type
  { Analytic stand-ins for Doom 3's light projection images: textures
    referenced only by light effects are not bound by CGE's renderer, so
    the shape is chosen from the image's name. }
  TD3LightShape = (lsRound, lsSquare, lsFull);

{ The shape for a projection image name ('' = Doom 3's default). }
function ProjectionShape(const ImageName: String): TD3LightShape;

{ The Effect for light number Index (names its uniform uniquely). The
  falloff along the light's depth follows Doom 3's default falloff images
  for point lights (a box fading at both ends) and projected lights
  (fading towards light_end). }
function CreateLightEffect(const Index: Integer; const M: TMatrix4;
  const ProjectionImage: String; const Projected: Boolean): TEffectNode;

{ The light's strength (0..1) at a CGE world point: the same volume, shape
  and falloff as the shader (for picking the shadow casting light). }
function LightVolumeStrength(const M: TMatrix4; const Shape: TD3LightShape;
  const Projected: Boolean; const WorldCge: TVector3): Single;

{ An Effect enabling CGE's EyeWorldSpace shader library for a group. }
function LightLibraryEffect: TEffectNode;

{ Add LightLibraryEffect to a root node (every scene lit by map lights). }
procedure AddLightLibrary(const Root: TAbstractGroupingNode);

var
  { Set False to use plain spherical lights (no effects). }
  LightVolumes: Boolean = True;

implementation

uses
  Math,
  Doom3MapFile;

{ Set row R of M to (A, B, C, D): M * v = sum over rows. CGE's TMatrix4 is
  column-major, Data[Column, Row]. }
procedure SetRow(var M: TMatrix4; const R: Integer; const A, B, C, D: Single);
begin
  M.Data[0, R] := A;
  M.Data[1, R] := B;
  M.Data[2, R] := C;
  M.Data[3, R] := D;
end;

{ Row computing dot(P - Origin, V) * Scale + Add for a CGE world point,
  where P = CgeToD3(world) = (x, -z, y), so dot(P, V) = x V.x + y V.z - z V.y. }
procedure SetDotRow(var M: TMatrix4; const R: Integer; const V, Origin: TVector3;
  const Scale, Add: Single);
begin
  SetRow(M, R, V.X * Scale, V.Z * Scale, -V.Y * Scale,
    -TVector3.DotProduct(Origin, V) * Scale + Add);
end;

function Axis(const Rot: TMatrix3; const I: Integer): TVector3;
begin
  Result := Vector3(Rot.Data[I, 0], Rot.Data[I, 1], Rot.Data[I, 2]);
end;

function RotateLocal(const Rot: TMatrix3; const V: TVector3): TVector3;
begin
  { idMat3 rows are the rotated axes: local (x, y, z) -> x row0 + y row1 + z row2 }
  Result := Axis(Rot, 0) * V.X + Axis(Rot, 1) * V.Y + Axis(Rot, 2) * V.Z;
end;

function PointLightMatrix(const Origin: TVector3; const Rot: TMatrix3;
  const Radius: TVector3): TMatrix4;
begin
  Result := TMatrix4.Zero;
  SetDotRow(Result, 0, Axis(Rot, 0), Origin, 0.5 / Max(1, Radius.X), 0.5);
  SetDotRow(Result, 1, Axis(Rot, 1), Origin, 0.5 / Max(1, Radius.Y), 0.5);
  SetDotRow(Result, 2, Axis(Rot, 2), Origin, 0.5 / Max(1, Radius.Z), 0.5);
  SetRow(Result, 3, 0, 0, 0, 1);
end;

function ProjectedLightMatrix(const Origin: TVector3; const Rot: TMatrix3;
  const Target, Up, Right, Start, End_: TVector3; const HasStartEnd: Boolean): TMatrix4;
var
  T, U, R, TN: TVector3;
  TT, UU, RR, S0, E0: Single;
begin
  T := RotateLocal(Rot, Target);
  U := RotateLocal(Rot, Up);
  R := RotateLocal(Rot, Right);
  TT := Max(1e-6, T.LengthSqr);
  UU := Max(1e-6, U.LengthSqr);
  RR := Max(1e-6, R.LengthSqr);
  Result := TMatrix4.Zero;
  { w = q = depth along the target, 1 at the target }
  SetDotRow(Result, 3, T, Origin, 1 / TT, 0);
  { s * w = 0.5 w + 0.5 (p . R) / |R|^2, t likewise with Up }
  SetDotRow(Result, 0, T / TT * 0.5 + R / RR * 0.5, Origin, 1, 0);
  SetDotRow(Result, 1, T / TT * 0.5 + U / UU * 0.5, Origin, 1, 0);
  { falloff from start to end along the target }
  if HasStartEnd then
  begin
    TN := T / Sqrt(TT);
    S0 := TVector3.DotProduct(RotateLocal(Rot, Start), TN);
    E0 := TVector3.DotProduct(RotateLocal(Rot, End_), TN);
    if Abs(E0 - S0) < 1 then
      E0 := S0 + 1;
    SetDotRow(Result, 2, TN, Origin, 1 / (E0 - S0), -S0 / (E0 - S0));
  end else
    SetDotRow(Result, 2, T, Origin, 1 / TT, 0);
end;

function LightTexCoord(const M: TMatrix4; const WorldCge: TVector3): TVector3;
var
  P: TVector4;
begin
  P := M * Vector4(WorldCge, 1);
  if P.W <= 0 then
    Exit(Vector3(-1, -1, -1));
  Result := Vector3(P.X / P.W, P.Y / P.W, P.Z);
end;

function ProjectionShape(const ImageName: String): TD3LightShape;
var
  L: String;
begin
  L := LowerCase(ImageName);
  if L = '' then
    Result := lsRound
  else
  if Pos('square', L) > 0 then
    Result := lsSquare
  else
  if (Pos('bright', L) > 0) or (Pos('white', L) > 0) or (Pos('nofalloff', L) > 0) then
    Result := lsFull
  else
    Result := lsRound;
end;

function LightEffectCode(const N: String; const Shape: TD3LightShape; const Projected: Boolean): String;
var
  ProjCode, FallCode: String;
begin
  case Shape of
    { gradients brightest at the center, like lights/squarelight1 and
      lights/round }
    lsSquare:
      ProjCode := '  vec2 d2 = abs(st * 2.0 - 1.0);' + LineEnding +
                  '  float projection = 1.0 - smoothstep(0.0, 1.0, max(d2.x, d2.y));' + LineEnding;
    lsFull:
      ProjCode := '  float projection = 1.0;' + LineEnding;
    else
      ProjCode := '  float projection = 1.0 - smoothstep(0.0, 1.0, length(st * 2.0 - 1.0));' + LineEnding;
  end;
  if Projected then
    FallCode := '  float falloff = (1.0 - smoothstep(0.85, 1.0, p.z)) * smoothstep(0.0, 0.05, p.z);' + LineEnding
  else
    FallCode := '  float falloff = 1.0 - smoothstep(0.3, 1.0, abs(p.z * 2.0 - 1.0));' + LineEnding;

  Result :=
    'uniform mat4 castle_CameraInverseMatrix;' + LineEnding +
    'varying vec4 castle_vertex_eye;' + LineEnding +
    'uniform mat4 d3_light_matrix_' + N + ';' + LineEnding +
    'void PLUG_light_scale(inout float scale, const in vec3 normal_eye, const in vec3 light_dir)' + LineEnding +
    '{' + LineEnding +
    '  vec4 p = d3_light_matrix_' + N + ' * (castle_CameraInverseMatrix * castle_vertex_eye);' + LineEnding +
    '  if (p.w <= 0.0) { scale = 0.0; return; }' + LineEnding +
    '  vec2 st = p.xy / p.w;' + LineEnding +
    '  if (st.x < 0.0 || st.x > 1.0 || st.y < 0.0 || st.y > 1.0 || p.z < 0.0 || p.z > 1.0)' + LineEnding +
    '  { scale = 0.0; return; }' + LineEnding +
    ProjCode + FallCode +
    '  scale *= projection * falloff;' + LineEnding +
    '}' + LineEnding;
end;

function CreateLightEffect(const Index: Integer; const M: TMatrix4;
  const ProjectionImage: String; const Projected: Boolean): TEffectNode;
var
  N: String;
  Part: TEffectPartNode;
begin
  N := IntToStr(Index);
  Result := TEffectNode.Create;
  Result.Language := slGLSL;
  Result.UniformMissing := umIgnore;
  Result.AddCustomField(TSFMatrix4f.Create(Result, True, 'd3_light_matrix_' + N, M));
  Part := TEffectPartNode.Create;
  Part.ShaderType := stFragment;
  Part.Contents := LightEffectCode(N, ProjectionShape(ProjectionImage), Projected);
  Result.SetParts([Part]);
end;

function SmoothStep(const E0, E1, X: Single): Single;
var
  T: Single;
begin
  T := Min(1, Max(0, (X - E0) / (E1 - E0)));
  Result := T * T * (3 - 2 * T);
end;

function LightVolumeStrength(const M: TMatrix4; const Shape: TD3LightShape;
  const Projected: Boolean; const WorldCge: TVector3): Single;
var
  TC: TVector3;
  Projection, Falloff: Single;
begin
  TC := LightTexCoord(M, WorldCge);
  if (TC.X < 0) or (TC.X > 1) or (TC.Y < 0) or (TC.Y > 1) or (TC.Z < 0) or (TC.Z > 1) then
    Exit(0);
  case Shape of
    lsSquare: Projection := 1 - SmoothStep(0, 1, Max(Abs(TC.X * 2 - 1), Abs(TC.Y * 2 - 1)));
    lsFull: Projection := 1;
    else Projection := 1 - SmoothStep(0, 1, Sqrt(Sqr(TC.X * 2 - 1) + Sqr(TC.Y * 2 - 1)));
  end;
  if Projected then
    Falloff := (1 - SmoothStep(0.85, 1, TC.Z)) * SmoothStep(0, 0.05, TC.Z)
  else
    Falloff := 1 - SmoothStep(0.3, 1, Abs(TC.Z * 2 - 1));
  Result := Projection * Falloff;
end;

function LightLibraryEffect: TEffectNode;
begin
  Result := TEffectNode.Create;
  Result.Language := slGLSL;
  Result.UniformMissing := umIgnore;
  Result.FdShaderLibraries.Items.Add('castle-shader:/EyeWorldSpace.glsl');
end;

procedure AddLightLibrary(const Root: TAbstractGroupingNode);
begin
  if LightVolumes then
    Root.AddChildren(LightLibraryEffect);
end;

end.
