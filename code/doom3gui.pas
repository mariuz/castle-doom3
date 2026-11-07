// Doom 3 GUIs (.gui files): the windowDef tree drawn into an image for the
// guisurf surfaces of the level (wall screens, door panels, terminals).
//
// A GUI is a tree of windowDef (and editDef, choiceDef, listDef...) with
// properties like rect, backcolor, matcolor, background (a material or
// image), text, textscale, textalign, forecolor, visible. It is laid out on a
// 640 x 480 virtual screen. Text can come from the GUI state, which an
// entity fills from its "gui_*" keys: text "gui::gui_parm1".
//
// Windows have events with scripts (idWindow): onTime N (a timeline per
// window, restarted by resetTime), onAction (a click), onMouseEnter /
// onMouseExit (the cursor), onActivate, onNamedEvent. Script commands:
// set "window::prop" "value" (also "cmd": a command for the entity, and
// "gui::name": the state), transition "window::prop" "from" "to" "ms"
// [accel decel], resetTime [window] [ms], runScript "function" (a command
// for the entity), localSound, showCursor, if ( expr ) { } else { }.
// Property values can be expressions reading gui:: state, $variables
// (definevec4 / definefloat) and other windows' properties.
//
// Rendering is done in software into a TRGBAlphaImage (no OpenGL needed):
// rectangles, scaled backgrounds and text with Doom 3's fonts
// (fonts/<lang>/<name>/fontImage_NN.dat and their TGA pages; CGE's UI font
// when the data has none), blitted glyph by glyph, and the cursor
// (ui/assets/guicursor_arrow) where the player looks. The result is served
// to CGE through the "d3gui:" URL protocol (uncompressed TGA): static
// renders cached per (path, state), and one texture per live GUI surface
// (TD3GuiSurface) that gets a new URL version every time it's redrawn.
//
// Not done: window rotation / shear, editDef / choiceDef / listDef / slider
// input, onEvent / onTrigger, named events, focus and key events.
unit Doom3Gui;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleVectors, CastleImages, CastleRectangles, X3DNodes, CastleTransform, CastleBoxes;

type
  TD3GuiWindow = class;
  TD3Gui = class;
  TD3GuiFloats = array of Single;

  TD3GuiScript = class;

  { One command of a window script (idGuiScript). }
  TD3GuiCommand = class
    { lowercase: set, transition, resettime, runscript, localsound,
      showcursor, evalregs, setfocus, if, ... }
    Name: String;
    Args: TStringArray;
    { "if": the condition and its branches }
    Condition: String;
    ThenList, ElseList: TD3GuiScript;
    destructor Destroy; override;
  end;

  TD3GuiScript = class(specialize TObjectList<TD3GuiCommand>)
  end;

  TD3GuiTimeEvent = record
    { ms after the window's time line start }
    Time: Integer;
    Script: TD3GuiScript;
    { not fired since the last resetTime }
    Pending: Boolean;
  end;

  { The windowDef kinds with their own behavior (idChoiceWindow,
    idSliderWindow, idEditWindow, idListWindow, idBindWindow,
    idRenderWindow) }
  TD3GuiKind = (gkWindow, gkList, gkChoice, gkSlider, gkEdit, gkBind, gkRender);

  TD3GuiWindow = class
    Name: String;
    Kind: TD3GuiKind;
    { the keys without a field (choices, values, cvar, low, high, step,
      thumbshader, maxchars, rotate, shear...): lowercase key=value }
    Props: TStringList;
    { runtime: a choiceDef's choice, a sliderDef's value, an editDef's
      text }
    Choice: Integer;
    SliderValue: Single;
    EditText: String;
    OnEnter: TD3GuiScript;
    Parent: TD3GuiWindow;
    { left, top, width, height in the 640 x 480 virtual screen, relative
      to the parent window }
    Rect: TFloatRectangle;
    BackColor, ForeColor, MatColor, BorderColor: TVector4;
    BorderSize: Single;
    Background: String;
    Text: String;
    TextScale: Single;
    TextAlign: Integer; { 0 left, 1 center, 2 right }
    TextAlignX, TextAlignY: Single;
    Visible: Boolean;
    NoWrap: Boolean;
    { "font": fonts/<name>; '' inherits the parent's }
    Font: String;
    { noevents: the cursor and clicks pass through; notime: no time line;
      nocursor: no cursor drawn over it }
    NoEvents, NoTime, NoCursor: Boolean;
    { noclip: its text and children may draw outside its rect (Doom 3 clips
      them to it otherwise) }
    NoClip: Boolean;
    { a listDef (idListWindow): rows from the GUI state "<name>_item_<i>",
      columns split by tabs at Tabstops, the selection "<name>_sel_0" }
    IsList: Boolean;
    Tabstops: TD3GuiFloats;
    { "listName": the state keys' prefix (idListWindow; the window's name
      when not set) }
    ListName: String;
    { properties given as expressions (visible "gui::x", backcolor
      "$hilite"): name=expression, evaluated when drawn }
    Exprs: TStringList;
    { definevec4 / definefloat / float / vec4: name=value }
    Vars: TStringList;
    { events (nil: none) }
    OnAction, OnActionRelease, OnMouseEnter, OnMouseExit, OnActivate, OnDeactivate,
    OnEsc, OnTrigger: TD3GuiScript;
    { onEvent (Doom 3's ON_FRAME): every time the time line runs }
    OnFrame: TD3GuiScript;
    NamedEvents: specialize TObjectDictionary<String, TD3GuiScript>;
    TimeEvents: array of TD3GuiTimeEvent;
    Children: specialize TObjectList<TD3GuiWindow>;
    { runtime: the GUI time (ms) the window's time line started }
    TimeLine: Integer;
    { the child under the cursor (mouse enter / exit) }
    HoverChild: TD3GuiWindow;
    constructor Create;
    destructor Destroy; override;
    { Set a property from its text (the parser and the "set" command);
      non-numeric values of numeric properties become expressions. }
    procedure SetProp(const Key, Value: String);
    { Has onAction (or mouse events), or a child has: the cursor shows
      over it and clicks reach it (idWindow::Interactive). }
    function Interactive: Boolean;
    { The font for its text: its own or the nearest parent's. }
    function FontName: String;
    { a listDef's state key prefix: ListName, else its name }
    function ListKey: String;
    { A variable (definevec4...) by name, here or in a parent; '' if none. }
    function FindVar(const AName: String; out Value: String): Boolean;
    { a key of Props ('' if not set) }
    function Prop(const Key: String; const Default: String = ''): String;
    { a choiceDef's choices ("a;b;c", string table names translated) and
      values ('' items: none) }
    function ChoiceList: TStringArray;
    function ValueList: TStringArray;
  end;

  TD3GuiTransition = record
    Window: TD3GuiWindow;
    { lowercase property: backcolor, forecolor, matcolor, rect, textscale,
      visible... }
    Prop: String;
    From, To_: TVector4;
    { ms }
    Start, Duration: Integer;
    { fractions of the duration spent accelerating / decelerating }
    Accel, Decel: Single;
    function Value(const Time: Integer): TVector4;
    function Done(const Time: Integer): Boolean;
  end;

  { A loaded GUI with its state: window properties change by scripts and
    transitions, the cursor moves over it, it collects commands for its
    entity ("set cmd", runScript). }
  TD3Gui = class
  private
    FState: TStringList;
    FTransitions: specialize TList<TD3GuiTransition>;
    FCmd: String;
    FTime: Integer;
    FInteractive: Boolean;
    { the editDef taking the keys, the sliderDef being dragged }
    FFocus, FDrag: TD3GuiWindow;
    procedure InitWidgets(const W: TD3GuiWindow);
    procedure ApplyChoice(const W: TD3GuiWindow);
    procedure SliderFromCursor(const W: TD3GuiWindow; const X, Y: Single);
    procedure ResetTime(const W: TD3GuiWindow; const T: Integer);
    procedure RunTimeEvents(const W: TD3GuiWindow);
    procedure RunTransitions;
    procedure RouteCursor(const W: TD3GuiWindow; const X, Y: Single);
    function ClickWindow(const W: TD3GuiWindow; const X, Y: Single; const Release: Boolean): Boolean;
    procedure ActivateWindow(const W: TD3GuiWindow);
    procedure WindowAbs(const W: TD3GuiWindow; out Left, Top: Single);
    function ResolveWindow(const Ref: String; const Context: TD3GuiWindow; out Prop: String): TD3GuiWindow;
  public
    Name: String;
    Desktop: TD3GuiWindow;
    { the cursor in GUI coordinates while the player looks at it }
    CursorX, CursorY: Single;
    CursorShown: Boolean;
    { showCursor 0 }
    NoCursor: Boolean;
    { something to redraw (a property, the state or the cursor changed) }
    Dirty: Boolean;
    { the last render drew a video (videomap): it changes every frame }
    HasVideo: Boolean;
    Active: Boolean;
    constructor Create;
    destructor Destroy; override;
    function LoadFromText(const AText: String): Boolean;
    function LoadFromVfs(const Path: String): Boolean;
    function WindowCount: Integer;
    function FindWindow(const AName: String): TD3GuiWindow;

    { gui:: variables: the entity's keys (gui_parm...) and what scripts set }
    property State: TStringList read FState;
    procedure SetState(const Key, Value: String);
    function StateValue(const Key: String): String;
    { Copy the gui_* keys (and noninteractive) of an entity. }
    procedure StateFromKeys(const Keys: TStrings);
    { Has clickable windows and isn't "noninteractive": the player's view
      focuses it and the cursor shows. }
    property Interactive: Boolean read FInteractive;
    { ms (the map's time) }
    property Time: Integer read FTime;

    { Start: time lines from TimeMs, onActivate scripts. }
    procedure Activate(const TimeMs: Integer);
    { Run the time line events and transitions due at a time. }
    procedure Update(const TimeMs: Integer);
    { The cursor at a GUI position (0..640, 0..480): mouse enter / exit
      scripts; ClearCursor when the player looks away. }
    procedure SetCursor(const X, Y: Single);
    procedure ClearCursor;
    { A click (and its release) at the cursor: the onAction of the deepest
      window under it (idWindow::HandleEvent K_MOUSE1), else the
      desktop's. Returns whether a script ran. }
    function Click: Boolean;
    function ClickRelease: Boolean;
    { An onNamedEvent (idUserInterface::HandleNamedEvent). }
    function NamedEvent(const AName: String): Boolean;
    { A key (idUserInterface::HandleEvent SE_KEY / SE_CHAR): the focused
      editDef types (Ch, or Key: 8 backspace, 13 enter), escape runs the
      desktop's onEsc. False when nothing used it. }
    function KeyDown(const Key: Integer; const Ch: Char): Boolean;
    { the editDef with the keyboard focus (nil: none) }
    property Focus: TD3GuiWindow read FFocus;
    { idUserInterface::Trigger (its entity activated): the windows'
      onTrigger scripts; False if none has one }
    function Trigger: Boolean;
    { The commands collected for the entity ("activate ; runScript x"),
      cleared. }
    function TakeCmd: String;
    { Run a script (the commands of an event) in a window's context. }
    procedure RunScript(const W: TD3GuiWindow; const Script: TD3GuiScript);
    { Evaluate an expression in a window's context (gui::x, $vars,
      win::prop, arithmetic and comparisons). }
    function Eval(const W: TD3GuiWindow; const S: String): Single;
    { "a, b, c, d" with an expression in each part (Default's for the
      missing ones); one part: the first component only }
    function EvalVec(const W: TD3GuiWindow; const S: String; const Default: TVector4): TVector4;
    { A window property as drawn now: a transition's value, an
      expression's, else the property. }
    function PropVec4(const W: TD3GuiWindow; const Prop: String): TVector4;
    function PropFloat(const W: TD3GuiWindow; const Prop: String): Single;
    function PropVisible(const W: TD3GuiWindow): Boolean;
    { Text with gui:: references resolved and \n new lines. }
    function PropText(const W: TD3GuiWindow): String;
    function TransitionCount: Integer;
    { listDef rows (idListWindow): the item text, how many items there are
      (up to the first empty one), the selected row (-1 none), the row
      height (its font's line height) }
    function ListItem(const W: TD3GuiWindow; const Index: Integer): String;
    function ListCount(const W: TD3GuiWindow): Integer;
    function ListSelection(const W: TD3GuiWindow): Integer;
    function ListRowHeight(const W: TD3GuiWindow): Single;
  end;

const
  GuiWidth = 640;
  GuiHeight = 480;
  { The size GUIs are drawn at: a power of two, so CGE uses the texture as
    it is (it would resize 640 x 480 for every GUI, slowly). }
  GuiImageWidth = 512;
  GuiImageHeight = 512;
  { idPlayer::UpdateFocus: how far the player's view reaches a GUI }
  GuiFocusDistance = 80;

var
  { The cvars GUI windows read and write ("cvar" keys of choiceDef,
    sliderDef, editDef: name=value; the game fills and watches them). }
  GuiCvars: TStringList;
  { called when a GUI changes a cvar }
  OnGuiCvarChanged: procedure (const AName, Value: String) of object;

function GuiCvar(const AName: String; const Default: String = ''): String;
{ Images rendered by the game (remoteRenderMap: textures/dynamic/camera1):
  GUI backgrounds whose material maps one draw it (and redraw while shown).
  The image is copied. }
procedure SetGuiDynamicImage(const AName: String; const Image: TRGBAlphaImage);
{ the dynamic images GUIs drew since the last call (cleared): what to
  render next }
function TakeWantedDynamicImages: TStringArray;
procedure SetGuiCvar(const AName, Value: String);

{ Draw a GUI into a new GuiImageWidth x GuiImageHeight image (caller
  frees), the 640 x 480 virtual screen stretched over it. State (may be
  nil) replaces the GUI's gui:: variables first. }
function RenderGui(const Gui: TD3Gui; const State: TStrings): TRGBAlphaImage; overload;
{ The same at another size (the full screen main menu) }
function RenderGui(const Gui: TD3Gui; const State: TStrings; const Width, Height: Integer): TRGBAlphaImage; overload;
{ The same over a transparent background (the HUD over the view): not
  premultiplied, additive stages get the alpha of their brightness. }
function RenderGuiTransparent(const Gui: TD3Gui): TRGBAlphaImage;

{ The texture URL of a GUI drawn with some state, '' when the GUI file is
  missing. Rendered once per (path, state) and cached; static (no events). }
function GuiImageUrl(const GuiPath: String; const State: TStrings): String;

{ The GUI path a guisurf keyword means for an entity: "entity" -> its "gui"
  key, "entity2" / "entity3" -> "gui2" / "gui3", otherwise a path. }
function GuiSurfPath(const GuiSurf: String; const EntityGui, EntityGui2, EntityGui3: String): String;

{ The GUI texture URL for a guisurf material on an entity (Entity may be
  nil for world surfaces: then only explicit paths work). '' when none. }
function GuiSurfaceUrl(const GuiSurf: String; const EntityKeys: TStrings): String;

{ The GUI file drawn into a "d3gui:" texture URL ('' if it's not one). }
function GuiUrlPath(const Url: String): String;

type
  { A live GUI on a surface: its own texture, redrawn when the GUI
    changes (events, transitions, the state, the cursor). The map owns
    them (one per scene and GUI URL) and updates them every frame. }
  TD3GuiSurface = class
  private
    FKey: String;
    FVersion: Integer;
    FUrl: String;
  public
    Gui: TD3Gui;
    { the texture nodes showing it }
    Nodes: TX3DNodeList;
    { the scene drawing it (portal visibility) and its entity's name }
    Scene: TCastleTransform;
    EntityName: String;
    { the map time (s) of the last render }
    LastRender: Single;
    { the seconds the last redraw took (UpdateGuis spaces costly GUIs) }
    RenderSeconds: Single;
    Renders: Integer;
    { the box of Scene's shapes showing it, in Scene's coordinates
      (TDoom3Map.UpdateGuis: GUIs out of the view don't redraw) }
    LocalBox: TBox3D;
    HasLocalBox: Boolean;
    { the texture size for the next redraw (0: GuiImageWidth x
      GuiImageHeight); UpdateGuis makes it smaller for GUIs that are small on
      screen. RenderedSize is the last texture's (0 before the first). }
    RenderSize: Integer;
    RenderedSize: Integer;
    { its estimated size on screen (pixels across) and its box's radius,
      for the console's "guis" }
    ScreenPixels, BoxRadius: Single;
    constructor Create(const AGui: TD3Gui);
    destructor Destroy; override;
    { Redraw into a new texture version and point the nodes at it;
      False when nothing was dirty (unless Force). }
    function Render(const Force: Boolean): Boolean;
    { the current texture URL (d3gui:/giN_vM.tga) }
    property Url: String read FUrl;
    property Key: String read FKey;
  end;

{ The GUI surface a texture URL belongs to (nil for static renders). }
function GuiSurfaceByUrl(const Url: String): TD3GuiSurface;

procedure RegisterGuiProtocol;
procedure ClearGuiCache;
function GuiCacheCount: Integer;

{ Doom 3 fonts: fonts/<lang>/<name>/fontImage_12|24|48.dat with their glyph
  pages. }
type
  TD3FontGlyph = record
    Height, Top, Bottom, Pitch, XSkip, ImageWidth, ImageHeight: Integer;
    S, T, S2, T2: Single;
    Page: TRGBAlphaImage; { nil: not drawn }
  end;

  TD3FontSize = class
    Glyphs: array [0..255] of TD3FontGlyph;
    GlyphScale: Single;
    MaxHeight, MaxWidth: Integer;
    PointSize: Integer;
  end;

  TD3Font = class
    Name: String;
    { 12, 24 and 48 (nil when missing) }
    Sizes: array [0..2] of TD3FontSize;
    destructor Destroy; override;
    { idDeviceContext::SetFontByScale: the size for a textscale }
    function SizeFor(const TextScale: Single): TD3FontSize;
    { Doom 3 units: sum of the glyphs' xSkip at the scale }
    function TextWidth(const S: String; const TextScale: Single): Single;
    function LineHeight(const TextScale: Single): Single;
  end;

{ A font by its GUI name ("fonts/micro", "fonts"); nil when the data has
  no such font (then CGE's UI font draws). Cached. }
function D3Font(const AName: String): TD3Font;
{ The language directory of the fonts (fonts/<lang>/...): "english". }
var
  D3FontLang: String = 'english';

implementation

uses
  Math, StrUtils,
  CastleDownload, CastleUriUtils, CastleLog, CastleTextureFontData, CastleTextureFont_DefaultUi,
  CastleUnicode, CastleUtils,
  Doom3Files, Doom3Lexer, Doom3Decls, Doom3Images, Doom3Roq, Doom3Expressions;

function DynamicImage(const ImageName: String): TRGBAlphaImage; forward;

{ TD3GuiCommand }

destructor TD3GuiCommand.Destroy;
begin
  FreeAndNil(ThenList);
  FreeAndNil(ElseList);
  inherited Destroy;
end;

{ TD3GuiWindow }

constructor TD3GuiWindow.Create;
begin
  inherited Create;
  Rect := FloatRectangle(0, 0, GuiWidth, GuiHeight);
  BackColor := Vector4(0, 0, 0, 0);
  ForeColor := Vector4(1, 1, 1, 1);
  MatColor := Vector4(1, 1, 1, 1);
  BorderColor := Vector4(0, 0, 0, 0);
  TextScale := 0.35;
  Visible := True;
  Children := specialize TObjectList<TD3GuiWindow>.Create(True);
  Exprs := TStringList.Create;
  Vars := TStringList.Create;
  Props := TStringList.Create;
  NamedEvents := specialize TObjectDictionary<String, TD3GuiScript>.Create([doOwnsValues]);
end;

destructor TD3GuiWindow.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(TimeEvents) do
    FreeAndNil(TimeEvents[I].Script);
  FreeAndNil(OnAction);
  FreeAndNil(OnActionRelease);
  FreeAndNil(OnMouseEnter);
  FreeAndNil(OnMouseExit);
  FreeAndNil(OnActivate);
  FreeAndNil(OnDeactivate);
  FreeAndNil(OnEsc);
  FreeAndNil(OnTrigger);
  FreeAndNil(NamedEvents);
  FreeAndNil(Children);
  FreeAndNil(Exprs);
  FreeAndNil(Vars);
  FreeAndNil(Props);
  FreeAndNil(OnEnter);
  FreeAndNil(OnFrame);
  inherited Destroy;
end;

function Unquote(const S: String): String;
begin
  Result := Trim(S);
  if (Length(Result) >= 2) and (Result[1] = '"') and (Result[Length(Result)] = '"') then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

{ Does the text hold only numbers (a constant), not an expression? }
function IsNumbers(const S: String): Boolean;
var
  I: Integer;
begin
  Result := Trim(S) <> '';
  for I := 1 to Length(S) do
    if not (S[I] in ['0'..'9', '-', '+', '.', ',', ' ', #9, 'e', 'E']) then
      Exit(False);
end;

{ "a, b, c, d" numbers; missing / non-numeric ones keep Default's }
function ParseNumbers(const S: String; const Default: TVector4): TVector4;
var
  Parts: TStringArray;
  I: Integer;
begin
  Result := Default;
  Parts := Unquote(S).Split([',', ' ', #9], TStringSplitOptions.ExcludeEmpty);
  for I := 0 to Min(3, High(Parts)) do
    Result.Data[I] := D3StrToFloat(Parts[I], Default.Data[I]);
end;

{ "10, 120, 200": a list of numbers }
function ParseFloatList(const S: String): TD3GuiFloats;
var
  Part: String;
begin
  Result := nil;
  for Part in S.Split([',', ' '], TStringSplitOptions.ExcludeEmpty) do
    Result := Concat(Result, [D3StrToFloat(Part, 0)]);
end;

procedure TD3GuiWindow.SetProp(const Key, Value: String);
var
  V: TVector4;
  K, S: String;
  I: Integer;
begin
  K := LowerCase(Key);
  S := Unquote(Value);
  { numeric properties given as expressions }
  if (K = 'rect') or (K = 'backcolor') or (K = 'forecolor') or (K = 'matcolor') or
     (K = 'bordercolor') or (K = 'bordersize') or (K = 'textscale') or (K = 'visible') or
     (K = 'textalign') or (K = 'textalignx') or (K = 'textaligny') or (K = 'nowrap') or
     (K = 'noevents') or (K = 'notime') or (K = 'nocursor') then
  begin
    if not IsNumbers(S) then
    begin
      Exprs.Values[K] := S;
      Exit;
    end;
    I := Exprs.IndexOfName(K);
    if I >= 0 then
      Exprs.Delete(I);
  end;
  if K = 'rect' then
  begin
    V := ParseNumbers(S, Vector4(Rect.Left, Rect.Bottom, Rect.Width, Rect.Height));
    Rect := FloatRectangle(V.X, V.Y, V.Z, V.W);
  end else
  if K = 'backcolor' then
    BackColor := ParseNumbers(S, BackColor)
  else
  if K = 'forecolor' then
    ForeColor := ParseNumbers(S, ForeColor)
  else
  if K = 'matcolor' then
    MatColor := ParseNumbers(S, MatColor)
  else
  if K = 'bordercolor' then
    BorderColor := ParseNumbers(S, BorderColor)
  else
  if K = 'bordersize' then
    BorderSize := D3StrToFloat(S, 0)
  else
  if K = 'background' then
    Background := S
  else
  if K = 'text' then
    Text := S
  else
  if K = 'textscale' then
    TextScale := D3StrToFloat(S, TextScale)
  else
  if K = 'textalign' then
    TextAlign := Round(D3StrToFloat(S, 0))
  else
  if K = 'textalignx' then
    TextAlignX := D3StrToFloat(S, 0)
  else
  if K = 'textaligny' then
    TextAlignY := D3StrToFloat(S, 0)
  else
  if K = 'visible' then
    Visible := D3StrToFloat(S, 1) <> 0
  else
  if K = 'nowrap' then
    NoWrap := D3StrToFloat(S, 0) <> 0
  else
  if K = 'tabstops' then
    Tabstops := ParseFloatList(S)
  else
  if K = 'listname' then
    ListName := S
  else
  if K = 'noevents' then
    NoEvents := D3StrToFloat(S, 0) <> 0
  else
  if K = 'notime' then
    NoTime := D3StrToFloat(S, 0) <> 0
  else
  if K = 'nocursor' then
    NoCursor := D3StrToFloat(S, 0) <> 0
  else
  if K = 'noclip' then
    NoClip := D3StrToFloat(S, 0) <> 0
  else
  if K = 'font' then
    Font := S
  else
  if Vars.IndexOfName(K) >= 0 then
    Vars.Values[K] := S
  else
    { the rest (choices, cvar, low, high, rotate, shear, modal...) }
    Props.Values[K] := S;
end;

function TD3GuiWindow.Prop(const Key, Default: String): String;
var
  I: Integer;
begin
  I := Props.IndexOfName(LowerCase(Key));
  if I >= 0 then
    Result := Props.ValueFromIndex[I]
  else
    Result := Default;
end;

function SplitChoices(const S: String): TStringArray;
var
  I: Integer;
begin
  Result := D3LangString(S).Split([';']);
  for I := 0 to High(Result) do
    Result[I] := Trim(D3LangString(Trim(Result[I])));
end;

function TD3GuiWindow.ChoiceList: TStringArray;
begin
  Result := SplitChoices(Prop('choices'));
  if Length(Result) = 0 then
    Result := ['No Choices Defined'];
end;

function TD3GuiWindow.ValueList: TStringArray;
begin
  Result := SplitChoices(Prop('values'));
end;

function TD3GuiWindow.Interactive: Boolean;
var
  C: TD3GuiWindow;
begin
  if (OnAction <> nil) or (OnActionRelease <> nil) or (OnMouseEnter <> nil) or (OnMouseExit <> nil) or
     (Kind in [gkChoice, gkSlider, gkEdit]) then
    Exit(True);
  for C in Children do
    if C.Interactive then
      Exit(True);
  Result := False;
end;

function TD3GuiWindow.FontName: String;
var
  W: TD3GuiWindow;
begin
  W := Self;
  while (W <> nil) and (W.Font = '') do
    W := W.Parent;
  if W = nil then
    Result := 'fonts'
  else
    Result := W.Font;
end;

function TD3GuiWindow.FindVar(const AName: String; out Value: String): Boolean;
var
  W: TD3GuiWindow;
  I: Integer;
begin
  W := Self;
  while W <> nil do
  begin
    I := W.Vars.IndexOfName(LowerCase(AName));
    if I >= 0 then
    begin
      Value := W.Vars.ValueFromIndex[I];
      Exit(True);
    end;
    W := W.Parent;
  end;
  Value := '';
  Result := False;
end;

{ TD3GuiTransition }

function TD3GuiTransition.Value(const Time: Integer): TVector4;
var
  F, A, D, T: Single;
begin
  if (Duration <= 0) or (Time >= Start + Duration) then
    Exit(To_);
  if Time <= Start then
    Exit(From);
  T := (Time - Start) / Duration;
  { idInterpolateAccelDecelLinear: accelerate over Accel, decelerate
    over Decel (fractions), linear between }
  A := Clamped(Accel, 0, 1);
  D := Clamped(Decel, 0, 1 - A);
  if A + D <= 0 then
    F := T
  else
  begin
    { the speed profile's area: the middle part at full speed }
    if T < A then
      F := T * T / (2 * A)
    else
    if T < 1 - D then
      F := A / 2 + (T - A)
    else
      F := A / 2 + (1 - A - D) + (D / 2 - Sqr(1 - T) / (2 * D));
    F := F / (1 - A / 2 - D / 2);
  end;
  Result := From + (To_ - From) * Clamped(F, 0, 1);
end;

function TD3GuiTransition.Done(const Time: Integer): Boolean;
begin
  Result := Time >= Start + Duration;
end;

{ Parsing -------------------------------------------------------------------- }

function IsWindowKeyword(const L: String): Boolean;
begin
  Result := (L = 'windowdef') or (L = 'editdef') or (L = 'choicedef') or (L = 'sliderdef') or
    (L = 'listdef') or (L = 'renderdef') or (L = 'binddef') or (L = 'fielddef') or
    (L = 'markerdef') or (L = 'gamessddef') or (L = 'gamebearshootdef') or (L = 'gamebustoutdef');
end;

{ The text of a parenthesized expression after "(" up to the matching ")". }
function ReadParenthesized(const L: TDoom3Lexer): String;
const
  OpChars = ['=', '!', '<', '>', '&', '|'];
var
  Depth: Integer;
  Tok, Last: String;
begin
  Result := '';
  Last := '';
  Depth := 1;
  while L.Next(Tok) do
  begin
    if Tok = '(' then
      Inc(Depth)
    else
    if Tok = ')' then
    begin
      Dec(Depth);
      if Depth = 0 then
        Break;
    end;
    { the lexer splits "==", "!=", "<=", ">=", "&&", "||": joined again }
    if (Result <> '') and not ((Length(Tok) = 1) and (Length(Last) = 1) and
       (Tok[1] in OpChars) and (Last[1] in OpChars)) then
      Result := Result + ' ';
    Result := Result + Tok;
    Last := Tok;
  end;
end;

const
  GuiOpChars = ['+', '-', '*', '/', '%', '<', '>', '=', '!', '&', '|', '?', ':'];

{ Tokens up to the matching "]" (the "[" read), joined. }
function ReadBracketed(const L: TDoom3Lexer): String;
var
  Depth: Integer;
  Tok: String;
begin
  Result := '';
  Depth := 1;
  while L.Next(Tok) do
  begin
    if Tok = '[' then
      Inc(Depth)
    else
    if Tok = ']' then
    begin
      Dec(Depth);
      if Depth = 0 then
        Break;
    end;
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + Tok;
  end;
end;

{ Is the next token an operator continuing an expression ("/", "*", "-",
  "==", "/3")? A signed number ("-5") is not. }
function NextIsOperator(const L: TDoom3Lexer): Boolean;
var
  T: String;
begin
  T := L.Peek;
  if (T = '') or L.PeekQuoted then
    Exit(False);
  { a stray comment end ("*/") is no operator }
  Result := (T[1] in GuiOpChars) and (T <> '*/');
  if Result and (Length(T) > 1) and (T[1] in ['-', '+']) and not (T[2] in GuiOpChars) then
    Result := False;
end;

function OnlyOpChars(const T: String): Boolean;
var
  I: Integer;
begin
  Result := T <> '';
  for I := 1 to Length(T) do
    if not (T[I] in GuiOpChars) then
      Exit(False);
end;

{ One operand of a property's expression: a token, a parenthesized
  expression, a table lookup "name[ expr ]", with a sign or "!". }
function ReadOperand(const L: TDoom3Lexer): String;
var
  Tok: String;
  Quoted: Boolean;
begin
  Tok := L.NextStr;
  Quoted := L.WasQuoted;
  if not Quoted and (Tok = '(') then
    Exit('(' + ReadParenthesized(L) + ')');
  if not Quoted and ((Tok = '-') or (Tok = '!')) then
    Exit(Tok + ReadOperand(L));
  Result := Tok;
  if not Quoted and (L.Peek = '[') and not L.PeekQuoted then
  begin
    L.NextStr;
    Result := Result + '[' + ReadBracketed(L) + ']';
  end;
end;

{ A property's expression (idWindow::ParseExpression): operands and
  operators, e.g. pdflick[ time * .0025 ] / 3 or ("gui::x" * 1.33). One
  plain token stays as it is. }
function ReadExpression(const L: TDoom3Lexer): String;
var
  Op: String;
begin
  Result := ReadOperand(L);
  while NextIsOperator(L) do
  begin
    Op := L.NextStr;
    { "==", ">=": the lexer splits "=" off }
    while OnlyOpChars(Op) and (L.Peek = '=') and not L.PeekQuoted do
      Op := Op + L.NextStr;
    Result := Result + ' ' + Op;
    if OnlyOpChars(Op) then
      Result := Result + ' ' + ReadOperand(L);
  end;
end;

{ A script block after its opening brace: commands up to the closing one. }
function ParseScript(const L: TDoom3Lexer): TD3GuiScript;
var
  Tok: String;
  C: TD3GuiCommand;
begin
  Result := TD3GuiScript.Create(True);
  while L.Next(Tok) and (Tok <> '}') do
  begin
    if Tok = ';' then
      Continue;
    C := TD3GuiCommand.Create;
    C.Name := LowerCase(Tok);
    Result.Add(C);
    if C.Name = 'if' then
    begin
      if L.Check('(') then
        C.Condition := ReadParenthesized(L);
      if L.Check('{') then
        C.ThenList := ParseScript(L);
      if SameText(L.Peek, 'else') then
      begin
        L.NextStr;
        if SameText(L.Peek, 'if') then
        begin
          { else if: a one-command list }
          C.ElseList := TD3GuiScript.Create(True);
          L.NextStr;
          C.ElseList.Add(TD3GuiCommand.Create);
          C.ElseList[0].Name := 'if';
          if L.Check('(') then
            C.ElseList[0].Condition := ReadParenthesized(L);
          if L.Check('{') then
            C.ElseList[0].ThenList := ParseScript(L);
          if SameText(L.Peek, 'else') then
          begin
            L.NextStr;
            if L.Check('{') then
              C.ElseList[0].ElseList := ParseScript(L);
          end;
        end else
        if L.Check('{') then
          C.ElseList := ParseScript(L);
      end;
      Continue;
    end;
    { arguments up to ";" or the block's end }
    while not L.AtEnd and (L.Peek <> ';') and (L.Peek <> '}') do
      C.Args := Concat(C.Args, [L.NextStr]);
    L.Check(';');
  end;
end;

procedure ParseWindow(const L: TDoom3Lexer; const W: TD3GuiWindow);
var
  Tok, Key, Value, VarName: String;
  Child: TD3GuiWindow;
  Script: TD3GuiScript;
  T: Integer;
  Included: TDoom3Lexer;
begin
  while L.Next(Tok) and (Tok <> '}') do
  begin
    Key := LowerCase(Tok);
    if IsWindowKeyword(Key) then
    begin
      Child := TD3GuiWindow.Create;
      Child.Name := L.NextStr;
      Child.IsList := Key = 'listdef';
      if Key = 'listdef' then Child.Kind := gkList else
      if Key = 'choicedef' then Child.Kind := gkChoice else
      if Key = 'sliderdef' then Child.Kind := gkSlider else
      if Key = 'editdef' then Child.Kind := gkEdit else
      if Key = 'binddef' then Child.Kind := gkBind else
      if Key = 'renderdef' then Child.Kind := gkRender;
      Child.Parent := W;
      W.Children.Add(Child);
      if L.Check('{') then
        ParseWindow(L, Child);
    end else
    if Copy(Key, 1, 2) = 'on' then
    begin
      { an event and its script: onTime N, onAction, onNamedEvent x... }
      if Key = 'ontime' then
      begin
        T := Round(D3StrToFloat(L.NextStr, 0));
        if L.Check('{') then
        begin
          SetLength(W.TimeEvents, Length(W.TimeEvents) + 1);
          W.TimeEvents[High(W.TimeEvents)].Time := T;
          W.TimeEvents[High(W.TimeEvents)].Script := ParseScript(L);
          W.TimeEvents[High(W.TimeEvents)].Pending := True;
        end;
      end else
      if Key = 'onnamedevent' then
      begin
        VarName := LowerCase(L.NextStr);
        if L.Check('{') then
          W.NamedEvents.AddOrSetValue(VarName, ParseScript(L));
      end else
      begin
        { other events take no arguments before their block }
        while not L.AtEnd and (L.Peek <> '{') do
          L.NextStr;
        Script := nil;
        if L.Check('{') then
          Script := ParseScript(L);
        if Key = 'onaction' then
          W.OnAction := Script
        else
        if Key = 'onactionrelease' then
          W.OnActionRelease := Script
        else
        if Key = 'onmouseenter' then
          W.OnMouseEnter := Script
        else
        if Key = 'onmouseexit' then
          W.OnMouseExit := Script
        else
        if Key = 'onactivate' then
          W.OnActivate := Script
        else
        if Key = 'ondeactivate' then
          W.OnDeactivate := Script
        else
        if Key = 'onesc' then
          W.OnEsc := Script
        else
        if Key = 'ontrigger' then
          W.OnTrigger := Script
        else
        if Key = 'onenter' then
          W.OnEnter := Script
        else
        if (Key = 'onevent') or (Key = 'onframe') then
          W.OnFrame := Script
        else
          Script.Free;
      end;
    end else
    if Tok = '{' then
      L.SkipBracedSection
    else
    { #include "file": its windows and properties here (idParser; the
      main menu's guis/test/grid2b.pd) }
    if not L.WasQuoted and SameText(Tok, '#include') then
    begin
      VarName := L.NextStr;
      if D3Fs.FileExists(VarName) then
      begin
        Included := TDoom3Lexer.Create(D3Fs.ReadText(VarName));
        try
          ParseWindow(Included, W);
        finally
          Included.Free;
        end;
      end else
        WritelnLog('Doom3Gui', 'GUI #include "%s" not found', [VarName]);
    end else
    { a stray token that can't be a key (mainmenu.gui's lone "*/"): Doom 3
      warns and goes on with the next one }
    if not L.WasQuoted and not (Tok[1] in ['a'..'z', 'A'..'Z', '_']) then
      Continue
    else
    begin
      { variable declarations name the variable before the value:
        definevec4 "$gui::hilite" 1, 1, 1, 1 / float x 0 }
      if (Key = 'definevec4') or (Key = 'definefloat') or (Key = 'float') or
         (Key = 'vec4') or (Key = 'vec2') or (Key = 'vec3') or (Key = 'rectangle') then
      begin
        VarName := LowerCase(L.NextStr);
        if (VarName <> '') and (VarName[1] = '$') then
          Delete(VarName, 1, 1);
        Value := ReadExpression(L);
        while L.Check(',') do
          Value := Value + ',' + ReadExpression(L);
        L.Check(';');
        W.Vars.Values[VarName] := Value;
        Continue;
      end;
      { a property's value: tokens separated by commas, e.g.
        rect 0, 0, 640, 480 / text "abc" / visible "gui::x" }
      { visible ("gui::inv_count" == 0), matcolor 1, 1, 1, pdflick[ time ]
        / 3: an expression in each part }
      Value := ReadExpression(L);
      while L.Check(',') do
        Value := Value + ',' + ReadExpression(L);
      L.Check(';');
      W.SetProp(Key, Value);
    end;
  end;
end;

{ TD3Gui }

constructor TD3Gui.Create;
begin
  inherited Create;
  FState := TStringList.Create;
  FTransitions := specialize TList<TD3GuiTransition>.Create;
end;

destructor TD3Gui.Destroy;
begin
  FreeAndNil(Desktop);
  FreeAndNil(FTransitions);
  FreeAndNil(FState);
  inherited Destroy;
end;

function TD3Gui.LoadFromText(const AText: String): Boolean;
var
  L: TDoom3Lexer;
  Tok: String;
begin
  FreeAndNil(Desktop);
  FTransitions.Clear;
  L := TDoom3Lexer.Create(AText);
  try
    while L.Next(Tok) do
      if IsWindowKeyword(LowerCase(Tok)) then
      begin
        Desktop := TD3GuiWindow.Create;
        Desktop.Name := L.NextStr;
        Desktop.IsList := LowerCase(Tok) = 'listdef';
        if L.Check('{') then
          ParseWindow(L, Desktop);
        Break;
      end;
  finally
    L.Free;
  end;
  Result := Desktop <> nil;
  FInteractive := Result and Desktop.Interactive and (StateValue('noninteractive') <> '1');
  Dirty := True;
end;

function TD3Gui.LoadFromVfs(const Path: String): Boolean;
var
  Text: String;
begin
  Name := NormalizeD3Path(Path);
  Text := D3Fs.ReadText(Path);
  Result := (Text <> '') and LoadFromText(Text);
end;

function CountWindows(const W: TD3GuiWindow): Integer;
var
  C: TD3GuiWindow;
begin
  Result := 1;
  for C in W.Children do
    Inc(Result, CountWindows(C));
end;

function TD3Gui.WindowCount: Integer;
begin
  if Desktop = nil then
    Result := 0
  else
    Result := CountWindows(Desktop);
end;

function FindIn(const W: TD3GuiWindow; const AName: String): TD3GuiWindow;
var
  C: TD3GuiWindow;
begin
  if SameText(W.Name, AName) then
    Exit(W);
  for C in W.Children do
  begin
    Result := FindIn(C, AName);
    if Result <> nil then
      Exit;
  end;
  Result := nil;
end;

function TD3Gui.FindWindow(const AName: String): TD3GuiWindow;
begin
  if Desktop = nil then
    Result := nil
  else
    Result := FindIn(Desktop, AName);
end;

procedure TD3Gui.SetState(const Key, Value: String);
begin
  if FState.Values[LowerCase(Key)] = Value then
    Exit;
  FState.Values[LowerCase(Key)] := Value;
  if LowerCase(Key) = 'noninteractive' then
    FInteractive := (Desktop <> nil) and Desktop.Interactive and (Value <> '1');
  Dirty := True;
end;

function TD3Gui.StateValue(const Key: String): String;
begin
  Result := FState.Values[LowerCase(Key)];
end;

procedure TD3Gui.StateFromKeys(const Keys: TStrings);
var
  I: Integer;
  K: String;
begin
  if Keys = nil then
    Exit;
  for I := 0 to Keys.Count - 1 do
  begin
    K := LowerCase(Keys.Names[I]);
    if Copy(K, 1, 4) = 'gui_' then
      SetState(K, Keys.ValueFromIndex[I]);
  end;
  if Keys.Values['gui_noninteractive'] <> '' then
    SetState('noninteractive', BoolToStr(D3StrToFloat(Keys.Values['gui_noninteractive'], 0) <> 0, '1', '0'));
end;

procedure TD3Gui.ActivateWindow(const W: TD3GuiWindow);
var
  I: Integer;
  C: TD3GuiWindow;
begin
  W.TimeLine := FTime;
  for I := 0 to High(W.TimeEvents) do
    W.TimeEvents[I].Pending := True;
  if W.OnActivate <> nil then
    RunScript(W, W.OnActivate);
  for C in W.Children do
    ActivateWindow(C);
end;

procedure TD3Gui.Activate(const TimeMs: Integer);
begin
  FTime := TimeMs;
  Active := True;
  if Desktop <> nil then
  begin
    InitWidgets(Desktop);
    ActivateWindow(Desktop);
  end;
  Dirty := True;
end;

procedure TD3Gui.InitWidgets(const W: TD3GuiWindow);
var
  C: TD3GuiWindow;
  CvarName, V: String;
  Items: TStringArray;
  I: Integer;
begin
  { idChoiceWindow / idSliderWindow / idEditWindow::InitVars: from the
    cvar, else the window's own start value }
  CvarName := W.Prop('cvar');
  case W.Kind of
    gkChoice:
      begin
        W.Choice := StrToIntDef(W.Prop('currentchoice', '0'), 0);
        if CvarName <> '' then
        begin
          V := GuiCvar(CvarName, '');
          if StrToIntDef(W.Prop('choicetype', '0'), 0) = 0 then
            W.Choice := StrToIntDef(V, W.Choice)
          else
          begin
            Items := W.ValueList;
            if Length(Items) = 0 then
              Items := W.ChoiceList;
            for I := 0 to High(Items) do
              if SameText(Items[I], V) then
                W.Choice := I;
          end;
        end;
        if (W.Choice < 0) or (W.Choice >= Length(W.ChoiceList)) then
          W.Choice := 0;
      end;
    gkSlider:
      begin
        W.SliderValue := D3StrToFloat(W.Prop('low', '0'), 0);
        if CvarName <> '' then
          W.SliderValue := D3StrToFloat(GuiCvar(CvarName, ''), W.SliderValue);
      end;
    gkEdit:
      if CvarName <> '' then
        W.EditText := GuiCvar(CvarName, '');
  end;
  for C in W.Children do
    InitWidgets(C);
end;

procedure TD3Gui.ApplyChoice(const W: TD3GuiWindow);
var
  Items: TStringArray;
begin
  { idChoiceWindow::UpdateChoice: the cvar gets the index (choiceType 0),
    the value or the choice }
  if W.Prop('cvar') = '' then
    Exit;
  if StrToIntDef(W.Prop('choicetype', '0'), 0) = 0 then
    SetGuiCvar(W.Prop('cvar'), IntToStr(W.Choice))
  else
  begin
    Items := W.ValueList;
    if Length(Items) = 0 then
      Items := W.ChoiceList;
    if W.Choice <= High(Items) then
      SetGuiCvar(W.Prop('cvar'), Items[W.Choice]);
  end;
end;

procedure TD3Gui.SliderFromCursor(const W: TD3GuiWindow; const X, Y: Single);
var
  Left, Top, Low, High, Step, F: Single;
  R: TVector4;
begin
  { idSliderWindow::RouteMouseCoords: the value under the cursor, in
    steps, written to the cvar }
  WindowAbs(W, Left, Top);
  R := PropVec4(W, 'rect');
  Low := D3StrToFloat(W.Prop('low', '0'), 0);
  High := D3StrToFloat(W.Prop('high', '100'), 100);
  Step := D3StrToFloat(W.Prop('step', '1'), 1);
  if D3StrToFloat(W.Prop('vertical', '0'), 0) <> 0 then
    F := (Y - Top) / Max(1, R.W)
  else
    F := (X - Left) / Max(1, R.Z);
  F := EnsureRange(F, 0, 1);
  W.SliderValue := Low + (High - Low) * F;
  if Step > 0 then
    W.SliderValue := Low + Round((W.SliderValue - Low) / Step) * Step;
  W.SliderValue := EnsureRange(W.SliderValue, Min(Low, High), Max(Low, High));
  if W.Prop('cvar') <> '' then
    SetGuiCvar(W.Prop('cvar'), FormatFloat('0.####', W.SliderValue, DefaultFormatSettings));
  Dirty := True;
end;

function TD3Gui.KeyDown(const Key: Integer; const Ch: Char): Boolean;
var
  W: TD3GuiWindow;
  MaxChars: Integer;
begin
  Result := False;
  if Desktop = nil then
    Exit;
  W := FFocus;
  if (W <> nil) and (W.Kind = gkEdit) and (D3StrToFloat(W.Prop('readonly', '0'), 0) = 0) then
  begin
    { idEditWindow::HandleEvent }
    if Key = 8 then
    begin
      if W.EditText <> '' then
        SetLength(W.EditText, Length(W.EditText) - 1);
      Result := True;
    end else
    if Key = 13 then
    begin
      if W.OnEnter <> nil then
        RunScript(W, W.OnEnter)
      else
      if W.OnAction <> nil then
        RunScript(W, W.OnAction);
      FFocus := nil;
      Result := True;
    end else
    if Key = 27 then
    begin
      FFocus := nil;
      Result := True;
    end else
    if Ch >= ' ' then
    begin
      MaxChars := StrToIntDef(W.Prop('maxchars', '0'), 0);
      if ((MaxChars <= 0) or (Length(W.EditText) < MaxChars)) and
         ((D3StrToFloat(W.Prop('numeric', '0'), 0) = 0) or (Ch in ['0'..'9', '.', '-'])) then
        W.EditText := W.EditText + Ch;
      Result := True;
    end;
    if Result then
    begin
      if W.Prop('cvar') <> '' then
        SetGuiCvar(W.Prop('cvar'), W.EditText);
      Dirty := True;
    end;
    Exit;
  end;
  { idWindow: escape runs the desktop's onEsc }
  if (Key = 27) and (Desktop.OnEsc <> nil) then
  begin
    RunScript(Desktop, Desktop.OnEsc);
    Result := True;
  end;
end;

procedure TD3Gui.ResetTime(const W: TD3GuiWindow; const T: Integer);
var
  I: Integer;
begin
  { idWindow::ResetTime: the time line starts T ms ago; events from T on
    fire again }
  W.TimeLine := FTime - T;
  W.NoTime := False;
  for I := 0 to High(W.TimeEvents) do
    if W.TimeEvents[I].Time >= T then
      W.TimeEvents[I].Pending := True;
end;

procedure TD3Gui.RunTimeEvents(const W: TD3GuiWindow);
var
  I: Integer;
  C: TD3GuiWindow;
begin
  if not W.NoTime then
    for I := 0 to High(W.TimeEvents) do
      if W.TimeEvents[I].Pending and (FTime - W.TimeLine >= W.TimeEvents[I].Time) then
      begin
        W.TimeEvents[I].Pending := False;
        RunScript(W, W.TimeEvents[I].Script);
      end;
  { idWindow::RunTimeEvents: onEvent (ON_FRAME) after the time line }
  if W.OnFrame <> nil then
    RunScript(W, W.OnFrame);
  for I := 0 to W.Children.Count - 1 do
  begin
    C := W.Children[I];
    RunTimeEvents(C);
  end;
end;

procedure TD3Gui.RunTransitions;
var
  I: Integer;
  T: TD3GuiTransition;
  V: TVector4;
begin
  for I := FTransitions.Count - 1 downto 0 do
  begin
    T := FTransitions[I];
    if T.Done(FTime) then
    begin
      { the end value becomes the property }
      V := T.To_;
      if T.Prop = 'rect' then
        T.Window.SetProp('rect', Format('%g, %g, %g, %g', [V.X, V.Y, V.Z, V.W], DefaultFormatSettings))
      else
      if (T.Prop = 'textscale') or (T.Prop = 'visible') or (T.Prop = 'bordersize') then
        T.Window.SetProp(T.Prop, Format('%g', [V.X], DefaultFormatSettings))
      else
        T.Window.SetProp(T.Prop, Format('%g, %g, %g, %g', [V.X, V.Y, V.Z, V.W], DefaultFormatSettings));
      FTransitions.Delete(I);
    end;
    Dirty := True;
  end;
end;

procedure TD3Gui.Update(const TimeMs: Integer);
begin
  FTime := TimeMs;
  if (Desktop = nil) or not Active then
    Exit;
  RunTimeEvents(Desktop);
  RunTransitions;
end;

procedure TD3Gui.WindowAbs(const W: TD3GuiWindow; out Left, Top: Single);
var
  R: TVector4;
  P: TD3GuiWindow;
begin
  Left := 0;
  Top := 0;
  P := W;
  while P <> nil do
  begin
    R := PropVec4(P, 'rect');
    Left := Left + R.X;
    Top := Top + R.Y;
    P := P.Parent;
  end;
end;

{ Is the point inside the window's rectangle (absolute GUI coordinates)? }
function WindowContains(const Gui: TD3Gui; const W: TD3GuiWindow; const X, Y: Single): Boolean;
var
  L, T: Single;
  R: TVector4;
begin
  Gui.WindowAbs(W, L, T);
  R := Gui.PropVec4(W, 'rect');
  Result := (X >= L) and (Y >= T) and (X < L + R.Z) and (Y < T + R.W);
end;

procedure TD3Gui.RouteCursor(const W: TD3GuiWindow; const X, Y: Single);
var
  I: Integer;
  C, Over: TD3GuiWindow;
begin
  { idWindow::RouteMouseCoords: the last child (drawn on top) under the
    cursor that is visible and takes events }
  Over := nil;
  for I := W.Children.Count - 1 downto 0 do
  begin
    C := W.Children[I];
    if PropVisible(C) and not C.NoEvents and WindowContains(Self, C, X, Y) then
    begin
      Over := C;
      Break;
    end;
  end;
  if Over <> W.HoverChild then
  begin
    if (W.HoverChild <> nil) and (W.HoverChild.OnMouseExit <> nil) then
      RunScript(W.HoverChild, W.HoverChild.OnMouseExit);
    if W.HoverChild <> nil then
      RouteCursor(W.HoverChild, -1, -1);
    W.HoverChild := Over;
    if (Over <> nil) and (Over.OnMouseEnter <> nil) then
      RunScript(Over, Over.OnMouseEnter);
  end;
  if Over <> nil then
    RouteCursor(Over, X, Y);
end;

procedure TD3Gui.SetCursor(const X, Y: Single);
begin
  if (Desktop = nil) then
    Exit;
  if CursorShown and (Abs(CursorX - X) < 0.5) and (Abs(CursorY - Y) < 0.5) then
    Exit;
  CursorX := X;
  CursorY := Y;
  CursorShown := True;
  Dirty := True;
  RouteCursor(Desktop, X, Y);
  { a slider follows the cursor while held }
  if FDrag <> nil then
    SliderFromCursor(FDrag, X, Y);
end;

procedure TD3Gui.ClearCursor;
begin
  if not CursorShown then
    Exit;
  CursorShown := False;
  Dirty := True;
  if Desktop <> nil then
    RouteCursor(Desktop, -1, -1);
end;

function TD3Gui.ClickWindow(const W: TD3GuiWindow; const X, Y: Single; const Release: Boolean): Boolean;
var
  I, Row: Integer;
  C: TD3GuiWindow;
  Left, Top: Single;
begin
  { idWindow::HandleEvent K_MOUSE1: the deepest window under the cursor
    that takes events gets the click }
  { the children under the cursor, the top one first; one that handles
    nothing passes the click on (idWindow::HandleEvent tries the next) }
  for I := W.Children.Count - 1 downto 0 do
  begin
    C := W.Children[I];
    if PropVisible(C) and not C.NoEvents and WindowContains(Self, C, X, Y) and
       ClickWindow(C, X, Y, Release) then
      Exit(True);
  end;
  Result := False;
  if not Release then
    case W.Kind of
      gkChoice:
        begin
          { idChoiceWindow: the next choice }
          W.Choice := (W.Choice + 1) mod Length(W.ChoiceList);
          ApplyChoice(W);
          Dirty := True;
          Result := True;
        end;
      gkSlider:
        begin
          FDrag := W;
          SliderFromCursor(W, X, Y);
          Result := True;
        end;
      gkEdit:
        begin
          FFocus := W;
          Dirty := True;
          Result := True;
        end;
    end;
  { a click elsewhere takes the keys from the edit }
  if (not Release) and (W.Kind <> gkEdit) and (FFocus <> nil) and (W <> Desktop) then
    FFocus := nil;
  { a listDef: the row under the cursor becomes the selection
    (idListWindow::HandleEvent), then its onAction runs }
  if W.IsList and not Release then
  begin
    WindowAbs(W, Left, Top);
    Row := Floor((Y - Top) / ListRowHeight(W));
    if (Row >= 0) and (ListItem(W, Row) <> '') then
    begin
      SetState(W.ListKey + '_sel_0', IntToStr(Row));
      Dirty := True;
    end;
  end;
  if Release then
  begin
    if W.OnActionRelease <> nil then
    begin
      RunScript(W, W.OnActionRelease);
      Result := True;
    end;
  end else
  if W.OnAction <> nil then
  begin
    RunScript(W, W.OnAction);
    Result := True;
  end;
end;

function TD3GuiWindow.ListKey: String;
begin
  Result := ListName;
  if Result = '' then
    Result := Name;
end;

function TD3Gui.ListItem(const W: TD3GuiWindow; const Index: Integer): String;
begin
  Result := StateValue(W.ListKey + '_item_' + IntToStr(Index));
end;

function TD3Gui.ListCount(const W: TD3GuiWindow): Integer;
begin
  Result := 0;
  while (Result < 256) and (ListItem(W, Result) <> '') do
    Inc(Result);
end;

function TD3Gui.ListSelection(const W: TD3GuiWindow): Integer;
begin
  Result := StrToIntDef(StateValue(W.ListKey + '_sel_0'), -1);
end;

function TD3Gui.ListRowHeight(const W: TD3GuiWindow): Single;
var
  F: TD3Font;
  Scale: Single;
begin
  { idDeviceContext's MaxCharHeight, like the text's lines }
  Scale := PropFloat(W, 'textscale');
  F := D3Font(W.FontName);
  if (F <> nil) and (F.SizeFor(Scale) <> nil) then
    Result := F.LineHeight(Scale) + 5
  else
    Result := 48 * Scale * 1.15;
  Result := Max(4, Result);
end;

function TD3Gui.Click: Boolean;
begin
  Result := (Desktop <> nil) and CursorShown and ClickWindow(Desktop, CursorX, CursorY, False);
end;

function TD3Gui.ClickRelease: Boolean;
begin
  FDrag := nil;
  Result := (Desktop <> nil) and CursorShown and ClickWindow(Desktop, CursorX, CursorY, True);
end;

function NamedEventIn(const Gui: TD3Gui; const W: TD3GuiWindow; const AName: String): Boolean;
var
  S: TD3GuiScript;
  C: TD3GuiWindow;
begin
  Result := False;
  if W.NamedEvents.TryGetValue(AName, S) then
  begin
    Gui.RunScript(W, S);
    Result := True;
  end;
  for C in W.Children do
    if NamedEventIn(Gui, C, AName) then
      Result := True;
end;

function TriggerIn(const Gui: TD3Gui; const W: TD3GuiWindow): Boolean;
var
  C: TD3GuiWindow;
begin
  { idWindow::Trigger: its onTrigger, then the children's }
  Result := False;
  if W.OnTrigger <> nil then
  begin
    Gui.RunScript(W, W.OnTrigger);
    Result := True;
  end;
  for C in W.Children do
    if TriggerIn(Gui, C) then
      Result := True;
end;

function TD3Gui.Trigger: Boolean;
begin
  Result := (Desktop <> nil) and TriggerIn(Self, Desktop);
  if Result then
    Dirty := True;
end;

function TD3Gui.NamedEvent(const AName: String): Boolean;
begin
  Result := (Desktop <> nil) and NamedEventIn(Self, Desktop, LowerCase(AName));
end;

function TD3Gui.TakeCmd: String;
begin
  Result := Trim(FCmd);
  FCmd := '';
end;

function TD3Gui.TransitionCount: Integer;
begin
  Result := FTransitions.Count;
end;

{ Expressions ---------------------------------------------------------------- }

type
  TGuiExprParser = class
    Gui: TD3Gui;
    W: TD3GuiWindow;
    S: String;
    P: Integer;
    function Peek: Char;
    procedure SkipSpaces;
    function ParseOr: Single;
    function ParseAnd: Single;
    function ParseEquality: Single;
    function ParseRelational: Single;
    function ParseAdditive: Single;
    function ParseTerm: Single;
    function ParseUnary: Single;
    function ParsePrimary: Single;
    function ReadName: String;
  end;

function TGuiExprParser.Peek: Char;
begin
  SkipSpaces;
  if P <= Length(S) then
    Result := S[P]
  else
    Result := #0;
end;

procedure TGuiExprParser.SkipSpaces;
begin
  while (P <= Length(S)) and (S[P] in [' ', #9, #10, #13]) do
    Inc(P);
end;

function TGuiExprParser.ReadName: String;
begin
  Result := '';
  while (P <= Length(S)) and (S[P] in ['a'..'z', 'A'..'Z', '0'..'9', '_', ':', '$', '.', '-']) do
  begin
    { "-" only inside names like gui::some-name, not an operator after one }
    if (S[P] = '-') and ((Result = '') or (P = Length(S)) or not (S[P + 1] in ['a'..'z', 'A'..'Z', '_'])) then
      Break;
    Result := Result + S[P];
    Inc(P);
  end;
end;

function TGuiExprParser.ParsePrimary: Single;
var
  Name, V: String;
  Start: Integer;
  Index: Single;
  Tab: TD3Table;
  Win: TD3GuiWindow;
  Prop: String;
begin
  SkipSpaces;
  if Peek = '(' then
  begin
    Inc(P);
    Result := ParseOr;
    if Peek = ')' then
      Inc(P);
    Exit;
  end;
  if Peek = '"' then
  begin
    { a quoted name or number }
    Inc(P);
    Start := P;
    while (P <= Length(S)) and (S[P] <> '"') do
      Inc(P);
    Name := Copy(S, Start, P - Start);
    if P <= Length(S) then
      Inc(P);
    if IsNumbers(Name) then
      Exit(D3StrToFloat(Trim(Name), 0));
    Exit(Gui.Eval(W, Name));
  end;
  if Peek in ['0'..'9', '.'] then
  begin
    Start := P;
    while (P <= Length(S)) and (S[P] in ['0'..'9', '.', 'e', 'E']) do
      Inc(P);
    Exit(D3StrToFloat(Copy(S, Start, P - Start), 0));
  end;
  Name := ReadName;
  if Name = '' then
  begin
    { something unexpected: skip it }
    if P <= Length(S) then
      Inc(P);
    Exit(0);
  end;
  if (Name <> '') and (Name[1] = '$') then
    Delete(Name, 1, 1);
  { a table lookup: pdflick[ time * .0025 ] }
  if Peek = '[' then
  begin
    Inc(P);
    Index := ParseOr;
    if Peek = ']' then
      Inc(P);
    Tab := nil;
    if Decls <> nil then
      Tab := Decls.Table(Name);
    if Tab <> nil then
      Exit(Tab.Lookup(Index));
    Exit(0);
  end;
  if SameText(Copy(Name, 1, 5), 'gui::') then
  begin
    V := Gui.StateValue(Copy(Name, 6, MaxInt));
    Exit(D3StrToFloat(Trim(V), 0));
  end;
  if (W <> nil) and W.FindVar(Name, V) then
    Exit(ParseNumbers(V, TVector4.Zero).X);
  if SameText(Name, 'time') then
    Exit(Gui.Time);
  Win := Gui.ResolveWindow(Name, W, Prop);
  if (Win <> nil) and (Prop <> '') then
    Exit(Gui.PropFloat(Win, Prop));
  Result := 0;
end;

function TGuiExprParser.ParseUnary: Single;
begin
  SkipSpaces;
  if Peek = '-' then
  begin
    Inc(P);
    Exit(-ParseUnary());
  end;
  if Peek = '!' then
  begin
    Inc(P);
    { ParseUnary() calls it: the bare name is the result variable }
    Exit(Ord(ParseUnary() = 0));
  end;
  Result := ParsePrimary;
end;

function TGuiExprParser.ParseTerm: Single;
var
  R: Single;
  C: Char;
begin
  Result := ParseUnary;
  while True do
  begin
    C := Peek;
    if not (C in ['*', '/', '%']) then
      Break;
    Inc(P);
    R := ParseUnary;
    case C of
      '*': Result := Result * R;
      '/': if R <> 0 then Result := Result / R else Result := 0;
      '%': if R <> 0 then Result := Result - R * Int(Result / R) else Result := 0;
    end;
  end;
end;

function TGuiExprParser.ParseAdditive: Single;
var
  C: Char;
begin
  Result := ParseTerm;
  while True do
  begin
    C := Peek;
    if not (C in ['+', '-']) then
      Break;
    Inc(P);
    if C = '+' then
      Result := Result + ParseTerm
    else
      Result := Result - ParseTerm;
  end;
end;

function TGuiExprParser.ParseRelational: Single;
var
  R: Single;
  Op: String;
begin
  Result := ParseAdditive;
  while True do
  begin
    SkipSpaces;
    Op := Copy(S, P, 2);
    if (Op = '<=') or (Op = '>=') then
      Inc(P, 2)
    else
    if (Peek = '<') or (Peek = '>') then
    begin
      Op := Peek;
      Inc(P);
    end else
      Break;
    R := ParseAdditive;
    case Op of
      '<': Result := Ord(Result < R);
      '>': Result := Ord(Result > R);
      '<=': Result := Ord(Result <= R);
      '>=': Result := Ord(Result >= R);
    end;
  end;
end;

function TGuiExprParser.ParseEquality: Single;
var
  R: Single;
  Op: String;
begin
  Result := ParseRelational;
  while True do
  begin
    SkipSpaces;
    Op := Copy(S, P, 2);
    if (Op = '==') or (Op = '!=') then
      Inc(P, 2)
    else
      Break;
    R := ParseRelational;
    if Op = '==' then
      Result := Ord(Abs(Result - R) < 0.0001)
    else
      Result := Ord(Abs(Result - R) >= 0.0001);
  end;
end;

function TGuiExprParser.ParseAnd: Single;
var
  R: Single;
begin
  Result := ParseEquality;
  while True do
  begin
    SkipSpaces;
    if Copy(S, P, 2) <> '&&' then
      Break;
    Inc(P, 2);
    R := ParseEquality;
    Result := Ord((Result <> 0) and (R <> 0));
  end;
end;

function TGuiExprParser.ParseOr: Single;
var
  R: Single;
begin
  Result := ParseAnd;
  while True do
  begin
    SkipSpaces;
    if Copy(S, P, 2) <> '||' then
      Break;
    Inc(P, 2);
    R := ParseAnd;
    Result := Ord((Result <> 0) or (R <> 0));
  end;
end;

function TD3Gui.EvalVec(const W: TD3GuiWindow; const S: String; const Default: TVector4): TVector4;
var
  Parts: array of String;
  Depth, I, Start: Integer;
  Part: String;
begin
  Result := Default;
  if IsNumbers(S) then
    Exit(ParseNumbers(S, Default));
  { split at the commas outside parentheses and brackets }
  Parts := nil;
  Depth := 0;
  Start := 1;
  for I := 1 to Length(S) + 1 do
    if (I > Length(S)) or ((S[I] = ',') and (Depth = 0)) then
    begin
      Parts := Concat(Parts, [Trim(Copy(S, Start, I - Start))]);
      Start := I + 1;
    end else
    if S[I] in ['(', '['] then
      Inc(Depth)
    else
    if S[I] in [')', ']'] then
      Dec(Depth);
  for I := 0 to Min(3, High(Parts)) do
  begin
    Part := Parts[I];
    if Part = '' then
      Continue;
    if IsNumbers(Part) then
      Result.Data[I] := D3StrToFloat(Part, Default.Data[I])
    else
      Result.Data[I] := Eval(W, Part);
  end;
end;

function TD3Gui.Eval(const W: TD3GuiWindow; const S: String): Single;
var
  Parser: TGuiExprParser;
begin
  if IsNumbers(S) then
    Exit(D3StrToFloat(Trim(S), 0));
  Parser := TGuiExprParser.Create;
  try
    Parser.Gui := Self;
    Parser.W := W;
    Parser.S := S;
    Parser.P := 1;
    Result := Parser.ParseOr;
  finally
    Parser.Free;
  end;
end;

function TD3Gui.ResolveWindow(const Ref: String; const Context: TD3GuiWindow; out Prop: String): TD3GuiWindow;
var
  I: Integer;
  WinName: String;
begin
  { "window::prop" names a window; "prop" the context window }
  I := Pos('::', Ref);
  if I > 0 then
  begin
    WinName := Copy(Ref, 1, I - 1);
    Prop := LowerCase(Copy(Ref, I + 2, MaxInt));
    if SameText(WinName, 'gui') then
      Exit(nil);
    Result := FindWindow(WinName);
  end else
  begin
    Prop := LowerCase(Ref);
    Result := Context;
  end;
end;

function TD3Gui.PropVec4(const W: TD3GuiWindow; const Prop: String): TVector4;
var
  I: Integer;
  E, V: String;
  Win: TD3GuiWindow;
  P: String;
begin
  for I := 0 to FTransitions.Count - 1 do
    if (FTransitions[I].Window = W) and (FTransitions[I].Prop = Prop) then
      Exit(FTransitions[I].Value(FTime));
  case Prop of
    'rect': Result := Vector4(W.Rect.Left, W.Rect.Bottom, W.Rect.Width, W.Rect.Height);
    'backcolor': Result := W.BackColor;
    'forecolor': Result := W.ForeColor;
    'matcolor': Result := W.MatColor;
    'bordercolor': Result := W.BorderColor;
    'bordersize': Result := Vector4(W.BorderSize, 0, 0, 0);
    'textscale': Result := Vector4(W.TextScale, 0, 0, 0);
    'textalign': Result := Vector4(W.TextAlign, 0, 0, 0);
    'textalignx': Result := Vector4(W.TextAlignX, 0, 0, 0);
    'textaligny': Result := Vector4(W.TextAlignY, 0, 0, 0);
    'visible': Result := Vector4(Ord(W.Visible), 0, 0, 0);
    'nowrap': Result := Vector4(Ord(W.NoWrap), 0, 0, 0);
    'noevents': Result := Vector4(Ord(W.NoEvents), 0, 0, 0);
    else
    begin
      if W.FindVar(Prop, V) then
        Exit(EvalVec(W, V, TVector4.Zero));
      Result := TVector4.Zero;
    end;
  end;
  E := W.Exprs.Values[Prop];
  if E <> '' then
  begin
    { a variable or another window's property gives 4 components, an
      expression one }
    if (E[1] = '$') and W.FindVar(Copy(E, 2, MaxInt), V) then
      Exit(EvalVec(W, V, Result));
    if W.FindVar(E, V) then
      Exit(EvalVec(W, V, Result));
    Win := ResolveWindow(E, nil, P);
    if (Win <> nil) and (Win <> W) and (P <> '') then
      Exit(PropVec4(Win, P));
    if SameText(Copy(E, 1, 5), 'gui::') or SameText(Copy(E, 1, 6), '$gui::') then
    begin
      V := StateValue(Copy(E, Pos('::', E) + 2, MaxInt));
      if IsNumbers(V) then
        Exit(ParseNumbers(V, Result));
    end;
    Result := EvalVec(W, E, Result);
  end;
end;

function TD3Gui.PropFloat(const W: TD3GuiWindow; const Prop: String): Single;
begin
  Result := PropVec4(W, Prop).X;
end;

function TD3Gui.PropVisible(const W: TD3GuiWindow): Boolean;
begin
  Result := PropFloat(W, 'visible') <> 0;
end;

function TD3Gui.PropText(const W: TD3GuiWindow): String;
var
  Key, V: String;
  Win: TD3GuiWindow;
  P: String;
  Items: TStringArray;
begin
  { a choice shows its choice, an edit its text (and the cursor while
    focused), a bind its cvar's key }
  if W.Kind = gkChoice then
  begin
    Items := W.ChoiceList;
    if (W.Choice >= 0) and (W.Choice <= High(Items)) then
      Exit(Items[W.Choice]);
    Exit('');
  end;
  if W.Kind = gkEdit then
  begin
    Result := W.EditText;
    if D3StrToFloat(W.Prop('password', '0'), 0) <> 0 then
      Result := StringOfChar('*', Length(Result));
    if FFocus = W then
      Result := Result + '_';
    Exit;
  end;
  Result := W.Text;
  { "gui::name" or "$gui::name": the GUI state (the entity's keys) }
  Key := Result;
  if (Key <> '') and (Key[1] = '$') then
    Delete(Key, 1, 1);
  if SameText(Copy(Key, 1, 5), 'gui::') then
    Result := StateValue(Copy(Key, 6, MaxInt))
  else
  if Pos('::', Key) > 0 then
  begin
    Win := ResolveWindow(Key, nil, P);
    if (Win <> nil) and (P = 'text') then
      Result := PropText(Win);
  end else
  if W.FindVar(Key, V) then
    Result := V;
  { "#str_01234": the string tables (idLangDict) }
  Result := D3LangString(Result);
  { Doom 3 strings use "\n" for new lines }
  Result := StringReplace(Result, '\n', #10, [rfReplaceAll]);
end;

{ Scripts -------------------------------------------------------------------- }

function JoinArgs(const Args: TStringArray; const From: Integer): String;
var
  I: Integer;
begin
  Result := '';
  for I := From to High(Args) do
  begin
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + Args[I];
  end;
end;

procedure TD3Gui.RunScript(const W: TD3GuiWindow; const Script: TD3GuiScript);
var
  C: TD3GuiCommand;
  Dest, Prop, Value: String;
  Win: TD3GuiWindow;
  T: TD3GuiTransition;
  I: Integer;
  Changed: Boolean;
begin
  if Script = nil then
    Exit;
  for C in Script do
  begin
    case C.Name of
      'if':
        begin
          if Eval(W, C.Condition) <> 0 then
            RunScript(W, C.ThenList)
          else
            RunScript(W, C.ElseList);
        end;
      'set':
        begin
          if Length(C.Args) < 2 then
            Continue;
          Dest := C.Args[0];
          if (Dest <> '') and (Dest[1] = '$') then
            Delete(Dest, 1, 1);
          Value := JoinArgs(C.Args, 1);
          if SameText(Dest, 'cmd') then
          begin
            { a command for the entity (idWindow::AddCommand) }
            if FCmd <> '' then
              FCmd := FCmd + ' ; ';
            FCmd := FCmd + Value;
          end else
          if SameText(Dest, 'print') then
            WritelnLog('Doom3Gui', '%s: %s', [Name, Value])
          else
          if SameText(Copy(Dest, 1, 5), 'gui::') then
            SetState(Copy(Dest, 6, MaxInt), Value)
          else
          begin
            Win := ResolveWindow(Dest, W, Prop);
            if Win <> nil then
            begin
              { a transition of the property ends }
              for I := FTransitions.Count - 1 downto 0 do
                if (FTransitions[I].Window = Win) and (FTransitions[I].Prop = Prop) then
                  FTransitions.Delete(I);
              Win.SetProp(Prop, Value);
              Dirty := True;
            end;
          end;
        end;
      'transition':
        begin
          if Length(C.Args) < 4 then
            Continue;
          Dest := C.Args[0];
          if (Dest <> '') and (Dest[1] = '$') then
            Delete(Dest, 1, 1);
          Win := ResolveWindow(Dest, W, Prop);
          if Win = nil then
            Continue;
          T.Window := Win;
          T.Prop := Prop;
          T.From := ParseNumbers(C.Args[1], PropVec4(Win, Prop));
          T.To_ := ParseNumbers(C.Args[2], T.From);
          T.Start := FTime;
          T.Duration := Round(D3StrToFloat(Unquote(C.Args[3]), 0));
          T.Accel := 0;
          T.Decel := 0;
          if Length(C.Args) > 4 then
            T.Accel := D3StrToFloat(Unquote(C.Args[4]), 0);
          if Length(C.Args) > 5 then
            T.Decel := D3StrToFloat(Unquote(C.Args[5]), 0);
          for I := FTransitions.Count - 1 downto 0 do
            if (FTransitions[I].Window = Win) and (FTransitions[I].Prop = Prop) then
              FTransitions.Delete(I);
          FTransitions.Add(T);
          Dirty := True;
        end;
      'resettime':
        begin
          { resetTime [window] [ms] }
          Win := W;
          I := 0;
          if Length(C.Args) = 1 then
          begin
            if IsNumbers(Unquote(C.Args[0])) then
              I := Round(D3StrToFloat(Unquote(C.Args[0]), 0))
            else
              Win := FindWindow(Unquote(C.Args[0]));
          end else
          if Length(C.Args) >= 2 then
          begin
            Win := FindWindow(Unquote(C.Args[0]));
            I := Round(D3StrToFloat(Unquote(C.Args[1]), 0));
          end;
          if Win <> nil then
            ResetTime(Win, I);
        end;
      'runscript':
        begin
          if Length(C.Args) >= 1 then
          begin
            if FCmd <> '' then
              FCmd := FCmd + ' ; ';
            FCmd := FCmd + 'runScript ' + Unquote(C.Args[0]);
          end;
        end;
      'localsound':
        begin
          { played by the entity (idEntity::HandleGuiCommands "play") }
          if Length(C.Args) >= 1 then
          begin
            if FCmd <> '' then
              FCmd := FCmd + ' ; ';
            FCmd := FCmd + 'play ' + Unquote(C.Args[0]);
          end;
        end;
      'showcursor':
        begin
          Changed := NoCursor;
          if Length(C.Args) >= 1 then
            NoCursor := D3StrToFloat(Unquote(C.Args[0]), 1) = 0;
          if Changed <> NoCursor then
            Dirty := True;
        end;
      'evalregs', 'setfocus', 'resetcinematics', 'endgame':
        ;
      else
        WritelnWarning('Doom3Gui', '%s: unknown script command "%s"', [Name, C.Name]);
    end;
  end;
end;

{ Fonts ---------------------------------------------------------------------- }

var
  Fonts: specialize TObjectDictionary<String, TD3Font>;
  { the glyph pages (shared by a font's sizes) }
  FontPages: specialize TObjectList<TRGBAlphaImage>;
  { names without font files (don't look again) }
  MissingFonts: TStringList;

destructor TD3Font.Destroy;
var
  I: Integer;
begin
  for I := 0 to 2 do
    FreeAndNil(Sizes[I]);
  inherited Destroy;
end;

function TD3Font.SizeFor(const TextScale: Single): TD3FontSize;
var
  I: Integer;
begin
  { idDeviceContext::SetFontByScale: gui_smallFontLimit 0.30,
    gui_mediumFontLimit 0.60 }
  if TextScale <= 0.30 then
    I := 0
  else
  if TextScale <= 0.60 then
    I := 1
  else
    I := 2;
  Result := Sizes[I];
  { a missing size: the nearest }
  if Result = nil then
    for I := 0 to 2 do
      if Sizes[I] <> nil then
        Exit(Sizes[I]);
end;

function TD3Font.TextWidth(const S: String; const TextScale: Single): Single;
var
  Size: TD3FontSize;
  I: Integer;
begin
  Result := 0;
  Size := SizeFor(TextScale);
  if Size = nil then
    Exit;
  for I := 1 to Length(S) do
    Result := Result + Size.Glyphs[Ord(S[I])].XSkip;
  Result := Result * TextScale * Size.GlyphScale;
end;

function TD3Font.LineHeight(const TextScale: Single): Single;
var
  Size: TD3FontSize;
begin
  Size := SizeFor(TextScale);
  if Size = nil then
    Exit(48 * TextScale);
  Result := Size.MaxHeight * TextScale * Size.GlyphScale;
end;

{ The data directory of a GUI font name: "fonts/micro" -> fonts/<lang>/micro,
  "fonts" -> fonts/<lang> (idDeviceContext::FindFont). }
function FontDir(const AName: String): String;
begin
  Result := NormalizeD3Path(AName);
  if Result = 'fonts' then
    Result := 'fonts/' + D3FontLang
  else
  if Copy(Result, 1, 6) = 'fonts/' then
    Result := 'fonts/' + D3FontLang + '/' + Copy(Result, 7, MaxInt);
end;

function LoadFontSize(const Dir: String; const PointSize: Integer): TD3FontSize;
var
  S: TStream;
  Data: array of Byte;
  P, I: Integer;
  ShaderName, ImageFile: String;
  Pages: specialize TDictionary<String, TRGBAlphaImage>;
  Page: TRGBAlphaImage;
  Loaded: TCastleImage;

  function ReadInt: Integer;
  begin
    { through LongWord: a negative value overflows Integer with range checks }
    Result := Integer(LongWord(Data[P]) or (LongWord(Data[P + 1]) shl 8) or
      (LongWord(Data[P + 2]) shl 16) or (LongWord(Data[P + 3]) shl 24));
    Inc(P, 4);
  end;

  function ReadFloat: Single;
  begin
    Move(Data[P], Result, 4);
    Inc(P, 4);
  end;

begin
  Result := nil;
  if not D3Fs.FileExists(Dir + '/fontImage_' + IntToStr(PointSize) + '.dat') then
    Exit;
  S := D3Fs.OpenFile(Dir + '/fontImage_' + IntToStr(PointSize) + '.dat');
  try
    SetLength(Data, S.Size);
    if Length(Data) > 0 then
      S.ReadBuffer(Data[0], Length(Data));
  finally
    S.Free;
  end;
  { fontInfo_t: 256 glyphInfo_t (7 ints, 4 floats, 1 int, char[32]),
    float glyphScale, char name[64] }
  if Length(Data) < 256 * 80 + 4 then
  begin
    WritelnWarning('Doom3Gui', 'Font file "%s/fontImage_%d.dat" is too short', [Dir, PointSize]);
    Exit;
  end;
  Result := TD3FontSize.Create;
  Result.PointSize := PointSize;
  Pages := specialize TDictionary<String, TRGBAlphaImage>.Create;
  try
    P := 0;
    for I := 0 to 255 do
    begin
      Result.Glyphs[I].Height := ReadInt;
      Result.Glyphs[I].Top := ReadInt;
      Result.Glyphs[I].Bottom := ReadInt;
      Result.Glyphs[I].Pitch := ReadInt;
      Result.Glyphs[I].XSkip := ReadInt;
      Result.Glyphs[I].ImageWidth := ReadInt;
      Result.Glyphs[I].ImageHeight := ReadInt;
      Result.Glyphs[I].S := ReadFloat;
      Result.Glyphs[I].T := ReadFloat;
      Result.Glyphs[I].S2 := ReadFloat;
      Result.Glyphs[I].T2 := ReadFloat;
      ReadInt; { the material pointer }
      ShaderName := '';
      while (ShaderName = '') or (Length(ShaderName) < 32) do
      begin
        if Data[P + Length(ShaderName)] = 0 then
          Break;
        ShaderName := ShaderName + Chr(Data[P + Length(ShaderName)]);
      end;
      Inc(P, 32);
      Result.Glyphs[I].Page := nil;
      if (ShaderName <> '') and (Result.Glyphs[I].ImageWidth > 0) then
      begin
        if not Pages.TryGetValue(ShaderName, Page) then
        begin
          { Doom 3 stores "fonts/<name>_N_SS" and looks the page up in
            the font's directory }
          ImageFile := FindImageFile(Dir + '/' + ExtractFileName(ChangeFileExt(ShaderName, '')), False);
          if ImageFile = '' then
            ImageFile := FindImageFile(ChangeFileExt(ShaderName, ''), False);
          Page := nil;
          if ImageFile <> '' then
          try
            Loaded := LoadImage(D3FsUrl(ImageFile));
            try
              if Loaded is TRGBAlphaImage then
              begin
                Page := TRGBAlphaImage(Loaded);
                Loaded := nil;
              end else
              begin
                Page := TRGBAlphaImage.Create;
                Page.Assign(Loaded);
              end;
            finally
              Loaded.Free;
            end;
          except
            on E: Exception do
              WritelnWarning('Doom3Gui', 'Cannot load font page "%s": %s', [ImageFile, E.Message]);
          end
          else
            WritelnWarning('Doom3Gui', 'Font page "%s" of "%s" not found', [ShaderName, Dir]);
          Pages.Add(ShaderName, Page);
        end;
        Result.Glyphs[I].Page := Page;
      end;
      Result.MaxHeight := Max(Result.MaxHeight, Result.Glyphs[I].Height);
      Result.MaxWidth := Max(Result.MaxWidth, Result.Glyphs[I].XSkip);
    end;
    Result.GlyphScale := ReadFloat;
    if (Result.GlyphScale <= 0) or (Result.GlyphScale > 100) then
      Result.GlyphScale := 48 / PointSize;
  finally
    { the pages stay alive with the glyphs (freed with the cache) }
    for Page in Pages.Values do
      if Page <> nil then
        FontPages.Add(Page);
    Pages.Free;
  end;
end;

function D3Font(const AName: String): TD3Font;
var
  Key, Dir: String;
  I, Loaded: Integer;
begin
  Key := LowerCase(AName);
  if Key = '' then
    Key := 'fonts';
  if Fonts.TryGetValue(Key, Result) then
    Exit;
  if MissingFonts.IndexOf(Key) >= 0 then
    Exit(nil);
  Dir := FontDir(Key);
  Result := TD3Font.Create;
  Result.Name := Key;
  Loaded := 0;
  for I := 0 to 2 do
  begin
    Result.Sizes[I] := LoadFontSize(Dir, 12 shl I);
    if Result.Sizes[I] <> nil then
      Inc(Loaded);
  end;
  if Loaded = 0 then
  begin
    FreeAndNil(Result);
    MissingFonts.Add(Key);
    Exit(nil);
  end;
  WritelnLog('Doom3Gui', 'Font "%s": %d sizes from %s', [Key, Loaded, Dir]);
  Fonts.Add(Key, Result);
end;

{ Rendering ------------------------------------------------------------------ }

var
  { GUI background images (files) as RGBA, loaded once }
  GuiSources: specialize TObjectDictionary<String, TRGBAlphaImage>;

function GuiSourceImage(const FileName: String): TRGBAlphaImage;
var
  Loaded: TCastleImage;
begin
  if GuiSources.TryGetValue(FileName, Result) then
    Exit;
  Loaded := LoadImage(D3FsUrl(FileName));
  try
    if Loaded is TRGBAlphaImage then
    begin
      Result := TRGBAlphaImage(Loaded);
      Loaded := nil;
    end else
    begin
      Result := TRGBAlphaImage.Create;
      Result.Assign(Loaded);
    end;
  finally
    Loaded.Free;
  end;
  GuiSources.Add(FileName, Result);
end;

type
  TGuiPainter = class
  strict private
    { scratch images for DrawTransformed, one per nesting level, reused
      for every transformed window of a render (hud.gui has ~20) }
    FScratches: array of TRGBAlphaImage;
    FScratchDepth: Integer;
  public
    Image: TRGBAlphaImage;
    { the window being drawn by DrawTransformed (not transformed again) }
    InTransform: TD3GuiWindow;
    Gui: TD3Gui;
    Font: TTextureFontData;
    { pixels per GUI unit }
    ScaleX, ScaleY: Single;
    { the pixels drawing may touch (idDeviceContext's clip rect: the
      windows' rects), end exclusive }
    ClipX0, ClipY0, ClipX1, ClipY1: Integer;
    { blend 0..255 color bytes with alpha 0..255 }
    procedure BlendBytes(const X, Y: Integer; const R, G, B, A: Integer); inline;
    { the pixels a GUI rectangle covers (y down), end exclusive }
    procedure PixelBox(const R: TFloatRectangle; out X0, Y0, X1, Y1: Integer);
    procedure FillRect(const R: TFloatRectangle; const C: TVector4);
    { add 0..255 color bytes (blend add) }
    procedure AddBytes(const X, Y: Integer; const R, G, B: Integer);
    procedure DrawImage(const R: TFloatRectangle; const Src: TCastleImage; const Tint: TVector4;
      const Additive: Boolean = False);
    { a part (S, T .. S2, T2, Doom 3 t down) of an image, its alpha
      scaled, in a color }
    procedure DrawImagePart(const X0, Y0, DstW, DstH: Integer; const Src: TRGBAlphaImage;
      const S, T, S2, T2: Single; const CR, CG, CB, CA: Integer);
    procedure DrawText(const R: TFloatRectangle; const W: TD3GuiWindow; const S: String);
    procedure DrawList(const R: TFloatRectangle; const W: TD3GuiWindow);
    procedure DrawWindow(const W: TD3GuiWindow; const ParentX, ParentY: Single);
    procedure DrawSliderThumb(const W: TD3GuiWindow; const R: TFloatRectangle);
    { a window with rotate / shear: drawn into a scratch image, then mapped
      onto Image around its center (idWindow::SetupTransforms) }
    function DrawTransformed(const W: TD3GuiWindow; const ParentX, ParentY: Single): Boolean;
    procedure DrawCursor;
  public
    destructor Destroy; override;
  end;

procedure TGuiPainter.BlendBytes(const X, Y: Integer; const R, G, B, A: Integer);
var
  P: PVector4Byte;
begin
  if (A <= 0) or (X < ClipX0) or (Y < ClipY0) or (X >= ClipX1) or (Y >= ClipY1) then
    Exit;
  { CGE images are bottom-to-top }
  P := Image.PixelPtr(X, Image.Height - 1 - Y);
  if A >= 255 then
  begin
    P^.X := R;
    P^.Y := G;
    P^.Z := B;
    P^.W := 255;
    Exit;
  end;
  P^.X := (P^.X * (255 - A) + R * A + 127) div 255;
  P^.Y := (P^.Y * (255 - A) + G * A + 127) div 255;
  P^.Z := (P^.Z * (255 - A) + B * A + 127) div 255;
  P^.W := P^.W + ((255 - P^.W) * A + 127) div 255;
end;

procedure TGuiPainter.AddBytes(const X, Y: Integer; const R, G, B: Integer);
var
  P: PVector4Byte;
begin
  if (X < ClipX0) or (Y < ClipY0) or (X >= ClipX1) or (Y >= ClipY1) then
    Exit;
  P := Image.PixelPtr(X, Image.Height - 1 - Y);
  P^.X := Min(255, P^.X + R);
  P^.Y := Min(255, P^.Y + G);
  P^.Z := Min(255, P^.Z + B);
end;

procedure TGuiPainter.PixelBox(const R: TFloatRectangle; out X0, Y0, X1, Y1: Integer);
begin
  X0 := Round(R.Left * ScaleX);
  Y0 := Round(R.Bottom * ScaleY);
  X1 := Round((R.Left + R.Width) * ScaleX);
  Y1 := Round((R.Bottom + R.Height) * ScaleY);
end;

{ 0..255 of a 0..1 color component }
function ColorByte(const F: Single): Integer;
begin
  if F <= 0 then
    Result := 0
  else
  if F >= 1 then
    Result := 255
  else
    Result := Round(F * 255);
end;

{ Blend a color over a destination pixel (BlendBytes without the clip
  check and address computation: the hot loops' inner step). }
procedure BlendInto(const D: PVector4Byte; const R, G, B, A: Integer);
begin
  if A >= 255 then
  begin
    D^.X := R;
    D^.Y := G;
    D^.Z := B;
    D^.W := 255;
    Exit;
  end;
  D^.X := (D^.X * (255 - A) + R * A + 127) div 255;
  D^.Y := (D^.Y * (255 - A) + G * A + 127) div 255;
  D^.Z := (D^.Z * (255 - A) + B * A + 127) div 255;
  D^.W := D^.W + ((255 - D^.W) * A + 127) div 255;
end;

procedure TGuiPainter.FillRect(const R: TFloatRectangle; const C: TVector4);
var
  X, Y, X0, Y0, X1, Y1, CR, CG, CB, CA: Integer;
  D: PVector4Byte;
begin
  if C.W <= 0 then
    Exit;
  PixelBox(R, X0, Y0, X1, Y1);
  CR := ColorByte(C.X);
  CG := ColorByte(C.Y);
  CB := ColorByte(C.Z);
  CA := ColorByte(C.W);
  { only inside the clip (BlendBytes checks it too) }
  X0 := Max(ClipX0, X0);
  X1 := Min(ClipX1, X1);
  if X1 <= X0 then
    Exit;
  for Y := Max(ClipY0, Y0) to Min(ClipY1, Y1) - 1 do
  begin
    { CGE images are bottom-to-top }
    D := Image.PixelPtr(X0, Image.Height - 1 - Y);
    for X := X0 to X1 - 1 do
    begin
      BlendInto(D, CR, CG, CB, CA);
      Inc(D);
    end;
  end;
end;

procedure TGuiPainter.DrawImage(const R: TFloatRectangle; const Src: TCastleImage; const Tint: TVector4;
  const Additive: Boolean);
var
  X, Y, X0, Y0, X1, Y1, SY, TR, TG, TB, TA: Integer;
  Columns: array of Integer;
  Row, P, D: PVector4Byte;
  Rgba: TRGBAlphaImage;
  FlipX, FlipY: Boolean;
  F: Single;
  CX0, CX1, SR, SG, SB, SA, V: Integer;
begin
  PixelBox(R, X0, Y0, X1, Y1);
  { idDeviceContext::DrawMaterial: a negative width or height mirrors the
    image over the rect from x (y) to x + abs(w) (y + abs(h)) }
  FlipX := X1 < X0;
  if FlipX then
    X1 := X0 + (X0 - X1);
  FlipY := Y1 < Y0;
  if FlipY then
    Y1 := Y0 + (Y0 - Y1);
  if (X1 <= X0) or (Y1 <= Y0) or not (Src is TRGBAlphaImage) then
    Exit;
  Rgba := TRGBAlphaImage(Src);
  TR := ColorByte(Tint.X);
  TG := ColorByte(Tint.Y);
  TB := ColorByte(Tint.Z);
  TA := ColorByte(Tint.W);
  { nothing to draw: transparent, or adding black (the menu's many hidden
    highlight layers) }
  if (not Additive and (TA = 0)) or (Additive and (TR = 0) and (TG = 0) and (TB = 0)) then
    Exit;
  if (Max(ClipX0, X0) >= Min(ClipX1, X1)) or (Max(ClipY0, Y0) >= Min(ClipY1, Y1)) then
    Exit;
  { the source column of each pixel column }
  SetLength(Columns, X1 - X0);
  for X := X0 to X1 - 1 do
  begin
    F := (X - X0 + 0.5) / (X1 - X0);
    if FlipX then
      F := 1 - F;
    Columns[X - X0] := Min(Rgba.Width - 1, Trunc(F * Rgba.Width));
  end;
  for Y := Max(ClipY0, Y0) to Min(ClipY1, Y1) - 1 do
  begin
    { GUI y goes down, the source image's rows go up }
    F := (Y - Y0 + 0.5) / (Y1 - Y0);
    if FlipY then
      F := 1 - F;
    SY := Min(Rgba.Height - 1, Trunc((1 - F) * Rgba.Height));
    Row := Rgba.PixelPtr(0, SY);
    CX0 := Max(ClipX0, X0);
    CX1 := Min(ClipX1, X1);
    D := Image.PixelPtr(CX0, Image.Height - 1 - Y);
    for X := CX0 to CX1 - 1 do
    begin
      P := Row;
      Inc(P, Columns[X - X0]);
      { the blend written out (the menu's full screen layers make this the
        hot loop); V div 255 as (V + 1 + V shr 8) shr 8 }
      if Additive then
      begin
        SR := D^.X + (P^.X * TR + 128 + ((P^.X * TR + 128) shr 8)) shr 8;
        SG := D^.Y + (P^.Y * TG + 128 + ((P^.Y * TG + 128) shr 8)) shr 8;
        SB := D^.Z + (P^.Z * TB + 128 + ((P^.Z * TB + 128) shr 8)) shr 8;
        if SR > 255 then SR := 255;
        if SG > 255 then SG := 255;
        if SB > 255 then SB := 255;
        D^.X := SR;
        D^.Y := SG;
        D^.Z := SB;
      end else
      if P^.W <> 0 then
      begin
        SA := P^.W * TA;
        SA := (SA + 128 + ((SA + 128) shr 8)) shr 8;
        if SA > 0 then
        begin
          SR := P^.X * TR;
          SR := (SR + 128 + ((SR + 128) shr 8)) shr 8;
          SG := P^.Y * TG;
          SG := (SG + 128 + ((SG + 128) shr 8)) shr 8;
          SB := P^.Z * TB;
          SB := (SB + 128 + ((SB + 128) shr 8)) shr 8;
          if SA >= 255 then
          begin
            D^.X := SR;
            D^.Y := SG;
            D^.Z := SB;
            D^.W := 255;
          end else
          begin
            V := D^.X * (255 - SA) + SR * SA + 128;
            D^.X := (V + (V shr 8)) shr 8;
            V := D^.Y * (255 - SA) + SG * SA + 128;
            D^.Y := (V + (V shr 8)) shr 8;
            V := D^.Z * (255 - SA) + SB * SA + 128;
            D^.Z := (V + (V shr 8)) shr 8;
            V := (255 - D^.W) * SA + 128;
            D^.W := D^.W + (V + (V shr 8)) shr 8;
          end;
        end;
      end;
      Inc(D);
    end;
  end;
end;

procedure TGuiPainter.DrawImagePart(const X0, Y0, DstW, DstH: Integer; const Src: TRGBAlphaImage;
  const S, T, S2, T2: Single; const CR, CG, CB, CA: Integer);
var
  GX, GY, SX, SY, A: Integer;
  P: PVector4Byte;
  SrcX0, SrcY0, SrcW, SrcH: Single;
begin
  if (Src = nil) or (DstW <= 0) or (DstH <= 0) then
    Exit;
  SrcX0 := S * Src.Width;
  SrcW := (S2 - S) * Src.Width;
  { Doom 3 t goes down the image; CGE rows go up }
  SrcY0 := T * Src.Height;
  SrcH := (T2 - T) * Src.Height;
  for GY := 0 to DstH - 1 do
  begin
    SY := Trunc(SrcY0 + (GY + 0.5) / DstH * SrcH);
    SY := Src.Height - 1 - Clamped(SY, 0, Src.Height - 1);
    for GX := 0 to DstW - 1 do
    begin
      SX := Clamped(Trunc(SrcX0 + (GX + 0.5) / DstW * SrcW), 0, Src.Width - 1);
      P := Src.PixelPtr(SX, SY);
      { the glyph is in the alpha (white RGB), or a gray image }
      A := P^.W;
      if A = 255 then
        A := Max(P^.X, Max(P^.Y, P^.Z));
      BlendBytes(X0 + GX, Y0 + GY, CR, CG, CB, CA * A div 255);
    end;
  end;
end;

{ Doom 3 color escapes ("^8" gray...) left out }
function StripColorCodes(const S: String): String;
var
  I: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] = '^') and (I < Length(S)) then
    begin
      Inc(I, 2);
      Continue;
    end;
    Result := Result + S[I];
    Inc(I);
  end;
end;

procedure TGuiPainter.DrawList(const R: TFloatRectangle; const W: TD3GuiWindow);
var
  I, C, Count, Sel: Integer;
  RowH, X0, X1, Y: Single;
  Columns: TStringArray;
  Hilite: TVector4;
begin
  { idListWindow::Draw: a row per item, its columns at the tab stops, the
    selected row hilited }
  RowH := Gui.ListRowHeight(W);
  Count := Gui.ListCount(W);
  Sel := Gui.ListSelection(W);
  for I := 0 to Count - 1 do
  begin
    Y := R.Bottom + I * RowH;
    if Y + RowH > R.Bottom + R.Height + 0.5 then
      Break;
    if I = Sel then
    begin
      Hilite := Gui.PropVec4(W, 'forecolor');
      Hilite.W := Hilite.W * 0.25;
      FillRect(FloatRectangle(R.Left, Y, R.Width, RowH), Hilite);
    end;
    Columns := StripColorCodes(Gui.ListItem(W, I)).Split([#9]);
    for C := 0 to High(Columns) do
    begin
      if C <= High(W.Tabstops) then
        X0 := R.Left + W.Tabstops[C]
      else
      if C = 0 then
        X0 := R.Left
      else
        X0 := R.Left + R.Width * C / Length(Columns);
      if C + 1 <= High(W.Tabstops) then
        X1 := R.Left + W.Tabstops[C + 1]
      else
        X1 := R.Left + R.Width;
      DrawText(FloatRectangle(X0, Y, Max(1, X1 - X0), RowH), W, Columns[C]);
    end;
  end;
end;

procedure TGuiPainter.DrawText(const R: TFloatRectangle; const W: TD3GuiWindow; const S: String);
var
  Scale, LineHeight, PenX, LineWidth, TextScale, UseScale, TextAlignX, TextAlignY: Single;
  Lines: TStringList;
  Words: TStringArray;
  Line, Candidate, Para: String;
  I, J, GX, GY, SX, SY, DstX0, DstY0, DstW, DstH, TextAlign: Integer;
  G: TTextureFontData.TGlyph;
  Rect: TRectangle;
  Baseline: Single;
  GlyphAlpha, ForeR, ForeG, ForeB, ForeA: Integer;
  ForeColor: TVector4;
  D3: TD3Font;
  Size: TD3FontSize;
  Glyph: TD3FontGlyph;

  function StringWidth(const T: String): Single;
  begin
    if D3 <> nil then
      Result := D3.TextWidth(T, TextScale)
    else
      Result := Font.TextWidth(T) * Scale;
  end;

begin
  if S = '' then
    Exit;
  ForeColor := Gui.PropVec4(W, 'forecolor');
  ForeR := ColorByte(ForeColor.X);
  ForeG := ColorByte(ForeColor.Y);
  ForeB := ColorByte(ForeColor.Z);
  ForeA := ColorByte(ForeColor.W);
  if ForeA <= 0 then
    Exit;
  TextScale := Gui.PropFloat(W, 'textscale');
  TextAlign := Round(Gui.PropFloat(W, 'textalign'));
  TextAlignX := Gui.PropFloat(W, 'textalignx');
  TextAlignY := Gui.PropFloat(W, 'textaligny');
  D3 := D3Font(W.FontName);
  Size := nil;
  if D3 <> nil then
    Size := D3.SizeFor(TextScale);
  if Size = nil then
    D3 := nil;
  if D3 <> nil then
  begin
    { idDeviceContext::DrawText: MaxCharHeight, 5 more between lines }
    UseScale := TextScale * Size.GlyphScale;
    LineHeight := D3.LineHeight(TextScale) + 5;
    Scale := UseScale;
  end else
  begin
    { Doom 3's fonts are 48 pixels at textscale 1 }
    Scale := 48 * TextScale / Max(1, Font.Size);
    LineHeight := Font.Size * Scale * 1.15;
    UseScale := Scale;
  end;
  Lines := TStringList.Create;
  try
    { word wrap to the window width }
    for Para in S.Split([#10]) do
    begin
      if W.NoWrap then
      begin
        Lines.Add(Para);
        Continue;
      end;
      Words := Para.Split([' ']);
      Line := '';
      for I := 0 to High(Words) do
      begin
        if Line = '' then
          Candidate := Words[I]
        else
          Candidate := Line + ' ' + Words[I];
        if (Line <> '') and (StringWidth(Candidate) > R.Width - TextAlignX) then
        begin
          Lines.Add(Line);
          Line := Words[I];
        end else
          Line := Candidate;
      end;
      Lines.Add(Line);
    end;

    if D3 <> nil then
      Baseline := R.Bottom + TextAlignY + D3.LineHeight(TextScale)
    else
      Baseline := R.Bottom + TextAlignY + Font.Size * Scale;
    for I := 0 to Lines.Count - 1 do
    begin
      LineWidth := StringWidth(Lines[I]);
      case TextAlign of
        1: PenX := R.Left + (R.Width - LineWidth) / 2;
        2: PenX := R.Left + R.Width - LineWidth - TextAlignX;
        else PenX := R.Left + TextAlignX;
      end;
      for J := 1 to Length(Lines[I]) do
      begin
        if D3 <> nil then
        begin
          Glyph := Size.Glyphs[Ord(Lines[I][J])];
          if (Glyph.Page <> nil) and (Glyph.ImageWidth > 0) and (Glyph.ImageHeight > 0) then
          begin
            { PaintChar at (x, baseline - top * useScale), imageWidth x
              imageHeight scaled }
            DstX0 := Round(PenX * ScaleX);
            DstY0 := Round((Baseline - Glyph.Top * UseScale) * ScaleY);
            DstW := Max(1, Round(Glyph.ImageWidth * UseScale * ScaleX));
            DstH := Max(1, Round(Glyph.ImageHeight * UseScale * ScaleY));
            DrawImagePart(DstX0, DstY0, DstW, DstH, Glyph.Page, Glyph.S, Glyph.T, Glyph.S2, Glyph.T2,
              ForeR, ForeG, ForeB, ForeA);
          end;
          PenX := PenX + Glyph.XSkip * UseScale;
          Continue;
        end;
        G := Font.Glyph(Ord(Lines[I][J]), False);
        if G = nil then
          Continue;
        Rect := Font.GlyphDrawImageRect(G);
        if (Rect.Width > 0) and (Rect.Height > 0) then
        begin
          { the glyph's box in GUI coordinates (y down); CGE draws a glyph
            at (pen x - G.X, baseline - G.Y) with y up }
          DstX0 := Round((PenX - G.X * Scale) * ScaleX);
          DstY0 := Round((Baseline + G.Y * Scale - Integer(Rect.Height) * Scale) * ScaleY);
          DstW := Max(1, Round(Rect.Width * Scale * ScaleX));
          DstH := Max(1, Round(Rect.Height * Scale * ScaleY));
          for GY := 0 to DstH - 1 do
            for GX := 0 to DstW - 1 do
            begin
              SX := Rect.Left + Min(Rect.Width - 1, Trunc((GX + 0.5) / DstW * Rect.Width));
              { atlas rows go up, GUI rows go down }
              SY := Rect.Bottom + Rect.Height - 1 - Min(Rect.Height - 1, Trunc((GY + 0.5) / DstH * Rect.Height));
              GlyphAlpha := PByte(Font.Image.PixelPtr(SX, SY))^;
              if GlyphAlpha > 0 then
                BlendBytes(DstX0 + GX, DstY0 + GY, ForeR, ForeG, ForeB, ForeA * GlyphAlpha div 255);
            end;
        end;
        PenX := PenX + G.AdvanceX * Scale;
      end;
      Baseline := Baseline + LineHeight;
    end;
  finally
    Lines.Free;
  end;
end;

destructor TGuiPainter.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FScratches) do
    FreeAndNil(FScratches[I]);
  inherited;
end;

function TGuiPainter.DrawTransformed(const W: TD3GuiWindow; const ParentX, ParentY: Single): Boolean;
var
  Angle, ShearX, ShearY, CosA, SinA, Det, CX, CY, DX, DY, SX, SY, Margin: Single;
  M00, M01, M10, M11, I00, I01, I10, I11: Single;
  V: TVector4;
  Scratch, Main: TRGBAlphaImage;
  Parts: TStringArray;
  X, Y, PX, PY, K, BX0, BY0, BX1, BY1: Integer;
  SaveX0, SaveY0, SaveX1, SaveY1: Integer;
  RX0, RY0, RX1, RY1, Row: Integer;
  P: PVector4Byte;
  OuterInTransform: TD3GuiWindow;
begin
  Result := False;
  Angle := 0;
  if W.Prop('rotate') <> '' then
    Angle := Gui.Eval(W, W.Prop('rotate'));
  ShearX := 0;
  ShearY := 0;
  if W.Prop('shear') <> '' then
  begin
    Parts := StringReplace(W.Prop('shear'), ',', ' ', [rfReplaceAll]).Split([' '], TStringSplitOptions.ExcludeEmpty);
    if Length(Parts) > 0 then
      ShearX := Gui.Eval(W, Parts[0]);
    if Length(Parts) > 1 then
      ShearY := Gui.Eval(W, Parts[1]);
  end;
  if (Abs(Angle) < 0.001) and (Abs(ShearX) < 0.0001) and (Abs(ShearY) < 0.0001) then
    Exit;
  Result := True;
  V := Gui.PropVec4(W, 'rect');
  { a transformed window's own text isn't clipped to it (dhewm3 draws
    hud.gui's 50 wide "100" whole in its 39 wide window): a margin }
  Margin := 24;
  { where the untransformed window draws: its rect with the margin, in
    the parent's clip; only that part of the scratch image is cleared,
    drawn and read }
  RX0 := Max(ClipX0, Floor((ParentX + V.X - Margin) * ScaleX));
  RY0 := Max(ClipY0, Floor((ParentY + V.Y - Margin) * ScaleY));
  RX1 := Min(ClipX1, Ceil((ParentX + V.X + V.Z + Margin) * ScaleX));
  RY1 := Min(ClipY1, Ceil((ParentY + V.Y + V.W + Margin) * ScaleY));
  if (RX1 <= RX0) or (RY1 <= RY0) then
    Exit;
  { the window and its children, untransformed, on a clear scratch image }
  Main := Image;
  if FScratchDepth >= Length(FScratches) then
    SetLength(FScratches, FScratchDepth + 1);
  Scratch := FScratches[FScratchDepth];
  if (Scratch = nil) or (Scratch.Width <> Main.Width) or (Scratch.Height <> Main.Height) then
  begin
    FreeAndNil(FScratches[FScratchDepth]);
    Scratch := TRGBAlphaImage.Create(Main.Width, Main.Height);
    FScratches[FScratchDepth] := Scratch;
  end;
  Inc(FScratchDepth);
  try
    for Row := RY0 to RY1 - 1 do
      FillChar(Scratch.PixelPtr(RX0, Scratch.Height - 1 - Row)^, (RX1 - RX0) * SizeOf(TVector4Byte), 0);
    Image := Scratch;
    OuterInTransform := InTransform;
    InTransform := W;
    SaveX0 := ClipX0;
    SaveY0 := ClipY0;
    SaveX1 := ClipX1;
    SaveY1 := ClipY1;
    ClipX0 := RX0;
    ClipY0 := RY0;
    ClipX1 := RX1;
    ClipY1 := RY1;
    try
      DrawWindow(W, ParentX, ParentY);
    finally
      ClipX0 := SaveX0;
      ClipY0 := SaveY0;
      ClipX1 := SaveX1;
      ClipY1 := SaveY1;
      InTransform := OuterInTransform;
      Image := Main;
    end;
    { the center of its rect (pixels). Doom 3: trans = rotation * smat
      (smat[0][1] = shear.x, smat[1][0] = shear.y), applied to row vectors
      (v * trans): on column vectors M = smat^T * rotation^T, so shear.x
      moves y along x and shear.y x along y (hud.gui's slanted text) }
    CX := (ParentX + V.X + V.Z / 2) * ScaleX;
    CY := (ParentY + V.Y + V.W / 2) * ScaleY;
    CosA := Cos(DegToRad(Angle));
    SinA := Sin(DegToRad(Angle));
    M00 := CosA + ShearY * SinA;
    M01 := -SinA + ShearY * CosA;
    M10 := ShearX * CosA + SinA;
    M11 := -ShearX * SinA + CosA;
    Det := M00 * M11 - M01 * M10;
    if Abs(Det) < 1e-6 then
      Exit;
    I00 := M11 / Det;
    I01 := -M01 / Det;
    I10 := -M10 / Det;
    I11 := M00 / Det;
    { only where the transformed rect lands (its corners' bounds, the clip
      within): children stay in their parent's rect (Doom 3's clip) }
    BX0 := MaxInt;
    BY0 := MaxInt;
    BX1 := -MaxInt;
    BY1 := -MaxInt;
    for K := 0 to 3 do
    begin
      DX := (ParentX + V.X - Margin + (V.Z + 2 * Margin) * (K mod 2)) * ScaleX - CX;
      DY := (ParentY + V.Y - Margin + (V.W + 2 * Margin) * (K div 2)) * ScaleY - CY;
      DX := DX / ScaleX;
      DY := DY / ScaleY;
      SX := CX + (M00 * DX + M01 * DY) * ScaleX;
      SY := CY + (M10 * DX + M11 * DY) * ScaleY;
      BX0 := Min(BX0, Floor(SX) - 2);
      BY0 := Min(BY0, Floor(SY) - 2);
      BX1 := Max(BX1, Ceil(SX) + 2);
      BY1 := Max(BY1, Ceil(SY) + 2);
    end;
    { Doom 3 clips before transforming (idDeviceContext::ClipCoords, then
      the matrix): the scratch drawing was clipped, its result may reach
      past the parent's clip }
    BX0 := Max(BX0, 0);
    BY0 := Max(BY0, 0);
    BX1 := Min(BX1, Integer(Image.Width));
    BY1 := Min(BY1, Integer(Image.Height));
    SaveX0 := ClipX0;
    SaveY0 := ClipY0;
    SaveX1 := ClipX1;
    SaveY1 := ClipY1;
    ClipX0 := 0;
    ClipY0 := 0;
    ClipX1 := Image.Width;
    ClipY1 := Image.Height;
    { every pixel there from where it comes in the scratch image }
    for Y := BY0 to BY1 - 1 do
      for X := BX0 to BX1 - 1 do
      begin
        { in GUI units (the pixels aren't square) }
        DX := (X + 0.5 - CX) / ScaleX;
        DY := (Y + 0.5 - CY) / ScaleY;
        SX := CX + (I00 * DX + I01 * DY) * ScaleX;
        SY := CY + (I10 * DX + I11 * DY) * ScaleY;
        PX := Floor(SX);
        PY := Floor(SY);
        { only the part drawn and cleared this time }
        if (PX < RX0) or (PY < RY0) or (PX >= RX1) or (PY >= RY1) then
          Continue;
        P := Scratch.PixelPtr(PX, Scratch.Height - 1 - PY);
        { blended onto a clear image its colors are times its alpha }
        if P^.W > 0 then
          BlendBytes(X, Y, Min(255, P^.X * 255 div P^.W), Min(255, P^.Y * 255 div P^.W),
            Min(255, P^.Z * 255 div P^.W), P^.W);
      end;
    ClipX0 := SaveX0;
    ClipY0 := SaveY0;
    ClipX1 := SaveX1;
    ClipY1 := SaveY1;
  finally
    Dec(FScratchDepth);
  end;
end;

procedure TGuiPainter.DrawSliderThumb(const W: TD3GuiWindow; const R: TFloatRectangle);
var
  M: TD3Material;
  F, ImageName: String;
  Img: TRGBAlphaImage;
  Low, High, T, TW, TH: Single;
  Vertical: Boolean;
begin
  M := Decls.Material(W.Prop('thumbshader'));
  ImageName := M.DiffuseImage;
  if M.StageImage <> '' then
    ImageName := M.StageImage;
  if ImageName = '' then
    ImageName := W.Prop('thumbshader');
  F := FindImageFile(ImageName, False);
  if F = '' then
    Exit;
  try
    Img := GuiSourceImage(F);
  except
    Exit;
  end;
  if Img = nil then
    Exit;
  Low := D3StrToFloat(W.Prop('low', '0'), 0);
  High := D3StrToFloat(W.Prop('high', '100'), 100);
  if High = Low then
    T := 0
  else
    T := EnsureRange((W.SliderValue - Low) / (High - Low), 0, 1);
  TW := Img.Width;
  TH := Img.Height;
  Vertical := D3StrToFloat(W.Prop('vertical', '0'), 0) <> 0;
  if Vertical then
    DrawImage(FloatRectangle(R.Left + (R.Width - TW) / 2, R.Bottom + T * (R.Height - TH), TW, TH), Img,
      Gui.PropVec4(W, 'matcolor'))
  else
    DrawImage(FloatRectangle(R.Left + T * (R.Width - TW), R.Bottom + (R.Height - TH) / 2, TW, TH), Img,
      Gui.PropVec4(W, 'matcolor'));
end;

procedure TGuiPainter.DrawWindow(const W: TD3GuiWindow; const ParentX, ParentY: Single);
var
  R: TFloatRectangle;
  M: TD3Material;
  ImageName, F, Bg: String;
  Video: TD3RoqVideo;
  Dyn: TRGBAlphaImage;
  C: TD3GuiWindow;
  B: Single;
  V: TVector4;
  SaveX0, SaveY0, SaveX1, SaveY1, X0, Y0, X1, Y1: Integer;
begin
  if not Gui.PropVisible(W) then
    Exit;
  if (W <> InTransform) and DrawTransformed(W, ParentX, ParentY) then
    Exit;
  { Rect: left, top, width, height; TFloatRectangle's Bottom holds the top
    here (GUI y goes down) }
  V := Gui.PropVec4(W, 'rect');
  R := FloatRectangle(ParentX + V.X, ParentY + V.Y, V.Z, V.W);
  FillRect(R, Gui.PropVec4(W, 'backcolor'));
  { a background named by the GUI state ("gui::PDAVideoVid") }
  Bg := W.Background;
  if SameText(Copy(Bg, 1, 5), 'gui::') then
    Bg := Gui.StateValue(Copy(Bg, 6, MaxInt));
  M := nil;
  if Bg <> '' then
    M := Decls.Material(Bg);
  if (M <> nil) and (M.VideoMap <> '') then
  begin
    { a videomap material: the video's frame at its time (idCinematic) }
    Video := RoqVideo(M.VideoMap);
    if Video <> nil then
    begin
      Video.SeekTime(RoqTime(M.VideoMap), M.VideoLoop);
      DrawImage(R, Video.Image, Gui.PropVec4(W, 'matcolor'));
      Gui.HasVideo := True;
    end;
  end else
  if (M <> nil) and ((Copy(LowerCase(M.StageImage), 1, 17) = 'textures/dynamic/') or
     (Copy(LowerCase(M.DiffuseImage), 1, 17) = 'textures/dynamic/')) then
  begin
    { a camera's view (remoteRenderMap into textures/dynamic/...): the
      game renders it, it changes every frame }
    if Copy(LowerCase(M.StageImage), 1, 17) = 'textures/dynamic/' then
      Dyn := DynamicImage(M.StageImage)
    else
      Dyn := DynamicImage(M.DiffuseImage);
    if Dyn <> nil then
      DrawImage(R, Dyn, Gui.PropVec4(W, 'matcolor'));
    Gui.HasVideo := True;
  end else
  if M <> nil then
  begin
    { a material (its diffuse / stage image) or an image }
    ImageName := M.DiffuseImage;
    if M.StageImage <> '' then
      ImageName := M.StageImage;
    F := FindImageFile(ImageName, False);
    if F <> '' then
    try
      { a "blend add" stage (the PDA's glow overlays) adds its colors }
      DrawImage(R, GuiSourceImage(F), Gui.PropVec4(W, 'matcolor'),
        (M.StageImage <> '') and (M.StageBlend = bmAdd));
    except
      on E: Exception do
        WritelnWarning('Doom3Gui', 'Cannot draw "%s": %s', [F, E.Message]);
    end;
  end;
  { a slider's thumb (idSliderWindow::Draw): its image's size, along the
    track by the value }
  if (W.Kind = gkSlider) and (W.Prop('thumbshader') <> '') then
    DrawSliderThumb(W, R);
  B := Gui.PropFloat(W, 'bordersize');
  V := Gui.PropVec4(W, 'bordercolor');
  if (B > 0) and (V.W > 0) then
  begin
    FillRect(FloatRectangle(R.Left, R.Bottom, R.Width, B), V);
    FillRect(FloatRectangle(R.Left, R.Bottom + R.Height - B, R.Width, B), V);
    FillRect(FloatRectangle(R.Left, R.Bottom + B, B, R.Height - 2 * B), V);
    FillRect(FloatRectangle(R.Left + R.Width - B, R.Bottom + B, B, R.Height - 2 * B), V);
  end;
  { idWindow::Redraw: the text and the children are clipped to the rect
    (a window shrunk to height 0 hides them: the PDA's objectives) }
  SaveX0 := ClipX0;
  SaveY0 := ClipY0;
  SaveX1 := ClipX1;
  SaveY1 := ClipY1;
  { a transformed window: only its parent clips it (see DrawTransformed) }
  if not W.NoClip and (W <> InTransform) then
  begin
    PixelBox(R, X0, Y0, X1, Y1);
    ClipX0 := Max(ClipX0, Min(X0, X1));
    ClipY0 := Max(ClipY0, Min(Y0, Y1));
    ClipX1 := Min(ClipX1, Max(X0, X1));
    ClipY1 := Min(ClipY1, Max(Y0, Y1));
  end;
  try
    if (ClipX1 > ClipX0) and (ClipY1 > ClipY0) then
    begin
      if W.IsList then
        DrawList(R, W)
      else
        DrawText(R, W, Gui.PropText(W));
      for C in W.Children do
        DrawWindow(C, R.Left, R.Bottom);
    end;
  finally
    ClipX0 := SaveX0;
    ClipY0 := SaveY0;
    ClipX1 := SaveX1;
    ClipY1 := SaveY1;
  end;
end;

{ Fill a polygon (GUI coordinates, y down) with the even-odd rule. }
procedure FillPolygon(const Painter: TGuiPainter; const Points: array of TVector2; const C: TVector4);
var
  X, Y, I, J, Crossings, X0, Y0, X1, Y1, CR, CG, CB, CA: Integer;
  GX, GY: Single;
  MinX, MinY, MaxX, MaxY: Single;
begin
  MinX := Points[0].X;
  MaxX := MinX;
  MinY := Points[0].Y;
  MaxY := MinY;
  for I := 1 to High(Points) do
  begin
    MinX := Min(MinX, Points[I].X);
    MaxX := Max(MaxX, Points[I].X);
    MinY := Min(MinY, Points[I].Y);
    MaxY := Max(MaxY, Points[I].Y);
  end;
  Painter.PixelBox(FloatRectangle(MinX, MinY, MaxX - MinX, MaxY - MinY), X0, Y0, X1, Y1);
  CR := ColorByte(C.X);
  CG := ColorByte(C.Y);
  CB := ColorByte(C.Z);
  CA := ColorByte(C.W);
  for Y := Max(0, Y0) to Min(Integer(Painter.Image.Height), Y1 + 1) - 1 do
    for X := Max(0, X0) to Min(Integer(Painter.Image.Width), X1 + 1) - 1 do
    begin
      GX := (X + 0.5) / Painter.ScaleX;
      GY := (Y + 0.5) / Painter.ScaleY;
      Crossings := 0;
      J := High(Points);
      for I := 0 to High(Points) do
      begin
        if ((Points[I].Y > GY) <> (Points[J].Y > GY)) and
           (GX < (Points[J].X - Points[I].X) * (GY - Points[I].Y) / (Points[J].Y - Points[I].Y) + Points[I].X) then
          Inc(Crossings);
        J := I;
      end;
      if Odd(Crossings) then
        Painter.BlendBytes(X, Y, CR, CG, CB, CA);
    end;
end;

procedure TGuiPainter.DrawCursor;
const
  { idUserInterfaceLocal::DrawCursor: 64 units in entity GUIs }
  CursorSize = 64;
  { an arrow of the same shape as Doom 3's guicursor_arrow, in 32 units }
  Arrow: array [0..6] of TVector2 = (
    (X: 0; Y: 0), (X: 0; Y: 22), (X: 6; Y: 17), (X: 10; Y: 27), (X: 14; Y: 25), (X: 10; Y: 15), (X: 17; Y: 15));
var
  F: String;
  Points: array [0..6] of TVector2;
  I: Integer;
begin
  if not Gui.CursorShown or Gui.NoCursor then
    Exit;
  F := FindImageFile('ui/assets/guicursor_arrow', False);
  if F <> '' then
  try
    DrawImage(FloatRectangle(Gui.CursorX, Gui.CursorY, CursorSize, CursorSize), GuiSourceImage(F),
      Vector4(1, 1, 1, 1));
    Exit;
  except
    on E: Exception do
      WritelnWarning('Doom3Gui', 'Cannot draw the cursor "%s": %s', [F, E.Message]);
  end;
  for I := 0 to 6 do
    Points[I] := Vector2(Gui.CursorX + Arrow[I].X * 1.5, Gui.CursorY + Arrow[I].Y * 1.5);
  FillPolygon(Self, Points, Vector4(0, 0, 0, 0.8));
  for I := 0 to 6 do
    Points[I] := Vector2(Gui.CursorX + Arrow[I].X * 1.2 + 1, Gui.CursorY + Arrow[I].Y * 1.2 + 1);
  FillPolygon(Self, Points, Vector4(1, 1, 1, 1));
end;

var
  DynamicImages: specialize TObjectDictionary<String, TRGBAlphaImage>;
  WantedDynamic: TStringList;

procedure SetGuiDynamicImage(const AName: String; const Image: TRGBAlphaImage);
var
  Copy_: TRGBAlphaImage;
begin
  Copy_ := TRGBAlphaImage.Create;
  Copy_.Assign(Image);
  DynamicImages.AddOrSetValue(LowerCase(AName), Copy_);
end;

function TakeWantedDynamicImages: TStringArray;
var
  I: Integer;
begin
  SetLength(Result, WantedDynamic.Count);
  for I := 0 to WantedDynamic.Count - 1 do
    Result[I] := WantedDynamic[I];
  WantedDynamic.Clear;
end;

{ a dynamic image by an image name (its extension dropped), noting that a
  GUI wants it; nil while not rendered yet }
function DynamicImage(const ImageName: String): TRGBAlphaImage;
var
  Key: String;
begin
  Key := LowerCase(ChangeFileExt(ImageName, ''));
  if Copy(Key, 1, 17) <> 'textures/dynamic/' then
    Exit(nil);
  if WantedDynamic.IndexOf(Key) < 0 then
    WantedDynamic.Add(Key);
  if not DynamicImages.TryGetValue(Key, Result) then
    Result := nil;
end;

function GuiCvar(const AName, Default: String): String;
var
  I: Integer;
begin
  I := GuiCvars.IndexOfName(LowerCase(AName));
  if I >= 0 then
    Result := GuiCvars.ValueFromIndex[I]
  else
    Result := Default;
end;

procedure SetGuiCvar(const AName, Value: String);
begin
  if GuiCvar(AName, #0) = Value then
    Exit;
  GuiCvars.Values[LowerCase(AName)] := Value;
  if Assigned(OnGuiCvarChanged) then
    OnGuiCvarChanged(LowerCase(AName), Value);
end;

function RenderGui(const Gui: TD3Gui; const State: TStrings): TRGBAlphaImage;
begin
  Result := RenderGui(Gui, State, GuiImageWidth, GuiImageHeight);
end;

function RenderGui(const Gui: TD3Gui; const State: TStrings; const Width, Height: Integer): TRGBAlphaImage;
var
  Painter: TGuiPainter;
  I: Integer;
begin
  Result := TRGBAlphaImage.Create(Width, Height);
  Result.Clear(Vector4Byte(0, 0, 0, 255));
  if (Gui = nil) or (Gui.Desktop = nil) then
    Exit;
  if State <> nil then
  begin
    Gui.State.Clear;
    for I := 0 to State.Count - 1 do
      Gui.SetState(State.Names[I], State.ValueFromIndex[I]);
  end;
  Painter := TGuiPainter.Create;
  try
    Painter.Image := Result;
    Painter.ScaleX := Width / GuiWidth;
    Painter.ScaleY := Height / GuiHeight;
    Painter.Gui := Gui;
    Painter.Font := Font_DefaultUi;
    Painter.ClipX0 := 0;
    Painter.ClipY0 := 0;
    Painter.ClipX1 := Result.Width;
    Painter.ClipY1 := Result.Height;
    Gui.HasVideo := False;
    Painter.DrawWindow(Gui.Desktop, 0, 0);
    Painter.DrawCursor;
  finally
    Painter.Free;
  end;
  Gui.Dirty := False;
end;

function RenderGuiTransparent(const Gui: TD3Gui): TRGBAlphaImage;
var
  Painter: TGuiPainter;
  P: PVector4Byte;
  I, A: Integer;
begin
  Result := TRGBAlphaImage.Create(GuiImageWidth, GuiImageHeight);
  Result.Clear(Vector4Byte(0, 0, 0, 0));
  if (Gui = nil) or (Gui.Desktop = nil) then
    Exit;
  Painter := TGuiPainter.Create;
  try
    Painter.Image := Result;
    Painter.ScaleX := GuiImageWidth / GuiWidth;
    Painter.ScaleY := GuiImageHeight / GuiHeight;
    Painter.Gui := Gui;
    Painter.Font := Font_DefaultUi;
    Painter.ClipX0 := 0;
    Painter.ClipY0 := 0;
    Painter.ClipX1 := Result.Width;
    Painter.ClipY1 := Result.Height;
    Gui.HasVideo := False;
    Painter.DrawWindow(Gui.Desktop, 0, 0);
    Painter.DrawCursor;
  finally
    Painter.Free;
  end;
  Gui.Dirty := False;
  { the painter blends over black: the colors are premultiplied; added
    light over nothing has no alpha yet (its brightness is) }
  P := Result.PixelPtr(0, 0);
  for I := 0 to Result.Width * Result.Height - 1 do
  begin
    A := Max(P^.W, Max(P^.X, Max(P^.Y, P^.Z)));
    if (A > 0) and (A < 255) then
    begin
      P^.X := Min(255, P^.X * 255 div A);
      P^.Y := Min(255, P^.Y * 255 div A);
      P^.Z := Min(255, P^.Z * 255 div A);
    end;
    P^.W := A;
    Inc(P);
  end;
end;

{ Cache and URL protocol ----------------------------------------------------- }

var
  GuiImages: specialize TObjectDictionary<String, TRGBAlphaImage>;
  GuiKeys: TStringList;
  ProtocolRegistered: Boolean;
  { live surfaces by key (giN) }
  Surfaces: specialize TDictionary<String, TD3GuiSurface>;
  SurfaceCount: Integer;

type
  TGuiProtocol = class
    function Read(const Url: String; out MimeType: String): TStream;
  end;

var
  GuiProtocol: TGuiProtocol;

function TGuiProtocol.Read(const Url: String; out MimeType: String): TStream;
var
  Key: String;
  Img: TRGBAlphaImage;
begin
  Key := ChangeFileExt(ExtractFileName(UriDeleteProtocol(Url)), '');
  if not GuiImages.TryGetValue(Key, Img) then
    raise EFOpenError.Create('No such GUI image: ' + Url);
  Result := TMemoryStream.Create;
  SaveTga(Img, Result);
  Result.Position := 0;
  MimeType := 'image/x-tga';
end;

procedure RegisterGuiProtocol;
begin
  if ProtocolRegistered then
    Exit;
  RegisterUrlProtocol('d3gui', @GuiProtocol.Read, nil);
  ProtocolRegistered := True;
end;

function GuiImageUrl(const GuiPath: String; const State: TStrings): String;
var
  Gui: TD3Gui;
  FullKey: String;
  I: Integer;
begin
  Result := '';
  if GuiPath = '' then
    Exit;
  RegisterGuiProtocol;
  FullKey := NormalizeD3Path(GuiPath);
  if State <> nil then
    for I := 0 to State.Count - 1 do
      if Copy(LowerCase(State.Names[I]), 1, 4) = 'gui_' then
        FullKey := FullKey + '|' + State[I];
  I := GuiKeys.IndexOf(FullKey);
  if I < 0 then
  begin
    Gui := TD3Gui.Create;
    try
      if not Gui.LoadFromVfs(GuiPath) then
      begin
        WritelnWarning('Doom3Gui', 'Cannot load GUI "%s"', [GuiPath]);
        Exit;
      end;
      Gui.StateFromKeys(State);
      { the static picture: the state the windows start in }
      Gui.Activate(0);
      I := GuiKeys.Add(FullKey);
      GuiImages.Add('gui' + IntToStr(I), RenderGui(Gui, nil));
      WritelnLog('Doom3Gui', 'Rendered "%s" (%d windows) as gui%d', [Gui.Name, Gui.WindowCount, I]);
    finally
      Gui.Free;
    end;
  end;
  Result := 'd3gui:/gui' + IntToStr(I) + '.tga';
end;

function GuiSurfPath(const GuiSurf: String; const EntityGui, EntityGui2, EntityGui3: String): String;
begin
  if SameText(GuiSurf, 'entity') then
    Result := EntityGui
  else
  if SameText(GuiSurf, 'entity2') then
    Result := EntityGui2
  else
  if SameText(GuiSurf, 'entity3') then
    Result := EntityGui3
  else
    Result := GuiSurf;
end;

function GuiSurfaceUrl(const GuiSurf: String; const EntityKeys: TStrings): String;
var
  G1, G2, G3: String;
begin
  G1 := '';
  G2 := '';
  G3 := '';
  if EntityKeys <> nil then
  begin
    G1 := EntityKeys.Values['gui'];
    G2 := EntityKeys.Values['gui2'];
    G3 := EntityKeys.Values['gui3'];
  end;
  Result := GuiImageUrl(GuiSurfPath(GuiSurf, G1, G2, G3), EntityKeys);
end;

function GuiSurfaceByUrl(const Url: String): TD3GuiSurface;
var
  S: String;
  I: Integer;
begin
  Result := nil;
  if Copy(Url, 1, 9) <> 'd3gui:/gi' then
    Exit;
  S := ChangeFileExt(Copy(Url, 8, MaxInt), '');
  I := Pos('_v', S);
  if I > 0 then
    S := Copy(S, 1, I - 1);
  Surfaces.TryGetValue(S, Result);
end;

function GuiUrlPath(const Url: String): String;
var
  S: String;
  I: Integer;
  Surface: TD3GuiSurface;
begin
  Result := '';
  Surface := GuiSurfaceByUrl(Url);
  if Surface <> nil then
    Exit(Surface.Gui.Name);
  if Copy(Url, 1, 10) <> 'd3gui:/gui' then
    Exit;
  S := ChangeFileExt(Copy(Url, 11, MaxInt), '');
  I := StrToIntDef(S, -1);
  if (I < 0) or (I >= GuiKeys.Count) then
    Exit;
  { the cache key: path, then |key=value of the state }
  Result := GuiKeys[I];
  if Pos('|', Result) > 0 then
    Result := Copy(Result, 1, Pos('|', Result) - 1);
end;

{ TD3GuiSurface }

constructor TD3GuiSurface.Create(const AGui: TD3Gui);
begin
  inherited Create;
  Gui := AGui;
  Nodes := TX3DNodeList.Create(False);
  Inc(SurfaceCount);
  FKey := 'gi' + IntToStr(SurfaceCount);
  Surfaces.Add(FKey, Self);
  RegisterGuiProtocol;
end;

destructor TD3GuiSurface.Destroy;
begin
  if Surfaces <> nil then
    Surfaces.Remove(FKey);
  if (GuiImages <> nil) and (FVersion > 0) then
    GuiImages.Remove(FKey + '_v' + IntToStr(FVersion));
  FreeAndNil(Nodes);
  FreeAndNil(Gui);
  inherited Destroy;
end;

function TD3GuiSurface.Render(const Force: Boolean): Boolean;
var
  I: Integer;
  Img: TRGBAlphaImage;
begin
  if not (Force or Gui.Dirty) then
    Exit(False);
  if RenderSize > 0 then
    Img := RenderGui(Gui, nil, RenderSize, RenderSize)
  else
    Img := RenderGui(Gui, nil);
  RenderedSize := Img.Width;
  Inc(FVersion);
  GuiImages.Add(FKey + '_v' + IntToStr(FVersion), Img);
  FUrl := 'd3gui:/' + FKey + '_v' + IntToStr(FVersion) + '.tga';
  { the image itself to the textures (a copy each): no TGA written and read
    back through the d3gui: protocol, which still serves the URL (a reload
    after the OpenGL context is lost) }
  for I := 0 to Nodes.Count - 1 do
    if Nodes[I] is TImageTextureNode then
      TImageTextureNode(Nodes[I]).LoadFromImage(Img, False, FUrl);
  if FVersion > 1 then
    GuiImages.Remove(FKey + '_v' + IntToStr(FVersion - 1));
  Inc(Renders);
  Result := True;
end;

procedure ClearGuiCache;
begin
  GuiImages.Clear;
  GuiSources.Clear;
  GuiKeys.Clear;
  Fonts.Clear;
  FontPages.Clear;
  MissingFonts.Clear;
end;

function GuiCacheCount: Integer;
begin
  Result := GuiKeys.Count;
end;

initialization
  GuiImages := specialize TObjectDictionary<String, TRGBAlphaImage>.Create([doOwnsValues]);
  GuiSources := specialize TObjectDictionary<String, TRGBAlphaImage>.Create([doOwnsValues]);
  GuiKeys := TStringList.Create;
  GuiProtocol := TGuiProtocol.Create;
  Surfaces := specialize TDictionary<String, TD3GuiSurface>.Create;
  Fonts := specialize TObjectDictionary<String, TD3Font>.Create([doOwnsValues]);
  FontPages := specialize TObjectList<TRGBAlphaImage>.Create(True);
  MissingFonts := TStringList.Create;
  GuiCvars := TStringList.Create;
  DynamicImages := specialize TObjectDictionary<String, TRGBAlphaImage>.Create([doOwnsValues]);
  WantedDynamic := TStringList.Create;
finalization
  FreeAndNil(DynamicImages);
  FreeAndNil(WantedDynamic);
  FreeAndNil(GuiCvars);
  if ProtocolRegistered then
    UnregisterUrlProtocol('d3gui');
  FreeAndNil(GuiProtocol);
  FreeAndNil(GuiImages);
  FreeAndNil(GuiSources);
  FreeAndNil(GuiKeys);
  FreeAndNil(Surfaces);
  FreeAndNil(Fonts);
  FreeAndNil(FontPages);
  FreeAndNil(MissingFonts);
end.
