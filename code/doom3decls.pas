{ Doom 3 declarations (a small idDeclManager): materials (.mtr), entity
  definitions and model declarations (.def), skins (.skin) and sound shaders
  (.sndshd).

  All declaration files are scanned once and every declaration's body is
  indexed by type and name; bodies are parsed on demand. Like Doom 3, the
  first definition of a name wins. }
unit Doom3Decls;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleVectors, CastleLog,
  Doom3Lexer, Doom3Expressions;

type
  TD3DeclType = (dtMaterial, dtEntityDef, dtModel, dtSkin, dtSound, dtTable, dtAF, dtOther);

  TD3BlendMode = (bmOpaque, bmBlend, bmAdd, bmFilter);

  { A texture matrix keyword of a stage (idMaterial's MultiplyTextureMatrix). }
  TD3TexOpKind = (toScroll, toScale, toCenterScale, toShear, toRotate);
  TD3TexOp = record
    Kind: TD3TexOpKind;
    A, B: TD3Expr; { B is nil for rotate }
  end;
  TD3TexOps = array of TD3TexOp;

  { A plain stage after the first one: drawn as an overlay. }
  TD3ExtraStage = record
    Image: String;
    Blend: TD3BlendMode;
    ColorExpr: array [0..3] of TD3Expr; { nil means 1; owned by the material }
    TexOps: TD3TexOps;                  { owned by the material }
    AlphaTest: Single;
  end;

  { A parsed material (only what this port renders). Image fields hold image
    programs, e.g. "textures/a_d.tga" or
    "addnormals(textures/a_local.tga,heightmap(textures/a_bmp.tga,4))". }
  TD3Material = class
    Name: String;
    { Found in a .mtr file (otherwise an implicit material named like its
      image, as Doom 3 does). }
    Defined: Boolean;
    DiffuseImage, BumpImage, SpecularImage, EditorImage: String;
    { The first plain blended stage, used when there is no diffuse map
      (glows, decals, windows, skies...). }
    StageImage: String;
    StageBlend: TD3BlendMode;
    StageColor: TVector4;
    AlphaTest: Single;
    Translucent, TwoSided, NonSolid, NoShadows, PlayerClip, MonsterClip: Boolean;
    { A surface parameter that clears the solid contents (water, trigger,
      monsterclip, ikclip, aassolid... like Doom 3's clearSolid parms). }
    ClearsSolid: Boolean;
    { A stage needs something we don't render (cube maps, GUIs, mirrors,
      videos, fragment programs). }
    HasSpecialStage: Boolean;
    { Light shaders }
    IsAmbientLight, IsFogLight, IsBlendLight: Boolean;
    LightFalloffImage: String;
    GuiSurf: String;
    { Color registers (red, green, blue, alpha) of the first plain stage
      (for lights: the light's color); nil means 1. Owned. }
    StageColorExpr: array [0..3] of TD3Expr;
    { The first plain stage's "if" condition (nil: always drawn). Owned.
      Weapons' muzzle flashes show with "if ( time + parm4 ) * 8 < 1". }
    StageCondition: TD3Expr;
    { Texture matrix keywords of the diffuse stage and of the first plain
      stage (scroll, translate, scale, centerScale, shear, rotate). Owned. }
    DiffuseTexOps, StageTexOps: TD3TexOps;
    { A sky: the image name of a cameraCubeMap (_forward, _back...) or
      cubeMap (_px, _nx...) stage }
    SkyCubeMap: String;
    SkyCameraCubeMap: Boolean;
    { Plain stages after the first one (glows over lit walls...) }
    ExtraStages: array of TD3ExtraStage;
    { The first heat haze stage (program heatHaze*.vfp, reading
      _currentRender): the distortion normal map (fragmentMap 1, '' when
      there is no such stage), the mask (fragmentMap 2 of the WithMask
      programs, or ''), the scroll (vertexParm 0, nil means 0; owned)
      and the distortion magnitude (vertexParm 1). }
    HazeNormalMap, HazeMask: String;
    HazeScroll: array [0..1] of TD3Expr;
    HazeMagnitude: Single;
    { The first stage reflecting a cube map ("cubeMap ...", "texgen reflect"):
      the cube map name ('' when there is no such stage), its blend mode
      and color registers (nil means 1; owned). }
    ReflectCubeMap: String;
    ReflectBlend: TD3BlendMode;
    ReflectColorExpr: array [0..3] of TD3Expr;
    { "deform sprite", "deform tube"...: the deform kind, lowercase }
    Deform: String;
    { Only stages we can't draw (reflections, heat haze, mirrors, videos):
      drawn as faint glass so windows stay visible }
    function DrawAsGlass: Boolean;
    { Plain stages drawn over the base appearance: for lit materials the
      first plain stage and the extra ones, otherwise the extra ones. }
    function OverlayCount: Integer;
    destructor Destroy; override;
    { The stage color for an entity's parameters at a time. }
    function EvalStageColor(const Ctx: TD3ExprContext): TVector4;
    { Does the stage color change with time? }
    function StageColorAnimated: Boolean;
    { Do the texture matrix keywords change with time? }
    class function TexOpsAnimated(const Ops: TD3TexOps): Boolean; static;
    { The texture matrix of some keywords, for CGE's texture coordinates
      (v = 1 - Doom 3's t), as a 4x4 matrix for TextureTransformMatrix3D. }
    class function TexMatrix(const Ops: TD3TexOps; const Ctx: TD3ExprContext): TMatrix4; static;
    { True when the surface has nothing we can draw. }
    function IsInvisible: Boolean;
    { Collides with the player? }
    function IsSolid: Boolean;
    { Blocks the player in a collision model: solid or playerclip. }
    function BlocksPlayer: Boolean;
  end;

  { A "model" declaration from a .def file. }
  TD3ModelDecl = class
    Name: String;
    Mesh: String;
    Skin: String;
    Offset: TVector3;
    { Anim name (lowercase) -> md5anim file (the first one listed). }
    Anims: TStringList;
    { Frame commands: lines "animname=frame command arguments" (frame
      1-based), like "melee_attack1=11 melee melee_zombie_maint_Right". }
    FrameCommands: TStringList;
    constructor Create;
    destructor Destroy; override;
    function AnimFile(const AnimName: String): String;
  end;

  { A skin: material -> material replacements. }
  TD3Skin = class
    Name: String;
    { Lowercase source material (or "*") -> replacement }
    Mapping: TStringList;
    constructor Create;
    destructor Destroy; override;
    function Remap(const Material: String): String;
  end;

  { A sound shader: files and distances. }
  TD3SoundShader = class
    Name: String;
    Files: TStringList;
    MinDistance, MaxDistance, Volume: Single;
    Looping, Omni, Global: Boolean;
    constructor Create;
    destructor Destroy; override;
  end;

  TD3DeclManager = class
  strict private
    FBodies: array [TD3DeclType] of specialize TDictionary<String, String>;
    FMaterials: specialize TObjectDictionary<String, TD3Material>;
    FModels: specialize TObjectDictionary<String, TD3ModelDecl>;
    FSkins: specialize TObjectDictionary<String, TD3Skin>;
    FSounds: specialize TObjectDictionary<String, TD3SoundShader>;
    FEntityDefs: specialize TObjectDictionary<String, TStringList>;
    FTables: specialize TObjectDictionary<String, TD3Table>;
    FLoaded: Boolean;
    procedure IndexFile(const Path: String; const DefaultType: TD3DeclType);
    procedure ParseEntityDefInto(const Name: String; const Dict: TStringList; const Depth: Integer);
  public
    { A material from its body (without the outer braces); the caller owns it. }
    function ParseMaterial(const Name, Body: String): TD3Material;
    constructor Create;
    destructor Destroy; override;
    { Scan materials/, def/, skins/, sound/ in the virtual file system. }
    procedure LoadAll;
    procedure Clear;
    function DeclCount(const T: TD3DeclType): Integer;
    function HasDecl(const T: TD3DeclType; const Name: String): Boolean;
    { the text between a decl's braces; False if there's no such decl }
    function DeclBody(const T: TD3DeclType; const Name: String; out Body: String): Boolean;
    function DeclNames(const T: TD3DeclType): TStringList;

    { Material by name; never nil (an implicit one when not declared). }
    function Material(const Name: String): TD3Material;
    { Entity definition with "inherit" resolved: Names=Values, child keys
      override parents. nil when not declared. Owned by the manager. }
    function EntityDef(const Name: String): TStringList;
    function ModelDecl(const Name: String): TD3ModelDecl;
    function Skin(const Name: String): TD3Skin;
    function SoundShader(const Name: String): TD3SoundShader;
    { Table decl by name, nil when missing. }
    function Table(const Name: String): TD3Table;
    property Loaded: Boolean read FLoaded;
  end;

{ Parse an image program at the lexer's position into a normalized string
  without spaces, like "heightmap(textures/a_bmp.tga,4)". }
function ReadImageProgram(const Lexer: TDoom3Lexer): String;

var
  Decls: TD3DeclManager;

implementation

uses
  Math,
  Doom3Files;

const
  DeclTypeNames: array [TD3DeclType] of String =
    ('material', 'entitydef', 'model', 'skin', 'sound', 'table', 'articulatedfigure', '');

function ReadImageProgram(const Lexer: TDoom3Lexer): String;
var
  T: String;
begin
  T := Lexer.NextStr;
  if Lexer.Peek = '(' then
  begin
    Lexer.NextStr;
    Result := LowerCase(T) + '(';
    while not Lexer.AtEnd do
    begin
      Result := Result + ReadImageProgram(Lexer);
      if Lexer.Check(',') then
        Result := Result + ','
      else
      begin
        Lexer.Check(')');
        Break;
      end;
    end;
    Result := Result + ')';
  end else
    Result := StringReplace(T, '\', '/', [rfReplaceAll]);
end;

{ TD3Material }

function TD3Material.IsInvisible: Boolean;
begin
  Result := (DiffuseImage = '') and (StageImage = '');
end;

procedure FreeTexOps(var Ops: TD3TexOps);
var
  I: Integer;
begin
  for I := 0 to High(Ops) do
  begin
    FreeAndNil(Ops[I].A);
    FreeAndNil(Ops[I].B);
  end;
  Ops := nil;
end;

function TD3Material.DrawAsGlass: Boolean;
begin
  Result := IsInvisible and HasSpecialStage and (SkyCubeMap = '') and (GuiSurf = '');
end;

function TD3Material.OverlayCount: Integer;
begin
  Result := Length(ExtraStages);
  if (DiffuseImage <> '') and (StageImage <> '') then
    Inc(Result);
end;

destructor TD3Material.Destroy;
var
  I, J: Integer;
begin
  for I := 0 to High(ExtraStages) do
  begin
    for J := 0 to 3 do
      FreeAndNil(ExtraStages[I].ColorExpr[J]);
    FreeTexOps(ExtraStages[I].TexOps);
  end;
  for I := 0 to 3 do
  begin
    FreeAndNil(StageColorExpr[I]);
    FreeAndNil(ReflectColorExpr[I]);
  end;
  for I := 0 to 1 do
    FreeAndNil(HazeScroll[I]);
  FreeAndNil(StageCondition);
  FreeTexOps(DiffuseTexOps);
  FreeTexOps(StageTexOps);
  inherited Destroy;
end;

class function TD3Material.TexOpsAnimated(const Ops: TD3TexOps): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(Ops) do
    if ((Ops[I].A <> nil) and Ops[I].A.UsesTime) or ((Ops[I].B <> nil) and Ops[I].B.UsesTime) then
      Exit(True);
  Result := False;
end;

type
  { 2x3 affine texture matrix, rows (s, t) }
  TTexAffine = array [0..1, 0..2] of Single;

function AffineMultiply(const A, B: TTexAffine): TTexAffine;
var
  R, C: Integer;
begin
  { A * B, both as 3x3 with a (0, 0, 1) last row }
  for R := 0 to 1 do
  begin
    for C := 0 to 1 do
      Result[R, C] := A[R, 0] * B[0, C] + A[R, 1] * B[1, C];
    Result[R, 2] := A[R, 0] * B[0, 2] + A[R, 1] * B[1, 2] + A[R, 2];
  end;
end;

class function TD3Material.TexMatrix(const Ops: TD3TexOps; const Ctx: TD3ExprContext): TMatrix4;
var
  M, K, F: TTexAffine;
  I: Integer;
  A, B, C, S: Single;
begin
  { identity }
  M[0, 0] := 1; M[0, 1] := 0; M[0, 2] := 0;
  M[1, 0] := 0; M[1, 1] := 1; M[1, 2] := 0;
  for I := 0 to High(Ops) do
  begin
    A := 0;
    B := 0;
    if Ops[I].A <> nil then
      A := Ops[I].A.Eval(Ctx);
    if Ops[I].B <> nil then
      B := Ops[I].B.Eval(Ctx);
    case Ops[I].Kind of
      toScroll:
        begin
          K[0, 0] := 1; K[0, 1] := 0; K[0, 2] := A;
          K[1, 0] := 0; K[1, 1] := 1; K[1, 2] := B;
        end;
      toScale:
        begin
          K[0, 0] := A; K[0, 1] := 0; K[0, 2] := 0;
          K[1, 0] := 0; K[1, 1] := B; K[1, 2] := 0;
        end;
      toCenterScale:
        begin
          K[0, 0] := A; K[0, 1] := 0; K[0, 2] := 0.5 - 0.5 * A;
          K[1, 0] := 0; K[1, 1] := B; K[1, 2] := 0.5 - 0.5 * B;
        end;
      toShear:
        begin
          K[0, 0] := 1; K[0, 1] := A; K[0, 2] := -0.5 * A;
          K[1, 0] := B; K[1, 1] := 1; K[1, 2] := -0.5 * B;
        end;
      toRotate:
        begin
          { in cycles, around the texture center (sinTable / cosTable) }
          C := Cos(2 * Pi * A);
          S := Sin(2 * Pi * A);
          K[0, 0] := C; K[0, 1] := -S; K[0, 2] := 0.5 - 0.5 * C + 0.5 * S;
          K[1, 0] := S; K[1, 1] := C;  K[1, 2] := 0.5 - 0.5 * S - 0.5 * C;
        end;
    end;
    { like MultiplyTextureMatrix: the new keyword applies after the old ones }
    M := AffineMultiply(K, M);
  end;
  { CGE's v is 1 - t: F M F with F (s, v) = (s, 1 - v) }
  F[0, 0] := 1; F[0, 1] := 0;  F[0, 2] := 0;
  F[1, 0] := 0; F[1, 1] := -1; F[1, 2] := 1;
  M := AffineMultiply(F, AffineMultiply(M, F));
  Result := TMatrix4.Identity;
  Result.Data[0, 0] := M[0, 0]; Result.Data[1, 0] := M[0, 1]; Result.Data[3, 0] := M[0, 2];
  Result.Data[0, 1] := M[1, 0]; Result.Data[1, 1] := M[1, 1]; Result.Data[3, 1] := M[1, 2];
end;

function TD3Material.EvalStageColor(const Ctx: TD3ExprContext): TVector4;
var
  I: Integer;
begin
  for I := 0 to 3 do
    if StageColorExpr[I] <> nil then
      Result.Data[I] := StageColorExpr[I].Eval(Ctx)
    else
      Result.Data[I] := 1;
end;

function TD3Material.StageColorAnimated: Boolean;
var
  I: Integer;
begin
  for I := 0 to 3 do
    if (StageColorExpr[I] <> nil) and StageColorExpr[I].UsesTime then
      Exit(True);
  Result := False;
end;

function TD3Material.IsSolid: Boolean;
begin
  Result := not NonSolid;
end;

function TD3Material.BlocksPlayer: Boolean;
begin
  Result := PlayerClip or not (NonSolid or ClearsSolid);
end;

{ TD3ModelDecl }

constructor TD3ModelDecl.Create;
begin
  inherited Create;
  Anims := TStringList.Create;
  FrameCommands := TStringList.Create;
end;

destructor TD3ModelDecl.Destroy;
begin
  Anims.Free;
  FrameCommands.Free;
  inherited Destroy;
end;

function TD3ModelDecl.AnimFile(const AnimName: String): String;
begin
  Result := Anims.Values[LowerCase(AnimName)];
end;

{ TD3Skin }

constructor TD3Skin.Create;
begin
  inherited Create;
  Mapping := TStringList.Create;
end;

destructor TD3Skin.Destroy;
begin
  Mapping.Free;
  inherited Destroy;
end;

function TD3Skin.Remap(const Material: String): String;
var
  I: Integer;
begin
  I := Mapping.IndexOfName(LowerCase(Material));
  if I < 0 then
    I := Mapping.IndexOfName('*');
  if I >= 0 then
    Result := Mapping.ValueFromIndex[I]
  else
    Result := Material;
end;

{ TD3SoundShader }

constructor TD3SoundShader.Create;
begin
  inherited Create;
  Files := TStringList.Create;
  MinDistance := 1;
  MaxDistance := 10;
  Volume := 0;
end;

destructor TD3SoundShader.Destroy;
begin
  Files.Free;
  inherited Destroy;
end;

{ TD3DeclManager }

constructor TD3DeclManager.Create;
var
  T: TD3DeclType;
begin
  inherited Create;
  for T := Low(T) to High(T) do
    FBodies[T] := specialize TDictionary<String, String>.Create;
  FMaterials := specialize TObjectDictionary<String, TD3Material>.Create([doOwnsValues]);
  FModels := specialize TObjectDictionary<String, TD3ModelDecl>.Create([doOwnsValues]);
  FSkins := specialize TObjectDictionary<String, TD3Skin>.Create([doOwnsValues]);
  FSounds := specialize TObjectDictionary<String, TD3SoundShader>.Create([doOwnsValues]);
  FEntityDefs := specialize TObjectDictionary<String, TStringList>.Create([doOwnsValues]);
  FTables := specialize TObjectDictionary<String, TD3Table>.Create([doOwnsValues]);
end;

destructor TD3DeclManager.Destroy;
var
  T: TD3DeclType;
begin
  Clear;
  for T := Low(T) to High(T) do
    FBodies[T].Free;
  FMaterials.Free;
  FModels.Free;
  FSkins.Free;
  FSounds.Free;
  FEntityDefs.Free;
  FTables.Free;
  inherited Destroy;
end;

procedure TD3DeclManager.Clear;
var
  T: TD3DeclType;
begin
  for T := Low(T) to High(T) do
    FBodies[T].Clear;
  FMaterials.Clear;
  FModels.Clear;
  FSkins.Clear;
  FSounds.Clear;
  FEntityDefs.Clear;
  FTables.Clear;
  FLoaded := False;
end;

procedure TD3DeclManager.IndexFile(const Path: String; const DefaultType: TD3DeclType);
var
  Lexer: TDoom3Lexer;
  Tok, Name, Body: String;
  T, DeclType: TD3DeclType;
  Start: Integer;
begin
  Lexer := TDoom3Lexer.Create(D3Fs.ReadText(Path));
  try
    while Lexer.Next(Tok) do
    begin
      if Tok = '{' then
      begin
        { stray block, skip it }
        Lexer.SkipBracedSection;
        Continue;
      end;
      DeclType := DefaultType;
      Name := Tok;
      for T := Low(T) to Pred(dtOther) do
        if SameText(Tok, DeclTypeNames[T]) and (Lexer.Peek <> '{') then
        begin
          DeclType := T;
          Name := Lexer.NextStr;
          Break;
        end;
      if (DeclType = DefaultType) and (DefaultType = dtOther) and (Lexer.Peek <> '{') then
      begin
        { an unknown typed decl: particle, fx, export... followed by its name }
        DeclType := dtOther;
        Name := Lexer.NextStr;
      end;
      if not Lexer.Check('{') then
        Continue;
      Start := Lexer.Position;
      Lexer.SkipBracedSection;
      Body := Copy(Lexer.Text, Start, Lexer.Position - 1 - Start);
      Name := LowerCase(StringReplace(Name, '\', '/', [rfReplaceAll]));
      FBodies[DeclType].TryAdd(Name, Body);
    end;
  finally
    Lexer.Free;
  end;
end;

procedure TD3DeclManager.LoadAll;

  procedure IndexDir(const Dir, Ext: String; const DefaultType: TD3DeclType);
  var
    Files: TStringList;
    F: String;
  begin
    Files := D3Fs.FindFiles(Dir, Ext);
    try
      for F in Files do
        IndexFile(F, DefaultType);
    finally
      Files.Free;
    end;
  end;

begin
  Clear;
  IndexDir('materials/', '.mtr', dtMaterial);
  IndexDir('def/', '.def', dtOther);
  IndexDir('skins/', '.skin', dtSkin);
  IndexDir('sound/', '.sndshd', dtSound);
  IndexDir('af/', '.af', dtAF);
  FLoaded := True;
  WritelnLog('Doom3Decls', 'Indexed %d materials, %d entityDefs, %d models, %d skins, %d sound shaders, %d articulated figures',
    [FBodies[dtMaterial].Count, FBodies[dtEntityDef].Count, FBodies[dtModel].Count,
     FBodies[dtSkin].Count, FBodies[dtSound].Count, FBodies[dtAF].Count]);
end;

function TD3DeclManager.DeclCount(const T: TD3DeclType): Integer;
begin
  Result := FBodies[T].Count;
end;

function TD3DeclManager.DeclBody(const T: TD3DeclType; const Name: String; out Body: String): Boolean;
begin
  Result := FBodies[T].TryGetValue(LowerCase(Name), Body);
end;

function TD3DeclManager.HasDecl(const T: TD3DeclType; const Name: String): Boolean;
begin
  Result := FBodies[T].ContainsKey(LowerCase(Name));
end;

function TD3DeclManager.DeclNames(const T: TD3DeclType): TStringList;
var
  K: String;
begin
  Result := TStringList.Create;
  for K in FBodies[T].Keys do
    Result.Add(K);
  Result.Sort;
end;

function ParseBlend(const Lexer: TDoom3Lexer; out Special: String): TD3BlendMode;
var
  Src, Dst: String;
begin
  Special := '';
  Src := LowerCase(Lexer.NextStr);
  Dst := '';
  if Lexer.Check(',') then
    Dst := LowerCase(Lexer.NextStr);
  if (Src = 'diffusemap') or (Src = 'bumpmap') or (Src = 'specularmap') then
  begin
    Special := Src;
    Exit(bmOpaque);
  end;
  if Src = 'add' then Exit(bmAdd);
  if Src = 'blend' then Exit(bmBlend);
  if (Src = 'filter') or (Src = 'modulate') then Exit(bmFilter);
  if Src = 'none' then
  begin
    Special := 'none';
    Exit(bmOpaque);
  end;
  if (Src = 'gl_one') and (Dst = 'gl_zero') then Exit(bmOpaque);
  if (Src = 'gl_one') and (Dst = 'gl_one') then Exit(bmAdd);
  if (Src = 'gl_src_alpha') and (Dst = 'gl_one') then Exit(bmAdd);
  if (Src = 'gl_src_alpha') and (Dst = 'gl_one_minus_src_alpha') then Exit(bmBlend);
  if ((Src = 'gl_dst_color') and (Dst = 'gl_zero')) or
     ((Src = 'gl_zero') and (Dst = 'gl_src_color')) then Exit(bmFilter);
  if Dst = 'gl_one' then Exit(bmAdd);
  Result := bmBlend;
end;

{ Split "a, b, c" at top level commas (not inside brackets / parentheses). }
function SplitTopLevel(const S: String): TStringArray;
var
  I, Depth, Start: Integer;
begin
  Result := nil;
  Depth := 0;
  Start := 1;
  for I := 1 to Length(S) do
  begin
    if S[I] in ['(', '['] then
      Inc(Depth)
    else
    if S[I] in [')', ']'] then
      Dec(Depth)
    else
    if (S[I] = ',') and (Depth = 0) then
    begin
      Result := Concat(Result, [Trim(Copy(S, Start, I - Start))]);
      Start := I + 1;
    end;
  end;
  Result := Concat(Result, [Trim(Copy(S, Start, MaxInt))]);
end;

{ Image options that may precede the image of a stage's fragmentMap. }
function IsFragmentMapOption(const S: String): Boolean;
begin
  Result := (S = 'cubemap') or (S = 'cameracubemap') or (S = 'nearest') or
    (S = 'linear') or (S = 'clamp') or (S = 'noclamp') or (S = 'zeroclamp') or
    (S = 'alphazeroclamp') or (S = 'forcehighquality') or (S = 'highquality') or
    (S = 'uncompressed') or (S = 'nopicmip');
end;

function TD3DeclManager.ParseMaterial(const Name, Body: String): TD3Material;
var
  Lexer: TDoom3Lexer;
  Tok, L, Special, StageMap, Line: String;
  StageBlendMode: TD3BlendMode;
  StageSpecial, HasBlend, HasStageColor, StageSkyTexGen: Boolean;
  StageCubeMap: String;
  StageCameraCubeMap, StageReflectTexGen: Boolean;
  StageProgram: String;
  StageFragmentMaps: array [0..2] of String;
  StageVertexParms: array [0..1] of String;
  StageAlphaTest: Single;
  Regs: array [0..3] of TD3Expr;
  StageCond: TD3Expr;
  Parts: TStringArray;
  I: Integer;
  StageOps: TD3TexOps;

  procedure AddOp(const Kind: TD3TexOpKind; const Text: String; const TwoArgs: Boolean);
  var
    Args: TStringArray;
    Op: TD3TexOp;
  begin
    Args := SplitTopLevel(Text);
    Op.Kind := Kind;
    Op.A := nil;
    Op.B := nil;
    if Length(Args) > 0 then
      Op.A := ParseD3ExpressionString(Args[0], @Table);
    if TwoArgs and (Length(Args) > 1) then
      Op.B := ParseD3ExpressionString(Args[1], @Table);
    if (Op.A = nil) or (TwoArgs and (Op.B = nil)) then
    begin
      FreeAndNil(Op.A);
      FreeAndNil(Op.B);
      Exit;
    end;
    StageOps := Concat(StageOps, [Op]);
  end;

  procedure SetReg(const Index: Integer; const Text: String);
  begin
    FreeAndNil(Regs[Index]);
    Regs[Index] := ParseD3ExpressionString(Text, @Table);
  end;

begin
  HasStageColor := False;
  StageCond := nil;
  for I := 0 to 3 do
    Regs[I] := nil;
  Result := TD3Material.Create;
  Result.Name := Name;
  Result.Defined := True;
  Result.AlphaTest := -1;
  Result.StageColor := Vector4(1, 1, 1, 1);
  Lexer := TDoom3Lexer.Create(Body);
  try
    while Lexer.Next(Tok) do
    begin
      L := LowerCase(Tok);
      if Tok = '{' then
      begin
        { a stage }
        StageMap := '';
        StageBlendMode := bmOpaque;
        Special := '';
        StageSpecial := False;
        StageCubeMap := '';
        StageCameraCubeMap := False;
        StageSkyTexGen := False;
        StageReflectTexGen := False;
        StageProgram := '';
        for I := 0 to High(StageFragmentMaps) do
          StageFragmentMaps[I] := '';
        for I := 0 to High(StageVertexParms) do
          StageVertexParms[I] := '';
        HasBlend := False;
        StageAlphaTest := -1;
        FreeAndNil(StageCond);
        for I := 0 to 3 do
          FreeAndNil(Regs[I]);
        FreeTexOps(StageOps);
        while Lexer.Next(Tok) and (Tok <> '}') do
        begin
          L := LowerCase(Tok);
          if (L = 'scroll') or (L = 'translate') then
            AddOp(toScroll, Lexer.RestOfLine, True)
          else
          if L = 'scale' then
            AddOp(toScale, Lexer.RestOfLine, True)
          else
          if L = 'centerscale' then
            AddOp(toCenterScale, Lexer.RestOfLine, True)
          else
          if L = 'shear' then
            AddOp(toShear, Lexer.RestOfLine, True)
          else
          if L = 'rotate' then
            AddOp(toRotate, Lexer.RestOfLine, False)
          else
          if (L = 'cameracubemap') or (L = 'cubemap') then
          begin
            StageCubeMap := Lexer.NextStr;
            StageCameraCubeMap := L = 'cameracubemap';
            StageSpecial := True;
          end else
          if L = 'texgen' then
          begin
            { skybox / wobblesky: a sky; reflect, screen...: not one }
            L := LowerCase(Lexer.NextStr);
            if (L = 'skybox') or (L = 'wobblesky') then
              StageSkyTexGen := True;
            if L = 'reflect' then
              StageReflectTexGen := True;
            Lexer.SkipLine;
            StageSpecial := True;
          end else
          if (L = 'program') or (L = 'fragmentprogram') or (L = 'vertexprogram') then
          begin
            { the vertex and fragment programs have the same name }
            StageProgram := LowerCase(Lexer.NextStr);
            StageSpecial := True;
          end else
          if L = 'vertexparm' then
          begin
            I := Lexer.ReadInt;
            Line := Lexer.RestOfLine;
            if (I >= 0) and (I <= High(StageVertexParms)) then
              StageVertexParms[I] := Line;
          end else
          if L = 'fragmentmap' then
          begin
            I := Lexer.ReadInt;
            { options before the image }
            while IsFragmentMapOption(LowerCase(Lexer.Peek)) do
              Lexer.NextStr;
            Line := ReadImageProgram(Lexer);
            if (I >= 0) and (I <= High(StageFragmentMaps)) then
              StageFragmentMaps[I] := Line;
          end else
          if (L = 'red') or (L = 'green') or (L = 'blue') or (L = 'alpha') then
          begin
            Line := Lexer.RestOfLine;
            if L = 'red' then SetReg(0, Line) else
            if L = 'green' then SetReg(1, Line) else
            if L = 'blue' then SetReg(2, Line) else
              SetReg(3, Line);
          end else
          if (L = 'rgb') or (L = 'rgba') then
          begin
            Line := Lexer.RestOfLine;
            for I := 0 to 2 do
              SetReg(I, Line);
            if L = 'rgba' then
              SetReg(3, Line);
          end else
          if L = 'color' then
          begin
            Parts := SplitTopLevel(Lexer.RestOfLine);
            for I := 0 to Min(3, High(Parts)) do
              SetReg(I, Parts[I]);
          end else
          if L = 'colored' then
          begin
            { the entity's shader parameters: a light's _color }
            for I := 0 to 3 do
              SetReg(I, 'parm' + IntToStr(I));
          end else
          if L = 'blend' then
          begin
            StageBlendMode := ParseBlend(Lexer, Special);
            HasBlend := True;
          end else
          if L = 'map' then
            StageMap := ReadImageProgram(Lexer)
          else
          if L = 'alphatest' then
            StageAlphaTest := Lexer.ReadFloat
          else
          if L = 'if' then
          begin
            FreeAndNil(StageCond);
            StageCond := ParseD3ExpressionString(Lexer.RestOfLine, @Table);
          end else
          if (L = 'cubemap') or (L = 'cameracubemap') or (L = 'videomap') or
             (L = 'soundmap') or (L = 'remoterendermap') or (L = 'mirrorrendermap') or
             (L = 'texgen') then
            StageSpecial := True
          else
          if Tok = '{' then
            Lexer.SkipBracedSection;
        end;
        { heat haze: the first stage with a heatHaze* program }
        if (Copy(StageProgram, 1, Length('heathaze')) = 'heathaze') and
           (Result.HazeNormalMap = '') and (StageFragmentMaps[1] <> '') then
        begin
          Result.HazeNormalMap := StageFragmentMaps[1];
          if Pos('withmask', StageProgram) > 0 then
            Result.HazeMask := StageFragmentMaps[2];
          Parts := SplitTopLevel(StageVertexParms[0]);
          for I := 0 to Min(1, High(Parts)) do
            Result.HazeScroll[I] := ParseD3ExpressionString(Parts[I], @Table);
          Result.HazeMagnitude := D3StrToFloat(Trim(StageVertexParms[1]), 1);
        end;
        { reflection: the first cube map stage with "texgen reflect" }
        if (StageCubeMap <> '') and StageReflectTexGen and (Result.ReflectCubeMap = '') then
        begin
          Result.ReflectCubeMap := StageCubeMap;
          if HasBlend then
            Result.ReflectBlend := StageBlendMode
          else
            Result.ReflectBlend := bmOpaque;
          for I := 0 to 3 do
          begin
            Result.ReflectColorExpr[I] := Regs[I];
            Regs[I] := nil;
          end;
        end;
        { a cube map is a sky only with "texgen skybox" (glass reflects one) }
        if (StageCubeMap <> '') and (StageSkyTexGen or StageCameraCubeMap) and
           (Result.SkyCubeMap = '') then
        begin
          Result.SkyCubeMap := StageCubeMap;
          Result.SkyCameraCubeMap := StageCameraCubeMap;
        end;
        if (Special <> 'diffusemap') and (Special <> 'bumpmap') and
           (Special <> 'specularmap') and (Special <> 'none') and not StageSpecial and
           HasStageColor and (StageMap <> '') and (Copy(StageMap, 1, 1) <> '_') and
           (StageMap <> Result.StageImage) then
        begin
          SetLength(Result.ExtraStages, Length(Result.ExtraStages) + 1);
          Result.ExtraStages[High(Result.ExtraStages)].Image := StageMap;
          if HasBlend then
            Result.ExtraStages[High(Result.ExtraStages)].Blend := StageBlendMode
          else
            Result.ExtraStages[High(Result.ExtraStages)].Blend := bmOpaque;
          Result.ExtraStages[High(Result.ExtraStages)].AlphaTest := StageAlphaTest;
          for I := 0 to 3 do
          begin
            Result.ExtraStages[High(Result.ExtraStages)].ColorExpr[I] := Regs[I];
            Regs[I] := nil;
          end;
          Result.ExtraStages[High(Result.ExtraStages)].TexOps := StageOps;
          StageOps := nil;
        end;
        { keep the color registers of the first plain stage }
        if (Special <> 'diffusemap') and (Special <> 'bumpmap') and
           (Special <> 'specularmap') and not StageSpecial and not HasStageColor then
        begin
          HasStageColor := True;
          for I := 0 to 3 do
          begin
            Result.StageColorExpr[I] := Regs[I];
            Regs[I] := nil;
          end;
          Result.StageTexOps := StageOps;
          StageOps := nil;
        end;
        if (Special = 'diffusemap') and (Result.DiffuseTexOps = nil) then
        begin
          Result.DiffuseTexOps := StageOps;
          StageOps := nil;
        end;
        FreeTexOps(StageOps);
        if StageSpecial then
        begin
          Result.HasSpecialStage := True;
          Continue;
        end;
        if Special = 'diffusemap' then
        begin
          if Result.DiffuseImage = '' then
            Result.DiffuseImage := StageMap;
          if StageAlphaTest >= 0 then
            Result.AlphaTest := StageAlphaTest;
        end else
        if Special = 'bumpmap' then
        begin
          if Result.BumpImage = '' then
            Result.BumpImage := StageMap;
        end else
        if Special = 'specularmap' then
        begin
          if Result.SpecularImage = '' then
            Result.SpecularImage := StageMap;
        end else
        if (Special <> 'none') and (StageMap <> '') and (Result.StageImage = '') and
           (Copy(StageMap, 1, 1) <> '_') then
        begin
          Result.StageImage := StageMap;
          Result.StageBlend := StageBlendMode;
          Result.StageCondition := StageCond;
          StageCond := nil;
          if not HasBlend then
            Result.StageBlend := bmOpaque;
          if StageAlphaTest >= 0 then
            Result.AlphaTest := StageAlphaTest;
        end;
      end else
      if L = 'diffusemap' then
        Result.DiffuseImage := ReadImageProgram(Lexer)
      else
      if L = 'bumpmap' then
        Result.BumpImage := ReadImageProgram(Lexer)
      else
      if L = 'specularmap' then
        Result.SpecularImage := ReadImageProgram(Lexer)
      else
      if L = 'qer_editorimage' then
        Result.EditorImage := ReadImageProgram(Lexer)
      else
      if L = 'lightfalloffimage' then
        Result.LightFalloffImage := ReadImageProgram(Lexer)
      else
      if L = 'translucent' then
        Result.Translucent := True
      else
      if L = 'twosided' then
        Result.TwoSided := True
      else
      if L = 'nonsolid' then
        Result.NonSolid := True
      else
      if L = 'noshadows' then
        Result.NoShadows := True
      else
      if L = 'playerclip' then
      begin
        Result.PlayerClip := True;
        Result.ClearsSolid := True;
      end else
      if L = 'monsterclip' then
      begin
        Result.MonsterClip := True;
        Result.ClearsSolid := True;
      end else
      if (L = 'water') or (L = 'moveableclip') or (L = 'ikclip') or (L = 'blood') or
         (L = 'trigger') or (L = 'aassolid') or (L = 'aasobstacle') or
         (L = 'flashlight_trigger') or (L = 'corpse') then
        Result.ClearsSolid := True
      else
      if L = 'ambientlight' then
        Result.IsAmbientLight := True
      else
      if L = 'foglight' then
        Result.IsFogLight := True
      else
      if L = 'blendlight' then
        Result.IsBlendLight := True
      else
      if L = 'guisurf' then
        Result.GuiSurf := Lexer.NextStr
      else
      if L = 'deform' then
      begin
        Result.Deform := LowerCase(Lexer.NextStr);
        Lexer.SkipLine;
      end else
      if (L = 'description') or (L = 'renderbump') or (L = 'decalinfo') or
         (L = 'sort') or (L = 'spectrum') or (L = 'polygonoffset') then
        Lexer.SkipLine;
    end;
  finally
    Lexer.Free;
    for I := 0 to 3 do
      FreeAndNil(Regs[I]);
    FreeAndNil(StageCond);
    FreeTexOps(StageOps);
  end;
end;

function TD3DeclManager.Table(const Name: String): TD3Table;
var
  Key, Body: String;
begin
  Key := LowerCase(Name);
  if FTables.TryGetValue(Key, Result) then
    Exit;
  Result := nil;
  if FBodies[dtTable].TryGetValue(Key, Body) then
  begin
    Result := TD3Table.Create;
    Result.Name := Key;
    Result.Parse(Body);
  end;
  FTables.Add(Key, Result);
end;

function TD3DeclManager.Material(const Name: String): TD3Material;
var
  Key, Body: String;
begin
  Key := LowerCase(StringReplace(Name, '\', '/', [rfReplaceAll]));
  if FMaterials.TryGetValue(Key, Result) then
    Exit;
  if FBodies[dtMaterial].TryGetValue(Key, Body) then
    Result := ParseMaterial(Key, Body)
  else
  begin
    { Doom 3 makes an implicit material: the image with the same name. }
    Result := TD3Material.Create;
    Result.Name := Key;
    Result.AlphaTest := -1;
    Result.StageColor := Vector4(1, 1, 1, 1);
    { The generic entity GUI screens ("guiSurf entity" .. "entity3" in
      Doom 3's materials/common.mtr), when the data doesn't define them
      (the demo): show the entity's gui / gui2 / gui3 instead of a missing
      image. }
    if Key = 'textures/common/entitygui' then
      Result.GuiSurf := 'entity'
    else
    if (Key = 'textures/common/entitygui2') or (Key = 'textures/common/entitygui3') then
      Result.GuiSurf := 'entity' + Copy(Key, Length(Key), 1)
    else
      Result.DiffuseImage := Key;
  end;
  FMaterials.Add(Key, Result);
end;

procedure TD3DeclManager.ParseEntityDefInto(const Name: String; const Dict: TStringList;
  const Depth: Integer);
var
  Body, Key, Value: String;
  Lexer: TDoom3Lexer;
  Pairs: TStringList;
  I: Integer;
begin
  if (Depth > 16) or not FBodies[dtEntityDef].TryGetValue(LowerCase(Name), Body) then
    Exit;
  Pairs := TStringList.Create;
  Lexer := TDoom3Lexer.Create(Body);
  try
    while Lexer.Next(Key) do
    begin
      if Key = '{' then
      begin
        Lexer.SkipBracedSection;
        Continue;
      end;
      Value := Lexer.NextStr;
      Pairs.Add(LowerCase(Key) + '=' + Value);
    end;
    { parents first, so our keys override theirs }
    if Pairs.IndexOfName('inherit') >= 0 then
      ParseEntityDefInto(Pairs.Values['inherit'], Dict, Depth + 1);
    for I := 0 to Pairs.Count - 1 do
      Dict.Values[Pairs.Names[I]] := Pairs.ValueFromIndex[I];
  finally
    Lexer.Free;
    Pairs.Free;
  end;
end;

function TD3DeclManager.EntityDef(const Name: String): TStringList;
var
  Key: String;
begin
  Key := LowerCase(Name);
  if FEntityDefs.TryGetValue(Key, Result) then
    Exit;
  if not FBodies[dtEntityDef].ContainsKey(Key) then
    Exit(nil);
  Result := TStringList.Create;
  ParseEntityDefInto(Key, Result, 0);
  FEntityDefs.Add(Key, Result);
end;

function TD3DeclManager.ModelDecl(const Name: String): TD3ModelDecl;
var
  Command: String;
  Key, Body, Tok, L, AnimName: String;
  Lexer: TDoom3Lexer;
  Parent: TD3ModelDecl;
  V: TVector3;
begin
  Key := LowerCase(Name);
  if FModels.TryGetValue(Key, Result) then
    Exit;
  if not FBodies[dtModel].TryGetValue(Key, Body) then
    Exit(nil);
  Result := TD3ModelDecl.Create;
  Result.Name := Key;
  FModels.Add(Key, Result);
  Lexer := TDoom3Lexer.Create(Body);
  try
    while Lexer.Next(Tok) do
    begin
      L := LowerCase(Tok);
      if L = 'inherit' then
      begin
        Parent := ModelDecl(Lexer.NextStr);
        if (Parent <> nil) and (Parent <> Result) then
        begin
          Result.Mesh := Parent.Mesh;
          Result.Skin := Parent.Skin;
          Result.Offset := Parent.Offset;
          Result.Anims.Assign(Parent.Anims);
          Result.FrameCommands.Assign(Parent.FrameCommands);
        end;
      end else
      if L = 'mesh' then
        Result.Mesh := Lexer.NextStr
      else
      if L = 'skin' then
        Result.Skin := Lexer.NextStr
      else
      if L = 'offset' then
      begin
        Lexer.ReadVector(@V.X, 3);
        Result.Offset := V;
      end else
      if L = 'channel' then
      begin
        Lexer.NextStr;
        if Lexer.Check('(') then
          while not Lexer.AtEnd and (Lexer.NextStr <> ')') do ;
      end else
      if L = 'anim' then
      begin
        AnimName := LowerCase(Lexer.NextStr);
        Result.Anims.Values[AnimName] := Lexer.NextStr;
        while Lexer.Check(',') do
          Lexer.NextStr;
        if Lexer.Check('{') then
        begin
          { frame <n> <command> <arguments...>, up to the next frame or the closing brace }
          Command := '';
          while not Lexer.AtEnd do
          begin
            Tok := Lexer.NextStr;
            if (Tok = '}') or SameText(Tok, 'frame') then
            begin
              if Command <> '' then
                Result.FrameCommands.Add(AnimName + '=' + Command);
              Command := '';
              if Tok = '}' then
                Break;
              Command := Lexer.NextStr;
            end else
            if Command <> '' then
              Command := Command + ' ' + Tok;
          end;
        end;
      end else
      if Tok = '{' then
        Lexer.SkipBracedSection;
    end;
  finally
    Lexer.Free;
  end;
end;

function TD3DeclManager.Skin(const Name: String): TD3Skin;
var
  Key, Body, Tok, Value: String;
  Lexer: TDoom3Lexer;
begin
  Key := LowerCase(Name);
  if FSkins.TryGetValue(Key, Result) then
    Exit;
  if not FBodies[dtSkin].TryGetValue(Key, Body) then
    Exit(nil);
  Result := TD3Skin.Create;
  Result.Name := Key;
  FSkins.Add(Key, Result);
  Lexer := TDoom3Lexer.Create(Body);
  try
    while Lexer.Next(Tok) do
    begin
      Value := Lexer.NextStr;
      if SameText(Tok, 'model') then
        Continue;
      Result.Mapping.Add(LowerCase(Tok) + '=' + Value);
    end;
  finally
    Lexer.Free;
  end;
end;

function TD3DeclManager.SoundShader(const Name: String): TD3SoundShader;
var
  Key, Body, Tok, L: String;
  Lexer: TDoom3Lexer;
begin
  Key := LowerCase(Name);
  if FSounds.TryGetValue(Key, Result) then
    Exit;
  Result := nil;
  if not FBodies[dtSound].TryGetValue(Key, Body) then
  begin
    { a direct file name works as a sound shader too }
    if D3Fs.FileExists(Key) then
    begin
      Result := TD3SoundShader.Create;
      Result.Name := Key;
      Result.Files.Add(Key);
      FSounds.Add(Key, Result);
    end;
    Exit;
  end;
  Result := TD3SoundShader.Create;
  Result.Name := Key;
  FSounds.Add(Key, Result);
  Lexer := TDoom3Lexer.Create(Body);
  try
    while Lexer.Next(Tok) do
    begin
      L := LowerCase(Tok);
      if L = 'mindistance' then
        Result.MinDistance := Lexer.ReadFloat
      else
      if L = 'maxdistance' then
        Result.MaxDistance := Lexer.ReadFloat
      else
      if L = 'volume' then
        Result.Volume := Lexer.ReadFloat
      else
      if L = 'looping' then
        Result.Looping := True
      else
      if L = 'omnidirectional' then
        Result.Omni := True
      else
      if L = 'global' then
        Result.Global := True
      else
      if (Pos('/', Tok) > 0) and
         ((ExtractFileExt(L) = '.wav') or (ExtractFileExt(L) = '.ogg')) then
        Result.Files.Add(Tok)
      else
      if Tok = '{' then
        Lexer.SkipBracedSection;
    end;
  finally
    Lexer.Free;
  end;
end;

initialization
  Decls := TD3DeclManager.Create;
finalization
  FreeAndNil(Decls);
end.
