{ Part of Doom3World (TD3Game): the smaller entity classes of Doom 3's
  Misc.cpp, Moveable.cpp, BrittleFracture.cpp and Mover.cpp, kept as
  TD3MiscEntity records: exploding barrels, breakable glass, damagables,
  force fields, shaking entities, earthquakes, activators, shockwaves;
  and the ones that only act when activated (explosions, item removers,
  teleporters, splats...). }

{ The world box (CGE) of an entity's collision model (brush triggers,
  force fields), placed at its origin and rotated. }
function TD3Game.CmBox(const E: TD3MapEntity; out Box: TBox3D): Boolean;
var
  Model: TD3CollisionModel;
  Rot: TMatrix3;
  V, W, BoxMin, BoxMax: TVector3;
  I, J: Integer;
begin
  Result := False;
  Box := TBox3D.Empty;
  if FMap.Collision = nil then
    Exit;
  Model := FMap.Collision.FindModel(E.Value('model', E.Name));
  if (Model = nil) or (Length(Model.Vertices) = 0) then
    Exit;
  Rot := E.Rotation;
  BoxMin := Vector3(MaxSingle, MaxSingle, MaxSingle);
  BoxMax := -BoxMin;
  for I := 0 to High(Model.Vertices) do
  begin
    V := Model.Vertices[I];
    W := E.Origin + Vector3(
      V.X * Rot.Data[0, 0] + V.Y * Rot.Data[1, 0] + V.Z * Rot.Data[2, 0],
      V.X * Rot.Data[0, 1] + V.Y * Rot.Data[1, 1] + V.Z * Rot.Data[2, 1],
      V.X * Rot.Data[0, 2] + V.Y * Rot.Data[1, 2] + V.Z * Rot.Data[2, 2]);
    W := D3ToCge(W);
    for J := 0 to 2 do
    begin
      BoxMin.Data[J] := Min(BoxMin.Data[J], W.Data[J]);
      BoxMax.Data[J] := Max(BoxMax.Data[J], W.Data[J]);
    end;
  end;
  Box := Box3D(BoxMin, BoxMax);
  Result := True;
end;

function TD3Game.MiscOf(const E: TD3MapEntity): TD3MiscEntity;
begin
  for Result in FMisc do
    if Result.Entity = E then
      Exit;
  Result := nil;
end;

function TD3Game.SecurityCameraView(const E: TD3MapEntity; out Rot: TMatrix3; out FovY: Single): Boolean;
var
  M: TD3MiscEntity;
begin
  Result := False;
  Rot := TMatrix3.Identity;
  FovY := 0;
  M := MiscOf(E);
  if (M = nil) or (M.Kind <> ekSecurityCamera) then
    Exit;
  Rot := AnglesMatrix(M.CamAngles);
  FovY := E.FloatValue('scanFov', 90);
  Result := True;
end;

procedure TD3Game.SpawnMisc(const E: TD3MapEntity);
var
  SC: String;
  M: TD3MiscEntity;
  B: TD3BrushEntity;
  Em: TD3EmitterEntity;
  V: TVector3;

  function NewMisc(const Kind: TD3MiscKind): TD3MiscEntity;
  begin
    Result := TD3MiscEntity.Create;
    Result.Entity := E;
    Result.Brush := B;
    Result.Kind := Kind;
    FMisc.Add(Result);
  end;

begin
  if TDoom3Map.EntityInhibited(E) then
    Exit;
  SC := E.Value('spawnclass');
  B := FMap.FindBrush(E.Name);
  if (SC = 'idExplodingBarrel') or (SC = 'idBarrel') then
  begin
    { idBarrel is an idMoveable (its rolling isn't done) }
    if B = nil then
      Exit;
    if MoveableOf(E) = nil then
      SpawnMoveable(B);
    if SC = 'idExplodingBarrel' then
    begin
      M := NewMisc(ekBarrel);
      M.Health := E.IntValue('health', 5);
    end;
  end else
  if SC = 'idBrittleFracture' then
  begin
    if B = nil then
      Exit;
    M := NewMisc(ekFracture);
    M.Health := E.IntValue('health', 0);
    { "disableFracture": shots don't break it until it is activated }
    M.On := not E.BoolValue('disableFracture');
  end else
  if SC = 'idDamagable' then
  begin
    if B = nil then
      Exit;
    M := NewMisc(ekDamagable);
    M.Health := E.IntValue('health', 5);
    M.Count := E.IntValue('count', 1);
  end else
  if SC = 'idForceField' then
  begin
    M := NewMisc(ekForceField);
    if not CmBox(E, M.Box) and (B <> nil) then
      M.Box := MoverBounds(B);
    if M.Box.IsEmpty then
    begin
      FMisc.Remove(M);
      Exit;
    end;
    { idForceField::Spawn: "uniform" (a direction and strength),
      "explosion" / "implosion" (away from / towards its center) }
    V := E.VectorValue('uniform', TVector3.Zero);
    if not V.IsZero then
    begin
      M.Mode := 0;
      M.Force := V;
    end else
    if E.FloatValue('explosion', 0) <> 0 then
    begin
      M.Mode := 1;
      M.Force := Vector3(E.FloatValue('explosion', 0), 0, 0);
    end else
    begin
      M.Mode := 2;
      M.Force := Vector3(E.FloatValue('implosion', 0), 0, 0);
    end;
    M.On := E.BoolValue('start_on');
    { a force field isn't drawn and doesn't block }
    if B <> nil then
      B.SetHidden(True);
  end else
  if SC = 'idShaking' then
  begin
    { (a brush, a static model or an md5 model) }
    if TransformOf(E.Name) = nil then
      Exit;
    M := NewMisc(ekShaking);
    M.Shaken := TransformOf(E.Name);
    M.BaseRotation := M.Shaken.Rotation;
    if M.BaseRotation.XYZ.IsZero then
      M.BaseRotation := Vector4(0, 1, 0, 0);
    M.Force := E.VectorValue('shake', Vector3(0.5, 0.5, 0.5));
    M.Phase := Random * 1000;
    M.On := not E.BoolValue('start_off');
  end else
  if SC = 'idEarthQuake' then
  begin
    M := NewMisc(ekEarthQuake);
    { not "triggered": it quakes by itself every wait +- random seconds }
    M.On := not E.BoolValue('triggered', True);
    if M.On then
      M.NextTime := FTime + E.FloatValue('wait', 15);
  end else
  if SC = 'idActivator' then
  begin
    M := NewMisc(ekActivator);
    M.On := not E.BoolValue('start_off');
  end else
  if SC = 'idShockwave' then
  begin
    M := NewMisc(ekShockwave);
    if E.BoolValue('start_on') then
    begin
      M.On := True;
      M.StartTime := FTime;
    end;
  end else
  if SC = 'idAFEntity_Harvest' then
    { d3xp: a body whose soul the artifact takes (idHarvestable) }
    NewMisc(ekHarvest)
  else
  if SC = 'idSecurityCamera' then
  begin
    { idSecurityCamera::Spawn: it sweeps its yaw back and forth by
      "sweepAngle" (negative: the other way first) and watches }
    if (B = nil) or (B.Scene = nil) then
      Exit;
    M := NewMisc(ekSecurityCamera);
    M.Health := E.IntValue('health', 100);
    D3PlacementFromMatrix(B.Scene.Transform, V, M.CamAngles);
    M.CamYaw := M.CamAngles.Y;
    M.CamNegative := E.FloatValue('sweepAngle', 90) < 0;
    CameraStartSweep(M);
  end else
  if (SC = 'idFuncSmoke') and (E.Value('smoke') <> '') then
  begin
    { idFuncSmoke: its "smoke" particle from its origin, toggled like an
      emitter }
    Em := TD3EmitterEntity.Create;
    Em.Entity := E;
    Em.Emitter := AddEmitter(E.Value('smoke'), E.Origin, E.Rotation, False, E.Name);
    if Em.Emitter = nil then
    begin
      Em.Free;
      Exit;
    end;
    Em.Emitter.Persistent := True;
    Em.On := not E.BoolValue('start_off');
    Em.Emitter.Enabled := Em.On;
    FEmitterEntities.Add(Em);
  end;
end;

{ func_plat (idPlat): rests at the bottom ("height" below where the map
  has it, else its own height minus "lip"), goes up when the player
  stands on it, waits and comes back: a door that opens upwards. }
procedure TD3Game.SpawnPlat(const B: TD3BrushEntity);
var
  E: TD3MapEntity;
  M: TD3Mover;
  Box: TBox3D;
  Height, Shrink: Single;
  BoxMin, BoxMax: TVector3;
begin
  E := B.Entity;
  Box := MoverBounds(B);
  if Box.IsEmpty then
    Exit;
  Height := E.FloatValue('height', 0);
  if Height = 0 then
    Height := Box.Size.Y - E.FloatValue('lip', 8);
  if Height <= 0 then
    Exit;
  M := TD3Mover.Create;
  M.Brush := B;
  M.Kind := mkDoor;
  M.MoveDir := Vector3(0, 1, 0);
  M.Distance := Height;
  M.ClosedPos := B.Scene.Translation - M.MoveDir * Height;
  B.Scene.Translation := M.ClosedPos;
  { idPlat::Spawn: "time" (1 by default) wins over "speed" }
  if E.FloatValue('time', 1) > 0 then
    M.Speed := Height / E.FloatValue('time', 1)
  else
    M.Speed := E.FloatValue('speed', 100);
  M.Wait := E.FloatValue('wait', 1);
  M.NoTouch := E.BoolValue('no_touch');
  M.Team := LowerCase(E.Value('team'));
  { idPlat::SpawnPlatTrigger: its bounds at the bottom, 33 in from the
    sides (when it is wide enough), 8 above }
  BoxMin := Box.Data[0] - M.MoveDir * Height;
  { (doors test the player's eye: up to it) }
  BoxMax := Box.Data[1] - M.MoveDir * Height + Vector3(0, 8 + 80, 0);
  Shrink := 33;
  if BoxMax.X - BoxMin.X > 2 * Shrink + 2 then
  begin
    BoxMin.X := BoxMin.X + Shrink;
    BoxMax.X := BoxMax.X - Shrink;
  end;
  if BoxMax.Z - BoxMin.Z > 2 * Shrink + 2 then
  begin
    BoxMin.Z := BoxMin.Z + Shrink;
    BoxMax.Z := BoxMax.Z - Shrink;
  end;
  M.TriggerBox := Box3D(BoxMin, BoxMax);
  M.TriggerBoxBase := M.TriggerBox;
  M.SoundOpen := SoundFromShader(E.Value('snd_open'));
  M.SoundClose := SoundFromShader(E.Value('snd_close'));
  if (M.SoundOpen <> nil) or (M.SoundClose <> nil) then
  begin
    M.Sounds := TCastleSoundSource.Create(B.Scene);
    M.Sounds.Spatial := True;
    B.Scene.AddBehavior(M.Sounds);
  end;
  FMovers.Add(M);
  WritelnLog('Doom3World', 'Plat %s: %.0f units up in %.1f s', [E.Name, Height, Height / Max(1, M.Speed)]);
end;

{ idGameLocal::RadiusDamage of a damage def ("damage", "radius", "push")
  at a CGE position: the player, monsters, moveables and the damageable
  entities (but Skip, the one exploding). }
procedure TD3Game.SplashAt(const Position: TVector3; const DefName, Who: String; const Skip: TD3MiscEntity);
var
  Def: TStringList;
  Damage: Integer;
  Radius, Push: Single;
begin
  Def := Decls.EntityDef(DefName);
  if Def = nil then
    Exit;
  Damage := StrToIntDef(Def.Values['damage'], 20);
  Radius := StrToFloatDef(Def.Values['radius'], 50, DefaultFormatSettings);
  Push := StrToFloatDef(Def.Values['push'], 0, DefaultFormatSettings);
  RadiusDamage(Position, Position, Damage, Radius, Who, DefName);
  MonsterSplash(Position, Damage, Radius, DefName);
  if Push > 0 then
    PushMoveablesInRadius(Position, Radius, Push);
  DamageMiscInRadius(Position, Radius, Damage, DefName, Skip);
end;

function TD3Game.DamageMiscAt(const Point: TVector3; const Damage: Integer; const DefName: String): Boolean;
var
  M: TD3MiscEntity;
begin
  Result := False;
  for M in FMisc do
    if (M.Kind in [ekBarrel, ekFracture, ekDamagable, ekSecurityCamera]) and not M.Dead and (M.Brush <> nil) and
       not M.Brush.Hidden and M.Brush.Scene.BoundingBox.Grow(2).Contains(Point) then
    begin
      M.HitPoint := Point;
      M.HitDir := Point - FPlayerEye;
      if not M.HitDir.IsZero then
        M.HitDir := M.HitDir.Normalize;
      DamageMisc(M, Damage, DefName);
      Exit(True);
    end;
end;

procedure TD3Game.DamageMiscInRadius(const Position: TVector3; const Radius: Single; const Damage: Integer;
  const DefName: String; const Skip: TD3MiscEntity);
var
  M: TD3MiscEntity;
  Box: TBox3D;
  Closest: TVector3;
  Dist: Single;
  I: Integer;
begin
  if (Radius <= 0) or (Damage <= 0) then
    Exit;
  for M in FMisc do
  begin
    if (M = Skip) or M.Dead or not (M.Kind in [ekBarrel, ekFracture, ekDamagable, ekSecurityCamera]) or
       (M.Brush = nil) or M.Brush.Hidden then
      Continue;
    Box := M.Brush.Scene.BoundingBox;
    if Box.IsEmpty then
      Continue;
    for I := 0 to 2 do
      Closest.Data[I] := EnsureRange(Position.Data[I], Box.Data[0].Data[I], Box.Data[1].Data[I]);
    Dist := (Closest - Position).Length;
    if Dist < Radius then
    begin
      M.HitPoint := Closest;
      M.HitDir := TVector3.Zero;
      DamageMisc(M, Max(1, Round(Damage * (1 - Dist / Radius))), DefName);
    end;
  end;
end;

procedure TD3Game.DamageMisc(const M: TD3MiscEntity; const Damage: Integer; const DefName: String);
var
  Def: TStringList;
begin
  if M.Dead then
    Exit;
  case M.Kind of
    ekBarrel:
      begin
        { idExplodingBarrel::Damage: a radius damage (another explosion)
          sets it off 0.4 s later, the chain reaction }
        Def := Decls.EntityDef(DefName);
        if (Def <> nil) and (Def.Values['radius'] <> '') then
        begin
          if M.ExplodeTime = 0 then
            M.ExplodeTime := FTime + 0.4;
        end else
        begin
          Dec(M.Health, Damage);
          if M.Health <= 0 then
            KillMisc(M);
        end;
      end;
    ekFracture:
      if M.On then
      begin
        Dec(M.Health, Damage);
        if M.Health <= 0 then
          KillMisc(M);
      end;
    ekDamagable:
      if FTime >= M.NextTime then
      begin
        Dec(M.Health, Damage);
        if M.Health <= 0 then
          KillMisc(M);
      end;
    ekSecurityCamera:
      if M.Health > 0 then
      begin
        Dec(M.Health, Damage);
        if M.Health <= 0 then
          KillMisc(M);
      end;
  end;
end;

{ idSecurityCamera ------------------------------------------------------------ }

procedure TD3Game.CameraSetAlert(const M: TD3MiscEntity; const Mode: Integer);
begin
  { SetAlertMode: shaderParm7 (SHADERPARM_MODE) shows it on the model }
  M.CamAlert := Mode;
  if M.Brush.Parms <> nil then
    M.Brush.Parms.Parms[7] := Mode;
end;

procedure TD3Game.CameraStartSweep(const M: TD3MiscEntity);
begin
  { StartSweep: "sweepSpeed" seconds a sweep, then a pause }
  M.CamSweeping := True;
  M.CamSweepStart := FTime;
  M.CamSweepEnd := FTime + Max(0.01, M.Entity.FloatValue('sweepSpeed', 5));
  M.CamEvent := 1;
  M.CamEventTime := M.CamSweepEnd;
  if M.Entity.FloatValue('sweepAngle', 90) <> 0 then
    StartScriptSound(EntityHandle(M.Entity), M.Entity.Value('snd_moving'), 3);
end;

procedure TD3Game.UpdateSecurityCamera(const M: TD3MiscEntity; const Feet: TVector3);
const
  CamScanning = 0;
  CamLosingInterest = 1;
  CamAlertMode = 2;
  CamActivated = 3;
var
  E: TD3MapEntity;
  Handle, ModelAxis: Integer;
  Pos, Dir, Axis: TVector3;
  Rot: TMatrix3;
  Pct, Dist, SweepAngle: Single;
  Sees: Boolean;
begin
  E := M.Entity;
  if CinematicActive or M.Brush.Hidden then
    Exit;
  Handle := EntityHandle(E);
  { the posted events }
  if (M.CamEvent <> 0) and (FTime >= M.CamEventTime) then
  begin
    case M.CamEvent of
      1:
        begin
          { Event_Pause: "sweepWait" seconds, then the other way }
          M.CamSweeping := False;
          StopScriptSound(Handle, 3);
          if E.FloatValue('sweepAngle', 90) <> 0 then
            StartScriptSound(Handle, E.Value('snd_stop'), 3);
          M.CamEvent := 2;
          M.CamEventTime := FTime + E.FloatValue('sweepWait', 0.5);
        end;
      2:
        begin
          { Event_ReverseSweep }
          M.CamYaw := M.CamAngles.Y;
          M.CamNegative := not M.CamNegative;
          CameraStartSweep(M);
        end;
      3:
        begin
          { Event_Alert: it saw the player for "sightTime": its targets,
            then back to sweeping after "wait" }
          CameraSetAlert(M, CamActivated);
          StopScriptSound(Handle, 3);
          StartScriptSound(Handle, E.Value('snd_activate'), 3);
          WritelnLog('Doom3World', 'Security camera %s alerts', [E.Name]);
          M.CamEvent := 4;
          M.CamEventTime := FTime + E.FloatValue('wait', 20);
          ActivateTargets(E, 0);
        end;
      4:
        begin
          { Event_ContinueSweep: the rest of the sweep it stopped in }
          CameraSetAlert(M, CamScanning);
          if M.CamSweepEnd > M.CamSweepStart then
            Pct := (M.CamStopSweeping - M.CamSweepStart) / (M.CamSweepEnd - M.CamSweepStart)
          else
            Pct := 0;
          Pct := EnsureRange(Pct, 0, 1);
          M.CamSweepStart := FTime - Max(0.01, E.FloatValue('sweepSpeed', 5)) * Pct;
          M.CamSweepEnd := M.CamSweepStart + Max(0.01, E.FloatValue('sweepSpeed', 5));
          M.CamSweeping := True;
          M.CamEvent := 1;
          M.CamEventTime := M.CamSweepEnd;
          if E.FloatValue('sweepAngle', 90) <> 0 then
            StartScriptSound(Handle, E.Value('snd_moving'), 3);
        end;
    end;
  end;

  { CanSeePlayer: within scanDist and scanFov of its axis, nothing opaque
    between }
  Sees := False;
  if not NoTarget and not PlayerDead then
  begin
    Pos := M.Brush.Scene.WorldTranslation;
    Dir := CgeToD3(Feet - Pos);
    Dist := Dir.Length;
    if (Dist > 0.01) and (Dist <= E.FloatValue('scanDist', 200)) then
    begin
      Dir := Dir / Dist;
      Rot := AnglesMatrix(M.CamAngles);
      ModelAxis := EnsureRange(E.IntValue('modelAxis', 0), 0, 2);
      Axis := Vector3(Rot.Data[ModelAxis, 0], Rot.Data[ModelAxis, 1], Rot.Data[ModelAxis, 2]);
      if E.BoolValue('flipAxis') then
        Axis := -Axis;
      { the trace skips the camera itself: it starts out of its box }
      if TVector3.DotProduct(Dir, Axis) >= Cos(DegToRad(E.FloatValue('scanFov', 90)) / 2) then
        Sees := CanSee(Pos + (FPlayerEye - Pos).Normalize * (M.Brush.Scene.BoundingBox.Diagonal / 2 + 1),
          FPlayerEye);
    end;
  end;

  if (M.CamAlert = CamLosingInterest) and (M.CamEvent = 0) then
    CameraSetAlert(M, CamScanning);
  if Sees then
  begin
    if M.CamAlert = CamScanning then
    begin
      CameraSetAlert(M, CamAlertMode);
      M.CamStopSweeping := FTime;
      M.CamSweeping := False;
      StopScriptSound(Handle, 3);
      StartScriptSound(Handle, E.Value('snd_sight'), 3);
      WritelnLog('Doom3World', 'Security camera %s sees the player', [E.Name]);
      M.CamEvent := 3;
      M.CamEventTime := FTime + E.FloatValue('sightTime', 5);
    end;
  end else
  begin
    if M.CamAlert = CamAlertMode then
    begin
      CameraSetAlert(M, CamLosingInterest);
      M.CamEvent := 4;
      M.CamEventTime := FTime + E.FloatValue('sightResume', 1.5);
    end;
    if M.CamSweeping then
    begin
      SweepAngle := Abs(E.FloatValue('sweepAngle', 90));
      Pct := EnsureRange((FTime - M.CamSweepStart) / Max(0.001, M.CamSweepEnd - M.CamSweepStart), 0, 1);
      if M.CamNegative then
        M.CamAngles.Y := M.CamYaw + Pct * SweepAngle
      else
        M.CamAngles.Y := M.CamYaw - Pct * SweepAngle;
      if SweepAngle <> 0 then
      begin
        Rot := AnglesMatrix(M.CamAngles);
        SetD3Rotation(M.Brush.Scene, Rot);
      end;
    end;
  end;
end;

{ Shards ---------------------------------------------------------------------- }

type
  { A shape's triangles in world coordinates with their texture
    coordinates, cut until each is at most MaxArea (idBrittleFracture's
    Fracture_r cuts its windings by random planes the same way). }
  TD3ShardCollector = class
    Scene: TCastleScene;
    Pos: array of TTriangle3;
    Tex: array of array [0..2] of TVector2;
    procedure Triangle(Shape: TObject; const Position: TTriangle3;
      const Normal: TTriangle3; const TexCoord: TTriangle4; const Face: TFaceIndex);
    procedure Cut(const MaxArea: Single; const MaxCount: Integer);
  end;

procedure TD3ShardCollector.Triangle(Shape: TObject; const Position: TTriangle3;
  const Normal: TTriangle3; const TexCoord: TTriangle4; const Face: TFaceIndex);
var
  T: TTriangle3;
  I, N: Integer;
begin
  for I := 0 to 2 do
    T.Data[I] := Scene.LocalToWorld(Position.Data[I]);
  N := Length(Pos);
  SetLength(Pos, N + 1);
  SetLength(Tex, N + 1);
  Pos[N] := T;
  for I := 0 to 2 do
    Tex[N][I] := TexCoord.Data[I].XY;
end;

procedure TD3ShardCollector.Cut(const MaxArea: Single; const MaxCount: Integer);
var
  I, Long, A, B, C, N: Integer;
  Len, BestLen, F: Single;
  T: TTriangle3;
  M: TVector3;
  MT: TVector2;
  TT: array [0..2] of TVector2;
begin
  I := 0;
  while (I < Length(Pos)) and (Length(Pos) < MaxCount) do
  begin
    T := Pos[I];
    if T.Area <= MaxArea then
    begin
      Inc(I);
      Continue;
    end;
    { cut the longest edge somewhere near its middle }
    Long := 0;
    BestLen := -1;
    for A := 0 to 2 do
    begin
      Len := PointsDistanceSqr(T.Data[A], T.Data[(A + 1) mod 3]);
      if Len > BestLen then
      begin
        BestLen := Len;
        Long := A;
      end;
    end;
    A := Long;
    B := (Long + 1) mod 3;
    C := (Long + 2) mod 3;
    F := 0.3 + 0.4 * Random;
    M := T.Data[A] + (T.Data[B] - T.Data[A]) * F;
    TT[0] := Tex[I][0]; TT[1] := Tex[I][1]; TT[2] := Tex[I][2];
    MT := TT[A] + (TT[B] - TT[A]) * F;
    { this one keeps A, M, C; a new one M, B, C }
    N := Length(Pos);
    SetLength(Pos, N + 1);
    SetLength(Tex, N + 1);
    Pos[N] := Triangle3(M, T.Data[B], T.Data[C]);
    Tex[N][0] := MT; Tex[N][1] := TT[B]; Tex[N][2] := TT[C];
    Pos[I] := Triangle3(T.Data[A], M, T.Data[C]);
    Tex[I][0] := TT[A]; Tex[I][1] := MT; Tex[I][2] := TT[C];
  end;
end;

destructor TD3Shatter.Destroy;
begin
  if (Scene <> nil) and (Scene.Parent <> nil) then
    Scene.Parent.Remove(Scene);
  FreeAndNil(Scene);
  inherited Destroy;
end;

procedure TD3Game.ShatterFracture(const M: TD3MiscEntity);
const
  { at most this many shards a surface (Doom 3 has no limit: a big pane
    with the default 200 square units makes hundreds) }
  MaxPieces = 600;
  Impulse = 2000;
var
  E: TD3MapEntity;
  Collector: TD3ShardCollector;
  Shapes: TShapeList;
  Shape: TShape;
  Node: TAbstractShapeNode;
  Sh: TD3Shatter;
  Root: TX3DRootNode;
  ShapeNode: TShapeNode;
  Tris: TTriangleSetNode;
  Coord: TCoordinateNode;
  TexCoord: TTextureCoordinateNode;
  Part: TD3ShatterPart;
  P: TD3ShardPiece;
  MaxArea, MinR, MaxR, LinScale, AngScale, Dist, F, D: Single;
  Dir2, Normal: TVector3;
  I, J, K: Integer;
  FloorCache: specialize TDictionary<Int64, Single>;
  Key: Int64;
begin
  if (M.Brush = nil) or (M.Brush.Scene = nil) then
    Exit;
  E := M.Entity;
  { idBrittleFracture::Spawn's defaults }
  MaxArea := E.FloatValue('maxShardArea', 200);
  MaxR := E.FloatValue('maxShatterRadius', 40);
  MinR := E.FloatValue('minShatterRadius', 10);
  LinScale := E.FloatValue('linearVelocityScale', 0.1);
  AngScale := E.FloatValue('angularVelocityScale', 40);
  if MaxArea < 4 then
    MaxArea := 4;
  Sh := TD3Shatter.Create;
  Sh.Name := E.Name;
  Root := TX3DRootNode.Create;
  Collector := TD3ShardCollector.Create;
  FloorCache := specialize TDictionary<Int64, Single>.Create;
  try
    Collector.Scene := M.Brush.Scene;
    Shapes := M.Brush.Scene.Shapes.TraverseList(True, True);
    for Shape in Shapes do
    begin
      Node := Shape.Node;
      if (Node = nil) or (Node.Appearance = nil) or not Node.Visible then
        Continue;
      Collector.Pos := nil;
      Collector.Tex := nil;
      Shape.Triangulate({$ifdef FPC}@{$endif} Collector.Triangle, True);
      if Length(Collector.Pos) = 0 then
        Continue;
      Collector.Cut(MaxArea, Max(Length(Collector.Pos), MaxPieces - Length(Sh.Pieces)));
      Coord := TCoordinateNode.Create;
      TexCoord := TTextureCoordinateNode.Create;
      Part.Coord := Coord;
      Part.First := Length(Sh.Pieces);
      Part.Count := Length(Collector.Pos);
      for I := 0 to High(Collector.Pos) do
      begin
        P := Default(TD3ShardPiece);
        P.Center := (Collector.Pos[I].Data[0] + Collector.Pos[I].Data[1] + Collector.Pos[I].Data[2]) / 3;
        for J := 0 to 2 do
        begin
          P.Corners[J] := Collector.Pos[I].Data[J] - P.Center;
          Coord.FdPoint.Items.Add(Collector.Pos[I].Data[J]);
          TexCoord.FdPoint.Items.Add(Collector.Tex[I][J]);
        end;
        { idBrittleFracture::DropShard: away from the hit, faster close to
          it; spinning about the shot's direction across that }
        Dir2 := P.Center - M.HitPoint;
        Dist := Dir2.Length;
        if Dist > 0.01 then
          Dir2 := Dir2 / Dist
        else
          Dir2 := Vector3(0, 1, 0);
        if Dist >= MaxR then
          F := 1
        else
          F := Sqrt(Max(0, Dist - MinR)) / Sqrt(Max(1, MaxR - MinR));
        if Dist < MaxR then
          P.Velocity := (M.HitDir + Dir2 * (1 - F)) * (Impulse * LinScale) * (0.6 + 0.4 * Random)
        else
          { past the shatter radius Doom 3 keeps them (until cut off from
            the frame): here the whole surface goes, these just fall }
          P.Velocity := (M.HitDir * 0.2 + Dir2 * 0.1) * (Impulse * LinScale);
        Normal := TVector3.CrossProduct(M.HitDir, Dir2);
        if Normal.Length < 0.01 then
          Normal := Vector3(Random - 0.5, Random - 0.5, Random - 0.5);
        if Normal.Length < 0.01 then
          Normal := Vector3(1, 0, 0);
        P.Axis := Normal.Normalize;
        P.Spin := Min(20, AngScale * (1 - F) * 0.25 + 2) * (0.5 + Random);
        { the floor under it (one ray per 16 units) }
        Key := (Int64(Floor(P.Center.X / 16)) shl 32) xor (Int64(Floor(P.Center.Z / 16)) and $FFFFFFFF);
        if not FloorCache.TryGetValue(Key, P.FloorY) then
        begin
          if WorldHit(P.Center, Vector3(0, -1, 0), 2048, D, Normal) then
            P.FloorY := P.Center.Y - D
          else
            P.FloorY := P.Center.Y - 2048;
          FloorCache.Add(Key, P.FloorY);
        end;
        Sh.Pieces := Concat(Sh.Pieces, [P]);
      end;
      Tris := TTriangleSetNode.Create;
      Tris.Coord := Coord;
      Tris.TexCoord := TexCoord;
      Tris.Solid := False;
      ShapeNode := TShapeNode.Create;
      ShapeNode.Appearance := Node.Appearance.DeepCopy as TAppearanceNode;
      ShapeNode.Geometry := Tris;
      Root.AddChildren(ShapeNode);
      Sh.Parts := Concat(Sh.Parts, [Part]);
      if Length(Sh.Pieces) >= MaxPieces then
        Break;
    end;
  finally
    FloorCache.Free;
    Collector.Free;
  end;
  if Length(Sh.Pieces) = 0 then
  begin
    Root.Free;
    Sh.Free;
    WritelnLog('Doom3World', '%s shatters (no surfaces)', [E.Name]);
    Exit;
  end;
  Sh.Scene := TD3Scene.Create(nil);
  Sh.Scene.SetTransient;
  Sh.Scene.Load(Root, True);
  Sh.Scene.Collides := False;
  Sh.Scene.Pickable := False;
  Sh.Scene.CastShadows := False;
  AddLightLibrary(Root);
  FMap.Add(Sh.Scene);
  FShatters.Add(Sh);
  K := 0;
  for I := 0 to High(Sh.Pieces) do
    if PointsDistance(Sh.Pieces[I].Center, M.HitPoint) < MaxR then
      Inc(K);
  WritelnLog('Doom3World', '%s shatters: %d shards (%d near the hit)', [E.Name, Length(Sh.Pieces), K]);
end;

{ A shard on the floor lies flat (Doom 3's physics lays it down): its
  corners as they are now, turned so that its face looks up. }
procedure LayFlat(var P: TD3ShardPiece);
var
  C: array [0..2] of TVector3;
  N, Axis: TVector3;
  I: Integer;
  Angle: Single;
begin
  for I := 0 to 2 do
    C[I] := RotatePointAroundAxisRad(P.Angle, P.Corners[I], P.Axis);
  N := TVector3.CrossProduct(C[1] - C[0], C[2] - C[0]);
  if N.Length < 1e-6 then
    Exit;
  N := N.Normalize;
  if N.Y < 0 then
    N := -N;
  Axis := TVector3.CrossProduct(N, Vector3(0, 1, 0));
  Angle := ArcCos(EnsureRange(N.Y, -1, 1));
  for I := 0 to 2 do
  begin
    if Axis.Length > 1e-6 then
      C[I] := RotatePointAroundAxisRad(Angle, C[I], Axis.Normalize);
    P.Corners[I] := C[I];
  end;
  P.Angle := 0;
end;

procedure TD3Game.UpdateShatters(const SecondsPassed: Single);
const
  { idBrittleFracture's SHARD_ALIVE_TIME and SHARD_FADE_START }
  AliveTime = 5;
  FadeStart = 2;
  Gravity = 1066;
var
  I, J, K, C: Integer;
  Sh: TD3Shatter;
  Scale: Single;
  Points: TVector3List;
begin
  for I := FShatters.Count - 1 downto 0 do
  begin
    Sh := FShatters[I];
    Sh.Age := Sh.Age + SecondsPassed;
    if Sh.Age >= AliveTime then
    begin
      FShatters.Delete(I);
      Continue;
    end;
    if SecondsPassed <= 0 then
      Continue;
    { Doom 3 fades them by their vertex colors (only vertexColor materials
      show it): here they shrink away }
    Scale := 1;
    if Sh.Age > FadeStart then
      Scale := Max(0, 1 - (Sh.Age - FadeStart) / (AliveTime - FadeStart));
    for J := 0 to High(Sh.Pieces) do
      if not Sh.Pieces[J].Resting then
      begin
        Sh.Pieces[J].Velocity.Y := Sh.Pieces[J].Velocity.Y - Gravity * SecondsPassed;
        Sh.Pieces[J].Center := Sh.Pieces[J].Center + Sh.Pieces[J].Velocity * SecondsPassed;
        Sh.Pieces[J].Angle := Sh.Pieces[J].Angle + Sh.Pieces[J].Spin * SecondsPassed;
        if Sh.Pieces[J].Center.Y <= Sh.Pieces[J].FloorY + 0.5 then
        begin
          Sh.Pieces[J].Center.Y := Sh.Pieces[J].FloorY + 0.5;
          Sh.Pieces[J].Resting := True;
          LayFlat(Sh.Pieces[J]);
        end;
      end;
    for J := 0 to High(Sh.Parts) do
    begin
      Points := Sh.Parts[J].Coord.FdPoint.Items;
      C := 0;
      for K := Sh.Parts[J].First to Sh.Parts[J].First + Sh.Parts[J].Count - 1 do
      begin
        Points.L[C] := Sh.Pieces[K].Center + RotatePointAroundAxisRad(Sh.Pieces[K].Angle,
          Sh.Pieces[K].Corners[0], Sh.Pieces[K].Axis) * Scale;
        Points.L[C + 1] := Sh.Pieces[K].Center + RotatePointAroundAxisRad(Sh.Pieces[K].Angle,
          Sh.Pieces[K].Corners[1], Sh.Pieces[K].Axis) * Scale;
        Points.L[C + 2] := Sh.Pieces[K].Center + RotatePointAroundAxisRad(Sh.Pieces[K].Angle,
          Sh.Pieces[K].Corners[2], Sh.Pieces[K].Axis) * Scale;
        Inc(C, 3);
      end;
      Sh.Parts[J].Coord.FdPoint.Changed;
    end;
  end;
end;

function TD3Game.ShatterCount: Integer;
begin
  Result := FShatters.Count;
end;

function TD3Game.ShardCount: Integer;
var
  Sh: TD3Shatter;
begin
  Result := 0;
  for Sh in FShatters do
    Inc(Result, Length(Sh.Pieces));
end;

function TD3Game.ShardMeanHeight: Single;
var
  Sh: TD3Shatter;
  P: TD3ShardPiece;
  N: Integer;
begin
  Result := 0;
  N := 0;
  for Sh in FShatters do
    for P in Sh.Pieces do
    begin
      Result := Result + P.Center.Y;
      Inc(N);
    end;
  if N > 0 then
    Result := Result / N;
end;

procedure TD3Game.KillMisc(const M: TD3MiscEntity);
var
  E: TD3MapEntity;
  Center, Velocity, N: TVector3;
  Burn, Dist: Single;
  I: Integer;
  Key: String;
  ItemDef: TStringList;
begin
  E := M.Entity;
  if M.Dead then
    Exit;
  Center := TVector3.Zero;
  if (M.Brush <> nil) and not M.Brush.Scene.BoundingBox.IsEmpty then
    Center := M.Brush.Scene.BoundingBox.Center
  else
    Center := D3ToCge(EntityOriginNow(E));
  case M.Kind of
    ekBarrel:
      begin
        { idExplodingBarrel::Killed: "burn" seconds of burning first }
        Burn := E.FloatValue('burn', 0);
        if (Burn > 0) and not M.Burning then
        begin
          M.Burning := True;
          M.ExplodeTime := FTime + Burn;
          PlaySoundAt(E.Value('snd_burn'), Center);
          if E.Value('model_burn') <> '' then
            EmitSmoke(E.Value('model_burn'), E.Name, Center, E.Rotation);
          WritelnLog('Doom3World', '%s burns for %s s', [E.Name, FormatFloat('0.#', Burn)]);
          Exit;
        end;
        M.Dead := True;
        { hidden before the radius damage, so it doesn't block it }
        M.Brush.SetHidden(True);
        if MoveableOf(E) <> nil then
          MoveableOf(E).AtRest := True;
        WritelnLog('Doom3World', '%s explodes (%s)', [E.Name, E.Value('def_splash_damage', 'damage_explosion')]);
        SplashAt(Center, E.Value('def_splash_damage', 'damage_explosion'), E.Name, M);
        { idExplodingBarrel::ExplodingEffects }
        if E.Value('model_detonate') <> '' then
          EmitSmoke(E.Value('model_detonate'), E.Name, Center, E.Rotation);
        PlaySoundAt(E.Value('snd_explode'), Center);
        if (E.Value('mtr_burnmark') <> '') and WorldHit(Center, Vector3(0, -1, 0), 128, Dist, N) then
          AddDecal(E.Value('mtr_burnmark'), Center + Vector3(0, -Dist, 0), N, 96);
        for I := 0 to 15 do
        begin
          if I = 0 then
            Key := 'def_debris'
          else
            Key := 'def_debris' + IntToStr(I);
          if E.Value(Key) = '' then
          begin
            if I = 0 then
              Continue;
            Break;
          end;
          ItemDef := Decls.EntityDef(E.Value(Key));
          if ItemDef = nil then
            Continue;
          Velocity := Vector3(RandomFloatRange(-1, 1), RandomFloatRange(0.3, 1), RandomFloatRange(-1, 1)).Normalize;
          SpawnDebris(ItemDef, Center + Velocity * 8, Velocity * RandomFloatRange(150, 300),
            Vector3(RandomFloatRange(-1, 1), RandomFloatRange(-1, 1), RandomFloatRange(-1, 1)) * 360,
            RandomFloatRange(0, 360), 4);
        end;
        if E.BoolValue('triggerTargets') then
          ActivateTargets(E, 0);
      end;
    ekFracture:
      begin
        { idBrittleFracture::Killed: its targets, then it shatters into
          falling shards }
        M.Dead := True;
        ActivateTargets(E, 0);
        PlaySoundAt(E.Value('snd_shatter'), Center);
        M.Brush.SetHidden(True);
        ShatterFracture(M);
      end;
    ekDamagable:
      begin
        { idDamagable::BecomeBroken }
        M.NextTime := FTime + E.FloatValue('wait', 0.1);
        if M.Count > 0 then
        begin
          Dec(M.Count);
          if M.Count = 0 then
            M.Dead := True
          else
            M.Health := E.IntValue('health', 5);
        end else
          M.Health := E.IntValue('health', 5);
        WritelnLog('Doom3World', '%s is broken', [E.Name]);
        ActivateTargets(E, 0);
        if E.BoolValue('hideWhenBroken') then
        begin
          M.Brush.SetHidden(True);
          M.ShowTime := M.NextTime;
        end;
      end;
    ekSecurityCamera:
      begin
        { idSecurityCamera::Killed: it stops, "fx_destroyed" plays }
        M.Dead := True;
        M.CamSweeping := False;
        M.CamEvent := 0;
        StopScriptSound(EntityHandle(E), 3);
        if E.Value('fx_destroyed') <> '' then
          StartFx(E.Value('fx_destroyed'), CgeToD3(Center), E.Rotation, E);
        WritelnLog('Doom3World', 'Security camera %s destroyed', [E.Name]);
      end;
  end;
end;

procedure TD3Game.QuakeMisc(const M: TD3MiscEntity; const BySelf: Boolean);
var
  E: TD3MapEntity;
  Wait: Single;
begin
  { idEarthQuake::Event_Activate }
  E := M.Entity;
  if FTime < M.NextTriggerTime then
    Exit;
  if M.Disabled and BySelf then
    Exit;
  if not E.BoolValue('triggered', True) and not BySelf then
  begin
    { a random quake: activation switches it off / on }
    M.Disabled := not M.Disabled;
    if M.Disabled then
      Exit;
    M.NextTime := FTime + E.FloatValue('wait', 15) + E.FloatValue('random', 5) * RandomFloatRange(-1, 1);
  end;
  ActivateTargets(E, 0);
  if E.BoolValue('playerOnly') then
    PlaySoundAt(E.Value('snd_quake'), FPlayerEye)
  else
    PlaySoundAt(E.Value('snd_quake'), D3ToCge(E.Origin));
  WritelnLog('Doom3World', 'Earthquake %s', [E.Name]);
  if E.FloatValue('shakeTime', 0) > 0 then
    M.ShowTime := FTime + E.FloatValue('shakeTime', 0);
  Wait := E.FloatValue('wait', 15);
  if Wait > 0 then
  begin
    Wait := Max(0.5, Wait + E.FloatValue('random', 5) * RandomFloatRange(-1, 1));
    if not E.BoolValue('triggered', True) then
      M.NextTime := FTime + Wait
    else
      M.NextTriggerTime := FTime + Wait;
  end;
end;

procedure TD3Game.UpdateMisc(const SecondsPassed: Single);
var
  M: TD3MiscEntity;
  Mov: TD3Moveable;
  T: TD3Trigger;
  E: TD3MapEntity;
  Feet, Pos, Dir, V, Center: TVector3;
  Q: TQuaternion;
  R: TVector4;
  S, Amp, Frac, RadiusNow, RadiusBefore, Dist, Magnitude: Single;
  Touched: Boolean;
  I: Integer;
begin
  Feet := PlayerFeet;
  for I := 0 to High(FSpawnedFx) do
    StartFx(FSpawnedFx[I].Value('fx'), FSpawnedFx[I].Origin, FSpawnedFx[I].Rotation, FSpawnedFx[I]);
  SetLength(FSpawnedFx, 0);
  for I := 0 to FMisc.Count - 1 do
  begin
    M := FMisc[I];
    E := M.Entity;
    case M.Kind of
      ekBarrel:
        if not M.Dead and (M.ExplodeTime > 0) and (FTime >= M.ExplodeTime) then
        begin
          M.Burning := True;
          KillMisc(M);
        end;
      ekDamagable:
        if (M.ShowTime > 0) and (FTime >= M.ShowTime) then
        begin
          M.ShowTime := 0;
          M.Brush.SetHidden(False);
        end;
      ekForceField:
        begin
          if M.On and (M.OffTime > 0) and (FTime >= M.OffTime) then
          begin
            M.On := False;
            M.OffTime := 0;
          end;
          if not M.On then
            Continue;
          Center := M.Box.Center;
          { the player (idForce_Field::Evaluate: its velocity is set) }
          if not E.BoolValue('monsterOnly') and not PlayerDead and
             M.Box.Contains(Feet + Vector3(0, 8, 0)) then
          begin
            case M.Mode of
              0: V := M.Force;
              1: V := CgeToD3(Feet - Center).Normalize * M.Force.X;
              else V := CgeToD3(Center - Feet).Normalize * M.Force.X;
            end;
            if E.BoolValue('applyForce') or E.BoolValue('applyImpulse') then
              FKnockVel := FKnockVel + V * (SecondsPassed / 70)
            else
              FKnockVel := V;
            if not FKnockAir and (FKnockVel.Z > 10) then
            begin
              FKnockAir := True;
              FKnockRise := 0;
              FKnockPeak := 0;
            end;
          end;
          if E.BoolValue('playerOnly') or E.BoolValue('monsterOnly') then
            Continue;
          for Mov in FMoveables do
          begin
            if Mov.Brush.Hidden or (Mov.Brush.Scene = nil) or (FindBinding(Mov.Brush.Scene) <> nil) then
              Continue;
            Pos := Mov.Brush.Scene.BoundingBox.Center;
            if not M.Box.Contains(Pos) then
              Continue;
            case M.Mode of
              0: V := M.Force;
              1: V := CgeToD3(Pos - Center).Normalize * M.Force.X;
              else V := CgeToD3(Center - Pos).Normalize * M.Force.X;
            end;
            if E.BoolValue('applyForce') or E.BoolValue('applyImpulse') then
              Mov.Velocity := Mov.Velocity + V * (SecondsPassed / Mov.Mass)
            else
              Mov.Velocity := V;
            Mov.AtRest := False;
          end;
        end;
      ekShaking:
        if M.On and (M.Shaken <> nil) and ((M.Brush = nil) or not M.Brush.Hidden) then
        begin
          { idShaking::BeginShaking: idExtrapolate DECELSINE | NOSTOP of
            period / 4 around the spawn angles, "shake" degrees a second }
          S := E.FloatValue('period', 0.05) * 0.25;
          if S <= 0 then
            Continue;
          Amp := Sin((FTime + M.Phase) / S * Pi / 2) * S * Sqrt(0.5);
          { idAngles: pitch about y, yaw about z, roll about x }
          Q := QuatFromAxisAngle(M.BaseRotation) *
            QuatFromAxisAngle(D3ToCge(Vector3(0, 0, 1)), DegToRad(M.Force.Y * Amp)) *
            QuatFromAxisAngle(D3ToCge(Vector3(0, 1, 0)), DegToRad(M.Force.X * Amp)) *
            QuatFromAxisAngle(D3ToCge(Vector3(1, 0, 0)), DegToRad(M.Force.Z * Amp));
          R := Q.ToAxisAngle;
          M.Shaken.Rotation := R;
        end;
      ekEarthQuake:
        begin
          if M.On and not M.Disabled and (M.NextTime > 0) and (FTime >= M.NextTime) then
            QuakeMisc(M, True);
          { idEarthQuake::Think: while it shakes, things around are pushed }
          if (M.ShowTime > 0) and (FTime < M.ShowTime) then
            for Mov in FMoveables do
              if Mov.AtRest and not Mov.Brush.Hidden and (Random < 0.02) then
              begin
                Mov.Velocity := Mov.Velocity + Vector3(RandomFloatRange(-20, 20), RandomFloatRange(-20, 20), 30);
                Mov.AtRest := False;
              end;
        end;
      ekActivator:
        if M.On then
        begin
          { idActivator::Think: it touches the triggers where it is (bound
            to a mover, it carries the touch around) }
          Pos := D3ToCge(EntityOriginNow(E));
          Touched := False;
          for T in FTriggers do
            if not T.Disabled and not T.WaitingForActivation and (T.Kind <> tkHurt) and
               (FTime >= T.NextTime) and T.Box.Contains(Pos) then
            begin
              FireTrigger(T);
              Touched := True;
            end;
          if Touched and not E.BoolValue('stay_on') then
            M.On := False;
        end;
      ekHarvest:
        UpdateHarvest(M);
      ekSecurityCamera:
        if not M.Dead then
          UpdateSecurityCamera(M, Feet);
      ekShockwave:
        if M.On then
        begin
          { idShockwave::Think: a ring growing from "startsize" to
            "endsize" in "duration" ms pushes what it passes }
          S := Max(0.01, E.FloatValue('duration', 1000) / 1000);
          Frac := (FTime - M.StartTime) / S;
          RadiusBefore := M.LastRadius;
          RadiusNow := E.FloatValue('startsize', 8) +
            (E.FloatValue('endsize', 512) - E.FloatValue('startsize', 8)) * Min(1, Frac);
          M.LastRadius := RadiusNow;
          Magnitude := E.FloatValue('magnitude', 10000);
          Center := D3ToCge(EntityOriginNow(E));
          for Mov in FMoveables do
          begin
            if Mov.Brush.Hidden or (Mov.Brush.Scene = nil) or (FindBinding(Mov.Brush.Scene) <> nil) then
              Continue;
            Pos := Mov.Brush.Scene.BoundingBox.Center;
            Dist := (Pos - Center).Length;
            if (Dist > RadiusBefore) and (Dist <= RadiusNow) then
            begin
              Dir := CgeToD3(Pos - Center);
              if Dir.IsZero then
                Dir := Vector3(0, 0, 1);
              Dir := Dir.Normalize;
              Dir.Z := Dir.Z + 0.5;
              Mov.Velocity := Mov.Velocity + Dir * (Magnitude / Max(1, Mov.Mass));
              Mov.AtRest := False;
            end;
          end;
          Dist := (FPlayerEye - Center).Length;
          if (Dist > RadiusBefore) and (Dist <= RadiusNow) and not PlayerDead and
             (E.FloatValue('player_magnitude', 0) > 0) then
          begin
            Dir := CgeToD3(FPlayerEye - Center);
            if not Dir.IsZero then
              FKnockVel := FKnockVel + Dir.Normalize * (E.FloatValue('player_magnitude', 0) / 70);
          end;
          if Frac >= 1 then
          begin
            M.On := False;
            M.LastRadius := 0;
          end;
        end;
    end;
  end;
end;

{ Activation of the classes above and of the ones that only act when
  activated. False: not one of them. }
function TD3Game.ActivateMisc(const E: TD3MapEntity; const Cls, SC: String): Boolean;
var
  M: TD3MiscEntity;
  Pos, N: TVector3;
  I: Integer;
  Dist: Single;
  Item: String;
begin
  Result := True;
  M := MiscOf(E);
  if M <> nil then
  begin
    case M.Kind of
      ekBarrel:
        begin
          M.Burning := True;
          KillMisc(M);
        end;
      ekFracture:
        begin
          { idBrittleFracture::Event_Activate: it can break from now on,
            and breaks when it has no health }
          M.On := True;
          if M.Health <= 0 then
            KillMisc(M);
        end;
      ekDamagable:
        KillMisc(M);
      ekForceField:
        begin
          { idForceField::Event_Activate: toggles, off again after "wait" }
          M.On := not M.On;
          M.OffTime := 0;
          if M.On and (E.FloatValue('wait', 0) > 0) then
            M.OffTime := FTime + E.FloatValue('wait', 0);
          WritelnLog('Doom3World', 'Force field %s %s', [E.Name, BoolToStr(M.On, 'on', 'off')]);
        end;
      ekShaking:
        begin
          M.On := not M.On;
          if not M.On and (M.Shaken <> nil) then
            M.Shaken.Rotation := M.BaseRotation;
        end;
      ekEarthQuake:
        QuakeMisc(M, False);
      ekActivator:
        M.On := not M.On;
      ekShockwave:
        begin
          M.On := True;
          M.StartTime := FTime;
          M.LastRadius := 0;
          WritelnLog('Doom3World', 'Shockwave %s', [E.Name]);
        end;
      ekSecurityCamera:
        { idSecurityCamera has no Event_Activate };
    end;
    Exit;
  end;

  if SC = 'idExplodable' then
  begin
    { idExplodable::Event_Explode: radius damage, the sound, its particle
      model for 2 s, its targets }
    Pos := D3ToCge(EntityOriginNow(E));
    WritelnLog('Doom3World', 'Explosion %s (%s)', [E.Name, E.Value('def_damage', 'damage_explosion')]);
    SplashAt(Pos, E.Value('def_damage', 'damage_explosion'), E.Name, nil);
    PlaySoundAt(E.Value('snd_explode'), Pos);
    if SameText(ExtractFileExt(E.Value('model')), '.prt') then
      EmitSmoke(E.Value('model'), E.Name, Pos, E.Rotation);
    ActivateTargets(E, 0);
  end else
  if SC = 'idItemRemover' then
  begin
    { idItemRemover::Event_Trigger: takes the carried item "remove" }
    Item := D3LangString(E.Value('remove'));
    I := FCarried.IndexOf(Item);
    if I >= 0 then
    begin
      WritelnLog('Doom3World', '%s takes %s', [E.Name, Item]);
      FCarried.Delete(I);
    end;
    ActivateTargets(E, 0);
  end else
  if SC = 'idFuncAASObstacle' then
    { idFuncAASObstacle: switches an AAS obstacle (routes don't have
      obstacles here: monsters walk into what blocks them) }
  else
  if SC = 'idTarget_EnableStamina' then
  begin
    FNoStamina := not E.BoolValue('enable');
    WritelnLog('Doom3World', 'Stamina %s', [BoolToStr(FNoStamina, 'off', 'on')]);
  end else
  if SC = 'idTarget_GiveSecurity' then
  begin
    { idPlayer::GiveSecurity: the HUD says the new clearance }
    FSecurity := D3LangString(E.Value('text_security'));
    Message(FSecurity);
    WritelnLog('Doom3World', 'Security clearance: %s', [FSecurity]);
  end else
  if SC = 'idTeleporter' then
  begin
    { idTeleporter::Event_DoAction: the player goes to it }
    FTeleportPending := True;
    FTeleportPos := D3ToCge(E.Origin);
    FTeleportYaw := E.Angle;
    WritelnLog('Doom3World', 'Teleport to %s', [E.Name]);
  end else
  if SC = 'idFuncSplat' then
  begin
    { idFuncSplat::Event_Splat: its decal on the surface under it }
    Pos := D3ToCge(E.Origin);
    PlaySoundAt(E.Value('snd_splat'), Pos);
    if (E.Value('mtr_decal') <> '') and
       WorldHit(Pos + Vector3(0, 8, 0), Vector3(0, -1, 0), E.FloatValue('splatDistance', 128) + 8, Dist, N) then
      AddDecal(E.Value('mtr_decal'), Pos + Vector3(0, 8 - Dist, 0), N, E.FloatValue('splatSize', 64));
  end else
  if SC = 'idVacuumSeparatorEntity' then
    ToggleVacuumSeparator(E)
  else
  if (SC = 'idSpawnableEntity') or (SC = 'idLocationSeparatorEntity') or (SC = 'idVacuumEntity') then
    { nothing to do when activated }
  else
    Result := False;
end;
