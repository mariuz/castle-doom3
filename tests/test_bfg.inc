{ Doom 3 BFG's binary formats (Doom3Bfg and the loaders' LoadFromBinary):
  the test writes its own ".resources" container, with binary versions of
  the test PK4's map, models and collision models (written here from the
  text versions, in the layouts idTech 4.5 reads) and small hand made
  images and sounds, then loads everything through a file system that has
  only that container. }

type
  TBfgWriter = class(TMemoryStream)
    procedure U8(const V: Byte);
    procedure Bool(const V: Boolean);
    procedure BigInt(const V: Int32);
    procedure BigInt64(const V: Int64);
    procedure BigWord(const V: Word);
    procedure BigFloat(const V: Single);
    procedure BigVec3(const V: TVector3);
    procedure LitInt(const V: Int32);
    procedure LitWord(const V: Word);
    procedure LitFloat(const V: Single);
    procedure LitVec3(const V: TVector3);
    procedure Str(const S: String);
    procedure Zeros(const N: Integer);
    procedure Half(const V: Single);
  end;

procedure TBfgWriter.U8(const V: Byte);
begin
  WriteBuffer(V, 1);
end;

procedure TBfgWriter.Bool(const V: Boolean);
begin
  U8(Ord(V));
end;

procedure TBfgWriter.BigInt(const V: Int32);
begin
  U8((V shr 24) and 255);
  U8((V shr 16) and 255);
  U8((V shr 8) and 255);
  U8(V and 255);
end;

procedure TBfgWriter.BigInt64(const V: Int64);
begin
  BigInt(Int32(V shr 32));
  BigInt(Int32(V and $FFFFFFFF));
end;

procedure TBfgWriter.BigWord(const V: Word);
begin
  U8(V shr 8);
  U8(V and 255);
end;

procedure TBfgWriter.BigFloat(const V: Single);
var
  I: Int32;
begin
  Move(V, I, 4);
  BigInt(I);
end;

procedure TBfgWriter.BigVec3(const V: TVector3);
begin
  BigFloat(V.X);
  BigFloat(V.Y);
  BigFloat(V.Z);
end;

procedure TBfgWriter.LitInt(const V: Int32);
begin
  WriteBuffer(V, 4);
end;

procedure TBfgWriter.LitWord(const V: Word);
begin
  WriteBuffer(V, 2);
end;

procedure TBfgWriter.LitFloat(const V: Single);
begin
  WriteBuffer(V, 4);
end;

procedure TBfgWriter.LitVec3(const V: TVector3);
begin
  WriteBuffer(V, 12);
end;

procedure TBfgWriter.Str(const S: String);
begin
  LitInt(Length(S));
  if S <> '' then
    WriteBuffer(S[1], Length(S));
end;

procedure TBfgWriter.Zeros(const N: Integer);
var
  I: Integer;
begin
  for I := 1 to N do
    U8(0);
end;

{ a half float (idDrawVert's texture coordinates), big endian }
procedure TBfgWriter.Half(const V: Single);
var
  A: Single;
  E, M: Integer;
  H: Word;
begin
  A := Abs(V);
  if A < Power(2, -14) then
  begin
    E := 0;
    M := Round(A / Power(2, -14) * 1024);
  end else
  begin
    E := Floor(Log2(A));
    M := Round((A / Power(2, E) - 1) * 1024);
    if M >= 1024 then
    begin
      M := 0;
      Inc(E);
    end;
    E := E + 15;
  end;
  H := (E shl 10) or M;
  if V < 0 then
    H := H or $8000;
  BigWord(H);
end;

{ idRenderModelStatic::WriteBinaryModel's layout. }
procedure WriteBfgModel(const W: TBfgWriter; const Name: String; const Surfaces: array of TBfgSurface);
var
  I, J, K: Integer;
begin
  W.BigInt($42524D6C);
  W.BigInt64(0);
  W.BigInt(Length(Surfaces));
  for I := 0 to High(Surfaces) do
  begin
    W.BigInt(I);
    W.Str(Surfaces[I].Material);
    W.Bool(True);
    W.Zeros(24); { bounds }
    W.BigInt(0);
    W.Zeros(4);
    W.BigInt(Length(Surfaces[I].Verts));
    W.BigInt(Length(Surfaces[I].Verts));
    for J := 0 to High(Surfaces[I].Verts) do
    begin
      W.LitVec3(Surfaces[I].Verts[J].Position);
      W.Half(Surfaces[I].Verts[J].ST.X);
      W.Half(Surfaces[I].Verts[J].ST.Y);
      for K := 0 to 2 do
        W.U8(Round((Surfaces[I].Verts[J].Normal[K] + 1) * 127.5));
      W.U8(0);
      W.Zeros(4); { tangent }
      for K := 0 to 3 do
        W.U8(Surfaces[I].Verts[J].Color[K]);
      for K := 0 to 3 do
        W.U8(Surfaces[I].Verts[J].Color2[K]);
    end;
    W.BigInt(Length(Surfaces[I].ShadowVerts));
    for J := 0 to High(Surfaces[I].ShadowVerts) do
    begin
      W.LitVec3(Surfaces[I].ShadowVerts[J]);
      W.LitFloat(1);
    end;
    W.BigInt(Length(Surfaces[I].Indexes));
    for J := 0 to High(Surfaces[I].Indexes) do
      W.BigWord(Surfaces[I].Indexes[J]);
    W.BigInt(0); { silIndexes }
    W.BigInt(0); { mirroredVerts }
    W.BigInt(0); { dupVerts }
    W.BigInt(0); { silEdges }
    W.Bool(False); { dominantTris }
    W.BigInt(Surfaces[I].NoFrontCaps);
    W.BigInt(Surfaces[I].NoCaps);
    W.BigInt(0);
  end;
  W.Zeros(24); { bounds }
  W.Zeros(12);
  W.Str(Name);
  W.Zeros(9);
end;

{ The text .proc as a .bproc. }
procedure WriteBfgProc(const W: TBfgWriter; const Proc: TD3ProcFile; const ShadowName: String);
var
  Surfaces: array of TBfgSurface;
  M: TD3ProcModel;
  SM: TD3ShadowModel;
  I, J, K, Entries: Integer;
begin
  SM := Proc.FindShadowModel(ShadowName);
  Entries := Proc.ModelCount + 2;
  if SM <> nil then
    Inc(Entries);
  W.BigInt(BfgProcMagic);
  W.BigInt(Entries);
  W.Str('maps/bfgmap.map');
  W.BigInt64(0);
  for I := 0 to Proc.ModelCount - 1 do
  begin
    M := Proc.Model(I);
    W.Str('shadowModel');
    W.Str(M.Name);
    SetLength(Surfaces, M.Surfaces.Count);
    for J := 0 to M.Surfaces.Count - 1 do
    begin
      Surfaces[J] := Default(TBfgSurface);
      Surfaces[J].Material := M.Surfaces[J].Material;
      SetLength(Surfaces[J].Verts, Length(M.Surfaces[J].Vertexes));
      for K := 0 to High(M.Surfaces[J].Vertexes) do
      begin
        Surfaces[J].Verts[K] := Default(TBfgVertex);
        Surfaces[J].Verts[K].Position := M.Surfaces[J].Vertexes[K].Position;
        Surfaces[J].Verts[K].ST := M.Surfaces[J].Vertexes[K].ST;
        Surfaces[J].Verts[K].Normal := M.Surfaces[J].Vertexes[K].Normal;
      end;
      SetLength(Surfaces[J].Indexes, Length(M.Surfaces[J].Indexes));
      for K := 0 to High(M.Surfaces[J].Indexes) do
        Surfaces[J].Indexes[K] := M.Surfaces[J].Indexes[K];
    end;
    WriteBfgModel(W, M.Name, Surfaces);
  end;
  if SM <> nil then
  begin
    W.Str('shadowModel');
    W.Str(SM.Name);
    SetLength(Surfaces, 1);
    Surfaces[0] := Default(TBfgSurface);
    Surfaces[0].Material := '_default';
    SetLength(Surfaces[0].ShadowVerts, Length(SM.Positions));
    for K := 0 to High(SM.Positions) do
      Surfaces[0].ShadowVerts[K] := SM.Positions[K];
    SetLength(Surfaces[0].Indexes, Length(SM.Indexes));
    for K := 0 to High(SM.Indexes) do
      Surfaces[0].Indexes[K] := SM.Indexes[K];
    Surfaces[0].NoCaps := SM.NoCaps;
    Surfaces[0].NoFrontCaps := SM.NoFrontCaps;
    WriteBfgModel(W, SM.Name, Surfaces);
  end;
  W.Str('interAreaPortals');
  W.BigInt(Proc.NumAreas);
  W.BigInt(Length(Proc.Portals));
  for I := 0 to High(Proc.Portals) do
  begin
    W.BigInt(Length(Proc.Portals[I].Points));
    W.BigInt(Proc.Portals[I].PositiveArea);
    W.BigInt(Proc.Portals[I].NegativeArea);
    for J := 0 to High(Proc.Portals[I].Points) do
      W.BigVec3(Proc.Portals[I].Points[J]);
  end;
  W.Str('nodes');
  W.BigInt(Length(Proc.Nodes));
  for I := 0 to High(Proc.Nodes) do
  begin
    W.BigFloat(Proc.Nodes[I].Plane.X);
    W.BigFloat(Proc.Nodes[I].Plane.Y);
    W.BigFloat(Proc.Nodes[I].Plane.Z);
    W.BigFloat(Proc.Nodes[I].Plane.W);
    W.BigInt(Proc.Nodes[I].Children[0]);
    W.BigInt(Proc.Nodes[I].Children[1]);
  end;
end;

{ The text .md5mesh as a .bmd5mesh: vertexes in the bind pose with up to
  four joints and byte weights, joints relative to their parents. }
procedure WriteBfgMd5Mesh(const W: TBfgWriter; const Model: TD3Md5Model);
var
  Surfaces: array of TBfgSurface;
  Positions: array of TVector3;
  Mesh: TD3Md5Mesh;
  Q: TQuaternion;
  T: TVector3;
  I, J, K, Sum, B: Integer;
  JointBytes, WeightBytes: array [0..3] of Byte;
begin
  SetLength(Surfaces, 0);
  WriteBfgModel(W, Model.Name, Surfaces);
  W.BigInt(BfgMd5MeshMagic);
  W.BigInt(Length(Model.Joints));
  for I := 0 to High(Model.Joints) do
  begin
    W.Str(Model.Joints[I].Name);
    W.BigInt(Model.Joints[I].Parent);
  end;
  W.BigInt(Length(Model.Joints));
  for I := 0 to High(Model.Joints) do
  begin
    Q := Model.Joints[I].Orientation;
    T := Model.Joints[I].Position;
    if Model.Joints[I].Parent >= 0 then
    begin
      Q := QuatMultiply(QuatConjugate(Model.Joints[Model.Joints[I].Parent].Orientation), Q);
      T := QuatRotate(QuatConjugate(Model.Joints[Model.Joints[I].Parent].Orientation),
        T - Model.Joints[Model.Joints[I].Parent].Position);
    end;
    W.BigFloat(Q.Data.Vector.X);
    W.BigFloat(Q.Data.Vector.Y);
    W.BigFloat(Q.Data.Vector.Z);
    W.BigFloat(-Q.Data.Real);
    W.LitVec3(T);
  end;
  W.BigInt(Length(Model.Joints));
  W.Zeros(48 * Length(Model.Joints));
  W.BigInt(Model.Meshes.Count);
  for I := 0 to Model.Meshes.Count - 1 do
  begin
    Mesh := Model.Meshes[I];
    W.Str(Mesh.Shader);
    W.BigInt(Length(Mesh.Verts));
    W.BigInt(Length(Mesh.Tris) div 3);
    W.BigInt(0); { mesh joints }
    W.BigFloat(0);
    W.BigInt(Length(Mesh.Verts));
    W.BigInt(Length(Mesh.Verts));
    W.BigInt(Length(Mesh.Tris));
    W.BigInt(0);
    W.BigInt(0);
    W.BigInt(0);
    SetLength(Positions, Length(Mesh.Verts));
    Model.SkinMesh(I, Model.Joints, Positions);
    for J := 0 to High(Mesh.Verts) do
    begin
      W.BigVec3(CgeToD3(Positions[J]));
      W.Half(Mesh.Verts[J].ST.X);
      W.Half(Mesh.Verts[J].ST.Y);
      W.Zeros(8); { normal, tangent }
      FillChar(JointBytes, SizeOf(JointBytes), 0);
      FillChar(WeightBytes, SizeOf(WeightBytes), 0);
      Sum := 0;
      for K := 0 to Min(3, Mesh.Verts[J].WeightCount - 1) do
      begin
        JointBytes[K] := Mesh.Weights[Mesh.Verts[J].StartWeight + K].Joint;
        B := Round(Mesh.Weights[Mesh.Verts[J].StartWeight + K].Bias * 255);
        if K = Min(3, Mesh.Verts[J].WeightCount - 1) then
          B := 255 - Sum;
        WeightBytes[K] := B;
        Inc(Sum, B);
      end;
      W.WriteBuffer(JointBytes, 4);
      W.WriteBuffer(WeightBytes, 4);
    end;
    for J := 0 to High(Mesh.Tris) do
      W.BigWord(Mesh.Tris[J]);
    W.Zeros(2 * Length(Mesh.Tris));
    W.BigInt(I);
  end;
end;

procedure WriteBfgMd5Anim(const W: TBfgWriter; const Anim: TD3Md5Anim);
var
  I, J: Integer;
  O: TVector3;
begin
  W.BigInt(BfgMd5AnimMagic);
  W.BigInt64(0);
  W.BigInt(Anim.NumFrames);
  W.BigInt(Anim.FrameRate);
  W.BigInt(0);
  W.BigInt(Length(Anim.Hierarchy));
  W.BigInt(Anim.NumAnimatedComponents);
  W.BigInt(0); { bounds }
  W.BigInt(Length(Anim.Hierarchy));
  for I := 0 to High(Anim.Hierarchy) do
  begin
    W.Str(Anim.Hierarchy[I].Name);
    W.BigInt(Anim.Hierarchy[I].Parent);
    W.BigInt(Anim.Hierarchy[I].Flags);
    W.BigInt(Anim.Hierarchy[I].StartIndex);
  end;
  W.BigInt(Length(Anim.BaseFrame));
  for I := 0 to High(Anim.BaseFrame) do
  begin
    O := Anim.BaseFrame[I].Orientation;
    W.BigFloat(O.X);
    W.BigFloat(O.Y);
    W.BigFloat(O.Z);
    W.BigFloat(Sqrt(Max(0, 1 - O.X * O.X - O.Y * O.Y - O.Z * O.Z)));
    W.LitVec3(Anim.BaseFrame[I].Position);
  end;
  W.BigInt(Anim.NumFrames * Anim.NumAnimatedComponents);
  for I := 0 to Anim.NumFrames - 1 do
    for J := 0 to Anim.NumAnimatedComponents - 1 do
      W.LitFloat(Anim.Frames[I][J]);
  W.LitFloat(0); { the pad }
  W.LitVec3(TVector3.Zero);
end;

{ A static model (loaded from its LWO or ASE) as the render model Doom 3
  makes of it: clockwise triangles, t down. }
procedure WriteBfgStatic(const W: TBfgWriter; const Model: TD3StaticModel);
var
  Surfaces: array of TBfgSurface;
  S: TD3StaticSurface;
  I, J, K: Integer;
begin
  SetLength(Surfaces, Model.Surfaces.Count);
  for I := 0 to Model.Surfaces.Count - 1 do
  begin
    S := Model.Surfaces[I];
    Surfaces[I] := Default(TBfgSurface);
    Surfaces[I].Material := S.Material;
    SetLength(Surfaces[I].Verts, Length(S.Positions));
    for J := 0 to High(S.Positions) do
    begin
      Surfaces[I].Verts[J] := Default(TBfgVertex);
      Surfaces[I].Verts[J].Position := S.Positions[J];
      Surfaces[I].Verts[J].ST := Vector2(S.TexCoords[J].X, 1 - S.TexCoords[J].Y);
      for K := 0 to 3 do
        if S.HasColors then
          Surfaces[I].Verts[J].Color[K] := Round(S.Colors[J][K] * 255)
        else
          Surfaces[I].Verts[J].Color[K] := 255;
    end;
    SetLength(Surfaces[I].Indexes, Length(S.Indexes));
    for J := 0 to Length(S.Indexes) div 3 - 1 do
    begin
      Surfaces[I].Indexes[J * 3] := S.Indexes[J * 3];
      Surfaces[I].Indexes[J * 3 + 1] := S.Indexes[J * 3 + 2];
      Surfaces[I].Indexes[J * 3 + 2] := S.Indexes[J * 3 + 1];
    end;
  end;
  WriteBfgModel(W, Model.Name, Surfaces);
end;

{ The text .cm as a .bcm. }
procedure WriteBfgCm(const W: TBfgWriter; const Cm: TD3CollisionFile);
const
  Names: array [0..15] of String = ('solid', 'opaque', 'water', 'playerclip', 'monsterclip',
    'moveableclip', 'ikclip', 'blood', 'body', 'projectile', 'corpse', 'rendermodel',
    'trigger', 'aas_solid', 'aas_obstacle', 'flashlight_trigger');
var
  M: TD3CollisionModel;
  I, J, K, E, N, A, B, Bits: Integer;
  Parts: TStringArray;
  Part: String;
begin
  W.BigInt(Cm.ModelCount);
  W.Str('');
  W.BigInt(Int32(Cm.Crc));
  W.Str('CM');
  W.Str('1.00');
  for I := 0 to Cm.ModelCount - 1 do
  begin
    M := Cm.Model(I);
    W.BigInt(BfgCmMagic);
    W.BigInt64(0);
    W.Str(M.Name);
    W.Zeros(24);
    W.BigInt(0);
    W.Bool(False);
    W.BigInt(Length(M.Vertices));
    W.BigInt(Length(M.Edges));
    W.BigInt(Length(M.Polygons));
    W.BigInt(Length(M.Brushes));
    W.Zeros(7 * 4);
    for J := 0 to High(M.Vertices) do
    begin
      W.BigVec3(M.Vertices[J]);
      W.Zeros(12);
    end;
    for J := 0 to High(M.Edges) do
    begin
      W.Zeros(16);
      W.BigInt(M.Edges[J][0]);
      W.BigInt(M.Edges[J][1]);
      W.Zeros(12);
    end;
    W.BigInt(0);
    W.BigInt(0);
    { one material per polygon }
    W.BigInt(Length(M.Polygons));
    for J := 0 to High(M.Polygons) do
      W.Str(M.Polygons[J].Material);
    for J := 0 to High(M.Polygons) do
    begin
      N := Length(M.Polygons[J].Verts);
      W.BigInt(J);
      W.BigInt(N);
      W.Zeros(24);
      W.BigInt(0);
      W.BigInt(0);
      W.BigVec3(M.Polygons[J].Normal);
      W.BigFloat(-M.Polygons[J].Dist);
      for K := 0 to N - 1 do
      begin
        { the edge from this vertex to the next (negative: stored the
          other way) }
        A := M.Polygons[J].Verts[K];
        B := M.Polygons[J].Verts[(K + 1) mod N];
        E := 0;
        for Bits := 1 to High(M.Edges) do
          if (M.Edges[Bits][0] = A) and (M.Edges[Bits][1] = B) then
          begin
            E := Bits;
            Break;
          end else
          if (M.Edges[Bits][1] = A) and (M.Edges[Bits][0] = B) then
          begin
            E := -Bits;
            Break;
          end;
        W.BigInt(E);
      end;
    end;
    for J := 0 to High(M.Brushes) do
    begin
      W.BigInt(0);
      W.BigInt(Length(M.Brushes[J].Planes));
      W.BigInt(0);
      W.BigVec3(M.Brushes[J].Mins);
      W.BigVec3(M.Brushes[J].Maxs);
      Bits := 0;
      Parts := LowerCase(M.Brushes[J].Contents).Split([',']);
      for Part in Parts do
        for K := 0 to High(Names) do
          if Trim(Part) = Names[K] then
            Bits := Bits or (1 shl K);
      W.BigInt(Bits);
      W.BigInt(0);
      for K := 0 to High(M.Brushes[J].Planes) do
      begin
        W.BigFloat(M.Brushes[J].Planes[K].X);
        W.BigFloat(M.Brushes[J].Planes[K].Y);
        W.BigFloat(M.Brushes[J].Planes[K].Z);
        W.BigFloat(-M.Brushes[J].Planes[K].W);
      end;
    end;
    { a leaf }
    W.BigInt(-1);
    W.BigFloat(0);
    W.BigInt(-1);
    W.BigInt(-1);
  end;
end;

{ A .bimage of one level. }
procedure WriteBfgImage(const W: TBfgWriter; const Format, ColorFormat, Width, Height: Integer;
  const Data: array of Byte);
begin
  W.BigInt64(0);
  W.BigInt($0A4D4942);
  W.BigInt(1); { 2D }
  W.BigInt(Format);
  W.BigInt(ColorFormat);
  W.BigInt(Width);
  W.BigInt(Height);
  W.BigInt(1);
  W.BigInt(0);
  W.BigInt(0);
  W.BigInt(Width);
  W.BigInt(Height);
  W.BigInt(Length(Data));
  W.WriteBuffer(Data[0], Length(Data));
end;

{ An .idwav of Microsoft ADPCM blocks (mono, 4 nibble bytes a block). }
procedure WriteBfgSound(const W: TBfgWriter; const Blocks: array of Byte; const NumSamples: Integer);
const
  Coefs: array [0..13] of SmallInt = (256, 0, 512, -256, 0, 0, 192, 64, 240, 0, 460, -208, 392, -232);
var
  I: Integer;
begin
  W.BigInt($6D7A7274);
  W.BigInt64(0);
  W.Bool(False);
  W.BigInt(0);
  W.BigInt(NumSamples);
  W.LitWord(2); { ADPCM }
  W.LitWord(1);
  W.LitInt(22050);
  W.LitInt(22050 * 11 div 20);
  W.LitWord(11); { block size: 7 bytes of header, 4 of nibbles }
  W.LitWord(4);
  W.LitWord(32);
  W.LitWord(10); { samples per block }
  W.LitWord(7);
  for I := 0 to 13 do
    W.LitWord(Word(Coefs[I]));
  W.BigInt(0); { amplitude }
  W.BigInt(Length(Blocks));
  W.BigInt(1);
  W.BigInt(NumSamples);
  W.BigInt(Length(Blocks));
  W.WriteBuffer(Blocks[0], Length(Blocks));
end;

type
  TBfgFile = record
    Name: String;
    Data: TBfgWriter;
  end;

{ A ".resources" container of the files. }
procedure WriteBfgResources(const FileName: String; const Files: array of TBfgFile);
var
  Out_, Table: TBfgWriter;
  I: Integer;
  Offset: Int64;
begin
  Out_ := TBfgWriter.Create;
  Table := TBfgWriter.Create;
  try
    Out_.BigInt(Int32($D000000D));
    Out_.BigInt(0);
    Out_.BigInt(0);
    Table.BigInt(Length(Files));
    for I := 0 to High(Files) do
    begin
      Offset := Out_.Position;
      Out_.WriteBuffer(Files[I].Data.Memory^, Files[I].Data.Size);
      Table.Str(Files[I].Name);
      Table.BigInt(Offset);
      Table.BigInt(Files[I].Data.Size);
    end;
    Offset := Out_.Position;
    Out_.WriteBuffer(Table.Memory^, Table.Size);
    Out_.Position := 4;
    Out_.BigInt(Offset);
    Out_.BigInt(Table.Size);
    Out_.SaveToFile(FileName);
  finally
    Out_.Free;
    Table.Free;
  end;
end;

procedure TestBfg;
const
  { DXT5 blocks: 8 bytes of alpha (two values, 3 bit indexes), 8 of color
    (two 565 colors, 2 bit indexes) }
  { diffuse (YCoCg): Y 200 in alpha, Co and Cg 16 / 31 and 32 / 63, scale 0 }
  DiffuseBlock: array [0..15] of Byte = (200, 200, 0, 0, 0, 0, 0, 0, $00, $84, $00, $84, 0, 0, 0, 0);
  { its alpha test version (DXT1, alpha in green): the two top rows 255,
    the two bottom rows 0 }
  CoverageBlock: array [0..7] of Byte = ($E0, $07, $00, $00, $00, $00, $55, $55);
  { a normal map: x 255 in alpha, y 32 / 63 in green }
  NormalBlock: array [0..15] of Byte = (255, 255, 0, 0, 0, 0, 0, 0, $00, $04, $00, $04, 0, 0, 0, 0);
  { red, green / blue with alpha 128, white (top row first) }
  RgbaPixels: array [0..15] of Byte = (255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 128, 255, 255, 255, 255);
  { two ADPCM blocks: predictor 0 (coefficients 256, 0), delta 16, the
    samples 100 and 50 before; predictor 1 (512, -256), delta 32, 1000 and
    900. A reference decoder gives the values below. }
  SoundBlocks: array [0..21] of Byte = (
    0, 16, 0, 100, 0, 50, 0, $12, $8F, $70, $39,
    1, 32, 0, $E8, $03, $84, $03, $21, $F0, $00, $00);
  SoundSamples: array [0..15] of Integer = (50, 100, 116, 148, 20, -28, 273, 273, 549, -25,
    900, 1000, 1164, 1356, 1523, 1690);
var
  Dir: String;
  Saved, Fs: TDoom3FileSystem;
  Files: array of TBfgFile;
  TextProc, BinProc: TD3ProcFile;
  TextModel, BinModel: TD3Md5Model;
  TextAnim, BinAnim: TD3Md5Anim;
  TextStatic, BinStatic: TD3StaticModel;
  TextCm, BinCm: TD3CollisionFile;
  BinCache: TD3Md5Cache;
  BinStatics: TD3StaticModelCache;
  PoseA, PoseB: TD3JointArray;
  PosA, PosB: array of TVector3;
  Img: TCastleImage;
  Stream: TStream;
  Maps: TStringList;
  Bytes: array of Byte;
  I, J, K: Integer;
  Same: Boolean;
  MaxDiff: Single;
  R: TBfgReader;
  M: TD3ProcModel;

  function Add(const Name: String): TBfgWriter;
  begin
    SetLength(Files, Length(Files) + 1);
    Files[High(Files)].Name := Name;
    Files[High(Files)].Data := TBfgWriter.Create;
    Result := Files[High(Files)].Data;
  end;

begin
  { the reader: big and little endian numbers, strings, half floats }
  Stream := TBfgWriter.Create;
  TBfgWriter(Stream).BigInt($01020304);
  TBfgWriter(Stream).LitInt($01020304);
  TBfgWriter(Stream).BigFloat(1.5);
  TBfgWriter(Stream).LitFloat(-2.25);
  TBfgWriter(Stream).Str('hello');
  TBfgWriter(Stream).BigWord($1234);
  TBfgWriter(Stream).Half(0.75);
  TBfgWriter(Stream).Half(-3.5);
  R := TBfgReader.Create(Stream, True);
  try
    CheckEquals($01020304, R.BigInt, 'a big endian int');
    CheckEquals($01020304, R.LittleInt, 'a little endian int');
    CheckNear(1.5, R.BigFloat, 'a big endian float', 0.0001);
    CheckNear(-2.25, R.LittleFloat, 'a little endian float', 0.0001);
    CheckEquals('hello', R.Str, 'a string');
    CheckEquals($1234, R.BigWord, 'a big endian short');
    CheckNear(0.75, BfgHalfToFloat(R.BigWord), 'a half float', 0.0001);
    CheckNear(-3.5, BfgHalfToFloat(R.BigWord), 'a negative half float', 0.0001);
    Check(R.Eof, 'the reader is at the end');
  finally
    R.Free;
  end;
  CheckNear(1, BfgHalfToFloat($3C00), 'half float 1', 0.0001);
  CheckNear(0, BfgHalfToFloat(0), 'half float 0', 0.0001);

  { the text versions, from the test PK4 }
  TextProc := TD3ProcFile.Create;
  TextCm := TD3CollisionFile.Create;
  TextModel := Md5Cache.Model('models/md5/test/blob.md5mesh');
  TextAnim := Md5Cache.Anim('models/md5/test/blob_walk.md5anim');
  TextStatic := StaticModels.Model('models/mapobjects/test/barrel.lwo');
  BinProc := TD3ProcFile.Create;
  BinCm := TD3CollisionFile.Create;
  BinCache := TD3Md5Cache.Create;
  BinStatics := TD3StaticModelCache.Create;
  Saved := D3Fs;
  Fs := TDoom3FileSystem.Create;
  SetLength(Files, 0);
  try
    Check(TextProc.LoadFromVfs('maps/testmap.proc') and TextCm.LoadFromVfs('maps/testmap.cm') and
      (TextModel <> nil) and (TextAnim <> nil) and (TextStatic <> nil), 'the text versions for the BFG test');
    if (TextModel = nil) or (TextAnim = nil) or (TextStatic = nil) then
      Exit;

    WriteBfgProc(Add('generated/maps/bfgmap.bproc'), TextProc, '_prelight_light_1');
    WriteBfgCm(Add('generated/maps/bfgmap.bcm'), TextCm);
    WriteBfgMd5Mesh(Add('generated/rendermodels/models/md5/test/blob.bmd5mesh'), TextModel);
    WriteBfgMd5Anim(Add('generated/anim/models/md5/test/blob_walk.bmd5anim'), TextAnim);
    WriteBfgStatic(Add('generated/rendermodels/models/mapobjects/test/barrel.blwo'), TextStatic);
    WriteBfgImage(Add('generated/images/textures/test/bfgrgba#__0200.bimage'), 1, 0, 2, 2, RgbaPixels);
    WriteBfgImage(Add('generated/images/textures/test/bfgdiffuse#__0100.bimage'), 8, 2, 4, 4, DiffuseBlock);
    WriteBfgImage(Add('generated/images/textures/test/bfgdiffuse#__1000.bimage'), 7, 3, 4, 4, CoverageBlock);
    WriteBfgImage(Add('generated/images/addnormals/textures/test/bfg_local/heightmap/textures/test/bfg_h/4#__0300.bimage'),
      8, 1, 4, 4, NormalBlock);
    WriteBfgSound(Add('generated/sound/test/bfgtone.idwav'), SoundBlocks, 16);
    Add('maps/bfgmap.map').Str('Version 2');

    Dir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'castle_doom3_bfg_test';
    ForceDirectories(Dir);
    WriteBfgResources(IncludeTrailingPathDelimiter(Dir) + '_common.resources', Files);

    D3Fs := Fs;
    Check(Fs.AddGameDirectory(Dir), 'mount the .resources container');
    Check(Fs.IsBfg, 'the file system has Doom 3 BFG data');
    Check(Fs.FileExists('maps/bfgmap.map'), 'a plain file of the container');
    Check(Fs.FileExists('maps/bfgmap.proc') and not Fs.FileExists('maps/other.proc'),
      'a .proc exists as its .bproc');
    CheckEquals('generated/maps/bfgmap.bcm', Fs.BfgGenerated('maps/bfgmap.cm'), 'the binary of a .cm');
    CheckEquals('generated/rendermodels/models/md5/test/blob.bmd5mesh',
      Fs.BfgGenerated('models/md5/test/blob.md5mesh'), 'the binary of an .md5mesh');
    Check(Fs.FileExists('models/mapobjects/test/barrel.lwo'), 'an .lwo exists as its .blwo');
    Check(Fs.FileExists('textures/test/bfgrgba.tga') and not Fs.FileExists('textures/test/none.tga'),
      'an image exists as its .bimage');
    Check(Fs.FileExists('sound/test/bfgtone.wav') and not Fs.FileExists('sound/test/bfgtone.ogg'),
      'a sound exists as a .wav');
    CheckEquals('sound/test/bfgtone.wav', D3SoundFile('sound/test/bfgtone.ogg'), 'a sound shader''s .ogg is the .wav');
    Maps := Fs.FindFiles('maps/', '.proc');
    try
      Check((Maps.Count = 1) and (Maps[0] = 'maps/bfgmap.proc'), 'FindFiles lists the binary maps');
    finally
      Maps.Free;
    end;

    { images }
    Stream := Fs.OpenFile('generated/images/textures/test/bfgrgba#__0200.bimage');
    Img := nil;
    try
      Check(Stream <> nil, 'open a .bimage');
      if Stream <> nil then
        Img := BfgDecodeImage(Stream);
      Check(Img is TRGBAlphaImage, 'an RGBA .bimage decodes with alpha');
      if Img is TRGBAlphaImage then
      begin
        CheckEquals(2, Img.Width, 'image width');
        { the file's rows go down, CGE's up }
        Check((TRGBAlphaImage(Img).PixelPtr(0, 1)^.X = 255) and (TRGBAlphaImage(Img).PixelPtr(0, 1)^.Y = 0),
          'the top left pixel is red');
        Check((TRGBAlphaImage(Img).PixelPtr(0, 0)^.Z = 255) and (TRGBAlphaImage(Img).PixelPtr(0, 0)^.W = 128),
          'the bottom left pixel is half transparent blue');
      end;
    finally
      Stream.Free;
      FreeAndNil(Img);
    end;
    Stream := Fs.OpenFile('textures/test/bfgdiffuse.tga');
    try
      Check((Stream <> nil) and (Stream.Size = 18 + 4 * 4 * 4), 'a diffuse image with its alpha test version reads as a 32 bit TGA');
      if (Stream <> nil) and (Stream.Size = 18 + 64) then
      begin
        SetLength(Bytes, Stream.Size);
        Stream.ReadBuffer(Bytes[0], Stream.Size);
        { BGRA, the bottom row first: Y 200, Co 3, Cg 1 }
        CheckNear(196, Bytes[18], 'YCoCg to blue', 2);
        CheckNear(201, Bytes[19], 'YCoCg to green', 2);
        CheckNear(202, Bytes[20], 'YCoCg to red', 2);
        CheckEquals(0, Bytes[21], 'the coverage image''s alpha, bottom row');
        CheckEquals(255, Bytes[18 + 3 * 16 + 3], 'the coverage image''s alpha, top row');
      end;
    finally
      Stream.Free;
    end;
    Img := EvaluateImageProgram('addnormals(textures/test/bfg_local.tga, heightmap(textures/test/bfg_h.tga, 4))', ikNormal);
    try
      Check(Img is TRGBImage, 'an image program is its generated image');
      if Img is TRGBImage then
      begin
        CheckEquals(4, Img.Width, 'the normal map''s size');
        CheckEquals(255, TRGBImage(Img).PixelPtr(0, 0)^.X, 'the normal''s x was in alpha');
        { y 129 of 255, green flipped like every normal map }
        CheckNear(126, TRGBImage(Img).PixelPtr(0, 0)^.Y, 'the normal''s y, flipped', 2);
        CheckNear(128, TRGBImage(Img).PixelPtr(0, 0)^.Z, 'the normal''s z is computed', 12);
      end;
    finally
      FreeAndNil(Img);
    end;

    { a sound }
    Stream := Fs.OpenFile('sound/test/bfgtone.wav');
    try
      Check((Stream <> nil) and (Stream.Size = 44 + 16 * 2), 'an ADPCM .idwav reads as a PCM .wav');
      if (Stream <> nil) and (Stream.Size = 44 + 32) then
      begin
        SetLength(Bytes, Stream.Size);
        Stream.ReadBuffer(Bytes[0], Stream.Size);
        Check((Chr(Bytes[0]) = 'R') and (Chr(Bytes[8]) = 'W') and (Bytes[22] = 1) and (Bytes[34] = 16),
          'a RIFF WAVE header: mono, 16 bits');
        CheckEquals(22050, Bytes[24] or (Bytes[25] shl 8), 'the sample rate');
        Same := True;
        for I := 0 to 15 do
          if SmallInt(Bytes[44 + I * 2] or (Bytes[45 + I * 2] shl 8)) <> SoundSamples[I] then
            Same := False;
        Check(Same, 'the ADPCM blocks decode to the reference samples');
      end;
    finally
      Stream.Free;
    end;

    { the map's render data }
    Check(BinProc.LoadFromVfs('maps/bfgmap.proc'), 'load the .bproc');
    CheckEquals(TextProc.ModelCount, BinProc.ModelCount, '.bproc models');
    CheckEquals(TextProc.NumAreas, BinProc.NumAreas, '.bproc areas');
    CheckEquals(Length(TextProc.Portals), Length(BinProc.Portals), '.bproc portals');
    CheckEquals(Length(TextProc.Nodes), Length(BinProc.Nodes), '.bproc nodes');
    CheckEquals(1, BinProc.ShadowModelCount, '.bproc shadow models');
    if BinProc.FindShadowModel('_prelight_light_1') <> nil then
    begin
      CheckEquals(Length(TextProc.FindShadowModel('_prelight_light_1').Positions),
        Length(BinProc.FindShadowModel('_prelight_light_1').Positions), 'the shadow volume''s vertexes');
      CheckEquals(TextProc.FindShadowModel('_prelight_light_1').NoCaps,
        BinProc.FindShadowModel('_prelight_light_1').NoCaps, 'the shadow volume''s indexes without caps');
    end;
    CheckEquals(1, BinProc.PointInArea(Vector3(500, 0, 50)), 'a point in room B, by the binary nodes');
    if (Length(BinProc.Portals) > 0) and (Length(TextProc.Portals) > 0) then
      CheckVec3(TextProc.Portals[0].Points[0], BinProc.Portals[0].Points[0], 'a portal point');
    Same := BinProc.ModelCount = TextProc.ModelCount;
    MaxDiff := 0;
    if Same then
      for I := 0 to TextProc.ModelCount - 1 do
      begin
        M := BinProc.FindModel(TextProc.Model(I).Name);
        if (M = nil) or (M.Surfaces.Count <> TextProc.Model(I).Surfaces.Count) then
        begin
          Same := False;
          Break;
        end;
        for J := 0 to M.Surfaces.Count - 1 do
        begin
          if (M.Surfaces[J].Material <> TextProc.Model(I).Surfaces[J].Material) or
             (Length(M.Surfaces[J].Vertexes) <> Length(TextProc.Model(I).Surfaces[J].Vertexes)) or
             (Length(M.Surfaces[J].Indexes) <> Length(TextProc.Model(I).Surfaces[J].Indexes)) then
          begin
            Same := False;
            Break;
          end;
          for K := 0 to High(M.Surfaces[J].Vertexes) do
          begin
            MaxDiff := Max(MaxDiff, (M.Surfaces[J].Vertexes[K].Position - TextProc.Model(I).Surfaces[J].Vertexes[K].Position).Length);
            { half floats: 11 bits }
            MaxDiff := Max(MaxDiff, (M.Surfaces[J].Vertexes[K].ST - TextProc.Model(I).Surfaces[J].Vertexes[K].ST).Length /
              Max(1, TextProc.Model(I).Surfaces[J].Vertexes[K].ST.Length));
            MaxDiff := Max(MaxDiff, (M.Surfaces[J].Vertexes[K].Normal - TextProc.Model(I).Surfaces[J].Vertexes[K].Normal).Length);
          end;
          for K := 0 to High(M.Surfaces[J].Indexes) do
            if M.Surfaces[J].Indexes[K] <> TextProc.Model(I).Surfaces[J].Indexes[K] then
              Same := False;
        end;
      end;
    Check(Same, 'the .bproc has the text version''s models, materials and indexes');
    Check(MaxDiff < 0.02, Format('its vertexes are the text version''s (off by up to %f)', [MaxDiff]));

    { the collision models }
    Check(BinCm.LoadFromVfs('maps/bfgmap.cm'), 'load the .bcm');
    CheckEquals(TextCm.ModelCount, BinCm.ModelCount, '.bcm models');
    CheckEquals(Int64(TextCm.Crc), Int64(BinCm.Crc), '.bcm CRC');
    if (BinCm.ModelCount > 0) and (TextCm.ModelCount > 0) then
    begin
      CheckEquals(TextCm.World.Name, BinCm.World.Name, '.bcm world name');
      CheckEquals(Length(TextCm.World.Vertices), Length(BinCm.World.Vertices), '.bcm vertexes');
      CheckEquals(Length(TextCm.World.Polygons), Length(BinCm.World.Polygons), '.bcm polygons');
      CheckEquals(Length(TextCm.World.Brushes), Length(BinCm.World.Brushes), '.bcm brushes');
      Same := (Length(TextCm.World.Polygons) = Length(BinCm.World.Polygons)) and
        (Length(TextCm.World.Brushes) = Length(BinCm.World.Brushes));
      if Same then
      begin
        for I := 0 to High(TextCm.World.Polygons) do
        begin
          if (TextCm.World.Polygons[I].Material <> BinCm.World.Polygons[I].Material) or
             (Abs(TextCm.World.Polygons[I].Dist - BinCm.World.Polygons[I].Dist) > 0.001) or
             (Length(TextCm.World.Polygons[I].Verts) <> Length(BinCm.World.Polygons[I].Verts)) then
            Same := False
          else
            for J := 0 to High(TextCm.World.Polygons[I].Verts) do
              if TextCm.World.Polygons[I].Verts[J] <> BinCm.World.Polygons[I].Verts[J] then
                Same := False;
        end;
        for I := 0 to High(TextCm.World.Brushes) do
        begin
          if (LowerCase(TextCm.World.Brushes[I].Contents) <> BinCm.World.Brushes[I].Contents) or
             (Length(TextCm.World.Brushes[I].Planes) <> Length(BinCm.World.Brushes[I].Planes)) then
            Same := False
          else
            for J := 0 to High(TextCm.World.Brushes[I].Planes) do
              if (TextCm.World.Brushes[I].Planes[J] - BinCm.World.Brushes[I].Planes[J]).Length > 0.001 then
                Same := False;
        end;
      end;
      Check(Same, 'the .bcm world has the text version''s polygons and brushes');
    end;

    { the skinned model and its animation }
    BinModel := BinCache.Model('models/md5/test/blob.md5mesh');
    BinAnim := BinCache.Anim('models/md5/test/blob_walk.md5anim');
    Check(BinModel <> nil, 'load the .bmd5mesh');
    Check(BinAnim <> nil, 'load the .bmd5anim');
    if (BinModel <> nil) and (BinAnim <> nil) then
    begin
      CheckEquals(Length(TextModel.Joints), Length(BinModel.Joints), '.bmd5mesh joints');
      CheckEquals(TextModel.Meshes.Count, BinModel.Meshes.Count, '.bmd5mesh meshes');
      CheckEquals(TextModel.Meshes[0].Shader, BinModel.Meshes[0].Shader, '.bmd5mesh shader');
      MaxDiff := 0;
      for I := 0 to Min(High(TextModel.Joints), High(BinModel.Joints)) do
        MaxDiff := Max(MaxDiff, (TextModel.Joints[I].Position - BinModel.Joints[I].Position).Length);
      Check(MaxDiff < 0.01, Format('the joints'' bind positions, from the poses relative to the parents (off by %f)', [MaxDiff]));
      CheckEquals(TextAnim.NumFrames, BinAnim.NumFrames, '.bmd5anim frames');
      CheckEquals(TextAnim.FrameRate, BinAnim.FrameRate, '.bmd5anim frame rate');
      SetLength(PoseA, Length(TextModel.Joints));
      SetLength(PoseB, Length(BinModel.Joints));
      TextAnim.PoseAt(0.37, True, PoseA);
      BinAnim.PoseAt(0.37, True, PoseB);
      MaxDiff := 0;
      for I := 0 to Min(High(PoseA), High(PoseB)) do
        MaxDiff := Max(MaxDiff, (PoseA[I].Position - PoseB[I].Position).Length);
      Check(MaxDiff < 0.01, Format('the animation''s pose (off by %f)', [MaxDiff]));
      { skinned by the animation: the weights are bytes now }
      for I := 0 to Min(TextModel.Meshes.Count, BinModel.Meshes.Count) - 1 do
      begin
        CheckEquals(Length(TextModel.Meshes[I].Verts), Length(BinModel.Meshes[I].Verts), '.bmd5mesh vertexes');
        CheckEquals(Length(TextModel.Meshes[I].Tris), Length(BinModel.Meshes[I].Tris), '.bmd5mesh indexes');
        if Length(TextModel.Meshes[I].Verts) <> Length(BinModel.Meshes[I].Verts) then
          Continue;
        SetLength(PosA, Length(TextModel.Meshes[I].Verts));
        SetLength(PosB, Length(PosA));
        TextModel.SkinMesh(I, TextModel.Joints, PosA);
        BinModel.SkinMesh(I, BinModel.Joints, PosB);
        MaxDiff := 0;
        for J := 0 to High(PosA) do
          MaxDiff := Max(MaxDiff, (PosA[J] - PosB[J]).Length);
        Check(MaxDiff < 0.01, Format('mesh %d in the bind pose (off by %f)', [I, MaxDiff]));
        TextModel.SkinMesh(I, PoseA, PosA);
        BinModel.SkinMesh(I, PoseB, PosB);
        MaxDiff := 0;
        for J := 0 to High(PosA) do
          MaxDiff := Max(MaxDiff, (PosA[J] - PosB[J]).Length);
        Check(MaxDiff < 0.5, Format('mesh %d skinned by the animation (off by %f)', [I, MaxDiff]));
      end;
    end;

    { the static model }
    BinStatic := BinStatics.Model('models/mapobjects/test/barrel.lwo');
    Check(BinStatic <> nil, 'load the .blwo');
    if BinStatic <> nil then
    begin
      CheckEquals(TextStatic.Surfaces.Count, BinStatic.Surfaces.Count, '.blwo surfaces');
      CheckEquals(TextStatic.TriangleCount, BinStatic.TriangleCount, '.blwo triangles');
      Same := TextStatic.Surfaces.Count = BinStatic.Surfaces.Count;
      MaxDiff := 0;
      if Same then
        for I := 0 to TextStatic.Surfaces.Count - 1 do
        begin
          if (TextStatic.Surfaces[I].Material <> BinStatic.Surfaces[I].Material) or
             (Length(TextStatic.Surfaces[I].Positions) <> Length(BinStatic.Surfaces[I].Positions)) or
             (Length(TextStatic.Surfaces[I].Indexes) <> Length(BinStatic.Surfaces[I].Indexes)) or
             (TextStatic.Surfaces[I].HasColors <> BinStatic.Surfaces[I].HasColors) then
          begin
            Same := False;
            Break;
          end;
          for J := 0 to High(TextStatic.Surfaces[I].Positions) do
          begin
            MaxDiff := Max(MaxDiff, (TextStatic.Surfaces[I].Positions[J] - BinStatic.Surfaces[I].Positions[J]).Length);
            MaxDiff := Max(MaxDiff, (TextStatic.Surfaces[I].TexCoords[J] - BinStatic.Surfaces[I].TexCoords[J]).Length);
          end;
          for J := 0 to High(TextStatic.Surfaces[I].Indexes) do
            if TextStatic.Surfaces[I].Indexes[J] <> BinStatic.Surfaces[I].Indexes[J] then
              Same := False;
        end;
      Check(Same, 'the .blwo has the LWO''s surfaces, vertex colors and triangles (counter-clockwise again)');
      Check(MaxDiff < 0.01, Format('its vertexes and texture coordinates (off by up to %f)', [MaxDiff]));
    end;
  finally
    D3Fs := Saved;
    Fs.Free;
    for I := 0 to High(Files) do
      Files[I].Data.Free;
    BinStatics.Free;
    BinCache.Free;
    BinCm.Free;
    BinProc.Free;
    TextCm.Free;
    TextProc.Free;
    if Dir <> '' then
    begin
      DeleteFile(IncludeTrailingPathDelimiter(Dir) + '_common.resources');
      RemoveDir(Dir);
    end;
  end;
end;
