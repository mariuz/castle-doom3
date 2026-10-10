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
  Doom3StaticModels, Doom3Level, Doom3Collision, Doom3Portals, Doom3Expressions, Doom3LightEffects, Doom3Gui,
  CastleTransform, CastleUtils, CastleBoxes;

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
  CheckEquals(46, D3Fs.FileCount, 'PK4 file count');
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
  CheckEquals(21, Decls.DeclCount(dtMaterial), 'material count');
  CheckEquals(2, Decls.DeclCount(dtEntityDef), 'entityDef count');
  CheckEquals(1, Decls.DeclCount(dtModel), 'model decl count');
  CheckEquals(3, Decls.DeclCount(dtSound), 'sound shader count');
  CheckEquals(3, Decls.DeclCount(dtTable), 'table count');

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
    CheckEquals(7, Proc.ModelCount, 'proc model count');
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
    CheckEquals(23, MapFile.Entities.Count, 'entity count');
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
    CheckEquals(6, Cm.ModelCount, 'cm models (world + 5 brush entities)');
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
      if Decls.Material(P.Material).BlocksPlayer then
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
      CheckEquals(3 * Fan, Indexes.Count,
        'player collision triangles: the polygons whose material blocks the player');
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

function EvalExpr(const Text: String; const Time: Single = 0): Single;
var
  E: TD3Expr;
  Ctx: TD3ExprContext;
begin
  E := ParseD3ExpressionString(Text, @Decls.Table);
  if E = nil then
    Exit(-999);
  try
    Ctx := DefaultExprContext;
    Ctx.Time := Time;
    Ctx.Parms[0] := 0.5;
    Ctx.Parms[5] := 3;
    Result := E.Eval(Ctx);
  finally
    E.Free;
  end;
end;

procedure TestExpressions;
var
  T: TD3Table;
  M: TD3Material;
  Ctx: TD3ExprContext;
  C: TVector4;
  E: TD3Expr;
begin
  CheckNear(7, EvalExpr('1 + 2 * 3'), 'precedence: * before +');
  CheckNear(9, EvalExpr('( 1 + 2 ) * 3'), 'parentheses');
  CheckNear(1, EvalExpr('7 % 3'), 'modulo');
  CheckNear(-2, EvalExpr('-2'), 'unary minus');
  CheckNear(1, EvalExpr('2 > 1 && 3 >= 3'), 'comparisons and &&');
  CheckNear(0, EvalExpr('1 == 2 || 0'), '== and ||');
  CheckNear(3, EvalExpr('time*2', 1.5), 'time without spaces');
  CheckNear(1.5, EvalExpr('Parm0 * parm5'), 'parms, case-insensitive');
  CheckNear(0, EvalExpr('3 / 0'), 'division by zero is 0');
  Check(EvalExpr('1 +') = -999, 'syntax error gives nil');
  E := ParseD3ExpressionString('0.5 * 2', @Decls.Table);
  try
    Check((E <> nil) and E.IsConstant, 'constant expression');
  finally
    E.Free;
  end;
  E := ParseD3ExpressionString('sinTable[ time ]', @Decls.Table);
  try
    Check((E <> nil) and not E.IsConstant, 'table of time is not constant');
  finally
    E.Free;
  end;

  CheckEquals(3, Decls.DeclCount(dtTable), 'table decls');
  T := Decls.Table('testStrobeTable');
  Check(T <> nil, 'table testStrobeTable');
  if T <> nil then
  begin
    CheckEquals(9, Length(T.Values), 'table values + the wrap copy');
    CheckNear(1, T.Lookup(0), 'lookup 0');
    CheckNear(0.2, T.Lookup(0.25), 'lookup 0.25 (index 2)');
    CheckNear(0.6, T.Lookup(0.3125), 'lookup interpolates (index 2.5)');
    CheckNear(0.2, T.Lookup(1.25), 'lookup wraps');
    CheckNear(0.2, T.Lookup(-0.75), 'lookup wraps negative');
  end;
  T := Decls.Table('testFlickerTable');
  if T <> nil then
  begin
    Check(T.Snap, 'snap table');
    CheckNear(0.3, T.Lookup(0.35), 'snap: no interpolation (index 3.5)');
  end else
    Check(False, 'table testFlickerTable');
  CheckNear(1, EvalExpr('sinTable[0.25]'), 'sinTable[0.25] = 1');

  M := Decls.Material('lights/test_strobe');
  Check(M.StageColorAnimated, 'strobe light shader is animated');
  Ctx := DefaultExprContext;
  Ctx.Parms[0] := 0.25;
  Ctx.Time := 0.125; { table index 0.25 -> 0.2 }
  C := M.EvalStageColor(Ctx);
  CheckNear(0.05, C.X, 'strobe red = table * parm0');
  CheckNear(1, C.W, 'alpha defaults to 1');

  M := Decls.Material('lights/test_pulse');
  Ctx := DefaultExprContext;
  Ctx.Parms[1] := 0.5;
  Ctx.Time := 0.5; { sinTable[0.25] = 1 }
  C := M.EvalStageColor(Ctx);
  CheckNear(0.5, C.Y, 'pulse green (expression ends before a // comment)');

  M := Decls.Material('lights/test_ambient');
  Check(not M.StageColorAnimated, '"colored" is not animated');
  Ctx := DefaultExprContext;
  Ctx.Parms[2] := 0.3;
  CheckNear(0.3, M.EvalStageColor(Ctx).Z, '"colored" uses parm2');
  M := Decls.Material('lights/test_white');
  CheckNear(1, M.EvalStageColor(Ctx).Z, 'a stage without color registers is white');
  M := Decls.Material('textures/test/floor');
  Check(M.StageColorExpr[0] = nil, 'diffuse stages have no light color');
end;

procedure CheckVec(const Expected, Actual: TVector3; const What: String);
begin
  Check(TVector3.Equals(Expected, Actual, 0.01),
    Format('%s: expected %s, got %s', [What, Expected.ToString, Actual.ToString]));
end;

procedure TestLightVolumes;
var
  M: TMatrix4;
  Origin: TVector3;
begin
  { a point light box 100 x 200 x 50 around (10, 20, 30) }
  Origin := Vector3(10, 20, 30);
  M := PointLightMatrix(Origin, TMatrix3.Identity, Vector3(100, 200, 50));
  CheckVec(Vector3(0.5, 0.5, 0.5), LightTexCoord(M, D3ToCge(Origin)), 'point light center');
  CheckVec(Vector3(1, 0.5, 0.5), LightTexCoord(M, D3ToCge(Origin + Vector3(100, 0, 0))), 'point light +X edge');
  CheckVec(Vector3(0.5, 0, 0.5), LightTexCoord(M, D3ToCge(Origin + Vector3(0, -200, 0))), 'point light -Y edge');
  CheckVec(Vector3(0.5, 0.5, 1), LightTexCoord(M, D3ToCge(Origin + Vector3(0, 0, 50))), 'point light top (falloff 1)');
  { rotated 90 degrees: the box's X axis is the world's Y }
  M := PointLightMatrix(Origin, YawMatrix(90), Vector3(100, 200, 50));
  CheckVec(Vector3(1, 0.5, 0.5), LightTexCoord(M, D3ToCge(Origin + Vector3(0, 100, 0))), 'rotated point light');

  { a projected light pointing down 190 units, 90 half width / height }
  Origin := Vector3(0, -150, 190);
  M := ProjectedLightMatrix(Origin, TMatrix3.Identity, Vector3(0, 0, -190), Vector3(0, 90, 0),
    Vector3(90, 0, 0), TVector3.Zero, TVector3.Zero, False);
  CheckVec(Vector3(0.5, 0.5, 1), LightTexCoord(M, D3ToCge(Vector3(0, -150, 0))), 'projected light target');
  CheckVec(Vector3(1, 0.5, 1), LightTexCoord(M, D3ToCge(Vector3(90, -150, 0))), 'projected light right edge');
  CheckVec(Vector3(0.5, 1, 1), LightTexCoord(M, D3ToCge(Vector3(0, -60, 0))), 'projected light up edge');
  { half way down the frustum is half as wide }
  CheckVec(Vector3(1, 0.5, 0.5), LightTexCoord(M, D3ToCge(Vector3(45, -150, 95))), 'projected light perspective');
  Check(LightTexCoord(M, D3ToCge(Vector3(0, -150, 300))).X < 0, 'behind a projected light: w <= 0');
  { light_start / light_end set the falloff range }
  M := ProjectedLightMatrix(Origin, TMatrix3.Identity, Vector3(0, 0, -190), Vector3(0, 90, 0),
    Vector3(90, 0, 0), Vector3(0, 0, -10), Vector3(0, 0, -210), True);
  CheckNear(0.9, LightTexCoord(M, D3ToCge(Vector3(0, -150, 0))).Z, 'projected falloff from start to end');
  { light strength at a point (picks the shadow casting light) }
  M := PointLightMatrix(Vector3(0, 0, 0), TMatrix3.Identity, Vector3(100, 100, 100));
  CheckNear(1, LightVolumeStrength(M, lsRound, False, D3ToCge(Vector3(0, 0, 0))), 'strength at the light center');
  Check(LightVolumeStrength(M, lsRound, False, D3ToCge(Vector3(50, 0, 0))) < 1, 'strength fades');
  CheckNear(0, LightVolumeStrength(M, lsRound, False, D3ToCge(Vector3(150, 0, 0))), 'no strength outside the box');
  { analytic projection shapes from image names }
  Check(ProjectionShape('lights/squarelight1.tga') = lsSquare, 'squarelight1 is a square');
  Check(ProjectionShape('makeintensity(lights/round.tga)') = lsRound, 'round is a disc');
  Check(ProjectionShape('') = lsRound, 'default projection is a disc');
  Check(ProjectionShape('lights/bright.tga') = lsFull, 'bright fills the volume');
  CheckEquals('lights/window.tga', Decls.Material('lights/test_window').StageImage, 'light shader projection image');
  CheckEquals('lights/projfalloff.tga', Decls.Material('lights/test_window').LightFalloffImage, 'light shader falloff image');
end;

function TexApply(const M: TMatrix4; const S, V: Single): TVector2;
var
  R: TVector4;
begin
  R := M * Vector4(S, V, 0, 1);
  Result := Vector2(R.X, R.Y);
end;

function MakeOps(const Kinds: array of TD3TexOpKind; const Args: array of String): TD3TexOps;
var
  I: Integer;
begin
  SetLength(Result, Length(Kinds));
  for I := 0 to High(Kinds) do
  begin
    Result[I].Kind := Kinds[I];
    Result[I].A := ParseD3ExpressionString(Args[I * 2], @Decls.Table);
    if Args[I * 2 + 1] <> '' then
      Result[I].B := ParseD3ExpressionString(Args[I * 2 + 1], @Decls.Table)
    else
      Result[I].B := nil;
  end;
end;

procedure FreeOps(var Ops: TD3TexOps);
var
  I: Integer;
begin
  for I := 0 to High(Ops) do
  begin
    Ops[I].A.Free;
    Ops[I].B.Free;
  end;
  Ops := nil;
end;

procedure CheckVec2(const Expected, Actual: TVector2; const What: String);
begin
  Check(TVector2.Equals(Expected, Actual, 0.001),
    Format('%s: expected %s, got %s', [What, Expected.ToString, Actual.ToString]));
end;

procedure TestMaterialStages;
var
  Ops: TD3TexOps;
  Ctx: TD3ExprContext;
  M: TD3Material;
begin
  Ctx := DefaultExprContext;
  Ctx.Time := 2;
  { scroll s: plain shift }
  Ops := MakeOps([toScroll], ['time * 0.125', '0']);
  CheckVec2(Vector2(0.35, 0.4), TexApply(TD3Material.TexMatrix(Ops, Ctx), 0.1, 0.4), 'scroll s');
  Check(TD3Material.TexOpsAnimated(Ops), 'scroll by time is animated');
  FreeOps(Ops);
  { scroll t: Doom 3's t goes down the image, CGE's v up }
  Ops := MakeOps([toScroll], ['0', '0.25']);
  CheckVec2(Vector2(0.1, 0.15), TexApply(TD3Material.TexMatrix(Ops, Ctx), 0.1, 0.4), 'scroll t moves v down');
  Check(not TD3Material.TexOpsAnimated(Ops), 'constant scroll');
  FreeOps(Ops);
  { scale 2: Doom (s, t) -> (2s, 2t); in CGE v = 1 - t }
  Ops := MakeOps([toScale], ['2', '2']);
  CheckVec2(Vector2(0.2, 0.6), TexApply(TD3Material.TexMatrix(Ops, Ctx), 0.1, 0.8), 'scale');
  FreeOps(Ops);
  { centerScale keeps the center }
  Ops := MakeOps([toCenterScale], ['3', '3']);
  CheckVec2(Vector2(0.5, 0.5), TexApply(TD3Material.TexMatrix(Ops, Ctx), 0.5, 0.5), 'centerScale center');
  FreeOps(Ops);
  { rotate a quarter cycle around the center }
  Ops := MakeOps([toRotate], ['0.25', '']);
  CheckVec2(Vector2(0.5, 0.5), TexApply(TD3Material.TexMatrix(Ops, Ctx), 0.5, 0.5), 'rotate center');
  CheckVec2(Vector2(0.5, 0), TexApply(TD3Material.TexMatrix(Ops, Ctx), 1, 0.5), 'rotate quarter');
  FreeOps(Ops);
  { order: scale then scroll (scroll is applied after the scale) }
  Ops := MakeOps([toScale, toScroll], ['2', '1', '0.5', '0']);
  CheckVec2(Vector2(0.7, 0.4), TexApply(TD3Material.TexMatrix(Ops, Ctx), 0.1, 0.4), 'keywords compose in order');
  FreeOps(Ops);

  M := Decls.Material('textures/test/screen');
  CheckEquals(2, Length(M.StageTexOps), 'screen: scroll and scale');
  Check(TD3Material.TexOpsAnimated(M.StageTexOps), 'screen scrolls with time');
  Check(M.StageTexOps[0].Kind = toScroll, 'screen first keyword');
  M := Decls.Material('textures/test/lightpanel');
  Check(M.StageColorAnimated, 'light panels pulse');
  Check(Length(M.StageTexOps) = 0, 'light panels have no texture matrix');
  M := Decls.Material('textures/test/sky');
  CheckEquals('env/testsky', M.SkyCubeMap, 'sky cube map');
  Check(M.SkyCameraCubeMap, 'cameraCubeMap');
  Check(M.IsInvisible, 'sky surfaces are not drawn');
  CheckEquals('env/testsky_forward.tga', FindImageFile('env/testsky_forward'), 'sky image');
end;

function PixelAt(const Img: TCastleImage; const X, Y: Integer): TVector4;
begin
  { GUI coordinates: y goes down }
  Result := Img.Colors[X, Img.Height - 1 - Y, 0];
end;

function BrightPixels(const Img: TCastleImage; const X0, Y0, X1, Y1: Integer): Integer;
var
  X, Y: Integer;
  C: TVector4;
begin
  Result := 0;
  for Y := Y0 to Y1 do
    for X := X0 to X1 do
    begin
      C := PixelAt(Img, X, Y);
      if C.X + C.Y + C.Z > 2.4 then
        Inc(Result);
    end;
end;

procedure TestGuis;
var
  Gui: TD3Gui;
  W: TD3GuiWindow;
  State: TStringList;
  Img: TRGBAlphaImage;
  C: TVector4;
  Url1, Url2: String;
begin
  CheckEquals('guis/a.gui', GuiSurfPath('entity', 'guis/a.gui', 'guis/b.gui', ''), 'guisurf entity');
  CheckEquals('guis/b.gui', GuiSurfPath('entity2', 'guis/a.gui', 'guis/b.gui', ''), 'guisurf entity2');
  CheckEquals('guis/x.gui', GuiSurfPath('guis/x.gui', 'guis/a.gui', '', ''), 'guisurf path');
  Check(Decls.Material('textures/test/guiscreen').GuiSurf = 'entity', 'guisurf material');

  Gui := TD3Gui.Create;
  State := TStringList.Create;
  try
    Check(Gui.LoadFromVfs('guis/test_panel.gui'), 'load test_panel.gui');
    CheckEquals(5, Gui.WindowCount, 'panel windows (definevec4 and events skipped)');
    W := Gui.FindWindow('header');
    Check(W <> nil, 'find header window');
    if W <> nil then
    begin
      CheckNear(110, W.Rect.Height, 'header rect height');
      CheckNear(0.55, W.BackColor.X, 'header backcolor');
      CheckEquals('gui::gui_parm1', W.Text, 'header text');
      CheckEquals(1, W.TextAlign, 'header textalign');
    end;
    W := Gui.FindWindow('hidden');
    Check((W <> nil) and not W.Visible, 'visible 0');
    W := Gui.FindWindow('body');
    Check((W <> nil) and (W.BorderSize = 3), 'bordersize');

    State.Values['gui_parm1'] := 'AREA A';
    State.Values['gui_parm2'] := 'Hello';
    Img := RenderGui(Gui, State);
    try
      CheckEquals(GuiWidth, Img.Width, 'GUI image width');
      C := PixelAt(Img, 5, 5);
      Check((C.X > 0.4) and (C.Y < 0.2), Format('header is red, got %s', [C.ToString]));
      Check(BrightPixels(Img, 200, 10, 440, 100) > 50, 'header text drawn (gui::gui_parm1)');
      C := PixelAt(Img, 320, 400);
      Check(C.X < 0.5, 'the hidden red window is not drawn');
      C := PixelAt(Img, 31, 300);
      Check(C.Z > 0.4, 'body border drawn');
    finally
      Img.Free;
    end;
    { no state: the header has no text }
    Img := RenderGui(Gui, nil);
    try
      Check(BrightPixels(Img, 200, 10, 440, 100) < 5, 'empty gui:: text');
    finally
      Img.Free;
    end;

    Check(Gui.LoadFromVfs('guis/test_status.gui'), 'load test_status.gui');
    CheckEquals(6, Gui.WindowCount, 'status windows (one-line windowDefs)');
    Img := RenderGui(Gui, nil);
    try
      C := PixelAt(Img, 100, 170);
      Check((C.Y > 0.6) and (C.X < 0.4), Format('green bar, got %s', [C.ToString]));
      C := PixelAt(Img, 100, 310);
      Check((C.X > 0.7) and (C.Y < 0.4), 'red bar');
    finally
      Img.Free;
    end;
  finally
    State.Free;
    Gui.Free;
  end;

  State := TStringList.Create;
  try
    State.Values['gui_parm1'] := 'X';
    Url1 := GuiImageUrl('guis/test_panel.gui', State);
    Url2 := GuiImageUrl('GUIS/test_panel.gui', State);
    Check((Url1 <> '') and (Url1 = Url2), 'GUI images are cached per path and state');
    State.Values['gui_parm1'] := 'Y';
    Check(GuiImageUrl('guis/test_panel.gui', State) <> Url1, 'another state, another image');
    CheckEquals('', GuiImageUrl('guis/missing.gui', nil), 'missing GUI');
  finally
    State.Free;
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
    S := FindSurface(M, 'textures/test/screen');
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
  TestExpressions;
  TestLightVolumes;
  TestMaterialStages;
  TestGuis;
  Writeln(Format('%d passed, %d failed', [Passed, Failed]));
  if Failed > 0 then
    Halt(1);
end.
