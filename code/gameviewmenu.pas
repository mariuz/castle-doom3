{ The title screen. With Doom 3's data it is Doom 3's main menu GUI
  (guis/mainmenu.gui, like idSessionLocal::StartMenu): drawn full screen,
  the mouse and keys go to it, its commands start the game ("startgame"),
  quit, go back to the game ("close") or play GUI sounds. Without that
  file (the test data), or after Tab, a button per map found in the loaded
  PK4s; its components are designed in
  data/gameviewmenu.castle-user-interface .

  Escape in the game pushes this view over it (the game pauses):
  "close" pops it again, like Doom 3's in-game menu. }
unit GameViewMenu;

{$mode objfpc}{$H+}

interface

uses
  Classes, Generics.Collections,
  CastleUIControls, CastleControls, CastleKeysMouse, CastleSoundEngine,
  Doom3Gui;

type
  TViewMenu = class(TCastleView)
  published
    { Components designed using CGE editor.
      These fields will be automatically initialized at Start. }
    RootGroup: TCastleUserInterface;
    GroupMaps: TCastleVerticalGroup;
    ButtonQuit: TCastleButton;
    LabelInfo: TCastleLabel;
  private
    FMaps: TStringList;
    FAutoTestTime: Single;
    FGui: TD3Gui;
    FGuiImage: TCastleImageControl;
    { black behind the 4:3 menu (the game doesn't show at its sides) }
    FGuiBack: TCastleRectangleControl;
    FGuiTimeMs, FGuiRedraw: Single;
    FMouseDown: Boolean;
    FSounds: specialize TObjectDictionary<String, TCastleSound>;
    FNotSupported: TStringList;
    { the menu's music ("music" command): looping, stopped with the menu }
    FMusic: TCastlePlayingSound;
    FDemo: TStringList;
    FDemoIndex: Integer;
    FDemoWait: Single;
    FShots: Integer;
    FRenders: Integer;
    FRenderSeconds: Double;
    procedure ClickMap(Sender: TObject);
    procedure ClickQuit(Sender: TObject);
    procedure SetGuiShown(const Value: Boolean);
    procedure UpdateGui(const SecondsPassed: Single);
    procedure GuiCommands(const Cmd: String);
    function GuiSound(const ShaderName: String): TCastleSound;
    procedure PlayGuiSound(const ShaderName: String);
    procedure PlayMusic(const ShaderName: String);
    procedure StartMap(const AMapName: String);
    procedure Leave;
    procedure QuitGame;
    procedure SaveShot;
    procedure RunDemo(const SecondsPassed: Single);
  public
    { --autotest MENU <prefix>: save <prefix>_menu.png and quit; with a
      --demo (W:<s>, S, C:<x> <y> clicks at GUI coordinates, K:esc,
      P:start / P:stop a sampling profile, Q) it
      drives the menu GUI instead }
    AutoTestPrefix: String;
    AutoTestDemo: String;
    { pushed over a running game (Escape): "close" goes back to it }
    InGame: Boolean;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Start; override;
    procedure Stop; override;
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
    function Press(const Event: TInputPressRelease): Boolean; override;
    { the menu GUI shown (False: our map list) }
    function GuiShown: Boolean;
    { a click at GUI coordinates, Escape (demo scripts, console "menu") }
    procedure GuiClick(const X, Y: Single);
    procedure GuiEscape;
  end;

var
  ViewMenu: TViewMenu;
  { console g_menuGui: Doom 3's main menu GUI when the data has it }
  UseMenuGui: Boolean = True;

{ All maps with a .proc file: "testmap", "game/mars_city1"... }
function ListMaps: TStringList;

implementation

uses
  SysUtils, Math,
  CastleWindow, CastleImages, CastleLog, CastleVectors, CastleRectangles, CastleUtils, CastleTimeUtils,
  Doom3Files, Doom3Decls, Doom3Sampler, GameViewPlay;

const
  MenuGuiPath = 'guis/mainmenu.gui';
  { software rendered (about ten full screen layers): at most this many
    redraws a second, at this size (the 640 x 480 GUI fills the screen, so
    more than the in-world 512) }
  MenuRedrawRate = 20;
  MenuImageWidth = 800;
  MenuImageHeight = 600;

function ListMaps: TStringList;
var
  Files: TStringList;
  F: String;
begin
  Result := TStringList.Create;
  Files := D3Fs.FindFiles('maps/', '.proc');
  try
    for F in Files do
      Result.Add(ChangeFileExt(Copy(F, Length('maps/') + 1, MaxInt), ''));
  finally
    Files.Free;
  end;
end;

constructor TViewMenu.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  DesignUrl := 'castle-data:/gameviewmenu.castle-user-interface';
  FSounds := specialize TObjectDictionary<String, TCastleSound>.Create([doOwnsValues]);
  FNotSupported := TStringList.Create;
  FDemo := TStringList.Create;
end;

destructor TViewMenu.Destroy;
begin
  FreeAndNil(FGui);
  FMaps.Free;
  FSounds.Free;
  FNotSupported.Free;
  FDemo.Free;
  inherited Destroy;
end;

procedure TViewMenu.Start;
var
  I: Integer;
  B: TCastleButton;
begin
  inherited Start;
  FreeAndNil(FMaps);
  FMaps := ListMaps;
  for I := 0 to FMaps.Count - 1 do
  begin
    B := TCastleButton.Create(FreeAtStop);
    B.Caption := FMaps[I];
    B.Tag := I;
    B.FontSize := 24;
    B.AutoSizeWidth := False;
    B.Width := 660;
    B.OnClick := @ClickMap;
    GroupMaps.InsertFront(B);
  end;
  ButtonQuit.OnClick := @ClickQuit;
  LabelInfo.Caption := Format('Maps: %d   Files: %d in %d PK4s / directories   Materials: %d   (Tab: %s)',
    [FMaps.Count, D3Fs.FileCount, D3Fs.SourceCount, Decls.DeclCount(dtMaterial),
     Iff(D3Fs.FileExists(MenuGuiPath), 'the menu GUI', 'no menu GUI in the data')]);
  { a game under this view must not see our clicks }
  InterceptInput := True;
  FDemo.Clear;
  if AutoTestDemo <> '' then
    FDemo.AddStrings(AutoTestDemo.Split([',']));
  FDemoIndex := 0;
  FDemoWait := 0;
  FShots := 0;
  SetGuiShown(UseMenuGui and D3Fs.FileExists(MenuGuiPath));
end;

procedure TViewMenu.Stop;
begin
  { freed with FreeAtStop }
  FGuiImage := nil;
  FGuiBack := nil;
  FreeAndNil(FGui);
  InGame := False;
  if FMusic <> nil then
    FMusic.Stop;
  inherited Stop;
end;

function TViewMenu.GuiShown: Boolean;
begin
  Result := (FGui <> nil) and (FGuiImage <> nil) and FGuiImage.Exists;
end;

procedure TViewMenu.SetGuiShown(const Value: Boolean);
begin
  if Value and (FGui = nil) then
  begin
    FGui := TD3Gui.Create;
    if not FGui.LoadFromVfs(MenuGuiPath) then
    begin
      WritelnWarning('GameViewMenu', 'Cannot load "%s": our map list', [MenuGuiPath]);
      FreeAndNil(FGui);
    end else
    begin
      FGuiBack := TCastleRectangleControl.Create(FreeAtStop);
      FGuiBack.FullSize := True;
      FGuiBack.Color := Vector4(0, 0, 0, 1);
      InsertFront(FGuiBack);
      { 4:3 in the middle, like dhewm3 (sized in UpdateGui) }
      FGuiImage := TCastleImageControl.Create(FreeAtStop);
      FGuiImage.Stretch := True;
      FGuiImage.Anchor(hpMiddle);
      FGuiImage.Anchor(vpMiddle);
      InsertFront(FGuiImage);
      { idSessionLocal::StartMenu: the state, activation, "NoIntro" (no
        intro video) }
      FGui.SetState('inGame', IntToStr(Ord(InGame)));
      FGui.SetState('skill', '1');
      FGuiTimeMs := 0;
      FGui.Activate(0);
      FGui.NamedEvent('NoIntro');
      FGuiRedraw := 0;
      WritelnLog('GameViewMenu', 'Menu GUI "%s" (%d windows%s)',
        [MenuGuiPath, FGui.WindowCount, Iff(InGame, ', in game', '')]);
    end;
  end;
  if FGuiImage <> nil then
  begin
    FGuiImage.Exists := Value and (FGui <> nil);
    FGuiBack.Exists := FGuiImage.Exists;
  end;
  RootGroup.Exists := not GuiShown;
end;

function TViewMenu.GuiSound(const ShaderName: String): TCastleSound;
var
  Shader: TD3SoundShader;
  Key: String;
begin
  { a GUI sound: 2D, its shader's first file (long ones streamed) }
  Result := nil;
  Key := LowerCase(Trim(ShaderName));
  if Key = '' then
    Exit;
  if FSounds.TryGetValue(Key, Result) then
    Exit;
  Shader := Decls.SoundShader(Key);
  if (Shader <> nil) and (Shader.Files.Count > 0) and D3Fs.FileExists(Shader.Files[0]) then
  begin
    Result := TCastleSound.Create(nil);
    Result.Stream := Pos('music', LowerCase(Shader.Files[0])) > 0;
    Result.Url := D3FsUrl(Shader.Files[0]);
    Result.Volume := Min(1, Power(10, Shader.Volume / 20));
  end else
    WritelnLog('GameViewMenu', 'Menu sound "%s" not found', [ShaderName]);
  FSounds.Add(Key, Result);
end;

procedure TViewMenu.PlayGuiSound(const ShaderName: String);
var
  Sound: TCastleSound;
begin
  Sound := GuiSound(ShaderName);
  if Sound <> nil then
    SoundEngine.Play(Sound);
end;

procedure TViewMenu.PlayMusic(const ShaderName: String);
var
  Sound: TCastleSound;
begin
  { idSessionLocal: the menu's music loops until the menu goes }
  if FMusic <> nil then
    FMusic.Stop;
  Sound := GuiSound(ShaderName);
  if Sound = nil then
    Exit;
  if FMusic = nil then
    FMusic := TCastlePlayingSound.Create(Self);
  FMusic.Sound := Sound;
  FMusic.Loop := True;
  SoundEngine.Play(FMusic);
end;

procedure TViewMenu.StartMap(const AMapName: String);
begin
  WritelnLog('GameViewMenu', 'Start map "%s"', [AMapName]);
  if AutoTestPrefix <> '' then
  begin
    { an autotest of the menu ends here }
    SaveShot;
    Application.Terminate;
    Exit;
  end;
  ViewPlay.MapName := AMapName;
  Container.View := ViewPlay;
end;

procedure TViewMenu.Leave;
begin
  { "close" / Escape: back to the game under this view, else nothing
    (Doom 3's title menu stays) }
  if InGame then
    Container.PopView(Self);
end;

procedure TViewMenu.QuitGame;
begin
  { Quit Current Game: the title menu (an autotest of the game ends) }
  WritelnLog('GameViewMenu', 'Quit the current game');
  if ViewPlay.AutoTestPrefix <> '' then
  begin
    Application.Terminate;
    Exit;
  end;
  InGame := False;
  Container.View := ViewMenu;
end;

procedure TViewMenu.GuiCommands(const Cmd: String);
var
  Part: String;
  Words: TStringArray;
begin
  WritelnLog('GameViewMenu', 'Menu GUI: "%s"', [Cmd]);
  for Part in Cmd.Split([';']) do
  begin
    Words := Trim(Part).Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
    if Length(Words) = 0 then
      Continue;
    { idSessionLocal::HandleMainMenuCommands }
    case LowerCase(Words[0]) of
      'startgame':
        begin
          { gui::skill: Doom 3's g_skill (not used here yet) }
          WritelnLog('GameViewMenu', 'New game, skill %s', [FGui.StateValue('skill')]);
          if Length(Words) > 1 then
            StartMap(Words[1])
          else
            StartMap('game/mars_city1');
          Exit;
        end;
      'quit':
        begin
          Application.Terminate;
          Exit;
        end;
      'close':
        begin
          Leave;
          Exit;
        end;
      'disconnect':
        begin
          { Quit Current Game: the title menu }
          QuitGame;
          Exit;
        end;
      'exec':
        if (Length(Words) > 1) and SameText(Words[1], 'disconnect') then
        begin
          QuitGame;
          Exit;
        end;
      'maplist':
        begin
          { ours (the test menu's MAP LIST): the map list }
          SetGuiShown(False);
          Exit;
        end;
      'play':
        if Length(Words) > 1 then
          PlayGuiSound(Words[1]);
      'music':
        if Length(Words) > 1 then
          PlayMusic(Words[1]);
      else
        if FNotSupported.IndexOf(LowerCase(Words[0])) < 0 then
        begin
          FNotSupported.Add(LowerCase(Words[0]));
          WritelnLog('GameViewMenu', 'Not supported yet: menu command "%s"', [Trim(Part)]);
        end;
    end;
  end;
end;

procedure TViewMenu.UpdateGui(const SecondsPassed: Single);
var
  R: TFloatRectangle;
  P: TVector2;
  Down: Boolean;
  Cmd: String;
  RenderStart: TTimerResult;
begin
  if not GuiShown then
    Exit;
  FGuiTimeMs := FGuiTimeMs + SecondsPassed * 1000;
  FGui.Update(Round(FGuiTimeMs));
  { the largest 4:3 rectangle in the window (unscaled UI units) }
  R := FloatRectangle(0, 0, Container.UnscaledWidth, Container.UnscaledHeight);
  FGuiImage.Width := Min(R.Width, R.Height * 4 / 3) / UIScale;
  FGuiImage.Height := Min(R.Height, R.Width * 3 / 4) / UIScale;
  { the mouse on the 640 x 480 GUI (CGE's y goes up); a demo script sets
    the cursor itself }
  R := FGuiImage.RenderRect;
  if (FDemo.Count = 0) and (R.Width > 0) and (R.Height > 0) then
  begin
    P := Container.MousePosition;
    FGui.SetCursor(EnsureRange((P.X - R.Left) / R.Width * GuiWidth, 0, GuiWidth),
      EnsureRange((1 - (P.Y - R.Bottom) / R.Height) * GuiHeight, 0, GuiHeight));
    Down := buttonLeft in Container.MousePressed;
    if Down and not FMouseDown then
      FGui.Click
    else
    if FMouseDown and not Down then
      FGui.ClickRelease;
    FMouseDown := Down;
  end;
  Cmd := FGui.TakeCmd;
  if Cmd <> '' then
  begin
    GuiCommands(Cmd);
    if not GuiShown then
      Exit;
  end;
  FGuiRedraw := FGuiRedraw - SecondsPassed;
  if (FGuiRedraw <= 0) or (FGuiImage.Image = nil) then
  begin
    RenderStart := Timer;
    FGuiImage.Image := RenderGui(FGui, nil, MenuImageWidth, MenuImageHeight);
    FGuiImage.OwnsImage := True;
    { the first renders also load the images: renders 31 to 90 are timed }
    Inc(FRenders);
    if FRenders > 30 then
      FRenderSeconds := FRenderSeconds + TimerSeconds(Timer, RenderStart);
    if FRenders = 90 then
      WritelnLog('GameViewMenu', 'Menu GUI: %.1f ms a render (renders 31 to 90)', [FRenderSeconds / 60 * 1000]);
    FGuiRedraw := 1 / MenuRedrawRate;
  end;
end;

procedure TViewMenu.GuiClick(const X, Y: Single);
begin
  if not GuiShown then
    Exit;
  FGui.SetCursor(X, Y);
  WritelnLog('GameViewMenu', 'Menu click at %.0f %.0f', [X, Y]);
  FGui.Click;
  FGui.ClickRelease;
  { a demo script owns the cursor from now on }
  if FDemo.Count = 0 then
    FDemo.Add('');
end;

procedure TViewMenu.GuiEscape;
begin
  if GuiShown then
    FGui.KeyDown(27, #0)
  else
    Leave;
end;

procedure TViewMenu.SaveShot;
var
  Img: TCastleImage;
  FileName: String;
begin
  Inc(FShots);
  if FShots = 1 then
    FileName := AutoTestPrefix + '_menu.png'
  else
    FileName := AutoTestPrefix + '_menu' + IntToStr(FShots) + '.png';
  Img := Container.SaveScreen;
  try
    SaveImage(Img, FileName);
  finally
    Img.Free;
  end;
  WritelnLog('AutoTest', 'Menu screenshot saved: %s', [FileName]);
end;

procedure TViewMenu.RunDemo(const SecondsPassed: Single);
var
  C, Arg: String;
  Words: TStringArray;
begin
  if FDemoWait > 0 then
  begin
    FDemoWait := FDemoWait - SecondsPassed;
    Exit;
  end;
  while FDemoIndex < FDemo.Count do
  begin
    C := Trim(FDemo[FDemoIndex]);
    Inc(FDemoIndex);
    Arg := Copy(C, 3, MaxInt);
    case UpCase(Copy(C, 1, 1)) of
      'W':
        begin
          FDemoWait := StrToFloatDef(Arg, 1, DefaultFormatSettings);
          Exit;
        end;
      'S': SaveShot;
      'C':
        begin
          { a click at GUI coordinates }
          Words := Arg.Split([' '], TStringSplitOptions.ExcludeEmpty);
          if Length(Words) >= 2 then
            GuiClick(StrToFloatDef(Words[0], 0, DefaultFormatSettings),
              StrToFloatDef(Words[1], 0, DefaultFormatSettings));
        end;
      'K':
        if SameText(Arg, 'esc') then
          GuiEscape;
      'P':
        { a sampling profile (an -Xm build): P:start, P:stop }
        if SameText(Arg, 'start') then
          SamplerStart
        else
          SamplerStopAndReport('Menu');
      'Q':
        begin
          Application.Terminate;
          Exit;
        end;
    end;
  end;
end;

procedure TViewMenu.Update(const SecondsPassed: Single; var HandleInput: Boolean);
begin
  inherited Update(SecondsPassed, HandleInput);
  UpdateGui(SecondsPassed);
  if AutoTestPrefix = '' then
    Exit;
  if FDemo.Count > 0 then
  begin
    RunDemo(SecondsPassed);
    Exit;
  end;
  FAutoTestTime := FAutoTestTime + SecondsPassed;
  { the menu GUI's opening animation takes a few seconds }
  if FAutoTestTime > Iff(GuiShown, 4, 1) then
  begin
    SaveShot;
    AutoTestPrefix := '';
    Application.Terminate;
  end;
end;

procedure TViewMenu.ClickMap(Sender: TObject);
begin
  ViewPlay.MapName := FMaps[TCastleButton(Sender).Tag];
  Container.View := ViewPlay;
end;

procedure TViewMenu.ClickQuit(Sender: TObject);
begin
  Application.Terminate;
end;

function TViewMenu.Press(const Event: TInputPressRelease): Boolean;
begin
  Result := inherited Press(Event);
  if Result then
    Exit;
  { Tab: Doom 3's menu or our map list }
  if Event.IsKey(keyTab) and ((FGui <> nil) or (UseMenuGui and D3Fs.FileExists(MenuGuiPath))) then
  begin
    SetGuiShown(not GuiShown);
    Exit(True);
  end;
  if GuiShown then
  begin
    { keys go to the GUI: an edit's typing, escape to onEsc ("close") }
    if (Event.EventType = itKey) and GuiKey(FGui, Event) then
      Exit(True);
    Exit(Event.EventType = itKey);
  end;
  if Event.IsKey(keyEnter) and (FMaps <> nil) and (FMaps.Count > 0) then
  begin
    ViewPlay.MapName := FMaps[0];
    Container.View := ViewPlay;
    Exit(True);
  end;
  if Event.IsKey(keyEscape) then
  begin
    if InGame then
      Leave
    else
      Application.Terminate;
    Exit(True);
  end;
end;

end.
