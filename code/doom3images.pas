{ Doom 3 images: finding the file of an image name (.tga, the dds/ copies,
  .png, .jpg) and running the image programs used by materials.

  Plain images go to Castle Game Engine directly as "d3fs:" URLs. Images that
  need processing are served by the "d3img:" protocol, whose path is the
  image program itself:

  - d3img:/normal/<program>  a tangent-space normal map in CGE's convention.
    Doom 3 normal maps have green pointing down the image (along +t), CGE
    wants it up the image, so green is inverted. heightmap(img, scale) is
    converted to a normal map (like R_HeightmapToNormalMap) and
    addnormals(a, b) adds two normal maps.
  - d3img:/color/<program>   makeIntensity, makeAlpha, invertColor...
    approximated by their source image.

  Processed images are encoded as uncompressed TGA (fast to write and read). }
unit Doom3Images;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  CastleImages, CastleVectors;

type
  TD3ImageKind = (ikColor, ikNormal);

{ URL of the image file for an image name, '' when there is none.
  Tries the name, then <name>.tga, dds/<name>.dds, <name>.dds, .png, .jpg. }
function FindImageFile(const AName: String; const AllowDds: Boolean = True): String;

{ Texture URL for a material image program; '' when the image is missing or
  means "nothing" (_flat, _white, _default for normal maps...). }
function ImageProgramUrl(const AProgram: String; const Kind: TD3ImageKind): String;

{ Evaluate an image program to an image (caller frees), nil if missing. }
function EvaluateImageProgram(const AProgram: String; const Kind: TD3ImageKind): TCastleImage;

procedure RegisterImageProtocol;

{ Simple uncompressed TGA writer (bottom-up rows, matching CGE images). }
procedure SaveTga(const Image: TCastleImage; const Stream: TStream);

implementation

uses
  Math,
  CastleDownload, CastleLog, CastleUriUtils, CastleTimeUtils,
  Doom3Files, Doom3Bfg, Doom3Lexer, Doom3Decls;

var
  ProtocolRegistered: Boolean;

function StripExt(const S: String): String;
var
  Ext: String;
begin
  Ext := LowerCase(ExtractFileExt(S));
  if (Ext = '.tga') or (Ext = '.dds') or (Ext = '.png') or (Ext = '.jpg') or (Ext = '.pcx') then
    Result := Copy(S, 1, Length(S) - Length(Ext))
  else
    Result := S;
end;

function FindImageFile(const AName: String; const AllowDds: Boolean): String;
var
  Base: String;
begin
  Base := NormalizeD3Path(StripExt(AName));
  if Base = '' then
    Exit('');
  if D3Fs.FileExists(Base + '.tga') then
    Exit(Base + '.tga');
  if D3Fs.FileExists(Base + '.png') then
    Exit(Base + '.png');
  if D3Fs.FileExists(Base + '.jpg') then
    Exit(Base + '.jpg');
  if AllowDds then
  begin
    if D3Fs.FileExists('dds/' + Base + '.dds') then
      Exit('dds/' + Base + '.dds');
    if D3Fs.FileExists(Base + '.dds') then
      Exit(Base + '.dds');
  end;
  Result := '';
end;

function IsBuiltinImage(const S: String): Boolean;
begin
  Result := (S <> '') and (S[1] = '_');
end;

function IsPlainName(const S: String): Boolean;
begin
  Result := Pos('(', S) = 0;
end;

var
  { images reported missing (once each) }
  MissingImages: TStringList;

procedure ReportMissingImage(const AName, Why: String);
begin
  if MissingImages = nil then
  begin
    MissingImages := TStringList.Create;
    MissingImages.Sorted := True;
    MissingImages.Duplicates := dupIgnore;
  end;
  if MissingImages.IndexOf(AName) >= 0 then
    Exit;
  MissingImages.Add(AName);
  WritelnLog('Doom3Images', 'Image %s: %s', [Why, AName]);
end;

function ImageProgramUrl(const AProgram: String; const Kind: TD3ImageKind): String;
var
  F: String;
begin
  Result := '';
  if (AProgram = '') or IsBuiltinImage(AProgram) then
    Exit;
  if Kind = ikNormal then
  begin
    { normal maps always need processing (green flip at least); DDS normal
      maps are compressed (often RXGB), so only uncompressed ones are used }
    if IsPlainName(AProgram) and (FindImageFile(AProgram, False) = '') then
    begin
      if FindImageFile(AProgram) <> '' then
        ReportMissingImage(AProgram, 'normal map only as DDS, not used')
      else
        ReportMissingImage(AProgram, 'not found');
      Exit;
    end;
    Result := 'd3img:/normal/' + AProgram;
  end
  else
  if IsPlainName(AProgram) then
  begin
    F := FindImageFile(AProgram);
    if F <> '' then
      Result := D3FsUrl(F)
    else
      ReportMissingImage(AProgram, 'not found');
  end else
    Result := 'd3img:/color/' + AProgram;
end;

function LoadPlain(const AName: String): TCastleImage;
var
  F: String;
  Loaded: TEncodedImage;
begin
  Result := nil;
  F := FindImageFile(AName, False);
  if F = '' then
    Exit;
  try
    Loaded := LoadEncodedImage(D3FsUrl(F));
    if Loaded is TCastleImage then
      Result := TCastleImage(Loaded)
    else
      Loaded.Free;
  except
    on E: Exception do
      WritelnWarning('Doom3Images', 'Cannot load "%s": %s', [F, E.Message]);
  end;
end;

{ A copy of any 8-bit image as RGB (grey is expanded, alpha dropped). }
function ToRGB(const Src: TCastleImage): TRGBImage;
var
  I, N: Integer;
  S, D: PByte;
  C: TVector4;
  X, Y: Integer;
begin
  Result := TRGBImage.Create(Src.Width, Src.Height);
  N := Src.Width * Src.Height;
  S := Src.RawPixels;
  D := Result.RawPixels;
  case Src.PixelSize of
    1: for I := 0 to N - 1 do
       begin
         D[0] := S[0]; D[1] := S[0]; D[2] := S[0];
         Inc(S); Inc(D, 3);
       end;
    2: for I := 0 to N - 1 do
       begin
         D[0] := S[0]; D[1] := S[0]; D[2] := S[0];
         Inc(S, 2); Inc(D, 3);
       end;
    3: Move(S^, D^, N * 3);
    4: for I := 0 to N - 1 do
       begin
         D[0] := S[0]; D[1] := S[1]; D[2] := S[2];
         Inc(S, 4); Inc(D, 3);
       end;
    else
      for Y := 0 to Src.Height - 1 do
        for X := 0 to Src.Width - 1 do
        begin
          C := Src.Colors[X, Y, 0];
          Result.Colors[X, Y, 0] := C;
        end;
  end;
end;

{ Doom 3 normal map -> CGE convention: green inverted (in place). }
procedure FlipGreen(const Img: TRGBImage);
var
  I: Integer;
  P: PByte;
begin
  P := Img.RawPixels;
  for I := 0 to Img.Width * Img.Height - 1 do
  begin
    P[1] := 255 - P[1];
    Inc(P, 3);
  end;
end;

procedure StoreNormal(const P: PByte; const NX, NY, NZ: Single);
var
  L2, K: Single;
begin
  L2 := NX * NX + NY * NY + NZ * NZ;
  if L2 < 1e-12 then
  begin
    P[0] := 128; P[1] := 128; P[2] := 255;
    Exit;
  end;
  { (n / |n| * 0.5 + 0.5) * 255, rounded: Trunc(x + 0.5) for x >= 0 is
    much faster than Round }
  K := 127.5 / Sqrt(L2);
  P[0] := Trunc(NX * K + 128.0);
  P[1] := Trunc(NY * K + 128.0);
  P[2] := Trunc(NZ * K + 128.0);
end;

{ heightmap(): like R_HeightmapToNormalMap, from the image's luminance. }
function HeightToNormal(const Src: TRGBImage; const Scale: Single): TRGBImage;
var
  W, H, X, Y, XL, XR: Integer;
  { heights * 3 (the sum of the channels), wrapping around the edges }
  Heights: array of Integer;
  Row, Down, Up: PInteger;
  P: PByte;
  S: Single;
begin
  W := Src.Width;
  H := Src.Height;
  SetLength(Heights, W * H);
  P := Src.RawPixels;
  for X := 0 to W * H - 1 do
  begin
    Heights[X] := P[0] + P[1] + P[2];
    Inc(P, 3);
  end;
  S := Scale / 256 / 3;
  Result := TRGBImage.Create(W, H);
  P := Result.RawPixels;
  for Y := 0 to H - 1 do
  begin
    Row := @Heights[Y * W];
    Down := @Heights[((Y + H - 1) mod H) * W];
    Up := @Heights[((Y + 1) mod H) * W];
    for X := 0 to W - 1 do
    begin
      if X = 0 then XL := W - 1 else XL := X - 1;
      if X = W - 1 then XR := 0 else XR := X + 1;
      { CGE images are bottom-to-top, so Y + 1 is up the image }
      StoreNormal(P, (Row[XL] - Row[XR]) * S, (Down[X] - Up[X]) * S, 1);
      Inc(P, 3);
    end;
  end;
end;

{ addnormals(): sums the slopes of two normal maps. }
function AddNormals(const A, B: TRGBImage): TRGBImage;
var
  I: Integer;
  PA, PB, D: PByte;
  AX, AY, AZ, BX, BY, BZ: Single;
begin
  if (B.Width <> A.Width) or (B.Height <> A.Height) then
    B.Resize(A.Width, A.Height);
  Result := TRGBImage.Create(A.Width, A.Height);
  PA := A.RawPixels;
  PB := B.RawPixels;
  D := Result.RawPixels;
  for I := 0 to A.Width * A.Height - 1 do
  begin
    AX := PA[0] * (1 / 127.5) - 1; AY := PA[1] * (1 / 127.5) - 1; AZ := PA[2] * (1 / 127.5) - 1;
    BX := PB[0] * (1 / 127.5) - 1; BY := PB[1] * (1 / 127.5) - 1; BZ := PB[2] * (1 / 127.5) - 1;
    StoreNormal(D, AX + BX, AY + BY, AZ * BZ);
    Inc(PA, 3); Inc(PB, 3); Inc(D, 3);
  end;
end;

{ Color's pixels with Alpha's alpha (its brightness without an alpha
  channel), Alpha sampled at the same relative place. }
function AlphaFrom(const Color, Alpha: TCastleImage): TRGBAlphaImage;
var
  X, Y, AX, AY: Integer;
  C, A: TVector4;
begin
  Result := TRGBAlphaImage.Create(Color.Width, Color.Height);
  for Y := 0 to Color.Height - 1 do
    for X := 0 to Color.Width - 1 do
    begin
      C := Color.Colors[X, Y, 0];
      AX := Min(Alpha.Width - 1, X * Alpha.Width div Max(1, Color.Width));
      AY := Min(Alpha.Height - 1, Y * Alpha.Height div Max(1, Color.Height));
      A := Alpha.Colors[AX, AY, 0];
      if Alpha.HasAlpha then
        C.W := A.W
      else
        C.W := (A.X + A.Y + A.Z) / 3;
      Result.Colors[X, Y, 0] := C;
    end;
end;

function Evaluate(const Lexer: TDoom3Lexer; const Kind: TD3ImageKind): TCastleImage;
var
  Func: String;
  A, B: TCastleImage;
  Scale: Single;
begin
  Result := nil;
  Func := Lexer.NextStr;
  if Lexer.Check('(') then
  begin
    Func := LowerCase(Func);
    if Func = 'heightmap' then
    begin
      A := Evaluate(Lexer, ikColor);
      Scale := 1;
      if Lexer.Check(',') then
        Scale := Lexer.ReadFloat;
      Lexer.Check(')');
      if A <> nil then
      try
        B := ToRGB(A);
        try
          Result := HeightToNormal(TRGBImage(B), Scale);
        finally
          B.Free;
        end;
      finally
        A.Free;
      end;
    end else
    if Func = 'castlealphafrom' then
    begin
      { (this port's) the first image's colors with the second's alpha (or
        brightness): a burn-away skin alpha tested by its dissolve map }
      A := Evaluate(Lexer, ikColor);
      B := nil;
      if Lexer.Check(',') then
        B := Evaluate(Lexer, ikColor);
      Lexer.Check(')');
      if (A <> nil) and (B <> nil) then
      begin
        Result := AlphaFrom(A, B);
        A.Free;
        B.Free;
      end else
      begin
        Result := A;
        B.Free;
      end;
    end else
    if Func = 'addnormals' then
    begin
      A := Evaluate(Lexer, ikNormal);
      B := nil;
      if Lexer.Check(',') then
        B := Evaluate(Lexer, ikNormal);
      Lexer.Check(')');
      if (A <> nil) and (B <> nil) then
      begin
        Result := AddNormals(TRGBImage(A), TRGBImage(B));
        A.Free;
        B.Free;
      end else
      if A <> nil then
        Result := A
      else
        Result := B;
    end else
    begin
      { makeIntensity, makeAlpha, downsize, scale, invertAlpha, invertColor,
        smoothNormals...: use the first argument }
      Result := Evaluate(Lexer, Kind);
      while not Lexer.AtEnd and not Lexer.Check(')') do
        Lexer.NextStr;
    end;
  end else
  begin
    if IsBuiltinImage(Func) then
      Exit(nil);
    A := LoadPlain(Func);
    if (A <> nil) and (Kind = ikNormal) then
    begin
      Result := ToRGB(A);
      A.Free;
      FlipGreen(TRGBImage(Result));
    end else
      Result := A;
  end;
end;

{ Doom 3 BFG: the image for a name without extension from its .bimage. }
function LoadBfgImage(const AName: String): TCastleImage;
var
  GenPath, CoveragePath: String;
  Face: Integer;
  Camera: Boolean;
  Data, Coverage: TStream;
begin
  Result := nil;
  if not D3Fs.BfgImage(AName, GenPath, CoveragePath, Face, Camera) then
    Exit;
  Data := D3Fs.OpenFile(GenPath);
  if Data = nil then
    Exit;
  Coverage := nil;
  try
    if CoveragePath <> '' then
      Coverage := D3Fs.OpenFile(CoveragePath);
    Result := BfgDecodeImage(Data, Face, Camera, Coverage);
    if Result = nil then
      WritelnWarning('Doom3Images', 'Cannot decode "%s"', [GenPath]);
  finally
    Data.Free;
    Coverage.Free;
  end;
end;

{ Doom 3 BFG has the results of image programs, named after them:
  "addnormals(a, heightmap(b, 4))" is generated/images/addnormals/a/
  heightmap/b/4 (idBinaryImage::GetGeneratedFileName). }
function BfgProgramName(const AProgram: String): String;
begin
  Result := LowerCase(AProgram);
  Result := StringReplace(Result, ' ', '', [rfReplaceAll]);
  Result := StringReplace(Result, '.tga', '', [rfReplaceAll]);
  Result := StringReplace(Result, '(', '/', [rfReplaceAll]);
  Result := StringReplace(Result, ',', '/', [rfReplaceAll]);
  Result := StringReplace(Result, ')', '', [rfReplaceAll]);
end;

{ BfgConvertHook: the .tga an image name stands for, or the .wav of a
  sound, made from the generated binary. }
function BfgConvert(const APath: String): TStream;
var
  Ext: String;
  Img: TCastleImage;
  Gen: TStream;
begin
  Result := nil;
  Ext := ExtractFileExt(APath);
  if Ext = '.tga' then
  begin
    Img := LoadBfgImage(ChangeFileExt(APath, ''));
    if Img = nil then
      Exit;
    try
      Result := TMemoryStream.Create;
      SaveTga(Img, Result);
      Result.Position := 0;
    finally
      Img.Free;
    end;
  end else
  if Ext = '.wav' then
  begin
    Gen := D3Fs.OpenGenerated(APath);
    if Gen = nil then
      Exit;
    try
      Result := BfgDecodeSound(Gen);
      if Result = nil then
        WritelnWarning('Doom3Images', 'Cannot decode the sound "%s"', [APath]);
    finally
      Gen.Free;
    end;
  end;
end;

function EvaluateImageProgram(const AProgram: String; const Kind: TD3ImageKind): TCastleImage;
var
  Lexer: TDoom3Lexer;
  A: TCastleImage;
begin
  if D3Fs.IsBfg and not IsPlainName(AProgram) then
  begin
    A := LoadBfgImage(BfgProgramName(AProgram));
    if A <> nil then
    begin
      if Kind = ikNormal then
      begin
        Result := ToRGB(A);
        A.Free;
        FlipGreen(TRGBImage(Result));
      end else
        Result := A;
      Exit;
    end;
  end;
  Lexer := TDoom3Lexer.Create(AProgram);
  try
    Result := Evaluate(Lexer, Kind);
  finally
    Lexer.Free;
  end;
end;

function ToByte(const F: Single): Byte;
begin
  if F <= 0 then
    Result := 0
  else
  if F >= 1 then
    Result := 255
  else
    Result := Round(F * 255);
end;

procedure SaveTga(const Image: TCastleImage; const Stream: TStream);
var
  Header: array [0..17] of Byte;
  X, Y, Bpp: Integer;
  C: TVector4;
  Row: TBytes;
  Src: PByte;
begin
  if Image.HasAlpha then
    Bpp := 4
  else
    Bpp := 3;
  FillChar(Header, SizeOf(Header), 0);
  Header[2] := 2; { uncompressed true colour }
  Header[12] := Image.Width and $FF;
  Header[13] := Image.Width shr 8;
  Header[14] := Image.Height and $FF;
  Header[15] := Image.Height shr 8;
  Header[16] := Bpp * 8;
  if Bpp = 4 then
    Header[17] := 8; { alpha bits, origin bottom-left }
  Stream.WriteBuffer(Header, SizeOf(Header));
  SetLength(Row, Image.Width * Bpp);
  for Y := 0 to Image.Height - 1 do
  begin
    if Image.PixelSize = Cardinal(Bpp) then
    begin
      { RGB(A) bytes -> BGR(A) }
      Src := Image.RowPtr(Y);
      for X := 0 to Image.Width - 1 do
      begin
        Row[X * Bpp + 0] := Src[X * Bpp + 2];
        Row[X * Bpp + 1] := Src[X * Bpp + 1];
        Row[X * Bpp + 2] := Src[X * Bpp + 0];
        if Bpp = 4 then
          Row[X * Bpp + 3] := Src[X * Bpp + 3];
      end;
    end else
      for X := 0 to Image.Width - 1 do
      begin
        C := Image.Colors[X, Y, 0];
        Row[X * Bpp + 0] := ToByte(C.Z);
        Row[X * Bpp + 1] := ToByte(C.Y);
        Row[X * Bpp + 2] := ToByte(C.X);
        if Bpp = 4 then
          Row[X * Bpp + 3] := ToByte(C.W);
      end;
    if Length(Row) > 0 then
      Stream.WriteBuffer(Row[0], Length(Row));
  end;
end;

type
  THandler = class
    function Read(const Url: String; out MimeType: String): TStream;
  end;

var
  Handler: THandler;

function THandler.Read(const Url: String; out MimeType: String): TStream;
var
  Path, Prog: String;
  Kind: TD3ImageKind;
  Img: TCastleImage;
  Start: TTimerResult;
begin
  Start := Timer;
  Inc(ProfileImageCount);
  Path := RawUriDecode(UriDeleteProtocol(Url));
  while (Path <> '') and (Path[1] = '/') do
    Delete(Path, 1, 1);
  if Copy(Path, 1, 7) = 'normal/' then
  begin
    Kind := ikNormal;
    Prog := Copy(Path, 8, MaxInt);
  end else
  begin
    Kind := ikColor;
    Prog := Copy(Path, Pos('/', Path) + 1, MaxInt);
  end;
  Img := EvaluateImageProgram(Prog, Kind);
  if Img = nil then
    raise EFOpenError.Create('Cannot evaluate Doom 3 image program: ' + Prog);
  try
    Result := TMemoryStream.Create;
    SaveTga(Img, Result);
    Result.Position := 0;
  finally
    Img.Free;
  end;
  MimeType := 'image/x-tga';
  ProfileImageSeconds := ProfileImageSeconds + TimerSeconds(Timer, Start);
end;

procedure RegisterImageProtocol;
begin
  if ProtocolRegistered then
    Exit;
  if Handler = nil then
    Handler := THandler.Create;
  RegisterUrlProtocol('d3img', @Handler.Read, nil);
  ProtocolRegistered := True;
end;

initialization
  BfgConvertHook := @BfgConvert;
finalization
  FreeAndNil(MissingImages);
  if ProtocolRegistered then
    UnregisterUrlProtocol('d3img');
  FreeAndNil(Handler);
end.
