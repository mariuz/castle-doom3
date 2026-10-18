{ Doom 3 style HUD: health / armor panel, ammo panel, crosshair, timed
  messages, damage flash, death screen. Registered for the CGE editor. }
unit Doom3Hud;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleVectors, CastleUIControls, CastleRectangles, CastleColors, CastleGLImages;

type
  { A damage blob on the screen (idPlayerView's screenBlob_t): an image on
    Doom 3's 640 x 480 screen, faded by Alpha. }
  TD3HudBlob = record
    ImageUrl: String;
    X, Y, W, H, Alpha: Single;
  end;

  TDoom3Hud = class(TCastleUserInterface)
  strict private
    FMessages: TStringList;
    FMessageTimes: array of Single;
    FVignette: TDrawableImage;
    FImages: specialize TObjectDictionary<String, TDrawableImage>;
    function Image(const Url: String): TDrawableImage;
  public
    Health, Armor: Integer;
    AmmoText: String;
    FlashlightOn: Boolean;
    Dead: Boolean;
    InfoText: String;
    { seconds since the player was hurt (the tunnel vision pulses) }
    DamageAge: Single;
    Blobs: array of TD3HudBlob;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure ShowMessage(const S: String; const Seconds: Single = 3);
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
    procedure Render; override;
  end;

implementation

uses
  Math,
  CastleGLUtils, CastleControls, CastleComponentSerialize, CastleImages;

constructor TDoom3Hud.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FullSize := True;
  FMessages := TStringList.Create;
  Health := 100;
  AmmoText := 'PISTOL';
  DamageAge := 1000;
  FImages := specialize TObjectDictionary<String, TDrawableImage>.Create([doOwnsValues]);
end;

destructor TDoom3Hud.Destroy;
begin
  FreeAndNil(FVignette);
  FImages.Free;
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
end;

function TDoom3Hud.Image(const Url: String): TDrawableImage;
begin
  if not FImages.TryGetValue(Url, Result) then
  begin
    try
      Result := TDrawableImage.Create(Url);
    except
      on E: Exception do
        Result := nil;
    end;
    FImages.Add(Url, Result);
  end;
end;

{ A dark ring towards the screen's edges, clear in the middle (the shape
  of Doom 3's textures/decals/tunnel). }
function MakeVignette: TRGBAlphaImage;
const
  N = 128;
var
  X, Y: Integer;
  R, A: Single;
  P: PVector4Byte;
begin
  Result := TRGBAlphaImage.Create(N, N);
  for Y := 0 to N - 1 do
    for X := 0 to N - 1 do
    begin
      R := Sqrt(Sqr((X + 0.5) / N * 2 - 1) + Sqr((Y + 0.5) / N * 2 - 1)) / Sqrt(2);
      A := EnsureRange((R - 0.3) / 0.7, 0, 1);
      A := A * A * (3 - 2 * A);
      P := Result.PixelPtr(X, Y);
      P^ := Vector4Byte(255, 255, 255, Round(A * 255));
    end;
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
  Img: TDrawableImage;
  Strength: Single;
begin
  inherited Render;
  R := RenderRect;
  S := UIScale;

  { damage blobs (blood) on Doom 3's 640 x 480 screen }
  for I := 0 to High(Blobs) do
  begin
    Img := Image(Blobs[I].ImageUrl);
    if Img = nil then
      Continue;
    Img.Color := Vector4(1, 1, 1, Blobs[I].Alpha);
    Img.Draw(FloatRectangle(R.Left + Blobs[I].X / 640 * R.Width,
      R.Top - (Blobs[I].Y + Blobs[I].H) / 480 * R.Height,
      Blobs[I].W / 640 * R.Width, Blobs[I].H / 480 * R.Height));
  end;

  { tunnel vision (idPlayerView: textures/decals/tunnel with the health
    and the last damage time): darker edges as health goes down, a red
    pulse at each hit }
  Strength := (1 - EnsureRange(Health / 100, 0, 1)) * 0.55 + Max(0, 1 - DamageAge / 0.4) * 0.4;
  if (Strength > 0.01) and not Dead then
  begin
    if FVignette = nil then
      FVignette := TDrawableImage.Create(MakeVignette, True, True);
    FVignette.Color := Vector4(0.45, 0, 0, Min(1, Strength));
    FVignette.Draw(R);
  end;

  if Dead then
  begin
    DrawRectangle(R, Vector4(0.25, 0, 0, 0.55));
    UIFont.Print(R.Left + (R.Width - UIFont.TextWidth('YOU ARE DEAD')) / 2, R.Bottom + R.Height / 2 + 4 * S,
      Vector4(1, 0.3, 0.2, 1), 'YOU ARE DEAD');
    UIFont.Print(R.Left + (R.Width - UIFont.TextWidth('press fire to restart')) / 2,
      R.Bottom + R.Height / 2 - UIFont.Height - 4 * S, Vector4(1, 0.3, 0.2, 1), 'press fire to restart');
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
  { wide enough for "TEST SHOTGUN  7 / 16    KILLS 10" }
  DrawRectangle(FloatRectangle(R.Right - 440 * S, R.Bottom + 20 * S, 420 * S, 70 * S), PanelColor);
  UIFont.Print(R.Right - 426 * S, R.Bottom + 56 * S, Cyan, AmmoText);
  if FlashlightOn then
    UIFont.Print(R.Right - 426 * S, R.Bottom + 30 * S, Vector4(1, 0.95, 0.6, 1), 'FLASHLIGHT ON  (F)')
  else
    UIFont.Print(R.Right - 426 * S, R.Bottom + 30 * S, Cyan, 'FLASHLIGHT     (F)');

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
