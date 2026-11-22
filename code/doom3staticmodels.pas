{ Doom 3 static models: LightWave objects (.lwo, LWO2), 3ds Max ASCII
  exports (.ase) and Maya ASCII scenes (.ma), used for props, items, light fixtures and func_static
  models.

  Both are read into TD3StaticModel: surfaces per material with positions in
  Doom 3 coordinates, texture coordinates already in CGE's convention and
  triangles counter-clockwise from the front.

  - LWO2 is left-handed and Y up; Doom 3 reads points as (x, z, y), which
    only relabels the axes (right, forward, up), so polygons stay clockwise
    seen from the front, as LightWave stores them and as Doom 3 draws them:
    the triangle fans are reversed. Texture t = 1 - v, so CGE's v = 1 - t is
    the file's v. VMAD
    entries override UVs per polygon (texture seams). The polygon's surface
    tag is the material name.
  - ASE is right-handed and Z up like Doom 3; Doom flips faces (A, C, B) to
    its clockwise style, so the file's order is counter-clockwise. The
    material is the *BITMAP path from "base/" on, without its extension.
  - Maya ASCII (.ma) is Y up; Doom 3 reads (x, y, z) as (x, -z, y), a
    rotation, and swaps two corners of each face to draw it clockwise, so
    the file's order is counter-clockwise. A face's corners come from its
    edges; the material is the texture path of the file node that the
    mesh's shading group leads to (OSPathToRelativePath). }
unit Doom3StaticModels;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleVectors, X3DNodes, Doom3Materials;

type
  TD3StaticSurface = class
    Material: String;
    Positions: array of TVector3; { Doom 3 coordinates }
    TexCoords: array of TVector2; { CGE convention }
    { Vertex colors (LWO RGB / RGBA maps, ASE color vertexes), one per
      position; empty when the model has none (Doom 3 then uses white).
      Stages with "vertexColor" are modulated by them (BuildNode). }
    Colors: array of TVector4;
    Indexes: array of Int32;      { counter-clockwise from the front }
    { Has vertex colors for every vertex? }
    function HasColors: Boolean;
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
    { Maya ASCII (.ma: Resurrection of Evil's hell and Erebus pieces),
      read like Doom 3's Model_ma.cpp }
    function LoadMa(const Text: String): Boolean;
    { Doom 3 BFG's binary version of either (generated/rendermodels/*.blwo,
      *.base): a render model. }
    function LoadBinary(const Stream: TStream): Boolean;
    procedure UpdateBounds;
    function TriangleCount: Integer;
    { X3D shapes for the model (fresh nodes on every call). A skin remaps
      materials. }
    function BuildNode(const SkinName: String = ''; const EntityKeys: TStrings = nil;
      const Parms: TD3EntityParms = nil): TX3DRootNode;
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

{ Is this a static model file we can load (.lwo, .ase, .ma)? }
function IsStaticModelPath(const Path: String): Boolean;

{ Material name of an ASE *BITMAP path: from "base/" on, no extension. }
function AseBitmapToMaterial(const Bitmap: String): String;

var
  StaticModels: TD3StaticModelCache;

implementation

uses
  Math,
  CastleLog, CastleUtils,
  Doom3Files, Doom3Bfg, Doom3Lexer, Doom3Decls, Doom3MapFile, Doom3LightEffects, Doom3Gui,
  Doom3Collision;

function IsStaticModelPath(const Path: String): Boolean;
var
  Ext: String;
begin
  Ext := LowerCase(ExtractFileExt(Path));
  Result := (Ext = '.lwo') or (Ext = '.ase') or (Ext = '.ma');
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

function TD3StaticSurface.HasColors: Boolean;
begin
  Result := (Length(Colors) > 0) and (Length(Colors) = Length(Positions));
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
    Colors: array of TVector4;  { per polygon-vertex colors (VMAD RGB / RGBA) }
    HasColor: array of Boolean;
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
  PointColors: array of TVector4;
  PointHasColor: array of Boolean;
  AnyColor: Boolean;
  Polys: array of TPolygon;
  VmapType, PolsType, PtagType: String;
  UV: TVector2;
  Color: TVector4;
  Surf: TD3StaticSurface;
  Base, K: Integer;
  PosLw: TVector3;
begin
  AnyColor := False;
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
        SetLength(PointColors, Length(Points));
        SetLength(PointHasColor, Length(Points));
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
          end
        else
        if ((VmapType = 'RGB ') and (Dim = 3)) or ((VmapType = 'RGBA') and (Dim = 4)) then
          { vertex colors, like Doom 3's lwo2 reader (idRenderModelStatic
            takes the first color map) }
          while R.Pos < ChunkEnd do
          begin
            V := PointBase + R.VX;
            if ChunkId = 'VMAD' then
              P := PolyBase + R.VX
            else
              P := -1;
            Color.X := R.F4;
            Color.Y := R.F4;
            Color.Z := R.F4;
            if Dim = 4 then
              Color.W := R.F4
            else
              Color.W := 1;
            AnyColor := True;
            if (P >= 0) and (P < Length(Polys)) then
            begin
              for J := 0 to High(Polys[P].Verts) do
                if Polys[P].Verts[J] = V then
                begin
                  Polys[P].Colors[J] := Color;
                  Polys[P].HasColor[J] := True;
                end;
            end else
            if (P < 0) and (V < Length(Points)) then
            begin
              PointColors[V] := Color;
              PointHasColor[V] := True;
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
          SetLength(Polys[High(Polys)].Colors, Count);
          SetLength(Polys[High(Polys)].HasColor, Count);
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

    { polygons -> triangle fans per surface, reversed: counter-clockwise
      from the front }
    for I := 0 to High(Polys) do
    begin
      if (Polys[I].Tag < 0) or (Polys[I].Tag >= Tags.Count) or (Length(Polys[I].Verts) < 3) then
        Continue;
      Surf := SurfaceFor(Tags[Polys[I].Tag]);
      Base := Length(Surf.Positions);
      SetLength(Surf.Positions, Base + Length(Polys[I].Verts));
      SetLength(Surf.TexCoords, Base + Length(Polys[I].Verts));
      if AnyColor then
        SetLength(Surf.Colors, Base + Length(Polys[I].Verts));
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
        if AnyColor then
        begin
          if Polys[I].HasColor[J] then
            Surf.Colors[Base + J] := Polys[I].Colors[J]
          else
          if PointHasColor[V] then
            Surf.Colors[Base + J] := PointColors[V]
          else
            Surf.Colors[Base + J] := Vector4(1, 1, 1, 1);
        end;
      end;
      K := Length(Surf.Indexes);
      SetLength(Surf.Indexes, K + 3 * (Length(Polys[I].Verts) - 2));
      for J := 1 to High(Polys[I].Verts) - 1 do
      begin
        Surf.Indexes[K] := Base;
        Surf.Indexes[K + 1] := Base + J + 1;
        Surf.Indexes[K + 2] := Base + J;
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
  CVerts: array of TVector3;
  Faces: array of array [0..2] of Integer;
  TFaces: array of array [0..2] of Integer;
  CFaces: array of array [0..2] of Integer;
  MtlIds: array of Integer;
  MaterialRef, Depth, I, K, N, Base: Integer;
  InMesh: Boolean;
  Mat: TAseMaterial;
  Surf: TD3StaticSurface;
  UV: TVector2;

  procedure FlushObject;
  var
    F, C: Integer;
    HasColors: Boolean;
  begin
    if (Length(Faces) = 0) or (Materials.Count = 0) then
      Exit;
    if (MaterialRef < 0) or (MaterialRef >= Materials.Count) then
      MaterialRef := 0;
    { *MESH_CVERTLIST / *MESH_CFACELIST: vertex colors per face corner
      (idRenderModelStatic::ConvertASEToModelSurfaces) }
    HasColors := (Length(CVerts) > 0) and (Length(CFaces) >= Length(Faces));
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
      if HasColors or (Length(Surf.Colors) > 0) then
        SetLength(Surf.Colors, Base + 3);
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
        if Length(Surf.Colors) > 0 then
        begin
          Surf.Colors[Base + C] := Vector4(1, 1, 1, 1);
          if HasColors and (CFaces[F][C] >= 0) and (CFaces[F][C] < Length(CVerts)) then
            Surf.Colors[Base + C] := Vector4(CVerts[CFaces[F][C]], 1);
        end;
      end;
    end;
    Faces := nil;
    TFaces := nil;
    CFaces := nil;
    MtlIds := nil;
    Verts := nil;
    TVerts := nil;
    CVerts := nil;
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
      if InMesh and SameText(Tok, '*MESH_NUMCVERTEX') then
        SetLength(CVerts, L.ReadInt)
      else
      if InMesh and SameText(Tok, '*MESH_VERTCOL') then
      begin
        I := L.ReadInt;
        if (I >= 0) and (I < Length(CVerts)) then
        begin
          CVerts[I].X := L.ReadFloat;
          CVerts[I].Y := L.ReadFloat;
          CVerts[I].Z := L.ReadFloat;
        end;
      end else
      if InMesh and SameText(Tok, '*MESH_NUMCVFACES') then
        SetLength(CFaces, L.ReadInt)
      else
      if InMesh and SameText(Tok, '*MESH_CFACE') then
      begin
        I := L.ReadInt;
        for K := 0 to 2 do
        begin
          N := L.ReadInt;
          if (I >= 0) and (I < Length(CFaces)) then
            CFaces[I][K] := N;
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

{ Maya ASCII ----------------------------------------------------------------- }

type
  TMaTransform = class
    Translate, Rotate, Scale: TVector3; { Doom 3's axes (MA_ParseTransform) }
    Parent: TMaTransform;
  end;

  TMaMaterialNode = class
    Child: TMaMaterialNode;
    FilePath: String;
    HasFile: Boolean;
  end;

  TMaFace = record
    Edge, TVert, Color: array [0..2] of Integer;
  end;

  TMaTweak = record
    Index: Integer;
    Offset: TVector3;
  end;

  TMaMesh = class
    Name, MaterialName: String;
    Transform: TMaTransform;
    Verts: array of TVector3;
    Edges: array of array [0..2] of Integer;
    TVerts: array of TVector2;
    Colors: array of TVector4;
    Faces: array of TMaFace;
    Tweaks: array of TMaTweak;
  end;

  TMaTokens = record
    Text: array of String;
    Quoted: array of Boolean;
    Count: Integer;
  end;

procedure MaTokenize(const S: String; out T: TMaTokens);
var
  I, Start, N: Integer;

  procedure Add(const Tok: String; const Q: Boolean);
  begin
    if T.Count = Length(T.Text) then
    begin
      SetLength(T.Text, T.Count * 2 + 1024);
      SetLength(T.Quoted, Length(T.Text));
    end;
    T.Text[T.Count] := Tok;
    T.Quoted[T.Count] := Q;
    Inc(T.Count);
  end;

begin
  T.Count := 0;
  T.Text := nil;
  T.Quoted := nil;
  N := Length(S);
  I := 1;
  while I <= N do
  begin
    case S[I] of
      #0..' ':
        Inc(I);
      ';':
        begin
          Add(';', False);
          Inc(I);
        end;
      '"':
        begin
          Start := I + 1;
          Inc(I);
          while (I <= N) and (S[I] <> '"') do
          begin
            if (S[I] = '\') and (I < N) then
              Inc(I);
            Inc(I);
          end;
          Add(Copy(S, Start, I - Start), True);
          Inc(I);
        end;
      else
        begin
          if (S[I] = '/') and (I < N) and (S[I + 1] = '/') then
          begin
            while (I <= N) and not (S[I] in [#10, #13]) do
              Inc(I);
            Continue;
          end;
          Start := I;
          while (I <= N) and not (S[I] in [#0..' ', ';', '"']) do
            Inc(I);
          Add(Copy(S, Start, I - Start), False);
        end;
    end;
  end;
end;

function TD3StaticModel.LoadMa(const Text: String): Boolean;
var
  T: TMaTokens;
  P: Integer;
  Transforms: specialize TObjectDictionary<String, TMaTransform>;
  MatNodes: specialize TObjectDictionary<String, TMaMaterialNode>;
  FileNodes: specialize TDictionary<String, String>;
  Meshes: specialize TObjectList<TMaMesh>;

  function AtEnd: Boolean;
  begin
    Result := P >= T.Count;
  end;

  { the end of a node's attributes: the next command Doom 3 looks for }
  function NodeComplete: Boolean;
  begin
    Result := AtEnd or (not T.Quoted[P] and (
      (T.Text[P] = 'createNode') or (T.Text[P] = 'connectAttr') or (T.Text[P] = 'select')));
  end;

  { createNode's flags up to ";": the name and the parent }
  procedure NodeHeader(out Name, Parent: String);
  begin
    Name := '';
    Parent := '';
    while not AtEnd and (T.Text[P] <> ';') do
    begin
      if (T.Text[P] = '-n') and (P + 1 < T.Count) then
      begin
        Name := T.Text[P + 1];
        Inc(P);
      end else
      if (T.Text[P] = '-p') and (P + 1 < T.Count) then
      begin
        Parent := T.Text[P + 1];
        Inc(P);
      end;
      Inc(P);
    end;
    Inc(P);
  end;

  { a setAttr (P past the word): its attribute, its "-s" size and its
    values up to ";" without "-type <type>" and parentheses; P past the
    ";" }
  function ReadSetAttr(out Attr: String; out Size: Integer; out Values: TStringArray): Boolean;
  var
    Count: Integer;
  begin
    Attr := '';
    Size := 0;
    Values := nil;
    while not AtEnd and (T.Text[P] <> ';') and not T.Quoted[P] do
    begin
      if (T.Text[P] = '-s') and (P + 1 < T.Count) then
      begin
        Size := StrToIntDef(T.Text[P + 1], 0);
        Inc(P);
      end;
      Inc(P);
    end;
    if not AtEnd and T.Quoted[P] then
    begin
      Attr := T.Text[P];
      Inc(P);
    end;
    Count := 0;
    while not AtEnd and (T.Text[P] <> ';') do
    begin
      if not T.Quoted[P] and (T.Text[P] = '-type') then
        Inc(P, 2)
      else
      { a long string is wrapped: ( "..." ) }
      if not T.Quoted[P] and ((T.Text[P] = '(') or (T.Text[P] = ')')) then
        Inc(P)
      else
      begin
        if Count = Length(Values) then
          SetLength(Values, Count * 2 + 16);
        Values[Count] := T.Text[P];
        Inc(Count);
        Inc(P);
      end;
    end;
    SetLength(Values, Count);
    Inc(P);
    Result := Attr <> '';
  end;

  { "[a:b]" or "[a]" after Skip in the attribute name }
  function HeaderIndex(const Attr, Skip: String; out MinI, MaxI: Integer): Boolean;
  var
    S: String;
    B, C, E: Integer;
  begin
    MinI := 0;
    MaxI := -1;
    S := Attr;
    if Skip <> '' then
    begin
      B := Pos(Skip, S);
      if B = 0 then
        Exit(False);
      S := Copy(S, B + Length(Skip), MaxInt);
    end;
    B := Pos('[', S);
    E := Pos(']', S);
    if (B = 0) or (E < B) then
      Exit(False);
    S := Copy(S, B + 1, E - B - 1);
    C := Pos(':', S);
    if C > 0 then
    begin
      MinI := StrToIntDef(Copy(S, 1, C - 1), 0);
      MaxI := StrToIntDef(Copy(S, C + 1, MaxInt), MinI);
    end else
    begin
      MinI := StrToIntDef(S, 0);
      MaxI := MinI;
    end;
    Result := (MinI >= 0) and (MaxI >= MinI);
  end;

  function F(const Values: TStringArray; const I: Integer): Single;
  begin
    if I < Length(Values) then
      Result := D3StrToFloat(Values[I])
    else
      Result := 0;
  end;

  function N(const Values: TStringArray; const I: Integer): Integer;
  begin
    if I < Length(Values) then
      Result := StrToIntDef(Values[I], 0)
    else
      Result := 0;
  end;

  { Maya's (x, y, z) as Doom 3's: x, -z, y }
  function MayaVec(const Values: TStringArray; const I: Integer): TVector3;
  begin
    Result := Vector3(F(Values, I), -F(Values, I + 2), F(Values, I + 1));
  end;

  procedure ParseTransform;
  var
    Name, Parent, Attr: String;
    Size: Integer;
    Values: TStringArray;
    Tr, Par: TMaTransform;
  begin
    NodeHeader(Name, Parent);
    Tr := TMaTransform.Create;
    Tr.Scale := Vector3(1, 1, 1);
    while not NodeComplete do
    begin
      if T.Quoted[P] or (T.Text[P] <> 'setAttr') then
      begin
        Inc(P);
        Continue;
      end;
      Inc(P);
      if not ReadSetAttr(Attr, Size, Values) or (Length(Values) < 3) then
        Continue;
      { MA_ReadVec3 reads (x, z, y); only the translation's y is negated }
      if Attr = '.t' then
        Tr.Translate := Vector3(F(Values, 0), -F(Values, 2), F(Values, 1))
      else
      if Attr = '.r' then
        Tr.Rotate := Vector3(F(Values, 0), F(Values, 2), F(Values, 1))
      else
      if Attr = '.s' then
        Tr.Scale := Vector3(F(Values, 0), F(Values, 2), F(Values, 1));
    end;
    if (Parent <> '') and Transforms.TryGetValue(Parent, Par) then
      Tr.Parent := Par;
    Transforms.AddOrSetValue(Name, Tr);
  end;

  procedure ParseFaces(const M: TMaMesh; const Values: TStringArray; const MinI: Integer);
  var
    I, K, Face, Count: Integer;
    Kind: String;
  begin
    Face := MinI - 1;
    I := 0;
    while I < Length(Values) do
    begin
      Kind := Values[I];
      if Kind = 'f' then
      begin
        Count := N(Values, I + 1);
        if Count <> 3 then
          raise Exception.Create('Face is not a triangle');
        Inc(Face);
        if Face > High(M.Faces) then
          SetLength(M.Faces, Face + 1);
        for K := 0 to 2 do
        begin
          M.Faces[Face].Edge[K] := N(Values, I + 2 + K);
          M.Faces[Face].TVert[K] := 0;
          M.Faces[Face].Color[K] := -1;
        end;
        Inc(I, 5);
      end else
      if ((Kind = 'mu') or (Kind = 'mf') or (Kind = 'fc')) and (Face >= MinI) then
      begin
        if Kind = 'mu' then
          Inc(I); { the uv set }
        Count := N(Values, I + 1);
        if Count <> 3 then
          raise Exception.Create('Invalid texture coordinates or colors');
        for K := 0 to 2 do
          if Kind = 'fc' then
            M.Faces[Face].Color[K] := N(Values, I + 2 + K)
          else
            M.Faces[Face].TVert[K] := N(Values, I + 2 + K);
        Inc(I, 5);
      end else
        Inc(I);
    end;
  end;

  procedure ParseMesh;
  var
    Name, Parent, Attr: String;
    Size, MinI, MaxI, I, J, K: Integer;
    Values: TStringArray;
    M: TMaMesh;
    Tr: TMaTransform;
    FacesDone: Boolean;
  begin
    NodeHeader(Name, Parent);
    M := TMaMesh.Create;
    M.Name := Name;
    Meshes.Add(M);
    if (Parent <> '') and Transforms.TryGetValue(Parent, Tr) then
      M.Transform := Tr;
    { Doom 3 reads faces up to the node's end: other attributes after them
      are skipped }
    FacesDone := False;
    while not NodeComplete do
    begin
      if T.Quoted[P] or (T.Text[P] <> 'setAttr') then
      begin
        Inc(P);
        Continue;
      end;
      Inc(P);
      if not ReadSetAttr(Attr, Size, Values) then
        Continue;
      if FacesDone and (Pos('.fc', Attr) = 0) then
        Continue;
      if Pos('.vt', Attr) > 0 then
      begin
        if Size > Length(M.Verts) then
          SetLength(M.Verts, Size);
        if HeaderIndex(Attr, '', MinI, MaxI) then
        begin
          if MaxI >= Length(M.Verts) then
            SetLength(M.Verts, MaxI + 1);
          for I := MinI to MaxI do
            M.Verts[I] := MayaVec(Values, (I - MinI) * 3);
        end;
      end else
      if Pos('.ed', Attr) > 0 then
      begin
        if Size > Length(M.Edges) then
          SetLength(M.Edges, Size);
        if HeaderIndex(Attr, '', MinI, MaxI) then
        begin
          if MaxI >= Length(M.Edges) then
            SetLength(M.Edges, MaxI + 1);
          for I := MinI to MaxI do
            for K := 0 to 2 do
              M.Edges[I][K] := N(Values, (I - MinI) * 3 + K);
        end;
      end else
      if Pos('.pt', Attr) > 0 then
      begin
        if HeaderIndex(Attr, '', MinI, MaxI) then
          for I := MinI to MaxI do
          begin
            J := Length(M.Tweaks);
            SetLength(M.Tweaks, J + 1);
            M.Tweaks[J].Index := I;
            M.Tweaks[J].Offset := MayaVec(Values, (I - MinI) * 3);
          end;
      end else
      if Pos('.n', Attr) > 0 then
        { explicit normals: smoothed like the other models instead
          (ComputeNormals) }
      else
      if Pos('.fc', Attr) > 0 then
      begin
        if Size > Length(M.Faces) then
          SetLength(M.Faces, Size);
        if HeaderIndex(Attr, '', MinI, MaxI) then
        begin
          FacesDone := True;
          ParseFaces(M, Values, MinI);
        end;
      end else
      if Pos('.clr', Attr) > 0 then
      begin
        if Size > Length(M.Colors) then
          SetLength(M.Colors, Size);
        if HeaderIndex(Attr, '', MinI, MaxI) then
        begin
          if MaxI >= Length(M.Colors) then
            SetLength(M.Colors, MaxI + 1);
          for I := MinI to MaxI do
            M.Colors[I] := Vector4(F(Values, (I - MinI) * 4), F(Values, (I - MinI) * 4 + 1),
              F(Values, (I - MinI) * 4 + 2), F(Values, (I - MinI) * 4 + 3));
        end;
      end else
      if (Pos('.uvst', Attr) > 0) and (Pos('uvsn', Attr) = 0) then
      begin
        if Size > Length(M.TVerts) then
          SetLength(M.TVerts, Size);
        if HeaderIndex(Attr, 'uvsp', MinI, MaxI) then
        begin
          if MaxI >= Length(M.TVerts) then
            SetLength(M.TVerts, MaxI + 1);
          { Doom 3's t = 1 - v; CGE's v = 1 - t }
          for I := MinI to MaxI do
            M.TVerts[I] := Vector2(F(Values, (I - MinI) * 2), F(Values, (I - MinI) * 2 + 1));
        end;
      end;
    end;
  end;

  procedure ParseFileNode;
  var
    Name, Parent, Attr: String;
    Size: Integer;
    Values: TStringArray;
  begin
    NodeHeader(Name, Parent);
    while not NodeComplete do
    begin
      if T.Quoted[P] or (T.Text[P] <> 'setAttr') then
      begin
        Inc(P);
        Continue;
      end;
      Inc(P);
      if ReadSetAttr(Attr, Size, Values) and (Pos('.ftn', Attr) > 0) and (Length(Values) > 0) then
        FileNodes.AddOrSetValue(Name, Values[0]);
    end;
  end;

  { MA_ParseConnectAttr: shading nodes' chains ("oc") and the meshes'
    shading groups ("iog") }
  procedure ParseConnectAttr;
  var
    Src, Dest, SrcName, SrcType, DestName, Path: String;
    D: Integer;
    SrcNode, DestNode: TMaMaterialNode;
    M: TMaMesh;
  begin
    if P + 1 >= T.Count then
    begin
      P := T.Count;
      Exit;
    end;
    Src := T.Text[P];
    Dest := T.Text[P + 1];
    Inc(P, 2);
    D := Pos('.', Src);
    if (D = 0) or (Pos('.', Dest) = 0) then
      Exit;
    SrcName := Copy(Src, 1, D - 1);
    SrcType := Copy(Src, D + 1, MaxInt);
    DestName := Copy(Dest, 1, Pos('.', Dest) - 1);
    if Pos('oc', SrcType) > 0 then
    begin
      if MatNodes.TryGetValue(SrcName, SrcNode) and MatNodes.TryGetValue(DestName, DestNode) then
        DestNode.Child := SrcNode;
      if FileNodes.TryGetValue(SrcName, Path) and MatNodes.TryGetValue(DestName, DestNode) then
      begin
        DestNode.FilePath := Path;
        DestNode.HasFile := True;
      end;
    end;
    if Pos('iog', SrcType) > 0 then
      for M in Meshes do
        if M.Name = SrcName then
        begin
          M.MaterialName := DestName;
          Break;
        end;
  end;

  { MA_AddMaterial: the shading group's chain down to a node with a file,
    its texture's path from "base/" or a known root on (like Doom 3 BFG's
    binary copies: "D:/d3xp/d3xp/textures/david/x.tga" is
    textures/david/x, where Doom 3's OSPathToRelativePath would keep
    d3xp/) }
  function MaterialOf(const M: TMaMesh): String;
  var
    Node: TMaMaterialNode;
    Guard: Integer;
  begin
    Result := '';
    if not MatNodes.TryGetValue(M.MaterialName, Node) then
      Exit;
    Guard := 0;
    while (Node <> nil) and not Node.HasFile and (Guard < 100) do
    begin
      Node := Node.Child;
      Inc(Guard);
    end;
    if (Node <> nil) and Node.HasFile then
      Result := AseBitmapToMaterial(Node.FilePath);
  end;

  { MA_BuildAxisRotation's matrices (idMat4 rows times the vector) }
  function RotX(const V: TVector3; const A: Single): TVector3;
  begin
    Result := Vector3(V.X, Cos(A) * V.Y + Sin(A) * V.Z, -Sin(A) * V.Y + Cos(A) * V.Z);
  end;

  function RotY(const V: TVector3; const A: Single): TVector3;
  begin
    Result := Vector3(Cos(A) * V.X - Sin(A) * V.Z, V.Y, Sin(A) * V.X + Cos(A) * V.Z);
  end;

  function RotZ(const V: TVector3; const A: Single): TVector3;
  begin
    Result := Vector3(Cos(A) * V.X + Sin(A) * V.Y, -Sin(A) * V.X + Cos(A) * V.Y, V.Z);
  end;

  procedure Build(const M: TMaMesh);
  var
    I, K, E, V, Base: Integer;
    Tr: TMaTransform;
    Surf: TD3StaticSurface;
    Mat: String;
    HasColors: Boolean;
    P3: TVector3;
  begin
    if (Length(M.Faces) = 0) or (Length(M.Verts) = 0) then
      Exit;
    Mat := MaterialOf(M);
    if Mat = '' then
      Exit;
    for I := 0 to High(M.Tweaks) do
      if (M.Tweaks[I].Index >= 0) and (M.Tweaks[I].Index < Length(M.Verts)) then
        M.Verts[M.Tweaks[I].Index] := M.Verts[M.Tweaks[I].Index] + M.Tweaks[I].Offset;
    { MA_ApplyTransformation: scale, rotations about x, z, y, translation,
      for the mesh's transform and each parent }
    Tr := M.Transform;
    while Tr <> nil do
    begin
      for I := 0 to High(M.Verts) do
      begin
        P3 := M.Verts[I] * Tr.Scale;
        if Tr.Rotate.X <> 0 then
          P3 := RotX(P3, DegToRad(-Tr.Rotate.X));
        if Tr.Rotate.Z <> 0 then
          P3 := RotZ(P3, DegToRad(-Tr.Rotate.Z));
        if Tr.Rotate.Y <> 0 then
          P3 := RotY(P3, DegToRad(Tr.Rotate.Y));
        M.Verts[I] := P3 + Tr.Translate;
      end;
      Tr := Tr.Parent;
    end;
    HasColors := Length(M.Colors) > 0;
    Surf := SurfaceFor(Mat);
    Base := Length(Surf.Positions);
    SetLength(Surf.Positions, Base + Length(M.Faces) * 3);
    SetLength(Surf.TexCoords, Length(Surf.Positions));
    SetLength(Surf.Indexes, Length(Surf.Positions));
    if HasColors or (Length(Surf.Colors) > 0) then
      SetLength(Surf.Colors, Length(Surf.Positions));
    for I := 0 to High(M.Faces) do
      for K := 0 to 2 do
      begin
        { a corner: its edge's start, or its end for an edge used backwards
          (-1 - e); the file's order is counter-clockwise from the front
          (Doom 3 swaps two corners to draw it clockwise) }
        E := M.Faces[I].Edge[K];
        if E < 0 then
          E := -E - 1;
        V := -1;
        if E < Length(M.Edges) then
          if M.Faces[I].Edge[K] < 0 then
            V := M.Edges[E][1]
          else
            V := M.Edges[E][0];
        if (V < 0) or (V >= Length(M.Verts)) then
          raise Exception.CreateFmt('Bad vertex index %d', [V]);
        Surf.Positions[Base + I * 3 + K] := M.Verts[V];
        if (M.Faces[I].TVert[K] >= 0) and (M.Faces[I].TVert[K] < Length(M.TVerts)) then
          Surf.TexCoords[Base + I * 3 + K] := M.TVerts[M.Faces[I].TVert[K]];
        Surf.Indexes[Base + I * 3 + K] := Base + I * 3 + K;
        if Length(Surf.Colors) > 0 then
        begin
          Surf.Colors[Base + I * 3 + K] := Vector4(1, 1, 1, 1);
          if HasColors and (M.Faces[I].Color[K] >= 0) and (M.Faces[I].Color[K] < Length(M.Colors)) then
            Surf.Colors[Base + I * 3 + K] := M.Colors[M.Faces[I].Color[K]];
        end;
      end;
  end;

var
  Tok, NodeName, NodeParent: String;
  M: TMaMesh;
begin
  MaTokenize(Text, T);
  Transforms := specialize TObjectDictionary<String, TMaTransform>.Create([doOwnsValues]);
  MatNodes := specialize TObjectDictionary<String, TMaMaterialNode>.Create([doOwnsValues]);
  FileNodes := specialize TDictionary<String, String>.Create;
  Meshes := specialize TObjectList<TMaMesh>.Create(True);
  try
    P := 0;
    while not AtEnd do
    begin
      Tok := T.Text[P];
      Inc(P);
      if T.Quoted[P - 1] then
        Continue;
      if (Tok = 'createNode') and not AtEnd then
      begin
        Tok := T.Text[P];
        Inc(P);
        if Tok = 'transform' then
          ParseTransform
        else
        if Tok = 'mesh' then
          ParseMesh
        else
        if Tok = 'file' then
          ParseFileNode
        else
        if (Tok = 'shadingEngine') or (Tok = 'lambert') or (Tok = 'phong') or (Tok = 'blinn') then
        begin
          NodeHeader(NodeName, NodeParent);
          MatNodes.AddOrSetValue(NodeName, TMaMaterialNode.Create);
        end;
      end else
      if Tok = 'connectAttr' then
        ParseConnectAttr;
    end;
    for M in Meshes do
      Build(M);
    UpdateBounds;
    Result := Surfaces.Count > 0;
  finally
    Meshes.Free;
    FileNodes.Free;
    MatNodes.Free;
    Transforms.Free;
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

{ an invisible shape that only collides (and casts no shadow) }
function CollisionShape(const S: TD3StaticSurface): TShapeNode;
var
  Geometry: TIndexedTriangleSetNode;
  C: TCoordinateNode;
  Coords: array of TVector3;
  I: Integer;
  App: TAppearanceNode;
begin
  SetLength(Coords, Length(S.Positions));
  for I := 0 to High(S.Positions) do
    Coords[I] := D3ToCge(S.Positions[I]);
  C := TCoordinateNode.Create;
  C.SetPoint(Coords);
  Geometry := TIndexedTriangleSetNode.Create;
  Geometry.Coord := C;
  Geometry.SetIndex(S.Indexes);
  Geometry.Solid := False;
  App := TAppearanceNode.Create;
  App.ShadowCaster := False;
  Result := TShapeNode.Create;
  Result.Geometry := Geometry;
  Result.Appearance := App;
  Result.Visible := False;
end;

function TD3StaticModel.BuildNode(const SkinName: String; const EntityKeys: TStrings;
  const Parms: TD3EntityParms): TX3DRootNode;
var
  S: TD3StaticSurface;
  Coords: array of TVector3;
  UVs: array of TVector2;
  Indexes: array of Int32;
  I, J: Integer;
  Coord: TCoordinateNode;
  NormalNode: TNormalNode;
  Normals: TVector3List;
  TexCoord: TTextureCoordinateNode;
  Shape: TShapeNode;
  SkinDecl: TD3Skin;
  MaterialName: String;
  M: TD3Material;
  GuiUrl: String;
  Kind: TD3SpecialShape;
  App: TAppearanceNode;
  Tube, Inverse: Boolean;
  Islands: TD3EyeIslands;
  EyeIndexes: TInt32List;

  { A shape of the surface's triangles (sharing coordinates, normals and
    texture coordinates) with an appearance; a "deform tube" surface's
    quads follow the view (each shape has its own coordinates then). }
  function SurfaceShape(const App: TAppearanceNode; const Overlay: Integer): TShapeNode;
  var
    Geometry: TIndexedTriangleSetNode;
    C: TCoordinateNode;
  begin
    Geometry := TIndexedTriangleSetNode.Create;
    if Tube then
    begin
      C := TCoordinateNode.Create;
      C.SetPoint(Coords);
      Geometry.Coord := C;
      RegisterTubeSurface(C, Coords, Indexes);
    end else
      Geometry.Coord := Coord;
    Geometry.TexCoord := TexCoord;
    Geometry.Normal := NormalNode;
    Geometry.SetIndex(Indexes);
    Geometry.Ccw := True;
    Geometry.Solid := not M.TwoSided and not Tube;
    { stages with "vertexColor" are modulated by the model's vertex colors }
    if S.HasColors and StageUsesVertexColors(M, Overlay, Inverse) then
      Geometry.Color := VertexColorNode(S.Colors, Inverse);
    Result := TShapeNode.Create;
    Result.Geometry := Geometry;
    Result.Appearance := App;
  end;

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
    if Length(S.Indexes) < 3 then
      Continue;
    if M.IsInvisible and (GuiUrl = '') and not M.DrawAsGlass then
    begin
      { nothing to draw, but solid or player clip: Doom 3's clip model of a
        render model has it (Doom 3 BFG's hell: its rock pieces are
        "solid" "0", invisible clip meshes collide instead) }
      if M.BlocksPlayer then
        Result.AddChildren(CollisionShape(S));
      Continue;
    end;
    { deform particle: its particles instead (TD3Game.SpawnParticleDeforms) }
    if (M.Deform = 'particle') or (M.Deform = 'particle2') then
      Continue;
    SetLength(Coords, Length(S.Positions));
    for I := 0 to High(S.Positions) do
      Coords[I] := D3ToCge(S.Positions[I]);
    UVs := Copy(S.TexCoords);
    Indexes := S.Indexes;
    Tube := M.Deform = 'tube';
    { "deform eyeball": the eye triangles with the projected texture
      coordinates, the origin and focus triangles dropped }
    if (M.Deform = 'eyeball') and EyeballIslands(S.Indexes, Length(Coords), Islands, Name + ' ' + S.Material) then
    begin
      EyeIndexes := EyeballIndexes(Islands, S.Indexes);
      try
        SetLength(Indexes, EyeIndexes.Count);
        for I := 0 to EyeIndexes.Count - 1 do
          Indexes[I] := EyeIndexes[I];
      finally
        EyeIndexes.Free;
      end;
      EyeballTexCoords(Islands, Coords, UVs);
      Inc(EyeballSurfaceCount);
    end;
    Coord := nil;
    if not Tube then
    begin
      Coord := TCoordinateNode.Create;
      Coord.SetPoint(Coords);
    end;
    TexCoord := TTextureCoordinateNode.Create;
    TexCoord.SetPoint(UVs);
    Normals := S.ComputeNormals;
    try
      for I := 0 to Normals.Count - 1 do
        Normals[I] := D3ToCge(Normals[I]);
      NormalNode := TNormalNode.Create;
      NormalNode.SetVector(Normals);
    finally
      Normals.Free;
    end;
    Kind := ssNone;
    if GuiUrl <> '' then
      App := GuiAppearance(GuiUrl)
    else
    if M.DrawAsGlass then
      App := GlassAppearance(MaterialName, Kind)
    else
      App := MaterialAppearance(MaterialName, Parms);
    Shape := SurfaceShape(App, -1);
    SetupSpecialShape(Shape, Kind);
    if (GuiUrl = '') and not M.DrawAsGlass then
      Result.AddChildren(ConditionalShapeNode(Shape, BaseStageCondition(M), Parms))
    else
      Result.AddChildren(Shape);

    { more stages: the same triangles (sharing coordinates, normals and
      texture coordinates), with a "lequal" depth test (OverlayAppearance) }
    if (GuiUrl = '') and not M.DrawAsGlass then
      for J := 0 to M.OverlayCount - 1 do
      begin
        Shape := SurfaceShape(OverlayAppearance(MaterialName, J, Parms), J);
        Result.AddChildren(ConditionalShapeNode(Shape, OverlayStageCondition(M, J), Parms));
      end;

    { a heat haze stage over a lit or plain surface }
    if (GuiUrl = '') and not M.DrawAsGlass and (M.HazeNormalMap <> '') then
    begin
      App := HazeOverlayAppearance(MaterialName);
      if App <> nil then
      begin
        Shape := SurfaceShape(App, MaxInt);
        SetupSpecialShape(Shape, ssHaze);
        Result.AddChildren(Shape);
      end;
    end;

    { a cube map reflection stage over a lit or plain surface (perturbed
      by the bump map when the material has one) }
    if (GuiUrl = '') and not M.DrawAsGlass and (M.ReflectCubeMap <> '') then
    begin
      App := ReflectionAppearance(MaterialName);
      if App <> nil then
      begin
        Shape := SurfaceShape(App, MaxInt);
        SetupSpecialShape(Shape, ReflectionKind(M));
        Result.AddChildren(Shape);
      end;
    end;

    { a mirror stage over a lit or plain surface }
    if (GuiUrl = '') and not M.DrawAsGlass and M.HasMirror then
    begin
      App := MirrorAppearance(MaterialName);
      if App <> nil then
      begin
        Shape := SurfaceShape(App, MaxInt);
        SetupSpecialShape(Shape, ssMirror);
        Result.AddChildren(Shape);
      end;
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

{ The render model's surfaces are as Doom 3 draws them: clockwise from the
  front, t down. The vertex colors count when they differ (models without
  any have one value everywhere). }
function TD3StaticModel.LoadBinary(const Stream: TStream): Boolean;
var
  R: TBfgReader;
  Brm: TBfgModel;
  Surf: TD3StaticSurface;
  I, J, N: Integer;
  Colored: Boolean;
begin
  Result := False;
  R := TBfgReader.Create(Stream, False);
  try
    if not BfgReadModel(R, Brm) then
      Exit;
  finally
    R.Free;
  end;
  for I := 0 to High(Brm.Surfaces) do
  begin
    N := Length(Brm.Surfaces[I].Verts);
    if (N = 0) or (Length(Brm.Surfaces[I].Indexes) < 3) then
      Continue;
    Surf := TD3StaticSurface.Create;
    Surfaces.Add(Surf);
    Surf.Material := Brm.Surfaces[I].Material;
    SetLength(Surf.Positions, N);
    SetLength(Surf.TexCoords, N);
    Colored := False;
    for J := 0 to N - 1 do
    begin
      Surf.Positions[J] := Brm.Surfaces[I].Verts[J].Position;
      Surf.TexCoords[J] := Vector2(Brm.Surfaces[I].Verts[J].ST.X, 1 - Brm.Surfaces[I].Verts[J].ST.Y);
      if (J > 0) and (PCardinal(@Brm.Surfaces[I].Verts[J].Color[0])^ <> PCardinal(@Brm.Surfaces[I].Verts[0].Color[0])^) then
        Colored := True;
    end;
    if Colored then
    begin
      SetLength(Surf.Colors, N);
      for J := 0 to N - 1 do
        Surf.Colors[J] := Vector4(Brm.Surfaces[I].Verts[J].Color[0] / 255, Brm.Surfaces[I].Verts[J].Color[1] / 255,
          Brm.Surfaces[I].Verts[J].Color[2] / 255, Brm.Surfaces[I].Verts[J].Color[3] / 255);
    end;
    N := Length(Brm.Surfaces[I].Indexes) div 3;
    SetLength(Surf.Indexes, N * 3);
    for J := 0 to N - 1 do
    begin
      Surf.Indexes[J * 3] := Brm.Surfaces[I].Indexes[J * 3];
      Surf.Indexes[J * 3 + 1] := Brm.Surfaces[I].Indexes[J * 3 + 2];
      Surf.Indexes[J * 3 + 2] := Brm.Surfaces[I].Indexes[J * 3 + 1];
    end;
  end;
  UpdateBounds;
  Result := Surfaces.Count > 0;
end;

function TD3StaticModelCache.Model(const Path: String): TD3StaticModel;
var
  Key: String;
  Stream: TStream;
  Ok, Binary: Boolean;
begin
  Key := NormalizeD3Path(Path);
  if FModels.TryGetValue(Key, Result) then
    Exit;
  Result := nil;
  Stream := D3Fs.OpenFile(Key);
  { Doom 3 BFG: only the binary version }
  Binary := Stream = nil;
  if Binary then
    Stream := D3Fs.OpenGenerated(Key);
  if Stream <> nil then
  try
    Result := TD3StaticModel.Create;
    Result.Name := Key;
    try
      if Binary then
        Ok := Result.LoadBinary(Stream)
      else
      if LowerCase(ExtractFileExt(Key)) = '.lwo' then
        Ok := Result.LoadLwo(Stream)
      else
      if LowerCase(ExtractFileExt(Key)) = '.ma' then
        Ok := Result.LoadMa(D3Fs.ReadText(Key))
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
