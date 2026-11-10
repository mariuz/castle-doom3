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

  The script goes on where it was: the game's clock is the saved one, the
  threads (stacks, frames, waits) and the actors' script objects are put
  back when the program is the same (the same number of functions and
  global variables), with the actors' states, the doors' and script
  movers' moves, every brush and model entity's place and the delayed
  activations.

  Also: projectiles in flight (made again from their defs), the weapon in
  the hand with its script thread and object, elevators, the lights'
  shader parameters (colors) and fades, which speakers play, god and
  notarget (the view adds noclip). The dead lie where they died: a body
  that was there falls again as a ragdoll at its place.

  Not saved: particles and FX in flight, one-shot sounds, decals. }

const
  SaveMagic = 'castle-doom3-save';
  SaveVersion = 3;

function SaveRot(const V: TVector4): String;
begin
  Result := FloatToStrF(V.X, ffGeneral, 9, 0, DefaultFormatSettings) + ' ' +
    FloatToStrF(V.Y, ffGeneral, 9, 0, DefaultFormatSettings) + ' ' +
    FloatToStrF(V.Z, ffGeneral, 9, 0, DefaultFormatSettings) + ' ' +
    FloatToStrF(V.W, ffGeneral, 9, 0, DefaultFormatSettings);
end;

function LoadRot(const S: String): TVector4;
var
  Parts: TStringArray;
begin
  Result := Vector4(0, 1, 0, 0);
  Parts := Trim(S).Split([' '], TStringSplitOptions.ExcludeEmpty);
  if Length(Parts) >= 4 then
    Result := Vector4(StrToFloatDef(Parts[0], 0, DefaultFormatSettings), StrToFloatDef(Parts[1], 1, DefaultFormatSettings),
      StrToFloatDef(Parts[2], 0, DefaultFormatSettings), StrToFloatDef(Parts[3], 0, DefaultFormatSettings));
end;

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
  A: TD3Actor;
  C: Integer;
  SM: TD3ScriptMover;
  HandlePair: specialize TPair<Integer, TD3ScriptMover>;
  E: TD3MapEntity;
  Proj: TD3Projectile;
  El: TD3Elevator;
  Sp: TD3Speaker;
  Info: TD3LightInfo;

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

    { the script's threads (the weapon's is made again when it is raised)
      and the actors' objects and states }
    if FScript <> nil then
    begin
      Add(['program', IntToStr(FScript.FunctionCount), IntToStr(FScript.GlobalCount)]);
      FScript.SaveThreads(L, '');
      { the weapon in the hand: its script object and state }
      if (FWeapon <> nil) and (FWeapon.Slot = Slot) then
      begin
        Add(['wstate', FWeapon.DefName, SaveText(FWeapon.StateName), SaveText(FWeapon.IdealName),
          IntToStr(Ord(FWeapon.HasIdeal)), IntToStr(Ord(FWeapon.Status)), SaveFloat(FWeapon.AnimDoneTime)]);
        if FWeapon.Obj <> nil then
        begin
          Add(['wobj', FWeapon.DefName, IntToStr(Length(FWeapon.Obj.Fields))]);
          for I := 0 to High(FWeapon.Obj.Fields) do
            Add(['wv', TD3ScriptVM.ValueKind(FWeapon.Obj.Fields[I]), TD3ScriptVM.ValueText(FWeapon.Obj.Fields[I])]);
        end;
      end;
      for A in FActors do
      begin
        Add(['actor', A.Model.Entity.Name, SaveText(A.StateName), SaveText(A.IdealName), IntToStr(Ord(A.HasIdeal)),
          SaveText(A.WaitAction), IntToStr(Ord(A.Thinking)), IntToStr(Ord(A.HasEnemy)), IntToStr(Ord(A.ChaseEnemy)),
          IntToStr(A.TalkState), IntToStr(A.TalkTarget), IntToStr(A.FocusTarget), IntToStr(Ord(A.Moving)),
          SaveVec(A.Goal), SaveFloat(A.Yaw), SaveFloat(A.IdealYaw), IntToStr(A.MoveType), SaveVec(A.Velocity),
          IntToStr(Ord(A.MoveDirect)), IntToStr(Ord(A.WaitMove)), SaveText(A.Attack)]);
        for C := Low(A.Channels) to High(A.Channels) do
          Add(['achan', A.Model.Entity.Name, IntToStr(C), SaveText(A.Channels[C].StateName),
            SaveText(A.Channels[C].PendingName), IntToStr(Ord(A.Channels[C].HasPending)),
            SaveText(A.Channels[C].AnimName), SaveFloat(A.Channels[C].AnimStart),
            SaveFloat(A.Channels[C].AnimLength), IntToStr(Ord(A.Channels[C].AnimLoop))]);
        if A.Obj <> nil then
        begin
          Add(['obj', A.Model.Entity.Name, IntToStr(Length(A.Obj.Fields))]);
          for I := 0 to High(A.Obj.Fields) do
            Add(['ov', TD3ScriptVM.ValueKind(A.Obj.Fields[I]), TD3ScriptVM.ValueText(A.Obj.Fields[I])]);
        end;
      end;
    end;
    for I := 0 to FPending.Count - 1 do
      if FPending[I].Entity <> nil then
        Add(['pending', FPending[I].Entity.Name, SaveFloat(FPending[I].Time)]);

    { where things are }
    for B in FMap.Brushes do
      Add(['xb', B.Entity.Name, SaveVec(B.Scene.Translation), SaveRot(B.Scene.Rotation)]);
    for ME in FMap.Models do
      Add(['xm', ME.Entity.Name, SaveVec(ME.Holder.Translation), SaveRot(ME.Holder.Rotation)]);
    for Mov in FMovers do
      Add(['door', Mov.Brush.Entity.Name, IntToStr(Ord(Mov.State)), SaveFloat(Mov.Progress), SaveFloat(Mov.Timer),
        IntToStr(Ord(Mov.Running)), SaveFloat(Mov.Angle), SaveFloat(Mov.Time)]);
    for HandlePair in FScriptMovers do
    begin
      SM := HandlePair.Value;
      E := HandleEntity(HandlePair.Key);
      if E = nil then
        Continue;
      Add(['smover', E.Name, SaveVec(SM.Origin), SaveVec(SM.Angles),
        SaveFloat(SM.MoveTime), SaveFloat(SM.MoveSpeed), SaveFloat(SM.AccelTime), SaveFloat(SM.DecelTime),
        IntToStr(Ord(SM.Moving)), SaveVec(SM.MoveFrom), SaveVec(SM.MoveTo), SaveFloat(SM.MoveStart),
        SaveFloat(SM.MoveDuration), IntToStr(Ord(SM.Rotating)), IntToStr(Ord(SM.RotContinuous)),
        SaveVec(SM.RotFrom), SaveVec(SM.RotTo), SaveVec(SM.RotSpeed), SaveFloat(SM.RotStart),
        SaveFloat(SM.RotDuration), IntToStr(Ord(SM.Swaying)), SaveVec(SM.SwayBase), SaveVec(SM.SwayAmplitude),
        SaveFloat(SM.SwayStart), SaveFloat(SM.SwayQuarter)]);
    end;

    Add(['cheats', IntToStr(Ord(God)), IntToStr(Ord(NoTarget))]);
    for Proj in FProjectiles do
      if (Proj.HeldBy = nil) and (Proj.HeldByWeapon = nil) and (Proj.DefName <> '') then
        Add(['projectile', Proj.DefName, SaveText(Proj.Owner), SaveVec(Proj.Position), SaveVec(Proj.Velocity),
          SaveFloat(Proj.Fuse), IntToStr(Ord(Proj.Resting)), SaveFloat(Proj.Pitch), SaveFloat(Proj.Yaw)]);
    for El in FElevators do
      Add(['elevator', El.Entity.Name, IntToStr(Ord(El.State)), IntToStr(El.CurrentFloor), IntToStr(El.PendingFloor),
        IntToStr(El.LastFloor), IntToStr(Ord(El.ControlsDisabled)), SaveFloat(El.RetryAt), SaveFloat(El.ArriveAt),
        SaveFloat(El.ReturnAt), SaveFloat(El.LastTouch), IntToStr(El.RetryFloor)]);
    for Sp in FSpeakers do
      if Sp.Looping then
        Add(['speaker', Sp.Entity.Name, IntToStr(Ord(Sp.Source.Sound <> nil))]);

    { entities }
    for I := 0 to FMap.LightCount - 1 do
      if FMap.Light(I).Entity <> nil then
      begin
        Info := FMap.Light(I);
        Add(['light', Info.Entity.Name, IntToStr(Ord(Info.StartOn))]);
        S := '';
        for C := 0 to High(Info.Parms.Parms) do
          S := S + SaveFloat(Info.Parms.Parms[C]) + ' ';
        Add(['lightparms', Info.Entity.Name, Trim(S), SaveFloat(Info.Fade)]);
      end;
    for B in FMap.Brushes do
      if B.Hidden then
        Add(['hidden', B.Entity.Name]);
    for ME in FMap.Models do
      if ME.Hidden then
        Add(['hidden', ME.Entity.Name]);
    for Mon in FMonsters do
      if Mon.Model <> nil then
        Add(['monster', Mon.Model.Entity.Name, IntToStr(Mon.Health), IntToStr(Ord(Mon.State = msDead)),
          SaveVec(CgeToD3(Mon.Model.Holder.Translation)), SaveFloat(Mon.Yaw), IntToStr(Ord(Mon.Dormant)),
          IntToStr(Ord(Mon.State))]);
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
  GlobalsMatch, ObjectivesCleared, ProgramMatch, ThreadsBegun: Boolean;
  A, ObjActor: TD3Actor;
  C, ObjIndex: Integer;
  SM: TD3ScriptMover;
  Pending: TD3PendingTargets;
  Proj: TD3Projectile;
  El: TD3Elevator;
  Sp: TD3Speaker;
  Info: TD3LightInfo;
  Parts: TStringArray;
  WeaponObj: Boolean;

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
    ProgramMatch := False;
    ThreadsBegun := False;
    ObjActor := nil;
    ObjIndex := 0;
    WeaponObj := False;
    GlobalsMatch := False;
    GlobalCount := 0;
    Slot := -1;
    for LineIndex := 1 to L.Count - 1 do
    begin
      P := L[LineIndex].Split([#9]);
      Kind := Field(0);
      Name := Field(1);
      case Kind of
        'time':
          begin
            { the saved clock: the threads' and movers' times are on it }
            FTime := LoadFloat(Field(1));
            if FScript <> nil then
              FScript.SetTime(FTime);
          end;
        'program':
          begin
            ProgramMatch := (FScript <> nil) and (FScript.FunctionCount = FieldInt(1)) and
              (FScript.GlobalCount = FieldInt(2));
            if not ProgramMatch then
              WritelnWarning('Doom3World', 'The saved game''s script program isn''t this one: its threads aren''t restored');
          end;
        'threadnext', 'thread', 'tf', 'tv':
          if ProgramMatch then
          begin
            if not ThreadsBegun then
            begin
              FScript.BeginRestoreThreads;
              FPending.Clear;
              ThreadsBegun := True;
            end;
            FScript.RestoreThreadLine(P);
          end;
        'actor':
          if ProgramMatch then
            for A in FActors do
              if A.Model.Entity.Name = Name then
              begin
                A.StateName := LoadText(Field(2));
                A.IdealName := LoadText(Field(3));
                A.HasIdeal := FieldInt(4) <> 0;
                A.IdealFunction := nil;
                if A.HasIdeal and (A.Obj <> nil) then
                  A.IdealFunction := A.Obj.Typ.FindMethodToRun(A.IdealName);
                if A.IdealFunction = nil then
                  A.HasIdeal := False;
                A.WaitAction := LoadText(Field(5));
                A.Thinking := FieldInt(6) <> 0;
                A.HasEnemy := FieldInt(7) <> 0;
                A.ChaseEnemy := FieldInt(8) <> 0;
                A.TalkState := FieldInt(9);
                A.TalkTarget := FieldInt(10);
                A.FocusTarget := FieldInt(11);
                A.Moving := FieldInt(12) <> 0;
                A.Goal := LoadVec(Field(13));
                A.Yaw := LoadFloat(Field(14));
                A.IdealYaw := LoadFloat(Field(15));
                A.MoveType := FieldInt(16);
                A.Velocity := LoadVec(Field(17));
                A.MoveDirect := FieldInt(18) <> 0;
                A.WaitMove := FieldInt(19) <> 0;
                A.Attack := LoadText(Field(20));
                Break;
              end;
        'achan':
          if ProgramMatch then
            for A in FActors do
              if A.Model.Entity.Name = Name then
              begin
                C := FieldInt(2);
                if (C >= Low(A.Channels)) and (C <= High(A.Channels)) then
                begin
                  A.Channels[C].StateName := LoadText(Field(3));
                  A.Channels[C].PendingName := LoadText(Field(4));
                  A.Channels[C].HasPending := FieldInt(5) <> 0;
                  A.Channels[C].PendingFunction := nil;
                  if A.Channels[C].HasPending and (A.Obj <> nil) then
                    A.Channels[C].PendingFunction := A.Obj.Typ.FindMethodToRun(A.Channels[C].PendingName);
                  if A.Channels[C].PendingFunction = nil then
                    A.Channels[C].HasPending := False;
                  A.Channels[C].AnimName := LoadText(Field(6));
                  A.Channels[C].AnimStart := LoadFloat(Field(7));
                  A.Channels[C].AnimLength := LoadFloat(Field(8));
                  A.Channels[C].AnimLoop := FieldInt(9) <> 0;
                  { the model shows the animation again (from its start) }
                  if A.Channels[C].AnimName <> '' then
                    A.Model.Instance.PlayAnim(A.Channels[C].AnimName, A.Channels[C].AnimLoop);
                end;
                Break;
              end;
        'obj':
          begin
            ObjActor := nil;
            ObjIndex := 0;
            if ProgramMatch then
              for A in FActors do
                if (A.Model.Entity.Name = Name) and (A.Obj <> nil) and (Length(A.Obj.Fields) = FieldInt(2)) then
                  ObjActor := A;
          end;
        'ov':
          begin
            if (ObjActor <> nil) and (ObjIndex <= High(ObjActor.Obj.Fields)) then
              ObjActor.Obj.Fields[ObjIndex] := TD3ScriptVM.ValueFrom(Field(1), Field(2));
            Inc(ObjIndex);
          end;
        'pending':
          if ProgramMatch then
          begin
            Pending.Entity := FindEntity(Name);
            Pending.Time := LoadFloat(Field(2));
            if Pending.Entity <> nil then
              FPending.Add(Pending);
          end;
        'xb':
          begin
            B := FMap.FindBrush(Name);
            if B <> nil then
            begin
              B.Scene.Translation := LoadVec(Field(2));
              B.Scene.Rotation := LoadRot(Field(3));
            end;
          end;
        'xm':
          begin
            ME := FMap.FindModelEntity(Name);
            if ME <> nil then
            begin
              ME.Holder.Translation := LoadVec(Field(2));
              ME.Holder.Rotation := LoadRot(Field(3));
            end;
          end;
        'door':
          for Mov in FMovers do
            if Mov.Brush.Entity.Name = Name then
            begin
              Mov.State := TD3DoorState(FieldInt(2));
              Mov.Progress := LoadFloat(Field(3));
              Mov.Timer := LoadFloat(Field(4));
              Mov.Running := FieldInt(5) <> 0;
              Mov.Angle := LoadFloat(Field(6));
              Mov.Time := LoadFloat(Field(7));
            end;
        'smover':
          begin
            SM := ScriptMover(EntityHandle(FindEntity(Name)));
            if SM <> nil then
            begin
              SM.Origin := LoadVec(Field(2));
              SM.Angles := LoadVec(Field(3));
              SM.MoveTime := LoadFloat(Field(4));
              SM.MoveSpeed := LoadFloat(Field(5));
              SM.AccelTime := LoadFloat(Field(6));
              SM.DecelTime := LoadFloat(Field(7));
              SM.Moving := FieldInt(8) <> 0;
              SM.MoveFrom := LoadVec(Field(9));
              SM.MoveTo := LoadVec(Field(10));
              SM.MoveStart := LoadFloat(Field(11));
              SM.MoveDuration := LoadFloat(Field(12));
              SM.Rotating := FieldInt(13) <> 0;
              SM.RotContinuous := FieldInt(14) <> 0;
              SM.RotFrom := LoadVec(Field(15));
              SM.RotTo := LoadVec(Field(16));
              SM.RotSpeed := LoadVec(Field(17));
              SM.RotStart := LoadFloat(Field(18));
              SM.RotDuration := LoadFloat(Field(19));
              SM.Swaying := FieldInt(20) <> 0;
              SM.SwayBase := LoadVec(Field(21));
              SM.SwayAmplitude := LoadVec(Field(22));
              SM.SwayStart := LoadFloat(Field(23));
              SM.SwayQuarter := LoadFloat(Field(24));
            end;
          end;
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
            { the saved weapon is in the hand at once: its thread and object
              follow }
            if (Slot >= 0) and HasWeapon(Slot) and ((FWeapon = nil) or (FWeapon.Slot <> Slot)) then
            begin
              if FWeapon <> nil then
              begin
                DropHeldProjectile(FWeapon);
                if (FScript <> nil) and (FWeapon.Thread <> nil) then
                  FScript.FreeThread(FWeapon.Thread);
                FreeAndNil(FWeapon);
              end;
              FIdealSlot := Slot;
              FWeapon := SpawnWeapon(Slot);
            end;
          end;
        'wstate':
          if ProgramMatch and (FWeapon <> nil) and (FWeapon.DefName = Name) then
          begin
            FWeapon.StateName := LoadText(Field(2));
            FWeapon.IdealName := LoadText(Field(3));
            FWeapon.HasIdeal := FieldInt(4) <> 0;
            FWeapon.IdealFunction := nil;
            if FWeapon.HasIdeal and (FWeapon.Obj <> nil) then
              FWeapon.IdealFunction := FWeapon.Obj.Typ.FindMethodToRun(FWeapon.IdealName);
            if FWeapon.IdealFunction = nil then
              FWeapon.HasIdeal := False;
            FWeapon.Status := TD3WeaponStatus(FieldInt(5));
            FWeapon.AnimDoneTime := LoadFloat(Field(6));
          end;
        'wobj':
          begin
            WeaponObj := ProgramMatch and (FWeapon <> nil) and (FWeapon.DefName = Name) and
              (FWeapon.Obj <> nil) and (Length(FWeapon.Obj.Fields) = FieldInt(2));
            ObjIndex := 0;
          end;
        'wv':
          begin
            if WeaponObj and (ObjIndex <= High(FWeapon.Obj.Fields)) then
              FWeapon.Obj.Fields[ObjIndex] := TD3ScriptVM.ValueFrom(Field(1), Field(2));
            Inc(ObjIndex);
          end;
        'cheats':
          begin
            God := FieldInt(1) <> 0;
            NoTarget := FieldInt(2) <> 0;
          end;
        'projectile':
          begin
            Proj := SpawnProjectile(Name, LoadText(Field(2)), LoadVec(Field(3)), LoadVec(Field(4)));
            if Proj <> nil then
            begin
              Proj.Position := LoadVec(Field(3));
              Proj.Velocity := LoadVec(Field(4));
              Proj.Fuse := LoadFloat(Field(5));
              Proj.Resting := FieldInt(6) <> 0;
              Proj.Pitch := LoadFloat(Field(7));
              Proj.Yaw := LoadFloat(Field(8));
            end;
          end;
        'elevator':
          for El in FElevators do
            if El.Entity.Name = Name then
            begin
              El.State := TD3ElevatorState(FieldInt(2));
              El.CurrentFloor := FieldInt(3);
              El.PendingFloor := FieldInt(4);
              El.LastFloor := FieldInt(5);
              El.ControlsDisabled := FieldInt(6) <> 0;
              El.RetryAt := LoadFloat(Field(7));
              El.ArriveAt := LoadFloat(Field(8));
              El.ReturnAt := LoadFloat(Field(9));
              El.LastTouch := LoadFloat(Field(10));
              El.RetryFloor := FieldInt(11);
            end;
        'speaker':
          for Sp in FSpeakers do
            if (Sp.Entity.Name = Name) and Sp.Looping then
            begin
              if (FieldInt(2) <> 0) and (Sp.Source.Sound = nil) then
                Sp.Source.Sound := Sp.Sound
              else
              if (FieldInt(2) = 0) and (Sp.Source.Sound <> nil) then
                Sp.Source.Sound := nil;
            end;
        'lightparms':
          begin
            I := FMap.FindLight(Name);
            if I >= 0 then
            begin
              Info := FMap.Light(I);
              Parts := Trim(Field(2)).Split([' '], TStringSplitOptions.ExcludeEmpty);
              for C := 0 to Min(High(Parts), High(Info.Parms.Parms)) do
                if Abs(Info.Parms.Parms[C] - LoadFloat(Parts[C])) > 0.0001 then
                  FMap.SetLightParm(I, C, LoadFloat(Parts[C]));
              if Abs(Info.Fade - LoadFloat(Field(3))) > 0.0001 then
                FMap.SetLightFade(I, LoadFloat(Field(3)));
            end;
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
                { dead: its body (unless it was gone: hidden above) lies
                  where it died, falling there again as a ragdoll }
                Mon.Model.Holder.Translation := D3ToCge(LoadVec(Field(4)));
                Mon.Yaw := LoadFloat(Field(5));
                Mon.Health := Min(0, FieldInt(2));
                Mon.State := msDead;
                Mon.StateTime := 1000;
                Mon.Dormant := False;
                if not Mon.Model.Hidden and Mon.Model.Holder.Exists then
                begin
                  if RagdollEnabled then
                    MonsterRagdoll(Mon, TVector3.Zero)
                  else
                    RemoveEntity(Mon.Model.Entity);
                end;
              end else
              begin
                Mon.Health := FieldInt(2);
                Mon.Model.Holder.Translation := D3ToCge(LoadVec(Field(4)));
                Mon.Yaw := LoadFloat(Field(5));
                if Length(P) > 7 then
                begin
                  Mon.Dormant := FieldInt(6) <> 0;
                  Mon.State := TD3MonsterState(FieldInt(7));
                end;
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
    { models hidden at spawn that the save had shown (monsters woken by a
      trigger): shown, with their monster }
    for ME in FMap.Models do
      if ME.Hidden and (L.IndexOf('hidden'#9 + ME.Entity.Name) < 0) then
      begin
        N := 0;
        for Mon in FMonsters do
          if Mon.Model = ME then
          begin
            Inc(N);
            if Mon.State = msDead then
              Inc(N);
          end;
        { (dead ones stay gone) }
        if N >= 2 then
          Continue;
        ME.Hidden := False;
        ME.Holder.Exists := True;
        if (N = 0) and (Copy(LowerCase(ME.Entity.ClassName_), 1, 8) = 'monster_') then
          SpawnMonster(ME);
      end;
    { the fresh map script's first moments (a camera, a fade) are undone:
      the saved threads go on instead }
    if ThreadsBegun then
    begin
      FCameraEntity := nil;
      FCameraAnim := nil;
      FFadeTime := 0;
      FFadeTo := TVector4.Zero;
      FFadeFrom := TVector4.Zero;
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
