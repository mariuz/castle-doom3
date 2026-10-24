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
  SysUtils, Classes, CastleVectors, CastleUtils, X3DNodes, Doom3Decls, Doom3Expressions;

type
  { An entity's shader parameters (its _color, shaderParm0..11): the stage
    colors and "if" conditions of its materials read them (parm0..11).
    Owned by the entity; the registered surfaces read it every frame, so
    changing it (setShaderParm, setColor) shows at once. }
  TD3EntityParms = class
    Parms: array [0..11] of Single;
    constructor Create;
    { _color (parms 0..2) and shaderParmN keys. }
    procedure FromKeys(const Keys: TStrings);
  end;

{ A new appearance for a material (nodes must not be shared between scenes;
  textures are still shared through CGE's URL cache). Parms: the entity's
  shader parameters (nil: Doom 3's world defaults, 1 1 1 1). }
function MaterialAppearance(const MaterialName: String; const Parms: TD3EntityParms = nil): TAppearanceNode;

{ The node to add to the scene for a shape whose stage has an "if"
  condition: a Switch holding it, shown while the condition holds
  (evaluated every frame by UpdateAnimatedSurfaces with the entity's
  parameters; a Switch, because CGE doesn't apply a shape's "visible"
  field changing at runtime). Without a condition the shape itself. }
function ConditionalShapeNode(const Shape: TShapeNode; const Condition: TD3Expr;
  const Parms: TD3EntityParms): TAbstractChildNode;
{ The "if" condition of a material's base shape (nil: none), and of its
  overlay stage Index (see OverlayAppearance). }
function BaseStageCondition(const M: TD3Material): TD3Expr;
function OverlayStageCondition(const M: TD3Material; const Index: Integer): TD3Expr;
{ Conditional shapes registered (for the log). }
function ConditionalShapeCount: Integer;

{ A texture node for a texture URL. }
function MakeTexture(const Url: String): TImageTextureNode;

{ The expression context of a world surface at a time (shader parameters
  1, like Doom 3's defaults). }
function SurfaceContext(const Time: Single): TD3ExprContext;

{ The appearance of an overlay stage (0..TD3Material.OverlayCount - 1),
  drawn over the base surface (Doom3Level offsets its geometry a little). }
function OverlayAppearance(const MaterialName: String; const Index: Integer;
  const Parms: TD3EntityParms = nil): TAppearanceNode;

{ The heat haze stage of a lit or plain material (HazeNormalMap set, not
  DrawAsGlass) as an overlay on the same triangles (DepthMode "lequal");
  set up its shape with SetupSpecialShape(ssHaze). }
function HazeOverlayAppearance(const MaterialName: String): TAppearanceNode;

type
  { How a special shape (glass, reflection) must be set up: see SetupSpecialShape. }
  TD3SpecialShape = (
    { nothing special }
    ssNone,
    { heat haze: the effect needs Phong shading (castle_vertex_eye) }
    ssHaze,
    { cube map reflection: texture coordinates from the reflection vector }
    ssReflection,
    { cube map reflection perturbed by the bump map: Phong shading, the
      surface's own texture coordinates (the normal map's) }
    ssBumpyReflection,
    { a mirror: texture coordinates from the mirror plane (CGE's
      RenderedTexture with a ViewpointMirror) }
    ssMirror
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
  Set up its shape with SetupSpecialShape(ReflectionKind(M)). }
function ReflectionAppearance(const MaterialName: String): TAppearanceNode;
{ How a material's reflection stage is drawn: perturbed by its bump map
  (ssBumpyReflection, like Doom 3's bumpyEnvironment program, used for every
  "texgen reflect" stage of a material with a bump map) or plain
  (ssReflection). }
function ReflectionKind(const M: TD3Material): TD3SpecialShape;

{ The mirror stage of a material ("mirrorRenderMap w h") as an overlay on
  the same triangles (DepthMode "lequal"): the scene rendered from the
  mirrored camera every frame (a RenderedTexture with a ViewpointMirror,
  w x h). nil if the material has none. Set up its shape with
  SetupSpecialShape(ssMirror). }
function MirrorAppearance(const MaterialName: String): TAppearanceNode;
{ Mirror appearances made so far (for the log). }
function MirrorCount: Integer;

{ Set up a shape for a special appearance: Phong shading for heat haze,
  texture coordinates from the reflection vector for reflections, from the
  mirror plane for mirrors (the geometry must be an X3DComposedGeometryNode). }
procedure SetupSpecialShape(const Shape: TShapeNode; const Kind: TD3SpecialShape);

{ The vertex colors of a material's stage: does the base stage (Overlay
  -1) or the overlay stage Overlay (see OverlayAppearance) use the
  model's vertex colors ("vertexColor"), and inverted ("inverseVertexColor")? }
function StageUsesVertexColors(const M: TD3Material; const Overlay: Integer;
  out Inverse: Boolean): Boolean;
{ A Color node modulating a stage's shape by vertex colors (1 - them when
  Inverse), for TAbstractComposedGeometryNode.Color. }
function VertexColorNode(const Colors: array of TVector4; const Inverse: Boolean): TColorRGBANode;

{ "deform tube": the quads of a surface (4 vertexes, 6 indexes each) are
  turned around their long axis to face the viewer every frame
  (R_TubeDeform). Register the shape's coordinate node with the original
  positions (the scene's coordinates) and indexes; UpdateViewDeforms
  (every frame, with the camera position in world space) rewrites the
  coordinates (the node's scene transform is taken into account once it
  is in a scene). }
procedure RegisterTubeSurface(const Coord: TCoordinateNode;
  const Positions: array of TVector3; const Indexes: array of Int32);
procedure UpdateViewDeforms(const ViewPosition: TVector3);
{ Compute the tube positions for a view position (the scene's
  coordinates): what UpdateViewDeforms writes. }
procedure TubePositions(const Positions: array of TVector3; const Indexes: array of Int32;
  const LocalView: TVector3; var Result: array of TVector3);
function TubeSurfaceCount: Integer;

type
  { A connected island of a "deform eyeball" surface (R_EyeballDeform):
    the triangles (their index into the index list / 3) and vertexes. }
  TD3EyeIsland = record
    Tris: array of Int32;
    Verts: array of Int32;
  end;
  TD3EyeIslands = array of TD3EyeIsland;

{ "deform eyeball": the surface must be exactly three islands of connected
  triangles: the eye (more than one triangle), an origin triangle behind it
  and a focus triangle in front. False (and a warning) otherwise. }
function EyeballIslands(const Indexes: array of Int32; const VertexCount: Integer;
  out Islands: TD3EyeIslands; const SurfaceName: String): Boolean;
{ The indexes of the drawn (eye) triangles: Doom 3 drops the origin and
  focus triangles. }
function EyeballIndexes(const Islands: TD3EyeIslands; const Indexes: array of Int32): TInt32List;
{ The eyes' texture coordinates for the current positions (any
  coordinates, the result is the same): the texture is projected from the
  origin island through the focus island, (0.5, 0.5) on the line between
  them, one texture unit per world unit (R_EyeballDeform; Doom 3's eye
  materials are small). UVs gets CGE's v = 1 - t for the eye vertexes,
  the others are left alone. }
procedure EyeballTexCoords(const Islands: TD3EyeIslands; const Positions: array of TVector3;
  var UVs: array of TVector2);
{ Eyeball surfaces registered (for the log): the builders count them. }
var
  EyeballSurfaceCount: Integer;

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
  Math, Generics.Collections, CastleLog, CastleRenderOptions, CastleImages, CastleTransform, X3DFields,
  Doom3Images, Doom3Files;

type
  TColorExprs = array [0..3] of TD3Expr;

  TAnimatedSurface = record
    ColorExpr: TColorExprs;
    Transform: TTextureTransformMatrix3DNode; { nil when the matrix is constant }
    Ops: TD3TexOps;
    Unlit: TUnlitMaterialNode; { nil when the color is constant }
    Blend: TD3BlendMode;
    Parms: TD3EntityParms; { nil: the world's }
  end;

  { A shape drawn while a stage condition holds. }
  TConditionalShape = record
    Shape: TShapeNode;
    Switch: TSwitchNode;
    Condition: TD3Expr;
    Parms: TD3EntityParms;
  end;

  { A "deform turbulent" effect whose range / time offset / domain change. }
  TTurbulentSurface = record
    Fields: array [0..2] of TSFFloat;
    Exprs: array [0..2] of TD3Expr; { owned by the material }
    Parms: TD3EntityParms;
  end;

  { A heat haze appearance whose scroll changes with time. }
  THazeScroll = record
    Field: TSFVec2f;
    Scroll: array [0..1] of TD3Expr; { owned by the material }
  end;

  { A "deform expand" / "deform move" effect whose amount changes. }
  TVertexDeformSurface = record
    Field: TSFFloat;
    Expr: TD3Expr; { owned by the material }
    Parms: TD3EntityParms;
  end;

  { A bumpy reflection whose stage color changes. }
  TReflectColor = record
    Field: TSFVec4f;
    ColorExpr: TColorExprs;
    Parms: TD3EntityParms;
  end;

  { A "deform tube" surface: its coordinate node and the original quads. }
  TTubeSurface = record
    Coord: TCoordinateNode;
    Positions: array of TVector3;
    Indexes: array of Int32;
  end;

  { Forgets registered animated surfaces whose nodes are freed (a
    scene with an animated material freed before the map: debris). }
  TNodeWatcher = class
    procedure NodeDestroyed(const Node: TX3DNode);
  end;

var
  AnimatedSurfaces: specialize TList<TAnimatedSurface>;
  HazeScrolls: specialize TList<THazeScroll>;
  ConditionalShapes: specialize TList<TConditionalShape>;
  TurbulentSurfaces: specialize TList<TTurbulentSurface>;
  VertexDeformSurfaces: specialize TList<TVertexDeformSurface>;
  ReflectColors: specialize TList<TReflectColor>;
  TubeSurfaces: specialize TList<TTubeSurface>;
  Mirrors: Integer;
  NodeWatcher: TNodeWatcher;

{ TD3EntityParms }

constructor TD3EntityParms.Create;
var
  I: Integer;
begin
  inherited Create;
  { Doom 3's defaults: white, alpha 1, the rest 0 }
  for I := 0 to 3 do
    Parms[I] := 1;
  for I := 4 to 11 do
    Parms[I] := 0;
end;

procedure TD3EntityParms.FromKeys(const Keys: TStrings);
var
  I: Integer;
  V: String;
  Parts: TStringArray;
begin
  if Keys = nil then
    Exit;
  V := Keys.Values['_color'];
  if V <> '' then
  begin
    Parts := Trim(V).Split([' '], TStringSplitOptions.ExcludeEmpty);
    for I := 0 to Min(2, High(Parts)) do
      Parms[I] := StrToFloatDef(Parts[I], 1, DefaultFormatSettings);
  end;
  for I := 0 to 11 do
  begin
    V := Keys.Values['shaderParm' + IntToStr(I)];
    if V <> '' then
      Parms[I] := StrToFloatDef(Trim(V), Parms[I], DefaultFormatSettings);
  end;
end;

function ContextFor(const Parms: TD3EntityParms; const Time: Single): TD3ExprContext;
var
  I: Integer;
begin
  Result := DefaultExprContext;
  Result.Time := Time;
  if Parms <> nil then
    for I := 0 to 11 do
      Result.Parms[I] := Parms.Parms[I];
end;

procedure TNodeWatcher.NodeDestroyed(const Node: TX3DNode);
var
  I: Integer;
begin
  for I := AnimatedSurfaces.Count - 1 downto 0 do
    if (AnimatedSurfaces[I].Transform = Node) or (AnimatedSurfaces[I].Unlit = Node) then
      AnimatedSurfaces.Delete(I);
  for I := HazeScrolls.Count - 1 downto 0 do
    if HazeScrolls[I].Field.ParentNode = Node then
      HazeScrolls.Delete(I);
  for I := ConditionalShapes.Count - 1 downto 0 do
    if (ConditionalShapes[I].Shape = Node) or (ConditionalShapes[I].Switch = Node) then
      ConditionalShapes.Delete(I);
  for I := TurbulentSurfaces.Count - 1 downto 0 do
    if TurbulentSurfaces[I].Fields[0].ParentNode = Node then
      TurbulentSurfaces.Delete(I);
  for I := VertexDeformSurfaces.Count - 1 downto 0 do
    if VertexDeformSurfaces[I].Field.ParentNode = Node then
      VertexDeformSurfaces.Delete(I);
  for I := ReflectColors.Count - 1 downto 0 do
    if ReflectColors[I].Field.ParentNode = Node then
      ReflectColors.Delete(I);
  for I := TubeSurfaces.Count - 1 downto 0 do
    if TubeSurfaces[I].Coord = Node then
      TubeSurfaces.Delete(I);
end;

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

{ Changes with time, or with an entity's parameters. }
function ColorAnimated(const ColorExpr: TColorExprs; const Parms: TD3EntityParms): Boolean;
var
  I: Integer;
begin
  for I := 0 to 3 do
    if (ColorExpr[I] <> nil) and
       (ColorExpr[I].UsesTime or ((Parms <> nil) and not ColorExpr[I].IsConstant)) then
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
  I, K: Integer;
  S: TAnimatedSurface;
  H: THazeScroll;
  C: TConditionalShape;
  T: TTurbulentSurface;
  Ctx, ECtx: TD3ExprContext;
  Visible: Boolean;
begin
  Ctx := SurfaceContext(Time);
  for I := 0 to AnimatedSurfaces.Count - 1 do
  begin
    S := AnimatedSurfaces[I];
    if S.Parms <> nil then
      ECtx := ContextFor(S.Parms, Time)
    else
      ECtx := Ctx;
    if S.Transform <> nil then
      S.Transform.Matrix := TD3Material.TexMatrix(S.Ops, ECtx);
    if S.Unlit <> nil then
      ApplyStageColor(S.ColorExpr, S.Unlit, S.Blend, ECtx);
  end;
  for I := 0 to HazeScrolls.Count - 1 do
  begin
    H := HazeScrolls[I];
    H.Field.Send(EvalScroll(H.Scroll, Ctx));
  end;
  { stage "if" conditions: shown while they hold }
  for I := 0 to ConditionalShapes.Count - 1 do
  begin
    C := ConditionalShapes[I];
    Visible := C.Condition.Eval(ContextFor(C.Parms, Time)) <> 0;
    if (C.Switch.WhichChoice >= 0) <> Visible then
    begin
      if Visible then
        C.Switch.WhichChoice := 0
      else
        C.Switch.WhichChoice := -1;
      WritelnLog('Doom3Materials', 'Conditional shape %s (unlit %s): %s', [C.Shape.X3DName,
        BoolToStr(C.Shape.Appearance.Material is TUnlitMaterialNode, '1', '0'), BoolToStr(Visible, 'shown', 'hidden')]);
    end;
  end;
  { deform turbulent: its range, time offset and domain }
  for I := 0 to TurbulentSurfaces.Count - 1 do
  begin
    T := TurbulentSurfaces[I];
    ECtx := ContextFor(T.Parms, Time);
    for K := 0 to 2 do
      if (T.Exprs[K] <> nil) and not T.Exprs[K].IsConstant then
        T.Fields[K].Send(T.Exprs[K].Eval(ECtx));
  end;
  { deform expand / move: the amount }
  for I := 0 to VertexDeformSurfaces.Count - 1 do
    VertexDeformSurfaces[I].Field.Send(VertexDeformSurfaces[I].Expr.Eval(
      ContextFor(VertexDeformSurfaces[I].Parms, Time)));
  { bumpy reflections: the stage color }
  for I := 0 to ReflectColors.Count - 1 do
    ReflectColors[I].Field.Send(EvalColor(ReflectColors[I].ColorExpr,
      ContextFor(ReflectColors[I].Parms, Time)));
end;

function ConditionalShapeNode(const Shape: TShapeNode; const Condition: TD3Expr;
  const Parms: TD3EntityParms): TAbstractChildNode;
var
  C: TConditionalShape;
begin
  Result := Shape;
  if (Shape = nil) or (Condition = nil) then
    Exit;
  C.Shape := Shape;
  C.Switch := TSwitchNode.Create;
  C.Switch.AddChildren(Shape);
  if Condition.Eval(ContextFor(Parms, 0)) <> 0 then
    C.Switch.WhichChoice := 0
  else
    C.Switch.WhichChoice := -1;
  C.Condition := Condition;
  C.Parms := Parms;
  C.Switch.AddDestructionNotification({$ifdef FPC}@{$endif} NodeWatcher.NodeDestroyed);
  ConditionalShapes.Add(C);
  Result := C.Switch;
end;

function BaseStageCondition(const M: TD3Material): TD3Expr;
begin
  if M.DiffuseImage <> '' then
    Result := M.DiffuseCondition
  else
    Result := M.StageCondition;
end;

function OverlayStageCondition(const M: TD3Material; const Index: Integer): TD3Expr;
var
  I: Integer;
begin
  I := Index;
  if (M.DiffuseImage <> '') and (M.StageImage <> '') then
  begin
    if I = 0 then
      Exit(M.StageCondition);
    Dec(I);
  end;
  if (I >= 0) and (I <= High(M.ExtraStages)) then
    Result := M.ExtraStages[I].Condition
  else
    Result := nil;
end;

function ConditionalShapeCount: Integer;
begin
  Result := ConditionalShapes.Count;
end;

procedure ClearAnimatedSurfaces;
begin
  AnimatedSurfaces.Clear;
  HazeScrolls.Clear;
  ConditionalShapes.Clear;
  TurbulentSurfaces.Clear;
  VertexDeformSurfaces.Clear;
  ReflectColors.Clear;
  TubeSurfaces.Clear;
end;

function AnimatedSurfaceCount: Integer;
begin
  Result := AnimatedSurfaces.Count;
end;

{ Texture matrix and animated colors of an appearance. }
procedure SetupStage(const App: TAppearanceNode; const ColorExpr: TColorExprs;
  const Blend: TD3BlendMode; const Ops: TD3TexOps; const Unlit: TUnlitMaterialNode;
  const Parms: TD3EntityParms = nil);
var
  Ctx: TD3ExprContext;
  Anim: TAnimatedSurface;
  Transform: TTextureTransformMatrix3DNode;
begin
  Ctx := ContextFor(Parms, 0);
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
  Anim.Parms := Parms;
  if (Transform <> nil) and TD3Material.TexOpsAnimated(Ops) then
    Anim.Transform := Transform;
  if (Unlit <> nil) and ColorAnimated(ColorExpr, Parms) then
    Anim.Unlit := Unlit;
  if (Anim.Transform <> nil) or (Anim.Unlit <> nil) then
  begin
    if Anim.Transform <> nil then
      Anim.Transform.AddDestructionNotification({$ifdef FPC}@{$endif} NodeWatcher.NodeDestroyed);
    if Anim.Unlit <> nil then
      Anim.Unlit.AddDestructionNotification({$ifdef FPC}@{$endif} NodeWatcher.NodeDestroyed);
    AnimatedSurfaces.Add(Anim);
  end;
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

{ The appearance's alpha mode and blend function for a stage blend mode
  (opaque stages with an alpha test are masked). }
procedure ApplyBlendMode(const App: TAppearanceNode; const BlendMode: TD3BlendMode;
  const AlphaTest: Single); forward;

{ An unlit stage: emissive texture, blend mode, texture matrix and color. }
procedure StageInto(const App: TAppearanceNode; const Image: String; const BlendMode: TD3BlendMode;
  const ColorExpr: TColorExprs; const Ops: TD3TexOps; const AlphaTest: Single;
  const Parms: TD3EntityParms = nil);
var
  Unlit: TUnlitMaterialNode;
  Url: String;
begin
  Unlit := TUnlitMaterialNode.Create;
  Unlit.EmissiveColor := Vector3(1, 1, 1);
  Url := ImageProgramUrl(Image, ikColor);
  if Url <> '' then
    Unlit.EmissiveTexture := MakeTexture(Url);
  App.Material := Unlit;
  SetupStage(App, ColorExpr, BlendMode, Ops, Unlit, Parms);
  ApplyBlendMode(App, BlendMode, AlphaTest);
end;

procedure ApplyBlendMode(const App: TAppearanceNode; const BlendMode: TD3BlendMode;
  const AlphaTest: Single);
var
  Blend: TBlendModeNode;
begin
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
procedure StageDepthMode(const App: TAppearanceNode; const Index: Integer; const M: TD3Material);
var
  DepthMode: TDepthModeNode;
begin
  DepthMode := TDepthModeNode.Create;
  DepthMode.DepthFunc := dmfLessEqual;
  if App.AlphaMode <> amBlend then
    DepthMode.PolygonOffset := Vector2(-1, -(Index + 1))
  else
  if M.PolygonOffset <> 0 then
    DepthMode.PolygonOffset := Vector2(-1, -2 * M.PolygonOffset - Index);
  App.DepthMode := DepthMode;
end;

{ "polygonOffset": the whole surface is moved a little towards the viewer
  in the depth buffer (decals over walls), like Doom 3's
  glPolygonOffset( -1, -2 * value ). }
procedure ApplyPolygonOffset(const App: TAppearanceNode; const M: TD3Material);
var
  DepthMode: TDepthModeNode;
begin
  if M.PolygonOffset = 0 then
    Exit;
  DepthMode := TDepthModeNode.Create;
  DepthMode.DepthFunc := dmfLessEqual;
  DepthMode.PolygonOffset := Vector2(-1, -2 * M.PolygonOffset);
  App.DepthMode := DepthMode;
end;

const
  { "deform turbulent": Doom 3's R_TurbulentDeform moves every vertex's
    texture coordinates by the table of a value made from its position,
    the time offset and the domain; here per fragment (the table is a
    texture, read with wrapping like TableLookup) }
  TurbulentVertexCode =
    'varying float d3_turb_f;' + LineEnding +
    'void PLUG_vertex_object_space(const in vec4 vertex_object, const in vec3 normal_object)' + LineEnding +
    '{' + LineEnding +
    '  /* Doom 3 x, y, z are CGE x, -z, y */' + LineEnding +
    '  d3_turb_f = vertex_object.x * 0.003 - vertex_object.z * 0.007 + vertex_object.y * 0.011;' + LineEnding +
    '}';
  TurbulentFragmentCode =
    'uniform sampler2D d3_turb_table;' + LineEnding +
    'uniform float d3_turb_range;' + LineEnding +
    'uniform float d3_turb_timeofs;' + LineEnding +
    'uniform float d3_turb_domain;' + LineEnding +
    'uniform float d3_turb_scale;' + LineEnding +
    'uniform float d3_turb_min;' + LineEnding +
    'uniform float d3_turb_half;' + LineEnding +
    'varying float d3_turb_f;' + LineEnding +
    'float d3_turb_lookup(float f)' + LineEnding +
    '{' + LineEnding +
    '  return texture2D(d3_turb_table, vec2(f + d3_turb_half, 0.5)).r * d3_turb_scale + d3_turb_min;' + LineEnding +
    '}' + LineEnding +
    'void PLUG_texture_coord_shift(inout vec2 tex_coord)' + LineEnding +
    '{' + LineEnding +
    '  float f = d3_turb_timeofs + d3_turb_domain * d3_turb_f + d3_turb_timeofs;' + LineEnding +
    '  tex_coord.x += d3_turb_range * d3_turb_lookup(f);' + LineEnding +
    '  /* CGE''s v is 1 - t */' + LineEnding +
    '  tex_coord.y -= d3_turb_range * d3_turb_lookup(f + 0.5);' + LineEnding +
    '}';

procedure ApplyTurbulentDeform(const App: TAppearanceNode; const M: TD3Material;
  const Parms: TD3EntityParms);
var
  Table: TD3Table;
  Effect: TEffectNode;
  Vert, Frag: TEffectPartNode;
  Image: TGrayscaleImage;
  Texture: TPixelTextureNode;
  Props: TTexturePropertiesNode;
  I, N: Integer;
  MinV, MaxV: Single;
  T: TTurbulentSurface;
  Ctx: TD3ExprContext;
  Values: array [0..2] of Single;
begin
  if M.Deform <> 'turbulent' then
    Exit;
  Table := Decls.Table(M.DeformTable);
  if (Table = nil) or (Length(Table.Values) < 2) then
    Exit;
  N := Length(Table.Values) - 1;
  MinV := Table.Values[0];
  MaxV := Table.Values[0];
  for I := 0 to N - 1 do
  begin
    MinV := Min(MinV, Table.Values[I]);
    MaxV := Max(MaxV, Table.Values[I]);
  end;
  if MaxV - MinV < 0.0001 then
    MaxV := MinV + 1;
  Image := TGrayscaleImage.Create(N, 1);
  for I := 0 to N - 1 do
    Image.Pixels[I] := Round(EnsureRange((Table.Values[I] - MinV) / (MaxV - MinV), 0, 1) * 255);
  Texture := TPixelTextureNode.Create;
  Texture.FdImage.Value := Image;
  Texture.RepeatS := True;
  Texture.RepeatT := True;
  Props := TTexturePropertiesNode.Create;
  if Table.Snap then
  begin
    Props.MagnificationFilter := magNearest;
    Props.MinificationFilter := minNearest;
  end else
  begin
    Props.MagnificationFilter := magLinear;
    Props.MinificationFilter := minLinear;
  end;
  Props.GuiTexture := True;
  Texture.TextureProperties := Props;

  Ctx := ContextFor(Parms, 0);
  for I := 0 to 2 do
    if M.DeformParms[I] <> nil then
      Values[I] := M.DeformParms[I].Eval(Ctx)
    else
      Values[I] := 0;
  Effect := TEffectNode.Create;
  Effect.Language := slGLSL;
  Effect.AddCustomField(TSFNode.Create(Effect, True, 'd3_turb_table', [TAbstractTextureNode], Texture));
  T.Fields[0] := TSFFloat.Create(Effect, True, 'd3_turb_range', Values[0]);
  T.Fields[1] := TSFFloat.Create(Effect, True, 'd3_turb_timeofs', Values[1]);
  T.Fields[2] := TSFFloat.Create(Effect, True, 'd3_turb_domain', Values[2]);
  for I := 0 to 2 do
    Effect.AddCustomField(T.Fields[I]);
  Effect.AddCustomField(TSFFloat.Create(Effect, True, 'd3_turb_scale', MaxV - MinV));
  Effect.AddCustomField(TSFFloat.Create(Effect, True, 'd3_turb_min', MinV));
  Effect.AddCustomField(TSFFloat.Create(Effect, True, 'd3_turb_half', 0.5 / N));
  Vert := TEffectPartNode.Create;
  Vert.ShaderType := stVertex;
  Vert.Contents := TurbulentVertexCode;
  Frag := TEffectPartNode.Create;
  Frag.ShaderType := stFragment;
  Frag.Contents := TurbulentFragmentCode;
  Effect.SetParts([Vert, Frag]);
  App.SetEffects([Effect]);

  for I := 0 to 2 do
    T.Exprs[I] := M.DeformParms[I];
  T.Parms := Parms;
  if ((T.Exprs[0] <> nil) and not T.Exprs[0].IsConstant) or
     ((T.Exprs[1] <> nil) and not T.Exprs[1].IsConstant) or
     ((T.Exprs[2] <> nil) and not T.Exprs[2].IsConstant) then
  begin
    Effect.AddDestructionNotification({$ifdef FPC}@{$endif} NodeWatcher.NodeDestroyed);
    TurbulentSurfaces.Add(T);
  end;
end;

const
  { "deform expand <amount>": every vertex moves along its normal by the
    amount (R_ExpandDeform); "deform move <amount>": along Doom 3's x axis,
    which is CGE's x (R_MoveDeform). In the vertex shader, so shadow
    volumes and collisions keep the plain surface. }
  ExpandVertexCode =
    'uniform float d3_deform_amount;' + LineEnding +
    'void PLUG_vertex_object_space(inout vec4 vertex_object, inout vec3 normal_object)' + LineEnding +
    '{' + LineEnding +
    '  vertex_object.xyz += normal_object * d3_deform_amount;' + LineEnding +
    '}';
  MoveVertexCode =
    'uniform float d3_deform_amount;' + LineEnding +
    'void PLUG_vertex_object_space(inout vec4 vertex_object, inout vec3 normal_object)' + LineEnding +
    '{' + LineEnding +
    '  vertex_object.x += d3_deform_amount;' + LineEnding +
    '}';

procedure ApplyVertexDeform(const App: TAppearanceNode; const M: TD3Material;
  const Parms: TD3EntityParms);
var
  Effect: TEffectNode;
  Vert: TEffectPartNode;
  D: TVertexDeformSurface;
  Amount: Single;
begin
  if (M.Deform <> 'expand') and (M.Deform <> 'move') then
    Exit;
  if M.DeformParms[0] <> nil then
    Amount := M.DeformParms[0].Eval(ContextFor(Parms, 0))
  else
    Amount := 0;
  Effect := TEffectNode.Create;
  Effect.Language := slGLSL;
  D.Field := TSFFloat.Create(Effect, True, 'd3_deform_amount', Amount);
  Effect.AddCustomField(D.Field);
  Vert := TEffectPartNode.Create;
  Vert.ShaderType := stVertex;
  if M.Deform = 'expand' then
    Vert.Contents := ExpandVertexCode
  else
    Vert.Contents := MoveVertexCode;
  Effect.SetParts([Vert]);
  App.SetEffects([Effect]);
  if (M.DeformParms[0] <> nil) and not M.DeformParms[0].IsConstant then
  begin
    D.Expr := M.DeformParms[0];
    D.Parms := Parms;
    Effect.AddDestructionNotification({$ifdef FPC}@{$endif} NodeWatcher.NodeDestroyed);
    VertexDeformSurfaces.Add(D);
  end;
end;

{ The shader deforms of a material's stages (turbulent, expand, move). }
procedure ApplyDeformEffects(const App: TAppearanceNode; const M: TD3Material;
  const Parms: TD3EntityParms);
begin
  ApplyTurbulentDeform(App, M, Parms);
  ApplyVertexDeform(App, M, Parms);
end;

{ "deform tube" ------------------------------------------------------------ }

procedure TubePositions(const Positions: array of TVector3; const Indexes: array of Int32;
  const LocalView: TVector3; var Result: array of TVector3);
const
  { the edges of a quad's two triangles (R_TubeDeform's edgeVerts) }
  EdgeVerts: array [0..5, 0..1] of Integer = ((0, 1), (1, 2), (2, 0), (3, 4), (4, 5), (5, 3));
var
  I, J, I1, I2: Integer;
  Lengths: array [0..1] of Single;
  Nums: array [0..1] of Integer;
  Mid: array [0..1] of TVector3;
  Major, Minor, Dir: TVector3;
  L: Single;
begin
  for I := 0 to High(Positions) do
    Result[I] := Positions[I];
  I := 0;
  while I + 5 < Length(Indexes) do
  begin
    { the two shortest of the six edges }
    Nums[0] := 0;
    Nums[1] := 0;
    Lengths[0] := 999999;
    Lengths[1] := 999999;
    for J := 0 to 5 do
    begin
      I1 := Indexes[I + EdgeVerts[J, 0]];
      I2 := Indexes[I + EdgeVerts[J, 1]];
      if (I1 > High(Positions)) or (I2 > High(Positions)) then
        Continue;
      L := PointsDistance(Positions[I1], Positions[I2]);
      if L < Lengths[0] then
      begin
        Nums[1] := Nums[0];
        Lengths[1] := Lengths[0];
        Nums[0] := J;
        Lengths[0] := L;
      end else
      if L < Lengths[1] then
      begin
        Nums[1] := J;
        Lengths[1] := L;
      end;
    end;
    { their midpoints give the major axis }
    for J := 0 to 1 do
    begin
      I1 := Indexes[I + EdgeVerts[Nums[J], 0]];
      I2 := Indexes[I + EdgeVerts[Nums[J], 1]];
      if (I1 > High(Positions)) or (I2 > High(Positions)) then
        Exit;
      Mid[J] := (Positions[I1] + Positions[I2]) * 0.5;
    end;
    Major := Mid[1] - Mid[0];
    { re-project the short edges' points across the view direction }
    for J := 0 to 1 do
    begin
      I1 := Indexes[I + EdgeVerts[Nums[J], 0]];
      I2 := Indexes[I + EdgeVerts[Nums[J], 1]];
      L := 0.5 * Lengths[J];
      Dir := Mid[J] - LocalView;
      Minor := TVector3.CrossProduct(Major, Dir);
      if Minor.IsZero then
        Continue;
      Minor := Minor.Normalize;
      if J = 1 then
      begin
        Result[I1] := Mid[J] - Minor * L;
        Result[I2] := Mid[J] + Minor * L;
      end else
      begin
        Result[I1] := Mid[J] + Minor * L;
        Result[I2] := Mid[J] - Minor * L;
      end;
    end;
    Inc(I, 6);
  end;
end;

procedure RegisterTubeSurface(const Coord: TCoordinateNode;
  const Positions: array of TVector3; const Indexes: array of Int32);
var
  T: TTubeSurface;
  I: Integer;
begin
  T.Coord := Coord;
  SetLength(T.Positions, Length(Positions));
  for I := 0 to High(Positions) do
    T.Positions[I] := Positions[I];
  SetLength(T.Indexes, Length(Indexes));
  for I := 0 to High(Indexes) do
    T.Indexes[I] := Indexes[I];
  Coord.AddDestructionNotification({$ifdef FPC}@{$endif} NodeWatcher.NodeDestroyed);
  TubeSurfaces.Add(T);
end;

procedure UpdateViewDeforms(const ViewPosition: TVector3);
var
  I: Integer;
  T: TTubeSurface;
  LocalView: TVector3;
  Points: TVector3List;
begin
  for I := 0 to TubeSurfaces.Count - 1 do
  begin
    T := TubeSurfaces[I];
    { the node's scene may be transformed (a brush entity) }
    if (T.Coord.Scene <> nil) and (T.Coord.Scene is TCastleTransform) then
      LocalView := TCastleTransform(T.Coord.Scene).WorldInverseTransform.MultPoint(ViewPosition)
    else
      LocalView := ViewPosition;
    Points := T.Coord.FdPoint.Items;
    Points.Count := Length(T.Positions);
    if Points.Count > 0 then
      TubePositions(T.Positions, T.Indexes, LocalView,
        Slice(TVector3List.PTypeList(Points.L)^, Points.Count));
    T.Coord.FdPoint.Changed;
  end;
end;

function TubeSurfaceCount: Integer;
begin
  Result := TubeSurfaces.Count;
end;

{ "deform eyeball" --------------------------------------------------------- }

function EyeballIslands(const Indexes: array of Int32; const VertexCount: Integer;
  out Islands: TD3EyeIslands; const SurfaceName: String): Boolean;
const
  MaxIslands = 3;
var
  NumTris, T, I, J, N: Integer;
  Used: array of Boolean;
  VertIsland: array of Integer;
  Stack: array of Integer;
  Island: Integer;

  function Shares(const A, B: Integer): Boolean;
  var
    K, L: Integer;
  begin
    for K := 0 to 2 do
      for L := 0 to 2 do
        if Indexes[A * 3 + K] = Indexes[B * 3 + L] then
          Exit(True);
    Result := False;
  end;

begin
  Result := False;
  Islands := nil;
  NumTris := Length(Indexes) div 3;
  if NumTris < 3 then
    Exit;
  SetLength(Used, NumTris);
  SetLength(VertIsland, VertexCount);
  for I := 0 to High(VertIsland) do
    VertIsland[I] := -1;
  Island := 0;
  for T := 0 to NumTris - 1 do
  begin
    if Used[T] then
      Continue;
    if Island >= MaxIslands then
    begin
      WritelnWarning('Doom3Materials', 'deform eyeball: "%s" has more than %d triangle islands',
        [SurfaceName, MaxIslands]);
      Islands := nil;
      Exit;
    end;
    SetLength(Islands, Island + 1);
    { flood the triangles connected by shared vertexes
      (AddTriangleToIsland_r) }
    Stack := [T];
    Used[T] := True;
    while Length(Stack) > 0 do
    begin
      I := Stack[High(Stack)];
      SetLength(Stack, Length(Stack) - 1);
      Islands[Island].Tris := Concat(Islands[Island].Tris, [I]);
      for J := 0 to NumTris - 1 do
        if not Used[J] and Shares(I, J) then
        begin
          Used[J] := True;
          Stack := Concat(Stack, [J]);
        end;
    end;
    for I := 0 to High(Islands[Island].Tris) do
      for J := 0 to 2 do
      begin
        N := Indexes[Islands[Island].Tris[I] * 3 + J];
        if (N >= 0) and (N < VertexCount) and (VertIsland[N] <> Island) then
        begin
          VertIsland[N] := Island;
          Islands[Island].Verts := Concat(Islands[Island].Verts, [N]);
        end;
      end;
    Inc(Island);
  end;
  if Island <> MaxIslands then
  begin
    WritelnWarning('Doom3Materials', 'deform eyeball: "%s" has %d triangle islands, needs 3',
      [SurfaceName, Island]);
    Islands := nil;
    Exit;
  end;
  Result := True;
end;

function EyeballIndexes(const Islands: TD3EyeIslands; const Indexes: array of Int32): TInt32List;
var
  I, J, K: Integer;
begin
  Result := TInt32List.Create;
  for I := 0 to High(Islands) do
    if Length(Islands[I].Tris) > 1 then
      for J := 0 to High(Islands[I].Tris) do
        for K := 0 to 2 do
          Result.Add(Indexes[Islands[I].Tris[J] * 3 + K]);
end;

procedure EyeballTexCoords(const Islands: TD3EyeIslands; const Positions: array of TVector3;
  var UVs: array of TVector2);
var
  Mids: array of TVector3;
  I, J, K, OriginIsland, FocusIsland: Integer;
  BoxMin, BoxMax, Origin, Focus, Dir, V1, V2, Local: TVector3;
  TexVec: array [0..1] of TVector3;
  Dist: array of Single;
  Order: array of Integer;
  Tmp: Integer;
  FTmp: Single;
begin
  if Length(Islands) < 3 then
    Exit;
  { the islands' centers (the centers of their bounds) }
  SetLength(Mids, Length(Islands));
  for I := 0 to High(Islands) do
  begin
    BoxMin := Vector3(MaxSingle, MaxSingle, MaxSingle);
    BoxMax := -BoxMin;
    for J := 0 to High(Islands[I].Verts) do
    begin
      K := Islands[I].Verts[J];
      if K > High(Positions) then
        Continue;
      BoxMin := Vector3(Min(BoxMin.X, Positions[K].X), Min(BoxMin.Y, Positions[K].Y), Min(BoxMin.Z, Positions[K].Z));
      BoxMax := Vector3(Max(BoxMax.X, Positions[K].X), Max(BoxMax.Y, Positions[K].Y), Max(BoxMax.Z, Positions[K].Z));
    end;
    Mids[I] := (BoxMin + BoxMax) * 0.5;
  end;
  SetLength(Dist, Length(Islands));
  SetLength(Order, Length(Islands));
  for I := 0 to High(Islands) do
  begin
    if Length(Islands[I].Tris) <= 1 then
      Continue;
    { the closest other island is the eye's origin, the next one its focus }
    for J := 0 to High(Islands) do
    begin
      Dist[J] := PointsDistance(Mids[J], Mids[I]);
      Order[J] := J;
      K := J - 1;
      while (K >= 0) and (Dist[K] > Dist[K + 1]) do
      begin
        Tmp := Order[K];
        Order[K] := Order[K + 1];
        Order[K + 1] := Tmp;
        FTmp := Dist[K];
        Dist[K] := Dist[K + 1];
        Dist[K + 1] := FTmp;
        Dec(K);
      end;
    end;
    OriginIsland := Order[1];
    FocusIsland := Order[2];
    Origin := Mids[OriginIsland];
    Focus := Mids[FocusIsland];
    Dir := Focus - Origin;
    if Dir.IsZero then
      Continue;
    Dir := Dir.Normalize;
    { the projection axes from the origin triangle: its normal, and the
      cross of that with the direction, both made perpendicular to it }
    if (Length(Islands[OriginIsland].Verts) < 3) or
       (Islands[OriginIsland].Verts[0] > High(Positions)) or
       (Islands[OriginIsland].Verts[1] > High(Positions)) or
       (Islands[OriginIsland].Verts[2] > High(Positions)) then
      Continue;
    V1 := Positions[Islands[OriginIsland].Verts[1]] - Positions[Islands[OriginIsland].Verts[0]];
    V2 := Positions[Islands[OriginIsland].Verts[2]] - Positions[Islands[OriginIsland].Verts[0]];
    if V1.IsZero or V2.IsZero then
      Continue;
    TexVec[0] := TVector3.CrossProduct(V1.Normalize, V2.Normalize);
    TexVec[1] := TVector3.CrossProduct(TexVec[0], Dir);
    for J := 0 to 1 do
    begin
      TexVec[J] := TexVec[J] - Dir * TVector3.DotProduct(TexVec[J], Dir);
      if not TexVec[J].IsZero then
        TexVec[J] := TexVec[J].Normalize;
    end;
    for J := 0 to High(Islands[I].Verts) do
    begin
      K := Islands[I].Verts[J];
      if (K > High(Positions)) or (K > High(UVs)) then
        Continue;
      Local := Positions[K] - Origin;
      { Doom 3's t goes down the image: CGE's v = 1 - t }
      UVs[K] := Vector2(0.5 + TVector3.DotProduct(Local, TexVec[0]),
        1 - (0.5 + TVector3.DotProduct(Local, TexVec[1])));
    end;
  end;
end;

function OverlayAppearance(const MaterialName: String; const Index: Integer;
  const Parms: TD3EntityParms): TAppearanceNode;
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
      StageInto(Result, M.StageImage, M.StageBlend, M.StageColorExpr, M.StageTexOps, M.AlphaTest, Parms);
      StageDepthMode(Result, Index, M);
      ApplyDeformEffects(Result, M, Parms);
      Exit;
    end;
    Dec(I);
  end;
  if (I >= 0) and (I <= High(M.ExtraStages)) then
    StageInto(Result, M.ExtraStages[I].Image, M.ExtraStages[I].Blend, M.ExtraStages[I].ColorExpr,
      M.ExtraStages[I].TexOps, M.ExtraStages[I].AlphaTest, Parms);
  StageDepthMode(Result, Index, M);
  ApplyDeformEffects(Result, M, Parms);
end;

function StageUsesVertexColors(const M: TD3Material; const Overlay: Integer;
  out Inverse: Boolean): Boolean;
var
  I: Integer;
begin
  Inverse := False;
  if Overlay < 0 then
  begin
    if M.DiffuseImage <> '' then
    begin
      Inverse := M.DiffuseInverseVertexColor;
      Exit(M.DiffuseVertexColor or M.DiffuseInverseVertexColor);
    end;
    Inverse := M.StageInverseVertexColor;
    Exit(M.StageVertexColor or M.StageInverseVertexColor);
  end;
  I := Overlay;
  if (M.DiffuseImage <> '') and (M.StageImage <> '') then
  begin
    if I = 0 then
    begin
      Inverse := M.StageInverseVertexColor;
      Exit(M.StageVertexColor or M.StageInverseVertexColor);
    end;
    Dec(I);
  end;
  Result := False;
  if (I >= 0) and (I <= High(M.ExtraStages)) then
  begin
    Inverse := M.ExtraStages[I].InverseVertexColor;
    Result := M.ExtraStages[I].VertexColor or M.ExtraStages[I].InverseVertexColor;
  end;
end;

function VertexColorNode(const Colors: array of TVector4; const Inverse: Boolean): TColorRGBANode;
var
  List: TVector4List;
  I: Integer;
begin
  Result := TColorRGBANode.Create;
  Result.Mode := cmModulate;
  List := TVector4List.Create;
  try
    List.Count := Length(Colors);
    for I := 0 to High(Colors) do
      if Inverse then
        { Doom 3's inverseVertexColor: 1 - the color, alpha too }
        List[I] := Vector4(1, 1, 1, 1) - Colors[I]
      else
        List[I] := Colors[I];
    Result.SetColor(List);
  finally
    List.Free;
  end;
end;

function HazeAppearance(const M: TD3Material): TAppearanceNode; forward;

function HazeOverlayAppearance(const MaterialName: String): TAppearanceNode;
var
  M: TD3Material;
  DepthMode: TDepthModeNode;
begin
  M := Decls.Material(MaterialName);
  if M.HazeNormalMap = '' then
    Exit(nil);
  Result := HazeAppearance(M);
  DepthMode := TDepthModeNode.Create;
  DepthMode.DepthFunc := dmfLessEqual;
  Result.DepthMode := DepthMode;
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
    'uniform mat4 castle_ProjectionMatrix;' + LineEnding +
    'varying vec4 castle_vertex_eye;' + LineEnding +
    'varying vec4 castle_TexCoord0;' + LineEnding +
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
    if ScrollField.ParentNode is TX3DNode then
      TX3DNode(ScrollField.ParentNode).AddDestructionNotification({$ifdef FPC}@{$endif} NodeWatcher.NodeDestroyed);
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

const
  { Doom 3's bumpyEnvironment program: the reflection vector from the
    bump-mapped normal (CGE's bump mapping plug runs before this one and
    leaves the perturbed normal in normal_eye), per fragment, looking up
    the cube map in world space like the plain reflection's texgen
    (-reflect(-V, N) = reflect(V, N)); the stage color scales it. The
    lit material's own color is replaced. }
  BumpyReflectionCode =
    'uniform samplerCube d3_refl_cube;' + LineEnding +
    'uniform vec4 d3_refl_color;' + LineEnding +
    'varying vec4 castle_vertex_eye;' + LineEnding +
    '/* from the EyeWorldSpace shader library, linked after this code */' + LineEnding +
    'vec3 direction_eye_to_world_space(vec3 direction_eye);' + LineEnding +
    'vec3 d3_refl_normal_eye = vec3(0.0, 0.0, 1.0);' + LineEnding +
    'void PLUG_fragment_eye_space(const vec4 vertex_eye, inout vec3 normal_eye)' + LineEnding +
    '{' + LineEnding +
    '  d3_refl_normal_eye = normal_eye;' + LineEnding +
    '}' + LineEnding +
    'void PLUG_fragment_modify(inout vec4 fragment_color)' + LineEnding +
    '{' + LineEnding +
    '  vec3 refl_eye = reflect(normalize(vec3(castle_vertex_eye)), normalize(d3_refl_normal_eye));' + LineEnding +
    '  vec3 refl_world = direction_eye_to_world_space(refl_eye);' + LineEnding +
    '  fragment_color = vec4(textureCube(d3_refl_cube, refl_world).rgb * d3_refl_color.rgb, 1.0);' + LineEnding +
    '}';

function ReflectionKind(const M: TD3Material): TD3SpecialShape;
begin
  if (M.BumpImage <> '') and (ImageProgramUrl(M.BumpImage, ikNormal) <> '') then
    Result := ssBumpyReflection
  else
    Result := ssReflection;
end;

{ An additive appearance reflecting the material's cube map,
  nil if the cube map images are missing. With a bump map the reflection
  is perturbed by it per fragment (ReflectionKind). }
function ReflectionAppearanceCore(const M: TD3Material): TAppearanceNode;
var
  Urls: array [0..5] of String;
  Cube: TComposedCubeMapTextureNode;
  Unlit: TUnlitMaterialNode;
  Mat: TMaterialNode;
  Blend: TBlendModeNode;
  Effect: TEffectNode;
  Part: TEffectPartNode;
  R: TReflectColor;

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
  if ReflectionKind(M) = ssBumpyReflection then
  begin
    { a lit material only for CGE's bump mapping (its normal map, the
      tangents from the surface's texture coordinates); the effect
      replaces the lit color }
    Mat := TMaterialNode.Create;
    Mat.DiffuseColor := TVector3.Zero;
    Mat.AmbientIntensity := 0;
    Mat.SpecularColor := TVector3.Zero;
    Mat.EmissiveColor := TVector3.Zero;
    Mat.NormalTexture := MakeTexture(ImageProgramUrl(M.BumpImage, ikNormal));
    Result.Material := Mat;
    Effect := TEffectNode.Create;
    Effect.Language := slGLSL;
    Effect.SetShaderLibraries(['castle-shader:/EyeWorldSpace.glsl']);
    Effect.AddCustomField(TSFNode.Create(Effect, True, 'd3_refl_cube', [TAbstractTextureNode], Cube));
    R.Field := TSFVec4f.Create(Effect, True, 'd3_refl_color',
      EvalColor(M.ReflectColorExpr, SurfaceContext(0)));
    Effect.AddCustomField(R.Field);
    Part := TEffectPartNode.Create;
    Part.ShaderType := stFragment;
    Part.Contents := BumpyReflectionCode;
    Effect.SetParts([Part]);
    Result.SetEffects([Effect]);
    if ColorAnimated(M.ReflectColorExpr, nil) then
    begin
      R.ColorExpr := M.ReflectColorExpr;
      R.Parms := nil;
      Effect.AddDestructionNotification({$ifdef FPC}@{$endif} NodeWatcher.NodeDestroyed);
      ReflectColors.Add(R);
    end;
  end else
  begin
    Unlit := TUnlitMaterialNode.Create;
    Result.Material := Unlit;
    Result.Texture := Cube;
    { reflections are added (Doom 3 blends them with gl_one destination) }
    SetupStage(Result, M.ReflectColorExpr, bmAdd, nil, Unlit);
  end;
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

{ The scene seen in the mirror, as the stage's texture: CGE renders it
  from the camera mirrored in the shape's plane every frame (the near plane
  at the mirror), and the MIRROR-PLANE texture coordinates (SetupSpecialShape)
  read it at the fragment's place. }
function MirrorAppearanceCore(const M: TD3Material): TAppearanceNode;
var
  Tex: TRenderedTextureNode;
  Mirror: TViewpointMirrorNode;
  Unlit: TUnlitMaterialNode;
begin
  Result := nil;
  if not M.HasMirror then
    Exit;
  Tex := TRenderedTextureNode.Create;
  Tex.SetDimensions([Max(16, M.MirrorWidth), Max(16, M.MirrorHeight), 4, 1, 1]);
  Tex.Update := upAlways;
  Tex.RepeatS := False;
  Tex.RepeatT := False;
  Mirror := TViewpointMirrorNode.Create;
  Tex.Viewpoint := Mirror;
  Result := TAppearanceNode.Create;
  Unlit := TUnlitMaterialNode.Create;
  Unlit.EmissiveColor := Vector3(1, 1, 1);
  Unlit.EmissiveTexture := Tex;
  Result.Material := Unlit;
  { the stage's color and blend; its texture matrix is Doom 3's clip space
    mapping, not applied }
  SetupStage(Result, M.MirrorColorExpr, M.MirrorBlend, nil, Unlit);
  ApplyBlendMode(Result, M.MirrorBlend, -1);
  Result.ShadowCaster := False;
  Inc(Mirrors);
end;

function MirrorAppearance(const MaterialName: String): TAppearanceNode;
var
  DepthMode: TDepthModeNode;
begin
  Result := MirrorAppearanceCore(Decls.Material(MaterialName));
  if Result = nil then
    Exit;
  DepthMode := TDepthModeNode.Create;
  DepthMode.DepthFunc := dmfLessEqual;
  Result.DepthMode := DepthMode;
end;

function MirrorCount: Integer;
begin
  Result := Mirrors;
end;

procedure SetupSpecialShape(const Shape: TShapeNode; const Kind: TD3SpecialShape);
var
  Generator: TTextureCoordinateGeneratorNode;
begin
  case Kind of
    ssHaze, ssBumpyReflection:
      Shape.Shading := shPhong;
    ssReflection:
      begin
        Generator := TTextureCoordinateGeneratorNode.Create;
        Generator.Mode := 'WORLDSPACEREFLECTIONVECTOR';
        (Shape.Geometry as TAbstractComposedGeometryNode).TexCoord := Generator;
      end;
    ssMirror:
      begin
        Generator := TTextureCoordinateGeneratorNode.Create;
        Generator.Mode := 'MIRROR-PLANE';
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
    Kind := ReflectionKind(M);
    Exit;
  end;
  Result := MirrorAppearanceCore(M);
  if Result <> nil then
  begin
    Kind := ssMirror;
    Exit;
  end;

  { videos, remote renders... we can't draw: a faint additive tint }
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

function MaterialAppearance(const MaterialName: String; const Parms: TD3EntityParms): TAppearanceNode;
var
  M: TD3Material;
  Url: String;
  Mat: TMaterialNode;
  Unlit: TUnlitMaterialNode;
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
    SetupStage(Result, M.StageColorExpr, M.StageBlend, M.DiffuseTexOps, nil, Parms);
    if M.AlphaTest >= 0 then
    begin
      Result.AlphaMode := amMask;
      Result.AlphaCutoff := Max(0.01, M.AlphaTest);
    end else
    if M.Translucent then
      Result.AlphaMode := amBlend
    else
      Result.AlphaMode := amOpaque;
    ApplyPolygonOffset(Result, M);
    ApplyDeformEffects(Result, M, Parms);
  end else
  if M.StageImage <> '' then
  begin
    StageInto(Result, M.StageImage, M.StageBlend, M.StageColorExpr, M.StageTexOps, M.AlphaTest, Parms);
    ApplyPolygonOffset(Result, M);
    ApplyDeformEffects(Result, M, Parms);
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
  ConditionalShapes := specialize TList<TConditionalShape>.Create;
  TurbulentSurfaces := specialize TList<TTurbulentSurface>.Create;
  VertexDeformSurfaces := specialize TList<TVertexDeformSurface>.Create;
  ReflectColors := specialize TList<TReflectColor>.Create;
  TubeSurfaces := specialize TList<TTubeSurface>.Create;
  NodeWatcher := TNodeWatcher.Create;
finalization
  FreeAndNil(AnimatedSurfaces);
  FreeAndNil(HazeScrolls);
  FreeAndNil(ConditionalShapes);
  FreeAndNil(TurbulentSurfaces);
  FreeAndNil(VertexDeformSurfaces);
  FreeAndNil(ReflectColors);
  FreeAndNil(TubeSurfaces);
  FreeAndNil(NodeWatcher);
end.
