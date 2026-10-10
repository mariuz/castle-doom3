{ Unit tests for Castle Doom 3's idTech 4 file parsers, using the bundled
  test PK4 (data/base/castle_doom3_test.pk4, made by tools/make_test_pk4.py).
  Exit code 0 = all passed. Run from this directory:
    castle-engine compile && ./castle-doom3-tests }
program castle_doom3_tests;

{$apptype console}
{$mode objfpc}{$H+}

uses
  {$ifdef UNIX} CThreads, {$endif}
  SysUtils, Classes, Math,
  CastleVectors, CastleLog, CastleImages,
  Doom3Files, Doom3Lexer, Doom3Decls, Doom3Images, Doom3Proc, Doom3MapFile, Doom3Md5;

var
  Passed, Failed: Integer;

procedure Check(const Condition: Boolean; const What: String);
begin
  if Condition then
    Inc(Passed)
  else
  begin
    Inc(Failed);
    Writeln('FAIL: ', What);
  end;
end;

procedure CheckEquals(const Expected, Actual: Int64; const What: String); overload;
begin
  Check(Expected = Actual, Format('%s: expected %d, got %d', [What, Expected, Actual]));
end;

procedure CheckEquals(const Expected, Actual: String; const What: String); overload;
begin
  Check(Expected = Actual, Format('%s: expected "%s", got "%s"', [What, Expected, Actual]));
end;

procedure CheckNear(const Expected, Actual: Single; const What: String; const Eps: Single = 0.01);
begin
  Check(Abs(Expected - Actual) <= Eps, Format('%s: expected %.4f, got %.4f', [What, Expected, Actual]));
end;

procedure TestLexer;
var
  L: TDoom3Lexer;
  V: array [0..2] of Single;
begin
  L := TDoom3Lexer.Create(
    'model { "_area0" // comment' + LineEnding +
    '/* block' + LineEnding + 'comment */ 3 ( 1.5 -2 1e-005 ) textures/a_b/c.tga' + LineEnding +
    'heightmap(x.tga, 4) - 5 }');
  try
    CheckEquals('model', L.NextStr, 'lexer: name');
    CheckEquals('{', L.NextStr, 'lexer: punctuation');
    CheckEquals('_area0', L.NextStr, 'lexer: quoted string');
    Check(L.WasQuoted, 'lexer: WasQuoted');
    CheckEquals('3', L.Peek, 'lexer: peek skips comments');
    CheckEquals(3, L.ReadInt, 'lexer: int');
    L.ReadVector(@V[0], 3);
    CheckNear(1.5, V[0], 'lexer: vector x');
    CheckNear(-2, V[1], 'lexer: negative number');
    CheckNear(0.00001, V[2], 'lexer: exponent', 1e-7);
    CheckEquals('textures/a_b/c.tga', L.NextStr, 'lexer: path is one token');
    CheckEquals('heightmap(x.tga,4)', ReadImageProgram(L), 'lexer: image program');
    CheckNear(-5, L.ReadFloat, 'lexer: "- 5" read as a number');
    Check(L.Check('}'), 'lexer: Check');
    Check(L.AtEnd, 'lexer: at end');
  finally
    L.Free;
  end;
end;

procedure TestFiles;
var
  S: TStream;
  Maps: TStringList;
begin
  CheckEquals(26, D3Fs.FileCount, 'PK4 file count');
  Check(D3Fs.FileExists('maps/testmap.proc'), 'maps/testmap.proc exists');
  Check(D3Fs.FileExists('MAPS\TestMap.PROC'), 'lookups are case-insensitive, accept backslashes');
  Check(not D3Fs.FileExists('maps/mars_city1.proc'), 'no Doom 3 data in the test PK4');
  S := D3Fs.OpenFile('textures/test/floor_d.tga');
  try
    Check(S <> nil, 'open a deflated file');
    if S <> nil then
      CheckEquals(18 + 128 * 128 * 3, S.Size, 'inflated TGA size');
  finally
    S.Free;
  end;
  Maps := D3Fs.FindFiles('maps/', '.proc');
  try
    CheckEquals(1, Maps.Count, 'FindFiles maps/*.proc');
  finally
    Maps.Free;
  end;
end;

procedure TestDecls;
var
  M: TD3Material;
  Def: TStringList;
  Model: TD3ModelDecl;
  Snd: TD3SoundShader;
begin
  CheckEquals(8, Decls.DeclCount(dtMaterial), 'material count');
  CheckEquals(2, Decls.DeclCount(dtEntityDef), 'entityDef count');
  CheckEquals(1, Decls.DeclCount(dtModel), 'model decl count');
  CheckEquals(3, Decls.DeclCount(dtSound), 'sound shader count');
  CheckEquals(1, Decls.DeclCount(dtTable), 'table count');

  M := Decls.Material('textures/test/floor');
  Check(M.Defined, 'floor is declared');
  CheckEquals('textures/test/floor_d.tga', M.DiffuseImage, 'floor diffusemap');
  CheckEquals('heightmap(textures/test/floor_bmp.tga,6)', M.BumpImage, 'floor bumpmap program');
  CheckEquals('textures/test/floor_s.tga', M.SpecularImage, 'floor specularmap');

  M := Decls.Material('TEXTURES/TEST/WALL');
  CheckEquals('addnormals(textures/test/wall_local.tga,heightmap(textures/test/wall_bmp.tga,2))',
    M.BumpImage, 'wall addnormals program (case-insensitive name)');

  M := Decls.Material('textures/test/metal');
  CheckEquals('textures/test/metal_d.tga', M.DiffuseImage, 'metal diffuse from a "blend diffusemap" stage');
  CheckEquals('textures/test/metal_local.tga', M.BumpImage, 'metal bump from a stage');

  M := Decls.Material('textures/test/lightpanel');
  Check(M.DiffuseImage = '', 'lightpanel has no diffusemap');
  CheckEquals('textures/test/lightpanel.tga', M.StageImage, 'lightpanel stage map');
  Check(M.StageBlend = bmAdd, 'lightpanel blends additively');
  Check(not M.IsInvisible, 'lightpanel is drawn');

  Check(Decls.Material('lights/test_ambient').IsAmbientLight, 'ambientLight keyword');
  M := Decls.Material('textures/does/not_exist');
  Check(not M.Defined, 'undeclared material is implicit');
  CheckEquals('textures/does/not_exist', M.DiffuseImage, 'implicit material uses its name as image');

  Def := Decls.EntityDef('monster_test_blob');
  Check(Def <> nil, 'entityDef monster_test_blob');
  if Def <> nil then
  begin
    CheckEquals('test_blob', Def.Values['model'], 'entityDef model');
    CheckEquals('80', Def.Values['health'], 'entityDef overrides inherited health');
    CheckEquals('idAI', Def.Values['spawnclass'], 'entityDef inherits spawnclass');
  end;

  Model := Decls.ModelDecl('test_blob');
  Check(Model <> nil, 'model decl test_blob');
  if Model <> nil then
  begin
    CheckEquals('models/md5/test/blob.md5mesh', Model.Mesh, 'model mesh');
    CheckEquals('models/md5/test/blob_walk.md5anim', Model.AnimFile('walk'), 'model anim (with frame commands)');
    CheckEquals(2, Model.Anims.Count, 'model anim count');
  end;

  Snd := Decls.SoundShader('test_hum');
  Check(Snd <> nil, 'sound shader test_hum');
  if Snd <> nil then
  begin
    Check(Snd.Looping, 'test_hum loops');
    CheckNear(15, Snd.MaxDistance, 'test_hum maxDistance');
    CheckNear(-6, Snd.Volume, 'test_hum volume');
    CheckEquals('sound/test/hum.wav', Snd.Files[0], 'test_hum file');
  end;
end;

procedure TestImages;
var
  Img: TCastleImage;
  P: PByte;
begin
  CheckEquals('textures/test/floor_d.tga', FindImageFile('textures/test/floor_d'), 'image without extension');
  CheckEquals('textures/test/floor_d.tga', FindImageFile('textures/test/floor_d.dds'), 'image with another extension');
  CheckEquals('', FindImageFile('textures/test/none'), 'missing image');
  CheckEquals('d3fs:/textures/test/wall_d.tga', ImageProgramUrl('textures/test/wall_d.tga', ikColor),
    'plain image URL');
  CheckEquals('', ImageProgramUrl('_flat', ikNormal), '_flat means no normal map');

  Img := EvaluateImageProgram('heightmap(textures/test/floor_bmp.tga,6)', ikNormal);
  try
    Check(Img <> nil, 'evaluate heightmap()');
    if Img <> nil then
    begin
      CheckEquals(128, Img.Width, 'heightmap width');
      { (20, 20) is on a flat part of a plate: the normal points straight out }
      P := Img.PixelPtr(20, 20);
      Check((Abs(P[0] - 128) <= 2) and (Abs(P[1] - 128) <= 2) and (P[2] >= 250),
        Format('flat heightmap normal, got %d %d %d', [P[0], P[1], P[2]]));
    end;
  finally
    Img.Free;
  end;

  Img := EvaluateImageProgram('addnormals(textures/test/wall_local.tga,heightmap(textures/test/wall_bmp.tga,2))', ikNormal);
  try
    Check((Img <> nil) and (Img.Width = 128), 'evaluate addnormals()');
  finally
    Img.Free;
  end;
end;

procedure TestProc;
var
  Proc: TD3ProcFile;
  M: TD3ProcModel;
begin
  Proc := TD3ProcFile.Create;
  try
    Check(Proc.LoadFromVfs('maps/testmap.proc'), 'load testmap.proc');
    CheckEquals(6, Proc.ModelCount, 'proc model count');
    CheckEquals(2, Proc.NumAreas, 'proc areas');
    CheckEquals(1, Length(Proc.Portals), 'proc portals');
    CheckEquals(1, Length(Proc.Nodes), 'proc nodes');
    CheckEquals(0, Proc.Model(0).AreaIndex, '_area0 index');
    M := Proc.FindModel('DOOR_1');
    Check(M <> nil, 'find brush model door_1');
    if M <> nil then
    begin
      CheckEquals(-1, M.AreaIndex, 'door_1 is not an area');
      CheckEquals(12, M.TriangleCount, 'door_1 is a box');
      CheckEquals('textures/test/metal', M.Surfaces[0].Material, 'door_1 material');
    end;
    CheckEquals(0, Proc.PointInArea(Vector3(0, 0, 50)), 'point in room A');
    CheckEquals(1, Proc.PointInArea(Vector3(500, 0, 50)), 'point in room B');
    CheckEquals(1, Proc.Portals[0].PositiveArea, 'portal positive side');
  finally
    Proc.Free;
  end;
end;

procedure TestMapFile;
var
  MapFile: TD3MapFile;
  E: TD3MapEntity;
begin
  MapFile := TD3MapFile.Create;
  try
    Check(MapFile.LoadFromVfs('maps/testmap.map'), 'load testmap.map');
    CheckEquals(17, MapFile.Entities.Count, 'entity count');
    Check(MapFile.WorldSpawn <> nil, 'worldspawn');
    E := MapFile.FindByName('info_player_start_1');
    Check(E <> nil, 'find player start');
    if E <> nil then
    begin
      CheckNear(-160, E.Origin.X, 'player start x');
      CheckNear(45, E.Angle, 'player start angle');
    end;
    E := MapFile.FindByName('door_1');
    if E <> nil then
    begin
      CheckEquals('func_door', E.ClassName_, 'door classname');
      CheckNear(160, E.FloatValue('speed'), 'door speed');
    end else
      Check(False, 'find door_1');
    E := MapFile.FindByName('crate_1');
    if E <> nil then
      CheckNear(Cos(DegToRad(20)), E.Rotation.Data[0, 0], 'rotation from angle')
    else
      Check(False, 'find crate_1');
  finally
    MapFile.Free;
  end;
  { coordinates: Doom 3 Z up -> CGE Y up }
  Check(TVector3.Equals(D3ToCge(Vector3(1, 2, 3)), Vector3(1, 3, -2)), 'D3ToCge');
  Check(TVector3.Equals(CgeToD3(D3ToCge(Vector3(1, 2, 3))), Vector3(1, 2, 3)), 'CgeToD3 inverts D3ToCge');
end;

procedure TestMd5;
var
  Model: TD3Md5Model;
  Anim: TD3Md5Anim;
  Pose: TD3JointArray;
  Positions: array of TVector3;
  Body: Integer;
begin
  Model := Md5Cache.Model('models/md5/test/blob.md5mesh');
  Check(Model <> nil, 'load blob.md5mesh');
  if Model = nil then
    Exit;
  CheckEquals(7, Length(Model.Joints), 'md5 joints');
  CheckEquals(1, Model.Meshes.Count, 'md5 meshes');
  CheckEquals(144, Length(Model.Meshes[0].Verts), 'md5 verts');
  CheckEquals(72 * 3, Length(Model.Meshes[0].Tris), 'md5 triangle indexes');
  CheckEquals('models/test/blob', Model.Meshes[0].Shader, 'md5 shader');
  Body := Model.JointIndex('body');
  CheckEquals(1, Body, 'joint index of body');
  CheckNear(40, Model.Joints[Body].Position.Z, 'body joint bind position');

  { skinning the bind pose gives the vertexes back }
  SetLength(Positions, Length(Model.Meshes[0].Verts));
  Model.SkinMesh(0, Model.Joints, Positions);
  CheckNear(24, Positions[0].Y, 'first body vertex (CGE Y = Doom 3 Z)');

  Anim := Md5Cache.Anim('models/md5/test/blob_idle.md5anim');
  Check(Anim <> nil, 'load blob_idle.md5anim');
  if Anim = nil then
    Exit;
  CheckEquals(48, Anim.NumFrames, 'anim frames');
  CheckEquals(24, Anim.FrameRate, 'anim frame rate');
  CheckNear(2, Anim.Duration, 'anim duration');
  Pose := nil;
  Anim.FramePose(0, Pose);
  CheckNear(40, Pose[Body].Position.Z, 'frame 0 body height');
  Anim.FramePose(12, Pose);
  CheckNear(42, Pose[Body].Position.Z, 'frame 12 body bobs up 2 units', 0.05);
  Anim.PoseAt(0.25, True, Pose);
  CheckNear(41.41, Pose[Body].Position.Z, 'PoseAt 0.25 s (frame 6)', 0.05);
end;

begin
  InitializeLog;
  D3Fs.RegisterProtocol;
  RegisterImageProtocol;
  if not D3Fs.AddPk4('../data/base/castle_doom3_test.pk4') then
  begin
    Writeln('Cannot open ../data/base/castle_doom3_test.pk4 (run from tests/)');
    Halt(2);
  end;
  Decls.LoadAll;
  TestLexer;
  TestFiles;
  TestDecls;
  TestImages;
  TestProc;
  TestMapFile;
  TestMd5;
  Writeln(Format('%d passed, %d failed', [Passed, Failed]));
  if Failed > 0 then
    Halt(1);
end.
