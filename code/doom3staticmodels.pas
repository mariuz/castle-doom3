{ Doom 3 static models: LightWave objects (.lwo, LWO2) and 3ds Max ASCII
  exports (.ase), used for props, items, light fixtures and func_static
  models.

  Both are read into TD3StaticModel: surfaces per material with positions in
  Doom 3 coordinates, texture coordinates already in CGE's convention and
  triangles counter-clockwise from the front.

  - LWO2 is left-handed and Y up; Doom 3 reads points as (x, z, y), which
    mirrors them, so its polygons end up counter-clockwise seen from the
    front. Texture t = 1 - v, so CGE's v = 1 - t is the file's v. VMAD
    entries override UVs per polygon (texture seams). The polygon's surface
    tag is the material name.
  - ASE is right-handed and Z up like Doom 3; Doom flips faces (A, C, B) to
    its clockwise style, so the file's order is counter-clockwise. The
    material is the *BITMAP path from "base/" on, without its extension. }
unit Doom3StaticModels;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleVectors, X3DNodes;

type
  TD3StaticSurface = class
    Material: String;
    Positions: array of TVector3; { Doom 3 coordinates }
    TexCoords: array of TVector2; { CGE convention }
    Indexes: array of Int32;      { counter-clockwise from the front }
    function TriangleCount: Integer;
    { Smooth normals like Doom 3: vertexes with the same position and
      texture coordinate share a normal (Doom 3 coordinates). }
    function ComputeNormals: TVector3List;
  end;

  TD3StaticModel = class
  strict private
    FClosedKnown, FClosed: Boolean;
    function SurfaceFor(const Material: String): TD3StaticSurface;
  public
    Name: String;
    Surfaces: specialize TObjectList<TD3StaticSurface>;
    BoundsMin, BoundsMax: TVector3; { Doom 3 coordinates }
    constructor Create;
    destructor Destroy; override;
    function LoadLwo(const Stream: TStream): Boolean;
    function LoadAse(const Text: String): Boolean;
    procedure UpdateBounds;
    function TriangleCount: Integer;
    { X3D shapes for the model (fresh nodes on every call). A skin remaps
      materials. }
    function BuildNode(const SkinName: String = ''; const EntityKeys: TStrings = nil): TX3DRootNode;
    { Some surface is closed (TrianglesClosed): worth casting shadows. }
    function HasClosedSurface: Boolean;
  end;

  TD3StaticModelCache = class
  strict private
    FModels: specialize TObjectDictionary<String, TD3StaticModel>;
  public
    constructor Create;
    destructor Destroy; override;
    { Parsed model or nil when missing / invalid (also cached). }
    function Model(const Path: String): TD3StaticModel;
    procedure Clear;
  end;

{ Is this a static model file we can load (.lwo, .ase)? }
function IsStaticModelPath(const Path: String): Boolean;

{ Material name of an ASE *BITMAP path: from "base/" on, no extension. }
function AseBitmapToMaterial(const Bitmap: String): String;

var
  StaticModels: TD3StaticModelCache;

implementation

uses
  Math,
  CastleLog,
  Doom3Files, Doom3Lexer, Doom3Decls, Doom3MapFile, Doom3Materials, Doom3LightEffects, Doom3Gui,
  Doom3Collision;

function IsStaticModelPath(const Path: String): Boolean;
var
  Ext: String;
begin
  Ext := LowerCase(ExtractFileExt(Path));
  Result := (Ext = '.lwo') or (Ext = '.ase');
end;

function AseBitmapToMaterial(const Bitmap: String): String;
const
  Roots: array [0..2] of String = ('textures/', 'models/', 'gfx/');
var
  S: String;
  P, I: Integer;
begin
  S := LowerCase(StringReplace(Bitmap, '\', '/', [rfReplaceAll]));
  P := Pos('/base/', S);
  if P > 0 then
    S := Copy(S, P + Length('/base/'), MaxInt)
  else
  if Copy(S, 1, 5) = 'base/' then
    S := Copy(S, 6, MaxInt)
  else
    { no game directory in the path: start at a known root }
    for I := Low(Roots) to High(Roots) do
    begin
      P := Pos(Roots[I], S);
      if P > 0 then
      begin
        S := Copy(S, P, MaxInt);
        Break;
      end;
    end;
  Result := ChangeFileExt(NormalizeD3Path(S), '');
end;

{ TD3StaticSurface }

function TD3StaticSurface.TriangleCount: Integer;
begin
  Result := Length(Indexes) div 3;
end;

function TD3StaticSurface.ComputeNormals: TVector3List;
var
  Keys: specialize TDictionary<String, Integer>;
  Group: array of Integer;
  Sums: array of TVector3;
  I, T, G: Integer;
  Key: String;
  N: TVector3;
begin
  Keys := specialize TDictionary<String, Integer>.Create;
  try
    SetLength(Group, Length(Positions));
    for I := 0 to High(Positions) do
    begin
      Key := Format('%.2f %.2f %.2f %.4f %.4f', [Positions[I].X, Positions[I].Y, Positions[I].Z,
        TexCoords[I].X, TexCoords[I].Y]);
      if not Keys.TryGetValue(Key, G) then
      begin
        G := Keys.Count;
        Keys.Add(Key, G);
      end;
      Group[I] := G;
    end;
    SetLength(Sums, Keys.Count);
    T := 0;
    while T + 2 < Length(Indexes) do
    begin
      { counter-clockwise from the front, right-handed: (b - a) x (c - a) }
      N := TVector3.CrossProduct(Positions[Indexes[T + 1]] - Positions[Indexes[T]],
        Positions[Indexes[T + 2]] - Positions[Indexes[T]]);
      for I := 0 to 2 do
        Sums[Group[Indexes[T + I]]] := Sums[Group[Indexes[T + I]]] + N;
      Inc(T, 3);
    end;
    Result := TVector3List.Create;
    Result.Count := Length(Positions);
    for I := 0 to High(Positions) do
    begin
      N := Sums[Group[I]];
      if N.Length > 1e-8 then
        N := N.Normalize
      else
        N := Vector3(0, 0, 1);
      Result[I] := N;
    end;
  finally
    Keys.Free;
  end;
end;

{ TD3StaticModel }

constructor TD3StaticModel.Create;
begin
  inherited Create;
  Surfaces := specialize TObjectList<TD3StaticSurface>.Create(True);
end;

destructor TD3StaticModel.Destroy;
begin
  Surfaces.Free;
  inherited Destroy;
end;

function TD3StaticModel.SurfaceFor(const Material: String): TD3StaticSurface;
var
  Key: String;
begin
  Key := ChangeFileExt(NormalizeD3Path(Material), '');
  for Result in Surfaces do
    if Result.Material = Key then
      Exit;
  Result := TD3StaticSurface.Create;
  Result.Material := Key;
  Surfaces.Add(Result);
end;

procedure TD3StaticModel.UpdateBounds;
var
  S: TD3StaticSurface;
  P: TVector3;
  Any: Boolean;
begin
  Any := False;
  BoundsMin := TVector3.Zero;
  BoundsMax := TVector3.Zero;
  for S in Surfaces do
    for P in S.Positions do
      if not Any then
      begin
        BoundsMin := P;
        BoundsMax := P;
        Any := True;
      end else
      begin
        BoundsMin := Vector3(Min(BoundsMin.X, P.X), Min(BoundsMin.Y, P.Y), Min(BoundsMin.Z, P.Z));
        BoundsMax := Vector3(Max(BoundsMax.X, P.X), Max(BoundsMax.Y, P.Y), Max(BoundsMax.Z, P.Z));
      end;
end;

function TD3StaticModel.TriangleCount: Integer;
var
  S: TD3StaticSurface;
begin
  Result := 0;
  for S in Surfaces do
    Inc(Result, S.TriangleCount);
end;

{ LWO2 ----------------------------------------------------------------------- }

type
  TLwoReader = class
    Data: TBytes;
    Pos, Limit: Integer;
    function U1: Byte;
    function U2: Word;
    function U4: LongWord;
    function F4: Single;
    function VX: Integer;
    function S0: String;
  end;

function TLwoReader.U1: Byte;
begin
  Result := Data[Pos];
  Inc(Pos);
end;

function TLwoReader.U2: Word;
begin
  Result := (Data[Pos] shl 8) or Data[Pos + 1];
  Inc(Pos, 2);
end;

function TLwoReader.U4: LongWord;
begin
  Result := (LongWord(Data[Pos]) shl 24) or (LongWord(Data[Pos + 1]) shl 16) or
    (LongWord(Data[Pos + 2]) shl 8) or Data[Pos + 3];
  Inc(Pos, 4);
end;

function TLwoReader.F4: Single;
var
  L: LongWord;
begin
  L := U4;
  Move(L, Result, 4);
end;

function TLwoReader.VX: Integer;
begin
  { variable length index: 2 bytes, or 4 bytes starting with $FF }
  if Data[Pos] = $FF then
    Result := Integer(U4 and $00FFFFFF)
  else
    Result := U2;
end;

function TLwoReader.S0: String;
var
  Start: Integer;
begin
  Start := Pos;
  while (Pos < Limit) and (Data[Pos] <> 0) do
    Inc(Pos);
  SetString(Result, PChar(@Data[Start]), Pos - Start);
  Inc(Pos); { the terminating zero }
  if ((Pos - Start) and 1) <> 0 then
    Inc(Pos); { strings are padded to an even length }
end;

function TD3StaticModel.LoadLwo(const Stream: TStream): Boolean;
type
  TPolygon = record
    Verts: array of Integer;
    UVs: array of TVector2;     { per polygon-vertex (VMAD), else from VMAP }
    HasUV: array of Boolean;
    Tag: Integer;
  end;
var
  R: TLwoReader;
  ChunkId: String;
  ChunkSize, ChunkEnd, I, J, Count, PointBase, PolyBase, Tag, Dim, V, P: Integer;
  Tags: TStringList;
  Points: array of TVector3;
  PointUVs: array of TVector2;
  PointHasUV: array of Boolean;
  Polys: array of TPolygon;
  VmapType, PolsType, PtagType: String;
  UV: TVector2;
  Surf: TD3StaticSurface;
  Base, K: Integer;
  PosLw: TVector3;
begin
  Result := False;
  R := TLwoReader.Create;
  Tags := TStringList.Create;
  try
    SetLength(R.Data, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(R.Data[0], Stream.Size);
    if (Length(R.Data) < 12) or
       (TEncoding.ANSI.GetString(R.Data, 0, 4) <> 'FORM') or
       (TEncoding.ANSI.GetString(R.Data, 8, 4) <> 'LWO2') then
    begin
      WritelnWarning('Doom3StaticModels', '"%s" is not an LWO2 file', [Name]);
      Exit;
    end;
    R.Pos := 12;
    R.Limit := Length(R.Data);
    PointBase := 0;
    PolyBase := 0;
    while R.Pos + 8 <= Length(R.Data) do
    begin
      ChunkId := TEncoding.ANSI.GetString(R.Data, R.Pos, 4);
      Inc(R.Pos, 4);
      ChunkSize := R.U4;
      ChunkEnd := R.Pos + ChunkSize;
      if ChunkEnd > Length(R.Data) then
        Break;
      R.Limit := ChunkEnd;
      if ChunkId = 'TAGS' then
      begin
        while R.Pos < ChunkEnd do
          Tags.Add(R.S0);
      end else
      if ChunkId = 'LAYR' then
      begin
        { points and polygons of later layers are appended }
        PointBase := Length(Points);
        PolyBase := Length(Polys);
      end else
      if ChunkId = 'PNTS' then
      begin
        Count := ChunkSize div 12;
        SetLength(Points, PointBase + Count);
        SetLength(PointUVs, Length(Points));
        SetLength(PointHasUV, Length(Points));
        for I := 0 to Count - 1 do
        begin
          PosLw.X := R.F4;
          PosLw.Y := R.F4;
          PosLw.Z := R.F4;
          { LightWave (x, y up, z) -> Doom 3 (x, z, y) }
          Points[PointBase + I] := Vector3(PosLw.X, PosLw.Z, PosLw.Y);
        end;
      end else
      if (ChunkId = 'VMAP') or (ChunkId = 'VMAD') then
      begin
        VmapType := TEncoding.ANSI.GetString(R.Data, R.Pos, 4);
        Inc(R.Pos, 4);
        Dim := R.U2;
        R.S0; { map name }
        if (VmapType = 'TXUV') and (Dim = 2) then
          while R.Pos < ChunkEnd do
          begin
            V := PointBase + R.VX;
            if ChunkId = 'VMAD' then
              P := PolyBase + R.VX
            else
              P := -1;
            UV.X := R.F4;
            UV.Y := R.F4;
            if (P >= 0) and (P < Length(Polys)) then
            begin
              for J := 0 to High(Polys[P].Verts) do
                if Polys[P].Verts[J] = V then
                begin
                  Polys[P].UVs[J] := UV;
                  Polys[P].HasUV[J] := True;
                end;
            end else
            if (P < 0) and (V < Length(Points)) then
            begin
              PointUVs[V] := UV;
              PointHasUV[V] := True;
            end;
          end;
      end else
      if ChunkId = 'POLS' then
      begin
        PolsType := TEncoding.ANSI.GetString(R.Data, R.Pos, 4);
        Inc(R.Pos, 4);
        while R.Pos < ChunkEnd do
        begin
          Count := R.U2 and $03FF;
          SetLength(Polys, Length(Polys) + 1);
          SetLength(Polys[High(Polys)].Verts, Count);
          SetLength(Polys[High(Polys)].UVs, Count);
          SetLength(Polys[High(Polys)].HasUV, Count);
          Polys[High(Polys)].Tag := -1;
          for J := 0 to Count - 1 do
            Polys[High(Polys)].Verts[J] := PointBase + R.VX;
          if (PolsType <> 'FACE') and (PolsType <> 'PTCH') then
            Polys[High(Polys)].Tag := -2; { curves, bones...: not drawn }
        end;
      end else
      if ChunkId = 'PTAG' then
      begin
        PtagType := TEncoding.ANSI.GetString(R.Data, R.Pos, 4);
        Inc(R.Pos, 4);
        while R.Pos < ChunkEnd do
        begin
          P := PolyBase + R.VX;
          Tag := R.U2;
          if (PtagType = 'SURF') and (P < Length(Polys)) and (Polys[P].Tag <> -2) then
            Polys[P].Tag := Tag;
        end;
      end;
      { chunks are padded to an even size }
      R.Pos := ChunkEnd + (ChunkSize and 1);
      R.Limit := Length(R.Data);
    end;

    { polygons -> triangle fans per surface }
    for I := 0 to High(Polys) do
    begin
      if (Polys[I].Tag < 0) or (Polys[I].Tag >= Tags.Count) or (Length(Polys[I].Verts) < 3) then
        Continue;
      Surf := SurfaceFor(Tags[Polys[I].Tag]);
      Base := Length(Surf.Positions);
      SetLength(Surf.Positions, Base + Length(Polys[I].Verts));
      SetLength(Surf.TexCoords, Base + Length(Polys[I].Verts));
      for J := 0 to High(Polys[I].Verts) do
      begin
        V := Polys[I].Verts[J];
        if V >= Length(Points) then
          V := 0;
        Surf.Positions[Base + J] := Points[V];
        if Polys[I].HasUV[J] then
          Surf.TexCoords[Base + J] := Polys[I].UVs[J]
        else
        if PointHasUV[V] then
          Surf.TexCoords[Base + J] := PointUVs[V]
        else
          Surf.TexCoords[Base + J] := TVector2.Zero;
      end;
      K := Length(Surf.Indexes);
      SetLength(Surf.Indexes, K + 3 * (Length(Polys[I].Verts) - 2));
      for J := 1 to High(Polys[I].Verts) - 1 do
      begin
        Surf.Indexes[K] := Base;
        Surf.Indexes[K + 1] := Base + J;
        Surf.Indexes[K + 2] := Base + J + 1;
        Inc(K, 3);
      end;
    end;
    UpdateBounds;
    Result := Surfaces.Count > 0;
  finally
    Tags.Free;
    R.Free;
  end;
end;

{ ASE ------------------------------------------------------------------------ }

type
  TAseMaterial = class
    Bitmap: String;
    UOffset, VOffset, UTiling, VTiling: Single;
    Subs: specialize TObjectList<TAseMaterial>;
    constructor Create;
    destructor Destroy; override;
    { The material a face with this sub-material id uses. }
    function ForFace(const MtlId: Integer): TAseMaterial;
  end;

constructor TAseMaterial.Create;
begin
  inherited Create;
  UTiling := 1;
  VTiling := 1;
  Subs := specialize TObjectList<TAseMaterial>.Create(True);
end;

destructor TAseMaterial.Destroy;
begin
  Subs.Free;
  inherited Destroy;
end;

function TAseMaterial.ForFace(const MtlId: Integer): TAseMaterial;
begin
  if Subs.Count > 0 then
    Result := Subs[Abs(MtlId) mod Subs.Count].ForFace(0)
  else
    Result := Self;
end;

function ParseAseMaterial(const L: TDoom3Lexer): TAseMaterial;
var
  Tok: String;
  Depth: Integer;
begin
  // *MATERIAL n or *SUBMATERIAL n and its opening brace were already read
  Result := TAseMaterial.Create;
  Depth := 1;
  while (Depth > 0) and L.Next(Tok) do
  begin
    if Tok = '{' then
      Inc(Depth)
    else
    if Tok = '}' then
      Dec(Depth)
    else
    if SameText(Tok, '*SUBMATERIAL') then
    begin
      L.NextStr;
      L.Expect('{');
      Result.Subs.Add(ParseAseMaterial(L));
    end else
    if SameText(Tok, '*BITMAP') and (Result.Bitmap = '') and (Depth = 2) then
      Result.Bitmap := L.NextStr
    else
    if SameText(Tok, '*UVW_U_OFFSET') and (Depth = 2) then
      Result.UOffset := L.ReadFloat
    else
    if SameText(Tok, '*UVW_V_OFFSET') and (Depth = 2) then
      Result.VOffset := L.ReadFloat
    else
    if SameText(Tok, '*UVW_U_TILING') and (Depth = 2) then
      Result.UTiling := L.ReadFloat
    else
    if SameText(Tok, '*UVW_V_TILING') and (Depth = 2) then
      Result.VTiling := L.ReadFloat;
  end;
end;

function TD3StaticModel.LoadAse(const Text: String): Boolean;
var
  L: TDoom3Lexer;
  Tok: String;
  Materials: specialize TObjectList<TAseMaterial>;
  Verts: array of TVector3;
  TVerts: array of TVector2;
  Faces: array of array [0..2] of Integer;
  TFaces: array of array [0..2] of Integer;
  MtlIds: array of Integer;
  MaterialRef, Depth, I, K, N, Base: Integer;
  InMesh: Boolean;
  Mat: TAseMaterial;
  Surf: TD3StaticSurface;
  UV: TVector2;

  procedure FlushObject;
  var
    F, C: Integer;
  begin
    if (Length(Faces) = 0) or (Materials.Count = 0) then
      Exit;
    if (MaterialRef < 0) or (MaterialRef >= Materials.Count) then
      MaterialRef := 0;
    for F := 0 to High(Faces) do
    begin
      Mat := Materials[MaterialRef].ForFace(MtlIds[F]);
      if Mat.Bitmap = '' then
        Continue;
      Surf := SurfaceFor(AseBitmapToMaterial(Mat.Bitmap));
      Base := Length(Surf.Positions);
      SetLength(Surf.Positions, Base + 3);
      SetLength(Surf.TexCoords, Base + 3);
      SetLength(Surf.Indexes, Base + 3);
      for C := 0 to 2 do
      begin
        if (Faces[F][C] >= 0) and (Faces[F][C] < Length(Verts)) then
          Surf.Positions[Base + C] := Verts[Faces[F][C]];
        UV := TVector2.Zero;
        if (F < Length(TFaces)) and (TFaces[F][C] >= 0) and (TFaces[F][C] < Length(TVerts)) then
          UV := TVerts[TFaces[F][C]];
        { Doom 3: t = 1 - (v * tiling + offset); CGE's v = 1 - t }
        Surf.TexCoords[Base + C] := Vector2(UV.X * Mat.UTiling + Mat.UOffset,
          UV.Y * Mat.VTiling + Mat.VOffset);
        Surf.Indexes[Base + C] := Base + C;
      end;
    end;
    Faces := nil;
    TFaces := nil;
    MtlIds := nil;
    Verts := nil;
    TVerts := nil;
  end;

begin
  Materials := specialize TObjectList<TAseMaterial>.Create(True);
  L := TDoom3Lexer.Create(Text);
  try
    MaterialRef := 0;
    InMesh := False;
    Depth := 0;
    while L.Next(Tok) do
    begin
      if Tok = '{' then
        Inc(Depth)
      else
      if Tok = '}' then
        Dec(Depth)
      else
      if SameText(Tok, '*MATERIAL') then
      begin
        L.NextStr;
        L.Expect('{');
        Materials.Add(ParseAseMaterial(L));
      end else
      if SameText(Tok, '*GEOMOBJECT') then
      begin
        FlushObject;
        MaterialRef := 0;
        InMesh := True;
      end else
      if InMesh and SameText(Tok, '*MESH_NUMVERTEX') then
        SetLength(Verts, L.ReadInt)
      else
      if InMesh and SameText(Tok, '*MESH_NUMFACES') then
      begin
        N := L.ReadInt;
        SetLength(Faces, N);
        SetLength(MtlIds, N);
      end else
      if InMesh and SameText(Tok, '*MESH_VERTEX') then
      begin
        I := L.ReadInt;
        if (I >= 0) and (I < Length(Verts)) then
        begin
          Verts[I].X := L.ReadFloat;
          Verts[I].Y := L.ReadFloat;
          Verts[I].Z := L.ReadFloat;
        end;
      end else
      if InMesh and SameText(Tok, '*MESH_FACE') then
      begin
        { *MESH_FACE 0: A: 0 B: 1 C: 2 AB: 1 BC: 1 CA: 1 *MESH_SMOOTHING 1 *MESH_MTLID 0 }
        I := StrToIntDef(StringReplace(L.NextStr, ':', '', []), -1);
        for K := 0 to 2 do
        begin
          L.NextStr; { "A:" "B:" "C:" }
          N := L.ReadInt;
          if (I >= 0) and (I < Length(Faces)) then
            Faces[I][K] := N;
        end;
      end else
      if InMesh and SameText(Tok, '*MESH_MTLID') then
      begin
        N := L.ReadInt;
        if (I >= 0) and (I < Length(MtlIds)) then
          MtlIds[I] := N;
      end else
      if InMesh and SameText(Tok, '*MESH_NUMTVERTEX') then
        SetLength(TVerts, L.ReadInt)
      else
      if InMesh and SameText(Tok, '*MESH_TVERT') then
      begin
        I := L.ReadInt;
        if (I >= 0) and (I < Length(TVerts)) then
        begin
          TVerts[I].X := L.ReadFloat;
          TVerts[I].Y := L.ReadFloat;
        end;
        L.ReadFloat; { w }
      end else
      if InMesh and SameText(Tok, '*MESH_NUMTVFACES') then
        SetLength(TFaces, L.ReadInt)
      else
      if InMesh and SameText(Tok, '*MESH_TFACE') then
      begin
        I := L.ReadInt;
        for K := 0 to 2 do
        begin
          N := L.ReadInt;
          if (I >= 0) and (I < Length(TFaces)) then
            TFaces[I][K] := N;
        end;
      end else
      if SameText(Tok, '*MATERIAL_REF') then
        MaterialRef := L.ReadInt;
    end;
    FlushObject;
    UpdateBounds;
    Result := Surfaces.Count > 0;
  finally
    L.Free;
    Materials.Free;
  end;
end;

function TD3StaticModel.HasClosedSurface: Boolean;
var
  S: TD3StaticSurface;
begin
  if not FClosedKnown then
  begin
    FClosedKnown := True;
    FClosed := False;
    for S in Surfaces do
      if TrianglesClosed(S.Positions, S.Indexes) then
      begin
        FClosed := True;
        Break;
      end;
  end;
  Result := FClosed;
end;

function TD3StaticModel.BuildNode(const SkinName: String; const EntityKeys: TStrings): TX3DRootNode;
var
  S: TD3StaticSurface;
  Coords: array of TVector3;
  I, J: Integer;
  Coord: TCoordinateNode;
  NormalNode: TNormalNode;
  Normals: TVector3List;
  TexCoord: TTextureCoordinateNode;
  Geometry: TIndexedTriangleSetNode;
  Shape: TShapeNode;
  SkinDecl: TD3Skin;
  MaterialName: String;
  M: TD3Material;
  GuiUrl: String;
begin
  Result := TX3DRootNode.Create;
  SkinDecl := nil;
  if SkinName <> '' then
    SkinDecl := Decls.Skin(SkinName);
  for S in Surfaces do
  begin
    MaterialName := S.Material;
    if SkinDecl <> nil then
      MaterialName := SkinDecl.Remap(MaterialName);
    M := Decls.Material(MaterialName);
    GuiUrl := '';
    if M.GuiSurf <> '' then
      GuiUrl := GuiSurfaceUrl(M.GuiSurf, EntityKeys);
    if (M.IsInvisible and (GuiUrl = '') and not M.DrawAsGlass) or (Length(S.Indexes) < 3) then
      Continue;
    SetLength(Coords, Length(S.Positions));
    for I := 0 to High(S.Positions) do
      Coords[I] := D3ToCge(S.Positions[I]);
    Coord := TCoordinateNode.Create;
    Coord.SetPoint(Coords);
    TexCoord := TTextureCoordinateNode.Create;
    TexCoord.SetPoint(S.TexCoords);
    Geometry := TIndexedTriangleSetNode.Create;
    Geometry.Coord := Coord;
    Geometry.TexCoord := TexCoord;
    Geometry.SetIndex(S.Indexes);
    Normals := S.ComputeNormals;
    try
      for I := 0 to Normals.Count - 1 do
        Normals[I] := D3ToCge(Normals[I]);
      NormalNode := TNormalNode.Create;
      NormalNode.SetVector(Normals);
    finally
      Normals.Free;
    end;
    Geometry.Normal := NormalNode;
    Geometry.Ccw := True;
    Geometry.Solid := not M.TwoSided;
    Shape := TShapeNode.Create;
    Shape.Geometry := Geometry;
    if GuiUrl <> '' then
      Shape.Appearance := GuiAppearance(GuiUrl)
    else
    if M.DrawAsGlass then
      Shape.Appearance := GlassAppearance
    else
      Shape.Appearance := MaterialAppearance(MaterialName);
    Result.AddChildren(Shape);

    { more stages: the same triangles (sharing coordinates, normals and
      texture coordinates), with a "lequal" depth test (OverlayAppearance) }
    if (GuiUrl = '') and not M.DrawAsGlass then
      for J := 0 to M.OverlayCount - 1 do
      begin
        Geometry := TIndexedTriangleSetNode.Create;
        Geometry.Coord := Coord;
        Geometry.TexCoord := TexCoord;
        Geometry.Normal := NormalNode;
        Geometry.SetIndex(S.Indexes);
        Geometry.Ccw := True;
        Geometry.Solid := not M.TwoSided;
        Shape := TShapeNode.Create;
        Shape.Geometry := Geometry;
        Shape.Appearance := OverlayAppearance(MaterialName, J);
        Result.AddChildren(Shape);
      end;
  end;
  AddLightLibrary(Result);
end;

{ TD3StaticModelCache }

constructor TD3StaticModelCache.Create;
begin
  inherited Create;
  FModels := specialize TObjectDictionary<String, TD3StaticModel>.Create([doOwnsValues]);
end;

destructor TD3StaticModelCache.Destroy;
begin
  FModels.Free;
  inherited Destroy;
end;

procedure TD3StaticModelCache.Clear;
begin
  FModels.Clear;
end;

function TD3StaticModelCache.Model(const Path: String): TD3StaticModel;
var
  Key: String;
  Stream: TStream;
  Ok: Boolean;
begin
  Key := NormalizeD3Path(Path);
  if FModels.TryGetValue(Key, Result) then
    Exit;
  Result := nil;
  Stream := D3Fs.OpenFile(Key);
  if Stream <> nil then
  try
    Result := TD3StaticModel.Create;
    Result.Name := Key;
    try
      if LowerCase(ExtractFileExt(Key)) = '.lwo' then
        Ok := Result.LoadLwo(Stream)
      else
        Ok := Result.LoadAse(D3Fs.ReadText(Key));
    except
      on E: Exception do
      begin
        WritelnWarning('Doom3StaticModels', 'Cannot read "%s": %s', [Key, E.Message]);
        Ok := False;
      end;
    end;
    if not Ok then
    begin
      WritelnWarning('Doom3StaticModels', 'No drawable surfaces in "%s"', [Key]);
      FreeAndNil(Result);
    end;
  finally
    Stream.Free;
  end else
    WritelnLog('Doom3StaticModels', 'Missing model "%s"', [Key]);
  FModels.Add(Key, Result);
end;

initialization
  StaticModels := TD3StaticModelCache.Create;
finalization
  FreeAndNil(StaticModels);
end.
