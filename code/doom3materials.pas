{ Doom 3 materials as X3D appearances.

  Doom 3 lights every surface per light with a diffuse map, a tangent-space
  normal map and a specular map (Blinn-Phong). That maps onto X3D's Phong
  TMaterialNode with DiffuseTexture, NormalTexture and SpecularTexture, and
  the map's lights become X3D point / spot lights (see Doom3Level).
  Materials without a diffuse map but with a blended stage (glows, screens,
  windows, decals) are drawn unlit with the stage's blending.

  Stage texture matrices (scroll, scale, rotate...) become a
  TextureTransformMatrix3D; a stage's color registers become the unlit
  material's emissive color / transparency. Appearances whose matrix or
  color change with time are registered and updated by
  UpdateAnimatedSurfaces (TDoom3Map calls it every frame). }
unit Doom3Materials;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, X3DNodes;

{ A new appearance for a material (nodes must not be shared between scenes;
  textures are still shared through CGE's URL cache). }
function MaterialAppearance(const MaterialName: String): TAppearanceNode;

{ A texture node for a texture URL. }
function MakeTexture(const Url: String): TImageTextureNode;

{ The appearance of an overlay stage (0..TD3Material.OverlayCount - 1),
  drawn over the base surface (Doom3Level offsets its geometry a little). }
function OverlayAppearance(const MaterialName: String; const Index: Integer): TAppearanceNode;

type
  { How a special shape (glass, reflection) must be set up: see SetupSpecialShape. }
  TD3SpecialShape = (
    { nothing special }
    ssNone,
    { heat haze: the effect needs Phong shading (castle_vertex_eye) }
    ssHaze,
    { cube map reflection: texture coordinates from the reflection vector }
    ssReflection
  );

{ The appearance of a glass-like material (TD3Material.DrawAsGlass):
  - a heat haze stage: the screen behind it (ScreenTexture), distorted
    by the stage's normal map, like Doom 3's heatHaze programs;
  - otherwise a cube map reflection stage: the reflection, added;
  - otherwise a faint additive tint.
  Kind says how to set up the shape (SetupSpecialShape). }
function GlassAppearance(const MaterialName: String; out Kind: TD3SpecialShape): TAppearanceNode;

{ The reflection stage of a material ("cubeMap ...", "texgen reflect")
  as an additive overlay on the same triangles (DepthMode "lequal"),
  or nil if the material has none (or its cube map images are missing).
  Set up its shape with SetupSpecialShape(ssReflection). }
function ReflectionAppearance(const MaterialName: String): TAppearanceNode;

{ Set up a shape for a special appearance: Phong shading for heat haze,
  texture coordinates from the reflection vector for reflections
  (the geometry must be an X3DComposedGeometryNode). }
procedure SetupSpecialShape(const Shape: TShapeNode; const Kind: TD3SpecialShape);

{ The URLs of a Doom 3 cube map's images, for CGE's +X, -X, +Y, -Y, -Z, +Z
  (the order of TCastleBackground's textures and of X3D's right, left,
  top, bottom, front, back); False if an image is missing. }
function CubeMapUrls(const Name: String; const CameraCubeMap: Boolean;
  out Urls: array of String): Boolean;

{ An unlit, opaque appearance showing a rendered GUI (Doom3Gui). }
function GuiAppearance(const Url: String): TAppearanceNode;

{ Re-evaluate the registered animated appearances at a time (seconds). }
procedure UpdateAnimatedSurfaces(const Time: Single);
{ Forget the registered appearances (when their scenes are freed). }
procedure ClearAnimatedSurfaces;
function AnimatedSurfaceCount: Integer;

var
  { Specular intensity of surfaces without a specular map (Doom 3 uses
    black; a little sheen helps without real-time shadows). }
  DefaultSpecular: Single = 0.08;
  { Brightness of the glass stand-in. }
  GlassTint: Single = 0.06;

implementation

uses
  Math, Generics.Collections, CastleVectors, CastleRenderOptions, X3DFields,
  Doom3Decls, Doom3Images, Doom3Expressions, Doom3Files, Doom3LightEffects;

type
  TColorExprs = array [0..3] of TD3Expr;

  TAnimatedSurface = record
    ColorExpr: TColorExprs;
    Transform: TTextureTransformMatrix3DNode; { nil when the matrix is constant }
    Ops: TD3TexOps;
    Unlit: TUnlitMaterialNode; { nil when the color is constant }
    Blend: TD3BlendMode;
  end;

  { A heat haze appearance whose scroll changes with time. }
  THazeScroll = record
    Field: TSFVec2f;
    Scroll: array [0..1] of TD3Expr; { owned by the material }
  end;

var
  AnimatedSurfaces: specialize TList<TAnimatedSurface>;
  HazeScrolls: specialize TList<THazeScroll>;

function SurfaceContext(const Time: Single): TD3ExprContext;
begin
  { world surfaces: shader parameters 1, like Doom 3's defaults }
  Result := DefaultExprContext;
  Result.Time := Time;
end;

function EvalColor(const ColorExpr: TColorExprs; const Ctx: TD3ExprContext): TVector4;
var
  I: Integer;
begin
  for I := 0 to 3 do
    if ColorExpr[I] <> nil then
      Result.Data[I] := ColorExpr[I].Eval(Ctx)
    else
      Result.Data[I] := 1;
end;

function ColorAnimated(const ColorExpr: TColorExprs): Boolean;
var
  I: Integer;
begin
  for I := 0 to 3 do
    if (ColorExpr[I] <> nil) and ColorExpr[I].UsesTime then
      Exit(True);
  Result := False;
end;

procedure ApplyStageColor(const ColorExpr: TColorExprs; const Unlit: TUnlitMaterialNode;
  const Blend: TD3BlendMode; const Ctx: TD3ExprContext);
var
  C: TVector4;
begin
  C := EvalColor(ColorExpr, Ctx);
  Unlit.EmissiveColor := Vector3(Max(0, C.X), Max(0, C.Y), Max(0, C.Z));
  if Blend = bmBlend then
    Unlit.Transparency := 1 - Min(1, Max(0, C.W));
end;

function EvalScroll(const Scroll: array of TD3Expr; const Ctx: TD3ExprContext): TVector2;
var
  I: Integer;
begin
  Result := TVector2.Zero;
  for I := 0 to 1 do
    if Scroll[I] <> nil then
      Result.Data[I] := Scroll[I].Eval(Ctx);
end;

procedure UpdateAnimatedSurfaces(const Time: Single);
var
  I: Integer;
  S: TAnimatedSurface;
  H: THazeScroll;
  Ctx: TD3ExprContext;
begin
  Ctx := SurfaceContext(Time);
  for I := 0 to AnimatedSurfaces.Count - 1 do
  begin
    S := AnimatedSurfaces[I];
    if S.Transform <> nil then
      S.Transform.Matrix := TD3Material.TexMatrix(S.Ops, Ctx);
    if S.Unlit <> nil then
      ApplyStageColor(S.ColorExpr, S.Unlit, S.Blend, Ctx);
  end;
  for I := 0 to HazeScrolls.Count - 1 do
  begin
    H := HazeScrolls[I];
    H.Field.Send(EvalScroll(H.Scroll, Ctx));
  end;
end;

procedure ClearAnimatedSurfaces;
begin
  AnimatedSurfaces.Clear;
  HazeScrolls.Clear;
end;

function AnimatedSurfaceCount: Integer;
begin
  Result := AnimatedSurfaces.Count;
end;

{ Texture matrix and animated colors of an appearance. }
procedure SetupStage(const App: TAppearanceNode; const ColorExpr: TColorExprs;
  const Blend: TD3BlendMode; const Ops: TD3TexOps; const Unlit: TUnlitMaterialNode);
var
  Ctx: TD3ExprContext;
  Anim: TAnimatedSurface;
  Transform: TTextureTransformMatrix3DNode;
begin
  Ctx := SurfaceContext(0);
  Transform := nil;
  if Length(Ops) > 0 then
  begin
    Transform := TTextureTransformMatrix3DNode.Create;
    Transform.Matrix := TD3Material.TexMatrix(Ops, Ctx);
    App.TextureTransform := Transform;
  end;
  if Unlit <> nil then
    ApplyStageColor(ColorExpr, Unlit, Blend, Ctx);
  Anim.ColorExpr := ColorExpr;
  Anim.Ops := Ops;
  Anim.Blend := Blend;
  Anim.Transform := nil;
  Anim.Unlit := nil;
  if (Transform <> nil) and TD3Material.TexOpsAnimated(Ops) then
    Anim.Transform := Transform;
  if (Unlit <> nil) and ColorAnimated(ColorExpr) then
    Anim.Unlit := Unlit;
  if (Anim.Transform <> nil) or (Anim.Unlit <> nil) then
    AnimatedSurfaces.Add(Anim);
end;

function MakeTexture(const Url: String): TImageTextureNode;
begin
  Result := TImageTextureNode.Create;
  Result.SetUrl([Url]);
  Result.RepeatS := True;
  Result.RepeatT := True;
end;

function GuiAppearance(const Url: String): TAppearanceNode;
var
  Unlit: TUnlitMaterialNode;
  Texture: TImageTextureNode;
begin
  Result := TAppearanceNode.Create;
  Unlit := TUnlitMaterialNode.Create;
  Unlit.EmissiveColor := Vector3(1, 1, 1);
  Texture := MakeTexture(Url);
  Texture.RepeatS := False;
  Texture.RepeatT := False;
  Unlit.EmissiveTexture := Texture;
  Result.Material := Unlit;
  Result.AlphaMode := amOpaque;
  Result.ShadowCaster := False;
end;

{ An unlit stage: emissive texture, blend mode, texture matrix and color. }
procedure StageInto(const App: TAppearanceNode; const Image: String; const BlendMode: TD3BlendMode;
  const ColorExpr: TColorExprs; const Ops: TD3TexOps; const AlphaTest: Single);
var
  Unlit: TUnlitMaterialNode;
  Url: String;
  Blend: TBlendModeNode;
begin
  Unlit := TUnlitMaterialNode.Create;
  Unlit.EmissiveColor := Vector3(1, 1, 1);
  Url := ImageProgramUrl(Image, ikColor);
  if Url <> '' then
    Unlit.EmissiveTexture := MakeTexture(Url);
  App.Material := Unlit;
  SetupStage(App, ColorExpr, BlendMode, Ops, Unlit);
  case BlendMode of
    bmOpaque:
      if AlphaTest >= 0 then
      begin
        App.AlphaMode := amMask;
        App.AlphaCutoff := Max(0.01, AlphaTest);
      end else
        App.AlphaMode := amOpaque;
    bmBlend:
      App.AlphaMode := amBlend;
    bmAdd:
      begin
        App.AlphaMode := amBlend;
        Blend := TBlendModeNode.Create;
        Blend.SrcFactor := bsOne;
        Blend.DestFactor := bdOne;
        App.BlendMode := Blend;
      end;
    bmFilter:
      begin
        App.AlphaMode := amBlend;
        Blend := TBlendModeNode.Create;
        Blend.SrcFactor := bsDstColor;
        Blend.DestFactor := bdZero;
        App.BlendMode := Blend;
      end;
  end;
end;

{ Doom 3 draws the next stages of a material on the same triangles
  with the depth test "less or equal". Blended stages are rendered after
  all opaque shapes, so "lequal" is enough; opaque (alpha-tested) stages
  may be rendered before their surface, so they are also moved towards
  the camera in the depth buffer (polygon offset), one step per stage. }
procedure StageDepthMode(const App: TAppearanceNode; const Index: Integer);
var
  DepthMode: TDepthModeNode;
begin
  DepthMode := TDepthModeNode.Create;
  DepthMode.DepthFunc := dmfLessEqual;
  if App.AlphaMode <> amBlend then
    DepthMode.PolygonOffset := Vector2(-1, -(Index + 1));
  App.DepthMode := DepthMode;
end;

function OverlayAppearance(const MaterialName: String; const Index: Integer): TAppearanceNode;
var
  M: TD3Material;
  I: Integer;
begin
  M := Decls.Material(MaterialName);
  Result := TAppearanceNode.Create;
  Result.ShadowCaster := False;
  I := Index;
  if (M.DiffuseImage <> '') and (M.StageImage <> '') then
  begin
    if I = 0 then
    begin
      StageInto(Result, M.StageImage, M.StageBlend, M.StageColorExpr, M.StageTexOps, M.AlphaTest);
      StageDepthMode(Result, Index);
      Exit;
    end;
    Dec(I);
  end;
  if (I >= 0) and (I <= High(M.ExtraStages)) then
    StageInto(Result, M.ExtraStages[I].Image, M.ExtraStages[I].Blend, M.ExtraStages[I].ColorExpr,
      M.ExtraStages[I].TexOps, M.ExtraStages[I].AlphaTest);
  StageDepthMode(Result, Index);
end;

const
  { Doom 3's heatHaze*.vfp programs: the screen behind the surface
    (_currentRender, our ScreenTexture) at the fragment's screen position,
    moved by the normal map (scrolled) times a magnitude that decreases
    with the distance (at most 0.02 of the screen), optionally masked. }
  HazeEffectCode =
    'uniform sampler2D screen_texture;' + LineEnding +
    'uniform sampler2D haze_normal_map;' + LineEnding +
    '#ifdef HAZE_MASK' + LineEnding +
    'uniform sampler2D haze_mask;' + LineEnding +
    '#endif' + LineEnding +
    'uniform vec2 haze_scroll;' + LineEnding +
    'uniform float haze_magnitude;' + LineEnding +
    EffectPrelude +
    'uniform D3_HIGHP mat4 castle_ProjectionMatrix;' + LineEnding +
    DesktopOnlyBegin +
    'varying vec4 castle_vertex_eye;' + LineEnding +
    'varying vec4 castle_TexCoord0;' + LineEnding +
    DesktopOnlyEnd +
    'void PLUG_fragment_modify(inout vec4 fragment_color)' + LineEnding +
    '{' + LineEnding +
    '  vec2 tex_coord = castle_TexCoord0.st;' + LineEnding +
    '  vec2 offset = texture2D(haze_normal_map, tex_coord + haze_scroll).xy * 2.0 - 1.0;' + LineEnding +
    '#ifdef HAZE_MASK' + LineEnding +
    '  vec4 mask = texture2D(haze_mask, tex_coord);' + LineEnding +
    '  if (mask.x < 0.01 || mask.y < 0.01) discard;' + LineEnding +
    '  offset *= mask.xy;' + LineEnding +
    '#endif' + LineEnding +
    '  float deform = min(castle_ProjectionMatrix[0][0] / max(-castle_vertex_eye.z, 1.0), 0.02) * haze_magnitude;' + LineEnding +
    '  vec4 clip = castle_ProjectionMatrix * castle_vertex_eye;' + LineEnding +
    '  vec2 screen = clamp(clip.xy / clip.w * 0.5 + 0.5 + offset * deform, 0.0, 1.0);' + LineEnding +
    '  fragment_color = vec4(texture2D(screen_texture, screen).rgb, 1.0);' + LineEnding +
    '}';

function HazeAppearance(const M: TD3Material): TAppearanceNode;
var
  Unlit: TUnlitMaterialNode;
  Effect: TEffectNode;
  Part: TEffectPartNode;
  NormalUrl, MaskUrl, Code: String;
  ScrollField: TSFVec2f;
  Haze: THazeScroll;
begin
  NormalUrl := ImageProgramUrl(M.HazeNormalMap, ikNormal);
  if M.HazeMask <> '' then
    MaskUrl := ImageProgramUrl(M.HazeMask, ikColor)
  else
    MaskUrl := '';

  Result := TAppearanceNode.Create;
  Unlit := TUnlitMaterialNode.Create;
  { the texture gives the effect castle_TexCoord0, its color is replaced }
  Unlit.EmissiveTexture := MakeTexture(NormalUrl);
  Result.Material := Unlit;
  { rendered after the opaque shapes, which the screen texture shows }
  Result.AlphaMode := amBlend;
  Result.ShadowCaster := False;

  Effect := TEffectNode.Create;
  Effect.Language := slGLSL;
  Effect.AddCustomField(TSFNode.Create(Effect, True, 'screen_texture',
    [TAbstractTextureNode], TScreenTextureNode.Create));
  Effect.AddCustomField(TSFNode.Create(Effect, True, 'haze_normal_map',
    [TAbstractTextureNode], MakeTexture(NormalUrl)));
  Code := HazeEffectCode;
  if MaskUrl <> '' then
  begin
    Effect.AddCustomField(TSFNode.Create(Effect, True, 'haze_mask',
      [TAbstractTextureNode], MakeTexture(MaskUrl)));
    Code := '#define HAZE_MASK' + LineEnding + Code;
  end;
  ScrollField := TSFVec2f.Create(Effect, True, 'haze_scroll',
    EvalScroll(M.HazeScroll, SurfaceContext(0)));
  Effect.AddCustomField(ScrollField);
  Effect.AddCustomField(TSFFloat.Create(Effect, True, 'haze_magnitude', M.HazeMagnitude));
  Part := TEffectPartNode.Create;
  Part.ShaderType := stFragment;
  Part.Contents := Code;
  Effect.SetParts([Part]);
  Result.SetEffects([Effect]);

  if ((M.HazeScroll[0] <> nil) and M.HazeScroll[0].UsesTime) or
     ((M.HazeScroll[1] <> nil) and M.HazeScroll[1].UsesTime) then
  begin
    Haze.Field := ScrollField;
    Haze.Scroll[0] := M.HazeScroll[0];
    Haze.Scroll[1] := M.HazeScroll[1];
    HazeScrolls.Add(Haze);
  end;
end;

function CubeMapUrls(const Name: String; const CameraCubeMap: Boolean;
  out Urls: array of String): Boolean;
const
  { Doom 3 suffixes for CGE's +X, -X, +Y, -Y, -Z, +Z: Doom 3 +X is CGE +X,
    Doom 3 +Z (up) is CGE +Y, Doom 3 +Y (left) is CGE -Z. }
  CameraSuffixes: array [0..5] of String = ('_forward', '_back', '_up', '_down', '_left', '_right');
  CubeSuffixes: array [0..5] of String = ('_px', '_nx', '_pz', '_nz', '_py', '_ny');
var
  I: Integer;
  F: String;
begin
  Result := False;
  for I := 0 to 5 do
  begin
    if CameraCubeMap then
      F := FindImageFile(Name + CameraSuffixes[I])
    else
      F := FindImageFile(Name + CubeSuffixes[I]);
    if F = '' then
      Exit;
    Urls[I] := D3FsUrl(F);
  end;
  Result := True;
end;

{ An additive appearance reflecting the material's cube map,
  nil if the cube map images are missing. }
function ReflectionAppearanceCore(const M: TD3Material): TAppearanceNode;
var
  Urls: array [0..5] of String;
  Cube: TComposedCubeMapTextureNode;
  Unlit: TUnlitMaterialNode;
  Blend: TBlendModeNode;

  function Face(const I: Integer): TImageTextureNode;
  begin
    Result := MakeTexture(Urls[I]);
    Result.RepeatS := False;
    Result.RepeatT := False;
  end;

begin
  Result := nil;
  if (M.ReflectCubeMap = '') or not CubeMapUrls(M.ReflectCubeMap, False, Urls) then
    Exit;
  Cube := TComposedCubeMapTextureNode.Create;
  Cube.Right := Face(0);
  Cube.Left := Face(1);
  Cube.Top := Face(2);
  Cube.Bottom := Face(3);
  Cube.Front := Face(4);
  Cube.Back := Face(5);

  Result := TAppearanceNode.Create;
  Unlit := TUnlitMaterialNode.Create;
  Result.Material := Unlit;
  Result.Texture := Cube;
  { reflections are added (Doom 3 blends them with gl_one destination) }
  SetupStage(Result, M.ReflectColorExpr, bmAdd, nil, Unlit);
  Result.AlphaMode := amBlend;
  Blend := TBlendModeNode.Create;
  Blend.SrcFactor := bsOne;
  Blend.DestFactor := bdOne;
  Result.BlendMode := Blend;
  Result.ShadowCaster := False;
end;

function ReflectionAppearance(const MaterialName: String): TAppearanceNode;
var
  DepthMode: TDepthModeNode;
begin
  Result := ReflectionAppearanceCore(Decls.Material(MaterialName));
  if Result = nil then
    Exit;
  { on the same triangles as the surface, see StageDepthMode }
  DepthMode := TDepthModeNode.Create;
  DepthMode.DepthFunc := dmfLessEqual;
  Result.DepthMode := DepthMode;
end;

procedure SetupSpecialShape(const Shape: TShapeNode; const Kind: TD3SpecialShape);
var
  Generator: TTextureCoordinateGeneratorNode;
begin
  case Kind of
    ssHaze:
      Shape.Shading := shPhong;
    ssReflection:
      begin
        Generator := TTextureCoordinateGeneratorNode.Create;
        Generator.Mode := 'WORLDSPACEREFLECTIONVECTOR';
        (Shape.Geometry as TAbstractComposedGeometryNode).TexCoord := Generator;
      end;
    else ;
  end;
end;

function GlassAppearance(const MaterialName: String; out Kind: TD3SpecialShape): TAppearanceNode;
var
  M: TD3Material;
  Unlit: TUnlitMaterialNode;
  Blend: TBlendModeNode;
begin
  M := Decls.Material(MaterialName);
  if M.HazeNormalMap <> '' then
  begin
    Kind := ssHaze;
    Exit(HazeAppearance(M));
  end;
  Result := ReflectionAppearanceCore(M);
  if Result <> nil then
  begin
    Kind := ssReflection;
    Exit;
  end;

  { mirrors, videos... we can't draw: a faint additive tint }
  Kind := ssNone;
  Result := TAppearanceNode.Create;
  Unlit := TUnlitMaterialNode.Create;
  Unlit.EmissiveColor := Vector3(GlassTint, GlassTint, GlassTint * 1.15);
  Result.Material := Unlit;
  Result.AlphaMode := amBlend;
  Blend := TBlendModeNode.Create;
  Blend.SrcFactor := bsOne;
  Blend.DestFactor := bdOne;
  Result.BlendMode := Blend;
  Result.ShadowCaster := False;
end;

function MaterialAppearance(const MaterialName: String): TAppearanceNode;
var
  M: TD3Material;
  Url: String;
  Mat: TMaterialNode;
  Unlit: TUnlitMaterialNode;
  Blend: TBlendModeNode;
begin
  M := Decls.Material(MaterialName);
  Result := TAppearanceNode.Create;
  { noshadows: the surface doesn't cast shadow volumes }
  Result.ShadowCaster := not M.NoShadows;

  if M.DiffuseImage <> '' then
  begin
    Mat := TMaterialNode.Create;
    Mat.DiffuseColor := Vector3(1, 1, 1);
    Mat.Shininess := 16 / 128; { Doom 3's specular exponent is 16 }
    Url := ImageProgramUrl(M.DiffuseImage, ikColor);
    if Url = '' then
      { a missing texture: Doom 3 shows _default, a grey surface is calmer }
      Mat.DiffuseColor := Vector3(0.5, 0.5, 0.5)
    else
      Mat.DiffuseTexture := MakeTexture(Url);
    Url := ImageProgramUrl(M.BumpImage, ikNormal);
    if Url <> '' then
      Mat.NormalTexture := MakeTexture(Url);
    Url := ImageProgramUrl(M.SpecularImage, ikColor);
    if Url <> '' then
    begin
      Mat.SpecularColor := Vector3(1, 1, 1);
      Mat.SpecularTexture := MakeTexture(Url);
    end else
      Mat.SpecularColor := Vector3(DefaultSpecular, DefaultSpecular, DefaultSpecular);
    Result.Material := Mat;
    SetupStage(Result, M.StageColorExpr, M.StageBlend, M.DiffuseTexOps, nil);
    if M.AlphaTest >= 0 then
    begin
      Result.AlphaMode := amMask;
      Result.AlphaCutoff := Max(0.01, M.AlphaTest);
    end else
    if M.Translucent then
      Result.AlphaMode := amBlend
    else
      Result.AlphaMode := amOpaque;
  end else
  if M.StageImage <> '' then
  begin
    StageInto(Result, M.StageImage, M.StageBlend, M.StageColorExpr, M.StageTexOps, M.AlphaTest);
  end else
  begin
    { not drawn; callers normally skip invisible materials }
    Unlit := TUnlitMaterialNode.Create;
    Unlit.Transparency := 1;
    Result.Material := Unlit;
    Result.AlphaMode := amBlend;
  end;
end;

initialization
  AnimatedSurfaces := specialize TList<TAnimatedSurface>.Create;
  HazeScrolls := specialize TList<THazeScroll>.Create;
finalization
  FreeAndNil(AnimatedSurfaces);
  FreeAndNil(HazeScrolls);
end.
