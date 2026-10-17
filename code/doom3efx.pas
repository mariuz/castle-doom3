// Doom 3's reverb files, efxs/<map>.efx: EAX reverb settings named by a
// portal area number, a location name or "default", read like dhewm3's
// idEFXFile, and the choice of one for the listener like dhewm3's
// idSoundWorldLocal::MixLoop (the area number, then the location name,
// then "default").
//
// The file:
//   Version 1
//   reverb "default" {
//     "environment" 0
//     "environment size" 7.5
//     "room" -1000
//     ...
//   }
// Gains are in millibels (mB): gain = 10 ^ (mB / 2000), clamped to the EFX
// range. Each effect becomes a TCastleSoundReverb (Enabled), to Assign to
// SoundEngine.Reverb.
unit Doom3Efx;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Generics.Collections,
  CastleSoundEngine,
  Doom3Lexer;

type
  TD3ReverbEffect = class
  public
    { As in the file ("default", an area number, a location name). }
    Name: String;
    { The settings, Enabled. }
    Reverb: TCastleSoundReverb;
    constructor Create;
    destructor Destroy; override;
  end;

  TD3ReverbEffectList = specialize TObjectList<TD3ReverbEffect>;

  TD3EfxFile = class
  strict private
    FEffects: TD3ReverbEffectList;
    FUnknownKeys: Integer;
    function ReadEffect(const L: TDoom3Lexer): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    { Parse an .efx file. False (and no effects) when it doesn't start
      with "Version 1". }
    function LoadFromText(const Text: String): Boolean;
    { Load a file from the Doom 3 file system, False when missing or bad. }
    function LoadFromVfs(const Path: String): Boolean;
    { The effect named Name (case-insensitive), nil when none. }
    function Find(const Name: String): TD3ReverbEffect;
    { The effect for a listener in portal area Area (-1 = outside) at
      location Location ('' = none): named by the area number, else by the
      location, else "default"; nil when none of them is in the file. }
    function Select(const Area: Integer; const Location: String): TD3ReverbEffect;
    property Effects: TD3ReverbEffectList read FEffects;
    { Keys in reverb blocks that aren't EAX reverb parameters (skipped). }
    property UnknownKeys: Integer read FUnknownKeys;
  end;

{ "efxs/<map file name>.efx", like dhewm3: "game/demo_mars_city1" ->
  "efxs/demo_mars_city1.efx". }
function EfxPathForMap(const MapName: String): String;

{ Millibels to a linear gain, clamped to Min..Max. }
function MillibelsToGain(const Millibels, AMin, AMax: Single): Single;

implementation

uses
  Math,
  CastleVectors, CastleLog,
  Doom3Files;

function EfxPathForMap(const MapName: String): String;
var
  S: String;
begin
  S := StringReplace(MapName, '\', '/', [rfReplaceAll]);
  S := ExtractFileName(StringReplace(S, '/', PathDelim, [rfReplaceAll]));
  S := ChangeFileExt(S, '');
  Result := 'efxs/' + LowerCase(S) + '.efx';
end;

function MillibelsToGain(const Millibels, AMin, AMax: Single): Single;
begin
  Result := EnsureRange(Power(10, Millibels / 2000), AMin, AMax);
end;

{ TD3ReverbEffect }

constructor TD3ReverbEffect.Create;
begin
  inherited Create;
  Reverb := TCastleSoundReverb.Create;
  Reverb.Enabled := True;
end;

destructor TD3ReverbEffect.Destroy;
begin
  Reverb.Free;
  inherited Destroy;
end;

{ TD3EfxFile }

constructor TD3EfxFile.Create;
begin
  inherited Create;
  FEffects := TD3ReverbEffectList.Create(True);
end;

destructor TD3EfxFile.Destroy;
begin
  FEffects.Free;
  inherited Destroy;
end;

function TD3EfxFile.ReadEffect(const L: TDoom3Lexer): Boolean;
var
  E: TD3ReverbEffect;
  R: TCastleSoundReverb;
  Key, S: String;
  KeyQuoted: Boolean;
  Size: Single;
  Flags: Integer;
  Pan: TVector3;

  function ReadPan: TVector3;
  begin
    Result.X := L.ReadFloat;
    Result.Y := L.ReadFloat;
    Result.Z := L.ReadFloat;
  end;

begin
  Result := False;
  if not L.Next(Key) then
    Exit;
  if not SameText(Key, 'reverb') then
  begin
    { dhewm3 supports only reverb effects too, and stops at anything else }
    WritelnWarning('Doom3Efx', 'Unknown effect "%s" (line %d)', [Key, L.Line]);
    Exit;
  end;
  E := TD3ReverbEffect.Create;
  try
    E.Name := L.NextStr;
    if not L.Expect('{') then
    begin
      WritelnWarning('Doom3Efx', 'Reverb "%s": "{" expected (line %d)', [E.Name, L.Line]);
      Exit;
    end;
    R := E.Reverb;
    repeat
      if not L.Next(Key) then
      begin
        WritelnWarning('Doom3Efx', 'Reverb "%s": end of file without "}"', [E.Name]);
        Exit;
      end;
      if Key = '}' then
        Break;
      { the keys are quoted strings ("decay hf ratio"); also take them
        unquoted, as words up to the value }
      KeyQuoted := L.WasQuoted;
      if not KeyQuoted then
        while (L.Peek <> '') and (L.Peek[1] in ['a'..'z', 'A'..'Z']) do
          Key := Key + ' ' + L.NextStr;
      Key := LowerCase(Key);
      if Key = 'environment' then
        L.ReadFloat { an EAX preset number, nothing like it in EFX }
      else
      if Key = 'environment size' then
      begin
        { density from the size, like Creative's EFX-Util }
        Size := L.ReadFloat;
        R.Density := EnsureRange(Size * Size * Size / 16, 0, 1);
      end else
      if Key = 'environment diffusion' then
        R.Diffusion := L.ReadFloat
      else
      if Key = 'room' then
        R.Gain := MillibelsToGain(Trunc(L.ReadFloat), 0, 1)
      else
      if Key = 'room hf' then
        R.GainHF := MillibelsToGain(Trunc(L.ReadFloat), 0, 1)
      else
      if Key = 'room lf' then
        R.GainLF := MillibelsToGain(Trunc(L.ReadFloat), 0, 1)
      else
      if Key = 'decay time' then
        R.DecayTime := L.ReadFloat
      else
      if Key = 'decay hf ratio' then
        R.DecayHFRatio := L.ReadFloat
      else
      if Key = 'decay lf ratio' then
        R.DecayLFRatio := L.ReadFloat
      else
      if Key = 'reflections' then
        R.ReflectionsGain := MillibelsToGain(Trunc(L.ReadFloat), 0, 3.16)
      else
      if Key = 'reflections delay' then
        R.ReflectionsDelay := L.ReadFloat
      else
      if Key = 'reflections pan' then
      begin
        Pan := ReadPan;
        R.ReflectionsPan := Pan;
      end else
      if Key = 'reverb' then
        R.LateReverbGain := MillibelsToGain(Trunc(L.ReadFloat), 0, 10)
      else
      if Key = 'reverb delay' then
        R.LateReverbDelay := L.ReadFloat
      else
      if Key = 'reverb pan' then
      begin
        Pan := ReadPan;
        R.LateReverbPan := Pan;
      end else
      if Key = 'echo time' then
        R.EchoTime := L.ReadFloat
      else
      if Key = 'echo depth' then
        R.EchoDepth := L.ReadFloat
      else
      if Key = 'modulation time' then
        R.ModulationTime := L.ReadFloat
      else
      if Key = 'modulation depth' then
        R.ModulationDepth := L.ReadFloat
      else
      if Key = 'air absorption hf' then
        R.AirAbsorptionGainHF := MillibelsToGain(L.ReadFloat, 0.892, 1)
      else
      if Key = 'hf reference' then
        R.HFReference := L.ReadFloat
      else
      if Key = 'lf reference' then
        R.LFReference := L.ReadFloat
      else
      if Key = 'room rolloff factor' then
        R.RoomRolloffFactor := L.ReadFloat
      else
      if Key = 'flags' then
      begin
        { EAXREVERBFLAGS_DECAYHFLIMIT = $20; the scale flags have no EFX
          equivalent }
        S := L.NextStr;
        if (Length(S) > 2) and (S[1] = '0') and (S[2] in ['x', 'X']) then
          Flags := StrToIntDef('$' + Copy(S, 3, MaxInt), 0)
        else
          Flags := StrToIntDef(S, 0);
        R.DecayHFLimit := (Flags and $20) <> 0;
      end else
      begin
        Inc(FUnknownKeys);
        WritelnWarning('Doom3Efx', 'Reverb "%s": unknown parameter "%s" (line %d)', [E.Name, Key, L.Line]);
        L.SkipLine;
      end;
    until False;
    FEffects.Add(E);
    E := nil;
    Result := True;
  finally
    E.Free;
  end;
end;

function TD3EfxFile.LoadFromText(const Text: String): Boolean;
var
  L: TDoom3Lexer;
begin
  FEffects.Clear;
  FUnknownKeys := 0;
  L := TDoom3Lexer.Create(Text);
  try
    if not L.Expect('Version') then
      Exit(False);
    if L.ReadInt <> 1 then
    begin
      WritelnWarning('Doom3Efx', 'Unknown .efx version');
      Exit(False);
    end;
    while not L.AtEnd do
      if not ReadEffect(L) then
        Break;
    Result := True;
  finally
    L.Free;
  end;
end;

function TD3EfxFile.LoadFromVfs(const Path: String): Boolean;
begin
  FEffects.Clear;
  if not D3Fs.FileExists(Path) then
    Exit(False);
  Result := LoadFromText(D3Fs.ReadText(Path));
end;

function TD3EfxFile.Find(const Name: String): TD3ReverbEffect;
begin
  for Result in FEffects do
    if SameText(Result.Name, Name) then
      Exit;
  Result := nil;
end;

function TD3EfxFile.Select(const Area: Integer; const Location: String): TD3ReverbEffect;
begin
  Result := Find(IntToStr(Area));
  if (Result = nil) and (Location <> '') then
    Result := Find(Location);
  if Result = nil then
    Result := Find('default');
end;

end.
