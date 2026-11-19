{ The title menu's Doom 3 data: finding installs (Doom3Installs), Steam's
  libraryfolders.vdf, the saved choice, and extracting demo/demo00.pk4
  from a .run file like the Linux demo's (Doom3DemoDownload), all on
  files these tests write. }

procedure TestInstallsAndDemoExtract;
var
  Dir, D3, Bfg, Demo, Cfg, BasePath, GameDir, RunFile, OutFile: String;
  List: TD3InstallList;
  Libs: TStringList;
  I: Integer;
  Tar, Run, Deflated: TMemoryStream;
  Z: TCompressionStream;
  Payload: String;
  Got: TStringList;
  GzHeader: array [0..9] of Byte = ($1F, $8B, 8, 0, 0, 0, 0, 0, 0, 3);

  procedure Touch(const FileName: String);
  var
    F: TFileStream;
  begin
    ForceDirectories(ExtractFileDir(FileName));
    F := TFileStream.Create(FileName, fmCreate);
    F.Free;
  end;

  procedure AddTarEntry(const Name, Content: String);
  var
    H: array [0..511] of Byte;
    SizeOct: String;
    Sum, J: Integer;
    Pad: Integer;
  begin
    FillChar(H, SizeOf(H), 0);
    Move(Name[1], H[0], Length(Name));
    SizeOct := Format('%.11s', [OctStr(Length(Content), 11)]);
    Move(SizeOct[1], H[124], 11);
    H[156] := Ord('0');
    Move(PChar('ustar ')^, H[257], 6);
    for J := 148 to 155 do
      H[J] := Ord(' ');
    Sum := 0;
    for J := 0 to 511 do
      Inc(Sum, H[J]);
    SizeOct := OctStr(Sum, 6);
    Move(SizeOct[1], H[148], 6);
    Tar.WriteBuffer(H, 512);
    if Content <> '' then
      Tar.WriteBuffer(Content[1], Length(Content));
    Pad := (512 - Length(Content) mod 512) mod 512;
    for J := 1 to Pad do
      Tar.WriteByte(0);
  end;

begin
  { Steam's library list }
  Libs := SteamLibraryPaths('"libraryfolders"' + LineEnding + '{' + LineEnding +
    #9'"0"' + LineEnding + #9'{' + LineEnding + #9#9'"path"'#9#9'"C:\\Program Files (x86)\\Steam"' + LineEnding +
    #9#9'"apps"' + LineEnding + #9#9'{' + LineEnding + #9#9#9'"9050"'#9#9'"1"' + LineEnding + #9#9'}' + LineEnding +
    #9'}' + LineEnding + #9'"1"' + LineEnding + #9'{' + LineEnding + #9#9'"path"'#9#9'"D:\\SteamLibrary"' + LineEnding +
    #9'}' + LineEnding + '}');
  try
    CheckEquals(2, Libs.Count, 'libraryfolders.vdf: 2 libraries');
    if Libs.Count = 2 then
    begin
      CheckEquals('C:\Program Files (x86)\Steam', Libs[0], 'libraryfolders.vdf: the first library');
      CheckEquals('D:\SteamLibrary', Libs[1], 'libraryfolders.vdf: the second library');
    end;
  finally
    Libs.Free;
  end;

  { installs: Doom 3 with Resurrection of Evil, the BFG edition, the demo }
  Dir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'castle_doom3_installs_test';
  D3 := Dir + PathDelim + 'Doom 3';
  Bfg := Dir + PathDelim + 'DOOM 3 BFG Edition';
  Demo := Dir + PathDelim + 'demo install';
  if DirectoryExists(Dir) then
    CastleFilesUtils.RemoveNonEmptyDir(Dir);
  Touch(D3 + PathDelim + 'base' + PathDelim + 'pak000.pk4');
  Touch(D3 + PathDelim + 'd3xp' + PathDelim + 'pak000.pk4');
  Touch(Bfg + PathDelim + 'base' + PathDelim + '_common.resources');
  Touch(Demo + PathDelim + 'demo' + PathDelim + 'demo00.pk4');
  { only game code: not an install }
  Touch(Dir + PathDelim + 'code only' + PathDelim + 'base' + PathDelim + 'game00.pk4');
  List := TD3InstallList.Create;
  try
    CheckEquals(2, AddInstallsIn(D3, 'GOG', List), 'installs: Doom 3 and Resurrection of Evil');
    CheckEquals(0, AddInstallsIn(D3 + PathDelim, 'Steam', List), 'installs: the same folder again adds nothing');
    CheckEquals(1, AddInstallsIn(Bfg, 'Steam', List), 'installs: the BFG edition');
    CheckEquals(1, AddInstallsIn(Demo, 'downloaded', List), 'installs: the demo');
    CheckEquals(0, AddInstallsIn(Dir + PathDelim + 'code only', 'GOG', List), 'installs: game00.pk4 alone is none');
    CheckEquals(0, AddInstallsIn(Dir + PathDelim + 'missing', 'GOG', List), 'installs: a missing folder');
    CheckEquals(4, List.Count, 'installs: 4 in all');
    if List.Count = 4 then
    begin
      Check(List[0].Kind = ikDoom3, 'installs: Doom 3 first');
      Check(List[1].Kind = ikRoe, 'installs: then Resurrection of Evil');
      CheckEquals('d3xp', List[1].GameDir, 'installs: Resurrection of Evil is -game d3xp');
      Check(SamePath(List[1].BasePath, D3), 'installs: Resurrection of Evil''s basepath is Doom 3''s');
      Check(List[2].Kind = ikBfg, 'installs: the BFG edition');
      Check(List[3].Kind = ikDemo, 'installs: the demo');
      CheckEquals('Doom 3 demo (downloaded)', List[3].Title, 'installs: the demo''s title');
    end;
  finally
    List.Free;
  end;

  { the saved choice }
  Cfg := Dir + PathDelim + 'cfg' + PathDelim + 'data.cfg';
  Check(not LoadDataChoiceFrom(Cfg, BasePath, GameDir), 'data.cfg: no choice before saving');
  SaveDataChoiceTo(Cfg, D3, 'd3xp');
  Check(LoadDataChoiceFrom(Cfg, BasePath, GameDir), 'data.cfg: a choice after saving');
  CheckEquals(D3, BasePath, 'data.cfg: basepath');
  CheckEquals('d3xp', GameDir, 'data.cfg: game');
  SaveDataChoiceTo(Cfg, '', '');
  Check(LoadDataChoiceFrom(Cfg, BasePath, GameDir) and (BasePath = ''), 'data.cfg: the test level alone is a choice too');

  { a .run like the demo's: a 373 line script, then a gzipped tar }
  Payload := '';
  for I := 0 to 69999 do
    Payload := Payload + Chr(Ord('a') + (I * 7 + I div 13) mod 26);
  Tar := TMemoryStream.Create;
  Run := TMemoryStream.Create;
  Deflated := TMemoryStream.Create;
  try
    AddTarEntry('README', 'not this one');
    AddTarEntry('demo/', '');
    AddTarEntry('demo/demo00.pk4', Payload);
    AddTarEntry('demo/after', 'x');
    for I := 1 to 1024 do
      Tar.WriteByte(0);
    Z := TCompressionStream.Create(clDefault, Deflated, True);
    try
      Z.WriteBuffer(Tar.Memory^, Tar.Size);
    finally
      Z.Free;
    end;
    for I := 1 to 373 do
      Run.WriteBuffer(PChar('# script line' + #10)^, 14);
    Run.WriteBuffer(GzHeader, SizeOf(GzHeader));
    Run.CopyFrom(Deflated, 0);
    { the gzip trailer (CRC32, size), not checked }
    for I := 1 to 8 do
      Run.WriteByte(0);
    CheckEquals(373 * 14, FindRunArchive(Run), 'demo .run: the archive after the script');
    RunFile := Dir + PathDelim + 'test.run';
    Run.SaveToFile(RunFile);
  finally
    Tar.Free;
    Run.Free;
    Deflated.Free;
  end;
  OutFile := Dir + PathDelim + 'out' + PathDelim + 'demo' + PathDelim + 'demo00.pk4';
  ExtractDemoPk4(RunFile, OutFile, False, nil, nil);
  Got := TStringList.Create;
  try
    Check(FileExists(OutFile), 'demo .run: demo00.pk4 extracted');
    Check(not FileExists(OutFile + '.part'), 'demo .run: no .part file left');
    if FileExists(OutFile) then
    begin
      Got.LoadFromFile(OutFile);
      CheckEquals(Payload, Got.Text.TrimRight, 'demo .run: demo00.pk4''s content');
    end;
  finally
    Got.Free;
  end;
  { the real demo's MD5 check refuses this one }
  try
    ExtractDemoPk4(RunFile, OutFile + '2', True, nil, nil);
    Check(False, 'demo .run: a wrong MD5 raises');
  except
    on E: Exception do
      Check(Pos('MD5', E.Message) > 0, 'demo .run: a wrong MD5 raises (' + E.Message + ')');
  end;
  Check(not FileExists(OutFile + '2'), 'demo .run: nothing kept after a wrong MD5');
  CastleFilesUtils.RemoveNonEmptyDir(Dir);
end;
