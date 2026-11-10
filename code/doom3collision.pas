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

  TD3Polygon = array of TVector3;
  TD3Polyhedron = array of TD3Polygon;

  TD3CollisionModel = class
    Name: String;
    Vertices: array of TVector3;
    Edges: array of array [0..1] of Int32;
    Polygons: array of TD3CmPolygon;
    Brushes: array of TD3CmBrush;
    NodeCount: Integer;
    { Indexed triangles (Doom 3 coordinates) of the polygons whose material
      blocks the player. }
    procedure PlayerTriangles(out Coords: TVector3List; out Indexes: TInt32List;
      const ForMonsters: Boolean = False);
    { An invisible collision-only X3D node of PlayerTriangles (ForMonsters:
      the polygons blocking monsters, solid and monsterclip). }
    function BuildCollisionNode(const ForMonsters: Boolean = False): TX3DRootNode;
    { Brushes that block light (contents with "solid" or "opaque"). }
    function BrushCastsShadows(const I: Integer): Boolean;
  end;

{ Whether triangles (Indexes into Positions, 3 per triangle) form closed
  surfaces: every edge has a counterpart going the other way, matching
  positions exactly (degenerate triangles left out), like CGE's shadow
  volume edges. CGE doesn't cast shadows from a shape with open edges, and
  finding its edges is quadratic in them: open models shouldn't cast. }
function TrianglesClosed(const Positions: array of TVector3; const Indexes: array of Int32): Boolean;

{ The closed convex polyhedron of a brush (Doom 3 coordinates), shrunk by
  Inset: every face polygon counter-clockwise seen from outside, vertexes
  shared between faces welded to exactly equal coordinates (CGE matches
  shadow volume edges by position). Empty when degenerate. }
function BrushPolyhedron(const Brush: TD3CmBrush; const Inset: Single): TD3Polyhedron;

{ X3D shapes of brushes as invisible-in-practice shadow casters: one closed,
  black, unlit shape per brush (CGE skips open shapes as casters). }
function BuildShadowCasterNode(const Brushes: array of TD3CmBrush; const Inset: Single): TX3DRootNode;

type
  TD3CollisionFile = class
  strict private
    FModels: specialize TObjectList<TD3CollisionModel>;
    procedure ParseModel(const L: TDoom3Lexer);
  public
    Crc: Cardinal;
    constructor Create;
    destructor Destroy; override;
    function LoadFromText(const Text: String): Boolean;
    { Doom 3 BFG's binary version (generated/maps/<name>.bcm). }
    function LoadFromBinary(const Stream: TStream): Boolean;
    function LoadFromVfs(const Path: String): Boolean;
    function ModelCount: Integer;
    function Model(const I: Integer): TD3CollisionModel;
    function FindModel(const AName: String): TD3CollisionModel;
    { The "worldMap" model (or the first one). }
    function World: TD3CollisionModel;
  end;

implementation

uses
  Math, CastleRenderOptions,
  CastleLog,
  Doom3Files, Doom3Decls, Doom3MapFile, Doom3Portals, Doom3Bfg;

function BrushPolyhedron(const Brush: TD3CmBrush; const Inset: Single): TD3Polyhedron;
var
  I, J, K, F: Integer;
  N, U, V, C: TVector3;
  R: Single;
  Poly: TD3PointArray;
  Welded: array of TVector3;
  Face: TD3Polygon;
  Found: Boolean;
begin
  Result := nil;
  if Length(Brush.Planes) < 4 then
    Exit;
  R := Max(64, (Brush.Maxs - Brush.Mins).Length * 2);
  Welded := nil;
  for I := 0 to High(Brush.Planes) do
  begin
    N := Vector3(Brush.Planes[I].X, Brush.Planes[I].Y, Brush.Planes[I].Z);
    if N.Length < 1e-6 then
      Continue;
    N := N.Normalize;
    { a big quad on the plane (n . p = dist - inset) around the brush
      center's projection, counter-clockwise around the outward normal:
      u x v = n }
    C := (Brush.Mins + Brush.Maxs) * 0.5;
    C := C - N * (TVector3.DotProduct(N, C) - (Brush.Planes[I].W - Inset));
    if Abs(N.Z) < 0.9 then
      U := TVector3.CrossProduct(Vector3(0, 0, 1), N).Normalize
    else
      U := TVector3.CrossProduct(Vector3(1, 0, 0), N).Normalize;
    V := TVector3.CrossProduct(N, U);
    Poly := [C + (-U - V) * R, C + (U - V) * R, C + (U + V) * R, C + (-U + V) * R];
    { keep the part inside every other plane: n_j . p <= dist_j - inset }
    for J := 0 to High(Brush.Planes) do
    begin
      if (J = I) or (Length(Poly) < 3) then
        Continue;
      Poly := ClipPolygon(Poly, Vector4(-Brush.Planes[J].X, -Brush.Planes[J].Y, -Brush.Planes[J].Z,
        Brush.Planes[J].W - Inset));
    end;
    if Length(Poly) < 3 then
      Continue;
    { weld to shared vertexes, drop repeated points }
    Face := nil;
    for K := 0 to High(Poly) do
    begin
      Found := False;
      for F := 0 to High(Welded) do
        if PointsDistanceSqr(Welded[F], Poly[K]) < Sqr(0.05) then
        begin
          Poly[K] := Welded[F];
          Found := True;
          Break;
        end;
      if not Found then
        Welded := Concat(Welded, [Poly[K]]);
      if (Length(Face) = 0) or not TVector3.PerfectlyEquals(Face[High(Face)], Poly[K]) then
        Face := Concat(Face, [Poly[K]]);
    end;
    if (Length(Face) > 1) and TVector3.PerfectlyEquals(Face[0], Face[High(Face)]) then
      SetLength(Face, Length(Face) - 1);
    if Length(Face) >= 3 then
      Result := Concat(Result, [Face]);
  end;
  if Length(Result) < 4 then
    Result := nil;
end;

function BuildShadowCasterNode(const Brushes: array of TD3CmBrush; const Inset: Single): TX3DRootNode;
var
  B, F, K, Base: Integer;
  Poly: TD3Polyhedron;
  Coords: TVector3List;
  Indexes: TInt32List;
  CoordNode: TCoordinateNode;
  Geometry: TIndexedTriangleSetNode;
  Shape: TShapeNode;
  Appearance: TAppearanceNode;
  Unlit: TUnlitMaterialNode;
begin
  Result := TX3DRootNode.Create;
  for B := 0 to High(Brushes) do
  begin
    Poly := BrushPolyhedron(Brushes[B], Inset);
    if Poly = nil then
      Continue;
    Coords := TVector3List.Create;
    Indexes := TInt32List.Create;
    try
      for F := 0 to High(Poly) do
      begin
        Base := Coords.Count;
        for K := 0 to High(Poly[F]) do
          Coords.Add(D3ToCge(Poly[F][K]));
        for K := 1 to High(Poly[F]) - 1 do
        begin
          Indexes.Add(Base);
          Indexes.Add(Base + K);
          Indexes.Add(Base + K + 1);
        end;
      end;
      CoordNode := TCoordinateNode.Create;
      CoordNode.SetPoint(Coords);
      Geometry := TIndexedTriangleSetNode.Create;
      Geometry.Coord := CoordNode;
      Geometry.SetIndex(Indexes);
      { counter-clockwise from outside (D3ToCge is a rotation) }
      Geometry.Ccw := True;
      Geometry.Solid := True;
      Unlit := TUnlitMaterialNode.Create;
      Unlit.EmissiveColor := Vector3(0, 0, 0);
      Appearance := TAppearanceNode.Create;
      Appearance.Material := Unlit;
      Shape := TShapeNode.Create;
      Shape.Geometry := Geometry;
      Shape.Appearance := Appearance;
      { a shadow-only caster: not rendered, CGE still casts its shadow
        volumes (with caps, mariuz/castle-engine#5) }
      Shape.Visible := False;
      Result.AddChildren(Shape);
    finally
      Coords.Free;
      Indexes.Free;
    end;
  end;
end;

{ TD3CollisionModel }

procedure TD3CollisionModel.PlayerTriangles(out Coords: TVector3List; out Indexes: TInt32List;
  const ForMonsters: Boolean);
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
    if ForMonsters then
    begin
      if not Decls.Material(Polygons[I].Material).BlocksMonsters then
        Continue;
    end else
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

type
  TEdgeKey = record
    A, B: TVector3;
  end;

function TrianglesClosed(const Positions: array of TVector3; const Indexes: array of Int32): Boolean;
var
  Edges: specialize TDictionary<TEdgeKey, Integer>;
  T, K, Count: Integer;
  P: array [0..2] of TVector3;
  Key, Back: TEdgeKey;
  Pair: specialize TPair<TEdgeKey, Integer>;
begin
  Result := Length(Indexes) >= 3;
  if not Result then
    Exit;
  Edges := specialize TDictionary<TEdgeKey, Integer>.Create;
  try
    for T := 0 to Length(Indexes) div 3 - 1 do
    begin
      for K := 0 to 2 do
        P[K] := Positions[Indexes[T * 3 + K]];
      if TVector3.PerfectlyEquals(P[0], P[1]) or TVector3.PerfectlyEquals(P[1], P[2]) or
         TVector3.PerfectlyEquals(P[2], P[0]) or
         TVector3.CrossProduct(P[1] - P[0], P[2] - P[0]).IsZero then
        Continue;
      for K := 0 to 2 do
      begin
        Key.A := P[K];
        Key.B := P[(K + 1) mod 3];
        if Edges.TryGetValue(Key, Count) then
          Edges[Key] := Count + 1
        else
          Edges.Add(Key, 1);
      end;
    end;
    for Pair in Edges do
    begin
      Back.A := Pair.Key.B;
      Back.B := Pair.Key.A;
      if not Edges.TryGetValue(Back, Count) or (Count <> Pair.Value) then
        Exit(False);
    end;
  finally
    Edges.Free;
  end;
end;

function TD3CollisionModel.BrushCastsShadows(const I: Integer): Boolean;
var
  C: String;
begin
  C := LowerCase(Brushes[I].Contents);
  { old .cm files write contents as a number: treat them as solid }
  Result := (Pos('solid', C) > 0) or (Pos('opaque', C) > 0) or
    ((C <> '') and (C[1] in ['0'..'9']));
end;

function TD3CollisionModel.BuildCollisionNode(const ForMonsters: Boolean): TX3DRootNode;
var
  Coords: TVector3List;
  Indexes: TInt32List;
  I: Integer;
  CoordNode: TCoordinateNode;
  Geometry: TIndexedTriangleSetNode;
  Shape: TShapeNode;
begin
  Result := TX3DRootNode.Create;
  PlayerTriangles(Coords, Indexes, ForMonsters);
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

{ The contents bits of a binary collision model as the text version's
  names. }
function ContentsNames(const Bits: Integer): String;
const
  Names: array [0..15] of String = ('solid', 'opaque', 'water', 'playerclip', 'monsterclip',
    'moveableclip', 'ikclip', 'blood', 'body', 'projectile', 'corpse', 'rendermodel',
    'trigger', 'aas_solid', 'aas_obstacle', 'flashlight_trigger');
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Names) do
    if (Bits and (1 shl I)) <> 0 then
    begin
      if Result <> '' then
        Result := Result + ',';
      Result := Result + Names[I];
    end;
  if Result = '' then
    Result := 'none';
end;

{ A .bcm: the number of models, the map's name, its CRC, "CM", the
  version, then the models (idCollisionModelManagerLocal::
  LoadBinaryModelFromFile): counts, vertices, edges, materials, polygons
  (edge numbers; negative: backwards), brushes (planes as a b c d with
  d = -dist), the node tree. }
function TD3CollisionFile.LoadFromBinary(const Stream: TStream): Boolean;
var
  R: TBfgReader;

  procedure ReadNode(const M: TD3CollisionModel; const Depth: Integer);
  var
    PlaneType: Integer;
  begin
    Inc(M.NodeCount);
    PlaneType := R.BigInt;
    R.BigFloat;
    while R.BigInt >= 0 do ;
    while R.BigInt >= 0 do ;
    if (PlaneType <> -1) and (Depth < 4000) then
    begin
      ReadNode(M, Depth + 1);
      ReadNode(M, Depth + 1);
    end;
  end;

var
  M: TD3CollisionModel;
  Materials: array of String;
  NumModels, I, J, K, N, E, NumVertices, NumEdges, NumPolygons, NumBrushes: Integer;
  D: Single;
begin
  Result := False;
  FModels.Clear;
  R := TBfgReader.Create(Stream, False);
  try
    try
      NumModels := R.BigInt;
      R.Str; { the map's name }
      Crc := R.BigUInt;
      if not SameText(R.Str, 'CM') then
      begin
        WritelnWarning('Doom3Collision', 'Not a Doom 3 BFG .bcm file');
        Exit;
      end;
      R.Str; { version }
      for I := 0 to NumModels - 1 do
      begin
        if R.BigUInt <> BfgCmMagic then
        begin
          WritelnWarning('Doom3Collision', 'Bad model %d in a .bcm file', [I]);
          Exit;
        end;
        R.BigInt64; { time }
        M := TD3CollisionModel.Create;
        FModels.Add(M);
        M.Name := R.Str;
        R.Skip(24); { bounds }
        R.BigInt; { contents }
        R.Bool; { isConvex }
        NumVertices := R.BigInt;
        NumEdges := R.BigInt;
        NumPolygons := R.BigInt;
        NumBrushes := R.BigInt;
        R.Skip(7 * 4); { nodes, brush and polygon refs, internal and sharp edges, removed and merged polygons }
        SetLength(M.Vertices, NumVertices);
        for J := 0 to NumVertices - 1 do
        begin
          M.Vertices[J] := R.BigVec3;
          R.Skip(12); { checkcount, side, sideSet }
        end;
        SetLength(M.Edges, NumEdges);
        for J := 0 to NumEdges - 1 do
        begin
          R.Skip(16); { checkcount, internal, numUsers, side, sideSet }
          M.Edges[J][0] := R.BigInt;
          M.Edges[J][1] := R.BigInt;
          R.Skip(12); { normal }
        end;
        R.BigInt; { polygon memory }
        R.BigInt; { brush memory }
        N := R.BigInt;
        SetLength(Materials, N);
        for J := 0 to N - 1 do
          Materials[J] := R.Str;
        SetLength(M.Polygons, NumPolygons);
        for J := 0 to NumPolygons - 1 do
        begin
          K := R.BigInt;
          if (K >= 0) and (K < Length(Materials)) then
            M.Polygons[J].Material := Materials[K];
          N := R.BigInt;
          R.Skip(24); { bounds }
          R.BigInt; { checkcount }
          R.BigInt; { contents }
          M.Polygons[J].Normal := R.BigVec3;
          D := R.BigFloat;
          M.Polygons[J].Dist := -D;
          SetLength(M.Polygons[J].Verts, N);
          for K := 0 to N - 1 do
          begin
            E := R.BigInt;
            if Abs(E) < NumEdges then
            begin
              if E < 0 then
                M.Polygons[J].Verts[K] := M.Edges[-E][1]
              else
                M.Polygons[J].Verts[K] := M.Edges[E][0];
            end;
          end;
        end;
        SetLength(M.Brushes, NumBrushes);
        for J := 0 to NumBrushes - 1 do
        begin
          R.BigInt; { material }
          N := R.BigInt;
          R.BigInt; { checkcount }
          M.Brushes[J].Mins := R.BigVec3;
          M.Brushes[J].Maxs := R.BigVec3;
          M.Brushes[J].Contents := ContentsNames(R.BigInt);
          R.BigInt; { primitiveNum }
          SetLength(M.Brushes[J].Planes, N);
          for K := 0 to N - 1 do
          begin
            M.Brushes[J].Planes[K].X := R.BigFloat;
            M.Brushes[J].Planes[K].Y := R.BigFloat;
            M.Brushes[J].Planes[K].Z := R.BigFloat;
            D := R.BigFloat;
            M.Brushes[J].Planes[K].W := -D;
          end;
        end;
        ReadNode(M, 0);
      end;
      Result := FModels.Count > 0;
    except
      on Err: Exception do
        WritelnWarning('Doom3Collision', 'Cannot read the .bcm file: %s', [Err.Message]);
    end;
  finally
    R.Free;
  end;
end;

function TD3CollisionFile.LoadFromVfs(const Path: String): Boolean;
var
  Text: String;
  W: TD3CollisionModel;
  Stream: TStream;
begin
  Text := D3Fs.ReadText(Path);
  if Text = '' then
  begin
    { Doom 3 BFG: only the binary version }
    Stream := D3Fs.OpenGenerated(Path);
    if Stream = nil then
      Exit(False);
    try
      Result := LoadFromBinary(Stream);
    finally
      Stream.Free;
    end;
  end else
    Result := LoadFromText(Text);
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
