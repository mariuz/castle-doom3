// Portal visibility, like Doom 3's renderer: start in the camera's area and
// flow through the inter-area portals. Each portal polygon is clipped by the
// current view volume (the camera frustum, then narrowed by the portals it
// was seen through) and narrowed again to the planes through the eye and the
// clipped polygon's edges. Closed portals (closed doors) stop the flow.
//
// Lights get the set of areas they can reach: flood from the light's area
// through the portals within its radius (computed once, ignoring doors).
//
// Everything here is in CGE coordinates. A plane is a TVector4 (normal xyz,
// w); a point is inside when dot(normal, point) + w >= 0, like CGE's
// TFrustum planes.
unit Doom3Portals;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Generics.Collections,
  CastleVectors, CastleBoxes,
  Doom3Proc;

type
  TD3PlaneArray = array of TVector4;
  TD3IntArray = array of Integer;
  TD3BoolArray = array of Boolean;
  TD3PointArray = array of TVector3;

  { A flow's view volume and clipped portal: fixed arrays, no heap (the
    flow is called thousands of times a frame in open maps). }
  TD3FlowPlanes = record
    Count: Integer;
    P: array [0..31] of TVector4;
  end;

  TD3FlowPoly = record
    Count: Integer;
    P: array [0..95] of TVector3;
  end;

  TD3PortalVisibility = class
  strict private
    FAreaCount: Integer;
    FPoints: array of TD3PointArray;
    FBoxMin, FBoxMax: array of TVector3;
    FAreas: array of array [0..1] of Integer;
    { area -> portals touching it }
    FAreaPortals: array of TD3IntArray;
    FFlowCalls: Integer;
    { the portal's plane, and on which side of it the portal's positive
      area is (1 the normal's, -1 the other, 0 unknown) }
    FPlanes: array of TVector4;
    FSides: array of Integer;
    FCheckCount: Integer;
    FCheckCalls, FCheckCallsOld: Int64;
    procedure Flow(const Eye: TVector3; const Area: Integer;
      const Planes: TD3FlowPlanes; const Depth: Integer);
    procedure FlowLight(const Origin: TVector3; const Area: Integer;
      const Planes, BoxPlanes: TD3FlowPlanes; const Depth: Integer;
      var Reached: TD3BoolArray; var Calls: Integer);
  public
    { Flow only through portals that face the eye (default). False: the
      older flow through every portal, to compare. }
    UseSides: Boolean;
    { Every Compute also flows without UseSides and logs a warning when
      the areas differ (env CD3_PORTAL_CHECK=1). }
    CheckSides: Boolean;
    { Per portal: closed (a closed door). }
    PortalClosed: array of Boolean;
    { Result of Compute, per area. }
    AreaVisible: array of Boolean;
    { Number of visible areas after Compute. }
    VisibleCount: Integer;
    constructor Create(const Proc: TD3ProcFile);
    function AreaCount: Integer;
    function PortalCount: Integer;
    { Portals whose sides (which area is in front) are known: the flow
      only passes those towards the eye's side. }
    function KnownSideCount: Integer;
    { Flow calls of the last Compute / ComputeAround. }
    property FlowCalls: Integer read FFlowCalls;
    { Mark visible areas seen from Eye (in StartArea) within the planes
      (usually the camera frustum's side planes; may be empty). }
    procedure Compute(const Eye: TVector3; const StartArea: Integer;
      const Planes: array of TVector4);
    procedure AllVisible;
    { The areas seen from Eye in every direction (like Compute without
      planes), into Visible, keeping AreaVisible (the view's) as it was:
      the player's PVS for the monsters' dormancy. }
    procedure ComputeAround(const Eye: TVector3; const StartArea: Integer;
      var Visible: TD3BoolArray);
    { Areas a light can reach: from StartArea through portals closer than
      Radius to Center. }
    function AreasWithinRadius(const Center: TVector3; const Radius: Single;
      const StartArea: Integer): TD3IntArray;
    { The areas a light flows into from Origin (in StartArea) through
      portals, open or closed, within its box (Doom 3 coordinates), each
      portal narrowing the volume to the planes through Origin and its
      edges (idRenderWorldLocal::FlowLightThroughPortals: Doom 3's area
      references of lights with a precomputed shadow volume). }
    function LightFlowAreas(const Origin: TVector3; const StartArea: Integer;
      const BoxMin, BoxMax: TVector3): TD3IntArray;
    { Portals whose polygon center is inside the box (for doors). }
    function PortalsInBox(const Box: TBox3D): TD3IntArray;
    { The first portal whose bounding box touches Box, -1 when none
      (idRenderWorld::FindPortal, for info_locationSeparator). }
    function FindPortal(const Box: TBox3D): Integer;
    function PortalCenter(const I: Integer): TVector3;
    { The area on one side (0 positive, 1 negative) of a portal. }
    function PortalArea(const I, Side: Integer): Integer;
  end;

{ Clip a convex polygon by a plane (keeps the inside). }
function ClipPolygon(const Points: array of TVector3; const Plane: TVector4): TD3PointArray;

implementation

uses
  Math, CastleLog,
  Doom3MapFile;

const
  MaxFlowDepth = 64;
  MaxFlowCalls = 20000;

function PlaneDist(const Plane: TVector4; const P: TVector3): Single; inline;
begin
  Result := Plane.X * P.X + Plane.Y * P.Y + Plane.Z * P.Z + Plane.W;
end;

function ClipPolygon(const Points: array of TVector3; const Plane: TVector4): TD3PointArray;
var
  I, N: Integer;
  A, B: TVector3;
  DA, DB: Single;
begin
  Result := nil;
  N := Length(Points);
  for I := 0 to N - 1 do
  begin
    A := Points[I];
    B := Points[(I + 1) mod N];
    DA := PlaneDist(Plane, A);
    DB := PlaneDist(Plane, B);
    if DA >= 0 then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := A;
    end;
    if (DA >= 0) <> (DB >= 0) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := A + (B - A) * (DA / (DA - DB));
    end;
  end;
end;

{ TD3PortalVisibility }

constructor TD3PortalVisibility.Create(const Proc: TD3ProcFile);

  { On which side of portal I its positive area is: points a little off
    the portal's middle, asked from the BSP tree. }
  procedure FindSide(const I: Integer);
  const
    Offsets: array [0..1] of Single = (4, 16);
  var
    J, K, Front, Back: Integer;
    Middle, Normal: TVector3;
  begin
    FSides[I] := 0;
    FPlanes[I] := TVector4.Zero;
    if (Length(FPoints[I]) < 3) or (Length(Proc.Nodes) = 0) or (FAreas[I][0] = FAreas[I][1]) then
      Exit;
    Middle := TVector3.Zero;
    for J := 0 to High(FPoints[I]) do
      Middle := Middle + FPoints[I][J];
    Middle := Middle / Length(FPoints[I]);
    Normal := TVector3.Zero;
    for J := 2 to High(FPoints[I]) do
    begin
      Normal := TVector3.CrossProduct(FPoints[I][1] - FPoints[I][0], FPoints[I][J] - FPoints[I][0]);
      if Normal.Length > 1e-3 then
        Break;
    end;
    if Normal.Length <= 1e-3 then
      Exit;
    Normal := Normal.Normalize;
    FPlanes[I] := Vector4(Normal, -TVector3.DotProduct(Normal, FPoints[I][0]));
    for K := 0 to High(Offsets) do
    begin
      Front := Proc.PointInArea(CgeToD3(Middle + Normal * Offsets[K]));
      Back := Proc.PointInArea(CgeToD3(Middle - Normal * Offsets[K]));
      if (Front = FAreas[I][0]) and (Back = FAreas[I][1]) then
        FSides[I] := 1
      else
      if (Front = FAreas[I][1]) and (Back = FAreas[I][0]) then
        FSides[I] := -1;
      if FSides[I] <> 0 then
        Exit;
    end;
  end;

var
  I, J, A: Integer;
  Count: Integer;
begin
  inherited Create;
  FAreaCount := Proc.NumAreas;
  Count := Length(Proc.Portals);
  SetLength(FPoints, Count);
  SetLength(FBoxMin, Count);
  SetLength(FBoxMax, Count);
  SetLength(FAreas, Count);
  SetLength(FPlanes, Count);
  SetLength(FSides, Count);
  SetLength(PortalClosed, Count);
  SetLength(FAreaPortals, FAreaCount);
  SetLength(AreaVisible, FAreaCount);
  for I := 0 to Count - 1 do
  begin
    SetLength(FPoints[I], Length(Proc.Portals[I].Points));
    for J := 0 to High(FPoints[I]) do
    begin
      FPoints[I][J] := D3ToCge(Proc.Portals[I].Points[J]);
      if J = 0 then
      begin
        FBoxMin[I] := FPoints[I][J];
        FBoxMax[I] := FPoints[I][J];
      end else
      begin
        FBoxMin[I] := Vector3(Min(FBoxMin[I].X, FPoints[I][J].X), Min(FBoxMin[I].Y, FPoints[I][J].Y),
          Min(FBoxMin[I].Z, FPoints[I][J].Z));
        FBoxMax[I] := Vector3(Max(FBoxMax[I].X, FPoints[I][J].X), Max(FBoxMax[I].Y, FPoints[I][J].Y),
          Max(FBoxMax[I].Z, FPoints[I][J].Z));
      end;
    end;
    FAreas[I][0] := Proc.Portals[I].PositiveArea;
    FAreas[I][1] := Proc.Portals[I].NegativeArea;
    FindSide(I);
    for J := 0 to 1 do
    begin
      A := FAreas[I][J];
      if (A >= 0) and (A < FAreaCount) then
      begin
        SetLength(FAreaPortals[A], Length(FAreaPortals[A]) + 1);
        FAreaPortals[A][High(FAreaPortals[A])] := I;
      end;
    end;
  end;
  UseSides := True;
  CheckSides := GetEnvironmentVariable('CD3_PORTAL_CHECK') = '1';
  AllVisible;
end;

function TD3PortalVisibility.AreaCount: Integer;
begin
  Result := FAreaCount;
end;

function TD3PortalVisibility.PortalCount: Integer;
begin
  Result := Length(FPoints);
end;

function TD3PortalVisibility.KnownSideCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FSides) do
    if FSides[I] <> 0 then
      Inc(Result);
end;

procedure TD3PortalVisibility.AllVisible;
var
  I: Integer;
begin
  for I := 0 to High(AreaVisible) do
    AreaVisible[I] := True;
  VisibleCount := Length(AreaVisible);
end;

function TD3PortalVisibility.PortalCenter(const I: Integer): TVector3;
begin
  Result := (FBoxMin[I] + FBoxMax[I]) * 0.5;
end;

{ Poly clipped by a plane (keeps the inside), like ClipPolygon. }
procedure ClipFlowPoly(const Source: TD3FlowPoly; const Plane: TVector4; out Dest: TD3FlowPoly);
var
  I: Integer;
  A, B: TVector3;
  DA, DB: Single;
begin
  Dest.Count := 0;
  for I := 0 to Source.Count - 1 do
  begin
    A := Source.P[I];
    if I + 1 < Source.Count then
      B := Source.P[I + 1]
    else
      B := Source.P[0];
    DA := PlaneDist(Plane, A);
    DB := PlaneDist(Plane, B);
    if (DA >= 0) and (Dest.Count <= High(Dest.P)) then
    begin
      Dest.P[Dest.Count] := A;
      Inc(Dest.Count);
    end;
    if ((DA >= 0) <> (DB >= 0)) and (Dest.Count <= High(Dest.P)) then
    begin
      Dest.P[Dest.Count] := A + (B - A) * (DA / (DA - DB));
      Inc(Dest.Count);
    end;
  end;
end;

procedure TD3PortalVisibility.Flow(const Eye: TVector3; const Area: Integer;
  const Planes: TD3FlowPlanes; const Depth: Integer);
var
  K, P, Other, J, N: Integer;
  Poly, Clipped: TD3FlowPoly;
  NewPlanes: TD3FlowPlanes;
  Center, Normal, A, B: TVector3;
  D: Single;
begin
  Inc(FFlowCalls);
  if not AreaVisible[Area] then
  begin
    AreaVisible[Area] := True;
    Inc(VisibleCount);
  end;
  if (Depth >= MaxFlowDepth) or (FFlowCalls >= MaxFlowCalls) then
    Exit;
  for K := 0 to High(FAreaPortals[Area]) do
  begin
    P := FAreaPortals[Area][K];
    if PortalClosed[P] then
      Continue;
    if FAreas[P][0] = Area then
      Other := FAreas[P][1]
    else
      Other := FAreas[P][0];
    if (Other < 0) or (Other >= FAreaCount) or (Other = Area) then
      Continue;
    { only through portals that face the eye from this area
      (idRenderWorldLocal::FloodViewThroughArea_r): never back through the
      portal the view came by, which made the flow bounce between two
      areas, thousands of calls in open maps. Not from the start area: the
      eye may be outside it (noclip in a wall). }
    if UseSides and (Depth > 0) and (FSides[P] <> 0) then
    begin
      D := PlaneDist(FPlanes[P], Eye) * FSides[P];
      if FAreas[P][0] <> Area then
        D := -D;
      if D < -1 then
        Continue;
    end;

    { clip the portal by the current view volume }
    Poly.Count := Min(Length(FPoints[P]), Length(Poly.P) div 2);
    for J := 0 to Poly.Count - 1 do
      Poly.P[J] := FPoints[P][J];
    for J := 0 to Planes.Count - 1 do
    begin
      if Poly.Count < 3 then
        Break;
      ClipFlowPoly(Poly, Planes.P[J], Clipped);
      Poly := Clipped;
    end;
    if Poly.Count < 3 then
      Continue;

    { the eye is (almost) in the portal: we see everything through it }
    Center := TVector3.Zero;
    for J := 0 to Poly.Count - 1 do
      Center := Center + Poly.P[J];
    Center := Center / Poly.Count;
    Normal := TVector3.CrossProduct(Poly.P[1] - Poly.P[0], Poly.P[2] - Poly.P[0]);
    if (Normal.Length < 1e-6) or
       (Abs(TVector3.DotProduct(Normal.Normalize, Eye - Poly.P[0])) < 1) or
       { more edges than planes fit (never seen): the view stays as wide }
       (Poly.Count > Length(NewPlanes.P)) then
    begin
      Flow(Eye, Other, Planes, Depth + 1);
      Continue;
    end;

    { narrow the view to the planes through the eye and the portal's edges }
    N := Poly.Count;
    NewPlanes.Count := N;
    for J := 0 to N - 1 do
    begin
      A := Poly.P[J] - Eye;
      B := Poly.P[(J + 1) mod N] - Eye;
      Normal := TVector3.CrossProduct(A, B);
      if Normal.Length < 1e-9 then
        Normal := TVector3.Zero
      else
        Normal := Normal.Normalize;
      if TVector3.DotProduct(Normal, Center - Eye) < 0 then
        Normal := -Normal;
      NewPlanes.P[J] := Vector4(Normal, -TVector3.DotProduct(Normal, Eye));
    end;
    Flow(Eye, Other, NewPlanes, Depth + 1);
  end;
end;

procedure TD3PortalVisibility.FlowLight(const Origin: TVector3; const Area: Integer;
  const Planes, BoxPlanes: TD3FlowPlanes; const Depth: Integer;
  var Reached: TD3BoolArray; var Calls: Integer);
var
  K, P, Other, J, N: Integer;
  Poly, Clipped: TD3FlowPoly;
  NewPlanes: TD3FlowPlanes;
  Center, Normal, A, B: TVector3;
  D: Single;
begin
  Inc(Calls);
  Reached[Area] := True;
  if (Depth >= MaxFlowDepth) or (Calls >= MaxFlowCalls) then
    Exit;
  for K := 0 to High(FAreaPortals[Area]) do
  begin
    P := FAreaPortals[Area][K];
    if FAreas[P][0] = Area then
      Other := FAreas[P][1]
    else
      Other := FAreas[P][0];
    if (Other < 0) or (Other >= FAreaCount) or (Other = Area) then
      Continue;
    { only through portals facing away from the light, like Flow }
    if (Depth > 0) and (FSides[P] <> 0) then
    begin
      D := PlaneDist(FPlanes[P], Origin) * FSides[P];
      if FAreas[P][0] <> Area then
        D := -D;
      if D < -1 then
        Continue;
    end;

    { the portal clipped by the volume so far and by the light's box }
    Poly.Count := Min(Length(FPoints[P]), Length(Poly.P) div 2);
    for J := 0 to Poly.Count - 1 do
      Poly.P[J] := FPoints[P][J];
    for J := 0 to Planes.Count - 1 do
    begin
      if Poly.Count < 3 then
        Break;
      ClipFlowPoly(Poly, Planes.P[J], Clipped);
      Poly := Clipped;
    end;
    for J := 0 to BoxPlanes.Count - 1 do
    begin
      if Poly.Count < 3 then
        Break;
      ClipFlowPoly(Poly, BoxPlanes.P[J], Clipped);
      Poly := Clipped;
    end;
    if Poly.Count < 3 then
      Continue;

    { the light is (almost) in the portal: it passes whole }
    Center := TVector3.Zero;
    for J := 0 to Poly.Count - 1 do
      Center := Center + Poly.P[J];
    Center := Center / Poly.Count;
    Normal := TVector3.CrossProduct(Poly.P[1] - Poly.P[0], Poly.P[2] - Poly.P[0]);
    if (Normal.Length < 1e-6) or
       (Abs(TVector3.DotProduct(Normal.Normalize, Origin - Poly.P[0])) < 1) or
       (Poly.Count > Length(NewPlanes.P)) then
    begin
      FlowLight(Origin, Other, Planes, BoxPlanes, Depth + 1, Reached, Calls);
      Continue;
    end;

    { narrow the volume to the planes through the light and the edges }
    N := Poly.Count;
    NewPlanes.Count := N;
    for J := 0 to N - 1 do
    begin
      A := Poly.P[J] - Origin;
      B := Poly.P[(J + 1) mod N] - Origin;
      Normal := TVector3.CrossProduct(A, B);
      if Normal.Length < 1e-9 then
        Normal := TVector3.Zero
      else
        Normal := Normal.Normalize;
      if TVector3.DotProduct(Normal, Center - Origin) < 0 then
        Normal := -Normal;
      NewPlanes.P[J] := Vector4(Normal, -TVector3.DotProduct(Normal, Origin));
    end;
    FlowLight(Origin, Other, NewPlanes, BoxPlanes, Depth + 1, Reached, Calls);
  end;
end;

function TD3PortalVisibility.LightFlowAreas(const Origin: TVector3; const StartArea: Integer;
  const BoxMin, BoxMax: TVector3): TD3IntArray;
var
  BoxPlanes, NoPlanes: TD3FlowPlanes;
  Reached: TD3BoolArray;
  I, N, Calls: Integer;
begin
  Result := nil;
  if (StartArea < 0) or (StartArea >= FAreaCount) then
    Exit;
  { inside: dist >= 0 }
  BoxPlanes.Count := 6;
  BoxPlanes.P[0] := Vector4( 1, 0, 0, -BoxMin.X);
  BoxPlanes.P[1] := Vector4(-1, 0, 0,  BoxMax.X);
  BoxPlanes.P[2] := Vector4(0,  1, 0, -BoxMin.Y);
  BoxPlanes.P[3] := Vector4(0, -1, 0,  BoxMax.Y);
  BoxPlanes.P[4] := Vector4(0, 0,  1, -BoxMin.Z);
  BoxPlanes.P[5] := Vector4(0, 0, -1,  BoxMax.Z);
  NoPlanes.Count := 0;
  SetLength(Reached, FAreaCount);
  Calls := 0;
  FlowLight(Origin, StartArea, NoPlanes, BoxPlanes, 0, Reached, Calls);
  N := 0;
  for I := 0 to FAreaCount - 1 do
    if Reached[I] then
      Inc(N);
  SetLength(Result, N);
  N := 0;
  for I := 0 to FAreaCount - 1 do
    if Reached[I] then
    begin
      Result[N] := I;
      Inc(N);
    end;
end;

procedure TD3PortalVisibility.Compute(const Eye: TVector3; const StartArea: Integer;
  const Planes: array of TVector4);
var
  I, Calls, Differ, Missing: Integer;
  Start: TD3FlowPlanes;
  WithSides: array of Boolean;
begin
  if (StartArea < 0) or (StartArea >= FAreaCount) then
  begin
    { outside the map (noclip): draw everything }
    AllVisible;
    Exit;
  end;
  for I := 0 to High(AreaVisible) do
    AreaVisible[I] := False;
  VisibleCount := 0;
  FFlowCalls := 0;
  Start.Count := 0;
  for I := 0 to High(Planes) do
    { skip unset planes (a camera before its first render) }
    if (Vector3(Planes[I].X, Planes[I].Y, Planes[I].Z).Length > 1e-6) and (Start.Count <= High(Start.P)) then
    begin
      Start.P[Start.Count] := Planes[I];
      Inc(Start.Count);
    end;
  Flow(Eye, StartArea, Start, 0);
  if CheckSides and UseSides then
  begin
    WithSides := Copy(AreaVisible);
    Calls := FFlowCalls;
    UseSides := False;
    for I := 0 to High(AreaVisible) do
      AreaVisible[I] := False;
    FFlowCalls := 0;
    Flow(Eye, StartArea, Start, 0);
    UseSides := True;
    Differ := 0;
    Missing := 0;
    for I := 0 to High(AreaVisible) do
      if AreaVisible[I] <> WithSides[I] then
      begin
        Inc(Differ);
        { seen only without the sides }
        if AreaVisible[I] then
          Inc(Missing);
      end;
    if Differ > 0 then
      WritelnWarning('Doom3Portals', 'Side check: %d areas differ (%d seen only without sides) from eye %s in area %d (%d planes; %d flow calls with sides, %d without)',
        [Differ, Missing, Eye.ToString, StartArea, Start.Count, Calls, FFlowCalls]);
    Inc(FCheckCount);
    FCheckCalls := FCheckCalls + Calls;
    FCheckCallsOld := FCheckCallsOld + FFlowCalls;
    if FCheckCount mod 2000 = 0 then
      WritelnLog('Doom3Portals', 'Side check: %d computes, %d flow calls with sides, %d without',
        [FCheckCount, FCheckCalls, FCheckCallsOld]);
    AreaVisible := WithSides;
    VisibleCount := 0;
    for I := 0 to High(AreaVisible) do
      if AreaVisible[I] then
        Inc(VisibleCount);
    FFlowCalls := Calls;
  end;
end;

procedure TD3PortalVisibility.ComputeAround(const Eye: TVector3; const StartArea: Integer;
  var Visible: TD3BoolArray);
var
  Saved: array of Boolean;
  SavedCount: Integer;
  SavedClosed: array of Boolean;
begin
  Saved := Copy(AreaVisible);
  SavedCount := VisibleCount;
  { through closed doors too: Doom 3's PVS is the map's geometry
    (idPVS::SetupCurrentPVS with PVS_NORMAL), a monster behind a closed
    door stays awake }
  SavedClosed := Copy(PortalClosed);
  if Length(PortalClosed) > 0 then
    FillChar(PortalClosed[0], Length(PortalClosed) * SizeOf(Boolean), 0);
  try
    Compute(Eye, StartArea, []);
  finally
    PortalClosed := SavedClosed;
  end;
  Visible := Copy(AreaVisible);
  AreaVisible := Saved;
  VisibleCount := SavedCount;
end;

function TD3PortalVisibility.AreasWithinRadius(const Center: TVector3; const Radius: Single;
  const StartArea: Integer): TD3IntArray;
var
  Visited: array of Boolean;
  Queue: TD3IntArray;
  Head, K, P, Other, J: Integer;
  Closest: TVector3;
begin
  Result := nil;
  if (StartArea < 0) or (StartArea >= FAreaCount) then
    Exit;
  SetLength(Visited, FAreaCount);
  Queue := [StartArea];
  Visited[StartArea] := True;
  Head := 0;
  while Head < Length(Queue) do
  begin
    for K := 0 to High(FAreaPortals[Queue[Head]]) do
    begin
      P := FAreaPortals[Queue[Head]][K];
      if FAreas[P][0] = Queue[Head] then
        Other := FAreas[P][1]
      else
        Other := FAreas[P][0];
      if (Other < 0) or (Other >= FAreaCount) or Visited[Other] then
        Continue;
      { the light reaches the portal's box? }
      for J := 0 to 2 do
        Closest.Data[J] := Max(FBoxMin[P].Data[J], Min(Center.Data[J], FBoxMax[P].Data[J]));
      if PointsDistance(Closest, Center) > Radius then
        Continue;
      Visited[Other] := True;
      Queue := Concat(Queue, [Other]);
    end;
    Inc(Head);
  end;
  Result := Queue;
end;

function TD3PortalVisibility.PortalArea(const I, Side: Integer): Integer;
begin
  Result := FAreas[I][Side];
end;

function TD3PortalVisibility.PortalsInBox(const Box: TBox3D): TD3IntArray;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to High(FPoints) do
    if Box.Contains(PortalCenter(I)) then
      Result := Concat(Result, [I]);
end;

function TD3PortalVisibility.FindPortal(const Box: TBox3D): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FPoints) do
    if Box.Collides(Box3D(FBoxMin[I], FBoxMax[I])) then
      Exit(I);
  Result := -1;
end;

end.
