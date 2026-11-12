{ Doom 3 virtual file system: stacked PK4 archives (ZIP files) and loose
  directories, served to Castle Game Engine through the "d3fs:" URL protocol.

  Like idFileSystem, later sources override earlier ones: pak000.pk4 ..
  pak004.pk4 are added in order, a mod's PK4s after them and loose files in
  base/ last. Paths are case-insensitive and use "/". }
unit Doom3Files;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleDownload, CastleUriUtils, CastleLog;

type
  { One file inside a PK4 or a loose directory. }
  TDoom3FileEntry = record
    { Path as stored in the archive (original case). }
    Path: String;
    SourceIndex: Integer;
    { ZIP: offset of the local file header, compression method and sizes.
      Loose directory: unused (the file is opened by name). }
    HeaderOffset: Int64;
    Method: Word;
    CompressedSize, Size: Int64;
  end;

  TDoom3Source = class
  strict private
    FMapping: PtrUInt;
  public
    Name: String;
    IsDirectory: Boolean;
    { A Doom 3 BFG ".resources" container: Stream is the open file, the
      entries' HeaderOffset is where their (uncompressed) data starts. }
    IsResources: Boolean;
    { PK4: the open archive file. }
    Stream: TStream;
    { PK4: the whole archive in memory (a memory mapped file, or the memory
      stream's memory), nil if it couldn't be mapped. }
    Data: PByte;
    DataSize: Int64;
    { Loose directory: its path with a trailing delimiter. }
    Directory: String;
    { Map the archive into memory (Data). }
    procedure MapData;
    destructor Destroy; override;
  end;

  TDoom3FileSystem = class
  strict private
    FSources: specialize TObjectList<TDoom3Source>;
    FEntries: specialize TList<TDoom3FileEntry>;
    { Normalized path -> index in FEntries }
    FIndex: specialize TDictionary<String, Integer>;
    FProtocolRegistered: Boolean;
    FBfg: Boolean;
    { BFG: image name (no extension) -> the codes (usage and cube kind,
      like "0100") of its generated/images/<name>#__<code>.bimage files,
      space separated }
    FBfgImages: specialize TDictionary<String, String>;
    function AddResources(const FileName: String): Boolean;
    function ReadResourceEntry(const Entry: TDoom3FileEntry): TMemoryStream;
    procedure AddEntry(const Entry: TDoom3FileEntry);
    function FindEntry(const APath: String; out Entry: TDoom3FileEntry): Boolean;
    function ReadZipEntry(const Entry: TDoom3FileEntry): TMemoryStream;
    procedure ScanDirectory(const Root, Sub: String; const SourceIndex: Integer);
    function ReadUrl(const Url: String; out MimeType: String): TStream;
  public
    constructor Create;
    destructor Destroy; override;

    { Add a PK4 (ZIP) archive from a filename or URL. }
    function AddPk4(const AUrlOrFilename: String): Boolean;
    { Add all loose files below a directory (e.g. "C:\Doom 3\base"). }
    function AddDirectory(const Dir: String): Boolean;
    { Add base/pak*.pk4 style archives (sorted by name) and the loose files
      of a game directory. }
    function AddGameDirectory(const Dir: String): Boolean;

    function HasSource(const Name: String): Boolean;
    { A file, or (Doom 3 BFG data) one that the generated binary of BfgGenerated
      stands for. }
    function FileExists(const APath: String): Boolean;
    { Doom 3 BFG data (".resources" containers) is mounted: source files
      (.proc, .cm, .md5mesh, .md5anim, .lwo, .ase, .tga, .wav) exist only
      as "generated/" binaries. }
    property IsBfg: Boolean read FBfg;
    { The generated binary that stands for a source file (.bproc, .bcm,
      .bmd5mesh, .bmd5anim, .blwo, .base, .bimage, .idwav), '' if none. }
    function BfgGenerated(const APath: String): String;
    { That binary's contents (caller frees), nil if none. }
    function OpenGenerated(const APath: String): TStream;
    { The .bimage for an image name without extension: a 2D image
      (CoveragePath: its alpha test version, whose alpha it lost, or ''),
      or one side of a cube map (Face, CameraCube) for a name ending with
      _px ... _nz or _forward ... _down. }
    function BfgImage(const AName: String; out GenPath, CoveragePath: String;
      out Face: Integer; out CameraCube: Boolean): Boolean;
    { Contents as a new stream (caller frees), nil when missing. }
    function OpenFile(const APath: String): TStream;
    { Contents as a string, '' when missing. }
    function ReadText(const APath: String): String;
    { All files whose normalized path starts with APrefix and ends with
      AExtension (e.g. 'maps/', '.proc'), sorted. Caller frees. }
    function FindFiles(const APrefix, AExtension: String): TStringList;
    function FileCount: Integer;
    function SourceCount: Integer;

    { Register the "d3fs:" protocol, e.g. d3fs:/textures/base_wall/a_d.tga }
    procedure RegisterProtocol;
  end;

{ Lowercase, "/" separators, no leading slash. }
function NormalizeD3Path(const S: String): String;
{ URL of a file inside the virtual file system. }
function D3FsUrl(const APath: String): String;

{ Load profiling: LoadProfileStart, then LoadProfileStep after each phase
  (it adds "name seconds" to LoadProfile); LoadProfileLog writes them. }
procedure LoadProfileStart;
procedure LoadProfileStep(const Name: String);
procedure LoadProfileLog(const Title: String);
{ The process's memory: private bytes and working set (Windows; 0
  elsewhere) and the Pascal heap in use, in MB. }
procedure ProcessMemory(out PrivateMB, WorkingSetMB, HeapMB: Single);
function ProcessMemoryText: String;

var
  D3Fs: TDoom3FileSystem;
  { Doom 3 BFG data: makes the source file (a .tga or .wav in memory) from
    its generated binary; nil when it can't. Set by Doom3Images. }
  BfgConvertHook: function (const APath: String): TStream;
  LoadProfile: String;
  { time spent (and calls) reading files, evaluating image programs (with
    their reads); LoadProfileLog writes and resets them }
  ProfileReadSeconds, ProfileImageSeconds: Double;
  ProfileReadCount, ProfileImageCount: Integer;

implementation

uses
  ZStream, CastleFilesUtils, CastleFindFiles, CastleStringUtils, CastleTimeUtils, CastleInternalZLib
  {$ifdef MSWINDOWS}, Windows{$endif}
  {$ifdef UNIX}, BaseUnix{$endif};

var
  LoadProfileTime, LoadProfileStartTime: TTimerResult;

{$ifdef MSWINDOWS}
type
  TD3ProcessMemoryCounters = record
    cb: DWORD;
    PageFaultCount: DWORD;
    PeakWorkingSetSize, WorkingSetSize, QuotaPeakPagedPoolUsage, QuotaPagedPoolUsage,
      QuotaPeakNonPagedPoolUsage, QuotaNonPagedPoolUsage, PagefileUsage, PeakPagefileUsage,
      PrivateUsage: PtrUInt;
  end;

function D3GetProcessMemoryInfo(Process: THandle; out Counters: TD3ProcessMemoryCounters;
  Size: DWORD): LongBool; stdcall; external 'psapi.dll' name 'GetProcessMemoryInfo';
{$endif}

procedure ProcessMemory(out PrivateMB, WorkingSetMB, HeapMB: Single);
{$ifdef MSWINDOWS}
var
  C: TD3ProcessMemoryCounters;
{$endif}
begin
  PrivateMB := 0;
  WorkingSetMB := 0;
  HeapMB := GetFPCHeapStatus.CurrHeapUsed / (1024 * 1024);
  {$ifdef MSWINDOWS}
  FillChar(C, SizeOf(C), 0);
  C.cb := SizeOf(C);
  if D3GetProcessMemoryInfo(GetCurrentProcess, C, SizeOf(C)) then
  begin
    PrivateMB := C.PrivateUsage / (1024 * 1024);
    WorkingSetMB := C.WorkingSetSize / (1024 * 1024);
  end;
  {$endif}
end;

function ProcessMemoryText: String;
var
  P, W, H: Single;
begin
  ProcessMemory(P, W, H);
  Result := Format('process %.0f MB (working set %.0f MB), Pascal heap %.0f MB', [P, W, H]);
end;

procedure LoadProfileStart;
begin
  LoadProfile := '';
  LoadProfileTime := Timer;
  LoadProfileStartTime := LoadProfileTime;
end;

procedure LoadProfileStep(const Name: String);
var
  Now: TTimerResult;
begin
  Now := Timer;
  if LoadProfile <> '' then
    LoadProfile := LoadProfile + ', ';
  LoadProfile := LoadProfile + Format('%s %.2f', [Name, TimerSeconds(Now, LoadProfileTime)]);
  LoadProfileTime := Now;
end;

procedure LoadProfileLog(const Title: String);
begin
  WritelnLog('Profile', '%s: %.2f s (%s; %d file reads %.2f s, %d image programs %.2f s)',
    [Title, TimerSeconds(Timer, LoadProfileStartTime), LoadProfile,
     ProfileReadCount, ProfileReadSeconds, ProfileImageCount, ProfileImageSeconds]);
  ProfileReadSeconds := 0;
  ProfileImageSeconds := 0;
  ProfileReadCount := 0;
  ProfileImageCount := 0;
end;

function NormalizeD3Path(const S: String): String;
var
  I: Integer;
begin
  Result := LowerCase(S);
  for I := 1 to Length(Result) do
    if Result[I] = '\' then
      Result[I] := '/';
  while (Result <> '') and (Result[1] = '/') do
    Delete(Result, 1, 1);
  I := Pos('//', Result);
  while I > 0 do
  begin
    Delete(Result, I, 1);
    I := Pos('//', Result);
  end;
end;

function D3FsUrl(const APath: String): String;
begin
  Result := 'd3fs:/' + NormalizeD3Path(APath);
end;

{ TDoom3Source }

procedure TDoom3Source.MapData;
begin
  Data := nil;
  DataSize := 0;
  if Stream is TCustomMemoryStream then
  begin
    Data := TCustomMemoryStream(Stream).Memory;
    DataSize := Stream.Size;
    Exit;
  end;
  if not (Stream is THandleStream) or (Stream.Size = 0) then
    Exit;
  {$ifdef MSWINDOWS}
  FMapping := CreateFileMapping(THandleStream(Stream).Handle, nil, PAGE_READONLY, 0, 0, nil);
  if FMapping = 0 then
    Exit;
  Data := MapViewOfFile(FMapping, FILE_MAP_READ, 0, 0, 0);
  if Data = nil then
  begin
    CloseHandle(FMapping);
    FMapping := 0;
    Exit;
  end;
  DataSize := Stream.Size;
  {$endif}
  {$ifdef UNIX}
  Data := Fpmmap(nil, Stream.Size, PROT_READ, MAP_SHARED, THandleStream(Stream).Handle, 0);
  if (Data = nil) or (Data = MAP_FAILED) then
  begin
    Data := nil;
    Exit;
  end;
  DataSize := Stream.Size;
  {$endif}
end;

destructor TDoom3Source.Destroy;
begin
  if (Data <> nil) and not (Stream is TCustomMemoryStream) then
  begin
    {$ifdef MSWINDOWS}
    UnmapViewOfFile(Data);
    CloseHandle(FMapping);
    {$endif}
    {$ifdef UNIX}
    Fpmunmap(Data, DataSize);
    {$endif}
  end;
  Data := nil;
  FreeAndNil(Stream);
  inherited Destroy;
end;

type
  { A read-only stream over memory it doesn't own. }
  TPointerStream = class(TCustomMemoryStream)
  public
    constructor Create(const P: Pointer; const ASize: PtrInt);
  end;

constructor TPointerStream.Create(const P: Pointer; const ASize: PtrInt);
begin
  inherited Create;
  SetPointer(P, ASize);
end;

{$ifdef MSWINDOWS}
type
  { C's z_stream on Win64 is 88 bytes: CGE's TZStream (84) misses the
    trailing padding, and zlib refuses a stream of the wrong size.
    CGE PR 744 fixes TZStream (88), so the size passed to zlib
    is TZStream's rounded up to the pointer size (CZStreamSize). }
  TPaddedZStream = record
    Z: TZStream;
    Pad: LongWord;
  end;

const
  CZStreamSize = (SizeOf(TZStream) + SizeOf(Pointer) - 1) and not (SizeOf(Pointer) - 1);

var
  { the C zlib can't be used (no library, or it refused our stream) }
  CZLibFailed: Boolean;

{ Inflate with the C zlib; False when it can't be used. }
function InflateRawC(const Src: PByte; const SrcSize: PtrInt; const Dest: PByte; const DestSize: PtrInt): Boolean;
var
  S: TPaddedZStream;
  Res: Integer;
begin
  Result := False;
  if CZLibFailed or not CastleZLibInitialized then
    Exit;
  FillChar(S, SizeOf(S), 0);
  S.Z.next_in := Src;
  S.Z.avail_in := SrcSize;
  S.Z.next_out := Dest;
  S.Z.avail_out := DestSize;
  { negative window bits: raw deflate }
  if inflateInit2_(S.Z, -15, ZLIB_VERSION, CZStreamSize) <> Z_OK then
  begin
    CZLibFailed := True;
    WritelnLog('Doom3Files', 'The C zlib refused the stream, inflating with FPC''s');
    Exit;
  end;
  try
    Res := inflate(S.Z, Z_FINISH);
    if (Res <> Z_STREAM_END) and not ((Res = Z_BUF_ERROR) and (S.Z.avail_out = 0)) then
      raise Exception.CreateFmt('zlib inflate failed (%d)', [Res]);
  finally
    inflateEnd(S.Z);
  end;
  Result := True;
end;
{$endif}

{ Inflate raw deflate data (no zlib header) into Dest (DestSize bytes, the
  known uncompressed size): with the C zlib CGE loaded on Windows (several
  times faster), else FPC's. }
procedure InflateRaw(const Src: PByte; const SrcSize: PtrInt; const Dest: PByte; const DestSize: PtrInt);
var
  SrcStream: TPointerStream;
  Inflater: TDecompressionStream;
begin
  if DestSize = 0 then
    Exit;
  {$ifdef MSWINDOWS}
  if InflateRawC(Src, SrcSize, Dest, DestSize) then
    Exit;
  {$endif}
  SrcStream := TPointerStream.Create(Src, SrcSize);
  try
    { True: raw deflate data, without a zlib header }
    Inflater := TDecompressionStream.Create(SrcStream, True);
    try
      Inflater.ReadBuffer(Dest^, DestSize);
    finally
      Inflater.Free;
    end;
  finally
    SrcStream.Free;
  end;
end;

{ TDoom3FileSystem }

constructor TDoom3FileSystem.Create;
begin
  inherited Create;
  FSources := specialize TObjectList<TDoom3Source>.Create(True);
  FEntries := specialize TList<TDoom3FileEntry>.Create;
  FIndex := specialize TDictionary<String, Integer>.Create;
  FBfgImages := specialize TDictionary<String, String>.Create;
end;

destructor TDoom3FileSystem.Destroy;
begin
  if FProtocolRegistered then
    UnregisterUrlProtocol('d3fs');
  FIndex.Free;
  FBfgImages.Free;
  FEntries.Free;
  FSources.Free;
  inherited Destroy;
end;

procedure TDoom3FileSystem.AddEntry(const Entry: TDoom3FileEntry);
var
  Key: String;
  Existing: Integer;
begin
  Key := NormalizeD3Path(Entry.Path);
  if FIndex.TryGetValue(Key, Existing) then
    FEntries[Existing] := Entry
  else
    FIndex.Add(Key, FEntries.Add(Entry));
end;

{ Doom 3 BFG ----------------------------------------------------------------- }

const
  BfgImagePrefix = 'generated/images/';

{ A ".resources" container: magic, the table's offset and size (big endian),
  then at the table the number of files and for each its name (little
  endian length), offset and size (big endian). Files aren't compressed. }
function TDoom3FileSystem.AddResources(const FileName: String): Boolean;
const
  ResourceMagic = $D000000D;
var
  Source: TDoom3Source;
  Entry: TDoom3FileEntry;
  Header: array [0..11] of Byte;
  Table: array of Byte;
  TableOffset, TableSize, Count, NameLen: UInt32;
  P, I, SourceIndex, Hash: Integer;
  Key, Name, Code, Codes: String;

  function Big(const Offset: Integer): UInt32;
  begin
    Result := (UInt32(Table[Offset]) shl 24) or (UInt32(Table[Offset + 1]) shl 16) or
      (UInt32(Table[Offset + 2]) shl 8) or Table[Offset + 3];
  end;

begin
  Result := False;
  Source := TDoom3Source.Create;
  try
    Source.Name := FileName;
    Source.IsResources := True;
    Source.Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
    if Source.Stream.Read(Header, 12) <> 12 then
      Exit;
    if ((UInt32(Header[0]) shl 24) or (UInt32(Header[1]) shl 16) or (UInt32(Header[2]) shl 8) or Header[3]) <> ResourceMagic then
      Exit;
    TableOffset := (UInt32(Header[4]) shl 24) or (UInt32(Header[5]) shl 16) or (UInt32(Header[6]) shl 8) or Header[7];
    TableSize := (UInt32(Header[8]) shl 24) or (UInt32(Header[9]) shl 16) or (UInt32(Header[10]) shl 8) or Header[11];
    if (TableSize < 4) or (Int64(TableOffset) + TableSize > Source.Stream.Size) then
      Exit;
    SetLength(Table, TableSize);
    Source.Stream.Position := TableOffset;
    Source.Stream.ReadBuffer(Table[0], TableSize);
    SourceIndex := FSources.Add(Source);
    Source := nil;
    Count := Big(0);
    P := 4;
    for I := 0 to Integer(Count) - 1 do
    begin
      if P + 4 > Integer(TableSize) then
        Break;
      NameLen := Table[P] or (UInt32(Table[P + 1]) shl 8) or (UInt32(Table[P + 2]) shl 16) or (UInt32(Table[P + 3]) shl 24);
      Inc(P, 4);
      if P + Integer(NameLen) + 8 > Integer(TableSize) then
        Break;
      SetLength(Name, NameLen);
      if NameLen > 0 then
        Move(Table[P], Name[1], NameLen);
      Inc(P, NameLen);
      Entry := Default(TDoom3FileEntry);
      Entry.Path := Name;
      Entry.SourceIndex := SourceIndex;
      Entry.HeaderOffset := Big(P);
      Entry.Size := Big(P + 4);
      Entry.CompressedSize := Entry.Size;
      Inc(P, 8);
      AddEntry(Entry);
      { index the images by name: "<name>#__<code>.bimage" }
      Key := NormalizeD3Path(Name);
      if (Copy(Key, 1, Length(BfgImagePrefix)) = BfgImagePrefix) and (ExtractFileExt(Key) = '.bimage') then
      begin
        Hash := Pos('#__', Key);
        if Hash > 0 then
        begin
          Code := Copy(Key, Hash + 3, Length(Key) - Hash - 2 - Length('.bimage'));
          Key := Copy(Key, Length(BfgImagePrefix) + 1, Hash - Length(BfgImagePrefix) - 1);
          if FBfgImages.TryGetValue(Key, Codes) then
          begin
            if Pos(Code, Codes) = 0 then
              FBfgImages[Key] := Codes + ' ' + Code;
          end else
            FBfgImages.Add(Key, Code);
        end;
      end;
    end;
    FBfg := True;
    Result := True;
  finally
    Source.Free;
  end;
end;

function TDoom3FileSystem.ReadResourceEntry(const Entry: TDoom3FileEntry): TMemoryStream;
var
  Source: TDoom3Source;
begin
  Source := FSources[Entry.SourceIndex];
  Result := TMemoryStream.Create;
  try
    Result.Size := Entry.Size;
    Source.Stream.Position := Entry.HeaderOffset;
    if Entry.Size > 0 then
      Source.Stream.ReadBuffer(Result.Memory^, Entry.Size);
  except
    Result.Free;
    raise;
  end;
end;

function TDoom3FileSystem.BfgImage(const AName: String; out GenPath, CoveragePath: String;
  out Face: Integer; out CameraCube: Boolean): Boolean;
const
  { the codes are the image's usage (textureUsage_t) and cube kind: a 2D
    image is drawn from its diffuse, plain, specular, bump or light version }
  Preferred: array [0..4] of String = ('0100', '0200', '0000', '0300', '0500');
  CubeSides: array [0..5] of String = ('_px', '_nx', '_py', '_ny', '_pz', '_nz');
  CameraSides: array [0..5] of String = ('_forward', '_back', '_left', '_right', '_up', '_down');
var
  Key, Codes, Code, Base: String;
  Parts: TStringArray;
  I: Integer;
begin
  Result := False;
  GenPath := '';
  CoveragePath := '';
  Face := 0;
  CameraCube := False;
  if not FBfg then
    Exit;
  Key := NormalizeD3Path(AName);
  if FBfgImages.TryGetValue(Key, Codes) then
  begin
    Code := '';
    for I := 0 to High(Preferred) do
      if Pos(Preferred[I], Codes) > 0 then
      begin
        Code := Preferred[I];
        Break;
      end;
    if Code = '' then
    begin
      { any other 2D version }
      Parts := Codes.Split([' ']);
      for I := 0 to High(Parts) do
        if Copy(Parts[I], 3, 2) = '00' then
          Code := Parts[I];
    end;
    if Code <> '' then
    begin
      GenPath := BfgImagePrefix + Key + '#__' + Code + '.bimage';
      if (Code = '0100') and (Pos('1000', Codes) > 0) then
        CoveragePath := BfgImagePrefix + Key + '#__1000.bimage';
      Exit(True);
    end;
  end;
  for I := 0 to 5 do
  begin
    if Copy(Key, Length(Key) - Length(CubeSides[I]) + 1, MaxInt) = CubeSides[I] then
    begin
      Base := Copy(Key, 1, Length(Key) - Length(CubeSides[I]));
      if FBfgImages.TryGetValue(Base, Codes) and (Pos('01 ', Codes + ' ') > 0) then
      begin
        Parts := Codes.Split([' ']);
        for Code in Parts do
          if Copy(Code, 3, 2) = '01' then
            GenPath := BfgImagePrefix + Base + '#__' + Code + '.bimage';
        Face := I;
        Exit(GenPath <> '');
      end;
    end;
    if Copy(Key, Length(Key) - Length(CameraSides[I]) + 1, MaxInt) = CameraSides[I] then
    begin
      Base := Copy(Key, 1, Length(Key) - Length(CameraSides[I]));
      if FBfgImages.TryGetValue(Base, Codes) and (Pos('02 ', Codes + ' ') > 0) then
      begin
        Parts := Codes.Split([' ']);
        for Code in Parts do
          if Copy(Code, 3, 2) = '02' then
            GenPath := BfgImagePrefix + Base + '#__' + Code + '.bimage';
        Face := I;
        CameraCube := True;
        Exit(GenPath <> '');
      end;
    end;
  end;
end;

function TDoom3FileSystem.BfgGenerated(const APath: String): String;
var
  Key, Ext, Coverage: String;
  Face: Integer;
  Camera: Boolean;
begin
  Result := '';
  if not FBfg then
    Exit;
  Key := NormalizeD3Path(APath);
  Ext := ExtractFileExt(Key);
  if Ext = '.proc' then
    Result := 'generated/' + ChangeFileExt(Key, '.bproc')
  else
  if Ext = '.cm' then
    Result := 'generated/' + ChangeFileExt(Key, '.bcm')
  else
  if Ext = '.md5mesh' then
    Result := 'generated/rendermodels/' + ChangeFileExt(Key, '.bmd5mesh')
  else
  if Ext = '.md5anim' then
    Result := 'generated/anim/' + ChangeFileExt(Key, '.bmd5anim')
  else
  if Ext = '.lwo' then
    Result := 'generated/rendermodels/' + ChangeFileExt(Key, '.blwo')
  else
  if Ext = '.ase' then
    Result := 'generated/rendermodels/' + ChangeFileExt(Key, '.base')
  else
  if Ext = '.wav' then
  begin
    { speech is per language (idSoundSample::LoadResource) }
    if Pos('/vo/', Key) > 0 then
    begin
      Result := 'generated/' + ChangeFileExt(StringReplace(Key, '/vo/', '/vo/english/', []), '.idwav');
      if FIndex.ContainsKey(Result) then
        Exit;
    end;
    Result := 'generated/' + ChangeFileExt(Key, '.idwav');
  end else
  if Ext = '.tga' then
  begin
    if not BfgImage(ChangeFileExt(Key, ''), Result, Coverage, Face, Camera) then
      Result := '';
    Exit;
  end else
    Exit;
  if not FIndex.ContainsKey(Result) then
    Result := '';
end;

function TDoom3FileSystem.OpenGenerated(const APath: String): TStream;
var
  G: String;
begin
  G := BfgGenerated(APath);
  if G = '' then
    Exit(nil);
  Result := OpenFile(G);
end;

function TDoom3FileSystem.FindEntry(const APath: String; out Entry: TDoom3FileEntry): Boolean;
var
  Idx: Integer;
begin
  Result := FIndex.TryGetValue(NormalizeD3Path(APath), Idx);
  if Result then
    Entry := FEntries[Idx];
end;

type
  TZipEndOfCentralDir = packed record
    Signature: LongWord; { $06054b50 }
    DiskNumber, CentralDirDisk: Word;
    EntriesThisDisk, EntriesTotal: Word;
    CentralDirSize, CentralDirOffset: LongWord;
    CommentLength: Word;
  end;

  TZipCentralHeader = packed record
    Signature: LongWord; { $02014b50 }
    VersionMadeBy, VersionNeeded, Flags, Method: Word;
    ModTime, ModDate: Word;
    Crc32, CompressedSize, UncompressedSize: LongWord;
    NameLength, ExtraLength, CommentLength: Word;
    DiskStart, InternalAttr: Word;
    ExternalAttr, LocalHeaderOffset: LongWord;
  end;

  TZipLocalHeader = packed record
    Signature: LongWord; { $04034b50 }
    VersionNeeded, Flags, Method: Word;
    ModTime, ModDate: Word;
    Crc32, CompressedSize, UncompressedSize: LongWord;
    NameLength, ExtraLength: Word;
  end;

function TDoom3FileSystem.AddPk4(const AUrlOrFilename: String): Boolean;
var
  Source: TDoom3Source;
  Stream: TStream;
  FileName: String;
  Tail: TBytes;
  TailSize, I, P: Integer;
  Eocd: TZipEndOfCentralDir;
  Central: TZipCentralHeader;
  Name: String;
  Entry: TDoom3FileEntry;
  SourceIndex: Integer;
begin
  Result := False;
  try
    FileName := UriToFilenameSafe(AUrlOrFilename);
    if (FileName <> '') and SysUtils.FileExists(FileName) then
      Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite)
    else
      Stream := Download(AUrlOrFilename, [soForceMemoryStream]);
  except
    on E: Exception do
    begin
      WritelnWarning('Doom3Files', 'Cannot open PK4 "%s": %s', [AUrlOrFilename, E.Message]);
      Exit;
    end;
  end;

  try
    { Find the end of central directory record (at most 64 KB of comment). }
    TailSize := Stream.Size;
    if TailSize > 65536 + SizeOf(Eocd) then
      TailSize := 65536 + SizeOf(Eocd);
    if TailSize < SizeOf(Eocd) then
      raise Exception.Create('File too small to be a ZIP');
    SetLength(Tail, TailSize);
    Stream.Position := Stream.Size - TailSize;
    Stream.ReadBuffer(Tail[0], TailSize);
    P := -1;
    for I := TailSize - SizeOf(Eocd) downto 0 do
      if (Tail[I] = $50) and (Tail[I + 1] = $4b) and (Tail[I + 2] = $05) and (Tail[I + 3] = $06) then
      begin
        P := I;
        Break;
      end;
    if P < 0 then
      raise Exception.Create('ZIP end of central directory not found');
    Move(Tail[P], Eocd, SizeOf(Eocd));

    Source := TDoom3Source.Create;
    Source.Name := AUrlOrFilename;
    Source.Stream := Stream;
    Source.MapData;
    SourceIndex := FSources.Add(Source);
    Stream := nil; { owned by Source now }

    Source.Stream.Position := Eocd.CentralDirOffset;
    for I := 0 to Eocd.EntriesTotal - 1 do
    begin
      Source.Stream.ReadBuffer(Central, SizeOf(Central));
      if Central.Signature <> $02014b50 then
        raise Exception.CreateFmt('Bad ZIP central directory entry %d', [I]);
      SetLength(Name, Central.NameLength);
      if Central.NameLength > 0 then
        Source.Stream.ReadBuffer(Name[1], Central.NameLength);
      Source.Stream.Seek(Central.ExtraLength + Central.CommentLength, soCurrent);
      if (Name = '') or (Name[Length(Name)] = '/') then
        Continue; { directory }
      Entry.Path := Name;
      Entry.SourceIndex := SourceIndex;
      Entry.HeaderOffset := Central.LocalHeaderOffset;
      Entry.Method := Central.Method;
      Entry.CompressedSize := Central.CompressedSize;
      Entry.Size := Central.UncompressedSize;
      AddEntry(Entry);
    end;
    WritelnLog('Doom3Files', 'Added PK4 "%s": %d files (%d indexed)',
      [AUrlOrFilename, Integer(Eocd.EntriesTotal), FEntries.Count]);
    Result := True;
  except
    on E: Exception do
    begin
      FreeAndNil(Stream);
      WritelnWarning('Doom3Files', 'Invalid PK4 "%s": %s', [AUrlOrFilename, E.Message]);
    end;
  end;
end;

procedure TDoom3FileSystem.ScanDirectory(const Root, Sub: String; const SourceIndex: Integer);
var
  Info: TSearchRec;
  Entry: TDoom3FileEntry;
begin
  if FindFirst(Root + Sub + '*', faAnyFile, Info) = 0 then
  try
    repeat
      if (Info.Name = '.') or (Info.Name = '..') then
        Continue;
      if (Info.Attr and faDirectory) <> 0 then
        ScanDirectory(Root, Sub + Info.Name + PathDelim, SourceIndex)
      else
      if not SameText(ExtractFileExt(Info.Name), '.pk4') then
      begin
        Entry.Path := StringReplace(Sub + Info.Name, PathDelim, '/', [rfReplaceAll]);
        Entry.SourceIndex := SourceIndex;
        Entry.HeaderOffset := 0;
        Entry.Method := 0;
        Entry.CompressedSize := Info.Size;
        Entry.Size := Info.Size;
        AddEntry(Entry);
      end;
    until FindNext(Info) <> 0;
  finally
    SysUtils.FindClose(Info);
  end;
end;

function TDoom3FileSystem.AddDirectory(const Dir: String): Boolean;
var
  Source: TDoom3Source;
  Before: Integer;
begin
  Result := DirectoryExists(Dir);
  if not Result then
    Exit;
  Source := TDoom3Source.Create;
  Source.Name := Dir;
  Source.IsDirectory := True;
  Source.Directory := IncludeTrailingPathDelimiter(ExpandFileName(Dir));
  Before := FEntries.Count;
  ScanDirectory(Source.Directory, '', FSources.Add(Source));
  WritelnLog('Doom3Files', 'Added directory "%s" (%d new files)', [Dir, FEntries.Count - Before]);
end;

function TDoom3FileSystem.AddGameDirectory(const Dir: String): Boolean;
var
  Info: TSearchRec;
  Names: TStringList;
  Name: String;
begin
  Result := False;
  if not DirectoryExists(Dir) then
    Exit;
  Names := TStringList.Create;
  try
    if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*.pk4', faAnyFile, Info) = 0 then
    try
      repeat
        Names.Add(Info.Name);
      until FindNext(Info) <> 0;
    finally
      SysUtils.FindClose(Info);
    end;
    Names.Sort; { pak000 < pak001 < ... < zpak_mod, like idFileSystem }
    for Name in Names do
      if AddPk4(IncludeTrailingPathDelimiter(Dir) + Name) then
        Result := True;
    { Doom 3 BFG: _common, _ordered, the sounds (English speech), then
      every map's container }
    Names.Clear;
    if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*.resources', faAnyFile, Info) = 0 then
    try
      repeat
        Name := LowerCase(Info.Name);
        if (Copy(Name, 1, 10) <> '_sound_pc_') or (Name = '_sound_pc_en.resources') then
          Names.Add(Info.Name);
      until FindNext(Info) <> 0;
    finally
      SysUtils.FindClose(Info);
    end;
    Names.Sort;
    for Name in Names do
      if AddResources(IncludeTrailingPathDelimiter(Dir) + Name) then
        Result := True;
    if Names.Count > 0 then
    begin
      Names.Clear;
      if FindFirst(IncludeTrailingPathDelimiter(Dir) + 'maps' + PathDelim + '*.resources', faAnyFile, Info) = 0 then
      try
        repeat
          Names.Add(Info.Name);
        until FindNext(Info) <> 0;
      finally
        SysUtils.FindClose(Info);
      end;
      Names.Sort;
      for Name in Names do
        AddResources(IncludeTrailingPathDelimiter(Dir) + 'maps' + PathDelim + Name);
      WritelnLog('Doom3Files', 'Doom 3 BFG data: %d files in the .resources containers of "%s" (%d images)',
        [FEntries.Count, Dir, FBfgImages.Count]);
    end;
  finally
    Names.Free;
  end;
  if AddDirectory(Dir) then
    Result := True;
end;

function TDoom3FileSystem.HasSource(const Name: String): Boolean;
var
  S: TDoom3Source;
begin
  for S in FSources do
    if S.Name = Name then
      Exit(True);
  Result := False;
end;

function TDoom3FileSystem.FileExists(const APath: String): Boolean;
begin
  Result := FIndex.ContainsKey(NormalizeD3Path(APath)) or (FBfg and (BfgGenerated(APath) <> ''));
end;

function TDoom3FileSystem.ReadZipEntry(const Entry: TDoom3FileEntry): TMemoryStream;
var
  Source: TDoom3Source;
  Local: TZipLocalHeader;
  PackedData: TMemoryStream;
  DataStart: Int64;
begin
  Source := FSources[Entry.SourceIndex];
  if Source.Data <> nil then
  begin
    { the mapped archive: no copies of the packed data }
    if Entry.HeaderOffset + SizeOf(Local) > Source.DataSize then
      raise Exception.CreateFmt('Bad ZIP offset for "%s"', [Entry.Path]);
    Move(Source.Data[Entry.HeaderOffset], Local, SizeOf(Local));
    if Local.Signature <> $04034b50 then
      raise Exception.CreateFmt('Bad ZIP local header for "%s"', [Entry.Path]);
    DataStart := Entry.HeaderOffset + SizeOf(Local) + Local.NameLength + Local.ExtraLength;
    if DataStart + Entry.CompressedSize > Source.DataSize then
      raise Exception.CreateFmt('Truncated ZIP data for "%s"', [Entry.Path]);
    Result := TMemoryStream.Create;
    try
      Result.Size := Entry.Size;
      case Entry.Method of
        0: if Entry.Size > 0 then
             Move(Source.Data[DataStart], Result.Memory^, Entry.Size);
        8: InflateRaw(@Source.Data[DataStart], Entry.CompressedSize, Result.Memory, Entry.Size);
        else
          raise Exception.CreateFmt('Unsupported ZIP compression method %d for "%s"',
            [Entry.Method, Entry.Path]);
      end;
      Result.Position := 0;
    except
      FreeAndNil(Result);
      raise;
    end;
    Exit;
  end;
  Source.Stream.Position := Entry.HeaderOffset;
  Source.Stream.ReadBuffer(Local, SizeOf(Local));
  if Local.Signature <> $04034b50 then
    raise Exception.CreateFmt('Bad ZIP local header for "%s"', [Entry.Path]);
  Source.Stream.Seek(Local.NameLength + Local.ExtraLength, soCurrent);

  Result := TMemoryStream.Create;
  try
    case Entry.Method of
      0:
        if Entry.Size > 0 then
          Result.CopyFrom(Source.Stream, Entry.Size);
      8:
        begin
          PackedData := TMemoryStream.Create;
          try
            if Entry.CompressedSize > 0 then
              PackedData.CopyFrom(Source.Stream, Entry.CompressedSize);
            Result.Size := Entry.Size;
            InflateRaw(PackedData.Memory, PackedData.Size, Result.Memory, Entry.Size);
          finally
            PackedData.Free;
          end;
        end;
      else
        raise Exception.CreateFmt('Unsupported ZIP compression method %d for "%s"',
          [Entry.Method, Entry.Path]);
    end;
    Result.Position := 0;
  except
    FreeAndNil(Result);
    raise;
  end;
end;

function TDoom3FileSystem.OpenFile(const APath: String): TStream;
var
  Entry: TDoom3FileEntry;
  Source: TDoom3Source;
  Mem: TMemoryStream;
  Start: TTimerResult;
begin
  Result := nil;
  if not FindEntry(APath, Entry) then
  begin
    { Doom 3 BFG: an image or a sound from its generated binary }
    if FBfg and Assigned(BfgConvertHook) and (BfgGenerated(APath) <> '') then
      Result := BfgConvertHook(NormalizeD3Path(APath));
    Exit;
  end;
  Start := Timer;
  Inc(ProfileReadCount);
  Source := FSources[Entry.SourceIndex];
  try
    if Source.IsDirectory then
    begin
      Mem := TMemoryStream.Create;
      try
        Mem.LoadFromFile(Source.Directory + StringReplace(Entry.Path, '/', PathDelim, [rfReplaceAll]));
      except
        Mem.Free;
        raise;
      end;
      Result := Mem;
    end else
    if Source.IsResources then
      Result := ReadResourceEntry(Entry)
    else
      Result := ReadZipEntry(Entry);
  except
    on E: Exception do
    begin
      WritelnWarning('Doom3Files', 'Cannot read "%s": %s', [APath, E.Message]);
      Result := nil;
    end;
  end;
  ProfileReadSeconds := ProfileReadSeconds + TimerSeconds(Timer, Start);
end;

function TDoom3FileSystem.ReadText(const APath: String): String;
var
  S: TStream;
begin
  Result := '';
  S := OpenFile(APath);
  if S = nil then
    Exit;
  try
    SetLength(Result, S.Size);
    if S.Size > 0 then
      S.ReadBuffer(Result[1], S.Size);
  finally
    S.Free;
  end;
end;

function TDoom3FileSystem.FindFiles(const APrefix, AExtension: String): TStringList;
var
  Key, Prefix, Ext: String;
begin
  Result := TStringList.Create;
  Prefix := NormalizeD3Path(APrefix);
  Ext := LowerCase(AExtension);
  for Key in FIndex.Keys do
    if ((Prefix = '') or (Copy(Key, 1, Length(Prefix)) = Prefix)) and
       ((Ext = '') or (ExtractFileExt(Key) = Ext)) then
      Result.Add(Key);
  { Doom 3 BFG: the maps are binary .bproc files }
  if FBfg and (Ext = '.proc') then
    for Key in FIndex.Keys do
      if (ExtractFileExt(Key) = '.bproc') and (Copy(Key, 1, 10 + Length(Prefix)) = 'generated/' + Prefix) then
        Result.Add(ChangeFileExt(Copy(Key, 11, MaxInt), '.proc'));
  Result.Sort;
end;

function TDoom3FileSystem.FileCount: Integer;
begin
  Result := FEntries.Count;
end;

function TDoom3FileSystem.SourceCount: Integer;
begin
  Result := FSources.Count;
end;

function TDoom3FileSystem.ReadUrl(const Url: String; out MimeType: String): TStream;
var
  Path: String;
  P: Integer;
begin
  Path := Url;
  P := Pos(':', Path);
  if P > 0 then
    Delete(Path, 1, P);
  Path := RawUriDecode(Path);
  Result := OpenFile(Path);
  if Result = nil then
    raise EFOpenError.Create('File not found in Doom 3 file system: ' + Url);
  { CGE picks the image / sound loader by the MIME type }
  MimeType := UriMimeType(Path);
end;

procedure TDoom3FileSystem.RegisterProtocol;
begin
  if FProtocolRegistered then
    Exit;
  RegisterUrlProtocol('d3fs', @ReadUrl, nil);
  FProtocolRegistered := True;
end;

initialization
  D3Fs := TDoom3FileSystem.Create;
finalization
  FreeAndNil(D3Fs);
end.
