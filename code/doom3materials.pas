{ Doom 3 materials as X3D appearances.

  Doom 3 lights every surface per light with a diffuse map, a tangent-space
  normal map and a specular map (Blinn-Phong). That maps onto X3D's Phong
  TMaterialNode with DiffuseTexture, NormalTexture and SpecularTexture, and
  the map's lights become X3D point / spot lights (see Doom3Level).
  Materials without a diffuse map but with a blended stage (glows, screens,
  windows, decals) are drawn unlit with the stage's blending. }
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

var
  { Specular intensity of surfaces without a specular map (Doom 3 uses
    black; a little sheen helps without real-time shadows). }
  DefaultSpecular: Single = 0.08;

implementation

uses
  Math, CastleVectors, CastleRenderOptions,
  Doom3Decls, Doom3Images;

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

end.
