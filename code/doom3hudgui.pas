// Doom 3's HUD as its own GUI (guis/hud.gui): the player's state in the
// GUI's state keys and its named events, like idPlayer::UpdateHudStats,
// UpdateHudAmmo, UpdateHudWeapon and the tip, objective, radio and pickup
// calls. Drawn by the view over the 3D world (software, like other GUIs).
unit Doom3HudGui;

interface

uses
  SysUtils, Classes,
  CastleImages,
  Doom3Gui, Doom3World;

type
  TD3HudGui = class
  strict private
    FGui: TD3Gui;
    FStarted: Boolean;
    FHealth, FArmor, FStamina: Integer;
    FAmmoKey: String;
    FTotalAmmo: Integer;
    FWeapons: String;
    FSlot: Integer;
    FTipText, FObjectiveNotice: String;
    FRadio: Boolean;
    FItem: Integer;
    FEvents: TStringList;
    FRenders: Integer;
    FRenderSeconds: Double;
    procedure Event(const AName: String);
  public
    constructor Create;
    destructor Destroy; override;
    { False when the file is missing or doesn't parse }
    function Load(const Path: String): Boolean;
    function LoadFromText(const AText: String): Boolean;
    { The state from the game and the named events for what changed
      (every frame; TimeMs: the HUD's own clock; Location: the player's
      location name, idPlayer::UpdateLocation). }
    procedure Update(const Game: TD3Game; const TimeMs: Integer; const Location: String);
    { An item pickup line (idPlayer::GiveItem's itemtextN and
      itemPickupN; up to 5 cycle). }
    procedure Pickup(const Text: String);
    function Render: TRGBAlphaImage;
    property Gui: TD3Gui read FGui;
    { every named event sent, oldest first (logged, read by tests) }
    property Events: TStringList read FEvents;
    property Renders: Integer read FRenders;
    { the average software render time (ms) }
    function RenderMs: Single;
  end;

implementation

uses
  Math,
  CastleLog, CastleTimeUtils;

constructor TD3HudGui.Create;
begin
  inherited Create;
  FGui := TD3Gui.Create;
  FEvents := TStringList.Create;
  FSlot := -2;
end;

destructor TD3HudGui.Destroy;
begin
  FreeAndNil(FGui);
  FreeAndNil(FEvents);
  inherited;
end;

function TD3HudGui.Load(const Path: String): Boolean;
begin
  Result := FGui.LoadFromVfs(Path);
  if Result then
    WritelnLog('Doom3HudGui', 'HUD GUI "%s" (%d windows)', [Path, FGui.WindowCount]);
end;

function TD3HudGui.LoadFromText(const AText: String): Boolean;
begin
  Result := FGui.LoadFromText(AText);
end;

procedure TD3HudGui.Event(const AName: String);
begin
  FGui.NamedEvent(AName);
  FEvents.Add(AName);
  { a long game must not grow it forever }
  if FEvents.Count > 200 then
    FEvents.Delete(0);
end;

procedure TD3HudGui.Pickup(const Text: String);
begin
  { idPlayer::UpdateHud shows the pickups in 5 lines, the newest next }
  FItem := FItem mod 5 + 1;
  FGui.SetState('itemtext' + IntToStr(FItem), Text);
  Event('itemPickup' + IntToStr(FItem));
end;

procedure TD3HudGui.Update(const Game: TD3Game; const TimeMs: Integer; const Location: String);
var
  First, OwnedBefore: Boolean;
  Health, Armor, Stamina, I, State, InClip, Total, LowAmmo: Integer;
  W: TD3Weapon;
  AmmoKey, Weapons: String;
begin
  First := not FStarted;
  if First then
  begin
    FGui.Activate(TimeMs);
    FStarted := True;
  end;
  FGui.Update(TimeMs);

  { idPlayer::UpdateHudStats }
  Health := Game.Health;
  Armor := Game.Armor;
  Stamina := Game.StaminaPercent;
  FGui.SetState('player_health', IntToStr(Health));
  FGui.SetState('player_armor', IntToStr(Armor));
  FGui.SetState('player_stamina', IntToStr(Max(0, Stamina)));
  FGui.SetState('player_nostamina', IntToStr(Ord(Stamina < 0)));
  FGui.SetState('player_air', '100');
  FGui.SetState('player_hr', '70');
  FGui.SetState('location', Location);
  if First or (Health <> FHealth) or (Armor <> FArmor) or (Stamina <> FStamina) then
    Event('updateArmorHealthAir');
  if not First and (Health > FHealth) then
    Event('healthPulse');
  if not First and (Armor > FArmor) then
    Event('armorPulse');
  FHealth := Health;
  FArmor := Armor;
  FStamina := Stamina;

  { UpdateHudAmmo: the clip and the rest, empty and low flags }
  W := Game.Weapon;
  Total := 0;
  if (W = nil) or (W.AmmoType = '') then
  begin
    FGui.SetState('player_ammo', '');
    FGui.SetState('player_totalammo', '');
    FGui.SetState('player_clips', '');
    FGui.SetState('player_allammo', '');
    FGui.SetState('player_ammo_empty', '0');
    FGui.SetState('player_clip_empty', '0');
    FGui.SetState('player_clip_low', '0');
    AmmoKey := '-';
  end else
  begin
    Total := Game.AmmoCount(W.AmmoType);
    if W.ClipSize > 0 then
      InClip := Game.Clip[W.Slot]
    else
      InClip := 0;
    LowAmmo := StrToIntDef(W.Def.Values['lowAmmo'], 0);
    FGui.SetState('player_totalammo', IntToStr(Max(0, Total - InClip)));
    if W.ClipSize > 0 then
    begin
      FGui.SetState('player_ammo', IntToStr(InClip));
      FGui.SetState('player_clips', IntToStr(Total div W.ClipSize));
    end else
    begin
      FGui.SetState('player_ammo', '--');
      FGui.SetState('player_clips', '--');
    end;
    FGui.SetState('player_allammo', Format('%d/%d', [InClip, Max(0, Total - InClip)]));
    FGui.SetState('player_ammo_empty', IntToStr(Ord(Total = 0)));
    FGui.SetState('player_clip_empty', IntToStr(Ord((W.ClipSize > 0) and (InClip = 0))));
    FGui.SetState('player_clip_low', IntToStr(Ord((W.ClipSize > 0) and (InClip <= LowAmmo))));
    AmmoKey := Format('%s %d %d', [W.AmmoType, InClip, Total]);
  end;
  if First or (AmmoKey <> FAmmoKey) then
    Event('updateAmmo');
  if not First and (W <> nil) and (AmmoKey <> FAmmoKey) and (Total > FTotalAmmo) and
     (Copy(FAmmoKey, 1, Length(W.AmmoType) + 1) = W.AmmoType + ' ') then
    Event('ammoPulse');
  FAmmoKey := AmmoKey;
  FTotalAmmo := Total;

  { UpdateHudWeapon: weaponN is 0 (not carried), 1 (carried) or 2 (the
    ideal weapon); weaponChange when the ideal one changes, newWeapon with
    newweapon for a new one }
  Weapons := '';
  for I := 0 to 11 do
  begin
    State := 0;
    if Game.HasWeapon(I) then
    begin
      State := 1;
      if Game.IdealSlot = I then
        State := 2;
    end;
    FGui.SetState('weapon' + IntToStr(I), IntToStr(State));
    Weapons := Weapons + IntToStr(State);
  end;
  if not First and (FWeapons <> '') then
    for I := 0 to 11 do
    begin
      OwnedBefore := FWeapons[I + 1] <> '0';
      if (Weapons[I + 1] <> '0') and not OwnedBefore then
      begin
        FGui.SetState('newweapon', IntToStr(I));
        Event('newWeapon');
        Event('weaponPulse');
      end;
    end;
  if First or (Game.IdealSlot <> FSlot) or (Weapons <> FWeapons) then
    Event('weaponChange');
  FWeapons := Weapons;
  FSlot := Game.IdealSlot;

  { target_tip (idPlayer::ShowTip / HideTip) }
  if Game.TipText <> FTipText then
  begin
    if Game.TipText <> '' then
    begin
      FGui.SetState('tip', Game.TipText);
      FGui.SetState('tiptitle', Game.TipTitle);
      Event('tipWindowUp');
    end else
      Event('tipWindowDown');
    FTipText := Game.TipText;
  end;

  { idPlayer::ShowObjective / HideObjective }
  if Game.ObjectiveNotice <> FObjectiveNotice then
  begin
    if Game.ObjectiveNotice <> '' then
    begin
      FGui.SetState('objectivetitle', Game.ObjectiveNoticeTitle);
      FGui.SetState('objectivetext', Game.ObjectiveNoticeText);
      if SameText(Game.ObjectiveNotice, 'Objective Complete') then
        Event('newObjectiveComplete')
      else
        Event('newObjective');
    end else
      Event('closeObjective');
    FObjectiveNotice := Game.ObjectiveNotice;
  end;

  { func_radiochatter }
  if Game.RadioChatter <> FRadio then
  begin
    if Game.RadioChatter then
      Event('radioChatterUp')
    else
      Event('radioChatterDown');
    FRadio := Game.RadioChatter;
  end;
end;

function TD3HudGui.Render: TRGBAlphaImage;
var
  Start: TTimerResult;
begin
  Start := Timer;
  Result := RenderGuiTransparent(FGui);
  FGui.Dirty := False;
  FRenderSeconds := FRenderSeconds + TimerSeconds(Timer, Start);
  Inc(FRenders);
  if FRenders = 50 then
    WritelnLog('Doom3HudGui', 'HUD GUI: %d renders, %.1f ms each', [FRenders, RenderMs]);
end;

function TD3HudGui.RenderMs: Single;
begin
  if FRenders = 0 then
    Result := 0
  else
    Result := FRenderSeconds / FRenders * 1000;
end;

end.
