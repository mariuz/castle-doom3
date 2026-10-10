{ Doom 3 .proc files (dmap output, "mapProcFile003"): the render geometry
  of every area ("_area0", "_area1"...) and of brush entities (models named
  like the entity), the inter-area portals and the area BSP tree.
  Shadow models are skipped (Castle Game Engine computes its own). }
unit Doom3Proc;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleVectors,
  Doom3Lexer;

type
  TD3ProcVertex = record
    Position: TVector3; { Doom 3 coordinates (Z up) }
    ST: TVector2;
    Normal: TVector3;
  end;

  TD3ProcSurface = class
    Material: String;
    Vertexes: array of TD3ProcVertex;
    Indexes: array of Int32;
  end;

  TD3ProcSurfaceList = specialize TObjectList<TD3ProcSurface>;

  TD3ProcModel = class
    Name: String;
    Surfaces: TD3ProcSurfaceList;
    constructor Create;
    destructor Destroy; override;
    { "_areaN" models: N, otherwise -1. }
    function AreaIndex: Integer;
    function TriangleCount: Integer;
  end;

  TD3Portal = record
    Points: array of TVector3;
    PositiveArea, NegativeArea: Integer;
  end;

  TD3ProcNode = record
    Plane: TVector4;
    { > 0 node index, 0 solid, < 0 area -1-child }
    Children: array [0..1] of Int32;
  end;

  TD3ProcFile = class
  strict private
    FModels: specialize TObjectList<TD3ProcModel>;
    FModelIndex: specialize TDictionary<String, TD3ProcModel>;
    procedure ParseModel(const Lexer: TDoom3Lexer);
    procedure ParsePortals(const Lexer: TDoom3Lexer);
    procedure ParseNodes(const Lexer: TDoom3Lexer);
  public
    NumAreas: Integer;
    Portals: array of TD3Portal;
    Nodes: array of TD3ProcNode;
    constructor Create;
    destructor Destroy; override;
    function LoadFromText(const Text: String): Boolean;
    { Load maps/<name>.proc from the virtual file system. }
    function LoadFromVfs(const Path: String): Boolean;
    function ModelCount: Integer;
    function Model(const I: Integer): TD3ProcModel;
    function FindModel(const Name: String): TD3ProcModel;
    { Area containing a point (Doom 3 coordinates), -1 in the void. }
    function PointInArea(const P: TVector3): Integer;
  end;

implementation

uses
  CastleLog,
  Doom3Files;

{ TD3ProcModel }

constructor TD3ProcModel.Create;
begin
  inherited Create;
  Surfaces := TD3ProcSurfaceList.Create(True);
end;

destructor TD3ProcModel.Destroy;
begin
  Surfaces.Free;
  inherited Destroy;
end;

function TD3ProcModel.AreaIndex: Integer;
begin
  if SameText(Copy(Name, 1, 5), '_area') then
    Result := StrToIntDef(Copy(Name, 6, MaxInt), -1)
  else
    Result := -1;
end;

function TD3ProcModel.TriangleCount: Integer;
var
  S: TD3ProcSurface;
begin
  Result := 0;
  for S in Surfaces do
    Inc(Result, Length(S.Indexes) div 3);
end;

{ TD3ProcFile }

constructor TD3ProcFile.Create;
begin
  inherited Create;
  FModels := specialize TObjectList<TD3ProcModel>.Create(True);
  FModelIndex := specialize TDictionary<String, TD3ProcModel>.Create;
end;

destructor TD3ProcFile.Destroy;
begin
  FModelIndex.Free;
  FModels.Free;
  inherited Destroy;
end;

procedure TD3ProcFile.ParseModel(const Lexer: TDoom3Lexer);
var
  M: TD3ProcModel;
  S: TD3ProcSurface;
  NumSurfaces, NumVerts, NumIndexes, I, J: Integer;
  F: array [0..7] of Single;
begin
  Lexer.Expect('{');
  M := TD3ProcModel.Create;
  M.Name := Lexer.NextStr;
  FModels.Add(M);
  FModelIndex.AddOrSetValue(LowerCase(M.Name), M);
  NumSurfaces := Lexer.ReadInt;
  for I := 0 to NumSurfaces - 1 do
  begin
    if not Lexer.Expect('{') then
      Break;
    S := TD3ProcSurface.Create;
    M.Surfaces.Add(S);
    S.Material := Lexer.NextStr;
    NumVerts := Lexer.ReadInt;
    NumIndexes := Lexer.ReadInt;
    SetLength(S.Vertexes, NumVerts);
    for J := 0 to NumVerts - 1 do
    begin
      Lexer.ReadVector(@F[0], 8);
      S.Vertexes[J].Position := Vector3(F[0], F[1], F[2]);
      S.Vertexes[J].ST := Vector2(F[3], F[4]);
      S.Vertexes[J].Normal := Vector3(F[5], F[6], F[7]);
    end;
    SetLength(S.Indexes, NumIndexes);
    for J := 0 to NumIndexes - 1 do
      S.Indexes[J] := Lexer.ReadInt;
    Lexer.Expect('}');
  end;
  Lexer.Expect('}');
end;

procedure TD3ProcFile.ParsePortals(const Lexer: TDoom3Lexer);
var
  NumPortals, I, J, NumPoints: Integer;
begin
  Lexer.Expect('{');
  NumAreas := Lexer.ReadInt;
  NumPortals := Lexer.ReadInt;
  SetLength(Portals, NumPortals);
  for I := 0 to NumPortals - 1 do
  begin
    NumPoints := Lexer.ReadInt;
    Portals[I].PositiveArea := Lexer.ReadInt;
    Portals[I].NegativeArea := Lexer.ReadInt;
    SetLength(Portals[I].Points, NumPoints);
    for J := 0 to NumPoints - 1 do
      Lexer.ReadVector(@Portals[I].Points[J].X, 3);
  end;
  Lexer.Expect('}');
end;

procedure TD3ProcFile.ParseNodes(const Lexer: TDoom3Lexer);
var
  NumNodes, I: Integer;
begin
  Lexer.Expect('{');
  NumNodes := Lexer.ReadInt;
  SetLength(Nodes, NumNodes);
  for I := 0 to NumNodes - 1 do
  begin
    Lexer.ReadVector(@Nodes[I].Plane.X, 4);
    Nodes[I].Children[0] := Lexer.ReadInt;
    Nodes[I].Children[1] := Lexer.ReadInt;
  end;
  Lexer.Expect('}');
end;

function TD3ProcFile.LoadFromText(const Text: String): Boolean;
var
  Lexer: TDoom3Lexer;
  Tok: String;
begin
  Lexer := TDoom3Lexer.Create(Text);
  try
    Tok := Lexer.NextStr;
    if not SameText(Tok, 'mapProcFile003') then
    begin
      WritelnWarning('Doom3Proc', 'Not a Doom 3 .proc file (header "%s")', [Tok]);
      Exit(False);
    end;
    while Lexer.Next(Tok) do
    begin
      if SameText(Tok, 'model') then
        ParseModel(Lexer)
      else
      if SameText(Tok, 'interAreaPortals') then
        ParsePortals(Lexer)
      else
      if SameText(Tok, 'nodes') then
        ParseNodes(Lexer)
      else
      if Lexer.Check('{') then
        Lexer.SkipBracedSection { shadowModel and anything else }
      else
      if Tok = '{' then
        Lexer.SkipBracedSection;
    end;
    { maps without portals have one area }
    if NumAreas = 0 then
      for Tok in FModelIndex.Keys do
        if Copy(Tok, 1, 5) = '_area' then
          Inc(NumAreas);
    Result := True;
  finally
    Lexer.Free;
  end;
end;

function TD3ProcFile.LoadFromVfs(const Path: String): Boolean;
var
  Text: String;
begin
  Text := D3Fs.ReadText(Path);
  if Text = '' then
    Exit(False);
  Result := LoadFromText(Text);
  if Result then
    WritelnLog('Doom3Proc', '"%s": %d models, %d areas, %d portals, %d nodes',
      [Path, FModels.Count, NumAreas, Length(Portals), Length(Nodes)]);
end;

function TD3ProcFile.ModelCount: Integer;
begin
  Result := FModels.Count;
end;

function TD3ProcFile.Model(const I: Integer): TD3ProcModel;
begin
  Result := FModels[I];
end;

function TD3ProcFile.FindModel(const Name: String): TD3ProcModel;
begin
  if not FModelIndex.TryGetValue(LowerCase(Name), Result) then
    Result := nil;
end;

function TD3ProcFile.PointInArea(const P: TVector3): Integer;
var
  N, Child, Guard: Integer;
  D: Single;
begin
  if Length(Nodes) = 0 then
    Exit(0);
  N := 0;
  Guard := 0;
  while Guard < 100000 do
  begin
    Inc(Guard);
    D := Nodes[N].Plane.X * P.X + Nodes[N].Plane.Y * P.Y + Nodes[N].Plane.Z * P.Z + Nodes[N].Plane.W;
    if D > 0 then
      Child := Nodes[N].Children[0]
    else
      Child := Nodes[N].Children[1];
    if Child = 0 then
      Exit(-1);
    if Child < 0 then
      Exit(-1 - Child);
    if Child >= Length(Nodes) then
      Exit(-1);
    N := Child;
  end;
  Result := -1;
end;

end.
