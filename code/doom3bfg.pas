{ Doom 3 BFG Edition's binary formats: the pieces shared by the loaders.

  The BFG edition ships no source assets: its ".resources" containers
  (Doom3Files mounts them) hold "generated/" binaries that idTech 4.5 wrote
  from them. Numbers are big endian where the engine used ReadBig and
  little endian where it used ReadFloat / ReadVec3 / ReadString.

  - TBfgReader: a file in memory with both kinds of reads.
  - BfgReadModel: a render model ("BRM" 108: generated/rendermodels/*.blwo
    and *.base, the head of *.bmd5mesh, the models inside a *.bproc), as
    surfaces of idDrawVerts (position, half float texture coordinates,
    byte normals, two byte quadruples: colors, or joints and weights).
  - BfgDecodeImage: a *.bimage (DXT1 / DXT5 and plain formats; normal maps
    with x in alpha, diffuse maps as YCoCg, alpha kept in green) to a CGE
    image like the TGA it was made from.
  - BfgDecodeSound: a *.idwav (MS ADPCM or PCM) to a 16 bit PCM WAV file. }
unit Doom3Bfg;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  CastleVectors, CastleImages;

type
  TBfgReader = class
  strict private
    FData: PByte;
    FSize, FPos: PtrInt;
    FOwned: TStream;
    procedure Need(const N: PtrInt);
  public
    { Reads the whole stream; frees it in the destructor when AOwns. }
    constructor Create(const AStream: TStream; const AOwns: Boolean);
    destructor Destroy; override;
    function Eof: Boolean;
    property Position: PtrInt read FPos write FPos;
    property Size: PtrInt read FSize;
    function Here: PByte;
    procedure Skip(const N: PtrInt);
    function U8: Byte;
    function Bool: Boolean;
    function BigInt: Int32;
    function BigUInt: UInt32;
    function BigInt64: Int64;
    function BigWord: Word;
    function BigFloat: Single;
    function BigVec3: TVector3;
    function LittleInt: Int32;
    function LittleWord: Word;
    function LittleFloat: Single;
    function LittleVec3: TVector3;
    { idFile::ReadString: a little endian length, then the characters }
    function Str: String;
  end;

  TBfgVertex = record
    Position: TVector3;
    ST: TVector2;
    Normal: TVector3;
    { idDrawVert's color and color2: vertex colors, or (md5 meshes) four
      joint numbers and their weights }
    Color, Color2: array [0..3] of Byte;
  end;

  TBfgSurface = record
    Material: String;
    Verts: array of TBfgVertex;
    Indexes: array of Int32;
    { a precomputed shadow volume (the "_prelight_" models of a .bproc) }
    ShadowVerts: array of TVector3;
    NoFrontCaps, NoCaps: Integer;
  end;

  TBfgModel = record
    Name: String;
    Surfaces: array of TBfgSurface;
    BoundsMin, BoundsMax: TVector3;
  end;

const
  BfgProcMagic = $50524F01;
  BfgMd5MeshMagic = $35444D6A;
  BfgMd5AnimMagic = $424D4465;
  BfgCmMagic = $424F0064;

{ A render model at the reader's position. False (the reader's position is
  then undefined) when it isn't one. }
function BfgReadModel(const R: TBfgReader; out M: TBfgModel): Boolean;
{ One idDrawVert (32 bytes; positions big endian, as in a .bmd5mesh). }
procedure BfgReadDrawVertBig(const R: TBfgReader; out V: TBfgVertex);
function BfgHalfToFloat(const H: Word): Single;

{ A .bimage as a TRGBImage or TRGBAlphaImage (caller frees), nil when it
  can't be read. Face: the side of a cube map (0 otherwise). CameraCube:
  undo the turns Doom 3 gave a "cameraCubeMap" side (the result is the
  _forward, _back, _left, _right, _up, _down image again). Coverage: the
  image's alpha test version (its alpha is in green), which replaces the
  result's alpha; nil for none. }
function BfgDecodeImage(const Data: TStream; const Face: Integer = 0;
  const CameraCube: Boolean = False; const Coverage: TStream = nil): TCastleImage;
{ An .idwav as a 16 bit PCM WAV file in memory (caller frees), nil when it
  can't be read. }
function BfgDecodeSound(const Data: TStream): TMemoryStream;

implementation

uses
  Math;

{ TBfgReader ----------------------------------------------------------------- }

constructor TBfgReader.Create(const AStream: TStream; const AOwns: Boolean);
var
  Mem: TMemoryStream;
begin
  inherited Create;
  if AStream is TCustomMemoryStream then
  begin
    FData := TCustomMemoryStream(AStream).Memory;
    FSize := AStream.Size;
    if AOwns then
      FOwned := AStream;
  end else
  begin
    Mem := TMemoryStream.Create;
    AStream.Position := 0;
    Mem.CopyFrom(AStream, AStream.Size);
    FData := Mem.Memory;
    FSize := Mem.Size;
    FOwned := Mem;
    if AOwns then
      AStream.Free;
  end;
end;

destructor TBfgReader.Destroy;
begin
  FreeAndNil(FOwned);
  inherited;
end;

procedure TBfgReader.Need(const N: PtrInt);
begin
  if (N < 0) or (FPos + N > FSize) then
    raise EReadError.CreateFmt('Doom 3 BFG file ends at %d (reading %d bytes at %d)', [FSize, N, FPos]);
end;

function TBfgReader.Eof: Boolean;
begin
  Result := FPos >= FSize;
end;

function TBfgReader.Here: PByte;
begin
  Result := FData + FPos;
end;

procedure TBfgReader.Skip(const N: PtrInt);
begin
  Need(N);
  Inc(FPos, N);
end;

function TBfgReader.U8: Byte;
begin
  Need(1);
  Result := FData[FPos];
  Inc(FPos);
end;

function TBfgReader.Bool: Boolean;
begin
  Result := U8 <> 0;
end;

function TBfgReader.BigUInt: UInt32;
begin
  Need(4);
  Result := (UInt32(FData[FPos]) shl 24) or (UInt32(FData[FPos + 1]) shl 16) or
    (UInt32(FData[FPos + 2]) shl 8) or FData[FPos + 3];
  Inc(FPos, 4);
end;

function TBfgReader.BigInt: Int32;
begin
  Result := Int32(BigUInt);
end;

function TBfgReader.BigInt64: Int64;
var
  Hi, Lo: UInt32;
begin
  Hi := BigUInt;
  Lo := BigUInt;
  Result := Int64((UInt64(Hi) shl 32) or Lo);
end;

function TBfgReader.BigWord: Word;
begin
  Need(2);
  Result := (Word(FData[FPos]) shl 8) or FData[FPos + 1];
  Inc(FPos, 2);
end;

function TBfgReader.BigFloat: Single;
var
  U: UInt32;
begin
  U := BigUInt;
  Move(U, Result, 4);
end;

function TBfgReader.BigVec3: TVector3;
begin
  Result.X := BigFloat;
  Result.Y := BigFloat;
  Result.Z := BigFloat;
end;

function TBfgReader.LittleInt: Int32;
begin
  Need(4);
  Move(FData[FPos], Result, 4);
  Inc(FPos, 4);
end;

function TBfgReader.LittleWord: Word;
begin
  Need(2);
  Move(FData[FPos], Result, 2);
  Inc(FPos, 2);
end;

function TBfgReader.LittleFloat: Single;
begin
  Need(4);
  Move(FData[FPos], Result, 4);
  Inc(FPos, 4);
end;

function TBfgReader.LittleVec3: TVector3;
begin
  Need(12);
  Move(FData[FPos], Result, 12);
  Inc(FPos, 12);
end;

function TBfgReader.Str: String;
var
  N: Int32;
begin
  N := LittleInt;
  Result := '';
  if N <= 0 then
    Exit;
  Need(N);
  SetLength(Result, N);
  Move(FData[FPos], Result[1], N);
  Inc(FPos, N);
  { stored without the terminator; cut at one anyway }
  N := Pos(#0, Result);
  if N > 0 then
    SetLength(Result, N - 1);
end;

{ Render models -------------------------------------------------------------- }

function BfgHalfToFloat(const H: Word): Single;
var
  E, M: Integer;
begin
  E := (H shr 10) and 31;
  M := H and 1023;
  if (E > 0) and (E < 31) then
    Result := Power(2, E - 15) * (1 + M / 1024)
  else
  if M = 0 then
    Result := 0
  else
    Result := Power(2, -14) * (M / 1024);
  if (H and $8000) <> 0 then
    Result := -Result;
end;

procedure ReadVertTail(const R: TBfgReader; var V: TBfgVertex);
var
  S, T: Word;
  B: array [0..3] of Byte;
  I: Integer;
begin
  S := R.BigWord;
  T := R.BigWord;
  V.ST := Vector2(BfgHalfToFloat(S), BfgHalfToFloat(T));
  for I := 0 to 3 do
    B[I] := R.U8;
  V.Normal := Vector3(B[0] * (2 / 255) - 1, B[1] * (2 / 255) - 1, B[2] * (2 / 255) - 1);
  R.Skip(4); { tangent }
  for I := 0 to 3 do
    V.Color[I] := R.U8;
  for I := 0 to 3 do
    V.Color2[I] := R.U8;
end;

procedure BfgReadDrawVertBig(const R: TBfgReader; out V: TBfgVertex);
begin
  V.Position := R.BigVec3;
  ReadVertTail(R, V);
end;

function BfgReadModel(const R: TBfgReader; out M: TBfgModel): Boolean;
const
  BrmMagic = $42524D6C;
var
  I, J, NumVerts, InFile, NumIndexes, N: Integer;
begin
  M.Name := '';
  SetLength(M.Surfaces, 0);
  if R.BigUInt <> BrmMagic then
    Exit(False);
  R.BigInt64; { time stamp }
  N := R.BigInt;
  if (N < 0) or (N > 100000) then
    Exit(False);
  SetLength(M.Surfaces, N);
  for I := 0 to N - 1 do
  begin
    R.BigInt; { id }
    M.Surfaces[I].Material := R.Str;
    M.Surfaces[I].NoCaps := 0;
    M.Surfaces[I].NoFrontCaps := 0;
    if not R.Bool then
      Continue;
    R.Skip(24); { bounds }
    R.BigInt; { ambientViewCount }
    R.Skip(4); { generateNormals, tangentsCalculated, perfectHull, referencedIndexes }
    NumVerts := R.BigInt;
    InFile := R.BigInt;
    if InFile > 0 then
    begin
      SetLength(M.Surfaces[I].Verts, NumVerts);
      for J := 0 to NumVerts - 1 do
      begin
        M.Surfaces[I].Verts[J].Position := R.LittleVec3;
        ReadVertTail(R, M.Surfaces[I].Verts[J]);
      end;
    end;
    InFile := R.BigInt;
    SetLength(M.Surfaces[I].ShadowVerts, InFile);
    for J := 0 to InFile - 1 do
    begin
      M.Surfaces[I].ShadowVerts[J] := R.LittleVec3;
      R.Skip(4); { w }
    end;
    NumIndexes := R.BigInt;
    SetLength(M.Surfaces[I].Indexes, NumIndexes);
    for J := 0 to NumIndexes - 1 do
      M.Surfaces[I].Indexes[J] := R.BigWord;
    if R.BigInt > 0 then
      R.Skip(2 * PtrInt(NumIndexes)); { silIndexes }
    R.Skip(4 * PtrInt(R.BigInt)); { mirroredVerts }
    R.Skip(8 * PtrInt(R.BigInt)); { dupVerts }
    R.Skip(8 * PtrInt(R.BigInt)); { silEdges }
    if R.Bool then
      R.Skip(16 * PtrInt(NumVerts)); { dominantTris }
    M.Surfaces[I].NoFrontCaps := R.BigInt;
    M.Surfaces[I].NoCaps := R.BigInt;
    R.BigInt; { shadowCapPlaneBits }
  end;
  M.BoundsMin := R.LittleVec3;
  M.BoundsMax := R.LittleVec3;
  R.Skip(12); { overlaysAdded, lastModifiedFrame, lastArchivedFrame }
  M.Name := R.Str;
  R.Skip(9); { flags }
  Result := True;
end;

{ Images --------------------------------------------------------------------- }

const
  FmtRgba8 = 1;
  FmtXrgb8 = 2;
  FmtAlpha = 3;
  FmtL8A8 = 4;
  FmtLum8 = 5;
  FmtInt8 = 6;
  FmtDxt1 = 7;
  FmtDxt5 = 8;
  FmtRgb565 = 12;
  CfmNormalDxt5 = 1;
  CfmYCoCgDxt5 = 2;
  CfmGreenAlpha = 3;

type
  TRgba = array [0..3] of Byte;
  PRgba = ^TRgba;
  TRgbaArray = array of TRgba;

procedure Color565(const C: Word; out P: TRgba);
begin
  P[0] := ((C shr 11) and 31) * 255 div 31;
  P[1] := ((C shr 5) and 63) * 255 div 63;
  P[2] := (C and 31) * 255 div 31;
  P[3] := 255;
end;

{ One level of an image to top-down RGBA. }
function DecodeLevel(const Src: PByte; const SrcSize: PtrInt; const Format, W, H: Integer;
  out Pixels: TRgbaArray): Boolean;
var
  X, Y, BX, BY, I, J, Code: Integer;
  P: PByte;
  C: array [0..3] of TRgba;
  A: array [0..7] of Byte;
  C0, C1: Word;
  Bits: UInt64;
  ColorBits: UInt32;
  D: PRgba;
  BlocksW, BlocksH: Integer;
begin
  Result := False;
  if (W <= 0) or (H <= 0) or (W > 16384) or (H > 16384) then
    Exit;
  SetLength(Pixels, W * H);
  Bits := 0;
  case Format of
    FmtRgba8, FmtXrgb8:
      begin
        if SrcSize < PtrInt(W) * H * 4 then
          Exit;
        Move(Src^, Pixels[0], W * H * 4);
        if Format = FmtXrgb8 then
          for I := 0 to W * H - 1 do
            Pixels[I][3] := 255;
      end;
    FmtAlpha, FmtLum8, FmtInt8:
      begin
        if SrcSize < PtrInt(W) * H then
          Exit;
        for I := 0 to W * H - 1 do
        begin
          if Format = FmtAlpha then
            J := 255
          else
            J := Src[I];
          Pixels[I][0] := J;
          Pixels[I][1] := J;
          Pixels[I][2] := J;
          if Format = FmtLum8 then
            Pixels[I][3] := 255
          else
            Pixels[I][3] := Src[I];
        end;
      end;
    FmtL8A8:
      begin
        if SrcSize < PtrInt(W) * H * 2 then
          Exit;
        for I := 0 to W * H - 1 do
        begin
          Pixels[I][0] := Src[I * 2];
          Pixels[I][1] := Src[I * 2];
          Pixels[I][2] := Src[I * 2];
          Pixels[I][3] := Src[I * 2 + 1];
        end;
      end;
    FmtRgb565:
      begin
        if SrcSize < PtrInt(W) * H * 2 then
          Exit;
        { big endian (the engine uploads it with GL_UNPACK_SWAP_BYTES) }
        for I := 0 to W * H - 1 do
          Color565((Word(Src[I * 2]) shl 8) or Src[I * 2 + 1], Pixels[I]);
      end;
    FmtDxt1, FmtDxt5:
      begin
        BlocksW := (W + 3) div 4;
        BlocksH := (H + 3) div 4;
        if Format = FmtDxt1 then
          I := 8
        else
          I := 16;
        if SrcSize < PtrInt(BlocksW) * BlocksH * I then
          Exit;
        P := Src;
        for BY := 0 to BlocksH - 1 do
          for BX := 0 to BlocksW - 1 do
          begin
            if Format = FmtDxt5 then
            begin
              A[0] := P[0];
              A[1] := P[1];
              if A[0] > A[1] then
                for I := 1 to 6 do
                  A[I + 1] := ((7 - I) * A[0] + I * A[1]) div 7
              else
              begin
                for I := 1 to 4 do
                  A[I + 1] := ((5 - I) * A[0] + I * A[1]) div 5;
                A[6] := 0;
                A[7] := 255;
              end;
              Bits := 0;
              for I := 0 to 5 do
                Bits := Bits or (UInt64(P[2 + I]) shl (8 * I));
              Inc(P, 8);
            end;
            C0 := P[0] or (Word(P[1]) shl 8);
            C1 := P[2] or (Word(P[3]) shl 8);
            Color565(C0, C[0]);
            Color565(C1, C[1]);
            if (C0 > C1) or (Format = FmtDxt5) then
            begin
              for I := 0 to 2 do
              begin
                C[2][I] := (2 * C[0][I] + C[1][I]) div 3;
                C[3][I] := (C[0][I] + 2 * C[1][I]) div 3;
              end;
              C[2][3] := 255;
              C[3][3] := 255;
            end else
            begin
              for I := 0 to 2 do
              begin
                C[2][I] := (C[0][I] + C[1][I]) div 2;
                C[3][I] := 0;
              end;
              C[2][3] := 255;
              C[3][3] := 0;
            end;
            ColorBits := P[4] or (UInt32(P[5]) shl 8) or (UInt32(P[6]) shl 16) or (UInt32(P[7]) shl 24);
            Inc(P, 8);
            for J := 0 to 3 do
            begin
              Y := BY * 4 + J;
              if Y >= H then
                Break;
              for I := 0 to 3 do
              begin
                X := BX * 4 + I;
                if X >= W then
                  Break;
                Code := (ColorBits shr (2 * (J * 4 + I))) and 3;
                D := @Pixels[Y * W + X];
                D^ := C[Code];
                if Format = FmtDxt5 then
                  D^[3] := A[(Bits shr (3 * (J * 4 + I))) and 7];
              end;
            end;
          end;
      end;
    else
      Exit;
  end;
  Result := True;
end;

type
  TBimage = record
    Format, ColorFormat, W, H: Integer;
    Pixels: TRgbaArray;
  end;

function ClampByte(const C: Integer): Byte;
begin
  if C < 0 then
    Result := 0
  else
  if C > 255 then
    Result := 255
  else
    Result := C;
end;

{ The largest level of a side, with the color format undone. }
function ReadBimage(const Data: TStream; const Face: Integer; out Img: TBimage): Boolean;
const
  BimageMagic = $0A4D4942;
var
  R: TBfgReader;
  TextureType, NumLevels, NumImages, I, Level, DestZ, W, H, DataSize: Integer;
  Co, Cg, Y, Scale, V: Integer;
  NX, NY, NZ: Single;
  P: PRgba;
begin
  Result := False;
  Img.W := 0;
  Img.H := 0;
  R := TBfgReader.Create(Data, False);
  try
    R.BigInt64;
    if R.BigUInt <> BimageMagic then
      Exit;
    TextureType := R.BigInt;
    Img.Format := R.BigInt;
    Img.ColorFormat := R.BigInt;
    R.BigInt;
    R.BigInt;
    NumLevels := R.BigInt;
    NumImages := NumLevels;
    if TextureType = 2 then
      NumImages := NumImages * 6;
    for I := 0 to NumImages - 1 do
    begin
      Level := R.BigInt;
      DestZ := R.BigInt;
      W := R.BigInt;
      H := R.BigInt;
      DataSize := R.BigInt;
      if (DataSize < 0) or (R.Position + DataSize > R.Size) then
        Exit;
      if (Level = 0) and (DestZ = Face) then
      begin
        Img.W := W;
        Img.H := H;
        Result := DecodeLevel(R.Here, DataSize, Img.Format, W, H, Img.Pixels);
        Break;
      end;
      R.Skip(DataSize);
    end;
  finally
    R.Free;
  end;
  if not Result then
    Exit;
  case Img.ColorFormat of
    CfmNormalDxt5:
      { x in alpha, y in green }
      for I := 0 to High(Img.Pixels) do
      begin
        P := @Img.Pixels[I];
        NX := P^[3] * (2 / 255) - 1;
        NY := P^[1] * (2 / 255) - 1;
        NZ := 1 - NX * NX - NY * NY;
        if NZ > 0 then
          NZ := Sqrt(NZ)
        else
          NZ := 0;
        P^[0] := P^[3];
        P^[2] := ClampByte(Round((NZ + 1) * 127.5));
        P^[3] := 255;
      end;
    CfmYCoCgDxt5:
      { CoCg in red and green, their scale in blue, Y in alpha }
      for I := 0 to High(Img.Pixels) do
      begin
        P := @Img.Pixels[I];
        Scale := (P^[2] shr 3) + 1;
        Co := (P^[0] - 128) div Scale;
        Cg := (P^[1] - 128) div Scale;
        Y := P^[3];
        P^[0] := ClampByte(Y + Co - Cg);
        P^[1] := ClampByte(Y + Cg);
        P^[2] := ClampByte(Y - Co - Cg);
        P^[3] := 255;
      end;
    CfmGreenAlpha:
      for I := 0 to High(Img.Pixels) do
      begin
        P := @Img.Pixels[I];
        V := P^[1];
        P^[0] := 255;
        P^[1] := 255;
        P^[2] := 255;
        P^[3] := V;
      end;
  end;
end;

procedure Transpose(var Img: TBimage);
var
  X, Y: Integer;
  T: TRgba;
begin
  if Img.W <> Img.H then
    Exit;
  for Y := 0 to Img.H - 1 do
    for X := Y + 1 to Img.W - 1 do
    begin
      T := Img.Pixels[Y * Img.W + X];
      Img.Pixels[Y * Img.W + X] := Img.Pixels[X * Img.W + Y];
      Img.Pixels[X * Img.W + Y] := T;
    end;
end;

procedure FlipH(var Img: TBimage);
var
  X, Y: Integer;
  T: TRgba;
begin
  for Y := 0 to Img.H - 1 do
    for X := 0 to Img.W div 2 - 1 do
    begin
      T := Img.Pixels[Y * Img.W + X];
      Img.Pixels[Y * Img.W + X] := Img.Pixels[Y * Img.W + Img.W - 1 - X];
      Img.Pixels[Y * Img.W + Img.W - 1 - X] := T;
    end;
end;

procedure FlipV(var Img: TBimage);
var
  X, Y: Integer;
  T: TRgba;
begin
  for Y := 0 to Img.H div 2 - 1 do
    for X := 0 to Img.W - 1 do
    begin
      T := Img.Pixels[Y * Img.W + X];
      Img.Pixels[Y * Img.W + X] := Img.Pixels[(Img.H - 1 - Y) * Img.W + X];
      Img.Pixels[(Img.H - 1 - Y) * Img.W + X] := T;
    end;
end;

function BfgDecodeImage(const Data: TStream; const Face: Integer;
  const CameraCube: Boolean; const Coverage: TStream): TCastleImage;
var
  Img, Cov: TBimage;
  I, X, Y: Integer;
  HasAlpha: Boolean;
  Rgb: PVector3Byte;
  S: PRgba;
begin
  Result := nil;
  try
    if not ReadBimage(Data, Face, Img) then
      Exit;
    if CameraCube then
      { R_LoadCubeImages turned the camera sides into native ones: back }
      case Face of
        0, 4, 5: Transpose(Img);
        1:
          begin
            FlipV(Img);
            FlipH(Img);
            Transpose(Img);
          end;
        2: FlipV(Img);
        3: FlipH(Img);
      end;
    if (Coverage <> nil) and ReadBimage(Coverage, 0, Cov) and (Cov.W > 0) and (Cov.H > 0) then
      for Y := 0 to Img.H - 1 do
        for X := 0 to Img.W - 1 do
          Img.Pixels[Y * Img.W + X][3] :=
            Cov.Pixels[(Y * Cov.H div Img.H) * Cov.W + X * Cov.W div Img.W][3];
  except
    on E: Exception do
      Exit(nil);
  end;
  HasAlpha := False;
  for I := 0 to High(Img.Pixels) do
    if Img.Pixels[I][3] <> 255 then
    begin
      HasAlpha := True;
      Break;
    end;
  { CGE's rows go up }
  if HasAlpha then
  begin
    Result := TRGBAlphaImage.Create(Img.W, Img.H);
    for Y := 0 to Img.H - 1 do
      Move(Img.Pixels[Y * Img.W], Result.RowPtr(Img.H - 1 - Y)^, Img.W * 4);
  end else
  begin
    Result := TRGBImage.Create(Img.W, Img.H);
    for Y := 0 to Img.H - 1 do
    begin
      Rgb := PVector3Byte(Result.RowPtr(Img.H - 1 - Y));
      S := @Img.Pixels[Y * Img.W];
      for X := 0 to Img.W - 1 do
      begin
        Rgb^.X := S^[0];
        Rgb^.Y := S^[1];
        Rgb^.Z := S^[2];
        Inc(Rgb);
        Inc(S);
      end;
    end;
  end;
end;

{ Sounds --------------------------------------------------------------------- }

function BfgDecodeSound(const Data: TStream): TMemoryStream;
const
  FormatPcm = 1;
  FormatAdpcm = 2;
  Adaptation: array [0..15] of Integer = (230, 230, 230, 230, 307, 409, 512, 614,
    768, 614, 512, 409, 307, 230, 230, 230);
var
  R: TBfgReader;
  Tag, Channels, BlockSize, Bits, NumCoef: Integer;
  Rate: UInt32;
  Coef1, Coef2: array [0..6] of Integer;
  Samples: array of SmallInt;
  SampleCount: PtrInt;

  procedure Put(const V: Integer);
  begin
    if SampleCount >= Length(Samples) then
      SetLength(Samples, Length(Samples) * 2 + 65536);
    if V > 32767 then
      Samples[SampleCount] := 32767
    else
    if V < -32768 then
      Samples[SampleCount] := -32768
    else
      Samples[SampleCount] := V;
    Inc(SampleCount);
  end;

  { Microsoft ADPCM: blocks of a 7 byte header per channel (predictor,
    delta, the two samples before), then a nibble per sample }
  procedure DecodeAdpcm(const Src: PByte; const SrcSize: PtrInt; const WantSamples: PtrInt);
  var
    Offset, BlockLen, Start: PtrInt;
    P: PByte;
    Pred, Delta, S1, S2: array [0..1] of Integer;
    C, I, N, Nibble, V, Left: Integer;
  begin
    Offset := 0;
    Start := SampleCount;
    while (Offset < SrcSize) and (SampleCount - Start < WantSamples * Channels) do
    begin
      BlockLen := Min(BlockSize, SrcSize - Offset);
      if BlockLen < 7 * Channels then
        Break;
      P := Src + Offset;
      for C := 0 to Channels - 1 do
      begin
        Pred[C] := P^;
        if Pred[C] >= NumCoef then
          Pred[C] := 0;
        Inc(P);
      end;
      for C := 0 to Channels - 1 do
      begin
        Delta[C] := SmallInt(P[0] or (Word(P[1]) shl 8));
        Inc(P, 2);
      end;
      for C := 0 to Channels - 1 do
      begin
        S1[C] := SmallInt(P[0] or (Word(P[1]) shl 8));
        Inc(P, 2);
      end;
      for C := 0 to Channels - 1 do
      begin
        S2[C] := SmallInt(P[0] or (Word(P[1]) shl 8));
        Inc(P, 2);
      end;
      for C := 0 to Channels - 1 do
        Put(S2[C]);
      for C := 0 to Channels - 1 do
        Put(S1[C]);
      Left := (BlockLen - 7 * Channels) * 2;
      C := 0;
      for I := 0 to Left - 1 do
      begin
        if (I and 1) = 0 then
          Nibble := P^ shr 4
        else
        begin
          Nibble := P^ and 15;
          Inc(P);
        end;
        N := Nibble;
        if N >= 8 then
          N := N - 16;
        V := SarLongint(S1[C] * Coef1[Pred[C]] + S2[C] * Coef2[Pred[C]], 8) + N * Delta[C];
        if V > 32767 then
          V := 32767
        else
        if V < -32768 then
          V := -32768;
        Put(V);
        S2[C] := S1[C];
        S1[C] := V;
        Delta[C] := (Adaptation[Nibble] * Delta[C]) div 256;
        if Delta[C] < 16 then
          Delta[C] := 16;
        C := (C + 1) mod Channels;
      end;
      Inc(Offset, BlockLen);
    end;
    { the last block is padded }
    if SampleCount - Start > WantSamples * Channels then
      SampleCount := Start + WantSamples * Channels;
  end;

  procedure W32(const S: TStream; const V: UInt32);
  begin
    S.WriteBuffer(V, 4);
  end;

  procedure W16(const S: TStream; const V: Word);
  begin
    S.WriteBuffer(V, 2);
  end;

const
  Riff: array [0..3] of AnsiChar = 'RIFF';
  WaveFmt: array [0..7] of AnsiChar = 'WAVEfmt ';
  DataTag: array [0..3] of AnsiChar = 'data';
var
  I, J, NumBuffers, NumSamples, BufferSize, ExtraSize: Integer;
  DataBytes: UInt32;
begin
  Result := nil;
  SampleCount := 0;
  NumCoef := 0;
  R := TBfgReader.Create(Data, False);
  try
    try
      R.BigUInt; { magic }
      R.BigInt64; { time stamp }
      R.Bool; { loaded }
      R.BigInt; { playBegin }
      R.BigInt; { playLength }
      Tag := R.LittleWord;
      Channels := R.LittleWord;
      Rate := UInt32(R.LittleInt);
      R.LittleInt; { avgBytesPerSec }
      BlockSize := R.LittleWord;
      Bits := R.LittleWord;
      if Tag = FormatAdpcm then
      begin
        ExtraSize := R.LittleWord;
        if ExtraSize <> 32 then
          Exit;
        R.LittleWord; { samplesPerBlock }
        NumCoef := R.LittleWord;
        for I := 0 to 6 do
        begin
          Coef1[I] := SmallInt(R.LittleWord);
          Coef2[I] := SmallInt(R.LittleWord);
        end;
        if NumCoef > 7 then
          NumCoef := 7;
      end else
      if (Tag = $FFFE) or (Tag = $FFFF) then
      begin
        { extensible: PCM }
        ExtraSize := R.LittleWord;
        R.Skip(ExtraSize);
        Tag := FormatPcm;
      end else
      if Tag <> FormatPcm then
        Exit;
      if (Channels < 1) or (Channels > 2) or (BlockSize <= 0) then
        Exit;
      if (Tag = FormatPcm) and (Bits <> 16) and (Bits <> 8) then
        Exit;
      R.Skip(R.BigInt); { amplitude }
      R.BigInt; { totalBufferSize }
      NumBuffers := R.BigInt;
      for I := 0 to NumBuffers - 1 do
      begin
        NumSamples := R.BigInt;
        BufferSize := R.BigInt;
        if (BufferSize < 0) or (R.Position + BufferSize > R.Size) then
          Exit;
        if Tag = FormatAdpcm then
          DecodeAdpcm(R.Here, BufferSize, NumSamples)
        else
        if Bits = 16 then
          for J := 0 to BufferSize div 2 - 1 do
            Put(SmallInt(R.Here[J * 2] or (Word(R.Here[J * 2 + 1]) shl 8)))
        else
          for J := 0 to BufferSize - 1 do
            Put((Integer(R.Here[J]) - 128) * 256);
        R.Skip(BufferSize);
      end;
    except
      on E: Exception do
        Exit;
    end;
  finally
    R.Free;
  end;
  { an empty sound (the data has some): a moment of silence }
  if SampleCount = 0 then
    Put(0);
  DataBytes := SampleCount * 2;
  Result := TMemoryStream.Create;
  Result.WriteBuffer(Riff, 4);
  W32(Result, 36 + DataBytes);
  Result.WriteBuffer(WaveFmt, 8);
  W32(Result, 16);
  W16(Result, 1);
  W16(Result, Channels);
  W32(Result, Rate);
  W32(Result, Rate * UInt32(Channels) * 2);
  W16(Result, Channels * 2);
  W16(Result, 16);
  Result.WriteBuffer(DataTag, 4);
  W32(Result, DataBytes);
  Result.WriteBuffer(Samples[0], DataBytes);
  Result.Position := 0;
end;

end.
