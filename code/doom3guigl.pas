{
  Copyright 2026 Castle Doom 3 developers.

  Drawing a recorded Doom 3 GUI (Doom3Gui's RecordGuiQuads) on the GPU:
  textured quads, a texture per image, one draw call per run of quads that
  share a texture and a blend mode. The HUD uses it (the software painter
  took ~14 ms a redraw at 1333 x 750, 7% of a fight's frames).
}

unit Doom3GuiGL;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleVectors, CastleUIControls, CastleImages, CastleGLUtils, CastleGLShaders,
  CastleGLImages, CastleRenderContext, CastleRectangles,
  Doom3Gui;

type
  { Draws Quads (filling its parent, the recorded size stretched over it). }
  TD3GuiGLControl = class(TCastleUserInterface)
  strict private
    type
      TVertex = packed record
        Position, TexCoord: TVector2;
        Color: TVector4;
      end;
      TTextureKey = record
        Image: TCastleImage;
        Kind: TGuiQuadKind;
      end;
      TTextureEntry = record
        Texture: TGLTextureId;
        Generation: Integer;
      end;
    var
      FQuads: TGuiQuadList;
      FProgram: TGLSLProgram;
      FVao: TVertexArrayObject;
      FVbo: TGLBuffer;
      FVboSize: Cardinal;
      FVertices: array of TVertex;
      FTextures: specialize TDictionary<TTextureKey, TTextureEntry>;
      FWhite: TGLTextureId;
      FFailed: Boolean;
    function TextureFor(const Q: TGuiQuad): TGLTextureId;
    procedure FreeResources;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Render; override;
    procedure GLContextClose; override;
    { what is drawn: record into it (RecordGuiQuads) }
    property Quads: TGuiQuadList read FQuads;
    { the textures of images no longer recorded can go (a GUI loaded again) }
    procedure ForgetTextures;
    { the GPU can draw it (shaders, not fixed function) }
    class function Supported: Boolean;
  end;

implementation

uses
  {$ifdef FPC} CastleGL, {$else} OpenGL, OpenGLext, {$endif}
  Math, CastleLog, CastleUtils, CastleRenderOptions, CastleInternalGLUtils;

const
  VertexShader =
    'attribute vec2 vertex;' + LineEnding +
    'attribute vec2 tex_coord;' + LineEnding +
    'attribute vec4 color;' + LineEnding +
    'uniform vec2 viewport_size;' + LineEnding +
    'varying vec2 tex_coord_frag;' + LineEnding +
    'varying vec4 color_frag;' + LineEnding +
    'void main(void)' + LineEnding +
    '{' + LineEnding +
    '  gl_Position = vec4(vertex * 2.0 / viewport_size - vec2(1.0), 0.0, 1.0);' + LineEnding +
    '  tex_coord_frag = tex_coord;' + LineEnding +
    '  color_frag = color;' + LineEnding +
    '}';
  { the texture times the color; additive quads have alpha 0 in their color
    (blending One, One adds the rgb) }
  FragmentShader =
    'varying vec2 tex_coord_frag;' + LineEnding +
    'varying vec4 color_frag;' + LineEnding +
    'uniform sampler2D image_texture;' + LineEnding +
    'void main(void)' + LineEnding +
    '{' + LineEnding +
    '  gl_FragColor = texture2D(image_texture, tex_coord_frag) * color_frag;' + LineEnding +
    '}';

{ A white image whose alpha is a glyph page's coverage (its alpha, or for an
  opaque gray page its brightness: the painter's DrawImagePart). }
function CoverageImage(const Src: TCastleImage): TRGBAlphaImage;
var
  X, Y, A: Integer;
  P: PVector4Byte;
  D: PVector4Byte;
begin
  Result := TRGBAlphaImage.Create(Src.Width, Src.Height);
  for Y := 0 to Src.Height - 1 do
  begin
    D := Result.PixelPtr(0, Y);
    for X := 0 to Src.Width - 1 do
    begin
      if Src is TRGBAlphaImage then
      begin
        P := TRGBAlphaImage(Src).PixelPtr(X, Y);
        A := P^.W;
        if A = 255 then
          A := Max(P^.X, Max(P^.Y, P^.Z));
      end else
      if Src is TGrayscaleImage then
        A := PByte(TGrayscaleImage(Src).PixelPtr(X, Y))^
      else
        A := 255;
      D^ := Vector4Byte(255, 255, 255, A);
      Inc(D);
    end;
  end;
end;

constructor TD3GuiGLControl.Create(AOwner: TComponent);
begin
  inherited;
  FQuads := TGuiQuadList.Create;
  FTextures := specialize TDictionary<TTextureKey, TTextureEntry>.Create;
  FullSize := True;
end;

destructor TD3GuiGLControl.Destroy;
begin
  FreeResources;
  FreeAndNil(FTextures);
  FreeAndNil(FQuads);
  inherited;
end;

class function TD3GuiGLControl.Supported: Boolean;
begin
  Result := not GLFeatures.EnableFixedFunction;
end;

procedure TD3GuiGLControl.ForgetTextures;
var
  E: TTextureEntry;
  T: TGLTextureId;
begin
  if FTextures = nil then
    Exit;
  for E in FTextures.Values do
  begin
    T := E.Texture;
    FreeTexture(T);
  end;
  FTextures.Clear;
end;

procedure TD3GuiGLControl.FreeResources;
begin
  ForgetTextures;
  FreeTexture(FWhite);
  FreeAndNil(FProgram);
  FreeAndNil(FVao);
  if FVbo <> GLObjectNone then
  begin
    glDeleteBuffer(FVbo);
    FVbo := GLObjectNone;
  end;
  FVboSize := 0;
end;

procedure TD3GuiGLControl.GLContextClose;
begin
  FreeResources;
  inherited;
end;

function TD3GuiGLControl.TextureFor(const Q: TGuiQuad): TGLTextureId;
var
  Key: TTextureKey;
  E: TTextureEntry;
  White: TRGBAlphaImage;
  Cov: TRGBAlphaImage;
begin
  if Q.Image = nil then
  begin
    if FWhite = GLObjectNone then
    begin
      White := TRGBAlphaImage.Create(1, 1);
      try
        White.Clear(Vector4Byte(255, 255, 255, 255));
        FWhite := LoadGLTexture(White, TextureFilter(minNearest, magNearest), Texture2DClampToEdge);
      finally
        White.Free;
      end;
    end;
    Exit(FWhite);
  end;
  Key.Image := Q.Image;
  Key.Kind := Q.Kind;
  if FTextures.TryGetValue(Key, E) then
  begin
    if not Q.Volatile or (E.Generation = FQuads.Generation) then
      Exit(E.Texture);
    FreeTexture(E.Texture);
  end;
  if Q.Kind = gqCoverage then
  begin
    { glyphs made smaller: mipmaps (the painter averages the span) }
    Cov := CoverageImage(Q.Image);
    try
      E.Texture := LoadGLTexture(Cov, TextureFilter(minLinearMipmapLinear, magLinear), Texture2DClampToEdge);
    finally
      Cov.Free;
    end;
  end else
    { the painter reads the nearest source pixel }
    E.Texture := LoadGLTexture(Q.Image, TextureFilter(minNearest, magNearest), Texture2DClampToEdge);
  E.Generation := FQuads.Generation;
  FTextures.AddOrSetValue(Key, E);
  Result := E.Texture;
end;

procedure TD3GuiGLControl.Render;
const
  Corner: array [0..5] of Integer = (0, 1, 2, 0, 2, 3);
var
  RR: TFloatRectangle;
  SX, SY: Single;
  I, K, N, First: Integer;
  Q: ^TGuiQuad;
  Col: TVector4;
  Tex, BatchTex: TGLTextureId;
  BatchAdd: Boolean;
  Textures: array of TGLTextureId;
  Stride: Integer;

  procedure Flush(const Last: Integer);
  begin
    if Last <= First then
      Exit;
    glBindTexture(GL_TEXTURE_2D, BatchTex);
    if BatchAdd then
      RenderContext.BlendingEnable(bsOne, bdOne)
    else
      RenderContext.BlendingEnable(bsSrcAlpha, bdOneMinusSrcAlpha);
    glDrawArrays(GL_TRIANGLES, First * 6, (Last - First) * 6);
  end;

begin
  inherited;
  if (FQuads.Count = 0) or FFailed or (FQuads.Width <= 0) or (FQuads.Height <= 0) then
    Exit;
  if FProgram = nil then
  begin
    try
      FProgram := TGLSLProgram.Create;
      FProgram.Name := 'TD3GuiGLControl';
      FProgram.AttachVertexShader(VertexShader);
      FProgram.AttachFragmentShader(FragmentShader);
      FProgram.Link;
    except
      on E: Exception do
      begin
        WritelnWarning('Doom3GuiGL', 'GUI shader failed, the GUI isn''t drawn: %s', [E.Message]);
        FreeAndNil(FProgram);
        FFailed := True;
        Exit;
      end;
    end;
    FVao := TVertexArrayObject.Create(nil);
    FVbo := glCreateBuffer;
  end;

  RR := RenderRect;
  SX := RR.Width / FQuads.Width;
  SY := RR.Height / FQuads.Height;
  { the vertices (screen pixels, y up) and the quads' textures }
  if Length(FVertices) < FQuads.Count * 6 then
    SetLength(FVertices, FQuads.Count * 6 + 1536);
  SetLength(Textures, FQuads.Count);
  for I := 0 to FQuads.Count - 1 do
  begin
    Q := @FQuads.Quads[I];
    Col := Q^.Color;
    if Q^.Additive then
      Col := Vector4(Col.X, Col.Y, Col.Z, 0);
    for K := 0 to 5 do
    begin
      N := Corner[K];
      FVertices[I * 6 + K].Position := Vector2(RR.Left + Q^.P[N].X * SX, RR.Bottom + RR.Height - Q^.P[N].Y * SY);
      FVertices[I * 6 + K].TexCoord := Q^.UV[N];
      FVertices[I * 6 + K].Color := Col;
    end;
    Textures[I] := TextureFor(Q^);
  end;

  Stride := SizeOf(TVertex);
  RenderContext.CurrentVao := FVao;
  RenderContext.BindBuffer[btArray] := FVbo;
  if FVboSize < Cardinal(FQuads.Count * 6 * Stride) then
  begin
    FVboSize := Length(FVertices) * Stride;
    glBufferData(GL_ARRAY_BUFFER, FVboSize, nil, GL_STREAM_DRAW);
  end;
  glBufferSubData(GL_ARRAY_BUFFER, 0, FQuads.Count * 6 * Stride, @FVertices[0]);
  RenderContext.CurrentProgram := FProgram;
  FProgram.Attribute('vertex').EnableArrayVector2(FVao, Stride, 0);
  FProgram.Attribute('tex_coord').EnableArrayVector2(FVao, Stride, SizeOf(TVector2));
  FProgram.Attribute('color').EnableArrayVector4(FVao, Stride, 2 * SizeOf(TVector2));
  FProgram.Uniform('viewport_size').SetValue(Vector2(RenderContext.Viewport.Width, RenderContext.Viewport.Height));
  FProgram.Uniform('image_texture').SetValue(TGLint(0));
  glActiveTexture(GL_TEXTURE0);

  { runs of quads with one texture and blend mode, in drawing order }
  First := 0;
  BatchTex := Textures[0];
  BatchAdd := FQuads.Quads[0].Additive;
  for I := 1 to FQuads.Count - 1 do
  begin
    Tex := Textures[I];
    if (Tex <> BatchTex) or (FQuads.Quads[I].Additive <> BatchAdd) then
    begin
      Flush(I);
      First := I;
      BatchTex := Tex;
      BatchAdd := FQuads.Quads[I].Additive;
    end;
  end;
  Flush(FQuads.Count);
  RenderContext.BlendingDisable;
end;

end.
