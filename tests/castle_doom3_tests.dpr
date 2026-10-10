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
  Doom3Files, Doom3Lexer, Doom3Decls, Doom3Images, Doom3Proc, Doom3MapFile, Doom3Md5,
  Doom3StaticModels, Doom3Level, Doom3Collision, Doom3Portals, CastleTransform, CastleUtils, CastleBoxes;

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
  CheckEquals(31, D3Fs.FileCount, 'PK4 file count');
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
  CheckEquals(11, Decls.DeclCount(dtMaterial), 'material count');
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
    CheckEquals(21, MapFile.Entities.Count, 'entity count');
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

function FindSurface(const M: TD3StaticModel; const Material: String): TD3StaticSurface;
var
  S: TD3StaticSurface;
begin
  for S in M.Surfaces do
    if S.Material = Material then
      Exit(S);
  Result := nil;
end;

{ Normal of a surface's first triangle (counter-clockwise = front). }
function FirstNormal(const S: TD3StaticSurface): TVector3;
begin
  Result := TVector3.CrossProduct(S.Positions[S.Indexes[1]] - S.Positions[S.Indexes[0]],
    S.Positions[S.Indexes[2]] - S.Positions[S.Indexes[0]]).Normalize;
end;

procedure TestCollisionModel;
var
  Cm: TD3CollisionFile;
  W: TD3CollisionModel;
  Coords: TVector3List;
  Indexes: TInt32List;
  I, ClipPolys, MonsterClipPolys, Fan: Integer;
  P: TD3CmPolygon;
  Found: Boolean;
begin
  Check(Decls.Material('textures/common/clip').BlocksPlayer, 'playerclip blocks the player');
  Check(not Decls.Material('textures/common/monster_clip').BlocksPlayer, 'monsterclip does not');
  Check(Decls.Material('textures/test/wall').BlocksPlayer, 'a plain material is solid');
  Check(Decls.Material('textures/common/clip').IsInvisible, 'clip is not drawn');

  Cm := TD3CollisionFile.Create;
  try
    Check(Cm.LoadFromVfs('maps/testmap.cm'), 'load testmap.cm');
    CheckEquals(5, Cm.ModelCount, 'cm models (world + 4 brush entities)');
    CheckEquals(1234567890, Cm.Crc, 'cm crc');
    W := Cm.World;
    Check((W <> nil) and (W.Name = 'worldMap'), 'worldMap model');
    if W = nil then
      Exit;
    CheckEquals(1, W.NodeCount, 'one leaf node');
    CheckEquals(1, Length(W.Brushes), 'one brush');
    if Length(W.Brushes) > 0 then
    begin
      CheckEquals(6, Length(W.Brushes[0].Planes), 'brush sides');
      CheckEquals('playerclip', W.Brushes[0].Contents, 'brush contents');
      CheckNear(-120, W.Brushes[0].Maxs.X, 'brush bounds');
    end;
    Check(Cm.FindModel('DOOR_1') <> nil, 'brush entity collision model');

    ClipPolys := 0;
    MonsterClipPolys := 0;
    Fan := 0;
    for P in W.Polygons do
    begin
      if P.Material = 'textures/common/clip' then
        Inc(ClipPolys);
      if P.Material = 'textures/common/monster_clip' then
        Inc(MonsterClipPolys);
      Inc(Fan, Length(P.Verts) - 2);
    end;
    CheckEquals(6, ClipPolys, 'playerclip box polygons');
    CheckEquals(6, MonsterClipPolys, 'monsterclip box polygons');

    { the first polygon is room A's west wall: vertexes 0 1 2 3 from edges 1..4 }
    CheckEquals(4, Length(W.Polygons[0].Verts), 'quad polygon');
    Check((W.Polygons[0].Verts[0] = 0) and (W.Polygons[0].Verts[1] = 1) and
      (W.Polygons[0].Verts[2] = 2) and (W.Polygons[0].Verts[3] = 3), 'polygon vertexes from edges');
    { every polygon's vertexes lie on its plane, also through reversed edges }
    Found := True;
    for P in W.Polygons do
      for I := 0 to High(P.Verts) do
        if Abs(TVector3.DotProduct(P.Normal, W.Vertices[P.Verts[I]]) - P.Dist) > 0.01 then
          Found := False;
    Check(Found, 'polygon vertexes are on their planes (signed edges decoded)');

    W.PlayerTriangles(Coords, Indexes);
    try
      CheckEquals(3 * (Fan - 2 * MonsterClipPolys), Indexes.Count,
        'player collision triangles: all but monsterclip');
    finally
      Coords.Free;
      Indexes.Free;
    end;
  finally
    Cm.Free;
  end;
end;

{ The 4 side planes of a 90 degree view from Eye along a horizontal CGE
  direction (X or Z axis), inside = dot(n, p) + w >= 0. }
function ViewPlanes(const Eye, Dir: TVector3): TD3PlaneArray;
var
  Side, Up: TVector3;
  N: array [0..3] of TVector3;
  I: Integer;
begin
  Up := Vector3(0, 1, 0);
  Side := TVector3.CrossProduct(Dir, Up);
  N[0] := (Dir + Side).Normalize;
  N[1] := (Dir - Side).Normalize;
  N[2] := (Dir + Up).Normalize;
  N[3] := (Dir - Up).Normalize;
  SetLength(Result, 4);
  for I := 0 to 3 do
    Result[I] := Vector4(N[I], -TVector3.DotProduct(N[I], Eye));
end;

procedure TestPortals;
var
  Proc: TD3ProcFile;
  V: TD3PortalVisibility;
  EyeA, EyeB: TVector3;
  Poly: TD3PointArray;
  Areas: TD3IntArray;
  Door: TD3IntArray;
  DoorBox: TBox3D;
begin
  { clipping a square by a plane keeps the inside half }
  Poly := ClipPolygon([Vector3(-1, 0, -1), Vector3(1, 0, -1), Vector3(1, 0, 1), Vector3(-1, 0, 1)],
    Vector4(1, 0, 0, 0));
  CheckEquals(4, Length(Poly), 'clipped square has 4 corners');
  CheckNear(0, Poly[0].X, 'clipped square starts at the plane');

  Proc := TD3ProcFile.Create;
  try
    Proc.LoadFromVfs('maps/testmap.proc');
    V := TD3PortalVisibility.Create(Proc);
    try
      CheckEquals(2, V.AreaCount, 'portal areas');
      CheckEquals(1, V.PortalCount, 'portals');
      { room A, eye height, looking at the doorway (+X) }
      EyeA := D3ToCge(Vector3(150, 0, 60));
      V.Compute(EyeA, 0, ViewPlanes(EyeA, Vector3(1, 0, 0)));
      CheckEquals(2, V.VisibleCount, 'room B is seen through the doorway');
      V.Compute(EyeA, 0, ViewPlanes(EyeA, Vector3(-1, 0, 0)));
      CheckEquals(1, V.VisibleCount, 'looking away: only room A');
      Check(V.AreaVisible[0] and not V.AreaVisible[1], 'looking away: area 0 only');
      { looking along +Z (Doom 3 -Y): the doorway is outside the view }
      V.Compute(EyeA, 0, ViewPlanes(EyeA, Vector3(0, 0, 1)));
      CheckEquals(1, V.VisibleCount, 'doorway outside the frustum');
      { a closed door closes the portal }
      V.PortalClosed[0] := True;
      V.Compute(EyeA, 0, ViewPlanes(EyeA, Vector3(1, 0, 0)));
      CheckEquals(1, V.VisibleCount, 'closed portal hides room B');
      V.PortalClosed[0] := False;
      { from room B looking back }
      EyeB := D3ToCge(Vector3(500, 0, 60));
      V.Compute(EyeB, 1, ViewPlanes(EyeB, Vector3(-1, 0, 0)));
      CheckEquals(2, V.VisibleCount, 'room A is seen from room B');
      { far to the side in room B the doorway is outside a narrow view }
      EyeB := D3ToCge(Vector3(500, -350, 60));
      V.Compute(EyeB, 1, ViewPlanes(EyeB, Vector3(0, 0, 1)));
      CheckEquals(1, V.VisibleCount, 'doorway not in view from the side');
      { no planes, outside the map }
      V.Compute(EyeA, -1, []);
      CheckEquals(2, V.VisibleCount, 'outside the map: everything');
      { lights reach areas through nearby portals only }
      Areas := V.AreasWithinRadius(D3ToCge(Vector3(0, 0, 160)), 320, 0);
      CheckEquals(2, Length(Areas), 'a light near the doorway reaches room B');
      Areas := V.AreasWithinRadius(D3ToCge(Vector3(-200, 200, 64)), 200, 0);
      CheckEquals(1, Length(Areas), 'a light far from the doorway stays in room A');
      { the door's box contains the portal }
      DoorBox := TBox3D.Empty;
      DoorBox.Include(D3ToCge(Vector3(244, -64, -16)));
      DoorBox.Include(D3ToCge(Vector3(284, 64, 128)));
      Door := V.PortalsInBox(DoorBox);
      CheckEquals(1, Length(Door), 'door box contains the portal');
    finally
      V.Free;
    end;
  finally
    Proc.Free;
  end;
end;

procedure TestEntityRotation;
var
  T: TCastleTransform;
  P, Expected: TVector3;
begin
  T := TCastleTransform.Create(nil);
  try
    SetD3Rotation(T, YawMatrix(135));
    { a model's +X (its front) must point along the yaw }
    P := T.Transform.MultPoint(D3ToCge(Vector3(1, 0, 0)));
    Expected := D3ToCge(Vector3(Cos(DegToRad(135)), Sin(DegToRad(135)), 0));
    Check(TVector3.Equals(P, Expected, 0.001),
      Format('yaw 135 turns +X to %s, got %s', [Expected.ToString, P.ToString]));
    P := T.Transform.MultPoint(D3ToCge(Vector3(0, 0, 1)));
    Check(TVector3.Equals(P, D3ToCge(Vector3(0, 0, 1)), 0.001), 'yaw keeps up');
  finally
    T.Free;
  end;
end;

procedure TestStaticModels;
var
  M: TD3StaticModel;
  S: TD3StaticSurface;
begin
  CheckEquals('textures/test/metal', AseBitmapToMaterial('\\purgatory\doom\base\textures\test\metal.tga'),
    'ASE bitmap with a UNC path');
  CheckEquals('textures/test/lightpanel', AseBitmapToMaterial('C:\Doom3\BASE\Textures\test\lightpanel.tga'),
    'ASE bitmap with a drive path');
  CheckEquals('textures/a/b', AseBitmapToMaterial('D:\art\textures\a\b.tga'), 'ASE bitmap without base/');
  Check(IsStaticModelPath('models/x/y.LWO') and IsStaticModelPath('a.ase') and
    not IsStaticModelPath('a.md5mesh'), 'IsStaticModelPath');

  M := StaticModels.Model('models/mapobjects/test/barrel.lwo');
  Check(M <> nil, 'load barrel.lwo');
  if M <> nil then
  begin
    CheckEquals(2, M.Surfaces.Count, 'barrel surfaces (unused tag skipped)');
    S := FindSurface(M, 'models/mapobjects/test/barrel');
    Check(S <> nil, 'barrel side surface');
    if S <> nil then
    begin
      CheckEquals(32, S.TriangleCount, 'barrel sides: 16 quads');
      { the first quad faces +X (angle 0..22.5 degrees) }
      Check(FirstNormal(S).X > 0.9, 'barrel side faces out (counter-clockwise)');
      { the seam quad (the 16th) uses u = 1 from VMAD at its second column }
      CheckNear(1, S.TexCoords[15 * 4 + 1].X, 'VMAD overrides the seam UV');
      CheckNear(0, S.TexCoords[15 * 4].X - 15 / 16, 'VMAP UV of the seam quad first column');
      CheckNear(1, S.TexCoords[2].Y, 'top ring v = 1 (CGE v = LightWave v)');
    end;
    S := FindSurface(M, 'textures/test/metal');
    if S <> nil then
    begin
      CheckEquals(28, S.TriangleCount, 'barrel caps: two 16-gons as fans');
      Check(FirstNormal(S).Z > 0.9, 'barrel top cap faces up');
    end else
      Check(False, 'barrel cap surface');
    CheckNear(44, M.BoundsMax.Z, 'barrel height (LightWave y -> Doom 3 z)');
    CheckNear(18, M.BoundsMax.X, 'barrel radius', 0.05);
  end;

  M := StaticModels.Model('models/mapobjects/test/terminal.ase');
  Check(M <> nil, 'load terminal.ase');
  if M <> nil then
  begin
    CheckEquals(2, M.Surfaces.Count, 'terminal surfaces from sub-materials');
    S := FindSurface(M, 'textures/test/lightpanel');
    if S <> nil then
    begin
      CheckEquals(2, S.TriangleCount, 'terminal screen triangles');
      Check(FirstNormal(S).X > 0.5, 'terminal screen faces +X');
      CheckNear(0, S.TexCoords[0].Y, 'ASE v kept (CGE convention)');
    end else
      Check(False, 'terminal screen surface (MESH_MTLID 1)');
    S := FindSurface(M, 'textures/test/metal');
    if S <> nil then
    begin
      CheckEquals(12, S.TriangleCount, 'terminal metal triangles');
      Check(FirstNormal(S).X > 0.9, 'terminal front faces +X');
    end else
      Check(False, 'terminal metal surface');
  end;
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
  TestStaticModels;
  TestEntityRotation;
  TestCollisionModel;
  TestPortals;
  Writeln(Format('%d passed, %d failed', [Passed, Failed]));
  if Failed > 0 then
    Halt(1);
end.
