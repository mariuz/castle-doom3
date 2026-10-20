{ Environment probes: image-based light baked from the map
  (RBDOOM-3-BFG's environment probes, CGE change P).

  A probe is 6 views rendered from a point (a cube map), used as the
  specular texture of an EnvironmentLight, and projected into order 2
  spherical harmonics (9 coefficients per color) for its diffuse light
  (an irradiance cube map). }
unit Doom3EnvProbes;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  CastleVectors, CastleImages, CastleUIControls, CastleViewport, CastleTransform,
  X3DNodes;

type
  { The 6 faces of a cube map, in OpenGL order: +X, -X, +Y, -Y, +Z, -Z. }
  TD3CubeFace = 0..5;
  TD3CubeImages = array [TD3CubeFace] of TCastleImage;

  { Order 2 spherical harmonics of RGB radiance. }
  TD3SH9 = array [0..8] of TVector3;

{ Direction of the texel (X, Y) of a cube map face of Size x Size texels,
  following the OpenGL cube map convention (row 0 is t = 0). }
function CubeTexelDirection(const Face: TD3CubeFace; const X, Y, Size: Integer): TVector3;

{ Camera direction and up vector to render the given cube map face:
  the image (row 0 at the bottom) is then the face as OpenGL expects it. }
procedure CubeFaceCamera(const Face: TD3CubeFace; out Direction, Up: TVector3);

{ Render the 6 faces of a cube map at Position, Size x Size each,
  with the viewport (its camera is changed; render it off-screen,
  it doesn't need to be in the container's controls).
  Needs the OpenGL context of the Container. }
function CaptureCubeFaces(const Container: TCastleContainer;
  const Viewport: TCastleViewport; const Position: TVector3;
  const Size: Integer): TD3CubeImages;

{ Spherical harmonics of the radiance in the cube map faces
  (each texel weighted by its solid angle). }
function ProjectSH9(const Faces: TD3CubeImages): TD3SH9;

{ Diffuse light (irradiance divided by Pi, so that a white surface reflects it)
  for the normal N, from the radiance's spherical harmonics. }
function SH9Irradiance(const SH: TD3SH9; const N: TVector3): TVector3;

{ Cube map faces (Size x Size, RGB) of the irradiance. Owned by the caller. }
function IrradianceFaces(const SH: TD3SH9; const Size: Integer): TD3CubeImages;

{ Cube map faces (Size x Size, RGB) of the radiance blurred by a Phong lobe
  (cosine to the power Exponent, normalized), over the whole cube
  (so without seams between faces): the light reflected by a glossy surface.
  Owned by the caller. }
function BlurredFaces(const Faces: TD3CubeImages; const Size: Integer;
  const Exponent: Single): TD3CubeImages;

{ A ComposedCubeMapTexture with the given faces (in OpenGL order and
  orientation, see CubeTexelDirection). The images are copied. }
function CubeMapTexture(const Faces: TD3CubeImages): TComposedCubeMapTextureNode;

procedure FreeCubeImages(var Faces: TD3CubeImages);

{ The CGE supports environment probes: EnvironmentLight has influenceSize
  (CGE change P, mariuz/castle-engine#10). }
function EnvironmentProbesAvailable: Boolean;

{ An environment light with the given textures, used by the shapes inside
  the box (CGE world coordinates). Its new fields are set by name,
  so this compiles with CGE versions without them
  (check EnvironmentProbesAvailable first). }
function CreateProbeLight(const Diffuse, Specular: TAbstractEnvironmentTextureNode;
  const BoxCenter, BoxSize: TVector3; const Intensity: Single): TEnvironmentLightNode;

implementation

uses Math,
  CastleGLImages, CastleRectangles, CastleGLUtils, CastleCameras, CastleProjection,
  X3DFields;

function CubeTexelDirection(const Face: TD3CubeFace; const X, Y, Size: Integer): TVector3;
var
  SC, TC: Single;
begin
  SC := 2 * (X + 0.5) / Size - 1;
  TC := 2 * (Y + 0.5) / Size - 1;
  case Face of
    0: Result := Vector3( 1, -TC, -SC);
    1: Result := Vector3(-1, -TC,  SC);
    2: Result := Vector3(SC,   1,  TC);
    3: Result := Vector3(SC,  -1, -TC);
    4: Result := Vector3(SC, -TC,   1);
    else Result := Vector3(-SC, -TC, -1);
  end;
  Result := Result.Normalize;
end;

procedure CubeFaceCamera(const Face: TD3CubeFace; out Direction, Up: TVector3);
begin
  { Up is the direction of increasing t, and Direction x Up the direction
    of increasing s, in CubeTexelDirection. }
  case Face of
    0: begin Direction := Vector3( 1, 0, 0); Up := Vector3(0, -1, 0); end;
    1: begin Direction := Vector3(-1, 0, 0); Up := Vector3(0, -1, 0); end;
    2: begin Direction := Vector3(0,  1, 0); Up := Vector3(0, 0,  1); end;
    3: begin Direction := Vector3(0, -1, 0); Up := Vector3(0, 0, -1); end;
    4: begin Direction := Vector3(0, 0,  1); Up := Vector3(0, -1, 0); end;
    else begin Direction := Vector3(0, 0, -1); Up := Vector3(0, -1, 0); end;
  end;
end;

function CaptureCubeFaces(const Container: TCastleContainer;
  const Viewport: TCastleViewport; const Position: TVector3;
  const Size: Integer): TD3CubeImages;
var
  RenderToTexture: TGLRenderToTexture;
  Rect: TRectangle;
  Face: TD3CubeFace;
  Direction, Up: TVector3;
begin
  Viewport.Camera.ProjectionType := ptPerspective;
  Viewport.Camera.Perspective.FieldOfView := Pi / 2;
  Viewport.Camera.Perspective.FieldOfViewAxis := faVertical;
  Rect := Rectangle(0, 0, Size, Size);
  RenderToTexture := TGLRenderToTexture.Create(Size, Size);
  try
    RenderToTexture.Buffer := tbNone;
    RenderToTexture.GLContextOpen;
    for Face := Low(TD3CubeFace) to High(TD3CubeFace) do
    begin
      CubeFaceCamera(Face, Direction, Up);
      Viewport.Camera.SetView(Position, Direction, Up);
      RenderToTexture.RenderBegin;
      Container.RenderControl(Viewport, Rect);
      Result[Face] := SaveScreen_NoFlush(TRGBImage, Rect, RenderToTexture.ColorBuffer);
      RenderToTexture.RenderEnd;
    end;
  finally FreeAndNil(RenderToTexture) end;
end;

{ Real spherical harmonics basis (order 2) for the unit direction D. }
procedure SHBasis(const D: TVector3; out Y: array of Single);
begin
  Y[0] := 0.282095;
  Y[1] := 0.488603 * D.Y;
  Y[2] := 0.488603 * D.Z;
  Y[3] := 0.488603 * D.X;
  Y[4] := 1.092548 * D.X * D.Y;
  Y[5] := 1.092548 * D.Y * D.Z;
  Y[6] := 0.315392 * (3 * D.Z * D.Z - 1);
  Y[7] := 1.092548 * D.X * D.Z;
  Y[8] := 0.546274 * (D.X * D.X - D.Y * D.Y);
end;

function ProjectSH9(const Faces: TD3CubeImages): TD3SH9;
var
  Face: TD3CubeFace;
  X, Y, I, N: Integer;
  SC, TC, Weight: Single;
  D: TVector3;
  C: TVector3;
  Basis: array [0..8] of Single;
begin
  for I := 0 to 8 do
    Result[I] := TVector3.Zero;
  for Face := Low(TD3CubeFace) to High(TD3CubeFace) do
  begin
    N := Faces[Face].Width;
    for Y := 0 to N - 1 do
      for X := 0 to N - 1 do
      begin
        SC := 2 * (X + 0.5) / N - 1;
        TC := 2 * (Y + 0.5) / N - 1;
        { solid angle of the texel }
        Weight := (4 / Sqr(N)) / Power(1 + SC * SC + TC * TC, 1.5);
        D := CubeTexelDirection(Face, X, Y, N);
        C := Faces[Face].Colors[X, Y, 0].XYZ;
        SHBasis(D, Basis);
        for I := 0 to 8 do
          Result[I] := Result[I] + C * (Basis[I] * Weight);
      end;
  end;
end;

function SH9Irradiance(const SH: TD3SH9; const N: TVector3): TVector3;
const
  { Convolution with the clamped cosine (Ramamoorthi and Hanrahan),
    divided by Pi: A0 = 1, A1 = 2/3, A2 = 1/4. }
  Band: array [0..8] of Single = (1, 2/3, 2/3, 2/3, 1/4, 1/4, 1/4, 1/4, 1/4);
var
  Basis: array [0..8] of Single;
  I: Integer;
begin
  SHBasis(N, Basis);
  Result := TVector3.Zero;
  for I := 0 to 8 do
    Result := Result + SH[I] * (Band[I] * Basis[I]);
  Result := Vector3(Max(Result.X, 0), Max(Result.Y, 0), Max(Result.Z, 0));
end;

function IrradianceFaces(const SH: TD3SH9; const Size: Integer): TD3CubeImages;
var
  Face: TD3CubeFace;
  X, Y: Integer;
  E: TVector3;
begin
  for Face := Low(TD3CubeFace) to High(TD3CubeFace) do
  begin
    Result[Face] := TRGBImage.Create(Size, Size);
    for Y := 0 to Size - 1 do
      for X := 0 to Size - 1 do
      begin
        E := SH9Irradiance(SH, CubeTexelDirection(Face, X, Y, Size));
        Result[Face].Colors[X, Y, 0] := Vector4(
          Min(E.X, 1), Min(E.Y, 1), Min(E.Z, 1), 1);
      end;
  end;
end;

function BlurredFaces(const Faces: TD3CubeImages; const Size: Integer;
  const Exponent: Single): TD3CubeImages;
var
  Face, SourceFace: TD3CubeFace;
  X, Y, SX, SY, N, I, Count: Integer;
  SC, TC, CosAngle, Weight, WeightSum: Single;
  Dirs: array of TVector3;
  SolidAngles: array of Single;
  Colors: array of TVector3;
  D, Sum: TVector3;
begin
  { the source texels' directions, solid angles and colors, once }
  N := Faces[0].Width;
  Count := 6 * N * N;
  SetLength(Dirs, Count);
  SetLength(SolidAngles, Count);
  SetLength(Colors, Count);
  I := 0;
  for SourceFace := Low(TD3CubeFace) to High(TD3CubeFace) do
    for SY := 0 to N - 1 do
      for SX := 0 to N - 1 do
      begin
        SC := 2 * (SX + 0.5) / N - 1;
        TC := 2 * (SY + 0.5) / N - 1;
        Dirs[I] := CubeTexelDirection(SourceFace, SX, SY, N);
        SolidAngles[I] := (4 / Sqr(N)) / Power(1 + SC * SC + TC * TC, 1.5);
        Colors[I] := Faces[SourceFace].Colors[SX, SY, 0].XYZ;
        Inc(I);
      end;

  for Face := Low(TD3CubeFace) to High(TD3CubeFace) do
  begin
    Result[Face] := TRGBImage.Create(Size, Size);
    for Y := 0 to Size - 1 do
      for X := 0 to Size - 1 do
      begin
        D := CubeTexelDirection(Face, X, Y, Size);
        Sum := TVector3.Zero;
        WeightSum := 0;
        for I := 0 to Count - 1 do
        begin
          CosAngle := TVector3.DotProduct(D, Dirs[I]);
          if CosAngle <= 0 then
            Continue;
          Weight := Power(CosAngle, Exponent) * SolidAngles[I];
          Sum := Sum + Colors[I] * Weight;
          WeightSum := WeightSum + Weight;
        end;
        if WeightSum > 0 then
          Sum := Sum / WeightSum;
        Result[Face].Colors[X, Y, 0] := Vector4(
          Min(Sum.X, 1), Min(Sum.Y, 1), Min(Sum.Z, 1), 1);
      end;
  end;
end;

function CubeMapTexture(const Faces: TD3CubeImages): TComposedCubeMapTextureNode;

  function Side(const Image: TCastleImage; const Rotate: Boolean): TPixelTextureNode;
  begin
    Result := TPixelTextureNode.Create;
    if Rotate then
      Result.FdImage.Value := Image.MakeRotated(2)
    else
      Result.FdImage.Value := Image.MakeCopy;
  end;

begin
  { CGE uploads ComposedCubeMapTexture sides as: +X right, -X left,
    +Y top, -Y bottom, +Z back, -Z front, rotating the 4 sides by 180 degrees
    (they are oriented like Background sides). So pass them rotated back. }
  Result := TComposedCubeMapTextureNode.Create;
  Result.Right  := Side(Faces[0], true);
  Result.Left   := Side(Faces[1], true);
  Result.Top    := Side(Faces[2], false);
  Result.Bottom := Side(Faces[3], false);
  Result.Back   := Side(Faces[4], true);
  Result.Front  := Side(Faces[5], true);
end;

procedure FreeCubeImages(var Faces: TD3CubeImages);
var
  Face: TD3CubeFace;
begin
  for Face := Low(TD3CubeFace) to High(TD3CubeFace) do
    FreeAndNil(Faces[Face]);
end;

var
  FAvailable: Integer = -1;

function EnvironmentProbesAvailable: Boolean;
var
  Light: TEnvironmentLightNode;
begin
  if FAvailable = -1 then
  begin
    Light := TEnvironmentLightNode.Create;
    try
      FAvailable := Ord(Light.Field('influenceSize') <> nil);
    finally FreeAndNil(Light) end;
  end;
  Result := FAvailable = 1;
end;

function CreateProbeLight(const Diffuse, Specular: TAbstractEnvironmentTextureNode;
  const BoxCenter, BoxSize: TVector3; const Intensity: Single): TEnvironmentLightNode;
var
  F: TX3DField;
begin
  Result := TEnvironmentLightNode.Create;
  Result.Global := true;
  Result.Intensity := Intensity;
  Result.DiffuseTexture := Diffuse;
  Result.SpecularTexture := Specular;
  F := Result.Field('influenceCenter');
  if F is TSFVec3f then
    TSFVec3f(F).Value := BoxCenter;
  F := Result.Field('influenceSize');
  if F is TSFVec3f then
    TSFVec3f(F).Value := BoxSize;
end;

end.
