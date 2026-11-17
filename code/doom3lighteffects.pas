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
// through position_eye_to_world_space (CGE's EyeWorldSpace shader library).
// Shader libraries are enabled by appearance / group effects only, so every
// scene the map builds adds LightLibraryEffect to its root (AddLightLibrary).
//
// The light matrix maps CGE world coordinates to (s * w, t * w, q, w);
// point lights have w = 1, projected lights divide by depth.
//
// Textures referenced only by light effects aren't bound by CGE's renderer
// (they read as black), so the images are measured instead (LightProfile):
// the projection image's brightness from its center to its edge (9 samples,
// averaged over the 4 axes) and how square it is (the norm measuring the
// distance from the center), the falloff image's brightness along q (9
// samples). The shader interpolates them (per-light mat3 uniforms).
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

type
  TD3LightProfileSamples = array [0..8] of Single;

  { A light's projection and falloff images as the shader uses them. }
  TD3LightProfile = record
    { the projection image's brightness at distance i / 8 from its center
      (1 = the edge), the average of the 4 axes }
    Projection: TD3LightProfileSamples;
    { the distance from the center is (|x|^Norm + |y|^Norm)^(1 / Norm):
      2 for round images, more for square ones (over 15: max(|x|, |y|)) }
    Norm: Single;
    { the falloff image's brightness at q = i / 8 }
    Falloff: TD3LightProfileSamples;
  end;

{ The profile of a light's projection image and falloff image (image
  programs, '' = none; Doom 3's _noFalloff is 1 everywhere). Images that
  don't load get the analytic stand-ins of ProjectionShape and Doom 3's
  default falloff curves. Cached. }
function LightProfile(const ProjectionImage, FalloffImage: String;
  const Projected: Boolean): TD3LightProfile;

{ The profile's value at X (0..1), linear between the samples. }
function ProfileAt(const Samples: TD3LightProfileSamples; const X: Single): Single;

{ The hue of a light's projection image, which the analytic shapes lose
  (lights/hellgate1 is red, lights/vivlight cyan): the image's colors summed
  over the sum of each pixel's brightest channel, so a white or gray image
  gives (1, 1, 1) and the brightest channel stays near 1. (1, 1, 1) when the
  image is missing. Cached by name. }
function ProjectionTint(const ImageName: String): TVector3;

{ The Effect for light number Index (names its uniform uniquely). The
  falloff along the light's depth follows Doom 3's default falloff images
  for point lights (a box fading at both ends) and projected lights
  (fading towards light_end). }
function CreateLightEffect(const Index: Integer; const M: TMatrix4;
  const Profile: TD3LightProfile): TEffectNode;

type
  { One shared Effect per light shape and kind (point / projected), for a
    map's lights (all in one scene). }
  TD3SharedLightEffects = array [TD3LightShape, Boolean] of TEffectNode;

{ Give Light its light volume: with SharedLightEffectsAvailable, the
  shared Effect for its shape and kind (created in Shared on first use)
  and its matrix as the light's own custom field (a per-light uniform,
  CGE change K): lights of the same kind then share shader programs.
  Otherwise its own Effect (CreateLightEffect, Index names the uniform). }
procedure SetLightVolume(const Light: TAbstractLightNode; var Shared: TD3SharedLightEffects;
  const Index: Integer; const M: TMatrix4; const Profile: TD3LightProfile);
{ Move a light's volume (SetLightVolume's matrix) when the light moves. }
procedure SetLightVolumeMatrix(const Light: TAbstractLightNode; const M: TMatrix4);

{ CGE passes light nodes' custom fields to their effects as per-light
  uniforms (light nodes have interface declarations). }
function SharedLightEffectsAvailable: Boolean;

{ The light's strength (0..1) at a CGE world point: the same volume, shape
  and falloff as the shader (for picking the shadow casting light). }
function LightVolumeStrength(const M: TMatrix4; const Profile: TD3LightProfile;
  const WorldCge: TVector3): Single;

{ An Effect enabling CGE's EyeWorldSpace shader library for a group. }
function LightLibraryEffect: TEffectNode;

{ Add LightLibraryEffect to a root node (every scene lit by map lights). }
procedure AddLightLibrary(const Root: TAbstractGroupingNode);

var
  { Set False to use plain spherical lights (no effects). }
  LightVolumes: Boolean = True;
  { Set False to give every light its own Effect even when CGE could share
    them (r_sharedLightEffects 0). }
  SharedLightEffects: Boolean = True;

implementation

uses
  Math, Generics.Collections,
  CastleImages,
  Doom3MapFile, Doom3Images;

var
  TintCache: specialize TDictionary<String, TVector3>;
  ProfileCache: specialize TDictionary<String, TD3LightProfile>;

function SmoothStep(const E0, E1, X: Single): Single; forward;

function ProfileAt(const Samples: TD3LightProfileSamples; const X: Single): Single;
var
  T: Single;
  I: Integer;
begin
  T := EnsureRange(X, 0, 1) * 8;
  I := Min(7, Trunc(T));
  Result := Samples[I] + (Samples[I + 1] - Samples[I]) * (T - I);
end;

{ The brightest channel of the pixel nearest to (S, T), clamped to the image. }
function ImageValue(const Img: TCastleImage; const S, T: Single): Single;
var
  C: TVector4;
begin
  C := Img.Colors[
    EnsureRange(Round(S * (Img.Width - 1)), 0, Img.Width - 1),
    EnsureRange(Round(T * (Img.Height - 1)), 0, Img.Height - 1), 0];
  Result := Max(C.X, Max(C.Y, C.Z));
end;

function LoadProfileImage(const Name: String): TCastleImage;
begin
  try
    Result := EvaluateImageProgram(Name, ikColor);
  except
    Result := nil;
  end;
end;

function LightProfile(const ProjectionImage, FalloffImage: String;
  const Projected: Boolean): TD3LightProfile;
const
  Norms: array [0..7] of Single = (1, 1.5, 2, 3, 4, 6, 8, 100);
var
  Key, Fall: String;
  Img: TCastleImage;
  I, J, Best: Integer;
  D, H, Err, BestErr, Predicted, Diag: Single;
begin
  Key := LowerCase(Trim(ProjectionImage)) + '|' + LowerCase(Trim(FalloffImage)) + '|' +
    BoolToStr(Projected, '1', '0');
  if ProfileCache = nil then
    ProfileCache := specialize TDictionary<String, TD3LightProfile>.Create;
  if ProfileCache.TryGetValue(Key, Result) then
    Exit;

  { the projection }
  Img := nil;
  if Trim(ProjectionImage) <> '' then
    Img := LoadProfileImage(LowerCase(Trim(ProjectionImage)));
  if Img <> nil then
  try
    for I := 0 to 8 do
    begin
      H := I / 16;
      Result.Projection[I] := (ImageValue(Img, 0.5 - H, 0.5) + ImageValue(Img, 0.5 + H, 0.5) +
        ImageValue(Img, 0.5, 0.5 - H) + ImageValue(Img, 0.5, 0.5 + H)) / 4;
    end;
    { the norm whose distances predict the diagonals best }
    Best := 2;
    BestErr := MaxSingle;
    for J := 0 to High(Norms) do
    begin
      Err := 0;
      for I := 1 to 6 do
      begin
        D := I / 8; // along each axis
        H := D / 2;
        Diag := (ImageValue(Img, 0.5 - H, 0.5 - H) + ImageValue(Img, 0.5 + H, 0.5 - H) +
          ImageValue(Img, 0.5 - H, 0.5 + H) + ImageValue(Img, 0.5 + H, 0.5 + H)) / 4;
        if Norms[J] > 15 then
          Predicted := ProfileAt(Result.Projection, D)
        else
          Predicted := ProfileAt(Result.Projection, D * Power(2, 1 / Norms[J]));
        Err := Err + Sqr(Predicted - Diag);
      end;
      if Err < BestErr then
      begin
        BestErr := Err;
        Best := J;
      end;
    end;
    Result.Norm := Norms[Best];
  finally
    Img.Free;
  end else
  begin
    { no image: the analytic stand-ins }
    for I := 0 to 8 do
      if ProjectionShape(ProjectionImage) = lsFull then
        Result.Projection[I] := 1
      else
        Result.Projection[I] := 1 - SmoothStep(0, 1, I / 8);
    if ProjectionShape(ProjectionImage) = lsSquare then
      Result.Norm := 100
    else
      Result.Norm := 2;
  end;

  { the falloff }
  Fall := LowerCase(Trim(FalloffImage));
  Img := nil;
  if (Fall <> '') and (Fall <> '_nofalloff') then
    Img := LoadProfileImage(Fall);
  if Img <> nil then
  try
    for I := 0 to 8 do
      Result.Falloff[I] := ImageValue(Img, I / 8, 0.5);
  finally
    Img.Free;
  end else
  if Fall = '_nofalloff' then
  begin
    for I := 0 to 8 do
      Result.Falloff[I] := 1;
  end else
    for I := 0 to 8 do
      if Projected then
        Result.Falloff[I] := (1 - SmoothStep(0.85, 1, I / 8)) * SmoothStep(0, 0.05, I / 8)
      else
        Result.Falloff[I] := 1 - SmoothStep(0.3, 1, Abs(I / 8 * 2 - 1));

  ProfileCache.AddOrSetValue(Key, Result);
end;

function ProjectionTint(const ImageName: String): TVector3;
var
  Key: String;
  Img: TCastleImage;
  X, Y, StepX, StepY: Integer;
  C: TVector4;
  SumR, SumG, SumB, SumMax, M: Double;
begin
  Result := Vector3(1, 1, 1);
  Key := LowerCase(Trim(ImageName));
  if Key = '' then
    Exit;
  if TintCache = nil then
    TintCache := specialize TDictionary<String, TVector3>.Create;
  if TintCache.TryGetValue(Key, Result) then
    Exit;
  Result := Vector3(1, 1, 1);
  try
    Img := EvaluateImageProgram(Key, ikColor);
  except
    Img := nil;
  end;
  if Img <> nil then
  try
    SumR := 0;
    SumG := 0;
    SumB := 0;
    SumMax := 0;
    { 64 x 64 samples are plenty for a hue }
    StepX := Max(1, Img.Width div 64);
    StepY := Max(1, Img.Height div 64);
    Y := 0;
    while Y < Img.Height do
    begin
      X := 0;
      while X < Img.Width do
      begin
        C := Img.Colors[X, Y, 0];
        M := Max(C.X, Max(C.Y, C.Z));
        SumR := SumR + C.X;
        SumG := SumG + C.Y;
        SumB := SumB + C.Z;
        SumMax := SumMax + M;
        Inc(X, StepX);
      end;
      Inc(Y, StepY);
    end;
    if SumMax > 0 then
      Result := Vector3(SumR / SumMax, SumG / SumMax, SumB / SumMax);
  finally
    Img.Free;
  end;
  TintCache.AddOrSetValue(Key, Result);
end;

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

function GlslFloat(const F: Single): String;
begin
  Result := FormatFloat('0.0#####', F, DefaultFormatSettings);
end;

{ The samples as a GLSL mat3 constructor (column i holds samples 3i..3i+2). }
function GlslMat3(const Samples: TD3LightProfileSamples): String;
var
  I: Integer;
begin
  Result := 'mat3(';
  for I := 0 to 8 do
  begin
    if I > 0 then
      Result := Result + ', ';
    Result := Result + GlslFloat(Samples[I]);
  end;
  Result := Result + ')';
end;

function ProfileMatrix(const Samples: TD3LightProfileSamples): TMatrix3;
var
  I: Integer;
begin
  for I := 0 to 8 do
    Result.Data[I div 3, I mod 3] := Samples[I];
end;

{ The light volume's code. N is the light's uniform name suffix: its index,
  or "<Light>" (CGE puts the light number there) for the shared effect,
  whose profile comes from the per-light uniforms d3_light_proj_<N>,
  d3_light_fall_<N> (mat3: 9 samples) and d3_light_norm_<N>; so all lights
  share one code and a shape's shader program depends on how many lights
  reach it, not on their kinds in each slot (in game/caverns1 that was 600
  programs for the first view and 200 to 500 more after most loads of a
  save, when other lights were on). Without Uniforms the profile is in the
  code (an effect per light). }
function LightEffectCodeProfile(const N: String; const Profile: TD3LightProfile;
  const Uniforms: Boolean): String;
var
  Decl, ProjM, FallM, NormV: String;
begin
  if Uniforms then
  begin
    Decl :=
      'uniform mat3 d3_light_proj_' + N + ';' + LineEnding +
      'uniform mat3 d3_light_fall_' + N + ';' + LineEnding +
      'uniform float d3_light_norm_' + N + ';' + LineEnding;
    ProjM := 'd3_light_proj_' + N;
    FallM := 'd3_light_fall_' + N;
    NormV := 'd3_light_norm_' + N;
  end else
  begin
    Decl := '';
    ProjM := GlslMat3(Profile.Projection);
    FallM := GlslMat3(Profile.Falloff);
    NormV := GlslFloat(Profile.Norm);
  end;

  { On OpenGLES all fragment shader parts are glued into one source: the
    Phong shader declares castle_vertex_eye, the EyeWorldSpace library
    castle_CameraInverseMatrix, and every light's effect is in it, so the
    shared declarations are guarded (separate sources on desktop OpenGL,
    so the profile lookup is a macro: a function in each would be defined
    twice in the program). D3_PROFILE(m, x): the 9 samples of m at x (0..1),
    linear between them (a tent of width 1/8 around each). }
  Result :=
    '#ifndef D3_LIGHT_VOLUME_DECLARATIONS' + LineEnding +
    '#define D3_LIGHT_VOLUME_DECLARATIONS' + LineEnding +
    '#ifndef GL_ES' + LineEnding +
    'varying vec4 castle_vertex_eye;' + LineEnding +
    '#endif' + LineEnding +
    'vec4 position_eye_to_world_space(vec4 position_eye);' + LineEnding +
    '#endif' + LineEnding +
    '#ifndef D3_PROFILE' + LineEnding +
    '#define D3_PROFILE(m, x) (' +
      'dot((m)[0], max(vec3(0.0), 1.0 - abs((x) * 8.0 - vec3(0.0, 1.0, 2.0)))) + ' +
      'dot((m)[1], max(vec3(0.0), 1.0 - abs((x) * 8.0 - vec3(3.0, 4.0, 5.0)))) + ' +
      'dot((m)[2], max(vec3(0.0), 1.0 - abs((x) * 8.0 - vec3(6.0, 7.0, 8.0)))))' + LineEnding +
    '#endif' + LineEnding +
    'uniform mat4 d3_light_matrix_' + N + ';' + LineEnding +
    Decl +
    'void PLUG_light_scale(inout float scale, const in vec3 normal_eye, const in vec3 light_dir)' + LineEnding +
    '{' + LineEnding +
    '  vec4 p = d3_light_matrix_' + N + ' * position_eye_to_world_space(castle_vertex_eye);' + LineEnding +
    '  if (p.w <= 0.0) { scale = 0.0; return; }' + LineEnding +
    '  vec2 st = p.xy / p.w;' + LineEnding +
    '  if (st.x < 0.0 || st.x > 1.0 || st.y < 0.0 || st.y > 1.0 || p.z < 0.0 || p.z > 1.0)' + LineEnding +
    '  { scale = 0.0; return; }' + LineEnding +
    '  vec2 d2 = max(abs(st * 2.0 - 1.0), vec2(1e-6));' + LineEnding +
    '  float norm = ' + NormV + ';' + LineEnding +
    { round and square images without pow (most lights; the branch is
      on a uniform, the same for the whole draw) }
    '  float dist = min(1.0, (norm > 15.0) ? max(d2.x, d2.y) :' + LineEnding +
    '    (abs(norm - 2.0) < 0.01) ? length(d2) :' + LineEnding +
    '    pow(pow(d2.x, norm) + pow(d2.y, norm), 1.0 / norm));' + LineEnding +
    '  float projection = D3_PROFILE(' + ProjM + ', dist);' + LineEnding +
    '  float falloff = D3_PROFILE(' + FallM + ', p.z);' + LineEnding +
    '  scale *= projection * falloff;' + LineEnding +
    '}' + LineEnding;
end;

function CreateLightEffect(const Index: Integer; const M: TMatrix4;
  const Profile: TD3LightProfile): TEffectNode;
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
  Part.Contents := LightEffectCodeProfile(N, Profile, False);
  Result.SetParts([Part]);
end;

var
  FSharedAvailable: Integer = -1;

function SharedLightEffectsAvailable: Boolean;
var
  Probe: TPointLightNode;
begin
  if FSharedAvailable < 0 then
  begin
    Probe := TPointLightNode.Create;
    try
      FSharedAvailable := Ord(Probe.HasInterfaceDeclarations <> []);
    finally
      FreeAndNil(Probe);
    end;
  end;
  Result := FSharedAvailable = 1;
end;

{ A new light volume matrix for a light SetLightVolume made (a light
  moving with its master): its per-light uniform, or its own effect's. }
procedure SetLightVolumeMatrix(const Light: TAbstractLightNode; const M: TMatrix4);
var
  I, J: Integer;
  F: TX3DField;
  E: TX3DNode;
begin
  F := Light.Field('d3_light_matrix_');
  if F is TSFMatrix4f then
  begin
    TSFMatrix4f(F).Send(M);
    Exit;
  end;
  for I := 0 to Light.FdEffects.Count - 1 do
  begin
    E := Light.FdEffects[I];
    for J := 0 to E.FieldsCount - 1 do
      if (Copy(E.Fields[J].X3DName, 1, 16) = 'd3_light_matrix_') and (E.Fields[J] is TSFMatrix4f) then
        TSFMatrix4f(E.Fields[J]).Send(M);
  end;
end;

procedure SetLightVolume(const Light: TAbstractLightNode; var Shared: TD3SharedLightEffects;
  const Index: Integer; const M: TMatrix4; const Profile: TD3LightProfile);
var
  Part: TEffectPartNode;
begin
  if not (SharedLightEffects and SharedLightEffectsAvailable) then
  begin
    Light.SetEffects([CreateLightEffect(Index, M, Profile)]);
    Exit;
  end;
  { one effect for all lights (kept in the first slot) }
  if Shared[lsRound, False] = nil then
  begin
    Shared[lsRound, False] := TEffectNode.Create;
    Shared[lsRound, False].Language := slGLSL;
    Shared[lsRound, False].UniformMissing := umIgnore;
    Part := TEffectPartNode.Create;
    Part.ShaderType := stFragment;
    Part.Contents := LightEffectCodeProfile('<Light>', Profile, True);
    Shared[lsRound, False].SetParts([Part]);
  end;
  { the per-light uniforms of the shared code }
  Light.AddCustomField(TSFMatrix4f.Create(Light, True, 'd3_light_matrix_', M));
  Light.AddCustomField(TSFMatrix3f.Create(Light, True, 'd3_light_proj_',
    ProfileMatrix(Profile.Projection)));
  Light.AddCustomField(TSFMatrix3f.Create(Light, True, 'd3_light_fall_',
    ProfileMatrix(Profile.Falloff)));
  Light.AddCustomField(TSFFloat.Create(Light, True, 'd3_light_norm_', Profile.Norm));
  Light.SetEffects([Shared[lsRound, False]]);
end;

function SmoothStep(const E0, E1, X: Single): Single;
var
  T: Single;
begin
  T := Min(1, Max(0, (X - E0) / (E1 - E0)));
  Result := T * T * (3 - 2 * T);
end;

function LightVolumeStrength(const M: TMatrix4; const Profile: TD3LightProfile;
  const WorldCge: TVector3): Single;
var
  TC: TVector3;
  DX, DY, Dist: Single;
begin
  TC := LightTexCoord(M, WorldCge);
  if (TC.X < 0) or (TC.X > 1) or (TC.Y < 0) or (TC.Y > 1) or (TC.Z < 0) or (TC.Z > 1) then
    Exit(0);
  DX := Max(1e-6, Abs(TC.X * 2 - 1));
  DY := Max(1e-6, Abs(TC.Y * 2 - 1));
  if Profile.Norm > 15 then
    Dist := Max(DX, DY)
  else
    Dist := Power(Power(DX, Profile.Norm) + Power(DY, Profile.Norm), 1 / Profile.Norm);
  Result := ProfileAt(Profile.Projection, Min(1, Dist)) * ProfileAt(Profile.Falloff, TC.Z);
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

finalization
  FreeAndNil(TintCache);
  FreeAndNil(ProfileCache);
end.
