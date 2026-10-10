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
  TD3DeclType = (dtMaterial, dtEntityDef, dtModel, dtSkin, dtSound, dtTable, dtOther);

  TD3BlendMode = (bmOpaque, bmBlend, bmAdd, bmFilter);

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
    destructor Destroy; override;
    { The stage color for an entity's parameters at a time. }
    function EvalStageColor(const Ctx: TD3ExprContext): TVector4;
    { Does the stage color change with time? }
    function StageColorAnimated: Boolean;
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
    function ParseMaterial(const Name, Body: String): TD3Material;
    procedure ParseEntityDefInto(const Name: String; const Dict: TStringList; const Depth: Integer);
  public
    constructor Create;
    destructor Destroy; override;
    { Scan materials/, def/, skins/, sound/ in the virtual file system. }
    procedure LoadAll;
    procedure Clear;
    function DeclCount(const T: TD3DeclType): Integer;
    function HasDecl(const T: TD3DeclType; const Name: String): Boolean;
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
    ('material', 'entitydef', 'model', 'skin', 'sound', 'table', '');

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

destructor TD3Material.Destroy;
var
  I: Integer;
begin
  for I := 0 to 3 do
    FreeAndNil(StageColorExpr[I]);
  inherited Destroy;
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
end;

destructor TD3ModelDecl.Destroy;
begin
  Anims.Free;
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
  FLoaded := True;
  WritelnLog('Doom3Decls', 'Indexed %d materials, %d entityDefs, %d models, %d skins, %d sound shaders',
    [FBodies[dtMaterial].Count, FBodies[dtEntityDef].Count, FBodies[dtModel].Count,
     FBodies[dtSkin].Count, FBodies[dtSound].Count]);
end;

function TD3DeclManager.DeclCount(const T: TD3DeclType): Integer;
begin
  Result := FBodies[T].Count;
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

function TD3DeclManager.ParseMaterial(const Name, Body: String): TD3Material;
var
  Lexer: TDoom3Lexer;
  Tok, L, Special, StageMap, Line: String;
  StageBlendMode: TD3BlendMode;
  StageSpecial, HasBlend, HasStageColor: Boolean;
  StageAlphaTest: Single;
  Regs: array [0..3] of TD3Expr;
  Parts: TStringArray;
  I: Integer;

  procedure SetReg(const Index: Integer; const Text: String);
  begin
    FreeAndNil(Regs[Index]);
    Regs[Index] := ParseD3ExpressionString(Text, @Table);
  end;

begin
  HasStageColor := False;
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
        HasBlend := False;
        StageAlphaTest := -1;
        for I := 0 to 3 do
          FreeAndNil(Regs[I]);
        while Lexer.Next(Tok) and (Tok <> '}') do
        begin
          L := LowerCase(Tok);
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
          if (L = 'cubemap') or (L = 'cameracubemap') or (L = 'videomap') or
             (L = 'soundmap') or (L = 'remoterendermap') or (L = 'mirrorrendermap') or
             (L = 'fragmentprogram') or (L = 'program') or (L = 'texgen') then
            StageSpecial := True
          else
          if Tok = '{' then
            Lexer.SkipBracedSection;
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
        end;
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
      if (L = 'description') or (L = 'renderbump') or (L = 'decalinfo') or
         (L = 'deform') or (L = 'sort') or (L = 'spectrum') or (L = 'polygonoffset') then
        Lexer.SkipLine;
    end;
  finally
    Lexer.Free;
    for I := 0 to 3 do
      FreeAndNil(Regs[I]);
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
          Lexer.SkipBracedSection;
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
