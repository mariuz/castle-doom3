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
  Doom3Proc, Doom3MapFile, Doom3Md5;

type
  { A brush entity: its .proc model as a scene. }
  TD3BrushEntity = class
    Entity: TD3MapEntity;
    Scene: TCastleScene;
    { Model bounds in the entity's local Doom 3 coordinates. }
    LocalMin, LocalMax: TVector3;
    destructor Destroy; override;
  end;

  { An entity drawn with an animated md5 model. }
  TD3ModelEntity = class
    Entity: TD3MapEntity;
    Holder: TCastleTransform;
    Instance: TD3Md5Instance;
    EntityDef: TStringList; { owned by Decls, may be nil }
    destructor Destroy; override;
  end;

  TD3LightInfo = record
    Entity: TD3MapEntity;
    Node: TAbstractPunctualLightNode;
    BaseColor: TVector3;
  end;

  TDoom3Map = class(TCastleTransform)
  strict private
    FMapName: String;
    FSpawnModels: Boolean;
    FLightScale: Single;
    FProc: TD3ProcFile;
    FMapFile: TD3MapFile;
    FWorld, FWorldNonSolid: TCastleScene;
    FBrushes: specialize TObjectList<TD3BrushEntity>;
    FModels: specialize TObjectList<TD3ModelEntity>;
    FLights: array of TD3LightInfo;
    FSpawnOrigin: TVector3;
    FSpawnAngle: Single;
    procedure SetMapName(const Value: String);
    procedure SetSpawnModels(const Value: Boolean);
    function GetAreaCount: Integer;
    function GetEntityCount: Integer;
    function GetTriangleCount: Integer;
    function GetLightCount: Integer;
    procedure ClearMap;
    procedure Rebuild;
    procedure BuildWorld;
    procedure BuildLights(const Root: TX3DRootNode);
    procedure BuildBrushEntities;
    procedure BuildModelEntities;
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
      const SolidGroup, NonSolidGroup: TAbstractGroupingNode);

    procedure Update(const SecondsPassed: Single; var RemoveMe: TRemoveType); override;

    property Proc: TD3ProcFile read FProc;
    property MapFile: TD3MapFile read FMapFile;
    property World: TCastleScene read FWorld;
    property Brushes: specialize TObjectList<TD3BrushEntity> read FBrushes;
    property Models: specialize TObjectList<TD3ModelEntity> read FModels;
    { Player start in CGE coordinates (feet) and Doom 3 yaw. }
    property SpawnOrigin: TVector3 read FSpawnOrigin;
    property SpawnAngle: Single read FSpawnAngle;
    function Light(const I: Integer): TD3LightInfo;
    { Area of a CGE point, -1 outside. }
    function AreaAt(const P: TVector3): Integer;
  published
    { Map name: "testmap" means maps/testmap.proc and maps/testmap.map. }
    property MapName: String read FMapName write SetMapName;
    { Create animated md5 models for monsters, characters and func_animate. }
    property SpawnModels: Boolean read FSpawnModels write SetSpawnModels default True;
    { Multiplies all light intensities. }
    property LightScale: Single read FLightScale write FLightScale {$ifdef FPC}default 1{$endif};
    { Read-only information, visible in the editor's inspector. }
    property AreaCount: Integer read GetAreaCount;
    property EntityCount: Integer read GetEntityCount;
    property TriangleCount: Integer read GetTriangleCount;
    property LightCount: Integer read GetLightCount;
  end;

const
  DefaultTestPk4 = 'castle-data:/base/castle_doom3_test.pk4';

{ Rotate a CGE-space vector by a Doom 3 entity rotation matrix. }
function D3RotateCge(const M: TMatrix3; const V: TVector3): TVector3;

implementation

uses
  Math,
  CastleComponentSerialize, CastleLog, CastleUtils, CastleStringUtils, CastleUriUtils,
  CastleRenderOptions,
  Doom3Files, Doom3Decls, Doom3Images, Doom3Materials;

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

{ TD3BrushEntity }

destructor TD3BrushEntity.Destroy;
begin
  FreeAndNil(Scene);
  inherited Destroy;
end;

{ TD3ModelEntity }

destructor TD3ModelEntity.Destroy;
begin
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
    'AreaCount', 'EntityCount', 'TriangleCount', 'LightCount']) then
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
begin
  FModels.Clear;
  FBrushes.Clear;
  FLights := nil;
  FreeAndNil(FWorld);
  FreeAndNil(FWorldNonSolid);
  FreeAndNil(FProc);
  FreeAndNil(FMapFile);
end;

class procedure TDoom3Map.BuildProcModel(const Model: TD3ProcModel;
  const SolidGroup, NonSolidGroup: TAbstractGroupingNode);
var
  Surf: TD3ProcSurface;
  M: TD3Material;
  Coords, Normals: array of TVector3;
  UVs: array of TVector2;
  I: Integer;
  CoordNode: TCoordinateNode;
  NormalNode: TNormalNode;
  TexCoordNode: TTextureCoordinateNode;
  Geometry: TIndexedTriangleSetNode;
  Shape: TShapeNode;
  Group: TAbstractGroupingNode;
begin
  for Surf in Model.Surfaces do
  begin
    if (Length(Surf.Indexes) < 3) or (Length(Surf.Vertexes) = 0) then
      Continue;
    M := Decls.Material(Surf.Material);
    if M.IsInvisible then
      Continue;
    if M.NonSolid or M.Translucent or (M.StageImage <> '') and (M.DiffuseImage = '') then
      Group := NonSolidGroup
    else
      Group := SolidGroup;
    if Group = nil then
      Continue;
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
    Geometry.SetIndex(Surf.Indexes);
    { Doom 3 triangles are clockwise seen from the front (like Quake) }
    Geometry.Ccw := False;
    Geometry.Solid := not M.TwoSided;
    Shape := TShapeNode.Create;
    Shape.Geometry := Geometry;
    Shape.Appearance := MaterialAppearance(Surf.Material);
    Group.AddChildren(Shape);
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
  N: Integer;
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
    if E.HasKey('light_target') then
    begin
      { a projected light: a spot light along light_target }
      TargetVec := E.VectorValue('light_target', Vector3(0, 0, -256));
      UpVec := E.VectorValue('light_up', Vector3(0, 0, 0));
      RightVec := E.VectorValue('light_right', Vector3(0, 0, 0));
      Spot := TSpotLightNode.Create;
      Spot.Location := D3ToCge(E.Origin);
      LightDir := D3RotateCge(Rot, D3ToCge(TargetVec));
      if LightDir.IsZero then
        LightDir := Vector3(0, -1, 0);
      Spot.Direction := LightDir.Normalize;
      R := Max(UpVec.Length, RightVec.Length);
      Spot.CutOffAngle := Min(Pi / 2 - 0.01, ArcTan2(R, Max(1, TargetVec.Length)) * 1.2);
      Spot.BeamWidth := Spot.CutOffAngle * 0.7;
      Spot.Radius := TargetVec.Length * 1.5;
      Spot.Attenuation := Vector3(1, 0, 4 / Sqr(Max(1, Spot.Radius)));
      Node := Spot;
    end else
    begin
      LightRadius := E.VectorValue('light_radius', Vector3(0, 0, 0));
      if LightRadius.IsZero then
      begin
        R := E.FloatValue('light', 300);
        LightRadius := Vector3(R, R, R);
      end;
      LightCenter := E.VectorValue('light_center', TVector3.Zero);
      Point := TPointLightNode.Create;
      Point.Location := D3ToCge(E.Origin) + D3RotateCge(Rot, D3ToCge(LightCenter));
      R := Max(LightRadius.X, Max(LightRadius.Y, LightRadius.Z));
      { Doom 3's falloff images fade the light to zero at the light box.
        X3D attenuation can't reach zero and CGE cuts a light off hard at
        its radius, so the radius is twice the box and the quadratic
        attenuation is 1/3 at the box and 1/33 at the cut. }
      Point.Radius := 2 * R;
      Point.Attenuation := Vector3(1, 0, 8 / Sqr(Max(1, R)));
      Node := Point;
    end;
    Node.Color := LightColor;
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
    Inc(N);
  end;
end;

procedure TDoom3Map.BuildWorld;
var
  Root, RootNonSolid: TX3DRootNode;
  I: Integer;
  M: TD3ProcModel;
begin
  Root := TX3DRootNode.Create;
  RootNonSolid := TX3DRootNode.Create;
  for I := 0 to FProc.ModelCount - 1 do
  begin
    M := FProc.Model(I);
    if M.AreaIndex >= 0 then
      BuildProcModel(M, Root, RootNonSolid);
  end;
  BuildLights(Root);

  FWorld := TCastleScene.Create(nil);
  FWorld.SetTransient;
  FWorld.Name := 'World';
  FWorld.Load(Root, True);
  FWorld.PreciseCollisions := True;
  FWorld.CastGlobalLights := True;
  FWorld.RenderOptions.MaxLightsPerShape := 32;
  Add(FWorld);

  FWorldNonSolid := TCastleScene.Create(nil);
  FWorldNonSolid.SetTransient;
  FWorldNonSolid.Name := 'WorldNonSolid';
  FWorldNonSolid.Load(RootNonSolid, True);
  FWorldNonSolid.Collides := False;
  FWorldNonSolid.Pickable := False;
  Add(FWorldNonSolid);
end;

procedure TDoom3Map.BuildBrushEntities;
var
  E: TD3MapEntity;
  Model: TD3ProcModel;
  B: TD3BrushEntity;
  Root: TX3DRootNode;
  Surf: TD3ProcSurface;
  I: Integer;
  Rot: TMatrix3;
  ModelName: String;
begin
  for E in FMapFile.Entities do
  begin
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
    BuildProcModel(Model, Root, Root);
    B.Scene := TCastleScene.Create(nil);
    B.Scene.SetTransient;
    B.Scene.Name := 'Brush_' + SReplaceChars(E.Name, AllChars - ['a'..'z', 'A'..'Z', '0'..'9'], '_');
    B.Scene.Load(Root, True);
    B.Scene.PreciseCollisions := E.BoolValue('solid', True);
    B.Scene.Translation := D3ToCge(E.Origin);
    Rot := E.Rotation;
    B.Scene.SetView(D3RotateCge(Rot, Vector3(0, 0, -1)), D3RotateCge(Rot, Vector3(0, 1, 0)));
    Add(B.Scene);
    FBrushes.Add(B);
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
      Continue; { .lwo / .ase static models are not supported yet }
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
    ME.Instance.Scene.Collides := False;
    ME.Instance.Scene.Pickable := False;
    ME.Instance.Scene.Translation := D3ToCge(Offset);
    ME.Holder := TCastleTransform.Create(nil);
    ME.Holder.SetTransient;
    ME.Holder.Name := 'Model_' + SReplaceChars(E.Name, AllChars - ['a'..'z', 'A'..'Z', '0'..'9'], '_');
    ME.Holder.Translation := D3ToCge(E.Origin);
    Rot := E.Rotation;
    ME.Holder.SetView(D3RotateCge(Rot, Vector3(0, 0, -1)), D3RotateCge(Rot, Vector3(0, 1, 0)));
    ME.Holder.Add(ME.Instance.Scene);
    Add(ME.Holder);
    FModels.Add(ME);
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

procedure TDoom3Map.Rebuild;
var
  Base: String;
  E: TD3MapEntity;
begin
  ClearMap;
  if FMapName = '' then
    Exit;
  EnsureData;
  Base := MapBasePath(FMapName);

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

  FSpawnOrigin := TVector3.Zero;
  FSpawnAngle := 0;
  for E in FMapFile.Entities do
    if SameText(E.ClassName_, 'info_player_start') then
    begin
      FSpawnOrigin := D3ToCge(E.Origin);
      FSpawnAngle := E.Angle;
      Break;
    end;

  BuildWorld;
  BuildBrushEntities;
  if FSpawnModels then
    BuildModelEntities;
  WritelnLog('Doom3Level', 'Map "%s": %d areas, %d triangles, %d lights, %d brush entities, %d md5 models',
    [Base, FProc.NumAreas, TriangleCount, Length(FLights), FBrushes.Count, FModels.Count]);
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

function TDoom3Map.AreaAt(const P: TVector3): Integer;
begin
  if FProc = nil then
    Exit(-1);
  Result := FProc.PointInArea(CgeToD3(P));
end;

procedure TDoom3Map.Update(const SecondsPassed: Single; var RemoveMe: TRemoveType);
var
  ME: TD3ModelEntity;
begin
  inherited Update(SecondsPassed, RemoveMe);
  { animate md5 models (also in the editor, it's nice to see them move) }
  for ME in FModels do
    ME.Instance.Update(SecondsPassed);
end;

initialization
  RegisterSerializableComponent(TDoom3Map, 'Doom 3 Map');
end.
