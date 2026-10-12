// A sampling profiler for finding slow code (Windows, x86_64): a thread
// stops the main thread about every millisecond and records where it is
// (its instruction pointer and the return addresses along its frame pointer
// chain). The samples go to samples.txt next to the executable, as offsets
// in the executable (or the names of other modules);
// tools/resolve_samples.py turns them into function names with the linker
// map (build with --compiler-option=-Xm) and lists where the time goes,
// inclusive (anywhere on the stack) and exclusive (innermost).
//
// Enabled by the environment variable CD3_SAMPLE; the game samples while it
// loads a map and draws its first frames.
unit Doom3Sampler;

{$mode objfpc}{$H+}

interface

{ Start recording samples of the calling (main) thread. }
procedure SamplerStart;
{ Stop recording and log the report. }
procedure SamplerStopAndReport(const Title: String);
{ Whether CD3_SAMPLE is set. }
function SamplerWanted: Boolean;

implementation

{$ifdef MSWINDOWS}
{$ifdef CPUX86_64}
{$define SAMPLER}
{$endif}
{$endif}

uses
  SysUtils, Classes, Generics.Collections, CastleLog
  {$ifdef SAMPLER}, Windows{$endif};

{$ifdef SAMPLER}

const
  MaxDepth = 48;

type
  TSample = record
    Count: Integer;
    Addresses: array [0..MaxDepth - 1] of PtrUInt;
  end;

  TSamplerThread = class(TThread)
  protected
    procedure Execute; override;
  public
    Target: THandle;
    StackLow, StackHigh: PtrUInt;
    Samples: array of TSample;
    SampleCount, SuspendFailures, ContextFailures, Loops: Integer;
  end;

var
  Thread: TSamplerThread;

const
  GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS = 4;
  GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT = 2;

function GetModuleHandleExA(Flags: DWORD; ModuleName: PAnsiChar; out Module: HMODULE): BOOL;
  stdcall; external 'kernel32' name 'GetModuleHandleExA';
procedure GetCurrentThreadStackLimits(out LowLimit, HighLimit: PtrUInt);
  stdcall; external 'kernel32' name 'GetCurrentThreadStackLimits';
function timeBeginPeriod(Period: UINT): UINT; stdcall; external 'winmm.dll';
function timeEndPeriod(Period: UINT): UINT; stdcall; external 'winmm.dll';

procedure TSamplerThread.Execute;
var
  Buffer: Pointer;
  Ctx: PContext;
  S: TSample;
  Frame, Ret: PtrUInt;
begin
  { GetThreadContext wants a 16-byte aligned CONTEXT on x86_64 }
  GetMem(Buffer, SizeOf(TContext) + 16);
  Ctx := PContext((PtrUInt(Buffer) + 15) and not PtrUInt(15));
  try
  while not Terminated do
  begin
    Sleep(1);
    Inc(Loops);
    if SuspendThread(Target) = DWORD(-1) then
    begin
      Inc(SuspendFailures);
      Continue;
    end;
    try
      FillChar(Ctx^, SizeOf(TContext), 0);
      Ctx^.ContextFlags := CONTEXT_CONTROL or CONTEXT_INTEGER;
      if not GetThreadContext(Target, Ctx^) then
      begin
        Inc(ContextFailures);
        Continue;
      end;
      S.Count := 1;
      S.Addresses[0] := Ctx^.Rip;
      { a leaf without a frame: its return address is at the stack top }
      if (Ctx^.Rsp >= StackLow) and (Ctx^.Rsp + 8 <= StackHigh) then
      begin
        S.Addresses[1] := PPtrUInt(Ctx^.Rsp)^;
        S.Count := 2;
      end;
      Frame := Ctx^.Rbp;
      while (S.Count < MaxDepth) and (Frame >= StackLow) and (Frame + 16 <= StackHigh) and
        (Frame >= Ctx^.Rsp) do
      begin
        Ret := PPtrUInt(Frame + 8)^;
        if Ret = 0 then
          Break;
        S.Addresses[S.Count] := Ret;
        Inc(S.Count);
        { frames go up the stack }
        if PPtrUInt(Frame)^ <= Frame then
          Break;
        Frame := PPtrUInt(Frame)^;
      end;
    finally
      ResumeThread(Target);
    end;
    if SampleCount >= Length(Samples) then
      SetLength(Samples, Length(Samples) * 2 + 1024);
    Samples[SampleCount] := S;
    Inc(SampleCount);
  end;
  finally
    FreeMem(Buffer);
  end;
end;

function SamplerWanted: Boolean;
begin
  Result := SysUtils.GetEnvironmentVariable('CD3_SAMPLE') <> '';
end;

procedure SamplerStart;
var
  Handle: THandle;
  Low, High: PtrUInt;
begin
  if Thread <> nil then
    Exit;
  if not DuplicateHandle(GetCurrentProcess, GetCurrentThread, GetCurrentProcess, @Handle,
    THREAD_SUSPEND_RESUME or THREAD_GET_CONTEXT or THREAD_QUERY_INFORMATION, False, 0) then
    Exit;
  Thread := TSamplerThread.Create(True);
  Thread.Target := Handle;
  { the main thread's stack }
  GetCurrentThreadStackLimits(Low, High);
  Thread.StackLow := Low;
  Thread.StackHigh := High;
  Thread.Priority := tpTimeCritical;
  { Sleep(1) sleeps 1 ms, not a 15.6 ms tick }
  timeBeginPeriod(1);
  Thread.Start;
end;

{ The module of an address outside the executable, '' inside it. }
function ModuleOf(const Address: PtrUInt; const ExeLow, ExeHigh: PtrUInt;
  const Cache: specialize TDictionary<PtrUInt, String>): String;
var
  Module: HMODULE;
  ModuleName: array [0..MAX_PATH] of Char;
begin
  if (Address >= ExeLow) and (Address < ExeHigh) then
    Exit('');
  if Cache.TryGetValue(Address, Result) then
    Exit;
  if GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS or GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
    PAnsiChar(Address), Module) and (GetModuleFileName(Module, ModuleName, MAX_PATH) > 0) then
    Result := ExtractFileName(ModuleName)
  else
    Result := '?';
  Cache.Add(Address, Result);
end;

procedure SamplerStopAndReport(const Title: String);
var
  Cache: specialize TDictionary<PtrUInt, String>;
  I, J: Integer;
  ExeBase, ExeHigh: PtrUInt;
  Line, Module, FileName: String;
  Output: TStringList;
  Dos: PImageDosHeader;
  Nt: PImageNtHeaders;
begin
  if Thread = nil then
    Exit;
  Thread.Terminate;
  Thread.WaitFor;
  timeEndPeriod(1);
  { the executable's image (its addresses are resolved offline with the
    linker map: tools/resolve_samples.py) }
  ExeBase := PtrUInt(GetModuleHandle(nil));
  Dos := PImageDosHeader(ExeBase);
  Nt := PImageNtHeaders(ExeBase + PtrUInt(Dos^.e_lfanew));
  ExeHigh := ExeBase + Nt^.OptionalHeader.SizeOfImage;
  Cache := specialize TDictionary<PtrUInt, String>.Create;
  Output := TStringList.Create;
  try
    Output.Add(Format('# %s: %d samples, image base %x', [Title, Thread.SampleCount, ExeBase]));
    for I := 0 to Thread.SampleCount - 1 do
    begin
      Line := '';
      for J := 0 to Thread.Samples[I].Count - 1 do
      begin
        Module := ModuleOf(Thread.Samples[I].Addresses[J], ExeBase, ExeHigh, Cache);
        if Module = '' then
          { an offset in the executable; return addresses one byte back
            (inside the call) }
          Line := Line + IntToHex(Thread.Samples[I].Addresses[J] - ExeBase - Ord(J > 0), 1) + ' '
        else
          Line := Line + '[' + Module + '] ';
      end;
      Output.Add(Trim(Line));
    end;
    FileName := ExtractFilePath(ParamStr(0)) + 'samples.txt';
    Output.SaveToFile(FileName);
    WritelnLog('Sampler', '%s: %d samples written to "%s" (%d loops, %d suspend and %d context failures)',
      [Title, Thread.SampleCount, FileName, Thread.Loops, Thread.SuspendFailures, Thread.ContextFailures]);
  finally
    Output.Free;
    Cache.Free;
    CloseHandle(Thread.Target);
    FreeAndNil(Thread);
  end;
end;

{$else}

function SamplerWanted: Boolean;
begin
  Result := False;
end;

procedure SamplerStart;
begin
end;

procedure SamplerStopAndReport(const Title: String);
begin
end;

{$endif}

end.
