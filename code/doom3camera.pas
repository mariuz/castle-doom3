{ Doom 3 camera animations (.md5camera), played by idCameraAnim entities
  in cinematics.

  The file has a frame rate, frames (origin, orientation quaternion x y z,
  horizontal field of view in degrees) and "cuts": frame numbers where the
  camera jumps to a new shot. Like idCameraAnim::GetViewParms, playback
  skips one frame at each cut (the last frame of the old shot and the first
  of the new one are at the same time) and interpolates between frames
  (positions and fov linearly, orientations along the shortest arc). }
unit Doom3Camera;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, CastleVectors, CastleQuaternions;

type
  TD3CameraFrame = record
    Origin: TVector3;
    { Orientation as stored (x y z of a unit quaternion, Doom 3's md5
      convention: w = -sqrt(1 - x2 - y2 - z2)). }
    Orient: TVector3;
    Fov: Single;
  end;

  TD3CameraAnim = class
  public
    FrameRate: Single;
    Frames: array of TD3CameraFrame;
    { Frame numbers where a new shot starts. }
    Cuts: array of Integer;
    { Parse the text of a .md5camera file. False if it's not one. }
    function Parse(const Text: String): Boolean;
    function LoadFromVfs(const APath: String): Boolean;
    { Playing time in seconds (the frames at the cuts don't count). }
    function Duration: Single;
    { The view after Time seconds (clamped to the last frame), in Doom 3
      coordinates: Forward and Up are the view's axes. }
    procedure Sample(const Time: Single; out Origin, Forward, Up: TVector3; out Fov: Single);
  end;

{ Doom 3's file name for a camera anim: "x.camera" in decls is "x.md5camera"
  on disk (idCameraAnim sets the extension). }
function D3CameraAnimPath(const DeclPath: String): String;

implementation

uses
  Math,
  Doom3Files, Doom3Lexer, Doom3Md5;

function D3CameraAnimPath(const DeclPath: String): String;
begin
  Result := ChangeFileExt(DeclPath, '.md5camera');
end;

function TD3CameraAnim.Parse(const Text: String): Boolean;
var
  Lex: TDoom3Lexer;
  Token: String;
  NumFrames, NumCuts, I: Integer;
begin
  Result := False;
  Frames := nil;
  Cuts := nil;
  FrameRate := 24;
  NumFrames := 0;
  NumCuts := 0;
  Lex := TDoom3Lexer.Create(Text);
  try
    if not Lex.Check('MD5Version') then
      Exit;
    Lex.NextStr; // version
    while Lex.Next(Token) do
    begin
      if Token = 'commandline' then
        Lex.NextStr
      else
      if Token = 'numFrames' then
        NumFrames := Lex.ReadInt
      else
      if Token = 'frameRate' then
        FrameRate := Lex.ReadFloat
      else
      if Token = 'numCuts' then
        NumCuts := Lex.ReadInt
      else
      if Token = 'cuts' then
      begin
        Lex.Expect('{');
        SetLength(Cuts, NumCuts);
        for I := 0 to NumCuts - 1 do
          Cuts[I] := Lex.ReadInt;
        Lex.Expect('}');
      end else
      if Token = 'camera' then
      begin
        Lex.Expect('{');
        SetLength(Frames, NumFrames);
        for I := 0 to NumFrames - 1 do
        begin
          { ReadVector reads the parentheses too }
          Lex.ReadVector(@Frames[I].Origin.Data[0], 3);
          Lex.ReadVector(@Frames[I].Orient.Data[0], 3);
          Frames[I].Fov := Lex.ReadFloat;
        end;
        Lex.Expect('}');
      end;
    end;
  finally
    Lex.Free;
  end;
  if FrameRate <= 0 then
    FrameRate := 24;
  Result := Length(Frames) > 0;
end;

function TD3CameraAnim.LoadFromVfs(const APath: String): Boolean;
begin
  Result := D3Fs.FileExists(APath) and Parse(D3Fs.ReadText(APath));
end;

function TD3CameraAnim.Duration: Single;
begin
  Result := Max(0, Length(Frames) - 1 - Length(Cuts)) / FrameRate;
end;

procedure TD3CameraAnim.Sample(const Time: Single; out Origin, Forward, Up: TVector3; out Fov: Single);
var
  FrameTime, Lerp: Single;
  Frame, Next, I: Integer;
  Q: TQuaternion;
begin
  FrameTime := Max(0, Time) * FrameRate;
  Frame := Trunc(FrameTime);
  Lerp := FrameTime - Frame;
  { skip one frame at each cut }
  for I := 0 to High(Cuts) do
  begin
    if Frame < Cuts[I] then
      Break;
    Inc(Frame);
  end;
  if Frame >= High(Frames) then
  begin
    Frame := High(Frames);
    Lerp := 0;
  end;
  Next := Min(Frame + 1, High(Frames));
  { don't blend into the next shot }
  for I := 0 to High(Cuts) do
    if Next = Cuts[I] then
      Lerp := 0;
  Origin := Frames[Frame].Origin + (Frames[Next].Origin - Frames[Frame].Origin) * Lerp;
  Fov := Frames[Frame].Fov + (Frames[Next].Fov - Frames[Frame].Fov) * Lerp;
  Q := QuatNlerp(QuatFromXYZ(Frames[Frame].Orient), QuatFromXYZ(Frames[Next].Orient), Lerp);
  { the quaternion turns the camera's local axes (forward = +X, up = +Z)
    like md5 joints turn their vertexes }
  Forward := QuatRotate(Q, Vector3(1, 0, 0));
  Up := QuatRotate(Q, Vector3(0, 0, 1));
end;

end.
