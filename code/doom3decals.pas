{
  Copyright 2025 Castle Doom 3 contributors.

  Decals: quads of a decal material (bullet holes, blood, scorch marks)
  stuck on the world where projectiles hit (idGameLocal::ProjectDecal).
  Doom 3 clips the hit polygons to the projection box; here a decal is a
  quad of the given size at the hit point, a little off the surface along
  its normal (the material's polygonOffset also pulls it towards the
  viewer). A decal stays its material's decalInfo stay time, then fades
  over the fade time from the start to the end color (the vertex colors
  modulate the material), and is removed. Materials without decalInfo use
  Doom 3's defaults: 10 s, 4 s, white to black.
}
unit Doom3Decals;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleVectors, CastleScene, X3DNodes,
  Doom3Decls;

const
  { Decals kept at once; the oldest goes when another is added. }
  MaxDecals = 128;

type
  TD3Decal = record
    Material: TD3Material;
    { game time it was added }
    Start: Single;
    { Doom 3 coordinates }
    Position, Normal: TVector3;
    { the quad's side }
    Size: Single;
    { rotation around the normal, radians }
    Angle: Single;
    { Doom 3's defaults when the material has no decalInfo }
    function Stay: Single;
    function Fade: Single;
    { the vertex color at a time: start, then fading to end }
    function Color(const Time: Single): TVector4;
    { gone (faded out) at a time }
    function Expired(const Time: Single): Boolean;
  end;

  TD3DecalList = specialize TList<TD3Decal>;

  TD3DecalSystem = class
  private
    type
      TMaterialShape = record
        Material: TD3Material;
        Shape: TShapeNode;
        Coord: TCoordinateNode;
        TexCoord: TTextureCoordinateNode;
        Colors: TColorRGBANode;
      end;
    var
      FScene: TCastleScene;
      FRoot: TX3DRootNode;
      FDecals: TD3DecalList;
      FShapes: array of TMaterialShape;
      FGeometryDirty: Boolean;
      FAdded: Integer;
    function ShapeFor(const M: TD3Material): Integer;
    procedure RebuildGeometry(const Time: Single);
    procedure UpdateColors(const Time: Single);
  public
    constructor Create;
    destructor Destroy; override;
    { Stick a decal of a material at a Doom 3 point on a surface with
      a normal (unit, pointing out of the surface). Size: the quad's side.
      Angle < 0: a random rotation (deterministic: by the decals added).
      Returns False (and logs once) when the material is unknown. }
    function Add(const MaterialName: String; const Position, Normal: TVector3;
      const Size, Time: Single; const Angle: Single = -1): Boolean;
    { Fade and remove the decals at a game time (every frame). }
    procedure Update(const Time: Single);
    procedure Clear;
    { The scene drawing them: add it to the map. }
    property Scene: TCastleScene read FScene;
    property Decals: TD3DecalList read FDecals;
    { Decals ever added (also seeds the random rotations). }
    property Added: Integer read FAdded;
  end;

implementation

uses
  Math, CastleLog, CastleUtils, CastleRenderOptions,
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

{ TD3DecalSystem }

constructor TD3DecalSystem.Create;
begin
  inherited Create;
  FDecals := TD3DecalList.Create;
  FRoot := TX3DRootNode.Create;
  AddLightLibrary(FRoot);
  FScene := TCastleScene.Create(nil);
  FScene.Name := 'Decals';
  FScene.Load(FRoot, True);
  FScene.Collides := False;
  FScene.Pickable := False;
  FScene.CastShadows := False;
end;

destructor TD3DecalSystem.Destroy;
begin
  FreeAndNil(FScene);
  FreeAndNil(FDecals);
  inherited Destroy;
end;

function TD3DecalSystem.ShapeFor(const M: TD3Material): Integer;
var
  I: Integer;
  Quads: TQuadSetNode;
  App: TAppearanceNode;
begin
  for I := 0 to High(FShapes) do
    if FShapes[I].Material = M then
      Exit(I);
  Result := Length(FShapes);
  SetLength(FShapes, Result + 1);
  FShapes[Result].Material := M;
  FShapes[Result].Coord := TCoordinateNode.Create;
  FShapes[Result].TexCoord := TTextureCoordinateNode.Create;
  FShapes[Result].Colors := TColorRGBANode.Create;
  FShapes[Result].Colors.Mode := cmModulate;
  Quads := TQuadSetNode.Create;
  Quads.Coord := FShapes[Result].Coord;
  Quads.TexCoord := FShapes[Result].TexCoord;
  Quads.Color := FShapes[Result].Colors;
  Quads.Solid := False;
  Quads.Ccw := True;
  App := MaterialAppearance(M.Name);
  App.ShadowCaster := False;
  FShapes[Result].Shape := TShapeNode.Create;
  FShapes[Result].Shape.Geometry := Quads;
  FShapes[Result].Shape.Appearance := App;
  FRoot.AddChildren(FShapes[Result].Shape);
end;

function TD3DecalSystem.Add(const MaterialName: String; const Position, Normal: TVector3;
  const Size, Time: Single; const Angle: Single): Boolean;
var
  D: TD3Decal;
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
  Inc(FAdded);
  while FDecals.Count >= MaxDecals do
    FDecals.Delete(0);
  FDecals.Add(D);
  ShapeFor(D.Material);
  FGeometryDirty := True;
  Result := True;
end;

procedure TD3DecalSystem.RebuildGeometry(const Time: Single);
var
  I, S: Integer;
  D: TD3Decal;
  Coords: array of TVector3List;
  UVs: array of TVector2List;
  Cols: array of TVector4List;
  N, U, V, C: TVector3;
  Color: TVector4;
  Half, SinA, CosA: Single;

  procedure AddVertex(const Sx, Sy: Single; const Tu, Tv: Single);
  begin
    Coords[S].Add(D3ToCge(C + U * (Sx * Half) + V * (Sy * Half)));
    { Doom 3 t goes down the image }
    UVs[S].Add(Vector2(Tu, 1 - Tv));
    Cols[S].Add(Color);
  end;

begin
  SetLength(Coords, Length(FShapes));
  SetLength(UVs, Length(FShapes));
  SetLength(Cols, Length(FShapes));
  for S := 0 to High(FShapes) do
  begin
    Coords[S] := TVector3List.Create;
    UVs[S] := TVector2List.Create;
    Cols[S] := TVector4List.Create;
  end;
  try
    for I := 0 to FDecals.Count - 1 do
    begin
      D := FDecals[I];
      S := ShapeFor(D.Material);
      { a basis on the surface (idVec3::NormalVectors), turned by the angle }
      N := D.Normal;
      if Abs(N.Z) < 0.9 then
        U := TVector3.CrossProduct(N, Vector3(0, 0, 1)).Normalize
      else
        U := TVector3.CrossProduct(N, Vector3(1, 0, 0)).Normalize;
      V := TVector3.CrossProduct(N, U);
      SinCos(D.Angle, SinA, CosA);
      C := D.Position + N * 0.5;
      Half := D.Size * 0.5;
      Color := D.Color(Time);
      { the quad's corners (1, 1), (-1, 1), (-1, -1), (1, -1) with
        Doom 3's texture coordinates (1, 1), (0, 1), (0, 0), (1, 0),
        turned by the angle }
      AddVertex(CosA - SinA, SinA + CosA, 1, 1);
      AddVertex(-CosA - SinA, -SinA + CosA, 0, 1);
      AddVertex(-CosA + SinA, -SinA - CosA, 0, 0);
      AddVertex(CosA + SinA, SinA - CosA, 1, 0);
    end;
    for S := 0 to High(FShapes) do
    begin
      FShapes[S].Coord.SetPoint(Coords[S]);
      FShapes[S].TexCoord.SetPoint(UVs[S]);
      FShapes[S].Colors.SetColor(Cols[S]);
    end;
  finally
    for S := 0 to High(FShapes) do
    begin
      Coords[S].Free;
      UVs[S].Free;
      Cols[S].Free;
    end;
  end;
  FGeometryDirty := False;
end;

procedure TD3DecalSystem.UpdateColors(const Time: Single);
var
  I, S, K: Integer;
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
  SetLength(Cols, Length(FShapes));
  for S := 0 to High(FShapes) do
    Cols[S] := TVector4List.Create;
  try
    for I := 0 to FDecals.Count - 1 do
    begin
      D := FDecals[I];
      S := ShapeFor(D.Material);
      Color := D.Color(Time);
      for K := 0 to 3 do
        Cols[S].Add(Color);
    end;
    for S := 0 to High(FShapes) do
      FShapes[S].Colors.SetColor(Cols[S]);
  finally
    for S := 0 to High(FShapes) do
      Cols[S].Free;
  end;
end;

procedure TD3DecalSystem.Update(const Time: Single);
var
  I: Integer;
begin
  for I := FDecals.Count - 1 downto 0 do
    if FDecals[I].Expired(Time) then
    begin
      FDecals.Delete(I);
      FGeometryDirty := True;
    end;
  if FGeometryDirty then
    RebuildGeometry(Time)
  else
    UpdateColors(Time);
end;

procedure TD3DecalSystem.Clear;
begin
  FDecals.Clear;
  FGeometryDirty := True;
  RebuildGeometry(0);
end;

end.
