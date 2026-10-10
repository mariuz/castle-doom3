{ Doom 3 style HUD: health / armor panel, ammo panel, crosshair, timed
  messages, damage flash, death screen. Registered for the CGE editor. }
unit Doom3Hud;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  CastleVectors, CastleUIControls, CastleRectangles, CastleColors;

type
  TDoom3Hud = class(TCastleUserInterface)
  strict private
    FMessages: TStringList;
    FMessageTimes: array of Single;
    FDamageFlash: Single;
    FLastHealth: Integer;
  public
    Health, Armor: Integer;
    AmmoText: String;
    FlashlightOn: Boolean;
    Dead: Boolean;
    InfoText: String;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure ShowMessage(const S: String; const Seconds: Single = 3);
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
    procedure Render; override;
  end;

implementation

uses
  Math,
  CastleGLUtils, CastleControls, CastleComponentSerialize;

constructor TDoom3Hud.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FullSize := True;
  FMessages := TStringList.Create;
  Health := 100;
  FLastHealth := 100;
  AmmoText := 'PISTOL';
end;

destructor TDoom3Hud.Destroy;
begin
  FMessages.Free;
  inherited Destroy;
end;

procedure TDoom3Hud.ShowMessage(const S: String; const Seconds: Single);
begin
  FMessages.Add(S);
  SetLength(FMessageTimes, FMessages.Count);
  FMessageTimes[FMessages.Count - 1] := Seconds;
  while FMessages.Count > 5 do
  begin
    FMessages.Delete(0);
    Move(FMessageTimes[1], FMessageTimes[0], SizeOf(Single) * FMessages.Count);
    SetLength(FMessageTimes, FMessages.Count);
  end;
end;

procedure TDoom3Hud.Update(const SecondsPassed: Single; var HandleInput: Boolean);
var
  I: Integer;
begin
  inherited Update(SecondsPassed, HandleInput);
  for I := FMessages.Count - 1 downto 0 do
  begin
    FMessageTimes[I] := FMessageTimes[I] - SecondsPassed;
    if FMessageTimes[I] <= 0 then
    begin
      FMessages.Delete(I);
      if I < High(FMessageTimes) then
        Move(FMessageTimes[I + 1], FMessageTimes[I], SizeOf(Single) * (High(FMessageTimes) - I));
      SetLength(FMessageTimes, FMessages.Count);
    end;
  end;
  if Health < FLastHealth then
    FDamageFlash := Min(0.6, FDamageFlash + (FLastHealth - Health) / 40);
  FLastHealth := Health;
  FDamageFlash := Max(0, FDamageFlash - SecondsPassed * 1.5);
end;

procedure TDoom3Hud.Render;
const
  Cyan: TCastleColor = (X: 0.55; Y: 0.85; Z: 1.0; W: 0.95);
  PanelColor: TCastleColor = (X: 0.02; Y: 0.08; Z: 0.12; W: 0.6);
var
  R: TFloatRectangle;
  CX, CY, S: Single;
  I: Integer;
  HealthColor: TCastleColor;
begin
  inherited Render;
  R := RenderRect;
  S := UIScale;

  if FDamageFlash > 0 then
    DrawRectangle(R, Vector4(0.7, 0, 0, FDamageFlash));

  if Dead then
  begin
    DrawRectangle(R, Vector4(0.25, 0, 0, 0.55));
    UIFont.PrintRect(R, Vector4(1, 0.3, 0.2, 1), 'YOU ARE DEAD' + #10 + 'press fire to restart',
      hpMiddle, vpMiddle);
    Exit;
  end;

  { crosshair }
  CX := R.Left + R.Width / 2;
  CY := R.Bottom + R.Height / 2;
  DrawRectangle(FloatRectangle(CX - 1 * S, CY - 8 * S, 2 * S, 5 * S), Cyan);
  DrawRectangle(FloatRectangle(CX - 1 * S, CY + 3 * S, 2 * S, 5 * S), Cyan);
  DrawRectangle(FloatRectangle(CX - 8 * S, CY - 1 * S, 5 * S, 2 * S), Cyan);
  DrawRectangle(FloatRectangle(CX + 3 * S, CY - 1 * S, 5 * S, 2 * S), Cyan);

  { health / armor (bottom left) }
  DrawRectangle(FloatRectangle(R.Left + 20 * S, R.Bottom + 20 * S, 300 * S, 70 * S), PanelColor);
  if Health > 25 then
    HealthColor := Cyan
  else
    HealthColor := Vector4(1, 0.25, 0.15, 1);
  UIFont.Print(R.Left + 34 * S, R.Bottom + 56 * S, HealthColor,
    Format('HEALTH  %d', [Health]));
  UIFont.Print(R.Left + 34 * S, R.Bottom + 30 * S, Cyan, Format('ARMOR   %d', [Armor]));
  DrawRectangle(FloatRectangle(R.Left + 190 * S, R.Bottom + 58 * S, 110 * S * Max(0, Min(100, Health)) / 100,
    12 * S), HealthColor);

  { weapon / flashlight (bottom right) }
  DrawRectangle(FloatRectangle(R.Right - 320 * S, R.Bottom + 20 * S, 300 * S, 70 * S), PanelColor);
  UIFont.Print(R.Right - 306 * S, R.Bottom + 56 * S, Cyan, AmmoText);
  if FlashlightOn then
    UIFont.Print(R.Right - 306 * S, R.Bottom + 30 * S, Vector4(1, 0.95, 0.6, 1), 'FLASHLIGHT ON  (F)')
  else
    UIFont.Print(R.Right - 306 * S, R.Bottom + 30 * S, Cyan, 'FLASHLIGHT     (F)');

  { messages (top left) }
  for I := 0 to FMessages.Count - 1 do
    UIFont.Print(R.Left + 20 * S, R.Top - (40 + 26 * I) * S, Vector4(1, 1, 1, Min(1, FMessageTimes[I])),
      FMessages[I]);

  if InfoText <> '' then
    UIFont.Print(R.Left + 20 * S, R.Bottom + 100 * S, Vector4(0.7, 0.7, 0.7, 0.8), InfoText);
end;

initialization
  RegisterSerializableComponent(TDoom3Hud, 'Doom 3 HUD');
end.
