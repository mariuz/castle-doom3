// Doom 3 AAS files (Area Awareness System, "DewmAAS" text files that dmap
// writes next to a map, one per monster size: maps/<map>.aas48...): the
// space a monster can stand in, split into convex areas by a BSP, and the
// reachabilities between areas (walk to the next area, walk off a ledge,
// jump...). Monsters route through them (idAI::PathToGoal) instead of
// walking straight into walls.
//
// Read: the planes, the BSP nodes and the areas with their reachabilities.
// The geometry sections (vertices, edges, faces) and the clusters / portals
// (a routing cache in idAASLocal) are skipped: routing here is a Dijkstra
// search over the areas. Doom 3 coordinates (Z up).
unit Doom3Aas;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  CastleVectors,
  Doom3Lexer;

const
  { travel types (idAASFile's TFL_*) }
  TFL_WALK = 2;
  TFL_WALKOFFLEDGE = 4;
  TFL_BARRIERJUMP = 8;
  TFL_JUMP = 16;
  TFL_LADDER = 32;
  TFL_SWIM = 64;
  TFL_WATERJUMP = 128;
  TFL_TELEPORT = 256;
  TFL_ELEVATOR = 512;
  TFL_FLY = 1024;
  TFL_SPECIAL = 2048;
  TFL_WATER = 4096;
  TFL_AIR = 8192;

  { what our walking monsters can follow: walking, falling off ledges
    (StepTowards drops them to the floor) and the air reachabilities dmap
    adds over gaps }
  WalkingTravelFlags = TFL_WALK or TFL_WALKOFFLEDGE or TFL_AIR;

type
  TD3AasReach = record
    TravelType, ToArea: Integer;
    { where it leaves this area and enters ToArea }
    Start, Stop: TVector3;
    TravelTime: Integer;
  end;

  TD3AasArea = record
    Flags, Contents, Cluster: Integer;
    Reach: array of TD3AasReach;
  end;

  TD3AasNode = record
    Plane: Integer;
    { > 0 a node, < 0 an area (negated), 0 solid }
    Children: array [0..1] of Integer;
  end;

  { A step of a path: the reachability Reach of area Area. }
  TD3AasStep = record
    Area, Reach: Integer;
  end;
  TD3AasPath = array of TD3AasStep;

  TD3AasFile = class
  public
    Name: String;
    { a b c d: a point's distance is a x + b y + c z + d (d is minus the
      file's distance) }
    Planes: array of TVector4;
    Nodes: array of TD3AasNode;
    Areas: array of TD3AasArea;
    function LoadFromText(const Text: String): Boolean;
    function LoadFromVfs(const Path: String): Boolean;
    { The area a point is in, 0 for none (solid, outside). }
    function PointAreaNum(const P: TVector3): Integer;
    { The area of a monster standing at Origin (its feet): a little above
      them, then around them (an origin right on an area's edge). }
    function OriginAreaNum(const Origin: TVector3): Integer;
    { The cheapest path (by travel time, then by the distance between
      reachability points) from area FromArea to area ToArea using only
      TravelFlags reachabilities. False when there's none; an empty path
      when FromArea = ToArea. }
    function FindPath(const FromArea, ToArea: Integer; const TravelFlags: Integer;
      out Path: TD3AasPath): Boolean;
    function ReachCount: Integer;
  end;

implementation

uses
  Math, Generics.Collections,
  CastleLog,
  Doom3Files;

function TD3AasFile.LoadFromText(const Text: String): Boolean;
var
  L: TDoom3Lexer;
  Section: String;
  Count, I, J, N: Integer;
  V: array [0..5] of Single;
begin
  Result := False;
  L := TDoom3Lexer.Create(Text);
  try
    if not SameText(L.NextStr, 'DewmAAS') then
      Exit;
    L.NextStr; { version }
    L.NextStr; { crc }
    while not L.AtEnd do
    begin
      Section := LowerCase(L.NextStr);
      if Section = 'settings' then
      begin
        L.Expect('{');
        L.SkipBracedSection;
        Continue;
      end;
      Count := L.ReadInt;
      if not L.Expect('{') then
        Exit;
      if Section = 'planes' then
      begin
        SetLength(Planes, Count);
        for I := 0 to Count - 1 do
        begin
          L.ReadInt;
          L.ReadVector(@V[0], 4);
          { the file has the normal and the distance (idPlane::SetDist):
            a point's distance is normal . p - dist }
          Planes[I] := Vector4(V[0], V[1], V[2], -V[3]);
        end;
        L.Expect('}');
      end else
      if Section = 'nodes' then
      begin
        SetLength(Nodes, Count);
        for I := 0 to Count - 1 do
        begin
          L.ReadInt;
          L.ReadVector(@V[0], 3);
          Nodes[I].Plane := Round(V[0]);
          Nodes[I].Children[0] := Round(V[1]);
          Nodes[I].Children[1] := Round(V[2]);
        end;
        L.Expect('}');
      end else
      if Section = 'areas' then
      begin
        // num ( flags contents firstFace numFaces cluster clusterAreaNum )
        // numReach, then in braces per reachability:
        // travelType toAreaNum (start) (end) edgeNum travelTime
        SetLength(Areas, Count);
        for I := 0 to Count - 1 do
        begin
          L.ReadInt;
          L.ReadVector(@V[0], 6);
          Areas[I].Flags := Round(V[0]);
          Areas[I].Contents := Round(V[1]);
          Areas[I].Cluster := Round(V[4]);
          N := L.ReadInt;
          L.Expect('{');
          SetLength(Areas[I].Reach, N);
          for J := 0 to N - 1 do
          begin
            Areas[I].Reach[J].TravelType := L.ReadInt;
            Areas[I].Reach[J].ToArea := L.ReadInt;
            L.ReadVector(@V[0], 3);
            Areas[I].Reach[J].Start := Vector3(V[0], V[1], V[2]);
            L.ReadVector(@V[0], 3);
            Areas[I].Reach[J].Stop := Vector3(V[0], V[1], V[2]);
            L.ReadInt; { edge }
            Areas[I].Reach[J].TravelTime := L.ReadInt;
          end;
          L.Expect('}');
        end;
        L.Expect('}');
      end else
        { vertices, edges, faces, portals, clusters... }
        L.SkipBracedSection;
    end;
    Result := (Length(Nodes) > 1) and (Length(Areas) > 1);
  finally
    L.Free;
  end;
end;

function TD3AasFile.LoadFromVfs(const Path: String): Boolean;
var
  Text: String;
begin
  Name := Path;
  Text := D3Fs.ReadText(Path);
  Result := (Text <> '') and LoadFromText(Text);
  if Result then
    WritelnLog('Doom3Aas', '"%s": %d areas, %d reachabilities, %d nodes',
      [Path, Length(Areas) - 1, ReachCount, Length(Nodes) - 1]);
end;

function TD3AasFile.ReachCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(Areas) do
    Inc(Result, Length(Areas[I].Reach));
end;

function TD3AasFile.PointAreaNum(const P: TVector3): Integer;
var
  NodeNum, Guard: Integer;
  Pl: TVector4;
begin
  { idAASFileLocal::PointAreaNum: down the BSP from node 1 }
  Result := 0;
  NodeNum := 1;
  Guard := 0;
  while (NodeNum > 0) and (NodeNum < Length(Nodes)) and (Guard < 10000) do
  begin
    Inc(Guard);
    if (Nodes[NodeNum].Plane < 0) or (Nodes[NodeNum].Plane >= Length(Planes)) then
      Exit;
    Pl := Planes[Nodes[NodeNum].Plane];
    if Pl.X * P.X + Pl.Y * P.Y + Pl.Z * P.Z + Pl.W < 0 then
      NodeNum := Nodes[NodeNum].Children[1]
    else
      NodeNum := Nodes[NodeNum].Children[0];
    if NodeNum < 0 then
    begin
      Result := -NodeNum;
      if Result >= Length(Areas) then
        Result := 0;
      Exit;
    end;
  end;
end;

function TD3AasFile.OriginAreaNum(const Origin: TVector3): Integer;
const
  Offsets: array [0..8] of TVector2 = ((X: 0; Y: 0), (X: 8; Y: 0), (X: -8; Y: 0), (X: 0; Y: 8),
    (X: 0; Y: -8), (X: 16; Y: 16), (X: -16; Y: 16), (X: 16; Y: -16), (X: -16; Y: -16));
const
  Heights: array [0..1] of Single = (4, 24);
var
  I, H: Integer;
begin
  for H := 0 to High(Heights) do
    for I := 0 to High(Offsets) do
    begin
      Result := PointAreaNum(Origin + Vector3(Offsets[I].X, Offsets[I].Y, Heights[H]));
      if Result > 0 then
        Exit;
    end;
  Result := 0;
end;

type
  TQueueItem = record
    Cost: Single;
    Area: Integer;
  end;

function TD3AasFile.FindPath(const FromArea, ToArea: Integer; const TravelFlags: Integer;
  out Path: TD3AasPath): Boolean;
var
  Cost: array of Single;
  { how each area was entered: from area, by its reachability }
  PrevArea, PrevReach: array of Integer;
  Done: array of Boolean;
  Heap: specialize TList<TQueueItem>;
  Item: TQueueItem;
  A, R, B, N, I: Integer;
  C: Single;
  Steps: specialize TList<TD3AasStep>;
  Step: TD3AasStep;

  procedure Push(const ACost: Single; const AArea: Integer);
  var
    K, P: Integer;
    T: TQueueItem;
  begin
    T.Cost := ACost;
    T.Area := AArea;
    Heap.Add(T);
    K := Heap.Count - 1;
    while K > 0 do
    begin
      P := (K - 1) div 2;
      if Heap[P].Cost <= Heap[K].Cost then
        Break;
      T := Heap[P];
      Heap[P] := Heap[K];
      Heap[K] := T;
      K := P;
    end;
  end;

  function Pop: TQueueItem;
  var
    K, L2, R2, M: Integer;
    T: TQueueItem;
  begin
    Result := Heap[0];
    Heap[0] := Heap[Heap.Count - 1];
    Heap.Delete(Heap.Count - 1);
    K := 0;
    while True do
    begin
      L2 := 2 * K + 1;
      R2 := L2 + 1;
      M := K;
      if (L2 < Heap.Count) and (Heap[L2].Cost < Heap[M].Cost) then
        M := L2;
      if (R2 < Heap.Count) and (Heap[R2].Cost < Heap[M].Cost) then
        M := R2;
      if M = K then
        Break;
      T := Heap[M];
      Heap[M] := Heap[K];
      Heap[K] := T;
      K := M;
    end;
  end;

begin
  Path := nil;
  N := Length(Areas);
  Result := (FromArea > 0) and (ToArea > 0) and (FromArea < N) and (ToArea < N);
  if not Result then
    Exit;
  if FromArea = ToArea then
    Exit(True);
  SetLength(Cost, N);
  SetLength(PrevArea, N);
  SetLength(PrevReach, N);
  SetLength(Done, N);
  for I := 0 to N - 1 do
  begin
    Cost[I] := MaxSingle;
    PrevArea[I] := -1;
  end;
  Cost[FromArea] := 0;
  Heap := specialize TList<TQueueItem>.Create;
  try
    Push(0, FromArea);
    while Heap.Count > 0 do
    begin
      Item := Pop;
      A := Item.Area;
      if Done[A] then
        Continue;
      Done[A] := True;
      if A = ToArea then
        Break;
      for R := 0 to High(Areas[A].Reach) do
      begin
        if (Areas[A].Reach[R].TravelType and TravelFlags) = 0 then
          Continue;
        B := Areas[A].Reach[R].ToArea;
        if (B <= 0) or (B >= N) or Done[B] then
          Continue;
        { the travel time (hundredths of a second) and the way from where we
          entered A to where we leave it }
        C := Cost[A] + Areas[A].Reach[R].TravelTime + 1;
        if PrevArea[A] >= 0 then
          C := C + PointsDistance(Areas[PrevArea[A]].Reach[PrevReach[A]].Stop,
            Areas[A].Reach[R].Start) / 4
        else
          C := C + 0.1;
        if C < Cost[B] then
        begin
          Cost[B] := C;
          PrevArea[B] := A;
          PrevReach[B] := R;
          Push(C, B);
        end;
      end;
    end;
  finally
    Heap.Free;
  end;
  Result := PrevArea[ToArea] >= 0;
  if not Result then
    Exit;
  Steps := specialize TList<TD3AasStep>.Create;
  try
    B := ToArea;
    while B <> FromArea do
    begin
      Step.Area := PrevArea[B];
      Step.Reach := PrevReach[B];
      Steps.Insert(0, Step);
      B := PrevArea[B];
    end;
    SetLength(Path, Steps.Count);
    for I := 0 to Steps.Count - 1 do
      Path[I] := Steps[I];
  finally
    Steps.Free;
  end;
end;

end.
