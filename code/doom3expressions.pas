// Doom 3 material expressions and tables.
//
// Material stages compute their color registers (red, green, blue, alpha,
// rgb, rgba, color) from expressions like
//   red ( strobeTable[ time * 2 ] ) * Parm0
// with numbers, time (seconds), parm0..parm11 (the entity's shader
// parameters; a light's _color is parm0..2), global0..7, table lookups
// name[expr], parentheses, unary minus and the operators of idMaterial's
// ParseExpressionPriority:
//   * / %   (highest)
//   + -
//   > >= < <= == !=
//   && ||   (lowest)
//
// Tables ("table name [snap] [clamp] { v, v, ... }") are looked up like
// idDeclTable::TableLookup: the index is scaled by the number of values,
// wraps around (or clamps), and values are interpolated unless "snap".
unit Doom3Expressions;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Generics.Collections;

type
  TD3Table = class
    Name: String;
    Snap, Clamp: Boolean;
    { The values, plus the first one appended for wrapping (as Doom 3). }
    Values: array of Single;
    function Lookup(Index: Single): Single;
    { Parse a table decl body: [snap] [clamp] { v, v, ... } }
    procedure Parse(const Body: String);
  end;

  TD3TableResolver = function (const Name: String): TD3Table of object;

  TD3ExprContext = record
    Time: Single;
    Parms: array [0..11] of Single;
    Globals: array [0..7] of Single;
  end;

  TD3Expr = class
    function Eval(const Ctx: TD3ExprContext): Single; virtual; abstract;
    { No time / parm / global / table dependency? }
    function IsConstant: Boolean; virtual;
    { Does the value change with time (for a fixed entity)? }
    function UsesTime: Boolean; virtual;
  end;

  TD3ExprList = specialize TObjectList<TD3Expr>;

{ Parse an expression from Text starting at Pos (1-based); Pos is moved
  after it. Tables are found with Resolve. Returns nil on a syntax error.
  Owned by the caller. }
function ParseD3Expression(const Text: String; var Pos: Integer;
  const Resolve: TD3TableResolver): TD3Expr;
{ Parse a whole string as one expression. }
function ParseD3ExpressionString(const Text: String; const Resolve: TD3TableResolver): TD3Expr;

{ A context with time 0, parm0..3 = 1 (like a default entity) and the
  other parameters 0. }
function DefaultExprContext: TD3ExprContext;

implementation

uses
  Math,
  Doom3Lexer;

{ TD3Table }

function TD3Table.Lookup(Index: Single): Single;
var
  Domain, I: Integer;
  Frac: Single;
begin
  Domain := Length(Values) - 1;
  if Domain <= 1 then
  begin
    if Length(Values) > 0 then
      Exit(Values[0]);
    Exit(1);
  end;
  if Clamp then
  begin
    Index := Index * (Domain - 1);
    if Index >= Domain - 1 then
      Exit(Values[Domain - 1]);
    if Index <= 0 then
      Exit(Values[0]);
    I := Trunc(Index);
    Frac := Index - I;
  end else
  begin
    Index := Index * Domain;
    if Index < 0 then
      Index := Index + Domain * Ceil(-Index / Domain);
    I := Floor(Index);
    Frac := Index - I;
    I := I mod Domain;
  end;
  if Snap then
    Result := Values[I]
  else
    Result := Values[I] * (1 - Frac) + Values[I + 1] * Frac;
end;

procedure TD3Table.Parse(const Body: String);
var
  L: TDoom3Lexer;
  Tok: String;
begin
  Values := nil;
  L := TDoom3Lexer.Create(Body);
  try
    while L.Next(Tok) do
    begin
      if SameText(Tok, 'snap') then
        Snap := True
      else
      if SameText(Tok, 'clamp') then
        Clamp := True
      else
      if Tok = '{' then
      begin
        while L.Next(Tok) and (Tok <> '}') do
          if Tok <> ',' then
          begin
            SetLength(Values, Length(Values) + 1);
            Values[High(Values)] := D3StrToFloat(Tok);
          end;
        Break;
      end;
    end;
  finally
    L.Free;
  end;
  { copy the first value to the end, so interpolation doesn't need to wrap }
  if Length(Values) > 0 then
  begin
    SetLength(Values, Length(Values) + 1);
    Values[High(Values)] := Values[0];
  end;
end;

{ TD3Expr }

function TD3Expr.IsConstant: Boolean;
begin
  Result := False;
end;

function TD3Expr.UsesTime: Boolean;
begin
  Result := False;
end;

type
  TConstExpr = class(TD3Expr)
    Value: Single;
    function Eval(const Ctx: TD3ExprContext): Single; override;
    function IsConstant: Boolean; override;
  end;

  TRegisterKind = (rkTime, rkParm, rkGlobal);

  TRegisterExpr = class(TD3Expr)
    Kind: TRegisterKind;
    Index: Integer;
    function Eval(const Ctx: TD3ExprContext): Single; override;
    function UsesTime: Boolean; override;
  end;

  TTableExpr = class(TD3Expr)
    Table: TD3Table;
    Arg: TD3Expr;
    destructor Destroy; override;
    function Eval(const Ctx: TD3ExprContext): Single; override;
    function UsesTime: Boolean; override;
  end;

  TNegExpr = class(TD3Expr)
    Arg: TD3Expr;
    destructor Destroy; override;
    function Eval(const Ctx: TD3ExprContext): Single; override;
    function IsConstant: Boolean; override;
    function UsesTime: Boolean; override;
  end;

  TBinaryExpr = class(TD3Expr)
    Op: String;
    A, B: TD3Expr;
    destructor Destroy; override;
    function Eval(const Ctx: TD3ExprContext): Single; override;
    function IsConstant: Boolean; override;
    function UsesTime: Boolean; override;
  end;

function TConstExpr.Eval(const Ctx: TD3ExprContext): Single;
begin
  Result := Value;
end;

function TConstExpr.IsConstant: Boolean;
begin
  Result := True;
end;

function TRegisterExpr.Eval(const Ctx: TD3ExprContext): Single;
begin
  case Kind of
    rkTime: Result := Ctx.Time;
    rkParm: Result := Ctx.Parms[Index];
    else    Result := Ctx.Globals[Index];
  end;
end;

function TRegisterExpr.UsesTime: Boolean;
begin
  Result := Kind = rkTime;
end;

function TTableExpr.UsesTime: Boolean;
begin
  Result := Arg.UsesTime;
end;

function TNegExpr.UsesTime: Boolean;
begin
  Result := Arg.UsesTime;
end;

function TBinaryExpr.UsesTime: Boolean;
begin
  Result := A.UsesTime or B.UsesTime;
end;

destructor TTableExpr.Destroy;
begin
  Arg.Free;
  inherited Destroy;
end;

function TTableExpr.Eval(const Ctx: TD3ExprContext): Single;
begin
  Result := Table.Lookup(Arg.Eval(Ctx));
end;

destructor TNegExpr.Destroy;
begin
  Arg.Free;
  inherited Destroy;
end;

function TNegExpr.Eval(const Ctx: TD3ExprContext): Single;
begin
  Result := -Arg.Eval(Ctx);
end;

function TNegExpr.IsConstant: Boolean;
begin
  Result := Arg.IsConstant;
end;

destructor TBinaryExpr.Destroy;
begin
  A.Free;
  B.Free;
  inherited Destroy;
end;

function BoolF(const B: Boolean): Single; inline;
begin
  if B then
    Result := 1
  else
    Result := 0;
end;

function TBinaryExpr.Eval(const Ctx: TD3ExprContext): Single;
var
  X, Y: Single;
begin
  X := A.Eval(Ctx);
  Y := B.Eval(Ctx);
  if Op = '+' then Result := X + Y else
  if Op = '-' then Result := X - Y else
  if Op = '*' then Result := X * Y else
  if Op = '/' then
  begin
    if Y = 0 then
      Result := 0
    else
      Result := X / Y;
  end else
  if Op = '%' then
  begin
    { Doom 3 uses integer modulo }
    if Trunc(Y) = 0 then
      Result := 0
    else
      Result := Trunc(X) mod Trunc(Y);
  end else
  if Op = '>' then Result := BoolF(X > Y) else
  if Op = '>=' then Result := BoolF(X >= Y) else
  if Op = '<' then Result := BoolF(X < Y) else
  if Op = '<=' then Result := BoolF(X <= Y) else
  if Op = '==' then Result := BoolF(X = Y) else
  if Op = '!=' then Result := BoolF(X <> Y) else
  if Op = '&&' then Result := BoolF((X <> 0) and (Y <> 0)) else
  if Op = '||' then Result := BoolF((X <> 0) or (Y <> 0)) else
    Result := 0;
end;

function TBinaryExpr.IsConstant: Boolean;
begin
  Result := A.IsConstant and B.IsConstant;
end;

{ Parser ---------------------------------------------------------------------- }

type
  TExprParser = class
    Text: String;
    P: Integer;
    Resolve: TD3TableResolver;
    Failed: Boolean;
    procedure SkipSpace;
    function PeekOp: String;
    function ParseLevel(const Level: Integer): TD3Expr;
    function ParseTerm: TD3Expr;
    function ReadName: String;
  end;

procedure TExprParser.SkipSpace;
begin
  while (P <= Length(Text)) and (Text[P] in [' ', #9]) do
    Inc(P);
end;

function TExprParser.PeekOp: String;
var
  Two: String;
begin
  SkipSpace;
  Result := '';
  if P > Length(Text) then
    Exit;
  Two := Copy(Text, P, 2);
  if (Two = '>=') or (Two = '<=') or (Two = '==') or (Two = '!=') or
     (Two = '&&') or (Two = '||') then
    Exit(Two);
  if Text[P] in ['+', '-', '*', '/', '%', '>', '<'] then
    Result := Text[P];
end;

function OpLevel(const Op: String): Integer;
begin
  if (Op = '*') or (Op = '/') or (Op = '%') then Exit(4);
  if (Op = '+') or (Op = '-') then Exit(3);
  if (Op = '>') or (Op = '>=') or (Op = '<') or (Op = '<=') or (Op = '==') or (Op = '!=') then Exit(2);
  if (Op = '&&') or (Op = '||') then Exit(1);
  Result := 0;
end;

function TExprParser.ReadName: String;
var
  Start: Integer;
begin
  Start := P;
  while (P <= Length(Text)) and (Text[P] in ['a'..'z', 'A'..'Z', '0'..'9', '_', '.']) do
    Inc(P);
  Result := Copy(Text, Start, P - Start);
end;

function TExprParser.ParseLevel(const Level: Integer): TD3Expr;
var
  Op: String;
  Bin: TBinaryExpr;
begin
  if Level > 4 then
    Exit(ParseTerm);
  Result := ParseLevel(Level + 1);
  while not Failed do
  begin
    Op := PeekOp;
    if (Op = '') or (OpLevel(Op) <> Level) then
      Break;
    Inc(P, Length(Op));
    Bin := TBinaryExpr.Create;
    Bin.Op := Op;
    Bin.A := Result;
    Bin.B := ParseLevel(Level + 1);
    Result := Bin;
  end;
end;

function TExprParser.ParseTerm: TD3Expr;
var
  Name, L: String;
  Code: Integer;
  V: Double;
  C: TConstExpr;
  R: TRegisterExpr;
  T: TTableExpr;
  N: TNegExpr;
  Table: TD3Table;
begin
  SkipSpace;
  if P > Length(Text) then
  begin
    Failed := True;
    Exit(TConstExpr.Create);
  end;
  if Text[P] = '(' then
  begin
    Inc(P);
    Result := ParseLevel(1);
    SkipSpace;
    if (P <= Length(Text)) and (Text[P] = ')') then
      Inc(P);
    Exit;
  end;
  if Text[P] = '-' then
  begin
    Inc(P);
    N := TNegExpr.Create;
    N.Arg := ParseTerm();
    Exit(N);
  end;
  Name := ReadName;
  if Name = '' then
  begin
    Failed := True;
    Exit(TConstExpr.Create);
  end;
  L := LowerCase(Name);
  if L[1] in ['0'..'9', '.'] then
  begin
    Val(Name, V, Code);
    C := TConstExpr.Create;
    if Code = 0 then
      C.Value := V
    else
      Failed := True;
    Exit(C);
  end;
  if L = 'time' then
  begin
    R := TRegisterExpr.Create;
    R.Kind := rkTime;
    Exit(R);
  end;
  if (Copy(L, 1, 4) = 'parm') and (StrToIntDef(Copy(L, 5, 2), -1) in [0..11]) then
  begin
    R := TRegisterExpr.Create;
    R.Kind := rkParm;
    R.Index := StrToInt(Copy(L, 5, 2));
    Exit(R);
  end;
  if (Copy(L, 1, 6) = 'global') and (StrToIntDef(Copy(L, 7, 1), -1) in [0..7]) then
  begin
    R := TRegisterExpr.Create;
    R.Kind := rkGlobal;
    R.Index := StrToInt(Copy(L, 7, 1));
    Exit(R);
  end;
  if (L = 'sound') or (L = 'fragmentprograms') then
  begin
    { no sound amplitude; fragment programs are always "supported" }
    C := TConstExpr.Create;
    C.Value := BoolF(L = 'fragmentprograms');
    Exit(C);
  end;
  { a table lookup }
  SkipSpace;
  if (P <= Length(Text)) and (Text[P] = '[') then
  begin
    Inc(P);
    Table := nil;
    if Assigned(Resolve) then
      Table := Resolve(L);
    T := TTableExpr.Create;
    T.Arg := ParseLevel(1);
    SkipSpace;
    if (P <= Length(Text)) and (Text[P] = ']') then
      Inc(P);
    if Table = nil then
    begin
      { unknown table: Doom 3 complains and uses 0 }
      T.Free;
      C := TConstExpr.Create;
      Exit(C);
    end;
    T.Table := Table;
    Exit(T);
  end;
  Failed := True;
  Result := TConstExpr.Create;
end;

function ParseD3Expression(const Text: String; var Pos: Integer;
  const Resolve: TD3TableResolver): TD3Expr;
var
  Parser: TExprParser;
begin
  Parser := TExprParser.Create;
  try
    Parser.Text := Text;
    Parser.P := Pos;
    Parser.Resolve := Resolve;
    Result := Parser.ParseLevel(1);
    Pos := Parser.P;
    if Parser.Failed then
      FreeAndNil(Result);
  finally
    Parser.Free;
  end;
end;

function ParseD3ExpressionString(const Text: String; const Resolve: TD3TableResolver): TD3Expr;
var
  Pos: Integer;
begin
  Pos := 1;
  Result := ParseD3Expression(Text, Pos, Resolve);
end;

function DefaultExprContext: TD3ExprContext;
var
  I: Integer;
begin
  Result.Time := 0;
  for I := 0 to High(Result.Parms) do
    Result.Parms[I] := 0;
  for I := 0 to 3 do
    Result.Parms[I] := 1;
  for I := 0 to High(Result.Globals) do
    Result.Globals[I] := 0;
end;

end.
