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

{ Re-evaluate the registered animated appearances at a time (seconds). }
procedure UpdateAnimatedSurfaces(const Time: Single);
{ Forget the registered appearances (when their scenes are freed). }
procedure ClearAnimatedSurfaces;
function AnimatedSurfaceCount: Integer;

var
  { Specular intensity of surfaces without a specular map (Doom 3 uses
    black; a little sheen helps without real-time shadows). }
  DefaultSpecular: Single = 0.08;

implementation

uses
  Math, Generics.Collections, CastleVectors, CastleRenderOptions,
  Doom3Decls, Doom3Images, Doom3Expressions;

type
  TAnimatedSurface = record
    Material: TD3Material;
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

procedure ApplyStageColor(const M: TD3Material; const Unlit: TUnlitMaterialNode;
  const Blend: TD3BlendMode; const Ctx: TD3ExprContext);
var
  C: TVector4;
begin
  C := M.EvalStageColor(Ctx);
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
      ApplyStageColor(S.Material, S.Unlit, S.Blend, Ctx);
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
procedure SetupStage(const App: TAppearanceNode; const M: TD3Material;
  const Ops: TD3TexOps; const Unlit: TUnlitMaterialNode);
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
    ApplyStageColor(M, Unlit, M.StageBlend, Ctx);
  Anim.Material := M;
  Anim.Ops := Ops;
  Anim.Blend := M.StageBlend;
  Anim.Transform := nil;
  Anim.Unlit := nil;
  if (Transform <> nil) and TD3Material.TexOpsAnimated(Ops) then
    Anim.Transform := Transform;
  if (Unlit <> nil) and M.StageColorAnimated then
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
    SetupStage(Result, M, M.DiffuseTexOps, nil);
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
    Unlit := TUnlitMaterialNode.Create;
    Unlit.EmissiveColor := Vector3(1, 1, 1);
    Url := ImageProgramUrl(M.StageImage, ikColor);
    if Url <> '' then
      Unlit.EmissiveTexture := MakeTexture(Url);
    Result.Material := Unlit;
    SetupStage(Result, M, M.StageTexOps, Unlit);
    case M.StageBlend of
      bmOpaque:
        if M.AlphaTest >= 0 then
        begin
          Result.AlphaMode := amMask;
          Result.AlphaCutoff := Max(0.01, M.AlphaTest);
        end else
          Result.AlphaMode := amOpaque;
      bmBlend:
        Result.AlphaMode := amBlend;
      bmAdd:
        begin
          Result.AlphaMode := amBlend;
          Blend := TBlendModeNode.Create;
          Blend.SrcFactor := bsOne;
          Blend.DestFactor := bdOne;
          Result.BlendMode := Blend;
        end;
      bmFilter:
        begin
          Result.AlphaMode := amBlend;
          Blend := TBlendModeNode.Create;
          Blend.SrcFactor := bsDstColor;
          Blend.DestFactor := bdZero;
          Result.BlendMode := Blend;
        end;
    end;
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
