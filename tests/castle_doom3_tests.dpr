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
  Doom3Materials, X3DNodes, X3DFields, Doom3World, CastleScene, Doom3Script, Doom3Camera, Doom3Efx, Doom3AF, Doom3Ragdoll, Doom3EnvProbes,
  Doom3Particles, Doom3Decals, Doom3Pda,
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
  CheckEquals(116, D3Fs.FileCount, 'PK4 file count');
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
  CheckEquals(49, Decls.DeclCount(dtMaterial), 'material count');
  CheckEquals(64, Decls.DeclCount(dtEntityDef), 'entityDef count');
  CheckEquals(8, Decls.DeclCount(dtModel), 'model decl count');
  CheckEquals(3, Decls.DeclCount(dtSkin), 'skin count');
  Check(Decls.Skin('skins/test/player_berserk') <> nil, 'the player''s berserk skin');
  CheckEquals('models/test/player_berserk', Decls.Skin('skins/test/player_berserk').Remap('models/test/player'),
    'the berserk skin remaps the body');
  CheckEquals(12, Decls.DeclCount(dtSound), 'sound shader count');
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
    CheckEquals(7, Model.Anims.Count, 'model anim count');
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
    CheckEquals(14, Proc.ModelCount, 'proc model count');
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
    CheckEquals(88, MapFile.Entities.Count, 'entity count');
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
  CheckEquals(2, Model.Meshes.Count, 'md5 meshes (the body and the eye)');
  CheckEquals(144, Length(Model.Meshes[0].Verts), 'md5 verts');
  if Model.Meshes.Count > 1 then
  begin
    CheckEquals('models/test/blob_eye', Model.Meshes[1].Shader, 'the eye mesh''s shader');
    CheckEquals(4 * 3, Length(Model.Meshes[1].Tris), 'the eye: its quad, the origin and focus triangles');
  end;
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
    CheckEquals(16, Cm.ModelCount, 'cm models (world + 12 brush entities + 3 triggers)');
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

{ Lights of one kind share an Effect with per-light matrices when CGE
  supports custom fields on lights; otherwise an effect each. }
procedure TestSharedLightEffects;
var
  Shared: TD3SharedLightEffects;
  A, B, C: TPointLightNode;
  M: TMatrix4;
  Field: TX3DField;
begin
  FillChar(Shared, SizeOf(Shared), 0);
  M := PointLightMatrix(Vector3(10, 20, 30), TMatrix3.Identity, Vector3(100, 200, 50));
  A := TPointLightNode.Create;
  B := TPointLightNode.Create;
  C := TPointLightNode.Create;
  try
    SetLightVolume(A, Shared, 0, M, '', False);
    SetLightVolume(B, Shared, 1, M, '', False);
    SetLightVolume(C, Shared, 2, M, '', True);
    CheckEquals(1, A.FdEffects.Count, 'light A has one effect');
    CheckEquals(1, C.FdEffects.Count, 'light C has one effect');
    Check(A.FdEffects[0] <> C.FdEffects[0], 'projected and point lights have different effects');
    if SharedLightEffectsAvailable then
    begin
      Check(A.FdEffects[0] = B.FdEffects[0], 'point lights share their effect');
      Field := A.Field('d3_light_matrix_');
      Check(Field is TSFMatrix4f, 'light A has the d3_light_matrix_ field');
      if Field is TSFMatrix4f then
        Check(TMatrix4.PerfectlyEquals(M, TSFMatrix4f(Field).Value), 'light A field holds its matrix');
      Check(Pos('d3_light_matrix_<Light>',
        (TEffectNode(A.FdEffects[0]).FdParts[0] as TEffectPartNode).Contents) > 0,
        'shared code uses the <Light> uniform');
    end else
      Check(A.FdEffects[0] <> B.FdEffects[0], 'without CGE support, an effect each');

    { r_sharedLightEffects 0 }
    SharedLightEffects := False;
    try
      SetLightVolume(B, Shared, 1, M, '', False);
      Check(A.FdEffects[0] <> B.FdEffects[0], 'r_sharedLightEffects 0: an effect each');
    finally
      SharedLightEffects := True;
    end;
  finally
    FreeAndNil(A);
    FreeAndNil(B);
    FreeAndNil(C);
  end;
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
    CheckEquals(8, Gui.WindowCount, 'panel windows (definevec4 and events are not windows)');
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
      C := PixelAt(Img, 100, 420);
      Check(C.X < 0.5, Format('the hidden red window is not drawn, got %s', [C.ToString]));
      C := PixelAt(Img, 31, 300);
      Check(C.Z > 0.4, 'body border drawn');
    finally
      Img.Free;
    end;
    { an empty state: the header has no text }
    State.Clear;
    Img := RenderGui(Gui, State);
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

{ Several lights casting shadow volumes (r_shadowLights, CGE change A):
  the strongest lights at the player, flags on exactly them. }
procedure TestShadowLights;
var
  World: TCastleRootTransform;
  Map: TDoom3Map;
  P: TVector3;
  I, J, Casting: Integer;
  InList: Boolean;
begin
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  try
    Map.SpawnModels := False;
    Check(Map.LoadMap('testmap'), 'load testmap for shadow lights');
    P := D3ToCge(Vector3(-160, -160, 40));
    CheckEquals(1, Map.ShadowLightsMax, 'one shadow light by default');
    Map.UpdateShadowLight(P);
    CheckEquals(1, Length(Map.ShadowLights), 'one shadow light');
    Check(Map.ShadowLight >= 0, 'a shadow light at the start');
    if Map.ShadowLight >= 0 then
      CheckEquals('light_1', Map.Light(Map.ShadowLight).Entity.Name, 'room A''s main light casts');

    Map.ShadowLightsMax := 3;
    Map.UpdateShadowLight(P);
    CheckEquals(3, Length(Map.ShadowLights), 'three shadow lights');
    if Length(Map.ShadowLights) = 3 then
    begin
      CheckEquals(Map.ShadowLights[0], Map.ShadowLight, 'ShadowLight is the first');
      CheckEquals('light_1', Map.Light(Map.ShadowLights[0]).Entity.Name, 'the strongest at the player first');
      Check((Map.ShadowLights[0] <> Map.ShadowLights[1]) and
        (Map.ShadowLights[1] <> Map.ShadowLights[2]) and
        (Map.ShadowLights[0] <> Map.ShadowLights[2]), 'three different lights');
    end;
    Casting := 0;
    for I := 0 to Map.LightCount - 1 do
    begin
      InList := False;
      for J in Map.ShadowLights do
        if J = I then
          InList := True;
      if Map.Light(I).Node.ShadowVolumesMain then
        Inc(Casting);
      Check(Map.Light(I).Node.ShadowVolumesMain = InList,
        'shadowVolumesMain exactly on the shadow lights: ' + Map.Light(I).Entity.Name);
    end;
    CheckEquals(3, Casting, 'three lights with shadowVolumesMain');

    { back to one }
    Map.ShadowLightsMax := 1;
    Map.UpdateShadowLight(P);
    CheckEquals(1, Length(Map.ShadowLights), 'back to one shadow light');
    Casting := 0;
    for I := 0 to Map.LightCount - 1 do
      if Map.Light(I).Node.ShadowVolumesMain then
        Inc(Casting);
    CheckEquals(1, Casting, 'one light with shadowVolumesMain again');
  finally
    FreeAndNil(World);
  end;
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
      Check(FirstNormal(S).X > 0.9, 'barrel side faces out (clockwise in the file)');
      { the seam quad (the 16th) uses u = 1 from VMAD at its second column }
      CheckNear(1, S.TexCoords[15 * 4 + 1].X, 'VMAD overrides the seam UV');
      CheckNear(0, S.TexCoords[15 * 4].X - 15 / 16, 'VMAP UV of the seam quad first column');
      CheckNear(1, S.TexCoords[0].Y, 'top ring v = 1 (CGE v = LightWave v)');
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

procedure TestEfx;
var
  Efx: TD3EfxFile;
  E: TD3ReverbEffect;
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
begin
  CheckEquals('efxs/demo_mars_city1.efx', EfxPathForMap('game/demo_mars_city1'), 'efx path of a map in a directory');
  CheckEquals('efxs/testmap.efx', EfxPathForMap('testmap'), 'efx path');
  CheckNear(0.1, MillibelsToGain(-2000, 0, 1), 'millibels to gain', 1e-5);
  CheckNear(1, MillibelsToGain(500, 0, 1), 'millibels to gain clamped', 1e-5);

  Efx := TD3EfxFile.Create;
  try
    Check(Efx.LoadFromVfs('efxs/testmap.efx'), 'load efxs/testmap.efx');
    CheckEquals(3, Efx.Effects.Count, 'efx effects');
    CheckEquals(0, Efx.UnknownKeys, 'efx: no unknown keys');
    E := Efx.Find('default');
    Check(E <> nil, 'efx: default');
    if E <> nil then
    begin
      Check(E.Reverb.Enabled, 'efx effect enabled');
      CheckNear(1, E.Reverb.Density, 'efx: size 7.5 -> density 1 (clamped)');
      CheckNear(0.3162, E.Reverb.Gain, 'efx: room -1000 mB', 1e-4);
      CheckNear(0.8913, E.Reverb.GainHF, 'efx: room hf -100 mB', 1e-4);
      CheckNear(0.05, E.Reverb.ReflectionsGain, 'efx: reflections -2602 mB', 1e-4);
      CheckNear(1.2589, E.Reverb.LateReverbGain, 'efx: reverb 200 mB', 1e-4);
      CheckNear(0.9943, E.Reverb.AirAbsorptionGainHF, 'efx: air absorption hf -5 mB', 1e-4);
      CheckNear(1.49, E.Reverb.DecayTime, 'efx: decay time');
      CheckNear(5000, E.Reverb.HFReference, 'efx: hf reference');
      Check(E.Reverb.DecayHFLimit, 'efx: flags 0x3f -> decay hf limit');
    end;
    E := Efx.Find('ROOM_A');
    Check(E <> nil, 'efx: find is case-insensitive');
    if E <> nil then
    begin
      CheckNear(1.9 * 1.9 * 1.9 / 16, E.Reverb.Density, 'efx: size 1.9 -> density size^3/16');
      Check(not E.Reverb.DecayHFLimit, 'efx: flags 0x1f -> no decay hf limit');
    end;
    E := Efx.Find('1');
    if E <> nil then
    begin
      CheckNear(10.05, E.Reverb.DecayTime, 'efx "1": decay time');
      CheckNear(0.5, E.Reverb.Diffusion, 'efx "1": diffusion');
      CheckVec3(Vector3(0, 0, -1), E.Reverb.ReflectionsPan, 'efx "1": reflections pan');
      CheckVec3(Vector3(0, 1, 0), E.Reverb.LateReverbPan, 'efx "1": reverb pan');
    end;
    { dhewm3's order: the area number, then the location, then "default" }
    CheckEquals('1', Efx.Select(1, 'room_b').Name, 'efx select: by area number first');
    CheckEquals('room_a', Efx.Select(0, 'room_a').Name, 'efx select: by location');
    CheckEquals('default', Efx.Select(0, 'nowhere').Name, 'efx select: default');
    CheckEquals('default', Efx.Select(-1, '').Name, 'efx select: outside the areas');

    { keys without quotes, and other versions }
    Check(Efx.LoadFromText('Version 1 reverb "x" {' + LineEnding +
      'room hf -2000' + LineEnding + 'decay time 2.5' + LineEnding + '}'), 'efx: unquoted keys');
    CheckEquals(1, Efx.Effects.Count, 'efx: one effect');
    if Efx.Effects.Count = 1 then
    begin
      CheckNear(0.1, Efx.Effects[0].Reverb.GainHF, 'efx: unquoted "room hf"', 1e-4);
      CheckNear(2.5, Efx.Effects[0].Reverb.DecayTime, 'efx: unquoted "decay time"');
    end;
    Check(Efx.Select(0, '') = nil, 'efx select: nothing without a default');
    Check(not Efx.LoadFromText('Version 2 reverb "x" { }'), 'efx: unknown version');
    CheckEquals(0, Efx.Effects.Count, 'efx: no effects from an unknown version');
  finally
    Efx.Free;
  end;

  { locations spread through the doorway's portal only while the door is
    open; it is closed when the map spawns }
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Map.SpawnModels := False;
    Check(Map.LoadMap('testmap'), 'load testmap for locations');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    CheckEquals('room_a', Game.LocationOfArea(0), 'room A location (lowercase)');
    CheckEquals('room_b', Game.LocationOfArea(1), 'room B location (the closed door blocks room A''s)');
    CheckEquals('room_a', Game.LocationAt(D3ToCge(Vector3(-160, -160, 40))), 'location at the player start');
    CheckEquals('', Game.LocationOfArea(-1), 'no location outside');
  finally
    FreeAndNil(Game);
    FreeAndNil(World);
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
    CheckEquals(3, Game.Triggers.Count, 'three trigger volumes (trigger_once_1, trigger_once_cin, trigger_hurt_1)');
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
    CheckEquals(44, Game.Script.FunctionCount, 'script functions');
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
    CheckEquals(3, Game.Script.ThreadCount, 'the lift loop, main (waiting to move bar_1 along its curve) and the weapon''s thread run');
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
    CheckEquals(7, Game.Actors.Count, 'seven actors (blob_scripted_1, test_walker_1, blob_ranged_1, blob_flyer_1, blob_dodger_1, blob_thrower_1, test_stepper_1)');
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

procedure TestRangedAttacks;
var
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  A, Ranged: TD3Actor;
  P: TD3Projectile;
  M: TD3Monster;
  I, Launched, Health: Integer;
  Eye, ToPlayer, Dir: TVector3;
  DotBefore: Single;
  SawHeld, SawGuided, Bounced: Boolean;
  RemoveMe: TRemoveType;
  YawToPlayer, Delta: Single;

  procedure Step(const Seconds: Single);
  begin
    Game.Update(Seconds, Eye);
    RemoveMe := rtNone;
    Map.Update(Seconds, RemoveMe);
  end;

begin
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Check(Map.LoadMap('testmap'), 'load testmap for ranged attacks');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    Ranged := nil;
    for A in Game.Actors do
      if A.Model.Entity.Name = 'blob_ranged_1' then
        Ranged := A
      else
        A.Thinking := False;
    Check(Ranged <> nil, 'blob_ranged_1 runs its script (monster_test_ranged derives from monster_test)');
    if Ranged = nil then
      Exit;
    for M in Game.Monsters do
      if M.Actor = nil then
        M.Dormant := True;
    { the player in room B, in sight of it, out of melee reach }
    Eye := D3ToCge(Vector3(420, -250, 0)) + Vector3(0, PlayerEyeHeight, 0);
    for I := 1 to 10 do
      Step(0.1);
    CheckEquals(0, Game.ProjectilesLaunched, 'blob_ranged_1 waits until activated');

    { activated: the throw anim's create_missile holds a ball in its hand,
      launch_missile throws it; 2 s later attackMissile throws another }
    Game.Activate(Game.FindEntity('blob_ranged_1'));
    SawHeld := False;
    SawGuided := False;
    for I := 1 to 50 do
    begin
      Step(0.1);
      for P in Game.Projectiles do
      begin
        if P.HeldBy = Ranged then
          SawHeld := True;
        if P.Guided and (P.HeldBy = nil) then
          SawGuided := True;
      end;
    end;
    Check(SawHeld, 'create_missile: a ball held in its hand before the throw');
    Check(SawGuided, 'a homing ball (idGuidedProjectile) flew');
    Check(Game.ProjectilesLaunched >= 2, Format('the anim and attackMissile both threw (%d)', [Game.ProjectilesLaunched]));
    Check(Game.Health < 100, Format('a homing ball hit the player (health %d)', [Game.Health]));
    Ranged.Thinking := False;
    for I := 1 to 30 do
      Step(0.1);

    { a homing ball launched away from the player turns towards it }
    Health := Game.Health;
    P := Game.SpawnProjectile('projectile_test_guided', 'test', D3ToCge(Vector3(420, -100, 60)),
      D3ToCge(Vector3(0, 300, 0)));
    Check((P <> nil) and P.Guided, 'projectile_test_guided is guided');
    if P <> nil then
    begin
      P.SeeksPlayer := True;
      DotBefore := TVector3.DotProduct(P.Velocity.Normalize, (Eye - P.Position).Normalize);
      Step(0.05);
      Step(0.05);
      Step(0.05);
      if Game.Projectiles.IndexOf(P) >= 0 then
      begin
        ToPlayer := (Eye - Vector3(0, 12, 0) - P.Position).Normalize;
        Dir := P.Velocity.Normalize;
        Check(TVector3.DotProduct(Dir, ToPlayer) > DotBefore + 0.1, 'the homing ball turns towards the player');
        { turn_max 240 degrees a second: 36 degrees in 0.15 s }
        CheckNear(36, RadToDeg(ArcCos(EnsureRange(TVector3.DotProduct(Dir, D3ToCge(Vector3(0, 1, 0))), -1, 1))),
          'the homing ball turned by turn_max', 1);
        CheckNear(300, P.Velocity.Length, 'the homing ball keeps its speed', 0.5);
      end;
      for I := 1 to 40 do
        Step(0.05);
      Check(Game.Health < Health, 'the homing ball came back and hit the player');
    end;

    { a grenade (detonate_on_world 0) bounces off the floor and explodes
      when its fuse ends, with its splash }
    Health := Game.Health;
    P := Game.SpawnProjectile('projectile_test_grenade', 'test', D3ToCge(Vector3(440, -250, 30)),
      D3ToCge(Vector3(0, 0, -200)));
    Check((P <> nil) and not P.DetonateOnWorld and (P.Bounce = 0.5), 'projectile_test_grenade bounces');
    Bounced := False;
    if P <> nil then
      for I := 1 to 10 do
      begin
        Step(0.05);
        if (Game.Projectiles.IndexOf(P) >= 0) and (P.Velocity.Y > 0) then
          Bounced := True;
      end;
    Check(Bounced, 'the grenade bounced up off the floor');
    Check((P <> nil) and (Game.Projectiles.IndexOf(P) >= 0), 'the grenade is still there after bouncing');
    for I := 1 to 25 do
      Step(0.05);
    CheckEquals(0, Game.Projectiles.Count, 'the grenade exploded when its fuse ended');
    Check(Game.Health < Health, Format('the grenade''s splash hurt the player (%d -> %d)', [Health, Game.Health]));

    { launch_missile keeps the yaw within attack_cone (70) of its facing:
      the player behind it }
    Ranged.Yaw := 90;
    Ranged.HasEnemy := True;
    P := Game.LaunchMissile(Ranged, 'body', True, False, TVector3.Zero, True);
    Check(P <> nil, 'LaunchMissile');
    if P <> nil then
    begin
      Dir := CgeToD3(P.Velocity);
      YawToPlayer := RadToDeg(ArcTan2(Dir.Y, Dir.X));
      Delta := YawToPlayer - 90;
      Delta := Delta - 360 * Floor((Delta + 180) / 360);
      Check(Abs(Delta) <= 70.5, Format('a missile at the player behind it stays in the attack cone (%.1f)', [Delta]));
    end;
    { createMissile then launchMissile (script events): the held one goes }
    Launched := Game.ProjectilesLaunched;
    P := Game.CreateMissile(Ranged, 'body');
    Check((P <> nil) and (P.HeldBy = Ranged) and (Ranged.Missile = P), 'createMissile holds a missile');
    Check(Game.LaunchMissileFrom(Ranged, CgeToD3(Ranged.Model.Holder.Translation) + Vector3(0, 0, 40),
      Vector3(0, 90, 0)) = P, 'launchMissile throws the held missile');
    Check((P <> nil) and (P.HeldBy = nil) and (Ranged.Missile = nil), 'launched, it is no longer held');
    if P <> nil then
      CheckVec3(Vector3(0, 300, 0), CgeToD3(P.Velocity), 'launchMissile along the angles (yaw 90 = +y)');
    CheckEquals(Launched + 1, Game.ProjectilesLaunched, 'one missile launched');

    { a multiframe attack (attack_begin, chargeAttack) hurts the player it
      touches once (idAI::DirectDamage ends it) }
    Ranged.Thinking := True;
    Ranged.Attack := 'damage_test_charge';
    Eye := Ranged.Model.Holder.Translation + D3ToCge(Vector3(40, 0, 0)) + Vector3(0, PlayerEyeHeight, 0);
    Health := Game.Health;
    Step(0.05);
    CheckEquals(Health - 9, Game.Health, 'the charge hit the player it touched (damage_test_charge)');
    CheckEquals('', Ranged.Attack, 'the hit ended the attack');
    Step(0.05);
    CheckEquals(Health - 9, Game.Health, 'one hit per attack');
  finally
    FreeAndNil(Game);
    FreeAndNil(World);
  end;
end;

procedure TestFlying;
var
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  A, Flyer: TD3Actor;
  M: TD3Monster;
  I, Health: Integer;
  Eye, Start, Pos: TVector3;
  SawCharge, Leaned: Boolean;
  RemoveMe: TRemoveType;
  MaxSpeed: Single;

  procedure Step(const Seconds: Single);
  begin
    Game.Update(Seconds, Eye);
    RemoveMe := rtNone;
    Map.Update(Seconds, RemoveMe);
  end;

begin
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Check(Map.LoadMap('testmap'), 'load testmap for flying');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    Flyer := nil;
    for A in Game.Actors do
      if A.Model.Entity.Name = 'blob_flyer_1' then
        Flyer := A
      else
        A.Thinking := False;
    for M in Game.Monsters do
      if M.Actor = nil then
        M.Dormant := True;
    Check(Flyer <> nil, 'blob_flyer_1 runs its script');
    if Flyer = nil then
      Exit;
    Eye := D3ToCge(Vector3(420, -250, 0)) + Vector3(0, PlayerEyeHeight, 0);
    Start := CgeToD3(Flyer.Model.Holder.Translation);
    for I := 1 to 5 do
      Step(0.1);
    CheckEquals(MoveTypeFly, Flyer.MoveType, 'init: setMoveType( MOVETYPE_FLY )');
    Pos := CgeToD3(Flyer.Model.Holder.Translation);
    Check((Pos - Start).Length < 20, Format('it hovers (bobbing) where it is until activated (%.1f away)',
      [(Pos - Start).Length]));

    { activated: it rises to the player's eyes plus fly_offset (68 + 10)
      and flies at it, leaning into its turns }
    Game.Activate(Game.FindEntity('blob_flyer_1'));
    MaxSpeed := 0;
    Leaned := False;
    for I := 1 to 15 do
    begin
      Step(0.1);
      MaxSpeed := Max(MaxSpeed, Flyer.Velocity.Length);
      if (Abs(Flyer.FlyRoll) > 0.5) or (Abs(Flyer.FlyPitch) > 0.5) then
        Leaned := True;
    end;
    Pos := CgeToD3(Flyer.Model.Holder.Translation);
    Check(Pos.Z > Start.Z + 40, Format('it flew up (z %.1f)', [Pos.Z]));
    Check(Sqrt(Sqr(Pos.X - 420) + Sqr(Pos.Y + 250)) < Sqrt(Sqr(Start.X - 420) + Sqr(Start.Y + 250)) - 50,
      'it flew towards the player');
    Check(MaxSpeed <= 150.5, Format('no faster than fly_speed (%.1f)', [MaxSpeed]));
    Check(Leaned, 'it leans (fly_pitch / fly_roll)');

    { near the player it charges: straight on, hurting once }
    Health := Game.Health;
    SawCharge := False;
    for I := 1 to 60 do
    begin
      Step(0.05);
      if Flyer.MoveDirect then
        SawCharge := True;
    end;
    Check(SawCharge, 'chargeAttack flies straight on (MoveDirect)');
    Check(Game.Health < Health, Format('the charge hurt the player (%d -> %d)', [Health, Game.Health]));
    Check((Health - Game.Health) mod 9 = 0, 'by damage_test_charge (9 per charge)');

    { hovering with an enemy (no move): it keeps to the player's eyes plus
      fly_offset (idAI::AdjustFlyHeight) }
    Flyer.MoveDirect := False;
    for I := 1 to 120 do
    begin
      Flyer.Moving := False;
      Flyer.Main.State := tsDone;
      Step(0.05);
    end;
    Pos := CgeToD3(Flyer.Model.Holder.Translation);
    CheckNear(PlayerEyeHeight + 10, Pos.Z, 'hovering at the player''s eyes plus fly_offset', 12);

    { killed in the air, it falls to the floor (without its ragdoll: the
      ragdoll is TestMonsterRagdoll's) }
    Game.RagdollEnabled := False;
    Game.KillActor(Flyer);
    for I := 1 to 20 do
      Step(0.05);
    CheckEquals(MoveTypeDead, Flyer.MoveType, 'dead: MOVETYPE_DEAD');
    Check(not Flyer.Monster.Falling, 'it landed');
    CheckNear(0, CgeToD3(Flyer.Model.Holder.Translation).Z, 'on room B''s floor', 1);
  finally
    FreeAndNil(Game);
    FreeAndNil(World);
  end;
end;

procedure TestDodgesAndCombatNodes;
var
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  A, Dodger: TD3Actor;
  M: TD3Monster;
  Node: TD3CombatNode;
  I: Integer;
  Eye, Feet, Pos, NodePos, Before: TVector3;
  Reached, Dodged, Walked: Boolean;
  RemoveMe: TRemoveType;
  Moved: Single;

  procedure Step(const Seconds: Single);
  begin
    Game.Update(Seconds, Eye);
    RemoveMe := rtNone;
    Map.Update(Seconds, RemoveMe);
  end;

begin
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Check(Map.LoadMap('testmap'), 'load testmap for dodges');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    Dodger := nil;
    for A in Game.Actors do
      if A.Model.Entity.Name = 'blob_dodger_1' then
        Dodger := A
      else
        A.Thinking := False;
    for M in Game.Monsters do
      if M.Actor = nil then
        M.Dormant := True;
    Check(Dodger <> nil, 'blob_dodger_1 runs its script');
    CheckEquals(1, Game.CombatNodes.Count, 'one combat node (ai_attackcone, spawnclass idCombatNode)');
    if (Dodger = nil) or (Game.CombatNodes.Count <> 1) then
      Exit;
    Node := Game.CombatNodes[0];
    Feet := Vector3(420, -250, 0);
    Eye := D3ToCge(Feet) + Vector3(0, PlayerEyeHeight, 0);
    { the cone: facing west (angle 180), up to 600 along it, 150 degrees }
    Check(Node.PlayerInView(Feet), 'the player in room B is in the node''s cone');
    Check(not Node.PlayerInView(Vector3(900, 100, 0)), 'behind the node: not in its cone');
    Check(not Node.PlayerInView(Vector3(650, -250, 0)), 'beside the node (behind its facing): not in its cone');
    Check(not Node.PlayerInView(Vector3(420, -250, 400)), 'above its height: not in its cone');
    CheckVec3(Vector3(0, 64, 0), Dodger.Model.Instance.AnimMovementDelta('evade_left'),
      'evade_left moves 64 to the left (model space)');

    { activated: it goes to the node (closer than the player, the player
      in its cone), marks it used (use_once: off), then dodges }
    NodePos := Node.Entity.Origin;
    Game.Activate(Game.FindEntity('blob_dodger_1'));
    Reached := False;
    for I := 1 to 120 do
    begin
      Step(0.1);
      if Node.Disabled then
      begin
        Reached := True;
        Break;
      end;
    end;
    Check(Reached, 'it reached its combat node and marked it used (use_once)');
    Pos := CgeToD3(Dodger.Model.Holder.Translation);
    Check(Sqrt(Sqr(Pos.X - NodePos.X) + Sqr(Pos.Y - NodePos.Y)) < 40,
      Format('at the combat node (%.0f %.0f)', [Pos.X, Pos.Y]));
    Before := Pos;
    Dodged := False;
    Walked := False;
    Moved := 0;
    for I := 1 to 30 do
    begin
      Step(0.1);
      if Dodger.Moving then
        Walked := True;
      Pos := CgeToD3(Dodger.Model.Holder.Translation);
      Moved := Max(Moved, (Pos - Before).Length);
      if Dodger.Channels[1].AnimName = 'evade_left' then
        Dodged := True;
    end;
    Check(Dodged, 'it played evade_left (testAnimMove found room)');
    Check(not Walked, 'a dodge is the anim''s move, not a walk');
    Check((Moved > 40) and (Moved < 140), Format('the evade anim moved it sideways (%.1f)', [Moved]));
    CheckNear(0, Pos.Z - Before.Z, 'on the floor', 1);

    { no room: a wall to its left }
    Dodger.Thinking := False;
    Dodger.Model.Holder.Translation := D3ToCge(Vector3(560, 320, 0));
    Check(not Game.AnimMoveClear(Dodger, 'evade_left', 0), 'testAnimMove: the north wall is to its left');
    Check(Game.AnimMoveClear(Dodger, 'evade_left', 180), 'testAnimMove: room to its left facing west');
    Check(not Game.AnimMoveClear(Dodger, 'no_such_anim', 0), 'testAnimMove: no such anim');
  finally
    FreeAndNil(Game);
    FreeAndNil(World);
  end;
end;

procedure TestFlyingRouteAndThrows;
var
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  A, Flyer, Thrower: TD3Actor;
  M: TD3Monster;
  Mov: TD3Moveable;
  I, Health: Integer;
  Eye, Pos, Waypoint, Start: TVector3;
  Route: TD3Route;
  RemoveMe: TRemoveType;
  InRoomA, Bounced: Boolean;
  MaxZ: Single;

  procedure Step(const Seconds: Single);
  begin
    Game.Update(Seconds, Eye);
    RemoveMe := rtNone;
    Map.Update(Seconds, RemoveMe);
  end;

begin
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Check(Map.LoadMap('testmap'), 'load testmap for flying routes and throws');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    Flyer := nil;
    Thrower := nil;
    for A in Game.Actors do
      if A.Model.Entity.Name = 'blob_flyer_1' then
        Flyer := A
      else
      if A.Model.Entity.Name = 'blob_thrower_1' then
        Thrower := A
      else
        A.Thinking := False;
    for M in Game.Monsters do
      if M.Actor = nil then
        M.Dormant := True;
    Check((Flyer <> nil) and (Thrower <> nil), 'blob_flyer_1 and blob_thrower_1 run their scripts');
    if (Flyer = nil) or (Thrower = nil) then
      Exit;

    { the flying route (idAASLocal::FlyPathToGoal): from room B to room A,
      the wall between them is in the way: first the doorway }
    Check(not Game.FlyPathClear(Vector3(620, -100, 60), Vector3(-100, -200, 0), 16, 72),
      'no straight flight through the wall between the rooms');
    Route := Default(TD3Route);
    Waypoint := Game.FlyRouteWaypoint(Route, Vector3(620, -100, 60), Vector3(-100, -200, 0), 16, 72);
    Check(Route.Found and Route.Fly, 'a flying AAS route from room B to room A');
    Check((Waypoint.X > 150) and (Waypoint.X < 320) and (Abs(Waypoint.Y) < 60),
      Format('it heads for the doorway first (%s)', [Waypoint.ToString]));
    Waypoint := Game.FlyRouteWaypoint(Route, Vector3(620, -100, 60), Vector3(420, -250, 0), 16, 72);
    CheckVec3(Vector3(420, -250, 0), Waypoint, 'in the same area: straight to the goal');

    { the flyer follows it into room A (the door opens for it) }
    Eye := D3ToCge(Vector3(-100, -200, 0)) + Vector3(0, PlayerEyeHeight, 0);
    Game.Activate(Game.FindEntity('blob_flyer_1'));
    InRoomA := False;
    for I := 1 to 300 do
    begin
      Step(0.1);
      if CgeToD3(Flyer.Model.Holder.Translation).X < 240 then
      begin
        InRoomA := True;
        Break;
      end;
    end;
    Pos := CgeToD3(Flyer.Model.Holder.Translation);
    Check(InRoomA, Format('the flyer came around the wall into room A (%s)', [Pos.ToString]));
    Flyer.Thinking := False;
    Flyer.Model.Holder.Exists := False;

    { a moveable lies still until something moves it, then falls, bounces
      and rests on the floor }
    CheckEquals(1, Game.Moveables.Count, 'one moveable (moveable_test_barrel, spawnclass idMoveable)');
    if Game.Moveables.Count <> 1 then
      Exit;
    Mov := Game.Moveables[0];
    Start := Mov.Origin;
    Eye := D3ToCge(Vector3(420, -250, 0)) + Vector3(0, PlayerEyeHeight, 0);
    for I := 1 to 5 do
      Step(0.1);
    Check(Mov.AtRest and TVector3.Equals(Start, Mov.Origin, 0.01), 'the barrel lies still');
    Mov.Velocity := Vector3(0, 0, 400);
    Mov.AtRest := False;
    MaxZ := 0;
    Bounced := False;
    for I := 1 to 60 do
    begin
      Step(0.05);
      MaxZ := Max(MaxZ, Mov.Origin.Z);
      if (I > 10) and (Mov.Velocity.Z > 0) then
        Bounced := True;
    end;
    Check(MaxZ > 50, Format('pushed up, it rose (%.1f)', [MaxZ]));
    Check(Bounced, 'it bounced on the floor');
    Check(Mov.AtRest, 'it came to rest');
    CheckNear(Start.Z, Mov.Origin.Z, 'on the floor again', 2);

    { thrown hard with long frames (8 FPS) into room B's pillar: it bounces
      and rests on the floor, not in it }
    Eye := D3ToCge(Vector3(-100, -200, 0)) + Vector3(0, PlayerEyeHeight, 0);
    Game.ThrowMoveable(Mov, Vector3(0, -700, 200));
    for I := 1 to 40 do
      Step(0.12);
    Check(Mov.AtRest, 'the hard-thrown barrel came to rest');
    CheckNear(Start.Z, Mov.Origin.Z, 'on the floor, not in it', 2);
    Check(Mov.Origin.Y > -232 + 18 - 1, Format('stopped by the pillar (y %.1f)', [Mov.Origin.Y]));
    Mov.Brush.Scene.Translation := D3ToCge(Start);
    Mov.CanDamage := False;
    Mov.DamageUntil := 0;
    Eye := D3ToCge(Vector3(420, -250, 0)) + Vector3(0, PlayerEyeHeight, 0);

    { the vagary's throw: blob_thrower_1 picks the barrel and throws it at
      the player, its damage on while it flies }
    Health := Game.Health;
    Game.Activate(Game.FindEntity('blob_thrower_1'));
    for I := 1 to 40 do
      Step(0.05);
    Check(not TVector3.Equals(Start, Mov.Origin, 1), 'the barrel was thrown');
    Check(Game.Health < Health, Format('the thrown barrel hit the player (%d -> %d)', [Health, Game.Health]));
    Check(Health - Game.Health <= 12, 'by at most damage_test_moveable (12)');
  finally
    FreeAndNil(Game);
    FreeAndNil(World);
  end;
end;

procedure TestCharacterAnimMove;
var
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  A, Stepper: TD3Actor;
  M: TD3Monster;
  I: Integer;
  Eye, Start, Pos: TVector3;
  Walked: Boolean;
  RemoveMe: TRemoveType;

  procedure Step(const Seconds: Single);
  begin
    Game.Update(Seconds, Eye);
    RemoveMe := rtNone;
    Map.Update(Seconds, RemoveMe);
  end;

begin
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Check(Map.LoadMap('testmap'), 'load testmap for a character moving by its anim');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    Stepper := nil;
    for A in Game.Actors do
      if A.Model.Entity.Name = 'test_stepper_1' then
        Stepper := A
      else
        A.Thinking := False;
    for M in Game.Monsters do
      M.Dormant := True;
    Check((Stepper <> nil) and (Stepper.Monster = nil), 'test_stepper_1 is a character (no monster)');
    if Stepper = nil then
      Exit;
    CheckNear(16, Game.ActorRadius(Stepper), 'a character''s radius: half its size (32)');
    CheckNear(72, Game.ActorHeight(Stepper), 'a character''s height: its size (72)');
    Eye := D3ToCge(Vector3(420, -250, 0)) + Vector3(0, PlayerEyeHeight, 0);
    Start := CgeToD3(Stepper.Model.Holder.Translation);
    for I := 1 to 5 do
      Step(0.1);
    CheckVec3(Start, CgeToD3(Stepper.Model.Holder.Translation), 'it stands still until activated');

    { activated: evade_left's origin moves 64 to its left (facing east:
      +y), and it moves with it, without walking }
    Game.Activate(Game.FindEntity('test_stepper_1'));
    Walked := False;
    for I := 1 to 20 do
    begin
      Step(0.1);
      if Stepper.Moving then
        Walked := True;
    end;
    Pos := CgeToD3(Stepper.Model.Holder.Translation);
    Check(not Walked, 'it didn''t walk: its anim moved it');
    CheckVec3(Start + Vector3(0, 64, 0), Pos, 'its anim moved it 64 to its left');
    CheckEquals('idle', Stepper.Channels[2].AnimName, 'then it idles');
    for I := 1 to 5 do
      Step(0.1);
    CheckVec3(Start + Vector3(0, 64, 0), CgeToD3(Stepper.Model.Holder.Translation), 'and stays there');
  finally
    FreeAndNil(Game);
    FreeAndNil(World);
  end;
end;

procedure TestItems;
var
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  A: TD3Actor;
  M: TD3Monster;
  It: TD3Item;
  Eye: TVector3;
  RemoveMe: TRemoveType;

  procedure StandAt(const X, Y: Single);
  begin
    Eye := D3ToCge(Vector3(X, Y, 0)) + Vector3(0, PlayerEyeHeight, 0);
    Game.Update(0.1, Eye);
    RemoveMe := rtNone;
    Map.Update(0.1, RemoveMe);
  end;

  function ItemNamed(const AName: String): TD3Item;
  begin
    for Result in Game.Items do
      if Result.Entity.Name = AName then
        Exit;
    Result := nil;
  end;

begin
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Check(Map.LoadMap('testmap'), 'load testmap for items');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    for A in Game.Actors do
      A.Thinking := False;
    for M in Game.Monsters do
      M.Dormant := True;

    { the inventory from player_test }
    Check(Game.PlayerDef <> nil, 'the player def (player_test)');
    CheckEquals(100, Game.MaxHealth, 'maxhealth');
    CheckEquals(0, Game.Armor, 'armor of the player def');
    CheckEquals('weapon_test_shotgun', Game.WeaponDefs[2], 'def_weapon2');
    CheckEquals(1, Game.WeaponSlot('weapon_test_pistol'), 'the pistol''s slot');
    CheckEquals(-1, Game.WeaponSlot('weapon_nothing'), 'no slot for unknown weapons');
    Check(Game.HasWeapon(0) and Game.HasWeapon(1) and not Game.HasWeapon(2), 'starts with the "weapon" key''s weapons');
    CheckEquals(24, Game.AmmoCount('ammo_test_bullets'), 'starting ammo');
    CheckEquals(60, Game.MaxAmmo('ammo_test_bullets'), 'max_ammo_test_bullets');
    CheckEquals(-1, Game.Clip[1], 'clips start at -1 (full when first used)');
    CheckEquals(9, Game.Items.Count, 'items spawned');

    { Give, like idPlayer::Give }
    Check(not Game.Give('health', '25'), 'full health takes no health');
    Game.Health := 90;
    Check(Game.Give('health', '25'), 'health given');
    CheckEquals(100, Game.Health, 'up to maxhealth');
    Check(Game.Give('ammo_test_bullets', '100'), 'ammo given');
    CheckEquals(60, Game.AmmoCount('ammo_test_bullets'), 'up to max_ammo');
    Check(not Game.Give('ammo_test_bullets', '10'), 'full ammo takes no more');
    Check(not Game.Give('ammo_none', '10'), 'no ammo without a max_ammo');
    Game.SetAmmo('ammo_test_bullets', 24);

    { touching items }
    StandAt(-40, -210);
    Check(not ItemNamed('item_medkit_1').PickedUp, 'the medkit stays: full health');
    StandAt(0, -150);
    Check(not ItemNamed('item_armor_1').PickedUp, 'not touched from 60 away');
    StandAt(0, -210);
    Check(ItemNamed('item_armor_1').PickedUp, 'armor picked up');
    CheckEquals(25, Game.Armor, 'armor 25');
    Check(ItemNamed('item_armor_1').Brush.Hidden, 'a picked up item is hidden');
    StandAt(40, -210);
    CheckEquals(44, Game.AmmoCount('ammo_test_bullets'), 'a clip: 20 bullets');
    StandAt(-80, -210);
    Check(Game.HasWeapon(2), 'the shotgun picked up');
    CheckEquals(8, Game.AmmoCount('ammo_test_shells'), 'with its shells');
    CheckEquals(4, Game.Clip[2], 'and 4 in its clip (inv_inclip_)');

    { triggerFirst: not until triggered (here by the key's targets) }
    It := ItemNamed('item_armor_2');
    Check(not It.CanPickUp, 'triggerFirst: can''t be picked up');
    StandAt(80, -210);
    Check(not It.PickedUp, 'touching it does nothing');
    StandAt(-140, -230);
    Check(ItemNamed('item_keycard_1').PickedUp, 'the key picked up within its triggersize');
    CheckEquals(1, Game.Carried.Count, 'carried');
    CheckEquals('Test Keycard', Game.Carried[0], 'by its inv_name');
    CheckEquals(25, Game.Armor, 'a carried item gives nothing else');
    StandAt(-120, -100);
    Check(It.CanPickUp, 'the key''s targets let item_armor_2 be picked up');
    StandAt(80, -210);
    Check(It.PickedUp, 'item_armor_2 picked up');
    CheckEquals(50, Game.Armor, 'armor 50');

    Game.GiveAll;
    CheckEquals(100, Game.Armor, 'give all: maxarmor');
    CheckEquals(24, Game.AmmoCount('ammo_test_shells'), 'give all: max ammo');
    Check(Pos('weapon_test_shotgun (clip 4)', Game.InventoryStatus) > 0, 'inventory status lists the weapons');
  finally
    FreeAndNil(Game);
    FreeAndNil(World);
  end;
end;

procedure TestWeapons;
var
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  A: TD3Actor;
  M, Blob: TD3Monster;
  Eye: TVector3;
  RemoveMe: TRemoveType;
  I, Health0, Shots0: Integer;

  procedure Step(const Seconds: Single);
  var
    T: Single;
  begin
    T := 0;
    while T < Seconds - 0.001 do
    begin
      Game.Update(0.05, Eye);
      RemoveMe := rtNone;
      Map.Update(0.05, RemoveMe);
      T := T + 0.05;
    end;
  end;

  procedure AimAt(const Mon: TD3Monster);
  begin
    Game.PlayerViewDir := (Mon.Center - Eye).Normalize;
  end;

begin
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Check(Map.LoadMap('testmap'), 'load testmap for weapons');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    Game.NoTarget := True;
    for A in Game.Actors do
      A.Thinking := False;
    Blob := nil;
    for M in Game.Monsters do
    begin
      M.Dormant := True;
      if M.Model.Entity.Name = 'blob_1' then
        Blob := M;
    end;
    Check(Blob <> nil, 'blob_1');
    if Blob = nil then
      Exit;
    { in room B, facing east (a wall far away) }
    Eye := D3ToCge(Vector3(420, -250, 0)) + Vector3(0, PlayerEyeHeight, 0);
    Game.PlayerViewDir := D3ToCge(Vector3(1, 0, 0));
    Step(0.1);
    Check(Game.Weapon <> nil, 'a weapon');
    if Game.Weapon = nil then
      Exit;
    CheckEquals(1, Game.Weapon.Slot, 'the pistol (current_weapon 1)');
    Check(Game.Weapon.Scripted, 'it runs its script (weapon_test_gun)');
    Check(Game.Weapon.View <> nil, 'its view model (model_view)');
    CheckEquals(12, Game.Clip[1], 'a full clip at first');
    Step(0.6);
    CheckEquals('Idle', Game.Weapon.StateName, 'raised, then idle');
    Check(Game.Weapon.Status = wsReady, 'ready (weaponReady)');
    Check(Game.Weapon.Holder.Exists, 'its view model shows');

    { held: a shot every 0.35 s }
    Game.Attack := True;
    Step(1);
    Game.Attack := False;
    Check(Game.Weapon.Shots in [3, 4], Format('3 shots a second while held (%d)', [Game.Weapon.Shots]));
    CheckEquals(12 - Game.Weapon.Shots, Game.Clip[1], 'each takes one from the clip');
    CheckEquals(24 - Game.Weapon.Shots, Game.AmmoCount('ammo_test_bullets'), 'and from the ammo (the clip counts in it)');
    Step(0.5);
    Shots0 := Game.Weapon.Shots;
    Game.AttackOnce;
    Step(0.6);
    CheckEquals(Shots0 + 1, Game.Weapon.Shots, 'AttackOnce: one shot');

    { reload: the clip fills from the ammo }
    Game.ReloadWeapon;
    Step(0.2);
    CheckEquals('Reload', Game.Weapon.StateName, 'reloading');
    Step(1.2);
    CheckEquals(12, Game.Clip[1], 'reloaded');
    CheckEquals('Idle', Game.Weapon.StateName, 'idle again');

    { a shot at blob_1 hurts it by the bullet's damage }
    Eye := D3ToCge(Vector3(450, -40, 0)) + Vector3(0, PlayerEyeHeight, 0);
    AimAt(Blob);
    Health0 := Blob.Health;
    Game.AttackOnce;
    Step(0.3);
    CheckEquals(Health0 - 14, Blob.Health, 'a bullet: 14 damage');

    { the fists: lower the pistol, raise the fists, punch }
    Game.SelectWeapon(0);
    Step(0.1);
    Check(Game.Weapon.Slot = 1, 'the pistol is lowered first');
    Step(1);
    CheckEquals(0, Game.Weapon.Slot, 'then the fists');
    Step(0.5);
    CheckEquals('Idle', Game.Weapon.StateName, 'fists ready');
    Eye := Blob.Position + D3ToCge(Vector3(-40, 0, 0)) + Vector3(0, PlayerEyeHeight - 10, 0);
    AimAt(Blob);
    Health0 := Blob.Health;
    Game.AttackOnce;
    Step(0.5);
    CheckEquals(Health0 - 20, Blob.Health, 'a punch: 20 damage (melee)');

    { the shotgun: 8 pellets a shot, one shell }
    Game.SelectWeapon(2);
    Check(Game.IdealSlot = 0, 'no shotgun yet');
    Game.Give('weapon', 'weapon_test_shotgun');
    Game.Give('ammo_test_shells', '16');
    Game.SelectWeapon(2);
    Step(1.5);
    CheckEquals(2, Game.Weapon.Slot, 'the shotgun');
    CheckEquals(8, Game.Clip[2], 'its clip filled from the shells');
    Eye := D3ToCge(Vector3(420, -250, 0)) + Vector3(0, PlayerEyeHeight, 0);
    Game.PlayerViewDir := D3ToCge(Vector3(1, 0, 0));
    I := Game.Projectiles.Count;
    Game.AttackOnce;
    Step(0.1);
    Step(0.05);
    CheckEquals(15, Game.AmmoCount('ammo_test_shells'), 'one shell a shot');
    CheckEquals(7, Game.Clip[2], 'clip 7');
    Check(Pos('TEST SHOTGUN  7 / 8', Game.WeaponHudText) = 1, 'HUD text: ' + Game.WeaponHudText);

    { the wheel order: next carried weapon after the shotgun is the fists }
    Game.NextWeapon(1);
    CheckEquals(0, Game.IdealSlot, 'next weapon wraps to the fists');
    Game.NextWeapon(-1);
    CheckEquals(2, Game.IdealSlot, 'previous: the shotgun');

    { out of ammo: no shot }
    Game.SetAmmo('ammo_test_shells', 0);
    Game.Clip[2] := 0;
    Shots0 := Game.Weapon.Shots;
    Game.AttackOnce;
    Step(1);
    CheckEquals(Shots0, Game.Weapon.Shots, 'no ammo: no shot');
  finally
    FreeAndNil(Game);
    FreeAndNil(World);
  end;
end;

procedure TestWeaponPresentation;
var
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  A: TD3Actor;
  M: TD3Monster;
  Eye, P, C, Dir: TVector3;
  R, MaxAngle, MaxBob, MaxRoll, MaxUp: Single;
  RemoveMe: TRemoveType;
  I, Flash: Integer;
  Mat: TD3Material;
  FlashSeen, LightSeen: Boolean;

  procedure Step;
  begin
    Game.Update(0.05, Eye);
    RemoveMe := rtNone;
    Map.Update(0.05, RemoveMe);
  end;

  function GunAngle: Single;
  begin
    { between the view model's forward (Doom 3 +x) and the view }
    Dir := Game.Weapon.Holder.LocalToWorldDirection(D3ToCge(Vector3(1, 0, 0))).Normalize;
    Result := RadToDeg(AngleRadBetweenVectors(Dir, Game.PlayerViewDir));
  end;

begin
  Mat := Decls.Material('models/weapons/test/muzzleflash');
  Check(Mat.StageCondition <> nil, 'the muzzle flash stage has its "if" condition');
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Check(Map.LoadMap('testmap'), 'load testmap for the weapon presentation');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    Game.NoTarget := True;
    for A in Game.Actors do
      A.Thinking := False;
    for M in Game.Monsters do
      M.Dormant := True;
    Eye := D3ToCge(Vector3(420, -250, 0)) + Vector3(0, PlayerEyeHeight, 0);
    Game.PlayerViewDir := D3ToCge(Vector3(1, 0, 0));
    for I := 1 to 20 do
      Step;
    Check((Game.Weapon <> nil) and (Game.Weapon.View <> nil), 'the pistol''s view model');
    if (Game.Weapon = nil) or (Game.Weapon.View = nil) then
      Exit;
    Flash := -1;
    for I := 0 to High(Game.Weapon.View.MeshMaterials) do
      if Game.Weapon.View.MeshMaterials[I] = 'models/weapons/test/muzzleflash' then
        Flash := I;
    Check(Flash >= 0, 'its muzzle flash mesh');
    if Flash < 0 then
      Exit;
    Check(not Game.Weapon.View.MeshShapes[Flash].Visible, 'the flash hides before a shot');
    Check(not Game.MuzzleFlash(P, C, R), 'no flash light before a shot');
    Check(GunAngle < 1, Format('standing still, the gun points along the view (%.2f)', [GunAngle]));

    { a shot: the flash shows, the gun kicks up, then settles }
    Game.AttackOnce;
    FlashSeen := False;
    LightSeen := False;
    MaxAngle := 0;
    for I := 1 to 6 do
    begin
      Step;
      if Game.Weapon.View.MeshShapes[Flash].Visible then
        FlashSeen := True;
      if Game.MuzzleFlash(P, C, R) then
      begin
        LightSeen := True;
        CheckNear(160, R, 'the flash light''s radius (flashRadius)');
        CheckVec3(Vector3(1, 0.8, 0.4), C, 'its color (flashColor)');
        Check(PointsDistance(P, Eye) < 60, 'near the gun');
      end;
      MaxAngle := Max(MaxAngle, GunAngle);
    end;
    CheckEquals(1, Game.Weapon.Shots, 'one shot');
    Check(FlashSeen, 'the flash mesh showed');
    Check(LightSeen, 'the flash light showed');
    Check(MaxAngle > 2, Format('the gun kicked up (%.2f degrees)', [MaxAngle]));
    for I := 1 to 10 do
      Step;
    Check(not Game.Weapon.View.MeshShapes[Flash].Visible, 'the flash hides again');
    Check(not Game.MuzzleFlash(P, C, R), 'the flash light is off again');
    Check(GunAngle < 1, Format('the kick settled (%.2f)', [GunAngle]));

    Check(Game.Weapon.Holder.RenderLayer = rlFront, 'the view model is drawn in front (the depth hack)');

    { walking (200 units a second): the gun and the view bob }
    MaxBob := 0;
    MaxAngle := 0;
    MaxRoll := 0;
    MaxUp := 0;
    for I := 1 to 20 do
    begin
      Eye := Eye + D3ToCge(Vector3(10, 0, 0));
      Step;
      MaxBob := Max(MaxBob, Game.BobFracSin);
      MaxAngle := Max(MaxAngle, GunAngle);
      MaxRoll := Max(MaxRoll, Abs(Game.ViewBobAngles.Z));
      MaxUp := Max(MaxUp, Game.ViewBobOffset.Y);
    end;
    Check(MaxRoll > 0.2, Format('the view rolls with the steps (%.2f degrees)', [MaxRoll]));
    Check((MaxUp > 0.5) and (MaxUp <= 6), Format('the view bobs up (%.2f, at most 6)', [MaxUp]));
    Game.ViewBobEnabled := False;
    Check(Game.ViewBobOffset.IsZero and Game.ViewBobAngles.IsZero, 'pm_bob 0: no view bob');
    Game.ViewBobEnabled := True;
    CheckNear(200, Game.PlayerSpeed, 'the player''s speed', 1);
    Check(MaxBob > 0.5, Format('the bob cycles (%.2f)', [MaxBob]));
    Check(MaxAngle > 0.5, Format('the gun sways while walking (%.2f degrees)', [MaxAngle]));
    for I := 1 to 10 do
      Step;
    CheckNear(0, Game.PlayerSpeed, 'standing again');
    CheckNear(0, Game.BobFracSin, 'no bob standing');
    CheckNear(0, Game.ViewBobOffset.Y, 'the view at the eye standing');

    { a landing at 400 units a second dips the view by 8 }
    for I := 1 to 4 do
    begin
      Eye := Eye - Vector3(0, 20, 0);
      Step;
    end;
    MaxUp := 0;
    for I := 1 to 6 do
    begin
      Step;
      MaxUp := Min(MaxUp, Game.ViewBobOffset.Y);
    end;
    Check((MaxUp < -4) and (MaxUp >= -8.01), Format('a landing dips the view (%.2f)', [MaxUp]));
    for I := 1 to 10 do
      Step;
    CheckNear(0, Game.ViewBobOffset.Y, 'and it comes back');

    { turning: the gun lags behind the view }
    Game.PlayerViewDir := D3ToCge(Vector3(0, 1, 0));
    Step;
    Check(GunAngle > 2, Format('the gun lags behind a turn (%.2f)', [GunAngle]));
    for I := 1 to 20 do
      Step;
    Check(GunAngle < 1, Format('then catches up (%.2f)', [GunAngle]));
  finally
    FreeAndNil(Game);
    FreeAndNil(World);
  end;
end;

procedure TestPlayerMotion;
var
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  A: TD3Actor;
  M: TD3Monster;
  Eye: TVector3;
  RemoveMe: TRemoveType;
  I, Health0: Integer;
  MinView: Single;

  procedure Step;
  begin
    Game.Update(0.05, Eye);
    RemoveMe := rtNone;
    Map.Update(0.05, RemoveMe);
  end;

  { walk east 10 units a step (200 units a second), rising by Rise }
  procedure Walk(const Rise: Single);
  begin
    Eye := Eye + D3ToCge(Vector3(10, 0, Rise));
    Step;
  end;

  procedure Fall(const Height, PerStep: Single);
  var
    Done: Single;
  begin
    Done := 0;
    while Done < Height - 0.01 do
    begin
      Eye := Eye - Vector3(0, Min(PerStep, Height - Done), 0);
      Done := Done + PerStep;
      Step;
    end;
    { landed: standing }
    Step;
    Step;
  end;

begin
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Check(Map.LoadMap('testmap'), 'load testmap for the player''s motion');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    Game.NoTarget := True;
    for A in Game.Actors do
      A.Thinking := False;
    for M in Game.Monsters do
      M.Dormant := True;
    Game.PlayerViewDir := D3ToCge(Vector3(1, 0, 0));
    Eye := D3ToCge(Vector3(380, -250, 0)) + Vector3(0, PlayerEyeHeight, 0);
    for I := 1 to 5 do
      Step;

    { a step up: the view starts 16 below and follows within 0.2 s }
    Walk(0);
    Walk(16);
    Check(Game.ViewBobOffset.Y < -9, Format('after a step up the view is below the eye (%.1f)', [Game.ViewBobOffset.Y]));
    for I := 1 to 4 do
      Walk(0);
    Check(Game.ViewBobOffset.Y > -0.01, Format('0.2 s later it caught up (%.1f)', [Game.ViewBobOffset.Y]));
    { steps in a row add up, to 32 at most }
    Walk(16);
    Walk(16);
    Check(Game.ViewBobOffset.Y < -16, Format('two steps add up (%.1f)', [Game.ViewBobOffset.Y]));
    Walk(16);
    Walk(16);
    Check(Game.ViewBobOffset.Y >= -32.01, Format('at most 32 below (%.1f)', [Game.ViewBobOffset.Y]));
    for I := 1 to 6 do
      Walk(0);
    { rising without walking (a lift) isn't a step }
    MinView := 0;
    for I := 1 to 10 do
    begin
      Eye := Eye + Vector3(0, 3, 0);
      Step;
      MinView := Min(MinView, Game.ViewBobOffset.Y);
    end;
    CheckNear(0, MinView, 'a lift doesn''t lower the view');
    Step;
    Step;

    { a fall of 100 units: a dip, no damage (delta 21) }
    Health0 := Game.Health;
    Fall(100, 25);
    CheckNear(21.32, Game.LastFallDelta, 'fall delta: 2 * 1066 * 100 / 10000', 0.01);
    CheckEquals(Health0, Game.Health, 'no damage below delta 30');
    { 200 units (delta 42.6): damage_softfall, 10 by default }
    Fall(200, 25);
    CheckEquals(Health0 - 10, Game.Health, 'a soft fall hurts by 10');
    { 250 units (delta 53): damage_hardfall, 25 }
    Game.Health := 100;
    Fall(250, 25);
    CheckEquals(75, Game.Health, 'a hard fall hurts by 25');
    { flying (noclip): no falls }
    Game.Health := 100;
    Game.PlayerFlying := True;
    Fall(250, 25);
    Game.PlayerFlying := False;
    CheckEquals(100, Game.Health, 'flying: no falling damage');
    { god mode: no damage }
    Game.God := True;
    Fall(400, 25);
    Game.God := False;
    CheckEquals(100, Game.Health, 'god mode: no falling damage');
    { a jump: the fall counts from its top }
    Game.PlayerJumping := True;
    for I := 1 to 4 do
    begin
      Eye := Eye + Vector3(0, 15, 0);
      Step;
    end;
    Game.PlayerJumping := False;
    Fall(60, 15);
    CheckNear(2 * 1066 * 60 * 0.0001, Game.LastFallDelta, 'a jump''s fall is from its top', 0.01);
    CheckEquals(100, Game.Health, 'jumping doesn''t hurt');
    { 320 units (delta 68): damage_fatalfall }
    Fall(320, 40);
    Check(Game.PlayerDead, 'a fatal fall kills');
  finally
    FreeAndNil(Game);
    FreeAndNil(World);
  end;
end;

procedure TestDamageFeedback;
var
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  A: TD3Actor;
  M: TD3Monster;
  Eye: TVector3;
  RemoveMe: TRemoveType;
  I: Integer;

  procedure Step(const Seconds: Single);
  var
    T: Single;
  begin
    T := 0;
    while T < Seconds - 0.001 do
    begin
      Game.Update(0.05, Eye);
      RemoveMe := rtNone;
      Map.Update(0.05, RemoveMe);
      T := T + 0.05;
    end;
  end;

var
  MaxShift: Single;
  Moved: TVector3;
begin
  CheckNear(120, TD3Game.FallSpeed(0), 'falling starts at 120 units a second');
  CheckNear(533, TD3Game.FallSpeed(0.5), 'Doom 3''s gravity: 1066 * 0.5 after half a second');
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Check(Map.LoadMap('testmap'), 'load testmap for damage feedback');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    Game.NoTarget := True;
    for A in Game.Actors do
      A.Thinking := False;
    for M in Game.Monsters do
      M.Dormant := True;
    Game.PlayerViewDir := D3ToCge(Vector3(1, 0, 0));
    Eye := D3ToCge(Vector3(420, -250, 0)) + Vector3(0, PlayerEyeHeight, 0);
    Step(1);
    Check(Game.SinceDamage > 100, 'not hurt yet');
    Check(Length(Game.ScreenBlobs) = 0, 'no blobs yet');

    { a hit from the front with damage_test_melee: pain, a kick, a blob }
    Game.DamagePlayer(7, 'damage_test_melee', D3ToCge(Vector3(-1, 0, 0)));
    CheckEquals(93, Game.Health, 'hurt by 7');
    CheckEquals('snd_pain_small', Game.LastPlayerSound, 'above 75 health: snd_pain_small');
    CheckEquals(1, Length(Game.ScreenBlobs), 'a blob (blob_time, mtr_blob)');
    CheckEquals('textures/test/blood_blob', Game.ScreenBlobs[0].Material, 'the blob''s material');
    Check(Abs(Game.ViewBobAngles.X) > 5, Format('the view kicks (pitch %.1f)', [Game.ViewBobAngles.X]));
    CheckNear(0, Game.SinceDamage, 'just hurt');
    { the shotgun's pellets: hits within 0.15 s make no new effects, nor
      a new cry within pain_delay }
    Game.LastPlayerSound := '';
    Game.DamagePlayer(7, 'damage_test_melee', D3ToCge(Vector3(-1, 0, 0)));
    CheckEquals(1, Length(Game.ScreenBlobs), 'no second blob at once');
    CheckEquals('', Game.LastPlayerSound, 'no cry within pain_delay');
    Step(0.6);
    CheckEquals(0, Length(Game.ScreenBlobs), 'the blob is gone after blob_time');
    CheckNear(0, Game.ViewBobAngles.Length, 'the kick is over after kick_time', 0.01);
    { cries by the health left }
    Game.Health := 60;
    Game.DamagePlayer(5);
    CheckEquals('snd_pain_medium', Game.LastPlayerSound, 'above 50: snd_pain_medium');
    Step(0.6);
    Game.Health := 40;
    Game.DamagePlayer(5);
    CheckEquals('snd_pain_large', Game.LastPlayerSound, 'above 25: snd_pain_large');
    Step(0.6);
    Game.DamagePlayer(20);
    CheckEquals('snd_pain_huge', Game.LastPlayerSound, 'below 25: snd_pain_huge');
    Step(0.6);
    { armor takes a third and clanks }
    Game.Health := 100;
    Game.Armor := 30;
    Game.DamagePlayer(9);
    CheckEquals(27, Game.Armor, 'armor absorbed 3');
    { the cry comes after the armor's sound }
    Check(Game.LastPlayerSound = 'snd_pain_small', 'then the cry');
    Game.Armor := 0;
    Step(0.6);
    { a damaging fall: the landing sound, no cry }
    Game.LastPlayerSound := '';
    for I := 1 to 8 do
    begin
      Eye := Eye - Vector3(0, 25, 0);
      Step(0.05);
    end;
    Step(0.1);
    CheckEquals('snd_land_hard', Game.LastPlayerSound, 'a hard landing sounds, no pain cry');
    { double vision (dv_time 500 ms in damage_test_projectile) }
    Game.Health := 100;
    Step(1);
    CheckNear(0, Game.DoubleVisionShift, 'no double vision before');
    { the earlier hits' knockback (the view would have moved the camera) }
    Game.KnockbackMove(5);
    Game.DamagePlayer(5, 'damage_test_projectile', D3ToCge(Vector3(1, 0, 0)));
    MaxShift := 0;
    for I := 1 to 10 do
    begin
      MaxShift := Max(MaxShift, Game.DoubleVisionShift);
      Step(0.05);
    end;
    Check((MaxShift > 0.05) and (MaxShift <= 0.5), Format('double vision shifts the view (%.2f, half the screen at most)', [MaxShift]));
    CheckNear(0, Game.DoubleVisionShift, 'it ends after dv_time');
    { knockback (40 in damage_test_projectile: 200 units a second along
      the force), slowed by Doom 3's friction to a stop after about 25 }
    CheckVec3(Vector3(200, 0, 0), Game.KnockbackVelocity, 'knockback velocity: 1000 * 40 / 200 along the force');
    Moved := TVector3.Zero;
    for I := 1 to 40 do
      Moved := Moved + Game.KnockbackMove(0.05);
    Check((CgeToD3(Moved).X > 20) and (CgeToD3(Moved).X < 30), Format('pushed about 25 units (%.1f)', [CgeToD3(Moved).X]));
    CheckNear(0, Game.KnockbackVelocity.Length, 'then stopped');
    { a def without "knockback": 20, 100 units a second }
    Step(0.5);
    Game.DamagePlayer(7, 'damage_test_melee', D3ToCge(Vector3(0, 1, 0)));
    CheckVec3(Vector3(0, 100, 0), Game.KnockbackVelocity, 'default knockback 20');
    Game.KnockbackMove(2);
    { no direction: no push }
    Game.DamagePlayer(3, 'damage_test_melee', TVector3.Zero);
    CheckNear(0, Game.KnockbackVelocity.Length, 'no direction, no knockback');
    { the armor's screen effect }
    Step(0.5);
    Game.Armor := 30;
    Game.DamagePlayer(9);
    Check(Game.ArmorPulse > 0.9, 'armor took a hit: its screen effect');
    Step(0.3);
    CheckNear(0, Game.ArmorPulse, 'it fades in 0.25 s');
    Game.Armor := 0;
    { death }
    Step(1);
    Game.DamagePlayer(1000);
    CheckEquals('snd_death', Game.LastPlayerSound, 'snd_death');
  finally
    FreeAndNil(Game);
    FreeAndNil(World);
  end;
end;

procedure TestPowerups;
var
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  A: TD3Actor;
  M, Blob: TD3Monster;
  Eye: TVector3;
  RemoveMe: TRemoveType;
  Health0: Integer;

  procedure Step(const Seconds: Single);
  var
    T: Single;
  begin
    T := 0;
    while T < Seconds - 0.001 do
    begin
      Game.Update(0.05, Eye);
      RemoveMe := rtNone;
      Map.Update(0.05, RemoveMe);
      T := T + 0.05;
    end;
  end;

begin
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Check(Map.LoadMap('testmap'), 'load testmap for powerups');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    Game.NoTarget := True;
    for A in Game.Actors do
      A.Thinking := False;
    Blob := nil;
    for M in Game.Monsters do
    begin
      M.Dormant := True;
      if M.Model.Entity.Name = 'blob_1' then
        Blob := M;
    end;
    Game.PlayerViewDir := D3ToCge(Vector3(1, 0, 0));
    Eye := D3ToCge(Vector3(-160, -160, 0)) + Vector3(0, PlayerEyeHeight, 0);
    Step(1);
    Check(not Game.PowerUpActive(PowerupBerserk), 'no berserk at first');
    CheckNear(1, Game.SpeedModifier, 'normal speed');

    { the berserk pickup (idItemPowerup, type 0, 20 s) }
    Eye := D3ToCge(Vector3(-220, 120, 0)) + Vector3(0, PlayerEyeHeight, 0);
    Step(0.1);
    Check(Game.PowerUpActive(PowerupBerserk), 'berserk picked up');
    CheckNear(20, Game.PowerUpLeft(PowerupBerserk), 'for its "time"', 0.2);
    CheckEquals('snd_berserk_third', Game.LastPlayerSound, 'its sound');
    CheckEquals(0, Game.IdealSlot, 'berserk switches to the fists');
    CheckNear(1.7, Game.SpeedModifier, 'berserk runs 1.7 times as fast');
    { monsters can't hurt a berserk player; other damage still does }
    Health0 := Game.Health;
    Game.DamagePlayerByMonster(10, 'damage_test_melee', TVector3.Zero);
    CheckEquals(Health0, Game.Health, 'monsters do no damage while berserk');
    Game.DamagePlayer(10, '', TVector3.Zero);
    CheckEquals(Health0 - 10, Game.Health, 'other damage still hurts');
    { the player's damage times 1.7 (idPlayer::DamageFeedback) }
    if Blob <> nil then
    begin
      Health0 := Blob.Health;
      Game.Fire(Blob.Center - D3ToCge(Vector3(100, 0, 0)), D3ToCge(Vector3(1, 0, 0)));
      CheckEquals(Health0 - 24, Blob.Health, 'the pistol''s 14 times 1.7');
    end;
    Step(20);
    Check(not Game.PowerUpActive(PowerupBerserk), 'berserk ends after 20 s');
    CheckNear(1, Game.SpeedModifier, 'normal speed again');

    { invisibility: the view weapon turns see-through }
    Eye := D3ToCge(Vector3(-160, -160, 0)) + Vector3(0, PlayerEyeHeight, 0);
    Step(1.5);
    Check(Game.GivePowerUp(PowerupInvisibility, 3), 'invisibility given');
    Step(0.1);
    Check((Game.Weapon <> nil) and Game.Weapon.Invisible, 'the view weapon is see-through');
    CheckEquals('snd_invisibility', Game.LastPlayerSound, 'its sound');
    Step(3.1);
    Check(not Game.PowerUpActive(PowerupInvisibility), 'invisibility ends');
    Check(not Game.Weapon.Invisible, 'the weapon is solid again');

    { megahealth: 200 health (powerup_megahealth's inv_health, else 200) }
    Check(Game.Give('mega', '0'), 'mega given');
    CheckEquals(200, Game.Health, 'megahealth: 200');
    { "berserk" through the inventory, then death clears the powerups }
    Check(Game.Give('berserk', '5'), 'berserk through Give');
    Check(Game.PowerUpActive(PowerupBerserk), 'berserk again');
    Game.God := False;
    Game.DamagePlayer(1000);
    Check(not Game.PowerUpActive(PowerupBerserk), 'death clears the powerups');
  finally
    FreeAndNil(Game);
    FreeAndNil(World);
  end;
end;

{ Stamina (idPlayer::AdjustSpeed), the player's body and its powerup
  skins, a knockback throwing the player up. }
procedure TestStaminaSkinsKnockback;
var
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  A: TD3Actor;
  M: TD3Monster;
  Eye, Move, Angles: TVector3;
  RemoveMe: TRemoveType;
  Rise, Peak, T: Single;

  procedure Step(const Seconds: Single);
  var
    T: Single;
  begin
    T := 0;
    while T < Seconds - 0.001 do
    begin
      Game.Update(0.05, Eye);
      RemoveMe := rtNone;
      Map.Update(0.05, RemoveMe);
      T := T + 0.05;
    end;
  end;

begin
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Check(Map.LoadMap('testmap'), 'load testmap for stamina');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    Game.NoTarget := True;
    for A in Game.Actors do
      A.Thinking := False;
    for M in Game.Monsters do
      M.Dormant := True;
    Game.PlayerViewDir := D3ToCge(Vector3(1, 0, 0));
    Eye := D3ToCge(Vector3(-160, -160, 0)) + Vector3(0, PlayerEyeHeight, 0);
    Step(0.5);

    { stamina: full (pm_stamina 24), running drains a second a second and
      blends walking (140) with running (220) by stamina / 45 }
    CheckNear(24, Game.Stamina, 'stamina starts full');
    CheckEquals(100, Game.StaminaPercent, 'stamina 100%');
    Game.PlayerRunning := True;
    Game.PlayerMoving := True;
    Step(4);
    CheckNear(20, Game.Stamina, 'running 4 s uses 4', 0.1);
    CheckNear(20 / 45, Game.RunFraction, 'run fraction stamina / threshold', 0.01);
    CheckNear((140 * (1 - 20 / 45) + 220 * 20 / 45) / 140, Game.RunMultiplier, 'run speed blended', 0.01);
    Step(25);
    CheckNear(0, Game.Stamina, 'stamina runs out');
    CheckNear(1, Game.RunMultiplier, 'out of stamina: walking speed');
    { the run key alone (not moving) regenerates, 25% faster }
    Game.PlayerMoving := False;
    Step(4);
    CheckNear(4 * 0.75 * 1.25, Game.Stamina, 'stamina regenerates at 0.75 * 1.25', 0.1);
    Game.PlayerRunning := False;
    Game.PlayerMoving := True;
    Step(2);
    CheckNear(4 * 0.75 * 1.25 + 2 * 0.75, Game.Stamina, 'walking: at 0.75', 0.1);
    { adrenaline: stamina 100 (full speed), not used up while it lasts }
    Check(Game.GivePowerUp(PowerupAdrenaline, 5), 'adrenaline given');
    CheckNear(100, Game.Stamina, 'adrenaline: stamina 100');
    Game.PlayerRunning := True;
    Step(2);
    CheckNear(100, Game.Stamina, 'adrenaline: running uses no stamina');
    CheckNear(220 / 140, Game.RunMultiplier, 'adrenaline: full run speed', 0.01);
    Step(4);
    Check(not Game.PowerUpActive(PowerupAdrenaline), 'adrenaline ends');
    Check(Game.Stamina < 100, 'then running uses it again');
    { stopping caps it to pm_stamina }
    Game.PlayerRunning := False;
    Step(0.1);
    CheckNear(24, Game.Stamina, 'more than pm_stamina is lost when not running');
    Game.StaminaMax := 0;
    CheckEquals(-1, Game.StaminaPercent, 'pm_stamina 0: no stamina on the HUD');
    Game.PlayerRunning := True;
    Step(0.1);
    CheckNear(220 / 140, Game.RunMultiplier, 'pm_stamina 0: always full run speed', 0.01);
    Game.StaminaMax := 24;
    Game.PlayerRunning := False;
    Game.PlayerMoving := False;

    { the body: player_test's model with its skin, berserk's _berserk
      skin, skin_invisibility }
    Check(Game.PlayerModel <> nil, 'the player has a body');
    CheckEquals('skins/test/player', Game.PlayerSkinName, 'its skin');
    CheckEquals('models/test/player_armor', Game.PlayerModel.MeshMaterials[0], 'the skin''s material');
    Check(not Game.PlayerModelHolder.Exists, 'not shown in first person');
    Game.ThirdPerson := True;
    Step(0.1);
    Check(Game.PlayerModelHolder.Exists, 'shown in third person');
    CheckNear(-160, CgeToD3(Game.PlayerModelHolder.Translation).X, 'at the player', 0.01);
    CheckNear(0, CgeToD3(Game.PlayerModelHolder.Translation).Z, 'on the floor', 0.01);
    Check(Game.GivePowerUp(PowerupBerserk, 2), 'berserk given');
    Step(0.1);
    CheckEquals('skins/test/player_berserk', Game.PlayerModel.SkinName, 'berserk: the _berserk skin');
    CheckEquals('models/test/player_berserk', Game.PlayerModel.MeshMaterials[0], 'the berserk material');
    Check(Game.GivePowerUp(PowerupInvisibility, 1), 'invisibility given');
    Step(0.1);
    CheckEquals('skins/test/player_invis', Game.PlayerModel.SkinName, 'invisible: skin_invisibility');
    Step(1);
    CheckEquals('skins/test/player_berserk', Game.PlayerModel.SkinName, 'invisibility over: berserk again');
    Step(1.5);
    CheckEquals('skins/test/player', Game.PlayerModel.SkinName, 'berserk over: the normal skin');
    CheckEquals('models/test/player_armor', Game.PlayerModel.MeshMaterials[0], 'the armor again');
    { the third person camera: 80 behind, 8 up, half the pitch }
    Game.ThirdPersonClip := False;
    Angles := Vector3(30, 0, 0);
    Game.ThirdPersonView(Eye, Angles, Move);
    CheckNear(-160 - 80 * Cos(DegToRad(15)), CgeToD3(Move).X, 'third person: 80 behind', 0.01);
    CheckNear(68 + 8 + 80 * Sin(DegToRad(15)), CgeToD3(Move).Z, 'third person: 8 up, half the pitch', 0.01);
    Check(Angles.X > 0, 'looking down at the focus point');
    Game.ThirdPersonClip := True;
    Game.ThirdPerson := False;
    Step(0.1);
    Check(not Game.PlayerModelHolder.Exists, 'hidden again in first person');

    { knockback up (200 units a second): no friction, Doom 3's gravity,
      down where it started: v^2 / 2g = 18.8 units }
    Game.God := False;
    Game.Health := 100;
    Game.DamagePlayer(1, 'damage_test_projectile', Vector3(0, 1, 0));
    Check(Game.KnockbackAirborne, 'thrown off the ground');
    CheckNear(200, Game.KnockbackVelocity.Z, 'knockback 40: 200 up', 0.01);
    Rise := 0;
    Peak := 0;
    T := 0;
    while Game.KnockbackAirborne and (T < 2) do
    begin
      Move := Game.KnockbackMove(1 / 60);
      Rise := Rise + Move.Y;
      Peak := Max(Peak, Rise);
      T := T + 1 / 60;
    end;
    CheckNear(18.8, Peak, 'rises v^2 / 2g', 0.3);
    CheckNear(0.375, T, 'lands after 2 v / g', 0.03);
    CheckNear(0, Rise, 'lands where it started', 0.01);
    CheckNear(18.8, Game.KnockbackPeak, 'its peak', 0.3);
    { pushed down on the ground: the ground takes it }
    Game.DamagePlayer(1, 'damage_test_projectile', Vector3(0, -1, 0));
    Check(not Game.KnockbackAirborne, 'down: not airborne');
    CheckNear(0, Game.KnockbackVelocity.Z, 'down: no vertical speed', 0.01);
    Move := Game.KnockbackMove(10);
    { a ceiling stops the rise, then it falls }
    Game.DamagePlayer(1, 'damage_test_projectile', Vector3(0, 1, 0));
    Move := Game.KnockbackMove(0.05);
    Game.KnockbackBlocked;
    CheckNear(0, Game.KnockbackVelocity.Z, 'a ceiling stops the rise');
    Check(Game.KnockbackAirborne, 'still in the air');
    Move := Game.KnockbackMove(0.05);
    Check(Move.Y < 0, 'falls back');
    Game.KnockbackBlocked;
    Check(not Game.KnockbackAirborne, 'landed on something');
  finally
    FreeAndNil(Game);
    FreeAndNil(World);
  end;
end;

{ Crouching (heights, rate, speed, the crawl bar), the body's crouch and
  death anims, the gun in its hand, the dead view. }
procedure TestCrouchAndDeath;
var
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  A: TD3Actor;
  M: TD3Monster;
  Eye, P, Angles, ViewPos: TVector3;
  RemoveMe: TRemoveType;
  Old: Single;

  { like TViewPlay: crouch, the eye moves by the change, then the game }
  procedure Step(const Seconds: Single);
  var
    T: Single;
  begin
    T := 0;
    while T < Seconds - 0.001 do
    begin
      Old := Game.EyeHeight;
      Game.UpdateCrouch(1 / 60, Eye);
      Eye := Eye + Vector3(0, Game.EyeHeight - Old, 0);
      Game.Update(1 / 60, Eye);
      RemoveMe := rtNone;
      Map.Update(1 / 60, RemoveMe);
      T := T + 1 / 60;
    end;
  end;

begin
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Check(Map.LoadMap('testmap'), 'load testmap for crouching');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    Game.NoTarget := True;
    for A in Game.Actors do
      A.Thinking := False;
    for M in Game.Monsters do
      M.Dormant := True;
    Game.PlayerViewDir := D3ToCge(Vector3(1, 0, 0));
    Eye := D3ToCge(Vector3(40, 80, 0)) + Vector3(0, PlayerEyeHeight, 0);
    Step(0.5);
    CheckNear(68, Game.EyeHeight, 'standing eye height');
    CheckNear(74, Game.PlayerBodyHeight, 'standing: 74 high');

    { crouching: the eye eases to 32 by 0.87 a frame, the feet stay }
    Game.PlayerCrouchHeld := True;
    Step(1 / 60);
    Check(Game.Crouched, 'crouched');
    CheckNear(32 + 36 * 0.87, Game.EyeHeight, 'one frame: pm_crouchrate', 0.01);
    Step(1);
    CheckNear(32, Game.EyeHeight, 'crouched eye height');
    CheckNear(0, CgeToD3(Game.PlayerFeet).Z, 'the feet stay on the floor', 0.01);
    CheckNear(38, Game.PlayerBodyHeight, 'crouched: 38 high');
    CheckNear(80 / 140, Game.CrouchSpeedScale, 'crouch speed 80');
    { holding crouch isn't running: no stamina used }
    Game.PlayerRunning := True;
    Game.PlayerMoving := True;
    Step(1);
    CheckNear(24, Game.Stamina, 'crouched running uses no stamina');
    Game.PlayerRunning := False;
    Game.PlayerMoving := False;

    { under the crawl bar (x 112..128, bottom at 52) it can't stand up }
    Eye := D3ToCge(Vector3(120, 80, 32));
    Game.PlayerCrouchHeld := False;
    Step(0.5);
    Check(not Game.CanStandUp(Eye), 'no room under the bar');
    Check(Game.Crouched, 'stays crouched under the bar');
    CheckNear(32, Game.EyeHeight, 'eye stays low under the bar');
    Eye := D3ToCge(Vector3(170, 80, 32));
    Step(0.1);
    Check(not Game.Crouched, 'out from under it: stands up');
    Step(1);
    CheckNear(68, Game.EyeHeight, 'standing again');

    { the body: crouch anim, the gun in its hand }
    Game.ThirdPerson := True;
    Step(0.5);
    Check((Game.Weapon <> nil) and (Game.Weapon.World <> nil), 'the gun has a world model');
    Check(Game.Weapon.WorldHolder.Exists, 'the gun shows in the body''s hand');
    CheckEquals('arm_r', Game.Weapon.AttachJoint, 'on joint_attach');
    Check(Game.PlayerModel.JointPosition('arm_r', P), 'the body has arm_r');
    CheckNear(P.X, Game.Weapon.WorldHolder.Translation.X, 'at the joint (x)', 0.01);
    CheckNear(P.Y, Game.Weapon.WorldHolder.Translation.Y, 'at the joint (height)', 0.01);
    { the world model's muzzle flash: its flash surface, and the flash
      light at its flash joint in third person }
    Game.Weapon.FlashStart := Game.Time;
    Step(1 / 60);
    Check(Game.Weapon.World.MeshShapes[1].Visible, 'the world model''s flash surface shows');
    Check(Game.MuzzleFlash(P, ViewPos, Old), 'third person: the flash light');
    Check(Game.Weapon.World.JointPosition('flash', Angles), 'the world model has a flash joint');
    Angles := Game.Weapon.World.Scene.LocalToWorld(Angles);
    Check((P - Angles).Length < 20, 'the flash light at the world model''s flash joint');
    Step(0.3);
    Check(not Game.Weapon.World.MeshShapes[1].Visible, 'the flash surface is gone');
    { crouch_down once, then the crouch loop }
    Game.PlayerCrouchHeld := True;
    Step(3 / 60);
    CheckEquals('crouch_down', Game.PlayerModel.PlayingAnim, 'crouching: crouch_down');
    Step(0.5);
    CheckEquals('crouch', Game.PlayerModel.PlayingAnim, 'crouched: the crouch anim');
    Check(Game.PlayerModel.JointPosition('body', P), 'the body joint');
    CheckNear(18, CgeToD3(P).Z, 'crouched: the body 22 lower', 1);
    Game.PlayerCrouchHeld := False;
    Step(3 / 60);
    CheckEquals('crouch_up', Game.PlayerModel.PlayingAnim, 'standing up: crouch_up');
    Step(1);
    CheckEquals('idle', Game.PlayerModel.PlayingAnim, 'then idle');
    Game.ThirdPerson := False;

    { death: the eye goes down to 10 (pm_deadviewheight), the body plays
      its death anim once and lies on the floor; pm_thirdPersonDeath backs
      the view away from it }
    Game.ThirdPersonDeath := True;
    { the death anim (the ragdoll is TestBrassAndRagdoll's) }
    Game.RagdollEnabled := False;
    Game.God := False;
    Game.DamagePlayer(1000);
    Check(Game.PlayerDead, 'dead');
    Check(Game.ThirdPersonActive, 'dead with pm_thirdPersonDeath: third person');
    Step(2);
    CheckNear(10, Game.EyeHeight, 'dead eye height', 0.1);
    CheckNear(20, Game.PlayerBodyHeight, 'dead: 20 high');
    Check(Game.PlayerModelHolder.Exists, 'the body shows dead');
    CheckEquals('death', Game.PlayerModel.PlayingAnim, 'the death anim');
    Check(Game.PlayerModel.JointPosition('body', P), 'the body joint dead');
    Check(CgeToD3(P).Z < 15, 'lying on the floor');
    Check(not Game.Weapon.WorldHolder.Exists, 'dead: the gun is gone');
    Angles := Vector3(0, 0, 0);
    Game.ThirdPersonView(Eye, Angles, ViewPos);
    CheckNear(20 + 120 * 2 / 3, (CgeToD3(Eye) - CgeToD3(ViewPos)).X, 'backing away (20 + 120 * t / 3)', 0.5);
  finally
    FreeAndNil(Game);
    FreeAndNil(World);
  end;
end;

{ Brass (def_ejectBrass from the eject joints) and the dead body's
  ragdoll. }
procedure TestBrassAndRagdoll;
var
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  A: TD3Actor;
  M: TD3Monster;
  Eye, P, Head, Feet: TVector3;
  RemoveMe: TRemoveType;
  I: Integer;
  AllAbove: Boolean;

  procedure Step(const Seconds: Single);
  var
    T: Single;
  begin
    T := 0;
    while T < Seconds - 0.001 do
    begin
      Game.Update(1 / 60, Eye);
      RemoveMe := rtNone;
      Map.Update(1 / 60, RemoveMe);
      T := T + 1 / 60;
    end;
  end;

begin
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Check(Map.LoadMap('testmap'), 'load testmap for brass');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    Game.NoTarget := True;
    for A in Game.Actors do
      A.Thinking := False;
    for M in Game.Monsters do
      M.Dormant := True;
    Game.PlayerViewDir := D3ToCge(Vector3(1, 0, 0));
    Eye := D3ToCge(Vector3(-20, -20, 0)) + Vector3(0, PlayerEyeHeight, 0);
    Step(1.5);
    Check(Game.Weapon <> nil, 'a weapon for brass');
    CheckEquals('debris_test_brass', Game.Weapon.BrassDef, 'def_ejectBrass');

    { from the view model's eject joint, 40 * (forward + left + up) }
    Check(Game.EjectBrass(Game.Weapon), 'brass ejected');
    CheckEquals(1, Game.Brass.Count, 'one casing');
    Check(Game.Weapon.View.JointPosition('eject', P), 'the view model has an eject joint');
    P := Game.Weapon.View.Scene.LocalToWorld(P);
    CheckNear(0, (Game.Brass[0].Position - P).Length, 'at the view model''s eject joint', 0.01);
    CheckNear(40, CgeToD3(Game.Brass[0].Velocity).X, 'forward 40', 0.5);
    CheckNear(40, CgeToD3(Game.Brass[0].Velocity).Y, 'left 40', 0.5);
    CheckNear(40, CgeToD3(Game.Brass[0].Velocity).Z, 'up 40', 0.5);
    Step(2);
    Check(Game.Brass[0].Resting, 'the casing lies on the floor');
    CheckNear(0, CgeToD3(Game.Brass[0].Position).Z, 'on the floor', 1);
    Step(2.5);
    CheckEquals(0, Game.Brass.Count, 'gone after its fuse (4 s)');
    { a shot ejects one (ejectBrassDelay 0) }
    Game.AttackOnce;
    Step(1);
    CheckEquals(1, Game.Brass.Count, 'a shot ejects a casing');
    { third person: from the world model's eject joint }
    Game.ThirdPerson := True;
    Step(0.2);
    Check(Game.EjectBrass(Game.Weapon), 'brass in third person');
    Check(Game.Weapon.World.JointPosition('eject', P), 'the world model has an eject joint');
    P := Game.Weapon.World.Scene.LocalToWorld(P);
    CheckNear(0, (Game.Brass[Game.Brass.Count - 1].Position - P).Length,
      'at the world model''s eject joint', 0.01);
    Game.ShowBrass := False;
    Check(not Game.EjectBrass(Game.Weapon), 'g_showBrass 0: none');
    Game.ShowBrass := True;

    { the ragdoll: player_test has "ragdoll"; it falls over, lies on the
      floor and settles }
    Feet := CgeToD3(Game.PlayerFeet);
    Game.God := False;
    Game.DamagePlayer(1000, 'damage_test_projectile', D3ToCge(Vector3(1, 0, 0)));
    Step(0.1);
    Check(Game.PlayerRagdoll <> nil, 'dead: a ragdoll');
    Check((Game.PlayerRagdoll <> nil) and (Game.PlayerRagdoll.Figure <> nil) and
      (Game.PlayerRagdoll.Figure.Name = 'test_player'), 'the player''s articulated figure');
    Step(4);
    Check((Game.PlayerRagdoll <> nil) and Game.PlayerRagdoll.Settled, 'the ragdoll settles');
    Check(Game.PlayerModel.JointPosition('head', Head), 'the head joint');
    Head := CgeToD3(Game.PlayerModel.Scene.LocalToWorld(Head));
    Check(Head.Z < 30, 'the head is down (fell over)');
    Check(Vector2(Head.X - Feet.X, Head.Y - Feet.Y).Length > 20, 'the head away from the feet');
    AllAbove := True;
    for I := 0 to High(Game.PlayerModel.Pose) do
      if CgeToD3(Game.PlayerModel.Scene.LocalToWorld(D3ToCge(Game.PlayerModel.Pose[I].Position))).Z < -1 then
        AllAbove := False;
    Check(AllAbove, 'no joint under the floor (player)');
    Check(not Game.Weapon.WorldHolder.Exists, 'the gun is gone');
  finally
    FreeAndNil(Game);
    FreeAndNil(World);
  end;
end;

{ Articulated figures: the generated ones and a retail-like snippet. }
procedure TestArticulatedFigures;
const
  Retail =
    'settings { model "monster_zombie" friction 0.01, 0.01, 0.8, 0.5 totalMass -1 }' + LineEnding +
    'body "waist" { joint "Waist" mod orientation model dodecahedron( ( -8, -8, -8 ), ( 8, 8, 8 ) )' + LineEnding +
    '  origin bonecenter( "Hips", "Waist" ) density 0.2 containedJoints "*Hips -*Chest" }' + LineEnding +
    'body "luparm" { joint "Luparm" model bone( joint( "Luparm" ), joint( "Lloarm" ), 6 ) origin joint( "Luparm" ) }' + LineEnding +
    'universalJoint "waist_chest" { body1 "chest" body2 "waist" position joint( "Chest" ) shafts ( 0, 0, 1 ), ( 0, 0, -1 )' + LineEnding +
    '  pyramid ( 0, 0, -1 ), 30, 60, 0 friction 0.2 }' + LineEnding +
    'fixed "f" { body1 "a" body2 "b" }' + LineEnding +
    'spring "s" { body1 "a" body2 "b" anchor1 ( 1, 2, 3 ) anchor2 ( 4, 5, 6 ) friction 0.9 stretch 100 compress 0 damping 0.5 restLength 0 minLength 0 maxLength 10 }' + LineEnding +
    'hinge "knee" { body1 "thigh" body2 "calf" position joint( "Knee" ) axis ( 0, 1, 0 ) limit 30, 120, 0 }' + LineEnding +
    'unknownblock { a b c }';
var
  AF: TD3ArticulatedFigure;
  B: TD3AFBody;
  Ok: Boolean;
  P: TVector3;
  Model: TD3Md5Model;
  Joints: specialize TArray<Integer>;
begin
  CheckEquals(2, Decls.DeclCount(dtAF), 'articulated figure decls');
  AF := ArticulatedFigure('test_blob');
  Check(AF <> nil, 'test_blob af');
  if AF = nil then
    Exit;
  CheckEquals('test_blob', AF.ModelName, 'its settings'' model');
  CheckEquals(6, AF.Bodies.Count, 'six bodies');
  CheckEquals(5, AF.Constraints.Count, 'five constraints');
  B := AF.Bodies[AF.BodyIndex('torso')];
  CheckEquals('body', B.JointName, 'the torso''s joint');
  CheckEquals('box', B.ModelKind, 'a box');
  CheckNear(14, B.Radius, 'radius: half its smallest size');
  P := B.Origin.Evaluate(nil, Ok);
  CheckNear(45, P.Z, 'its origin');
  Model := Md5Cache.Model('models/md5/test/blob.md5mesh');
  Joints := B.JointList(Model.Joints);
  CheckEquals(1, Length(Joints), 'the torso moves the body joint (not origin, the root)');
  CheckEquals(Ord(acBallAndSocket), Ord(AF.Constraints[0].Kind), 'the neck: ball and socket');
  CheckNear(40, AF.Constraints[0].LimitAngle, 'its cone');
  CheckEquals(Ord(acUniversal), Ord(AF.Constraints[1].Kind), 'a shoulder: universal');
  CheckEquals(Ord(avJoint), Ord(AF.Constraints[1].Anchor.Kind), 'positioned at joint( arm_l )');
  P := AF.Constraints[1].Anchor.Evaluate(Model.Joints, Ok);
  Check(Ok and (P.Y = 22) and (P.Z = 60), 'at the arm_l joint');
  CheckEquals(Ord(acHinge), Ord(AF.Constraints[3].Kind), 'a hip: hinge');
  CheckNear(90, AF.Constraints[3].LimitAngle, 'its limit''s width');
  Check(ArticulatedFigure('test_player') <> nil, 'test_player af');
  Check(ArticulatedFigure('no_such_af') = nil, 'no such af');

  AF := ParseArticulatedFigure('retail', Retail);
  try
    CheckEquals('monster_zombie', AF.ModelName, 'retail: settings');
    CheckEquals(2, AF.Bodies.Count, 'retail: bodies');
    CheckEquals(4, AF.Constraints.Count, 'retail: constraints (unknown block skipped)');
    CheckEquals(Ord(avBoneCenter), Ord(AF.Bodies[0].Origin.Kind), 'bonecenter origin');
    CheckEquals('Hips', AF.Bodies[0].Origin.Joint1, 'bonecenter''s first joint');
    CheckEquals('*Hips -*Chest', AF.Bodies[0].ContainedJoints, 'contained joints');
    CheckEquals('bone', AF.Bodies[1].ModelKind, 'a bone model');
    CheckNear(3, AF.Bodies[1].Radius, 'a bone''s radius: half its width');
    CheckNear(60, AF.Constraints[0].LimitAngle, 'a pyramid: its larger angle');
    CheckEquals(Ord(acFixed), Ord(AF.Constraints[1].Kind), 'fixed');
    CheckEquals(Ord(acSpring), Ord(AF.Constraints[2].Kind), 'spring');
    Check(AF.Constraints[2].HasAnchor and (AF.Constraints[2].Anchor.Point.Z = 3), 'a spring''s anchor1');
    CheckNear(120, AF.Constraints[3].LimitAngle, 'a hinge''s limit width');
  finally
    AF.Free;
  end;
end;

{ A monster killed falls as its ragdoll and stays. }
procedure TestMonsterRagdoll;
var
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  A: TD3Actor;
  M, Blob: TD3Monster;
  Eye, P: TVector3;
  RemoveMe: TRemoveType;
  I, Shots: Integer;
  AllAbove: Boolean;

  procedure Step(const Seconds: Single);
  var
    T: Single;
  begin
    T := 0;
    while T < Seconds - 0.001 do
    begin
      Game.Update(1 / 60, Eye);
      RemoveMe := rtNone;
      Map.Update(1 / 60, RemoveMe);
      T := T + 1 / 60;
    end;
  end;

begin
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Check(Map.LoadMap('testmap'), 'load testmap for monster ragdolls');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    Game.NoTarget := True;
    for A in Game.Actors do
      A.Thinking := False;
    Blob := nil;
    for M in Game.Monsters do
    begin
      M.Dormant := True;
      if M.Model.Entity.Name = 'blob_1' then
        Blob := M;
    end;
    Check(Blob <> nil, 'blob_1');
    if Blob = nil then
      Exit;
    Eye := Blob.Center - D3ToCge(Vector3(150, 0, 0));
    Step(0.5);
    Shots := 0;
    while (Blob.State <> msDead) and (Shots < 20) do
    begin
      Game.Fire(Blob.Center - D3ToCge(Vector3(100, 0, 0)), D3ToCge(Vector3(1, 0, 0)));
      Inc(Shots);
      Step(0.4);
    end;
    Check(Blob.State = msDead, 'blob_1 shot dead');
    Check(Blob.Ragdoll <> nil, 'a ragdoll (its "ragdoll" test_blob)');
    if Blob.Ragdoll = nil then
      Exit;
    Check(Blob.Ragdoll.Figure <> nil, 'with its articulated figure');
    CheckEquals(11, Blob.Ragdoll.ParticleCount, '6 bodies and 5 anchors');
    Check(Blob.Model.Instance.PoseLocked, 'the ragdoll owns the pose');
    Step(5);
    Check(Blob.Ragdoll.Settled, 'it settles');
    Check(Blob.Model.Holder.Exists, 'the corpse stays (no sinking away)');
    Check(Blob.Model.Instance.JointPosition('head', P), 'its head');
    P := CgeToD3(Blob.Model.Instance.Scene.LocalToWorld(P));
    Check(P.Z < 50, 'the head came down');
    AllAbove := True;
    for I := 0 to High(Blob.Model.Instance.Pose) do
      if CgeToD3(Blob.Model.Instance.Scene.LocalToWorld(
         D3ToCge(Blob.Model.Instance.Pose[I].Position))).Z < -1 then
        AllAbove := False;
    Check(AllAbove, 'no joint under the floor');
    Check(not Blob.Model.Holder.Pickable, 'the corpse isn''t shot');
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

{ Environment probes' math (no OpenGL): cube map texel directions
  agree with the capture cameras, spherical harmonics of a uniform
  environment give its irradiance, the glossy blur keeps colors in place. }
procedure TestEnvProbes;

  function SolidFaces(const Size: Integer; const Colors: array of TVector3): TD3CubeImages;
  var
    Face: TD3CubeFace;
    X, Y: Integer;
  begin
    for Face := Low(TD3CubeFace) to High(TD3CubeFace) do
    begin
      Result[Face] := TRGBImage.Create(Size, Size);
      for Y := 0 to Size - 1 do
        for X := 0 to Size - 1 do
          Result[Face].Colors[X, Y, 0] := Vector4(Colors[Face], 1);
    end;
  end;

const
  Black: TVector3 = (X: 0; Y: 0; Z: 0);
  White: TVector3 = (X: 1; Y: 1; Z: 1);
  Red: TVector3 = (X: 1; Y: 0; Z: 0);
var
  Face: TD3CubeFace;
  Direction, Up, Side: TVector3;
  Faces, Blurred: TD3CubeImages;
  SH: TD3SH9;
begin
  for Face := Low(TD3CubeFace) to High(TD3CubeFace) do
  begin
    CubeFaceCamera(Face, Direction, Up);
    Side := TVector3.CrossProduct(Direction, Up);
    Check(TVector3.DotProduct(CubeTexelDirection(Face, 8, 8, 16), Direction) > 0.99,
      Format('env probes: face %d center is its camera direction', [Face]));
    Check(TVector3.DotProduct(CubeTexelDirection(Face, 8, 15, 16) -
      CubeTexelDirection(Face, 8, 0, 16), Up) > 1,
      Format('env probes: face %d rows go up', [Face]));
    Check(TVector3.DotProduct(CubeTexelDirection(Face, 15, 8, 16) -
      CubeTexelDirection(Face, 0, 8, 16), Side) > 1,
      Format('env probes: face %d columns go right', [Face]));
  end;

  { white all around: radiance 1, so the diffuse light is 1 for every normal }
  Faces := SolidFaces(8, [White, White, White, White, White, White]);
  try
    SH := ProjectSH9(Faces);
    CheckNear(4 * Pi * 0.282095, SH[0].X, 'env probes: SH band 0 of a white environment', 0.02);
    CheckNear(0, SH[1].X, 'env probes: no SH band 1 in a white environment');
    CheckVectorNear(White, SH9Irradiance(SH, Vector3(0, 1, 0)), 'env probes: white irradiance up', 0.02);
    CheckVectorNear(White, SH9Irradiance(SH, Vector3(-1, 0, 0)), 'env probes: white irradiance -X', 0.02);
  finally FreeCubeImages(Faces) end;

  { only +Y (up) is lit: surfaces facing up get more light than facing down }
  Faces := SolidFaces(8, [Black, Black, White, Black, Black, Black]);
  try
    SH := ProjectSH9(Faces);
    Check(SH9Irradiance(SH, Vector3(0, 1, 0)).X > 0.4,
      'env probes: a lit ceiling lights surfaces facing up');
    Check(SH9Irradiance(SH, Vector3(0, -1, 0)).X < 0.05,
      'env probes: a lit ceiling hardly lights surfaces facing down');
  finally FreeCubeImages(Faces) end;

  { a red +X face stays at +X after blurring }
  Faces := SolidFaces(8, [Red, Black, Black, Black, Black, Black]);
  try
    Blurred := BlurredFaces(Faces, 4, 32);
    try
      Check(Blurred[0].Colors[2, 2, 0].X > 0.8, 'env probes: blurred +X stays red');
      CheckNear(0, Blurred[0].Colors[2, 2, 0].Y, 'env probes: blurred +X has no green');
      Check(Blurred[1].Colors[2, 2, 0].X < 0.05, 'env probes: blurred -X stays dark');
      Check(Blurred[2].Colors[3, 2, 0].X > Blurred[2].Colors[0, 2, 0].X + 0.01,
        'env probes: +Y is redder towards +X');
    finally FreeCubeImages(Blurred) end;
  finally FreeCubeImages(Faces) end;
end;


procedure TestDamageEffects;
var
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  Eye: TVector3;
  RemoveMe: TRemoveType;
  Blob1, Blob2, M: TD3Monster;
  A: TD3Actor;
  Info: TD3DamageInfo;
  Health0, Debris0, I: Integer;
  Hurt: TD3Trigger;

  procedure Step(const Seconds: Single);
  var
    T: Single;
  begin
    T := 0;
    while T < Seconds - 0.001 do
    begin
      Game.Update(0.05, Eye);
      RemoveMe := rtNone;
      Map.Update(0.05, RemoveMe);
      T := T + 0.05;
    end;
  end;

begin
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Check(Map.LoadMap('testmap'), 'load testmap for damage effects');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    Game.NoTarget := True;
    for A in Game.Actors do
      A.Thinking := False;
    Blob1 := nil;
    Blob2 := nil;
    for M in Game.Monsters do
    begin
      M.Dormant := True;
      if M.Model.Entity.Name = 'blob_1' then
        Blob1 := M;
      if M.Model.Entity.Name = 'blob_2' then
        Blob2 := M;
    end;
    Check((Blob1 <> nil) and (Blob2 <> nil), 'blob_1 and blob_2 (the simple AI)');
    if (Blob1 = nil) or (Blob2 = nil) then
      Exit;
    Eye := D3ToCge(Vector3(420, -250, 0)) + Vector3(0, PlayerEyeHeight, 0);
    Game.PlayerViewDir := D3ToCge(Vector3(1, 0, 0));
    Step(0.2);

    { damage defs }
    Info := Game.DamageInfo('damage_test_gib');
    Check(Info.Found, 'damage_test_gib found');
    CheckEquals(200, Info.Damage, 'its damage');
    Check(Info.Gib, 'it gibs');
    CheckNear(60, Info.Knockback, 'its knockback');
    Info := Game.DamageInfo('damage_test_hurt');
    CheckEquals(5, Info.Damage, 'damage_test_hurt damage');
    Check(not Info.Gib, 'does not gib');
    CheckNear(20, Info.Knockback, 'knockback 20 when missing');
    Info := Game.DamageInfo('no_such_damage', 7);
    Check(not Info.Found, 'a missing def');
    CheckEquals(7, Info.Damage, 'keeps the default damage');

    { pain: a cry by the health left, the pain anim (the simple AI),
      pain_delay apart }
    Health0 := Blob1.Health;
    Game.DamageMonster(Blob1, 10, 'damage_test_hurt', D3ToCge(Vector3(1, 0, 0)));
    CheckEquals(Health0 - 10, Blob1.Health, 'blob_1 hurt by 10');
    CheckEquals('snd_pain_medium', Blob1.LastSound, 'a medium cry (health 70)');
    Check(Blob1.PainAnim, 'the pain anim plays');
    CheckEquals('pain', Blob1.Model.Instance.PlayingAnim, 'the blob''s "pain" anim');
    Blob1.LastSound := '';
    Game.DamageMonster(Blob1, 10, 'damage_test_hurt', D3ToCge(Vector3(1, 0, 0)));
    CheckEquals('', Blob1.LastSound, 'no second cry within pain_delay (0.3)');
    Step(0.5);
    Check(not Blob1.PainAnim, 'the pain anim is over');
    Check(Blob1.Model.Instance.PlayingAnim <> 'pain', 'back to the state''s anim (idle: notarget)');
    Game.DamageMonster(Blob1, 30, 'damage_test_hurt', D3ToCge(Vector3(1, 0, 0)));
    CheckEquals('snd_pain_large', Blob1.LastSound, 'a large cry (health 30)');

    { death without gibbing: snd_death, the ragdoll pushed along the hit }
    Game.DamageMonster(Blob1, 40, 'damage_test_bullet', D3ToCge(Vector3(0, 1, 0)));
    Check(Blob1.State = msDead, 'blob_1 dead (health -10, not past -20)');
    Check(not Blob1.Gibbed, 'not gibbed');
    CheckEquals('snd_death', Blob1.LastSound, 'its death sound');
    Check(Blob1.Ragdoll <> nil, 'a ragdoll');
    CheckEquals(1, Game.Kills, 'one kill');

    { gibbing: a gibbing def (or past -20): no ragdoll, gibs fly, the body
      shrivels away in a second }
    Debris0 := Game.Brass.Count;
    Game.DamageMonster(Blob2, 200, 'damage_test_gib', D3ToCge(Vector3(0, 1, 0)));
    Check(Blob2.State = msDead, 'blob_2 dead');
    Check(Blob2.Gibbed, 'gibbed');
    CheckEquals('snd_gibbed', Blob2.LastSound, 'snd_gibbed');
    Check(Blob2.Ragdoll = nil, 'no ragdoll for a gibbed body');
    CheckEquals(Debris0 + 3, Game.Brass.Count, 'its 3 def_dropGibItems fly as debris');
    for I := Debris0 to Game.Brass.Count - 1 do
      Check(Game.Brass[I].Velocity.Length > 30, 'a gib flies');
    Step(0.5);
    Check(Blob2.Model.Holder.Exists, 'the body is still there after 0.5 s');
    Check((Blob2.Model.Instance.SkinScale > 0.3) and (Blob2.Model.Instance.SkinScale < 0.7),
      Format('the body shrivelled half way (%.2f)', [Blob2.Model.Instance.SkinScale]));
    Step(0.6);
    Check(not Blob2.Model.Holder.Exists, 'the body is gone after a second');
    CheckEquals(2, Game.Kills, 'two kills');
    Step(4);
    CheckEquals(Debris0, Game.Brass.Count, 'the gibs are gone after their 4 s');

    { trigger_hurt: the player and monsters in it take its def's damage
      every "delay" }
    Hurt := nil;
    for I := 0 to Game.Triggers.Count - 1 do
      if Game.Triggers[I].Entity.Name = 'trigger_hurt_1' then
        Hurt := Game.Triggers[I];
    Check(Hurt <> nil, 'trigger_hurt_1');
    if Hurt = nil then
      Exit;
    Check(Hurt.Kind = tkHurt, 'a hurt trigger');
    CheckEquals('damage_test_hurt', Hurt.DamageDefName, 'its def_damage');
    CheckEquals(5, Hurt.Damage, 'its damage');
    Health0 := Game.Health;
    Eye := D3ToCge(Vector3(640, -260, 0)) + Vector3(0, PlayerEyeHeight, 0);
    Step(0.1);
    CheckEquals(Health0 - 5, Game.Health, 'hurt by 5 on entering');
    CheckEquals('snd_pain_small', Game.LastPlayerSound, 'with the def''s effects (a cry)');
    Step(0.3);
    CheckEquals(Health0 - 5, Game.Health, 'not again before its delay (0.5)');
    Step(0.3);
    CheckEquals(Health0 - 10, Game.Health, 'hurt again after it');
    { a monster put in it }
    Eye := D3ToCge(Vector3(420, -250, 0)) + Vector3(0, PlayerEyeHeight, 0);
    M := nil;
    for I := 0 to Game.Monsters.Count - 1 do
      if (Game.Monsters[I].State <> msDead) and (Game.Monsters[I].Actor = nil) then
        M := Game.Monsters[I];
    if M = nil then
      for I := 0 to Game.Monsters.Count - 1 do
        if Game.Monsters[I].State <> msDead then
          M := Game.Monsters[I];
    Check(M <> nil, 'a live monster');
    if M <> nil then
    begin
      Health0 := M.Health;
      M.Model.Holder.Translation := D3ToCge(Vector3(640, -260, 0));
      Step(0.6);
      Check(M.Health < Health0, Format('%s is hurt in the trigger (%d of %d)', [M.Model.Entity.Name, M.Health, Health0]));
    end;

    { the player gibbed: no body, no ragdoll, gibs }
    Game.God := False;
    Debris0 := Game.Brass.Count;
    Game.DamagePlayer(300, 'damage_test_gib', D3ToCge(Vector3(1, 0, 0)));
    Check(Game.PlayerDead, 'the player died');
    Check(Game.PlayerGibbed, 'gibbed (damage_test_gib)');
    CheckEquals('snd_gibbed', Game.LastPlayerSound, 'snd_gibbed');
    CheckEquals(Debris0 + 2, Game.Brass.Count, 'its 2 def_dropGibItems');
    Step(0.3);
    Check(Game.PlayerRagdoll = nil, 'no ragdoll');
  finally
    FreeAndNil(Game);
    FreeAndNil(World);
  end;
end;


procedure TestExactStages;
var
  App: TAppearanceNode;
  M: TD3Material;
  Ctx: TD3ExprContext;
  Parms: TD3EntityParms;
  Keys: TStringList;
  DecalSys: TD3DecalSystem;
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  Eye: TVector3;
  RemoveMe: TRemoveType;
  B: TD3BrushEntity;
  Root: TX3DRootNode;
  I, Shapes, Hidden, Before: Integer;
  D: TD3Decal;

  procedure Step(const Seconds: Single);
  var
    T: Single;
  begin
    T := 0;
    while T < Seconds - 0.001 do
    begin
      Game.Update(0.05, Eye);
      RemoveMe := rtNone;
      Map.Update(0.05, RemoveMe);
      T := T + 0.05;
    end;
  end;

  { shapes, and conditional ones (a Switch holding the shape) that are
    hidden (whichChoice -1) }
  procedure CountShapes(const Node: TX3DRootNode; out Shapes, Hidden: Integer);
  var
    I: Integer;
  begin
    Shapes := 0;
    Hidden := 0;
    for I := 0 to Node.FdChildren.Count - 1 do
      if Node.FdChildren[I] is TShapeNode then
        Inc(Shapes)
      else
      if Node.FdChildren[I] is TSwitchNode then
      begin
        Inc(Shapes);
        if TSwitchNode(Node.FdChildren[I]).WhichChoice < 0 then
          Inc(Hidden);
      end;
  end;

begin
  { the parser: polygonOffset, decalInfo }
  M := Decls.Material('textures/test/decal_hole');
  CheckNear(1, M.PolygonOffset, 'polygonOffset without a value is 1');
  CheckNear(3, M.DecalStay, 'decalInfo stay');
  CheckNear(1, M.DecalFade, 'decalInfo fade');
  CheckVec3(Vector3(1, 1, 1), M.DecalStart.XYZ, 'decalInfo start color');
  CheckNear(0, M.DecalEnd.W, 'decalInfo end alpha');
  Check(M.Translucent, 'decal is translucent');
  M := Decls.Material('textures/test/floor');
  CheckNear(0, M.PolygonOffset, 'no polygonOffset by default');
  CheckNear(-1, M.DecalStay, 'no decalInfo by default');

  { deform turbulent: a table and three expressions, whitespace separated }
  M := Decls.Material('textures/test/pool');
  CheckEquals('turbulent', M.Deform, 'pool deform');
  CheckEquals('sintable', M.DeformTable, 'pool deform table');
  Check((M.DeformParms[0] <> nil) and (M.DeformParms[1] <> nil) and (M.DeformParms[2] <> nil),
    'turbulent: range, timeOfs and domain');
  Ctx := DefaultExprContext;
  Ctx.Time := 2;
  if M.DeformParms[2] <> nil then
  begin
    CheckNear(0.04, M.DeformParms[0].Eval(Ctx), 'turbulent range');
    CheckNear(0.4, M.DeformParms[1].Eval(Ctx), 'turbulent timeOfs (time * 0.2)');
    CheckNear(0.02, M.DeformParms[2].Eval(Ctx), 'turbulent domain');
  end;
  CheckEquals('textures/test/metal_d.tga', M.DiffuseImage, 'the pool is lit');

  { deform flare <size> }
  M := Decls.Material('textures/test/flare2');
  CheckEquals('flare', M.Deform, 'flare deform');
  Check(M.DeformParms[0] <> nil, 'flare size parsed');
  if M.DeformParms[0] <> nil then
    CheckNear(24, M.DeformParms[0].Eval(Ctx), 'flare size');

  { heat haze on a lit material: not glass, drawn as an overlay }
  M := Decls.Material('textures/test/hazewall');
  Check(not M.DrawAsGlass, 'hazewall has a diffuse stage: not glass');
  CheckEquals('textures/test/haze_local.tga', M.HazeNormalMap, 'hazewall heat haze normal map');
  CheckEquals('textures/test/metal_d.tga', M.DiffuseImage, 'hazewall diffuse');

  { stage "if" conditions and vertexColor }
  M := Decls.Material('textures/test/crateglow');
  CheckEquals(1, M.OverlayCount, 'crateglow: the glow is an overlay');
  Check(BaseStageCondition(M) = nil, 'crateglow base stage: no condition');
  Check(OverlayStageCondition(M, 0) <> nil, 'crateglow glow stage: an if condition');
  Check(M.StageVertexColor, 'crateglow glow stage: vertexColor');
  if OverlayStageCondition(M, 0) <> nil then
  begin
    Ctx := DefaultExprContext;
    Ctx.Parms[7] := 0;
    CheckNear(0, OverlayStageCondition(M, 0).Eval(Ctx), 'if ( parm7 > 0 ) with parm7 0');
    Ctx.Parms[7] := 1;
    CheckNear(1, OverlayStageCondition(M, 0).Eval(Ctx), 'if ( parm7 > 0 ) with parm7 1');
  end;
  M := Decls.ParseMaterial('test/inline_if',
    '{ if ( parm5 > 0.5 )' + LineEnding + 'blend add map a.tga }' + LineEnding +
    '{ blend add map b.tga inverseVertexColor }');
  try
    Check(BaseStageCondition(M) <> nil, 'plain material: the first stage''s if');
    CheckEquals(1, Length(M.ExtraStages), 'inline_if: an extra stage');
    if Length(M.ExtraStages) = 1 then
    begin
      Check(M.ExtraStages[0].Condition = nil, 'extra stage without an if');
      Check(M.ExtraStages[0].InverseVertexColor, 'extra stage inverseVertexColor');
    end;
  finally
    M.Free;
  end;
  M := Decls.ParseMaterial('test/inline_turb', 'deform turbulent testStrobeTable 0.1 time 5' + LineEnding +
    '{ blend add map a.tga }');
  try
    CheckEquals('teststrobetable', M.DeformTable, 'turbulent table (single tokens)');
    Check(M.DeformParms[2] <> nil, 'turbulent: three single token expressions');
    if M.DeformParms[2] <> nil then
      CheckNear(5, M.DeformParms[2].Eval(Ctx), 'turbulent domain 5');
  finally
    M.Free;
  end;

  { entity parms }
  Parms := TD3EntityParms.Create;
  Keys := TStringList.Create;
  try
    CheckNear(1, Parms.Parms[0], 'default parm0 (red) is 1');
    CheckNear(1, Parms.Parms[3], 'default parm3 (alpha) is 1');
    CheckNear(0, Parms.Parms[7], 'default parm7 is 0');
    Keys.Values['_color'] := '1 0.6 0.2';
    Keys.Values['shaderParm7'] := '1';
    Keys.Values['shaderParm11'] := '2.5';
    Parms.FromKeys(Keys);
    CheckNear(0.6, Parms.Parms[1], '_color green');
    CheckNear(0.2, Parms.Parms[2], '_color blue');
    CheckNear(1, Parms.Parms[7], 'shaderParm7');
    CheckNear(2.5, Parms.Parms[11], 'shaderParm11');
  finally
    Keys.Free;
    Parms.Free;
  end;

  { the decal system }
  DecalSys := TD3DecalSystem.Create(nil);
  try
    Check(DecalSys.Add('textures/test/decal_hole', Vector3(10, 20, 0), Vector3(0, 0, 1), 8, 0), 'decal added');
    CheckEquals(1, DecalSys.Decals.Count, 'one decal');
    D := DecalSys.Decals[0];
    CheckNear(3, D.Stay, 'decal stay from decalInfo');
    CheckNear(1, D.Fade, 'decal fade from decalInfo');
    CheckNear(1, D.Color(2).W, 'opaque while staying');
    CheckNear(0.5, D.Color(3.5).W, 'half faded');
    Check(not D.Expired(3.9), 'not expired while fading');
    Check(D.Expired(4.1), 'expired after stay + fade');
    DecalSys.Update(0);
    CheckNear(8, DecalSys.Scene.BoundingBox.Size.X, 'the quad is size wide');
    CheckNear(8, DecalSys.Scene.BoundingBox.Size.Z, 'the quad is size deep');
    CheckNear(0.5, DecalSys.Scene.BoundingBox.Center.Y, 'the quad is half a unit above the surface');
    DecalSys.Update(3.5);
    CheckEquals(1, DecalSys.Decals.Count, 'still there while fading');
    DecalSys.Update(4.1);
    CheckEquals(0, DecalSys.Decals.Count, 'removed when faded');
    Check(DecalSys.Scene.BoundingBox.IsEmpty, 'nothing drawn after the removal');
    for I := 0 to MaxDecals + 9 do
      DecalSys.Add('textures/test/decal_hole', Vector3(I, 0, 0), Vector3(0, 0, 1), 4, 10);
    CheckEquals(MaxDecals, DecalSys.Decals.Count, 'at most MaxDecals: the oldest go');
    CheckNear(10, DecalSys.Decals[0].Position.X, 'the oldest decals went');
    D := DecalSys.Decals[0];
    { a material without decalInfo: Doom 3's defaults }
    Check(DecalSys.Add('textures/test/metal', Vector3(0, 0, 0), Vector3(0, 0, 1), 4, 10), 'any material decals');
    D := DecalSys.Decals[DecalSys.Decals.Count - 1];
    CheckNear(10, D.Stay, 'default stay 10 s');
    CheckNear(4, D.Fade, 'default fade 4 s');
    CheckNear(0, D.Color(30).W, 'default end color: faded to nothing');
  finally
    DecalSys.Free;
  end;

  { in the map: conditional shapes, entity parms, projectile and FX decals }
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Check(Map.LoadMap('testmap'), 'load testmap for exact stages');
    Check(ConditionalShapeCount >= 1, 'conditional shapes registered (crate_2 glow)');
    B := Map.FindBrush('crate_2');
    Check(B <> nil, 'crate_2 is a brush entity');
    if B <> nil then
    begin
      Check(B.Parms <> nil, 'crate_2 has parms');
      CheckNear(1, B.Parms.Parms[7], 'crate_2 shaderParm7 from the map');
      CheckNear(0.6, B.Parms.Parms[1], 'crate_2 _color green');
      Root := B.Scene.RootNode;
      UpdateAnimatedSurfaces(1);
      CountShapes(Root, Shapes, Hidden);
      CheckEquals(2, Shapes, 'crate_2: the lit box and its glow overlay');
      CheckEquals(0, Hidden, 'glow shown with parm7 1');
      { the conditional shape is the overlay: unlit, additive, blended }
      for I := 0 to Root.FdChildren.Count - 1 do
        if Root.FdChildren[I] is TSwitchNode then
        begin
          Check(TSwitchNode(Root.FdChildren[I]).FdChildren.Count = 1, 'the switch holds one shape');
          if TSwitchNode(Root.FdChildren[I]).FdChildren[0] is TShapeNode then
          begin
            App := TShapeNode(TSwitchNode(Root.FdChildren[I]).FdChildren[0]).Appearance;
            Check(App.Material is TUnlitMaterialNode, 'the conditional shape is the unlit overlay');
            Check(App.AlphaMode = amBlend, 'the overlay blends');
            Check((App.BlendMode <> nil) and (App.BlendMode.DestFactor = bdOne), 'the overlay adds');
          end;
        end;
      B.Parms.Parms[7] := 0;
      UpdateAnimatedSurfaces(1.1);
      CountShapes(Root, Shapes, Hidden);
      CheckEquals(1, Hidden, 'glow hidden with parm7 0 (setShaderParm)');
      B.Parms.Parms[7] := 1;
      UpdateAnimatedSurfaces(1.2);
      CountShapes(Root, Shapes, Hidden);
      CheckEquals(0, Hidden, 'glow back with parm7 1');
    end;
    B := Map.FindBrush('crate_1');
    if B <> nil then
    begin
      CountShapes(B.Scene.RootNode, Shapes, Hidden);
      CheckEquals(1, Shapes, 'crate_1 (metal): only the lit box');
    end;

    Game := TD3Game.Create(Map);
    Game.Spawn;
    Game.NoTarget := True;
    Eye := D3ToCge(Vector3(420, -250, 0)) + Vector3(0, PlayerEyeHeight, 0);
    Step(0.1);
    CheckEquals(0, Game.Decals.Decals.Count, 'no decals at the start');
    { a bullet east from room B's south: it hits the pillar at x = 480 }
    Before := Game.Projectiles.Count;
    Check(Game.SpawnProjectile('projectile_test_bullet', 'test', Eye + Vector3(60, 0, 0), Vector3(7200, 0, 0)) <> nil,
      'bullet spawned');
    Check(Game.Projectiles.Count = Before + 1, 'bullet launched');
    Step(0.3);
    CheckEquals(1, Game.Decals.Decals.Count, 'the bullet left a decal (mtr_detonate)');
    if Game.Decals.Decals.Count = 1 then
    begin
      D := Game.Decals.Decals[0];
      CheckEquals('textures/test/decal_hole', D.Material.Name, 'bullet decal material');
      CheckNear(8, D.Size, 'decal_size 8');
      { room B's south pillar (x 480..528, y -280..-232) is in the way }
      CheckNear(480, D.Position.X, 'on the pillar''s west face', 1);
      CheckNear(-1, D.Normal.X, 'the face''s normal');
      Check(Game.Decals.Scene.Parent = Map, 'the decal scene joined the map');
    end;
    { the FX's decal action: projected down onto the floor }
    Game.Activate(Game.FindEntity('fx_test_1'));
    Step(0.1);
    CheckEquals(2, Game.Decals.Decals.Count, 'the FX left a decal');
    if Game.Decals.Decals.Count = 2 then
    begin
      D := Game.Decals.Decals[1];
      CheckNear(32, D.Size, 'fx decal size');
      CheckNear(0, D.Position.Z, 'fx decal on the floor', 0.1);
      CheckNear(400, D.Position.X, 'fx decal under the fx', 0.1);
      CheckNear(1, D.Normal.Z, 'the floor''s normal');
    end;
    Step(4.5);
    CheckEquals(0, Game.Decals.Decals.Count, 'decals faded after 4 s');
  finally
    Game.Free;
    World.Free;
  end;
end;


{ Roadmap item 3's leftovers: mirrors, deform tube / expand / move /
  eyeball, bumpy reflections, vertex colors, projected decals. }
procedure TestMirrorsDeformsDecals;
var
  M: TD3Material;
  Ctx: TD3ExprContext;
  Positions, Turned: array of TVector3;
  Indexes: array of Int32;
  UVs: array of TVector2;
  Islands: TD3EyeIslands;
  EyeIdx: TInt32List;
  SM: TD3StaticModel;
  S: TD3StaticSurface;
  Inverse: Boolean;
  Colors: TColorRGBANode;
  Root: TX3DRootNode;
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  Eye: TVector3;
  RemoveMe: TRemoveType;
  I, Found, Before: Integer;
  Shape: TShapeNode;
  Tex: TRenderedTextureNode;
  Geometry: TIndexedTriangleSetNode;
  D: TD3Decal;
  B: TD3BrushEntity;
  ME: TD3ModelEntity;
  EyesBefore: Integer;
  Coord: TCoordinateNode;

  { The I-th shape of a root (looking inside a Switch); nil for other nodes. }
  function ShapeAt(const Root: TX3DRootNode; const I: Integer): TShapeNode;
  var
    N: TX3DNode;
  begin
    Result := nil;
    N := Root.FdChildren[I];
    if N is TSwitchNode then
      if TSwitchNode(N).FdChildren.Count > 0 then
        N := TSwitchNode(N).FdChildren[0];
    if N is TShapeNode then
      Result := TShapeNode(N);
  end;

  procedure Step(const Seconds: Single);
  var
    T: Single;
  begin
    T := 0;
    while T < Seconds - 0.001 do
    begin
      Game.Update(0.05, Eye);
      RemoveMe := rtNone;
      Map.Update(0.05, RemoveMe);
      T := T + 0.05;
    end;
  end;

begin
  { the parser }
  M := Decls.Material('textures/test/mirror');
  Check(M.HasMirror, 'mirrorRenderMap stage parsed');
  CheckEquals(256, M.MirrorWidth, 'mirror width');
  CheckEquals(256, M.MirrorHeight, 'mirror height');
  Check(M.MirrorBlend = bmOpaque, 'the mirror stage is opaque');
  Check(M.DrawAsGlass, 'a material of only a mirror stage is drawn by GlassAppearance');
  M := Decls.Material('textures/test/beam');
  CheckEquals('tube', M.Deform, 'deform tube parsed');
  M := Decls.Material('textures/test/expand');
  CheckEquals('expand', M.Deform, 'deform expand parsed');
  Ctx := DefaultExprContext;
  Ctx.Time := 0;
  Check(M.DeformParms[0] <> nil, 'expand amount parsed');
  if M.DeformParms[0] <> nil then
  begin
    CheckNear(2, M.DeformParms[0].Eval(Ctx), 'expand amount at time 0 (2 + 2 * sin 0)');
    Ctx.Time := 0.5;
    CheckNear(4, M.DeformParms[0].Eval(Ctx), 'expand amount at time 0.5 (sinTable 0.25 = 1)');
  end;
  M := Decls.Material('textures/test/move');
  CheckEquals('move', M.Deform, 'deform move parsed');
  Ctx.Time := 1;
  if M.DeformParms[0] <> nil then
    CheckNear(16, M.DeformParms[0].Eval(Ctx), 'move amount at time 1');
  CheckEquals('eyeball', Decls.Material('textures/test/eyeball').Deform, 'deform eyeball parsed');
  CheckEquals('eyeball', Decls.Material('models/test/blob_eye').Deform, 'the blob eye material');
  Check(ReflectionKind(Decls.Material('textures/test/shinymetal')) = ssBumpyReflection,
    'a reflection stage of a material with a bump map is perturbed by it');
  Check(ReflectionKind(Decls.Material('textures/test/glass')) = ssReflection,
    'glass without a bump map reflects plainly');
  M := Decls.Material('textures/test/sign');
  Check(StageUsesVertexColors(M, -1, Inverse) and not Inverse, 'the sign''s stage uses vertex colors');
  M := Decls.Material('models/mapobjects/test/barrel');
  Check(M.DiffuseVertexColor, 'the barrel''s diffuse stage has vertexColor');
  Check(StageUsesVertexColors(M, -1, Inverse) and not Inverse, 'the barrel''s base stage uses vertex colors');
  Check(not StageUsesVertexColors(Decls.Material('textures/test/metal'), -1, Inverse), 'metal: no vertex colors');
  M := Decls.ParseMaterial('test/inline_inv', '{ blend diffusemap map a.tga inverseVertexColor }');
  try
    Check(M.DiffuseInverseVertexColor, 'inverseVertexColor on a diffuse stage');
    Check(StageUsesVertexColors(M, -1, Inverse) and Inverse, 'inverse vertex colors reported');
  finally
    M.Free;
  end;

  { deform tube: a vertical quad 16 wide (x) and 180 high (z) at y = 0 }
  SetLength(Positions, 4);
  Positions[0] := Vector3(0, 0, 0);
  Positions[1] := Vector3(16, 0, 0);
  Positions[2] := Vector3(16, 0, 180);
  Positions[3] := Vector3(0, 0, 180);
  Indexes := [0, 2, 1, 0, 3, 2];
  SetLength(Turned, 4);
  TubePositions(Positions, Indexes, Vector3(8, -100, 90), Turned);
  { seen from the front it keeps its plane (the short edges' points swap,
    as in Doom 3: tubes are two sided) }
  CheckVectorNear(Vector3(16, 0, 0), Turned[0], 'tube from the front: first point');
  CheckVectorNear(Vector3(0, 0, 0), Turned[1], 'tube from the front: second point');
  CheckVectorNear(Vector3(0, 0, 180), Turned[2], 'tube from the front: third point');
  CheckVectorNear(Vector3(16, 0, 180), Turned[3], 'tube from the front: fourth point');
  { seen from the side (+x) it turns to the y axis, still 16 wide }
  TubePositions(Positions, Indexes, Vector3(100, 0, 90), Turned);
  CheckVectorNear(Vector3(8, 8, 0), Turned[0], 'tube from the side: first point');
  CheckVectorNear(Vector3(8, -8, 0), Turned[1], 'tube from the side: second point');
  CheckVectorNear(Vector3(8, -8, 180), Turned[2], 'tube from the side: third point');
  CheckVectorNear(Vector3(8, 8, 180), Turned[3], 'tube from the side: fourth point');

  { deform eyeball: an eye quad at y = 0 facing -y, its origin triangle 4
    behind, its focus triangle 20 in front and 6 to the right }
  SetLength(Positions, 10);
  Positions[0] := Vector3(-16, 0, -16);
  Positions[1] := Vector3(16, 0, -16);
  Positions[2] := Vector3(16, 0, 16);
  Positions[3] := Vector3(-16, 0, 16);
  Positions[4] := Vector3(-2, 4, -2);
  Positions[5] := Vector3(2, 4, -2);
  Positions[6] := Vector3(0, 4, 2);
  Positions[7] := Vector3(4, -20, -2);
  Positions[8] := Vector3(8, -20, -2);
  Positions[9] := Vector3(6, -20, 2);
  Indexes := [0, 2, 1, 0, 3, 2, 4, 6, 5, 7, 9, 8];
  Check(EyeballIslands(Indexes, 10, Islands, 'test eye'), 'the eye surface has three islands');
  if Length(Islands) = 3 then
  begin
    CheckEquals(2, Length(Islands[0].Tris), 'the eye island: two triangles');
    CheckEquals(4, Length(Islands[0].Verts), 'the eye island: four vertexes');
    EyeIdx := EyeballIndexes(Islands, Indexes);
    try
      CheckEquals(6, EyeIdx.Count, 'only the eye triangles are drawn');
      Check((EyeIdx[0] = 0) and (EyeIdx[1] = 2) and (EyeIdx[2] = 1), 'the eye triangles keep their order');
    finally
      EyeIdx.Free;
    end;
    SetLength(UVs, 10);
    for I := 0 to 9 do
      UVs[I] := Vector2(7, 7);
    EyeballTexCoords(Islands, Positions, UVs);
    { one texture unit per world unit from the origin; the pupil (s, t =
      0.5) where the origin -> focus line crosses the eye: 1 unit right of
      its center }
    CheckNear(-15.99, UVs[0].X, 'eye corner (-16, -16) s', 0.1);
    CheckNear(-15.5, UVs[0].Y, 'eye corner (-16, -16) v (1 - t)', 0.1);
    CheckNear(15.05, UVs[2].X, 'eye corner (16, 16) s', 0.1);
    CheckNear(16.5, UVs[2].Y, 'eye corner (16, 16) v', 0.1);
    CheckNear(-0.47, (UVs[0].X + UVs[1].X + UVs[2].X + UVs[3].X) / 4, 'the pupil is 1 unit right of the eye center', 0.05);
    CheckNear(7, UVs[4].X, 'the origin triangle''s texture coordinates are left alone');
  end;
  Indexes := [0, 2, 1, 0, 3, 2];
  Check(not EyeballIslands(Indexes, 4, Islands, 'test eye'), 'one island is not an eye');

  { vertex colors of static models: the barrel's RGBA map, the sign's
    ASE color vertexes }
  SM := StaticModels.Model('models/mapobjects/test/barrel.lwo');
  Check(SM <> nil, 'barrel loads');
  if SM <> nil then
  begin
    S := FindSurface(SM, 'models/mapobjects/test/barrel');
    Check((S <> nil) and S.HasColors, 'the barrel sides have vertex colors');
    if (S <> nil) and S.HasColors then
    begin
      { the side quads are written top ring first (reversed, clockwise) }
      CheckNear(1, S.Colors[0].X, 'top ring color (LWO RGBA map)');
      CheckNear(0.4, S.Colors[2].X, 'bottom ring color');
      CheckNear(1, S.Colors[0].W, 'RGBA alpha');
    end;
  end;
  SM := StaticModels.Model('models/mapobjects/test/sign.ase');
  Check(SM <> nil, 'sign.ase loads');
  if SM <> nil then
  begin
    S := FindSurface(SM, 'textures/test/sign');
    Check(S <> nil, 'the sign''s surface');
    if S <> nil then
    begin
      CheckEquals(2, S.TriangleCount, 'the sign is a quad');
      Check(S.HasColors, 'ASE color vertexes loaded');
      if S.HasColors then
      begin
        CheckVec3(Vector3(1, 0, 0), S.Colors[0].XYZ, 'bottom corner red (MESH_CFACELIST)');
        CheckVec3(Vector3(0, 1, 0), S.Colors[2].XYZ, 'top corner green');
      end;
    end;
    Root := SM.BuildNode;
    try
      Found := 0;
      for I := 0 to Root.FdChildren.Count - 1 do
      begin
        Shape := ShapeAt(Root, I);
        if (Shape <> nil) and (Shape.Geometry is TIndexedTriangleSetNode) and
           (TIndexedTriangleSetNode(Shape.Geometry).Color is TColorRGBANode) then
        begin
          Inc(Found);
          CheckEquals(6, TColorRGBANode(TIndexedTriangleSetNode(Shape.Geometry).Color).FdColor.Count,
            'a color per vertex on the sign''s shape');
          Check(TColorRGBANode(TIndexedTriangleSetNode(Shape.Geometry).Color).Mode = cmModulate,
            'vertex colors modulate the stage');
        end;
      end;
      CheckEquals(1, Found, 'the sign''s vertexColor stage got the colors');
    finally
      Root.Free;
    end;
  end;
  Colors := VertexColorNode([Vector4(1, 0, 0, 1)], True);
  try
    CheckNear(0, Colors.FdColor.Items[0].X, 'inverseVertexColor: 1 - red');
    CheckNear(1, Colors.FdColor.Items[0].Y, 'inverseVertexColor: 1 - green');
    CheckNear(0, Colors.FdColor.Items[0].W, 'inverseVertexColor: 1 - alpha');
  finally
    Colors.Free;
  end;

  { in the map }
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    EyesBefore := EyeballSurfaceCount;
    Check(Map.LoadMap('testmap'), 'load testmap for mirrors and deforms');
    CheckEquals(1, TubeSurfaceCount, 'the beam is the one tube surface');
    Check(EyeballSurfaceCount - EyesBefore >= 2, 'the wall eye and the blobs'' eyes are eyeball surfaces');
    { the mirror: a RenderedTexture with a ViewpointMirror on the mirror
      quad, with MIRROR-PLANE texture coordinates }
    Found := 0;
    if Map.AreaNonSolidScene(0) <> nil then
      for I := 0 to Map.AreaNonSolidScene(0).RootNode.FdChildren.Count - 1 do
      begin
        Shape := ShapeAt(Map.AreaNonSolidScene(0).RootNode, I);
        if (Shape = nil) or not (Shape.Appearance.Material is TUnlitMaterialNode) then
          Continue;
        if TUnlitMaterialNode(Shape.Appearance.Material).EmissiveTexture is TRenderedTextureNode then
        begin
          Inc(Found);
          Tex := TRenderedTextureNode(TUnlitMaterialNode(Shape.Appearance.Material).EmissiveTexture);
          Check(Tex.Viewpoint is TViewpointMirrorNode, 'the mirror texture renders from the mirrored camera');
          Check(Tex.Update = upAlways, 'the mirror renders every frame');
          CheckEquals(256, Tex.FdDimensions.Items[0], 'mirrorRenderMap width');
          Check((Shape.Geometry is TIndexedTriangleSetNode) and
            (TIndexedTriangleSetNode(Shape.Geometry).TexCoord is TTextureCoordinateGeneratorNode) and
            (TTextureCoordinateGeneratorNode(TIndexedTriangleSetNode(Shape.Geometry).TexCoord).Mode = 'MIRROR-PLANE'),
            'mirror plane texture coordinates');
        end;
      end;
    CheckEquals(1, Found, 'room A has one mirror');
    { the wall eye: a shape of 6 indexes over 10 vertexes, texture
      coordinates projected }
    Found := 0;
    if Map.AreaNonSolidScene(0) <> nil then
      for I := 0 to Map.AreaNonSolidScene(0).RootNode.FdChildren.Count - 1 do
      begin
        Shape := ShapeAt(Map.AreaNonSolidScene(0).RootNode, I);
        if (Shape <> nil) and (Shape.Geometry is TIndexedTriangleSetNode) then
        begin
          Geometry := TIndexedTriangleSetNode(Shape.Geometry);
          if (Geometry.FdIndex.Count = 6) and (Geometry.Coord is TCoordinateNode) and
             (TCoordinateNode(Geometry.Coord).FdPoint.Count = 10) then
          begin
            Inc(Found);
            Check(Geometry.TexCoord is TTextureCoordinateNode, 'eye texture coordinates');
            if Geometry.TexCoord is TTextureCoordinateNode then
              Check(Abs(TTextureCoordinateNode(Geometry.TexCoord).FdPoint.Items[0].X) > 5,
                'the eye''s texture coordinates are projected (one unit per world unit)');
          end;
        end;
      end;
    CheckEquals(1, Found, 'the wall eye draws its eye triangles only');
    { the bumpy reflection: an effect with the EyeWorldSpace library }
    Found := 0;
    if Map.AreaScene(0) <> nil then
      for I := 0 to Map.AreaScene(0).RootNode.FdChildren.Count - 1 do
      begin
        Shape := ShapeAt(Map.AreaScene(0).RootNode, I);
        if (Shape <> nil) and (Shape.Appearance.FdEffects.Count > 0) and
           (Shape.Appearance.FdEffects[0] is TEffectNode) and
           (TEffectNode(Shape.Appearance.FdEffects[0]).FdShaderLibraries.Count = 1) then
        begin
          Inc(Found);
          Check(Shape.Appearance.Material is TMaterialNode, 'the bumpy reflection is a lit material (for the bump map)');
          Check(Shape.Shading = shPhong, 'the bumpy reflection needs Phong shading');
        end;
      end;
    Check(Found >= 1, 'the shiny pillar''s reflection is bumpy');
    { the tube turns to the view: from room B's west the beam (x 552..568
      at y = 100) faces +x }
    UpdateViewDeforms(D3ToCge(Vector3(400, 100, 68)));
    Found := 0;
    if Map.AreaNonSolidScene(1) <> nil then
      for I := 0 to Map.AreaNonSolidScene(1).RootNode.FdChildren.Count - 1 do
      begin
        Shape := ShapeAt(Map.AreaNonSolidScene(1).RootNode, I);
        if (Shape <> nil) and (Shape.Geometry is TIndexedTriangleSetNode) and
           (TIndexedTriangleSetNode(Shape.Geometry).Coord is TCoordinateNode) then
        begin
          Coord := TCoordinateNode(TIndexedTriangleSetNode(Shape.Geometry).Coord);
          if (Coord.FdPoint.Count = 4) and (Abs(Coord.FdPoint.Items[0].X - 560) < 0.01) and
             (Abs(Coord.FdPoint.Items[0].Z + 100) < 8.01) then
          begin
            Inc(Found);
            CheckNear(8, Abs(Coord.FdPoint.Items[0].Z + 100), 'the beam turned across the view, 16 wide');
            CheckNear(8, Abs(Coord.FdPoint.Items[2].Z + 100), 'the beam''s far end too');
          end;
        end;
      end;
    CheckEquals(1, Found, 'the beam faces the camera');
    { the blob's eye follows its head: its texture coordinates are
      projected from the skinned positions }
    ME := Map.FindModelEntity('blob_1');
    Check(ME <> nil, 'blob_1 has a model');
    if ME <> nil then
    begin
      Found := 0;
      for I := 0 to ME.Instance.Scene.RootNode.FdChildren.Count - 1 do
      begin
        Shape := ShapeAt(ME.Instance.Scene.RootNode, I);
        if (Shape <> nil) and (Shape.Geometry is TIndexedTriangleSetNode) and
           (TIndexedTriangleSetNode(Shape.Geometry).FdIndex.Count = 6) then
        begin
          Inc(Found);
          Geometry := TIndexedTriangleSetNode(Shape.Geometry);
          if Geometry.TexCoord is TTextureCoordinateNode then
          begin
            CheckNear(-6.43, TTextureCoordinateNode(Geometry.TexCoord).FdPoint.Items[0].X,
              'the blob eye''s s from the origin through the focus', 0.1);
            CheckNear(-5.5, TTextureCoordinateNode(Geometry.TexCoord).FdPoint.Items[0].Y,
              'the blob eye''s v', 0.1);
          end else
            Check(False, 'the blob eye has texture coordinates');
        end;
      end;
      CheckEquals(1, Found, 'the blob draws its eye quad');
    end;

    { projected decals: onto crate_1's top (an entity scene) and across
      the south wall and the floor (the world) }
    Game := TD3Game.Create(Map);
    Game.Spawn;
    Game.NoTarget := True;
    Eye := D3ToCge(Vector3(-160, -160, 0)) + Vector3(0, PlayerEyeHeight, 0);
    Step(0.1);
    B := Map.FindBrush('crate_1');
    Check(B <> nil, 'crate_1');
    Before := 0;
    if B <> nil then
      Before := B.Scene.RootNode.FdChildren.Count;
    Game.AddDecal('textures/test/decal_hole', Vector3(128, -160, 64), Vector3(0, 0, 1), 8);
    CheckEquals(1, Game.Decals.Decals.Count, 'a decal on the crate');
    if Game.Decals.Decals.Count = 1 then
    begin
      D := Game.Decals.Decals[0];
      Check(D.Target > 0, 'the decal is on an entity scene');
      { the box across the top face's two triangles (its diagonal splits
        it): two to six triangles, nothing from the sides }
      Check((D.TriangleCount >= 2) and (D.TriangleCount <= 6),
        Format('the crate''s top face, clipped (%d triangles)', [D.TriangleCount]));
      CheckEquals(1, Game.Decals.TargetCount, 'one entity scene holds decals');
      if Length(D.Vertexes) >= 3 then
      begin
        CheckNear(32, D.Vertexes[0].Position.Y, 'the decal is in the crate''s local coordinates (its top at 32)');
        CheckNear(1, D.Vertexes[0].Fade, 'on the surface: no depth fade');
        Check((D.Vertexes[0].TexCoord.X >= -0.01) and (D.Vertexes[0].TexCoord.X <= 1.01), 'texture coordinates across the box');
      end;
    end;
    Step(0.1);
    if B <> nil then
      CheckEquals(Before + 1, B.Scene.RootNode.FdChildren.Count, 'the crate''s scene got a group of decal shapes');
    Game.AddDecal('textures/test/decal_hole', Vector3(-200, -256, 4), Vector3(0, 1, 0), 16);
    CheckEquals(2, Game.Decals.Decals.Count, 'a decal on the south wall near the floor');
    if Game.Decals.Decals.Count = 2 then
    begin
      D := Game.Decals.Decals[1];
      CheckEquals(0, D.Target, 'the wall decal is on the world');
      Check(D.TriangleCount > 2, Format('the wall and the floor both got pieces (%d triangles)', [D.TriangleCount]));
      Found := 0;
      for I := 0 to High(D.Vertexes) do
        if D.Vertexes[I].Fade < 0.99 then
          Inc(Found);
      Check(Found > 0, 'the floor piece fades with the depth');
    end;
    Step(0.1);
    Check(not Game.Decals.Scene.BoundingBox.IsEmpty, 'the world decal is drawn');
    Step(4.5);
    CheckEquals(0, Game.Decals.Decals.Count, 'the decals faded');
    CheckEquals(0, Game.Decals.TargetCount, 'the crate''s decals went with them');
  finally
    Game.Free;
    World.Free;
  end;
end;

procedure TestGuiScripts;
var
  Gui: TD3Gui;
  W, Btn, Body, Hidden: TD3GuiWindow;
  V: TVector4;
  Img: TRGBAlphaImage;
  C: TVector4;
  F: TD3Font;
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  Eye: TVector3;
  RemoveMe: TRemoveType;
  S, Panel, Status: TD3GuiSurface;
  L, Renders: Integer;

  procedure Step(const Seconds: Single);
  var
    T: Single;
  begin
    T := 0;
    while T < Seconds - 0.001 do
    begin
      Game.Update(0.05, Eye);
      RemoveMe := rtNone;
      Map.Update(0.05, RemoveMe);
      T := T + 0.05;
    end;
  end;

begin
  Gui := TD3Gui.Create;
  try
    Check(Gui.LoadFromVfs('guis/test_panel.gui'), 'load test_panel.gui for scripts');
    Check(Gui.Interactive, 'the panel has onAction windows: interactive');
    Btn := Gui.FindWindow('button');
    Body := Gui.FindWindow('body');
    Hidden := Gui.FindWindow('hidden');
    W := Gui.FindWindow('blink');
    Check((Btn <> nil) and (Body <> nil) and (Hidden <> nil) and (W <> nil), 'panel windows found');
    if (Btn = nil) or (Body = nil) or (Hidden = nil) or (W = nil) then
      Exit;
    Check(Btn.OnAction <> nil, 'button onAction parsed');
    if Btn.OnAction <> nil then
    begin
      CheckEquals(4, Btn.OnAction.Count, 'button onAction: 4 commands');
      CheckEquals('set', Btn.OnAction[0].Name, 'first command');
      CheckEquals('transition', Btn.OnAction[2].Name, 'third command');
      CheckEquals(4, Length(Btn.OnAction[2].Args), 'transition arguments');
    end;
    Check((Btn.OnMouseEnter <> nil) and (Btn.OnMouseExit <> nil), 'mouse enter / exit scripts');
    CheckEquals(3, Length(W.TimeEvents), 'blink: 3 onTime events');
    if Length(W.TimeEvents) = 3 then
    begin
      CheckEquals(500, W.TimeEvents[1].Time, 'onTime 500');
      CheckEquals('resettime', W.TimeEvents[2].Script[0].Name, 'resetTime at 1000');
    end;
    Check(Gui.FindWindow('bg').NoEvents, 'bg noevents');
    CheckEquals('fonts/test', Gui.Desktop.Font, 'desktop font');
    CheckEquals('fonts/test', Btn.FontName, 'children inherit the font');
    CheckEquals('$buttoncolor', Btn.Exprs.Values['backcolor'], 'backcolor is a variable reference');
    V := Gui.PropVec4(Btn, 'backcolor');
    CheckNear(0.3, V.Y, 'backcolor from the buttoncolor variable (definevec4)');
    CheckEquals(1, Length(Gui.Desktop.TimeEvents), 'desktop onTime 0');

    { time lines and transitions }
    Gui.SetState('gui_parm1', 'X');
    Gui.Activate(0);
    Gui.Update(0);
    Check(Gui.PropVisible(W), 'blink visible at 0 ms');
    CheckEquals(1, Gui.TransitionCount, 'the body forecolor transition started at 0 ms');
    V := Gui.PropVec4(Body, 'forecolor');
    CheckNear(0, V.X, 'transition start: black');
    Gui.Update(250);
    V := Gui.PropVec4(Body, 'forecolor');
    CheckNear(0.3, V.X, 'transition half way (linear)', 0.03);
    Gui.Update(600);
    Check(not Gui.PropVisible(W), 'blink hidden after 500 ms');
    CheckEquals(0, Gui.TransitionCount, 'transition done after 500 ms');
    V := Gui.PropVec4(Body, 'forecolor');
    CheckNear(0.6, V.X, 'transition end value kept');
    { resetTime at 1000 ms: the onTime 0 fires on the next update }
    Gui.Update(1100);
    Gui.Update(1150);
    Check(Gui.PropVisible(W), 'blink visible again after resetTime');
    Gui.Update(1600);
    Check(not Gui.PropVisible(W), 'blink keeps blinking');
    Check(Gui.Dirty, 'changes mark the GUI dirty');

    { the cursor: mouse enter / exit }
    Gui.SetCursor(320, 430);
    Check(Gui.CursorShown, 'cursor shown');
    V := Gui.PropVec4(Btn, 'backcolor');
    CheckNear(0.5, V.Y, 'onMouseEnter color');
    Gui.SetCursor(320, 200);
    V := Gui.PropVec4(Btn, 'backcolor');
    CheckNear(0.3, V.Y, 'onMouseExit restores the variable color');

    { clicks }
    Gui.SetCursor(320, 430);
    Check(Gui.Click, 'click on the button runs its onAction');
    CheckEquals('activate ; runScript test_gui_clicked', Gui.TakeCmd, 'commands for the entity');
    CheckEquals('CLICKED', Gui.StateValue('gui_clicked'), 'set "gui::gui_clicked"');
    CheckEquals('CLICKED', Gui.PropText(Gui.FindWindow('status')), 'the status text shows the state');
    CheckEquals(1, Gui.TransitionCount, 'the header transition started');
    CheckEquals('', Gui.TakeCmd, 'commands taken once');
    Gui.SetCursor(320, 200);
    Check(Gui.Click, 'a click over noevents windows reaches the desktop');
    CheckEquals('activate', Gui.TakeCmd, 'the desktop onAction');
    Gui.ClearCursor;
    Check(not Gui.Click, 'no click without the cursor');

    { expressions }
    CheckNear(1, Gui.Eval(nil, '1 + 2 * 3 == 7'), 'arithmetic and comparison');
    CheckNear(0, Gui.Eval(nil, '(1 + 2) * 3 == 7'), 'parentheses');
    Gui.SetState('x', '2');
    CheckNear(1, Gui.Eval(nil, 'gui::x > 1 && gui::x < 3'), 'gui:: variables and &&');
    CheckNear(0, Gui.Eval(nil, '!gui::x'), 'not');
    CheckNear(0.1, Gui.Eval(Btn, '$buttoncolor'), 'a vec4 variable gives its first component');
    CheckNear(0, Gui.Eval(nil, 'button::visible == 0 || gui::x == 3'), 'window properties and ||');
    Hidden.SetProp('visible', 'gui::x == 2');
    Check(Gui.PropVisible(Hidden), 'visible expression true');
    Gui.SetState('x', '5');
    Check(not Gui.PropVisible(Hidden), 'visible expression false');
    Hidden.SetProp('visible', '0');
    CheckEquals('', Hidden.Exprs.Values['visible'], 'a constant replaces the expression');

    { rendering: the cursor and the Doom 3 font }
    Gui.SetCursor(100, 100);
    Img := RenderGui(Gui, nil);
    try
      Check(not Gui.Dirty, 'rendered: clean');
      C := PixelAt(Img, 104, 113);
      Check(C.X > 0.9, Format('cursor arrow drawn (white), got %s', [C.ToString]));
      Check(BrightPixels(Img, 200, 10, 440, 100) > 50, 'header text drawn with the Doom 3 font');
      C := PixelAt(Img, 10, 5);
      Check((C.X > 0.9) and (C.Y > 0.9), Format('header flashes yellow (the click''s transition), got %s', [C.ToString]));
    finally
      Img.Free;
    end;
    Gui.ClearCursor;
    Gui.Update(1700);
    Gui.FindWindow('status').SetProp('visible', '1');
    Img := RenderGui(Gui, nil);
    try
      Check(BrightPixels(Img, 30, 440, 190, 470) > 20, 'the status text (CLICKED) drawn at textscale 0.3 (12 pt font)');
    finally
      Img.Free;
    end;
  finally
    Gui.Free;
  end;

  F := D3Font('fonts/test');
  Check(F <> nil, 'fonts/test loaded (fonts/english/test/fontImage_NN.dat)');
  if F <> nil then
  begin
    Check((F.Sizes[0] <> nil) and (F.Sizes[1] <> nil) and (F.Sizes[2] <> nil), 'three font sizes');
    CheckEquals(12, F.Sizes[0].PointSize, 'small font 12 pt');
    Check(F.SizeFor(0.25) = F.Sizes[0], 'textscale 0.25: the 12 pt font');
    Check(F.SizeFor(0.5) = F.Sizes[1], 'textscale 0.5: the 24 pt font');
    Check(F.SizeFor(1) = F.Sizes[2], 'textscale 1: the 48 pt font');
    CheckNear(1, F.Sizes[2].GlyphScale, 'glyphScale of 48 pt');
    CheckNear(4, F.Sizes[0].GlyphScale, 'glyphScale of 12 pt (48 / 12)');
    Check(F.Sizes[2].Glyphs[Ord('A')].Page <> nil, 'glyph page loaded');
    Check(F.Sizes[2].Glyphs[Ord('A')].XSkip > 20, 'glyph advance');
    Check(F.TextWidth('AREA', 1) > 80, 'text width at textscale 1');
    CheckNear(F.TextWidth('AREA', 1) * 0.5, F.TextWidth('AREA', 0.5), 'text width scales', 4);
    Check(F.LineHeight(1) > 40, 'line height');
  end;
  Check(D3Font('fonts/missing') = nil, 'a missing font: nil (CGE font fallback)');
  Check(D3Font('fonts/test') = F, 'fonts are cached');

  { in the map: live GUI surfaces, the player's focus, clicks }
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Check(Map.LoadMap('testmap'), 'load testmap for GUIs');
    CheckEquals(2, Map.GuiSurfaces.Count, 'two live GUIs: the panel and the status screen');
    Panel := nil;
    Status := nil;
    for S in Map.GuiSurfaces do
      if SameText(S.EntityName, 'panel_1') then
        Panel := S
      else
        Status := S;
    Check(Panel <> nil, 'the panel GUI surface');
    Check(Status <> nil, 'the status screen GUI surface');
    if (Panel = nil) or (Status = nil) then
      Exit;
    Check(Panel.Gui.Interactive, 'the panel is interactive');
    Check(not Status.Gui.Interactive, 'the status screen has no events');
    CheckEquals('AREA A', Panel.Gui.StateValue('gui_parm1'), 'the entity keys are the state');
    CheckEquals(1, Panel.Nodes.Count, 'one texture node shows the panel');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    Game.NoTarget := True;
    Eye := D3ToCge(Vector3(-190, -60, 0)) + Vector3(0, PlayerEyeHeight, 0);
    Game.PlayerViewDir := D3ToCge(Vector3(-1, 0, 0.21)).Normalize;
    Step(0.2);
    Check(Panel.Renders >= 1, 'the panel was redrawn (its transition)');
    Check(Panel.Url <> '', 'the panel has its own texture URL');
    Check(Game.GuiFocus = Panel, 'looking at the panel from 60 units: focus');
    if Game.GuiFocus = Panel then
    begin
      CheckNear(320, Panel.Gui.CursorX, 'cursor x at the panel center', 20);
      CheckNear(430, Panel.Gui.CursorY, 'cursor y on the button', 30);
    end;
    L := Map.FindLight('light_panel_1');
    Check(L >= 0, 'light_panel_1 exists');
    if L >= 0 then
      Check(not Map.Light(L).StartOn, 'the panel light starts off');
    { the weapon rises for a second after the spawn, then lowers for the
      focused GUI }
    Step(1.2);
    Renders := Panel.Renders;
    Game.AttackOnce;
    Step(0.3);
    CheckEquals(1, Game.GuiClicks, 'the attack button clicked the GUI');
    CheckEquals('CLICKED', Panel.Gui.StateValue('gui_clicked'), 'the button''s onAction ran');
    if L >= 0 then
      Check(Map.Light(L).StartOn, 'the GUI''s activate command switched the panel''s light on');
    Check(Panel.Renders > Renders, 'redrawn after the click');
    Check((Game.Weapon <> nil) and (Game.Weapon.Status in [wsLowering, wsHolstered]), 'the weapon lowers while a GUI has the focus');
    Game.PlayerViewDir := D3ToCge(Vector3(1, 0, 0));
    Step(0.1);
    Check(Game.GuiFocus = nil, 'looking away: no focus');
    Check(not Panel.Gui.CursorShown, 'the cursor is gone');
    Check(Map.SetGuiParm(Game.FindEntity('panel_1'), 'gui_parm1', 'HELLO') >= 1, 'setGuiParm reaches the live GUI');
    CheckEquals('HELLO', Panel.Gui.StateValue('gui_parm1'), 'the state changed');
    Check(Panel.Gui.Dirty, 'the state change redraws it');
    { the status screen in room B is out of sight: it doesn't run }
    Check(Status.Renders <= 1, 'a GUI out of sight is not redrawn');
  finally
    Game.Free;
    World.Free;
  end;
end;


procedure TestPlayerInfo;
var
  Pda: TD3PdaDecl;
  Email: TD3EmailDecl;
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  Eye: TVector3;
  RemoveMe: TRemoveType;
  B: TD3BrushEntity;
  L, Armor, Health: Integer;
  Mon: TD3Monster;
  P: TD3Projectile;

  procedure Step(const Seconds: Single);
  var
    T: Single;
  begin
    T := 0;
    while T < Seconds - 0.001 do
    begin
      Game.Update(0.05, Eye);
      RemoveMe := rtNone;
      Map.Update(0.05, RemoveMe);
      T := T + 0.05;
    end;
  end;

  procedure Activate(const AName: String);
  begin
    Check(Game.FindEntity(AName) <> nil, 'entity ' + AName + ' exists');
    if Game.FindEntity(AName) <> nil then
      Game.Activate(Game.FindEntity(AName));
  end;

begin
  { the PDA decls }
  CheckEquals(2, Decls.DeclCount(dtPda), 'pda decls (pdas/test.pda)');
  CheckEquals(4, Decls.DeclCount(dtEmail), 'email decls');
  CheckEquals(1, Decls.DeclCount(dtAudio), 'audio decls');
  CheckEquals(1, Decls.DeclCount(dtVideo), 'video decls');
  Pda := PdaDecl('pda_test_admin');
  Check(Pda <> nil, 'pda_test_admin parsed');
  if Pda <> nil then
  begin
    CheckEquals('A. Administrator', Pda.FullName, 'pda fullname');
    CheckEquals('Facilities', Pda.Post, 'pda post');
    CheckEquals('Admin', Pda.Security, 'pda security');
    CheckEquals(2, Pda.Emails.Count, 'pda emails');
    CheckEquals('test_email_pump', Pda.Emails[0], 'pda first email');
    CheckEquals(1, Pda.Audios.Count, 'pda audio logs');
    CheckEquals(1, Pda.Videos.Count, 'pda videos');
  end;
  Check(PdaDecl('PDA_TEST_ADMIN') = Pda, 'pda decls are cached, case-insensitive');
  Email := EmailDecl('test_email_welcome');
  Check(Email <> nil, 'email parsed');
  if Email <> nil then
  begin
    CheckEquals('Welcome', Email.Subject, 'email subject');
    CheckEquals('Castle Doom 3', Email.From, 'email from');
    Check(Pos('Press Tab', Email.Text) > 0, 'email text lines joined');
    Check(Pos(#10, Email.Text) > 0, 'email text newline');
  end;
  Check(AudioDecl('test_audio_log') <> nil, 'audio parsed');
  if AudioDecl('test_audio_log') <> nil then
    CheckEquals('test_hum', AudioDecl('test_audio_log').Audio, 'audio shader');
  Check((VideoDecl('test_video_intro') <> nil) and (VideoDecl('test_video_intro').VideoName = 'Intro'), 'video parsed');
  Check(PdaDecl('missing') = nil, 'missing pda');

  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Check(Map.LoadMap('testmap'), 'load testmap for player info');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    Game.NoTarget := True;
    Eye := D3ToCge(Vector3(-160, -160, 0)) + Vector3(0, PlayerEyeHeight, 0);
    Step(0.1);
    { the personal PDA from the start }
    CheckEquals(1, Game.Pdas.Count, 'the personal PDA at the start');
    CheckEquals('personal', Game.Pdas[0], 'personal PDA');

    { tips }
    Activate('target_tip_1');
    CheckEquals('TIP', Game.TipTitle, 'tip title');
    CheckEquals('Press E to use panels and doors', Game.TipText, 'tip text');
    Step(1);
    Eye := D3ToCge(Vector3(-160, 0, 0)) + Vector3(0, PlayerEyeHeight, 0);
    Step(0.1);
    CheckEquals('Press E to use panels and doors', Game.TipText, 'the tip stays in the first 2 s');
    Step(1.1);
    CheckEquals('', Game.TipText, 'the tip hides once the player walked 96 units after 2 s');

    { objectives }
    Activate('target_primaryobjective_1');
    CheckEquals('Reach room B', Game.MissionObjective, 'the mission objective');
    Activate('item_objective_1');
    CheckEquals(1, Game.ObjectiveCount, 'an objective given');
    CheckEquals('Find the keycard', Game.Objective(0).Title, 'objective title');
    Check(not Game.Objective(0).Complete, 'not complete yet');
    CheckEquals('New Objective', Game.ObjectiveNotice, 'the new objective notice');
    Activate('item_objective_1');
    CheckEquals(1, Game.ObjectiveCount, 'an objective is given once');
    Activate('item_objectivecomplete_1');
    Check(Game.Objective(0).Complete, 'objective completed');
    CheckEquals('Objective Complete', Game.ObjectiveNotice, 'the completion notice');
    CheckEquals('The locker is open.', Game.ObjectiveNoticeText, 'the completion text');
    Step(2.1);
    Eye := D3ToCge(Vector3(-160, 100, 0)) + Vector3(0, PlayerEyeHeight, 0);
    Step(0.1);
    CheckEquals('', Game.ObjectiveNotice, 'the notice hides once the player walked 64 units');

    { radio chatter: 2 s, then its target (light_trig) }
    L := Map.FindLight('light_trig');
    Check((L >= 0) and not Map.Light(L).StartOn, 'light_trig off before the chatter');
    Activate('func_radiochatter_1');
    Check(Game.RadioChatter, 'radio chatter on');
    Step(1);
    Check(Game.RadioChatter, 'radio chatter still on after 1 s');
    Step(1.2);
    Check(not Game.RadioChatter, 'radio chatter over after 2 s');
    if L >= 0 then
      Check(Map.Light(L).StartOn, 'the chatter activated its target when it ended');

    { shader parms and fades of brush entities }
    B := Map.FindBrush('crate_2');
    Check((B <> nil) and (B.Parms <> nil), 'crate_2 with parms');
    if (B <> nil) and (B.Parms <> nil) then
    begin
      CheckNear(1, B.Parms.Parms[7], 'crate_2 shaderParm7 1 at the start');
      Activate('target_setshaderparm_1');
      CheckNear(0, B.Parms.Parms[7], 'target_setshaderparm set shaderParm7 0');
      Activate('target_setshaderparm_1');
      CheckNear(1, B.Parms.Parms[7], 'toggle: the next activation sets 1');
      Activate('target_setshadertime_1');
      Check(B.Parms.Parms[4] < 0, 'target_setshadertime: parm4 is minus the time');
      CheckNear(0.6, B.Parms.Parms[1], 'crate_2 _color green at the start');
      Activate('target_fadeentity_1');
      CheckEquals(1, Game.EntityFadeCount, 'a fade started');
      Step(0.5);
      CheckNear(0.6, B.Parms.Parms[2], 'half way through the fade (blue 0.2 -> 1)', 0.1);
      Step(0.6);
      CheckNear(1, B.Parms.Parms[2], 'fade end: blue 1');
      CheckNear(0.2, B.Parms.Parms[0], 'fade end: red 0.2');
      CheckEquals(0, Game.EntityFadeCount, 'the fade is over');
    end;

    { give, remove, show, keyval }
    Armor := Game.Armor;
    Activate('target_give_1');
    Check(Game.Armor > Armor, 'target_give gave the armor');
    Check(Game.Pdas.IndexOf('pda_test_admin') < 0, 'item_pda without pda_name gives no PDA');
    Check(Game.Carried.IndexOf('PDA') >= 0, 'target_give gave the PDA item');
    B := Map.FindBrush('crate_1');
    Check((B <> nil) and not B.Hidden, 'crate_1 shown before target_remove');
    Activate('target_remove_1');
    Check((B <> nil) and B.Hidden, 'target_remove hid crate_1');
    Activate('target_show_1');
    Check((B <> nil) and not B.Hidden, 'target_show showed it again');
    Activate('target_setkeyval_1');
    CheckEquals('KEYVAL', Game.FindEntity('panel_1').Value('gui_parm1'), 'target_setkeyval set the key');
    Check(Map.GuiSurfaces.Count > 0, 'live GUIs');
    if Map.GuiSurfaces.Count > 0 then
      CheckEquals('KEYVAL', Map.GuiSurfaces[Map.GuiSurfaces.Count - 1].Gui.StateValue('gui_parm1'),
        'the panel GUI shows the new key');

    { fov }
    CheckNear(0, Game.ViewFov, 'the default fov (0)');
    Activate('target_setfov_1');
    Step(0.5);
    CheckNear(75, Game.ViewFov, 'fov half way from 90 to 60', 2);
    Step(0.6);
    CheckNear(60, Game.ViewFov, 'fov 60');
    Activate('target_setfov_2');
    Step(0.6);
    CheckNear(0, Game.ViewFov, 'back to the default');

    { damage }
    Mon := nil;
    for Mon in Game.Monsters do
      if SameText(Mon.Model.Entity.Name, 'blob_1') then
        Break;
    Check((Mon <> nil) and SameText(Mon.Model.Entity.Name, 'blob_1'), 'blob_1');
    if Mon <> nil then
    begin
      Health := Mon.Health;
      Activate('target_damage_1');
      Check(Mon.Health < Health, 'target_damage hurt blob_1');
    end;

    { emails, PDAs, the end of the level }
    Activate('target_giveemail_1');
    CheckEquals(1, Game.Emails.Count, 'target_giveemail with a PDA');
    CheckEquals('test_email_extra', Game.Emails[0], 'the email');
    Eye := D3ToCge(Vector3(-220, -120, 0)) + Vector3(0, PlayerEyeHeight, 0);
    Step(0.2);
    Check(Game.Pdas.IndexOf('pda_test_admin') >= 0, 'picking up item_pda_1 gives its pda_name');
    CheckEquals('', Game.EndLevelMap, 'no end level yet');
    Activate('target_endlevel_1');
    CheckEquals('testmap', Game.EndLevelMap, 'target_endlevel names the next map');
    L := Map.FindLight('light_1');
    Check(L >= 0, 'light_1');
    if L >= 0 then
    begin
      Activate('target_lightfadeout_1');
      Step(0.5);
      Check((Map.Light(L).Fade > 0.2) and (Map.Light(L).Fade < 0.8), 'light_1 fading out');
      Step(0.6);
      CheckNear(0, Map.Light(L).Fade, 'light_1 faded out', 0.05);
      Activate('target_lightfadein_1');
      Step(1.1);
      CheckNear(1, Map.Light(L).Fade, 'light_1 faded back in', 0.05);
    end;

    { the thrown weapon: createProjectile holds the grenade until a throw }
    Check(Game.Give('weapon', 'weapon_test_grenade'), 'the grenade weapon given');
    Check(Game.Give('ammo_test_grenades', '3'), 'grenades given');
    Game.SelectWeapon(3);
    Step(1.5);
    Check((Game.Weapon <> nil) and (Game.Weapon.DefName = 'weapon_test_grenade'), 'the grenade weapon raised');
    if (Game.Weapon <> nil) and (Game.Weapon.DefName = 'weapon_test_grenade') then
    begin
      Check(Game.Weapon.HeldProjectile <> nil, 'createProjectile holds a grenade');
      P := Game.Weapon.HeldProjectile;
      if P <> nil then
      begin
        Check(P.HeldByWeapon = Game.Weapon, 'held by the weapon');
        CheckNear(0, P.Velocity.Length, 'the held grenade does not move');
      end;
      Game.AttackOnce;
      Step(0.3);
      Check((P <> nil) and (P.HeldByWeapon = nil) and (P.Velocity.Length > 100), 'launchProjectiles threw the held grenade');
      Check(Game.Weapon.HeldProjectile = nil, 'nothing held right after the throw');
      Step(0.6);
      Check(Game.Weapon.HeldProjectile <> nil, 'the next grenade is held once idle again');
      { the switch drops the held grenade }
      Game.SelectWeapon(1);
      Step(1.5);
      Check((Game.Weapon <> nil) and (Game.Weapon.DefName = 'weapon_test_pistol'), 'back to the pistol');
    end;
  finally
    Game.Free;
    World.Free;
  end;
end;

procedure TestParticles;
var
  Decl: TD3ParticleDecl;
  S: TD3ParticleStage;
  Fx: TD3FxDecl;
  Em: TD3ParticleEmitter;
  Holder: TCastleTransform;
  Box: TBox3D;
  Axis: TD3Axis;
begin
  CheckEquals(7, Decls.DeclCount(dtParticle), 'particle decls indexed (particles/*.prt)');
  CheckEquals(1, Decls.DeclCount(dtFx), 'fx decls indexed (fx/*.fx)');

  { the steam vent: two stages }
  Decl := ParticleDecl('test_steam.prt');
  Check(Decl <> nil, 'test_steam.prt found (the extension is stripped)');
  if Decl = nil then
    Exit;
  Check(Decl = ParticleDecl('test_steam'), 'the same decl without the extension (cached)');
  CheckEquals(2, Decl.Stages.Count, 'test_steam: 2 stages');
  S := Decl.Stages[0];
  CheckEquals(20, S.Count, 'stage 0 count');
  CheckEquals('textures/particles/test_smoke', S.Material, 'stage 0 material');
  CheckNear(1.5, S.Time, 'stage 0 time');
  CheckEquals(0, S.Cycles, 'stage 0 cycles (forever)');
  Check(S.Distribution = pdCylinder, 'stage 0 cylinder distribution');
  CheckNear(4, S.DistParms[0], 'cylinder size x');
  CheckNear(0, S.DistParms[2], 'cylinder size z');
  Check(S.Direction = pdirCone, 'stage 0 cone direction');
  CheckNear(20, S.DirParm, 'cone angle');
  Check(S.Orientation = poView, 'stage 0 view oriented');
  CheckNear(50, S.Speed.From, 'speed from');
  CheckNear(20, S.Speed.To_, 'speed to');
  CheckNear(6, S.Size.From, 'size from');
  CheckNear(16, S.Size.To_, 'size to');
  CheckNear(30, S.Rotation.From, 'rotation from');
  CheckNear(-12, S.Gravity, 'gravity (negative: rising)');
  Check(not S.WorldGravity, 'local gravity');
  CheckNear(0.2, S.FadeIn, 'fadeIn');
  CheckNear(0.5, S.FadeOut, 'fadeOut');
  CheckNear(0.85, S.Color.Y, 'color green');
  CheckNear(0.6, S.Color.W, 'color alpha');
  CheckNear(2, S.Offset.Z, 'offset z');
  S := Decl.Stages[1];
  Check(S.Orientation = poAimed, 'stage 1 aimed');
  CheckNear(1, S.OrientParms[0], 'aimed trails');
  CheckNear(0.1, S.OrientParms[1], 'aimed trail time');
  Check(S.WorldGravity, 'stage 1 world gravity');
  CheckNear(200, S.Gravity, 'stage 1 gravity');
  CheckNear(1.5, S.Size.From, 'a plain size ("1.5"): from = to');
  CheckNear(1.5, S.Size.To_, 'a plain size: to');

  Decl := ParticleDecl('test_ring');
  Check(Decl <> nil, 'test_ring found');
  if Decl <> nil then
  begin
    S := Decl.Stages[0];
    Check(S.Orientation = poZ, 'test_ring: z oriented');
    CheckEquals(4, S.AnimationFrames, 'animationFrames');
    CheckNear(8, S.AnimationRate, 'animationRate');
    CheckNear(90, S.InitialAngle, 'initialAngle');
    CheckNear(0, S.Bunching, 'bunching 0');
  end;
  Check(ParticleDecl('no_such.prt') = nil, 'a missing particle decl is nil');

  { the FX }
  Fx := FxDecl('fx/test_blast');
  Check(Fx <> nil, 'fx/test_blast found');
  if Fx <> nil then
  begin
    CheckEquals(5, Fx.Actions.Count, 'fx: 5 actions');
    Check(Fx.Actions[0].Kind = fxLight, 'action 0: a light');
    CheckNear(1.2, Fx.Actions[0].Duration, 'light duration');
    CheckNear(0.7, Fx.Actions[0].LightColor.Y, 'light color');
    CheckNear(200, Fx.Actions[0].LightRadius, 'light radius');
    CheckNear(0.8, Fx.Actions[0].FadeOut, 'light fadeOut');
    Check(Fx.Actions[1].Kind = fxParticle, 'action 1: a particle');
    CheckEquals('test_explosion.prt', Fx.Actions[1].Data, 'the particle');
    Check(Fx.Actions[2].Kind = fxSound, 'action 2: a sound');
    CheckNear(0.05, Fx.Actions[2].Delay, 'sound delay');
    Check(Fx.Actions[3].Kind = fxModel, 'action 3: a particle model');
    CheckNear(0.3, Fx.Actions[3].Delay, 'model delay');
    CheckNear(2, Fx.Actions[3].Duration, 'model duration');
    CheckNear(8, Fx.Actions[3].Offset.Z, 'model offset');
  end;

  { evaluation: a stage made here, one particle at a time }
  Holder := TCastleTransform.Create(nil);
  try
    Decl := TD3ParticleDecl.Create;
    try
      Decl.Parse('{ count 1 time 1 cycles 1 bunching 0 distribution rect 0 0 0 ' +
        'direction cone 0 speed "100" size "2" fadeIn 0 fadeOut 0 gravity 0 orientation z ' +
        'initialAngle 90 material "textures/particles/test_spark" }');
      CheckEquals(1, Decl.Stages.Count, 'parsed stage');
      Em := TD3ParticleEmitter.Create(Decl, 0);
      try
        Holder.Add(Em.Scene);
        Em.Origin := Vector3(100, 200, 0);
        Axis := IdentityAxis;
        Em.Axis := Axis;
        { age 0.5: the integrated speed is 100 * 0.5 along +z (Doom 3 up) }
        Em.Update(0.5, Axis);
        CheckEquals(1, Em.Live, 'one particle alive at 0.5 s');
        Box := Em.Scene.BoundingBox;
        CheckNear(100, Box.Center.X, 'particle x (the emitter origin)');
        CheckNear(-200, Box.Center.Z, 'particle z (CGE: minus Doom 3 y)');
        CheckNear(50, Box.Center.Y, 'particle height (speed * age)');
        CheckNear(4, Box.Size.X, 'a z-oriented quad 2 * size wide');
        CheckNear(0, Box.Size.Y, 'and flat');
        Em.Update(1.5, Axis);
        CheckEquals(0, Em.Live, 'dead after its time (one cycle)');
        Check(Em.Finished(1.5), 'finished');
        Check(not Em.Finished(0.5), 'not finished while alive');
      finally
        Em.Free;
      end;
      { gravity: z -= g * age * age }
      Decl.Parse('{ count 1 time 1 cycles 0 bunching 0 distribution rect 0 0 0 ' +
        'direction cone 0 speed "0" size "1" fadeIn 0 fadeOut 0 gravity 100 orientation view ' +
        'material "textures/particles/test_spark" }');
      Em := TD3ParticleEmitter.Create(Decl, 0);
      try
        Holder.Add(Em.Scene);
        Em.Update(0.5, Axis);
        CheckNear(-25, Em.Scene.BoundingBox.Center.Y, 'fallen by gravity * age^2');
        { cycles 0: alive again in the next cycle }
        Em.Update(2.25, Axis);
        CheckEquals(1, Em.Live, 'alive in the third cycle');
        CheckNear(-6.25, Em.Scene.BoundingBox.Center.Y, 'the cycle restarts the fall');
        Check(not Em.Finished(100), 'never finished (cycles 0)');
        Em.OneShot := True;
        Em.Update(2.25, Axis);
        CheckEquals(0, Em.Live, 'a one-shot plays one cycle');
        Check(Em.Finished(2.25), 'and is finished after it');
      finally
        Em.Free;
      end;
      { a trail: particles stay where the emitter was when they spawned }
      Decl.Parse('{ count 10 time 1 cycles 0 bunching 1 distribution rect 0 0 0 ' +
        'direction cone 0 speed "0" size "1" fadeIn 0 fadeOut 0 gravity 0 orientation view ' +
        'material "textures/particles/test_spark" }');
      Em := TD3ParticleEmitter.Create(Decl, 0);
      try
        Holder.Add(Em.Scene);
        Em.Origin := Vector3(0, 0, 0);
        Em.Update(0.25, Axis);
        CheckEquals(3, Em.Live, 'bunching: 3 of 10 spawned in the first quarter');
        Em.Origin := Vector3(500, 0, 0);
        Em.Update(0.55, Axis);
        CheckEquals(6, Em.Live, '6 spawned after half the time');
        Box := Em.Scene.BoundingBox;
        { view-oriented quads (the view along +x) have no x extent }
        CheckNear(0, Box.Data[0].X, 'the first particles stayed at the old origin');
        CheckNear(500, Box.Data[1].X, 'the new ones are at the new origin');
        Em.Stopped := True;
        Em.Update(1.5, Axis);
        CheckEquals(0, Em.Live, 'stopped: the old particles died, no new ones');
        Check(Em.Finished(1.5), 'a stopped emitter with no particles is finished');
      finally
        Em.Free;
      end;
      { entity color and fades }
      Decl.Parse('{ count 1 time 1 cycles 0 bunching 0 distribution rect 0 0 0 direction cone 0 ' +
        'speed "0" size "1" fadeIn 0.5 fadeOut 0 entityColor 1 orientation view ' +
        'material "textures/particles/test_spark" }');
      Em := TD3ParticleEmitter.Create(Decl, 0);
      try
        Holder.Add(Em.Scene);
        Em.Update(0.0, Axis);
        CheckEquals(0, Em.Live, 'fully faded (fadeIn, frac 0): not drawn');
        Em.Update(0.25, Axis);
        CheckEquals(1, Em.Live, 'half faded in: drawn');
        SkipParticles := True;
        Em.Update(0.25, Axis);
        CheckEquals(0, Em.Live, 'r_skipParticles: nothing');
        Check(not Em.Scene.Exists, 'the scene hidden');
        SkipParticles := False;
        Em.Enabled := False;
        Em.Update(0.25, Axis);
        CheckEquals(0, Em.Live, 'disabled: nothing');
        Em.Enabled := True;
        Em.Update(0.25, Axis);
        CheckEquals(1, Em.Live, 'enabled again');
      finally
        Em.Free;
      end;
    finally
      Decl.Free;
    end;
  finally
    Holder.Free;
  end;
end;

procedure TestParticleEntities;
var
  World: TCastleRootTransform;
  Map: TDoom3Map;
  Game: TD3Game;
  Eye: TVector3;
  RemoveMe: TRemoveType;
  Steam, Ring: TD3EmitterEntity;
  FxEntity: TD3MapEntity;
  Em: TD3ParticleEmitter;
  I, Trails, Wounds: Integer;
  M: TD3Monster;
  A: TD3Actor;

  procedure Step(const Seconds: Single);
  var
    T: Single;
  begin
    T := 0;
    while T < Seconds - 0.001 do
    begin
      Game.Update(0.05, Eye);
      RemoveMe := rtNone;
      Map.Update(0.05, RemoveMe);
      T := T + 0.05;
    end;
  end;

  function EmitterNamed(const Part: String): TD3ParticleEmitter;
  begin
    for Result in Game.Emitters do
      if Pos(Part, Result.Name) > 0 then
        Exit;
    Result := nil;
  end;

begin
  World := TCastleRootTransform.Create(nil);
  Map := TDoom3Map.Create(World);
  World.Add(Map);
  Game := nil;
  try
    Check(Map.LoadMap('testmap'), 'load testmap for particles');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    Game.NoTarget := True;
    for A in Game.Actors do
      A.Thinking := False;
    for M in Game.Monsters do
      M.Dormant := True;
    Eye := D3ToCge(Vector3(420, -250, 0)) + Vector3(0, PlayerEyeHeight, 0);
    Game.PlayerViewDir := D3ToCge(Vector3(1, 0, 0));

    CheckEquals(2, Game.EmitterEntities.Count, 'two emitter entities (func_emitter with .prt models)');
    if Game.EmitterEntities.Count <> 2 then
      Exit;
    Steam := Game.EmitterEntities[0];
    Ring := Game.EmitterEntities[1];
    CheckEquals('emitter_steam_1', Steam.Entity.Name, 'the steam vent');
    CheckEquals('emitter_ring_1', Ring.Entity.Name, 'the ring');
    Check(Steam.On, 'the steam is on');
    Check(not Ring.On, 'the ring is start_off');
    Check(Steam.Emitter.Persistent, 'entity emitters are kept');
    CheckVectorNear(Vector3(-180, -20, 4), Steam.Emitter.Origin, 'the steam at its entity origin (Doom 3)');
    Check(Steam.Emitter.Scene.Parent = Map, 'the emitter scene is in the map');
    Step(1);
    Check(Steam.Emitter.Live > 0, Format('steam particles alive (%d)', [Steam.Emitter.Live]));
    CheckEquals(0, Ring.Emitter.Live, 'no ring particles while off');
    { activation toggles it (idFuncEmitter) }
    Game.Activate(Ring.Entity);
    Check(Ring.On, 'activated: on');
    Step(0.5);
    CheckEquals(1, Ring.Emitter.Live, 'the ring (count 1) shows');
    CheckNear(560, Ring.Emitter.Scene.BoundingBox.Center.X, 'the ring over its entity');
    Game.Activate(Ring.Entity);
    Check(not Ring.On, 'activated again: off');
    Step(0.1);
    CheckEquals(0, Ring.Emitter.Live, 'and gone');

    { the FX entity }
    FxEntity := nil;
    for I := 0 to Map.MapFile.Entities.Count - 1 do
      if Map.MapFile.Entities[I].Name = 'fx_test_1' then
        FxEntity := Map.MapFile.Entities[I];
    Check(FxEntity <> nil, 'fx_test_1 exists');
    if FxEntity = nil then
      Exit;
    CheckEquals(0, Game.Fx.Count, 'no fx playing at first');
    Game.Activate(FxEntity);
    CheckEquals(1, Game.Fx.Count, 'activating func_fx plays its fx');
    Step(0.1);
    Check(Game.Fx[0].Actions[0].Started, 'the light action started');
    Check(Game.Fx[0].Actions[0].Light <> nil, 'a light in the map');
    Check(Game.Fx[0].Actions[0].Light.Parent = Map, 'added to the map');
    CheckVectorNear(D3ToCge(Vector3(400, -60, 40)), Game.Fx[0].Actions[0].Light.Translation, 'at the entity');
    Check(Game.Fx[0].Actions[0].Light.Intensity > 0.9, 'faded in (fadeIn 0.05)');
    Check(EmitterNamed('fx/test_blast') <> nil, 'the explosion particles emitted');
    Check(not Game.Fx[0].Actions[3].Started, 'the steam model waits for its delay (0.3)');
    Step(0.3);
    Check(Game.Fx[0].Actions[3].Started, 'the steam model started');
    Check(Game.Fx[0].Actions[3].Emitter <> nil, 'as an emitter');
    Check(not Game.Fx[0].Actions[3].Emitter.OneShot, 'that repeats for its duration');
    Step(0.5);
    Check(Game.Fx[0].Actions[0].Light.Intensity < 0.9, Format('the light fades out over its last 0.8 s (%.2f)',
      [Game.Fx[0].Actions[0].Light.Intensity]));
    Step(0.5);
    Check(Game.Fx[0].Actions[0].Done, 'the light action is done after 1.2 s');
    Check(Game.Fx[0].Actions[0].Light = nil, 'the light removed');
    Step(1.2);
    CheckEquals(0, Game.Fx.Count, 'the fx is over after its last action (0.3 + 2 s)');
    Check(EmitterNamed('fx/test_blast') = nil, 'its emitters are gone');

    { the pistol's muzzle smoke }
    Step(0.6);
    Check((Game.Weapon <> nil) and (Game.Weapon.Status = wsReady), 'the pistol is ready');
    Check(EmitterNamed('smoke_muzzle') = nil, 'no muzzle smoke before a shot');
    Game.AttackOnce;
    Step(0.2);
    Em := EmitterNamed('smoke_muzzle');
    Check(Em <> nil, 'a shot emits smoke_muzzle');
    if Em <> nil then
    begin
      Check(Em.OneShot, 'a one-shot smoke');
      Check(Em.Live > 0, 'with particles');
      Check((Em.Origin - Vector3(420, -250, PlayerEyeHeight)).Length < 60, 'near the muzzle');
    end;
    { the bullet hit the east wall: sparks (smoke_detonate) }
    Check(EmitterNamed('smoke_detonate') <> nil, 'the bullet''s smoke_detonate on the wall');
    Step(1.5);
    Check(EmitterNamed('smoke_muzzle') = nil, 'the smoke is freed when done');

    { a monster's projectile trails smoke_fly: a fresh game, the player
      on room B's floor below blob_scripted_1's balcony (like TestProjectiles) }
    FreeAndNil(Game);
    FreeAndNil(World);
    World := TCastleRootTransform.Create(nil);
    Map := TDoom3Map.Create(World);
    World.Add(Map);
    Check(Map.LoadMap('testmap'), 'load testmap again');
    Game := TD3Game.Create(Map);
    Game.Spawn;
    for M in Game.Monsters do
      if M.Actor = nil then
        M.Dormant := True;
    Eye := D3ToCge(Vector3(560, 300, 0)) + Vector3(0, PlayerEyeHeight, 0);
    Trails := 0;
    Wounds := 0;
    for I := 1 to 40 do
    begin
      Game.Update(0.1, Eye);
      RemoveMe := rtNone;
      Map.Update(0.1, RemoveMe);
      if EmitterNamed('smoke_fly') <> nil then
        Inc(Trails);
      if EmitterNamed('smoke_wound_flesh') <> nil then
        Inc(Wounds);
    end;
    Check(Game.ProjectilesLaunched > 0, 'a projectile was thrown');
    Check(Trails > 0, 'a thrown ball trails smoke_fly particles');
    Check(Game.Health < 100, 'the ball hit the player');
    Check(Wounds > 0, 'the hit emitted the player''s smoke_wound_flesh (a short one-shot)');
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
  TestSharedLightEffects;
  TestMaterialStages;
  TestGuis;
  TestShadowCasters;
  TestShadowLights;
  TestTriggers;
  TestEfx;
  TestMovers;
  TestScriptVM;
  TestMapScripts;
  TestCinematics;
  TestActors;
  TestScriptedMonster;
  TestProjectiles;
  TestSplashDamage;
  TestRangedAttacks;
  TestFlying;
  TestDodgesAndCombatNodes;
  TestFlyingRouteAndThrows;
  TestCharacterAnimMove;
  TestItems;
  TestWeapons;
  TestWeaponPresentation;
  TestPlayerMotion;
  TestDamageFeedback;
  TestPowerups;
  TestStaminaSkinsKnockback;
  TestCrouchAndDeath;
  TestBrassAndRagdoll;
  TestArticulatedFigures;
  TestMonsterRagdoll;
  TestAas;
  TestAasChase;
  TestEnvProbes;
  TestParticles;
  TestParticleEntities;
  TestDamageEffects;
  TestExactStages;
  TestMirrorsDeformsDecals;
  TestGuiScripts;
  TestPlayerInfo;
  Writeln(Format('%d passed, %d failed', [Passed, Failed]));
  if Failed > 0 then
    Halt(1);
end.
