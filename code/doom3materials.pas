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

{ A faint additive tint for glass-like materials (TD3Material.DrawAsGlass). }
function GlassAppearance: TAppearanceNode;

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
  { Distance of overlay stages (glows...) in front of their surface: CGE's
    depth test is "less", coplanar copies would be hidden. }
  OverlayOffset: Single = 0.25;

implementation

uses
  Math, Generics.Collections, CastleVectors, CastleRenderOptions,
  Doom3Decls, Doom3Images, Doom3Expressions;

type
  TColorExprs = array [0..3] of TD3Expr;

  TAnimatedSurface = record
    ColorExpr: TColorExprs;
    Transform: TTextureTransformMatrix3DNode; { nil when the matrix is constant }
    Ops: TD3TexOps;
    Unlit: TUnlitMaterialNode; { nil when the color is constant }
    Blend: TD3BlendMode;
  end;

var
  AnimatedSurfaces: specialize TList<TAnimatedSurface>;

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

procedure UpdateAnimatedSurfaces(const Time: Single);
var
  I: Integer;
  S: TAnimatedSurface;
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
end;

procedure ClearAnimatedSurfaces;
begin
  AnimatedSurfaces.Clear;
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
      Exit;
    end;
    Dec(I);
  end;
  if (I >= 0) and (I <= High(M.ExtraStages)) then
    StageInto(Result, M.ExtraStages[I].Image, M.ExtraStages[I].Blend, M.ExtraStages[I].ColorExpr,
      M.ExtraStages[I].TexOps, M.ExtraStages[I].AlphaTest);
end;

function GlassAppearance: TAppearanceNode;
var
  Unlit: TUnlitMaterialNode;
  Blend: TBlendModeNode;
begin
  { reflections / heat haze / mirrors we can't draw: a faint additive tint }
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
finalization
  FreeAndNil(AnimatedSurfaces);
end.
