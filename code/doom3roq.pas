{
  Copyright 2026 Castle Doom 3 contributors.

  This file is part of Castle Doom 3, licensed under the GNU GPL v2 or later.
}

{ Doom 3's RoQ videos (idCinematic: "videomap" material stages, the PDA's
  videos, the in-world screens): vector quantized 4:4:4 YUV frames.

  A file is a list of chunks (id, size, argument). The codebook chunk has
  2x2 cells (4 luma values and one U, V) and 4x4 cells (4 indexes of 2x2
  cells). The frame chunk covers the image in 16x16 macroblocks of four 8x8
  blocks, each coded by 2 bits: unchanged, copied from the previous frame
  by a motion vector, a 4x4 cell scaled up, or split into four 4x4 blocks
  coded the same way (down to four 2x2 cells). Two frame buffers swap, so
  "unchanged" keeps the frame before the previous one, like the encoder
  expects (the same as idCinematic and FFmpeg's decoder). }
unit Doom3Roq;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils,
  CastleImages;

type
  TD3RoqVideo = class
  strict private
    type
      TCell2 = record
        Y: array [0..3] of Byte;
        U, V: Byte;
      end;
      TCell4 = array [0..3] of Byte;
    var
      FData: TBytes;
      FPos, FFirstFrame: Integer;
      FWidth, FHeight: Integer;
      FFps: Integer;
      FFrameCount: Integer;
      FFrame: Integer;
      { YUV planes: [0] current, [1] the previous frame }
      FY, FU, FV: array [0..1] of TBytes;
      FCells2: array [0..255] of TCell2;
      FCells4: array [0..255] of TCell4;
      FImage: TRGBAlphaImage;
      FImageFrame: Integer;
      FFlags: Word;
      FFlagPos: Integer;
      FChunkArg: Word;
    function ReadWord(const At: Integer): Word;
    function ReadDWord(const At: Integer): Cardinal;
    function NextByte: Byte;
    function NextCode: Integer;
    procedure ReadCodebook(const At, Size: Integer; const Arg: Word);
    procedure DecodeFrame(const At, Size: Integer);
    procedure Motion(const X, Y, Size, DX, DY: Integer);
    procedure Cell2(const X, Y: Integer; const C: TCell2; const Scale: Integer);
    procedure Block4(const X, Y: Integer; const Scale: Integer; const C4: Integer);
    procedure Rewind;
    procedure UpdateImage;
  public
    destructor Destroy; override;
    { Load from a stream / the d3fs file system. False when it isn't a
      RoQ (or has no frames). }
    function LoadFromStream(const S: TStream): Boolean;
    function LoadFromVfs(const Path: String): Boolean;
    { Decode the next frame (from the first after the last); False when
      there is none. }
    function NextFrame: Boolean;
    { The frame at Seconds since the start (looping): decodes forward,
      from the start when going back. }
    procedure SeekTime(const Seconds: Single; const Loop: Boolean = True);
    { Seconds of the whole video. }
    function Duration: Single;
    { The current frame as an image (owned by the video, y up like CGE
      images). }
    function Image: TRGBAlphaImage;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
    property Fps: Integer read FFps;
    property FrameCount: Integer read FFrameCount;
    { 0-based index of the decoded frame (-1 before the first) }
    property Frame: Integer read FFrame;
  end;

var
  { The clock videos play by (seconds; the map's time). }
  RoqClock: Double;

{ The video of a RoQ file, decoded once and shared (nil when it can't be
  loaded). Freed by RoqClearCache. }
function RoqVideo(const FileName: String): TD3RoqVideo;
{ idMaterial::ResetCinematicTime: the video starts again now. }
procedure RoqResetTime(const FileName: String);
{ Seconds into the video by RoqClock (videos never reset play from 0). }
function RoqTime(const FileName: String): Single;
procedure RoqClearCache;

implementation

uses
  Math, Generics.Collections,
  CastleVectors, CastleLog,
  Doom3Files;

type
  TRoqVideos = specialize TObjectDictionary<String, TD3RoqVideo>;
  TRoqStarts = specialize TDictionary<String, Double>;

var
  Videos: TRoqVideos;
  Starts: TRoqStarts;

function RoqVideo(const FileName: String): TD3RoqVideo;
var
  Key: String;
begin
  Key := LowerCase(FileName);
  if Videos = nil then
    Videos := TRoqVideos.Create([doOwnsValues]);
  if Videos.TryGetValue(Key, Result) then
    Exit;
  Result := TD3RoqVideo.Create;
  if Result.LoadFromVfs(Key) then
    WritelnLog('Doom3Roq', 'Video "%s": %d x %d, %d frames at %d fps',
      [Key, Result.Width, Result.Height, Result.FrameCount, Result.Fps])
  else
  begin
    WritelnWarning('Doom3Roq', 'Cannot load video "%s"', [Key]);
    FreeAndNil(Result);
  end;
  Videos.Add(Key, Result);
end;

procedure RoqResetTime(const FileName: String);
begin
  if Starts = nil then
    Starts := TRoqStarts.Create;
  Starts.AddOrSetValue(LowerCase(FileName), RoqClock);
end;

function RoqTime(const FileName: String): Single;
var
  Start: Double;
begin
  Start := 0;
  if Starts <> nil then
    Starts.TryGetValue(LowerCase(FileName), Start);
  Result := Max(0, RoqClock - Start);
end;

procedure RoqClearCache;
begin
  FreeAndNil(Videos);
  FreeAndNil(Starts);
end;

const
  RoqSignature = $1084;
  RoqInfo = $1001;
  RoqCodebook = $1002;
  RoqVq = $1011;

destructor TD3RoqVideo.Destroy;
begin
  FreeAndNil(FImage);
  inherited Destroy;
end;

function TD3RoqVideo.ReadWord(const At: Integer): Word;
begin
  Result := FData[At] or (Word(FData[At + 1]) shl 8);
end;

function TD3RoqVideo.ReadDWord(const At: Integer): Cardinal;
begin
  Result := ReadWord(At) or (Cardinal(ReadWord(At + 2)) shl 16);
end;

function TD3RoqVideo.NextByte: Byte;
begin
  if FPos < Length(FData) then
  begin
    Result := FData[FPos];
    Inc(FPos);
  end else
    Result := 0;
end;

function TD3RoqVideo.NextCode: Integer;
begin
  { 2 bit codes from 16 bit words, the highest first }
  if FFlagPos < 0 then
  begin
    if FPos + 1 < Length(FData) then
      FFlags := ReadWord(FPos)
    else
      FFlags := 0;
    Inc(FPos, 2);
    FFlagPos := 7;
  end;
  Result := (FFlags shr (FFlagPos * 2)) and 3;
  Dec(FFlagPos);
end;

function TD3RoqVideo.LoadFromStream(const S: TStream): Boolean;
var
  At, Size: Integer;
  Id: Word;
begin
  Result := False;
  SetLength(FData, S.Size - S.Position);
  if Length(FData) > 0 then
    S.ReadBuffer(FData[0], Length(FData));
  if (Length(FData) < 8) or (ReadWord(0) <> RoqSignature) then
    Exit;
  FFps := ReadWord(6);
  if FFps <= 0 then
    FFps := 30;
  FWidth := 0;
  FHeight := 0;
  FFrameCount := 0;
  FFirstFrame := -1;
  { the size and the frames }
  At := 8;
  while At + 8 <= Length(FData) do
  begin
    Id := ReadWord(At);
    Size := Integer(ReadDWord(At + 2));
    if (Size < 0) or (At + 8 + Size > Length(FData)) then
      Break;
    if (Id = RoqInfo) and (Size >= 4) and (FWidth = 0) then
    begin
      FWidth := ReadWord(At + 8);
      FHeight := ReadWord(At + 10);
    end else
    if (Id = RoqCodebook) and (FFirstFrame < 0) then
      FFirstFrame := At
    else
    if Id = RoqVq then
    begin
      if FFirstFrame < 0 then
        FFirstFrame := At;
      Inc(FFrameCount);
    end;
    At := At + 8 + Size;
  end;
  if (FWidth <= 0) or (FHeight <= 0) or (FFrameCount = 0) or
     (FWidth mod 16 <> 0) or (FHeight mod 16 <> 0) then
    Exit;
  Rewind;
  Result := True;
end;

function TD3RoqVideo.LoadFromVfs(const Path: String): Boolean;
var
  S: TStream;
begin
  Result := False;
  if not D3Fs.FileExists(Path) then
    Exit;
  S := D3Fs.OpenFile(Path);
  try
    Result := LoadFromStream(S);
  finally
    S.Free;
  end;
end;

procedure TD3RoqVideo.Rewind;
var
  I: Integer;
begin
  for I := 0 to 1 do
  begin
    SetLength(FY[I], FWidth * FHeight);
    SetLength(FU[I], FWidth * FHeight);
    SetLength(FV[I], FWidth * FHeight);
    FillChar(FY[I][0], Length(FY[I]), 0);
    FillChar(FU[I][0], Length(FU[I]), 128);
    FillChar(FV[I][0], Length(FV[I]), 128);
  end;
  FPos := FFirstFrame;
  FFrame := -1;
  FImageFrame := -2;
end;

procedure TD3RoqVideo.ReadCodebook(const At, Size: Integer; const Arg: Word);
var
  N2, N4, I, J, P: Integer;
begin
  N2 := Arg shr 8;
  if N2 = 0 then
    N2 := 256;
  N4 := Arg and $FF;
  if (N4 = 0) and (N2 * 6 < Size) then
    N4 := 256;
  P := At;
  for I := 0 to N2 - 1 do
  begin
    if P + 6 > Length(FData) then
      Exit;
    for J := 0 to 3 do
      FCells2[I].Y[J] := FData[P + J];
    FCells2[I].U := FData[P + 4];
    FCells2[I].V := FData[P + 5];
    Inc(P, 6);
  end;
  for I := 0 to N4 - 1 do
  begin
    if P + 4 > Length(FData) then
      Exit;
    for J := 0 to 3 do
      FCells4[I][J] := FData[P + J];
    Inc(P, 4);
  end;
end;

procedure TD3RoqVideo.Motion(const X, Y, Size, DX, DY: Integer);
var
  SX, SY, I, J, Src, Dst: Integer;
begin
  { a block of the previous frame, moved }
  SX := X + DX;
  SY := Y + DY;
  if (SX < 0) or (SY < 0) or (SX + Size > FWidth) or (SY + Size > FHeight) then
    Exit;
  for J := 0 to Size - 1 do
    for I := 0 to Size - 1 do
    begin
      Src := (SY + J) * FWidth + SX + I;
      Dst := (Y + J) * FWidth + X + I;
      FY[0][Dst] := FY[1][Src];
      FU[0][Dst] := FU[1][Src];
      FV[0][Dst] := FV[1][Src];
    end;
end;

procedure TD3RoqVideo.Cell2(const X, Y: Integer; const C: TCell2; const Scale: Integer);
var
  I, J, P, Q: Integer;
begin
  { a 2x2 cell, each pixel Scale x Scale }
  for J := 0 to 2 * Scale - 1 do
    for I := 0 to 2 * Scale - 1 do
    begin
      if (X + I >= FWidth) or (Y + J >= FHeight) then
        Continue;
      P := (Y + J) * FWidth + X + I;
      Q := (J div Scale) * 2 + (I div Scale);
      FY[0][P] := C.Y[Q];
      FU[0][P] := C.U;
      FV[0][P] := C.V;
    end;
end;

procedure TD3RoqVideo.Block4(const X, Y: Integer; const Scale: Integer; const C4: Integer);
var
  S: Integer;
begin
  { a 4x4 cell: four 2x2 cells (at Scale 2: an 8x8 block) }
  S := 2 * Scale;
  Cell2(X, Y, FCells2[FCells4[C4][0]], Scale);
  Cell2(X + S, Y, FCells2[FCells4[C4][1]], Scale);
  Cell2(X, Y + S, FCells2[FCells4[C4][2]], Scale);
  Cell2(X + S, Y + S, FCells2[FCells4[C4][3]], Scale);
end;

procedure TD3RoqVideo.DecodeFrame(const At, Size: Integer);
var
  XPos, YPos, XP, YP, K, X, Y, B: Integer;
  MeanX, MeanY: Integer;
begin
  FPos := At;
  FFlagPos := -1;
  MeanX := ShortInt(FChunkArg shr 8);
  MeanY := ShortInt(FChunkArg and $FF);
  XPos := 0;
  YPos := 0;
  while (FPos < At + Size) and (YPos < FHeight) do
  begin
    YP := YPos;
    while YP < YPos + 16 do
    begin
      XP := XPos;
      while XP < XPos + 16 do
      begin
        case NextCode of
          0: ;
          1:
            begin
              B := NextByte;
              Motion(XP, YP, 8, 8 - (B shr 4) - MeanX, 8 - (B and 15) - MeanY);
            end;
          2: Block4(XP, YP, 2, NextByte);
          3:
            for K := 0 to 3 do
            begin
              X := XP + 4 * (K and 1);
              Y := YP + 4 * (K shr 1);
              case NextCode of
                0: ;
                1:
                  begin
                    B := NextByte;
                    Motion(X, Y, 4, 8 - (B shr 4) - MeanX, 8 - (B and 15) - MeanY);
                  end;
                2: Block4(X, Y, 1, NextByte);
                3:
                  begin
                    Cell2(X, Y, FCells2[NextByte], 1);
                    Cell2(X + 2, Y, FCells2[NextByte], 1);
                    Cell2(X, Y + 2, FCells2[NextByte], 1);
                    Cell2(X + 2, Y + 2, FCells2[NextByte], 1);
                  end;
              end;
            end;
        end;
        Inc(XP, 8);
      end;
      Inc(YP, 8);
    end;
    Inc(XPos, 16);
    if XPos >= FWidth then
    begin
      XPos := 0;
      Inc(YPos, 16);
    end;
  end;
end;

function TD3RoqVideo.NextFrame: Boolean;
var
  Id, Arg: Word;
  Size, At: Integer;
  T: TBytes;
begin
  Result := False;
  if FFirstFrame < 0 then
    Exit;
  At := FPos;
  if FFrame < 0 then
    At := FFirstFrame;
  while At + 8 <= Length(FData) do
  begin
    Id := ReadWord(At);
    Size := Integer(ReadDWord(At + 2));
    Arg := ReadWord(At + 6);
    if (Size < 0) or (At + 8 + Size > Length(FData)) then
      Exit;
    if Id = RoqCodebook then
      ReadCodebook(At + 8, Size, Arg)
    else
    if Id = RoqVq then
    begin
      { the buffers swap: the new frame starts from the one before the
        previous ("unchanged" blocks keep it), motion copies the previous }
      T := FY[0]; FY[0] := FY[1]; FY[1] := T;
      T := FU[0]; FU[0] := FU[1]; FU[1] := T;
      T := FV[0]; FV[0] := FV[1]; FV[1] := T;
      if FFrame = 0 then
      begin
        { the second frame: both buffers start as the first }
        FY[0] := Copy(FY[1]);
        FU[0] := Copy(FU[1]);
        FV[0] := Copy(FV[1]);
      end;
      FChunkArg := Arg;
      DecodeFrame(At + 8, Size);
      FPos := At + 8 + Size;
      Inc(FFrame);
      Exit(True);
    end;
    At := At + 8 + Size;
    FPos := At;
  end;
end;

procedure TD3RoqVideo.SeekTime(const Seconds: Single; const Loop: Boolean);
var
  Target: Integer;
begin
  if FFrameCount = 0 then
    Exit;
  Target := Max(0, Floor(Seconds * FFps));
  if Loop then
    Target := Target mod FFrameCount
  else
    Target := Min(Target, FFrameCount - 1);
  if Target < FFrame then
    Rewind;
  while FFrame < Target do
    if not NextFrame then
      Break;
end;

function TD3RoqVideo.Duration: Single;
begin
  Result := FFrameCount / FFps;
end;

procedure TD3RoqVideo.UpdateImage;
var
  X, Y, P, C, D, E, R, G, B: Integer;
  Px: PVector4Byte;
begin
  if FImage = nil then
    FImage := TRGBAlphaImage.Create(FWidth, FHeight);
  for Y := 0 to FHeight - 1 do
  begin
    { CGE images are bottom to top }
    Px := FImage.PixelPtr(0, FHeight - 1 - Y);
    for X := 0 to FWidth - 1 do
    begin
      P := Y * FWidth + X;
      C := FY[0][P];
      D := FU[0][P] - 128;
      E := FV[0][P] - 128;
      { BT.601, full range }
      R := C + (91881 * E) div 65536;
      G := C - (22554 * D + 46802 * E) div 65536;
      B := C + (116130 * D) div 65536;
      Px^.X := EnsureRange(R, 0, 255);
      Px^.Y := EnsureRange(G, 0, 255);
      Px^.Z := EnsureRange(B, 0, 255);
      Px^.W := 255;
      Inc(Px);
    end;
  end;
  FImageFrame := FFrame;
end;

function TD3RoqVideo.Image: TRGBAlphaImage;
begin
  if FFrame < 0 then
    NextFrame;
  if FImageFrame <> FFrame then
    UpdateImage;
  Result := FImage;
end;

finalization
  RoqClearCache;
end.
