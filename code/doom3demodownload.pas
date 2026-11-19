{ Downloading the free Doom 3 demo (2004) for the title menu.

  The Linux demo, doom3-linux-1.1.1286-demo.x86.run from id Software's FTP
  (mirrored at ftp.gwdg.de), works on every system: only its
  demo/demo00.pk4 is needed. The .run file is a shell script (373 lines)
  followed by a gzipped tar. A thread downloads it into
  <config dir>/demo/download.run, extracts demo/demo00.pk4 alone into
  <config dir>/demo/demo/demo00.pk4 (checking its size and MD5), then
  deletes the .run file. Nothing of it is bundled with the port. }
unit Doom3DemoDownload;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs;

const
  DemoUrl = 'https://ftp.gwdg.de/pub/misc/ftp.idsoftware.com/idstuff/doom3/linux/doom3-linux-1.1.1286-demo.x86.run';
  { the .run file's size, shown before asking (the server's
    Content-Length is used once it answers) }
  DemoRunSize = 485257318;
  DemoPk4Name = 'demo/demo00.pk4';
  DemoPk4Size = 483535485;
  DemoPk4Md5 = '70c2c63ef1190158f1ebd6c255b22d8e';

type
  TD3DemoDownloadState = (ddsDownloading, ddsExtracting, ddsDone, ddsFailed, ddsCancelled);

  { Progress of ExtractDemoPk4: Done of Total bytes of the .run file read. }
  TD3ExtractProgress = procedure (const Done, Total: Int64) of object;

  TD3DemoDownload = class(TThread)
  private
    FLock: TCriticalSection;
    FState: TD3DemoDownloadState;
    FDone, FTotal: Int64;
    FError: String;
    FUrl, FBasePath: String;
    { Cancel: polled by the extraction }
    FCancelFlag: Boolean;
    procedure SetProgress(const Done, Total: Int64);
    procedure SetState(const AState: TD3DemoDownloadState; const AError: String = '');
    procedure Download(const FileName: String);
  protected
    procedure Execute; override;
  public
    { downloads Url and puts demo/demo00.pk4 under BasePath }
    constructor Create(const AUrl, ABasePath: String);
    destructor Destroy; override;
    { thread safe }
    procedure GetProgress(out State: TD3DemoDownloadState; out Done, Total: Int64; out Error: String);
    procedure Cancel;
  end;

{ Extract demo/demo00.pk4 from the .run file RunFile into OutFile; checks
  the size and MD5 when CheckMd5 (the real demo). Raises an exception on
  errors (OutFile then doesn't exist). Cancelled is polled. }
procedure ExtractDemoPk4(const RunFile, OutFile: String; const CheckMd5: Boolean;
  const Progress: TD3ExtractProgress; const Cancelled: PBoolean);

{ The offset of the gzipped tar in a .run file (after its script):
  -1 if there is none. }
function FindRunArchive(const Stream: TStream): Int64;

implementation

uses
  {$ifdef MSWINDOWS} Windows, WinInet, {$else} fphttpclient, opensslsockets, {$endif}
  ZStream, Md5, CastleLog;

const
  ScriptLines = 373;

function FindRunArchive(const Stream: TStream): Int64;
var
  Buf: array of Byte;
  N, I, Lines: Integer;
begin
  { the makeself script is 373 lines; then the gzip magic 1F 8B 08 (looked
    for a little further too, should another .run have a longer script) }
  Result := -1;
  SetLength(Buf, 256 * 1024);
  Stream.Position := 0;
  N := Stream.Read(Buf[0], Length(Buf));
  Lines := 0;
  I := 0;
  while (I < N) and (Lines < ScriptLines) do
  begin
    if Buf[I] = 10 then
      Inc(Lines);
    Inc(I);
  end;
  if Lines < ScriptLines then
    I := 0;
  while I + 2 < N do
  begin
    if (Buf[I] = $1F) and (Buf[I + 1] = $8B) and (Buf[I + 2] = 8) then
      Exit(I);
    Inc(I);
  end;
end;

{ A stream reading Source and counting the bytes for the progress. }
type
  TCountingStream = class(TStream)
  private
    FSource: TStream;
    FCount, FTotal: Int64;
    FProgress: TD3ExtractProgress;
    FCancelled: PBoolean;
    FLastReport: Int64;
  public
    function Read(var Buffer; Count: Longint): Longint; override;
  end;

function TCountingStream.Read(var Buffer; Count: Longint): Longint;
begin
  if (FCancelled <> nil) and FCancelled^ then
    raise Exception.Create('Cancelled');
  Result := FSource.Read(Buffer, Count);
  Inc(FCount, Result);
  if Assigned(FProgress) and (FCount - FLastReport > 1024 * 1024) then
  begin
    FProgress(FCount, FTotal);
    FLastReport := FCount;
  end;
end;

procedure SkipGzipHeader(const S: TStream);
var
  H: array [0..9] of Byte;
  Flags, B: Byte;
  XLen: Word;
begin
  S.ReadBuffer(H, 10);
  if (H[0] <> $1F) or (H[1] <> $8B) or (H[2] <> 8) then
    raise Exception.Create('Not a gzip stream');
  Flags := H[3];
  { FEXTRA, FNAME, FCOMMENT, FHCRC }
  if Flags and 4 <> 0 then
  begin
    S.ReadBuffer(XLen, 2);
    XLen := LEtoN(XLen);
    S.Seek(XLen, soCurrent);
  end;
  if Flags and 8 <> 0 then
    repeat
      S.ReadBuffer(B, 1);
    until B = 0;
  if Flags and 16 <> 0 then
    repeat
      S.ReadBuffer(B, 1);
    until B = 0;
  if Flags and 2 <> 0 then
    S.Seek(2, soCurrent);
end;

function OctalField(const H: array of Byte; const Offset, Len: Integer): Int64;
var
  I: Integer;
begin
  Result := 0;
  for I := Offset to Offset + Len - 1 do
    if H[I] in [Ord('0')..Ord('7')] then
      Result := Result * 8 + (H[I] - Ord('0'))
    else
    if (H[I] = 0) or ((H[I] = Ord(' ')) and (Result > 0)) then
      Break;
end;

function StringField(const H: array of Byte; const Offset, Len: Integer): String;
var
  I: Integer;
begin
  Result := '';
  for I := Offset to Offset + Len - 1 do
  begin
    if H[I] = 0 then
      Break;
    Result := Result + Chr(H[I]);
  end;
end;

procedure ExtractDemoPk4(const RunFile, OutFile: String; const CheckMd5: Boolean;
  const Progress: TD3ExtractProgress; const Cancelled: PBoolean);
var
  Run: TFileStream;
  Counter: TCountingStream;
  Gz: TDecompressionStream;
  Header: array [0..511] of Byte;
  Buf: array of Byte;
  Name: String;
  Size, Left, Padded: Int64;
  Offset: Int64;
  N: Integer;
  OutStream: TFileStream;
  Ctx: TMD5Context;
  Digest: TMD5Digest;
  Found: Boolean;
  TempFile: String;
begin
  Found := False;
  TempFile := OutFile + '.part';
  SetLength(Buf, 1024 * 1024);
  Run := TFileStream.Create(RunFile, fmOpenRead or fmShareDenyWrite);
  try
    Offset := FindRunArchive(Run);
    if Offset < 0 then
      raise Exception.CreateFmt('"%s" has no gzipped archive', [RunFile]);
    Run.Position := Offset;
    Counter := TCountingStream.Create;
    try
      Counter.FSource := Run;
      Counter.FTotal := Run.Size;
      Counter.FCount := Offset;
      Counter.FProgress := Progress;
      Counter.FCancelled := Cancelled;
      SkipGzipHeader(Counter);
      { True: raw deflate (the gzip header is read above) }
      Gz := TDecompressionStream.Create(Counter, True);
      try
        while True do
        begin
          if Gz.Read(Header, 512) <> 512 then
            Break;
          if Header[0] = 0 then
            Break;
          Name := StringField(Header, 0, 100);
          { ustar's prefix }
          if (StringField(Header, 257, 5) = 'ustar') and (Header[345] <> 0) then
            Name := StringField(Header, 345, 155) + '/' + Name;
          if Copy(Name, 1, 2) = './' then
            Delete(Name, 1, 2);
          Size := OctalField(Header, 124, 12);
          Padded := (Size + 511) and not Int64(511);
          if (Name = DemoPk4Name) and (Chr(Header[156]) in ['0', #0]) then
          begin
            ForceDirectories(ExtractFileDir(OutFile));
            MD5Init(Ctx);
            OutStream := TFileStream.Create(TempFile, fmCreate);
            try
              Left := Size;
              while Left > 0 do
              begin
                if Left > Length(Buf) then
                  N := Length(Buf)
                else
                  N := Left;
                Gz.ReadBuffer(Buf[0], N);
                OutStream.WriteBuffer(Buf[0], N);
                MD5Update(Ctx, Buf[0], N);
                Dec(Left, N);
              end;
            finally
              OutStream.Free;
            end;
            MD5Final(Ctx, Digest);
            if CheckMd5 and ((Size <> DemoPk4Size) or (MD5Print(Digest) <> DemoPk4Md5)) then
            begin
              SysUtils.DeleteFile(TempFile);
              raise Exception.CreateFmt('%s: wrong size or MD5 (%d bytes, MD5 %s; expected %d, %s)',
                [DemoPk4Name, Size, MD5Print(Digest), Int64(DemoPk4Size), DemoPk4Md5]);
            end;
            Found := True;
            Break;
          end;
          { skip this entry }
          Left := Padded;
          while Left > 0 do
          begin
            if Left > Length(Buf) then
              N := Length(Buf)
            else
              N := Left;
            Gz.ReadBuffer(Buf[0], N);
            Dec(Left, N);
          end;
        end;
      finally
        Gz.Free;
      end;
    finally
      Counter.Free;
    end;
  finally
    Run.Free;
  end;
  if not Found then
    raise Exception.CreateFmt('"%s" has no %s', [RunFile, DemoPk4Name]);
  if FileExists(OutFile) then
    SysUtils.DeleteFile(OutFile);
  if not SysUtils.RenameFile(TempFile, OutFile) then
    raise Exception.CreateFmt('Cannot rename "%s" to "%s"', [TempFile, OutFile]);
end;

{ TD3DemoDownload }

constructor TD3DemoDownload.Create(const AUrl, ABasePath: String);
begin
  FLock := SyncObjs.TCriticalSection.Create;
  FUrl := AUrl;
  FBasePath := ExcludeTrailingPathDelimiter(ABasePath);
  FTotal := DemoRunSize;
  FState := ddsDownloading;
  inherited Create(False);
end;

destructor TD3DemoDownload.Destroy;
begin
  inherited Destroy;
  FLock.Free;
end;

procedure TD3DemoDownload.SetProgress(const Done, Total: Int64);
begin
  FLock.Acquire;
  try
    FDone := Done;
    if Total > 0 then
      FTotal := Total;
  finally
    FLock.Release;
  end;
end;

procedure TD3DemoDownload.SetState(const AState: TD3DemoDownloadState; const AError: String);
begin
  FLock.Acquire;
  try
    FState := AState;
    FError := AError;
  finally
    FLock.Release;
  end;
end;

procedure TD3DemoDownload.GetProgress(out State: TD3DemoDownloadState; out Done, Total: Int64; out Error: String);
begin
  FLock.Acquire;
  try
    State := FState;
    Done := FDone;
    Total := FTotal;
    Error := FError;
  finally
    FLock.Release;
  end;
end;

procedure TD3DemoDownload.Cancel;
begin
  FCancelFlag := True;
  Terminate;
end;

{$ifdef MSWINDOWS}
procedure TD3DemoDownload.Download(const FileName: String);
var
  Net, Url: HINTERNET;
  Buf: array of Byte;
  Got, Len, Index: DWORD;
  LenText: array [0..63] of Char;
  Done, Total: Int64;
  OutStream: TFileStream;
  Status: DWORD;
begin
  SetLength(Buf, 256 * 1024);
  Net := InternetOpen('castle-doom3', INTERNET_OPEN_TYPE_PRECONFIG, nil, nil, 0);
  if Net = nil then
    RaiseLastOSError;
  try
    Url := InternetOpenUrl(Net, PChar(FUrl), nil, 0,
      INTERNET_FLAG_RELOAD or INTERNET_FLAG_NO_CACHE_WRITE or INTERNET_FLAG_NO_UI, 0);
    if Url = nil then
      raise Exception.CreateFmt('Cannot open %s (error %d)', [FUrl, GetLastError]);
    try
      Len := SizeOf(Status);
      Index := 0;
      if HttpQueryInfo(Url, HTTP_QUERY_STATUS_CODE or HTTP_QUERY_FLAG_NUMBER, @Status, Len, Index) and
         (Status <> 200) then
        raise Exception.CreateFmt('%s: HTTP status %d', [FUrl, Status]);
      Total := 0;
      Len := SizeOf(LenText);
      Index := 0;
      FillChar(LenText, SizeOf(LenText), 0);
      if HttpQueryInfo(Url, HTTP_QUERY_CONTENT_LENGTH, @LenText[0], Len, Index) then
        Total := StrToInt64Def(String(PChar(@LenText[0])), 0);
      SetProgress(0, Total);
      Done := 0;
      OutStream := TFileStream.Create(FileName, fmCreate);
      try
        repeat
          if Terminated then
            Exit;
          if not InternetReadFile(Url, @Buf[0], Length(Buf), Got) then
            raise Exception.CreateFmt('Download of %s failed after %d bytes (error %d)',
              [FUrl, Done, GetLastError]);
          if Got > 0 then
          begin
            OutStream.WriteBuffer(Buf[0], Got);
            Inc(Done, Got);
            SetProgress(Done, 0);
          end;
        until Got = 0;
      finally
        OutStream.Free;
      end;
      if (Total > 0) and (Done <> Total) then
        raise Exception.CreateFmt('Download of %s incomplete: %d of %d bytes', [FUrl, Done, Total]);
    finally
      InternetCloseHandle(Url);
    end;
  finally
    InternetCloseHandle(Net);
  end;
end;
{$else}
type
  TDownloadReceiver = class
    Owner: TD3DemoDownload;
    procedure DataReceived(Sender: TObject; const ContentLength, CurrentPos: Int64);
  end;

procedure TDownloadReceiver.DataReceived(Sender: TObject; const ContentLength, CurrentPos: Int64);
begin
  Owner.SetProgress(CurrentPos, ContentLength);
  if Owner.Terminated then
    (Sender as TFPHTTPClient).Terminate;
end;

procedure TD3DemoDownload.Download(const FileName: String);
var
  Client: TFPHTTPClient;
  Receiver: TDownloadReceiver;
begin
  Client := TFPHTTPClient.Create(nil);
  Receiver := TDownloadReceiver.Create;
  try
    Receiver.Owner := Self;
    Client.AllowRedirect := True;
    Client.OnDataReceived := @Receiver.DataReceived;
    Client.Get(FUrl, FileName);
  finally
    Receiver.Free;
    Client.Free;
  end;
end;
{$endif}

procedure TD3DemoDownload.Execute;
var
  RunFile, Pk4File: String;
begin
  RunFile := FBasePath + PathDelim + 'download.run';
  Pk4File := FBasePath + PathDelim + 'demo' + PathDelim + 'demo00.pk4';
  try
    ForceDirectories(FBasePath);
    WritelnLog('Doom3DemoDownload', 'Downloading %s to "%s"', [FUrl, RunFile]);
    Download(RunFile);
    if Terminated then
    begin
      SysUtils.DeleteFile(RunFile);
      SetState(ddsCancelled);
      WritelnLog('Doom3DemoDownload', 'Download cancelled');
      Exit;
    end;
    WritelnLog('Doom3DemoDownload', 'Downloaded %d bytes, extracting %s', [FDone, DemoPk4Name]);
    SetState(ddsExtracting);
    SetProgress(0, 0);
    ExtractDemoPk4(RunFile, Pk4File, True, @SetProgress, @FCancelFlag);
    SysUtils.DeleteFile(RunFile);
    WritelnLog('Doom3DemoDownload', 'Doom 3 demo ready: "%s" (MD5 checked)', [Pk4File]);
    SetState(ddsDone);
  except
    on E: Exception do
    begin
      SysUtils.DeleteFile(RunFile);
      if Terminated then
      begin
        SetState(ddsCancelled);
        WritelnLog('Doom3DemoDownload', 'Download cancelled');
      end else
      begin
        SetState(ddsFailed, E.Message);
        WritelnWarning('Doom3DemoDownload', 'Doom 3 demo download failed: %s', [E.Message]);
      end;
    end;
  end;
end;

end.
