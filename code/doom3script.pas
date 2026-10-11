// Doom 3 scripts (script/*.script, maps/<map>.script): compiler and
// virtual machine.
//
// The whole program is compiled at once, like idProgram: script/doom_main.script
// (which #includes everything else) and the map's own script. The language is
// idCompiler's: C-like functions, globals and locals of the types void,
// float, boolean, vector, string, entity and script object types, namespaces,
// objects (fields and methods, called virtually), "scriptEvent" declarations
// of the engine's events, $name entity references, 'x y z' vector constants,
// vector components as name_x / name_y / name_z, the preprocessor's #include,
// #define (also with parameters), #ifdef / #ifndef / #else / #endif.
//
// Operator priorities are idCompiler's, not C's:
//   unary - ! ~ ++ -- thread, postfix ++ --, member .   (terms)
//   * / % & |                                         3
//   + -                                               4
//   == != < <= > >=                                   5
//   = += -= *= /= %= &= |=   (right associative)      6
//   && ||    (both sides evaluated, like OP_AND)      7
//
// Code is compiled to a stack machine. Each script thread has its own stack
// and call frames, so a thread can stop anywhere (sys.wait, sys.waitFor,
// sys.waitFrame, sys.waitForThread) and go on in a later frame. Events
// other than the thread's own (waiting, printing, math and strings) go to a
// TD3ScriptHost, which the game implements.
unit Doom3Script;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, CastleVectors;

type
  ED3ScriptError = class(Exception);

  TD3ScriptBase = (sbVoid, sbFloat, sbBoolean, sbVector, sbString, sbEntity, sbObject);

  TD3ScriptFunction = class;

  { A type: a basic one, or a script object type (object x : parent ...). }
  TD3ScriptType = class
    Base: TD3ScriptBase;
    Name: String;
    Parent: TD3ScriptType;
    { object types: field names to indexes (the parent's fields first) }
    Fields: specialize TDictionary<String, Integer>;
    FieldTypes: specialize TList<TD3ScriptType>;
    Methods: specialize TDictionary<String, TD3ScriptFunction>;
    constructor Create(const ABase: TD3ScriptBase; const AName: String);
    destructor Destroy; override;
    function FindField(const AName: String; out Index: Integer): Boolean;
    { The closest declaration (for compiling calls). }
    function FindMethod(const AName: String): TD3ScriptFunction;
    { The closest definition (for running). }
    function FindMethodToRun(const AName: String): TD3ScriptFunction;
    function IsA(const T: TD3ScriptType): Boolean;
  end;

  TD3Value = record
    Kind: TD3ScriptBase; // sbFloat, sbVector, sbString or sbEntity (booleans are floats, objects entities)
    F: Single;
    V: TVector3;
    S: String;
    E: Integer; // entity handle, 0 = none ($null_entity)
  end;
  TD3ValueArray = array of TD3Value;

  TD3ScriptFunction = class
    Name: String;           // with namespaces / object: "map_x::main"
    ReturnType: TD3ScriptType;
    ParamTypes: array of TD3ScriptType;
    { all locals, the parameters first }
    LocalTypes: array of TD3ScriptType;
    Address: Integer;       // -1: only declared
    Obj: TD3ScriptType;     // methods: the object type
  end;

  TD3ScriptEvent = class
    Name: String;
    ReturnType: TD3ScriptType;
    ParamTypes: array of TD3ScriptType;
  end;

  TD3Op = (
    opPushConst, opPushGlobal, opStoreGlobal, opPushLocal, opStoreLocal,
    opPushField, opStoreField, opPushSelf, opPushEntity,
    opComp, opSetComp, opConvert, opDup, opPop,
    opAdd, opSub, opMul, opDiv, opMod, opBitAnd, opBitOr, opAnd, opOr,
    opEq, opNe, opLt, opLe, opGt, opGe, opNeg, opNot, opComplement, opInt,
    opJump, opJumpFalse,
    opCall, opCallMethod, opEvent, opSysEvent, opThread, opThreadMethod,
    opReturn);

  TD3Instr = record
    Op: TD3Op;
    A, B: Integer;
  end;

  { An instance of a script object type, on an entity (its "scriptobject"). }
  TD3ScriptObject = class
    Typ: TD3ScriptType;
    Fields: TD3ValueArray;
    constructor Create(const AType: TD3ScriptType);
  end;

  TD3ScriptThreadState = (tsRunning, tsWaitTime, tsWaitFrame, tsWaitEntity,
    tsWaitThread, tsDone);

  TD3ScriptFrame = record
    Func: TD3ScriptFunction;
    ReturnPC, Base: Integer;
    Self: Integer;
  end;

  TD3ScriptVM = class;

  TD3ScriptThread = class
  private
    Stack: TD3ValueArray;
    Top: Integer;
    Frames: array of TD3ScriptFrame;
    FrameCount: Integer;
    PC: Integer;
    WaitUntil: Single;
    WaitEntity, WaitThread: Integer;
    procedure Push(const V: TD3Value);
    function Pop: TD3Value;
  public
    Number: Integer;
    Name: String;
    State: TD3ScriptThreadState;
    { Kept when done (not freed by Update), to be restarted
      (TD3ScriptVM.RestartThread): an actor's state threads. }
    Persistent: Boolean;
    { For the host: the entity (actor) and animation channel it runs for. }
    Tag, Channel: Integer;
    { Stop running for this frame (host events changing the thread's
      function, like an actor's setState). }
    procedure Yield;
    { Wait until TD3ScriptHost.EntityBusy(E) is false (sys.waitFor). }
    procedure WaitFor(const E: Integer);
    property FrameDepth: Integer read FrameCount;
  end;

  { What the game provides to scripts. Entity handles are > 0. }
  TD3ScriptHost = class
  public
    { $name: the entity handle, 0 if there's none. }
    function FindEntity(const AName: String): Integer; virtual; abstract;
    function EntityName(const E: Integer): String; virtual;
    { The script object of an entity, nil if none. }
    function EntityObject(const E: Integer): TD3ScriptObject; virtual;
    { sys.waitFor: is the entity (a mover) still moving? }
    function EntityBusy(const E: Integer): Boolean; virtual;
    { Run an event on an entity (Target > 0) or sys (Target = 0). Result
      is preset to the event's return type default. False if the event isn't
      implemented (the VM logs it once). }
    function CallEvent(const Thread: TD3ScriptThread; const Target: Integer;
      const Event: TD3ScriptEvent; const Args: TD3ValueArray;
      var EventResult: TD3Value): Boolean; virtual;
    { sys.print / println }
    procedure Print(const S: String); virtual;
  end;

  TD3ScriptLoader = function (const APath: String; out Text: String): Boolean of object;

  { The compiled program and its threads. }
  TD3ScriptVM = class
  private
    FTypes: specialize TObjectDictionary<String, TD3ScriptType>;
    FFunctions: specialize TObjectList<TD3ScriptFunction>;
    FEvents: specialize TObjectDictionary<String, TD3ScriptEvent>;
    { global names (with namespaces) to TD3ScriptFunction or a global index }
    FGlobalNames: specialize TDictionary<String, Integer>;
    FFunctionNames: specialize TDictionary<String, TD3ScriptFunction>;
    FGlobalTypes: specialize TList<TD3ScriptType>;
    FGlobals: TD3ValueArray;
    FConsts: TD3ValueArray;
    FConstCount: Integer;
    FCode: array of TD3Instr;
    FCodeCount: Integer;
    FThreads: specialize TObjectList<TD3ScriptThread>;
    FNextThread: Integer;
    FHost: TD3ScriptHost;
    FTime: Single;
    FReported: specialize TDictionary<String, Boolean>;
    FLoader: TD3ScriptLoader;
    FCompiled: Boolean;
    FFileCount: Integer;
    FCurrent: TD3ScriptThread;
    { #defines, kept for the files compiled later (a TMacroTable) }
    FMacros: TObject;
    procedure Emit(const Op: TD3Op; const A: Integer = 0; const B: Integer = 0);
    function AddConst(const V: TD3Value): Integer;
    procedure Execute(const T: TD3ScriptThread);
    function SysEvent(const T: TD3ScriptThread; const Target: Integer;
      const Ev: TD3ScriptEvent; const Args: TD3ValueArray; var R: TD3Value): Boolean;
    procedure ReportOnce(const Msg: String);
    function NewThread(const F: TD3ScriptFunction; const ASelf: Integer;
      const Args: TD3ValueArray): TD3ScriptThread;
    function Ready(const T: TD3ScriptThread): Boolean;
    function DefaultLoader(const APath: String; out Text: String): Boolean;
  public
    TypeVoid, TypeFloat, TypeBoolean, TypeVector, TypeString, TypeEntity: TD3ScriptType;
    constructor Create;
    destructor Destroy; override;
    { Compile files into the program (call before running anything; later
      files see earlier definitions). Raises ED3ScriptError. }
    procedure CompileFile(const APath: String);
    procedure CompileText(const AText, AFileName: String);
    function FindFunction(const AName: String): TD3ScriptFunction;
    function FindEvent(const AName: String): TD3ScriptEvent;
    function FindType(const AName: String): TD3ScriptType;
    { Start a thread running F (with Self for methods); it runs at once
      until it waits or ends. Returns the thread (nil if it already ended). }
    function StartThread(const F: TD3ScriptFunction; const ASelf: Integer = 0): TD3ScriptThread; overload;
    function StartThread(const F: TD3ScriptFunction; const ASelf: Integer;
      const Args: TD3ValueArray): TD3ScriptThread; overload;
    { Start a thread on the next Update (like idThread::DelayedStart). }
    function QueueThread(const F: TD3ScriptFunction; const ASelf: Integer = 0): TD3ScriptThread;
    { A thread that is kept when it ends (Persistent), not running yet. }
    function NewPersistentThread(const AName: String): TD3ScriptThread;
    { Run F (from the start, with ASelf) in T on the next Update, dropping
      what T was doing. Not for the thread that is running now. }
    procedure RestartThread(const T: TD3ScriptThread; const F: TD3ScriptFunction; const ASelf: Integer);
    { Remove a thread (persistent ones too). }
    procedure FreeThread(const T: TD3ScriptThread);
    { Run the threads that are done waiting. }
    procedure Update(const ATime: Single);
    procedure KillThreads;
    function GlobalValue(const AName: String): TD3Value;
    function FunctionCount: Integer;
    function ThreadCount: Integer;
    function ThreadByNumber(const N: Integer): TD3ScriptThread;
    property Host: TD3ScriptHost read FHost write FHost;
    property Loader: TD3ScriptLoader read FLoader write FLoader;
    property Time: Single read FTime;
    property Compiled: Boolean read FCompiled;
    property FileCount: Integer read FFileCount;
    property EventsTable: specialize TObjectDictionary<String, TD3ScriptEvent> read FEvents;
    { for the compiler }
    property Types: specialize TObjectDictionary<String, TD3ScriptType> read FTypes;
  end;

function D3FloatValue(const F: Single): TD3Value;
function D3StringValue(const S: String): TD3Value;
function D3VectorValue(const V: TVector3): TD3Value;
function D3EntityValue(const E: Integer): TD3Value;
function D3ValueToString(const V: TD3Value): String;
function D3ValueToFloat(const V: TD3Value): Single;
{ Like idStr's float conversion: no trailing zeros. }
function D3FloatToStr(const F: Single): String;

implementation

uses
  Math, CastleLog, Doom3Files;

const
  MaxInstructionsPerUpdate = 1000000;

{ values --------------------------------------------------------------------- }

function D3FloatValue(const F: Single): TD3Value;
begin
  Result := Default(TD3Value);
  Result.Kind := sbFloat;
  Result.F := F;
end;

function D3StringValue(const S: String): TD3Value;
begin
  Result := Default(TD3Value);
  Result.Kind := sbString;
  Result.S := S;
end;

function D3VectorValue(const V: TVector3): TD3Value;
begin
  Result := Default(TD3Value);
  Result.Kind := sbVector;
  Result.V := V;
end;

function D3EntityValue(const E: Integer): TD3Value;
begin
  Result := Default(TD3Value);
  Result.Kind := sbEntity;
  Result.E := E;
end;

function D3FloatToStr(const F: Single): String;
begin
  if (Abs(F) < 1e9) and (F = Round(F)) then
    Result := IntToStr(Round(F))
  else
    Result := FormatFloat('0.######', F, DefaultFormatSettings);
  if Result = '-0' then
    Result := '0';
end;

function D3ValueToString(const V: TD3Value): String;
begin
  case V.Kind of
    sbString: Result := V.S;
    sbVector: Result := D3FloatToStr(V.V.X) + ' ' + D3FloatToStr(V.V.Y) + ' ' + D3FloatToStr(V.V.Z);
    sbEntity: Result := IntToStr(V.E);
    else Result := D3FloatToStr(V.F);
  end;
end;

function D3ValueToFloat(const V: TD3Value): Single;
begin
  case V.Kind of
    sbString: Result := StrToFloatDef(V.S, 0, DefaultFormatSettings);
    sbVector: Result := V.V.Length;
    sbEntity: Result := V.E;
    else Result := V.F;
  end;
end;

function DefaultValue(const T: TD3ScriptType): TD3Value;
begin
  Result := Default(TD3Value);
  if T = nil then
    Result.Kind := sbFloat
  else
    case T.Base of
      sbVector: Result.Kind := sbVector;
      sbString: Result.Kind := sbString;
      sbEntity, sbObject: Result.Kind := sbEntity;
      else Result.Kind := sbFloat;
    end;
end;

function ConvertValue(const V: TD3Value; const Base: TD3ScriptBase): TD3Value;
begin
  case Base of
    sbFloat, sbBoolean:
      if V.Kind = sbFloat then
        Result := V
      else
        Result := D3FloatValue(D3ValueToFloat(V));
    sbString:
      if V.Kind = sbString then
        Result := V
      else
        Result := D3StringValue(D3ValueToString(V));
    sbVector:
      if V.Kind = sbVector then
        Result := V
      else
      if V.Kind = sbString then
        Result := D3VectorValue(Vector3(0, 0, 0)) // not used by scripts
      else
        Result := D3VectorValue(Vector3(V.F, V.F, V.F));
    sbEntity, sbObject:
      if V.Kind = sbEntity then
        Result := V
      else
        Result := D3EntityValue(Round(D3ValueToFloat(V)));
    else
      Result := V;
  end;
end;

function Truthy(const V: TD3Value): Boolean;
begin
  case V.Kind of
    sbString: Result := V.S <> '';
    sbVector: Result := not V.V.IsPerfectlyZero;
    sbEntity: Result := V.E <> 0;
    else Result := V.F <> 0;
  end;
end;

{ TD3ScriptType -------------------------------------------------------------- }

constructor TD3ScriptType.Create(const ABase: TD3ScriptBase; const AName: String);
begin
  inherited Create;
  Base := ABase;
  Name := AName;
  if Base = sbObject then
  begin
    Fields := specialize TDictionary<String, Integer>.Create;
    FieldTypes := specialize TList<TD3ScriptType>.Create;
    Methods := specialize TDictionary<String, TD3ScriptFunction>.Create;
  end;
end;

destructor TD3ScriptType.Destroy;
begin
  FreeAndNil(Fields);
  FreeAndNil(FieldTypes);
  FreeAndNil(Methods);
  inherited;
end;

function TD3ScriptType.FindField(const AName: String; out Index: Integer): Boolean;
begin
  Result := (Fields <> nil) and Fields.TryGetValue(AName, Index);
end;

function TD3ScriptType.FindMethodToRun(const AName: String): TD3ScriptFunction;
var
  T: TD3ScriptType;
begin
  T := Self;
  while T <> nil do
  begin
    if (T.Methods <> nil) and T.Methods.TryGetValue(AName, Result) and
       (Result.Address >= 0) then
      Exit;
    T := T.Parent;
  end;
  Result := nil;
end;

function TD3ScriptType.FindMethod(const AName: String): TD3ScriptFunction;
var
  T: TD3ScriptType;
begin
  T := Self;
  while T <> nil do
  begin
    if (T.Methods <> nil) and T.Methods.TryGetValue(AName, Result) then
      Exit;
    T := T.Parent;
  end;
  Result := nil;
end;

function TD3ScriptType.IsA(const T: TD3ScriptType): Boolean;
var
  P: TD3ScriptType;
begin
  P := Self;
  while P <> nil do
  begin
    if P = T then
      Exit(True);
    P := P.Parent;
  end;
  Result := False;
end;

constructor TD3ScriptObject.Create(const AType: TD3ScriptType);
var
  I: Integer;
begin
  inherited Create;
  Typ := AType;
  SetLength(Fields, AType.FieldTypes.Count);
  for I := 0 to High(Fields) do
    Fields[I] := DefaultValue(AType.FieldTypes[I]);
end;

{ TD3ScriptThread ------------------------------------------------------------ }

procedure TD3ScriptThread.Yield;
begin
  if State = tsRunning then
    State := tsWaitFrame;
end;

procedure TD3ScriptThread.WaitFor(const E: Integer);
begin
  State := tsWaitEntity;
  WaitEntity := E;
end;

procedure TD3ScriptThread.Push(const V: TD3Value);
begin
  if Top >= Length(Stack) then
    SetLength(Stack, Length(Stack) * 2 + 64);
  Stack[Top] := V;
  Inc(Top);
end;

function TD3ScriptThread.Pop: TD3Value;
begin
  Dec(Top);
  Result := Stack[Top];
end;

{ TD3ScriptHost -------------------------------------------------------------- }

function TD3ScriptHost.EntityName(const E: Integer): String;
begin
  Result := IntToStr(E);
end;

function TD3ScriptHost.EntityObject(const E: Integer): TD3ScriptObject;
begin
  Result := nil;
end;

function TD3ScriptHost.EntityBusy(const E: Integer): Boolean;
begin
  Result := False;
end;

function TD3ScriptHost.CallEvent(const Thread: TD3ScriptThread; const Target: Integer;
  const Event: TD3ScriptEvent; const Args: TD3ValueArray; var EventResult: TD3Value): Boolean;
begin
  Result := False;
end;

procedure TD3ScriptHost.Print(const S: String);
begin
  WritelnLog('Script', TrimRight(S));
end;

{ Tokenizer and preprocessor ------------------------------------------------- }

type
  TTokenKind = (tkEnd, tkName, tkNumber, tkString, tkVector, tkPunct);

  TToken = record
    Kind: TTokenKind;
    Text: String;
    Num: Single;
    Vec: TVector3;
    { first token on its line (for # directives) }
    LineStart: Boolean;
    Line, Col: Integer;
    FileName: String;
  end;
  TTokenArray = array of TToken;

  TMacro = class
    Params: TStringList;
    Body: TTokenArray;
    HasParams: Boolean;
    destructor Destroy; override;
  end;

  TSource = class
    Text, FileName: String;
    Pos, Line: Integer;
    AtLineStart: Boolean;
  end;

  TMacroTable = specialize TObjectDictionary<String, TMacro>;

  TScriptTokenizer = class
  strict private
    FSources: specialize TObjectList<TSource>;
    FPending: specialize TList<TToken>; // macro expansions, read first (from the end)
    FMacros: TMacroTable; // not owned
    FIncluded: TStringList;
    FCond: array of Boolean; // stack of "active" flags
    FLoader: TD3ScriptLoader;
    FFileCount: Integer;
    function RawToken(out T: TToken): Boolean;
    function SourceToken(out T: TToken): Boolean;
    procedure Directive(const Hash: TToken);
    function Active: Boolean;
    procedure ReadLineTokens(var List: TTokenArray; const Src: TSource);
    procedure Expand(const M: TMacro; const NameTok: TToken);
    function NextUnexpanded(out T: TToken): Boolean;
  public
    constructor Create(const ALoader: TD3ScriptLoader; const AMacros: TMacroTable);
    destructor Destroy; override;
    procedure PushText(const AText, AFileName: String);
    procedure Include(const APath: String; const From: TToken);
    function Next(out T: TToken): Boolean;
    procedure Error(const T: TToken; const Msg: String);
    property FileCount: Integer read FFileCount;
  end;

destructor TMacro.Destroy;
begin
  FreeAndNil(Params);
  inherited;
end;

constructor TScriptTokenizer.Create(const ALoader: TD3ScriptLoader; const AMacros: TMacroTable);
begin
  inherited Create;
  FSources := specialize TObjectList<TSource>.Create(True);
  FPending := specialize TList<TToken>.Create;
  FMacros := AMacros;
  FIncluded := TStringList.Create;
  FIncluded.Sorted := True;
  FIncluded.CaseSensitive := False;
  FLoader := ALoader;
end;

destructor TScriptTokenizer.Destroy;
begin
  FSources.Free;
  FPending.Free;
  FIncluded.Free;
  inherited;
end;

procedure TScriptTokenizer.Error(const T: TToken; const Msg: String);
begin
  raise ED3ScriptError.CreateFmt('%s(%d): %s', [T.FileName, T.Line, Msg]);
end;

procedure TScriptTokenizer.PushText(const AText, AFileName: String);
var
  Src: TSource;
begin
  Src := TSource.Create;
  Src.Text := AText;
  Src.FileName := AFileName;
  Src.Pos := 1;
  Src.Line := 1;
  Src.AtLineStart := True;
  FSources.Add(Src);
  Inc(FFileCount);
end;

procedure TScriptTokenizer.Include(const APath: String; const From: TToken);
var
  Text, P: String;
begin
  P := NormalizeD3Path(APath);
  if FIncluded.IndexOf(P) >= 0 then
    Exit;
  FIncluded.Add(P);
  if not FLoader(P, Text) then
    Error(From, Format('Cannot include "%s"', [APath]));
  PushText(Text, P);
end;

function TScriptTokenizer.Active: Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FCond) do
    if not FCond[I] then
      Exit(False);
  Result := True;
end;

{ One token from the innermost source, or False at its end. }
function TScriptTokenizer.RawToken(out T: TToken): Boolean;
const
  Puncts: array [0 .. 16] of String = ('::', '==', '!=', '<=', '>=', '&&', '||',
    '++', '--', '+=', '-=', '*=', '/=', '%=', '&=', '|=', '<<');
var
  Src: TSource;
  Len, Start, I: Integer;
  C: Char;
  S, Two: String;
  Parts: TStringArray;
begin
  T := Default(TToken);
  Src := FSources.Last;
  Len := Length(Src.Text);
  { white space and comments }
  while Src.Pos <= Len do
  begin
    C := Src.Text[Src.Pos];
    if C = #10 then
    begin
      Inc(Src.Line);
      Src.AtLineStart := True;
      Inc(Src.Pos);
    end else
    if C <= ' ' then
      Inc(Src.Pos)
    else
    if (C = '/') and (Src.Pos < Len) and (Src.Text[Src.Pos + 1] = '/') then
    begin
      while (Src.Pos <= Len) and (Src.Text[Src.Pos] <> #10) do
        Inc(Src.Pos);
    end else
    if (C = '/') and (Src.Pos < Len) and (Src.Text[Src.Pos + 1] = '*') then
    begin
      Inc(Src.Pos, 2);
      while (Src.Pos < Len) and not ((Src.Text[Src.Pos] = '*') and (Src.Text[Src.Pos + 1] = '/')) do
      begin
        if Src.Text[Src.Pos] = #10 then
          Inc(Src.Line);
        Inc(Src.Pos);
      end;
      Inc(Src.Pos, 2);
    end else
      Break;
  end;
  if Src.Pos > Len then
    Exit(False);
  Result := True;
  T.Line := Src.Line;
  T.Col := Src.Pos;
  T.FileName := Src.FileName;
  T.LineStart := Src.AtLineStart;
  Src.AtLineStart := False;
  C := Src.Text[Src.Pos];
  Start := Src.Pos;
  if C in ['A'..'Z', 'a'..'z', '_'] then
  begin
    while (Src.Pos <= Len) and (Src.Text[Src.Pos] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) do
      Inc(Src.Pos);
    T.Kind := tkName;
    T.Text := Copy(Src.Text, Start, Src.Pos - Start);
  end else
  if (C in ['0'..'9']) or ((C = '.') and (Src.Pos < Len) and (Src.Text[Src.Pos + 1] in ['0'..'9'])) then
  begin
    if (C = '0') and (Src.Pos < Len) and (Src.Text[Src.Pos + 1] in ['x', 'X']) then
    begin
      Inc(Src.Pos, 2);
      while (Src.Pos <= Len) and (Src.Text[Src.Pos] in ['0'..'9', 'a'..'f', 'A'..'F']) do
        Inc(Src.Pos);
      T.Text := Copy(Src.Text, Start, Src.Pos - Start);
      T.Num := StrToInt('$' + Copy(T.Text, 3, MaxInt));
    end else
    begin
      while (Src.Pos <= Len) and (Src.Text[Src.Pos] in ['0'..'9', '.']) do
        Inc(Src.Pos);
      T.Text := Copy(Src.Text, Start, Src.Pos - Start);
      T.Num := StrToFloatDef(T.Text, 0, DefaultFormatSettings);
      if (Src.Pos <= Len) and (Src.Text[Src.Pos] in ['f', 'F']) then
        Inc(Src.Pos);
    end;
    T.Kind := tkNumber;
  end else
  if C = '"' then
  begin
    Inc(Src.Pos);
    S := '';
    while (Src.Pos <= Len) and (Src.Text[Src.Pos] <> '"') do
    begin
      C := Src.Text[Src.Pos];
      if (C = '\') and (Src.Pos < Len) then
      begin
        Inc(Src.Pos);
        case Src.Text[Src.Pos] of
          'n': S := S + #10;
          't': S := S + #9;
          else S := S + Src.Text[Src.Pos];
        end;
      end else
      begin
        if C = #10 then
          Inc(Src.Line);
        S := S + C;
      end;
      Inc(Src.Pos);
    end;
    Inc(Src.Pos);
    T.Kind := tkString;
    T.Text := S;
  end else
  if C = '''' then
  begin
    Inc(Src.Pos);
    while (Src.Pos <= Len) and (Src.Text[Src.Pos] <> '''') do
      Inc(Src.Pos);
    T.Kind := tkVector;
    T.Text := Copy(Src.Text, Start + 1, Src.Pos - Start - 1);
    Inc(Src.Pos);
    Parts := T.Text.Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
    for I := 0 to Min(2, High(Parts)) do
      T.Vec.Data[I] := StrToFloatDef(Parts[I], 0, DefaultFormatSettings);
  end else
  begin
    T.Kind := tkPunct;
    Two := Copy(Src.Text, Src.Pos, 2);
    for I := 0 to High(Puncts) do
      if Two = Puncts[I] then
      begin
        T.Text := Two;
        Inc(Src.Pos, 2);
        Exit;
      end;
    T.Text := C;
    Inc(Src.Pos);
  end;
end;

{ A token from the sources (popping finished includes), directives handled. }
function TScriptTokenizer.SourceToken(out T: TToken): Boolean;
begin
  repeat
    if FSources.Count = 0 then
      Exit(False);
    if not RawToken(T) then
    begin
      FSources.Delete(FSources.Count - 1);
      Continue;
    end;
    if (T.Kind = tkPunct) and (T.Text = '#') and T.LineStart then
    begin
      Directive(T);
      Continue;
    end;
    if Active then
      Exit(True);
  until False;
end;

{ The rest of the current line as tokens (for #define). }
procedure TScriptTokenizer.ReadLineTokens(var List: TTokenArray; const Src: TSource);
var
  T: TToken;
  Len: Integer;
begin
  Len := Length(Src.Text);
  repeat
    { stop at the end of the line, unless it's continued with a backslash }
    while (Src.Pos <= Len) and (Src.Text[Src.Pos] in [' ', #9, #13]) do
      Inc(Src.Pos);
    if (Src.Pos <= Len) and (Src.Text[Src.Pos] = '\') then
    begin
      Inc(Src.Pos);
      while (Src.Pos <= Len) and (Src.Text[Src.Pos] in [' ', #9, #13]) do
        Inc(Src.Pos);
      if (Src.Pos <= Len) and (Src.Text[Src.Pos] = #10) then
      begin
        Inc(Src.Pos);
        Inc(Src.Line);
      end;
      Continue;
    end;
    if (Src.Pos > Len) or (Src.Text[Src.Pos] = #10) then
      Break;
    if (Src.Pos < Len) and (Src.Text[Src.Pos] = '/') and (Src.Text[Src.Pos + 1] = '/') then
      Break;
    if (Src.Pos < Len) and (Src.Text[Src.Pos] = '/') and (Src.Text[Src.Pos + 1] = '*') then
    begin
      { a comment inside the line: skip it (RawToken does, then we go on) }
      Inc(Src.Pos, 2);
      while (Src.Pos < Len) and not ((Src.Text[Src.Pos] = '*') and (Src.Text[Src.Pos + 1] = '/')) do
      begin
        if Src.Text[Src.Pos] = #10 then
          Inc(Src.Line);
        Inc(Src.Pos);
      end;
      Inc(Src.Pos, 2);
      Continue;
    end;
    if not RawToken(T) then
      Break;
    SetLength(List, Length(List) + 1);
    List[High(List)] := T;
  until False;
end;

procedure TScriptTokenizer.Directive(const Hash: TToken);
var
  Src: TSource;
  NameTok, T: TToken;
  Line: TTokenArray;
  M: TMacro;
  I, Start: Integer;
begin
  Src := FSources.Last;
  if not RawToken(NameTok) then
    Exit;
  Line := nil;
  ReadLineTokens(Line, Src);
  if NameTok.Text = 'endif' then
  begin
    if Length(FCond) > 0 then
      SetLength(FCond, Length(FCond) - 1);
  end else
  if NameTok.Text = 'else' then
  begin
    if Length(FCond) > 0 then
      FCond[High(FCond)] := not FCond[High(FCond)];
  end else
  if (NameTok.Text = 'ifdef') or (NameTok.Text = 'ifndef') then
  begin
    SetLength(FCond, Length(FCond) + 1);
    FCond[High(FCond)] := (Length(Line) > 0) and
      (FMacros.ContainsKey(Line[0].Text) = (NameTok.Text = 'ifdef'));
  end else
  if NameTok.Text = 'if' then
  begin
    SetLength(FCond, Length(FCond) + 1);
    FCond[High(FCond)] := (Length(Line) > 0) and (Line[0].Kind = tkNumber) and (Line[0].Num <> 0);
  end else
  if not Active then
    Exit
  else
  if NameTok.Text = 'include' then
  begin
    if (Length(Line) > 0) and (Line[0].Kind = tkString) then
      Include(Line[0].Text, NameTok);
  end else
  if NameTok.Text = 'undef' then
  begin
    if Length(Line) > 0 then
      FMacros.Remove(Line[0].Text);
  end else
  if NameTok.Text = 'define' then
  begin
    if (Length(Line) = 0) or (Line[0].Kind <> tkName) then
      Error(NameTok, '#define without a name');
    M := TMacro.Create;
    Start := 1;
    { parameters: "(" right after the name (no space) }
    if (Length(Line) > 1) and (Line[1].Text = '(') and (Line[1].Kind = tkPunct) and
       (Line[1].Col = Line[0].Col + Length(Line[0].Text)) then
    begin
      M.HasParams := True;
      M.Params := TStringList.Create;
      I := 2;
      while (I < Length(Line)) and (Line[I].Text <> ')') do
      begin
        if Line[I].Kind = tkName then
          M.Params.Add(Line[I].Text);
        Inc(I);
      end;
      Start := I + 1;
    end;
    for I := Start to High(Line) do
    begin
      T := Line[I];
      SetLength(M.Body, Length(M.Body) + 1);
      M.Body[High(M.Body)] := T;
    end;
    FMacros.AddOrSetValue(Line[0].Text, M);
  end;
  { other directives (#pragma ...) are ignored }
end;

function TScriptTokenizer.NextUnexpanded(out T: TToken): Boolean;
begin
  if FPending.Count > 0 then
  begin
    T := FPending.Last;
    FPending.Delete(FPending.Count - 1);
    Exit(True);
  end;
  Result := SourceToken(T);
end;

procedure TScriptTokenizer.Expand(const M: TMacro; const NameTok: TToken);
var
  Args: array of TTokenArray;
  T: TToken;
  Depth, I, J, P: Integer;
  Output: TTokenArray;
begin
  Args := nil;
  if M.HasParams then
  begin
    if not NextUnexpanded(T) or (T.Text <> '(') then
      Error(NameTok, 'Macro without arguments');
    SetLength(Args, 1);
    Depth := 0;
    repeat
      if not NextUnexpanded(T) then
        Error(NameTok, 'Macro arguments not closed');
      if (T.Kind = tkPunct) and (T.Text = '(') then
        Inc(Depth)
      else
      if (T.Kind = tkPunct) and (T.Text = ')') then
      begin
        if Depth = 0 then
          Break;
        Dec(Depth);
      end else
      if (T.Kind = tkPunct) and (T.Text = ',') and (Depth = 0) then
      begin
        SetLength(Args, Length(Args) + 1);
        Continue;
      end;
      SetLength(Args[High(Args)], Length(Args[High(Args)]) + 1);
      Args[High(Args)][High(Args[High(Args)])] := T;
    until False;
  end;
  Output := nil;
  for I := 0 to High(M.Body) do
  begin
    T := M.Body[I];
    P := -1;
    if M.HasParams and (T.Kind = tkName) then
      P := M.Params.IndexOf(T.Text);
    if (P >= 0) and (P < Length(Args)) then
    begin
      for J := 0 to High(Args[P]) do
      begin
        SetLength(Output, Length(Output) + 1);
        Output[High(Output)] := Args[P][J];
      end;
    end else
    begin
      T.Line := NameTok.Line;
      T.FileName := NameTok.FileName;
      SetLength(Output, Length(Output) + 1);
      Output[High(Output)] := T;
    end;
  end;
  { pending is read from its end }
  for I := High(Output) downto 0 do
  begin
    Output[I].LineStart := False;
    FPending.Add(Output[I]);
  end;
end;

function TScriptTokenizer.Next(out T: TToken): Boolean;
var
  M: TMacro;
  Guard: Integer;
begin
  Guard := 0;
  repeat
    if not NextUnexpanded(T) then
    begin
      T := Default(TToken);
      T.Kind := tkEnd;
      Exit(False);
    end;
    if (T.Kind = tkName) and FMacros.TryGetValue(T.Text, M) then
    begin
      Inc(Guard);
      if Guard > 10000 then
        Error(T, 'Recursive macro ' + T.Text);
      Expand(M, T);
      Continue;
    end;
    Exit(True);
  until False;
end;

{ Compiler ------------------------------------------------------------------- }

type
  TOperandKind = (okValue, okGlobal, okLocal, okField, okSelfField, okVoid);

  { An expression while compiling: a value on the stack, or something
    assignable that isn't loaded yet (okField: its entity is on the stack). }
  TOperand = record
    Kind: TOperandKind;
    Index, Comp: Integer;
    Typ: TD3ScriptType;
  end;

  TScope = specialize TDictionary<String, Integer>;

  TLoopInfo = record
    BreakJumps, ContinueJumps: array of Integer;
  end;

  TScriptCompiler = class
  strict private
    VM: TD3ScriptVM;
    Tok: TScriptTokenizer;
    Cur, Ahead: TToken;
    HasAhead: Boolean;
    Namespaces: TStringList;
    Scopes: specialize TObjectList<TScope>;
    Func: TD3ScriptFunction;
    Loops: array of TLoopInfo;
    FThreadPrefix: Boolean;
    procedure Advance;
    function PeekToken: TToken;
    procedure Error(const Msg: String);
    function IsP(const S: String): Boolean;
    function AcceptP(const S: String): Boolean;
    procedure ExpectP(const S: String);
    function ExpectName: String;
    function TryType(out T: TD3ScriptType): Boolean;
    function ScopedName(const AName: String): String;
    function LookupGlobal(const AName: String; out Index: Integer): Boolean;
    function LookupFunction(const AName: String): TD3ScriptFunction;
    function LookupLocal(const AName: String; out Index: Integer): Boolean;
    procedure ParseDefinition;
    procedure ParseObject;
    procedure ParseEventDef;
    procedure ParseParams(out Types: specialize TArray<TD3ScriptType>; out Names: TStringArray);
    procedure ParseFunctionBody(const F: TD3ScriptFunction; const Names: TStringArray);
    function DeclareFunction(const FullName: String; const Ret: TD3ScriptType;
      const Params: specialize TArray<TD3ScriptType>; const Obj: TD3ScriptType): TD3ScriptFunction;
    procedure ParseGlobals(const T: TD3ScriptType; const FirstName: String);
    function ConstantValue(const T: TD3ScriptType): TD3Value;
    { statements }
    procedure ParseStatement;
    procedure ParseBlock;
    procedure ParseLocals(const T: TD3ScriptType);
    function AddLocal(const AName: String; const T: TD3ScriptType): Integer;
    { expressions }
    function Expression(const Priority: Integer): TOperand;
    function Term: TOperand;
    function Postfix(Op: TOperand): TOperand;
    function NameTerm(const AName: String; const IsThread: Boolean): TOperand;
    procedure Load(var Op: TOperand);
    procedure StoreKeep(const Target: TOperand);
    procedure LoadForUpdate(const Op: TOperand);
    procedure ConvertTo(var Op: TOperand; const T: TD3ScriptType);
    function CallArgs(const Params: array of TD3ScriptType): Integer;
    function CallFunction(const F: TD3ScriptFunction; const IsThread: Boolean): TOperand;
    function CallEvent(const Ev: TD3ScriptEvent; const OnSys: Boolean): TOperand;
    function CallMethod(const F: TD3ScriptFunction; const IsThread: Boolean): TOperand;
    function Member(Obj: TOperand; const IsThread: Boolean): TOperand;
    function BinaryType(const Op: String; const A, B: TD3ScriptType): TD3ScriptType;
    function ValueOp(const T: TD3ScriptType): TOperand;
    procedure ExpressionStatement;
    function CodePos: Integer;
    procedure Patch(const At, Target: Integer);
    function EmitJump(const Op: TD3Op): Integer;
    function SelfType: TD3ScriptType;
  public
    constructor Create(const AVM: TD3ScriptVM; const ATok: TScriptTokenizer);
    destructor Destroy; override;
    procedure CompileAll;
  end;


constructor TScriptCompiler.Create(const AVM: TD3ScriptVM; const ATok: TScriptTokenizer);
begin
  inherited Create;
  VM := AVM;
  Tok := ATok;
  Namespaces := TStringList.Create;
  Scopes := specialize TObjectList<TScope>.Create(True);
end;

destructor TScriptCompiler.Destroy;
begin
  Namespaces.Free;
  Scopes.Free;
  inherited;
end;

procedure TScriptCompiler.Advance;
begin
  if HasAhead then
  begin
    Cur := Ahead;
    HasAhead := False;
  end else
    Tok.Next(Cur);
end;

function TScriptCompiler.PeekToken: TToken;
begin
  if not HasAhead then
  begin
    Tok.Next(Ahead);
    HasAhead := True;
  end;
  Result := Ahead;
end;

procedure TScriptCompiler.Error(const Msg: String);
begin
  Tok.Error(Cur, Msg + ' (at "' + Cur.Text + '")');
end;

function TScriptCompiler.IsP(const S: String): Boolean;
begin
  Result := (Cur.Kind = tkPunct) and (Cur.Text = S);
end;

function TScriptCompiler.AcceptP(const S: String): Boolean;
begin
  Result := IsP(S);
  if Result then
    Advance;
end;

procedure TScriptCompiler.ExpectP(const S: String);
begin
  if not AcceptP(S) then
    Error('Expected "' + S + '"');
end;

function TScriptCompiler.ExpectName: String;
begin
  if Cur.Kind <> tkName then
    Error('Expected a name');
  Result := Cur.Text;
  Advance;
end;

function TScriptCompiler.TryType(out T: TD3ScriptType): Boolean;
begin
  Result := (Cur.Kind = tkName) and VM.Types.TryGetValue(Cur.Text, T);
  if Result then
    Advance;
end;

function TScriptCompiler.ScopedName(const AName: String): String;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to Namespaces.Count - 1 do
    Result := Result + Namespaces[I] + '::';
  Result := Result + AName;
end;

function TScriptCompiler.LookupGlobal(const AName: String; out Index: Integer): Boolean;
var
  I, J: Integer;
  Prefix: String;
begin
  for I := Namespaces.Count downto 0 do
  begin
    Prefix := '';
    for J := 0 to I - 1 do
      Prefix := Prefix + Namespaces[J] + '::';
    if VM.FGlobalNames.TryGetValue(Prefix + AName, Index) then
      Exit(True);
  end;
  Result := False;
end;

function TScriptCompiler.LookupFunction(const AName: String): TD3ScriptFunction;
var
  I, J: Integer;
  Prefix: String;
begin
  for I := Namespaces.Count downto 0 do
  begin
    Prefix := '';
    for J := 0 to I - 1 do
      Prefix := Prefix + Namespaces[J] + '::';
    if VM.FFunctionNames.TryGetValue(Prefix + AName, Result) then
      Exit;
  end;
  Result := nil;
end;

function TScriptCompiler.LookupLocal(const AName: String; out Index: Integer): Boolean;
var
  I: Integer;
begin
  for I := Scopes.Count - 1 downto 0 do
    if Scopes[I].TryGetValue(AName, Index) then
      Exit(True);
  Result := False;
end;

function TScriptCompiler.CodePos: Integer;
begin
  Result := VM.FCodeCount;
end;

procedure TScriptCompiler.Patch(const At, Target: Integer);
begin
  VM.FCode[At].A := Target;
end;

function TScriptCompiler.EmitJump(const Op: TD3Op): Integer;
begin
  Result := CodePos;
  VM.Emit(Op, -1);
end;

function TScriptCompiler.SelfType: TD3ScriptType;
begin
  if Func <> nil then
    Result := Func.Obj
  else
    Result := nil;
end;

procedure TScriptCompiler.CompileAll;
begin
  Advance;
  while Cur.Kind <> tkEnd do
    ParseDefinition;
end;

procedure TScriptCompiler.ParseParams(out Types: specialize TArray<TD3ScriptType>; out Names: TStringArray);
var
  T: TD3ScriptType;
begin
  Types := nil;
  Names := nil;
  ExpectP('(');
  if not IsP(')') then
    repeat
      if not TryType(T) then
        Error('Expected a parameter type');
      if T = VM.TypeVoid then
        Break; // "( void )"
      SetLength(Types, Length(Types) + 1);
      Types[High(Types)] := T;
      SetLength(Names, Length(Names) + 1);
      if Cur.Kind = tkName then
        Names[High(Names)] := ExpectName
      else
        Names[High(Names)] := '';
    until not AcceptP(',');
  ExpectP(')');
end;

function TScriptCompiler.DeclareFunction(const FullName: String; const Ret: TD3ScriptType;
  const Params: specialize TArray<TD3ScriptType>; const Obj: TD3ScriptType): TD3ScriptFunction;
var
  I: Integer;
begin
  if VM.FFunctionNames.TryGetValue(FullName, Result) then
    Exit;
  Result := TD3ScriptFunction.Create;
  Result.Name := FullName;
  Result.ReturnType := Ret;
  SetLength(Result.ParamTypes, Length(Params));
  for I := 0 to High(Params) do
    Result.ParamTypes[I] := Params[I];
  Result.Address := -1;
  Result.Obj := Obj;
  VM.FFunctions.Add(Result);
  VM.FFunctionNames.Add(FullName, Result);
end;

procedure TScriptCompiler.ParseDefinition;
var
  T, ObjType: TD3ScriptType;
  AName, MemberName: String;
  Params: specialize TArray<TD3ScriptType>;
  Names: TStringArray;
  F: TD3ScriptFunction;
begin
  if AcceptP(';') then
    Exit;
  if (Cur.Kind = tkName) and (Cur.Text = 'namespace') then
  begin
    Advance;
    Namespaces.Add(ExpectName);
    ExpectP('{');
    while not IsP('}') do
    begin
      if Cur.Kind = tkEnd then
        Error('Namespace not closed');
      ParseDefinition;
    end;
    ExpectP('}');
    Namespaces.Delete(Namespaces.Count - 1);
    Exit;
  end;
  if (Cur.Kind = tkName) and (Cur.Text = 'object') then
  begin
    ParseObject;
    Exit;
  end;
  if (Cur.Kind = tkName) and (Cur.Text = 'scriptEvent') then
  begin
    ParseEventDef;
    Exit;
  end;
  if not TryType(T) then
    Error('Expected a type');
  AName := ExpectName;
  { method definition: type object::name ( ... ) }
  if IsP('::') and VM.Types.TryGetValue(AName, ObjType) and (ObjType.Base = sbObject) then
  begin
    Advance;
    MemberName := ExpectName;
    ParseParams(Params, Names);
    if not ObjType.Methods.TryGetValue(MemberName, F) then
    begin
      F := DeclareFunction(AName + '::' + MemberName, T, Params, ObjType);
      ObjType.Methods.Add(MemberName, F);
    end;
    if AcceptP(';') then
      Exit;
    ParseFunctionBody(F, Names);
    Exit;
  end;
  if IsP('(') then
  begin
    ParseParams(Params, Names);
    F := DeclareFunction(ScopedName(AName), T, Params, nil);
    if AcceptP(';') then
      Exit;
    ParseFunctionBody(F, Names);
    Exit;
  end;
  ParseGlobals(T, AName);
end;

function TScriptCompiler.ConstantValue(const T: TD3ScriptType): TD3Value;
var
  Neg: Boolean;
  Index: Integer;
begin
  Neg := AcceptP('-');
  case Cur.Kind of
    tkNumber: Result := D3FloatValue(Cur.Num);
    tkString: Result := D3StringValue(Cur.Text);
    tkVector: Result := D3VectorValue(Cur.Vec);
    tkName:
      { another global (its initial value) }
      if LookupGlobal(Cur.Text, Index) then
        Result := VM.FGlobals[Index]
      else
        Error('Expected a constant');
    else
      Error('Expected a constant');
  end;
  Advance;
  if Neg then
  begin
    Result.F := -Result.F;
    Result.V := -Result.V;
  end;
  Result := ConvertValue(Result, T.Base);
end;

procedure TScriptCompiler.ParseGlobals(const T: TD3ScriptType; const FirstName: String);
var
  AName, FullName: String;
  Index: Integer;
  V: TD3Value;
  Acc: TD3ScriptVM;
begin
  Acc := VM;
  AName := FirstName;
  repeat
    if T = VM.TypeVoid then
      Error('Variable of type void');
    FullName := ScopedName(AName);
    V := DefaultValue(T);
    if AcceptP('=') then
      V := ConstantValue(T);
    if not Acc.FGlobalNames.TryGetValue(FullName, Index) then
    begin
      Index := Length(Acc.FGlobals);
      SetLength(Acc.FGlobals, Index + 1);
      Acc.FGlobalTypes.Add(T);
      Acc.FGlobalNames.Add(FullName, Index);
    end;
    Acc.FGlobals[Index] := V;
    if not AcceptP(',') then
      Break;
    AName := ExpectName;
  until False;
  ExpectP(';');
end;

procedure TScriptCompiler.ParseObject;
var
  ObjType, Parent, T: TD3ScriptType;
  AName, FieldName: String;
  Params: specialize TArray<TD3ScriptType>;
  Names: TStringArray;
  F: TD3ScriptFunction;
  Key: String;
begin
  Advance; // object
  AName := ExpectName;
  Parent := nil;
  if AcceptP(':') then
  begin
    if not VM.Types.TryGetValue(ExpectName, Parent) or (Parent.Base <> sbObject) then
      Error('Unknown parent object type');
  end;
  if VM.Types.TryGetValue(AName, ObjType) then
    Error('Object type redefined: ' + AName);
  ObjType := TD3ScriptType.Create(sbObject, AName);
  ObjType.Parent := Parent;
  if Parent <> nil then
  begin
    for Key in Parent.Fields.Keys do
      ObjType.Fields.Add(Key, Parent.Fields[Key]);
    ObjType.FieldTypes.AddRange(Parent.FieldTypes);
  end;
  VM.Types.Add(AName, ObjType);
  ExpectP('{');
  while not AcceptP('}') do
  begin
    if not TryType(T) then
      Error('Expected a field or method type');
    FieldName := ExpectName;
    if IsP('(') then
    begin
      ParseParams(Params, Names);
      F := DeclareFunction(AName + '::' + FieldName, T, Params, ObjType);
      ObjType.Methods.AddOrSetValue(FieldName, F);
      { a method can be defined in the object }
      if IsP('{') then
        ParseFunctionBody(F, Names)
      else
        ExpectP(';');
      Continue;
    end;
    repeat
      if not ObjType.Fields.ContainsKey(FieldName) then
      begin
        ObjType.Fields.Add(FieldName, ObjType.FieldTypes.Count);
        ObjType.FieldTypes.Add(T);
      end;
      if not AcceptP(',') then
        Break;
      FieldName := ExpectName;
    until False;
    ExpectP(';');
  end;
  AcceptP(';');
end;

procedure TScriptCompiler.ParseEventDef;
var
  Ev: TD3ScriptEvent;
  T: TD3ScriptType;
  AName: String;
  Params: specialize TArray<TD3ScriptType>;
  Names: TStringArray;
  I: Integer;
begin
  Advance; // scriptEvent
  if not TryType(T) then
    Error('Expected the event''s return type');
  AName := ExpectName;
  ParseParams(Params, Names);
  ExpectP(';');
  if VM.EventsTable.ContainsKey(AName) then
    Exit;
  Ev := TD3ScriptEvent.Create;
  Ev.Name := AName;
  Ev.ReturnType := T;
  SetLength(Ev.ParamTypes, Length(Params));
  for I := 0 to High(Params) do
    Ev.ParamTypes[I] := Params[I];
  VM.EventsTable.Add(AName, Ev);
end;

function TScriptCompiler.AddLocal(const AName: String; const T: TD3ScriptType): Integer;
begin
  Result := Length(Func.LocalTypes);
  SetLength(Func.LocalTypes, Result + 1);
  Func.LocalTypes[Result] := T;
  if AName <> '' then
    Scopes.Last.AddOrSetValue(AName, Result);
end;

procedure TScriptCompiler.ParseFunctionBody(const F: TD3ScriptFunction; const Names: TStringArray);
var
  I: Integer;
  Acc: TD3ScriptVM;
begin
  Acc := VM;
  if F.Address >= 0 then
    Error('Function redefined: ' + F.Name);
  Func := F;
  F.Address := CodePos;
  F.LocalTypes := nil;
  Scopes.Clear;
  Scopes.Add(TScope.Create);
  for I := 0 to High(F.ParamTypes) do
    AddLocal(Names[I], F.ParamTypes[I]);
  ParseBlock;
  { falling off the end }
  if F.ReturnType <> VM.TypeVoid then
  begin
    Acc.Emit(opPushConst, Acc.AddConst(DefaultValue(F.ReturnType)));
    Acc.Emit(opReturn, 1);
  end else
    Acc.Emit(opReturn, 0);
  Scopes.Clear;
  Func := nil;
end;

procedure TScriptCompiler.ParseBlock;
begin
  ExpectP('{');
  Scopes.Add(TScope.Create);
  while not AcceptP('}') do
  begin
    if Cur.Kind = tkEnd then
      Error('Block not closed');
    ParseStatement;
  end;
  Scopes.Delete(Scopes.Count - 1);
end;

procedure TScriptCompiler.ParseLocals(const T: TD3ScriptType);
var
  AName: String;
  Index: Integer;
  Op, Target: TOperand;
  Acc: TD3ScriptVM;
begin
  Acc := VM;
  repeat
    AName := ExpectName;
    Index := AddLocal(AName, T);
    { locals start at their default value each time the declaration runs }
    Acc.Emit(opPushConst, Acc.AddConst(DefaultValue(T)));
    if AcceptP('=') then
    begin
      Acc.Emit(opPop);
      Op := Expression(7);
      Load(Op);
      ConvertTo(Op, T);
    end;
    Target.Kind := okLocal;
    Target.Index := Index;
    Target.Comp := -1;
    Target.Typ := T;
    StoreKeep(Target);
    Acc.Emit(opPop);
  until not AcceptP(',');
  ExpectP(';');
end;

procedure TScriptCompiler.ExpressionStatement;
var
  Op: TOperand;
begin
  Op := Expression(7);
  if Op.Kind = okField then
    VM.Emit(opPop) // the entity
  else
  if Op.Kind = okValue then
    VM.Emit(opPop);
  ExpectP(';');
end;

procedure TScriptCompiler.ParseStatement;
var
  T: TD3ScriptType;
  Op: TOperand;
  JFalse, JEnd, LoopStart, ContinueTarget, I: Integer;
  Acc: TD3ScriptVM;
  Info: TLoopInfo;

  procedure Condition;
  begin
    ExpectP('(');
    Op := Expression(7);
    Load(Op);
    ExpectP(')');
  end;

  procedure BeginLoop;
  begin
    SetLength(Loops, Length(Loops) + 1);
    Loops[High(Loops)] := Default(TLoopInfo);
  end;

  procedure EndLoop(const BreakTarget, AContinueTarget: Integer);
  var
    J: Integer;
  begin
    Info := Loops[High(Loops)];
    for J := 0 to High(Info.BreakJumps) do
      Patch(Info.BreakJumps[J], BreakTarget);
    for J := 0 to High(Info.ContinueJumps) do
      Patch(Info.ContinueJumps[J], AContinueTarget);
    SetLength(Loops, Length(Loops) - 1);
  end;

var
  ForIncrement: array of TD3Instr;
  IncStart, IncEnd: Integer;
begin
  Acc := VM;
  if AcceptP(';') then
    Exit;
  if IsP('{') then
  begin
    ParseBlock;
    Exit;
  end;
  if Cur.Kind = tkName then
  begin
    if Cur.Text = 'return' then
    begin
      Advance;
      if AcceptP(';') then
      begin
        if Func.ReturnType <> VM.TypeVoid then
        begin
          Acc.Emit(opPushConst, Acc.AddConst(DefaultValue(Func.ReturnType)));
          Acc.Emit(opReturn, 1);
        end else
          Acc.Emit(opReturn, 0);
        Exit;
      end;
      Op := Expression(7);
      Load(Op);
      ExpectP(';');
      if Func.ReturnType = VM.TypeVoid then
      begin
        if Op.Kind = okValue then
          Acc.Emit(opPop);
        Acc.Emit(opReturn, 0);
      end else
      begin
        ConvertTo(Op, Func.ReturnType);
        Acc.Emit(opReturn, 1);
      end;
      Exit;
    end;
    if Cur.Text = 'if' then
    begin
      Advance;
      Condition;
      JFalse := EmitJump(opJumpFalse);
      ParseStatement;
      if (Cur.Kind = tkName) and (Cur.Text = 'else') then
      begin
        Advance;
        JEnd := EmitJump(opJump);
        Patch(JFalse, CodePos);
        ParseStatement;
        Patch(JEnd, CodePos);
      end else
        Patch(JFalse, CodePos);
      Exit;
    end;
    if Cur.Text = 'while' then
    begin
      Advance;
      LoopStart := CodePos;
      Condition;
      JFalse := EmitJump(opJumpFalse);
      BeginLoop;
      ParseStatement;
      Acc.Emit(opJump, LoopStart);
      Patch(JFalse, CodePos);
      EndLoop(CodePos, LoopStart);
      Exit;
    end;
    if Cur.Text = 'do' then
    begin
      Advance;
      LoopStart := CodePos;
      BeginLoop;
      ParseStatement;
      if (Cur.Kind <> tkName) or (Cur.Text <> 'while') then
        Error('Expected "while"');
      Advance;
      ContinueTarget := CodePos;
      Condition;
      AcceptP(';');
      JFalse := EmitJump(opJumpFalse);
      Acc.Emit(opJump, LoopStart);
      Patch(JFalse, CodePos);
      EndLoop(CodePos, ContinueTarget);
      Exit;
    end;
    if Cur.Text = 'for' then
    begin
      Advance;
      ExpectP('(');
      if not IsP(';') then
      begin
        Op := Expression(7);
        if Op.Kind in [okValue, okField] then
          Acc.Emit(opPop);
      end;
      ExpectP(';');
      LoopStart := CodePos;
      if not IsP(';') then
      begin
        Op := Expression(7);
        Load(Op);
      end else
        Acc.Emit(opPushConst, Acc.AddConst(D3FloatValue(1)));
      ExpectP(';');
      JFalse := EmitJump(opJumpFalse);
      { the increment is compiled here, then moved after the body }
      IncStart := CodePos;
      if not IsP(')') then
      begin
        Op := Expression(7);
        if Op.Kind in [okValue, okField] then
          Acc.Emit(opPop);
      end;
      ExpectP(')');
      IncEnd := CodePos;
      SetLength(ForIncrement, IncEnd - IncStart);
      for I := 0 to High(ForIncrement) do
        ForIncrement[I] := Acc.FCode[IncStart + I];
      Acc.FCodeCount := IncStart;
      BeginLoop;
      ParseStatement;
      ContinueTarget := CodePos;
      for I := 0 to High(ForIncrement) do
        Acc.Emit(ForIncrement[I].Op, ForIncrement[I].A, ForIncrement[I].B);
      Acc.Emit(opJump, LoopStart);
      Patch(JFalse, CodePos);
      EndLoop(CodePos, ContinueTarget);
      Exit;
    end;
    if (Cur.Text = 'break') or (Cur.Text = 'continue') then
    begin
      if Length(Loops) = 0 then
        Error(Cur.Text + ' outside a loop');
      if Cur.Text = 'break' then
      begin
        SetLength(Loops[High(Loops)].BreakJumps, Length(Loops[High(Loops)].BreakJumps) + 1);
        Loops[High(Loops)].BreakJumps[High(Loops[High(Loops)].BreakJumps)] := EmitJump(opJump);
      end else
      begin
        SetLength(Loops[High(Loops)].ContinueJumps, Length(Loops[High(Loops)].ContinueJumps) + 1);
        Loops[High(Loops)].ContinueJumps[High(Loops[High(Loops)].ContinueJumps)] := EmitJump(opJump);
      end;
      Advance;
      ExpectP(';');
      Exit;
    end;
    { local declaration }
    if VM.Types.TryGetValue(Cur.Text, T) and
       ((PeekToken.Kind = tkName)) then
    begin
      Advance;
      ParseLocals(T);
      Exit;
    end;
  end;
  ExpressionStatement;
end;

{ expressions }

function TScriptCompiler.ValueOp(const T: TD3ScriptType): TOperand;
begin
  Result := Default(TOperand);
  Result.Comp := -1;
  Result.Typ := T;
  if (T = nil) or (T = VM.TypeVoid) then
    Result.Kind := okVoid
  else
    Result.Kind := okValue;
end;

procedure TScriptCompiler.Load(var Op: TOperand);
var
  Acc: TD3ScriptVM;
begin
  Acc := VM;
  case Op.Kind of
    okValue: Exit;
    okVoid: Error('A void value is used');
    okGlobal: Acc.Emit(opPushGlobal, Op.Index);
    okLocal: Acc.Emit(opPushLocal, Op.Index);
    okField: Acc.Emit(opPushField, Op.Index);
    okSelfField:
      begin
        Acc.Emit(opPushSelf);
        Acc.Emit(opPushField, Op.Index);
      end;
  end;
  if Op.Comp >= 0 then
    Acc.Emit(opComp, Op.Comp);
  Op.Kind := okValue;
  Op.Comp := -1;
end;

{ Stack: [entity for okField] value -> value (stored to Target). }
procedure TScriptCompiler.StoreKeep(const Target: TOperand);
var
  Acc: TD3ScriptVM;
begin
  Acc := VM;
  if Target.Comp >= 0 then
  begin
    { a vector component: load the vector, replace it, store the vector }
    case Target.Kind of
      okGlobal: Acc.Emit(opPushGlobal, Target.Index);
      okLocal: Acc.Emit(opPushLocal, Target.Index);
      else Error('Vector component of a field can''t be assigned');
    end;
    Acc.Emit(opSetComp, Target.Comp);
    case Target.Kind of
      okGlobal: Acc.Emit(opStoreGlobal, Target.Index);
      okLocal: Acc.Emit(opStoreLocal, Target.Index);
      else ;
    end;
    Acc.Emit(opComp, Target.Comp);
    Exit;
  end;
  case Target.Kind of
    okGlobal: Acc.Emit(opStoreGlobal, Target.Index);
    okLocal: Acc.Emit(opStoreLocal, Target.Index);
    okField: Acc.Emit(opStoreField, Target.Index);
    okSelfField: Acc.Emit(opStoreField, Target.Index, 1);
    else Error('Not assignable');
  end;
end;

{ For "x op= y" / "++x": [entity] -> [entity] value-of-x }
procedure TScriptCompiler.LoadForUpdate(const Op: TOperand);
var
  Acc: TD3ScriptVM;
  Copy: TOperand;
begin
  Acc := VM;
  if Op.Kind = okField then
  begin
    Acc.Emit(opDup);
    Acc.Emit(opPushField, Op.Index);
    Exit;
  end;
  Copy := Op;
  Load(Copy);
end;

procedure TScriptCompiler.ConvertTo(var Op: TOperand; const T: TD3ScriptType);
begin
  if (T = nil) or (Op.Typ = T) then
    Exit;
  if (Op.Typ <> nil) and (Op.Typ.Base = T.Base) then
    Exit;
  if (Op.Typ <> nil) and (Op.Typ.Base in [sbFloat, sbBoolean]) and (T.Base in [sbFloat, sbBoolean]) then
    Exit;
  if (Op.Typ <> nil) and (Op.Typ.Base in [sbEntity, sbObject]) and (T.Base in [sbEntity, sbObject]) then
    Exit;
  VM.Emit(opConvert, Ord(T.Base));
  Op.Typ := T;
end;

function TScriptCompiler.BinaryType(const Op: String; const A, B: TD3ScriptType): TD3ScriptType;
var
  AB, BB: TD3ScriptBase;
begin
  AB := A.Base;
  BB := B.Base;
  if (Op = '+') and ((AB = sbString) or (BB = sbString)) then
    Exit(VM.TypeString);
  if (Op = '*') and (AB = sbVector) and (BB = sbVector) then
    Exit(VM.TypeFloat);
  if (Op = '+') or (Op = '-') or (Op = '*') or (Op = '/') then
    if (AB = sbVector) or (BB = sbVector) then
      Exit(VM.TypeVector);
  Result := VM.TypeFloat;
end;

function TScriptCompiler.Expression(const Priority: Integer): TOperand;
const
  Ops3: array [0 .. 4] of String = ('*', '/', '%', '&', '|');
  OpCodes3: array [0 .. 4] of TD3Op = (opMul, opDiv, opMod, opBitAnd, opBitOr);
var
  Acc: TD3ScriptVM;
  Right: TOperand;
  OpText: String;
  Code: TD3Op;
  I: Integer;
  Found: Boolean;
begin
  Acc := VM;
  if Priority <= 2 then
    Exit(Term);
  Result := Expression(Priority - 1);
  repeat
    if Cur.Kind <> tkPunct then
      Exit;
    OpText := Cur.Text;
    Found := False;
    Code := opAdd;
    case Priority of
      3:
        for I := 0 to High(Ops3) do
          if OpText = Ops3[I] then
          begin
            Found := True;
            Code := OpCodes3[I];
          end;
      4:
        begin
          Found := (OpText = '+') or (OpText = '-');
          if OpText = '-' then
            Code := opSub;
        end;
      5:
        begin
          Found := True;
          if OpText = '==' then Code := opEq else
          if OpText = '!=' then Code := opNe else
          if OpText = '<' then Code := opLt else
          if OpText = '<=' then Code := opLe else
          if OpText = '>' then Code := opGt else
          if OpText = '>=' then Code := opGe else
            Found := False;
        end;
      6:
        begin
          Found := (OpText = '=') or (OpText = '+=') or (OpText = '-=') or
            (OpText = '*=') or (OpText = '/=') or (OpText = '%=') or
            (OpText = '&=') or (OpText = '|=');
          if not Found then
            Exit;
          if Result.Kind in [okValue, okVoid] then
            Error('Not assignable');
          Advance;
          if OpText = '=' then
          begin
            Right := Expression(6);
            Load(Right);
          end else
          begin
            LoadForUpdate(Result);
            Right := Expression(6);
            Load(Right);
            case OpText[1] of
              '+': Code := opAdd;
              '-': Code := opSub;
              '*': Code := opMul;
              '/': Code := opDiv;
              '%': Code := opMod;
              '&': Code := opBitAnd;
              else Code := opBitOr;
            end;
            Acc.Emit(Code);
            Right.Typ := BinaryType(OpText[1], Result.Typ, Right.Typ);
          end;
          if Result.Comp >= 0 then
            ConvertTo(Right, VM.TypeFloat)
          else
            ConvertTo(Right, Result.Typ);
          StoreKeep(Result);
          if Result.Comp >= 0 then
            Exit(ValueOp(VM.TypeFloat));
          Exit(ValueOp(Result.Typ));
        end;
      7:
        begin
          Found := (OpText = '&&') or (OpText = '||');
          if OpText = '&&' then
            Code := opAnd
          else
            Code := opOr;
        end;
    end;
    if not Found then
      Exit;
    Advance;
    Load(Result);
    Right := Expression(Priority - 1);
    Load(Right);
    Acc.Emit(Code);
    if Priority in [3, 4] then
      Result := ValueOp(BinaryType(OpText, Result.Typ, Right.Typ))
    else
      Result := ValueOp(VM.TypeFloat);
  until False;
end;

function TScriptCompiler.CallArgs(const Params: array of TD3ScriptType): Integer;
var
  Op: TOperand;
begin
  Result := 0;
  ExpectP('(');
  if not IsP(')') then
    repeat
      Op := Expression(7);
      Load(Op);
      if Result < Length(Params) then
        ConvertTo(Op, Params[Result]);
      Inc(Result);
    until not AcceptP(',');
  ExpectP(')');
  if Result <> Length(Params) then
    Error(Format('Expected %d arguments, got %d', [Length(Params), Result]));
end;

function TScriptCompiler.CallFunction(const F: TD3ScriptFunction; const IsThread: Boolean): TOperand;
var
  Acc: TD3ScriptVM;
  N: Integer;
begin
  Acc := VM;
  N := CallArgs(F.ParamTypes);
  if IsThread then
  begin
    Acc.Emit(opThread, Acc.FFunctions.IndexOf(F), N);
    Exit(ValueOp(VM.TypeFloat));
  end;
  Acc.Emit(opCall, Acc.FFunctions.IndexOf(F), N);
  Result := ValueOp(F.ReturnType);
end;

{ the target (entity, or nothing for sys) is already on the stack }
function TScriptCompiler.CallEvent(const Ev: TD3ScriptEvent; const OnSys: Boolean): TOperand;
var
  Acc: TD3ScriptVM;
  N: Integer;
begin
  Acc := VM;
  N := CallArgs(Ev.ParamTypes);
  if OnSys then
    Acc.Emit(opSysEvent, Acc.AddConst(D3StringValue(Ev.Name)), N)
  else
    Acc.Emit(opEvent, Acc.AddConst(D3StringValue(Ev.Name)), N);
  Result := ValueOp(Ev.ReturnType);
end;

{ the entity is already on the stack }
function TScriptCompiler.CallMethod(const F: TD3ScriptFunction; const IsThread: Boolean): TOperand;
var
  Acc: TD3ScriptVM;
  N: Integer;
  MName: String;
begin
  Acc := VM;
  N := CallArgs(F.ParamTypes);
  MName := Copy(F.Name, LastDelimiter(':', F.Name) + 1, MaxInt);
  if IsThread then
  begin
    Acc.Emit(opThreadMethod, Acc.AddConst(D3StringValue(MName)), N);
    Exit(ValueOp(VM.TypeFloat));
  end;
  Acc.Emit(opCallMethod, Acc.AddConst(D3StringValue(MName)), N);
  Result := ValueOp(F.ReturnType);
end;

{ obj . name [( args )] ; Obj is loaded (an entity on the stack) }
function TScriptCompiler.Member(Obj: TOperand; const IsThread: Boolean): TOperand;
var
  AName: String;
  F: TD3ScriptFunction;
  Ev: TD3ScriptEvent;
  Index: Integer;
  ObjType: TD3ScriptType;
begin
  AName := ExpectName;
  if (Obj.Typ <> nil) and (Obj.Typ.Base = sbObject) then
  begin
    F := Obj.Typ.FindMethod(AName);
    if F <> nil then
      Exit(CallMethod(F, IsThread));
    if Obj.Typ.FindField(AName, Index) then
    begin
      Result := Default(TOperand);
      Result.Kind := okField;
      Result.Index := Index;
      Result.Comp := -1;
      Result.Typ := Obj.Typ.FieldTypes[Index];
      Exit;
    end;
  end;
  if (Obj.Typ = nil) or not (Obj.Typ.Base in [sbEntity, sbObject]) then
    Error('Member of a value that isn''t an entity');
  if VM.EventsTable.TryGetValue(AName, Ev) then
    Exit(CallEvent(Ev, False));
  { an entity's script object method, found at run time by name }
  for ObjType in VM.Types.Values do
    if ObjType.Base = sbObject then
    begin
      F := ObjType.FindMethod(AName);
      if F <> nil then
        Exit(CallMethod(F, IsThread));
    end;
  Error('Unknown event or method "' + AName + '"');
  Result := Default(TOperand);
end;

function TScriptCompiler.NameTerm(const AName: String; const IsThread: Boolean): TOperand;
var
  Index, C: Integer;
  F: TD3ScriptFunction;
  Ev: TD3ScriptEvent;
  ST, T: TD3ScriptType;
  Base, FullName: String;
  Acc: TD3ScriptVM;

  function VarOperand(const Kind: TOperandKind; const AIndex: Integer;
    const AType: TD3ScriptType; const AComp: Integer): TOperand;
  begin
    Result := Default(TOperand);
    Result.Kind := Kind;
    Result.Index := AIndex;
    Result.Typ := AType;
    Result.Comp := AComp;
    if AComp >= 0 then
      Result.Typ := VM.TypeFloat;
  end;

  function TryVariable(const N: String; const AComp: Integer; out Op: TOperand): Boolean;
  begin
    Result := True;
    if (Func <> nil) and LookupLocal(N, Index) then
    begin
      T := Func.LocalTypes[Index];
      if (AComp < 0) or (T.Base = sbVector) then
      begin
        Op := VarOperand(okLocal, Index, T, AComp);
        Exit;
      end;
    end;
    ST := SelfType;
    if (ST <> nil) and ST.FindField(N, Index) then
    begin
      T := ST.FieldTypes[Index];
      if (AComp < 0) or (T.Base = sbVector) then
      begin
        Op := VarOperand(okSelfField, Index, T, AComp);
        Exit;
      end;
    end;
    if LookupGlobal(N, Index) then
    begin
      T := Acc.FGlobalTypes[Index];
      if (AComp < 0) or (T.Base = sbVector) then
      begin
        Op := VarOperand(okGlobal, Index, T, AComp);
        Exit;
      end;
    end;
    Result := False;
  end;

begin
  Acc := VM;
  FullName := AName;
  { qualified: a::b::c }
  while IsP('::') do
  begin
    Advance;
    FullName := FullName + '::' + ExpectName;
  end;
  if IsP('(') then
  begin
    ST := SelfType;
    if (ST <> nil) and (FullName = AName) then
    begin
      F := ST.FindMethod(AName);
      if F <> nil then
      begin
        Acc.Emit(opPushSelf);
        Exit(CallMethod(F, IsThread));
      end;
    end;
    F := LookupFunction(FullName);
    if F <> nil then
      Exit(CallFunction(F, IsThread));
    if VM.EventsTable.TryGetValue(FullName, Ev) then
    begin
      { in an object's method, events go to its entity; elsewhere to sys }
      if ST <> nil then
      begin
        Acc.Emit(opPushSelf);
        Exit(CallEvent(Ev, False));
      end;
      Exit(CallEvent(Ev, True));
    end;
    Error('Unknown function "' + FullName + '"');
  end;
  if IsThread then
    Error('"thread" needs a function call');
  if TryVariable(FullName, -1, Result) then
    Exit;
  { name_x, name_y, name_z }
  if (Length(FullName) > 2) and (FullName[Length(FullName) - 1] = '_') and
     (FullName[Length(FullName)] in ['x', 'y', 'z']) then
  begin
    Base := Copy(FullName, 1, Length(FullName) - 2);
    C := Ord(FullName[Length(FullName)]) - Ord('x');
    if TryVariable(Base, C, Result) then
      Exit;
  end;
  Error('Unknown name "' + FullName + '"');
  Result := Default(TOperand);
end;

function TScriptCompiler.Postfix(Op: TOperand): TOperand;
var
  Acc: TD3ScriptVM;
  OpText: String;
  Target: TOperand;
begin
  Acc := VM;
  Result := Op;
  repeat
    if IsP('.') then
    begin
      Advance;
      Load(Result);
      Result := Member(Result, False);
    end else
    if IsP('++') or IsP('--') then
    begin
      OpText := Cur.Text;
      Advance;
      if Result.Kind in [okValue, okVoid] then
        Error('Not assignable');
      Target := Result;
      if Target.Kind in [okGlobal, okLocal] then
      begin
        { the old value stays as the expression's value }
        Load(Result);
        LoadForUpdate(Target);
        Acc.Emit(opPushConst, Acc.AddConst(D3FloatValue(1)));
        if OpText = '++' then Acc.Emit(opAdd) else Acc.Emit(opSub);
        StoreKeep(Target);
        Acc.Emit(opPop);
      end else
      begin
        LoadForUpdate(Target);
        Acc.Emit(opPushConst, Acc.AddConst(D3FloatValue(1)));
        if OpText = '++' then Acc.Emit(opAdd) else Acc.Emit(opSub);
        StoreKeep(Target);
        Result := ValueOp(VM.TypeFloat);
      end;
    end else
      Exit;
  until False;
end;

function TScriptCompiler.Term: TOperand;
var
  Acc: TD3ScriptVM;
  Op: TOperand;
  OpText, AName: String;
  IsThread: Boolean;
  Index: Integer;
begin
  Acc := VM;
  if Cur.Kind = tkPunct then
  begin
    OpText := Cur.Text;
    if (OpText = '-') or (OpText = '!') or (OpText = '~') then
    begin
      Advance;
      { negative number constants }
      if (OpText = '-') and (Cur.Kind = tkNumber) then
      begin
        Acc.Emit(opPushConst, Acc.AddConst(D3FloatValue(-Cur.Num)));
        Advance;
        Exit(Postfix(ValueOp(VM.TypeFloat)));
      end;
      Op := Term();
      Load(Op);
      if OpText = '-' then
      begin
        Acc.Emit(opNeg);
        Exit(ValueOp(Op.Typ));
      end;
      if OpText = '!' then
        Acc.Emit(opNot)
      else
        Acc.Emit(opComplement);
      Exit(ValueOp(VM.TypeFloat));
    end;
    if (OpText = '++') or (OpText = '--') then
    begin
      Advance;
      Op := Term();
      if Op.Kind in [okValue, okVoid] then
        Error('Not assignable');
      LoadForUpdate(Op);
      Acc.Emit(opPushConst, Acc.AddConst(D3FloatValue(1)));
      if OpText = '++' then Acc.Emit(opAdd) else Acc.Emit(opSub);
      StoreKeep(Op);
      Exit(ValueOp(VM.TypeFloat));
    end;
    if OpText = '(' then
    begin
      Advance;
      Op := Expression(7);
      ExpectP(')');
      Exit(Postfix(Op));
    end;
    if OpText = '$' then
    begin
      Advance;
      AName := ExpectName;
      Acc.Emit(opPushEntity, Acc.AddConst(D3StringValue(AName)));
      Exit(Postfix(ValueOp(VM.TypeEntity)));
    end;
    Error('Unexpected token');
  end;
  case Cur.Kind of
    tkNumber:
      begin
        Acc.Emit(opPushConst, Acc.AddConst(D3FloatValue(Cur.Num)));
        Advance;
        Exit(Postfix(ValueOp(VM.TypeFloat)));
      end;
    tkString:
      begin
        Acc.Emit(opPushConst, Acc.AddConst(D3StringValue(Cur.Text)));
        Advance;
        Exit(Postfix(ValueOp(VM.TypeString)));
      end;
    tkVector:
      begin
        Acc.Emit(opPushConst, Acc.AddConst(D3VectorValue(Cur.Vec)));
        Advance;
        Exit(Postfix(ValueOp(VM.TypeVector)));
      end;
    tkName: ;
    else
      Error('Unexpected end of file');
  end;
  IsThread := FThreadPrefix;
  FThreadPrefix := False;
  if Cur.Text = 'thread' then
  begin
    IsThread := True;
    Advance;
    { thread ( f() ) }
    if AcceptP('(') then
    begin
      FThreadPrefix := True;
      Result := Term();
      ExpectP(')');
      Exit;
    end;
  end;
  AName := Cur.Text;
  { int( expression ): truncation }
  if (AName = 'int') and (PeekToken.Kind = tkPunct) and (PeekToken.Text = '(') then
  begin
    Advance;
    ExpectP('(');
    Op := Expression(7);
    Load(Op);
    ExpectP(')');
    Acc.Emit(opInt);
    Exit(Postfix(ValueOp(VM.TypeFloat)));
  end;
  if AName = 'sys' then
  begin
    Advance;
    ExpectP('.');
    AName := ExpectName;
    if not VM.EventsTable.ContainsKey(AName) then
      Error('Unknown event "sys.' + AName + '"');
    Exit(Postfix(CallEvent(VM.EventsTable[AName], True)));
  end;
  if (AName = 'self') and not ((Func <> nil) and LookupLocal('self', Index)) then
  begin
    Advance;
    Acc.Emit(opPushSelf);
    if SelfType <> nil then
      Op := ValueOp(SelfType)
    else
      Op := ValueOp(VM.TypeEntity);
    if IsThread then
    begin
      ExpectP('.');
      Exit(Member(Op, True));
    end;
    Exit(Postfix(Op));
  end;
  Advance;
  if IsThread and (Cur.Kind = tkPunct) and (Cur.Text = '.') then
  begin
    { thread var.method() }
    Op := NameTerm(AName, False);
    Load(Op);
    Advance;
    Exit(Member(Op, True));
  end;
  Result := Postfix(NameTerm(AName, IsThread));
end;

{ TD3ScriptVM ---------------------------------------------------------------- }

constructor TD3ScriptVM.Create;

  function AddType(const B: TD3ScriptBase; const N: String): TD3ScriptType;
  begin
    Result := TD3ScriptType.Create(B, N);
    FTypes.Add(N, Result);
  end;

begin
  inherited Create;
  FTypes := specialize TObjectDictionary<String, TD3ScriptType>.Create([doOwnsValues]);
  FFunctions := specialize TObjectList<TD3ScriptFunction>.Create(True);
  FEvents := specialize TObjectDictionary<String, TD3ScriptEvent>.Create([doOwnsValues]);
  FGlobalNames := specialize TDictionary<String, Integer>.Create;
  FFunctionNames := specialize TDictionary<String, TD3ScriptFunction>.Create;
  FGlobalTypes := specialize TList<TD3ScriptType>.Create;
  FThreads := specialize TObjectList<TD3ScriptThread>.Create(True);
  FReported := specialize TDictionary<String, Boolean>.Create;
  TypeVoid := AddType(sbVoid, 'void');
  TypeFloat := AddType(sbFloat, 'float');
  TypeBoolean := AddType(sbBoolean, 'boolean');
  TypeVector := AddType(sbVector, 'vector');
  TypeString := AddType(sbString, 'string');
  TypeEntity := AddType(sbEntity, 'entity');
  FLoader := @DefaultLoader;
  FNextThread := 1;
end;

destructor TD3ScriptVM.Destroy;
begin
  FThreads.Free;
  FFunctionNames.Free;
  FGlobalNames.Free;
  FGlobalTypes.Free;
  FEvents.Free;
  FFunctions.Free;
  FTypes.Free;
  FReported.Free;
  FMacros.Free;
  inherited;
end;

function TD3ScriptVM.DefaultLoader(const APath: String; out Text: String): Boolean;
begin
  Result := D3Fs.FileExists(APath);
  if Result then
    Text := D3Fs.ReadText(APath)
  else
    Text := '';
end;

procedure TD3ScriptVM.Emit(const Op: TD3Op; const A: Integer; const B: Integer);
begin
  if FCodeCount >= Length(FCode) then
    SetLength(FCode, FCodeCount * 2 + 1024);
  FCode[FCodeCount].Op := Op;
  FCode[FCodeCount].A := A;
  FCode[FCodeCount].B := B;
  Inc(FCodeCount);
end;

function TD3ScriptVM.AddConst(const V: TD3Value): Integer;
begin
  if FConstCount >= Length(FConsts) then
    SetLength(FConsts, FConstCount * 2 + 256);
  FConsts[FConstCount] := V;
  Result := FConstCount;
  Inc(FConstCount);
end;

procedure TD3ScriptVM.CompileText(const AText, AFileName: String);
var
  Tok: TScriptTokenizer;
  C: TScriptCompiler;
begin
  if FMacros = nil then
    FMacros := TMacroTable.Create([doOwnsValues]);
  Tok := TScriptTokenizer.Create(FLoader, TMacroTable(FMacros));
  try
    Tok.PushText(AText, AFileName);
    C := TScriptCompiler.Create(Self, Tok);
    try
      C.CompileAll;
    finally
      C.Free;
    end;
    Inc(FFileCount, Tok.FileCount);
  finally
    Tok.Free;
  end;
  FCompiled := True;
end;

procedure TD3ScriptVM.CompileFile(const APath: String);
var
  Text: String;
begin
  if not FLoader(NormalizeD3Path(APath), Text) then
    raise ED3ScriptError.CreateFmt('Cannot read "%s"', [APath]);
  CompileText(Text, NormalizeD3Path(APath));
end;

function TD3ScriptVM.FindFunction(const AName: String): TD3ScriptFunction;
begin
  if not FFunctionNames.TryGetValue(AName, Result) then
    Result := nil;
end;

function TD3ScriptVM.FindEvent(const AName: String): TD3ScriptEvent;
begin
  if not FEvents.TryGetValue(AName, Result) then
    Result := nil;
end;

function TD3ScriptVM.FindType(const AName: String): TD3ScriptType;
begin
  if not FTypes.TryGetValue(AName, Result) then
    Result := nil;
end;

function TD3ScriptVM.GlobalValue(const AName: String): TD3Value;
var
  Index: Integer;
begin
  if FGlobalNames.TryGetValue(AName, Index) then
    Result := FGlobals[Index]
  else
    Result := D3FloatValue(0);
end;

function TD3ScriptVM.FunctionCount: Integer;
begin
  Result := FFunctions.Count;
end;

function TD3ScriptVM.ThreadCount: Integer;
begin
  Result := FThreads.Count;
end;

function TD3ScriptVM.ThreadByNumber(const N: Integer): TD3ScriptThread;
begin
  for Result in FThreads do
    if Result.Number = N then
      Exit;
  Result := nil;
end;

procedure TD3ScriptVM.ReportOnce(const Msg: String);
begin
  if FReported.ContainsKey(Msg) then
    Exit;
  FReported.Add(Msg, True);
  WritelnLog('Script', Msg);
end;

procedure TD3ScriptVM.KillThreads;
begin
  FThreads.Clear;
end;

function TD3ScriptVM.NewThread(const F: TD3ScriptFunction; const ASelf: Integer;
  const Args: TD3ValueArray): TD3ScriptThread;
var
  I: Integer;
begin
  Result := TD3ScriptThread.Create;
  Result.Number := FNextThread;
  Inc(FNextThread);
  Result.Name := F.Name;
  SetLength(Result.Stack, 64);
  for I := 0 to High(F.LocalTypes) do
    if I <= High(Args) then
      Result.Push(ConvertValue(Args[I], F.LocalTypes[I].Base))
    else
      Result.Push(DefaultValue(F.LocalTypes[I]));
  SetLength(Result.Frames, 8);
  Result.FrameCount := 1;
  Result.Frames[0].Func := F;
  Result.Frames[0].ReturnPC := -1;
  Result.Frames[0].Base := 0;
  Result.Frames[0].Self := ASelf;
  Result.PC := F.Address;
  Result.State := tsRunning;
  FThreads.Add(Result);
end;

function TD3ScriptVM.StartThread(const F: TD3ScriptFunction; const ASelf: Integer): TD3ScriptThread;
begin
  Result := StartThread(F, ASelf, nil);
end;

function TD3ScriptVM.StartThread(const F: TD3ScriptFunction; const ASelf: Integer;
  const Args: TD3ValueArray): TD3ScriptThread;
begin
  if (F = nil) or (F.Address < 0) then
    Exit(nil);
  Result := NewThread(F, ASelf, Args);
  Execute(Result);
  if Result.State = tsDone then
  begin
    FThreads.Remove(Result);
    Result := nil;
  end;
end;

function TD3ScriptVM.QueueThread(const F: TD3ScriptFunction; const ASelf: Integer): TD3ScriptThread;
begin
  if (F = nil) or (F.Address < 0) then
    Exit(nil);
  Result := NewThread(F, ASelf, nil);
end;

function TD3ScriptVM.NewPersistentThread(const AName: String): TD3ScriptThread;
begin
  Result := TD3ScriptThread.Create;
  Result.Number := FNextThread;
  Inc(FNextThread);
  Result.Name := AName;
  Result.Persistent := True;
  Result.State := tsDone;
  SetLength(Result.Stack, 64);
  SetLength(Result.Frames, 8);
  FThreads.Add(Result);
end;

procedure TD3ScriptVM.RestartThread(const T: TD3ScriptThread; const F: TD3ScriptFunction; const ASelf: Integer);
var
  I: Integer;
begin
  T.Top := 0;
  T.FrameCount := 0;
  if (F = nil) or (F.Address < 0) then
  begin
    T.State := tsDone;
    Exit;
  end;
  for I := 0 to High(F.LocalTypes) do
    T.Push(DefaultValue(F.LocalTypes[I]));
  T.FrameCount := 1;
  T.Frames[0].Func := F;
  T.Frames[0].ReturnPC := -1;
  T.Frames[0].Base := 0;
  T.Frames[0].Self := ASelf;
  T.PC := F.Address;
  T.State := tsRunning;
end;

procedure TD3ScriptVM.FreeThread(const T: TD3ScriptThread);
begin
  FThreads.Remove(T);
end;

function TD3ScriptVM.Ready(const T: TD3ScriptThread): Boolean;
begin
  case T.State of
    tsRunning, tsWaitFrame: Result := True;
    tsWaitTime: Result := FTime >= T.WaitUntil;
    tsWaitEntity: Result := (FHost = nil) or not FHost.EntityBusy(T.WaitEntity);
    tsWaitThread: Result := ThreadByNumber(T.WaitThread) = nil;
    else Result := False;
  end;
end;

procedure TD3ScriptVM.Update(const ATime: Single);
var
  I: Integer;
  Snapshot: array of TD3ScriptThread;
  T: TD3ScriptThread;
begin
  FTime := ATime;
  { threads started during this update run at once (StartThread) }
  Snapshot := FThreads.ToArray;
  for T in Snapshot do
    if (FThreads.IndexOf(T) >= 0) and (T.State <> tsDone) and Ready(T) then
    begin
      T.State := tsRunning;
      Execute(T);
    end;
  for I := FThreads.Count - 1 downto 0 do
    if (FThreads[I].State = tsDone) and not FThreads[I].Persistent then
      FThreads.Delete(I);
end;

function NumOp(const Op: TD3Op; const A, B: Single): Single;
begin
  case Op of
    opAdd: Result := A + B;
    opSub: Result := A - B;
    opMul: Result := A * B;
    opDiv: if B = 0 then Result := 0 else Result := A / B;
    opMod: if Trunc(B) = 0 then Result := 0 else Result := Trunc(A) mod Trunc(B);
    opBitAnd: Result := Trunc(A) and Trunc(B);
    opBitOr: Result := Trunc(A) or Trunc(B);
    opLt: Result := Ord(A < B);
    opLe: Result := Ord(A <= B);
    opGt: Result := Ord(A > B);
    opGe: Result := Ord(A >= B);
    else Result := 0;
  end;
end;

function Binary(const Op: TD3Op; const A, B: TD3Value): TD3Value;
var
  Same: Boolean;
begin
  case Op of
    opAnd: Exit(D3FloatValue(Ord(Truthy(A) and Truthy(B))));
    opOr: Exit(D3FloatValue(Ord(Truthy(A) or Truthy(B))));
    opEq, opNe:
      begin
        if (A.Kind = sbString) or (B.Kind = sbString) then
          Same := D3ValueToString(A) = D3ValueToString(B)
        else
        if (A.Kind = sbVector) and (B.Kind = sbVector) then
          Same := TVector3.PerfectlyEquals(A.V, B.V)
        else
        if (A.Kind = sbEntity) or (B.Kind = sbEntity) then
          Same := Round(D3ValueToFloat(A)) = Round(D3ValueToFloat(B))
        else
          Same := A.F = B.F;
        Exit(D3FloatValue(Ord(Same = (Op = opEq))));
      end;
    else ;
  end;
  if (Op = opAdd) and ((A.Kind = sbString) or (B.Kind = sbString)) then
    Exit(D3StringValue(D3ValueToString(A) + D3ValueToString(B)));
  if (A.Kind = sbVector) or (B.Kind = sbVector) then
  begin
    if (A.Kind = sbVector) and (B.Kind = sbVector) then
      case Op of
        opAdd: Exit(D3VectorValue(A.V + B.V));
        opSub: Exit(D3VectorValue(A.V - B.V));
        opMul: Exit(D3FloatValue(TVector3.DotProduct(A.V, B.V)));
        else Exit(D3FloatValue(0));
      end;
    if A.Kind = sbVector then
      case Op of
        opMul: Exit(D3VectorValue(A.V * D3ValueToFloat(B)));
        opDiv: if D3ValueToFloat(B) = 0 then Exit(D3VectorValue(A.V)) else Exit(D3VectorValue(A.V / D3ValueToFloat(B)));
        else Exit(D3VectorValue(A.V));
      end;
    if Op = opMul then
      Exit(D3VectorValue(B.V * D3ValueToFloat(A)));
    Exit(D3VectorValue(B.V));
  end;
  Result := D3FloatValue(NumOp(Op, D3ValueToFloat(A), D3ValueToFloat(B)));
end;

function TD3ScriptVM.SysEvent(const T: TD3ScriptThread; const Target: Integer;
  const Ev: TD3ScriptEvent; const Args: TD3ValueArray; var R: TD3Value): Boolean;
var
  N: String;
  Other: TD3ScriptThread;
  Fwd, Right, Up: TVector3;
  A: Single;
begin
  Result := True;
  N := Ev.Name;
  if N = 'wait' then
  begin
    T.State := tsWaitTime;
    T.WaitUntil := FTime + D3ValueToFloat(Args[0]);
  end else
  if N = 'waitFrame' then
    T.State := tsWaitFrame
  else
  if N = 'waitFor' then
  begin
    T.State := tsWaitEntity;
    T.WaitEntity := Args[0].E;
  end else
  if N = 'waitForThread' then
  begin
    T.State := tsWaitThread;
    T.WaitThread := Round(D3ValueToFloat(Args[0]));
  end else
  if N = 'terminate' then
  begin
    Other := ThreadByNumber(Round(D3ValueToFloat(Args[0])));
    if Other <> nil then
      Other.State := tsDone;
  end else
  if N = 'killthread' then
  begin
    for Other in FThreads do
      if SameText(Other.Name, Args[0].S) then
        Other.State := tsDone;
  end else
  if N = 'threadname' then
    T.Name := Args[0].S
  else
  if (N = 'print') or (N = 'println') or (N = 'say') then
  begin
    if FHost <> nil then
      FHost.Print(D3ValueToString(Args[0]))
    else
      WritelnLog('Script', TrimRight(D3ValueToString(Args[0])));
  end else
  if N = 'getTime' then
    R := D3FloatValue(FTime)
  else
  if N = 'getTicsPerSecond' then
    R := D3FloatValue(60)
  else
  if N = 'random' then
    R := D3FloatValue(Random * D3ValueToFloat(Args[0]))
  else
  if N = 'sin' then
    R := D3FloatValue(Sin(DegToRad(D3ValueToFloat(Args[0]))))
  else
  if N = 'cos' then
    R := D3FloatValue(Cos(DegToRad(D3ValueToFloat(Args[0]))))
  else
  if N = 'sqrt' then
    R := D3FloatValue(Sqrt(Max(0, D3ValueToFloat(Args[0]))))
  else
  if N = 'vecLength' then
    R := D3FloatValue(Args[0].V.Length)
  else
  if N = 'vecNormalize' then
    R := D3VectorValue(Args[0].V.Normalize)
  else
  if N = 'DotProduct' then
    R := D3FloatValue(TVector3.DotProduct(Args[0].V, Args[1].V))
  else
  if N = 'CrossProduct' then
    R := D3VectorValue(TVector3.CrossProduct(Args[0].V, Args[1].V))
  else
  if N = 'VecToAngles' then
  begin
    { pitch yaw roll in degrees, like idVec3::ToAngles }
    Fwd := Args[0].V;
    A := Sqrt(Sqr(Fwd.X) + Sqr(Fwd.Y));
    R := D3VectorValue(Vector3(-RadToDeg(ArcTan2(Fwd.Z, A)), RadToDeg(ArcTan2(Fwd.Y, Fwd.X)), 0));
  end else
  if (N = 'angToForward') or (N = 'angToRight') or (N = 'angToUp') then
  begin
    { idAngles::ToVectors }
    Fwd := Vector3(
      Cos(DegToRad(Args[0].V.X)) * Cos(DegToRad(Args[0].V.Y)),
      Cos(DegToRad(Args[0].V.X)) * Sin(DegToRad(Args[0].V.Y)),
      -Sin(DegToRad(Args[0].V.X)));
    Right := TVector3.CrossProduct(Fwd, Vector3(0, 0, 1)).Normalize;
    Up := TVector3.CrossProduct(Right, Fwd);
    if N = 'angToForward' then R := D3VectorValue(Fwd) else
    if N = 'angToRight' then R := D3VectorValue(Right) else
      R := D3VectorValue(Up);
  end else
  if N = 'strLength' then
    R := D3FloatValue(Length(Args[0].S))
  else
  if N = 'strLeft' then
    R := D3StringValue(Copy(Args[0].S, 1, Round(D3ValueToFloat(Args[1]))))
  else
  if N = 'strRight' then
    R := D3StringValue(Copy(Args[0].S, Length(Args[0].S) - Round(D3ValueToFloat(Args[1])) + 1, MaxInt))
  else
  if N = 'strSkip' then
    R := D3StringValue(Copy(Args[0].S, Round(D3ValueToFloat(Args[1])) + 1, MaxInt))
  else
  if N = 'strMid' then
    R := D3StringValue(Copy(Args[0].S, Round(D3ValueToFloat(Args[1])) + 1, Round(D3ValueToFloat(Args[2]))))
  else
  if N = 'strToFloat' then
    R := D3FloatValue(StrToFloatDef(Trim(Args[0].S), 0, DefaultFormatSettings))
  else
  if N = 'warning' then
    ReportOnce('Script warning: ' + TrimRight(D3ValueToString(Args[0])))
  else
  if N = 'error' then
  begin
    { sys.error stops the thread (idThread::Error) }
    ReportOnce(Format('Script error in thread "%s": %s', [T.Name, TrimRight(D3ValueToString(Args[0]))]));
    T.State := tsDone;
  end else
  if (N = 'cacheSoundShader') or (N = 'assert') then
    // nothing to do
  else
    Result := False;
end;

procedure TD3ScriptVM.Execute(const T: TD3ScriptThread);
var
  Count, I, N: Integer;
  Ins: TD3Instr;
  A, B, V: TD3Value;
  Args: TD3ValueArray;
  F: TD3ScriptFunction;
  Ev: TD3ScriptEvent;
  Obj: TD3ScriptObject;
  Target: Integer;
  Frame: ^TD3ScriptFrame;
  SaveCurrent: TD3ScriptThread;
  NewT: TD3ScriptThread;

  procedure RuntimeError(const Msg: String);
  begin
    WritelnWarning('Script', 'Thread "%s": %s; the thread stops', [T.Name, Msg]);
    T.State := tsDone;
  end;

  procedure EnterFunction(const AF: TD3ScriptFunction; const ArgCount: Integer; const ASelf: Integer);
  var
    J: Integer;
  begin
    if T.FrameCount >= Length(T.Frames) then
      SetLength(T.Frames, T.FrameCount * 2);
    if T.FrameCount > 1000 then
    begin
      RuntimeError('call stack overflow in ' + AF.Name);
      Exit;
    end;
    T.Frames[T.FrameCount].Func := AF;
    T.Frames[T.FrameCount].ReturnPC := T.PC;
    T.Frames[T.FrameCount].Base := T.Top - ArgCount;
    T.Frames[T.FrameCount].Self := ASelf;
    Inc(T.FrameCount);
    for J := ArgCount to High(AF.LocalTypes) do
      T.Push(DefaultValue(AF.LocalTypes[J]));
    T.PC := AF.Address;
  end;

  procedure PopArgs(const ArgCount: Integer);
  var
    J: Integer;
  begin
    SetLength(Args, ArgCount);
    for J := ArgCount - 1 downto 0 do
      Args[J] := T.Pop;
  end;

begin
  SaveCurrent := FCurrent;
  FCurrent := T;
  try
    Count := 0;
    while T.State = tsRunning do
    begin
      Inc(Count);
      if Count > MaxInstructionsPerUpdate then
      begin
        RuntimeError('runaway loop');
        Break;
      end;
      Ins := FCode[T.PC];
      Inc(T.PC);
      Frame := @T.Frames[T.FrameCount - 1];
      case Ins.Op of
        opPushConst: T.Push(FConsts[Ins.A]);
        opPushGlobal: T.Push(FGlobals[Ins.A]);
        opStoreGlobal: FGlobals[Ins.A] := T.Stack[T.Top - 1];
        opPushLocal: T.Push(T.Stack[Frame^.Base + Ins.A]);
        opStoreLocal: T.Stack[Frame^.Base + Ins.A] := T.Stack[T.Top - 1];
        opPushSelf: T.Push(D3EntityValue(Frame^.Self));
        opPushEntity:
          if FHost <> nil then
            T.Push(D3EntityValue(FHost.FindEntity(FConsts[Ins.A].S)))
          else
            T.Push(D3EntityValue(0));
        opPushField:
          begin
            A := T.Pop;
            Obj := nil;
            if FHost <> nil then
              Obj := FHost.EntityObject(A.E);
            if (Obj <> nil) and (Ins.A < Length(Obj.Fields)) then
              T.Push(Obj.Fields[Ins.A])
            else
              T.Push(D3FloatValue(0));
          end;
        opStoreField:
          begin
            V := T.Pop;
            if Ins.B = 1 then
              A := D3EntityValue(Frame^.Self)
            else
              A := T.Pop;
            Obj := nil;
            if FHost <> nil then
              Obj := FHost.EntityObject(A.E);
            if (Obj <> nil) and (Ins.A < Length(Obj.Fields)) then
              Obj.Fields[Ins.A] := V;
            T.Push(V);
          end;
        opComp:
          begin
            A := T.Pop;
            T.Push(D3FloatValue(A.V.Data[Ins.A]));
          end;
        opSetComp:
          begin
            { stack: float vector -> vector }
            A := T.Pop;
            B := T.Pop;
            A := ConvertValue(A, sbVector);
            A.V.Data[Ins.A] := D3ValueToFloat(B);
            T.Push(A);
          end;
        opConvert: T.Stack[T.Top - 1] := ConvertValue(T.Stack[T.Top - 1], TD3ScriptBase(Ins.A));
        opDup: T.Push(T.Stack[T.Top - 1]);
        opPop: Dec(T.Top);
        opAdd, opSub, opMul, opDiv, opMod, opBitAnd, opBitOr, opAnd, opOr,
        opEq, opNe, opLt, opLe, opGt, opGe:
          begin
            B := T.Pop;
            A := T.Pop;
            T.Push(Binary(Ins.Op, A, B));
          end;
        opNeg:
          begin
            A := T.Pop;
            if A.Kind = sbVector then
              T.Push(D3VectorValue(-A.V))
            else
              T.Push(D3FloatValue(-D3ValueToFloat(A)));
          end;
        opNot: T.Push(D3FloatValue(Ord(not Truthy(T.Pop))));
        opComplement: T.Push(D3FloatValue(not Trunc(D3ValueToFloat(T.Pop))));
        opInt: T.Push(D3FloatValue(Trunc(D3ValueToFloat(T.Pop))));
        opJump: T.PC := Ins.A;
        opJumpFalse:
          if not Truthy(T.Pop) then
            T.PC := Ins.A;
        opCall:
          begin
            F := FFunctions[Ins.A];
            if F.Address < 0 then
            begin
              RuntimeError('function ' + F.Name + ' is declared but not defined');
              Break;
            end;
            EnterFunction(F, Ins.B, Frame^.Self);
          end;
        opCallMethod, opThreadMethod:
          begin
            PopArgs(Ins.B);
            Target := T.Pop.E;
            Obj := nil;
            if FHost <> nil then
              Obj := FHost.EntityObject(Target);
            F := nil;
            if Obj <> nil then
              F := Obj.Typ.FindMethodToRun(FConsts[Ins.A].S);
            if (F = nil) or (F.Address < 0) then
            begin
              ReportOnce(Format('Method "%s" called on an entity without it', [FConsts[Ins.A].S]));
              if Ins.Op = opThreadMethod then
                T.Push(D3FloatValue(0))
              else
              if (F <> nil) and (F.ReturnType <> TypeVoid) then
                T.Push(DefaultValue(F.ReturnType));
              Continue;
            end;
            if Ins.Op = opThreadMethod then
            begin
              NewT := StartThread(F, Target, Args);
              if NewT <> nil then
                T.Push(D3FloatValue(NewT.Number))
              else
                T.Push(D3FloatValue(0));
              Continue;
            end;
            for I := 0 to High(Args) do
              T.Push(ConvertValue(Args[I], F.LocalTypes[I].Base));
            EnterFunction(F, Ins.B, Target);
          end;
        opThread:
          begin
            PopArgs(Ins.B);
            NewT := StartThread(FFunctions[Ins.A], Frame^.Self, Args);
            { a thread that ended at once still had a number }
            if NewT <> nil then
              T.Push(D3FloatValue(NewT.Number))
            else
              T.Push(D3FloatValue(FNextThread - 1));
          end;
        opEvent, opSysEvent:
          begin
            Ev := FEvents[FConsts[Ins.A].S];
            PopArgs(Ins.B);
            if Ins.Op = opEvent then
              Target := T.Pop.E
            else
              Target := 0;
            V := DefaultValue(Ev.ReturnType);
            { callFunction / hasFunction: a method of the entity's script
              object by name, called in this thread }
            if (Ev.Name = 'callFunction') or (Ev.Name = 'hasFunction') then
            begin
              if Target = 0 then
                Target := Frame^.Self;
              Obj := nil;
              if FHost <> nil then
                Obj := FHost.EntityObject(Target);
              F := nil;
              if Obj <> nil then
                F := Obj.Typ.FindMethodToRun(D3ValueToString(Args[0]));
              if Ev.Name = 'hasFunction' then
                T.Push(D3FloatValue(Ord(F <> nil)))
              else
              if (F <> nil) and (Length(F.ParamTypes) = 0) then
                EnterFunction(F, 0, Target);
              Continue;
            end;
            { the thread's own events work on any target }
            if not SysEvent(T, Target, Ev, Args, V) then
            begin
              if (Ins.Op = opEvent) and (Target = 0) then
                ReportOnce(Format('Event "%s" on $null_entity', [Ev.Name]))
              else
              if (FHost = nil) or not FHost.CallEvent(T, Target, Ev, Args, V) then
                ReportOnce(Format('Not supported yet: event "%s"', [Ev.Name]));
            end;
            if Ev.ReturnType <> TypeVoid then
              T.Push(V);
          end;
        opReturn:
          begin
            if Ins.A = 1 then
              V := T.Pop;
            T.Top := Frame^.Base;
            T.PC := Frame^.ReturnPC;
            Dec(T.FrameCount);
            if T.FrameCount = 0 then
            begin
              T.State := tsDone;
              Break;
            end;
            if Ins.A = 1 then
              T.Push(V);
          end;
      end;
    end;
  finally
    FCurrent := SaveCurrent;
  end;
end;

end.
