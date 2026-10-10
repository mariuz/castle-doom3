{ Tokenizer for idTech 4 text formats (.proc, .map, .mtr, .def, .md5mesh,
  .md5anim, .skin, .sndshd), a small subset of idLexer.

  Tokens are: quoted strings ("..."), single punctuation characters
  (braces, parentheses, brackets, comma, semicolon, equals sign), and runs of any other non-space characters (names,
  paths such as textures/base_wall/a.tga, numbers such as -1.5e-005).
  // and /* */ comments are skipped. }
unit Doom3Lexer;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TDoom3Lexer = class
  strict private
    FText: String;
    FPos: Integer;
    FLine: Integer;
    FWasQuoted: Boolean;
    FPeeked: Boolean;
    FPeekToken: String;
    FPeekQuoted: Boolean;
    FPeekLine: Integer;
    FPeekOk: Boolean;
    procedure SkipWhiteAndComments;
    function ReadRaw(out Token: String; out Quoted: Boolean): Boolean;
  public
    constructor Create(const AText: String);
    { Next token, False at the end of the text. }
    function Next(out Token: String): Boolean;
    { Next token or '' at the end. }
    function NextStr: String;
    { Look at the next token without consuming it ('' at the end). }
    function Peek: String;
    function AtEnd: Boolean;
    { Read the next token and check it (case-insensitive). }
    function Expect(const S: String): Boolean;
    { Consume the next token if it equals S (case-insensitive). }
    function Check(const S: String): Boolean;
    function ReadFloat: Single;
    function ReadInt: Integer;
    { Read "( a b c ... )" with Count numbers. }
    procedure ReadVector(const Values: PSingle; const Count: Integer);
    { Skip until the closing brace matching an already consumed opening brace. }
    procedure SkipBracedSection;
    { Skip the rest of the current line. }
    procedure SkipLine;
    { The rest of the current line (without a // comment), consumed.
      Only valid when nothing was peeked. }
    function RestOfLine: String;
    { Was the last token returned by Next a quoted string? }
    property WasQuoted: Boolean read FWasQuoted;
    property Line: Integer read FLine;
    { Text position (1-based) right after the last token read by Next.
      Valid only when nothing was peeked. }
    property Position: Integer read FPos;
    property Text: String read FText;
  end;

{ Locale-independent float parsing, Default when S isn't a number. }
function D3StrToFloat(const S: String; const Default: Single = 0): Single;

implementation

function D3StrToFloat(const S: String; const Default: Single): Single;
var
  Code: Integer;
  D: Double;
begin
  Val(S, D, Code);
  if Code = 0 then
    Result := D
  else
    Result := Default;
end;

constructor TDoom3Lexer.Create(const AText: String);
begin
  inherited Create;
  FText := AText;
  FPos := 1;
  FLine := 1;
end;

procedure TDoom3Lexer.SkipWhiteAndComments;
var
  Len: Integer;
begin
  Len := Length(FText);
  while FPos <= Len do
  begin
    case FText[FPos] of
      #10:
        begin
          Inc(FLine);
          Inc(FPos);
        end;
      #0..#9, #11..' ':
        Inc(FPos);
      '/':
        if (FPos < Len) and (FText[FPos + 1] = '/') then
        begin
          while (FPos <= Len) and (FText[FPos] <> #10) do
            Inc(FPos);
        end else
        if (FPos < Len) and (FText[FPos + 1] = '*') then
        begin
          Inc(FPos, 2);
          while (FPos < Len) and not ((FText[FPos] = '*') and (FText[FPos + 1] = '/')) do
          begin
            if FText[FPos] = #10 then
              Inc(FLine);
            Inc(FPos);
          end;
          Inc(FPos, 2);
        end else
          Exit;
      else
        Exit;
    end;
  end;
end;

function TDoom3Lexer.ReadRaw(out Token: String; out Quoted: Boolean): Boolean;
const
  Punctuation = ['{', '}', '(', ')', '[', ']', ',', ';', '=', '"'];
var
  Len, Start: Integer;
begin
  Quoted := False;
  SkipWhiteAndComments;
  Len := Length(FText);
  if FPos > Len then
  begin
    Token := '';
    Exit(False);
  end;
  Result := True;
  if FText[FPos] = '"' then
  begin
    Quoted := True;
    Inc(FPos);
    Start := FPos;
    while (FPos <= Len) and (FText[FPos] <> '"') do
    begin
      if FText[FPos] = #10 then
        Inc(FLine);
      Inc(FPos);
    end;
    Token := Copy(FText, Start, FPos - Start);
    Inc(FPos); { closing quote }
  end else
  if FText[FPos] in Punctuation then
  begin
    Token := FText[FPos];
    Inc(FPos);
  end else
  begin
    Start := FPos;
    while (FPos <= Len) and (FText[FPos] > ' ') and not (FText[FPos] in Punctuation) do
    begin
      if (FText[FPos] = '/') and (FPos < Len) and (FText[FPos + 1] in ['/', '*']) then
        Break;
      Inc(FPos);
    end;
    Token := Copy(FText, Start, FPos - Start);
  end;
end;

function TDoom3Lexer.Next(out Token: String): Boolean;
begin
  if FPeeked then
  begin
    FPeeked := False;
    Token := FPeekToken;
    FWasQuoted := FPeekQuoted;
    FLine := FPeekLine;
    Exit(FPeekOk);
  end;
  Result := ReadRaw(Token, FWasQuoted);
end;

function TDoom3Lexer.NextStr: String;
begin
  if not Next(Result) then
    Result := '';
end;

function TDoom3Lexer.Peek: String;
var
  SaveLine: Integer;
begin
  if not FPeeked then
  begin
    SaveLine := FLine;
    FPeekOk := ReadRaw(FPeekToken, FPeekQuoted);
    FPeekLine := FLine;
    FLine := SaveLine;
    FPeeked := True;
  end;
  Result := FPeekToken;
end;

function TDoom3Lexer.AtEnd: Boolean;
begin
  if FPeeked then
    Exit(not FPeekOk);
  SkipWhiteAndComments;
  Result := FPos > Length(FText);
end;

function TDoom3Lexer.Expect(const S: String): Boolean;
begin
  Result := SameText(NextStr, S);
end;

function TDoom3Lexer.Check(const S: String): Boolean;
begin
  Result := SameText(Peek, S) and FPeekOk and not (FPeekQuoted and (Length(S) = 1));
  if Result then
    NextStr;
end;

function TDoom3Lexer.ReadFloat: Single;
var
  T: String;
begin
  T := NextStr;
  { idLexer reads "- 5" as one number too }
  if T = '-' then
    Result := -D3StrToFloat(NextStr)
  else
    Result := D3StrToFloat(T);
end;

function TDoom3Lexer.ReadInt: Integer;
begin
  Result := Round(ReadFloat);
end;

procedure TDoom3Lexer.ReadVector(const Values: PSingle; const Count: Integer);
var
  I: Integer;
begin
  Check('(');
  for I := 0 to Count - 1 do
    Values[I] := ReadFloat;
  Check(')');
end;

procedure TDoom3Lexer.SkipBracedSection;
var
  Depth: Integer;
  T: String;
begin
  Depth := 1;
  while (Depth > 0) and Next(T) do
    if not FWasQuoted then
    begin
      if T = '{' then
        Inc(Depth)
      else
      if T = '}' then
        Dec(Depth);
    end;
end;

function TDoom3Lexer.RestOfLine: String;
var
  Start, Len, P: Integer;
begin
  Len := Length(FText);
  Start := FPos;
  while (FPos <= Len) and (FText[FPos] <> #10) do
    Inc(FPos);
  Result := Copy(FText, Start, FPos - Start);
  P := Pos('//', Result);
  if P > 0 then
    SetLength(Result, P - 1);
  Result := Trim(Result);
end;

procedure TDoom3Lexer.SkipLine;
var
  Len: Integer;
begin
  if FPeeked then
  begin
    { A peeked token on a later line is kept, one on this line is skipped. }
    if FPeekLine > FLine then
      Exit;
    FPeeked := False;
    FLine := FPeekLine;
  end;
  Len := Length(FText);
  while (FPos <= Len) and (FText[FPos] <> #10) do
    Inc(FPos);
end;

end.
