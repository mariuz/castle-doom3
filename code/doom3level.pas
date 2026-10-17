{ TDoom3Map: a Doom 3 level as a regular Castle Game Engine component.

  Set MapName (e.g. "testmap", "game/mars_city1") and it loads
  maps/<name>.proc (render geometry) and maps/<name>.map (entities) from the
  Doom 3 virtual file system and builds:

  - World: one TCastleScene with a shape per area and material, collidable,
    plus WorldNonSolid for "nonsolid" materials;
  - every map light as an X3D point / spot light with a radius (so CGE only
    applies it to shapes it reaches), global, lighting all scenes;
  - one TCastleScene per brush entity (func_static, func_door...), placed at
    the entity origin and rotation;
  - an animated TD3Md5Instance for entities whose entityDef / model decl
    names an md5mesh (monsters, characters, func_animate).

  Registered with RegisterSerializableComponent and listed in editor_units,
  so the CGE editor shows Doom 3 levels in the design. }
unit Doom3Level;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleVectors, CastleTransform, CastleScene, CastleClassUtils, CastleBoxes, X3DNodes,
  CastleCameras, Doom3Scene,
  Doom3Proc, Doom3MapFile, Doom3Md5, Doom3Collision, Doom3Portals, Doom3Decls, Doom3Expressions,
  Doom3LightEffects;

type
  { A brush entity (its .proc model) or a static model entity (.lwo / .ase)
    as a scene. Both can be movers (func_door, func_rotating...). }
  TCastleStringArray6 = array [0..5] of String;

  TD3BrushEntity = class
    Entity: TD3MapEntity;
    Scene: TCastleScene;
    { Model bounds in the entity's local Doom 3 coordinates. }
    LocalMin, LocalMax: TVector3;
    { Areas the entity's bounding box touches (empty: always drawn). }
    Areas: TD3IntArray;
    { "hide": not shown (nor colliding) until activated }
    Hidden: Boolean;
    procedure SetHidden(const Value: Boolean);
    destructor Destroy; override;
  end;

  { An entity drawn with an animated md5 model. }
  TD3ModelEntity = class
    Entity: TD3MapEntity;
    Holder: TCastleTransform;
    Instance: TD3Md5Instance;
    EntityDef: TStringList; { owned by Decls, may be nil }
    { "hide": built but not shown until triggered (idAI / idAnimated) }
    Hidden: Boolean;
    { "def_head": the head, a separate md5 model following the body's
      "head_joint" (idActor::SetupHead) }
    HeadInstance: TD3Md5Instance;
    HeadHolder: TCastleTransform;
    HeadJoint: String;
    { The body's model decl offset (the scene's translation). }
    Offset: TVector3;
    { Place the head at its joint. }
    procedure UpdateHead;
    destructor Destroy; override;
  end;

  TD3LightInfo = record
    Entity: TD3MapEntity;
    Node: TAbstractPunctualLightNode;
    BaseColor: TVector3;
    { Doom 3 light radius (the light box), CGE location }
    Radius: Single;
    Location: TVector3;
    StartOn: Boolean;
    { Areas the light reaches (empty: always on) }
    Areas: TD3IntArray;
    { The light shader (nil: Doom 3's default, "colored") and the
      entity's shader parameters (parm0..2 = _color, parm3 = 1...) }
    Shader: TD3Material;
    Parms: TD3ExprContext;
    { The shader's color changes with time }
    Animated: Boolean;
    { Current color (after the shader) }
    Color: TVector3;
    { The light volume (Doom3LightEffects), also when LightVolumes is off }
    Matrix: TMatrix4;
    Projected: Boolean;
    Shape: TD3LightShape;
    { Area of the light's origin (-1 outside: lights often sit inside
      their fixture; then the first area of Areas) }
    OriginArea: Integer;
    { Bounding box of the light volume (Doom 3 coordinates) }
    VolumeMin, VolumeMax: TVector3;
    { "noshadows": never the shadow casting light }
    NoShadows: Boolean;
    { Color scale of idLight::FadeIn / FadeOut (1 = full). }
    Fade: Single;
  end;

  TDoom3Map = class(TCastleTransform)
  strict private
    FMapName: String;
    FSpawnModels: Boolean;
    FLightScale: Single;
    FProc: TD3ProcFile;
    FMapFile: TD3MapFile;
    FLightScene, FWorldCollision: TCastleScene;
    FAreaScenes, FAreaNonSolid: array of TCastleScene;
    { shadow casting brushes (.cm) per area; the last one has brushes
      outside all areas }
    FCasterScenes: array of TCastleScene;
    FCasterBrushCount: Integer;
    { Per light: the scene casting its precomputed shadow volume
      (shadowModel "_prelight_<light>"), built when the light first casts;
      FPrelightState 0 = not looked up yet, 1 = built, 2 = none. }
    FPrelightScenes: array of TCastleScene;
    FPrelightState: array of Byte;
    FPortals: TD3PortalVisibility;
    FPortalCulling: Boolean;
    FTime: Single;
    FShadows: Boolean;
    FShadowLight: Integer;
    FPrelightShadows: Boolean;
    FSkyMaterial: String;
    FCollision: TD3CollisionFile;
    FUseCollisionModel: Boolean;
    FBrushes: specialize TObjectList<TD3BrushEntity>;
    FModels: specialize TObjectList<TD3ModelEntity>;
    FHeadCount: Integer;
    FGuiTextures: TX3DNodeList;
    FLights: array of TD3LightInfo;
    FSpawnOrigin: TVector3;
    FSpawnAngle: Single;
    FStaticModelCount: Integer;
    procedure CollectGuiTexture(Node: TX3DNode);
    procedure SetShadowLight(const I: Integer);
    procedure ApplyLightColor(const I: Integer; const C: TVector3);
    function LightShaderColor(const I: Integer): TVector3;
    function PrelightScene(const I: Integer): TCastleScene;
    procedure SetMapName(const Value: String);
    procedure SetSpawnModels(const Value: Boolean);
    function GetAreaCount: Integer;
    function GetEntityCount: Integer;
    function GetTriangleCount: Integer;
    function GetLightCount: Integer;
    procedure ClearMap;
    procedure Rebuild;
    procedure BuildWorld;
    procedure BuildCollision(const Base: String);
    procedure BuildShadowCasters(const WorldModel: TD3CollisionModel);
    procedure BuildLights(const Root: TX3DRootNode);
    procedure BuildBrushEntities;
    procedure BuildModelEntities;
    procedure BuildHead(const ME: TD3ModelEntity; const HeadDefName, JointName: String);
    procedure BuildStaticModelEntities;
  protected
    procedure Loaded; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function PropertySections(const PropertyName: String): TPropertySections; override;

    { Make sure the file system, protocols and declarations are ready (also
      in the editor, where GameInitialize didn't run). }
    class procedure EnsureData;

    { (Re)load a map. False if it couldn't be loaded. }
    function LoadMap(const AMapName: String): Boolean;
    { Path without extension ("maps/testmap") of a map name. }
    class function MapBasePath(const AMapName: String): String;
    { Is there maps/<name>.proc in the loaded data? }
    class function MapExists(const AMapName: String): Boolean;

    { Shapes of a .proc model as an X3D group, Doom 3 coordinates converted.
      Solid / non-solid surfaces go to separate groups (either may be nil). }
    class procedure BuildProcModel(const Model: TD3ProcModel;
      const SolidGroup, NonSolidGroup: TAbstractGroupingNode;
      const Entity: TD3MapEntity = nil);

    procedure Update(const SecondsPassed: Single; var RemoveMe: TRemoveType); override;

    property Proc: TD3ProcFile read FProc;
    property MapFile: TD3MapFile read FMapFile;
    { The scene holding all map lights (global lights). }
    property LightScene: TCastleScene read FLightScene;
    { Number of .cm brushes casting shadows (walls, pillars...). }
    property CasterBrushCount: Integer read FCasterBrushCount;
    { The solid / non-solid render scene of an area (may be nil). }
    function AreaScene(const I: Integer): TCastleScene;
    function AreaNonSolidScene(const I: Integer): TCastleScene;
    { Portal visibility of the loaded map, nil when no map is loaded. }
    property Portals: TD3PortalVisibility read FPortals;
    { Show only the areas, entities and lights visible from the camera
      through the portals (call every frame). Everything is shown when
      PortalCulling is off or the camera is outside the map. }
    procedure UpdateVisibility(const Camera: TCastleCamera);
    { Pick the light casting shadow volumes: the strongest light at a point
      (the player), with some hysteresis. Called by UpdateVisibility. }
    procedure UpdateShadowLight(const P: TVector3);
    { The first sky material (cameraCubeMap / cubeMap stage) of the map's
      areas, '' when none. }
    property SkyMaterial: String read FSkyMaterial;
    { The six skybox image URLs of SkyMaterial, CGE background order:
      +X, -X, +Y (up), -Y, +Z, -Z. False when there's no sky or an image is
      missing. }
    function SkyboxUrls(out Urls: TCastleStringArray6): Boolean;
    { Index of the light casting shadows, -1 when none. }
    property ShadowLight: Integer read FShadowLight;
    { The light's strength (0..1, times its color) at a CGE point. }
    function LightStrengthAt(const I: Integer; const P: TVector3): Single;
    function VisibleAreaCount: Integer;
    { The .cm collision model, nil when the map has none (or
      UseCollisionModel is off): then the render geometry collides. }
    property Collision: TD3CollisionFile read FCollision;
    property WorldCollision: TCastleScene read FWorldCollision;
    property Brushes: specialize TObjectList<TD3BrushEntity> read FBrushes;
    property Models: specialize TObjectList<TD3ModelEntity> read FModels;
    { Player start in CGE coordinates (feet) and Doom 3 yaw. }
    property SpawnOrigin: TVector3 read FSpawnOrigin;
    property SpawnAngle: Single read FSpawnAngle;
    function Light(const I: Integer): TD3LightInfo;
    { Index of the light entity with this name, -1 if none. }
    function FindLight(const AName: String): Integer;
    { Switch a light on or off (like idLight::On / Off); portal visibility
      still turns it off in hidden areas. }
    procedure SetLightOn(const I: Integer; const Value: Boolean);
    { Set a light's shader parameter (0..2 are its color), like
      idLight::SetShaderParm / SetColor. }
    procedure SetLightParm(const I, Parm: Integer; const Value: Single);
    { Scale a light's color (0..1), for fading lights in and out. }
    procedure SetLightFade(const I: Integer; const Value: Single);
    { Set a GUI parameter of an entity (a "gui_parm1"... key, which its
      GUIs show) and redraw its GUI screens (idEntity::Event_SetGuiParm).
      Returns the number of screens redrawn. }
    function SetGuiParm(const E: TD3MapEntity; const Key, Value: String): Integer;
    { The brush entity or static model with this entity name, nil if none. }
    function FindBrush(const AName: String): TD3BrushEntity;
    { The md5 model entity with this entity name, nil if none. }
    function FindModelEntity(const AName: String): TD3ModelEntity;
    { Seconds since the map was loaded (the "time" of material
      expressions). }
    property Time: Single read FTime;
    { Doom 3's skill level (g_skill): 0 easy, 1 medium, 2 hard, 3 nightmare. }
    class var Skill: Integer;
    { Not spawned at the current skill (idGameLocal::InhibitEntitySpawn:
      "not_easy", "not_medium", "not_hard"; nightmare counts as hard). }
    class function EntityInhibited(const E: TD3MapEntity): Boolean;
    { Area of a CGE point, -1 outside. }
    function AreaAt(const P: TVector3): Integer;
  published
    { Map name: "testmap" means maps/testmap.proc and maps/testmap.map. }
    property MapName: String read FMapName write SetMapName;
    { Create animated md5 models for monsters, characters and func_animate. }
    property SpawnModels: Boolean read FSpawnModels write SetSpawnModels default True;
    { Collide with the map's .cm collision model (with Doom 3's invisible
      clip brushes) instead of the render geometry, when the map has one. }
    property UseCollisionModel: Boolean read FUseCollisionModel write FUseCollisionModel default True;
    { Shadow volumes from the strongest light at the player (CGE renders
      stencil shadow volumes for one light; the viewport's ShadowVolumes
      must be on too). }
    property Shadows: Boolean read FShadows write FShadows default True;
    { Lights with a precomputed shadow volume in the .proc file
      (shadowModel "_prelight_<light>") also cast it, with the other casters.
      Console r_prelightShadows. }
    property PrelightShadows: Boolean read FPrelightShadows write FPrelightShadows default True;
    { Draw only what is visible through the portals (UpdateVisibility). }
    property PortalCulling: Boolean read FPortalCulling write FPortalCulling default True;
    { Multiplies all light intensities. }
    property LightScale: Single read FLightScale write FLightScale {$ifdef FPC}default 1{$endif};
    { Read-only information, visible in the editor's inspector. }
    property AreaCount: Integer read GetAreaCount;
    property EntityCount: Integer read GetEntityCount;
    property TriangleCount: Integer read GetTriangleCount;
    property LightCount: Integer read GetLightCount;
    property StaticModelCount: Integer read FStaticModelCount;
  end;

const
  DefaultTestPk4 = 'castle-data:/base/castle_doom3_test.pk4';

{ Rotate a CGE-space vector by a Doom 3 entity rotation matrix. }
function D3RotateCge(const M: TMatrix3; const V: TVector3): TVector3;

{ Orient a transform by a Doom 3 rotation matrix (idMat3). Respects the
  transform's Orientation: CGE's default otUpYDirectionZ points
  Direction along local +Z. }
var
  { Billboards built for "deform sprite" materials (scenes holding them
    process events). }
  SpriteCount: Integer;
  { Overlay stage shapes and glass stand-ins built (for the log). }
  OverlayShapeCount, GlassCount: Integer;
  { Glass surfaces with heat haze, reflection overlays and glass
    reflections built (for the log). }
  HazeCount, ReflectionCount: Integer;

procedure SetD3Rotation(const T: TCastleTransform; const M: TMatrix3);

implementation

uses
  Math,
  CastleComponentSerialize, CastleLog, CastleUtils, CastleStringUtils, CastleUriUtils,
  CastleRenderOptions, CastleFrustum,
  Doom3Files, Doom3Images, Doom3Materials, Doom3StaticModels, Doom3Gui;

function D3RotateCge(const M: TMatrix3; const V: TVector3): TVector3;
var
  U, W: TVector3;
begin
  U := CgeToD3(V);
  { idMat3 rows are the rotated local axes: world = u.x*row0 + u.y*row1 + u.z*row2 }
  W := Vector3(
    U.X * M.Data[0, 0] + U.Y * M.Data[1, 0] + U.Z * M.Data[2, 0],
    U.X * M.Data[0, 1] + U.Y * M.Data[1, 1] + U.Z * M.Data[2, 1],
    U.X * M.Data[0, 2] + U.Y * M.Data[1, 2] + U.Z * M.Data[2, 2]);
  Result := D3ToCge(W);
end;

procedure SetD3Rotation(const T: TCastleTransform; const M: TMatrix3);
var
  LocalDirection: TVector3;
begin
  if T.Orientation = otUpYDirectionMinusZ then
    LocalDirection := Vector3(0, 0, -1)
  else
    LocalDirection := Vector3(0, 0, 1);
  T.SetView(D3RotateCge(M, LocalDirection), D3RotateCge(M, Vector3(0, 1, 0)));
end;

{ TD3BrushEntity }

procedure TD3BrushEntity.SetHidden(const Value: Boolean);
begin
  Hidden := Value;
  { Exists (not Visible, which portal visibility sets) also stops collisions }
  Scene.Exists := not Value;
end;

destructor TD3BrushEntity.Destroy;
begin
  FreeAndNil(Scene);
  inherited Destroy;
end;

{ TD3ModelEntity }

procedure TD3ModelEntity.UpdateHead;
var
  M: TMatrix4;
  T, Scale: TVector3;
  R: TVector4;
begin
  if (HeadInstance = nil) or not Instance.JointTransform(HeadJoint, M) then
    Exit;
  MatrixDecompose(TranslationMatrix(D3ToCge(Offset)) * M, T, R, Scale);
  HeadHolder.Translation := T;
  HeadHolder.Rotation := R;
end;

destructor TD3ModelEntity.Destroy;
begin
  if HeadInstance <> nil then
  begin
    HeadHolder.Remove(HeadInstance.Scene);
    FreeAndNil(HeadInstance);
  end;
  { the instance owns its scene; detach it before the holder goes }
  if (Instance <> nil) and (Holder <> nil) then
    Holder.Remove(Instance.Scene);
  FreeAndNil(Instance);
  FreeAndNil(Holder);
  inherited Destroy;
end;

{ TDoom3Map }

constructor TDoom3Map.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FSpawnModels := True;
  FUseCollisionModel := True;
  FPortalCulling := True;
  FShadows := True;
  FPrelightShadows := True;
  FShadowLight := -1;
  FLightScale := 1;
  FBrushes := specialize TObjectList<TD3BrushEntity>.Create(True);
  FModels := specialize TObjectList<TD3ModelEntity>.Create(True);
end;

destructor TDoom3Map.Destroy;
begin
  ClearMap;
  FreeAndNil(FBrushes);
  FreeAndNil(FModels);
  inherited Destroy;
end;

function TDoom3Map.PropertySections(const PropertyName: String): TPropertySections;
begin
  if ArrayContainsString(PropertyName, ['MapName', 'SpawnModels', 'LightScale',
    'AreaCount', 'EntityCount', 'TriangleCount', 'LightCount', 'StaticModelCount', 'UseCollisionModel',
    'PortalCulling', 'Shadows']) then
    Result := [psBasic]
  else
    Result := inherited PropertySections(PropertyName);
end;

class procedure TDoom3Map.EnsureData;
begin
  D3Fs.RegisterProtocol;
  RegisterImageProtocol;
  if (D3Fs.SourceCount = 0) and UriFileExists(DefaultTestPk4) then
    D3Fs.AddPk4(DefaultTestPk4);
  if not Decls.Loaded then
    Decls.LoadAll;
end;

procedure TDoom3Map.ClearMap;
var
  I: Integer;
begin
  FTime := 0;
  FSkyMaterial := '';
  ClearAnimatedSurfaces;
  FShadowLight := -1;
  FStaticModelCount := 0;
  FModels.Clear;
  FHeadCount := 0;
  FBrushes.Clear;
  FLights := nil;
  for I := 0 to High(FAreaScenes) do
  begin
    FreeAndNil(FAreaScenes[I]);
    FreeAndNil(FAreaNonSolid[I]);
  end;
  FAreaScenes := nil;
  FAreaNonSolid := nil;
  for I := 0 to High(FCasterScenes) do
    FreeAndNil(FCasterScenes[I]);
  FCasterScenes := nil;
  for I := 0 to High(FPrelightScenes) do
    FreeAndNil(FPrelightScenes[I]);
  FPrelightScenes := nil;
  FPrelightState := nil;
  FCasterBrushCount := 0;
  FreeAndNil(FLightScene);
  FreeAndNil(FPortals);
  FreeAndNil(FWorldCollision);
  FreeAndNil(FCollision);
  FreeAndNil(FProc);
  FreeAndNil(FMapFile);
end;

{ Shape of an indexed triangle set, Doom 3 winding. }
function ProcShape(const Coords, Normals: array of TVector3; const UVs: array of TVector2;
  const Indexes: array of Int32; const Solid: Boolean; const App: TAppearanceNode): TShapeNode;
var
  CoordNode: TCoordinateNode;
  NormalNode: TNormalNode;
  TexCoordNode: TTextureCoordinateNode;
  Geometry: TIndexedTriangleSetNode;
begin
  CoordNode := TCoordinateNode.Create;
  CoordNode.SetPoint(Coords);
  NormalNode := TNormalNode.Create;
  NormalNode.SetVector(Normals);
  TexCoordNode := TTextureCoordinateNode.Create;
  TexCoordNode.SetPoint(UVs);
  Geometry := TIndexedTriangleSetNode.Create;
  Geometry.Coord := CoordNode;
  Geometry.Normal := NormalNode;
  Geometry.TexCoord := TexCoordNode;
  Geometry.SetIndex(Indexes);
  { Doom 3 triangles are clockwise seen from the front (like Quake) }
  Geometry.Ccw := False;
  Geometry.Solid := Solid;
  Result := TShapeNode.Create;
  Result.Geometry := Geometry;
  Result.Appearance := App;
end;

{ "deform sprite": every 4 vertexes are a quad, drawn as a camera facing
  billboard of the same size at its center. }
procedure AddSprites(const Surf: TD3ProcSurface; const Group: TAbstractGroupingNode);
var
  Q, K: Integer;
  Center: TVector3;
  R: Single;
  Transform: TTransformNode;
  Billboard: TBillboardNode;
  Coord: TCoordinateNode;
  TexCoord: TTextureCoordinateNode;
  Quad: TIndexedFaceSetNode;
  Shape: TShapeNode;
begin
  for Q := 0 to Length(Surf.Vertexes) div 4 - 1 do
  begin
    Center := TVector3.Zero;
    for K := 0 to 3 do
      Center := Center + D3ToCge(Surf.Vertexes[Q * 4 + K].Position);
    Center := Center / 4;
    R := PointsDistance(D3ToCge(Surf.Vertexes[Q * 4].Position), Center) * 0.7071;
    Coord := TCoordinateNode.Create;
    Coord.SetPoint([Vector3(-R, -R, 0), Vector3(R, -R, 0), Vector3(R, R, 0), Vector3(-R, R, 0)]);
    TexCoord := TTextureCoordinateNode.Create;
    TexCoord.SetPoint([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]);
    Quad := TIndexedFaceSetNode.Create;
    Quad.Coord := Coord;
    Quad.TexCoord := TexCoord;
    Quad.SetCoordIndex([0, 1, 2, 3]);
    Quad.Solid := False;
    Shape := TShapeNode.Create;
    Shape.Geometry := Quad;
    Shape.Appearance := MaterialAppearance(Surf.Material);
    Shape.Appearance.ShadowCaster := False;
    { axis (0, 0, 0): local +Z always points at the viewer }
    Billboard := TBillboardNode.Create;
    Billboard.AxisOfRotation := TVector3.Zero;
    Billboard.AddChildren(Shape);
    Transform := TTransformNode.Create;
    Transform.Translation := Center;
    Transform.AddChildren(Billboard);
    Group.AddChildren(Transform);
    Inc(SpriteCount);
  end;
end;

class procedure TDoom3Map.BuildProcModel(const Model: TD3ProcModel;
  const SolidGroup, NonSolidGroup: TAbstractGroupingNode;
  const Entity: TD3MapEntity);
var
  Surf: TD3ProcSurface;
  M: TD3Material;
  Coords, Normals: array of TVector3;
  UVs: array of TVector2;
  I, J: Integer;
  Group: TAbstractGroupingNode;
  GuiUrl: String;
  App: TAppearanceNode;
  Kind: TD3SpecialShape;
  Shape: TShapeNode;
begin
  for Surf in Model.Surfaces do
  begin
    if (Length(Surf.Indexes) < 3) or (Length(Surf.Vertexes) = 0) then
      Continue;
    M := Decls.Material(Surf.Material);
    GuiUrl := '';
    if M.GuiSurf <> '' then
    begin
      { a GUI screen: the entity's gui key (guisurf entity) or a path }
      if Entity <> nil then
        GuiUrl := GuiSurfaceUrl(M.GuiSurf, Entity.Pairs)
      else
        GuiUrl := GuiSurfaceUrl(M.GuiSurf, nil);
    end;
    if M.IsInvisible and (GuiUrl = '') and not M.DrawAsGlass then
      Continue;
    if M.NonSolid or M.Translucent or M.DrawAsGlass or (M.Deform = 'sprite') or
       (M.StageImage <> '') and (M.DiffuseImage = '') then
      Group := NonSolidGroup
    else
      Group := SolidGroup;
    if Group = nil then
      Continue;
    if M.Deform = 'sprite' then
    begin
      AddSprites(Surf, Group);
      Continue;
    end;
    SetLength(Coords, Length(Surf.Vertexes));
    SetLength(Normals, Length(Surf.Vertexes));
    SetLength(UVs, Length(Surf.Vertexes));
    for I := 0 to High(Surf.Vertexes) do
    begin
      Coords[I] := D3ToCge(Surf.Vertexes[I].Position);
      Normals[I] := D3ToCge(Surf.Vertexes[I].Normal);
      { CGE images are bottom-to-top, Doom 3 t goes down the image }
      UVs[I] := Vector2(Surf.Vertexes[I].ST.X, 1 - Surf.Vertexes[I].ST.Y);
    end;
    Kind := ssNone;
    if GuiUrl <> '' then
      App := GuiAppearance(GuiUrl)
    else
    if M.DrawAsGlass then
    begin
      App := GlassAppearance(Surf.Material, Kind);
      Inc(GlassCount);
      if Kind = ssHaze then
        Inc(HazeCount)
      else
      if Kind = ssReflection then
        Inc(ReflectionCount);
    end
    else
      App := MaterialAppearance(Surf.Material);
    Shape := ProcShape(Coords, Normals, UVs, Surf.Indexes, not M.TwoSided, App);
    SetupSpecialShape(Shape, Kind);
    Group.AddChildren(Shape);

    { more stages: the same triangles, with a "lequal" depth test
      (OverlayAppearance) }
    if (GuiUrl = '') and not M.DrawAsGlass then
      for J := 0 to M.OverlayCount - 1 do
      begin
        Group.AddChildren(ProcShape(Coords, Normals, UVs, Surf.Indexes,
          not M.TwoSided, OverlayAppearance(Surf.Material, J)));
        Inc(OverlayShapeCount);
      end;

    { a cube map reflection stage over a lit or plain surface }
    if (GuiUrl = '') and not M.DrawAsGlass and (M.ReflectCubeMap <> '') then
    begin
      App := ReflectionAppearance(Surf.Material);
      if App <> nil then
      begin
        Shape := ProcShape(Coords, Normals, UVs, Surf.Indexes, not M.TwoSided, App);
        SetupSpecialShape(Shape, ssReflection);
        Group.AddChildren(Shape);
        Inc(ReflectionCount);
      end;
    end;
  end;
end;

{ Rotate a Doom 3 vector by an entity rotation (rows: the rotated axes). }
function RotateD3(const M: TMatrix3; const V: TVector3): TVector3;
begin
  Result := Vector3(
    V.X * M.Data[0, 0] + V.Y * M.Data[1, 0] + V.Z * M.Data[2, 0],
    V.X * M.Data[0, 1] + V.Y * M.Data[1, 1] + V.Z * M.Data[2, 1],
    V.X * M.Data[0, 2] + V.Y * M.Data[1, 2] + V.Z * M.Data[2, 2]);
end;

{ Bounding box of a light volume in Doom 3 coordinates: the rotated
  light_radius box around the light center, or the pyramid of a
  projected light (origin, target +- right +- up). }
procedure LightVolumeBox(const Origin: TVector3; const Rot: TMatrix3; const Projected: Boolean;
  const LightCenter, LightRadius, Target, Up, Right: TVector3; out BoxMin, BoxMax: TVector3);
var
  Corners: array [0..4] of TVector3;
  Half, C: TVector3;
  I, J: Integer;
begin
  if Projected then
  begin
    Corners[0] := Origin;
    for I := 0 to 3 do
      Corners[I + 1] := Origin + RotateD3(Rot,
        Target + Right * (2 * (I and 1) - 1) + Up * (2 * ((I shr 1) and 1) - 1));
    BoxMin := Corners[0];
    BoxMax := Corners[0];
    for I := 1 to 4 do
      for J := 0 to 2 do
      begin
        BoxMin.Data[J] := Min(BoxMin.Data[J], Corners[I].Data[J]);
        BoxMax.Data[J] := Max(BoxMax.Data[J], Corners[I].Data[J]);
      end;
  end else
  begin
    C := Origin + RotateD3(Rot, LightCenter);
    for J := 0 to 2 do
      Half.Data[J] :=
        Abs(Rot.Data[0, J]) * LightRadius.X +
        Abs(Rot.Data[1, J]) * LightRadius.Y +
        Abs(Rot.Data[2, J]) * LightRadius.Z;
    BoxMin := C - Half;
    BoxMax := C + Half;
  end;
end;

procedure TDoom3Map.BuildLights(const Root: TX3DRootNode);
var
  E: TD3MapEntity;
  LightRadius, LightCenter, LightColor, TargetVec, UpVec, RightVec, LightDir: TVector3;
  Rot: TMatrix3;
  R: Single;
  Point: TPointLightNode;
  Spot: TSpotLightNode;
  Node: TAbstractPunctualLightNode;
  Shader: TD3Material;
  N, I: Integer;
  Projected: Boolean;
  LightMatrix: TMatrix4;
  ProjectionImage: String;
begin
  N := 0;
  for E in FMapFile.Entities do
  begin
    if not SameText(E.ClassName_, 'light') then
      Continue;
    Shader := nil;
    if E.Value('texture') <> '' then
      Shader := Decls.Material(E.Value('texture'));
    if (Shader <> nil) and (Shader.IsFogLight or Shader.IsBlendLight) then
      Continue;
    LightColor := E.VectorValue('_color', Vector3(1, 1, 1));
    Rot := E.Rotation;
    Projected := E.HasKey('light_target');
    { Doom 3's default light shaders, when the game data has them }
    if (Shader = nil) and Projected and Decls.HasDecl(dtMaterial, 'lights/defaultprojectedlight') then
      Shader := Decls.Material('lights/defaultprojectedlight');
    if (Shader = nil) and not Projected and Decls.HasDecl(dtMaterial, 'lights/defaultpointlight') then
      Shader := Decls.Material('lights/defaultpointlight');
    LightCenter := E.VectorValue('light_center', TVector3.Zero);
    if Projected then
    begin
      TargetVec := E.VectorValue('light_target', Vector3(0, 0, -256));
      UpVec := E.VectorValue('light_up', Vector3(0, 0, 0));
      RightVec := E.VectorValue('light_right', Vector3(0, 0, 0));
      R := TargetVec.Length + Max(UpVec.Length, RightVec.Length);
    end else
    begin
      LightRadius := E.VectorValue('light_radius', Vector3(0, 0, 0));
      if LightRadius.IsZero then
      begin
        R := E.FloatValue('light', 300);
        LightRadius := Vector3(R, R, R);
      end;
      R := Max(LightRadius.X, Max(LightRadius.Y, LightRadius.Z));
    end;

    if Projected then
      LightMatrix := ProjectedLightMatrix(E.Origin, Rot, TargetVec, UpVec, RightVec,
        E.VectorValue('light_start', TVector3.Zero), E.VectorValue('light_end', TargetVec),
        E.HasKey('light_start') or E.HasKey('light_end'))
    else
      LightMatrix := PointLightMatrix(E.Origin, Rot, LightRadius);
    ProjectionImage := '';
    if Shader <> nil then
      ProjectionImage := Shader.StageImage;

    if LightVolumes then
    begin
      { Doom 3's light volume as a shader effect (Doom3LightEffects): a
        point light without attenuation; its radius only bounds which
        shapes CGE gives the light to (the box's corner / the frustum) }
      Point := TPointLightNode.Create;
      Point.Attenuation := Vector3(1, 0, 0);
      if Projected then
      begin
        Point.Location := D3ToCge(E.Origin);
        Point.Radius := R * 1.2;
      end else
      begin
        Point.Location := D3ToCge(E.Origin) + D3RotateCge(Rot, D3ToCge(LightCenter));
        Point.Radius := LightRadius.Length + LightCenter.Length + 1;
      end;
      Point.SetEffects([CreateLightEffect(N, LightMatrix, ProjectionImage, Projected)]);
      Node := Point;
    end else
    if Projected then
    begin
      { a spot light along light_target }
      Spot := TSpotLightNode.Create;
      Spot.Location := D3ToCge(E.Origin);
      LightDir := D3RotateCge(Rot, D3ToCge(TargetVec));
      if LightDir.IsZero then
        LightDir := Vector3(0, -1, 0);
      Spot.Direction := LightDir.Normalize;
      Spot.CutOffAngle := Min(Pi / 2 - 0.01,
        ArcTan2(Max(UpVec.Length, RightVec.Length), Max(1, TargetVec.Length)) * 1.2);
      Spot.BeamWidth := Spot.CutOffAngle * 0.7;
      Spot.Radius := TargetVec.Length * 1.5;
      Spot.Attenuation := Vector3(1, 0, 4 / Sqr(Max(1, Spot.Radius)));
      Node := Spot;
    end else
    begin
      Point := TPointLightNode.Create;
      Point.Location := D3ToCge(E.Origin) + D3RotateCge(Rot, D3ToCge(LightCenter));
      { spheres: the radius is twice the box and the quadratic attenuation
        is 1/3 at the box and 1/33 where CGE cuts the light off }
      Point.Radius := 2 * R;
      Point.Attenuation := Vector3(1, 0, 8 / Sqr(Max(1, R)));
      Node := Point;
    end;
    Node.Global := True;
    Node.Shadows := False;
    if (Shader <> nil) and Shader.IsAmbientLight then
    begin
      Node.Intensity := 0;
      Node.AmbientIntensity := 1;
    end else
    begin
      Node.Intensity := 1.5 * FLightScale;
      Node.AmbientIntensity := 0;
    end;
    Node.IsOn := not E.BoolValue('start_off');
    Root.AddChildren(Node);
    SetLength(FLights, N + 1);
    FLights[N].Entity := E;
    FLights[N].Node := Node;
    FLights[N].BaseColor := LightColor;
    FLights[N].Radius := R;
    FLights[N].StartOn := Node.IsOn;
    if Node is TPointLightNode then
      FLights[N].Location := TPointLightNode(Node).Location
    else
      FLights[N].Location := TSpotLightNode(Node).Location;
    FLights[N].Areas := nil;
    LightVolumeBox(E.Origin, Rot, Projected, LightCenter, LightRadius, TargetVec, UpVec, RightVec,
      FLights[N].VolumeMin, FLights[N].VolumeMax);
    { shader parameters: _color, shaderParm0..11 }
    FLights[N].Parms := DefaultExprContext;
    FLights[N].Fade := 1;
    FLights[N].Parms.Parms[0] := LightColor.X;
    FLights[N].Parms.Parms[1] := LightColor.Y;
    FLights[N].Parms.Parms[2] := LightColor.Z;
    for I := 0 to 11 do
      if E.HasKey('shaderParm' + IntToStr(I)) then
        FLights[N].Parms.Parms[I] := E.FloatValue('shaderParm' + IntToStr(I));
    { an undeclared light shader behaves like the default "colored" one }
    if (Shader <> nil) and not Shader.Defined then
      Shader := nil;
    FLights[N].Shader := Shader;
    FLights[N].Matrix := LightMatrix;
    FLights[N].Projected := Projected;
    FLights[N].Shape := ProjectionShape(ProjectionImage);
    FLights[N].NoShadows := E.BoolValue('noshadows') or
      ((Shader <> nil) and Shader.NoShadows);
    FLights[N].Animated := (Shader <> nil) and Shader.StageColorAnimated;
    ApplyLightColor(N, LightShaderColor(N));
    Inc(N);
  end;
end;

function TDoom3Map.LightShaderColor(const I: Integer): TVector3;
var
  Ctx: TD3ExprContext;
  C: TVector4;
begin
  if FLights[I].Shader = nil then
    Exit(Vector3(FLights[I].Parms.Parms[0], FLights[I].Parms.Parms[1], FLights[I].Parms.Parms[2]) *
      FLights[I].Fade);
  Ctx := FLights[I].Parms;
  { shaderParm4 is Doom 3's time offset (SHADERPARM_TIMEOFFSET) }
  Ctx.Time := FTime - FLights[I].Parms.Parms[4];
  C := FLights[I].Shader.EvalStageColor(Ctx);
  Result := Vector3(Max(0, C.X), Max(0, C.Y), Max(0, C.Z)) * FLights[I].Fade;
end;

procedure TDoom3Map.ApplyLightColor(const I: Integer; const C: TVector3);
var
  M, Base: Single;
  Node: TAbstractPunctualLightNode;
begin
  FLights[I].Color := C;
  Node := FLights[I].Node;
  { X3D colors are 0..1: brighter colors raise the intensity }
  M := Max(1, Max(C.X, Max(C.Y, C.Z)));
  Node.Color := C / M;
  if (FLights[I].Shader <> nil) and FLights[I].Shader.IsAmbientLight then
  begin
    Node.Intensity := 0;
    Node.AmbientIntensity := M;
  end else
  begin
    Base := 1.5 * FLightScale;
    Node.Intensity := Base * M;
    Node.AmbientIntensity := 0;
  end;
end;

procedure TDoom3Map.BuildWorld;
var
  Root, RootNonSolid, LightRoot: TX3DRootNode;
  I, Area: Integer;
  M: TD3ProcModel;
  Surf: TD3ProcSurface;
  Sprites, J: Integer;
  BspAreas: TD3AreaList;
begin
  { one solid and one non-solid scene per area, so portal visibility can
    hide areas; shapes stay per material inside them }
  SetLength(FAreaScenes, FProc.NumAreas);
  SetLength(FAreaNonSolid, FProc.NumAreas);
  for I := 0 to FProc.ModelCount - 1 do
  begin
    M := FProc.Model(I);
    Area := M.AreaIndex;
    if (Area < 0) or (Area >= FProc.NumAreas) then
      Continue;
    Root := TX3DRootNode.Create;
    RootNonSolid := TX3DRootNode.Create;
    Sprites := SpriteCount;
    BuildProcModel(M, Root, RootNonSolid);
    if FSkyMaterial = '' then
      for Surf in M.Surfaces do
        if Decls.Material(Surf.Material).SkyCubeMap <> '' then
        begin
          FSkyMaterial := Surf.Material;
          Break;
        end;
    AddLightLibrary(Root);
    AddLightLibrary(RootNonSolid);

    FAreaScenes[Area] := TD3Scene.Create(nil);
    FAreaScenes[Area].SetTransient;
    FAreaScenes[Area].Name := 'Area' + IntToStr(Area);
    FAreaScenes[Area].Load(Root, True);
    FAreaScenes[Area].PreciseCollisions := True;
    FAreaScenes[Area].RenderOptions.MaxLightsPerShape := 32;
    { area geometry isn't closed (and is big): it receives shadows only }
    FAreaScenes[Area].CastShadows := False;
    Add(FAreaScenes[Area]);

    FAreaNonSolid[Area] := TD3Scene.Create(nil);
    FAreaNonSolid[Area].SetTransient;
    FAreaNonSolid[Area].Name := 'AreaNonSolid' + IntToStr(Area);
    FAreaNonSolid[Area].Load(RootNonSolid, True);
    FAreaNonSolid[Area].Collides := False;
    FAreaNonSolid[Area].Pickable := False;
    FAreaNonSolid[Area].RenderOptions.MaxLightsPerShape := 32;
    FAreaNonSolid[Area].CastShadows := False;
    { billboards turn to the camera only when the scene processes events }
    FAreaNonSolid[Area].ProcessEvents := SpriteCount <> Sprites;
    Add(FAreaNonSolid[Area]);
  end;

  LightRoot := TX3DRootNode.Create;
  BuildLights(LightRoot);
  FLightScene := TD3Scene.Create(nil);
  FLightScene.SetTransient;
  FLightScene.Name := 'Lights';
  FLightScene.Load(LightRoot, True);
  FLightScene.CastGlobalLights := True;
  FLightScene.Collides := False;
  FLightScene.Pickable := False;
  FLightScene.CastShadows := False;
  Add(FLightScene);

  FPortals := TD3PortalVisibility.Create(FProc);
  for I := 0 to High(FLights) do
  begin
    { like Doom 3, a light belongs to all areas its volume touches (its
      origin is often inside the fixture, outside any area) }
    BspAreas := FProc.BoxAreas(FLights[I].VolumeMin, FLights[I].VolumeMax);
    SetLength(FLights[I].Areas, Length(BspAreas));
    for J := 0 to High(BspAreas) do
      FLights[I].Areas[J] := BspAreas[J];
    FLights[I].OriginArea := AreaAt(FLights[I].Location);
    if (FLights[I].OriginArea < 0) and (Length(FLights[I].Areas) > 0) then
      FLights[I].OriginArea := FLights[I].Areas[0];
  end;
end;

function TDoom3Map.SkyboxUrls(out Urls: TCastleStringArray6): Boolean;
const
  { Doom 3 cameraCubeMap suffixes for CGE's +X, -X, +Y, -Y, +Z, -Z:
    Doom 3 +X is CGE +X, Doom 3 +Z (up) is CGE +Y, Doom 3 +Y (left) is
    CGE -Z. CGE's background draws TexturePositiveZ ("front") at -Z. }
  CameraSuffixes: array [0..5] of String = ('_forward', '_back', '_up', '_down', '_left', '_right');
  CubeSuffixes: array [0..5] of String = ('_px', '_nx', '_pz', '_nz', '_py', '_ny');
var
  M: TD3Material;
  I: Integer;
  F: String;
begin
  Result := False;
  if FSkyMaterial = '' then
    Exit;
  M := Decls.Material(FSkyMaterial);
  for I := 0 to 5 do
  begin
    if M.SkyCameraCubeMap then
      F := FindImageFile(M.SkyCubeMap + CameraSuffixes[I])
    else
      F := FindImageFile(M.SkyCubeMap + CubeSuffixes[I]);
    if F = '' then
      Exit;
    Urls[I] := D3FsUrl(F);
  end;
  Result := True;
end;

function TDoom3Map.AreaScene(const I: Integer): TCastleScene;
begin
  if (I >= 0) and (I <= High(FAreaScenes)) then
    Result := FAreaScenes[I]
  else
    Result := nil;
end;

function TDoom3Map.AreaNonSolidScene(const I: Integer): TCastleScene;
begin
  if (I >= 0) and (I <= High(FAreaNonSolid)) then
    Result := FAreaNonSolid[I]
  else
    Result := nil;
end;

function TDoom3Map.VisibleAreaCount: Integer;
begin
  if FPortals <> nil then
    Result := FPortals.VisibleCount
  else
    Result := 0;
end;

{ Areas a world-space box touches: its corners and center. }
function BoxAreas(const Map: TDoom3Map; const Box: TBox3D): TD3IntArray;
var
  I, A, K, P2, Side: Integer;
  D3Min, D3Max, C0, C1: TVector3;
  BspAreas: TD3AreaList;
  Known: Boolean;
begin
  Result := nil;
  if Box.IsEmpty then
    Exit;
  { all areas the box touches (the box pushed down the BSP tree), in Doom 3
    coordinates: a model mostly inside a wall (an elevator in its shaft)
    may have few of its points in an area }
  C0 := CgeToD3(Box.Data[0]);
  C1 := CgeToD3(Box.Data[1]);
  for I := 0 to 2 do
  begin
    D3Min.Data[I] := Min(C0.Data[I], C1.Data[I]);
    D3Max.Data[I] := Max(C0.Data[I], C1.Data[I]);
  end;
  if Map.Proc <> nil then
  begin
    BspAreas := Map.Proc.BoxAreas(D3Min, D3Max);
    SetLength(Result, Length(BspAreas));
    for I := 0 to High(BspAreas) do
      Result[I] := BspAreas[I];
  end;
  { an entity in a portal (a door) belongs to the areas on both sides }
  if Map.Portals <> nil then
    for P2 in Map.Portals.PortalsInBox(Box.Grow(16)) do
      for Side := 0 to 1 do
      begin
        A := Map.Portals.PortalArea(P2, Side);
        if A < 0 then
          Continue;
        Known := False;
        for K := 0 to High(Result) do
          if Result[K] = A then
            Known := True;
        if not Known then
          Result := Concat(Result, [A]);
      end;
end;

function AnyAreaVisible(const Portals: TD3PortalVisibility; const Areas: TD3IntArray): Boolean;
var
  A: Integer;
begin
  if Length(Areas) = 0 then
    Exit(True);
  for A in Areas do
    if (A >= 0) and (A <= High(Portals.AreaVisible)) and Portals.AreaVisible[A] then
      Exit(True);
  Result := False;
end;

procedure TDoom3Map.UpdateVisibility(const Camera: TCastleCamera);
var
  Planes: array [0..3] of TVector4;
  P: TFrustumPlane;
  I: Integer;
  B: TD3BrushEntity;
  ME: TD3ModelEntity;
  Area: Integer;
  On: Boolean;
begin
  if FPortals = nil then
    Exit;
  if FPortalCulling and (Camera <> nil) then
  begin
    for P := fpLeft to fpTop do
      Planes[Ord(P)] := Camera.Frustum.Planes[P];
    FPortals.Compute(Camera.WorldTranslation, AreaAt(Camera.WorldTranslation), Planes);
  end else
    FPortals.AllVisible;

  for I := 0 to High(FAreaScenes) do
  begin
    if FAreaScenes[I] <> nil then
      FAreaScenes[I].Visible := FPortals.AreaVisible[I];
    if FAreaNonSolid[I] <> nil then
      FAreaNonSolid[I].Visible := FPortals.AreaVisible[I];
  end;
  for B in FBrushes do
    B.Scene.Visible := AnyAreaVisible(FPortals, B.Areas);
  for ME in FModels do
  begin
    Area := AreaAt(ME.Holder.Translation + Vector3(0, 32, 0));
    ME.Holder.Visible := (Area < 0) or (Area > High(FPortals.AreaVisible)) or FPortals.AreaVisible[Area];
  end;
  for I := 0 to High(FLights) do
  begin
    On := FLights[I].StartOn and AnyAreaVisible(FPortals, FLights[I].Areas);
    if FLights[I].Node.IsOn <> On then
      FLights[I].Node.IsOn := On;
  end;
  if Camera <> nil then
    UpdateShadowLight(Camera.WorldTranslation);
  { shadow casting brushes of visible areas and of areas the shadow light
    reaches }
  for I := 0 to High(FCasterScenes) do
    if FCasterScenes[I] <> nil then
    begin
      On := (I > High(FPortals.AreaVisible)) or FPortals.AreaVisible[I];
      if (not On) and (FShadowLight >= 0) then
        for Area in FLights[FShadowLight].Areas do
          if Area = I then
            On := True;
      FCasterScenes[I].Exists := On and FShadows;
    end;
end;

function TDoom3Map.LightStrengthAt(const I: Integer; const P: TVector3): Single;
var
  C: TVector3;
begin
  C := FLights[I].Color;
  Result := Max(C.X, Max(C.Y, C.Z)) *
    LightVolumeStrength(FLights[I].Matrix, FLights[I].Shape, FLights[I].Projected, P);
end;

procedure TDoom3Map.SetShadowLight(const I: Integer);
var
  Prelight: TCastleScene;
begin
  if I = FShadowLight then
    Exit;
  if (FShadowLight >= 0) and (FShadowLight <= High(FLights)) then
  begin
    FLights[FShadowLight].Node.ShadowVolumes := False;
    FLights[FShadowLight].Node.ShadowVolumesMain := False;
    if (FShadowLight <= High(FPrelightScenes)) and (FPrelightScenes[FShadowLight] <> nil) then
      FPrelightScenes[FShadowLight].Exists := False;
  end;
  FShadowLight := I;
  if I >= 0 then
  begin
    FLights[I].Node.ShadowVolumes := True;
    FLights[I].Node.ShadowVolumesMain := True;
    { its precomputed shadow volume casts only for it }
    if FPrelightShadows then
    begin
      Prelight := PrelightScene(I);
      if Prelight <> nil then
        Prelight.Exists := True;
    end;
  end;
end;

function TDoom3Map.PrelightScene(const I: Integer): TCastleScene;

  { Signed volume of a closed mesh (positive when its triangles are
    counter-clockwise seen from outside). }
  function SignedVolume(const Positions: array of TVector3; const Indexes: array of Int32): Single;
  var
    T: Integer;
  begin
    Result := 0;
    T := 0;
    while T + 2 <= High(Indexes) do
    begin
      Result := Result + TVector3.DotProduct(Positions[Indexes[T]],
        TVector3.CrossProduct(Positions[Indexes[T + 1]], Positions[Indexes[T + 2]]));
      Inc(T, 3);
    end;
    Result := Result / 6;
  end;

var
  Model: TD3ShadowModel;
  Positions: array of TVector3;
  J: Integer;
  Coord: TCoordinateNode;
  Geometry: TIndexedTriangleSetNode;
  Shape: TShapeNode;
  Root: TX3DRootNode;
  Scene: TD3Scene;
begin
  Result := nil;
  if (FProc = nil) or (I < 0) or (I > High(FLights)) or (FLights[I].Entity = nil) then
    Exit;
  if Length(FPrelightScenes) <> Length(FLights) then
  begin
    SetLength(FPrelightScenes, Length(FLights));
    SetLength(FPrelightState, Length(FLights));
  end;
  if FPrelightState[I] = 0 then
  begin
    FPrelightState[I] := 2;
    Model := FProc.FindShadowModel('_prelight_' + FLights[I].Entity.Name);
    if (Model = nil) or (Length(Model.Indexes) < 3) then
      Exit;
    SetLength(Positions, Length(Model.Positions));
    for J := 0 to High(Positions) do
      Positions[J] := D3ToCge(Model.Positions[J]);
    Coord := TCoordinateNode.Create;
    Coord.SetPoint(Positions);
    Geometry := TIndexedTriangleSetNode.Create;
    Geometry.Coord := Coord;
    Geometry.SetIndex(Model.Indexes);
    { the light cap must face the light: outward triangles }
    Geometry.Ccw := SignedVolume(Positions, Model.Indexes) > 0;
    Geometry.Solid := True;
    Shape := TShapeNode.Create;
    Shape.Geometry := Geometry;
    { a shadow-only caster (CGE renders the shadow volumes of invisible
      shapes with caps). The precomputed volume, extruded again from its
      light, covers the same space within the light's bounds. }
    Shape.Visible := False;
    Root := TX3DRootNode.Create;
    Root.AddChildren(Shape);
    Scene := TD3Scene.Create(nil);
    Scene.SetTransient;
    Scene.Name := 'Prelight' + IntToStr(I);
    Scene.Load(Root, True);
    { Most precomputed volumes have T-junctions (edges split on one side
      only, from clipping), so CGE wouldn't find them closed and would skip
      them. They are closed in space: WholeSceneManifold renders the quads
      of the unpaired edges too, and at a T-junction the quads of both sides
      cover the same strip in opposite directions. }
    Scene.RenderOptions.WholeSceneManifold := True;
    Scene.Collides := False;
    Scene.Pickable := False;
    Scene.CastShadows := True;
    Scene.Exists := False;
    Add(Scene);
    FPrelightScenes[I] := Scene;
    FPrelightState[I] := 1;
    WritelnLog('Doom3Level', 'Prelight shadow volume "%s": %d triangles',
      [Model.Name, Length(Model.Indexes) div 3]);
  end;
  Result := FPrelightScenes[I];
end;

procedure TDoom3Map.UpdateShadowLight(const P: TVector3);
var
  I, Best, Pass, PlayerArea: Integer;
  S, BestScore, CurrentScore: Single;
begin
  if not FShadows then
  begin
    SetShadowLight(-1);
    Exit;
  end;
  PlayerArea := AreaAt(P);
  Best := -1;
  BestScore := 0.05;
  { lights in the player's area first: area walls don't cast shadows, so a
    light behind a wall must not be the one casting them }
  for Pass := 0 to 1 do
  begin
    for I := 0 to High(FLights) do
    begin
      if not FLights[I].Node.IsOn then
        Continue;
      if (FLights[I].Shader <> nil) and FLights[I].Shader.IsAmbientLight then
        Continue;
      if FLights[I].NoShadows then
        Continue;
      if (Pass = 0) and (FLights[I].OriginArea <> PlayerArea) then
        Continue;
      S := LightStrengthAt(I, P);
      if S > BestScore then
      begin
        BestScore := S;
        Best := I;
      end;
    end;
    if Best >= 0 then
      Break;
  end;
  { hysteresis: keep the current light unless another is clearly stronger }
  if (FShadowLight >= 0) and (Best <> FShadowLight) and FLights[FShadowLight].Node.IsOn and
     ((FLights[FShadowLight].OriginArea = PlayerArea) or (FLights[Best].OriginArea <> PlayerArea)) then
  begin
    CurrentScore := LightStrengthAt(FShadowLight, P);
    if (CurrentScore > 0.05) and (BestScore < CurrentScore * 1.2) then
      Exit;
  end;
  SetShadowLight(Best);
end;

procedure TDoom3Map.BuildCollision(const Base: String);
var
  WorldModel: TD3CollisionModel;
  I: Integer;
begin
  if not (FUseCollisionModel and D3Fs.FileExists(Base + '.cm')) then
    Exit;
  FCollision := TD3CollisionFile.Create;
  if not FCollision.LoadFromVfs(Base + '.cm') then
  begin
    FreeAndNil(FCollision);
    Exit;
  end;
  WorldModel := FCollision.World;
  FWorldCollision := TD3Scene.Create(nil);
  FWorldCollision.SetTransient;
  FWorldCollision.Name := 'WorldCollision';
  FWorldCollision.Load(WorldModel.BuildCollisionNode, True);
  FWorldCollision.PreciseCollisions := True;
  { invisible, collides (player, monsters' sight), not pickable: shots and
    floor ray casts hit the visible world }
  FWorldCollision.Visible := False;
  FWorldCollision.Pickable := False;
  FWorldCollision.CastShadows := False;
  Add(FWorldCollision);
  for I := 0 to High(FAreaScenes) do
    if FAreaScenes[I] <> nil then
      FAreaScenes[I].Collides := False;
  BuildShadowCasters(WorldModel);
end;

procedure TDoom3Map.BuildShadowCasters(const WorldModel: TD3CollisionModel);
var
  Groups: array of array of TD3CmBrush;
  I, G: Integer;
  Box: TBox3D;
  Areas: TD3IntArray;
  Scene: TCastleScene;
begin
  { The render geometry of areas is open, it can't cast shadow volumes.
    The .cm brushes are closed convex solids: rebuild them as shadow
    casters, 1 unit inside the walls so they are never seen, grouped by
    the first area they touch (the last group: no area). }
  SetLength(Groups, Length(FAreaScenes) + 1);
  for I := 0 to High(WorldModel.Brushes) do
  begin
    if not WorldModel.BrushCastsShadows(I) then
      Continue;
    Box := TBox3D.Empty;
    Box.Include(D3ToCge(WorldModel.Brushes[I].Mins));
    Box.Include(D3ToCge(WorldModel.Brushes[I].Maxs));
    Areas := BoxAreas(Self, Box.Grow(24));
    if Length(Areas) > 0 then
      G := Areas[0]
    else
      G := High(Groups);
    Groups[G] := Concat(Groups[G], [WorldModel.Brushes[I]]);
    Inc(FCasterBrushCount);
  end;
  SetLength(FCasterScenes, Length(Groups));
  for G := 0 to High(Groups) do
  begin
    if Length(Groups[G]) = 0 then
      Continue;
    Scene := TD3Scene.Create(nil);
    Scene.SetTransient;
    Scene.Name := 'ShadowCasters' + IntToStr(G);
    Scene.Load(BuildShadowCasterNode(Groups[G], 1), True);
    Scene.Collides := False;
    Scene.Pickable := False;
    Scene.CastShadows := True;
    Add(Scene);
    FCasterScenes[G] := Scene;
  end;
  WritelnLog('Doom3Level', 'Shadow casters: %d brushes', [FCasterBrushCount]);
end;

procedure TDoom3Map.BuildBrushEntities;
var
  E: TD3MapEntity;
  Model: TD3ProcModel;
  B: TD3BrushEntity;
  Root: TX3DRootNode;
  Surf: TD3ProcSurface;
  I, Sprites: Integer;
  Rot: TMatrix3;
  ModelName: String;
  Solid, Closed: Boolean;
  Positions: array of TVector3;
begin
  for E in FMapFile.Entities do
  begin
    if EntityInhibited(E) then
      Continue;
    if SameText(E.ClassName_, 'worldspawn') then
      Continue;
    { brush entities: the .proc model is named like the entity (or its
      "model" key names it) }
    Model := nil;
    ModelName := E.Value('model');
    if (ModelName <> '') and (ExtractFileExt(ModelName) = '') then
      Model := FProc.FindModel(ModelName);
    if (Model = nil) and (E.Name <> '') then
      Model := FProc.FindModel(E.Name);
    if (Model = nil) or (Model.AreaIndex >= 0) then
      Continue;

    B := TD3BrushEntity.Create;
    B.Entity := E;
    B.LocalMin := Vector3(MaxSingle, MaxSingle, MaxSingle);
    B.LocalMax := Vector3(-MaxSingle, -MaxSingle, -MaxSingle);
    for Surf in Model.Surfaces do
      for I := 0 to High(Surf.Vertexes) do
      begin
        B.LocalMin := Vector3(Min(B.LocalMin.X, Surf.Vertexes[I].Position.X),
          Min(B.LocalMin.Y, Surf.Vertexes[I].Position.Y), Min(B.LocalMin.Z, Surf.Vertexes[I].Position.Z));
        B.LocalMax := Vector3(Max(B.LocalMax.X, Surf.Vertexes[I].Position.X),
          Max(B.LocalMax.Y, Surf.Vertexes[I].Position.Y), Max(B.LocalMax.Z, Surf.Vertexes[I].Position.Z));
      end;
    Root := TX3DRootNode.Create;
    Sprites := SpriteCount;
    BuildProcModel(Model, Root, Root, E);
    AddLightLibrary(Root);
    B.Scene := TD3Scene.Create(nil);
    B.Scene.SetTransient;
    B.Scene.Name := 'Brush_' + SReplaceChars(E.Name, AllChars - ['a'..'z', 'A'..'Z', '0'..'9'], '_');
    B.Scene.Load(Root, True);
    B.Scene.ProcessEvents := SpriteCount <> Sprites;
    { a model of only nonsolid surfaces (heat haze sprites, decals...)
      neither collides nor blocks sight and shots }
    Solid := False;
    Closed := False;
    for Surf in Model.Surfaces do
    begin
      if not (Decls.Material(Surf.Material).NonSolid or Decls.Material(Surf.Material).ClearsSolid) then
        Solid := True;
      if not Closed then
      begin
        SetLength(Positions, Length(Surf.Vertexes));
        for I := 0 to High(Surf.Vertexes) do
          Positions[I] := Surf.Vertexes[I].Position;
        Closed := TrianglesClosed(Positions, Surf.Indexes);
      end;
    end;
    B.Scene.PreciseCollisions := E.BoolValue('solid', True) and Solid;
    B.Scene.CastShadows := Closed;
    B.Scene.Collides := B.Scene.PreciseCollisions;
    B.Scene.Pickable := B.Scene.PreciseCollisions;
    B.Scene.Translation := D3ToCge(E.Origin);
    Rot := E.Rotation;
    SetD3Rotation(B.Scene, Rot);
    Add(B.Scene);
    B.SetHidden(E.IntValue('hide', 0) <> 0);
    FBrushes.Add(B);
  end;
end;

{ Model of an entity (its "model" key or its entityDef's), resolved through
  a model decl; '' when there is none. }
function EntityModelPath(const E: TD3MapEntity; const Def: TStringList;
  out Decl: TD3ModelDecl): String;
begin
  Decl := nil;
  Result := E.Value('model');
  if (Result = '') and (Def <> nil) then
    Result := Def.Values['model'];
  if (Result <> '') and (ExtractFileExt(Result) = '') then
  begin
    Decl := Decls.ModelDecl(Result);
    if Decl <> nil then
      Result := Decl.Mesh;
  end;
end;

procedure TDoom3Map.BuildStaticModelEntities;
var
  E: TD3MapEntity;
  Def: TStringList;
  Decl: TD3ModelDecl;
  Path, SkinName, Cls: String;
  Model: TD3StaticModel;
  B: TD3BrushEntity;
  Rot: TMatrix3;
begin
  for E in FMapFile.Entities do
  begin
    if EntityInhibited(E) then
      Continue;
    if SameText(E.ClassName_, 'worldspawn') then
      Continue;
    Def := Decls.EntityDef(E.ClassName_);
    Path := EntityModelPath(E, Def, Decl);
    if not IsStaticModelPath(Path) then
      Continue;
    Model := StaticModels.Model(Path);
    if Model = nil then
      Continue;
    SkinName := E.Value('skin');
    if (SkinName = '') and (Def <> nil) then
      SkinName := Def.Values['skin'];
    if (SkinName = '') and (Decl <> nil) then
      SkinName := Decl.Skin;

    B := TD3BrushEntity.Create;
    B.Entity := E;
    B.LocalMin := Model.BoundsMin;
    B.LocalMax := Model.BoundsMax;
    B.Scene := TD3Scene.Create(nil);
    B.Scene.SetTransient;
    B.Scene.Name := 'Static_' + SReplaceChars(E.Name, AllChars - ['a'..'z', 'A'..'Z', '0'..'9'], '_');
    B.Scene.Load(Model.BuildNode(SkinName, E.Pairs), True);
    { map geometry (func_static, doors...) collides, unless "noclipmodel";
      lights' fixtures, items and other props don't }
    Cls := LowerCase(E.ClassName_);
    B.Scene.PreciseCollisions := (Copy(Cls, 1, 5) = 'func_') and
      not E.BoolValue('noclipmodel') and E.BoolValue('solid', True);
    { open models never cast (CGE skips open shapes), and finding their
      edges takes long }
    B.Scene.CastShadows := Model.HasClosedSurface;
    B.Scene.Collides := B.Scene.PreciseCollisions;
    B.Scene.Pickable := B.Scene.PreciseCollisions;
    B.Scene.Translation := D3ToCge(E.Origin);
    Rot := E.Rotation;
    SetD3Rotation(B.Scene, Rot);
    Add(B.Scene);
    B.SetHidden(E.IntValue('hide', 0) <> 0);
    FBrushes.Add(B);
    Inc(FStaticModelCount);
  end;
end;

procedure TDoom3Map.BuildModelEntities;
var
  E: TD3MapEntity;
  Def: TStringList;
  ModelName, MeshPath, SkinName: String;
  Decl: TD3ModelDecl;
  Md5: TD3Md5Model;
  ME: TD3ModelEntity;
  Anims: TStringList;
  Rot: TMatrix3;
  Offset: TVector3;
begin
  for E in FMapFile.Entities do
  begin
    if EntityInhibited(E) then
      Continue;
    Def := Decls.EntityDef(E.ClassName_);
    ModelName := E.Value('model');
    if (ModelName = '') and (Def <> nil) then
      ModelName := Def.Values['model'];
    if ModelName = '' then
      Continue;
    MeshPath := '';
    Decl := nil;
    if SameText(ExtractFileExt(ModelName), '.md5mesh') then
      MeshPath := ModelName
    else
    begin
      Decl := Decls.ModelDecl(ModelName);
      if Decl <> nil then
        MeshPath := Decl.Mesh;
    end;
    if not SameText(ExtractFileExt(MeshPath), '.md5mesh') then
      Continue; { .lwo / .ase: BuildStaticModelEntities }
    Md5 := Md5Cache.Model(MeshPath);
    if Md5 = nil then
      Continue;
    SkinName := E.Value('skin');
    if (SkinName = '') and (Def <> nil) then
      SkinName := Def.Values['skin'];
    if (SkinName = '') and (Decl <> nil) then
      SkinName := Decl.Skin;
    Anims := nil;
    if Decl <> nil then
      Anims := Decl.Anims;
    Offset := TVector3.Zero;
    if Decl <> nil then
      Offset := Decl.Offset;

    ME := TD3ModelEntity.Create;
    ME.Entity := E;
    ME.EntityDef := Def;
    ME.Instance := TD3Md5Instance.Create(Md5, Anims, SkinName);
    if Decl <> nil then
      ME.Instance.FrameCommands := Decl.FrameCommands;
    ME.Instance.Scene.Collides := False;
    ME.Instance.Scene.Pickable := False;
    ME.Instance.Scene.Translation := D3ToCge(Offset);
    ME.Holder := TCastleTransform.Create(nil);
    ME.Holder.SetTransient;
    ME.Holder.Name := 'Model_' + SReplaceChars(E.Name, AllChars - ['a'..'z', 'A'..'Z', '0'..'9'], '_');
    ME.Holder.Translation := D3ToCge(E.Origin);
    Rot := E.Rotation;
    SetD3Rotation(ME.Holder, Rot);
    ME.Holder.Add(ME.Instance.Scene);
    ME.Offset := Offset;
    if Def <> nil then
      BuildHead(ME, Def.Values['def_head'], Def.Values['head_joint']);
    { "hide" "1" (or "2"): hidden until a trigger shows it (TD3Game.Activate) }
    ME.Hidden := E.IntValue('hide', 0) <> 0;
    ME.Holder.Exists := not ME.Hidden;
    Add(ME.Holder);
    FModels.Add(ME);
  end;
end;

procedure TDoom3Map.BuildHead(const ME: TD3ModelEntity; const HeadDefName, JointName: String);
var
  HeadDef: TStringList;
  Decl: TD3ModelDecl;
  Md5: TD3Md5Model;
  SkinName, ModelName: String;
  I: Integer;
begin
  if (HeadDefName = '') or (JointName = '') then
    Exit;
  { a model decl (idAFAttachment::SetBody), or an entityDef naming one }
  ModelName := HeadDefName;
  SkinName := '';
  HeadDef := Decls.EntityDef(HeadDefName);
  if HeadDef <> nil then
  begin
    ModelName := HeadDef.Values['model'];
    SkinName := HeadDef.Values['skin'];
  end;
  Decl := Decls.ModelDecl(ModelName);
  if Decl <> nil then
    Md5 := Md5Cache.Model(Decl.Mesh)
  else
    Md5 := Md5Cache.Model(ModelName);
  if Md5 = nil then
    Exit;
  if (SkinName = '') and (Decl <> nil) then
    SkinName := Decl.Skin;
  if Decl <> nil then
  begin
    ME.HeadInstance := TD3Md5Instance.Create(Md5, Decl.Anims, SkinName);
    { lip sync anims say their lines: sound_voice frame commands }
    ME.HeadInstance.FrameCommands := Decl.FrameCommands;
  end else
    ME.HeadInstance := TD3Md5Instance.Create(Md5, nil, SkinName);
  { copy_joint <body joint> = <head joint>: the head's neck follows the
    body's (its animation and head looks); copy_joint_world (the eyes)
    isn't done }
  for I := 0 to ME.Entity.Pairs.Count - 1 do
    if SameText(Copy(ME.Entity.Pairs.Names[I], 1, 11), 'copy_joint ') then
      ME.HeadInstance.AddCopyJoint(ME.Instance, Trim(Copy(ME.Entity.Pairs.Names[I], 12, MaxInt)),
        Trim(ME.Entity.Pairs.ValueFromIndex[I]));
  ME.HeadInstance.Scene.Collides := False;
  ME.HeadInstance.Scene.Pickable := False;
  if Decl <> nil then
    ME.HeadInstance.Scene.Translation := D3ToCge(Decl.Offset);
  ME.HeadJoint := JointName;
  ME.HeadHolder := TCastleTransform.Create(ME.Holder);
  ME.HeadHolder.SetTransient;
  ME.HeadHolder.Add(ME.HeadInstance.Scene);
  ME.Holder.Add(ME.HeadHolder);
  ME.UpdateHead;
  Inc(FHeadCount);
end;

class function TDoom3Map.EntityInhibited(const E: TD3MapEntity): Boolean;
begin
  case Skill of
    0: Result := E.BoolValue('not_easy');
    1: Result := E.BoolValue('not_medium');
    else Result := E.BoolValue('not_hard');
  end;
end;

class function TDoom3Map.MapBasePath(const AMapName: String): String;
begin
  Result := NormalizeD3Path(AMapName);
  if Copy(Result, 1, 5) <> 'maps/' then
    Result := 'maps/' + Result;
  if (ExtractFileExt(Result) = '.map') or (ExtractFileExt(Result) = '.proc') then
    Result := ChangeFileExt(Result, '');
end;

class function TDoom3Map.MapExists(const AMapName: String): Boolean;
begin
  EnsureData;
  Result := (AMapName <> '') and D3Fs.FileExists(MapBasePath(AMapName) + '.proc');
end;

procedure MergeEntityDef(const E: TD3MapEntity);
var
  Def: TStringList;
  I: Integer;
  Key: String;
begin
  Def := Decls.EntityDef(E.ClassName_);
  if Def = nil then
    Exit;
  for I := 0 to Def.Count - 1 do
  begin
    Key := Def.Names[I];
    if (Key <> '') and (Copy(LowerCase(Key), 1, 7) <> 'editor_') and not E.HasKey(Key) then
      E.SetValue(Key, Def.ValueFromIndex[I]);
  end;
end;

procedure TDoom3Map.Rebuild;
var
  Base: String;
  E: TD3MapEntity;
  B: TD3BrushEntity;
  Overlays, Sprites, Glass, Haze, Reflections: Integer;
begin
  ClearMap;
  if FMapName = '' then
    Exit;
  EnsureData;
  Base := MapBasePath(FMapName);

  LoadProfileStep('clear');
  FProc := TD3ProcFile.Create;
  if not FProc.LoadFromVfs(Base + '.proc') then
  begin
    WritelnWarning('Doom3Level', 'Cannot load "%s.proc"', [Base]);
    FreeAndNil(FProc);
    Exit;
  end;
  FMapFile := TD3MapFile.Create;
  if not FMapFile.LoadFromVfs(Base + '.map') then
    WritelnWarning('Doom3Level', 'No entities: cannot load "%s.map"', [Base]);
  LoadProfileStep('proc+map');
  { like idGameLocal's spawnArgs: the entityDef's keys (with "inherit"
    resolved) are defaults for the map's keys (func_door: speed, lip,
    triggersize, sounds; func_rotating: start_on...) }
  for E in FMapFile.Entities do
    MergeEntityDef(E);

  FSpawnOrigin := TVector3.Zero;
  FSpawnAngle := 0;
  for E in FMapFile.Entities do
    if SameText(E.ClassName_, 'info_player_start') then
    begin
      FSpawnOrigin := D3ToCge(E.Origin);
      FSpawnAngle := E.Angle;
      Break;
    end;

  Overlays := OverlayShapeCount;
  Sprites := SpriteCount;
  Glass := GlassCount;
  Haze := HazeCount;
  Reflections := ReflectionCount;
  BuildWorld;
  LoadProfileStep('world');
  BuildCollision(Base);
  LoadProfileStep('collision');
  BuildBrushEntities;
  LoadProfileStep('brushes');
  WritelnLog('Doom3Level', 'Material stages: %d overlays, %d sprites, %d glass surfaces',
    [OverlayShapeCount - Overlays, SpriteCount - Sprites, GlassCount - Glass]);
  WritelnLog('Doom3Level', 'Special stages: %d heat haze glass surfaces, %d reflections',
    [HazeCount - Haze, ReflectionCount - Reflections]);
  BuildStaticModelEntities;
  LoadProfileStep('static models');
  for B in FBrushes do
    B.Areas := BoxAreas(Self, B.Scene.BoundingBox);
  if FSpawnModels then
    BuildModelEntities;
  LoadProfileStep('md5 models');
  WritelnLog('Doom3Level', 'Map "%s": %d areas, %d triangles, %d lights, %d brush entities, %d static models, %d md5 models (%d with heads)',
    [Base, FProc.NumAreas, TriangleCount, Length(FLights), FBrushes.Count - FStaticModelCount,
     FStaticModelCount, FModels.Count, FHeadCount]);
end;

function TDoom3Map.LoadMap(const AMapName: String): Boolean;
begin
  FMapName := AMapName;
  Rebuild;
  Result := FProc <> nil;
end;

procedure TDoom3Map.Loaded;
begin
  inherited Loaded;
  { In the editor, show the map right away. The game calls LoadMap with
    the level it wants. }
  if CastleDesignMode then
    Rebuild;
end;

procedure TDoom3Map.SetMapName(const Value: String);
begin
  if FMapName = Value then
    Exit;
  FMapName := Value;
  if not (csLoading in ComponentState) then
    Rebuild;
end;

procedure TDoom3Map.SetSpawnModels(const Value: Boolean);
begin
  if FSpawnModels = Value then
    Exit;
  FSpawnModels := Value;
  if not (csLoading in ComponentState) then
    Rebuild;
end;

function TDoom3Map.GetAreaCount: Integer;
begin
  if FProc <> nil then
    Result := FProc.NumAreas
  else
    Result := 0;
end;

function TDoom3Map.GetEntityCount: Integer;
begin
  if FMapFile <> nil then
    Result := FMapFile.Entities.Count
  else
    Result := 0;
end;

function TDoom3Map.GetTriangleCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  if FProc <> nil then
    for I := 0 to FProc.ModelCount - 1 do
      Inc(Result, FProc.Model(I).TriangleCount);
end;

function TDoom3Map.GetLightCount: Integer;
begin
  Result := Length(FLights);
end;

function TDoom3Map.Light(const I: Integer): TD3LightInfo;
begin
  Result := FLights[I];
end;

function TDoom3Map.FindLight(const AName: String): Integer;
begin
  for Result := 0 to High(FLights) do
    if SameText(FLights[Result].Entity.Name, AName) then
      Exit;
  Result := -1;
end;

procedure TDoom3Map.SetLightOn(const I: Integer; const Value: Boolean);
begin
  FLights[I].StartOn := Value;
  { applied by UpdateVisibility, also when the light's areas are visible }
  FLights[I].Node.IsOn := Value and
    ((FPortals = nil) or (not FPortalCulling) or AnyAreaVisible(FPortals, FLights[I].Areas));
end;

procedure TDoom3Map.SetLightParm(const I, Parm: Integer; const Value: Single);
begin
  if (Parm < 0) or (Parm > High(FLights[I].Parms.Parms)) then
    Exit;
  FLights[I].Parms.Parms[Parm] := Value;
  ApplyLightColor(I, LightShaderColor(I));
end;

procedure TDoom3Map.CollectGuiTexture(Node: TX3DNode);
begin
  if (TImageTextureNode(Node).FdUrl.Count > 0) and
     (Copy(TImageTextureNode(Node).FdUrl.Items[0], 1, 6) = 'd3gui:') then
    FGuiTextures.Add(Node);
end;

function TDoom3Map.SetGuiParm(const E: TD3MapEntity; const Key, Value: String): Integer;
var
  B: TD3BrushEntity;
  I: Integer;
  Tex: TImageTextureNode;
  Path, NewUrl: String;
begin
  Result := 0;
  E.SetValue(Key, Value);
  B := FindBrush(E.Name);
  if (B = nil) or (B.Scene.RootNode = nil) then
    Exit;
  FGuiTextures := TX3DNodeList.Create(False);
  try
    B.Scene.RootNode.EnumerateNodes(TImageTextureNode, @CollectGuiTexture, False);
    for I := 0 to FGuiTextures.Count - 1 do
    begin
      Tex := TImageTextureNode(FGuiTextures[I]);
      Path := GuiUrlPath(Tex.FdUrl.Items[0]);
      if Path = '' then
        Continue;
      { drawn once per state, then cached }
      NewUrl := GuiImageUrl(Path, E.Pairs);
      if (NewUrl <> '') and (NewUrl <> Tex.FdUrl.Items[0]) then
      begin
        Tex.SetUrl([NewUrl]);
        Inc(Result);
      end;
    end;
  finally
    FreeAndNil(FGuiTextures);
  end;
end;

procedure TDoom3Map.SetLightFade(const I: Integer; const Value: Single);
begin
  if FLights[I].Fade = Value then
    Exit;
  FLights[I].Fade := Value;
  ApplyLightColor(I, LightShaderColor(I));
end;

function TDoom3Map.FindBrush(const AName: String): TD3BrushEntity;
begin
  for Result in FBrushes do
    if SameText(Result.Entity.Name, AName) then
      Exit;
  Result := nil;
end;

function TDoom3Map.FindModelEntity(const AName: String): TD3ModelEntity;
begin
  for Result in FModels do
    if SameText(Result.Entity.Name, AName) then
      Exit;
  Result := nil;
end;

function TDoom3Map.AreaAt(const P: TVector3): Integer;
begin
  if FProc = nil then
    Exit(-1);
  Result := FProc.PointInArea(CgeToD3(P));
end;

procedure TDoom3Map.Update(const SecondsPassed: Single; var RemoveMe: TRemoveType);
var
  ME: TD3ModelEntity;
  I: Integer;
  C: TVector3;
begin
  inherited Update(SecondsPassed, RemoveMe);
  FTime := FTime + SecondsPassed;
  { scrolling / rotating textures, pulsing glows }
  if FProc <> nil then
    UpdateAnimatedSurfaces(FTime);
  { light shaders: strobes, flickers, pulses }
  for I := 0 to High(FLights) do
    if FLights[I].Animated and FLights[I].Node.IsOn then
    begin
      C := LightShaderColor(I);
      if not TVector3.Equals(C, FLights[I].Color, 0.002) then
        ApplyLightColor(I, C);
    end;
  { animate md5 models (also in the editor, it's nice to see them move) }
  for ME in FModels do
  begin
    { skinning is the slow part: only for models that can be seen (portal
      visibility hides the others) }
    ME.Instance.Shown := ME.Holder.Visible and ME.Holder.Exists;
    ME.Instance.Update(SecondsPassed);
    if ME.HeadInstance <> nil then
    begin
      ME.HeadInstance.Shown := ME.Instance.Shown;
      ME.HeadInstance.Update(SecondsPassed);
      ME.UpdateHead;
    end;
  end;
end;

initialization
  RegisterSerializableComponent(TDoom3Map, 'Doom 3 Map');
  TDoom3Map.Skill := 1; // Doom 3's default g_skill: medium
end.
