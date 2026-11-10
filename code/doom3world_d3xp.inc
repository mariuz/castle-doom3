{ Part of Doom3World (TD3Game): Resurrection of Evil's game code (the
  artifact's powerups with hell time, the grabber), the air supply in
  vacuum areas (idPlayer::UpdateAir, both games) and script events that
  came with them. }

{ Vacuum and air ------------------------------------------------------------- }

procedure TD3Game.SpawnVacuum;
var
  E: TD3MapEntity;
  P, Area, N: Integer;
begin
  FVacuumAreas := nil;
  FVacuumBlocked := nil;
  FAirless := False;
  FAirTics := AirTicsMax;
  FLastAirDamage := 0;
  FAirCheckTime := 0;
  if (FMap.MapFile = nil) or (FMap.Portals = nil) then
    Exit;
  SetLength(FVacuumBlocked, FMap.Portals.PortalCount);
  N := 0;
  for E in FMap.MapFile.Entities do
    if E.Value('spawnclass') = 'idVacuumEntity' then
    begin
      Area := FMap.AreaAt(D3ToCge(E.Origin));
      if Area >= 0 then
        FVacuumAreas := Concat(FVacuumAreas, [Area]);
    end else
    if E.Value('spawnclass') = 'idVacuumSeparatorEntity' then
    begin
      { idVacuumSeparatorEntity: the portal at it blocks the air until
        it is activated }
      P := FMap.Portals.FindPortal(Box3DAroundPoint(D3ToCge(E.Origin), 32));
      if P >= 0 then
      begin
        FVacuumBlocked[P] := True;
        Inc(N);
      end else
        WritelnWarning('Doom3World', 'VacuumSeparator "%s" didn''t contact a portal', [E.Name]);
    end;
  if Length(FVacuumAreas) > 0 then
    WritelnLog('Doom3World', 'Vacuum: %d info_vacuum, %d separators', [Length(FVacuumAreas), N]);
end;

procedure TD3Game.ToggleVacuumSeparator(const E: TD3MapEntity);
var
  P: Integer;
begin
  if FMap.Portals = nil then
    Exit;
  P := FMap.Portals.FindPortal(Box3DAroundPoint(D3ToCge(E.Origin), 32));
  if (P >= 0) and (P <= High(FVacuumBlocked)) then
  begin
    FVacuumBlocked[P] := not FVacuumBlocked[P];
    WritelnLog('Doom3World', 'Vacuum separator %s %s', [E.Name, BoolToStr(FVacuumBlocked[P], 'blocks', 'open')]);
    FAirCheckTime := 0;
  end;
end;

{ Is the area connected to an info_vacuum's area through portals that
  let air through (not a closed door, not a vacuum separator)? }
function TD3Game.AreaInVacuum(const Area: Integer): Boolean;
var
  Portals: TD3PortalVisibility;
  Seen: array of Boolean;
  Queue: array of Integer;
  Head, Tail, A, P, Other, I: Integer;
begin
  Result := False;
  Portals := FMap.Portals;
  if (Portals = nil) or (Length(FVacuumAreas) = 0) or (Area < 0) or (Area >= Portals.AreaCount) then
    Exit;
  SetLength(Seen, Portals.AreaCount);
  SetLength(Queue, Portals.AreaCount);
  Tail := 0;
  for I := 0 to High(FVacuumAreas) do
    if not Seen[FVacuumAreas[I]] then
    begin
      Seen[FVacuumAreas[I]] := True;
      Queue[Tail] := FVacuumAreas[I];
      Inc(Tail);
    end;
  Head := 0;
  while Head < Tail do
  begin
    A := Queue[Head];
    Inc(Head);
    if A = Area then
      Exit(True);
    for P := 0 to Portals.PortalCount - 1 do
    begin
      if FVacuumBlocked[P] or Portals.PortalClosed[P] then
        Continue;
      if Portals.PortalArea(P, 0) = A then
        Other := Portals.PortalArea(P, 1)
      else
      if Portals.PortalArea(P, 1) = A then
        Other := Portals.PortalArea(P, 0)
      else
        Continue;
      if (Other < 0) or (Other >= Portals.AreaCount) or Seen[Other] then
        Continue;
      Seen[Other] := True;
      Queue[Tail] := Other;
      Inc(Tail);
    end;
  end;
end;

procedure TD3Game.UpdateAir(const SecondsPassed: Single);
var
  NewAirless: Boolean;
  Def: TStringList;
  Delay: Single;
begin
  { idPlayer::UpdateAir }
  if PlayerDead or (Length(FVacuumAreas) = 0) then
    Exit;
  if FTime >= FAirCheckTime then
  begin
    FAirCheckTime := FTime + 0.25;
    FAirCheckResult := AreaInVacuum(FMap.AreaAt(FPlayerEye));
  end;
  NewAirless := FAirCheckResult and not PowerUpActive(PowerupEnvirotime);
  if NewAirless then
  begin
    if not FAirless then
    begin
      PlayerSound('snd_decompress');
      FAirEvent := 'noAir';
      WritelnLog('Doom3World', 'Player in a vacuum (air %d%%)', [AirPercent]);
    end;
    { a tic is 1 / 60 s }
    FAirTics := FAirTics - SecondsPassed * 60;
    if FAirTics < 0 then
    begin
      FAirTics := 0;
      Def := Decls.EntityDef('damage_noair');
      Delay := 3;
      if Def <> nil then
        Delay := StrToFloatDef(Def.Values['delay'], 3, DefaultFormatSettings);
      if FTime > FLastAirDamage + Delay then
      begin
        FLastAirDamage := FTime;
        WritelnLog('Doom3World', 'Player out of air (damage_noair)', []);
        if Def <> nil then
          DamagePlayer(StrToIntDef(Def.Values['damage'], 10), 'damage_noair', TVector3.Zero)
        else
          DamagePlayer(10);
      end;
    end;
  end else
  begin
    if FAirless then
    begin
      PlayerSound('snd_recompress');
      FAirEvent := 'Air';
      WritelnLog('Doom3World', 'Player has air again (air %d%%)', [AirPercent]);
    end;
    { regained twice as fast as lost }
    FAirTics := Min(AirTicsMax, FAirTics + SecondsPassed * 120);
  end;
  FAirless := NewAirless;
end;

function TD3Game.AirPercent: Integer;
begin
  Result := Round(100 * FAirTics / AirTicsMax);
end;

function TD3Game.TakeAirEvent: String;
begin
  Result := FAirEvent;
  FAirEvent := '';
end;

{ Harvesting ----------------------------------------------------------------- }

{ idHarvestable (the body's "def_harvest_type"): the player with the
  artifact ("required_weapons") within "triggersize" takes its soul: the
  artifact's ammo ("give_item" / "give_value"), the fx, the weapon's Charge
  state; the body is gone "remove_delay" seconds later. }
procedure TD3Game.UpdateHarvest(const M: TD3MiscEntity);
var
  E: TD3MapEntity;
  Def: TStringList;
  ME: TD3ModelEntity;
  Names: TStringArray;
  Pos: TVector3;
  I: Integer;
  Has: Boolean;
begin
  E := M.Entity;
  ME := FMap.FindModelEntity(E.Name);
  if M.Dead then
  begin
    if (M.ShowTime > 0) and (FTime >= M.ShowTime) then
    begin
      M.ShowTime := 0;
      if ME <> nil then
      begin
        ME.Hidden := True;
        ME.Holder.Exists := False;
      end;
    end;
    Exit;
  end;
  if PlayerDead or (FTime < M.NextTime) then
    Exit;
  { not every frame }
  M.NextTime := FTime + 0.2;
  if (ME <> nil) and ME.Hidden then
    Exit;
  Def := Decls.EntityDef(E.Value('def_harvest_type', 'env_harvest_default'));
  if Def = nil then
    Exit;
  Pos := D3ToCge(E.Origin);
  if (ME <> nil) and not ME.Holder.BoundingBox.IsEmpty then
    Pos := ME.Holder.BoundingBox.Center;
  if (Pos - PlayerFeet).Length > StrToFloatDef(Def.Values['triggersize'], 40, DefaultFormatSettings) + 24 then
    Exit;
  Has := False;
  Names := Def.Values['required_weapons'].Split([',']);
  for I := 0 to High(Names) do
    if (WeaponSlot(Trim(Names[I])) >= 0) and HasWeapon(WeaponSlot(Trim(Names[I]))) then
      Has := True;
  if not Has then
    Exit;
  M.Dead := True;
  M.ShowTime := FTime + StrToFloatDef(Def.Values['remove_delay'], 3, DefaultFormatSettings);
  if Def.Values['give_item'] <> '' then
    Give(Def.Values['give_item'], Def.Values['give_value']);
  if Def.Values['fx'] <> '' then
    StartFx(Def.Values['fx'], CgeToD3(Pos), E.Rotation, E);
  PlaySoundAt(E.Value(E.Value('harvest_sound', 'snd_harvest_whisper')), Pos);
  WritelnLog('Doom3World', 'Harvested %s (%s %s)', [E.Name, Def.Values['give_item'], Def.Values['give_value']]);
  { the artifact in the hand absorbs it (weapon_bloodstone_passive::Charge) }
  if (FWeapon <> nil) and FWeapon.Scripted and (FWeapon.Obj <> nil) and
     (FWeapon.Obj.Typ.FindMethodToRun('Charge') <> nil) then
  begin
    FWeapon.IdealFunction := FWeapon.Obj.Typ.FindMethodToRun('Charge');
    FWeapon.IdealName := 'Charge';
    FWeapon.HasIdeal := True;
  end;
end;

{ Hell time ------------------------------------------------------------------ }

function TD3Game.WorldTimeScale: Single;
begin
  { idGameLocal's slow motion (g_enableSlowmo): everything but the player
    and the weapon runs 4 times slower }
  if PowerUpActive(PowerupHelltime) then
    Result := 0.25
  else
    Result := 1;
end;

{ The grabber ---------------------------------------------------------------- }

{ idGrabber::Update: 0 nothing in reach, 1 something to grab, 2 holding
  it, 3 just thrown. }
function TD3Game.UpdateGrabber: Integer;
const
  { Grabber.cpp: the reach, where the thing is held in front of the eye,
    the longest hold (g_grabberHoldSeconds) and the pause after a throw }
  HoldDistance = 72;
  HoldSeconds = 3;
  FiringDelay = 1;
  ThrowSpeed = 900;
var
  Axis: TMatrix3;
  Fwd, Eye, Goal, Center, Dir: TVector3;
  M, Best: TD3Moveable;
  Along, Off, BestAlong: Single;
  Held, WasPickable, Visible: Boolean;
begin
  if (FGrabFired > 0) and (FTime < FGrabFired + FiringDelay) then
    Exit(3);
  if not FGrabEnabled or PlayerDead or (FWeapon = nil) then
  begin
    FGrabbed := nil;
    Exit(0);
  end;
  Axis := PlayerViewAxis;
  Fwd := Vector3(Axis.Data[0, 0], Axis.Data[0, 1], Axis.Data[0, 2]);
  Eye := CgeToD3(FPlayerEye);
  Held := FWeapon.Flag('WEAPON_ATTACK');
  if (FGrabbed <> nil) and (FGrabbed.Brush.Hidden or (FMoveables.IndexOf(FGrabbed) < 0)) then
    FGrabbed := nil;
  if FGrabbed = nil then
  begin
    { the nearest moveable along the view, within the reach }
    Best := nil;
    BestAlong := FGrabDistance;
    for M in FMoveables do
    begin
      if M.Brush.Hidden or (M.Brush.Scene = nil) or (FindBinding(M.Brush.Scene) <> nil) or
         M.Brush.Scene.BoundingBox.IsEmpty or M.Brush.Entity.BoolValue('notPushable') then
        Continue;
      Center := CgeToD3(M.Brush.Scene.BoundingBox.Center);
      Along := TVector3.DotProduct(Center - Eye, Fwd);
      if (Along <= 8) or (Along >= BestAlong) then
        Continue;
      Off := ((Center - Eye) - Fwd * Along).Length;
      if Off > Max(12, M.HalfSize.Length) then
        Continue;
      { nothing between the eye and it (it is pickable itself) }
      WasPickable := M.Brush.Scene.Pickable;
      M.Brush.Scene.Pickable := False;
      try
        Visible := CanSee(FPlayerEye, D3ToCge(Center));
      finally
        M.Brush.Scene.Pickable := WasPickable;
      end;
      if not Visible then
        Continue;
      Best := M;
      BestAlong := Along;
    end;
    if Best = nil then
      Exit(0);
    if not Held then
      Exit(1);
    FGrabbed := Best;
    FGrabStart := FTime;
    WritelnLog('Doom3World', 'Grabber holds %s', [Best.Brush.Entity.Name]);
    Exit(2);
  end;
  Center := CgeToD3(FGrabbed.Brush.Scene.BoundingBox.Center);
  if not Held or (FTime > FGrabStart + HoldSeconds) then
  begin
    { thrown along the view; it hurts what it hits for a while }
    FGrabbed.Velocity := Fwd * ThrowSpeed;
    FGrabbed.AtRest := False;
    FGrabbed.CanDamage := True;
    FGrabbed.DamageUntil := FTime + 2.5;
    FGrabbed.ThrownUntil := FTime + 2.5;
    WritelnLog('Doom3World', 'Grabber throws %s', [FGrabbed.Brush.Entity.Name]);
    FGrabbed := nil;
    FGrabFired := FTime;
    Exit(3);
  end;
  { held: pulled to the point in front of the eye }
  Goal := Eye + Fwd * HoldDistance;
  Dir := Goal - Center;
  FGrabbed.Velocity := Dir * 10;
  FGrabbed.AtRest := False;
  Result := 2;
end;

{ Moveables the player threw (the grabber) hurt the monsters they hit. }
procedure TD3Game.UpdateThrownMoveables;
var
  M: TD3Moveable;
  Mon: TD3Monster;
  Center: TVector3;
  DefName: String;
  Def: TStringList;
  Damage: Integer;
begin
  for M in FMoveables do
  begin
    if (M.ThrownUntil <= 0) or (FTime > M.ThrownUntil) or M.AtRest or M.Brush.Hidden or
       (M.Velocity.Length < 100) then
      Continue;
    Center := M.Brush.Scene.BoundingBox.Center;
    for Mon in FMonsters do
    begin
      if (Mon.State = msDead) or not Mon.Model.Holder.Exists then
        Continue;
      if (Mon.Center - Center).Length > Mon.Radius + M.HalfSize.Length then
        Continue;
      { idMoveable::Collide: "monster_damage" of the moveable, else its
        def_damage }
      DefName := M.Brush.Entity.Value('monster_damage', M.DamageDef);
      Def := Decls.EntityDef(DefName);
      Damage := 20;
      if Def <> nil then
        Damage := StrToIntDef(Def.Values['damage'], 20);
      WritelnLog('Doom3World', '%s hits %s (%s, %d)', [M.Brush.Entity.Name, Mon.Model.Entity.Name, DefName, Damage]);
      DamageMonster(Mon, Damage, DefName, D3ToCge(M.Velocity));
      M.ThrownUntil := 0;
      M.Velocity := M.Velocity * (-M.Bounce);
      Break;
    end;
  end;
end;

{ Script events -------------------------------------------------------------- }

function TD3Game.MiscScriptEvent(const Thread: TD3ScriptThread; const Target: Integer; const N: String;
  const Args: TD3ValueArray; var EventResult: TD3Value): Boolean;
var
  E, Other: TD3MapEntity;
  B: TD3BrushEntity;
  GS: TD3GuiSurface;
  Light, I: Integer;
  V, Dir, Normal: TVector3;
  Dist, Len: Single;
  Key, S: String;
  Def: TStringList;

  function ArgF(const Index: Integer): Single;
  begin
    Result := D3ValueToFloat(Args[Index]);
  end;

  function ArgStr(const Index: Integer): String;
  begin
    Result := D3ValueToString(Args[Index]);
  end;

begin
  Result := True;

  if Target = 0 then
  begin
    case N of
      'isMultiplayer', 'isClient': EventResult := D3FloatValue(0);
      'acos': EventResult := D3FloatValue(RadToDeg(ArcCos(EnsureRange(ArgF(0), -1, 1))));
      'trace', 'tracePoint':
        begin
          { sys.trace( start, end, mins, maxs, contents, pass ): a ray here
            (the box isn't swept); the fraction that was free }
          V := Args[0].V;
          Dir := Args[1].V - V;
          Len := Dir.Length;
          FTraceFraction := 1;
          FTraceEnd := Args[1].V;
          FTraceNormal := TVector3.Zero;
          if (Len > 0.01) and WorldHit(D3ToCge(V), D3ToCge(Dir / Len), Len, Dist, Normal) then
          begin
            FTraceFraction := EnsureRange(Dist / Len, 0, 1);
            FTraceEnd := V + Dir * FTraceFraction;
            FTraceNormal := CgeToD3(Normal);
          end;
          EventResult := D3FloatValue(FTraceFraction);
        end;
      'getTraceFraction': EventResult := D3FloatValue(FTraceFraction);
      'getTraceEndPos': EventResult := D3VectorValue(FTraceEnd);
      'getTraceNormal': EventResult := D3VectorValue(FTraceNormal);
      'getTraceEntity': EventResult := D3EntityValue(0);
      'getTraceJoint', 'getTraceBody': EventResult := D3StringValue('');
      'radiusDamage':
        { sys.radiusDamage( origin, inflictor, attacker, ignore, damageDef, scale ) }
        if High(Args) >= 4 then
          SplashAt(D3ToCge(Args[0].V), ArgStr(4), 'script', nil);
      'setSpawnArg':
        FSpawnArgs.Values[ArgStr(0)] := ArgStr(1);
      'copySpawnArgs':
        begin
          Other := HandleEntity(Args[0].E);
          if Other <> nil then
            for I := 0 to Other.Pairs.Count - 1 do
              FSpawnArgs.Values[Other.Pairs.Names[I]] := Other.Pairs.ValueFromIndex[I];
        end;
      'spawn':
        begin
          { sys.spawn( classname ) with the setSpawnArg arguments: the
            entity exists for scripts and activation (targets, explosions,
            relays...); models, lights and AI aren't made at run time }
          if FMap.MapFile = nil then
            Exit(False);
          Other := TD3MapEntity.Create;
          Other.SetValue('classname', ArgStr(0));
          for I := 0 to FSpawnArgs.Count - 1 do
            Other.SetValue(FSpawnArgs.Names[I], FSpawnArgs.ValueFromIndex[I]);
          FSpawnArgs.Clear;
          if Other.Name = '' then
            Other.SetValue('name', Format('%s_spawned_%d', [ArgStr(0), FMap.MapFile.Entities.Count]));
          FMap.MapFile.Entities.Add(Other);
          FEntities.AddOrSetValue(LowerCase(Other.Name), Other);
          FHandles.AddOrSetValue(LowerCase(Other.Name), FMap.MapFile.Entities.Count);
          EventResult := D3EntityValue(FMap.MapFile.Entities.Count);
          Unsupported('sys.spawn of ' + ArgStr(0) + ' (the entity exists for scripts; no model, light or AI is made)');
        end;
      'onSignal', 'clearSignalThread', 'clearSignal':
        { signals (a blocked mover...) aren't raised here: the threads
          they would start never run };
      'toggleBloom', 'setBloomParms':
        { d3xp's bloom post process isn't done };
      else
        Result := False;
    end;
    Exit;
  end;

  if Target = WeaponHandle then
  begin
    if FWeapon = nil then
      Exit(False);
    case N of
      'launchPowerup':
        begin
          { idWeapon::Event_LaunchPowerup( name, duration, useAmmo ) }
          if ArgF(2) <> 0 then
          begin
            if HasAmmo(FWeapon.AmmoType, FWeapon.AmmoRequired) = 0 then
              Exit;
            UseAmmo(FWeapon.AmmoType, FWeapon.AmmoRequired);
          end;
          Give(ArgStr(0), FloatToStr(ArgF(1), DefaultFormatSettings));
        end;
      'grabber':
        begin
          FGrabEnabled := ArgF(0) <> 0;
          if not FGrabEnabled then
            FGrabbed := nil;
        end;
      'grabberHasTarget': EventResult := D3FloatValue(UpdateGrabber);
      'grabberGrabDistance': FGrabDistance := ArgF(0);
      'startWeaponParticle', 'stopWeaponParticle', 'startWeaponLight', 'stopWeaponLight',
      'startWeaponSmoke', 'stopWeaponSmoke':
        { the weapon's own emitters and lights (def keys) aren't done };
      else
        Result := False;
    end;
    Exit;
  end;

  if Target = PlayerHandle then
  begin
    case N of
      'getCurrentWeapon', 'getIdealWeapon':
        begin
          S := '';
          if (N = 'getIdealWeapon') and (FIdealSlot >= 0) and (FIdealSlot <= High(WeaponDefs)) then
            S := WeaponDefs[FIdealSlot]
          else
          if FWeapon <> nil then
            S := FWeapon.DefName;
          EventResult := D3StringValue(S);
        end;
      'getPreviousWeapon': EventResult := D3StringValue(FPreviousWeaponName);
      'getWeaponEntity': EventResult := D3EntityValue(WeaponHandle);
      'weaponAvailable':
        EventResult := D3FloatValue(Ord((WeaponSlot(ArgStr(0)) >= 0) and HasWeapon(WeaponSlot(ArgStr(0)))));
      'isPowerupActive': EventResult := D3FloatValue(Ord(PowerUpActive(Round(ArgF(0)))));
      'setPowerupTime':
        if (Round(ArgF(0)) >= Low(FPowerupEnd)) and (Round(ArgF(0)) <= High(FPowerupEnd)) then
          FPowerupEnd[Round(ArgF(0))] := FTime + ArgF(1) / 1000;
      'stopHelltime': FPowerupEnd[PowerupHelltime] := 0;
      'giveInventoryItem': GiveItemDef(ArgStr(0));
      'removeInventoryItem':
        begin
          Def := Decls.EntityDef(ArgStr(0));
          S := ArgStr(0);
          if Def <> nil then
            S := D3LangString(Def.Values['inv_name']);
          I := FCarried.IndexOf(S);
          if I >= 0 then
            FCarried.Delete(I);
        end;
      'getViewAngles':
        begin
          { pitch, yaw, roll of the view }
          V := PlayerViewAxis.Rows[0];
          EventResult := D3VectorValue(Vector3(
            -RadToDeg(ArcTan2(V.Z, Sqrt(Sqr(V.X) + Sqr(V.Y)))), RadToDeg(ArcTan2(V.Y, V.X)), 0));
        end;
      'getButtons': EventResult := D3FloatValue(Ord(Attack));
      'inPDA': EventResult := D3FloatValue(0);
      'touches':
        begin
          { the player in a trigger's volume (d3xp's bloodstone walls) }
          Other := HandleEntity(Args[0].E);
          EventResult := D3FloatValue(0);
          if Other <> nil then
            for I := 0 to FTriggers.Count - 1 do
              if (FTriggers[I].Entity = Other) and
                 FTriggers[I].Box.Contains(PlayerFeet + Vector3(0, 8, 0)) then
                EventResult := D3FloatValue(1);
        end;
      'setDamageCap', 'hideTip', 'activateTargets', 'enableEyeFocus', 'disableEyeFocus':
        ;
      else
        Result := False;
    end;
    Exit;
  end;

  E := HandleEntity(Target);
  if E = nil then
    Exit(False);
  Light := FMap.FindLight(E.Name);
  B := FMap.FindBrush(E.Name);
  case N of
    'getColor':
      if Light >= 0 then
        EventResult := D3VectorValue(Vector3(FMap.Light(Light).Parms.Parms[0],
          FMap.Light(Light).Parms.Parms[1], FMap.Light(Light).Parms.Parms[2]))
      else
      if B <> nil then
        EventResult := D3VectorValue(Vector3(B.Parms.Parms[0], B.Parms.Parms[1], B.Parms.Parms[2]))
      else
        EventResult := D3VectorValue(E.VectorValue('_color', Vector3(1, 1, 1)));
    'setGui':
      begin
        { setGui( n, gui ): the entity's gui / gui2 / gui3 }
        if Round(ArgF(0)) <= 1 then
          Key := 'gui'
        else
          Key := 'gui' + IntToStr(Round(ArgF(0)));
        if (E.Value(Key) <> '') and not SameText(E.Value(Key), ArgStr(1)) then
        begin
          FMap.ReplaceGui(E.Name, E.Value(Key), ArgStr(1), E.Pairs);
          E.SetValue(Key, ArgStr(1));
        end;
      end;
    'guiNamedEvent':
      for GS in FMap.GuiSurfaces do
        if SameText(GS.EntityName, E.Name) then
        begin
          GS.Gui.Update(Round(FMap.Time * 1000));
          GS.Gui.NamedEvent(ArgStr(1));
        end;
    'activateTargets': ActivateTargets(E, 0);
    'getMins':
      if B <> nil then
        EventResult := D3VectorValue(B.LocalMin);
    'getMaxs':
      if B <> nil then
        EventResult := D3VectorValue(B.LocalMax);
    'distanceToPoint': EventResult := D3FloatValue((EntityOriginNow(E) - Args[0].V).Length);
    'setAnimation':
      if FindAnimated(E) <> nil then
        PlayAnimatedAnim(FindAnimated(E), ArgStr(0))
      else
        Result := False;
    'setOwner', 'setGuiStates', 'precacheGui':
      ;
    { entities without a mover or a model: where the map has them }
    'getOrigin', 'getWorldOrigin': EventResult := D3VectorValue(EntityOriginNow(E));
    'getAngles': EventResult := D3VectorValue(Vector3(0, E.Angle, 0));
    'On', 'Off':
      begin
        { idTrigger's On / Off }
        Result := False;
        for I := 0 to FTriggers.Count - 1 do
          if FTriggers[I].Entity = E then
          begin
            FTriggers[I].Disabled := N = 'Off';
            Result := True;
          end;
      end;
    else
      Result := False;
  end;
end;
