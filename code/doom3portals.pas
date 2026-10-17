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
  TD3PointArray = array of TVector3;

  TD3PortalVisibility = class
  strict private
    FAreaCount: Integer;
    FPoints: array of TD3PointArray;
    FBoxMin, FBoxMax: array of TVector3;
    FAreas: array of array [0..1] of Integer;
    { area -> portals touching it }
    FAreaPortals: array of TD3IntArray;
    FFlowCalls: Integer;
    procedure Flow(const Eye: TVector3; const Area: Integer;
      const Planes: TD3PlaneArray; const Depth: Integer);
  public
    { Per portal: closed (a closed door). }
    PortalClosed: array of Boolean;
    { Result of Compute, per area. }
    AreaVisible: array of Boolean;
    { Number of visible areas after Compute. }
    VisibleCount: Integer;
    constructor Create(const Proc: TD3ProcFile);
    function AreaCount: Integer;
    function PortalCount: Integer;
    { Mark visible areas seen from Eye (in StartArea) within the planes
      (usually the camera frustum's side planes; may be empty). }
    procedure Compute(const Eye: TVector3; const StartArea: Integer;
      const Planes: array of TVector4);
    procedure AllVisible;
    { Areas a light can reach: from StartArea through portals closer than
      Radius to Center. }
    function AreasWithinRadius(const Center: TVector3; const Radius: Single;
      const StartArea: Integer): TD3IntArray;
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
  Math,
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

procedure TD3PortalVisibility.Flow(const Eye: TVector3; const Area: Integer;
  const Planes: TD3PlaneArray; const Depth: Integer);
var
  K, P, Other, J, N: Integer;
  Poly: TD3PointArray;
  NewPlanes: TD3PlaneArray;
  Center, Normal, A, B: TVector3;
  Plane: TVector4;
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

    { clip the portal by the current view volume }
    Poly := Copy(FPoints[P]);
    for J := 0 to High(Planes) do
    begin
      if Length(Poly) < 3 then
        Break;
      Poly := ClipPolygon(Poly, Planes[J]);
    end;
    if Length(Poly) < 3 then
      Continue;

    { the eye is (almost) in the portal: we see everything through it }
    Center := TVector3.Zero;
    for J := 0 to High(Poly) do
      Center := Center + Poly[J];
    Center := Center / Length(Poly);
    Normal := TVector3.CrossProduct(Poly[1] - Poly[0], Poly[2] - Poly[0]);
    if (Normal.Length < 1e-6) or
       (Abs(TVector3.DotProduct(Normal.Normalize, Eye - Poly[0])) < 1) then
    begin
      Flow(Eye, Other, Planes, Depth + 1);
      Continue;
    end;

    { narrow the view to the planes through the eye and the portal's edges }
    N := Length(Poly);
    SetLength(NewPlanes, N);
    for J := 0 to N - 1 do
    begin
      A := Poly[J] - Eye;
      B := Poly[(J + 1) mod N] - Eye;
      Normal := TVector3.CrossProduct(A, B);
      if Normal.Length < 1e-9 then
        Normal := TVector3.Zero
      else
        Normal := Normal.Normalize;
      if TVector3.DotProduct(Normal, Center - Eye) < 0 then
        Normal := -Normal;
      Plane := Vector4(Normal, -TVector3.DotProduct(Normal, Eye));
      NewPlanes[J] := Plane;
    end;
    Flow(Eye, Other, NewPlanes, Depth + 1);
  end;
end;

procedure TD3PortalVisibility.Compute(const Eye: TVector3; const StartArea: Integer;
  const Planes: array of TVector4);
var
  I: Integer;
  Start: TD3PlaneArray;
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
  SetLength(Start, 0);
  for I := 0 to High(Planes) do
    { skip unset planes (a camera before its first render) }
    if Vector3(Planes[I].X, Planes[I].Y, Planes[I].Z).Length > 1e-6 then
    begin
      SetLength(Start, Length(Start) + 1);
      Start[High(Start)] := Planes[I];
    end;
  Flow(Eye, StartArea, Start, 0);
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
