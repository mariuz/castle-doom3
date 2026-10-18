{
  Copyright 2026 Castle Doom 3 contributors.

  Doom 3 articulated figures (af/*.af, "articulatedFigure" decls): the
  bodies and constraints of a ragdoll (idDeclAF). Only what the port's
  ragdoll uses is kept: each body's joint, origin, model bounds and
  contained joints, each constraint's kind, bodies, anchor and its cone /
  hinge limit. Vectors stay symbolic ("joint( name )", "bonecenter( a, b )")
  and are evaluated against a pose by TD3AFVector.Evaluate.
}
unit Doom3AF;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleVectors,
  Doom3Md5;

type
  TD3AFVectorKind = (avPoint, avJoint, avBoneCenter, avBoneDir);

  { idAFVector: a point, a joint's position, the middle of two joints or
    the direction from one to the other (in the model's space). }
  TD3AFVector = record
    Kind: TD3AFVectorKind;
    Point: TVector3;
    Joint1, Joint2: String;
    { the position (direction for avBoneDir) in Pose; Defined is False
      when a joint is missing (then Result is Point) }
    function Evaluate(const Pose: TD3JointArray; out Defined: Boolean): TVector3;
  end;

  TD3AFBody = class
    Name, JointName: String;
    Origin: TD3AFVector;
    { the collision model's kind (box, bone, cylinder...) and the bounds
      of its arguments (model space, relative to Origin for boxes) }
    ModelKind: String;
    ModelMins, ModelMaxs: TVector3;
    ModelWidth: Single;
    { "*joint -*other": the joints this body moves ('' = its joint) }
    ContainedJoints: String;
    { the joint indexes ContainedJoints names in a skeleton }
    function JointList(const Pose: TD3JointArray): specialize TArray<Integer>;
    { half the body's smallest extent: its collision radius }
    function Radius: Single;
  end;

  TD3AFConstraintKind = (acFixed, acBallAndSocket, acUniversal, acHinge, acSlider, acSpring, acPlane);

  TD3AFConstraint = class
    Name: String;
    Kind: TD3AFConstraintKind;
    Body1, Body2: String;
    { the shared point (position, or a spring's anchor1) }
    Anchor: TD3AFVector;
    HasAnchor: Boolean;
    { how far body2 may bend from body1 (degrees; 0 = no limit): a cone's
      angle, a pyramid's larger angle, a hinge limit's width }
    LimitAngle: Single;
  end;

  TD3ArticulatedFigure = class
    Name, ModelName: String;
    Bodies: specialize TObjectList<TD3AFBody>;
    Constraints: specialize TObjectList<TD3AFConstraint>;
    constructor Create;
    destructor Destroy; override;
    function BodyIndex(const AName: String): Integer;
  end;

{ Parse the body of an articulatedFigure decl (between its braces). }
function ParseArticulatedFigure(const AName, Body: String): TD3ArticulatedFigure;

{ The articulated figure of that name (af/*.af through Decls; cached), nil
  if none. }
function ArticulatedFigure(const AName: String): TD3ArticulatedFigure;

procedure ClearArticulatedFigures;

implementation

uses
  Math,
  Doom3Lexer, Doom3Decls;

var
  Cache: specialize TObjectDictionary<String, TD3ArticulatedFigure>;

{ TD3AFVector }

function TD3AFVector.Evaluate(const Pose: TD3JointArray; out Defined: Boolean): TVector3;

  function JointPos(const JointName: String; out P: TVector3): Boolean;
  var
    I: Integer;
  begin
    for I := 0 to High(Pose) do
      if SameText(Pose[I].Name, JointName) then
      begin
        P := Pose[I].Position;
        Exit(True);
      end;
    P := TVector3.Zero;
    Result := False;
  end;

var
  A, B: TVector3;
begin
  Defined := True;
  Result := Point;
  case Kind of
    avJoint:
      Defined := JointPos(Joint1, Result);
    avBoneCenter, avBoneDir:
      begin
        Defined := JointPos(Joint1, A) and JointPos(Joint2, B);
        if Defined then
        begin
          if Kind = avBoneCenter then
            Result := (A + B) * 0.5
          else
            Result := B - A;
        end;
      end;
  end;
  if not Defined then
    Result := Point;
end;

{ TD3AFBody }

function TD3AFBody.JointList(const Pose: TD3JointArray): specialize TArray<Integer>;
var
  Words: TStringArray;
  W, JName: String;
  Remove, Tree: Boolean;
  Marked: array of Boolean;
  I, J: Integer;

  function IsUnder(const Joint, Root: Integer): Boolean;
  var
    K: Integer;
  begin
    K := Joint;
    while K >= 0 do
    begin
      if K = Root then
        Exit(True);
      K := Pose[K].Parent;
    end;
    Result := False;
  end;

begin
  SetLength(Marked, Length(Pose));
  if Trim(ContainedJoints) = '' then
    Words := [JointName]
  else
    Words := Trim(ContainedJoints).Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
  for W in Words do
  begin
    JName := W;
    Remove := Copy(JName, 1, 1) = '-';
    if Remove then
      Delete(JName, 1, 1);
    Tree := Copy(JName, 1, 1) = '*';
    if Tree then
      Delete(JName, 1, 1);
    J := -1;
    for I := 0 to High(Pose) do
      if SameText(Pose[I].Name, JName) then
      begin
        J := I;
        Break;
      end;
    if J < 0 then
      Continue;
    for I := 0 to High(Pose) do
      if (I = J) or (Tree and IsUnder(I, J)) then
        Marked[I] := not Remove;
  end;
  Result := nil;
  for I := 0 to High(Marked) do
    if Marked[I] then
      Result := Concat(Result, [I]);
end;

function TD3AFBody.Radius: Single;
var
  Size: TVector3;
begin
  if SameText(ModelKind, 'bone') and (ModelWidth > 0) then
    Exit(ModelWidth * 0.5);
  Size := ModelMaxs - ModelMins;
  Result := Min(Size.X, Min(Size.Y, Size.Z)) * 0.5;
  if Result <= 0.5 then
    Result := 4;
end;

{ TD3ArticulatedFigure }

constructor TD3ArticulatedFigure.Create;
begin
  inherited Create;
  Bodies := specialize TObjectList<TD3AFBody>.Create(True);
  Constraints := specialize TObjectList<TD3AFConstraint>.Create(True);
end;

destructor TD3ArticulatedFigure.Destroy;
begin
  Bodies.Free;
  Constraints.Free;
  inherited Destroy;
end;

function TD3ArticulatedFigure.BodyIndex(const AName: String): Integer;
begin
  for Result := 0 to Bodies.Count - 1 do
    if SameText(Bodies[Result].Name, AName) then
      Exit;
  Result := -1;
end;

{ parsing }

type
  { one value of a key: a number, a string, a vector ( x, y, z ) or a call
    name( args ) }
  TD3AFValueKind = (vkNumber, vkString, vkVector, vkCall);

  TD3AFValue = class
    Kind: TD3AFValueKind;
    Number: Single;
    Str: String;
    Vector: TVector3;
    Args: specialize TObjectList<TD3AFValue>;
    constructor Create;
    destructor Destroy; override;
  end;

  TD3AFValueList = specialize TObjectList<TD3AFValue>;

constructor TD3AFValue.Create;
begin
  inherited Create;
  Args := TD3AFValueList.Create(True);
end;

destructor TD3AFValue.Destroy;
begin
  Args.Free;
  inherited Destroy;
end;

function IsNumber(const S: String): Boolean;
var
  F: Double;
begin
  Result := TryStrToFloat(S, F, DefaultFormatSettings);
end;

{ one value at the lexer's position }
function ReadValue(const Lexer: TDoom3Lexer): TD3AFValue;
var
  Tok: String;
  Values: array [0..2] of Single;
  I: Integer;
begin
  Result := TD3AFValue.Create;
  Tok := Lexer.NextStr;
  if Tok = '(' then
  begin
    { ( x, y, z ): numbers, commas optional }
    for I := 0 to 2 do
    begin
      Values[I] := D3StrToFloat(Lexer.NextStr);
      if Lexer.Peek = ',' then
        Lexer.NextStr;
    end;
    while (not Lexer.AtEnd) and (Lexer.Peek <> ')') do
      Lexer.NextStr;
    Lexer.Check(')');
    Result.Kind := vkVector;
    Result.Vector := Vector3(Values[0], Values[1], Values[2]);
  end else
  if Lexer.Peek = '(' then
  begin
    { name( arg, arg... ) }
    Lexer.NextStr;
    Result.Kind := vkCall;
    Result.Str := LowerCase(Tok);
    while (not Lexer.AtEnd) and (Lexer.Peek <> ')') do
    begin
      Result.Args.Add(ReadValue(Lexer));
      if Lexer.Peek = ',' then
        Lexer.NextStr;
    end;
    Lexer.Check(')');
  end else
  if IsNumber(Tok) then
  begin
    Result.Kind := vkNumber;
    Result.Number := D3StrToFloat(Tok);
  end else
  begin
    Result.Kind := vkString;
    Result.Str := Tok;
  end;
end;

{ a key's values: separated by commas }
procedure ReadValues(const Lexer: TDoom3Lexer; const Values: TD3AFValueList);
begin
  Values.Clear;
  if Lexer.AtEnd or (Lexer.Peek = '}') then
    Exit;
  Values.Add(ReadValue(Lexer));
  while Lexer.Peek = ',' do
  begin
    Lexer.NextStr;
    Values.Add(ReadValue(Lexer));
  end;
end;

function ValueToVector(const V: TD3AFValue): TD3AFVector;
begin
  Result.Kind := avPoint;
  Result.Point := TVector3.Zero;
  Result.Joint1 := '';
  Result.Joint2 := '';
  if V = nil then
    Exit;
  case V.Kind of
    vkVector:
      Result.Point := V.Vector;
    vkCall:
      begin
        if (V.Str = 'joint') and (V.Args.Count >= 1) then
        begin
          Result.Kind := avJoint;
          Result.Joint1 := V.Args[0].Str;
        end else
        if ((V.Str = 'bonecenter') or (V.Str = 'bonedir')) and (V.Args.Count >= 2) then
        begin
          if V.Str = 'bonecenter' then
            Result.Kind := avBoneCenter
          else
            Result.Kind := avBoneDir;
          Result.Joint1 := V.Args[0].Str;
          Result.Joint2 := V.Args[1].Str;
        end;
      end;
  end;
end;

function NumberAt(const Values: TD3AFValueList; const I: Integer; const Default: Single = 0): Single;
begin
  if (I < Values.Count) and (Values[I].Kind = vkNumber) then
    Result := Values[I].Number
  else
    Result := Default;
end;

function StringAt(const Values: TD3AFValueList; const I: Integer): String;
begin
  if (I < Values.Count) and (Values[I].Kind in [vkString, vkNumber]) then
    Result := Values[I].Str
  else
    Result := '';
end;

procedure ParseBody(const Lexer: TDoom3Lexer; const Body: TD3AFBody);
var
  Key: String;
  Values: TD3AFValueList;
  M: TD3AFValue;
  I: Integer;
  P: TVector3;
begin
  Values := TD3AFValueList.Create(True);
  try
    while (not Lexer.AtEnd) and not Lexer.Check('}') do
    begin
      Key := LowerCase(Lexer.NextStr);
      ReadValues(Lexer, Values);
      if Key = 'joint' then
        Body.JointName := StringAt(Values, 0)
      else
      if Key = 'origin' then
      begin
        if Values.Count > 0 then
          Body.Origin := ValueToVector(Values[0]);
      end else
      if Key = 'containedjoints' then
        Body.ContainedJoints := StringAt(Values, 0)
      else
      if (Key = 'model') and (Values.Count > 0) and (Values[0].Kind = vkCall) then
      begin
        { box( mins, maxs ), cylinder / cone( mins, maxs, sides ),
          octahedron / dodecahedron( mins, maxs ), bone( a, b, width ) }
        M := Values[0];
        Body.ModelKind := M.Str;
        if (M.Args.Count >= 2) and (M.Args[0].Kind = vkVector) and (M.Args[1].Kind = vkVector) then
        begin
          Body.ModelMins := M.Args[0].Vector;
          Body.ModelMaxs := M.Args[1].Vector;
        end;
        if M.Str = 'bone' then
          for I := 0 to M.Args.Count - 1 do
            if M.Args[I].Kind = vkNumber then
              Body.ModelWidth := M.Args[I].Number;
      end;
    end;
  finally
    Values.Free;
  end;
  { a box around nothing: a small one }
  P := Body.ModelMaxs - Body.ModelMins;
  if P.IsZero then
  begin
    Body.ModelMins := Vector3(-4, -4, -4);
    Body.ModelMaxs := Vector3(4, 4, 4);
  end;
end;

procedure ParseConstraint(const Lexer: TDoom3Lexer; const C: TD3AFConstraint);
var
  Key: String;
  Values: TD3AFValueList;
begin
  Values := TD3AFValueList.Create(True);
  try
    while (not Lexer.AtEnd) and not Lexer.Check('}') do
    begin
      Key := LowerCase(Lexer.NextStr);
      ReadValues(Lexer, Values);
      if Key = 'body1' then
        C.Body1 := StringAt(Values, 0)
      else
      if Key = 'body2' then
        C.Body2 := StringAt(Values, 0)
      else
      if ((Key = 'position') or (Key = 'anchor') or (Key = 'anchor1')) and (Values.Count > 0) then
      begin
        C.Anchor := ValueToVector(Values[0]);
        C.HasAnchor := True;
      end else
      if Key = 'cone' then
        { cone ( axis ), angle }
        C.LimitAngle := NumberAt(Values, 1)
      else
      if Key = 'pyramid' then
        { pyramid ( axis ), angle1, angle2, yaw }
        C.LimitAngle := Max(NumberAt(Values, 1), NumberAt(Values, 2))
      else
      if Key = 'limit' then
        { a hinge's limit: angle, width, shaft angle }
        C.LimitAngle := NumberAt(Values, 1);
    end;
  finally
    Values.Free;
  end;
end;

function ParseArticulatedFigure(const AName, Body: String): TD3ArticulatedFigure;
var
  Lexer: TDoom3Lexer;
  Tok, Kind: String;
  B: TD3AFBody;
  C: TD3AFConstraint;
  Values: TD3AFValueList;
begin
  Result := TD3ArticulatedFigure.Create;
  Result.Name := AName;
  Lexer := TDoom3Lexer.Create(Body);
  Values := TD3AFValueList.Create(True);
  try
    while Lexer.Next(Tok) do
    begin
      Kind := LowerCase(Tok);
      if Kind = 'settings' then
      begin
        if not Lexer.Check('{') then
          Continue;
        while (not Lexer.AtEnd) and not Lexer.Check('}') do
        begin
          Tok := LowerCase(Lexer.NextStr);
          ReadValues(Lexer, Values);
          if Tok = 'model' then
            Result.ModelName := StringAt(Values, 0);
        end;
      end else
      if Kind = 'body' then
      begin
        B := TD3AFBody.Create;
        B.Name := Lexer.NextStr;
        Result.Bodies.Add(B);
        if Lexer.Check('{') then
          ParseBody(Lexer, B);
      end else
      if (Kind = 'fixed') or (Kind = 'ballandsocketjoint') or (Kind = 'universaljoint') or
         (Kind = 'hinge') or (Kind = 'slider') or (Kind = 'spring') or (Kind = 'plane') then
      begin
        C := TD3AFConstraint.Create;
        C.Name := Lexer.NextStr;
        if Kind = 'fixed' then
          C.Kind := acFixed
        else
        if Kind = 'ballandsocketjoint' then
          C.Kind := acBallAndSocket
        else
        if Kind = 'universaljoint' then
          C.Kind := acUniversal
        else
        if Kind = 'hinge' then
          C.Kind := acHinge
        else
        if Kind = 'slider' then
          C.Kind := acSlider
        else
        if Kind = 'spring' then
          C.Kind := acSpring
        else
          C.Kind := acPlane;
        Result.Constraints.Add(C);
        if Lexer.Check('{') then
          ParseConstraint(Lexer, C);
      end else
      if Lexer.Peek = '{' then
      begin
        { an unknown block }
        Lexer.NextStr;
        Lexer.SkipBracedSection;
      end;
    end;
  finally
    Values.Free;
    Lexer.Free;
  end;
end;

function ArticulatedFigure(const AName: String): TD3ArticulatedFigure;
var
  Key, Body: String;
begin
  Key := LowerCase(AName);
  if Key = '' then
    Exit(nil);
  if Cache.TryGetValue(Key, Result) then
    Exit;
  Result := nil;
  if (Decls <> nil) and Decls.DeclBody(dtAF, Key, Body) then
    Result := ParseArticulatedFigure(Key, Body);
  { nil too: not looked up again }
  Cache.Add(Key, Result);
end;

procedure ClearArticulatedFigures;
begin
  Cache.Clear;
end;

initialization
  Cache := specialize TObjectDictionary<String, TD3ArticulatedFigure>.Create([doOwnsValues]);
finalization
  FreeAndNil(Cache);
end.
