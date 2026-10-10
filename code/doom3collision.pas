// Doom 3 collision models (.cm files written by dmap, "CM" "1.00"):
// vertices, edges, the BSP nodes, polygons with their materials and brushes
// of the world ("worldMap") and of every brush entity.
//
// Castle Doom 3 uses the world model's polygons that block the player as an
// invisible collision scene (instead of the render geometry), which adds
// Doom 3's invisible playerclip / clip brushes and leaves out render-only
// detail. Polygons are triangle fans in Doom 3 coordinates.
unit Doom3Collision;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleVectors, CastleUtils, X3DNodes,
  Doom3Lexer;

type
  TD3CmPolygon = record
    { Vertex indexes, in the edge order of the polygon. }
    Verts: array of Int32;
    Normal: TVector3;
    Dist: Single;
    Material: String;
  end;

  TD3CmBrush = record
    Planes: array of TVector4; { normal xyz, dist w }
    Mins, Maxs: TVector3;
    Contents: String;
  end;

  TD3CollisionModel = class
    Name: String;
    Vertices: array of TVector3;
    Edges: array of array [0..1] of Int32;
    Polygons: array of TD3CmPolygon;
    Brushes: array of TD3CmBrush;
    NodeCount: Integer;
    { Indexed triangles (Doom 3 coordinates) of the polygons whose material
      blocks the player. }
    procedure PlayerTriangles(out Coords: TVector3List; out Indexes: TInt32List);
    { An invisible collision-only X3D node of PlayerTriangles. }
    function BuildCollisionNode: TX3DRootNode;
  end;

  TD3CollisionFile = class
  strict private
    FModels: specialize TObjectList<TD3CollisionModel>;
    procedure ParseModel(const L: TDoom3Lexer);
  public
    Crc: Cardinal;
    constructor Create;
    destructor Destroy; override;
    function LoadFromText(const Text: String): Boolean;
    function LoadFromVfs(const Path: String): Boolean;
    function ModelCount: Integer;
    function Model(const I: Integer): TD3CollisionModel;
    function FindModel(const AName: String): TD3CollisionModel;
    { The "worldMap" model (or the first one). }
    function World: TD3CollisionModel;
  end;

implementation

uses
  CastleLog,
  Doom3Files, Doom3Decls, Doom3MapFile;

{ TD3CollisionModel }

procedure TD3CollisionModel.PlayerTriangles(out Coords: TVector3List; out Indexes: TInt32List);
var
  I, J, Base: Integer;
  V: Int32;
begin
  Coords := TVector3List.Create;
  Indexes := TInt32List.Create;
  for I := 0 to High(Polygons) do
  begin
    if Length(Polygons[I].Verts) < 3 then
      Continue;
    if not Decls.Material(Polygons[I].Material).BlocksPlayer then
      Continue;
    Base := Coords.Count;
    for J := 0 to High(Polygons[I].Verts) do
    begin
      V := Polygons[I].Verts[J];
      if (V < 0) or (V > High(Vertices)) then
        V := 0;
      Coords.Add(Vertices[V]);
    end;
    for J := 1 to High(Polygons[I].Verts) - 1 do
    begin
      Indexes.Add(Base);
      Indexes.Add(Base + J);
      Indexes.Add(Base + J + 1);
    end;
  end;
end;

function TD3CollisionModel.BuildCollisionNode: TX3DRootNode;
var
  Coords: TVector3List;
  Indexes: TInt32List;
  I: Integer;
  CoordNode: TCoordinateNode;
  Geometry: TIndexedTriangleSetNode;
  Shape: TShapeNode;
begin
  Result := TX3DRootNode.Create;
  PlayerTriangles(Coords, Indexes);
  try
    if Indexes.Count = 0 then
      Exit;
    for I := 0 to Coords.Count - 1 do
      Coords[I] := D3ToCge(Coords[I]);
    CoordNode := TCoordinateNode.Create;
    CoordNode.SetPoint(Coords);
    Geometry := TIndexedTriangleSetNode.Create;
    Geometry.Coord := CoordNode;
    Geometry.SetIndex(Indexes);
    { collisions don't care about facing }
    Geometry.Solid := False;
    Shape := TShapeNode.Create;
    Shape.Geometry := Geometry;
    Result.AddChildren(Shape);
  finally
    Coords.Free;
    Indexes.Free;
  end;
end;

{ TD3CollisionFile }

constructor TD3CollisionFile.Create;
begin
  inherited Create;
  FModels := specialize TObjectList<TD3CollisionModel>.Create(True);
end;

destructor TD3CollisionFile.Destroy;
begin
  FModels.Free;
  inherited Destroy;
end;

{ Skip counts that some writers put before a block's brace. }
procedure ExpectBlock(const L: TDoom3Lexer);
begin
  while not L.AtEnd and (L.Peek <> '{') do
    L.NextStr;
  L.Expect('{');
end;

procedure TD3CollisionFile.ParseModel(const L: TDoom3Lexer);
var
  M: TD3CollisionModel;
  Tok: String;
  N, I, J, NumEdges, E: Integer;
  Depth: Integer;
  Bounds: TVector3;

  procedure ReadVec(out V: TVector3);
  begin
    L.ReadVector(@V.X, 3);
  end;

begin
  M := TD3CollisionModel.Create;
  FModels.Add(M);
  M.Name := L.NextStr;
  L.Expect('{');
  while L.Next(Tok) and (Tok <> '}') do
  begin
    if SameText(Tok, 'vertices') then
    begin
      L.Expect('{');
      N := L.ReadInt;
      SetLength(M.Vertices, N);
      for I := 0 to N - 1 do
        ReadVec(M.Vertices[I]);
      L.Expect('}');
    end else
    if SameText(Tok, 'edges') then
    begin
      L.Expect('{');
      N := L.ReadInt;
      SetLength(M.Edges, N);
      for I := 0 to N - 1 do
      begin
        L.Expect('(');
        M.Edges[I][0] := L.ReadInt;
        M.Edges[I][1] := L.ReadInt;
        L.Expect(')');
        L.ReadInt; { internal }
        L.ReadInt; { number of users }
      end;
      L.Expect('}');
    end else
    if SameText(Tok, 'nodes') then
    begin
      { "( planeType dist )" nodes, children of a node follow it; we only
        count them }
      L.Expect('{');
      while not L.AtEnd and (L.Peek <> '}') do
      begin
        L.Expect('(');
        L.ReadInt;
        L.ReadFloat;
        L.Expect(')');
        Inc(M.NodeCount);
      end;
      L.Expect('}');
    end else
    if SameText(Tok, 'polygons') then
    begin
      ExpectBlock(L);
      while not L.AtEnd and (L.Peek <> '}') do
      begin
        NumEdges := L.ReadInt;
        SetLength(M.Polygons, Length(M.Polygons) + 1);
        SetLength(M.Polygons[High(M.Polygons)].Verts, NumEdges);
        L.Expect('(');
        for J := 0 to NumEdges - 1 do
        begin
          E := L.ReadInt;
          { a negative edge is used backwards: it starts at its 2nd vertex }
          if (Abs(E) < Length(M.Edges)) then
          begin
            if E < 0 then
              M.Polygons[High(M.Polygons)].Verts[J] := M.Edges[-E][1]
            else
              M.Polygons[High(M.Polygons)].Verts[J] := M.Edges[E][0];
          end;
        end;
        L.Expect(')');
        ReadVec(M.Polygons[High(M.Polygons)].Normal);
        M.Polygons[High(M.Polygons)].Dist := L.ReadFloat;
        ReadVec(Bounds); { bounds min }
        ReadVec(Bounds); { bounds max }
        M.Polygons[High(M.Polygons)].Material := L.NextStr;
      end;
      L.Expect('}');
    end else
    if SameText(Tok, 'brushes') then
    begin
      ExpectBlock(L);
      while not L.AtEnd and (L.Peek <> '}') do
      begin
        N := L.ReadInt;
        SetLength(M.Brushes, Length(M.Brushes) + 1);
        SetLength(M.Brushes[High(M.Brushes)].Planes, N);
        L.Expect('{');
        for J := 0 to N - 1 do
        begin
          L.ReadVector(@M.Brushes[High(M.Brushes)].Planes[J].X, 3);
          M.Brushes[High(M.Brushes)].Planes[J].W := L.ReadFloat;
        end;
        L.Expect('}');
        ReadVec(M.Brushes[High(M.Brushes)].Mins);
        ReadVec(M.Brushes[High(M.Brushes)].Maxs);
        M.Brushes[High(M.Brushes)].Contents := L.NextStr;
      end;
      L.Expect('}');
    end else
    if Tok = '{' then
    begin
      Depth := 1;
      while (Depth > 0) and L.Next(Tok) do
        if Tok = '{' then
          Inc(Depth)
        else
        if Tok = '}' then
          Dec(Depth);
    end;
  end;
end;

function TD3CollisionFile.LoadFromText(const Text: String): Boolean;
var
  L: TDoom3Lexer;
  Tok: String;
begin
  FModels.Clear;
  L := TDoom3Lexer.Create(Text);
  try
    if not SameText(L.NextStr, 'CM') then
    begin
      WritelnWarning('Doom3Collision', 'Not a Doom 3 collision model file');
      Exit(False);
    end;
    L.NextStr; { version "1.00" }
    Crc := Cardinal(StrToInt64Def(L.Peek, 0));
    if L.Peek <> 'collisionModel' then
      L.NextStr;
    while L.Next(Tok) do
      if SameText(Tok, 'collisionModel') then
        ParseModel(L);
    Result := FModels.Count > 0;
  finally
    L.Free;
  end;
end;

function TD3CollisionFile.LoadFromVfs(const Path: String): Boolean;
var
  Text: String;
  W: TD3CollisionModel;
begin
  Text := D3Fs.ReadText(Path);
  Result := (Text <> '') and LoadFromText(Text);
  if Result then
  begin
    W := World;
    WritelnLog('Doom3Collision', '"%s": %d models, world: %d vertices, %d edges, %d polygons, %d brushes',
      [Path, FModels.Count, Length(W.Vertices), Length(W.Edges), Length(W.Polygons), Length(W.Brushes)]);
  end;
end;

function TD3CollisionFile.ModelCount: Integer;
begin
  Result := FModels.Count;
end;

function TD3CollisionFile.Model(const I: Integer): TD3CollisionModel;
begin
  Result := FModels[I];
end;

function TD3CollisionFile.FindModel(const AName: String): TD3CollisionModel;
var
  M: TD3CollisionModel;
begin
  for M in FModels do
    if SameText(M.Name, AName) then
      Exit(M);
  Result := nil;
end;

function TD3CollisionFile.World: TD3CollisionModel;
begin
  Result := FindModel('worldMap');
  if (Result = nil) and (FModels.Count > 0) then
    Result := FModels[0];
end;

end.
