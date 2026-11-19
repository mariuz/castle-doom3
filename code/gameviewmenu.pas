{ The title screen. With Doom 3's data it is Doom 3's main menu GUI
  (guis/mainmenu.gui, like idSessionLocal::StartMenu): drawn full screen,
  the mouse and keys go to it, its commands start the game ("startgame"),
  quit, go back to the game ("close") or play GUI sounds. Without that
  file (the test data), or after Tab, a button per map found in the loaded
  PK4s; its components are designed in
  data/gameviewmenu.castle-user-interface .

  The "Doom 3 data..." button (bottom right, or F2) opens the data panel:
  the Doom 3 installs found on this computer (GOG, Steam, BFG, the demo;
  Doom3Installs), the test level alone, and a download of the free Doom 3
  demo (Doom3DemoDownload, asked first, with its progress). A choice is
  saved in data.cfg and the game starts again with it. It opens by itself
  on the first start without any Doom 3 data or choice.

  Escape in the game pushes this view over it (the game pauses):
  "close" pops it again, like Doom 3's in-game menu. }
unit GameViewMenu;

{$mode objfpc}{$H+}

interface

uses
  Classes, Generics.Collections,
  CastleUIControls, CastleControls, CastleKeysMouse, CastleSoundEngine,
  Doom3Gui, Doom3Installs, Doom3DemoDownload;

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
    { the data panel (see the unit's comment) }
    FDataButton: TCastleButton;
    { classic mode (D3ClassicMode), above the data button }
    FClassicButton: TCastleButton;
    FDataPanel: TCastleRectangleControl;
    FDataGroup: TCastleVerticalGroup;
    FDataStatus: TCastleLabel;
    FProgressBack, FProgressBar: TCastleRectangleControl;
    FInstalls: TD3InstallList;
    FDownload: TD3DemoDownload;
    FDataConfirm: Boolean;
    FDataShownOnce: Boolean;
    FDownloadDoneShown: Boolean;
    procedure CreateDataControls;
    procedure ShowDataPanel(const Value: Boolean);
    procedure RebuildDataPanel;
    function DataLabel(const Text: String; const Size: Single; const Gray: Single = 0.75): TCastleLabel;
    function DataButton(const Caption: String; const ATag: Integer; const Event: TNotifyEvent): TCastleButton;
    procedure ClickData(Sender: TObject);
    procedure ClickClassic(Sender: TObject);
    procedure SetClassic(const Value: Boolean);
    procedure ClickInstall(Sender: TObject);
    procedure ClickTestOnly(Sender: TObject);
    procedure ClickDownload(Sender: TObject);
    procedure ClickDownloadYes(Sender: TObject);
    procedure ClickDownloadCancel(Sender: TObject);
    procedure ClickDataBack(Sender: TObject);
    procedure StartDownload;
    procedure UpdateDownload;
    function DownloadRunning: Boolean;
    procedure UseData(const BasePath, GameDir: String);
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
    { the data panel is open }
    function DataPanelShown: Boolean;
  end;

var
  ViewMenu: TViewMenu;
  { console g_menuGui: Doom 3's main menu GUI when the data has it }
  UseMenuGui: Boolean = True;

{ All maps with a .proc file: "testmap", "game/mars_city1"... }
function ListMaps: TStringList;

implementation

uses
  SysUtils, Math, Process,
  CastleWindow, CastleImages, CastleLog, CastleVectors, CastleRectangles, CastleUtils, CastleTimeUtils,
  Doom3Files, Doom3Decls, Doom3Sampler, Doom3Level, GameViewPlay;

const
  { software rendered (about ten full screen layers): at most this many
    redraws a second, at this size (the 640 x 480 GUI fills the screen, so
    more than the in-world 512) }
  MenuRedrawRate = 20;
  MenuImageWidth = 800;
  MenuImageHeight = 600;

{ idSessionLocal: the demo's menu is guis/demo_mainmenu.gui (the demo data
  has no mainmenu.gui; the test PK4's would show instead) }
function MenuGuiPath: String;
begin
  if D3Fs.FileExists('guis/demo_mainmenu.gui') then
    Result := 'guis/demo_mainmenu.gui'
  else
    Result := 'guis/mainmenu.gui';
end;

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
  if FDownload <> nil then
  begin
    FDownload.Cancel;
    FDownload.WaitFor;
    FreeAndNil(FDownload);
  end;
  FInstalls.Free;
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
  CreateDataControls;
  { the first start without Doom 3 data or a choice: the data panel }
  if (AutoTestPrefix = '') and (not InGame) and (not FDataShownOnce) and
     (DataBasePathInUse = '') and (not DataChoiceSaved) and (not DataFromCommandLine) then
    ShowDataPanel(True);
end;

procedure TViewMenu.Stop;
begin
  { freed with FreeAtStop }
  FGuiImage := nil;
  FGuiBack := nil;
  { freed with FreeAtStop too (FDataGroup is owned by the panel) }
  FDataButton := nil;
  FClassicButton := nil;
  FDataPanel := nil;
  FDataGroup := nil;
  FDataStatus := nil;
  FProgressBack := nil;
  FProgressBar := nil;
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
      { the data button and panel stay in front }
      if FDataButton <> nil then
      begin
        RemoveControl(FDataButton);
        InsertFront(FDataButton);
        RemoveControl(FClassicButton);
        InsertFront(FClassicButton);
        RemoveControl(FDataPanel);
        InsertFront(FDataPanel);
      end;
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
      'datamenu':
        begin
          { ours: the data panel }
          ShowDataPanel(True);
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
  P := Container.MousePosition;
  if (FDemo.Count = 0) and (R.Width > 0) and (R.Height > 0) and (not DataPanelShown) and
     not ((FDataButton <> nil) and FDataButton.RenderRect.Contains(P)) and
     not ((FClassicButton <> nil) and FClassicButton.RenderRect.Contains(P)) then
  begin
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
  I: Integer;
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
      'D':
        begin
          { the data panel: D:open, D:close, D:pick <n> (1 is the first
            install listed, 0 the test level), D:download (asks), D:yes,
            D:cancel, D:wait (until the download is over); D:classic 0|1
            sets classic mode for this run (the button also saves it) }
          Words := Arg.Split([' '], TStringSplitOptions.ExcludeEmpty);
          if Length(Words) = 0 then
            Continue;
          case LowerCase(Words[0]) of
            'open': ShowDataPanel(True);
            'classic': SetClassic((Length(Words) < 2) or (Words[1] <> '0'));
            'close': ShowDataPanel(False);
            'download': ClickDownload(nil);
            'yes': ClickDownloadYes(nil);
            'cancel': ClickDownloadCancel(nil);
            'wait':
              if DownloadRunning then
              begin
                Dec(FDemoIndex);
                Exit;
              end;
            'pick':
              if Length(Words) > 1 then
              begin
                if not DataPanelShown then
                  ShowDataPanel(True);
                I := StrToIntDef(Words[1], -1);
                if I = 0 then
                  ClickTestOnly(nil)
                else
                if (I >= 1) and (I <= FInstalls.Count) then
                  UseData(FInstalls[I - 1].BasePath, FInstalls[I - 1].GameDir)
                else
                  WritelnWarning('GameViewMenu', 'D:pick %s: no such install', [Words[1]]);
                if Application.Terminated then
                  Exit;
              end;
          end;
        end;
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
  UpdateDownload;
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
  { F2: the data panel }
  if Event.IsKey(keyF2) then
  begin
    ShowDataPanel(not DataPanelShown);
    Exit(True);
  end;
  if DataPanelShown then
  begin
    if Event.IsKey(keyEscape) then
    begin
      if FDataConfirm then
        ClickDownloadCancel(nil)
      else
      if not DownloadRunning then
        ShowDataPanel(False);
    end;
    Exit(Event.EventType = itKey);
  end;
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

{ The data panel ------------------------------------------------------------ }

function MegaBytes(const Bytes: Int64): String;
begin
  Result := Format('%d MB', [Round(Bytes / (1024 * 1024))]);
end;

{ the demo download's URL (env CD3_DEMO_URL for another mirror) }
function DemoDownloadUrl: String;
begin
  Result := GetEnvironmentVariable('CD3_DEMO_URL');
  if Result = '' then
    Result := DemoUrl;
end;

procedure TViewMenu.CreateDataControls;
begin
  FDataButton := TCastleButton.Create(FreeAtStop);
  FDataButton.Caption := 'Doom 3 data...';
  FDataButton.FontSize := 20;
  FDataButton.Anchor(hpRight, -20);
  FDataButton.Anchor(vpBottom, 20);
  FDataButton.OnClick := @ClickData;
  InsertFront(FDataButton);

  FClassicButton := TCastleButton.Create(FreeAtStop);
  FClassicButton.FontSize := 20;
  FClassicButton.Anchor(hpRight, -20);
  FClassicButton.Anchor(vpBottom, 70);
  FClassicButton.OnClick := @ClickClassic;
  InsertFront(FClassicButton);
  SetClassic(D3ClassicMode);

  FDataPanel := TCastleRectangleControl.Create(FreeAtStop);
  FDataPanel.FullSize := True;
  FDataPanel.Color := Vector4(0.03, 0.03, 0.05, 1);
  FDataPanel.Exists := False;
  InsertFront(FDataPanel);
end;

function TViewMenu.DataPanelShown: Boolean;
begin
  Result := (FDataPanel <> nil) and FDataPanel.Exists;
end;

procedure TViewMenu.ShowDataPanel(const Value: Boolean);
var
  I: Integer;
begin
  if FDataPanel = nil then
    Exit;
  if Value then
  begin
    FDataShownOnce := True;
    FDataConfirm := False;
    FreeAndNil(FInstalls);
    FInstalls := DetectInstalls;
    WritelnLog('GameViewMenu', 'Data: %d Doom 3 installs found%s', [FInstalls.Count,
      Iff(DataBasePathInUse <> '', Format(', in use "%s" %s', [DataBasePathInUse, DataGameDirInUse]), ', the test level in use')]);
    for I := 0 to FInstalls.Count - 1 do
      WritelnLog('GameViewMenu', 'Data %d: %s "%s"%s', [I + 1, FInstalls[I].Title, FInstalls[I].BasePath,
        Iff(FInstalls[I].GameDir <> '', ' -game ' + FInstalls[I].GameDir, '')]);
    RebuildDataPanel;
  end;
  FDataPanel.Exists := Value;
  FDataButton.Exists := not Value;
  FClassicButton.Exists := not Value;
end;

procedure TViewMenu.SetClassic(const Value: Boolean);
begin
  D3ClassicMode := Value;
  { the 2004 game's look on BFG data, or Doom 3 BFG's }
  FClassicButton.Caption := Iff(Value, 'Classic look: on (Doom 3 2004)', 'Classic look: off (Doom 3 BFG)');
  WritelnLog('GameViewMenu', 'Classic mode %s', [BoolToStr(Value, 'on', 'off')]);
end;

procedure TViewMenu.ClickClassic(Sender: TObject);
begin
  SetClassic(not D3ClassicMode);
  SaveClassicChoice(D3ClassicMode);
end;

function TViewMenu.DataLabel(const Text: String; const Size: Single; const Gray: Single): TCastleLabel;
begin
  Result := TCastleLabel.Create(FDataGroup);
  Result.Caption := Text;
  Result.FontSize := Size;
  Result.Color := Vector4(Gray, Gray, Gray, 1);
  Result.MaxWidth := 1100;
  FDataGroup.InsertFront(Result);
end;

function TViewMenu.DataButton(const Caption: String; const ATag: Integer; const Event: TNotifyEvent): TCastleButton;
begin
  Result := TCastleButton.Create(FDataGroup);
  Result.Caption := Caption;
  Result.Tag := ATag;
  Result.FontSize := 22;
  Result.AutoSizeWidth := False;
  Result.Width := 1100;
  Result.OnClick := Event;
  FDataGroup.InsertFront(Result);
end;

procedure TViewMenu.RebuildDataPanel;
var
  I: Integer;
  Inst: TD3Install;
  InUse, DemoFound: Boolean;
  Caption, Note: String;
begin
  FreeAndNil(FDataGroup);
  FDataStatus := nil;
  FProgressBack := nil;
  FProgressBar := nil;
  FDataGroup := TCastleVerticalGroup.Create(FDataPanel);
  FDataGroup.Anchor(hpMiddle);
  FDataGroup.Anchor(vpTop, -40);
  FDataGroup.Alignment := hpMiddle;
  FDataGroup.Spacing := 10;
  FDataPanel.InsertFront(FDataGroup);

  DataLabel('DOOM 3 DATA', 48, 0.9).Color := Vector4(0.85, 0.15, 0.1, 1);
  if DataBasePathInUse <> '' then
    Note := 'In use: ' + DataBasePathInUse + Iff(DataGameDirInUse <> '', ' (' + DataGameDirInUse + ')', '')
  else
  if D3Fs.SourceCount > 1 then
    Note := 'In use: Doom 3 data next to the program'
  else
    Note := 'In use: the bundled test level only';
  DataLabel(Note, 20);
  if DataFromCommandLine then
    DataLabel('The command line (-basepath, -pk4) or a base/ or demo/ folder next to the program gives the data: ' +
      'a choice here applies when the game starts without them.', 18, 0.6);

  if FDataConfirm then
  begin
    DataLabel('', 10);
    DataLabel(Format('Download the free Doom 3 demo (id Software, 2004: three maps of Mars City) from %s?',
      ['ftp.gwdg.de, a mirror of id Software''s FTP']), 22, 0.9);
    DataLabel(Format('It downloads %s (the Linux demo, which has the data for every system), keeps only its ' +
      'demo00.pk4 (%s) in "%s" and checks its MD5.',
      [MegaBytes(DemoRunSize), MegaBytes(DemoPk4Size), DownloadedDemoBasePath]), 18);
    DataButton('Download (' + MegaBytes(DemoRunSize) + ')', 0, @ClickDownloadYes);
    DataButton('Cancel', 0, @ClickDownloadCancel);
    Exit;
  end;

  if DownloadRunning then
  begin
    DataLabel('', 10);
    FDataStatus := DataLabel('Downloading the Doom 3 demo...', 22, 0.9);
    FProgressBack := TCastleRectangleControl.Create(FDataGroup);
    FProgressBack.Width := 800;
    FProgressBack.Height := 24;
    FProgressBack.Color := Vector4(0.15, 0.15, 0.18, 1);
    FDataGroup.InsertFront(FProgressBack);
    FProgressBar := TCastleRectangleControl.Create(FProgressBack);
    FProgressBar.Height := 24;
    FProgressBar.Width := 0;
    FProgressBar.Color := Vector4(0.8, 0.2, 0.1, 1);
    FProgressBack.InsertFront(FProgressBar);
    DataButton('Cancel the download', 0, @ClickDownloadCancel);
    UpdateDownload;
    Exit;
  end;

  DataLabel('', 6);
  if FInstalls.Count = 0 then
    DataLabel('No Doom 3 found (GOG, Steam, the BFG edition or the demo). Download the free demo below, ' +
      'or start the game with -basepath "<Doom 3 folder>".', 18, 0.6)
  else
    DataLabel('Found on this computer (the game starts again with your choice):', 18, 0.6);
  DemoFound := False;
  for I := 0 to FInstalls.Count - 1 do
  begin
    Inst := FInstalls[I];
    if Inst.Kind = ikDemo then
      DemoFound := True;
    InUse := SamePath(Inst.BasePath, DataBasePathInUse) and SameText(Inst.GameDir, DataGameDirInUse);
    Caption := Format('%d. %s   %s', [I + 1, Inst.Title, Inst.BasePath]);
    if InUse then
      Caption := Caption + '   [in use]';
    DataButton(Caption, I, @ClickInstall);
  end;
  DataButton('0. The bundled test level only' + Iff((DataBasePathInUse = '') and (D3Fs.SourceCount <= 1), '   [in use]', ''),
    0, @ClickTestOnly);
  if not DemoFound then
    DataButton('Download the free Doom 3 demo (' + MegaBytes(DemoRunSize) + ')...', 0, @ClickDownload);
  if FDownload <> nil then
  begin
    { the last download's result }
    if FDownloadDoneShown then
      DataLabel('The Doom 3 demo is downloaded: choose it above.', 20, 0.9)
    else
      FDataStatus := DataLabel('', 20, 0.9);
  end;
  DataButton('Back', 0, @ClickDataBack);
end;

procedure TViewMenu.ClickData(Sender: TObject);
begin
  ShowDataPanel(True);
end;

procedure TViewMenu.ClickInstall(Sender: TObject);
var
  I: Integer;
begin
  I := TCastleButton(Sender).Tag;
  if (FInstalls <> nil) and (I >= 0) and (I < FInstalls.Count) then
    UseData(FInstalls[I].BasePath, FInstalls[I].GameDir);
end;

procedure TViewMenu.ClickTestOnly(Sender: TObject);
begin
  UseData('', '');
end;

procedure TViewMenu.ClickDownload(Sender: TObject);
begin
  if DownloadRunning then
    Exit;
  if not DataPanelShown then
    ShowDataPanel(True);
  FDataConfirm := True;
  WritelnLog('GameViewMenu', 'Data: asking before the demo download (%s)', [MegaBytes(DemoRunSize)]);
  RebuildDataPanel;
end;

procedure TViewMenu.ClickDownloadYes(Sender: TObject);
begin
  if not FDataConfirm then
    Exit;
  FDataConfirm := False;
  StartDownload;
end;

procedure TViewMenu.ClickDownloadCancel(Sender: TObject);
begin
  if FDataConfirm then
  begin
    FDataConfirm := False;
    RebuildDataPanel;
  end else
  if DownloadRunning then
  begin
    WritelnLog('GameViewMenu', 'Data: cancelling the demo download');
    FDownload.Cancel;
  end;
end;

procedure TViewMenu.ClickDataBack(Sender: TObject);
begin
  ShowDataPanel(False);
end;

function TViewMenu.DownloadRunning: Boolean;
var
  State: TD3DemoDownloadState;
  Done, Total: Int64;
  Error: String;
begin
  Result := False;
  if FDownload = nil then
    Exit;
  FDownload.GetProgress(State, Done, Total, Error);
  Result := State in [ddsDownloading, ddsExtracting];
end;

procedure TViewMenu.StartDownload;
begin
  if DownloadRunning then
    Exit;
  if FDownload <> nil then
  begin
    FDownload.WaitFor;
    FreeAndNil(FDownload);
  end;
  FDownloadDoneShown := False;
  WritelnLog('GameViewMenu', 'Data: downloading the Doom 3 demo from %s', [DemoDownloadUrl]);
  FDownload := TD3DemoDownload.Create(DemoDownloadUrl, DownloadedDemoBasePath);
  RebuildDataPanel;
end;

procedure TViewMenu.UpdateDownload;
var
  State: TD3DemoDownloadState;
  Done, Total: Int64;
  Error: String;
  Fraction: Single;
begin
  if FDownload = nil then
    Exit;
  FDownload.GetProgress(State, Done, Total, Error);
  if Total > 0 then
    Fraction := EnsureRange(Done / Total, 0, 1)
  else
    Fraction := 0;
  if (FProgressBar <> nil) and (State in [ddsDownloading, ddsExtracting]) then
    FProgressBar.Width := 800 * Fraction;
  if FDataStatus <> nil then
    case State of
      ddsDownloading: FDataStatus.Caption := Format('Downloading the Doom 3 demo: %s of %s (%d%%)',
        [MegaBytes(Done), MegaBytes(Total), Round(Fraction * 100)]);
      ddsExtracting: FDataStatus.Caption := Format('Extracting demo/demo00.pk4: %d%%', [Round(Fraction * 100)]);
      ddsFailed: FDataStatus.Caption := 'The download failed: ' + Error;
      ddsCancelled: FDataStatus.Caption := 'The download was cancelled.';
    end;
  { over: the list again, with the demo when it's there }
  if (not (State in [ddsDownloading, ddsExtracting])) and (FProgressBar <> nil) then
  begin
    FDownloadDoneShown := State = ddsDone;
    if State = ddsDone then
      WritelnLog('GameViewMenu', 'Data: the Doom 3 demo is downloaded');
    if DataPanelShown then
      ShowDataPanel(True)
    else
      RebuildDataPanel;
    { the failure's message (ShowDataPanel made a new status label) }
    UpdateDownload;
  end;
end;

procedure TViewMenu.UseData(const BasePath, GameDir: String);
var
  P: TProcess;
  I: Integer;
begin
  SaveDataChoice(BasePath, GameDir);
  WritelnLog('GameViewMenu', 'Data chosen: basepath "%s", game "%s"', [BasePath, GameDir]);
  { env CD3_DATA_RESTART=1: an autotest starts the game again too (to
    test that; the new game is a plain one, not an autotest) }
  if (AutoTestPrefix <> '') and (GetEnvironmentVariable('CD3_DATA_RESTART') <> '1') then
  begin
    { an autotest ends here (the next run with --data-config loads it) }
    WritelnLog('GameViewMenu', 'Data: autotest, not starting again');
    SaveShot;
    Application.Terminate;
    Exit;
  end;
  { the data is mounted at the start: start the game again (with the same
    sound and window options) }
  WritelnLog('GameViewMenu', 'Data: starting the game again');
  P := TProcess.Create(nil);
  try
    P.Executable := ParamStr(0);
    for I := 1 to ParamCount do
      if (ParamStr(I) = '--mute') or (ParamStr(I) = '--minimized') then
        P.Parameters.Add(ParamStr(I));
    P.CurrentDirectory := GetCurrentDir;
    P.InheritHandles := False;
    try
      P.Execute;
    except
      on E: Exception do
        WritelnWarning('GameViewMenu', 'Cannot start the game again (%s): start it yourself', [E.Message]);
    end;
  finally
    P.Free;
  end;
  Application.Terminate;
end;

end.
