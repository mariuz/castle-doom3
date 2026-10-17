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
  Doom3StaticModels, Doom3Level, Doom3Collision, Doom3Portals, Doom3Aas, Doom3Expressions, Doom3LightEffects, Doom3Gui,
  Doom3Materials, X3DNodes, Doom3World, CastleScene, Doom3Script, Doom3Camera,
  CastleTransform, CastleUtils, CastleBoxes, CastleRenderOptions;

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

procedure CheckVec3(const Expected, Actual: TVector3; const What: String);
begin
  Check(TVector3.Equals(Expected, Actual, 0.01),
    Format('%s: expected %s, got %s', [What, Expected.ToString, Actual.ToString]));
end;

procedure CheckNear(const Expected, Actual: Single; const What: String; const Eps: Single = 0.01);
begin
  Check(Abs(Expected - Actual) <= Eps, Format('%s: expected %.4f, got %.4f', [What, Expected, Actual]));
end;

procedure CheckVectorNear(const Expected, Actual: TVector3; const What: String; const Eps: Single = 0.01);
begin
  Check(TVector3.Equals(Expected, Actual, Eps), Format('%s: expected %s, got %s',
    [What, Expected.ToString, Actual.ToString]));
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
  CheckEquals(59, D3Fs.FileCount, 'PK4 file count');
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
  CheckEquals(27, Decls.DeclCount(dtMaterial), 'material count');
  CheckEquals(12, Decls.DeclCount(dtEntityDef), 'entityDef count');
  CheckEquals(2, Decls.DeclCount(dtModel), 'model decl count');
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
  M := Decls.Material('textures/common/entitygui2');
  CheckEquals('entity2', M.GuiSurf, 'undefined entitygui2 is the entity''s gui2 screen');
  CheckEquals('', M.DiffuseImage, 'undefined entitygui2 has no image');

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
    CheckEquals(4, Model.Anims.Count, 'model anim count');
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
  SM: TD3ShadowModel;
begin
  Proc := TD3ProcFile.Create;
  try
    Check(Proc.LoadFromVfs('maps/testmap.proc'), 'load testmap.proc');
    CheckEquals(11, Proc.ModelCount, 'proc model count');
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
      CheckEquals('textures/test/door', M.Surfaces[0].Material, 'door_1 material (its big faces)');
    end;
    CheckEquals(0, Proc.PointInArea(Vector3(0, 0, 50)), 'point in room A');
    CheckEquals(1, Proc.PointInArea(Vector3(500, 0, 50)), 'point in room B');
    CheckEquals(1, Proc.Portals[0].PositiveArea, 'portal positive side');
    CheckEquals(1, Proc.ShadowModelCount, 'proc shadow models');
    SM := Proc.FindShadowModel('_PRELIGHT_LIGHT_1');
    Check(SM <> nil, 'find shadowModel _prelight_light_1');
    if SM <> nil then
    begin
      CheckEquals(16, Length(SM.Positions), 'prelight volume vertexes');
      CheckEquals(60, Length(SM.Indexes), 'prelight volume indexes');
      CheckEquals(36, SM.NoCaps, 'prelight volume sides (noCaps)');
      CheckEquals(48, SM.NoFrontCaps, 'prelight volume noFrontCaps');
    end;
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
    CheckEquals(41, MapFile.Entities.Count, 'entity count');
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
  Body, I, J, W, Reversed: Integer;
  Corners: array [0..7] of TVector3;
  Tris: TD3IndexArray;
  Closed, Outward: Boolean;
  Weight: TD3Md5Weight;
  Instance: TD3Md5Instance;
  SavedMax: Integer;
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

  { shadow hulls: a joint's matrix places joint-space points like skinning }
  Anim.FramePose(12, Pose);
  for W := 0 to High(Model.Meshes[0].Weights) do
    if Model.Meshes[0].Weights[W].Joint = Body then
    begin
      Weight := Model.Meshes[0].Weights[W];
      CheckVec3(D3ToCge(Pose[Body].Position + QuatRotate(Pose[Body].Orientation, Weight.Position)),
        JointMatrix(Pose[Body]).MultPoint(D3ToCge(Weight.Position)), 'joint matrix = skinning');
      Break;
    end;
  { the hull box is closed (every edge used once each way) and faces out }
  for I := 0 to 7 do
    Corners[I] := Vector3(10 * (I and 1), 4 * ((I shr 1) and 1), 7 * ((I shr 2) and 1));
  Tris := BoxTriangles(Corners);
  CheckEquals(36, Length(Tris), 'box triangles');
  Closed := True;
  Outward := True;
  for I := 0 to 11 do
  begin
    for J := 0 to 2 do
    begin
      Reversed := 0;
      for W := 0 to 35 do
        if (Tris[W] = Tris[I * 3 + (J + 1) mod 3]) and
           (Tris[(W div 3) * 3 + (W mod 3 + 1) mod 3] = Tris[I * 3 + J]) then
          Inc(Reversed);
      if Reversed <> 1 then
        Closed := False;
    end;
    if TVector3.DotProduct(
      TVector3.CrossProduct(Corners[Tris[I * 3 + 1]] - Corners[Tris[I * 3]],
        Corners[Tris[I * 3 + 2]] - Corners[Tris[I * 3]]),
      (Corners[Tris[I * 3]] + Corners[Tris[I * 3 + 1]] + Corners[Tris[I * 3 + 2]]) / 3 -
        Vector3(5, 2, 3.5)) <= 0 then
      Outward := False;
  end;
  Check(Closed, 'hull box is closed');
  Check(Outward, 'hull box faces outward');
  { a closed mesh over the limit casts with its own triangles }
  Check(Model.MeshClosed(0), 'the blob mesh is closed');
  SavedMax := MaxShadowCastingTriangles;
  MaxShadowCastingTriangles := 10;
  Instance := TD3Md5Instance.Create(Model, nil);
  try
    CheckEquals(0, Instance.ShadowHullCount, 'closed blob over the limit: no joint boxes');
    Check(Instance.Scene.CastShadows, 'the closed mesh casts');
  finally
    Instance.Free;
  end;
  { without r_md5ShadowClosed, a mesh over the limit casts with joint boxes }
  ClosedMeshesCastShadows := False;
  Instance := TD3Md5Instance.Create(Model, nil);
  try
    CheckEquals(6, Instance.ShadowHullCount, 'joint boxes of the blob (not the root)');
    Check(Instance.Scene.CastShadows, 'the boxes cast');
  finally
    Instance.Free;
    ClosedMeshesCastShadows := True;
    MaxShadowCastingTriangles := SavedMax;
  end;
  Instance := TD3Md5Instance.Create(Model, nil);
  try
    CheckEquals(0, Instance.ShadowHullCount, 'small meshes cast themselves');
  finally
    Instance.Free;
  end;
end;

procedure TestTrianglesClosed;
const
  { a tetrahedron, faces counter-clockwise from outside }
  Tetra: array [0..11] of Int32 = (0, 2, 1, 0, 1, 3, 1, 2, 3, 2, 0, 3);
var
  P: array [0..3] of TVector3;
begin
  P[0] := Vector3(0, 0, 0);
  P[1] := Vector3(10, 0, 0);
  P[2] := Vector3(0, 10, 0);
  P[3] := Vector3(0, 0, 10);
  Check(TrianglesClosed(P, Tetra), 'a tetrahedron is closed');
  Check(not TrianglesClosed(P, Slice(Tetra, 9)), 'three of its faces are open');
  { degenerate triangles are left out, like CGE's shadow casters: the two
    faces left are one triangle seen from both sides, closed }
  P[3] := Vector3(0, 0, 0);
  Check(TrianglesClosed(P, Tetra), 'degenerate faces are left out');
end;

procedure TestJointMods;
var
  Model: TD3Md5Model;
  Body, Head: TD3Md5Instance;
  P: TVector3;
begin
  { Doom 3 angles: yaw turns forward (+x) left (+y), pitch looks down }
  CheckVectorNear(Vector3(0, 1, 0), QuatRotate(QuatFromAngles(0, 90, 0), Vector3(1, 0, 0)), 'yaw 90 turns +x to +y');
  CheckVectorNear(Vector3(Cos(DegToRad(30)), 0, -Sin(DegToRad(30))),
    QuatRotate(QuatFromAngles(30, 0, 0), Vector3(1, 0, 0)), 'pitch 30 looks down');
  Model := Md5Cache.Model('models/md5/test/blob.md5mesh');
  if Model = nil then
    Exit;
  Body := TD3Md5Instance.Create(Model, nil);
  Head := TD3Md5Instance.Create(Model, nil);
  try
    { JOINTMOD_WORLD on "body": the subtree turns about the joint }
    Body.SetJointMod(Model.JointIndex('body'), QuatFromAngles(0, 90, 0));
    Body.Update(0);
    Check(Body.JointPosition('arm_l', P), 'arm_l joint');
    { arm_l is (0, 22, 20) from body (0, 0, 40): turned to (-22, 0, 20) }
    CheckVectorNear(D3ToCge(Vector3(-22, 0, 60)), P, 'a joint mod turns the joints under it');
    Check(Body.JointPosition('body', P), 'body joint');
    CheckVectorNear(D3ToCge(Vector3(0, 0, 40)), P, 'the turned joint stays in place');
    { copy_joint: the head's "body" takes the body's local rotation }
    Check(Head.AddCopyJoint(Body, 'body', 'body'), 'add a copy joint');
    Check(not Head.AddCopyJoint(Body, 'body', 'no_such_joint'), 'a missing joint is refused');
    Head.Update(0);
    CheckVectorNear(Vector3(0, 1, 0), QuatRotate(Head.Pose[Model.JointIndex('body')].Orientation, Vector3(1, 0, 0)),
      'the copied joint turned like the body''s');
    Body.ClearJointMods;
    Body.Update(0);
    Head.Update(0);
    CheckVectorNear(Vector3(1, 0, 0), QuatRotate(Head.Pose[Model.JointIndex('body')].Orientation, Vector3(1, 0, 0)),
      'cleared mods: back to the animation');
  finally
    Head.Free;
    Body.Free;
  end;
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
    CheckEquals(12, Cm.ModelCount, 'cm models (world + 9 brush entities + 2 triggers)');
    CheckEquals(1234567890, Cm.Crc, 'cm crc');
    W := Cm.World;
    Check((W <> nil) and (W.Name = 'worldMap'), 'worldMap model');
    if W = nil then
      Exit;
    CheckEquals(1, W.NodeCount, 'one leaf node');
    CheckEquals(21, Length(W.Brushes), 'brushes (playerclip + 20 solid)');
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
  App: TAppearanceNode;
  Proc: TD3ProcFile;
  Root: TX3DRootNode;
  Sprites: Integer;
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

  { more stages }
  M := Decls.Material('textures/test/door');
  CheckEquals('textures/test/metal_d.tga', M.DiffuseImage, 'door is lit');
  CheckEquals('textures/test/doorlights.tga', M.StageImage, 'door glow stage');
  CheckEquals(1, M.OverlayCount, 'door: the glow is an overlay');
  Check(M.StageColorAnimated, 'door glow pulses');
  App := OverlayAppearance('textures/test/door', 0);
  try
    Check(App.Material is TUnlitMaterialNode, 'overlay is unlit');
    Check((App.BlendMode <> nil) and (App.BlendMode.DestFactor = bdOne), 'overlay blends additively');
    Check(not App.ShadowCaster, 'overlay casts no shadow');
  finally
    FreeIfUnusedAndNil(App);
  end;

  M := Decls.ParseMaterial('test/inline_stages',
    '{ blend add map a.tga }' + LineEnding + '{ blend filter map b.tga' + LineEnding + 'rgb 0.5' + LineEnding +
      '}' + LineEnding + '{ blend diffusemap map c.tga }');
  try
    CheckEquals('a.tga', M.StageImage, 'first plain stage');
    CheckEquals(1, Length(M.ExtraStages), 'second plain stage kept');
    if Length(M.ExtraStages) = 1 then
    begin
      CheckEquals('b.tga', M.ExtraStages[0].Image, 'extra stage image');
      Check(M.ExtraStages[0].Blend = bmFilter, 'extra stage blend');
      Check(M.ExtraStages[0].ColorExpr[0] <> nil, 'extra stage color');
    end;
    CheckEquals('c.tga', M.DiffuseImage, 'diffuse stage after the plain ones');
    CheckEquals(2, M.OverlayCount, 'lit material: both plain stages are overlays');
  finally
    M.Free;
  end;

  M := Decls.Material('textures/test/glass');
  Check(M.DrawAsGlass, 'glass: only a reflection stage');
  CheckEquals('', M.SkyCubeMap, 'a reflected cube map is not a sky');
  CheckEquals('env/testenv', M.ReflectCubeMap, 'glass reflects a cube map');
  CheckEquals('', M.HazeNormalMap, 'glass: no heat haze');
  M := Decls.Material('textures/test/hazeglass');
  Check(M.DrawAsGlass, 'heat haze: only a program stage');
  CheckEquals('textures/test/haze_local.tga', M.HazeNormalMap, 'heat haze normal map (fragmentMap 1)');
  CheckEquals('', M.HazeMask, 'heatHaze.vfp has no mask');
  Check((M.HazeScroll[0] <> nil) and M.HazeScroll[0].UsesTime, 'heat haze scroll (vertexParm 0) uses time');
  Check(Abs(M.HazeMagnitude - 1.5) < 0.001, 'heat haze magnitude (vertexParm 1)');
  CheckEquals('', M.ReflectCubeMap, 'heat haze: no reflection');
  M := Decls.Material('textures/test/shinymetal');
  Check(not M.DrawAsGlass, 'shiny metal is lit');
  CheckEquals('textures/test/metal_d.tga', M.DiffuseImage, 'shiny metal diffuse map');
  CheckEquals('env/testenv', M.ReflectCubeMap, 'shiny metal reflects a cube map');
  Check(M.ReflectColorExpr[0] <> nil, 'reflection color (rgb)');
  M := Decls.Material('textures/test/flare');
  CheckEquals('sprite', M.Deform, 'deform sprite');
  Check(not M.DrawAsGlass, 'flare is drawn normally');

  Proc := TD3ProcFile.Create;
  Root := TX3DRootNode.Create;
  try
    Proc.LoadFromVfs('maps/testmap.proc');
    TDoom3Map.BuildProcModel(Proc.FindModel('door_1'), Root, Root);
    CheckEquals(3, Root.FdChildren.Count, 'door: metal, door and its overlay shapes');
    Root.FdChildren.Clear;
    Sprites := SpriteCount;
    TDoom3Map.BuildProcModel(Proc.Model(0), Root, Root);
    CheckEquals(1, SpriteCount - Sprites, 'one flare billboard in room A');
  finally
    Root.Free;
    Proc.Free;
  end;
end;

function PixelAt(const Img: TCastleImage; const X, Y: Integer): TVector4;
begin
  { GUI coordinates (640 x 480, y goes down) on the GuiImageWidth x
    GuiImageHeight image }
  Result := Img.Colors[Trunc((X + 0.5) * Img.Width / GuiWidth),
    Img.Height - 1 - Trunc((Y + 0.5) * Img.Height / GuiHeight), 0];
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
      CheckEquals(GuiImageWidth, Img.Width, 'GUI image width (a power of two)');
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

{ Is the polyhedron closed: every directed edge has its reverse in
  another face (what CGE's shadow volumes need)? }
function PolyhedronClosed(const P: TD3Polyhedron): Boolean;
var
  F, K, F2, K2: Integer;
  A, B: TVector3;
  Found: Boolean;
begin
  for F := 0 to High(P) do
    for K := 0 to High(P[F]) do
    begin
      A := P[F][K];
      B := P[F][(K + 1) mod Length(P[F])];
      Found := False;
      for F2 := 0 to High(P) do
        if F2 <> F then
          for K2 := 0 to High(P[F2]) do
            if TVector3.PerfectlyEquals(P[F2][K2], B) and
               TVector3.PerfectlyEquals(P[F2][(K2 + 1) mod Length(P[F2])], A) then
              Found := True;
      if not Found then
        Exit(False);
    end;
  Result := True;
end;

procedure TestShadowCasters;
var
  Brush: TD3CmBrush;
  Poly: TD3Polyhedron;
  Cm: TD3CollisionFile;
  W: TD3CollisionModel;
  I, Solid: Integer;
  AllClosed: Boolean;
  CasterRoot: TX3DRootNode;
  N: TVector3;
  App: TAppearanceNode;
begin
  { a 100 x 50 x 20 box brush: outward planes n . p = dist }
  Brush.Planes := [Vector4(1, 0, 0, 100), Vector4(-1, 0, 0, 0), Vector4(0, 1, 0, 50),
    Vector4(0, -1, 0, 0), Vector4(0, 0, 1, 20), Vector4(0, 0, -1, 0)];
  Brush.Mins := Vector3(0, 0, 0);
  Brush.Maxs := Vector3(100, 50, 20);
  Brush.Contents := 'solid';
  Poly := BrushPolyhedron(Brush, 0);
  CheckEquals(6, Length(Poly), 'box brush faces');
  Check((Length(Poly) > 0) and (Length(Poly[0]) = 4), 'box faces are quads');
  Check(PolyhedronClosed(Poly), 'box brush polyhedron is closed (2-manifold)');
  if Length(Poly) > 0 then
  begin
    { the first face (+X) is counter-clockwise seen from outside }
    N := TVector3.CrossProduct(Poly[0][1] - Poly[0][0], Poly[0][2] - Poly[0][0]);
    Check(N.X > 0, 'faces are counter-clockwise from outside');
    CheckNear(100, Poly[0][0].X, '+X face position');
  end;
  Poly := BrushPolyhedron(Brush, 1);
  if Length(Poly) > 0 then
    CheckNear(99, Poly[0][0].X, 'inset moves faces inside');
  { a wedge (5 planes) }
  Brush.Planes := [Vector4(0, 0, -1, 0), Vector4(0, -1, 0, 0), Vector4(0, 1, 0, 64),
    Vector4(-1, 0, 0, 0), Vector4(0.7071, 0, 0.7071, 45.25)];
  Brush.Maxs := Vector3(64, 64, 64);
  Poly := BrushPolyhedron(Brush, 0);
  CheckEquals(5, Length(Poly), 'wedge faces');
  Check(PolyhedronClosed(Poly), 'wedge polyhedron is closed');

  Cm := TD3CollisionFile.Create;
  try
    Cm.LoadFromVfs('maps/testmap.cm');
    W := Cm.World;
    Solid := 0;
    AllClosed := True;
    for I := 0 to High(W.Brushes) do
      if W.BrushCastsShadows(I) then
      begin
        Inc(Solid);
        if not PolyhedronClosed(BrushPolyhedron(W.Brushes[I], 1)) then
          AllClosed := False;
      end;
    CheckEquals(20, Solid, 'solid brushes cast shadows, the playerclip brush not');
    Check(AllClosed, 'every test level brush makes a closed caster');
    { the casters are shadow-only: invisible shapes }
    CasterRoot := BuildShadowCasterNode(W.Brushes, 1);
    try
      Check(CasterRoot.FdChildren.Count > 0, 'shadow caster shapes built');
      Check(not (CasterRoot.FdChildren[0] as TShapeNode).Visible, 'shadow casters are not rendered');
    finally
      CasterRoot.Free;
    end;
  finally
    Cm.Free;
  end;

  App := MaterialAppearance('textures/test/lightpanel');
  try
    Check(not App.ShadowCaster, 'noshadows material does not cast');
  finally
    App.Free;
  end;
  App := MaterialAppearance('textures/test/floor');
  try
    Check(App.ShadowCaster, 'other materials cast');
  finally
    App.Free;
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

procedure TestTriggers;
var
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  LightTrig, I: Integer;
  Relay: TD3MapEntity;
begin
  { the map in a world, like in a viewport (sound sources need one) }
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Map.SpawnModels := False;
    Check(Map.LoadMap('testmap'), 'load testmap for triggers');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    CheckEquals(2, Game.Triggers.Count, 'two trigger volumes (trigger_once_1, trigger_once_cin)');
    if Game.Triggers.Count <> 2 then
      Exit;
    { the volume comes from the .cm model at the entity origin (330 0 56):
      x 306..354, Doom 3 z 0..112 = CGE y }
    CheckNear(306, Game.Triggers[0].Box.Data[0].X, 'trigger volume min x');
    CheckNear(354, Game.Triggers[0].Box.Data[1].X, 'trigger volume max x');
    CheckNear(112, Game.Triggers[0].Box.Data[1].Y, 'trigger volume top');

    LightTrig := Map.FindLight('light_trig');
    Check(LightTrig >= 0, 'light_trig exists');
    if LightTrig < 0 then
      Exit;
    Check(not Map.Light(LightTrig).StartOn, 'light_trig starts off');

    { the player outside: nothing fires }
    Game.Update(0.1, D3ToCge(Vector3(200, 0, 0)) + Vector3(0, PlayerEyeHeight, 0));
    Check(not Game.Triggers[0].Disabled, 'trigger waits outside');
    { the player inside: trigger_once fires trigger_relay_1 (delay 0.5) }
    Game.Update(0.1, D3ToCge(Vector3(330, 0, 0)) + Vector3(0, PlayerEyeHeight, 0));
    Check(Game.Triggers[0].Disabled, 'trigger_once fired once');
    Check(not Map.Light(LightTrig).StartOn, 'light waits for the relay delay');
    for I := 1 to 7 do
      Game.Update(0.1, D3ToCge(Vector3(200, 0, 0)) + Vector3(0, PlayerEyeHeight, 0));
    Check(Map.Light(LightTrig).StartOn, 'relay switched light_trig on after 0.5 s');

    { activating a light again toggles it off }
    Relay := Game.FindEntity('trigger_relay_1');
    Check(Relay <> nil, 'find trigger_relay_1 by name');
    if Relay <> nil then
    begin
      Game.Activate(Relay);
      for I := 1 to 7 do
        Game.Update(0.1, D3ToCge(Vector3(200, 0, 0)) + Vector3(0, PlayerEyeHeight, 0));
      Check(not Map.Light(LightTrig).StartOn, 'activating the relay again switches the light off');
    end;
  finally
    FreeAndNil(Game);
    FreeAndNil(World);
  end;
end;

type
  { Entities 1 (busy until released) and 2 (with a script object) for
    TestScriptVM; events are logged in Calls. }
  TTestScriptHost = class(TD3ScriptHost)
    Busy: Boolean;
    Obj: TD3ScriptObject;
    Calls: TStringList;
    Printed: String;
    constructor Create;
    destructor Destroy; override;
    function FindEntity(const AName: String): Integer; override;
    function EntityObject(const E: Integer): TD3ScriptObject; override;
    function EntityBusy(const E: Integer): Boolean; override;
    function CallEvent(const Thread: TD3ScriptThread; const Target: Integer;
      const Event: TD3ScriptEvent; const Args: TD3ValueArray;
      var EventResult: TD3Value): Boolean; override;
    procedure Print(const S: String); override;
  end;

constructor TTestScriptHost.Create;
begin
  inherited;
  Calls := TStringList.Create;
end;

destructor TTestScriptHost.Destroy;
begin
  Calls.Free;
  Obj.Free;
  inherited;
end;

function TTestScriptHost.FindEntity(const AName: String): Integer;
begin
  if AName = 'mover' then
    Result := 1
  else
  if AName = 'thing' then
    Result := 2
  else
    Result := 0;
end;

function TTestScriptHost.EntityObject(const E: Integer): TD3ScriptObject;
begin
  if E = 2 then
    Result := Obj
  else
    Result := nil;
end;

function TTestScriptHost.EntityBusy(const E: Integer): Boolean;
begin
  Result := (E = 1) and Busy;
end;

function TTestScriptHost.CallEvent(const Thread: TD3ScriptThread; const Target: Integer;
  const Event: TD3ScriptEvent; const Args: TD3ValueArray; var EventResult: TD3Value): Boolean;
var
  S: String;
  I: Integer;
begin
  S := Format('%d.%s(', [Target, Event.Name]);
  for I := 0 to High(Args) do
  begin
    if I > 0 then
      S := S + ',';
    S := S + D3ValueToString(Args[I]);
  end;
  Calls.Add(S + ')');
  if Event.Name = 'getName' then
    EventResult := D3StringValue('ent' + IntToStr(Target));
  Result := True;
end;

procedure TTestScriptHost.Print(const S: String);
begin
  Printed := Printed + S;
end;

const
  TestScriptSource =
    '#define TWICE( x ) ( (x) * 2 )' + LineEnding +
    '#define ANSWER 42' + LineEnding +
    '#ifndef ANSWER' + LineEnding +
    'this is not compiled' + LineEnding +
    '#endif' + LineEnding +
    'scriptEvent void wait( float time );' + LineEnding +
    'scriptEvent void waitFor( entity mover );' + LineEnding +
    'scriptEvent void waitFrame();' + LineEnding +
    'scriptEvent void waitForThread( float threadNumber );' + LineEnding +
    'scriptEvent void killthread( string threadName );' + LineEnding +
    'scriptEvent void print( string text );' + LineEnding +
    'scriptEvent void trigger( entity ent );' + LineEnding +
    'scriptEvent string getName();' + LineEnding +
    'scriptEvent void move( float dir, float dist );' + LineEnding +
    'float prec1, prec2, prec3, prec4, prec5, macro1, int1;' + LineEnding +
    'vector v = ''1 2 3'';' + LineEnding +
    'float dot, comp;' + LineEnding +
    'string str;' + LineEnding +
    'float loops, fact, steps, waited, after, killed, threaded;' + LineEnding +
    'float objresult, field1;' + LineEnding +
    'object base { float hits; float value(); void hit(); };' + LineEnding +
    'object derived : base { float value(); };' + LineEnding +
    'float base::value() { return 1; }' + LineEnding +
    'float derived::value() { return 2 + hits; }' + LineEnding +
    'void base::hit() { hits++; }' + LineEnding +
    'namespace ns {' + LineEnding +
    '  float factorial( float n ) { if ( n <= 1 ) { return 1; } return n * factorial( n - 1 ); }' + LineEnding +
    '  void counter() { while ( 1 ) { steps++; sys.waitFrame(); } }' + LineEnding +
    '}' + LineEnding +
    'void waiter() { sys.wait( 1 ); waited = 1; }' + LineEnding +
    'void main() {' + LineEnding +
    '  float i, t;' + LineEnding +
    '  prec1 = 2 + 3 * 4;' + LineEnding +           // 14
    '  prec2 = 1 | 2 + 4;' + LineEnding +           // (1 | 2) + 4 = 7: | is a priority 3 operator
    '  prec3 = 2 * 3 == 6;' + LineEnding +          // 1
    '  prec4 = 10 - 4 - 3;' + LineEnding +          // 3
    '  prec5 = -2 * -3;' + LineEnding +             // 6
    '  macro1 = TWICE( ANSWER + 1 );' + LineEnding +  // 86
    '  int1 = int( 7.9 ) + 8 % 3;' + LineEnding +   // 9
    '  dot = v * ''1 1 1'';' + LineEnding +         // 6
    '  v_y = 5;' + LineEnding +
    '  comp = v_y + v_z;' + LineEnding +            // 8
    '  str = "a" + 1.5 + "b" + 2;' + LineEnding +   // a1.5b2
    '  for ( i = 0; i < 10; i++ ) { if ( i == 2 ) { continue; } if ( i == 5 ) { break; } loops += i; }' + LineEnding + // 0+1+3+4 = 8
    '  do { loops = loops + 100; } while ( loops < 300 );' + LineEnding + // 308
    '  fact = ns::factorial( 5 );' + LineEnding +    // 120
    '  thread ns::counter();' + LineEnding +
    '  t = thread waiter();' + LineEnding +
    '  sys.waitFor( $mover );' + LineEnding +
    '  sys.waitForThread( t );' + LineEnding +
    '  after = waited;' + LineEnding +
    '  sys.killthread( "ns::counter" );' + LineEnding +
    '  killed = steps;' + LineEnding +
    '  $thing.hit();' + LineEnding +
    '  $thing.hit();' + LineEnding +
    '  objresult = $thing.value();' + LineEnding +  // derived: 2 + 2 hits
    '  sys.trigger( $mover );' + LineEnding +
    '  $mover.move( -1, 64 );' + LineEnding +
    '  sys.print( $mover.getName() + "\n" );' + LineEnding +
    '  $null_entity.move( 1, 2 );' + LineEnding +
    '}' + LineEnding;

procedure TestScriptVM;
var
  VM: TD3ScriptVM;
  Host: TTestScriptHost;
  T: TD3ScriptThread;
  I: Integer;
  Steps: Single;
begin
  VM := TD3ScriptVM.Create;
  Host := TTestScriptHost.Create;
  try
    VM.Host := Host;
    try
      VM.CompileText(TestScriptSource, 'test.script');
    except
      on E: ED3ScriptError do
      begin
        Check(False, 'test script compiles: ' + E.Message);
        Exit;
      end;
    end;
    Check(VM.FindFunction('ns::factorial') <> nil, 'namespaced function');
    Check(VM.FindType('derived') <> nil, 'object type');
    if VM.FindType('derived') = nil then
      Exit;
    Host.Obj := TD3ScriptObject.Create(VM.FindType('derived'));
    Host.Busy := True;
    T := VM.StartThread(VM.FindFunction('main'));
    Check(T <> nil, 'main waits for the mover');
    CheckNear(14, VM.GlobalValue('prec1').F, '2 + 3 * 4');
    CheckNear(7, VM.GlobalValue('prec2').F, '1 | 2 + 4 (| has * priority)');
    CheckNear(1, VM.GlobalValue('prec3').F, '2 * 3 == 6');
    CheckNear(3, VM.GlobalValue('prec4').F, '10 - 4 - 3 (left associative)');
    CheckNear(6, VM.GlobalValue('prec5').F, 'unary minus');
    CheckNear(86, VM.GlobalValue('macro1').F, 'macro with a parameter');
    CheckNear(9, VM.GlobalValue('int1').F, 'int() and %');
    CheckNear(6, VM.GlobalValue('dot').F, 'vector * vector is the dot product');
    CheckNear(8, VM.GlobalValue('comp').F, 'vector components v_y / v_z');
    CheckEquals('a1.5b2', VM.GlobalValue('str').S, 'string concatenation');
    CheckNear(308, VM.GlobalValue('loops').F, 'for / continue / break / do-while');
    CheckNear(120, VM.GlobalValue('fact').F, 'recursion');
    CheckNear(1, VM.GlobalValue('steps').F, 'a thread runs at once until it waits');
    { frames: the mover keeps main waiting }
    for I := 1 to 3 do
      VM.Update(0.1 * I);
    Check(VM.ThreadByNumber(T.Number) <> nil, 'main still waits for the busy mover');
    Host.Busy := False;
    VM.Update(0.4);
    CheckNear(0, VM.GlobalValue('after').F, 'main now waits for the waiter thread');
    VM.Update(1.1);
    { main wakes up the frame after the waiter ended }
    VM.Update(1.15);
    CheckNear(1, VM.GlobalValue('after').F, 'sys.wait( 1 ) and waitForThread');
    Steps := VM.GlobalValue('killed').F;
    Check(Steps >= 5, 'the counter thread ran every frame');
    VM.Update(1.25);
    CheckNear(Steps, VM.GlobalValue('steps').F, 'killthread stopped the counter');
    CheckNear(2, Host.Obj.Fields[0].F, 'object field updated by a method');
    CheckNear(4, VM.GlobalValue('objresult').F, 'virtual method of the derived type');
    Check(Host.Calls.IndexOf('0.trigger(1)') >= 0, 'sys.trigger goes to the host');
    Check(Host.Calls.IndexOf('1.move(-1,64)') >= 0, 'entity event with arguments');
    CheckEquals('ent1' + #10, Host.Printed, 'event result used in an expression');
    CheckEquals(0, VM.ThreadCount, 'all threads ended');
  finally
    VM.Free;
    Host.Free;
  end;
end;

{ The test map's scripts (maps/testmap.script) run by a TD3Game. }
procedure TestMapScripts;
var
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  Lift, Bar: TD3BrushEntity;
  LightTrig, I: Integer;
  Away: TVector3;
  Box: TBox3D;
  Mid: Single;
  GuisBefore: Integer;
begin
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Map.SpawnModels := False;
    Check(Map.LoadMap('testmap'), 'load testmap for scripts');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    Check(Game.Script <> nil, 'the test map''s scripts compile');
    Lift := Map.FindBrush('lift_1');
    Bar := Map.FindBrush('bar_1');
    LightTrig := Map.FindLight('light_trig');
    Check((Lift <> nil) and (Bar <> nil) and (LightTrig >= 0), 'lift_1, bar_1, light_trig exist');
    if (Game.Script = nil) or (Lift = nil) or (Bar = nil) or (LightTrig < 0) then
      Exit;
    CheckEquals(18, Game.Script.FunctionCount, 'script functions');
    CheckNear(4, Lift.Scene.Translation.Y, 'lift starts on the floor');
    Away := D3ToCge(Vector3(-160, -160, 0)) + Vector3(0, PlayerEyeHeight, 0);
    { main starts on the first frame: the lift goes up 64 in 2 s (accelerating
      for 0.5 s, decelerating for 0.5 s); the bar turns in 1 s }
    for I := 1 to 11 do
      Game.Update(0.1, Away);
    Mid := Lift.Scene.Translation.Y;
    Check((Mid > 20) and (Mid < 52), Format('lift half way after 1 s (%.1f)', [Mid]));
    CheckNear(1, Game.Script.GlobalValue('bar_turned').F, 'sys.waitFor( $bar_1 ) returned');
    { the bar reached along local +x (east): turned by yaw +90 it reaches
      north, Doom 3 y -300..-252 = CGE z 252..300 }
    Box := Bar.Scene.BoundingBox;
    CheckNear(596, Box.Data[0].X, 'turned bar min x', 0.5);
    CheckNear(604, Box.Data[1].X, 'turned bar max x', 0.5);
    CheckNear(252, Box.Data[0].Z, 'turned bar min z (Doom 3 -y)', 0.5);
    CheckNear(300, Box.Data[1].Z, 'turned bar max z', 0.5);
    for I := 1 to 11 do
      Game.Update(0.1, Away);
    CheckNear(4 + 64, Lift.Scene.Translation.Y, 'lift up after 2 s');
    CheckEquals(2, Game.Script.ThreadCount, 'the lift loop and main (waiting to move bar_1 along its curve) run');
    { trigger_once_1's "call" runs test_trigger_called on the next frame }
    GuisBefore := GuiCacheCount;
    Game.Update(0.1, D3ToCge(Vector3(330, 0, 0)) + Vector3(0, PlayerEyeHeight, 0));
    Game.Update(0.1, Away);
    CheckNear(1, Game.Script.GlobalValue('trigger_calls').F, 'the trigger''s call key ran');
    CheckEquals('TRIGGERED', Map.FindBrush('panel_1').Entity.Value('gui_parm1'), 'setGuiParm set the key');
    { the panel's screen shows that state already; another value redraws it }
    CheckEquals(0, Map.SetGuiParm(Map.FindBrush('panel_1').Entity, 'gui_parm1', 'TRIGGERED'),
      'setGuiParm redrew the panel''s GUI (same value: nothing to redraw)');
    CheckEquals(1, Map.SetGuiParm(Map.FindBrush('panel_1').Entity, 'gui_parm1', 'AREA A'),
      'SetGuiParm redraws the GUI screen for a new value');
    Check(GuiCacheCount >= GuisBefore, 'GUI states are cached');
    for I := 1 to 12 do
      Game.Update(0.1, Away);
    Check(Map.Light(LightTrig).StartOn, 'the relay switched light_trig on');
    CheckNear(0, Map.Light(LightTrig).Parms.Parms[0], 'setColor: red 0');
    CheckNear(1, Map.Light(LightTrig).Parms.Parms[1], 'setColor: green 1');
    for I := 1 to 20 do
      Game.Update(0.1, Away);
    CheckNear(0, Map.Light(LightTrig).Fade, 'fadeOutLight( 1 ) faded the light out');
    CheckNear(1, Game.Script.GlobalValue('lift_trips').F, 'the lift went up and down once');
    CheckNear(4, Lift.Scene.Translation.Y, 'lift back down');
    { bar_1 followed spline_1 (2 s, from 2 s after its turn) to its end }
    CheckNear(1, Game.Script.GlobalValue('bar_splined').F, 'startSpline: waitFor returned');
    CheckNear(750, Bar.Scene.Translation.X, 'bar_1 at the curve''s end x', 0.5);
    CheckNear(250, Bar.Scene.Translation.Z, 'bar_1 at the curve''s end (Doom 3 y -250)', 0.5);
  finally
    FreeAndNil(Game);
    FreeAndNil(World);
  end;
end;

procedure TestCinematics;
var
  Anim: TD3CameraAnim;
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  Origin, Fwd, Up, P, D, U, Feet: TVector3;
  Fov, Yaw: Single;
  I: Integer;
  Away: TVector3;
  Blob: TD3ModelEntity;
  Light5: Integer;
  Light5On: Boolean;
  Walk: Single;
begin
  Anim := TD3CameraAnim.Create;
  try
    Check(Anim.LoadFromVfs(D3CameraAnimPath('models/md5/cameras/test_flyby.camera')),
      'load test_flyby.md5camera (decls say .camera)');
    CheckEquals(73, Length(Anim.Frames), 'camera frames');
    CheckEquals(1, Length(Anim.Cuts), 'camera cuts');
    { 73 frames, one of them skipped at the cut: 71 frame steps at 24 fps }
    CheckNear(71 / 24, Anim.Duration, 'camera anim duration');
    Anim.Sample(0, Origin, Fwd, Up, Fov);
    CheckNear(380, Origin.X, 'first frame origin x');
    CheckNear(1, Fwd.Y, 'first shot looks north (+Y)');
    CheckNear(1, Up.Z, 'first shot up is +Z');
    CheckNear(90, Fov, 'first shot fov');
    { before the cut, the first shot's last frame (no blend into the next shot) }
    Anim.Sample(36.5 / 24, Origin, Fwd, Up, Fov);
    CheckNear(700, Origin.X, 'just before the cut: the first shot''s end');
    { after the cut (Doom 3 skips frame 37): the balcony shot }
    Anim.Sample(37.5 / 24, Origin, Fwd, Up, Fov);
    CheckNear(800, Origin.X, 'after the cut: the second shot''s origin');
    CheckNear(70, Fov, 'after the cut: the second shot''s fov');
    Check(Fwd.X < 0, 'second shot looks back west');
  finally
    Anim.Free;
  end;

  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    { md5 models too: the cinematic's idAnimated blob }
    Check(Map.LoadMap('testmap'), 'load testmap for cinematics');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    Blob := Map.FindModelEntity('animated_blob_1');
    Check(Blob <> nil, 'animated_blob_1 built');
    if Blob = nil then
      Exit;
    CheckEquals(1, Game.Animated.Count, 'one idAnimated entity');
    Check(not Blob.Holder.Exists, 'the idAnimated blob is hidden until triggered');
    { def_head: a head model at the "head" joint (Doom 3 z 76 = CGE y) }
    Check(Blob.HeadInstance <> nil, 'def_head built a head');
    if Blob.HeadInstance <> nil then
      CheckNear(76, Blob.HeadHolder.Translation.Y, 'the head sits at the head joint', 1);
    Light5 := Map.FindLight('light_5');
    Light5On := Map.Light(Light5).StartOn;
    Away := D3ToCge(Vector3(-160, -160, 0)) + Vector3(0, PlayerEyeHeight, 0);
    { walk into trigger_once_cin: fade to black in 0.3 s, then the camera }
    Game.Update(0.1, D3ToCge(Vector3(340, -340, 0)) + Vector3(0, PlayerEyeHeight, 0));
    Check(not Game.CinematicActive, 'no camera before the relay''s delay');
    for I := 1 to 3 do
      Game.Update(0.1, Away);
    CheckNear(1, Game.FadeColor.W, 'trigger_fade faded to black', 0.05);
    Game.Update(0.1, Away);
    Check(Game.CinematicActive, 'the relay started the camera');
    Check(Blob.Holder.Exists, 'the relay showed the idAnimated blob');
    Walk := Blob.Instance.AnimLength;
    Check(Walk > 0, 'the blob plays its walk anim');
    CheckEquals('test_cam_1', Game.CinematicName, 'cinematic camera name');
    Game.CinematicView(P, D, U, Fov);
    CheckNear(380, CgeToD3(P).X, 'cinematic view at the anim''s first frames', 30);
    CheckNear(-1, D.Z, 'cinematic view looks north (CGE -Z)', 0.01);
    Check(Game.FadeColor.W < 1, 'fading back in');
    for I := 1 to 6 do
      Game.Update(0.1, Away);
    CheckNear(0, Game.FadeColor.W, 'faded in after 0.5 s');
    { the anim lasts 71 / 24 s, then the camera fires info_player_teleport_1 }
    for I := 1 to 30 do
      Game.Update(0.1, Away);
    Check(not Game.CinematicActive, 'the camera stopped at the anim''s end');
    Check(Game.TakeTeleport(Feet, Yaw), 'the camera''s target teleports the player');
    CheckNear(500, CgeToD3(Feet).X, 'teleport x');
    CheckNear(200, CgeToD3(Feet).Y, 'teleport y');
    CheckNear(180, Yaw, 'teleport yaw');
    Check(not Game.TakeTeleport(Feet, Yaw), 'a teleport is taken once');
    { "cycle" "2": the walk twice since the relay, then "remove" and the target }
    for I := 1 to Round(Walk * 2 * 10) do
      Game.Update(0.1, Away);
    Check(not Blob.Holder.Exists, 'the idAnimated blob is removed after its anim');
    Check(Map.Light(Light5).StartOn <> Light5On, 'the blob''s anim end fired its target (light_5)');
  finally
    FreeAndNil(Game);
    FreeAndNil(World);
  end;
end;

{ A character running its AI script (test map: test_walker_1). }
procedure TestActors;
var
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  A: TD3Actor;
  I: Integer;
  Away, Pos: TVector3;
  SawWalk: Boolean;
  RemoveMe: TRemoveType;
  HeadM: TMatrix4;
begin
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Check(Map.LoadMap('testmap'), 'load testmap for actors');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    CheckEquals(2, Game.Actors.Count, 'two actors (blob_scripted_1, test_walker_1)');
    A := nil;
    for I := 0 to Game.Actors.Count - 1 do
      if Game.Actors[I].Model.Entity.Name = 'test_walker_1' then
        A := Game.Actors[I];
    if A = nil then
      Exit;
    Away := D3ToCge(Vector3(-160, -160, 0)) + Vector3(0, PlayerEyeHeight, 0);
    for I := 1 to 3 do
      Game.Update(0.1, Away);
    { init -> setNextState -> state_Begin, which starts the legs' state }
    CheckEquals('state_Begin', A.StateName, 'init set the state');
    CheckEquals('Legs_Idle', A.Channels[2].StateName, 'animState on the legs');
    CheckEquals('idle', A.Channels[2].AnimName, 'idleAnim on the legs');
    { activation: AI_ACTIVATED, then the walk }
    Game.Activate(Game.FindEntity('test_walker_1'));
    SawWalk := False;
    for I := 1 to 40 do
    begin
      Game.Update(0.1, Away);
      if (A.Channels[2].StateName = 'Legs_Walk') and (A.Channels[2].AnimName = 'walk') then
        SawWalk := True;
    end;
    Check(SawWalk, 'AI_FORWARD switched the legs to Legs_Walk playing walk');
    CheckNear(1, Game.Script.GlobalValue('walker_done').F, 'the character reached state_Done');
    Pos := CgeToD3(A.Model.Holder.Translation);
    CheckNear(-80, Pos.X, 'the character walked to path_corner_1 x', 1);
    CheckNear(60, Pos.Y, 'the character walked to path_corner_1 y', 1);
    CheckNear(90, A.Yaw, 'turnTo( 90 ) turned it north');
    CheckEquals('Legs_Idle', A.Channels[2].StateName, 'the legs are idle again');
    { talking: the use key in front of it (TALK_OK since state_Done) }
    Check(A.Model.HeadInstance <> nil, 'it has a head (def_head)');
    Pos := CgeToD3(A.Model.Holder.Translation);
    Game.Use(D3ToCge(Pos + Vector3(0, 60, 0)) + Vector3(0, 48, 0), D3ToCge(Vector3(0, -1, 0)));
    CheckEquals(PlayerHandle, A.TalkTarget, 'Use made the player its talk target (AI_TALK)');
    { it looks at the player (lookAt): the player steps to its right
      (north-east of it, 45 degrees right of its facing north) }
    Away := D3ToCge(Pos + Vector3(60, 60, 0)) + Vector3(0, PlayerEyeHeight, 0);
    for I := 1 to 10 do
    begin
      Game.Update(0.1, Away);
      RemoveMe := rtNone;
      Map.Update(0.1, RemoveMe);
    end;
    CheckNear(-45, A.LookAngles.Y, 'lookAt( $player1 ) turned its head right', 3);
    Check(A.Model.Instance.JointTransform('head', HeadM), 'head joint');
    Pos := CgeToD3(HeadM.MultDirection(D3ToCge(Vector3(1, 0, 0))));
    CheckNear(-45, RadToDeg(ArcTan2(Pos.Y, Pos.X)), 'the head joint (the head on it) turned', 3);
    { the head's talk_primary lasts 2 s }
    for I := 1 to 20 do
    begin
      Game.Update(0.1, Away);
      RemoveMe := rtNone;
      Map.Update(0.1, RemoveMe);
    end;
    CheckNear(1, Game.Script.GlobalValue('walker_talks').F, 'it said its line (head talk_primary) once');
    CheckEquals(0, A.TalkTarget, 'setTalkTarget( $null_entity ) ended the talk');
  finally
    FreeAndNil(Game);
    FreeAndNil(World);
  end;
end;

{ A monster running its AI script (test map: blob_scripted_1). }
procedure TestScriptedMonster;
var
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  A: TD3Actor;
  M: TD3Monster;
  I: Integer;
  Eye, Target: TVector3;
  RemoveMe: TRemoveType;

  { the game, and the map's md5 animations (their frame commands) }
  procedure Step;
  begin
    Game.Update(0.1, Eye);
    RemoveMe := rtNone;
    Map.Update(0.1, RemoveMe);
  end;

begin
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Check(Map.LoadMap('testmap'), 'load testmap for the scripted monster');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    A := nil;
    for I := 0 to Game.Actors.Count - 1 do
      if Game.Actors[I].Model.Entity.Name = 'blob_scripted_1' then
        A := Game.Actors[I];
    Check(A <> nil, 'blob_scripted_1 runs its script');
    if A = nil then
      Exit;
    Check(A.Monster <> nil, 'the scripted monster has its game monster (health, shots)');
    { only this one hunts: the others (simple AI) sleep }
    for M in Game.Monsters do
      if M.Actor = nil then
        M.Dormant := True;
    { the player on the balcony, 100 units west of it, in its view }
    Eye := D3ToCge(Vector3(740, 300, 96)) + Vector3(0, PlayerEyeHeight, 0);
    for I := 1 to 5 do
      Step;
    CheckEquals('state_Combat', A.StateName, 'it saw the player: state_Combat');
    for I := 1 to 30 do
      Step;
    Check(Game.Health < 100, Format('its melee frame command hurt the player (health %d)', [Game.Health]));
    Check(Abs(CgeToD3(A.Model.Holder.Translation).X - 740) < 80, 'it came to the player');
    { shoot it (40 health, 14 per shot) }
    for I := 1 to 20 do
    begin
      Target := A.Model.Holder.Translation + Vector3(0, 36, 0);
      Game.Fire(Eye, (Target - Eye).Normalize);
      Step;
      if A.Monster.State = msDead then
        Break;
    end;
    Check(A.Monster.State = msDead, 'shot dead');
    for I := 1 to 3 do
      Step;
    CheckNear(1, Game.Script.GlobalValue('monster_killed').F, 'death started state_Killed');
    Check(not A.Thinking, 'stopThinking');
  finally
    FreeAndNil(Game);
    FreeAndNil(World);
  end;
end;

{ A scripted monster throwing projectiles (launch_missile frame command). }
procedure TestAas;
var
  Aas: TD3AasFile;
  Path: TD3AasPath;
begin
  Aas := TD3AasFile.Create;
  try
    Check(Aas.LoadFromVfs('maps/testmap.aas48'), 'load testmap.aas48');
    CheckEquals(5, Length(Aas.Areas), 'AAS areas (with the dummy 0)');
    CheckEquals(7, Aas.ReachCount, 'AAS reachabilities');
    CheckEquals(1, Aas.PointAreaNum(Vector3(0, 0, 10)), 'room A is area 1');
    CheckEquals(2, Aas.PointAreaNum(Vector3(264, 0, 10)), 'the doorway is area 2');
    CheckEquals(3, Aas.PointAreaNum(Vector3(400, 0, 10)), 'room B is area 3');
    CheckEquals(4, Aas.PointAreaNum(Vector3(800, 0, 100)), 'the balcony is area 4');
    CheckEquals(0, Aas.PointAreaNum(Vector3(800, 0, 10)), 'under the balcony is solid');
    CheckEquals(0, Aas.PointAreaNum(Vector3(264, 100, 10)), 'the wall beside the doorway is solid');
    CheckEquals(4, Aas.OriginAreaNum(Vector3(840, 300, 96)), 'blob_scripted_1 stands in area 4');
    Check(Aas.FindPath(4, 1, WalkingTravelFlags, Path), 'a path from the balcony to room A');
    CheckEquals(3, Length(Path), 'balcony -> room B -> doorway -> room A');
    if Length(Path) = 3 then
    begin
      CheckEquals(4, Path[0].Area, 'the path starts on the balcony');
      CheckEquals(2, Aas.Areas[Path[1].Area].Reach[Path[1].Reach].ToArea, 'then to the doorway');
      CheckEquals(1, Aas.Areas[Path[2].Area].Reach[Path[2].Reach].ToArea, 'then into room A');
    end;
    Check(not Aas.FindPath(3, 4, TFL_WALKOFFLEDGE, Path), 'no way up with walk off ledge only');
    Check(Aas.FindPath(2, 2, WalkingTravelFlags, Path) and (Length(Path) = 0), 'the same area: an empty path');
  finally
    Aas.Free;
  end;
end;

procedure TestAasChase;
var
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  M: TD3Monster;
  A: TD3Actor;
  I: Integer;
  Eye, Pos, WP: TVector3;
  Route: TD3Route;
  RemoveMe: TRemoveType;
begin
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Check(Map.LoadMap('testmap'), 'load testmap for AAS routes');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    Check(Game.Aas <> nil, 'the game loads maps/testmap.aas48');
    if Game.Aas = nil then
      Exit;
    { the waypoints: down the stairs, then through the doorway }
    FillChar(Route, SizeOf(Route), 0);
    WP := Game.RouteWaypoint(Route, Vector3(840, 300, 96), Vector3(-100, -200, 0));
    CheckNear(695.5, WP.X, 'from the balcony: the stairs first');
    FillChar(Route, SizeOf(Route), 0);
    WP := Game.RouteWaypoint(Route, Vector3(400, 300, 0), Vector3(-100, -200, 0));
    CheckNear(295.5, WP.X, 'from room B: to the doorway');
    CheckNear(0, WP.Y, 'the doorway''s middle');
    FillChar(Route, SizeOf(Route), 0);
    WP := Game.RouteWaypoint(Route, Vector3(-100, 100, 0), Vector3(-100, -200, 0));
    CheckNear(-200, WP.Y, 'the same area: straight to the goal');

    { blob_scripted_1 sees the player in room B, then chases it into room
      A, out of line with the doorway: only the route gets it there }
    A := nil;
    for M in Game.Monsters do
      if M.Actor = nil then
        M.Dormant := True
      else
      if M.Model.Entity.Name = 'blob_scripted_1' then
        A := M.Actor;
    Check(A <> nil, 'blob_scripted_1 runs its script');
    if A = nil then
      Exit;
    Game.God := True;
    Eye := D3ToCge(Vector3(760, 300, 96)) + Vector3(0, PlayerEyeHeight, 0);
    for I := 1 to 10 do
    begin
      Game.Update(0.1, Eye);
      RemoveMe := rtNone;
      Map.Update(0.1, RemoveMe);
    end;
    Check(A.HasEnemy, 'it saw the player');
    Eye := D3ToCge(Vector3(-100, -200, 0)) + Vector3(0, PlayerEyeHeight, 0);
    for I := 1 to 300 do
    begin
      Game.Update(0.1, Eye);
      RemoveMe := rtNone;
      Map.Update(0.1, RemoveMe);
    end;
    Pos := CgeToD3(A.Model.Holder.Translation);
    Check(Pos.X < 232, Format('it went through the doorway into room A (at %s)', [Pos.ToString]));
  finally
    FreeAndNil(Game);
    FreeAndNil(World);
  end;
end;

procedure TestProjectiles;
var
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  M: TD3Monster;
  I: Integer;
  Eye: TVector3;
  SawFlying: Boolean;
  RemoveMe: TRemoveType;
begin
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Check(Map.LoadMap('testmap'), 'load testmap for projectiles');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    for M in Game.Monsters do
      if M.Actor = nil then
        M.Dormant := True;
    { the player on room B's floor, below the balcony: out of melee reach }
    Eye := D3ToCge(Vector3(560, 300, 0)) + Vector3(0, PlayerEyeHeight, 0);
    SawFlying := False;
    for I := 1 to 40 do
    begin
      Game.Update(0.1, Eye);
      RemoveMe := rtNone;
      Map.Update(0.1, RemoveMe);
      if (Game.Projectiles.Count > 0) and (Game.Projectiles[0].Visual <> nil) then
        SawFlying := True;
    end;
    Check(Game.ProjectilesLaunched > 0, 'the range anim''s launch_missile fired a projectile');
    Check(SawFlying, 'a glowing projectile flew (light_color: a visible ball)');
    Check(Game.Health < 100, Format('a projectile hit the player (health %d)', [Game.Health]));
  finally
    FreeAndNil(Game);
    FreeAndNil(World);
  end;
end;

procedure TestSplashDamage;
var
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  M: TD3Monster;
  P: TD3Projectile;
  I: Integer;
  Eye: TVector3;
begin
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Map.SpawnModels := False;
    Check(Map.LoadMap('testmap'), 'load testmap for splash damage');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    for M in Game.Monsters do
      M.Dormant := True;
    Game.NoTarget := True;
    Eye := D3ToCge(Vector3(-160, -160, 0)) + Vector3(0, PlayerEyeHeight, 0);
    { down onto the floor 40 units east of the player: 24 from its box }
    P := Game.SpawnProjectile('projectile_test', 'test', D3ToCge(Vector3(-120, -160, 40)),
      D3ToCge(Vector3(0, 0, -500)));
    Check(P <> nil, 'spawn projectile_test');
    if P = nil then
      Exit;
    CheckEquals(6, P.SplashDamage, 'def_splash_damage damage');
    CheckNear(80, P.SplashRadius, 'def_splash_damage radius');
    Check(not P.DetonateOnFuse, 'detonate_on_fuse is off by default');
    for I := 1 to 5 do
      Game.Update(0.05, Eye);
    CheckEquals(0, Game.Projectiles.Count, 'it exploded on the floor');
    { 6 * (1 - 24 / 80) }
    CheckEquals(96, Game.Health, 'the splash hurt the player by distance');
    { a direct hit: only def_damage (RadiusDamage ignores the one hit) }
    Game.SpawnProjectile('projectile_test', 'test', D3ToCge(Vector3(-60, -160, 40)),
      D3ToCge(Vector3(-500, 0, 0)));
    for I := 1 to 8 do
      Game.Update(0.05, Eye);
    CheckEquals(91, Game.Health, 'a direct hit takes def_damage only');
    { out of the radius: no splash }
    Game.SpawnProjectile('projectile_test', 'test', D3ToCge(Vector3(-40, -160, 40)),
      D3ToCge(Vector3(0, 0, -500)));
    for I := 1 to 5 do
      Game.Update(0.05, Eye);
    CheckEquals(91, Game.Health, 'no splash 104 units away');
  finally
    FreeAndNil(Game);
    FreeAndNil(World);
  end;
end;

procedure TestMovers;
var
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  Door1, Door2, M: TD3Mover;
  DoorLight: TD3BrushEntity;
  LightStart: TVector3;
  I: Integer;
  Lock: TD3MapEntity;
  Far: TVector3;
begin
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Map.SpawnModels := False;
    Check(Map.LoadMap('testmap'), 'load testmap for movers');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    Door1 := nil;
    Door2 := nil;
    for M in Game.Movers do
      if M.Brush.Entity.Name = 'door_1' then
        Door1 := M
      else
      if M.Brush.Entity.Name = 'door_2' then
        Door2 := M;
    Check((Door1 <> nil) and (Door2 <> nil), 'door_1 and door_2 are movers');
    DoorLight := Map.FindBrush('door_light_1');
    Check(DoorLight <> nil, 'door_light_1 exists');
    if (Door1 = nil) or (Door2 = nil) or (DoorLight = nil) then
      Exit;

    { travel: the world box along the move direction minus lip; door_2 is
      rotated 90 degrees, so its 48 units long local y moves along x }
    CheckNear(112 - 8, Door1.Distance, 'door_1 distance (height - lip)');
    CheckNear(48 - 8, Door2.Distance, 'door_2 distance from its rotated box');
    CheckEquals('tunnel', Door2.Team, 'door_2 team');
    { the entityDef's keys are merged into the entity (none in the test def:
      func_door spawn defaults come from the code then) }
    CheckNear(3, Door2.Wait, 'door_2 default wait');

    { activating door_1 opens its team }
    Far := D3ToCge(Vector3(-200, -200, 0)) + Vector3(0, PlayerEyeHeight, 0);
    LightStart := DoorLight.Scene.Translation;
    Game.Activate(Door1.Brush.Entity);
    Check(Door2.State in [dsOpening, dsOpen], 'activating door_1 opens door_2 (team)');
    for I := 1 to 10 do
      Game.Update(0.1, Far);
    Check(Door1.State = dsOpen, 'door_1 open after 1 s');
    { the bound panel rides up with door_1 }
    CheckNear(LightStart.Y + Door1.Distance, DoorLight.Scene.Translation.Y,
      'door_light_1 follows door_1 (bind)');
    CheckNear(LightStart.X, DoorLight.Scene.Translation.X, 'door_light_1 stays above its spot');

    { both close after wait; then target_lock-like locking keeps them shut }
    for I := 1 to 50 do
      Game.Update(0.1, Far);
    Check((Door1.State = dsClosed) and (Door2.State = dsClosed), 'the team closes after wait');
    CheckNear(LightStart.Y, DoorLight.Scene.Translation.Y, 'door_light_1 back down');

    { a target_lock (made here: the test map has none) locks the whole team }
    Lock := TD3MapEntity.Create;
    try
      Lock.SetValue('classname', 'target_lock');
      Lock.SetValue('target', 'door_2');
      Lock.SetValue('locked', '1');
      Game.Activate(Lock);
      Check(Door1.Locked and Door2.Locked, 'target_lock locks the team');
      Game.Update(0.1, D3ToCge(Vector3(200, 0, 0)) + Vector3(0, PlayerEyeHeight, 0));
      Check(Door1.State = dsClosed, 'a locked door stays shut when the player comes near');
      Lock.SetValue('locked', '0');
      Game.Activate(Lock);
      Check(not Door1.Locked and not Door2.Locked, 'target_lock with locked 0 unlocks');
      Game.Update(0.1, D3ToCge(Vector3(200, 0, 0)) + Vector3(0, PlayerEyeHeight, 0));
      Check(Door1.State = dsOpening, 'unlocked: the player opens it');
    finally
      Lock.Free;
    end;

    { func_rotating: activation stops and starts it }
    for M in Game.Movers do
      if M.Kind = mkRotating then
      begin
        Check(M.Running, 'spinner_1 starts on');
        Game.Activate(M.Brush.Entity);
        Check(not M.Running, 'activating spinner_1 stops it');
      end;
  finally
    FreeAndNil(Game);
    FreeAndNil(World);
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
  TestJointMods;
  TestTrianglesClosed;
  TestStaticModels;
  TestEntityRotation;
  TestCollisionModel;
  TestPortals;
  TestExpressions;
  TestLightVolumes;
  TestMaterialStages;
  TestGuis;
  TestShadowCasters;
  TestTriggers;
  TestMovers;
  TestScriptVM;
  TestMapScripts;
  TestCinematics;
  TestActors;
  TestScriptedMonster;
  TestProjectiles;
  TestSplashDamage;
  TestAas;
  TestAasChase;
  Writeln(Format('%d passed, %d failed', [Passed, Failed]));
  if Failed > 0 then
    Halt(1);
end.
