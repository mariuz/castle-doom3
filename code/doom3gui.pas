// Doom 3 GUIs (.gui files): the windowDef tree drawn into an image for the
// guisurf surfaces of the level (wall screens, door panels, terminals).
//
// A GUI is a tree of windowDef (and editDef, choiceDef, listDef...) with
// properties like rect, backcolor, matcolor, background (a material or
// image), text, textscale, textalign, forecolor, visible. It is laid out on a
// 640 x 480 virtual screen. Text can come from the GUI state, which an
// entity fills from its "gui_*" keys: text "gui::gui_parm1".
//
// Rendering is done in software into a TRGBAlphaImage (no OpenGL needed):
// rectangles, scaled backgrounds and text with CGE's built-in UI font,
// blitted glyph by glyph. The result is served to CGE through the "d3gui:"
// URL protocol (uncompressed TGA), so textures are shared between surfaces.
//
// Not done yet: events and scripts (onTime transitions, onAction, the
// cursor), window rotation / shear, Doom 3's own fonts (fonts/*.dat).
unit Doom3Gui;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleVectors, CastleImages, CastleRectangles;

type
  TD3GuiWindow = class
    Name: String;
    { left, top, width, height in the 640 x 480 virtual screen, relative
      to the parent window }
    Rect: TFloatRectangle;
    BackColor, ForeColor, MatColor, BorderColor: TVector4;
    BorderSize: Single;
    Background: String;
    Text: String;
    TextScale: Single;
    TextAlign: Integer; { 0 left, 1 center, 2 right }
    TextAlignX, TextAlignY: Single;
    Visible: Boolean;
    NoWrap: Boolean;
    Children: specialize TObjectList<TD3GuiWindow>;
    constructor Create;
    destructor Destroy; override;
  end;

  TD3Gui = class
  public
    Name: String;
    Desktop: TD3GuiWindow;
    destructor Destroy; override;
    function LoadFromText(const AText: String): Boolean;
    function LoadFromVfs(const Path: String): Boolean;
    function WindowCount: Integer;
    function FindWindow(const AName: String): TD3GuiWindow;
  end;

const
  GuiWidth = 640;
  GuiHeight = 480;

{ Draw a GUI into a new image (caller frees). State answers gui:: variables
  (Names=Values, e.g. the entity's keys). }
function RenderGui(const Gui: TD3Gui; const State: TStrings): TRGBAlphaImage;

{ The texture URL of a GUI drawn with some state, '' when the GUI file is
  missing. Rendered once per (path, state) and cached. }
function GuiImageUrl(const GuiPath: String; const State: TStrings): String;

{ The GUI path a guisurf keyword means for an entity: "entity" -> its "gui"
  key, "entity2" / "entity3" -> "gui2" / "gui3", otherwise a path. }
function GuiSurfPath(const GuiSurf: String; const EntityGui, EntityGui2, EntityGui3: String): String;

{ The GUI texture URL for a guisurf material on an entity (Entity may be
  nil for world surfaces: then only explicit paths work). '' when none. }
function GuiSurfaceUrl(const GuiSurf: String; const EntityKeys: TStrings): String;

{ The GUI file drawn into a "d3gui:" texture URL ('' if it's not one). }
function GuiUrlPath(const Url: String): String;

procedure RegisterGuiProtocol;
procedure ClearGuiCache;
function GuiCacheCount: Integer;

implementation

uses
  Math,
  CastleDownload, CastleUriUtils, CastleLog, CastleTextureFontData, CastleTextureFont_DefaultUi,
  CastleUnicode,
  Doom3Files, Doom3Lexer, Doom3Decls, Doom3Images;

{ TD3GuiWindow }

constructor TD3GuiWindow.Create;
begin
  inherited Create;
  Rect := FloatRectangle(0, 0, GuiWidth, GuiHeight);
  BackColor := Vector4(0, 0, 0, 0);
  ForeColor := Vector4(1, 1, 1, 1);
  MatColor := Vector4(1, 1, 1, 1);
  BorderColor := Vector4(0, 0, 0, 0);
  TextScale := 0.35;
  Visible := True;
  Children := specialize TObjectList<TD3GuiWindow>.Create(True);
end;

destructor TD3GuiWindow.Destroy;
begin
  Children.Free;
  inherited Destroy;
end;

{ Parsing -------------------------------------------------------------------- }

function IsWindowKeyword(const L: String): Boolean;
begin
  Result := (L = 'windowdef') or (L = 'editdef') or (L = 'choicedef') or (L = 'sliderdef') or
    (L = 'listdef') or (L = 'renderdef') or (L = 'binddef') or (L = 'fielddef') or
    (L = 'markerdef') or (L = 'gamessddef') or (L = 'gamebearshootdef') or (L = 'gamebustoutdef');
end;

function Unquote(const S: String): String;
begin
  Result := Trim(S);
  if (Length(Result) >= 2) and (Result[1] = '"') and (Result[Length(Result)] = '"') then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

{ "a, b, c, d" numbers; missing / non-numeric ones keep Default's }
function ParseNumbers(const S: String; const Default: TVector4): TVector4;
var
  Parts: TStringArray;
  I: Integer;
begin
  Result := Default;
  Parts := Unquote(S).Split([',', ' ', #9], TStringSplitOptions.ExcludeEmpty);
  for I := 0 to Min(3, High(Parts)) do
    Result.Data[I] := D3StrToFloat(Parts[I], Default.Data[I]);
end;

procedure ParseWindow(const L: TDoom3Lexer; const W: TD3GuiWindow);
var
  Tok, Key, Value: String;
  V: TVector4;
  Child: TD3GuiWindow;
begin
  while L.Next(Tok) and (Tok <> '}') do
  begin
    Key := LowerCase(Tok);
    if IsWindowKeyword(Key) then
    begin
      Child := TD3GuiWindow.Create;
      Child.Name := L.NextStr;
      W.Children.Add(Child);
      if L.Check('{') then
        ParseWindow(L, Child);
    end else
    if Copy(Key, 1, 2) = 'on' then
    begin
      // an event: onTime 0, onAction, onNamedEvent x... and its block
      while not L.AtEnd and (L.Peek <> '{') do
        L.NextStr;
      if L.Check('{') then
        L.SkipBracedSection;
    end else
    if Tok = '{' then
      L.SkipBracedSection
    else
    begin
      { variable declarations name the variable before the value:
        definevec4 "$gui::hilite" 1, 1, 1, 1 / float x 0 }
      if (Key = 'definevec4') or (Key = 'definefloat') or (Key = 'float') or
         (Key = 'vec4') or (Key = 'vec2') or (Key = 'vec3') or (Key = 'rectangle') then
        L.NextStr;
      { a property's value: tokens separated by commas, e.g.
        rect 0, 0, 640, 480 / text "abc" / visible "gui::x" }
      Value := L.NextStr;
      while L.Check(',') do
        Value := Value + ',' + L.NextStr;
      L.Check(';');
      if Key = 'rect' then
      begin
        V := ParseNumbers(Value, Vector4(0, 0, GuiWidth, GuiHeight));
        W.Rect := FloatRectangle(V.X, V.Y, V.Z, V.W);
      end else
      if Key = 'backcolor' then
        W.BackColor := ParseNumbers(Value, W.BackColor)
      else
      if Key = 'forecolor' then
        W.ForeColor := ParseNumbers(Value, W.ForeColor)
      else
      if Key = 'matcolor' then
        W.MatColor := ParseNumbers(Value, W.MatColor)
      else
      if Key = 'bordercolor' then
        W.BorderColor := ParseNumbers(Value, W.BorderColor)
      else
      if Key = 'bordersize' then
        W.BorderSize := D3StrToFloat(Unquote(Value), 0)
      else
      if Key = 'background' then
        W.Background := Unquote(Value)
      else
      if Key = 'text' then
        W.Text := Unquote(Value)
      else
      if Key = 'textscale' then
        W.TextScale := D3StrToFloat(Unquote(Value), W.TextScale)
      else
      if Key = 'textalign' then
        W.TextAlign := Round(D3StrToFloat(Unquote(Value), 0))
      else
      if Key = 'textalignx' then
        W.TextAlignX := D3StrToFloat(Unquote(Value), 0)
      else
      if Key = 'textaligny' then
        W.TextAlignY := D3StrToFloat(Unquote(Value), 0)
      else
      if Key = 'visible' then
        { gui:: expressions stay visible }
        W.Visible := D3StrToFloat(Unquote(Value), 1) <> 0
      else
      if Key = 'nowrap' then
        W.NoWrap := D3StrToFloat(Unquote(Value), 0) <> 0;
      { everything else (font, noevents, definevec4, float...) is ignored }
    end;
  end;
end;

{ TD3Gui }

destructor TD3Gui.Destroy;
begin
  FreeAndNil(Desktop);
  inherited Destroy;
end;

function TD3Gui.LoadFromText(const AText: String): Boolean;
var
  L: TDoom3Lexer;
  Tok: String;
begin
  FreeAndNil(Desktop);
  L := TDoom3Lexer.Create(AText);
  try
    while L.Next(Tok) do
      if IsWindowKeyword(LowerCase(Tok)) then
      begin
        Desktop := TD3GuiWindow.Create;
        Desktop.Name := L.NextStr;
        if L.Check('{') then
          ParseWindow(L, Desktop);
        Break;
      end;
  finally
    L.Free;
  end;
  Result := Desktop <> nil;
end;

function TD3Gui.LoadFromVfs(const Path: String): Boolean;
var
  Text: String;
begin
  Name := NormalizeD3Path(Path);
  Text := D3Fs.ReadText(Path);
  Result := (Text <> '') and LoadFromText(Text);
end;

function CountWindows(const W: TD3GuiWindow): Integer;
var
  C: TD3GuiWindow;
begin
  Result := 1;
  for C in W.Children do
    Inc(Result, CountWindows(C));
end;

function TD3Gui.WindowCount: Integer;
begin
  if Desktop = nil then
    Result := 0
  else
    Result := CountWindows(Desktop);
end;

function FindIn(const W: TD3GuiWindow; const AName: String): TD3GuiWindow;
var
  C: TD3GuiWindow;
begin
  if SameText(W.Name, AName) then
    Exit(W);
  for C in W.Children do
  begin
    Result := FindIn(C, AName);
    if Result <> nil then
      Exit;
  end;
  Result := nil;
end;

function TD3Gui.FindWindow(const AName: String): TD3GuiWindow;
begin
  if Desktop = nil then
    Result := nil
  else
    Result := FindIn(Desktop, AName);
end;

{ Rendering ------------------------------------------------------------------ }

type
  TGuiPainter = class
    Image: TRGBAlphaImage;
    State: TStrings;
    Font: TTextureFontData;
    { blend a color onto a pixel (GUI coordinates: y down) }
    procedure Blend(const X, Y: Integer; const C: TVector4);
    procedure FillRect(const R: TFloatRectangle; const C: TVector4);
    procedure DrawImage(const R: TFloatRectangle; const Src: TCastleImage; const Tint: TVector4);
    procedure DrawText(const R: TFloatRectangle; const W: TD3GuiWindow; const S: String);
    procedure DrawWindow(const W: TD3GuiWindow; const ParentX, ParentY: Single);
    function ResolveText(const S: String): String;
  end;

procedure TGuiPainter.Blend(const X, Y: Integer; const C: TVector4);
var
  P: PVector4Byte;
  A: Single;
begin
  if (X < 0) or (Y < 0) or (X >= Image.Width) or (Y >= Image.Height) or (C.W <= 0) then
    Exit;
  { CGE images are bottom-to-top }
  P := Image.PixelPtr(X, Image.Height - 1 - Y);
  A := Min(1, C.W);
  P^.X := Round(P^.X * (1 - A) + Min(1, Max(0, C.X)) * 255 * A);
  P^.Y := Round(P^.Y * (1 - A) + Min(1, Max(0, C.Y)) * 255 * A);
  P^.Z := Round(P^.Z * (1 - A) + Min(1, Max(0, C.Z)) * 255 * A);
  P^.W := Round(Min(255, P^.W + (255 - P^.W) * A));
end;

procedure TGuiPainter.FillRect(const R: TFloatRectangle; const C: TVector4);
var
  X, Y: Integer;
begin
  if C.W <= 0 then
    Exit;
  for Y := Round(R.Bottom) to Round(R.Bottom + R.Height) - 1 do
    for X := Round(R.Left) to Round(R.Left + R.Width) - 1 do
      Blend(X, Y, C);
end;

procedure TGuiPainter.DrawImage(const R: TFloatRectangle; const Src: TCastleImage; const Tint: TVector4);
var
  X, Y, X0, Y0, X1, Y1: Integer;
  U, V: Single;
  C: TVector4;
begin
  X0 := Round(R.Left);
  Y0 := Round(R.Bottom);
  X1 := Round(R.Left + R.Width);
  Y1 := Round(R.Bottom + R.Height);
  if (X1 <= X0) or (Y1 <= Y0) then
    Exit;
  for Y := Y0 to Y1 - 1 do
    for X := X0 to X1 - 1 do
    begin
      U := (X - X0 + 0.5) / (X1 - X0);
      { GUI y goes down, the source image's rows go up }
      V := 1 - (Y - Y0 + 0.5) / (Y1 - Y0);
      C := Src.Colors[Min(Src.Width - 1, Trunc(U * Src.Width)), Min(Src.Height - 1, Trunc(V * Src.Height)), 0];
      Blend(X, Y, Vector4(C.X * Tint.X, C.Y * Tint.Y, C.Z * Tint.Z, C.W * Tint.W));
    end;
end;

function TGuiPainter.ResolveText(const S: String): String;
var
  Key: String;
begin
  Result := S;
  { "gui::name" or "$gui::name": the GUI state (the entity's keys) }
  Key := S;
  if (Key <> '') and (Key[1] = '$') then
    Delete(Key, 1, 1);
  if SameText(Copy(Key, 1, 5), 'gui::') then
  begin
    Key := Copy(Key, 6, MaxInt);
    if State <> nil then
      Result := State.Values[LowerCase(Key)]
    else
      Result := '';
  end;
  { Doom 3 strings use "\n" for new lines }
  Result := StringReplace(Result, '\n', #10, [rfReplaceAll]);
end;

procedure TGuiPainter.DrawText(const R: TFloatRectangle; const W: TD3GuiWindow; const S: String);
var
  Scale, LineHeight, PenX, LineWidth: Single;
  Lines: TStringList;
  Words: TStringArray;
  Line, Candidate, Para: String;
  I, J, GX, GY, SX, SY, DstX0, DstY0, DstW, DstH: Integer;
  G: TTextureFontData.TGlyph;
  Rect: TRectangle;
  Alpha: Single;
  Baseline: Single;

  function StringWidth(const T: String): Single;
  begin
    Result := Font.TextWidth(T) * Scale;
  end;

begin
  if S = '' then
    Exit;
  { Doom 3's fonts are 48 pixels at textscale 1 }
  Scale := 48 * W.TextScale / Max(1, Font.Size);
  LineHeight := Font.Size * Scale * 1.15;
  Lines := TStringList.Create;
  try
    { word wrap to the window width }
    for Para in S.Split([#10]) do
    begin
      if W.NoWrap then
      begin
        Lines.Add(Para);
        Continue;
      end;
      Words := Para.Split([' ']);
      Line := '';
      for I := 0 to High(Words) do
      begin
        if Line = '' then
          Candidate := Words[I]
        else
          Candidate := Line + ' ' + Words[I];
        if (Line <> '') and (StringWidth(Candidate) > R.Width - W.TextAlignX) then
        begin
          Lines.Add(Line);
          Line := Words[I];
        end else
          Line := Candidate;
      end;
      Lines.Add(Line);
    end;

    Baseline := R.Bottom + W.TextAlignY + Font.Size * Scale;
    for I := 0 to Lines.Count - 1 do
    begin
      LineWidth := StringWidth(Lines[I]);
      case W.TextAlign of
        1: PenX := R.Left + (R.Width - LineWidth) / 2;
        2: PenX := R.Left + R.Width - LineWidth - W.TextAlignX;
        else PenX := R.Left + W.TextAlignX;
      end;
      for J := 1 to Length(Lines[I]) do
      begin
        G := Font.Glyph(Ord(Lines[I][J]), False);
        if G = nil then
          Continue;
        Rect := Font.GlyphDrawImageRect(G);
        if (Rect.Width > 0) and (Rect.Height > 0) then
        begin
          { the glyph's box in GUI coordinates (y down); CGE draws a glyph
            at (pen x - G.X, baseline - G.Y) with y up }
          DstX0 := Round(PenX - G.X * Scale);
          DstY0 := Round(Baseline + G.Y * Scale - Integer(Rect.Height) * Scale);
          DstW := Max(1, Round(Rect.Width * Scale));
          DstH := Max(1, Round(Rect.Height * Scale));
          for GY := 0 to DstH - 1 do
            for GX := 0 to DstW - 1 do
            begin
              SX := Rect.Left + Min(Rect.Width - 1, Trunc((GX + 0.5) / DstW * Rect.Width));
              { atlas rows go up, GUI rows go down }
              SY := Rect.Bottom + Rect.Height - 1 - Min(Rect.Height - 1, Trunc((GY + 0.5) / DstH * Rect.Height));
              Alpha := PByte(Font.Image.PixelPtr(SX, SY))^ / 255;
              if Alpha > 0 then
                Blend(DstX0 + GX, DstY0 + GY, Vector4(W.ForeColor.X, W.ForeColor.Y, W.ForeColor.Z,
                  W.ForeColor.W * Alpha));
            end;
        end;
        PenX := PenX + G.AdvanceX * Scale;
      end;
      Baseline := Baseline + LineHeight;
    end;
  finally
    Lines.Free;
  end;
end;

procedure TGuiPainter.DrawWindow(const W: TD3GuiWindow; const ParentX, ParentY: Single);
var
  R: TFloatRectangle;
  M: TD3Material;
  ImageName, F: String;
  Src: TCastleImage;
  C: TD3GuiWindow;
  B: Single;
begin
  if not W.Visible then
    Exit;
  { Rect: left, top, width, height; TFloatRectangle's Bottom holds the top
    here (GUI y goes down) }
  R := FloatRectangle(ParentX + W.Rect.Left, ParentY + W.Rect.Bottom, W.Rect.Width, W.Rect.Height);
  FillRect(R, W.BackColor);
  if W.Background <> '' then
  begin
    { a material (its diffuse / stage image) or an image }
    M := Decls.Material(W.Background);
    ImageName := M.DiffuseImage;
    if M.StageImage <> '' then
      ImageName := M.StageImage;
    F := FindImageFile(ImageName, False);
    if F <> '' then
    try
      Src := LoadImage(D3FsUrl(F));
      try
        DrawImage(R, Src, W.MatColor);
      finally
        Src.Free;
      end;
    except
      on E: Exception do
        WritelnWarning('Doom3Gui', 'Cannot draw "%s": %s', [F, E.Message]);
    end;
  end;
  if (W.BorderSize > 0) and (W.BorderColor.W > 0) then
  begin
    B := W.BorderSize;
    FillRect(FloatRectangle(R.Left, R.Bottom, R.Width, B), W.BorderColor);
    FillRect(FloatRectangle(R.Left, R.Bottom + R.Height - B, R.Width, B), W.BorderColor);
    FillRect(FloatRectangle(R.Left, R.Bottom + B, B, R.Height - 2 * B), W.BorderColor);
    FillRect(FloatRectangle(R.Left + R.Width - B, R.Bottom + B, B, R.Height - 2 * B), W.BorderColor);
  end;
  DrawText(R, W, ResolveText(W.Text));
  for C in W.Children do
    DrawWindow(C, R.Left, R.Bottom);
end;

function RenderGui(const Gui: TD3Gui; const State: TStrings): TRGBAlphaImage;
var
  Painter: TGuiPainter;
begin
  Result := TRGBAlphaImage.Create(GuiWidth, GuiHeight);
  Result.Clear(Vector4Byte(0, 0, 0, 255));
  if (Gui = nil) or (Gui.Desktop = nil) then
    Exit;
  Painter := TGuiPainter.Create;
  try
    Painter.Image := Result;
    Painter.State := State;
    Painter.Font := Font_DefaultUi;
    Painter.DrawWindow(Gui.Desktop, 0, 0);
  finally
    Painter.Free;
  end;
end;

{ Cache and URL protocol ----------------------------------------------------- }

var
  GuiImages: specialize TObjectDictionary<String, TRGBAlphaImage>;
  GuiKeys: TStringList;
  ProtocolRegistered: Boolean;

type
  TGuiProtocol = class
    function Read(const Url: String; out MimeType: String): TStream;
  end;

var
  GuiProtocol: TGuiProtocol;

function TGuiProtocol.Read(const Url: String; out MimeType: String): TStream;
var
  Key: String;
  Img: TRGBAlphaImage;
begin
  Key := ChangeFileExt(ExtractFileName(UriDeleteProtocol(Url)), '');
  if not GuiImages.TryGetValue(Key, Img) then
    raise EFOpenError.Create('No such GUI image: ' + Url);
  Result := TMemoryStream.Create;
  SaveTga(Img, Result);
  Result.Position := 0;
  MimeType := 'image/x-tga';
end;

procedure RegisterGuiProtocol;
begin
  if ProtocolRegistered then
    Exit;
  RegisterUrlProtocol('d3gui', @GuiProtocol.Read, nil);
  ProtocolRegistered := True;
end;

function GuiImageUrl(const GuiPath: String; const State: TStrings): String;
var
  Gui: TD3Gui;
  FullKey, Key: String;
  I: Integer;
begin
  Result := '';
  if GuiPath = '' then
    Exit;
  RegisterGuiProtocol;
  FullKey := NormalizeD3Path(GuiPath);
  if State <> nil then
    for I := 0 to State.Count - 1 do
      if Copy(LowerCase(State.Names[I]), 1, 4) = 'gui_' then
        FullKey := FullKey + '|' + State[I];
  I := GuiKeys.IndexOf(FullKey);
  if I < 0 then
  begin
    Gui := TD3Gui.Create;
    try
      if not Gui.LoadFromVfs(GuiPath) then
      begin
        WritelnWarning('Doom3Gui', 'Cannot load GUI "%s"', [GuiPath]);
        Exit;
      end;
      I := GuiKeys.Add(FullKey);
      GuiImages.Add('gui' + IntToStr(I), RenderGui(Gui, State));
      WritelnLog('Doom3Gui', 'Rendered "%s" (%d windows) as gui%d', [Gui.Name, Gui.WindowCount, I]);
    finally
      Gui.Free;
    end;
  end;
  Result := 'd3gui:/gui' + IntToStr(I) + '.tga';
end;

function GuiSurfPath(const GuiSurf: String; const EntityGui, EntityGui2, EntityGui3: String): String;
begin
  if SameText(GuiSurf, 'entity') then
    Result := EntityGui
  else
  if SameText(GuiSurf, 'entity2') then
    Result := EntityGui2
  else
  if SameText(GuiSurf, 'entity3') then
    Result := EntityGui3
  else
    Result := GuiSurf;
end;

function GuiSurfaceUrl(const GuiSurf: String; const EntityKeys: TStrings): String;
var
  G1, G2, G3: String;
begin
  G1 := '';
  G2 := '';
  G3 := '';
  if EntityKeys <> nil then
  begin
    G1 := EntityKeys.Values['gui'];
    G2 := EntityKeys.Values['gui2'];
    G3 := EntityKeys.Values['gui3'];
  end;
  Result := GuiImageUrl(GuiSurfPath(GuiSurf, G1, G2, G3), EntityKeys);
end;

function GuiUrlPath(const Url: String): String;
var
  S: String;
  I: Integer;
begin
  Result := '';
  if Copy(Url, 1, 10) <> 'd3gui:/gui' then
    Exit;
  S := ChangeFileExt(Copy(Url, 11, MaxInt), '');
  I := StrToIntDef(S, -1);
  if (I < 0) or (I >= GuiKeys.Count) then
    Exit;
  { the cache key: path, then |key=value of the state }
  Result := GuiKeys[I];
  if Pos('|', Result) > 0 then
    Result := Copy(Result, 1, Pos('|', Result) - 1);
end;

procedure ClearGuiCache;
begin
  GuiImages.Clear;
  GuiKeys.Clear;
end;

function GuiCacheCount: Integer;
begin
  Result := GuiKeys.Count;
end;

initialization
  GuiImages := specialize TObjectDictionary<String, TRGBAlphaImage>.Create([doOwnsValues]);
  GuiKeys := TStringList.Create;
  GuiProtocol := TGuiProtocol.Create;
finalization
  if ProtocolRegistered then
    UnregisterUrlProtocol('d3gui');
  FreeAndNil(GuiProtocol);
  FreeAndNil(GuiImages);
  FreeAndNil(GuiKeys);
end.
