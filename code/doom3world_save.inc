{ Saved games (roadmap "After the playthroughs" 1), the first part: the
  state that survives a level restart.

  A save is text: a line per fact, fields separated by tabs. Loading a
  save loads its map again (entities spawn, the map's script starts from
  main) and RestoreState puts back what is saved: the player (place, yaw,
  health, armor, weapons, clips, ammo, carried items, PDAs, emails, videos,
  objectives, security, stamina, air, powerups), the script's global
  variables, and per entity: lights on or off, brush and model entities
  hidden, monsters' health / death / place, items picked up, triggers
  disabled, doors locked, the smaller entities' state, trigger counts.

  Not saved yet: the script threads (a restarted map script runs its
  beginning again), where movers are, projectiles, monsters' awareness,
  moveables' places. }

const
  SaveMagic = 'castle-doom3-save';
  SaveVersion = 1;

function SaveFloat(const F: Single): String;
begin
  Result := FloatToStrF(F, ffGeneral, 9, 0, DefaultFormatSettings);
end;

function SaveVec(const V: TVector3): String;
begin
  Result := SaveFloat(V.X) + ' ' + SaveFloat(V.Y) + ' ' + SaveFloat(V.Z);
end;

function LoadFloat(const S: String): Single;
begin
  Result := StrToFloatDef(Trim(S), 0, DefaultFormatSettings);
end;

function LoadVec(const S: String): TVector3;
var
  Parts: TStringArray;
begin
  Result := TVector3.Zero;
  Parts := Trim(S).Split([' '], TStringSplitOptions.ExcludeEmpty);
  if Length(Parts) >= 3 then
    Result := Vector3(LoadFloat(Parts[0]), LoadFloat(Parts[1]), LoadFloat(Parts[2]));
end;

{ strings in a save: no tabs or line ends }
function SaveText(const S: String): String;
begin
  Result := StringReplace(S, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, #9, '\t', [rfReplaceAll]);
  Result := StringReplace(Result, #13, '', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '\n', [rfReplaceAll]);
end;

function LoadText(const S: String): String;
var
  I: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] = '\') and (I < Length(S)) then
    begin
      Inc(I);
      case S[I] of
        't': Result := Result + #9;
        'n': Result := Result + #10;
        else Result := Result + S[I];
      end;
    end else
      Result := Result + S[I];
    Inc(I);
  end;
end;

class function TD3Game.SavedMapName(const Text: String): String;
var
  Lines: TStringList;
  Parts: TStringArray;
  I: Integer;
begin
  Result := '';
  Lines := TStringList.Create;
  try
    Lines.Text := Text;
    if (Lines.Count = 0) or (Copy(Lines[0], 1, Length(SaveMagic)) <> SaveMagic) then
      Exit;
    for I := 1 to Min(Lines.Count - 1, 8) do
    begin
      Parts := Lines[I].Split([#9]);
      if (Length(Parts) >= 2) and (Parts[0] = 'map') then
        Exit(Parts[1]);
    end;
  finally
    Lines.Free;
  end;
end;

function TD3Game.SaveState(const AMapName: String): String;
var
  L: TStringList;
  I, Slot: Integer;
  D: TVector3;
  Yaw: Single;
  Pair: specialize TPair<String, Integer>;
  V: TD3Value;
  B: TD3BrushEntity;
  ME: TD3ModelEntity;
  Mon: TD3Monster;
  Item: TD3Item;
  T: TD3Trigger;
  Mov: TD3Mover;
  M: TD3MiscEntity;
  S: String;

  procedure Add(const Fields: array of String);
  var
    K: Integer;
    Line: String;
  begin
    Line := '';
    for K := 0 to High(Fields) do
    begin
      if K > 0 then
        Line := Line + #9;
      Line := Line + Fields[K];
    end;
    L.Add(Line);
  end;

begin
  L := TStringList.Create;
  try
    Add([SaveMagic, IntToStr(SaveVersion)]);
    Add(['map', AMapName]);
    Add(['time', SaveFloat(FTime)]);

    { the player }
    D := CgeToD3(PlayerViewDir);
    Yaw := 0;
    if (Abs(D.X) > 0.0001) or (Abs(D.Y) > 0.0001) then
      Yaw := RadToDeg(ArcTan2(D.Y, D.X));
    Add(['player', SaveVec(CgeToD3(PlayerFeet)), SaveFloat(Yaw), IntToStr(Health), IntToStr(Armor)]);
    Slot := FIdealSlot;
    if (Slot < 0) and (FWeapon <> nil) then
      Slot := FWeapon.Slot;
    Add(['weapons', IntToStr(Int64(WeaponBits)), IntToStr(Slot)]);
    for I := 0 to High(Clip) do
      if WeaponDefs[I] <> '' then
        Add(['clip', WeaponDefs[I], IntToStr(Clip[I])]);
    for Pair in FAmmo do
      Add(['ammo', Pair.Key, IntToStr(Pair.Value)]);
    for I := 0 to FCarried.Count - 1 do
      Add(['carried', SaveText(FCarried[I])]);
    for I := 0 to FPdas.Count - 1 do
      Add(['pda', SaveText(FPdas[I])]);
    for I := 0 to FEmails.Count - 1 do
      Add(['email', SaveText(FEmails[I])]);
    for I := 0 to FVideos.Count - 1 do
      Add(['video', SaveText(FVideos[I])]);
    for I := 0 to High(FObjectives) do
      Add(['objective', SaveText(FObjectives[I].Title), SaveText(FObjectives[I].Text),
        SaveText(FObjectives[I].Screenshot), IntToStr(Ord(FObjectives[I].Complete))]);
    Add(['mission', SaveText(FMissionObjective)]);
    Add(['security', SaveText(FSecurity)]);
    Add(['stamina', SaveFloat(FStamina), IntToStr(Ord(FNoStamina)), SaveFloat(FAirTics)]);
    for I := 0 to High(FPowerupEnd) do
      if FPowerupEnd[I] > FTime then
        Add(['powerup', IntToStr(I), SaveFloat(FPowerupEnd[I] - FTime)]);

    { the script's global variables }
    if FScript <> nil then
    begin
      Add(['globals', IntToStr(FScript.GlobalCount)]);
      for I := 0 to FScript.GlobalCount - 1 do
      begin
        V := FScript.GlobalAt(I);
        case V.Kind of
          sbFloat: if V.F <> 0 then Add(['g', IntToStr(I), 'f', SaveFloat(V.F)]);
          sbVector: if not V.V.IsZero then Add(['g', IntToStr(I), 'v', SaveVec(V.V)]);
          sbString: if V.S <> '' then Add(['g', IntToStr(I), 's', SaveText(V.S)]);
          sbEntity: if V.E <> 0 then Add(['g', IntToStr(I), 'e', IntToStr(V.E)]);
        end;
      end;
    end;
    for Pair in FCounts do
      Add(['count', SaveText(Pair.Key), IntToStr(Pair.Value)]);

    { entities }
    for I := 0 to FMap.LightCount - 1 do
      if FMap.Light(I).Entity <> nil then
        Add(['light', FMap.Light(I).Entity.Name, IntToStr(Ord(FMap.Light(I).StartOn))]);
    for B in FMap.Brushes do
      if B.Hidden then
        Add(['hidden', B.Entity.Name]);
    for ME in FMap.Models do
      if ME.Hidden then
        Add(['hidden', ME.Entity.Name]);
    for Mon in FMonsters do
      if Mon.Model <> nil then
        Add(['monster', Mon.Model.Entity.Name, IntToStr(Mon.Health), IntToStr(Ord(Mon.State = msDead)),
          SaveVec(CgeToD3(Mon.Model.Holder.Translation)), SaveFloat(Mon.Yaw)]);
    for Item in FItems do
      if Item.PickedUp then
        Add(['picked', Item.Entity.Name]);
    for T in FTriggers do
      if T.Disabled or T.WaitingForActivation then
        Add(['trigger', T.Entity.Name, IntToStr(Ord(T.Disabled)), IntToStr(Ord(T.WaitingForActivation))]);
    for Mov in FMovers do
      Add(['mover', Mov.Brush.Entity.Name, IntToStr(Ord(Mov.Locked)), IntToStr(Ord(Mov.Disabled))]);
    for M in FMisc do
      Add(['misc', M.Entity.Name, IntToStr(Ord(M.Dead)), IntToStr(M.Health), IntToStr(Ord(M.On)),
        IntToStr(M.Count)]);
    S := L.Text;
  finally
    L.Free;
  end;
  Result := S;
end;

function TD3Game.RestoreState(const Text: String): Boolean;
var
  L: TStringList;
  P: TStringArray;
  LineIndex, I, N, Slot, GlobalCount: Integer;
  V: TD3Value;
  E: TD3MapEntity;
  B: TD3BrushEntity;
  ME: TD3ModelEntity;
  Mon: TD3Monster;
  Item: TD3Item;
  T: TD3Trigger;
  Mov: TD3Mover;
  M: TD3MiscEntity;
  Name, Kind: String;
  GlobalsMatch, ObjectivesCleared: Boolean;

  function Field(const Index: Integer): String;
  begin
    if Index < Length(P) then
      Result := P[Index]
    else
      Result := '';
  end;

  function FieldInt(const Index: Integer): Integer;
  begin
    Result := StrToIntDef(Field(Index), 0);
  end;

begin
  Result := False;
  L := TStringList.Create;
  try
    L.Text := Text;
    if L.Count = 0 then
      Exit;
    P := L[0].Split([#9]);
    if (Field(0) <> SaveMagic) or (FieldInt(1) <> SaveVersion) then
    begin
      WritelnWarning('Doom3World', 'Not a saved game of this version');
      Exit;
    end;
    { what the fresh spawn gave is replaced }
    FAmmo.Clear;
    FCarried.Clear;
    FPdas.Clear;
    FEmails.Clear;
    FVideos.Clear;
    ObjectivesCleared := False;
    GlobalsMatch := False;
    GlobalCount := 0;
    Slot := -1;
    for LineIndex := 1 to L.Count - 1 do
    begin
      P := L[LineIndex].Split([#9]);
      Kind := Field(0);
      Name := Field(1);
      case Kind of
        'player':
          begin
            FTeleportPending := True;
            FTeleportPos := D3ToCge(LoadVec(Field(1)));
            FTeleportYaw := LoadFloat(Field(2));
            Health := FieldInt(3);
            Armor := FieldInt(4);
          end;
        'weapons':
          begin
            WeaponBits := Cardinal(StrToInt64Def(Field(1), 0));
            Slot := FieldInt(2);
          end;
        'clip':
          for I := 0 to High(WeaponDefs) do
            if WeaponDefs[I] = Name then
              Clip[I] := FieldInt(2);
        'ammo': FAmmo.AddOrSetValue(Name, FieldInt(2));
        'carried': FCarried.Add(LoadText(Name));
        'pda': FPdas.Add(LoadText(Name));
        'email': FEmails.Add(LoadText(Name));
        'video': FVideos.Add(LoadText(Name));
        'objective':
          begin
            if not ObjectivesCleared then
            begin
              SetLength(FObjectives, 0);
              ObjectivesCleared := True;
            end;
            SetLength(FObjectives, Length(FObjectives) + 1);
            FObjectives[High(FObjectives)].Title := LoadText(Field(1));
            FObjectives[High(FObjectives)].Text := LoadText(Field(2));
            FObjectives[High(FObjectives)].Screenshot := LoadText(Field(3));
            FObjectives[High(FObjectives)].Complete := FieldInt(4) <> 0;
          end;
        'mission': FMissionObjective := LoadText(Name);
        'security': FSecurity := LoadText(Name);
        'stamina':
          begin
            FStamina := LoadFloat(Field(1));
            FNoStamina := FieldInt(2) <> 0;
            FAirTics := LoadFloat(Field(3));
          end;
        'powerup':
          if (FieldInt(1) >= 0) and (FieldInt(1) <= High(FPowerupEnd)) then
            FPowerupEnd[FieldInt(1)] := FTime + LoadFloat(Field(2));
        'globals':
          begin
            GlobalCount := FieldInt(1);
            { the same program: the same variables at the same places }
            GlobalsMatch := (FScript <> nil) and (FScript.GlobalCount = GlobalCount);
            if not GlobalsMatch then
              WritelnWarning('Doom3World', 'The saved game''s script variables don''t match the program: not restored');
          end;
        'g':
          if GlobalsMatch then
          begin
            N := FieldInt(1);
            V := FScript.GlobalAt(N);
            case Field(2) of
              'f': if V.Kind = sbFloat then V.F := LoadFloat(Field(3));
              'v': if V.Kind = sbVector then V.V := LoadVec(Field(3));
              's': if V.Kind = sbString then V.S := LoadText(Field(3));
              'e': if V.Kind = sbEntity then V.E := FieldInt(3);
            end;
            FScript.SetGlobalAt(N, V);
          end;
        'count': FCounts.AddOrSetValue(LoadText(Name), FieldInt(2));
        'light':
          begin
            I := FMap.FindLight(Name);
            if (I >= 0) and (FMap.Light(I).StartOn <> (FieldInt(2) <> 0)) then
              FMap.SetLightOn(I, FieldInt(2) <> 0);
          end;
        'hidden':
          begin
            B := FMap.FindBrush(Name);
            if (B <> nil) and not B.Hidden then
              B.SetHidden(True);
            ME := FMap.FindModelEntity(Name);
            if (ME <> nil) and not ME.Hidden then
            begin
              ME.Hidden := True;
              ME.Holder.Exists := False;
            end;
          end;
        'monster':
          for Mon in FMonsters do
            if (Mon.Model <> nil) and (Mon.Model.Entity.Name = Name) then
            begin
              if FieldInt(3) <> 0 then
              begin
                { dead: gone (the body isn't kept) }
                if Mon.State <> msDead then
                  RemoveEntity(Mon.Model.Entity);
                Mon.Health := Min(0, FieldInt(2));
              end else
              begin
                Mon.Health := FieldInt(2);
                Mon.Model.Holder.Translation := D3ToCge(LoadVec(Field(4)));
                Mon.Yaw := LoadFloat(Field(5));
              end;
              Break;
            end;
        'picked':
          for Item in FItems do
            if Item.Entity.Name = Name then
            begin
              Item.PickedUp := True;
              RemoveEntity(Item.Entity);
              Break;
            end;
        'trigger':
          for T in FTriggers do
            if T.Entity.Name = Name then
            begin
              T.Disabled := FieldInt(2) <> 0;
              T.WaitingForActivation := FieldInt(3) <> 0;
            end;
        'mover':
          for Mov in FMovers do
            if Mov.Brush.Entity.Name = Name then
            begin
              Mov.Locked := FieldInt(2) <> 0;
              Mov.Disabled := FieldInt(3) <> 0;
            end;
        'misc':
          for M in FMisc do
            if M.Entity.Name = Name then
            begin
              M.Health := FieldInt(3);
              M.On := FieldInt(4) <> 0;
              M.Count := FieldInt(5);
              if (FieldInt(2) <> 0) and not M.Dead then
              begin
                M.Dead := True;
                if M.Brush <> nil then
                  M.Brush.SetHidden(True);
              end;
            end;
      end;
    end;
    { entities the fresh spawn shows but the save had hidden are handled
      above; the other way (hidden at spawn, shown when saved) }
    for B in FMap.Brushes do
      if B.Hidden and (L.IndexOf('hidden'#9 + B.Entity.Name) < 0) then
      begin
        E := B.Entity;
        { (items and the smaller entities hide theirs themselves) }
        if (MiscOf(E) = nil) and (ItemOf(E) = nil) then
          B.SetHidden(False);
      end;
    if (Slot >= 0) and HasWeapon(Slot) then
      SelectWeapon(Slot);
    WritelnLog('Doom3World', 'Saved game restored: %d lines, health %d, %d script variables',
      [L.Count, Health, GlobalCount]);
    Result := True;
  finally
    L.Free;
  end;
end;
