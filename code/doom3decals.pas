{
  Copyright 2025 Castle Doom 3 contributors.

  Decals: pieces of a decal material (bullet holes, blood, scorch marks)
  projected onto the surfaces where projectiles hit, like Doom 3's
  idRenderModelDecal (idGameLocal::ProjectDecal, idRenderWorld::
  ProjectDecalOntoWorld): the triangles of the surfaces around the hit are
  clipped to the projection volume, a box Size wide around the hit point
  reaching DecalDepth units to either side of the surface, and get texture
  coordinates from the decal's axes; vertexes near the volume's ends fade
  (the depth fade), so decals wrapping an edge thin out. The world's decals
  live in the system's own scene; a decal on an entity's scene (a mover, a
  static model) is added to that scene and moves with it.

  A decal stays its material's decalInfo stay time, then fades over the
  fade time from the start to the end color (the vertex colors modulate the
  material), and is removed. Materials without decalInfo use Doom 3's
  defaults: 10 s, 4 s, white to black. Without surfaces to project onto
  (Add) a decal is a plain quad at the hit point.
}
unit Doom3Decals;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleVectors, CastleScene, CastleTransform, CastleTriangles, CastleShapes, X3DNodes,
  Doom3Decls;

const
  { Decals kept at once; the oldest goes when another is added. }
  MaxDecals = 128;
  { How far the projection volume reaches to either side of the hit point
    (idGameLocal::ProjectDecal's depth 8 for projectiles and FX decals);
    the outer half of it fades. }
  DecalDepth = 8.0;

type
  TD3DecalVertex = record
    { the target scene's coordinates (CGE) }
    Position: TVector3;
    { CGE's texture coordinates (v = 1 - Doom 3's t) }
    TexCoord: TVector2;
    { the depth fade: 1 near the surface, 0 at the volume's ends }
    Fade: Single;
  end;

  TD3Decal = record
    Material: TD3Material;
    { game time it was added }
    Start: Single;
    { the hit, Doom 3 coordinates }
    Position, Normal: TVector3;
    { the projection box's side }
    Size: Single;
    { rotation around the normal, radians }
    Angle: Single;
    { the clipped surface triangles, 3 vertexes each }
    Vertexes: array of TD3DecalVertex;
    { the scene the triangles are in (an index of the system's targets;
      0 is the world: the system's own scene) }
    Target: Integer;
    { Doom 3's defaults when the material has no decalInfo }
    function Stay: Single;
    function Fade: Single;
    { the vertex color at a time: start, then fading to end }
    function Color(const Time: Single): TVector4;
    { gone (faded out) at a time }
    function Expired(const Time: Single): Boolean;
    function TriangleCount: Integer;
  end;

  TD3DecalList = specialize TList<TD3Decal>;

  TD3DecalSystem = class(TComponent)
  private
    type
      TMaterialShape = record
        Material: TD3Material;
        Shape: TShapeNode;
        Geometry: TTriangleSetNode;
        Coord: TCoordinateNode;
        TexCoord: TTextureCoordinateNode;
        Colors: TColorRGBANode;
      end;
      { A scene decals are projected onto: the world (the system's own
        scene, Scene = nil) or an entity's scene, which gets a group of
        the decal shapes. }
      TTarget = record
        Scene: TCastleScene;
        Group: TGroupNode;
        Shapes: array of TMaterialShape;
        Dirty: Boolean;
      end;
    var
      FScene: TCastleScene;
      FRoot: TX3DRootNode;
      FDecals: TD3DecalList;
      FTargets: array of TTarget;
      FAdded: Integer;
      { the projection being built (ProjectTriangle) }
      FProjCenter, FProjNormal, FProjAxis0, FProjAxis1: TVector3;
      FProjHalf, FProjSize: Single;
      FProjVertexes: array of TD3DecalVertex;
    function TargetIndex(const Scene: TCastleScene): Integer;
    function ShapeFor(const Target: Integer; const M: TD3Material): Integer;
    procedure ProjectTriangle(Shape: TObject; const Position: TTriangle3;
      const Normal: TTriangle3; const TexCoord: TTriangle4; const Face: TFaceIndex);
    { Project the volume (world coordinates, CGE) onto a scene's shapes,
      appending to FProjVertexes (the scene's coordinates). }
    procedure ProjectOnto(const Scene: TCastleScene; const Center, Normal, Axis0, Axis1: TVector3;
      const Size: Single);
    procedure AddPolygon(const Points: array of TVector3; const Count: Integer);
    procedure RebuildTarget(const T: Integer; const Time: Single);
    procedure UpdateColors(const Time: Single);
    procedure RemoveDecal(const Index: Integer);
    function AddDecal(const MaterialName: String; const Position, Normal: TVector3;
      const Size, Time, Angle: Single; out D: TD3Decal): Boolean;
    { the decal's axes (Doom 3 coordinates) }
    procedure DecalAxes(const D: TD3Decal; out Axis0, Axis1: TVector3);
  protected
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { Stick a quad of a material at a Doom 3 point on a surface with a
      normal (unit, pointing out of the surface), on the world. Size: the
      quad's side. Angle < 0: a random rotation (deterministic: by the
      decals added). Returns False (and logs once) when the material is
      unknown. }
    function Add(const MaterialName: String; const Position, Normal: TVector3;
      const Size, Time: Single; const Angle: Single = -1): Boolean;
    { Project a decal of a material onto the surfaces of some scenes: their
      triangles within the projection box (Size wide, DecalDepth deep to
      either side) are clipped to it, like idRenderModelDecal::CreateDecal.
      WorldScenes (the map's areas, at the world's origin) get their decals
      in this system's scene; EntityScenes (movers, static models) get a
      group of decal shapes of their own, moving with them. Scenes whose
      bounds miss the box are skipped; so are blended shapes and overlay
      stages. Returns False when no triangle was in the box (nothing is
      added) or the material is unknown. }
    function Project(const MaterialName: String; const Position, Normal: TVector3;
      const Size, Time: Single; const WorldScenes, EntityScenes: array of TCastleScene;
      const Angle: Single = -1): Boolean;
    { Fade and remove the decals at a game time (every frame). }
    procedure Update(const Time: Single);
    procedure Clear;
    { The scene drawing the world's decals: add it to the map. }
    property Scene: TCastleScene read FScene;
    property Decals: TD3DecalList read FDecals;
    { Decals ever added (also seeds the random rotations). }
    property Added: Integer read FAdded;
    { Triangles of all the decals. }
    function TriangleCount: Integer;
    { Entity scenes with decals on them now. }
    function TargetCount: Integer;
  end;

implementation

uses
  Math, CastleLog, CastleUtils, CastleRenderOptions, CastleBoxes,
  Doom3MapFile, Doom3Materials, Doom3LightEffects;

{ TD3Decal }

function TD3Decal.Stay: Single;
begin
  if Material.DecalStay < 0 then
    Result := 10
  else
    Result := Material.DecalStay;
end;

function TD3Decal.Fade: Single;
begin
  if Material.DecalStay < 0 then
    Result := 4
  else
    Result := Material.DecalFade;
end;

function TD3Decal.Color(const Time: Single): TVector4;
var
  F: Single;
  StartColor, EndColor: TVector4;
begin
  if Material.DecalStay < 0 then
  begin
    StartColor := Vector4(1, 1, 1, 1);
    EndColor := Vector4(0, 0, 0, 0);
  end else
  begin
    StartColor := Material.DecalStart;
    EndColor := Material.DecalEnd;
  end;
  if Time - Start <= Stay then
    Exit(StartColor);
  if Fade <= 0 then
    Exit(EndColor);
  F := Clamped((Time - Start - Stay) / Fade, 0, 1);
  Result := StartColor * (1 - F) + EndColor * F;
end;

function TD3Decal.Expired(const Time: Single): Boolean;
begin
  Result := Time - Start > Stay + Fade;
end;

function TD3Decal.TriangleCount: Integer;
begin
  Result := Length(Vertexes) div 3;
end;

{ TD3DecalSystem }

constructor TD3DecalSystem.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FDecals := TD3DecalList.Create;
  FRoot := TX3DRootNode.Create;
  AddLightLibrary(FRoot);
  FScene := TCastleScene.Create(nil);
  FScene.Name := 'Decals';
  FScene.Load(FRoot, True);
  FScene.Collides := False;
  FScene.Pickable := False;
  FScene.CastShadows := False;
  { target 0: the world }
  SetLength(FTargets, 1);
  FTargets[0].Scene := nil;
  FTargets[0].Group := nil;
end;

destructor TD3DecalSystem.Destroy;
begin
  Clear;
  FreeAndNil(FScene);
  FreeAndNil(FDecals);
  inherited Destroy;
end;

procedure TD3DecalSystem.Notification(AComponent: TComponent; Operation: TOperation);
var
  I, T: Integer;
begin
  inherited Notification(AComponent, Operation);
  if (Operation = opRemove) and (AComponent is TCastleScene) and (FTargets <> nil) then
    for T := 1 to High(FTargets) do
      if FTargets[T].Scene = AComponent then
      begin
        { the scene goes with its decal shapes: forget them }
        for I := FDecals.Count - 1 downto 0 do
          if FDecals[I].Target = T then
            FDecals.Delete(I);
        FTargets[T].Scene := nil;
        FTargets[T].Group := nil;
        FTargets[T].Shapes := nil;
        FTargets[T].Dirty := False;
      end;
end;

function TD3DecalSystem.TargetIndex(const Scene: TCastleScene): Integer;
var
  I: Integer;
begin
  if Scene = nil then
    Exit(0);
  for I := 1 to High(FTargets) do
    if FTargets[I].Scene = Scene then
      Exit(I);
  { a freed slot, or a new one }
  Result := -1;
  for I := 1 to High(FTargets) do
    if FTargets[I].Scene = nil then
    begin
      Result := I;
      Break;
    end;
  if Result < 0 then
  begin
    Result := Length(FTargets);
    SetLength(FTargets, Result + 1);
  end;
  FTargets[Result].Scene := Scene;
  FTargets[Result].Group := TGroupNode.Create;
  FTargets[Result].Shapes := nil;
  FTargets[Result].Dirty := False;
  Scene.RootNode.AddChildren(FTargets[Result].Group);
  Scene.FreeNotification(Self);
end;

function TD3DecalSystem.ShapeFor(const Target: Integer; const M: TD3Material): Integer;
var
  I: Integer;
  App: TAppearanceNode;
  DepthMode: TDepthModeNode;
  S: TMaterialShape;
begin
  for I := 0 to High(FTargets[Target].Shapes) do
    if FTargets[Target].Shapes[I].Material = M then
      Exit(I);
  S.Material := M;
  S.Coord := TCoordinateNode.Create;
  S.TexCoord := TTextureCoordinateNode.Create;
  S.Colors := TColorRGBANode.Create;
  S.Colors.Mode := cmModulate;
  S.Geometry := TTriangleSetNode.Create;
  S.Geometry.Coord := S.Coord;
  S.Geometry.TexCoord := S.TexCoord;
  S.Geometry.Color := S.Colors;
  S.Geometry.Solid := False;
  S.Geometry.Ccw := True;
  App := MaterialAppearance(M.Name);
  App.ShadowCaster := False;
  { on the surface's own triangles: a polygon offset wins the depth test
    (decal materials have polygonOffset, see ApplyPolygonOffset) }
  if App.DepthMode = nil then
  begin
    DepthMode := TDepthModeNode.Create;
    DepthMode.DepthFunc := dmfLessEqual;
    DepthMode.PolygonOffset := Vector2(-1, -2);
    App.DepthMode := DepthMode;
  end;
  S.Shape := TShapeNode.Create;
  S.Shape.Geometry := S.Geometry;
  S.Shape.Appearance := App;
  if Target = 0 then
    FRoot.AddChildren(S.Shape)
  else
  begin
    { not part of the entity's collisions and picking }
    S.Shape.Collision := scNone;
    FTargets[Target].Group.AddChildren(S.Shape);
  end;
  Result := Length(FTargets[Target].Shapes);
  SetLength(FTargets[Target].Shapes, Result + 1);
  FTargets[Target].Shapes[Result] := S;
end;

procedure TD3DecalSystem.DecalAxes(const D: TD3Decal; out Axis0, Axis1: TVector3);
var
  N, U, V: TVector3;
  SinA, CosA: Single;
begin
  { a basis on the surface (idVec3::NormalVectors), turned by the angle }
  N := D.Normal;
  if Abs(N.Z) < 0.9 then
    U := TVector3.CrossProduct(N, Vector3(0, 0, 1)).Normalize
  else
    U := TVector3.CrossProduct(N, Vector3(1, 0, 0)).Normalize;
  V := TVector3.CrossProduct(N, U);
  SinCos(D.Angle, SinA, CosA);
  Axis0 := U * CosA + V * SinA;
  Axis1 := -U * SinA + V * CosA;
end;

function TD3DecalSystem.AddDecal(const MaterialName: String; const Position, Normal: TVector3;
  const Size, Time, Angle: Single; out D: TD3Decal): Boolean;
begin
  D.Material := Decls.Material(MaterialName);
  if D.Material.IsInvisible and (D.Material.StageImage = '') then
  begin
    WritelnWarning('Doom3Decals', 'Decal material "%s" has nothing to draw', [MaterialName]);
    Exit(False);
  end;
  D.Start := Time;
  D.Position := Position;
  if Normal.IsZero then
    D.Normal := Vector3(0, 0, 1)
  else
    D.Normal := Normal.Normalize;
  D.Size := Size;
  if Angle < 0 then
    { idGameLocal::ProjectDecal: a random angle; deterministic here }
    D.Angle := Frac(FAdded * 0.618034) * 2 * Pi
  else
    D.Angle := Angle;
  D.Vertexes := nil;
  D.Target := 0;
  Result := True;
end;

procedure TD3DecalSystem.RemoveDecal(const Index: Integer);
var
  T: Integer;
begin
  T := FDecals[Index].Target;
  if (T >= 0) and (T <= High(FTargets)) then
    FTargets[T].Dirty := True;
  FDecals.Delete(Index);
end;

function TD3DecalSystem.Add(const MaterialName: String; const Position, Normal: TVector3;
  const Size, Time: Single; const Angle: Single): Boolean;
var
  D: TD3Decal;
  Axis0, Axis1, C, A0, A1: TVector3;
  Half: Single;

  procedure Vertex(const I: Integer; const Sx, Sy: Single; const Tu, Tv: Single);
  begin
    D.Vertexes[I].Position := D3ToCge(C + A0 * (Sx * Half) + A1 * (Sy * Half));
    { Doom 3 t goes down the image }
    D.Vertexes[I].TexCoord := Vector2(Tu, 1 - Tv);
    D.Vertexes[I].Fade := 1;
  end;

begin
  if not AddDecal(MaterialName, Position, Normal, Size, Time, Angle, D) then
    Exit(False);
  Inc(FAdded);
  { a quad half a unit off the surface, two triangles, Doom 3's texture
    coordinates ((1, 1) at the first corner) }
  DecalAxes(D, Axis0, Axis1);
  A0 := Axis0;
  A1 := Axis1;
  C := D.Position + D.Normal * 0.5;
  Half := D.Size * 0.5;
  SetLength(D.Vertexes, 6);
  Vertex(0, 1, 1, 1, 1);
  Vertex(1, -1, 1, 0, 1);
  Vertex(2, -1, -1, 0, 0);
  Vertex(3, 1, 1, 1, 1);
  Vertex(4, -1, -1, 0, 0);
  Vertex(5, 1, -1, 1, 0);
  while FDecals.Count >= MaxDecals do
    RemoveDecal(0);
  FDecals.Add(D);
  ShapeFor(0, D.Material);
  FTargets[0].Dirty := True;
  Result := True;
end;

{ Clip a convex polygon to the half space n . p <= d (Sutherland-Hodgman);
  Points must have room for one more point. }
procedure ClipPolygon(var Points: array of TVector3; var Count: Integer;
  const N: TVector3; const Dist: Single);
var
  Result: array [0..15] of TVector3;
  ResultCount, I, J: Integer;
  DI, DJ, F: Single;
begin
  ResultCount := 0;
  for I := 0 to Count - 1 do
  begin
    J := (I + 1) mod Count;
    DI := TVector3.DotProduct(N, Points[I]) - Dist;
    DJ := TVector3.DotProduct(N, Points[J]) - Dist;
    if DI <= 0 then
    begin
      Result[ResultCount] := Points[I];
      Inc(ResultCount);
    end;
    if ((DI < 0) and (DJ > 0)) or ((DI > 0) and (DJ < 0)) then
    begin
      F := DI / (DI - DJ);
      Result[ResultCount] := Points[I] + (Points[J] - Points[I]) * F;
      Inc(ResultCount);
    end;
    if ResultCount >= High(Result) then
      Break;
  end;
  Count := Min(ResultCount, Length(Points));
  for I := 0 to Count - 1 do
    Points[I] := Result[I];
end;

procedure TD3DecalSystem.AddPolygon(const Points: array of TVector3; const Count: Integer);
var
  I, Base: Integer;

  function MakeVertex(const P: TVector3): TD3DecalVertex;
  var
    Local: TVector3;
    Depth: Single;
  begin
    Local := P - FProjCenter;
    Result.Position := P;
    { the texture across the box: (0.5, 0.5) at the hit point;
      Doom 3's t goes down the image }
    Result.TexCoord := Vector2(0.5 + TVector3.DotProduct(Local, FProjAxis0) / FProjSize,
      1 - (0.5 + TVector3.DotProduct(Local, FProjAxis1) / FProjSize));
    { the depth fade over the outer half of the volume (Doom 3's fade
      planes at depth / 2) }
    Depth := Abs(TVector3.DotProduct(Local, FProjNormal));
    Result.Fade := 1 - Clamped((Depth - DecalDepth * 0.5) / (DecalDepth * 0.5), 0, 1);
  end;

begin
  if Count < 3 then
    Exit;
  Base := Length(FProjVertexes);
  SetLength(FProjVertexes, Base + (Count - 2) * 3);
  { a fan }
  for I := 1 to Count - 2 do
  begin
    FProjVertexes[Base] := MakeVertex(Points[0]);
    FProjVertexes[Base + 1] := MakeVertex(Points[I]);
    FProjVertexes[Base + 2] := MakeVertex(Points[I + 1]);
    Inc(Base, 3);
  end;
end;

procedure TD3DecalSystem.ProjectTriangle(Shape: TObject; const Position: TTriangle3;
  const Normal: TTriangle3; const TexCoord: TTriangle4; const Face: TFaceIndex);
var
  Points: array [0..15] of TVector3;
  Count, I: Integer;
  N: TVector3;
begin
  { triangles facing away from the hit normal are skipped
    (idRenderModelDecal::CreateDecal: -0.1) }
  N := Position.Normal;
  if TVector3.DotProduct(N, FProjNormal) < -0.1 then
    Exit;
  for I := 0 to 2 do
    Points[I] := Position.Data[I];
  Count := 3;
  { the box's six planes }
  ClipPolygon(Points, Count, FProjAxis0, TVector3.DotProduct(FProjAxis0, FProjCenter) + FProjHalf);
  if Count < 3 then Exit;
  ClipPolygon(Points, Count, -FProjAxis0, -TVector3.DotProduct(FProjAxis0, FProjCenter) + FProjHalf);
  if Count < 3 then Exit;
  ClipPolygon(Points, Count, FProjAxis1, TVector3.DotProduct(FProjAxis1, FProjCenter) + FProjHalf);
  if Count < 3 then Exit;
  ClipPolygon(Points, Count, -FProjAxis1, -TVector3.DotProduct(FProjAxis1, FProjCenter) + FProjHalf);
  if Count < 3 then Exit;
  ClipPolygon(Points, Count, FProjNormal, TVector3.DotProduct(FProjNormal, FProjCenter) + DecalDepth);
  if Count < 3 then Exit;
  ClipPolygon(Points, Count, -FProjNormal, -TVector3.DotProduct(FProjNormal, FProjCenter) + DecalDepth);
  if Count < 3 then Exit;
  AddPolygon(Points, Count);
end;

procedure TD3DecalSystem.ProjectOnto(const Scene: TCastleScene; const Center, Normal, Axis0, Axis1: TVector3;
  const Size: Single);
var
  Box: TBox3D;
  Corner: TVector3;
  I: Integer;
  Shapes: TShapeList;
  Shape: TShape;
  Node: TAbstractShapeNode;
begin
  { the volume in the scene's coordinates }
  if Scene <> nil then
  begin
    FProjCenter := Scene.WorldToLocal(Center);
    FProjNormal := Scene.WorldToLocalDirection(Normal).Normalize;
    FProjAxis0 := Scene.WorldToLocalDirection(Axis0).Normalize;
    FProjAxis1 := Scene.WorldToLocalDirection(Axis1).Normalize;
  end else
  begin
    FProjCenter := Center;
    FProjNormal := Normal;
    FProjAxis0 := Axis0;
    FProjAxis1 := Axis1;
  end;
  FProjSize := Size;
  FProjHalf := Size * 0.5;
  Box := TBox3D.Empty;
  for I := 0 to 7 do
  begin
    Corner := FProjCenter + FProjAxis0 * (FProjHalf * (2 * (I and 1) - 1)) +
      FProjAxis1 * (FProjHalf * (2 * ((I shr 1) and 1) - 1)) +
      FProjNormal * (DecalDepth * (2 * ((I shr 2) and 1) - 1));
    Box.Include(Corner);
  end;
  if Scene = nil then
    Exit;
  if not Box.Collides(Scene.LocalBoundingBox) then
    Exit;
  Shapes := Scene.Shapes.TraverseList(True, True);
  for Shape in Shapes do
  begin
    Node := Shape.Node;
    if (Node = nil) or (Node.Appearance = nil) then
      Continue;
    { not on overlay stages (drawn on their surface's triangles again),
      glass, sprites, particles or other decals }
    if (Node.Appearance.DepthMode <> nil) or (Node.Appearance.AlphaMode = amBlend) or not Node.Visible then
      Continue;
    if not Shape.BoundingBox.Collides(Box) then
      Continue;
    Shape.Triangulate({$ifdef FPC}@{$endif} ProjectTriangle, True);
  end;
end;

function TD3DecalSystem.Project(const MaterialName: String; const Position, Normal: TVector3;
  const Size, Time: Single; const WorldScenes, EntityScenes: array of TCastleScene;
  const Angle: Single): Boolean;
var
  D: TD3Decal;
  Axis0, Axis1, C, N, A0, A1: TVector3;
  Any: Boolean;

  { One decal per scene hit (a decal across a mover and the wall is two). }
  procedure ProjectScene(const Scene: TCastleScene; const World: Boolean);
  begin
    if (Scene = nil) or not Scene.Exists then
      Exit;
    FProjVertexes := nil;
    ProjectOnto(Scene, C, N, A0, A1, Size);
    if Length(FProjVertexes) = 0 then
      Exit;
    D.Vertexes := FProjVertexes;
    FProjVertexes := nil;
    { the areas' decals go to the world's scene (so they don't depend on
      the area's visibility; the areas sit at the world's origin) }
    if World then
      D.Target := 0
    else
      D.Target := TargetIndex(Scene);
    while FDecals.Count >= MaxDecals do
      RemoveDecal(0);
    FDecals.Add(D);
    ShapeFor(D.Target, D.Material);
    FTargets[D.Target].Dirty := True;
    Any := True;
  end;

var
  I: Integer;
begin
  if not AddDecal(MaterialName, Position, Normal, Size, Time, Angle, D) then
    Exit(False);
  Inc(FAdded);
  DecalAxes(D, Axis0, Axis1);
  C := D3ToCge(D.Position);
  N := D3ToCge(D.Normal);
  A0 := D3ToCge(Axis0);
  A1 := D3ToCge(Axis1);
  Any := False;
  for I := 0 to High(WorldScenes) do
    ProjectScene(WorldScenes[I], True);
  for I := 0 to High(EntityScenes) do
    ProjectScene(EntityScenes[I], False);
  Result := Any;
end;

procedure TD3DecalSystem.RebuildTarget(const T: Integer; const Time: Single);
var
  I, S, K: Integer;
  D: TD3Decal;
  Coords: array of TVector3List;
  UVs: array of TVector2List;
  Cols: array of TVector4List;
  Color: TVector4;
begin
  SetLength(Coords, Length(FTargets[T].Shapes));
  SetLength(UVs, Length(FTargets[T].Shapes));
  SetLength(Cols, Length(FTargets[T].Shapes));
  for S := 0 to High(FTargets[T].Shapes) do
  begin
    Coords[S] := TVector3List.Create;
    UVs[S] := TVector2List.Create;
    Cols[S] := TVector4List.Create;
  end;
  try
    for I := 0 to FDecals.Count - 1 do
    begin
      D := FDecals[I];
      if D.Target <> T then
        Continue;
      S := ShapeFor(T, D.Material);
      Color := D.Color(Time);
      for K := 0 to High(D.Vertexes) do
      begin
        Coords[S].Add(D.Vertexes[K].Position);
        UVs[S].Add(D.Vertexes[K].TexCoord);
        Cols[S].Add(Color * D.Vertexes[K].Fade);
      end;
    end;
    for S := 0 to High(FTargets[T].Shapes) do
    begin
      FTargets[T].Shapes[S].Coord.SetPoint(Coords[S]);
      FTargets[T].Shapes[S].TexCoord.SetPoint(UVs[S]);
      FTargets[T].Shapes[S].Colors.SetColor(Cols[S]);
    end;
  finally
    for S := 0 to High(FTargets[T].Shapes) do
    begin
      Coords[S].Free;
      UVs[S].Free;
      Cols[S].Free;
    end;
  end;
  FTargets[T].Dirty := False;
end;

procedure TD3DecalSystem.UpdateColors(const Time: Single);
var
  I, S, K, T: Integer;
  D: TD3Decal;
  Cols: array of TVector4List;
  Fading: Boolean;
  Color: TVector4;
begin
  Fading := False;
  for I := 0 to FDecals.Count - 1 do
    if Time - FDecals[I].Start > FDecals[I].Stay then
      Fading := True;
  if not Fading then
    Exit;
  for T := 0 to High(FTargets) do
  begin
    if (T > 0) and (FTargets[T].Scene = nil) then
      Continue;
    SetLength(Cols, Length(FTargets[T].Shapes));
    for S := 0 to High(FTargets[T].Shapes) do
      Cols[S] := TVector4List.Create;
    try
      for I := 0 to FDecals.Count - 1 do
      begin
        D := FDecals[I];
        if D.Target <> T then
          Continue;
        S := ShapeFor(T, D.Material);
        Color := D.Color(Time);
        for K := 0 to High(D.Vertexes) do
          Cols[S].Add(Color * D.Vertexes[K].Fade);
      end;
      for S := 0 to High(FTargets[T].Shapes) do
        FTargets[T].Shapes[S].Colors.SetColor(Cols[S]);
    finally
      for S := 0 to High(FTargets[T].Shapes) do
        Cols[S].Free;
    end;
  end;
end;

procedure TD3DecalSystem.Update(const Time: Single);
var
  I, T: Integer;
  AnyDirty: Boolean;
begin
  for I := FDecals.Count - 1 downto 0 do
    if FDecals[I].Expired(Time) then
      RemoveDecal(I);
  AnyDirty := False;
  for T := 0 to High(FTargets) do
    if FTargets[T].Dirty and ((T = 0) or (FTargets[T].Scene <> nil)) then
    begin
      RebuildTarget(T, Time);
      AnyDirty := True;
    end;
  if not AnyDirty then
    UpdateColors(Time);
end;

procedure TD3DecalSystem.Clear;
var
  T: Integer;
begin
  FDecals.Clear;
  for T := 1 to High(FTargets) do
    if FTargets[T].Scene <> nil then
    begin
      FTargets[T].Scene.RemoveFreeNotification(Self);
      if (FTargets[T].Scene.RootNode <> nil) and (FTargets[T].Group <> nil) then
        FTargets[T].Scene.RootNode.RemoveChildren(FTargets[T].Group);
      FTargets[T].Scene := nil;
      FTargets[T].Group := nil;
      FTargets[T].Shapes := nil;
    end;
  SetLength(FTargets, 1);
  FTargets[0].Dirty := True;
  RebuildTarget(0, 0);
end;

function TD3DecalSystem.TriangleCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FDecals.Count - 1 do
    Inc(Result, FDecals[I].TriangleCount);
end;

function TD3DecalSystem.TargetCount: Integer;
var
  T, I: Integer;
begin
  Result := 0;
  for T := 1 to High(FTargets) do
    if FTargets[T].Scene <> nil then
      for I := 0 to FDecals.Count - 1 do
        if FDecals[I].Target = T then
        begin
          Inc(Result);
          Break;
        end;
end;

end.
