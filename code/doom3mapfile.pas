{ Doom 3 .map files ("Version 2"): only the entities' key / value pairs are
  read. Brushes and patches are skipped, their render geometry comes from
  the .proc file. Also coordinate helpers shared by the port. }
unit Doom3MapFile;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleVectors;

type
  TD3MapEntity = class
  strict private
    FPairs: TStringList;
  public
    { Has brushes or patches (a brush entity, its geometry is a .proc model
      named like the entity). }
    PrimitiveCount: Integer;
    constructor Create;
    destructor Destroy; override;
    procedure SetValue(const Key, Value: String);
    function Value(const Key: String; const Default: String = ''): String;
    function HasKey(const Key: String): Boolean;
    function FloatValue(const Key: String; const Default: Single = 0): Single;
    function IntValue(const Key: String; const Default: Integer = 0): Integer;
    function BoolValue(const Key: String; const Default: Boolean = False): Boolean;
    function VectorValue(const Key: String; const Default: TVector3): TVector3;
    { "x y z w" }
    function Vector4Value(const Key: String; const Default: TVector4): TVector4;
    function ClassName_: String;
    function Name: String;
    { "origin" in Doom 3 coordinates }
    function Origin: TVector3;
    { "angle" in degrees (yaw), or derived from "rotation" }
    function Angle: Single;
    { "rotation" 3x3 matrix (rows), identity / from "angle" when missing.
      Doom 3 coordinates. }
    function Rotation: TMatrix3;
    property Pairs: TStringList read FPairs;
  end;

  TD3MapEntityList = specialize TObjectList<TD3MapEntity>;

  TD3MapFile = class
  public
    Entities: TD3MapEntityList;
    constructor Create;
    destructor Destroy; override;
    function LoadFromText(const Text: String): Boolean;
    function LoadFromVfs(const Path: String): Boolean;
    function FindByName(const Name: String): TD3MapEntity;
    function WorldSpawn: TD3MapEntity;
  end;

{ Doom 3 (X forward, Y left, Z up) -> CGE (Y up): X = X, Y = Z, Z = -Y. }
function D3ToCge(const V: TVector3): TVector3; inline;
function CgeToD3(const V: TVector3): TVector3; inline;
{ Parse "x y z". }
function ParseVector3(const S: String; const Default: TVector3): TVector3;
{ Direction of a Doom 3 yaw (degrees, 0 = +X, 90 = +Y) in CGE coordinates. }
function YawToCgeDir(const YawDeg: Single): TVector3;
{ Doom 3 rotation matrix (idMat3, rows = axes) of a yaw in degrees. }
function YawMatrix(const YawDeg: Single): TMatrix3;
{ idAngles::ToMat3: Angles are pitch, yaw, roll in degrees; the rows of the
  result are the rotated axes (forward, left, up). }
function AnglesMatrix(const Angles: TVector3): TMatrix3;
{ idMat3::ToAngles }
function MatrixAngles(const M: TMatrix3): TVector3;

implementation

uses
  Math,
  CastleLog,
  Doom3Lexer, Doom3Files;

function D3ToCge(const V: TVector3): TVector3;
begin
  Result := Vector3(V.X, V.Z, -V.Y);
end;

function CgeToD3(const V: TVector3): TVector3;
begin
  Result := Vector3(V.X, -V.Z, V.Y);
end;

function ParseVector3(const S: String; const Default: TVector3): TVector3;
var
  Parts: TStringArray;
  I, N: Integer;
begin
  Result := Default;
  Parts := Trim(S).Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
  if Length(Parts) < 3 then
    Exit;
  N := 0;
  for I := 0 to 2 do
  begin
    Result.Data[I] := D3StrToFloat(Parts[I], Default.Data[I]);
    Inc(N);
  end;
end;

function YawToCgeDir(const YawDeg: Single): TVector3;
var
  A: Single;
begin
  A := DegToRad(YawDeg);
  Result := D3ToCge(Vector3(Cos(A), Sin(A), 0));
end;

function YawMatrix(const YawDeg: Single): TMatrix3;
var
  C, S: Single;
begin
  C := Cos(DegToRad(YawDeg));
  S := Sin(DegToRad(YawDeg));
  Result := TMatrix3.Identity;
  Result.Data[0, 0] := C; Result.Data[0, 1] := S;
  Result.Data[1, 0] := -S; Result.Data[1, 1] := C;
end;

function AnglesMatrix(const Angles: TVector3): TMatrix3;
var
  SP, CP, SY, CY, SR, CR: Single;
begin
  SinCos(DegToRad(Angles.X), SP, CP);
  SinCos(DegToRad(Angles.Y), SY, CY);
  SinCos(DegToRad(Angles.Z), SR, CR);
  Result.Data[0, 0] := CP * CY;
  Result.Data[0, 1] := CP * SY;
  Result.Data[0, 2] := -SP;
  Result.Data[1, 0] := SR * SP * CY + CR * -SY;
  Result.Data[1, 1] := SR * SP * SY + CR * CY;
  Result.Data[1, 2] := SR * CP;
  Result.Data[2, 0] := CR * SP * CY + -SR * -SY;
  Result.Data[2, 1] := CR * SP * SY + -SR * CY;
  Result.Data[2, 2] := CR * CP;
end;

function MatrixAngles(const M: TMatrix3): TVector3;
var
  SP, Theta: Single;
begin
  SP := EnsureRange(M.Data[0, 2], -1, 1);
  Theta := -ArcSin(SP);
  Result.X := RadToDeg(Theta);
  if Cos(Theta) > 8192 * 1.192092896e-07 then
  begin
    Result.Y := RadToDeg(ArcTan2(M.Data[0, 1], M.Data[0, 0]));
    Result.Z := RadToDeg(ArcTan2(M.Data[1, 2], M.Data[2, 2]));
  end else
  begin
    Result.Y := RadToDeg(-ArcTan2(M.Data[1, 0], M.Data[1, 1]));
    Result.Z := 0;
  end;
end;

{ TD3MapEntity }

constructor TD3MapEntity.Create;
begin
  inherited Create;
  FPairs := TStringList.Create;
  FPairs.CaseSensitive := False;
end;

destructor TD3MapEntity.Destroy;
begin
  FPairs.Free;
  inherited Destroy;
end;

procedure TD3MapEntity.SetValue(const Key, Value: String);
begin
  FPairs.Values[LowerCase(Key)] := Value;
end;

function TD3MapEntity.Value(const Key: String; const Default: String): String;
var
  I: Integer;
begin
  I := FPairs.IndexOfName(LowerCase(Key));
  if I >= 0 then
    Result := FPairs.ValueFromIndex[I]
  else
    Result := Default;
end;

function TD3MapEntity.HasKey(const Key: String): Boolean;
begin
  Result := FPairs.IndexOfName(LowerCase(Key)) >= 0;
end;

function TD3MapEntity.FloatValue(const Key: String; const Default: Single): Single;
begin
  Result := D3StrToFloat(Value(Key), Default);
end;

function TD3MapEntity.IntValue(const Key: String; const Default: Integer): Integer;
begin
  Result := Round(FloatValue(Key, Default));
end;

function TD3MapEntity.BoolValue(const Key: String; const Default: Boolean): Boolean;
begin
  if HasKey(Key) then
    Result := FloatValue(Key, 0) <> 0
  else
    Result := Default;
end;

function TD3MapEntity.VectorValue(const Key: String; const Default: TVector3): TVector3;
begin
  Result := ParseVector3(Value(Key), Default);
end;

function TD3MapEntity.Vector4Value(const Key: String; const Default: TVector4): TVector4;
var
  Parts: TStringArray;
  I: Integer;
begin
  Result := Default;
  Parts := Trim(Value(Key)).Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
  for I := 0 to Min(3, High(Parts)) do
    Result.Data[I] := D3StrToFloat(Parts[I], Default.Data[I]);
end;

function TD3MapEntity.ClassName_: String;
begin
  Result := Value('classname');
end;

function TD3MapEntity.Name: String;
begin
  Result := Value('name');
end;

function TD3MapEntity.Origin: TVector3;
begin
  Result := VectorValue('origin', TVector3.Zero);
end;

function TD3MapEntity.Rotation: TMatrix3;
var
  Parts: TStringArray;
  I: Integer;
begin
  Result := TMatrix3.Identity;
  Parts := Trim(Value('rotation')).Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
  if Length(Parts) >= 9 then
  begin
    { Doom 3 writes the matrix row by row; idMat3 rows are the axes }
    for I := 0 to 8 do
      Result.Data[I div 3, I mod 3] := D3StrToFloat(Parts[I]);
  end else
  if HasKey('angle') then
    Result := YawMatrix(FloatValue('angle'));
end;

function TD3MapEntity.Angle: Single;
var
  M: TMatrix3;
begin
  if HasKey('angle') or not HasKey('rotation') then
    Exit(FloatValue('angle'));
  M := Rotation;
  { first axis (forward) projected on XY }
  Result := RadToDeg(ArcTan2(M.Data[0, 1], M.Data[0, 0]));
end;

{ TD3MapFile }

constructor TD3MapFile.Create;
begin
  inherited Create;
  Entities := TD3MapEntityList.Create(True);
end;

destructor TD3MapFile.Destroy;
begin
  Entities.Free;
  inherited Destroy;
end;

function TD3MapFile.LoadFromText(const Text: String): Boolean;
var
  Lexer: TDoom3Lexer;
  Tok, Key: String;
  E: TD3MapEntity;
begin
  Entities.Clear;
  Lexer := TDoom3Lexer.Create(Text);
  try
    if SameText(Lexer.Peek, 'Version') then
    begin
      Lexer.NextStr;
      Lexer.NextStr;
    end;
    while Lexer.Next(Tok) do
    begin
      if Tok <> '{' then
        Continue;
      E := TD3MapEntity.Create;
      Entities.Add(E);
      while Lexer.Next(Tok) do
      begin
        if Lexer.WasQuoted then
        begin
          Key := Tok;
          E.SetValue(Key, Lexer.NextStr);
        end else
        if Tok = '{' then
        begin
          Inc(E.PrimitiveCount);
          Lexer.SkipBracedSection;
        end else
        if Tok = '}' then
          Break;
      end;
    end;
    Result := Entities.Count > 0;
  finally
    Lexer.Free;
  end;
end;

function TD3MapFile.LoadFromVfs(const Path: String): Boolean;
var
  Text: String;
begin
  Text := D3Fs.ReadText(Path);
  Result := (Text <> '') and LoadFromText(Text);
  if Result then
    WritelnLog('Doom3MapFile', '"%s": %d entities', [Path, Entities.Count]);
end;

function TD3MapFile.FindByName(const Name: String): TD3MapEntity;
var
  E: TD3MapEntity;
begin
  for E in Entities do
    if SameText(E.Name, Name) then
      Exit(E);
  Result := nil;
end;

function TD3MapFile.WorldSpawn: TD3MapEntity;
var
  E: TD3MapEntity;
begin
  for E in Entities do
    if SameText(E.ClassName_, 'worldspawn') then
      Exit(E);
  Result := nil;
end;

end.
