{ The title screen: a button per map found in the loaded PK4s.
  Its components are designed in data/gameviewmenu.castle-user-interface . }
unit GameViewMenu;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  CastleUIControls, CastleControls, CastleKeysMouse;

type
  TViewMenu = class(TCastleView)
  published
    { Components designed using CGE editor.
      These fields will be automatically initialized at Start. }
    GroupMaps: TCastleVerticalGroup;
    ButtonQuit: TCastleButton;
    LabelInfo: TCastleLabel;
  private
    FMaps: TStringList;
    FAutoTestTime: Single;
    procedure ClickMap(Sender: TObject);
    procedure ClickQuit(Sender: TObject);
  public
    { --autotest MENU <prefix>: save <prefix>_menu.png and quit }
    AutoTestPrefix: String;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Start; override;
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
    function Press(const Event: TInputPressRelease): Boolean; override;
  end;

var
  ViewMenu: TViewMenu;

{ All maps with a .proc file: "testmap", "game/mars_city1"... }
function ListMaps: TStringList;

implementation

uses
  SysUtils,
  CastleWindow, CastleImages, CastleLog,
  Doom3Files, Doom3Decls, GameViewPlay;

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
end;

destructor TViewMenu.Destroy;
begin
  FMaps.Free;
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
  LabelInfo.Caption := Format('Maps: %d   Files: %d in %d PK4s / directories   Materials: %d',
    [FMaps.Count, D3Fs.FileCount, D3Fs.SourceCount, Decls.DeclCount(dtMaterial)]);
end;

procedure TViewMenu.Update(const SecondsPassed: Single; var HandleInput: Boolean);
var
  Img: TCastleImage;
begin
  inherited Update(SecondsPassed, HandleInput);
  if AutoTestPrefix = '' then
    Exit;
  FAutoTestTime := FAutoTestTime + SecondsPassed;
  if FAutoTestTime > 1 then
  begin
    Img := Container.SaveScreen;
    try
      SaveImage(Img, AutoTestPrefix + '_menu.png');
    finally
      Img.Free;
    end;
    WritelnLog('AutoTest', 'Menu screenshot saved');
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
  if Event.IsKey(keyEnter) and (FMaps <> nil) and (FMaps.Count > 0) then
  begin
    ViewPlay.MapName := FMaps[0];
    Container.View := ViewPlay;
    Exit(True);
  end;
  if Event.IsKey(keyEscape) then
  begin
    Application.Terminate;
    Exit(True);
  end;
end;

end.
