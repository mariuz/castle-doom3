{ The game view: a Doom 3 map, the player, HUD and console.
  Its components are designed in data/gameviewplay.castle-user-interface . }
unit GameViewPlay;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils,
  CastleVectors, CastleUIControls, CastleControls, CastleKeysMouse, CastleViewport,
  CastleCameras, CastleTransform, CastleScene, CastleSceneCore, X3DNodes, X3DFields, CastleTimeUtils, CastleGLImages,
  Doom3Level, Doom3World, Doom3Hud, Doom3Console, Doom3Efx, Doom3Particles, Doom3Pda, Doom3Gui, Doom3HudGui, Doom3RenderDoc,
  Doom3GuiGL;

type
  { d3xp's portal sky (idPlayerView::SingleView renders it before the
    view): the map seen from the info_portalsky, drawn under the main
    viewport, which is then transparent and whose portal sky surfaces
    write only the depth (holes). Around its render the map's area
    visibility is the sky camera's. }
  TD3PortalSkyViewport = class(TCastleViewport)
  public
    Map: TDoom3Map;
    MainCamera: TCastleCamera;
    procedure Render; override;
  end;

  TViewPlay = class(TCastleView)
  published
    { Components designed using CGE editor.
      These fields will be automatically initialized at Start. }
    MainViewport: TCastleViewport;
    Camera: TCastleCamera;
    WalkNavigation: TCastleWalkNavigation;
    Map: TDoom3Map;
    Flashlight: TCastlePointLight;
    MuzzleFlash: TCastlePointLight;
    Hud: TDoom3Hud;
    LabelFps: TCastleLabel;
    Console: TDoom3Console;
    FadeRect: TCastleRectangleControl;
  private
    FGame: TD3Game;
    FSky: TCastleBackground;
    FNoclip: Boolean;
    { autotest / demo scripts }
    FDemoCommands: TStringList;
    FDemoIndex: Integer;
    FDemoTimer: Single;
    FDemoHeld: array of TKey;
    FShots: Integer;
    FQuitting: Boolean;
    { environment probes (r_envProbes): one EnvironmentLight per area,
      baked from the map; nil until baked for the current map }
    FEnvProbes: TCastleScene;
    { security monitors (remoteRenderMap): a viewport over the same world
      rendering the cameras GUIs show, a few times a second }
    FRemoteViewport: TCastleViewport;
    FRemoteCamera: TCastleCamera;
    { d3xp's portal sky; FPortalSkyOn: console g_enablePortalSky, env
      CD3_PORTAL_SKY=0 }
    FSkyViewport: TD3PortalSkyViewport;
    FSkyCamera: TCastleCamera;
    FPortalSkyOn, FPortalSkyActive: Boolean;
    FRemoteTime: Single;
    FEnvProbesOn: Boolean;
    { don't prepare the map's rendering resources at load (console
      r_prepareResources 0, env CD3_PREPARE_RESOURCES=0): they are then
      prepared when each area first shows (a stall) }
    FSkipPrepare: Boolean;
    FEnvProbeScale: Single;
    { a cinematic camera has the view: the player's view to go back to }
    FInCinematic: Boolean;
    { the camera before ApplyViewBob }
    FBobApplied, FBobBadLogged: Boolean;
    { seconds walk navigation has been falling (Doom 3's falling speed) }
    FFallTime: Single;
    { double vision (idPlayerView::DoubleVision) as a screen effect }
    FDvEffect: TScreenEffectNode;
    { walk navigation's MoveSpeed of the design (berserk multiplies it) }
    FBaseMoveSpeed: Single;
    { the jump's height (JumpMaxHeight times PreferredHeight, which
      crouching changes) }
    FBaseJump: Single;
    { the console's crouch holds the crouch key }
    FDemoCrouch: Boolean;
    { GO:... crouch holds it while moving }
    FDemoGoCrouch: Boolean;
    { N: past the last monster or at a hidden one: the next S takes no shot }
    FDemoSkipShot: Boolean;
    { the console "route" (Doom 3 feet points) and the demo's R: walk
      along it: the segment, the distance along it, the distance since the
      last screenshot, the map it was made for, the time in a cinematic }
    FRoute: TD3PointArray;
    FRouteSeg: Integer;
    FRouteAlong, FRouteSinceShot, FRouteWalked, FRouteCinematic: Single;
    FRouteMap: String;
    { the point indexes where the route reaches a trigger or an item, and
      their names (logged when the walk gets there) }
    FRouteMarks: array of Integer;
    FRouteMarkNames: TStringArray;
    FRouteNextMark: Integer;
    { where the walk put the eye last frame (a teleport moves it away), and
      the seconds left to stand where a teleport put the player }
    FRouteLastEye: TVector3;
    FRouteHold: Single;
    { The fighting playthrough (console "fight 1", then a route): the walk
      stops to shoot the monsters that come for the player, without god
      mode; the game is saved every FightSaveEvery seconds of quiet, and
      loaded when the player dies (three deaths after one save: god mode
      until the next save). }
    FFight: Boolean;
    FFightKills, FFightDeaths, FFightSaves, FFightDeathsHere, FFightLastKills, FFightGaveUp: Integer;
    FFightSinceSave, FFightOnTarget, FFightSkipUntil, FFightTime: Single;
    { the route's units walked at the furthest death since the save; in
      god mode no save (which ends it) before the walk is past that }
    FFightDeathWalked, FFightGodUntil: Single;
    FFightTarget, FFightIgnore: String;
    { waiting for a chaser out of sight (FightStep): its name, how long, the
      ones waited for long enough }
    FFightWaitFor, FFightWaitIgnore: String;
    FFightWait: Single;
    { hazards (TD3Game.HazardAt): the walk's way to the side of the route
      around them now and where it heads (Doom 3), the last one logged; the
      fight's last hazard stepped out of and projectile dodged }
    FRouteOffset, FRouteOffsetGoal: TVector3;
    FRouteHazardLogged, FFightHazardLogged: String;
    { a hazard the walk goes through (no way around it, or stepping out of
      it fought the walk: caverns1's barrel by the route, the player shook
      in place for 10 s): no stepping out of it until FHazardPassUntil }
    FHazardPassAt: TVector3;
    FHazardPassUntil, FHazardStepTime, FHazardStepAt: Single;
    { the side detour's progress along the route (none for 2 s: through) }
    FDetourWalked, FDetourSince: Single;
    FFightDodged: TObject;
    FFightHasSave, FFightGod: Boolean;
    FFightRoute: TD3PointArray;
    FFightSeg: Integer;
    FFightAlong, FFightWalked: Single;
    { it sidesteps while it shoots: at most FightStrafeReach from where
      the fight began, turning back at walls }
    FFightAnchor: TVector3;
    FFightSide: Single;
    { fight 2: after the route, the hunt walks to every monster alive and
      shown (the nearest first) and kills it (HuntNext) }
    FHunt: Boolean;
    FHuntTarget, FHuntDone, FHuntHidden, FHuntWoken: String;
    { every route of the hunt to a monster (",name," each): the tries count
      over the whole hunt (delta2b: a pack of imps, a new one nearest every
      route, tries reset at each switch, 276 routes in 11 minutes) }
    FHuntTried: String;
    { the fight target's health last frame: hurt, it isn't one that
      doesn't die }
    FFightTargetHealthOf: String;
    FFightTargetHealth: Integer;
    FHuntTries, FHuntRoutes: Integer;
    FHuntTime: Single;
    { the hunt ends when it kills nothing for a while (delta2b: fists only
      against an archvile's imps, it switched between them for an hour) }
    FHuntLastKills: Integer;
    FHuntKillTime: Single;
    FRouteGaps: Single;
    { console "route_walk 1": the route is walked on foot (collisions,
      gravity, doors opened by touch, elevators called) instead of in
      noclip; where it can't go on it is stuck: it tries a door or an
      elevator there, then is put ahead along the route (WalkOnFoot) }
    FRouteWalkMode: Boolean;
    FWalkStuck, FWalkProgressAt: Single;
    { the seconds a put ahead waited for the fight (a monster at the
      player): FightHoldMax at most each spot }
    FWalkFightHold: Single;
    FWalkUsed: Boolean;
    FWalkStuckCount, FWalkDoorsOpened, FWalkElevatorsCalled, FWalkPutStreak, FWalkElevatorTries, FWalkFellCount, FWalkReroutes: Integer;
    { the view's turns during a route (how smooth the bots look) }
    FViewFrames, FViewJerks, FViewReversals: Integer;
    FViewTurnSum, FViewLastTurn: Single;
    FViewLastDir: TVector3;
    FViewBy, FViewShakeBy: String;
    FViewShakeTimes: array [0..7] of Single;
    FViewShakeNext: Integer;
    FViewShakeLogged, FViewClock: Single;
    { the bots keep looking at a monster a moment after it went out of
      sight (at corners the sight came and went every frame: the view
      swung between it and the route) }
    FViewHoldPoint: TVector3;
    FViewHoldUntil: Single;
    { the walk's memory between runs (per map, a text file next to the
      saves): where it had to be put ahead, died and gave up }
    FMemMap: String;
    FMemStuck, FMemGiveUp, FMemDeath: TD3PointArray;
    { a give-up place gives god mode again only once the walk is this far
      on (FRouteWalked): a route that comes back to a pit died there once
      a pass }
    FMemGiveUpArm: array of Single;
    FMemStuckUsed, FMemGiveUpsUsed: Integer;
    FMemCheckAt: Single;
    FLastDeathAt: TVector3;
    FWalkLastFloor: TVector3;
    FWalkRerouted, FWalkCrouch: Boolean;
    FWalkRerouteSpot: TVector3;
    FWalkRerouteTries: Integer;
    { the walk's detours (where and when, FViewClock): three at one spot in
      a few minutes is a loop (delta1: an elevator called to the floor it
      was at, a detour away and back for an hour) }
    FWalkDetours: TD3PointArray;
    FWalkDetourTimes: array of Single;
    FWalkLoops: Integer;
    { where and when (FViewClock) the walk was put ahead: put ahead again
      near one of them soon after, the route led back (alphalabs4: a pit
      the route climbs out of, an hour of put aheads into it) }
    FWalkPuts: TD3PointArray;
    FWalkPutTimes: array of Single;
    FWalkJumpAt: Single;
    FWalkStuckSpots: String;
    FDvShift: TSFFloat;
    FBobSavedPos, FBobSavedDir, FBobSavedUp: TVector3;
    FPlayerEye, FPlayerDir: TVector3;
    FPlayerFov: Single;
    FPlayerFovAxis: TFieldOfViewAxis;
    { the camera's own field of view (target_setfov changes it) }
    FDefaultFov: Single;
    FDefaultFovAxis: TFieldOfViewAxis;
    FFovApplied: Boolean;
    { the PDA screen (Tab): PDAs, emails, objectives }
    FPdaPanel: TCastleRectangleControl;
    FPdaLabel: TCastleLabel;
    FPdaOpen: Boolean;
    { Doom 3's PDA GUI (guis/pda.gui, idPlayer's objectiveSystem) when the
      data has it, drawn full screen; else the text panel }
    FPdaGui: TD3Gui;
    FPdaImage: TCastleImageControl;
    FPdaTimeMs: Single;
    FPdaOpenedOnce, FPdaMouseDown: Boolean;
    { console g_pdaGui (1 by default): guis/pda.gui when the data has it
      (no video or audio playback), else the text panel }
    FUsePdaGui: Boolean;
    { Doom 3's HUD (guis/hud.gui) when the data has it and console
      g_hudGui is 1 (the default); else our own HUD panels }
    FHudGui: TD3HudGui;
    { FHudImage's drawable (FHudImage owns it) }
    FHudDrawable: TDrawableImage;
    FHudImage: TCastleImageControl;
    { the HUD GUI drawn on the GPU (g_hudGpu 1, the default): recorded as
      quads (RecordGuiQuads), no software painting }
    FHudGpu: TD3GuiGLControl;
    FUseHudGpu: Boolean;
    FHudRecords: Integer;
    FHudRecordSeconds: Single;
    FHudUpdates: Integer;
    FHudUpdateSeconds: Single;
    FHudTimeMs: Double;
    FHudRedraw: Single;
    { "sample start <seconds>": the sampler stops by itself (a demo script
      can't, while its R: step walks a route) }
    FSampleLeft: Single;
    FUseHudGui, FHudGuiTried: Boolean;
    { under the menu: no game time, no navigation (the mouse look's state
      to restore) }
    FPaused, FPausedMouseLook: Boolean;
    { target_endlevel's next map, loaded FPendingMapIn seconds later }
    FPendingMap: String;
    FPendingMapIn: Single;
    { target_checkpoint fired: saved ("autosave") at the next frame, like
      Doom 3 BFG's appended "savegame autosave" (console g_checkpoints 0
      turns it off) }
    FPendingAutosave: Boolean;
    FCheckpoints: Boolean;
    { a saved game to restore once its map has spawned }
    FPendingRestore: String;
    { the inventory the level's end takes to the next map (Doom 3's
      persistent info); env CD3_CARRY_INVENTORY=<file> also writes it there
      and starts the first map with it (the tour runs a process a map:
      delta4's two hell knights of 1400 health each against the pistol) }
    FCarryInfo: String;
    FPdaIndex: Integer;
    { after loading a map: the first frames (textures, shaders) are profiled }
    FProfileFrames: Integer;
    { map loads in this run, and the shader programs linked before the
      last one (the memory log line) }
    FMapLoads: Integer;
    FProgramsAtLoad: Cardinal;
    { after those, frames longer than LongFrameSeconds are logged (stalls
      when new areas come into view: textures, shaders) }
    FLastUpdate: TTimerResult;
    FLastUpdateValid: Boolean;
    { the counters at the last Update: what a long frame loaded (file reads,
      image programs, shader programs) }
    FLastReads, FLastImages: Integer;
    FLastReadSeconds, FLastImageSeconds: Double;
    FLastPrograms: Cardinal;
    { seconds of the last Update's parts, for the long frame log line }
    FPartGame, FPartVisibility, FPartHud, FPartDemo, FPartUpdate: Single;
    { console "perf <seconds>": sums of the frames' times and parts }
    FPerfLeft, FPerfFrame, FPerfWorst, FPerfUpdate, FPerfGame, FPerfVisibility, FPerfHud: Double;
    FPerfFrames: Integer;
    FPerfParts: array [0..UpdatePartCount - 1] of Double;
    { GPU time of the frames' 3D view (from Render to RenderOverChildren)
      by GL timer queries, read 4 frames later (console "perf") }
    FGpuQueries: array [0..3] of Cardinal;
    FGpuQueryUsed: array [0..3] of Boolean;
    FGpuQueryIndex: Integer;
    FGpuQueryActive: Boolean;
    { the flashlight's projection image ('-' none, '' not looked for) }
    FFlashlightProfileName: String;
    { the flashlight's designed intensity (global_flashlight_intensity scales it) }
    FFlashlightIntensity: Single;
    { perf: the main thread's CPU time at its start }
    FPerfCpuStart: Double;
    { perf: from the end of Update to the view's rendering (CGE updating
      the viewport's transforms), and the 3D view's rendering on the CPU
      (between Render and RenderOverChildren, without the swap) }
    FPerfPreRender, FPerfRenderCpu: Double;
    FPerfRenderFrames: Integer;
    FPerfRenderStart: TTimerResult;
    FPerfGpu: Double;
    FPerfGpuFrames: Integer;
    FPartGameParts: String;
    { the map's efxs/<map>.efx (nil when missing), the effect in
      SoundEngine.Reverb (nil = reverb off), console s_useEAXReverb }
    FEfx: TD3EfxFile;
    FReverbEffect: TD3ReverbEffect;
    FUseReverb: Boolean;
    procedure PerfFrame(const SecondsPassed: Single);
    procedure LoadReverb;
    procedure UpdateReverb;
    procedure SetReverbEffect(const Effect: TD3ReverbEffect; const Why: String);
    function ReverbStatus: String;
    procedure UpdateCinematic;
    procedure RunSkippedCinematic;
    procedure LoadLevel(const AMapName: String);
    { The camera's fov: g_fov's default for the look (D3DefaultFov). }
    procedure ApplyDefaultFov;
    { route all: FRoute through every touch trigger and item, nearest
      first, ending at Goal (Doom 3 feet); FRouteGaps sums the hops }
    procedure BuildCoverageRoute(const Goal: TVector3; const GoalName: String);
    { R: returns True when the walk is over }
    function WalkRoute(const SecondsPassed: Single; const Speed, ShotEvery: Single): Boolean;
    { route_walk: the feet towards the route's point Goal (Doom 3 feet),
      with collisions; the view along Yaw }
    procedure WalkOnFoot(const Goal: TVector3; const Yaw, MaxStep, SecondsPassed: Single);
    { turns the view towards Dir at a player's pace (the bots: a view set
      to its goal every frame shook as the goals took turns); returns the
      angle still to turn, in degrees }
    function TurnViewTo(const Dir: TVector3; const SecondsPassed: Single;
      const DegreesPerSecond: Single; const Who: String; const DeadBand: Single = 0): Single;
    { the walk's turn: along the route, or at a monster just out of sight }
    procedure TurnRouteView(const Yaw, SecondsPassed: Single; const Who: String);
    { the walk's memory: loaded when the map changes, appended to at once
      (a run that times out keeps what it learned) }
    procedure MemoryEnsure;
    procedure MemoryAdd(const Kind: String; const At: TVector3);
    function MemoryNear(const Points: TD3PointArray; const At: TVector3;
      const Radius: Single; out Index: Integer): Integer;
    { route_walk: no progress along the route for a while: a door or an
      elevator near the feet is used, later it is put ahead }
    procedure WalkStuck(const SecondsPassed: Single; const Fell: Boolean = False);
    procedure WalkSummary;
    function FightSafeToSave: Boolean;
    function FightStep(const SecondsPassed: Single): Boolean;
    { fighting: a hurt volume or a barrel at the eye's feet }
    function FightHazard(const Eye: TVector3; const Margin: Single; out What: String): Boolean;
    { the route's point P (Doom 3 feet) moved aside around hazards }
    function RouteAroundHazards(const P, Dir: TVector3; const Step: Single): TVector3;
    function HazardPassed(const Eye: TVector3): Boolean;
    { the hunt's next monster: FRoute to it; False when none is left }
    function HuntNext: Boolean;
    procedure LogMemory(const Title: String);
    procedure FightSummary;
    { After preparing resources: wait until the driver has compiled the
      shader programs it started (InternalParallelShaderCompile). }
    procedure WaitForShaderPrograms;
    procedure SetupSky;
    procedure PlaceCamera(const FeetPos: TVector3; const YawDeg: Single);
    procedure HandleMessage(const Msg: String);
    procedure HandleFlashlight(const Value: Boolean);
    procedure HandleCheckpoint(const Msg: String);
    procedure HandleEndLevel(const Msg: String);
    function SaveFileName(const AName: String): String;
    procedure SaveGame(const AName: String);
    procedure LoadGame(const AName: String);
    procedure SetPdaOpen(const Value: Boolean);
    procedure UpdatePdaText;
    { idPlayer::UpdatePDAInfo (and TogglePDA's inventory, weapons and
      UpdateObjectiveInfo) into the PDA GUI's state }
    procedure FillPdaGui(const UpdateSel: Boolean);
    procedure UpdatePdaGui(const SecondsPassed: Single);
    procedure UpdateHudGui(const SecondsPassed: Single);
    procedure FreeHudGui;
    procedure HandleConsoleCommand(const Cmd, Args: String);
    { fire the weapon: Once from a demo script, else the button is held }
    procedure Fire(const Once: Boolean);
    { the weapon's muzzle flash light (its def's flashColor, flashRadius,
      flashTime), else the built-in pistol's }
    procedure UpdateMuzzleFlash;
    procedure UpdateFlashlight;
    procedure UpdatePortalSky;
    { the HUD's tunnel vision and blood blobs from the game's damage }
    procedure UpdateDamageView;
    procedure UpdateRemoteViews(const SecondsPassed: Single);
    { walk navigation falls at Doom 3's speed (TD3Game.FallSpeed) }
    procedure UpdateFallSpeed(const SecondsPassed: Single);
    { knockback moves the camera (with collisions) }
    procedure ApplyKnockback(const SecondsPassed: Single);
    procedure CreateDoubleVision;
    procedure SetFlashlight(const Value: Boolean);
    { the F key: Doom 3 BFG's mounted flashlight (TD3Game), or the view's }
    procedure ToggleFlashlight;
    procedure SetNoclip(const Value: Boolean);
    procedure RunDemoStep(const SecondsPassed: Single);
    procedure ReleaseDemoKeys;
    procedure BakeEnvProbes;
    procedure FreeEnvProbes;
    procedure SetEnvProbeScale(const Value: Single);
    procedure UpdateCrouch(const SecondsPassed: Single);
    procedure CaptureScreenshot;
    function CameraYaw: Single;
  public
    MapName: String;
    AutoTestPrefix: String;
    AutoTestDemo: String;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Start; override;
    procedure Stop; override;
    { the menu pushed over the game (Escape) pauses it }
    procedure Pause; override;
    procedure Resume; override;
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
    function Press(const Event: TInputPressRelease): Boolean; override;
    { the view's bob, only while rendering (walk navigation moves the
      camera without it) }
    procedure Render; override;
    procedure RenderOverChildren; override;
  strict private
    procedure ApplyViewBob;
    procedure RemoveViewBob;
  end;

var
  ViewPlay: TViewPlay;
  { --minimized: minimize the window when the view starts }
  StartMinimized: Boolean;

{ A key to a GUI: backspace 8, enter 13, escape 27, else the character
  (only to a focused edit, escape always). }
function GuiKey(const Gui: TD3Gui; const Event: TInputPressRelease): Boolean;

implementation

uses
  Math, TypInfo,
  CastleWindow, CastleLog, CastleImages, CastleUtils, CastleStringUtils, CastleRenderOptions,
  CastleInternalRenderer,
  CastleSoundEngine, CastleInternalOpenAL, CastleInternalEFX, CastleGLUtils, CastleGL,
  CastleRenderContext,
  Doom3Sampler, CastleInternalGLShadowVolumes, CastleGLShaders,
  CastleShapes, CastleBoxes,
  Doom3MapFile, Doom3Files, Doom3Decls, Doom3LightEffects, Doom3Md5, Doom3Images, GameViewMenu,
  Doom3EnvProbes, CastleColors, CastleRectangles, Doom3Roq, CastleFilesUtils, CastleUriUtils;

{$ifdef MSWINDOWS}
function D3GetThreadTimes(Thread: PtrUInt; out CreationTime, ExitTime, KernelTime, UserTime: Int64): LongBool;
  stdcall; external 'kernel32' name 'GetThreadTimes';
function D3GetCurrentThread: PtrUInt; stdcall; external 'kernel32' name 'GetCurrentThread';
{$endif}

{ The main thread's CPU time (user and kernel), seconds; 0 where unknown.
  Unlike frame times it doesn't include waiting for vertical sync. }
function MainThreadCpuSeconds: Double;
{$ifdef MSWINDOWS}
var
  Creation, ExitTime, Kernel, User: Int64;
begin
  if D3GetThreadTimes(D3GetCurrentThread, Creation, ExitTime, Kernel, User) then
    Result := (Kernel + User) / 1e7
  else
    Result := 0;
end;
{$else}
begin
  Result := 0;
end;
{$endif}


type
  { Saves a screenshot in its own thread: without libpng (no DLL next to
    the exe) PNGs are written by FPImage, 0.3 to 0.9 s for a 1600 x 900
    image, which was most of a route's stalls (game/monorail: 77 of 80). }
  TScreenshotSaver = class(TThread)
  public
    Img: TCastleImage;
    Path, Error: String;
    SaveTime: Single;
    procedure Execute; override;
  end;

var
  ScreenshotSaver: TScreenshotSaver;

procedure TScreenshotSaver.Execute;
var
  SaveStart: TTimerResult;
begin
  SaveStart := Timer;
  try
    SaveImage(Img, Path);
  except
    on E: Exception do
      Error := E.ClassName + ': ' + E.Message;
  end;
  FreeAndNil(Img);
  SaveTime := TimerSeconds(Timer, SaveStart);
end;

{ Wait until the screenshot being saved is written (before the next one,
  when the view stops and when the program ends). }
procedure WaitScreenshotSaved;
begin
  if ScreenshotSaver = nil then
    Exit;
  ScreenshotSaver.WaitFor;
  if ScreenshotSaver.Error <> '' then
    WritelnWarning('Screenshot "%s" not saved: %s', [ScreenshotSaver.Path, ScreenshotSaver.Error]);
  FreeAndNil(ScreenshotSaver);
end;

{ idGameLocal::CalcFov: Doom 3's fov (degrees) is the horizontal one of a
  4:3 view; wider screens keep its vertical fov and see more on the sides
  (like dhewm3 and Doom 3 with r_aspectRatio). Radians. }
{ A Doom 3 fov (g_fov, target_setfov, a camera's) as CGE's vertical fov:
  the 2004 game means it across a 4:3 screen, Doom 3 BFG across a 16:9 one
  (idGameLocal::CalcFov), so BFG's default 80 is 50.6 degrees high, the
  2004 game's 90 is 73.7 }
function D3VerticalFov(const FovX: Single): Single;
begin
  if D3BfgLook then
    Result := 2 * ArcTan(Tan(DegToRad(EnsureRange(FovX, 1, 170)) / 2) * 9 / 16)
  else
    Result := 2 * ArcTan(Tan(DegToRad(EnsureRange(FovX, 1, 170)) / 2) * 3 / 4);
end;

{ g_fov's default: 80 in Doom 3 BFG, 90 in the 2004 game }
function D3DefaultFov: Single;
begin
  if D3BfgLook then
    Result := 80
  else
    Result := 90;
end;

procedure TViewPlay.ApplyDefaultFov;
begin
  Camera.Perspective.FieldOfViewAxis := faVertical;
  Camera.Perspective.FieldOfView := D3VerticalFov(D3DefaultFov);
  FDefaultFov := Camera.Perspective.FieldOfView;
  FDefaultFovAxis := Camera.Perspective.FieldOfViewAxis;
  WritelnLog('GameViewPlay', 'Look: %s (lights x%s, g_fov %s, %.1f degrees high)',
    [Iff(D3BfgLook, 'Doom 3 BFG', 'Doom 3 2004'), FloatToStrDot(TDoom3Map.DataLightScale),
     FloatToStrDot(D3DefaultFov), RadToDeg(FDefaultFov)]);
end;

const
  LongFrameSeconds = 0.1;

constructor TViewPlay.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  DesignUrl := 'castle-data:/gameviewplay.castle-user-interface';
  FDemoCommands := TStringList.Create;
  MapName := 'testmap';
  FUseReverb := True;
  FEnvProbeScale := 0.5;
  FUsePdaGui := True;
  FUseHudGui := True;
  FUseHudGpu := GetEnvironmentVariable('CD3_HUD_GPU') <> '0';
end;

destructor TViewPlay.Destroy;
begin
  FDemoCommands.Free;
  FreeAndNil(FEfx);
  inherited Destroy;
end;

procedure MinimizeGameWindow; forward;

procedure TViewPlay.Start;
begin
  inherited Start;
  if StartMinimized then
  begin
    StartMinimized := false;
    MinimizeGameWindow;
  end;
  { env CD3_PRECOMPRESSED=0: plain color images from their TGA, not from
    Doom 3's compressed dds/ copies (console image_usePrecompressedTextures) }
  if GetEnvironmentVariable('CD3_PRECOMPRESSED') = '0' then
    UsePrecompressedImages := False;
  { black where no light reaches, like Doom 3: no global ambient light
    (CGE's default is 0.2: a flat gray of 10 in unlit places; against
    dhewm3's views the median image difference was 3.9 with it, 2.1
    without). Env CD3_GLOBAL_AMBIENT=0.2 (console r_globalAmbient) for
    the gray. }
  RenderContext.GlobalAmbient := TVector3.Zero;
  if GetEnvironmentVariable('CD3_GLOBAL_AMBIENT') <> '' then
    RenderContext.GlobalAmbient := Vector3(1, 1, 1) *
      SysUtils.StrToFloatDef(GetEnvironmentVariable('CD3_GLOBAL_AMBIENT'), 0, DefaultFormatSettings);
  { opaque shapes front to back: the GPU's early depth test skips the
    pixels behind (game/caverns1's start view: 2.5 M pixel shader runs in
    the first pass, 1.8 M sorted; console r_occlusionSort) }
  MainViewport.OcclusionSort := sort3D;
  FPortalSkyOn := GetEnvironmentVariable('CD3_PORTAL_SKY') <> '0';
  FSkyViewport := nil;
  FSkyCamera := nil;
  FPortalSkyActive := False;
  { the shadow light's lit pass adds only its light to the shapes it
    reaches, in its screen rectangle (CGE change AC), like Doom 3's
    interactions: the other way every shape is drawn again with all its
    lights (caverns1: 8 to 11 ms of GPU time for the view, 4.5 to 5 this
    way); env CD3_SHADOW_ADDITIVE=0 or console r_shadowAdditive 0 }
  InternalShadowVolumesAdditive := GetEnvironmentVariable('CD3_SHADOW_ADDITIVE') <> '0';
  FGame := TD3Game.Create(Map);
  FGame.OnMessage := @HandleMessage;
  FGame.OnFlashlight := @HandleFlashlight;
  FFlashlightIntensity := Flashlight.Intensity;
  FGame.OnEndLevel := @HandleEndLevel;
  FGame.OnCheckpoint := @HandleCheckpoint;
  FCheckpoints := True;
  { g_fov's default (90, or 80 with the BFG look) the way Doom 3 means it }
  ApplyDefaultFov;
  { the PDA screen }
  FPdaPanel := TCastleRectangleControl.Create(FreeAtStop);
  FPdaPanel.Color := Vector4(0.02, 0.08, 0.12, 0.94);
  FPdaPanel.Width := 1000;
  FPdaPanel.Height := 680;
  FPdaPanel.Anchor(hpMiddle);
  FPdaPanel.Anchor(vpMiddle);
  FPdaPanel.Exists := False;
  InsertFront(FPdaPanel);
  FPdaLabel := TCastleLabel.Create(FreeAtStop);
  FPdaLabel.Color := Vector4(0.75, 0.9, 1, 1);
  FPdaLabel.MaxWidth := 960;
  FPdaLabel.Anchor(hpLeft, 20);
  FPdaLabel.Anchor(vpTop, -20);
  FPdaPanel.InsertFront(FPdaLabel);
  Console.OnCommand := @HandleConsoleCommand;
  FNoclip := False;
  FShots := 0;
  { Doom 3's view bob (TD3Game.ViewBobOffset / ViewBobAngles) instead of
    CGE's head bobbing }
  WalkNavigation.HeadBobbing := 0;
  { Doom 3 steps up at once and smooths only the view (TD3Game's step up),
    and has no falling camera effect (a landing dips the view instead) }
  WalkNavigation.GrowSpeed := 1000;
  FBaseMoveSpeed := WalkNavigation.MoveSpeed;
  FBaseJump := WalkNavigation.JumpMaxHeight * WalkNavigation.PreferredHeight;
  { crouching is TD3Game's (Doom 3's heights and rate): CGE's own crouch
    (Input_Crouch lowering the camera) does nothing, its key is read }
  WalkNavigation.CrouchHeight := 1;
  CreateDoubleVision;
  WalkNavigation.FallingEffect := False;
  if AutoTestPrefix <> '' then
  begin
    { results must not depend on the desktop mouse }
    WalkNavigation.MouseLook := False;
    FDemoCommands.Clear;
    FDemoCommands.AddStrings(AutoTestDemo.Split([',']));
    FDemoIndex := 0;
    FDemoTimer := 0;
  end;
  LoadLevel(ViewPlay.MapName);
end;

procedure TViewPlay.FreeEnvProbes;
begin
  if FEnvProbes <> nil then
  begin
    MainViewport.Items.Remove(FEnvProbes);
    FreeAndNil(FEnvProbes);
  end;
end;

procedure TViewPlay.BakeEnvProbes;
const
  FaceSize = 32;
  IrradianceSize = 8;
  { the reflection: blurred like a glossy (not mirror) surface reflects }
  SpecularSize = 16;
  SpecularExponent = 32;
var
  BakeViewport: TCastleViewport;
  BakeCamera: TCastleCamera;
  Hidden: TCastleTransformList;
  Root: TX3DRootNode;
  I, Count: Integer;
  Box: TBox3D;
  Faces, Irradiance, Specular: TD3CubeImages;
  SH: TD3SH9;
  SavedPortalCulling: Boolean;
  Child: TCastleTransform;
  StartTime: TTimerResult;
begin
  FreeEnvProbes;
  if not EnvironmentProbesAvailable then
  begin
    Console.Print('r_envProbes: not supported by this CGE (needs EnvironmentLight.influenceSize)');
    WritelnLog('GameViewPlay', 'Environment probes: not supported by this CGE (needs EnvironmentLight.influenceSize, CGE change P)');
    Exit;
  end;
  StartTime := Timer;
  { Bake the map alone: every area visible, its lights on,
    without the weapon, the player's body, creatures and items. }
  SavedPortalCulling := Map.PortalCulling;
  Map.PortalCulling := False;
  Map.UpdateVisibility(nil);
  Hidden := TCastleTransformList.Create(false);
  BakeViewport := TCastleViewport.Create(nil);
  BakeCamera := TCastleCamera.Create(nil);
  Root := TX3DRootNode.Create;
  try
    for I := 0 to MainViewport.Items.Count - 1 do
    begin
      Child := MainViewport.Items[I];
      if (Child <> Map) and Child.Exists then
      begin
        Child.Exists := False;
        Hidden.Add(Child);
      end;
    end;
    BakeViewport.Items := MainViewport.Items;
    MainViewport.Items.Add(BakeCamera);
    BakeViewport.Camera := BakeCamera;
    BakeViewport.BackgroundColor := Black;
    BakeViewport.ShadowVolumes := MainViewport.ShadowVolumes;

    Count := 0;
    for I := 0 to Map.AreaCount - 1 do
    begin
      Box := TBox3D.Empty;
      if Map.AreaScene(I) <> nil then
        Box.Include(Map.AreaScene(I).BoundingBox);
      if Map.AreaNonSolidScene(I) <> nil then
        Box.Include(Map.AreaNonSolidScene(I).BoundingBox);
      if Box.IsEmpty then
        Continue;
      { the probe at the area's center, used by the shapes inside its bounds }
      Faces := CaptureCubeFaces(Container, BakeViewport, Box.Center, FaceSize);
      try
        SH := ProjectSH9(Faces);
        Irradiance := IrradianceFaces(SH, IrradianceSize);
        Specular := BlurredFaces(Faces, SpecularSize, SpecularExponent);
        try
          Root.AddChildren(CreateProbeLight(CubeMapTexture(Irradiance),
            CubeMapTexture(Specular), Box.Center, Box.Size, FEnvProbeScale));
        finally
          FreeCubeImages(Irradiance);
          FreeCubeImages(Specular);
        end;
      finally FreeCubeImages(Faces) end;
      Inc(Count);
    end;
  finally
    MainViewport.Items.Remove(BakeCamera);
    FreeAndNil(BakeCamera);
    FreeAndNil(BakeViewport);
    for I := 0 to Hidden.Count - 1 do
      Hidden[I].Exists := True;
    FreeAndNil(Hidden);
    Map.PortalCulling := SavedPortalCulling;
  end;

  FEnvProbes := TCastleScene.Create(nil);
  FEnvProbes.Name := 'EnvProbes';
  FEnvProbes.Load(Root, True);
  FEnvProbes.CastGlobalLights := True;
  FEnvProbes.Collides := False;
  FEnvProbes.Pickable := False;
  FEnvProbes.Exists := FEnvProbesOn;
  MainViewport.Items.Add(FEnvProbes);
  WritelnLog('GameViewPlay', 'Environment probes: %d areas baked in %.2f s (%d x %d faces)',
    [Count, TimerSeconds(Timer, StartTime), FaceSize, FaceSize]);
end;

procedure TViewPlay.SetEnvProbeScale(const Value: Single);
var
  I: Integer;
  Root: TX3DRootNode;
begin
  FEnvProbeScale := Value;
  if FEnvProbes = nil then
    Exit;
  Root := FEnvProbes.RootNode;
  for I := 0 to Root.FdChildren.Count - 1 do
    if Root.FdChildren[I] is TEnvironmentLightNode then
      TEnvironmentLightNode(Root.FdChildren[I]).Intensity := Value;
end;

procedure TViewPlay.Pause;
begin
  inherited Pause;
  if FPaused or (FGame = nil) then
    Exit;
  FPaused := True;
  FPausedMouseLook := WalkNavigation.MouseLook;
  WalkNavigation.MouseLook := False;
  WalkNavigation.Exists := False;
  { the menu covers it all: don't draw the world under it }
  MainViewport.Exists := False;
  ReleaseDemoKeys;
end;

procedure TViewPlay.Resume;
begin
  inherited Resume;
  if not FPaused then
    Exit;
  FPaused := False;
  MainViewport.Exists := True;
  WalkNavigation.Exists := True;
  WalkNavigation.MouseLook := FPausedMouseLook;
end;

procedure TViewPlay.Stop;
begin
  WaitScreenshotSaved;
  FPaused := False;
  MainViewport.Exists := True;
  WalkNavigation.Exists := True;
  ReleaseDemoKeys;
  FreeEnvProbes;
  SetReverbEffect(nil, 'leaving the game');
  FreeAndNil(FPdaGui);
  { freed with FreeAtStop }
  FPdaImage := nil;
  FreeHudGui;
  FPdaOpen := False;
  FreeAndNil(FGame);
  inherited Stop;
end;

function TViewPlay.CameraYaw: Single;
var
  D: TVector3;
begin
  D := CgeToD3(Camera.Direction);
  Result := RadToDeg(ArcTan2(D.Y, D.X));
end;

procedure TViewPlay.PlaceCamera(const FeetPos: TVector3; const YawDeg: Single);
var
  EyeHeight: Single;
begin
  { crouched, the eye is lower }
  EyeHeight := PlayerEyeHeight;
  if FGame <> nil then
    EyeHeight := FGame.EyeHeight;
  Camera.SetWorldView(FeetPos + Vector3(0, EyeHeight, 0), YawToCgeDir(YawDeg),
    Vector3(0, 1, 0));
  { the move from the old place isn't a fall (at a few frames per second
    the teleport and the start of a fall could be one frame's move) }
  if FGame <> nil then
    FGame.PlayerTeleported(Camera.WorldTranslation);
end;

procedure TViewPlay.UpdateCinematic;
var
  P, D, U: TVector3;
  Fov, Yaw: Single;
  C: TVector4;
begin
  if FGame.CinematicActive then
  begin
    if not FInCinematic then
    begin
      FInCinematic := True;
      FPlayerEye := Camera.Translation;
      FPlayerDir := Camera.Direction;
      FPlayerFov := Camera.Perspective.FieldOfView;
      FPlayerFovAxis := Camera.Perspective.FieldOfViewAxis;
    end;
    FGame.CinematicView(P, D, U, Fov);
    Camera.SetWorldView(P, D, U);
    Camera.Perspective.FieldOfViewAxis := faVertical;
    Camera.Perspective.FieldOfView := D3VerticalFov(Fov);
  end else
  if FInCinematic then
  begin
    FInCinematic := False;
    Camera.SetWorldView(FPlayerEye, FPlayerDir, Vector3(0, 1, 0));
    Camera.Perspective.FieldOfViewAxis := FPlayerFovAxis;
    Camera.Perspective.FieldOfView := FPlayerFov;
  end;
  { info_player_teleport }
  if FGame.TakeTeleport(P, Yaw) then
  begin
    if FInCinematic then
    begin
      FPlayerEye := P + Vector3(0, PlayerEyeHeight, 0);
      FPlayerDir := YawToCgeDir(Yaw);
    end else
      PlaceCamera(P, Yaw);
  end;
  Hud.Exists := not FInCinematic;
  C := FGame.FadeColor;
  { a skipped cinematic runs on behind black }
  if FGame.Skipping then
    C := Vector4(0, 0, 0, 1);
  FadeRect.Exists := C.W > 0.002;
  FadeRect.Color := C;
end;

{ A skipped cinematic (TD3Game.Skipping) runs on in 0.1 s steps (the game
  copes with 3 FPS), without drawing, like Doom 3's skipCinematic; at most
  0.2 s of work a frame keeps the window alive. }
procedure TViewPlay.RunSkippedCinematic;
const
  Step = 0.1;
  Budget = 0.2;
var
  StepsStart: TTimerResult;
  RemoveMe: TRemoveType;
begin
  StepsStart := Timer;
  while FGame.Skipping and (TimerSeconds(Timer, StepsStart) < Budget) do
  begin
    if FInCinematic then
      FGame.Update(Step, FPlayerEye)
    else
      FGame.Update(Step, Camera.Translation);
    RemoveMe := rtNone;
    Map.FastForward := True;
    try
      Map.Update(Step, RemoveMe);
    finally
      Map.FastForward := False;
    end;
    UpdateCinematic;
  end;
  { not a long frame to look at }
  FLastUpdateValid := False;
end;

{ One log line: the process's memory, the Pascal heap, the shader programs
  linked (in all and since the map's load began), the textures on the GPU
  (env CD3_TEXMEM=1 turns CGE's texture memory profiler on). }
procedure TViewPlay.LogMemory(const Title: String);
var
  S: String;
begin
  S := Format('%s: %s, %d shader programs linked (%d by this load)',
    [Title, ProcessMemoryText, InternalProgramsLinked, InternalProgramsLinked - FProgramsAtLoad]);
  { files and images read since the load's profile line: reads during play
    mean something is loaded again and again }
  S := S + Format(', %d file reads (%.2f s) and %d image programs (%.2f s) since the load',
    [ProfileReadCount, ProfileReadSeconds, ProfileImageCount, ProfileImageSeconds]);
  if ProfileImageCacheHits > 0 then
    S := S + Format(' (%d from the cache of slow image programs)', [ProfileImageCacheHits]);
  if TextureMemoryProfiler.Enabled then
    S := S + ', ' + Copy(TextureMemoryProfiler.Summary, 1, Pos(#10, TextureMemoryProfiler.Summary + #10) - 1);
  WritelnLog('Memory', S);
end;

{ Keep (nil: none) and its children keep their decoded images: CGE's image
  cache serves a URL again only while a node holds it. }
procedure FreeTextureData(const T, Keep: TCastleTransform);
var
  I: Integer;
begin
  if T = Keep then
    Exit;
  if T is TCastleSceneCore then
    TCastleSceneCore(T).FreeResources([frTextureDataInNodes]);
  for I := 0 to T.Count - 1 do
    FreeTextureData(T[I], Keep);
end;

procedure TViewPlay.LoadLevel(const AMapName: String);
begin
  WritelnLog('GameViewPlay', 'Loading map "%s"', [AMapName]);
  Inc(FMapLoads);
  FProgramsAtLoad := InternalProgramsLinked;
  ProfileLogReads := False;
  LoadProfileStart;
  if SamplerWanted then
    SamplerStart;
  { keep the current level when the new one doesn't exist }
  if not TDoom3Map.MapExists(AMapName) then
  begin
    WritelnWarning('GameViewPlay', 'No map "%s"', [AMapName]);
    Hud.ShowMessage('No map ' + AMapName, 6);
    Console.Print('No map ' + AMapName + ' (type "maps" for the list)');
    Exit;
  end;
  { the level's end cut the fight's route short: its summary and monster
    review before the map goes }
  if FFight and (FRoute <> nil) and (FPendingRestore = '') and (Map.MapName <> '') and
    not SameText(Map.MapName, AMapName) then
  begin
    WritelnLog('GameViewPlay', 'Fight: the level ends before the route does (%.0f units walked)', [FRouteWalked]);
    FightSummary;
  end;
  FGame.Clear;
  { Doom 3 loads the HUD again with every map: its DEAD window ("BIOSIGNAL
    LOST") and the red border, once health hit 0, stay on until then }
  FreeHudGui;
  if FInCinematic then
  begin
    FInCinematic := False;
    Camera.Perspective.FieldOfViewAxis := FPlayerFovAxis;
    Camera.Perspective.FieldOfView := FPlayerFov;
  end;
  if not Map.LoadMap(AMapName) then
  begin
    Hud.ShowMessage('Cannot load map ' + AMapName, 6);
    Console.Print('Cannot load map ' + AMapName);
    Exit;
  end;
  MapName := AMapName;
  FreeEnvProbes;
  FGame.Health := 100;
  FGame.Armor := 0;
  FGame.Spawn;
  PlaceCamera(Map.SpawnOrigin, Map.SpawnAngle);
  { the first map of a tour's process: the inventory the last one ended
    with }
  if (FMapLoads = 1) and (FCarryInfo = '') and (FPendingRestore = '') and
     (GetEnvironmentVariable('CD3_CARRY_INVENTORY') <> '') and
     FileExists(GetEnvironmentVariable('CD3_CARRY_INVENTORY')) then
    FCarryInfo := FileToString(FilenameToUriSafe(GetEnvironmentVariable('CD3_CARRY_INVENTORY')));
  if (FCarryInfo <> '') and (FPendingRestore = '') then
    FGame.RestorePersistentInfo(FCarryInfo);
  FCarryInfo := '';
  if FPendingRestore <> '' then
  begin
    if not FGame.RestoreState(FPendingRestore) then
      Hud.ShowMessage('Cannot restore the saved game', 6);
    FPendingRestore := '';
  end;
  LoadReverb;
  SetupSky;
  if FEnvProbesOn then
    BakeEnvProbes;
  Hud.ShowMessage(AMapName, 4);
  LoadProfileStep('sky');
  { textures, shaders and buffers of every area now, also the ones hidden by
    portal visibility, instead of a stall when each first comes into view }
  if not FSkipPrepare and (GetEnvironmentVariable('CD3_PREPARE_RESOURCES') <> '0') then
  begin
    { with every light on that starts on, not only the visible areas' ones:
      the shapes' shaders are for the lights reaching them, so prepared
      with the hidden areas' lights off they were compiled again on the
      way (stalls of seconds in every map) }
    if GetEnvironmentVariable('CD3_LIGHTS_IN_HIDDEN_AREAS') <> '' then
      Map.LightsInHiddenAreas := GetEnvironmentVariable('CD3_LIGHTS_IN_HIDDEN_AREAS') <> '0';
    { env CD3_PREPARE_LIGHTS=0: prepare without the map's lights (CGE's
      old way, to compare) }
    InternalPrepareGlobalLights := GetEnvironmentVariable('CD3_PREPARE_LIGHTS') <> '0';
    FGame.PrepareWeaponViews;
    Map.AllLightsOn;
    MainViewport.PrepareResources(Map, [prRenderSelf, prBoundingBox]);
    Map.UpdateVisibility(MainViewport.Camera);
    LoadProfileStep('prepare');
    WaitForShaderPrograms;
    { the decoded images are in the GPU's textures now: the copies in the
      texture nodes go (hundreds of MB in a big map; a texture needed
      again, by a scene made later, is read again) }
    if GetEnvironmentVariable('CD3_FREE_TEXTURE_DATA') <> '0' then
    begin
      FreeTextureData(Map, FGame.PreparedViewsHolder);
      LoadProfileStep('texture data freed');
    end;
  end;
  FProfileFrames := 1;
  FLastUpdateValid := False;
end;

procedure TViewPlay.WaitForShaderPrograms;
const
  { a driver that never says "done" doesn't block the game: the shapes
    are drawn once it does }
  MaxWait = 120;
var
  Compiling, NotReady: Integer;
  WaitStart: TTimerResult;
begin
  Compiling := InternalShaderProgramsCompiling;
  if Compiling = 0 then
    Exit;
  WaitStart := Timer;
  repeat
    NotReady := InternalShaderProgramsCompiling(True);
    if NotReady = 0 then
      Break;
    Sleep(2);
  until TimerSeconds(Timer, WaitStart) > MaxWait;
  WritelnLog('Shaders: %d programs compiled by the driver in parallel, %.2f s waited for them (%d not done)',
    [Compiling, TimerSeconds(Timer, WaitStart), NotReady]);
  LoadProfileStep('shader programs');
end;

procedure TViewPlay.SetupSky;
var
  Urls: TCastleStringArray6;
begin
  if not Map.SkyboxUrls(Urls) then
  begin
    MainViewport.Background := nil;
    Exit;
  end;
  if FSky = nil then
    FSky := TCastleBackground.Create(Self);
  FSky.TexturePositiveX := Urls[0];
  FSky.TextureNegativeX := Urls[1];
  FSky.TexturePositiveY := Urls[2];
  FSky.TextureNegativeY := Urls[3];
  FSky.TexturePositiveZ := Urls[4];
  FSky.TextureNegativeZ := Urls[5];
  MainViewport.Background := FSky;
  WritelnLog('GameViewPlay', 'Sky "%s"', [Map.SkyMaterial]);
end;

procedure TViewPlay.HandleMessage(const Msg: String);
begin
  { Doom 3's HUD lists them as pickups }
  if FHudGui <> nil then
    FHudGui.Pickup(Msg)
  else
    Hud.ShowMessage(Msg);
  Console.Print(Msg);
end;

procedure TViewPlay.HandleFlashlight(const Value: Boolean);
begin
  SetFlashlight(Value);
end;

procedure TViewPlay.HandleCheckpoint(const Msg: String);
begin
  if FCheckpoints then
    FPendingAutosave := True;
end;

{ Saved games: <user config>/saves/<name>.sav ("quick" without a name). }
function TViewPlay.SaveFileName(const AName: String): String;
var
  N: String;
  I: Integer;
begin
  N := LowerCase(Trim(AName));
  if N = '' then
    N := 'quick';
  for I := 1 to Length(N) do
    if not (N[I] in ['a'..'z', '0'..'9', '_', '-']) then
      N[I] := '_';
  Result := InclPathDelim(GetAppConfigDir(False)) + 'saves' + PathDelim + N + '.sav';
end;

procedure TViewPlay.SaveGame(const AName: String);
var
  FileName, SaveText: String;
  Lines: TStringList;
  SaveStream: TFileStream;
begin
  if (FGame = nil) or (MapName = '') then
    Exit;
  if FGame.PlayerDead then
  begin
    Console.Print('Cannot save: the player is dead');
    Exit;
  end;
  FileName := SaveFileName(AName);
  Lines := TStringList.Create;
  try
    Lines.Text := FGame.SaveState(MapName);
    Lines.Add('noclip'#9 + IntToStr(Ord(FNoclip)));
    try
      ForceDirectories(ExtractFileDir(FileName));
      { one write: TStrings.SaveToFile writes line by line, 8000 writes
        (0.15 s) for a save of a retail map }
      SaveText := Lines.Text;
      SaveStream := TFileStream.Create(FileName, fmCreate);
      try
        if SaveText <> '' then
          SaveStream.WriteBuffer(SaveText[1], Length(SaveText));
      finally
        FreeAndNil(SaveStream);
      end;
      WritelnLog('GameViewPlay', 'Game saved: "%s" (%d lines)', [FileName, Lines.Count]);
      Hud.ShowMessage('Game saved', 3);
      Console.Print('Game saved: ' + FileName);
    except
      on E: Exception do
      begin
        WritelnWarning('GameViewPlay', 'Cannot save "%s": %s', [FileName, E.Message]);
        Console.Print('Cannot save: ' + E.Message);
      end;
    end;
  finally
    Lines.Free;
  end;
end;

procedure TViewPlay.LoadGame(const AName: String);
var
  FileName, AMap: String;
  Lines: TStringList;
  HadNoclip: Boolean;
begin
  HadNoclip := False;
  FileName := SaveFileName(AName);
  if not SysUtils.FileExists(FileName) then
  begin
    Console.Print('No saved game ' + FileName);
    WritelnLog('GameViewPlay', 'No saved game "%s"', [FileName]);
    Exit;
  end;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FileName);
    AMap := TD3Game.SavedMapName(Lines.Text);
    if (AMap = '') or not TDoom3Map.MapExists(AMap) then
    begin
      Console.Print('Not a saved game of this data: ' + FileName);
      Exit;
    end;
    WritelnLog('GameViewPlay', 'Loading the saved game "%s" (map "%s")', [FileName, AMap]);
    FPendingRestore := Lines.Text;
    HadNoclip := Lines.IndexOf('noclip'#9'1') >= 0;
  finally
    Lines.Free;
  end;
  LoadLevel(AMap);
  FPendingRestore := '';
  SetNoclip(HadNoclip);
end;

procedure TViewPlay.HandleEndLevel(const Msg: String);
begin
  { idTarget_EndLevel: the next map loads ("map <nextMap>"), after the
    message has shown for a moment }
  Hud.ShowMessage('End of level: next map ' + Msg, 6);
  { fired again while pending (the player standing in a trigger_multiple,
    delta2a's end): keep counting down, or the map never changes }
  if (Msg <> '') and (FPendingMap = '') and D3Fs.FileExists(TDoom3Map.MapBasePath(Msg) + '.map') then
  begin
    FPendingMap := Msg;
    FPendingMapIn := 2;
  end;
end;

procedure TViewPlay.SetPdaOpen(const Value: Boolean);
begin
  FPdaOpen := Value and (FGame <> nil);
  if FPdaOpen and FUsePdaGui and (FPdaGui = nil) and D3Fs.FileExists('guis/pda.gui') then
  begin
    FPdaGui := TD3Gui.Create;
    if not FPdaGui.LoadFromVfs('guis/pda.gui') then
      FreeAndNil(FPdaGui)
    else
    begin
      FPdaImage := TCastleImageControl.Create(FreeAtStop);
      FPdaImage.Stretch := True;
      FPdaImage.ProportionalScaling := psFit;
      FPdaImage.FullSize := True;
      FPdaImage.Exists := False;
      InsertFront(FPdaImage);
    end;
  end;
  if (FPdaGui <> nil) and not FUsePdaGui then
  begin
    FPdaImage.Exists := False;
    FreeAndNil(FPdaGui);
  end;
  if FPdaGui <> nil then
  begin
    FPdaPanel.Exists := False;
    FPdaImage.Exists := FPdaOpen;
    if FPdaOpen then
    begin
      FPdaTimeMs := 0;
      FillPdaGui(False);
      FPdaGui.Activate(0);
      FPdaGui.Dirty := True;
      UpdatePdaGui(0);
    end;
  end else
  begin
    FPdaPanel.Exists := FPdaOpen;
    if FPdaOpen then
      UpdatePdaText;
  end;
  WritelnLog('GameViewPlay', 'PDA screen %s%s', [BoolToStr(FPdaOpen, 'open', 'closed'),
    Iff(FPdaOpen and (FPdaGui <> nil), ' (guis/pda.gui)', '')]);
end;

procedure TViewPlay.FillPdaGui(const UpdateSel: Boolean);
var
  G: TD3Gui;
  I, J, Current, Index, Sel, N: Integer;
  Pda, Cur: TD3PdaDecl;
  Email: TD3EmailDecl;
  Audio: TD3AudioDecl;
  Video: TD3VideoDecl;
  EmailNames: TStringList;
  Sec: String;
  O: TD3Objective;

  procedure SetS(const Key, Value: String);
  begin
    G.SetState(Key, Value);
  end;

begin
  G := FPdaGui;
  { idPlayer::TogglePDA: the inventory and weapons }
  SetS('inv_count', IntToStr(FGame.Carried.Count));
  for I := 0 to 31 do
  begin
    SetS('inv_name_' + IntToStr(I), '');
    SetS('inv_icon_' + IntToStr(I), '');
    SetS('inv_text_' + IntToStr(I), '');
  end;
  for I := 0 to FGame.Carried.Count - 1 do
    SetS('inv_name_' + IntToStr(I), FGame.Carried[I]);
  for I := 0 to 31 do
    SetS('weapon' + IntToStr(I), IntToStr(Ord(FGame.HasWeapon(I))));
  { UpdatePDAInfo: the PDA list (the personal one first, the others newest
    first), the selected PDA's data }
  Current := StrToIntDef(G.StateValue('listPDA_sel_0'), 0);
  if Current < 0 then
    Current := 0;
  if UpdateSel then
  begin
    SetS('listPDAVideo_sel_0', '0');
    SetS('listPDAEmail_sel_0', '0');
    SetS('listPDAAudio_sel_0', '0');
  end;
  N := FGame.Pdas.Count;
  if Current > 0 then
    Current := N - Current;
  for I := 0 to 127 do
    SetS('listPDA_item_' + IntToStr(I), '');
  for I := 0 to 63 do
  begin
    SetS('listPDAVideo_item_' + IntToStr(I), '');
    SetS('listPDAAudio_item_' + IntToStr(I), '');
    SetS('listPDAEmail_item_' + IntToStr(I), '');
    SetS('listPDASecurity_item_' + IntToStr(I), '');
  end;
  Cur := nil;
  for J := 0 to N - 1 do
  begin
    Pda := PdaDecl(FGame.Pdas[J]);
    if Pda = nil then
      Continue;
    Index := N - J;
    if J = 0 then
      Index := 0;
    SetS('listPDA_item_' + IntToStr(Index), D3LangString(Pda.PdaName));
    if J = Current then
      Cur := Pda;
  end;
  if Cur <> nil then
  begin
    Sec := D3LangString(Cur.Security);
    if Sec = '' then
      Sec := D3LangString('#str_00066');
    SetS('PDASecurityClearance', Sec);
    SetS('pda_icon', Cur.Icon);
    SetS('pda_id', Cur.Id);
    SetS('pda_title', D3LangString(Cur.Title));
    if Current = 0 then
    begin
      { the personal PDA: the player's location and name, the videos }
      if UpdateSel or not FPdaOpenedOnce then
      begin
        G.NamedEvent('playerPDAActive');
        SetS('pda_personal', '1');
        FPdaOpenedOnce := True;
      end;
      SetS('pda_location', D3LangString(FGame.LocationAt(Camera.Translation)));
      SetS('pda_name', 'Player');
      for I := 0 to FGame.Videos.Count - 1 do
      begin
        Video := VideoDecl(FGame.Videos[I]);
        if Video <> nil then
          SetS('listPDAVideo_item_' + IntToStr(I), D3LangString(Video.VideoName));
      end;
      Sel := StrToIntDef(G.StateValue('listPDAVideo_sel_0'), 0);
      Video := nil;
      if (Sel >= 0) and (Sel < FGame.Videos.Count) then
        Video := VideoDecl(FGame.Videos[Sel]);
      if Video <> nil then
      begin
        SetS('PDAVideoTitle', D3LangString(Video.VideoName));
        SetS('PDAVideoVid', Video.Video);
        SetS('PDAVideoIcon', Video.Preview);
        SetS('PDAVideoInfo', D3LangString(Video.Info));
      end else
      begin
        SetS('PDAVideoTitle', '');
        SetS('PDAVideoInfo', '');
      end;
    end else
    begin
      { another's PDA: its owner, the audio logs }
      if UpdateSel then
      begin
        G.NamedEvent('playerPDANotActive');
        SetS('pda_personal', '0');
      end;
      SetS('pda_location', D3LangString(Cur.Post));
      SetS('pda_name', D3LangString(Cur.FullName));
      for I := 0 to Cur.Audios.Count - 1 do
      begin
        Audio := AudioDecl(Cur.Audios[I]);
        if Audio <> nil then
          SetS('listPDAAudio_item_' + IntToStr(I), D3LangString(Audio.AudioName));
      end;
      SetS('audioLogCount', IntToStr(Cur.Audios.Count));
      Sel := StrToIntDef(G.StateValue('listPDAAudio_sel_0'), 0);
      Audio := nil;
      if (Sel >= 0) and (Sel < Cur.Audios.Count) then
        Audio := AudioDecl(Cur.Audios[Sel]);
      if Audio <> nil then
      begin
        SetS('PDAAudioTitle', D3LangString(Audio.AudioName));
        SetS('PDAAudioIcon', Audio.Preview);
        SetS('PDAAudioInfo', D3LangString(Audio.Info));
      end;
    end;
    { the emails: the PDA's, the personal one also those given later
      (target_giveemail) }
    EmailNames := TStringList.Create;
    try
      EmailNames.AddStrings(Cur.Emails);
      if Current = 0 then
        for I := 0 to FGame.Emails.Count - 1 do
          if EmailNames.IndexOf(FGame.Emails[I]) < 0 then
            EmailNames.Add(FGame.Emails[I]);
      for I := 0 to EmailNames.Count - 1 do
      begin
        Email := EmailDecl(EmailNames[I]);
        if Email <> nil then
          SetS('listPDAEmail_item_' + IntToStr(I), D3LangString(Email.From) + #9 +
            D3LangString(Email.Subject) + #9 + D3LangString(Email.Date));
      end;
      Sel := StrToIntDef(G.StateValue('listPDAEmail_sel_0'), -1);
      Email := nil;
      if (Sel >= 0) and (Sel < EmailNames.Count) then
        Email := EmailDecl(EmailNames[Sel]);
      if Email <> nil then
      begin
        SetS('PDAEmailTitle', D3LangString(Email.Subject));
        SetS('PDAEmailText', D3LangString(Email.Text));
      end else
      begin
        SetS('PDAEmailTitle', '');
        SetS('PDAEmailText', '');
      end;
    finally
      EmailNames.Free;
    end;
  end;
  if StrToIntDef(G.StateValue('listPDA_sel_0'), -1) = -1 then
    SetS('listPDA_sel_0', '0');
  { UpdateObjectiveInfo }
  for I := 1 to 3 do
    SetS('objective' + IntToStr(I), '');
  for I := 0 to FGame.ObjectiveCount - 1 do
  begin
    O := FGame.Objective(I);
    SetS('objective' + IntToStr(I + 1), '1');
    SetS('objectivetitle' + IntToStr(I + 1), O.Title);
    SetS('objectivetext' + IntToStr(I + 1), O.Text);
    SetS('objectiveshot' + IntToStr(I + 1), O.Screenshot);
  end;
  SetS('missionobjective', FGame.MissionObjective);
  G.Dirty := True;
end;

procedure TViewPlay.UpdatePdaGui(const SecondsPassed: Single);
var
  R: TFloatRectangle;
  P: TVector2;
  Down: Boolean;
  Cmd, Part: String;
  Words: TStringArray;
  Mat: TD3Material;
  Sel: Integer;
begin
  if (FPdaGui = nil) or not FPdaOpen then
    Exit;
  FPdaTimeMs := FPdaTimeMs + SecondsPassed * 1000;
  FPdaGui.Update(Round(FPdaTimeMs));
  { the mouse on the 640 x 480 GUI (CGE's y goes up) }
  R := FPdaImage.RenderRect;
  if (R.Width > 0) and (R.Height > 0) then
  begin
    P := Container.MousePosition;
    FPdaGui.SetCursor(EnsureRange((P.X - R.Left) / R.Width * GuiWidth, 0, GuiWidth),
      EnsureRange((1 - (P.Y - R.Bottom) / R.Height) * GuiHeight, 0, GuiHeight));
  end;
  Down := buttonLeft in Container.MousePressed;
  if Down and not FPdaMouseDown then
    FPdaGui.Click
  else
  if FPdaMouseDown and not Down then
    FPdaGui.ClickRelease;
  FPdaMouseDown := Down;
  { idPlayer::HandleSingleGuiCommand: the PDA's commands }
  Cmd := FPdaGui.TakeCmd;
  if Cmd <> '' then
  begin
    WritelnLog('GameViewPlay', 'PDA GUI: "%s"', [Cmd]);
    for Part in Cmd.Split([';']) do
    begin
      Words := Trim(Part).Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
      if Length(Words) = 0 then
        Continue;
      case LowerCase(Words[0]) of
        'updatepda': FillPdaGui(True);
        'updatepda2': FillPdaGui(False);
        'close':
          begin
            SetPdaOpen(False);
            Exit;
          end;
        'playpdaaudio':
          if FPdaGui.StateValue('PDAAudioTitle') <> '' then
            FGame.PlayPdaAudio(FPdaGui.StateValue('pda_personal') <> '1',
              StrToIntDef(FPdaGui.StateValue('listPDA_sel_0'), 0),
              StrToIntDef(FPdaGui.StateValue('listPDAAudio_sel_0'), 0));
        'playpdavideo':
          begin
            { idPlayer: the selected video starts again with its sound }
            Mat := Decls.Material(FPdaGui.StateValue('PDAVideoVid'));
            if Mat.VideoMap <> '' then
            begin
              RoqResetTime(Mat.VideoMap);
              WritelnLog('GameViewPlay', 'PDA video %s (%s)', [FPdaGui.StateValue('PDAVideoVid'), Mat.VideoMap]);
            end;
            Sel := StrToIntDef(FPdaGui.StateValue('listPDAVideo_sel_0'), 0);
            if (Sel >= 0) and (Sel < FGame.Videos.Count) and (VideoDecl(FGame.Videos[Sel]) <> nil) and
               (VideoDecl(FGame.Videos[Sel]).Audio <> '') then
              FGame.PlayPdaSound(VideoDecl(FGame.Videos[Sel]).Audio);
          end;
        'stoppdaaudio', 'stoppdavideo':
          FGame.StopPdaSound;
      end;
    end;
  end;
  if FPdaGui.HasVideo then
    FPdaGui.Dirty := True;
  if FPdaGui.Dirty then
  begin
    FPdaImage.Image := RenderGui(FPdaGui, nil);
    FPdaImage.OwnsImage := True;
    FPdaGui.Dirty := False;
  end;
end;

procedure TViewPlay.FreeHudGui;
begin
  FreeAndNil(FHudGui);
  if FHudImage <> nil then
    FreeAndNil(FHudImage);
  if FHudGpu <> nil then
    FreeAndNil(FHudGpu);
  FHudDrawable := nil;
  FHudGuiTried := False;
  Hud.GuiHud := False;
end;

procedure TViewPlay.UpdateHudGui(const SecondsPassed: Single);
const
  { software rendered: at most this many redraws a second when the state
    or an event changed something, else (the flickers and scrolls of its
    time expressions) IdleRate }
  RedrawRate = 8;
  IdleRate = 4;
  GpuRedrawRate = 30;
  GpuIdleRate = 15;
  HudGuiMaxPixels = 1000000;
var
  HudParent: TCastleUserInterface;
  HudScale: Single;
  Shown: Boolean;
  RecordStart: TTimerResult;
  HudPath: String;
begin
  if not FUseHudGui then
  begin
    if FHudGui <> nil then
      FreeHudGui;
    Exit;
  end;
  if (FHudGui = nil) and not FHudGuiTried then
  begin
    FHudGuiTried := True;
    { the player def's "hud" (a port key: the test level's
      guis/test_hud.gui), else Doom 3's guis/hud.gui }
    HudPath := 'guis/hud.gui';
    if (FGame.PlayerDef <> nil) and (FGame.PlayerDef.Values['hud'] <> '') then
      HudPath := FGame.PlayerDef.Values['hud'];
    if D3Fs.FileExists(HudPath) then
    begin
      FHudGui := TD3HudGui.Create;
      if not FHudGui.Load(HudPath) then
        FreeAndNil(FHudGui)
      else
      begin
        { under our HUD (the crosshair, screen effects) and the PDA }
        FHudImage := TCastleImageControl.Create(nil);
        FHudImage.Stretch := True;
        FHudImage.FullSize := True;
        FHudImage.Color := Vector4(1, 1, 1, 1);
        { the painter's premultiplied colors as they are (no pass over
          every pixel to divide them by the alpha) }
        FHudDrawable := TDrawableImage.Create(nil, True, True);
        FHudDrawable.BlendingSourceFactor := bsOne;
        FHudDrawable.BlendingDestinationFactor := bdOneMinusSrcAlpha;
        FHudImage.DrawableImage := FHudDrawable;
        FHudImage.OwnsDrawableImage := True;
        FHudImage.AlphaChannel := acBlending;
        HudParent := Hud.Parent;
        if HudParent <> nil then
          HudParent.InsertControl(HudParent.IndexOfControl(Hud), FHudImage)
        else
          InsertFront(FHudImage);
        { the GPU's drawing at the same place }
        FHudGpu := TD3GuiGLControl.Create(nil);
        FHudGpu.Exists := False;
        if HudParent <> nil then
          HudParent.InsertControl(HudParent.IndexOfControl(Hud), FHudGpu)
        else
          InsertFront(FHudGpu);
        FHudRecords := 0;
        FHudRecordSeconds := 0;
        FHudTimeMs := 0;
        FHudRedraw := 0;
      end;
    end;
  end;
  if FHudGui = nil then
    Exit;
  Hud.GuiHud := True;
  FHudTimeMs := FHudTimeMs + SecondsPassed * 1000;
  RecordStart := Timer;
  FHudGui.Update(FGame, Round(FHudTimeMs), D3LangString(FGame.LocationAt(Camera.Translation)));
  FHudUpdateSeconds := FHudUpdateSeconds + TimerSeconds(Timer, RecordStart);
  Inc(FHudUpdates);
  { dead or in a cinematic: no HUD (idPlayer::DrawHUD) }
  Shown := not FGame.PlayerDead and not FInCinematic and not FPdaOpen;
  FHudRedraw := FHudRedraw + SecondsPassed;
  if FUseHudGpu and TD3GuiGLControl.Supported then
  begin
    FHudImage.Exists := False;
    FHudGpu.Exists := Shown;
    { recording is only the windows' values (no pixels, ~1 ms): at a
      change (at most GpuRedrawRate a second), else (time expressions:
      flickers, scrolls) GpuIdleRate a second }
    if Shown and ((FHudGpu.Quads.Count = 0) or (FHudGui.Gui.Dirty and (FHudRedraw >= 1 / GpuRedrawRate)) or
       (FHudRedraw >= 1 / GpuIdleRate) or
       (FHudGpu.Quads.Width <> Container.PixelsWidth) or (FHudGpu.Quads.Height <> Container.PixelsHeight)) then
    begin
      RecordStart := Timer;
      RecordGuiQuads(FHudGui.Gui, Container.PixelsWidth, Container.PixelsHeight, FHudGpu.Quads);
      FHudRecordSeconds := FHudRecordSeconds + TimerSeconds(Timer, RecordStart);
      Inc(FHudRecords);
      if FHudRecords = 50 then
        WritelnLog('GameViewPlay', 'HUD GUI on the GPU: %d records, %.2f ms each, %d quads (%d x %d)',
          [FHudRecords, FHudRecordSeconds / FHudRecords * 1000, FHudGpu.Quads.Count,
           Container.PixelsWidth, Container.PixelsHeight]);
      FHudRedraw := 0;
    end;
    Exit;
  end;
  if FHudGpu <> nil then
    FHudGpu.Exists := False;
  FHudImage.Exists := Shown;
  if FHudImage.Exists and ((FHudDrawable.Image = nil) or (FHudRedraw >= 1 / IdleRate) or
     (FHudGui.Gui.Dirty and (FHudRedraw >= 1 / RedrawRate))) then
  begin
    { near the screen's size, so the text is sharp (512 x 512 stretched
      over the screen blurred it); at most about a million pixels: the
      painter's time grows with them (1600 x 900: 14 ms a redraw, at
      1333 x 750 about 10) }
    HudScale := Min(1, Sqrt(HudGuiMaxPixels / Max(1, Container.PixelsWidth * Container.PixelsHeight)));
    FHudDrawable.Load(FHudGui.Render(Max(64, Round(Container.PixelsWidth * HudScale)),
      Max(48, Round(Container.PixelsHeight * HudScale)), True));
    FHudRedraw := 0;
  end;
end;

procedure TViewPlay.UpdatePdaText;
var
  T: String;
  I: Integer;
  Pda: TD3PdaDecl;
  Email: TD3EmailDecl;
  Audio: TD3AudioDecl;
  Video: TD3VideoDecl;
  PdaName: String;
begin
  T := 'PDA   (Tab closes, [ and ] switch PDAs)' + LineEnding;
  if FGame.MissionObjective <> '' then
    T := T + LineEnding + 'MISSION OBJECTIVE: ' + FGame.MissionObjective + LineEnding;
  if FGame.ObjectiveCount > 0 then
  begin
    T := T + LineEnding + 'OBJECTIVES' + LineEnding;
    for I := 0 to FGame.ObjectiveCount - 1 do
      T := T + Format('  [%s] %s: %s', [BoolToStr(FGame.Objective(I).Complete, 'x', ' '),
        FGame.Objective(I).Title, FGame.Objective(I).Text]) + LineEnding;
  end;
  T := T + LineEnding + 'PDAs' + LineEnding;
  if FGame.Pdas.Count = 0 then
    T := T + '  (none)' + LineEnding;
  FPdaIndex := EnsureRange(FPdaIndex, 0, Max(0, FGame.Pdas.Count - 1));
  for I := 0 to FGame.Pdas.Count - 1 do
  begin
    Pda := PdaDecl(FGame.Pdas[I]);
    if Pda <> nil then
      PdaName := Pda.FullName
    else
      PdaName := FGame.Pdas[I];
    T := T + Format('  %s %s', [BoolToStr(I = FPdaIndex, '>', ' '), PdaName]) + LineEnding;
  end;
  if FGame.Pdas.Count > 0 then
  begin
    Pda := PdaDecl(FGame.Pdas[FPdaIndex]);
    if Pda <> nil then
    begin
      T := T + LineEnding + Format('%s   %s, %s   security: %s   id %s', [Pda.FullName, Pda.Post, Pda.Title,
        Pda.Security, Pda.Id]) + LineEnding;
      T := T + LineEnding + 'EMAILS' + LineEnding;
      for I := 0 to Pda.Emails.Count - 1 do
      begin
        Email := EmailDecl(Pda.Emails[I]);
        if Email = nil then
          Continue;
        T := T + Format('  %s   from %s, %s', [Email.Subject, Email.From, Email.Date]) + LineEnding +
          '    ' + StringReplace(Email.Text, #10, LineEnding + '    ', [rfReplaceAll]) + LineEnding;
      end;
      { the personal PDA also holds the emails given by target_giveemail }
      if FPdaIndex = 0 then
        for I := 0 to FGame.Emails.Count - 1 do
        begin
          Email := EmailDecl(FGame.Emails[I]);
          if (Email = nil) or (Pda.Emails.IndexOf(FGame.Emails[I]) >= 0) then
            Continue;
          T := T + Format('  %s   from %s, %s', [Email.Subject, Email.From, Email.Date]) + LineEnding +
            '    ' + StringReplace(Email.Text, #10, LineEnding + '    ', [rfReplaceAll]) + LineEnding;
        end;
      if Pda.Audios.Count > 0 then
      begin
        T := T + LineEnding + 'AUDIO LOGS' + LineEnding;
        for I := 0 to Pda.Audios.Count - 1 do
        begin
          Audio := AudioDecl(Pda.Audios[I]);
          if Audio <> nil then
            T := T + Format('  %s: %s', [Audio.AudioName, Audio.Info]) + LineEnding;
        end;
      end;
      if (Pda.Videos.Count > 0) or (FGame.Videos.Count > 0) then
      begin
        T := T + LineEnding + 'VIDEOS' + LineEnding;
        for I := 0 to Pda.Videos.Count - 1 do
        begin
          Video := VideoDecl(Pda.Videos[I]);
          if Video <> nil then
            T := T + Format('  %s: %s', [Video.VideoName, Video.Info]) + LineEnding;
        end;
        for I := 0 to FGame.Videos.Count - 1 do
        begin
          Video := VideoDecl(FGame.Videos[I]);
          if (Video <> nil) and (Pda.Videos.IndexOf(FGame.Videos[I]) < 0) then
            T := T + Format('  %s: %s', [Video.VideoName, Video.Info]) + LineEnding;
        end;
      end;
    end;
  end;
  FPdaLabel.Caption := T;
end;

procedure TViewPlay.SetFlashlight(const Value: Boolean);
begin
  Flashlight.Exists := Value;
end;

procedure TViewPlay.ToggleFlashlight;
begin
  if FGame.MountedFlashlight then
    FGame.ToggleMountedFlashlight
  else
    SetFlashlight(not Flashlight.Exists);
end;

procedure TViewPlay.SetNoclip(const Value: Boolean);
begin
  FNoclip := Value;
  WalkNavigation.Gravity := not Value;
  WalkNavigation.CheckCollisions := not Value;
end;

{ The sound engine's information, and whether OpenAL can do reverb: the
  EFX extension (ALC_EXT_EFX), its version and auxiliary sends, and a test
  that an EAX reverb effect and an auxiliary effect slot can be made. }
function SoundInfo: String;
var
  Device: PALCdevice;
  Major, Minor, Sends: TALint;
  Effect, Slot: TALuint;
  Err: TALenum;
  I, Playing: Integer;
begin
  Result := Format('Sound: %s', [SoundEngine.InformationSummary]);
  { the sources in use: when all of MaxAllocatedSources play, a new sound
    takes one of a lower or equal priority }
  Playing := 0;
  for I := 0 to SoundEngine.InternalAllocatedSources.Count - 1 do
    if SoundEngine.InternalAllocatedSources[I].PlayingOrPaused then
      Inc(Playing);
  Result := Result + LineEnding + Format('Sources: %d playing, %d allocated, at most %d', [
    Playing, SoundEngine.InternalAllocatedSources.Count, SoundEngine.MaxAllocatedSources]);
  if not SoundEngine.IsContextOpenSuccess or (alcGetCurrentContext() = nil) then
    Exit(Result + LineEnding + 'No OpenAL context');
  Device := alcGetContextsDevice(alcGetCurrentContext());
  Result := Result + LineEnding + Format('OpenAL device "%s", vendor "%s", renderer "%s", version "%s"', [
    alcGetString(Device, ALC_DEVICE_SPECIFIER), alGetString(AL_VENDOR),
    alGetString(AL_RENDERER), alGetString(AL_VERSION)]);
  if not Load_EFX(Device) then
    Exit(Result + LineEnding + 'EFX (ALC_EXT_EFX): not available');
  alcGetIntegerv(Device, ALC_EFX_MAJOR_VERSION, 1, @Major);
  alcGetIntegerv(Device, ALC_EFX_MINOR_VERSION, 1, @Minor);
  alcGetIntegerv(Device, ALC_MAX_AUXILIARY_SENDS, 1, @Sends);
  Result := Result + LineEnding + Format('EFX (ALC_EXT_EFX): version %d.%d, %d auxiliary sends per source', [
    Major, Minor, Sends]);
  { make an EAX reverb (what Doom 3's .efx files describe), falling back
    to the standard reverb, in an auxiliary effect slot }
  alGetError();
  alGenEffects(1, @Effect);
  alEffecti(Effect, AL_EFFECT_TYPE, AL_EFFECT_EAXREVERB);
  Err := alGetError();
  if Err = AL_NO_ERROR then
    Result := Result + LineEnding + 'EAX reverb effect: OK'
  else
  begin
    alEffecti(Effect, AL_EFFECT_TYPE, AL_EFFECT_REVERB);
    Err := alGetError();
    Result := Result + LineEnding + Format('EAX reverb effect: not supported, standard reverb: %s', [
      Iff(Err = AL_NO_ERROR, 'OK', 'error ' + IntToStr(Err))]);
  end;
  { a second slot: Creative's driver has one, the game's reverb may hold it
    (AL_OUT_OF_MEMORY); delete only a slot made here, or the game's reverb
    slot goes with it }
  Slot := 0;
  alGenAuxiliaryEffectSlots(1, @Slot);
  Err := alGetError();
  if Err = AL_NO_ERROR then
  begin
    alAuxiliaryEffectSloti(Slot, AL_EFFECTSLOT_EFFECT, Effect);
    Err := alGetError();
    alDeleteAuxiliaryEffectSlots(1, @Slot);
    Result := Result + LineEnding + Format('Auxiliary effect slot with the reverb: %s', [
      Iff(Err = AL_NO_ERROR, 'OK', 'error ' + IntToStr(Err))]);
  end else
    Result := Result + LineEnding + Format('Auxiliary effect slot: no other one (error %d; the reverb''s is in use: %s)', [
      Err, Iff(SoundEngine.ReverbSupported, 'yes', 'no')]);
  alDeleteEffects(1, @Effect);
end;

procedure TViewPlay.LoadReverb;
var
  Path: String;
begin
  SetReverbEffect(nil, 'new map');
  if FEfx = nil then
    FEfx := TD3EfxFile.Create;
  Path := EfxPathForMap(MapName);
  if FEfx.LoadFromVfs(Path) then
    WritelnLog('Reverb', 'Found %s: %d effects%s', [Path, FEfx.Effects.Count,
      Iff(SoundEngine.ReverbSupported, '', ' (no reverb with this sound device)')])
  else
  begin
    WritelnLog('Reverb', 'Missing %s', [Path]);
    FreeAndNil(FEfx);
  end;
end;

procedure TViewPlay.SetReverbEffect(const Effect: TD3ReverbEffect; const Why: String);
begin
  if Effect = FReverbEffect then
    Exit;
  FReverbEffect := Effect;
  if Effect <> nil then
  begin
    SoundEngine.Reverb.Assign(Effect.Reverb);
    WritelnLog('Reverb', 'Effect "%s" (%s)', [Effect.Name, Why]);
  end else
  begin
    SoundEngine.Reverb.Enabled := False;
    WritelnLog('Reverb', 'Off (%s)', [Why]);
  end;
end;

{ Like dhewm3: the listener's (camera's) portal area names the effect,
  else its location, else "default"; when none is in the file, the previous
  effect stays. }
procedure TViewPlay.UpdateReverb;
var
  Area: Integer;
  Location: String;
  Effect: TD3ReverbEffect;
begin
  if not FUseReverb then
  begin
    SetReverbEffect(nil, 's_useEAXReverb 0');
    Exit;
  end;
  if (FEfx = nil) or (FGame = nil) then
    Exit;
  Area := Map.AreaAt(Camera.Translation);
  Location := FGame.LocationOfArea(Area);
  Effect := FEfx.Select(Area, Location);
  if Effect <> nil then
    SetReverbEffect(Effect, Format('area %d, location "%s"', [Area, Location]));
end;

function TViewPlay.ReverbStatus: String;
var
  Area: Integer;
  R: TCastleSoundReverb;
begin
  Area := Map.AreaAt(Camera.Translation);
  Result := Format('s_useEAXReverb %s, sound device %s, area %d, location "%s", ', [
    BoolToStr(FUseReverb, '1', '0'),
    Iff(SoundEngine.ReverbSupported, 'supports reverb', 'has no reverb'),
    Area, FGame.LocationOfArea(Area)]);
  if FEfx = nil then
    Result := Result + 'no ' + EfxPathForMap(MapName)
  else
    Result := Result + Format('%d effects in %s', [FEfx.Effects.Count, EfxPathForMap(MapName)]);
  if FReverbEffect = nil then
    Result := Result + ', off'
  else
  begin
    R := FReverbEffect.Reverb;
    Result := Result + Format(', effect "%s": gain %.3f, decay %.2f s, reflections %.3f after %.3f s, late reverb %.3f after %.3f s, density %.2f, diffusion %.2f', [
      FReverbEffect.Name, R.Gain, R.DecayTime, R.ReflectionsGain, R.ReflectionsDelay,
      R.LateReverbGain, R.LateReverbDelay, R.Density, R.Diffusion]);
  end;
end;

procedure TViewPlay.ApplyViewBob;
var
  Angles, Pos, ViewPos: TVector3;
  D: TVector3;
  M: TMatrix3;
begin
  if FBobApplied or (FGame = nil) or FInCinematic then
    Exit;
  FBobSavedPos := Camera.Translation;
  FBobSavedDir := Camera.Direction;
  FBobSavedUp := Camera.Up;
  D := CgeToD3(Camera.Direction);
  Angles := Vector3(D3DirPitch(D), D3DirYaw(D), 0);
  if FGame.PlayerDead then
    { idPlayer::GetViewPos: dead, the view tilts }
    Angles := Vector3(-15, Angles.Y, 40)
  else
    Angles := Angles + FGame.ViewBobAngles;
  Pos := Camera.Translation + FGame.ViewBobOffset;
  { pm_thirdPerson: behind the player (idPlayer::OffsetThirdPersonView) }
  if FGame.ThirdPersonActive then
  begin
    { the plain view angles (no dead tilt) }
    if FGame.PlayerDead then
      Angles := Vector3(D3DirPitch(D), D3DirYaw(D), 0);
    FGame.ThirdPersonView(Pos, Angles, ViewPos);
    Pos := ViewPos;
  end else
  if Angles.IsZero(0.0001) and FGame.ViewBobOffset.IsZero then
    Exit;
  { a bob that isn't finite would make the whole view black (every shape
    culled): left out, logged once }
  if IsNan(Angles.X) or IsNan(Angles.Y) or IsNan(Angles.Z) or IsInfinite(Angles.X) or IsInfinite(Angles.Z) or
     IsNan(Pos.X) or IsNan(Pos.Y) or IsNan(Pos.Z) or IsInfinite(Pos.Y) then
  begin
    if not FBobBadLogged then
      WritelnWarning('GameViewPlay', 'View bob not finite (angles %s, offset %s, eye %s): left out',
        [Angles.ToString, FGame.ViewBobOffset.ToString, Camera.Translation.ToString]);
    FBobBadLogged := True;
    Exit;
  end;
  M := AnglesMatrix(Angles);
  Camera.SetView(Pos,
    D3ToCge(Vector3(M.Data[0, 0], M.Data[0, 1], M.Data[0, 2])),
    D3ToCge(Vector3(M.Data[2, 0], M.Data[2, 1], M.Data[2, 2])));
  FBobApplied := True;
end;

procedure TViewPlay.RemoveViewBob;
begin
  if not FBobApplied then
    Exit;
  FBobApplied := False;
  Camera.SetView(FBobSavedPos, FBobSavedDir, FBobSavedUp);
end;

procedure TViewPlay.Render;
var
  Slot: Integer;
  Nanoseconds: UInt64;
begin
  inherited Render;
  if (FPerfLeft > 0) and FLastUpdateValid then
  begin
    FPerfRenderStart := Timer;
    FPerfPreRender := FPerfPreRender + Max(0, TimerSeconds(FPerfRenderStart, FLastUpdate) - FPartUpdate);
  end;
  { before the children: the viewport renders with the bob }
  ApplyViewBob;
  { console "perf": the GPU time of the view (GL_TIME_ELAPSED, OpenGL 3.3) }
  FGpuQueryActive := False;
  if (FPerfLeft > 0) and Assigned(glGenQueries) and Assigned(glGetQueryObjectui64v) then
  begin
    if FGpuQueries[0] = 0 then
      glGenQueries(Length(FGpuQueries), @FGpuQueries[0]);
    Slot := FGpuQueryIndex mod Length(FGpuQueries);
    if FGpuQueryUsed[Slot] then
    begin
      { 4 frames old: done by now (waits if not) }
      glGetQueryObjectui64v(FGpuQueries[Slot], GL_QUERY_RESULT, @Nanoseconds);
      FPerfGpu := FPerfGpu + Nanoseconds / 1e9;
      Inc(FPerfGpuFrames);
      FGpuQueryUsed[Slot] := False;
    end;
    glBeginQuery(GL_TIME_ELAPSED, FGpuQueries[Slot]);
    FGpuQueryActive := True;
  end;
end;

procedure TViewPlay.RenderOverChildren;
begin
  if (FPerfLeft > 0) and FLastUpdateValid then
  begin
    FPerfRenderCpu := FPerfRenderCpu + TimerSeconds(Timer, FPerfRenderStart);
    Inc(FPerfRenderFrames);
  end;
  if FGpuQueryActive then
  begin
    glEndQuery(GL_TIME_ELAPSED);
    FGpuQueryUsed[FGpuQueryIndex mod Length(FGpuQueries)] := True;
    Inc(FGpuQueryIndex);
    FGpuQueryActive := False;
  end;
  RemoveViewBob;
  inherited RenderOverChildren;
end;

procedure TViewPlay.CreateDoubleVision;
var
  Part: TShaderPartNode;
  Shader: TComposedShaderNode;
begin
  if FDvEffect <> nil then
    Exit;
  { the frame drawn shifted left (opaque), then shifted right at half
    alpha, like idPlayerView::DoubleVision's two stretched pictures }
  Part := TShaderPartNode.Create;
  Part.ShaderType := stFragment;
  Part.Contents :=
    'uniform float shift;' + NL +
    'void main (void)' + NL +
    '{' + NL +
    '  vec2 p = screenf_position();' + NL +
    '  float w = float(screen_width);' + NL +
    '  vec4 a = screenf_get_color(vec2(shift * w + p.x * (1.0 - shift), p.y));' + NL +
    '  vec4 b = screenf_get_color(vec2(p.x * (1.0 - shift), p.y));' + NL +
    '  gl_FragColor = mix(a, b, 0.5);' + NL +
    '}';
  Shader := TComposedShaderNode.Create;
  Shader.SetParts([Part]);
  FDvShift := TSFFloat.Create(Shader, True, 'shift', 0);
  Shader.AddCustomField(FDvShift);
  FDvEffect := TScreenEffectNode.Create;
  FDvEffect.SetShaders([Shader]);
  FDvEffect.Enabled := False;
  MainViewport.AddScreenEffect(FDvEffect);
end;

procedure TViewPlay.ApplyKnockback(const SecondsPassed: Single);
var
  Move, NewPos: TVector3;
begin
  Move := FGame.KnockbackMove(SecondsPassed);
  if Move.IsZero or FNoclip or FInCinematic or FGame.PlayerDead then
    Exit;
  if Map.World.WorldMoveAllowed(Camera.Translation, Camera.Translation + Move, NewPos,
    True, WalkNavigation.Radius, TBox3D.Empty, TBox3D.Empty, False) then
  begin
    { a ceiling or a floor stopped the vertical part }
    if FGame.KnockbackAirborne and (Abs(NewPos.Y - (Camera.Translation.Y + Move.Y)) > 0.01) then
      FGame.KnockbackBlocked;
    Camera.Translation := NewPos;
  end else
  if FGame.KnockbackAirborne then
    FGame.KnockbackBlocked;
end;

procedure TViewPlay.UpdateCrouch(const SecondsPassed: Single);
var
  OldHeight: Single;
begin
  FGame.PlayerCrouchHeld := FDemoCrouch or FDemoGoCrouch or FWalkCrouch or
    (not Console.IsOpen and WalkNavigation.Input_Crouch.IsPressed(Container));
  OldHeight := FGame.EyeHeight;
  FGame.UpdateCrouch(SecondsPassed, Camera.Translation);
  { the eye goes down / up by the change (the feet stay) }
  if (FGame.EyeHeight <> OldHeight) and not FInCinematic then
    Camera.Translation := Camera.Translation + Vector3(0, FGame.EyeHeight - OldHeight, 0);
  if FGame.EyeHeight >= WalkNavigation.Radius then
    WalkNavigation.PreferredHeight := FGame.EyeHeight;
  { crouched: crouch speed, no running, no jumping (idPhysics_Player) }
  if FGame.Crouched then
  begin
    WalkNavigation.MoveSpeed := FBaseMoveSpeed * FGame.CrouchSpeedScale;
    WalkNavigation.RunMultiplier := 1;
    WalkNavigation.JumpMaxHeight := 0;
  end else
  if FGame.InfluenceLevel = 2 then
    WalkNavigation.JumpMaxHeight := 0
  else
    WalkNavigation.JumpMaxHeight := FBaseJump / WalkNavigation.PreferredHeight;
end;

procedure TViewPlay.UpdateFallSpeed(const SecondsPassed: Single);
begin
  { CGE's walk navigation falls at FallSpeedStart times MoveSpeed, growing
    exponentially by FallSpeedIncrease; Doom 3's speed grows linearly
    (gravity 1066). FallSpeedStart is read when a fall starts, so Falling
    is reset every frame to take the speed for the next one. Navigation
    updates before the view: its Falling says whether it fell this frame. }
  if WalkNavigation.Falling then
    FFallTime := FFallTime + SecondsPassed
  else
    FFallTime := 0;
  WalkNavigation.FallSpeedIncrease := 1;
  WalkNavigation.FallSpeedStart := FGame.FallSpeed(FFallTime + SecondsPassed * 0.5) /
    (WalkNavigation.MoveSpeed * WalkNavigation.MoveVerticalSpeed);
  WalkNavigation.Falling := False;
end;

procedure TD3PortalSkyViewport.Render;
begin
  if Map <> nil then
    Map.BeginPortalSkyPass(Camera);
  try
    inherited Render;
  finally
    if Map <> nil then
      Map.EndPortalSkyPass(MainCamera);
  end;
end;

procedure TViewPlay.UpdatePortalSky;
var
  Sky: TD3MapEntity;
  Holder: TCastleUserInterface;
  SkyOn: Boolean;
begin
  Sky := FGame.PortalSky;
  { gameLocal.IsPortalSkyAcive: a portal sky surface in a visible area }
  SkyOn := FPortalSkyOn and (Sky <> nil) and Map.HasPortalSky and Map.PortalSkyInView;
  if SkyOn <> FPortalSkyActive then
  begin
    if SkyOn then
      WritelnLog('GameViewPlay', 'Portal sky on (from %s)', [Sky.Name])
    else
      WritelnLog('GameViewPlay', 'Portal sky off');
  end;
  FPortalSkyActive := SkyOn;
  if SkyOn and (FSkyViewport = nil) and (MainViewport.Parent <> nil) then
  begin
    FSkyViewport := TD3PortalSkyViewport.Create(FreeAtStop);
    FSkyViewport.FullSize := True;
    FSkyViewport.Items := MainViewport.Items;
    FSkyCamera := TCastleCamera.Create(FreeAtStop);
    MainViewport.Items.Add(FSkyCamera);
    FSkyViewport.Camera := FSkyCamera;
    FSkyViewport.BackgroundColor := Black;
    { a far away room: no shadow volumes (the main view's shadow light) }
    FSkyViewport.ShadowVolumes := False;
    FSkyViewport.OcclusionSort := MainViewport.OcclusionSort;
    FSkyViewport.Map := Map;
    FSkyViewport.MainCamera := Camera;
    { drawn first, under the main viewport }
    Holder := MainViewport.Parent;
    Holder.InsertControl(Holder.IndexOfControl(MainViewport), FSkyViewport);
  end;
  if FSkyViewport <> nil then
    FSkyViewport.Exists := SkyOn;
  MainViewport.Transparent := SkyOn;
  if not SkyOn then
    Exit;
  { idPlayerView: the player's view, from the portal sky's origin }
  FSkyCamera.SetView(D3ToCge(Sky.Origin), Camera.Direction, Camera.Up);
  FSkyCamera.Perspective.FieldOfViewAxis := Camera.Perspective.FieldOfViewAxis;
  FSkyCamera.Perspective.FieldOfView := Camera.Perspective.FieldOfView;
  FSkyCamera.ProjectionNear := Camera.ProjectionNear;
  FSkyCamera.ProjectionFar := Camera.ProjectionFar;
end;

procedure TViewPlay.UpdateRemoteViews(const SecondsPassed: Single);
const
  { idRenderWorld renders remote views every frame; 5 a second here }
  Interval = 0.2;
var
  Wanted: TStringArray;
  RV: TD3RemoteView;
  Img: TRGBImage;
  Rgba: TRGBAlphaImage;
  W: String;
  Want: Boolean;
  Cam: TD3MapEntity;
  CamRot: TMatrix3;
  CamFov: Single;
begin
  FRemoteTime := FRemoteTime + SecondsPassed;
  if (FRemoteTime < Interval) or (Map.RemoteViews.Count = 0) then
    Exit;
  FRemoteTime := 0;
  Wanted := TakeWantedDynamicImages;
  if Length(Wanted) = 0 then
    Exit;
  if FRemoteViewport = nil then
  begin
    FRemoteViewport := TCastleViewport.Create(FreeAtStop);
    FRemoteViewport.FullSize := False;
    FRemoteViewport.Items := MainViewport.Items;
    FRemoteCamera := TCastleCamera.Create(FreeAtStop);
    MainViewport.Items.Add(FRemoteCamera);
    FRemoteViewport.Camera := FRemoteCamera;
    FRemoteViewport.BackgroundColor := Black;
  end;
  for RV in Map.RemoteViews do
  begin
    { a GUI switched the monitor's cameraTarget (setkeyval) }
    if (RV.Owner <> nil) and not SameText(RV.Owner.Value('cameratarget'), RV.CameraName) and
       (Map.MapFile.FindByName(RV.Owner.Value('cameratarget')) <> nil) then
    begin
      Map.AimRemoteView(RV, Map.MapFile.FindByName(RV.Owner.Value('cameratarget')));
      WritelnLog('GameViewPlay', 'Remote view %s looks from %s', [RV.Image, RV.CameraName]);
    end;
    Want := False;
    for W in Wanted do
      if SameText(W, ChangeFileExt(RV.Image, '')) then
        Want := True;
    if not Want then
      Continue;
    { a security camera's view follows its sweep }
    Cam := Map.MapFile.FindByName(RV.CameraName);
    if (Cam <> nil) and FGame.SecurityCameraView(Cam, CamRot, CamFov) then
      Map.AimRemoteView(RV, Cam, CamRot, CamFov);
    FRemoteViewport.Width := RV.Width;
    FRemoteViewport.Height := RV.Height;
    { portal visibility from the security camera, the player's again after }
    FRemoteCamera.SetView(RV.Position, RV.Direction, RV.Up);
    Map.UpdateVisibility(FRemoteCamera);
    try
      Img := CaptureView(Container, FRemoteViewport, RV.Position, RV.Direction, RV.Up, RV.FieldOfView,
        RV.Width, RV.Height);
    finally
      Map.UpdateVisibility(MainViewport.Camera);
    end;
    try
      { env CD3_REMOTE_DUMP=<dir>: the captured views as PNGs (debugging) }
      if GetEnvironmentVariable('CD3_REMOTE_DUMP') <> '' then
        SaveImage(Img, InclPathDelim(GetEnvironmentVariable('CD3_REMOTE_DUMP')) + RV.CameraName + '.png');
      Rgba := Img.ToRGBAlphaImage;
      try
        SetGuiDynamicImage(ChangeFileExt(RV.Image, ''), Rgba);
      finally
        Rgba.Free;
      end;
    finally
      Img.Free;
    end;
  end;
end;

procedure TViewPlay.UpdateDamageView;
var
  Blobs: specialize TArray<TD3ScreenBlob>;
  I: Integer;
  Mat, InfluenceMat: TD3Material;
  ImageName: String;
begin
  Hud.DamageAge := FGame.SinceDamage;
  Hud.ArmorPulse := FGame.ArmorPulse;
  Hud.TipTitle := FGame.TipTitle;
  Hud.TipText := FGame.TipText;
  Hud.ObjectiveNotice := FGame.ObjectiveNotice;
  Hud.ObjectiveTitle := FGame.ObjectiveNoticeTitle;
  Hud.ObjectiveText := FGame.ObjectiveNoticeText;
  Hud.RadioChatter := FGame.RadioChatter;
  Hud.RadioTime := Hud.RadioTime + Container.Fps.SecondsPassed;
  { target_setfov (Doom 3's fov: D3VerticalFov) }
  if not FInCinematic then
  begin
    if FGame.ViewFov > 0 then
    begin
      Camera.Perspective.FieldOfViewAxis := faVertical;
      Camera.Perspective.FieldOfView := D3VerticalFov(FGame.ViewFov);
      FFovApplied := True;
    end else
    if FFovApplied then
    begin
      Camera.Perspective.FieldOfViewAxis := FDefaultFovAxis;
      Camera.Perspective.FieldOfView := FDefaultFov;
      FFovApplied := False;
    end;
  end;
  { berserk (idPlayerView: textures/decals/berserk over the screen, fading
    over its last 10 s); the HUD's own red tint without the material }
  if FGame.PowerUpActive(PowerupBerserk) then
    Hud.BerserkAlpha := Min(1, FGame.PowerUpLeft(PowerupBerserk) / 10)
  else
    Hud.BerserkAlpha := 0;
  if Decls.Material('textures/decals/berserk').Defined and
     (Decls.Material('textures/decals/berserk').StageImage <> '') then
    Hud.BerserkImageUrl := ImageProgramUrl(Decls.Material('textures/decals/berserk').StageImage, ikColor)
  else
    Hud.BerserkImageUrl := '';
  Hud.Invisible := FGame.PowerUpActive(PowerupInvisibility);
  Hud.TalkCursor := FGame.TalkFocus <> nil;
  { a demonic influence's vision material: its stage image at the stage's
    alpha, or (a colorProcess program) a red tint }
  Hud.InfluenceAlpha := FGame.InfluenceAlpha;
  Hud.InfluenceImageUrl := '';
  if FGame.InfluenceMaterial <> '' then
  begin
    InfluenceMat := Decls.Material(FGame.InfluenceMaterial);
    if InfluenceMat.StageImage <> '' then
    begin
      Hud.InfluenceImageUrl := ImageProgramUrl(InfluenceMat.StageImage, ikColor);
      Hud.InfluenceAlpha := Hud.InfluenceAlpha * InfluenceMat.StageColor.W;
    end;
  end;
  { Doom 3's armorViewEffect when the game has it, else the HUD's own }
  if Decls.Material('armorViewEffect').Defined and (Decls.Material('armorViewEffect').StageImage <> '') then
    Hud.ArmorImageUrl := ImageProgramUrl(Decls.Material('armorViewEffect').StageImage, ikColor)
  else
    Hud.ArmorImageUrl := '';
  if FDvEffect <> nil then
  begin
    FDvEffect.Enabled := FGame.DoubleVisionShift > 0;
    if FDvEffect.Enabled then
      FDvShift.Send(FGame.DoubleVisionShift);
  end;
  Blobs := FGame.ScreenBlobs;
  SetLength(Hud.Blobs, 0);
  for I := 0 to High(Blobs) do
  begin
    { the blob material's image (its first plain stage, else its diffuse map) }
    Mat := Decls.Material(Blobs[I].Material);
    ImageName := Mat.StageImage;
    if ImageName = '' then
      ImageName := Mat.DiffuseImage;
    if ImageName = '' then
      Continue;
    SetLength(Hud.Blobs, Length(Hud.Blobs) + 1);
    Hud.Blobs[High(Hud.Blobs)].ImageUrl := ImageProgramUrl(ImageName, ikColor);
    Hud.Blobs[High(Hud.Blobs)].X := Blobs[I].X;
    Hud.Blobs[High(Hud.Blobs)].Y := Blobs[I].Y;
    Hud.Blobs[High(Hud.Blobs)].W := Blobs[I].W;
    Hud.Blobs[High(Hud.Blobs)].H := Blobs[I].H;
    Hud.Blobs[High(Hud.Blobs)].Alpha := EnsureRange((Blobs[I].Finish - FGame.Time) /
      Max(0.001, Blobs[I].Finish - Blobs[I].Start), 0, 1);
  end;
end;

procedure TViewPlay.UpdateMuzzleFlash;
var
  P, C: TVector3;
  R: Single;
begin
  if FGame.MuzzleFlash(P, C, R) then
  begin
    MuzzleFlash.Exists := True;
    MuzzleFlash.Translation := MuzzleFlash.Parent.WorldToLocal(P);
    MuzzleFlash.Color := C;
    MuzzleFlash.Radius := R;
    { Doom 3's light color is the light at its center }
    MuzzleFlash.Intensity := 1;
    { a light volume like the map's (once: its custom fields stay), or
      every shape a shot lights links a new shader program }
    if MuzzleFlash.InternalLightNode.Field('d3_light_matrix_') = nil then
      Map.DynamicLightVolume(MuzzleFlash, CgeToD3(P), R, Map.PointLightProfile(''));
    Map.MoveDynamicLightVolume(MuzzleFlash, CgeToD3(P), R);
  end else
  begin
    { the built-in pistol: a short flash in front of the camera }
    MuzzleFlash.Exists := (FGame.SinceFire < 0.07) and
      ((FGame.Weapon = nil) or not FGame.Weapon.Scripted);
    MuzzleFlash.Translation := Vector3(0, 0, -24);
    MuzzleFlash.Color := Vector3(1, 0.8, 0.4);
    MuzzleFlash.Radius := 400;
    MuzzleFlash.Intensity := 2;
    if MuzzleFlash.Exists then
      Map.MoveDynamicLightVolume(MuzzleFlash, CgeToD3(MuzzleFlash.WorldTranslation), 400);
  end;
end;

{ The flashlight is a projected light volume (a pyramid from the light
  along the view, Doom 3's flashlight is a projected light): as a spot
  light, a light kind of its own, every shape it reached linked a new
  shader program, stalls of up to 1.7 s on a first play (erebus5). }
procedure TViewPlay.UpdateFlashlight;
var
  P, Dir, Up, Right, CamPos, CamDir, CamUp: TVector3;
  Range, W: Single;
  M: TMatrix4;
begin
  if not Flashlight.Exists then
    Exit;
  if FGame.MountedFlashlight then
  begin
    { weapon_flashlight_new: flashTarget 1280, flashUp / flashRight 640 }
    Range := 1280;
    W := 640;
  end else
  begin
    Range := 1200;
    W := Range * Tan(0.4);
  end;
  P := CgeToD3(Flashlight.WorldTranslation);
  MainViewport.Camera.GetWorldView(CamPos, CamDir, CamUp);
  Dir := CgeToD3(CamDir).Normalize;
  Up := CgeToD3(CamUp).Normalize;
  Right := TVector3.CrossProduct(Dir, Up);
  M := ProjectedLightMatrix(P, TMatrix3.Identity, Dir * Range, Up * W, Right * W,
    TVector3.Zero, TVector3.Zero, False);
  if Flashlight.InternalLightNode.Field('d3_light_matrix_') = nil then
  begin
    if FFlashlightProfileName = '' then
    begin
      { Doom 3's flashlight image when the data has it }
      if D3Fs.FileExists('lights/flashlight5.tga') then
        FFlashlightProfileName := 'lights/flashlight5'
      else
        FFlashlightProfileName := '-';
    end;
    if FFlashlightProfileName = '-' then
      Map.DynamicLightVolumeMatrix(Flashlight, M, Sqrt(Sqr(Range) + 2 * Sqr(W)),
        LightProfile('', '', True))
    else
      Map.DynamicLightVolumeMatrix(Flashlight, M, Sqrt(Sqr(Range) + 2 * Sqr(W)),
        LightProfile(FFlashlightProfileName, '', True));
  end else
    Map.MoveDynamicLightVolumeMatrix(Flashlight, M, Sqrt(Sqr(Range) + 2 * Sqr(W)));
end;

procedure TViewPlay.Fire(const Once: Boolean);
begin
  { the player's weapon script fires on WEAPON_ATTACK; without one, the
    built-in pistol }
  if (FGame.Weapon <> nil) and FGame.Weapon.Scripted then
  begin
    if Once then
      FGame.AttackOnce;
  end else
    FGame.Fire(Camera.Translation, Camera.Direction);
end;

{ The texture URLs of a shape's appearance (the material's images), for
  console "pick". }
function ShapeTextureUrls(const Shape: TShape): String;

  procedure AddTexture(const T: TX3DNode);
  var
    I: Integer;
  begin
    if T is TImageTextureNode then
    begin
      if TImageTextureNode(T).FdUrl.Count > 0 then
        Result := Result + ' ' + TImageTextureNode(T).FdUrl.Items[0];
    end else
    if T is TMultiTextureNode then
      for I := 0 to TMultiTextureNode(T).FdTexture.Count - 1 do
        AddTexture(TMultiTextureNode(T).FdTexture[I])
    else
    if T <> nil then
      Result := Result + ' (' + T.X3DType + ')';
  end;

var
  App: TAppearanceNode;
begin
  Result := '';
  if (Shape = nil) or (Shape.Node = nil) or (Shape.Node.Appearance = nil) then
    Exit('(none)');
  App := Shape.Node.Appearance;
  AddTexture(App.Texture);
  if App.Material is TMaterialNode then
  begin
    AddTexture(TMaterialNode(App.Material).DiffuseTexture);
    AddTexture(TMaterialNode(App.Material).EmissiveTexture);
    AddTexture(TMaterialNode(App.Material).NormalTexture);
  end else
  if App.Material is TUnlitMaterialNode then
    AddTexture(TUnlitMaterialNode(App.Material).EmissiveTexture);
  if Result = '' then
    Result := '(none)';
end;

procedure TViewPlay.HandleConsoleCommand(const Cmd, Args: String);
var
  Maps: TStringList;
  P: TVector3;
  I, J: Integer;
  L: TD3LightInfo;
  S, ShaderName: String;
  Words: TStringArray;
  E: TD3MapEntity;
  Dist: Single;
  Gui: TD3Gui;
  GuiImage: TCastleImage;
  GuiStart: TTimerResult;
  GuiSum: QWord;
  GuiRuns: Integer;
  Hit: TRayCollision;
  HitDistance: Single;
  HitNormal: TVector3;
  RayOrigin, RayDirection: TVector3;
  Found: Boolean;
  T: TD3Trigger;
  Total: Single;
  Args2: String;
begin
  Args2 := '';
  if Cmd = 'help' then
  begin
    Console.Print('map <name>, maps, noclip, god, notarget, flashlight, kill, health <n>,');
    Console.Print('give [all|weapons|<weapon>|<stat> <amount>], inventory, weapon <slot>, weapnext, weapprev, reload, pm_bob [0|1], hurt <damage def> [amount] [up], pos, setviewpos x y z [yaw], fps, lightscale <f>, decls,');
    Console.Print('r_useportals [0|1], r_lightvolumes [0|1], r_shadows [0|1], r_md5ShadowTris <n>, r_md5ShadowClosed [0|1], r_prelightShadows [0|1], r_shadowLights <n>, r_useScissor [0|1], r_useDepthBounds [0|1],');
    Console.Print('portals, lights, lightsat, ent <name>, pick, guidump <gui file>, guis, objectives, pda [name], scripts, g_stopTime [0|1],');
    Console.Print('stamina [n], pm_stamina <s>, pm_staminarate <r>, pm_staminathreshold <s>, pm_thirdPerson [0|1], pm_thirdPersonRange / Height / Angle <n>, pm_thirdPersonClip [0|1], pm_thirdPersonDeath [0|1], crouch [0|1], ragdoll [0|1], g_showBrass [0|1],');
    Console.Print('skipcinematic, actors, near <entity> [distance], activate <entity>, soundinfo, reverb, s_useEAXReverb [0|1], route [x y z], tour <i> <n>, quit');
  end else
  if (Cmd = 'map') or (Cmd = 'devmap') then
    LoadLevel(Args)
  else
  if Cmd = 'maps' then
  begin
    Maps := ListMaps;
    try
      Console.Print(Maps.CommaText);
    finally
      Maps.Free;
    end;
  end else
  if Cmd = 'noclip' then
  begin
    SetNoclip(not FNoclip);
    Console.Print('noclip ' + BoolToStr(FNoclip, 'ON', 'OFF'));
  end else
  if Cmd = 'god' then
  begin
    FGame.God := not FGame.God;
    Console.Print('godmode ' + BoolToStr(FGame.God, 'ON', 'OFF'));
  end else
  if Cmd = 'g_checkpoints' then
  begin
    if Args <> '' then
      FCheckpoints := Trim(Args) <> '0';
    Console.Print('g_checkpoints ' + IntToStr(Ord(FCheckpoints)));
  end else
  if Cmd = 'notarget' then
  begin
    FGame.NoTarget := not FGame.NoTarget;
    Console.Print('notarget ' + BoolToStr(FGame.NoTarget, 'ON', 'OFF'));
  end else
  if Cmd = 'flashlight' then
    ToggleFlashlight
  else
  if Cmd = 'kill' then
    FGame.DamagePlayer(1000)
  else
  if Cmd = 'health' then
    FGame.Health := StrToIntDef(Args, 100)
  else
  if Cmd = 'give' then
  begin
    { like Doom 3: give all, give <stat> [amount] }
    Words := Trim(Args).Split([' '], TStringSplitOptions.ExcludeEmpty);
    if (Length(Words) = 0) or SameText(Words[0], 'all') then
      FGame.GiveAll
    else
    if SameText(Words[0], 'weapons') then
    begin
      for I := 0 to High(FGame.WeaponDefs) do
        if FGame.WeaponDefs[I] <> '' then
          FGame.Give('weapon', FGame.WeaponDefs[I]);
    end else
    if SameText(Words[0], 'weapon') or (Length(Words) = 1) and (FGame.WeaponSlot(Words[0]) >= 0) then
      FGame.Give('weapon', Words[High(Words)])
    else
    if Length(Words) >= 2 then
      FGame.Give(Words[0], Words[1])
    else
      FGame.Give(Words[0], '1000');
    Console.Print(FGame.InventoryStatus);
  end else
  if Cmd = 'weapon' then
  begin
    if Args <> '' then
      FGame.SelectWeapon(StrToIntDef(Args, -1));
    Console.Print(Format('weapon slot %d: %s', [FGame.IdealSlot, FGame.WeaponHudText]));
  end else
  if Cmd = 'hurt' then
  begin
    { hurt <damage def> [amount] [up]: a hit from the front (from below
      with "up"), with the def's effects (kick, blobs, double vision,
      knockback) }
    Words := Trim(Args).Split([' '], TStringSplitOptions.ExcludeEmpty);
    if Length(Words) = 0 then
      Console.Print('hurt <damage def> [amount] [up]')
    else
    begin
      I := 10;
      if Decls.EntityDef(Words[0]) <> nil then
        I := StrToIntDef(Decls.EntityDef(Words[0]).Values['damage'], 10);
      if Length(Words) > 1 then
        I := StrToIntDef(Words[1], I);
      if (Length(Words) > 2) and SameText(Words[2], 'up') then
        FGame.DamagePlayer(I, Words[0], Vector3(0, 1, 0))
      else
        FGame.DamagePlayer(I, Words[0], -Camera.Direction);
    end;
  end else
  if Cmd = 'hurtmonster' then
  begin
    { hurtmonster <name> [damage def] [amount]: hit a monster from the
      camera's direction (its pain, death, gibs) }
    Words := Trim(Args).Split([' '], TStringSplitOptions.ExcludeEmpty);
    if Length(Words) = 0 then
      Console.Print('hurtmonster <name> [damage def] [amount]')
    else
    begin
      S := '';
      if Length(Words) > 1 then
        S := Words[1];
      I := FGame.DamageInfo(S).Damage;
      if Length(Words) > 2 then
        I := StrToIntDef(Words[2], I);
      for J := 0 to FGame.Monsters.Count - 1 do
        if SameText(FGame.Monsters[J].Model.Entity.Name, Words[0]) then
        begin
          FGame.DamageMonster(FGame.Monsters[J], I, S, FGame.Monsters[J].Center - Camera.Translation);
          Console.Print(Format('%s: health %d', [Words[0], FGame.Monsters[J].Health]));
        end;
    end;
  end else
  if Cmd = 'stamina' then
  begin
    if Args <> '' then
      FGame.Stamina := StrToFloatDef(Args, FGame.Stamina);
    S := Format('Stamina %.1f of %.0f (%d%%), running %.2f, speed x%.2f', [FGame.Stamina,
      FGame.StaminaMax, FGame.StaminaPercent, FGame.RunFraction, FGame.RunMultiplier], DefaultFormatSettings);
    Console.Print(S);
    WritelnLog('Console', S);
  end else
  if Cmd = 'pm_stamina' then
  begin
    if Args <> '' then
      FGame.StaminaMax := StrToFloatDef(Args, FGame.StaminaMax);
    Console.Print(Format('pm_stamina %g (seconds of running, 0: no stamina)', [FGame.StaminaMax], DefaultFormatSettings));
  end else
  if Cmd = 'pm_staminarate' then
  begin
    if Args <> '' then
      FGame.StaminaRate := StrToFloatDef(Args, FGame.StaminaRate);
    Console.Print(Format('pm_staminarate %g', [FGame.StaminaRate], DefaultFormatSettings));
  end else
  if Cmd = 'pm_staminathreshold' then
  begin
    if Args <> '' then
      FGame.StaminaThreshold := StrToFloatDef(Args, FGame.StaminaThreshold);
    Console.Print(Format('pm_staminathreshold %g', [FGame.StaminaThreshold], DefaultFormatSettings));
  end else
  if Cmd = 'pm_thirdperson' then
  begin
    if Args <> '' then
      FGame.ThirdPerson := Args <> '0';
    S := Format('pm_thirdPerson %s (player model %s, skin "%s")', [BoolToStr(FGame.ThirdPerson, '1', '0'),
      BoolToStr(FGame.PlayerModel <> nil, 'yes', 'none'), FGame.PlayerSkinName]);
    Console.Print(S);
    WritelnLog('Console', S);
  end else
  if Cmd = 'g_showbrass' then
  begin
    if Args <> '' then
      FGame.ShowBrass := Args <> '0';
    Console.Print('g_showBrass ' + BoolToStr(FGame.ShowBrass, '1', '0'));
  end else
  if Cmd = 'ragdoll' then
  begin
    { ragdoll [0|1]: the dead body falls as a ragdoll (with the player
      def's "ragdoll"), or plays its death anim }
    if Args <> '' then
      FGame.RagdollEnabled := Args <> '0';
    Console.Print('ragdoll ' + BoolToStr(FGame.RagdollEnabled, '1', '0'));
  end else
  if Cmd = 'pm_thirdpersondeath' then
  begin
    if Args <> '' then
      FGame.ThirdPersonDeath := Args <> '0';
    Console.Print('pm_thirdPersonDeath ' + BoolToStr(FGame.ThirdPersonDeath, '1', '0'));
  end else
  if Cmd = 'crouch' then
  begin
    { crouch [0|1]: hold the crouch key (without an argument: the state) }
    if Args <> '' then
      FDemoCrouch := Args <> '0';
    S := Format('crouch %s (crouched %s, eye height %.1f)', [BoolToStr(FDemoCrouch, '1', '0'),
      BoolToStr(FGame.Crouched, 'yes', 'no'), FGame.EyeHeight]);
    Console.Print(S);
    WritelnLog('Console', S);
  end else
  if Cmd = 'pm_thirdpersonrange' then
  begin
    if Args <> '' then
      FGame.ThirdPersonRange := StrToFloatDef(Args, FGame.ThirdPersonRange);
    Console.Print(Format('pm_thirdPersonRange %g', [FGame.ThirdPersonRange], DefaultFormatSettings));
  end else
  if Cmd = 'pm_thirdpersonheight' then
  begin
    if Args <> '' then
      FGame.ThirdPersonHeight := StrToFloatDef(Args, FGame.ThirdPersonHeight);
    Console.Print(Format('pm_thirdPersonHeight %g', [FGame.ThirdPersonHeight], DefaultFormatSettings));
  end else
  if Cmd = 'pm_thirdpersonangle' then
  begin
    if Args <> '' then
      FGame.ThirdPersonAngle := StrToFloatDef(Args, FGame.ThirdPersonAngle);
    Console.Print(Format('pm_thirdPersonAngle %g', [FGame.ThirdPersonAngle], DefaultFormatSettings));
  end else
  if Cmd = 'pm_thirdpersonclip' then
  begin
    if Args <> '' then
      FGame.ThirdPersonClip := Args <> '0';
    Console.Print('pm_thirdPersonClip ' + BoolToStr(FGame.ThirdPersonClip, '1', '0'));
  end else
  if Cmd = 'pm_bob' then
  begin
    if Args <> '' then
      FGame.ViewBobEnabled := Args <> '0';
    Console.Print('pm_bob ' + BoolToStr(FGame.ViewBobEnabled, '1', '0') + ' (the view bobs)');
  end else
  if Cmd = 'weapnext' then
    FGame.NextWeapon(1)
  else
  if Cmd = 'weapprev' then
    FGame.NextWeapon(-1)
  else
  if Cmd = 'reload' then
    FGame.ReloadWeapon
  else
  if Cmd = 'inventory' then
  begin
    S := FGame.InventoryStatus;
    Console.Print(S);
    WritelnLog('Inventory', LineEnding + S);
  end else
  if Cmd = 'fight' then
  begin
    FFight := StrToIntDef(Trim(Args), Ord(not FFight)) <> 0;
    FHunt := StrToIntDef(Trim(Args), 0) = 2;
    FHuntTarget := '';
    FHuntDone := '';
    FHuntHidden := '';
    FHuntWoken := '';
    FHuntTried := '';
    FHuntTries := 0;
    FHuntRoutes := 0;
    FHuntTime := 0;
    FHuntLastKills := -1;
    FHuntKillTime := 0;
    FFightKills := 0;
    FFightDeaths := 0;
    FFightSaves := 0;
    FFightGaveUp := 0;
    FFightDeathsHere := 0;
    FFightLastKills := FGame.Kills;
    FFightHasSave := False;
    FFightGod := False;
    FFightDeathWalked := 0;
    FFightGodUntil := 0;
    FFightIgnore := '';
    FFightTarget := '';
    FFightTime := 0;
    FMemCheckAt := 0;
    { the first save at once }
    FFightSinceSave := 1000;
    { the weapons by the start (a map started alone has only the player's
      first ones: cpuboss's bot fought Sabaoth with its fists) }
    if FFight then
    begin
      I := FGame.PickUpStartKit(CgeToD3(Camera.Translation) - Vector3(0, 0, FGame.EyeHeight), 1200);
      if I > 0 then
        WritelnLog('GameViewPlay', 'Fight: %d weapons by the start picked up', [I]);
    end;
    Console.Print('fight ' + BoolToStr(FFight, 'ON', 'OFF'));
    if FHunt then
      WritelnLog('GameViewPlay', 'Fight: %s, then the hunt for every monster left', [BoolToStr(FFight, 'on', 'off')])
    else
      WritelnLog('GameViewPlay', 'Fight: %s', [BoolToStr(FFight, 'on', 'off')]);
  end else
  if Cmd = 'route_walk' then
  begin
    FRouteWalkMode := StrToIntDef(Trim(Args), Ord(not FRouteWalkMode)) <> 0;
    if FRouteWalkMode and FNoclip then
      SetNoclip(False);
    FWalkStuck := 0;
    FWalkProgressAt := 0;
    FWalkUsed := False;
    FWalkElevatorTries := 0;
    FWalkStuckCount := 0;
    FWalkFellCount := 0;
    FWalkReroutes := 0;
    FViewFrames := 0;
    FViewJerks := 0;
    FViewReversals := 0;
    FViewTurnSum := 0;
    FViewLastTurn := 0;
    FViewLastDir := TVector3.Zero;
    FWalkDoorsOpened := 0;
    FWalkElevatorsCalled := 0;
    FWalkStuckSpots := '';
    FWalkDetours := nil;
    FWalkDetourTimes := nil;
    FWalkLoops := 0;
    FWalkPuts := nil;
    FWalkPutTimes := nil;
    WritelnLog('GameViewPlay', 'Route walk on foot: %s', [BoolToStr(FRouteWalkMode, 'on', 'off')]);
    Console.Print('route_walk ' + BoolToStr(FRouteWalkMode, 'ON', 'OFF'));
  end else
  if Cmd = 'monsters' then
  begin
    FGame.MonsterReport;
    Console.Print('monsters: see the log');
  end else
  if Cmd = 'call' then
    FGame.RunScriptFunction(Trim(Args))
  else
  if Cmd = 'savegame' then
    SaveGame(Trim(Args))
  else
  if Cmd = 'loadgame' then
    LoadGame(Trim(Args))
  else
  if Cmd = 'pos' then
  begin
    P := CgeToD3(Camera.Translation - Vector3(0, FGame.EyeHeight, 0));
    Console.Print(Format('origin %.0f %.0f %.0f  yaw %.0f  area %d',
      [P.X, P.Y, P.Z, CameraYaw, Map.AreaAt(Camera.Translation)]));
  end else
  if Cmd = 'route' then
  begin
    { route [all | x y z]: the AAS route from the player's feet to the
      level's end (target_endlevel's trigger) or to a point, for the demo's
      R: walk; "all" goes through every touch trigger and item on the way
      (the nearest next) }
    FRouteMarks := nil;
    FRouteMarkNames := nil;
    FRouteNextMark := 0;
    if SameText(Args, 'all') then
    begin
      Found := FGame.EndLevelGoal(P, S);
      if not Found then
      begin
        { no end: finish where it started }
        P := CgeToD3(Camera.Translation) - Vector3(0, 0, FGame.EyeHeight);
        S := 'the start';
      end;
      BuildCoverageRoute(P, S);
      Found := True;
      Args2 := 'all';
    end else
    if Args <> '' then
    begin
      P := ParseVector3(Args, TVector3.Zero);
      S := 'point';
      Found := True;
    end else
      Found := FGame.EndLevelGoal(P, S);
    if not Found then
    begin
      FRoute := nil;
      WritelnLog('GameViewPlay', 'Route: no target_endlevel in this map');
      Console.Print('Route: no target_endlevel in this map');
    end else
    begin
      if Args2 = 'all' then
      begin
        Dist := FRouteGaps;
        I := Length(FRouteMarks);
      end else
        FGame.PlayerRoute(CgeToD3(Camera.Translation) - Vector3(0, 0, FGame.EyeHeight), P,
          FRoute, Dist, I);
      FRouteSeg := 0;
      FRouteAlong := 0;
      FRouteSinceShot := 0;
      FRouteWalked := 0;
      FRouteCinematic := 0;
      FRouteHold := 0;
      FRouteLastEye := Camera.Translation;
      FRouteMap := MapName;
      Total := 0;
      for J := 1 to High(FRoute) do
        Total := Total + PointsDistance(FRoute[J - 1], FRoute[J]);
      WritelnLog('GameViewPlay', 'Route to %s at %s: %d points over %d areas (spots), %.0f units, gaps %.0f',
        [S, P.ToString, Length(FRoute), I, Total, Dist]);
      Console.Print(Format('Route to %s: %.0f units, gap %.0f', [S, Total, Dist]));
    end;
  end else
  if Cmd = 'tour' then
  begin
    { tour <i> <n>: the i-th of n spots spread over the map (the player
      start, then the items, which lie on floors in playable places), the
      eye there and the view along the entity's angle (tools/tour_maps.ps1) }
    Words := Args.Split([' '], TStringSplitOptions.ExcludeEmpty);
    I := 0;
    J := 1;
    if Length(Words) > 0 then
      I := StrToIntDef(Words[0], 0);
    if Length(Words) > 1 then
      J := Max(1, StrToIntDef(Words[1], 1));
    Maps := TStringList.Create;
    try
      for E in Map.MapFile.Entities do
        if SameText(E.ClassName_, 'info_player_start') then
          Maps.AddObject(E.Name, E);
      for E in Map.MapFile.Entities do
      begin
        S := LowerCase(E.ClassName_);
        if (Copy(S, 1, 5) = 'item_') or (Copy(S, 1, 7) = 'weapon_') or (Copy(S, 1, 5) = 'ammo_') or
           (Copy(S, 1, 14) = 'moveable_item_') then
          Maps.AddObject(E.Name, E);
      end;
      if Maps.Count = 0 then
        for E in Map.MapFile.Entities do
          if SameText(E.ClassName_, 'light') then
            Maps.AddObject(E.Name, E);
      if Maps.Count > 0 then
      begin
        E := TD3MapEntity(Maps.Objects[Min(Maps.Count - 1, Round(EnsureRange(I, 0, J - 1) * (Maps.Count - 1) / Max(1, J - 1)))]);
        { standing where the item lies (PlaceCamera adds the eye height) }
        P := E.Origin + Vector3(0, 0, 1);
        PlaceCamera(D3ToCge(P), E.Angle);
        P := CgeToD3(Camera.Translation);
        WritelnLog('GameViewPlay', 'Tour %d/%d: %s (%s) at %s, area %d', [I, J, E.Name, E.ClassName_,
          P.ToString, Map.AreaAt(D3ToCge(P))]);
        Console.Print(Format('Tour %d/%d: %s (%s)', [I, J, E.Name, E.ClassName_]));
      end else
        Console.Print('Tour: no spots in this map');
    finally
      Maps.Free;
    end;
  end else
  if Cmd = 'setviewpos' then
  begin
    P := ParseVector3(Args, CgeToD3(Camera.Translation));
    PlaceCamera(D3ToCge(P), StrToFloatDef(Copy(Args, LastDelimiter(' ', Args) + 1, MaxInt), CameraYaw));
  end else
  if Cmd = 'r_useportals' then
  begin
    if Args <> '' then
      Map.PortalCulling := StrToIntDef(Args, 1) <> 0
    else
      Map.PortalCulling := not Map.PortalCulling;
    Console.Print('r_usePortals ' + BoolToStr(Map.PortalCulling, '1', '0'));
  end else
  if Cmd = 'r_shadows' then
  begin
    if Args <> '' then
      Map.Shadows := StrToIntDef(Args, 1) <> 0
    else
      Map.Shadows := not Map.Shadows;
    MainViewport.ShadowVolumes := Map.Shadows;
    Console.Print('r_shadows ' + BoolToStr(Map.Shadows, '1', '0'));
  end else
  if Cmd = 'r_envprobes' then
  begin
    { environment probes: baked image-based light per area (CGE change P);
      only with physical materials it is the full effect, the classic
      Phong look gets the diffuse and specular light too: off by default }
    if Args <> '' then
      FEnvProbesOn := StrToIntDef(Args, 1) <> 0
    else
      FEnvProbesOn := not FEnvProbesOn;
    if FEnvProbesOn and (FEnvProbes = nil) then
      BakeEnvProbes;
    if FEnvProbes <> nil then
      FEnvProbes.Exists := FEnvProbesOn;
    Console.Print('r_envProbes ' + BoolToStr(FEnvProbesOn, '1', '0') +
      BoolToStr(FEnvProbesOn and (FEnvProbes = nil), ' (not baked)', ''));
  end else
  if Cmd = 'r_envprobebake' then
  begin
    { bake again (e.g. after lights changed) }
    BakeEnvProbes;
    Console.Print('r_envProbeBake: ' + BoolToStr(FEnvProbes <> nil, 'baked', 'not baked'));
  end else
  if Cmd = 'r_envprobescale' then
  begin
    if Args <> '' then
      SetEnvProbeScale(StrToFloatDefDot(Args, 1));
    Console.Print('r_envProbeScale ' + FloatToStrDot(FEnvProbeScale));
  end else
  if Cmd = 'r_shadowmaps' then
  begin
    { the shadow lights cast shadow maps instead of shadow volumes:
      point lights with 6 views in CGE's shadow map atlas (CGE changes B, R) }
    if not TDoom3Map.ShadowMapsAvailable then
    begin
      Console.Print('r_shadowMaps: not supported by this CGE');
      WritelnLog('GameViewPlay', 'Shadow maps: not supported by this CGE (needs point light shadow maps, CGE changes B and R)');
    end else
    begin
      if Args <> '' then
        Map.ShadowMaps := StrToIntDef(Args, 1) <> 0
      else
        Map.ShadowMaps := not Map.ShadowMaps;
      Console.Print('r_shadowMaps ' + BoolToStr(Map.ShadowMaps, '1', '0'));
      WritelnLog('GameViewPlay', 'Shadow maps %s', [BoolToStr(Map.ShadowMaps, 'on', 'off')]);
    end;
  end else
  if Cmd = 'r_skipparticles' then
  begin
    if Args <> '' then
      SkipParticles := StrToIntDef(Args, 1) <> 0
    else
      SkipParticles := not SkipParticles;
    Console.Print('r_skipParticles ' + BoolToStr(SkipParticles, '1', '0'));
  end else
  if Cmd = 'objectives' then
  begin
    { the mission objective, the objectives given, PDAs, emails }
    S := Format('Objectives: %d (mission: "%s"), PDAs: %s, emails: %s, videos: %s', [FGame.ObjectiveCount,
      FGame.MissionObjective, FGame.Pdas.CommaText, FGame.Emails.CommaText, FGame.Videos.CommaText]);
    Console.Print(S);
    WritelnLog('Objectives', S);
    for I := 0 to FGame.ObjectiveCount - 1 do
    begin
      S := Format('  [%s] %s: %s', [BoolToStr(FGame.Objective(I).Complete, 'x', ' '), FGame.Objective(I).Title,
        FGame.Objective(I).Text]);
      Console.Print(S);
      WritelnLog('Objectives', S);
    end;
  end else
  if Cmd = 'pda' then
  begin
    { pda [name]: toggle the PDA screen (or show a PDA by its decl name) }
    if Args <> '' then
    begin
      I := FGame.Pdas.IndexOf(LowerCase(Trim(Args)));
      if I >= 0 then
        FPdaIndex := I
      else
        Console.Print('pda: not carried: ' + Args);
      SetPdaOpen(True);
    end else
      SetPdaOpen(not FPdaOpen);
  end else
  if Cmd = 'guis' then
  begin
    { every live GUI: its file, entity, windows, redraws, interactivity,
      the cursor and transitions }
    for I := 0 to Map.GuiSurfaces.Count - 1 do
    begin
      S := Format('%s (%s): %d windows, %d redraws (the last %d px, %.1f ms; on screen ~%.0f px, radius %.0f)%s%s%s', [
        Map.GuiSurfaces[I].Gui.Name, Map.GuiSurfaces[I].EntityName, Map.GuiSurfaces[I].Gui.WindowCount,
        Map.GuiSurfaces[I].Renders, Map.GuiSurfaces[I].RenderedSize, Map.GuiSurfaces[I].RenderSeconds * 1000,
        Map.GuiSurfaces[I].ScreenPixels, Map.GuiSurfaces[I].BoxRadius, BoolToStr(Map.GuiSurfaces[I].Gui.Interactive, ', interactive', ''),
        BoolToStr(Map.GuiSurfaces[I].Gui.CursorShown, Format(', cursor %d %d', [Round(Map.GuiSurfaces[I].Gui.CursorX),
          Round(Map.GuiSurfaces[I].Gui.CursorY)]), ''),
        BoolToStr(Map.GuiSurfaces[I].Gui.TransitionCount > 0, Format(', %d transitions', [Map.GuiSurfaces[I].Gui.TransitionCount]), '')]);
      { asleep: its scene out of sight (portal visibility) }
      if (Map.GuiSurfaces[I].Scene <> nil) and not (Map.GuiSurfaces[I].Scene.Visible and Map.GuiSurfaces[I].Scene.Exists) then
        S := S + Format(', asleep (%s visible %s, exists %s)', [Map.GuiSurfaces[I].Scene.Name,
          BoolToStr(Map.GuiSurfaces[I].Scene.Visible, True), BoolToStr(Map.GuiSurfaces[I].Scene.Exists, True)]);
      Console.Print(S);
      WritelnLog('Guis', S);
    end;
    S := Format('GUIs: %d live, %d redraws, %d clicks', [Map.GuiSurfaces.Count, Map.GuiRenders, FGame.GuiClicks]);
    if FGame.GuiFocus <> nil then
      S := S + ', focus ' + FGame.GuiFocus.Gui.Name;
    Console.Print(S);
    WritelnLog('Guis', S);
  end else
  if Cmd = 'particles' then
  begin
    { every particle system: who, the decl, stages and live particles }
    for I := 0 to FGame.Emitters.Count - 1 do
    begin
      S := Format('%s: %s (%d stages, %d particles)%s%s', [
        FGame.Emitters[I].Name, FGame.Emitters[I].Decl.Name, FGame.Emitters[I].Decl.Stages.Count,
        FGame.Emitters[I].Live, BoolToStr(FGame.Emitters[I].Enabled, '', ' off'),
        BoolToStr(FGame.Emitters[I].Stopped, ' stopped', '')]);
      Console.Print(S);
      WritelnLog('Particles', S);
    end;
    for I := 0 to FGame.Fx.Count - 1 do
    begin
      S := Format('fx %s: %d actions, %.1f s', [FGame.Fx[I].Decl.Name,
        Length(FGame.Fx[I].Actions), FGame.Time - FGame.Fx[I].Start]);
      Console.Print(S);
      WritelnLog('Particles', S);
    end;
    Console.Print(Format('%d particle systems, %d fx', [FGame.Emitters.Count, FGame.Fx.Count]));
  end else
  if Cmd = 'elevator' then
  begin
    { elevator: list them; elevator <name> <floor>: its GUI's "changefloor" }
    Words := Args.Split([' '], TStringSplitOptions.ExcludeEmpty);
    if (Length(Words) > 1) and (FGame.FindEntity(Words[0]) <> nil) and
       (FGame.ElevatorOf(FGame.FindEntity(Words[0])) <> nil) then
      FGame.ElevatorChangeFloor(FGame.ElevatorOf(FGame.FindEntity(Words[0])), StrToIntDef(Words[1], 0))
    else
      for I := 0 to FGame.Elevators.Count - 1 do
        Console.Print(Format('Elevator %s: floor %d, state %d', [FGame.Elevators[I].Entity.Name,
          FGame.Elevators[I].CurrentFloor, Ord(FGame.Elevators[I].State)]));
  end else
  if Cmd = 'pdaclick' then
  begin
    { pdaclick <x> <y>: a click on the PDA GUI at 640 x 480 coordinates
      (demo scripts have no mouse) }
    Words := Args.Split([' '], TStringSplitOptions.ExcludeEmpty);
    if (FPdaGui <> nil) and FPdaOpen and (Length(Words) >= 2) then
    begin
      FPdaGui.SetCursor(StrToFloatDef(Words[0], 0), StrToFloatDef(Words[1], 0));
      WritelnLog('GameViewPlay', 'PDA click at %s %s: cursor shown %s, %s', [Words[0], Words[1],
        BoolToStr(FPdaGui.CursorShown, True), BoolToStr(FPdaGui.Click, 'an onAction ran', 'nothing ran')]);
      FPdaGui.ClickRelease;
      FPdaMouseDown := buttonLeft in Container.MousePressed;
      Console.Print(Format('pdaclick %s %s', [Words[0], Words[1]]));
    end;
  end else
  if Cmd = 'burn' then
  begin
    { burn <actor>: its burn-away (idAI::Event_Burn) }
    for I := 0 to FGame.Actors.Count - 1 do
      if SameText(FGame.Actors[I].Model.Entity.Name, Args) then
        FGame.ActorBurn(FGame.Actors[I]);
  end else
  if Cmd = 's_occlusion' then
  begin
    { sounds quieter by their path through the portals (closed doors) }
    if Args <> '' then
      SoundOcclusion := StrToIntDef(Args, 1) <> 0;
    Console.Print('s_occlusion ' + Iff(SoundOcclusion, '1', '0'));
  end else
  if Cmd = 'menu' then
  begin
    { the in-game menu (Escape); "menu x y" clicks it at GUI coordinates,
      "menu esc" sends it Escape }
    Words := Args.Split([' '], TStringSplitOptions.ExcludeEmpty);
    if Length(Words) = 0 then
    begin
      if not FPaused then
      begin
        ViewMenu.InGame := True;
        Container.PushView(ViewMenu);
      end;
    end else
    if SameText(Words[0], 'esc') then
      ViewMenu.GuiEscape
    else
    if Length(Words) >= 2 then
      ViewMenu.GuiClick(StrToFloatDef(Words[0], 0), StrToFloatDef(Words[1], 0));
    Console.Print(Format('Menu: %s%s', [Iff(FPaused, 'open', 'closed'),
      Iff(ViewMenu.GuiShown, ' (guis/mainmenu.gui)', '')]));
  end else
  if Cmd = 'g_menugui' then
  begin
    { Doom 3's main menu GUI instead of our map list }
    if Args <> '' then
      UseMenuGui := StrToIntDef(Args, 0) <> 0;
    Console.Print('g_menuGui ' + Iff(UseMenuGui, '1', '0') + ' (guis/mainmenu.gui when the data has it, else our map list)');
  end else
  if Cmd = 'g_hudgpu' then
  begin
    { the HUD GUI drawn on the GPU (1) or by the software painter (0);
      "bench": 200 records in a row, timed }
    if SameText(Trim(Args), 'bench') then
    begin
      if (FHudGui <> nil) and (FHudGpu <> nil) then
      begin
        GuiStart := Timer;
        for I := 1 to 200 do
          RecordGuiQuads(FHudGui.Gui, Container.PixelsWidth, Container.PixelsHeight, FHudGpu.Quads);
        WritelnLog('GameViewPlay', 'HUD GUI record bench: %.3f ms a record (%d quads)',
          [TimerSeconds(Timer, GuiStart) / 200 * 1000, FHudGpu.Quads.Count]);
        GuiStart := Timer;
        for I := 1 to 20 do
          RenderGuiTransparent(FHudGui.Gui, Container.PixelsWidth, Container.PixelsHeight, True).Free;
        WritelnLog('GameViewPlay', 'HUD GUI software bench: %.3f ms a render (%d x %d)',
          [TimerSeconds(Timer, GuiStart) / 20 * 1000, Container.PixelsWidth, Container.PixelsHeight]);
      end;
    end else
    if Args <> '' then
      FUseHudGpu := StrToIntDef(Args, 0) <> 0;
    if FHudRecords > 0 then
    begin
      Console.Print(Format('g_hudGpu %s (%d records, %.2f ms each)',
        [Iff(FUseHudGpu, '1', '0'), FHudRecords, FHudRecordSeconds / FHudRecords * 1000]));
      WritelnLog('GameViewPlay', 'HUD GUI on the GPU: %d records, %.2f ms each, %d quads; the GUI''s update %.2f ms a frame',
        [FHudRecords, FHudRecordSeconds / FHudRecords * 1000, FHudGpu.Quads.Count,
         FHudUpdateSeconds / Max(1, FHudUpdates) * 1000]);
    end else
      Console.Print('g_hudGpu ' + Iff(FUseHudGpu, '1', '0'));
    WritelnLog('GameViewPlay', 'HUD GUI drawn %s', [Iff(FUseHudGpu, 'on the GPU', 'by the software painter')]);
  end else
  if Cmd = 'g_hudgui' then
  begin
    { Doom 3's HUD GUI instead of our panels }
    if Args <> '' then
      FUseHudGui := StrToIntDef(Args, 0) <> 0;
    if FHudGui <> nil then
      Console.Print(Format('g_hudGui %s (guis/hud.gui shown: %d renders, %.1f ms each, %d events)',
        [Iff(FUseHudGui, '1', '0'), FHudGui.Renders, FHudGui.RenderMs, FHudGui.Events.Count]))
    else
      Console.Print('g_hudGui ' + Iff(FUseHudGui, '1', '0') + ' (guis/hud.gui when the data has it, else our HUD)');
  end else
  if Cmd = 'g_pdagui' then
  begin
    { Doom 3's PDA GUI instead of the text panel (partial) }
    if Args <> '' then
      FUsePdaGui := StrToIntDef(Args, 0) <> 0;
    Console.Print('g_pdaGui ' + Iff(FUsePdaGui, '1', '0') + ' (guis/pda.gui when the data has it, else the text panel)');
  end else
  if Cmd = 'image_useprecompressedtextures' then
  begin
    { plain color images from Doom 3's compressed dds/ copies }
    if Args <> '' then
      UsePrecompressedImages := StrToIntDef(Args, 1) <> 0;
    Console.Print('image_usePrecompressedTextures ' + Iff(UsePrecompressedImages, '1', '0') + ' (used by the next map loaded)');
  end else
  if Cmd = 'r_prepareresources' then
  begin
    { prepare every area's rendering resources at load (the next map) }
    if Args <> '' then
      FSkipPrepare := StrToIntDef(Args, 1) = 0;
    Console.Print('r_prepareResources ' + Iff(FSkipPrepare, '0', '1') + ' (used by the next map loaded)');
  end else
  if Cmd = 'r_shadowmapsize' then
  begin
    { size of each shadow map view, for the next map loaded }
    if Args <> '' then
      Map.ShadowMapSize := Max(16, StrToIntDef(Args, 512));
    Console.Print('r_shadowMapSize ' + IntToStr(Map.ShadowMapSize) + ' (used by the next map loaded)');
  end else
  if Cmd = 'renderdoc' then
  begin
    { a RenderDoc capture of the next frame (the game started by RenderDoc,
      with --capabilities=force-modern) }
    if RenderDocTriggerCapture then
    begin
      WritelnLog('GameViewPlay', 'RenderDoc: capturing the next frame (%d captures so far)', [RenderDocCaptureCount]);
      Console.Print('RenderDoc: capturing the next frame');
    end else
    begin
      WritelnLog('GameViewPlay', 'RenderDoc: not loaded (start the game with renderdoccmd capture)');
      Console.Print('RenderDoc: not loaded (start the game with renderdoccmd capture)');
    end;
  end else
  if Cmd = 'r_lightareas' then
  begin
    { lights light only the scenes of the areas they touch (Doom 3's light
      references; CGE's InternalGlobalLightsMask, doom3-port) }
    if Args <> '' then
      Map.MaskLights := StrToIntDef(Args, 1) <> 0
    else
      Map.MaskLights := not Map.MaskLights;
    Console.Print('r_lightAreas ' + Iff(Map.MaskLights, '1', '0'));
  end else
  if Cmd = 'r_lightsinhiddenareas' then
  begin
    if Args <> '' then
      Map.LightsInHiddenAreas := StrToIntDef(Args, 1) <> 0;
    Console.Print('r_lightsInHiddenAreas ' + Iff(Map.LightsInHiddenAreas, '1', '0'));
  end else
  if Cmd = 'r_filterlights' then
  begin
    { only the lights that are on are given to CGE's renderer (it walks
      every global light per shape and pass) }
    if Args <> '' then
      Map.KeepAllLights := StrToIntDef(Args, 1) = 0;
    Console.Print('r_filterLights ' + Iff(Map.KeepAllLights, '0', '1') +
      Format(' (%d global lights given to the renderer)', [Map.LightScene.InternalGlobalLights.Count]));
  end else
  if Cmd = 'r_shadowlights' then
  begin
    { how many lights cast shadow volumes at once (CGE change A) }
    if Args <> '' then
      Map.ShadowLightsMax := Max(1, StrToIntDef(Args, 1));
    MainViewport.ShadowVolumesMaxLights := Map.ShadowLightsMax;
    Console.Print('r_shadowLights ' + IntToStr(Map.ShadowLightsMax) +
      ' (depth bounds test: ' + Iff(GLFeatures.DepthBoundsTest, 'supported', 'not supported by this OpenGL') + ')');
  end else
  if Cmd = 'r_usedepthbounds' then
  begin
    { limit each shadow light's passes to the depth range of its sphere,
      like Doom 3's r_useDepthBounds (CGE change S) }
    if Args <> '' then
      InternalShadowVolumesLightDepthBounds := StrToIntDef(Args, 1) <> 0
    else
      InternalShadowVolumesLightDepthBounds := not InternalShadowVolumesLightDepthBounds;
    Console.Print('r_useDepthBounds ' + BoolToStr(InternalShadowVolumesLightDepthBounds, '1', '0') +
      Iff(GLFeatures.DepthBoundsTest, '', ' (GL_EXT_depth_bounds_test not supported by this OpenGL: no effect)'));
    WritelnLog('GameViewPlay', 'Depth bounds per shadow light %s (GL_EXT_depth_bounds_test %s)',
      [Iff(InternalShadowVolumesLightDepthBounds, 'on', 'off'),
       Iff(GLFeatures.DepthBoundsTest, 'supported', 'not supported')]);
  end else
  if Cmd = 'r_shadowzerolights' then
  begin
    { the shadowed pass keeps the shadow lights in the shaders with zero
      color (CGE change T, doom3-port): it shares the lit pass's shader
      programs, and a new shadow light makes no new ones; 0 leaves them out }
    if Args <> '' then
      InternalShadowVolumesZeroLights := StrToIntDef(Args, 1) <> 0
    else
      InternalShadowVolumesZeroLights := not InternalShadowVolumesZeroLights;
    Console.Print('r_shadowZeroLights ' + BoolToStr(InternalShadowVolumesZeroLights, '1', '0'));
  end else
  if Cmd = 'r_shadowadditive' then
  begin
    { one shadow light like several: its lit pass adds only its own light,
      in its screen rectangle, to the shapes it reaches (1), or draws every
      shape again with all its lights (0) (CGE change AC) }
    if Args <> '' then
      InternalShadowVolumesAdditive := StrToIntDef(Args, 1) <> 0
    else
      InternalShadowVolumesAdditive := not InternalShadowVolumesAdditive;
    Console.Print('r_shadowAdditive ' + BoolToStr(InternalShadowVolumesAdditive, '1', '0'));
  end else
  if Cmd = 'r_usescissor' then
  begin
    { limit each shadow light's passes to its screen rectangle, like
      Doom 3's r_useScissor (CGE change A follow-up) }
    if Args <> '' then
      InternalShadowVolumesLightScissor := StrToIntDef(Args, 1) <> 0
    else
      InternalShadowVolumesLightScissor := not InternalShadowVolumesLightScissor;
    Console.Print('r_useScissor ' + BoolToStr(InternalShadowVolumesLightScissor, '1', '0'));
  end else
  if Cmd = 'r_highdynamicrange' then
  begin
    { TCastleViewport.HighDynamicRange (CGE change I): light passes added
      in linear colors. Set by name: older CGE versions don't have it. }
    if IsPublishedProp(MainViewport, 'HighDynamicRange') then
    begin
      if Args <> '' then
        SetOrdProp(MainViewport, 'HighDynamicRange', Ord(StrToIntDef(Args, 1) <> 0))
      else
        SetOrdProp(MainViewport, 'HighDynamicRange', 1 - GetOrdProp(MainViewport, 'HighDynamicRange'));
      Console.Print('r_highDynamicRange ' + IntToStr(GetOrdProp(MainViewport, 'HighDynamicRange')));
    end else
      Console.Print('r_highDynamicRange: not supported by this CGE');
  end else
  if Cmd = 'r_taa' then
  begin
    { TCastleViewport.TemporalAntiAliasing (CGE change Q): each frame jittered
      and blended with the previous ones (like RBDOOM-3-BFG's TAA).
      Set by name: older CGE versions don't have it. }
    if IsPublishedProp(MainViewport, 'TemporalAntiAliasing') then
    begin
      if Args <> '' then
        SetOrdProp(MainViewport, 'TemporalAntiAliasing', Ord(StrToIntDef(Args, 1) <> 0))
      else
        SetOrdProp(MainViewport, 'TemporalAntiAliasing', 1 - GetOrdProp(MainViewport, 'TemporalAntiAliasing'));
      Console.Print('r_taa ' + IntToStr(GetOrdProp(MainViewport, 'TemporalAntiAliasing')));
      WritelnLog('GameViewPlay', 'Temporal anti-aliasing %s',
        [BoolToStr(GetOrdProp(MainViewport, 'TemporalAntiAliasing') <> 0, 'on', 'off')]);
    end else
    begin
      Console.Print('r_taa: not supported by this CGE');
      WritelnLog('GameViewPlay', 'Temporal anti-aliasing: not supported by this CGE (needs TCastleViewport.TemporalAntiAliasing, CGE change Q)');
    end;
  end else
  if Cmd = 'r_sharedlighteffects' then
  begin
    { lights of a kind share one Effect with per-light uniforms (CGE change
      K): fewer shader programs; 0 gives each light its own Effect }
    if Args <> '' then
      SharedLightEffects := StrToIntDef(Args, 1) <> 0
    else
      SharedLightEffects := not SharedLightEffects;
    Console.Print('r_sharedLightEffects ' + BoolToStr(SharedLightEffects, '1', '0') +
      BoolToStr(SharedLightEffectsAvailable, '', ' (not supported by this CGE)') + ', reloading the map');
    LoadLevel(MapName);
  end else
  if Cmd = 'r_globalambient' then
  begin
    { CGE's global ambient light (its default 0.2 times the materials' 0.2
      ambient make every surface at least 10 of 255 bright; Doom 3 is
      black where no light reaches: r_globalAmbient 0) }
    if Args <> '' then
      RenderContext.GlobalAmbient := Vector3(1, 1, 1) * SysUtils.StrToFloatDef(Trim(Args), 0, DefaultFormatSettings);
    Console.Print(Format('r_globalAmbient %.2f', [RenderContext.GlobalAmbient.X]));
  end else
  if Cmd = 'r_lightvolumes' then
  begin
    if Args <> '' then
      LightVolumes := StrToIntDef(Args, 1) <> 0
    else
      LightVolumes := not LightVolumes;
    Console.Print('r_lightVolumes ' + BoolToStr(LightVolumes, '1', '0') + ', reloading the map');
    LoadLevel(MapName);
  end else
  if Cmd = 'r_md5shadowtris' then
  begin
    if Args <> '' then
    begin
      MaxShadowCastingTriangles := StrToIntDef(Args, MaxShadowCastingTriangles);
      Console.Print(Format('r_md5ShadowTris %d, reloading the map', [MaxShadowCastingTriangles]));
      LoadLevel(MapName);
    end else
      Console.Print(Format('r_md5ShadowTris %d (bigger md5 meshes cast with joint boxes, unless closed and r_md5ShadowClosed)',
        [MaxShadowCastingTriangles]));
  end else
  if Cmd = 'r_prelightshadows' then
  begin
    if Args <> '' then
    begin
      Map.PrelightShadows := Args <> '0';
      Console.Print('r_prelightShadows ' + BoolToStr(Map.PrelightShadows, '1', '0') + ', reloading the map');
      LoadLevel(MapName);
    end else
      Console.Print('r_prelightShadows ' + BoolToStr(Map.PrelightShadows, '1', '0') +
        ' (lights also cast the shadow volumes precomputed in the .proc file)');
  end else
  if Cmd = 'r_md5shadowclosed' then
  begin
    if Args <> '' then
      ClosedMeshesCastShadows := Args <> '0';
    Console.Print('r_md5ShadowClosed ' + BoolToStr(ClosedMeshesCastShadows, '1', '0') +
      ' (closed md5 meshes cast with their triangles; r_md5ShadowTris reloads the map)');
  end else
  if Cmd = 'guidump' then
  begin
    { draw a GUI file (no state) and save it next to the screenshots }
    Gui := TD3Gui.Create;
    try
      if Gui.LoadFromVfs(Args) then
      begin
        GuiImage := RenderGui(Gui, nil);
        try
          { back to the GUI's 640 x 480 shape }
          GuiImage.Resize(GuiWidth, GuiHeight, riBilinear);
          S := Iff(AutoTestPrefix <> '', AutoTestPrefix, 'castle-doom3') + '_gui.png';
          SaveImage(GuiImage, S);
          Console.Print('Saved ' + S);
          WritelnLog('GuiDump', '%s (%d windows) -> %s', [Args, Gui.WindowCount, S]);
        finally FreeAndNil(GuiImage) end;
        { the software painter's time and a checksum of its pixels (to
          compare painter changes) }
        GuiStart := Timer;
        GuiSum := 0;
        GuiRuns := Max(1, StrToIntDef(GetEnvironmentVariable('CD3_GUIDUMP_RUNS'), 10));
        { env CD3_GUIDUMP_SIZE=<w>x<h>: the transparent render at that size
          (the HUD at the screen's size, premultiplied like the game's) }
        S := GetEnvironmentVariable('CD3_GUIDUMP_SIZE');
        for I := 1 to GuiRuns do
        begin
          if Pos('x', S) > 0 then
            GuiImage := RenderGuiTransparent(Gui, StrToIntDef(Copy(S, 1, Pos('x', S) - 1), 0),
              StrToIntDef(Copy(S, Pos('x', S) + 1, MaxInt), 0), True)
          else
            GuiImage := RenderGui(Gui, nil);
          if I = GuiRuns then
            for J := 0 to GuiImage.Width * GuiImage.Height * 4 - 1 do
              GuiSum := (GuiSum * 31 + PByte(GuiImage.RawPixels)[J]) and $FFFFFFFF;
          FreeAndNil(GuiImage);
        end;
        WritelnLog('GuiDump', '%s: %.2f ms a render, checksum %d', [Args, TimerSeconds(Timer, GuiStart) * 1000 / GuiRuns, GuiSum]);
      end else
        Console.Print('Cannot load GUI ' + Args);
    finally FreeAndNil(Gui) end;
  end else
  if Cmd = 'ent' then
  begin
    { a built entity (brush entity or static model): scene state }
    S := 'not built (no brush or static model entity named ' + Args + ')';
    for I := 0 to Map.Brushes.Count - 1 do
      if SameText(Map.Brushes[I].Entity.Name, Args) then
      begin
        S := Format('%s %s exists=%s visible=%s collides=%s pickable=%s areas=%d box=%s scene %s', [Args,
          Map.Brushes[I].Entity.ClassName_,
          BoolToStr(Map.Brushes[I].Scene.Exists, '1', '0'), BoolToStr(Map.Brushes[I].Scene.Visible, '1', '0'),
          BoolToStr(Map.Brushes[I].Scene.Collides, '1', '0'), BoolToStr(Map.Brushes[I].Scene.Pickable, '1', '0'),
          Length(Map.Brushes[I].Areas), Map.Brushes[I].Scene.WorldBoundingBox.ToString,
          Map.Brushes[I].Scene.Name]);
        Break;
      end;
    Console.Print(S);
    WritelnLog('Ent', S);
  end else
  if Cmd = 'decal' then
  begin
    { decal <material> [size]: stick a decal where the view's center ray
      hits the world (roadmap item 3) }
    Words := Trim(Args).Split([' '], TStringSplitOptions.ExcludeEmpty);
    if Length(Words) = 0 then
      Console.Print('decal <material> [size]')
    else
    if FGame.WorldHit(Camera.Translation, Camera.Direction, 4096, HitDistance, HitNormal) then
    begin
      I := 16;
      if Length(Words) > 1 then
        I := StrToIntDef(Words[1], I);
      FGame.AddDecal(Words[0], CgeToD3(Camera.Translation + Camera.Direction * HitDistance),
        CgeToD3(HitNormal), I);
      Console.Print(Format('Decal %s, %d decals', [Words[0], FGame.Decals.Decals.Count]));
    end else
      Console.Print('decal: nothing hit');
  end else
  if Cmd = 'pick' then
  begin
    { what the view's center ray hits first (pickable, existing scenes,
      also ones hidden by portal visibility); "pick x y": the ray through
      that point of the view, as fractions from the top left }
    Words := Args.Split([' '], TStringSplitOptions.ExcludeEmpty);
    if Length(Words) >= 2 then
    begin
      MainViewport.PositionToRay(Vector2(StrToFloatDef(Words[0], 0.5) * MainViewport.EffectiveWidth,
        (1 - StrToFloatDef(Words[1], 0.5)) * MainViewport.EffectiveHeight), True, RayOrigin, RayDirection);
      Hit := Map.World.WorldRay(RayOrigin, RayDirection);
    end else
      Hit := Map.World.WorldRay(Camera.Translation, Camera.Direction);
    try
      if (Hit = nil) or (Hit.Count = 0) then
        S := 'nothing'
      else
      begin
        S := Format('%s (visible %s) at %s, distance %.1f', [Hit[0].Item.Name,
          BoolToStr(Hit[0].Item.Visible, '1', '0'), CgeToD3(Hit[0].Point).ToString, Hit.Distance]);
        if Hit[0].Triangle <> nil then
        begin
          S := S + Format(', shape %s, geometry %s', [Hit[0].Triangle^.Shape.Node.X3DName,
            Hit[0].Triangle^.Shape.Geometry.X3DName]);
          S := S + ', textures ' + ShapeTextureUrls(TShape(Hit[0].Triangle^.InternalShape));
        end;
        for I := 1 to Hit.Count - 1 do
          S := S + ' < ' + Hit[I].Item.Name;
        { the lights reaching the hit point; "(masked)": not in the hit
          scene's InternalGlobalLightsMask (r_lightAreas) }
        S := S + ', lights';
        for I := 0 to Map.LightCount - 1 do
          if Map.LightStrengthAt(I, Hit[0].Point) > 0 then
          begin
            S := S + ' ' + Map.Light(I).Entity.Name;
            if (Hit[0].Item is TCastleScene) and
               (Length(TCastleScene(Hit[0].Item).InternalGlobalLightsMask) <> 0) and
               (Map.Light(I).Node.InternalGlobalLightsMaskIndex > 0) and
               not TCastleScene(Hit[0].Item).InternalGlobalLightsMask[Map.Light(I).Node.InternalGlobalLightsMaskIndex - 1] then
              S := S + '(masked)';
          end;
      end;
    finally FreeAndNil(Hit) end;
    Console.Print(S);
    WritelnLog('Pick', S);
  end else
  if Cmd = 'activate' then
  begin
    { as if a trigger targeted it }
    if FGame.FindEntity(Args) <> nil then
      FGame.Activate(FGame.FindEntity(Args))
    else
      Console.Print('activate: no entity ' + Args);
  end else
  if Cmd = 'moveables' then
  begin
    { the moveables still moving (idMoveable's physics not at rest) }
    J := 0;
    for I := 0 to FGame.Moveables.Count - 1 do
      if not FGame.Moveables[I].AtRest and not FGame.Moveables[I].Brush.Hidden then
      begin
        Inc(J);
        WritelnLog('GameViewPlay', 'Moveable %s at %s, velocity %s', [FGame.Moveables[I].Brush.Entity.Name,
          FGame.Moveables[I].Origin.ToString, FGame.Moveables[I].Velocity.ToString]);
      end;
    WritelnLog('GameViewPlay', 'Moveables: %d of %d moving', [J, FGame.Moveables.Count]);
    Console.Print(Format('Moveables: %d of %d moving', [J, FGame.Moveables.Count]));
  end else
  if Cmd = 'g_dormant' then
  begin
    { monsters out of the player's PVS stop thinking (idEntity::CheckDormant) }
    if Args <> '' then
      FGame.DormancyEnabled := StrToIntDef(Args, 1) <> 0
    else
      FGame.DormancyEnabled := not FGame.DormancyEnabled;
    Console.Print(Format('g_dormant %s (%d dormant)', [BoolToStr(FGame.DormancyEnabled, '1', '0'), FGame.DormantCount]));
  end else
  if Cmd = 'endlevel' then
  begin
    { activate the map's target_endlevel (its exit GUI or script does in
      the game): the next map loads }
    for E in Map.MapFile.Entities do
      if SameText(E.ClassName_, 'target_endlevel') then
      begin
        WritelnLog('GameViewPlay', 'End level: activating %s (next map "%s")', [E.Name, E.Value('nextMap')]);
        FGame.Activate(E);
        Break;
      end;
  end else
  if Cmd = 'near' then
  begin
    { stand in front of an entity, facing it: near <name> [distance] }
    Words := Args.Split([' '], TStringSplitOptions.ExcludeEmpty);
    if (Length(Words) > 0) and (FGame.FindEntity(Words[0]) <> nil) then
    begin
      E := FGame.FindEntity(Words[0]);
      Dist := 100;
      if Length(Words) > 1 then
        Dist := StrToFloatDef(Words[1], 100);
      P := E.Origin + Vector3(Cos(DegToRad(E.Angle)), Sin(DegToRad(E.Angle)), 0) * Dist;
      PlaceCamera(D3ToCge(P), E.Angle + 180);
      Console.Print(Format('near %s at %s', [E.Name, P.ToString]));
    end else
      Console.Print('near: no entity ' + Args);
  end else
  if Cmd = 'actors' then
  begin
    S := FGame.ActorStatus;
    Console.Print(S);
    WritelnLog('Actors', LineEnding + S);
  end else
  if Cmd = 'skipcinematic' then
    FGame.SkipCinematic
  else
  if Cmd = 'reverb' then
  begin
    S := ReverbStatus;
    Console.Print(S);
    WritelnLog('Reverb', S);
  end else
  if Cmd = 's_useeaxreverb' then
  begin
    if Args <> '' then
      FUseReverb := Args <> '0';
    Console.Print('s_useEAXReverb ' + BoolToStr(FUseReverb, '1', '0') + ' (reverb from efxs/<map>.efx)');
  end else
  if Cmd = 'soundinfo' then
  begin
    S := SoundInfo;
    Console.Print(S);
    WritelnLog('SoundInfo', S);
  end else
  if Cmd = 'aas' then
  begin
    { the player's AAS area; with an entity, its route to the player }
    S := FGame.RouteStatus(Args);
    Console.Print(S);
    WritelnLog('AAS', S);
  end else
  if Cmd = 'r_occlusionsort' then
  begin
    { opaque shapes front to back (1), so the GPU's early depth test skips
      the pixels of the ones behind, or in the scenes' order (0) }
    if Trim(Args) <> '' then
    begin
      if StrToIntDef(Trim(Args), 1) <> 0 then
        MainViewport.OcclusionSort := sort3D
      else
        MainViewport.OcclusionSort := sortNone;
    end;
    Console.Print('r_occlusionSort ' + IntToStr(Ord(MainViewport.OcclusionSort = sort3D)));
  end else
  if Cmd = 'perf' then
  begin
    { the average frame and its parts over N seconds (PerfFrame) }
    FPerfLeft := StrToFloatDef(Trim(Args), 5);
    FPerfFrames := 0;
    FPerfFrame := 0;
    FPerfWorst := 0;
    FPerfUpdate := 0;
    FPerfGame := 0;
    FPerfVisibility := 0;
    FPerfHud := 0;
    FillChar(FPerfParts, SizeOf(FPerfParts), 0);
    FPerfGpu := 0;
    FPerfGpuFrames := 0;
    FPerfCpuStart := MainThreadCpuSeconds;
    FPerfPreRender := 0;
    FPerfRenderCpu := 0;
    FPerfRenderFrames := 0;
    { queries of earlier frames measured the settings before }
    FillChar(FGpuQueryUsed, SizeOf(FGpuQueryUsed), 0);
    Console.Print(Format('Measuring %.1f s', [FPerfLeft]));
  end else
  if Cmd = 'sample' then
  begin
    { the sampling profiler (Doom3Sampler): "sample start", "sample stop"
      writes samples.txt next to the exe (tools/resolve_samples.py) }
    if Copy(Args, 1, 5) = 'start' then
    begin
      SamplerStart;
      FSampleLeft := StrToFloatDef(Trim(Copy(Args, 6, MaxInt)), 0);
      Console.Print('Sampling');
    end else
    begin
      SamplerStopAndReport('Sample of ' + MapName);
      Console.Print('Samples written (samples.txt)');
    end;
  end else
  if Cmd = 'r_broadphase' then
  begin
    { monsters' collision queries ask only the scenes near them (1), or
      the world's own methods (0) }
    FGame.Broadphase := StrToIntDef(Trim(Args), Ord(not FGame.Broadphase)) <> 0;
    Console.Print('r_broadphase ' + IntToStr(Ord(FGame.Broadphase)));
  end else
  if Cmd = 'r_heightbroadphase' then
  begin
    Map.HeightBroadphase := StrToIntDef(Trim(Args), Ord(not Map.HeightBroadphase)) <> 0;
    Console.Print('r_heightBroadphase ' + BoolToStr(Map.HeightBroadphase, '1', '0'));
    WritelnLog('GameViewPlay', 'Height broadphase %s', [BoolToStr(Map.HeightBroadphase, 'on', 'off')]);
  end else
  if Cmd = 'colbench' then
  begin
    { the cost of a short segment collision at the eye: against the whole
      world, then without the collision model's scenes (what the other
      colliding scenes cost) }
    S := FGame.CollisionBenchmark(Camera.Translation);
    Console.Print(S);
    WritelnLog('Benchmark', S);
  end else
  if Cmd = 'meminfo' then
  begin
    LogMemory('Now');
    Console.Print(ProcessMemoryText);
    Map.LogChildCounts;
    if TextureMemoryProfiler.Enabled and (Trim(Args) = 'full') then
      WritelnLogMultiline('Memory', TextureMemoryProfiler.Summary);
  end else
  if Cmd = 'scripts' then
  begin
    S := FGame.ScriptStatus;
    Console.Print(S);
    WritelnLog('Scripts', S);
  end else
  if Cmd = 'g_stoptime' then
  begin
    { freeze script threads and the entities they move,
      and the map's time (light shaders, animated surfaces) }
    if Args <> '' then
      FGame.ScriptsPaused := StrToIntDef(Args, 1) <> 0
    else
      FGame.ScriptsPaused := not FGame.ScriptsPaused;
    Map.TimePaused := FGame.ScriptsPaused;
    Console.Print('g_stopTime ' + BoolToStr(FGame.ScriptsPaused, '1', '0'));
  end else
  if Cmd = 'lightsat' then
  begin
    { lights reaching the player: Doom 3 light texture coordinates (s, t, q)
      and strength at the floor below the eye and at the eye }
    P := Camera.Translation - Vector3(0, PlayerEyeHeight - 1, 0);
    for I := 0 to Map.LightCount - 1 do
    begin
      L := Map.Light(I);
      if (Map.LightStrengthAt(I, P) > 0) or (Map.LightStrengthAt(I, Camera.Translation) > 0) then
      begin
        S := Format('%s %s on=%s floor %.2f eye %.2f stq %s', [L.Entity.Name, L.Entity.Value('texture', '(default)'),
          BoolToStr(L.Node.IsOn, '1', '0'), Map.LightStrengthAt(I, P), Map.LightStrengthAt(I, Camera.Translation),
          LightTexCoord(L.Matrix, P).ToString]);
        { its areas, and whether it lights the player's area scene
          (r_lightAreas: InternalGlobalLightsMask) }
        S := S + ' areas';
        for J in L.Areas do
          S := S + ' ' + IntToStr(J);
        J := Map.AreaAt(Camera.Translation);
        if (J >= 0) and (Map.AreaScene(J) <> nil) and
           (Length(Map.AreaScene(J).InternalGlobalLightsMask) <> 0) and
           (L.Node.InternalGlobalLightsMaskIndex > 0) and
           not Map.AreaScene(J).InternalGlobalLightsMask[L.Node.InternalGlobalLightsMaskIndex - 1] then
          S := S + Format(' (not in area %d''s lights)', [J]);
        Console.Print(S);
        WritelnLog('LightsAt', S);
      end;
    end;
  end else
  if Cmd = 'lights' then
  begin
    for I := 0 to Map.LightCount - 1 do
    begin
      L := Map.Light(I);
      { not Iff: it evaluates both arguments (L.Shader may be nil) }
      if L.Shader <> nil then
        ShaderName := L.Shader.Name
      else
        ShaderName := '(default)';
      S := Format('%s %s color %.2f %.2f %.2f%s%s%s', [L.Entity.Name, ShaderName,
        L.Color.X, L.Color.Y, L.Color.Z, BoolToStr(L.Animated, ' animated', ''),
        BoolToStr(L.Node.IsOn, '', ' off'), BoolToStr(L.Node.ShadowVolumesMain, ' shadows', '')]);
      Console.Print(S);
      WritelnLog('Lights', S);
    end;
  end else
  if Cmd = 'triggers' then
  begin
    { triggers [name part]: each trigger's volume (Doom 3 coordinates) and
      state }
    for T in FGame.Triggers do
      if (Args = '') or (Pos(LowerCase(Args), LowerCase(T.Entity.Name)) > 0) then
      begin
        S := Format('Trigger %s (%s): %s - %s%s%s%s%s', [T.Entity.Name, T.Entity.ClassName_,
          CgeToD3(T.Box.Data[0]).ToString, CgeToD3(T.Box.Data[1]).ToString,
          BoolToStr(T.Disabled, ' disabled', ''), BoolToStr(T.NoTouch, ' noTouch', ''),
          BoolToStr(T.WaitingForActivation, ' waiting for activation', ''),
          BoolToStr(T.Flashlight, ' flashlight', '')]);
        WritelnLog('Triggers', S);
        Console.Print(S);
      end;
  end else
  if Cmd = 'portals' then
  begin
    Console.Print(Format('area %d, %d of %d areas visible, %d portals',
      [Map.AreaAt(Camera.Translation), Map.VisibleAreaCount, Map.AreaCount,
       Map.Portals.PortalCount]));
    WritelnLog('Portals', 'area %d, %d of %d areas visible',
      [Map.AreaAt(Camera.Translation), Map.VisibleAreaCount, Map.AreaCount]);
  end else
  if Cmd = 'fps' then
    LabelFps.Exists := not LabelFps.Exists
  else
  if Cmd = 'g_enableportalsky' then
  begin
    { g_enablePortalSky [0|1]: d3xp's cvar }
    if Args <> '' then
      FPortalSkyOn := StrToIntDef(Args, 1) <> 0;
    Console.Print(Format('g_enablePortalSky %d (%s; the map %s)', [Ord(FPortalSkyOn),
      BoolToStr(FPortalSkyActive, 'drawn now', 'not drawn now'),
      BoolToStr(Map.HasPortalSky, 'has portal sky surfaces', 'has none')]));
  end else
  if Cmd = 'r_skipfoglights' then
  begin
    { r_skipFogLights [0|1]: Doom 3's cvar, fog lights off }
    if Args <> '' then
      Map.FogLightsOn := StrToIntDef(Args, 0) = 0
    else
      Map.FogLightsOn := not Map.FogLightsOn;
    Console.Print('r_skipFogLights ' + BoolToStr(not Map.FogLightsOn, '1', '0'));
  end else
  if Cmd = 'classic' then
  begin
    { classic [0|1]: the 2004 game's light scale and field of view on BFG
      data (D3ClassicMode); reloads the map for the lights }
    if Args <> '' then
      D3ClassicMode := StrToIntDef(Args, 1) <> 0;
    Console.Print(Format('classic %s (%s look)', [BoolToStr(D3ClassicMode, '1', '0'),
      Iff(D3BfgLook, 'Doom 3 BFG', 'Doom 3 2004')]));
    WritelnLog('GameViewPlay', 'Classic mode %s: %s look', [BoolToStr(D3ClassicMode, 'on', 'off'),
      Iff(D3BfgLook, 'Doom 3 BFG', 'Doom 3 2004')]);
    if Args <> '' then
    begin
      ApplyDefaultFov;
      LoadLevel(MapName);
    end;
  end else
  if Cmd = 'lightscale' then
  begin
    Map.LightScale := StrToFloatDef(Args, 1);
    LoadLevel(MapName);
  end else
  if Cmd = 'decls' then
    Console.Print(Format('%d materials, %d entityDefs, %d models, %d skins, %d sound shaders',
      [Decls.DeclCount(dtMaterial), Decls.DeclCount(dtEntityDef), Decls.DeclCount(dtModel),
       Decls.DeclCount(dtSkin), Decls.DeclCount(dtSound)]))
  else
  if Cmd = 'quit' then
    Application.Terminate
  else
    Console.Print('Unknown command "' + Cmd + '"');
end;

{$ifdef MSWINDOWS}
{ user32 calls declared here: the Windows unit's names would hide
  SysUtils' (GetEnvironmentVariable) }
type
  TEnumWindowsProc = function(Wnd: PtrUInt; Param: PtrInt): LongBool; stdcall;
function EnumThreadWindows(ThreadId: LongWord; Proc: TEnumWindowsProc; Param: PtrInt): LongBool; stdcall; external 'user32.dll';
function IsIconic(Wnd: PtrUInt): LongBool; stdcall; external 'user32.dll';
function IsWindowVisible(Wnd: PtrUInt): LongBool; stdcall; external 'user32.dll';
function ShowWindow(Wnd: PtrUInt; CmdShow: Integer): LongBool; stdcall; external 'user32.dll';
function GetCurrentThreadId: LongWord; stdcall; external 'kernel32.dll';

function IconicWindowFound(Wnd: PtrUInt; Param: PtrInt): LongBool; stdcall;
begin
  if IsWindowVisible(Wnd) and IsIconic(Wnd) then
    PBoolean(Param)^ := true;
  Result := true;
end;
{$endif}

{$ifdef MSWINDOWS}
function MinimizeWindowFound(Wnd: PtrUInt; Param: PtrInt): LongBool; stdcall;
const
  SW_MINIMIZE = 6;
begin
  if IsWindowVisible(Wnd) then
    ShowWindow(Wnd, SW_MINIMIZE);
  Result := true;
end;
{$endif}

procedure MinimizeGameWindow;
begin
  {$ifdef MSWINDOWS}
  EnumThreadWindows(GetCurrentThreadId, @MinimizeWindowFound, 0);
  {$endif}
end;

{ Is the game's window minimized (test runs started minimized): then its
  pixels aren't drawn, a screenshot read from it is black. }
function GameWindowMinimized: Boolean;
begin
  Result := false;
  {$ifdef MSWINDOWS}
  EnumThreadWindows(GetCurrentThreadId, @IconicWindowFound, PtrInt(@Result));
  {$endif}
end;

procedure TViewPlay.CaptureScreenshot;

  { The whole container rendered into a framebuffer object of the window's
    size: works while the window is minimized. }
  function SaveScreenOffscreen: TRGBImage;
  var
    RenderToTexture: TGLRenderToTexture;
    R: TRectangle;
  begin
    R := Container.PixelsRect;
    RenderToTexture := TGLRenderToTexture.Create(R.Width, R.Height);
    try
      RenderToTexture.Buffer := tbNone;
      RenderToTexture.GLContextOpen;
      RenderToTexture.RenderBegin;
      Container.EventBeforeRender;
      Container.EventRender;
      Result := SaveScreen_NoFlush(TRGBImage, R, RenderToTexture.ColorBuffer) as TRGBImage;
      RenderToTexture.RenderEnd;
    finally
      FreeAndNil(RenderToTexture);
    end;
  end;

var
  Path, ShadowName: String;
  Img: TCastleImage;
  I: Integer;
  ShotStart: TTimerResult;
  CaptureTime, SaveTime: Single;
begin
  Inc(FShots);
  ShotStart := Timer;
  if AutoTestPrefix <> '' then
    Path := AutoTestPrefix + '_' + IntToStr(FShots) + '.png'
  else
    Path := FormatDateTime('"castle-doom3-"yyyymmdd-hhnnss', Now) + '.png';
  if GameWindowMinimized then
    Img := SaveScreenOffscreen
  else
    Img := Container.SaveScreen;
  CaptureTime := TimerSeconds(Timer, ShotStart);
  { the previous one is long written by now (shots are seconds apart) }
  WaitScreenshotSaved;
  SaveTime := TimerSeconds(Timer, ShotStart) - CaptureTime;
  ScreenshotSaver := TScreenshotSaver.Create(True);
  ScreenshotSaver.Img := Img;
  ScreenshotSaver.Path := Path;
  ScreenshotSaver.Start;
  ShadowName := '';
  for I in Map.ShadowLights do
  begin
    if ShadowName <> '' then
      ShadowName := ShadowName + ' ';
    ShadowName := ShadowName + Map.Light(I).Entity.Name;
  end;
  if ShadowName = '' then
    ShadowName := 'none';
  WritelnLog('GameViewPlay', 'Screenshot "%s" (%.1f FPS, eye %s, yaw %.0f, area %d, visible areas %d, shapes %d of %d, programs %d, dormant %d, capture %.2f s, waited %.2f s, shadows %s%s)',
    [Path, Container.Fps.RealFps, CgeToD3(Camera.Translation).ToString, CameraYaw,
     Map.AreaAt(Camera.Translation), Map.VisibleAreaCount,
     MainViewport.Statistics.ShapesRendered, MainViewport.Statistics.ShapesVisible,
     InternalProgramsLinked, FGame.DormantCount,
     CaptureTime, SaveTime, ShadowName,
     Iff(FGame.CinematicName <> '', ', cinematic ' + FGame.CinematicName, '')]);
end;

procedure TViewPlay.BuildCoverageRoute(const Goal: TVector3; const GoalName: String);
var
  Spots: TD3PointArray;
  Names: TStringList;
  T: TD3Trigger;
  E: TD3MapEntity;
  S: String;
  Cur, P: TVector3;
  Hop: TD3PointArray;
  Best, D, Gap: Single;
  I, J, BestI, Areas: Integer;
  Used: array of Boolean;
begin
  Spots := nil;
  Names := TStringList.Create;
  try
    for T in FGame.Triggers do
      { flashlight triggers: the beam fires them, walking there doesn't }
      if (T.Kind <> tkHurt) and not T.NoTouch and not T.Flashlight and not SameText(T.Entity.Name, GoalName) then
      begin
        P := CgeToD3(T.Box.Center);
        P.Z := CgeToD3(T.Box.Data[0]).Z;
        if PointsDistance(P, Goal) < 64 then
          Continue;
        Spots := Concat(Spots, [P]);
        Names.Add(T.Entity.Name);
      end;
    for E in Map.MapFile.Entities do
    begin
      S := LowerCase(E.ClassName_);
      if (Copy(S, 1, 5) = 'item_') or (Copy(S, 1, 7) = 'weapon_') or (Copy(S, 1, 5) = 'ammo_') or
         (Copy(S, 1, 14) = 'moveable_item_') then
      begin
        Spots := Concat(Spots, [E.Origin]);
        Names.Add(E.Name);
      end;
    end;
    Cur := CgeToD3(Camera.Translation) - Vector3(0, 0, FGame.EyeHeight);
    FRoute := [Cur];
    FRouteGaps := 0;
    SetLength(Used, Length(Spots));
    for I := 0 to High(Spots) + 1 do
    begin
      if I <= High(Spots) then
      begin
        { the nearest spot left (heights count double: stay on a floor) }
        Best := MaxSingle;
        BestI := -1;
        for J := 0 to High(Spots) do
          if not Used[J] then
          begin
            D := Sqr(Spots[J].X - Cur.X) + Sqr(Spots[J].Y - Cur.Y) + 4 * Sqr(Spots[J].Z - Cur.Z);
            if D < Best then
            begin
              Best := D;
              BestI := J;
            end;
          end;
        Used[BestI] := True;
        P := Spots[BestI];
        S := Names[BestI];
      end else
      begin
        P := Goal;
        S := GoalName;
      end;
      FGame.PlayerRoute(Cur, P, Hop, Gap, Areas);
      FRoute := Concat(FRoute, Copy(Hop, 1, MaxInt));
      FRouteGaps := FRouteGaps + Gap;
      FRouteMarks := Concat(FRouteMarks, [High(FRoute)]);
      FRouteMarkNames := Concat(FRouteMarkNames, [S]);
      Cur := P;
    end;
  finally
    Names.Free;
  end;
end;

procedure TViewPlay.FightSummary;
begin
  WritelnLog('GameViewPlay', 'Fight: summary: %d kills, %d deaths, %d saves, %d places given up (god mode), health %d, armor %d, %.0f s',
    [FFightKills, FFightDeaths, FFightSaves, FFightGaveUp, FGame.Health, FGame.Armor, FFightTime]);
  FGame.MonsterReport;
  if FRouteWalkMode then
    WalkSummary;
end;

procedure TViewPlay.WalkSummary;
begin
  WritelnLog('GameViewPlay', 'Walk: summary: %d stuck spots (%d remembered from earlier runs), %d falls through the floor, %d doors opened for the walk, %d elevators called, %d detours, %d loops put ahead, %d remembered give-up places%s',
    [FWalkStuckCount, FMemStuckUsed, FWalkFellCount, FWalkDoorsOpened, FWalkElevatorsCalled, FWalkReroutes, FWalkLoops, FMemGiveUpsUsed, FWalkStuckSpots]);
end;

function TViewPlay.HuntNext: Boolean;
const
  HuntTries = 3;
  HuntMaxSeconds = 1500;
  HuntNoKillSeconds = 300;
var
  Stalled: Boolean;
  Mon, Best, Hidden: TD3Monster;
  Feet, P, Away: TVector3;
  D, BestD, Gap, HiddenD: Single;
  Hop: TD3PointArray;
  Areas, I: Integer;
  MonName, AliveList: String;

  function Listed(const List, AName: String): Boolean;
  begin
    Result := Pos(',' + LowerCase(AName) + ',', ',' + LowerCase(List) + ',') > 0;
  end;

begin
  Result := False;
  Feet := CgeToD3(Camera.Translation) - Vector3(0, 0, FGame.EyeHeight);
  if FFightKills <> FHuntLastKills then
  begin
    FHuntLastKills := FFightKills;
    FHuntKillTime := FHuntTime;
  end;
  Stalled := FHuntTime - FHuntKillTime > HuntNoKillSeconds;
  repeat
    Best := nil;
    BestD := MaxSingle;
    for Mon in FGame.Monsters do
      if FGame.MonsterHuntable(Mon) and not Listed(FHuntDone, Mon.Model.Entity.Name) and
         not Listed(FFightIgnore, Mon.Model.Entity.Name) then
      begin
        D := PointsDistance(Feet, CgeToD3(Mon.Position));
        if D < BestD then
        begin
          BestD := D;
          Best := Mon;
        end;
      end;
    { none shown is left: the places of the monsters never shown (their
      trigger never fired: a part of the map the route didn't go through,
      a closet a script opens); walking there fires it, or, once there,
      it is woken as its trigger would }
    if (Best = nil) and (FHuntTime <= HuntMaxSeconds) and not Stalled then
    begin
      Hidden := nil;
      HiddenD := MaxSingle;
      for Mon in FGame.Monsters do
        if (Mon.Model <> nil) and not Mon.Appeared and Mon.Model.Hidden and
           (Mon.State <> msDead) and not Listed(FHuntWoken, Mon.Model.Entity.Name) then
        begin
          D := PointsDistance(Feet, Mon.Model.Entity.Origin);
          if D < HiddenD then
          begin
            HiddenD := D;
            Hidden := Mon;
          end;
        end;
      if Hidden <> nil then
      begin
        MonName := Hidden.Model.Entity.Name;
        if Listed(FHuntHidden, MonName) then
        begin
          FHuntWoken := FHuntWoken + ',' + MonName;
          WritelnLog('GameViewPlay', 'Fight: hunt: %s (%s) still hidden, %.0f from its place: woken, as its trigger would',
            [MonName, Hidden.Model.Entity.ClassName_, HiddenD]);
          FGame.Activate(Hidden.Model.Entity);
          Continue;
        end;
        FHuntHidden := FHuntHidden + ',' + MonName;
        P := Hidden.Model.Entity.Origin;
        FGame.PlayerRoute(Feet, P, Hop, Gap, Areas);
        if Length(Hop) < 2 then
          Hop := [Feet, P];
        FRoute := Hop;
        FRouteSeg := 0;
        FRouteAlong := 0;
        FRouteMarks := nil;
        FRouteMarkNames := nil;
        FRouteNextMark := 0;
        FRouteLastEye := Camera.Translation;
        FHuntTarget := MonName;
        Inc(FHuntRoutes);
        WritelnLog('GameViewPlay', 'Fight: hunt: to the place of %s (%s, never shown) at %s, %.0f away',
          [MonName, Hidden.Model.Entity.ClassName_, P.ToString, HiddenD]);
        Exit(True);
      end;
    end;
    if (Best = nil) or (FHuntTime > HuntMaxSeconds) or Stalled then
    begin
      if Stalled then
        WritelnLog('GameViewPlay', 'Fight: hunt: no kill in %.0f s (%d routes): done',
          [FHuntTime - FHuntKillTime, FHuntRoutes]);
      AliveList := '';
      for Mon in FGame.Monsters do
        if FGame.MonsterHuntable(Mon) then
          AliveList := AliveList + ' ' + Mon.Model.Entity.Name;
      if FHuntTime > HuntMaxSeconds then
        WritelnLog('GameViewPlay', 'Fight: hunt: out of time (%.0f s)', [FHuntTime]);
      if AliveList = '' then
        AliveList := ' none';
      WritelnLog('GameViewPlay', 'Fight: hunt done after %d routes, %.0f s; alive and shown:%s',
        [FHuntRoutes, FHuntTime, AliveList]);
      FHuntTarget := '';
      Exit;
    end;
    MonName := Best.Model.Entity.Name;
    FHuntTarget := MonName;
    FHuntTries := 0;
    I := Pos(',' + LowerCase(MonName) + ',', FHuntTried);
    while I > 0 do
    begin
      Inc(FHuntTries);
      I := Pos(',' + LowerCase(MonName) + ',', FHuntTried, I + 1);
    end;
    FHuntTried := FHuntTried + ',' + LowerCase(MonName) + ',';
    if FHuntTries >= HuntTries then
    begin
      WritelnLog('GameViewPlay', 'Fight: hunt: gave up on %s at %s (health %d)',
        [MonName, CgeToD3(Best.Position).ToString, Best.Health]);
      FHuntDone := FHuntDone + ',' + MonName;
      Continue;
    end;
    Break;
  until False;
  { wake it, as a trigger would: it comes for the player }
  FGame.Activate(Best.Model.Entity);
  P := CgeToD3(Best.Position);
  if (BestD < 96) and not ((FGame.IdealSlot >= 0) and
     (Pos('fists', LowerCase(FGame.WeaponDefs[FGame.IdealSlot])) > 0)) then
  begin
    { arrived on top of it, and the fight didn't take aim (too close: the
      routes of tries 2 and 3 were empty, the hunt gave up on a monster
      clawing the player): back off 160 units so it is in front }
    Away := Feet - P;
    Away.Z := 0;
    if Away.Length < 1 then
      Away := Vector3(1, 0, 0);
    Hop := [Feet, Feet + Away.Normalize * 160];
    WritelnLog('GameViewPlay', 'Fight: hunt: backing off from %s', [Best.Model.Entity.Name]);
  end else
  begin
    FGame.PlayerRoute(Feet, P, Hop, Gap, Areas);
    if Length(Hop) < 2 then
      Hop := [Feet, P];
  end;
  FRoute := Hop;
  FRouteSeg := 0;
  FRouteAlong := 0;
  FRouteMarks := nil;
  FRouteMarkNames := nil;
  FRouteNextMark := 0;
  FRouteLastEye := Camera.Translation;
  Inc(FHuntRoutes);
  WritelnLog('GameViewPlay', 'Fight: hunting %s (%s) at %s, %.0f away (try %d)',
    [MonName, Best.Model.Entity.ClassName_, P.ToString, BestD, FHuntTries + 1]);
  Result := True;
end;

{ One step of the fighting playthrough; True while the walk waits (a
  fight, a death). }
function WalkMemoryFile(const Map: String): String;
begin
  Result := InclPathDelim(GetAppConfigDir(False)) + 'walkmemory' + PathDelim +
    StringReplace(StringReplace(LowerCase(Map), '/', '_', [rfReplaceAll]), '', '_', [rfReplaceAll]) + '.txt';
end;

{ The walk's memory is used unless env CD3_WALK_MEMORY=0 (it is still
  written then). }
function WalkMemoryOn: Boolean;
begin
  Result := GetEnvironmentVariable('CD3_WALK_MEMORY') <> '0';
end;

{ The fight's save: "fight", or env CD3_FIGHT_SAVE (two games fighting at
  once must not share a save). }
function FightSaveName: String;
begin
  Result := GetEnvironmentVariable('CD3_FIGHT_SAVE');
  if Result = '' then
    Result := 'fight';
end;

{ The fight's tactics (waiting for chasers out of sight, backing off from
  claws): env CD3_FIGHT_TACTICS=0 turns them off, to compare. }
function FightTactics: Boolean;
begin
  Result := GetEnvironmentVariable('CD3_FIGHT_TACTICS') <> '0';
end;

function TViewPlay.FightStep(const SecondsPassed: Single): Boolean;
const
  FightSaveEvery = 20;
  { no save while badly hurt (a load would start every fight like that),
    unless the last one is this old }
  FightSaveHealth = 50;
  FightSaveAnyway = 90;
  FightStrafeSpeed = 140;
  FightStrafeReach = 44;
  { closer than this it backs off (melee: claws, bites), at this speed }
  FightBackOffDist = 160;
  FightBackOffSpeed = 160;
  { a chaser out of sight this close holds the walk, this long at most }
  FightWaitDist = 600;
  FightWaitMax = 6;
  { out of a projectile's path: one passing within FightDodgeMiss of the
    eye in the next FightDodgeWithin seconds, at Doom 3's run speed
    (pm_runspeed) }
  FightDodgeMiss = 40;
  FightDodgeWithin = 0.7;
  FightDodgeSpeed = 220;
  { faster ones (bullets, 2000 and more) can't be dodged: sidestepping them
    only jitters (fireballs 325 to 475, rockets 300 to 700) }
  FightDodgeMaxSpeed = 1000;
var
  Target, Dir, Side, NewEye, Back, Away, Close: TVector3;
  TargetName, What: String;
  Slot, MemI, I: Integer;
  Fists: Boolean;
  Feet: TVector3;
  Mon: TD3Monster;
  HuntAlive: Boolean;
  Proj: TObject;

  { free to move to: no wall on the way, no hazard there }
  function CanMoveTo(const Eye, Dir: TVector3): Boolean;
  var
    W: String;
  begin
    Result := not MainViewport.Items.WorldSegmentCollision(Camera.Translation, Eye + Dir * (PlayerRadius + 8)) and
      not FightHazard(Eye, 0, W);
  end;

  { standing in a hazard: towards the nearest spot out of it with a floor;
    False when there is none }
  function StepOutOfHazard: Boolean;
  const
    Dirs = 16;
  var
    R, I: Integer;
    D, C, N: TVector3;
    Dist: Single;
    W: String;
  begin
    Result := False;
    for R := 1 to 6 do
      for I := 0 to Dirs - 1 do
      begin
        D := Vector3(Cos(2 * Pi * I / Dirs), 0, Sin(2 * Pi * I / Dirs));
        C := Camera.Translation + D * (R * 32);
        if MainViewport.Items.WorldSegmentCollision(Camera.Translation, C + D * (PlayerRadius + 8)) or
           FightHazard(C, 8, W) or
           not FGame.WorldHit(C, Vector3(0, -1, 0), FGame.EyeHeight + 48, Dist, N) then
          Continue;
        if What <> FFightHazardLogged then
        begin
          FFightHazardLogged := What;
          WritelnLog('GameViewPlay', 'Fight: stepping out of %s at %s (%d away)',
            [What, CgeToD3(Camera.Translation).ToString, R * 32]);
        end;
        Camera.Translation := Camera.Translation + D * Min(R * 32, FightDodgeSpeed * 2 * Min(SecondsPassed, 0.1));
        FFightAnchor := Camera.Translation;
        FRouteLastEye := Camera.Translation;
        Exit(True);
      end;
  end;

begin
  Result := False;
  { the fire button is held only while there is a target }
  FGame.Attack := False;
  FFightTime := FFightTime + SecondsPassed;
  if FGame.Kills > FFightLastKills then
  begin
    FFightKills := FFightKills + FGame.Kills - FFightLastKills;
    { something died: the fight makes progress }
    FFightOnTarget := 0;
  end;
  FFightLastKills := FGame.Kills;

  if FHuntTarget <> '' then
  begin
    FHuntTime := FHuntTime + SecondsPassed;
    { the hunted one died (or went away) on the way: the next one }
    HuntAlive := False;
    for Mon in FGame.Monsters do
      if FGame.MonsterHuntable(Mon) and SameText(Mon.Model.Entity.Name, FHuntTarget) then
        HuntAlive := True;
    if not HuntAlive and (FRouteHold <= 0) and (Length(FRoute) >= 2) then
    begin
      FRouteSeg := High(FRoute);
      FRouteAlong := 0;
    end;
  end;

  if FGame.PlayerDead then
  begin
    Inc(FFightDeaths);
    Inc(FFightDeathsHere);
    WritelnLog('GameViewPlay', 'Fight: died at %s (death %d, %d since the save)',
      [CgeToD3(Camera.Translation).ToString, FFightDeaths, FFightDeathsHere]);
    FLastDeathAt := CgeToD3(Camera.Translation) - Vector3(0, 0, FGame.EyeHeight);
    MemoryAdd('death', FLastDeathAt);
    FFightDeathWalked := Max(FFightDeathWalked, FRouteWalked);
    if not FFightHasSave then
    begin
      WritelnLog('GameViewPlay', 'Fight: no save to load: the fight ends');
      FightSummary;
      FFight := False;
      FRoute := nil;
      Exit(True);
    end;
    LoadGame(FightSaveName);
    FRoute := Copy(FFightRoute);
    FRouteSeg := FFightSeg;
    FRouteAlong := FFightAlong;
    FRouteWalked := FFightWalked;
    FRouteLastEye := Camera.Translation;
    FRouteHold := 0;
    FFightLastKills := FGame.Kills;
    FFightTarget := '';
    FFightIgnore := '';
    FFightWaitFor := '';
    FFightWaitIgnore := '';
    FFightWait := 0;
    FFightSinceSave := 0;
    FRouteOffset := TVector3.Zero;
    FRouteOffsetGoal := TVector3.Zero;
    if FFightDeathsHere >= 3 then
    begin
      { it can't get past here alive: on in god mode, until the next save,
        which waits until the walk is past the place of the deaths (a
        save right after this load ended the god mode thousands of units
        before it: the run died there again and again) }
      Inc(FFightGaveUp);
      FFightGod := True;
      FFightGodUntil := FFightDeathWalked + 400;
      WritelnLog('GameViewPlay', 'Fight: gave up at %s after %d deaths: god mode until the next save, %.0f units on',
        [FLastDeathAt.ToString, FFightDeathsHere, FFightGodUntil - FRouteWalked]);
      MemoryAdd('giveup', FLastDeathAt);
      { this run comes back here too (routes and hunts pass a place again
        and again: delta1's pit killed it 26 times) }
      MemoryEnsure;
      FMemGiveUp := Concat(FMemGiveUp, [FLastDeathAt]);
      SetLength(FMemGiveUpArm, Length(FMemGiveUp));
      FMemGiveUpArm[High(FMemGiveUpArm)] := FFightGodUntil + 600;
    end;
    FGame.God := FFightGod;
    Exit(True);
  end;

  { an earlier run gave up near here (3 deaths): god mode from 300 units
    before the place to 600 past it, without dying there again }
  if WalkMemoryOn and not FFightGod and (FFightTime >= FMemCheckAt) then
  begin
    FMemCheckAt := FFightTime + 0.5;
    MemoryEnsure;
    Feet := CgeToD3(Camera.Translation) - Vector3(0, 0, FGame.EyeHeight);
    if (MemoryNear(FMemGiveUp, Feet, 300, MemI) > 0) and (FRouteWalked >= FMemGiveUpArm[MemI]) then
    begin
      { every give-up at this place waits until the walk is well past it }
      for I := 0 to High(FMemGiveUp) do
        if PointsDistance(FMemGiveUp[I], FMemGiveUp[MemI]) < 300 then
          FMemGiveUpArm[I] := FRouteWalked + 1500;
      Inc(FMemGiveUpsUsed);
      FFightGod := True;
      FGame.God := True;
      FFightGodUntil := FRouteWalked + 900;
      WritelnLog('GameViewPlay', 'Fight: a run gave up near %s (%d times), %.0f away: god mode for 900 units',
        [FMemGiveUp[MemI].ToString, MemoryNear(FMemGiveUp, FMemGiveUp[MemI], 300, I), PointsDistance(Feet, FMemGiveUp[MemI])]);
    end;
  end;

  if FightTactics then
  begin
    { a fireball (a rocket, a burst) on its way: out of its path }
    if FGame.IncomingProjectile(Camera.Translation, FightDodgeMiss, FightDodgeWithin, FightDodgeMaxSpeed, Away, Proj, What) then
    begin
      NewEye := Camera.Translation + Away * (FightDodgeSpeed * Min(SecondsPassed, 0.1));
      if CanMoveTo(NewEye, Away) then
      begin
        if Proj <> FFightDodged then
        begin
          FFightDodged := Proj;
          WritelnLog('GameViewPlay', 'Fight: dodging %s at %s', [What, CgeToD3(Camera.Translation).ToString]);
        end;
        Camera.Translation := NewEye;
        FFightAnchor := NewEye;
        FRouteLastEye := NewEye;
      end;
    end;
    { in a hurt volume or by a barrel: out first, or walk on }
    if FightHazard(Camera.Translation, 0, What) then
    begin
      if HazardPassed(Camera.Translation) then
        { the walk goes through it }
      else
      begin
        { stepping out of it for over a second within 4 s: the walk keeps
          going back in (its way leads through it) }
        if FViewClock - FHazardStepAt > 4 then
          FHazardStepTime := 0;
        FHazardStepAt := FViewClock;
        FHazardStepTime := FHazardStepTime + SecondsPassed;
        if FHazardStepTime > 1 then
        begin
          WritelnLog('GameViewPlay', 'Fight: stepping out of %s fights the walk at %s: walking through it',
            [What, CgeToD3(Camera.Translation).ToString]);
          FHazardPassAt := Camera.Translation;
          FHazardPassUntil := FViewClock + 8;
          FHazardStepTime := 0;
        end else
        if not StepOutOfHazard then
          Exit(False);
      end;
    end;
  end;

  if FGame.FightTarget(Camera.Translation, 1200, FFightIgnore, Target, TargetName, FHuntTarget) and
     (FFightTime >= FFightSkipUntil) then
  begin
    if FFightTarget = '' then
    begin
      FFightAnchor := Camera.Translation;
      if FFightSide = 0 then
        FFightSide := 1;
    end;
    if TargetName <> FFightTarget then
    begin
      FFightTarget := TargetName;
      WritelnLog('GameViewPlay', 'Fight: target %s at %s (health %d)',
        [TargetName, CgeToD3(Target).ToString, FGame.Health]);
    end;
    { the map enables the weapons at a point the walk may not have reached
      (it cuts through doors) }
    if FGame.WeaponsDisabled then
    begin
      WritelnLog('GameViewPlay', 'Fight: the map had the weapons disabled here: enabled');
      FGame.WeaponsDisabled := False;
    end;
    { time since something died (the target may change back and forth) or
      the target was hurt (a boss: Sabaoth's 1750 took longer than 25 s) }
    for Mon in FGame.Monsters do
      if SameText(Mon.Model.Entity.Name, TargetName) then
      begin
        if (FFightTargetHealthOf = TargetName) and (Mon.Health < FFightTargetHealth) then
          FFightOnTarget := 0;
        FFightTargetHealthOf := TargetName;
        FFightTargetHealth := Mon.Health;
      end;
    FFightOnTarget := FFightOnTarget + SecondsPassed;
    if FFightOnTarget > 25 then
    begin
      { it doesn't die: leave it }
      WritelnLog('GameViewPlay', 'Fight: %s doesn''t die, walking on', [TargetName]);
      FFightIgnore := FFightIgnore + ',' + TargetName;
      FFightTarget := '';
      FFightOnTarget := 0;
      Exit(False);
    end;
    Slot := FGame.BestFightSlot;
    if (Slot >= 0) and (Slot <> FGame.IdealSlot) then
      FGame.SelectWeapon(Slot);
    Dir := Target - Camera.Translation;
    { held, not a pulse per frame: a shot ends a pulse, and the weapon's
      script gets a turn per game tic (several in a long frame); only once
      the view is on the target (it turns there smoothly) }
    { up close it fires anyway: a calm view there (a zombie stepping across
      it swung the aim back and forth) }
    if Dir.Length < 128 then
      FGame.Attack := (TurnViewTo(Dir, SecondsPassed, 200, 'aim', 10) < 20) or (Dir.Length < 96)
    else
      FGame.Attack := TurnViewTo(Dir, SecondsPassed, 540, 'aim', 3) < 12;
    FViewHoldPoint := Target;
    FViewHoldUntil := FViewClock + 0.8;
    FFightWaitFor := '';
    FFightWait := 0;
    { back off from claws and bites: it keeps shooting while the monster
      walks after it (hell knights, imps up close) }
    Fists := (Slot >= 0) and (Pos('fists', LowerCase(FGame.WeaponDefs[Slot])) > 0);
    if FightTactics and (Dir.Length < FightBackOffDist) and not Fists then
    begin
      Back := Vector3(-Dir.X, 0, -Dir.Z);
      if Back.Length > 0.01 then
      begin
        Back := Back.Normalize;
        NewEye := Camera.Translation + Back * (FightBackOffSpeed * Min(SecondsPassed, 0.1));
        if CanMoveTo(NewEye, Back) then
        begin
          Camera.Translation := NewEye;
          FFightAnchor := NewEye;
        end;
      end;
    end;
    { sidestep: fireballs and bursts aimed at where it stood miss }
    Side := TVector3.CrossProduct(Dir, Vector3(0, 1, 0));
    if Side.Length > 0.01 then
    begin
      Side := Side.Normalize * FFightSide;
      NewEye := Camera.Translation + Side * (FightStrafeSpeed * Min(SecondsPassed, 0.1));
      if (PointsDistance(NewEye, FFightAnchor) > FightStrafeReach) or
         (FightTactics and not CanMoveTo(NewEye, Side)) or
         MainViewport.Items.WorldSegmentCollision(Camera.Translation, NewEye + Side * (PlayerRadius + 8)) then
        FFightSide := -FFightSide
      else
        Camera.Translation := NewEye;
    end;
    { the hunt with only the fists: close in and punch (the hunt's route
      got there and backed off again, until it gave up) }
    if Fists and FHunt and (FHuntTarget <> '') then
    begin
      Close := Vector3(Dir.X, 0, Dir.Z);
      if Close.Length > 40 then
      begin
        Close := Close.Normalize;
        NewEye := Camera.Translation + Close * (FightBackOffSpeed * Min(SecondsPassed, 0.1));
        if CanMoveTo(NewEye, Close) then
        begin
          Camera.Translation := NewEye;
          FFightAnchor := NewEye;
        end;
      end;
      FRouteLastEye := Camera.Translation;
      Exit(True);
    end;
    FRouteLastEye := Camera.Translation;
    { with only the fists it can't wait for the monster: it walks on }
    Exit(not Fists);
  end;
  FFightTarget := '';
  FFightOnTarget := 0;

  { a chaser out of sight (around a corner, behind): wait for it facing its
    way, so the ones after the player come one by one, not in a crowd at
    the next stop (the walk is faster than they are) }
  if FightTactics and (FFightTime >= FFightSkipUntil) and
     FGame.FightThreat(Camera.Translation, FightWaitDist, FFightIgnore + FFightWaitIgnore, Target, TargetName) then
  begin
    { the wait counts on when the nearest threat changes: two trites taking
      turns being the nearest kept it waiting for hours (caverns1) }
    if TargetName <> FFightWaitFor then
    begin
      FFightWaitFor := TargetName;
      WritelnLog('GameViewPlay', 'Fight: waiting for %s at %s (out of sight, %.0f away)',
        [TargetName, CgeToD3(Target).ToString, PointsDistance(Target, Camera.Translation)]);
    end;
    FFightWait := FFightWait + SecondsPassed;
    if FFightWait <= FightWaitMax then
    begin
      Dir := Target - Camera.Translation;
      Dir.Y := 0;
      TurnViewTo(Dir, SecondsPassed, 240, 'wait', 3);
      FViewHoldPoint := Camera.Translation + Dir;
      FViewHoldUntil := FViewClock + 0.8;
      FRouteLastEye := Camera.Translation;
      Exit(True);
    end;
    { it doesn't come: walk on (a second for the next one) }
    FFightWaitIgnore := FFightWaitIgnore + ',' + TargetName;
    FFightWaitFor := '';
    FFightWait := FightWaitMax - 1;
  end else
  begin
    FFightWaitFor := '';
    FFightWait := 0;
  end;

  { quiet: save now and then }
  FFightSinceSave := FFightSinceSave + SecondsPassed;
  if (FFightSinceSave >= FightSaveEvery) and not FGame.CinematicActive and (FGame.Health > 0) and
     ((FGame.Health >= FightSaveHealth) or (FFightSinceSave >= FightSaveAnyway) or not FFightHasSave) and
     (not FFightGod or (FRouteWalked >= FFightGodUntil)) and FightSafeToSave then
  begin
    FFightSinceSave := 0;
    SaveGame(FightSaveName);
    FFightHasSave := True;
    Inc(FFightSaves);
    { the deaths count on until the walk is past their place: a save
      before it is no progress (the run died there once per save) }
    if FRouteWalked > FFightDeathWalked then
    begin
      FFightDeathsHere := 0;
      FFightDeathWalked := 0;
    end;
    FFightRoute := Copy(FRoute);
    FFightSeg := FRouteSeg;
    FFightAlong := FRouteAlong;
    FFightWalked := FRouteWalked;
    if FFightGod then
    begin
      FFightGod := False;
      FGame.God := False;
    end;
  end;
end;

function TViewPlay.FightSafeToSave: Boolean;
var
  What: String;
  D: Single;
  N: TVector3;
begin
  { not in a hurt volume (a save in a kill pit dies on every load: Mars
    City Underground looped there) and, walking, on a floor (not falling) }
  Result := not FGame.HazardAt(Camera.Translation - Vector3(0, FGame.EyeHeight, 0), 0, What) and
    (not FRouteWalkMode or FGame.WorldHit(Camera.Translation, Vector3(0, -1, 0), FGame.EyeHeight + 24, D, N)) and
    { inside the map's areas (cpuboss: a save on top of a wall, outside
      them, fell 6000 units into the void on every load) }
    (Map.AreaAt(Camera.Translation) >= 0);
end;

function TViewPlay.WalkRoute(const SecondsPassed: Single; const Speed, ShotEvery: Single): Boolean;
var
  Step, SegLen, Ahead, Yaw, D: Single;
  P, Q, Dir, OldDir: TVector3;
  Seg: Integer;
  Along: Single;
  Hop: TD3PointArray;

  function ShakeWho: String;
  var
    W: String;
  begin
    Result := '';
    for W in ['walk', 'route', 'aim', 'wait', 'hold'] do
      if Pos(W, FViewShakeBy) > 0 then
        Result := Result + ' ' + W;
    FViewShakeBy := '';
  end;

  procedure MeasureViewTurn;
  var
    A, B: TVector3;
    Turn: Single;
  begin
    B := CgeToD3(Camera.Direction);
    FViewShakeBy := FViewShakeBy + FViewBy;
    if Length(FViewShakeBy) > 400 then
      FViewShakeBy := Copy(FViewShakeBy, 201, MaxInt);
    FViewBy := '';
    A := FViewLastDir;
    FViewLastDir := B;
    if A.IsPerfectlyZero then
      Exit;
    { signed yaw change; a big jump (a teleport, a load) isn't a turn }
    Turn := RadToDeg(ArcTan2(B.Y, B.X) - ArcTan2(A.Y, A.X));
    while Turn > 180 do
      Turn := Turn - 360;
    while Turn < -180 do
      Turn := Turn + 360;
    if Abs(Turn) > 90 then
      Exit;
    Inc(FViewFrames);
    FViewTurnSum := FViewTurnSum + Abs(Turn);
    if Abs(Turn) > 10 then
      Inc(FViewJerks);
    if (Abs(Turn) > 2) and (Abs(FViewLastTurn) > 2) and (Turn * FViewLastTurn < 0) then
    begin
      Inc(FViewReversals);
      { 8 reversals within 2 s: the view shakes here; log the place and
        what turned it }
      FViewShakeTimes[FViewShakeNext] := FViewClock;
      FViewShakeNext := (FViewShakeNext + 1) mod Length(FViewShakeTimes);
      FViewShakeBy := FViewShakeBy + FViewBy;
      if (FViewClock - FViewShakeTimes[FViewShakeNext] < 2) and (FViewClock - FViewShakeLogged > 3) then
      begin
        FViewShakeLogged := FViewClock;
        WritelnLog('GameViewPlay', 'View: shaking at %s (8 reversals in %.1f s; turned by%s; fight target "%s", waiting for "%s")',
          [(CgeToD3(Camera.Translation) - Vector3(0, 0, FGame.EyeHeight)).ToString,
           FViewClock - FViewShakeTimes[FViewShakeNext], ShakeWho, FFightTarget, FFightWaitFor]);
      end;
    end;
    if Abs(Turn) > 2 then
      FViewLastTurn := Turn;
  end;

begin
  Result := True;
  FViewClock := FViewClock + SecondsPassed;
  if Length(FRoute) >= 2 then
    MeasureViewTurn;
  if (Length(FRoute) < 2) or (FRouteMap <> MapName) then
  begin
    if FRouteMap <> MapName then
      WritelnLog('GameViewPlay', 'Route: the map changed to "%s" after %.0f units', [MapName, FRouteWalked]);
    FRoute := nil;
    FGame.RouteInvulnerable := False;
    Exit;
  end;
  { cinematics play for 2 s, then they are skipped }
  if FGame.CinematicActive then
  begin
    FRouteCinematic := FRouteCinematic + SecondsPassed;
    { a camera that a skip (game time run on fast up to its cap) didn't
      end is the game's end (Resurrection of Evil's credits after hell):
      the route is done }
    if FGame.SkipRanOut and not FGame.Skipping then
    begin
      WritelnLog('GameViewPlay', 'Route: cinematic %s never ends (the game''s end), the route stops',
        [FGame.CinematicName]);
      if FFight then
        FightSummary;
      FRoute := nil;
      FGame.RouteInvulnerable := False;
      Exit(True);
    end;
    if FRouteCinematic > 2 then
    begin
      WritelnLog('GameViewPlay', 'Route: skipping cinematic %s', [FGame.CinematicName]);
      FGame.SkipCinematic;
      FRouteCinematic := 0;
    end;
    Exit(False);
  end;
  { the game teleported the player (info_player_teleport): stand there for
    a while (its triggers fire, a fade in...), then walk back to the route }
  if (not FRouteWalkMode and (PointsDistance(Camera.Translation, FRouteLastEye) > 64)) or
     (FRouteWalkMode and (Sqr(Camera.Translation.X - FRouteLastEye.X) +
       Sqr(Camera.Translation.Z - FRouteLastEye.Z) > Sqr(96))) then
  begin
    WritelnLog('GameViewPlay', 'Route: teleported to %s, back to the route in 2 s',
      [CgeToD3(Camera.Translation).ToString]);
    FRouteHold := 2;
    FRouteLastEye := Camera.Translation;
  end;
  { given up at a place (god mode): noGod damage too, or a kill volume on
    the route (le_enpro2's, le_hell's trigger_hurt of 1000) kills it again
    and again after every load }
  FGame.RouteInvulnerable := not FFight or FFightGod;
  { on foot, fallen far below the route (a pit the route crosses on a
    platform that isn't there, a hole in the floor): logged, then put ahead
    past the gap onto a floor; checked before the fight, which can hold the
    walk while the player falls to the bottom }
  if FRouteWalkMode and (FRouteSeg < High(FRoute)) then
  begin
    SegLen := Max(0.001, PointsDistance(FRoute[FRouteSeg], FRoute[FRouteSeg + 1]));
    P := FRoute[FRouteSeg] + (FRoute[FRouteSeg + 1] - FRoute[FRouteSeg]) * (FRouteAlong / SegLen);
    Q := CgeToD3(Camera.Translation) - Vector3(0, 0, FGame.EyeHeight);
    if (Q.Z < P.Z - 400) and (Q.Z < FWalkLastFloor.Z - 400) and not FGame.PlayerDead then
    begin
      Inc(FWalkFellCount);
      WritelnLog('GameViewPlay', 'Walk: fell through the floor near %s (last on a floor at %s, now %.0f below): put ahead',
        [P.ToString, FWalkLastFloor.ToString, P.Z - Q.Z]);
      if Length(FWalkStuckSpots) < 2000 then
        FWalkStuckSpots := FWalkStuckSpots + Format('; %.0f %.0f %.0f (fell through the floor)',
          [FWalkLastFloor.X, FWalkLastFloor.Y, FWalkLastFloor.Z]);
      WalkStuck(0, True);
      Exit(False);
    end;
  end;
  if FFight and FightStep(SecondsPassed) then
    Exit(False);
  if FRouteHold > 0 then
  begin
    FRouteHold := FRouteHold - SecondsPassed;
    if FRouteHold <= 0 then
    begin
      P := CgeToD3(Camera.Translation) - Vector3(0, 0, FGame.EyeHeight);
      Q := FRoute[FRouteSeg] + (FRoute[FRouteSeg + 1] - FRoute[FRouteSeg]) *
        (FRouteAlong / Max(0.001, PointsDistance(FRoute[FRouteSeg], FRoute[FRouteSeg + 1])));
      FGame.PlayerRoute(P, Q, Hop, Along, Seg);
      { the hop, then the rest of the route from where it was left }
      FRoute := Concat(Hop, Copy(FRoute, FRouteSeg + 1, MaxInt));
      for Seg := 0 to High(FRouteMarks) do
        FRouteMarks[Seg] := FRouteMarks[Seg] - FRouteSeg - 1 + Length(Hop);
      FRouteSeg := 0;
      FRouteAlong := 0;
    end;
    FRouteLastEye := Camera.Translation;
    Exit(False);
  end;
  { at most 1/10 s of walking per frame (slow frames, loads) }
  Step := Speed * Min(SecondsPassed, 0.1);
  if FRouteWalkMode then
  begin
    { on foot the route's point goes on only while the feet keep up }
    SegLen := Max(0.001, PointsDistance(FRoute[FRouteSeg], FRoute[FRouteSeg + 1]));
    P := FRoute[FRouteSeg] + (FRoute[FRouteSeg + 1] - FRoute[FRouteSeg]) * (FRouteAlong / SegLen);
    Q := CgeToD3(Camera.Translation) - Vector3(0, 0, FGame.EyeHeight);
    { up to 100 above the feet: items on tables and shelves (the route
      visits the item's own point) }
    { right under (or over) the point it goes on whatever the height: the
      items and monsters the route visits up on shelves, ledges and in the
      air (a third of the stuck places stood under them) }
    D := Sqr(P.X - Q.X) + Sqr(P.Y - Q.Y);
    if (D > Sqr(40)) or ((D > Sqr(24)) and ((P.Z - Q.Z > 100) or (Q.Z - P.Z > 72))) then
      Step := 0;
    if FGame.WorldHit(Camera.Translation, Vector3(0, -1, 0), FGame.EyeHeight + 8, SegLen, Dir) then
      FWalkLastFloor := Q;
    if (FRouteWalked > FWalkProgressAt + 32) or (FRouteWalked < FWalkProgressAt) then
    begin
      FWalkProgressAt := FRouteWalked;
      FWalkStuck := 0;
      FWalkUsed := False;
      FWalkElevatorTries := 0;
      FWalkPutStreak := 0;
      FWalkFightHold := 0;
      FWalkRerouted := False;
      FWalkCrouch := False;
      FWalkJumpAt := 0;
    end;
    if Step = 0 then
      WalkStuck(SecondsPassed);
  end;
  while (Step > 0) and (FRouteSeg < High(FRoute)) do
  begin
    SegLen := PointsDistance(FRoute[FRouteSeg], FRoute[FRouteSeg + 1]);
    if FRouteAlong + Step < SegLen then
    begin
      FRouteAlong := FRouteAlong + Step;
      FRouteWalked := FRouteWalked + Step;
      FRouteSinceShot := FRouteSinceShot + Step;
      Step := 0;
    end else
    begin
      Step := Step - (SegLen - FRouteAlong);
      FRouteWalked := FRouteWalked + SegLen - FRouteAlong;
      FRouteSinceShot := FRouteSinceShot + SegLen - FRouteAlong;
      FRouteAlong := 0;
      Inc(FRouteSeg);
      while (FRouteNextMark <= High(FRouteMarks)) and (FRouteMarks[FRouteNextMark] <= FRouteSeg) do
      begin
        WritelnLog('GameViewPlay', 'Route: at %s (%d of %d, %.0f units)',
          [FRouteMarkNames[FRouteNextMark], FRouteNextMark + 1, Length(FRouteMarks), FRouteWalked]);
        Inc(FRouteNextMark);
      end;
    end;
  end;
  if FRouteSeg >= High(FRoute) then
  begin
    P := FRoute[High(FRoute)];
    if not FRouteWalkMode then
      PlaceCamera(D3ToCge(P), CameraYaw);
    if FFight and FHunt and HuntNext then
      Exit(False);
    WritelnLog('GameViewPlay', 'Route: done, %.0f units', [FRouteWalked]);
    WritelnLog('GameViewPlay', 'Route: view turns: %d frames, %.2f degrees a frame, %d over 10 degrees, %d reversals of turns over 2 degrees',
      [FViewFrames, FViewTurnSum / Max(1, FViewFrames), FViewJerks, FViewReversals]);
    if FFight then
      FightSummary
    else
    if FRouteWalkMode then
      WalkSummary;
    CaptureScreenshot;
    FRoute := nil;
    FGame.RouteInvulnerable := False;
    Exit;
  end;
  SegLen := Max(0.001, PointsDistance(FRoute[FRouteSeg], FRoute[FRouteSeg + 1]));
  P := FRoute[FRouteSeg] + (FRoute[FRouteSeg + 1] - FRoute[FRouteSeg]) * (FRouteAlong / SegLen);
  { look at the route 96 units ahead }
  Seg := FRouteSeg;
  Along := FRouteAlong + 96;
  while (Seg < High(FRoute)) and (Along > PointsDistance(FRoute[Seg], FRoute[Seg + 1])) do
  begin
    Along := Along - PointsDistance(FRoute[Seg], FRoute[Seg + 1]);
    Inc(Seg);
  end;
  if Seg < High(FRoute) then
    Q := FRoute[Seg] + (FRoute[Seg + 1] - FRoute[Seg]) *
      (Along / Max(0.001, PointsDistance(FRoute[Seg], FRoute[Seg + 1])))
  else
    Q := FRoute[High(FRoute)];
  Dir := Q - P;
  Yaw := CameraYaw;
  if Sqr(Dir.X) + Sqr(Dir.Y) > 1 then
    Yaw := RadToDeg(ArcTan2(Dir.Y, Dir.X));
  P := RouteAroundHazards(P, Dir, Speed * Min(SecondsPassed, 0.1));
  if FRouteWalkMode then
    WalkOnFoot(P, Yaw, Speed * Min(SecondsPassed, 0.1), SecondsPassed)
  else
  begin
    OldDir := Camera.Direction;
    PlaceCamera(D3ToCge(P), Yaw);
    Camera.SetWorldView(Camera.Translation, OldDir, Vector3(0, 1, 0));
    TurnRouteView(Yaw, SecondsPassed, 'route');
  end;
  FRouteLastEye := Camera.Translation;
  if FRouteSinceShot >= ShotEvery then
  begin
    FRouteSinceShot := 0;
    WritelnLog('GameViewPlay', 'Route: %.0f units walked, segment %d of %d', [FRouteWalked, FRouteSeg + 1, High(FRoute)]);
    CaptureScreenshot;
  end;
  Result := False;
end;

procedure TViewPlay.MemoryEnsure;
var
  I: Integer;
  L: TStringList;
  Line, Kind: String;
  Parts: TStringArray;
  V: TVector3;
  FileName: String;
begin
  if SameText(FMemMap, MapName) then
    Exit;
  FMemMap := MapName;
  FMemStuck := nil;
  FMemGiveUp := nil;
  FMemDeath := nil;
  FMemGiveUpArm := nil;
  FMemStuckUsed := 0;
  FMemGiveUpsUsed := 0;
  FileName := WalkMemoryFile(MapName);
  if not WalkMemoryOn or not FileExists(FileName) then
    Exit;
  L := TStringList.Create;
  try
    L.LoadFromFile(FileName);
    for Line in L do
    begin
      Parts := Line.Split([#9, ' '], TStringSplitOptions.ExcludeEmpty);
      if Length(Parts) < 4 then
        Continue;
      Kind := Parts[0];
      V := Vector3(StrToFloatDefDot(Parts[1], 0), StrToFloatDefDot(Parts[2], 0), StrToFloatDefDot(Parts[3], 0));
      if Kind = 'stuck' then
        FMemStuck := Concat(FMemStuck, [V])
      else if Kind = 'giveup' then
        FMemGiveUp := Concat(FMemGiveUp, [V])
      else if Kind = 'death' then
        FMemDeath := Concat(FMemDeath, [V]);
    end;
  finally
    FreeAndNil(L);
  end;
  SetLength(FMemGiveUpArm, Length(FMemGiveUp));
  for I := 0 to High(FMemGiveUpArm) do
    FMemGiveUpArm[I] := 0;
  WritelnLog('GameViewPlay', 'Walk memory: %s: %d stuck spots, %d deaths, %d give-ups from earlier runs (%s)',
    [MapName, Length(FMemStuck), Length(FMemDeath), Length(FMemGiveUp), FileName]);
end;

procedure TViewPlay.MemoryAdd(const Kind: String; const At: TVector3);
var
  FileName: String;
  F: TextFile;
begin
  FileName := WalkMemoryFile(MapName);
  try
    ForceDirectories(ExtractFileDir(FileName));
    AssignFile(F, FileName);
    if FileExists(FileName) then
      Append(F)
    else
      Rewrite(F);
    try
      Writeln(F, Kind, #9, FloatToStrDot(Round(At.X)), ' ', FloatToStrDot(Round(At.Y)), ' ', FloatToStrDot(Round(At.Z)));
    finally
      CloseFile(F);
    end;
  except
    on E: Exception do
      WritelnWarning('GameViewPlay', 'Walk memory: cannot write "%s": %s', [FileName, E.Message]);
  end;
end;

function TViewPlay.MemoryNear(const Points: TD3PointArray; const At: TVector3;
  const Radius: Single; out Index: Integer): Integer;
var
  I: Integer;
begin
  Result := 0;
  Index := -1;
  for I := 0 to High(Points) do
    if (Sqr(Points[I].X - At.X) + Sqr(Points[I].Y - At.Y) < Sqr(Radius)) and
       (Abs(Points[I].Z - At.Z) < 96) then
    begin
      Inc(Result);
      if Index < 0 then
        Index := I;
    end;
end;

procedure TViewPlay.TurnRouteView(const Yaw, SecondsPassed: Single; const Who: String);
begin
  if FViewClock < FViewHoldUntil then
    TurnViewTo(FViewHoldPoint - Camera.Translation, SecondsPassed, 360, 'hold', 3)
  else
    TurnViewTo(YawToCgeDir(Yaw), SecondsPassed, 240, Who);
end;

function TViewPlay.TurnViewTo(const Dir: TVector3; const SecondsPassed: Single;
  const DegreesPerSecond: Single; const Who: String; const DeadBand: Single): Single;
var
  Cur, Want: TVector3;
  CurYaw, CurPitch, WantYaw, WantPitch, DYaw, DPitch, Err, Turn, T: Single;
begin
  Result := 0;
  if Pos(Who, FViewBy) = 0 then
    FViewBy := FViewBy + ' ' + Who;
  if Dir.Length < 0.0001 then
    Exit;
  if GetEnvironmentVariable('CD3_SMOOTH_TURN') = '0' then
  begin
    Camera.SetWorldView(Camera.Translation, Dir.Normalize, Vector3(0, 1, 0));
    Exit;
  end;
  Cur := CgeToD3(Camera.Direction);
  Want := CgeToD3(Dir.Normalize);
  CurYaw := RadToDeg(ArcTan2(Cur.Y, Cur.X));
  CurPitch := RadToDeg(ArcTan2(Cur.Z, Sqrt(Sqr(Cur.X) + Sqr(Cur.Y))));
  WantYaw := RadToDeg(ArcTan2(Want.Y, Want.X));
  WantPitch := RadToDeg(ArcTan2(Want.Z, Sqrt(Sqr(Want.X) + Sqr(Want.Y))));
  DYaw := WantYaw - CurYaw;
  while DYaw > 180 do
    DYaw := DYaw - 360;
  while DYaw < -180 do
    DYaw := DYaw + 360;
  DPitch := WantPitch - CurPitch;
  Err := Sqrt(Sqr(DYaw) + Sqr(DPitch));
  Result := Err;
  { close enough: no chasing small wobbles (a monster's center moving
    with its anims, the strafe) }
  if Err < Max(0.05, DeadBand) then
    Exit;
  { eases in (a fraction of what is left a frame), at most the rate: small
    corrections are gentle, big turns don't take long }
  T := Min(SecondsPassed, 0.1);
  Turn := Min(DegreesPerSecond * T, Max(Err * (1 - Exp(-10 * T)), 30 * T));
  if Turn >= Err then
    Turn := Err;
  CurYaw := DegToRad(CurYaw + DYaw * Turn / Err);
  CurPitch := DegToRad(CurPitch + DPitch * Turn / Err);
  Camera.SetWorldView(Camera.Translation,
    D3ToCge(Vector3(Cos(CurPitch) * Cos(CurYaw), Cos(CurPitch) * Sin(CurYaw), Sin(CurPitch))),
    Vector3(0, 1, 0));
  Result := Err - Turn;
end;

procedure TViewPlay.WalkOnFoot(const Goal: TVector3; const Yaw, MaxStep, SecondsPassed: Single);
var
  Feet, D, Move, From, Side: TVector3;
  Moved, Angle: Single;
  I: Integer;

  function TryMove(const M: TVector3): Boolean;
  var
    NewPos: TVector3;
  begin
    Result := Map.World.WorldMoveAllowed(Camera.Translation, Camera.Translation + M, NewPos,
      True, WalkNavigation.Radius, TBox3D.Empty, TBox3D.Empty, False);
    if Result then
      Camera.Translation := NewPos;
  end;

begin
  Feet := CgeToD3(Camera.Translation) - Vector3(0, 0, FGame.EyeHeight);
  D := Goal - Feet;
  D.Z := 0;
  if D.Length > 0.5 then
  begin
    { Doom 3 (x, y) to CGE (x, -z); along walls when straight on is blocked }
    D := D.Normalize * Min(MaxStep, D.Length);
    Move := Vector3(D.X, 0, -D.Y);
    From := Camera.Translation;
    if not TryMove(Move) then
      if not TryMove(Vector3(Move.X, 0, 0)) then
        TryMove(Vector3(0, 0, Move.Z));
    { hardly on (a corner the route's line cuts): 45 and 90 degrees to
      either side, the first that gets on }
    Moved := Sqr(Camera.Translation.X - From.X) + Sqr(Camera.Translation.Z - From.Z);
    if Moved < Sqr(0.3 * Move.Length) then
      for I := 1 to 4 do
      begin
        Angle := Pi / 4 * ((I + 1) div 2) * (1 - 2 * (I mod 2));
        Side := Vector3(Move.X * Cos(Angle) - Move.Z * Sin(Angle), 0, Move.X * Sin(Angle) + Move.Z * Cos(Angle));
        Camera.Translation := From;
        if TryMove(Side) then
          Break;
        Camera.Translation := From;
      end;
  end;
  TurnRouteView(Yaw, SecondsPassed, 'walk');
end;

procedure TViewPlay.WalkStuck(const SecondsPassed: Single; const Fell: Boolean);
const
  { after this long it uses what is near (a door, an elevator); after
    PutAheadAfter (longer after an elevator was called) it is put ahead }
  UseAfter = 3;
  PutAheadAfter = 10;
  RememberedPutAheadAfter = 2.5;
  ElevatorWait = 20;
  PutAheadBy = 96;
  FightHoldMax = 60;
  FightHoldDist = 700;
var
  HoldAt: TVector3;
  HoldName: String;
  Feet, P, Ahead: TVector3;
  Mover: TD3Mover;
  El: TD3Elevator;
  I, BestFloor, FeetFloor: Integer;
  Reason, GoalName: String;
  D, BestD, Along, SegLen, Extra: Single;
  Seg: Integer;
  Near: TBox3D;
  N: TVector3;
  Hop: TD3PointArray;
  Remembered, Looping, HuntFound: Boolean;
  LoopCount, UsedBefore: Integer;
  HuntAt: TVector3;
  Mon: TD3Monster;
  Above: TVector3;
  CurZ: Single;

  { the route's point Dist units further on }
  function RouteAhead(const Dist: Single): TVector3;
  begin
    Seg := FRouteSeg;
    Along := FRouteAlong + Dist;
    while (Seg < High(FRoute)) and (Along > PointsDistance(FRoute[Seg], FRoute[Seg + 1])) do
    begin
      Along := Along - PointsDistance(FRoute[Seg], FRoute[Seg + 1]);
      Inc(Seg);
    end;
    if Seg >= High(FRoute) then
      Exit(FRoute[High(FRoute)]);
    SegLen := Max(0.001, PointsDistance(FRoute[Seg], FRoute[Seg + 1]));
    Result := FRoute[Seg] + (FRoute[Seg + 1] - FRoute[Seg]) * (Along / SegLen);
  end;

  { the floor's height under a Doom 3 point (from just above it: from 48
    above, a point floating under a ceiling found the roof's top), only
    with the eye inside the map's areas there }
  function FloorUnder(const At: TVector3; out FloorZ: Single): Boolean;
  var
    Dist: Single;
    Normal: TVector3;
    Start: Integer;
  begin
    { from just above the point; then from under it (the objectives and
      items floating under a ceiling: from above, the ray started inside
      the ceiling and found its underside), down to 224 below }
    for Start := 0 to 1 do
    begin
      Result := FGame.WorldHit(D3ToCge(At) + Vector3(0, 8 - 32 * Start, 0), Vector3(0, -1, 0),
        104 + 96 * Start, Dist, Normal);
      if not Result then
        Continue;
      FloorZ := At.Z + 8 - 32 * Start - Dist;
      { room for the player over it, the eye inside the map's areas (ray
        casts ignore the faces' sides) }
      Result := not FGame.WorldHit(D3ToCge(Vector3(At.X, At.Y, FloorZ + 1)), Vector3(0, 1, 0),
        FGame.EyeHeight + 4, Dist, Normal) and
        (Map.AreaAt(D3ToCge(Vector3(At.X, At.Y, FloorZ + FGame.EyeHeight))) >= 0);
      if Result then
        Exit;
    end;
  end;

begin
  FWalkStuck := FWalkStuck + SecondsPassed;
  if Fell then
    FWalkStuck := PutAheadAfter;
  Feet := CgeToD3(Camera.Translation) - Vector3(0, 0, FGame.EyeHeight);
  P := RouteAhead(0);
  { an earlier run had to put it ahead here: no waiting for doors and
    elevators, put ahead after 2.5 s }
  MemoryEnsure;
  Remembered := not Fell and (MemoryNear(FMemStuck, Feet, 64, I) > 0);
  { the third detour at this spot in 4 minutes: going round in a loop }
  Looping := False;
  if not Fell and (FWalkStuck >= 2) and not FWalkRerouted then
  begin
    LoopCount := 0;
    for I := 0 to High(FWalkDetours) do
      if (FViewClock - FWalkDetourTimes[I] < 240) and (PointsDistance(FWalkDetours[I], Feet) < 128) then
        Inc(LoopCount);
    Looping := LoopCount >= 3;
    if Looping then
    begin
      Inc(FWalkLoops);
      WritelnLog('GameViewPlay', 'Walk: going round in a loop at %s (%d detours here in 4 minutes): put ahead',
        [Feet.ToString, LoopCount]);
      FWalkDetours := nil;
      FWalkDetourTimes := nil;
      FWalkPutStreak := Max(FWalkPutStreak, 3);
      Remembered := True;
    end;
  end;
  if not Fell then
  begin
    { a ledge up to the jump's height ahead: jump (every 1.5 s) }
    if (FWalkStuck >= 0.5) and (FWalkStuck - FWalkJumpAt >= 1.5) and
       (P.Z - Feet.Z > 16) and (P.Z - Feet.Z < 68) and
       (Sqr(P.X - Feet.X) + Sqr(P.Y - Feet.Y) < Sqr(96)) then
    begin
      FWalkJumpAt := FWalkStuck;
      { TCastleWalkNavigation.Jump is strict private: its key }
      if (WalkNavigation.Input_Jump.Key1 <> keyNone) and
         WalkNavigation.Press(InputKey(TVector2.Zero, WalkNavigation.Input_Jump.Key1, '', [])) then
        WritelnLog('GameViewPlay', 'Walk: jumping %.0f up at %s', [P.Z - Feet.Z, Feet.ToString]);
    end;
    { blocked on the flat: a vent or a low pipe, crouch (the game stands up
      again where there is room) }
    if (FWalkStuck >= 1.5) and not FWalkCrouch and (Abs(P.Z - Feet.Z) < 16) and
       not MainViewport.Items.WorldSegmentCollision(
         Camera.Translation - Vector3(0, FGame.EyeHeight - 20, 0), D3ToCge(P) + Vector3(0, 20, 0)) then
    begin
      FWalkCrouch := True;
      WritelnLog('GameViewPlay', 'Walk: crouching at %s', [Feet.ToString]);
    end;
    { off the line the route takes (pushed off by a corner, a monster, a
      ledge): a new route from the feet along the AAS to the route's point
      128 further, once a place }
    if (FWalkStuck >= 2) and not FWalkRerouted and not Looping and
       ((PointsDistance(Feet, FWalkRerouteSpot) > 96) or (FWalkRerouteTries < 2)) then
    begin
      FWalkRerouted := True;
      { at most twice a place: a detour that comes back here doesn't help }
      if PointsDistance(Feet, FWalkRerouteSpot) > 96 then
      begin
        FWalkRerouteSpot := Feet;
        FWalkRerouteTries := 0;
      end;
      Inc(FWalkRerouteTries);
      Ahead := RouteAhead(128);
      FGame.PlayerRoute(Feet, Ahead, Hop, D, I);
      if Length(Hop) >= 3 then
      begin
        WritelnLog('GameViewPlay', 'Walk: around the corner at %s: %d points to %s',
          [Feet.ToString, Length(Hop), Ahead.ToString]);
        FRoute := Concat(Hop, Copy(FRoute, Seg + 1, MaxInt));
        for I := 0 to High(FRouteMarks) do
          FRouteMarks[I] := FRouteMarks[I] - Seg - 1 + Length(Hop);
        FRouteSeg := 0;
        FRouteAlong := 0;
        FRouteLastEye := Camera.Translation;
        Inc(FWalkReroutes);
        FWalkDetours := Concat(FWalkDetours, [Feet]);
        FWalkDetourTimes := Concat(FWalkDetourTimes, [FViewClock]);
        if Length(FWalkDetours) > 32 then
        begin
          Delete(FWalkDetours, 0, 1);
          Delete(FWalkDetourTimes, 0, 1);
        end;
        Exit;
      end;
    end;
  end;
  if Remembered and not Looping then
  begin
    if FWalkStuck < RememberedPutAheadAfter then
      Exit;
  end else
  if not Looping and (FWalkStuck < UseAfter) then
    Exit;
  if not FWalkUsed and not Fell and not Remembered then
  begin
    FWalkUsed := True;
    UsedBefore := FWalkDoorsOpened + FWalkElevatorsCalled;
    { a door near the feet that touching doesn't open }
    Near := Box3DAroundPoint(Camera.Translation, 192);
    for Mover in FGame.Movers do
      if (Mover.Kind = mkDoor) and (Mover.State = dsClosed) and (Mover.Brush.Scene <> nil) and
         Mover.Brush.Scene.WorldBoundingBox.Collides(Near) then
      begin
        if Mover.Locked then
          Reason := 'locked'
        else if (Mover.Requires <> '') and (FGame.Carried.IndexOf(D3LangString(Mover.Requires)) < 0) then
          Reason := 'needs ' + Mover.Requires
        else if Mover.Disabled then
          Reason := 'disabled by its elevator'
        else if Mover.NoTouch then
          Reason := 'no_touch: a button, a GUI or a script opens it'
        else
          Reason := 'didn''t open on touch';
        WritelnLog('GameViewPlay', 'Walk: door %s closed (%s) at %s: opened for the walk',
          [Mover.Brush.Entity.Name, Reason, Feet.ToString]);
        Mover.Locked := False;
        FGame.OpenTeam(Mover);
        Inc(FWalkDoorsOpened);
      end;
    { an elevator: to the floor nearest the height the route goes to }
    for El in FGame.Elevators do
    begin
      if Length(El.Floors) = 0 then
        Continue;
      BestD := MaxSingle;
      for I := 0 to High(El.Floors) do
        BestD := Min(BestD, Sqr(El.Floors[I].Pos.X - Feet.X) + Sqr(El.Floors[I].Pos.Y - Feet.Y));
      if BestD > Sqr(256) then
        Continue;
      { the height the route goes to: the point of the next 800 units
        farthest up or down (at 400 it was still at the elevator's
        bottom, and the elevator was called to the floor it was at) }
      Ahead := RouteAhead(0);
      for I := 1 to 25 do
      begin
        Above := RouteAhead(32 * I);
        if Abs(Above.Z - Feet.Z) > Abs(Ahead.Z - Feet.Z) then
          Ahead := Above;
      end;
      BestFloor := -1;
      BestD := MaxSingle;
      for I := 0 to High(El.Floors) do
      begin
        D := Abs(El.Floors[I].Pos.Z - Ahead.Z);
        if D < BestD then
        begin
          BestD := D;
          BestFloor := El.Floors[I].Floor;
        end;
      end;
      { the floor it is at, with the route going far up or down: the
        nearest floor that way }
      if (BestFloor = El.CurrentFloor) and (Abs(Ahead.Z - Feet.Z) > 64) and
         (El.FloorIndex(El.CurrentFloor) >= 0) then
      begin
        CurZ := El.Floors[El.FloorIndex(El.CurrentFloor)].Pos.Z;
        BestD := MaxSingle;
        for I := 0 to High(El.Floors) do
        begin
          D := (El.Floors[I].Pos.Z - CurZ) * Sign(Ahead.Z - Feet.Z);
          if (D > 16) and (D < BestD) then
          begin
            BestD := D;
            BestFloor := El.Floors[I].Floor;
          end;
        end;
      end;
      { its cab at another floor than the feet: called to the feet's floor
        first (delta2a: the cab waited upstairs at the floor the route
        went to, the walk called it there again and again from below) }
      FeetFloor := -1;
      BestD := MaxSingle;
      for I := 0 to High(El.Floors) do
        if Abs(El.Floors[I].Pos.Z - Feet.Z) < BestD then
        begin
          BestD := Abs(El.Floors[I].Pos.Z - Feet.Z);
          FeetFloor := El.Floors[I].Floor;
        end;
      if (FeetFloor >= 0) and (FeetFloor <> El.CurrentFloor) and (BestFloor = El.CurrentFloor) then
        BestFloor := FeetFloor;
      if (BestFloor >= 0) and (FWalkElevatorTries < 2) then
      begin
        Inc(FWalkElevatorTries);
        WritelnLog('GameViewPlay', 'Walk: calling elevator %s to floor %d (at %d) at %s',
          [El.Entity.Name, BestFloor, El.CurrentFloor, Feet.ToString]);
        FGame.ElevatorChangeFloor(El, BestFloor);
        Inc(FWalkElevatorsCalled);
        { on it: the floor it is at opens its doors, the next call (after
          the wait) moves it }
        FWalkStuck := UseAfter - ElevatorWait + PutAheadAfter;
        FWalkUsed := (BestFloor = El.CurrentFloor) or (FWalkElevatorTries >= 2);
      end;
    end;
    { nothing to use, and the route goes straight up past any jump (a lift
      a script or a call panel moves, a ledge, a pit's wall): no waiting
      the whole PutAheadAfter (half the stuck spots, 10 s each) }
    if (FWalkDoorsOpened + FWalkElevatorsCalled = UsedBefore) and (P.Z - Feet.Z > 100) and
       (Sqr(P.X - Feet.X) + Sqr(P.Y - Feet.Y) < Sqr(64)) then
    begin
      WritelnLog('GameViewPlay', 'Walk: the route goes %.0f straight up at %s, nothing to use: put ahead in 1 s',
        [P.Z - Feet.Z, Feet.ToString]);
      FWalkStuck := PutAheadAfter - 1;
    end;
    Exit;
  end;
  if (FWalkStuck < PutAheadAfter) and not Remembered then
    Exit;
  { a monster at the player that it can see: no put ahead away from the
    fight (delta4: put ahead through the door the script locked, the two
    hell knights it must kill to be teleported on were left behind, the
    walk went on to the level's end over a gap), up to FightHoldMax }
  if not Fell and FFight and not FFightGod and (FWalkFightHold < FightHoldMax) and
     FGame.FightTarget(Camera.Translation, FightHoldDist, FFightIgnore, HoldAt, HoldName) then
  begin
    if FWalkFightHold = 0 then
      WritelnLog('GameViewPlay', 'Walk: stuck at %s while fighting %s: no put ahead for up to %.0f s',
        [Feet.ToString, HoldName, FightHoldMax]);
    FWalkFightHold := FWalkFightHold + SecondsPassed;
    Exit;
  end;
  FWalkFightHold := 0;
  { it can't get on: logged, then put ahead past the spot }
  if Fell then
    Reason := 'fell'
  else if MainViewport.Items.WorldSegmentCollision(Camera.Translation,
    D3ToCge(P) + Vector3(0, FGame.EyeHeight, 0)) then
    Reason := 'a wall between'
  else if P.Z - Feet.Z > 40 then
    Reason := Format('%.0f up', [P.Z - Feet.Z])
  else if Feet.Z - P.Z > 72 then
    Reason := Format('%.0f down (fell off)', [Feet.Z - P.Z])
  else
    Reason := 'blocked';
  GoalName := '';
  if FRouteNextMark <= High(FRouteMarkNames) then
    GoalName := FRouteMarkNames[FRouteNextMark]
  else if FHuntTarget <> '' then
    GoalName := FHuntTarget;
  if not Fell then
  begin
    Inc(FWalkStuckCount);
    if Remembered then
    begin
      Inc(FMemStuckUsed);
      WritelnLog('GameViewPlay', 'Walk: stuck at a remembered spot %s (%d times in earlier runs) for %.1f s, the route''s point %s (%s, on the way to %s, %.0f units): put ahead',
        [Feet.ToString, MemoryNear(FMemStuck, Feet, 64, I), FWalkStuck, P.ToString, Reason, GoalName, FRouteWalked]);
    end else
      WritelnLog('GameViewPlay', 'Walk: stuck at %s for %.0f s, the route''s point %s (%s, on the way to %s, %.0f units): put ahead',
        [Feet.ToString, FWalkStuck, P.ToString, Reason, GoalName, FRouteWalked]);
    MemoryAdd('stuck', Feet);
    if Length(FWalkStuckSpots) < 2000 then
      FWalkStuckSpots := FWalkStuckSpots + Format('; %.0f %.0f %.0f (%s)', [Feet.X, Feet.Y, Feet.Z, Reason]);
  end;
  { put ahead near here before, in the last 15 minutes: the route came
    back, so much further each time (4, 16, 64 times) }
  LoopCount := 0;
  for I := 0 to High(FWalkPuts) do
    if (FViewClock - FWalkPutTimes[I] < 900) and (PointsDistance(FWalkPuts[I], Feet) < 256) then
      Inc(LoopCount);
  if (LoopCount > 0) and (FWalkPutStreak < 2 * LoopCount) then
  begin
    WritelnLog('GameViewPlay', 'Walk: put ahead near %s %d times in 15 minutes: %.0f units on',
      [Feet.ToString, LoopCount, PutAheadBy * (1 shl Min(2 * LoopCount, 6)) * 1.0]);
    FWalkPutStreak := 2 * LoopCount;
  end;
  FWalkPuts := Concat(FWalkPuts, [Feet]);
  FWalkPutTimes := Concat(FWalkPutTimes, [FViewClock]);
  if Length(FWalkPuts) > 64 then
  begin
    Delete(FWalkPuts, 0, 1);
    Delete(FWalkPutTimes, 0, 1);
  end;
  { stuck again right after: further each time (a gap in the route, where
    the AAS found no way, is one long straight line) }
  Ahead := RouteAhead(PutAheadBy * (1 shl Min(FWalkPutStreak, 6)));
  Inc(FWalkPutStreak);
  { a point with a floor under it (not one of the items up in the air the
    route visits, not over a pit), up to 512 units further (1024 after a
    fall: the gap can be wide); the feet on the floor's surface }
  Extra := 0;
  while (Extra < 512 * (1 + Ord(Fell))) and (not FloorUnder(Ahead, D) or
    FGame.HazardAt(D3ToCge(Ahead), 16, Reason)) do
  begin
    Extra := Extra + 64;
    Ahead := RouteAhead(PutAheadBy * (1 shl Min(FWalkPutStreak - 1, 6)) + Extra);
  end;
  { none: on along the route to the first point with a floor (delta4's
    route is mostly gaps over a shaft: a point in the air dropped the player
    to the bottom, the fall put it ahead again, three times to the level's
    end); only past 4096 units the route's point as it is }
  if not FloorUnder(Ahead, D) then
  begin
    D := Extra;
    while (Extra < 4096) and (not FloorUnder(Ahead, CurZ) or
      FGame.HazardAt(D3ToCge(Ahead), 16, Reason)) do
    begin
      Extra := Extra + 64;
      Ahead := RouteAhead(PutAheadBy * (1 shl Min(FWalkPutStreak - 1, 6)) + Extra);
    end;
    { then the rest of the route, in bigger steps }
    while (Extra < 65536) and (Seg < High(FRoute)) and (not FloorUnder(Ahead, CurZ) or
      FGame.HazardAt(D3ToCge(Ahead), 16, Reason)) do
    begin
      Extra := Extra + 128;
      Ahead := RouteAhead(PutAheadBy * (1 shl Min(FWalkPutStreak - 1, 6)) + Extra);
    end;
    if FloorUnder(Ahead, CurZ) then
      WritelnLog('GameViewPlay', 'Walk: the first floor ahead is %.0f units on', [Extra - D])
    else
    begin
      { no floor anywhere on the rest of the route (delta4: the rest is
        over a shaft, to a room only a teleport reaches; three falls of
        1000 units put the player at the level's end, past the hell
        knights): on the last floor, the route's end left to the map }
      WritelnLog('GameViewPlay', 'Walk: no floor on the rest of the route from %s: back to the last floor %s, the route ends here',
        [Feet.ToString, FWalkLastFloor.ToString]);
      if Fell or (Feet.Z < FWalkLastFloor.Z - 72) then
      begin
        PlaceCamera(D3ToCge(FWalkLastFloor + Vector3(0, 0, 1)), CameraYaw);
        WalkNavigation.CancelFalling;
      end;
      FRouteSeg := High(FRoute);
      FRouteAlong := 0;
      FRouteLastEye := Camera.Translation;
      FWalkStuck := 0;
      FWalkProgressAt := FRouteWalked;
      Exit;
    end;
  end;
  { a hunted monster over no floor (delta2b: an imp's place in the air over
    a shaft, the player put there fell to its bottom 57 times): back on the
    last floor, the hunt gives it up }
  { the hunted monster's own place (not the route's end: a back off ends
    160 away from it, where cpuboss gave up Sabaoth) }
  HuntAt := TVector3.Zero;
  HuntFound := False;
  if FHuntTarget <> '' then
    for Mon in FGame.Monsters do
      if SameText(Mon.Model.Entity.Name, FHuntTarget) then
      begin
        HuntAt := Mon.Position;
        HuntFound := True;
      end;
  if not FloorUnder(Ahead, D) and HuntFound and (FRouteNextMark > High(FRouteMarkNames)) and
     (not FGame.WorldHit(HuntAt + Vector3(0, 8, 0), Vector3(0, -1, 0), 600, D, N) or
      { or outside the map's areas (cpuboss: an imp in the void beside the
        boss's room, 11 falls) }
      (Map.AreaAt(HuntAt + Vector3(0, 32, 0)) < 0)) then
  begin
    { only when the monster's own place has no floor within 600 below: a
      gap on the way (cpuboss: a shaft before the boss's room) is no reason
      to give up Sabaoth and six more }
    WritelnLog('GameViewPlay', 'Walk: no floor on the way to the hunted %s: back to %s, given up',
      [FHuntTarget, FWalkLastFloor.ToString]);
    FHuntDone := FHuntDone + ',' + FHuntTarget;
    if Fell then
    begin
      PlaceCamera(D3ToCge(FWalkLastFloor + Vector3(0, 0, 1)), CameraYaw);
      WalkNavigation.CancelFalling;
    end;
    FRouteSeg := High(FRoute);
    FRouteAlong := 0;
    FRouteLastEye := Camera.Translation;
    FWalkStuck := 0;
    FWalkProgressAt := FRouteWalked;
    Exit;
  end;
  if FloorUnder(Ahead, D) then
    Ahead.Z := D + 1;
  FRouteSeg := Seg;
  FRouteAlong := Along;
  FRouteWalked := FRouteWalked + PutAheadBy * (1 shl Min(FWalkPutStreak - 1, 6)) + Extra;
  if not FloorUnder(Ahead, D) then
    WritelnLog('GameViewPlay', 'Walk: no floor found ahead, put at the route''s point %s', [Ahead.ToString]);
  PlaceCamera(D3ToCge(Ahead), CameraYaw);
  WalkNavigation.CancelFalling;
  FRouteLastEye := Camera.Translation;
  FWalkStuck := 0;
  FWalkUsed := False;
  FWalkElevatorTries := 0;
  FWalkRerouted := False;
  FWalkCrouch := False;
  FWalkJumpAt := 0;
  FWalkProgressAt := FRouteWalked;
end;

function TViewPlay.FightHazard(const Eye: TVector3; const Margin: Single; out What: String): Boolean;
begin
  What := '';
  { in god mode (given up there) nothing hurts it: the hazards don't count }
  Result := FightTactics and FFight and not FFightGod and
    FGame.HazardAt(Eye - Vector3(0, FGame.EyeHeight, 0), Margin, What);
end;

function TViewPlay.HazardPassed(const Eye: TVector3): Boolean;
begin
  { hazards near the place the walk goes through (a group of barrels) }
  Result := (FViewClock < FHazardPassUntil) and (PointsDistance(Eye, FHazardPassAt) < 160);
end;

function TViewPlay.RouteAroundHazards(const P, Dir: TVector3; const Step: Single): TVector3;
const
  { looks this far ahead along the route, tries this far to the side }
  AheadDist = 64;
  SideStep = 24;
  SideSteps = 8;
var
  Ahead, Side, Off, C, N: TVector3;
  What, W: String;
  I, S: Integer;
  Dist: Single;
  Found: Boolean;

  function Hazard(const Feet: TVector3; const Margin: Single; out Name: String): Boolean;
  begin
    Result := FightHazard(D3ToCge(Feet) + Vector3(0, FGame.EyeHeight, 0), Margin, Name);
    { the one the walk goes through doesn't count }
    if Result and HazardPassed(D3ToCge(Feet) + Vector3(0, FGame.EyeHeight, 0)) then
      Result := False;
  end;

begin
  Ahead := Vector3(Dir.X, Dir.Y, 0);
  if Ahead.Length > 0.01 then
    Ahead := Ahead.Normalize
  else
    Ahead := TVector3.Zero;
  if not (FightTactics and FFight and not FFightGod) then
    FRouteOffsetGoal := TVector3.Zero
  else if Hazard(P + FRouteOffsetGoal, 4, What) or Hazard(P + FRouteOffsetGoal + Ahead * AheadDist, 4, What) then
  begin
    { a way to the side: the nearest one with a floor that the route's eye
      sees }
    Side := Vector3(-Ahead.Y, Ahead.X, 0);
    if Side.Length < 0.01 then
      Side := Vector3(1, 0, 0);
    Found := False;
    Off := TVector3.Zero;
    for I := 1 to SideSteps do
    begin
      for S := 0 to 1 do
      begin
        Off := Side * (I * SideStep * (1 - 2 * S));
        C := P + Off;
        if Hazard(C, 8, W) or Hazard(C + Ahead * AheadDist, 8, W) or
           MainViewport.Items.WorldSegmentCollision(D3ToCge(P) + Vector3(0, FGame.EyeHeight, 0),
             D3ToCge(C) + Vector3(0, FGame.EyeHeight, 0)) or
           not FGame.WorldHit(D3ToCge(C) + Vector3(0, 8, 0), Vector3(0, -1, 0), 64, Dist, N) then
          Continue;
        Found := True;
        Break;
      end;
      if Found then
        Break;
    end;
    if Found then
    begin
      FRouteOffsetGoal := Off;
      if What <> FRouteHazardLogged then
        WritelnLog('GameViewPlay', 'Route: around %s at %s (%.0f to the side)', [What, P.ToString, Off.Length]);
    end else
    begin
      if What <> FRouteHazardLogged then
        WritelnLog('GameViewPlay', 'Route: through %s at %s (no way around)', [What, P.ToString]);
      FHazardPassAt := D3ToCge(P) + Vector3(0, FGame.EyeHeight, 0);
      FHazardPassUntil := FViewClock + 8;
    end;
    FRouteHazardLogged := What;
  end else
  if not FRouteOffsetGoal.IsPerfectlyZero then
  begin
    { back onto the route where that is safe }
    if not Hazard(P, 8, W) and not Hazard(P + Ahead * AheadDist, 8, W) then
      FRouteOffsetGoal := TVector3.Zero;
  end;
  { to the side, the route doesn't go on (its next point is among the
    barrels, a wall at the side): through the hazards after all }
  if FRouteOffsetGoal.IsPerfectlyZero or (FRouteWalked > FDetourWalked + 16) then
  begin
    FDetourWalked := FRouteWalked;
    FDetourSince := FViewClock;
  end else
  if FViewClock - FDetourSince > 2 then
  begin
    WritelnLog('GameViewPlay', 'Route: no way past %s to the side at %s: through it', [FRouteHazardLogged, P.ToString]);
    FHazardPassAt := D3ToCge(P) + Vector3(0, FGame.EyeHeight, 0);
    FHazardPassUntil := FViewClock + 8;
    FRouteOffsetGoal := TVector3.Zero;
    FDetourWalked := FRouteWalked;
    FDetourSince := FViewClock;
  end;
  { towards the goal at the walk's speed (a jump would look like a
    teleport) }
  C := FRouteOffsetGoal - FRouteOffset;
  if C.Length <= Step then
    FRouteOffset := FRouteOffsetGoal
  else
    FRouteOffset := FRouteOffset + C.Normalize * Step;
  Result := P + FRouteOffset;
end;

procedure TViewPlay.ReleaseDemoKeys;
var
  K: TKey;
  KeyString: String;
begin
  if Container <> nil then
    for K in FDemoHeld do
      Container.Pressed.KeyUp(K, KeyString);
  FDemoHeld := nil;
  FDemoGoCrouch := False;
end;

{ Demo script commands (comma separated):
  W:sec wait, S screenshot, T:deg turn left, A:deg absolute yaw (Doom 3),
  P:deg pitch up, G:x y z go to Doom 3 coordinates (feet), F flashlight,
  X fire, U use, GO:forward side seconds hold movement keys (1 / -1 / 0),
  N:i stand 150 units in front of monster i facing it, Y god mode,
  O:command console command, L:map load a map, Q quit. }
procedure TViewPlay.RunDemoStep(const SecondsPassed: Single);
var
  Cmd, Action, Param: String;
  P, I: Integer;
  Parts: TStringArray;
  Mon: TD3Monster;
  Dir: TVector3;
begin
  if FQuitting then
    Exit;
  if FDemoIndex >= FDemoCommands.Count then
  begin
    WritelnLog('AutoTest', 'Demo finished');
    FQuitting := True;
    Application.Terminate;
    Exit;
  end;
  Cmd := Trim(FDemoCommands[FDemoIndex]);
  P := Pos(':', Cmd);
  if P > 0 then
  begin
    Action := UpperCase(Copy(Cmd, 1, P - 1));
    Param := Copy(Cmd, P + 1, MaxInt);
  end else
  begin
    Action := UpperCase(Cmd);
    Param := '';
  end;

  if Action = 'W' then
  begin
    FDemoTimer := FDemoTimer + SecondsPassed;
    if FDemoTimer < StrToFloatDef(Param, 1) then
      Exit;
    FDemoTimer := 0;
  end else
  if Action = 'GO' then
  begin
    Parts := Param.Split([' '], TStringSplitOptions.ExcludeEmpty);
    if FDemoTimer = 0 then
    begin
      ReleaseDemoKeys;
      if (Length(Parts) > 0) and (StrToFloatDef(Parts[0], 0) > 0) then
        FDemoHeld := Concat(FDemoHeld, [keyW]);
      if (Length(Parts) > 0) and (StrToFloatDef(Parts[0], 0) < 0) then
        FDemoHeld := Concat(FDemoHeld, [keyS]);
      if (Length(Parts) > 1) and (StrToFloatDef(Parts[1], 0) > 0) then
        FDemoHeld := Concat(FDemoHeld, [keyD]);
      if (Length(Parts) > 1) and (StrToFloatDef(Parts[1], 0) < 0) then
        FDemoHeld := Concat(FDemoHeld, [keyA]);
      { GO:x y seconds run: with the run key held }
      if (Length(Parts) > 3) and SameText(Parts[3], 'run') then
        FDemoHeld := Concat(FDemoHeld, [keyShift]);
      if (Length(Parts) > 3) and SameText(Parts[3], 'crouch') then
        FDemoGoCrouch := True;
      for I := 0 to High(FDemoHeld) do
        Container.Pressed.KeyDown(FDemoHeld[I], '');
    end;
    FDemoTimer := FDemoTimer + SecondsPassed;
    if (Length(Parts) > 2) and (FDemoTimer < StrToFloatDef(Parts[2], 1)) then
      Exit;
    ReleaseDemoKeys;
    FDemoTimer := 0;
  end else
  if Action = 'R' then
  begin
    { R:speed shotEvery [maxUnits]: walk the console's "route" (noclip), a
      screenshot every shotEvery units, at most maxUnits }
    Parts := Param.Split([' '], TStringSplitOptions.ExcludeEmpty);
    if (Length(Parts) > 2) and (FRoute <> nil) and (FRouteWalked >= StrToFloatDef(Parts[2], MaxSingle)) then
    begin
      { a later R: with a bigger maxUnits goes on }
      WritelnLog('GameViewPlay', 'Route: stopped after %.0f units', [FRouteWalked]);
    end else
    if not WalkRoute(SecondsPassed,
      StrToFloatDef(Iff(Length(Parts) > 0, Parts[0], ''), 300),
      StrToFloatDef(Iff(Length(Parts) > 1, Parts[1], ''), 500)) then
      Exit;
  end else
  if Action = 'S' then
  begin
    if FDemoSkipShot then
      FDemoSkipShot := False
    else
      CaptureScreenshot;
  end else
  if Action = 'T' then
    Camera.Direction := RotatePointAroundAxisDeg(StrToFloatDef(Param, 0), Camera.Direction,
      Vector3(0, 1, 0))
  else
  if Action = 'A' then
    Camera.SetWorldView(Camera.Translation, YawToCgeDir(StrToFloatDef(Param, 0)), Vector3(0, 1, 0))
  else
  if Action = 'P' then
  begin
    Dir := Camera.Direction;
    Dir := RotatePointAroundAxisDeg(StrToFloatDef(Param, 0), Dir,
      TVector3.CrossProduct(Dir, Vector3(0, 1, 0)));
    Camera.SetWorldView(Camera.Translation, Dir, Vector3(0, 1, 0));
  end else
  if Action = 'G' then
    PlaceCamera(D3ToCge(ParseVector3(Param, TVector3.Zero)), CameraYaw)
  else
  if Action = 'F' then
    ToggleFlashlight
  else
  if Action = 'X' then
    Fire(True)
  else
  if Action = 'U' then
    FGame.Use(Camera.Translation, Camera.Direction)
  else
  if Action = 'Y' then
    FGame.God := True
  else
  if Action = 'N' then
  begin
    I := StrToIntDef(Param, 0);
    FDemoSkipShot := (I < 0) or (I >= FGame.Monsters.Count) or (FGame.Monsters[I].Model = nil) or
      FGame.Monsters[I].Model.Hidden or not FGame.Monsters[I].Model.Holder.Exists;
    if not FDemoSkipShot then
    begin
      Mon := FGame.Monsters[I];
      WritelnLog('GameViewPlay', 'Monster view %d: %s (%s) at %s, yaw %.0f', [I, Mon.Model.Entity.Name,
        Mon.Model.Entity.ClassName_, CgeToD3(Mon.Position).ToString, Mon.Yaw]);
      { 150 units from the monster, the first free direction from where it looks }
      for P := 0 to 7 do
      begin
        Dir := YawToCgeDir(Mon.Yaw + P * 45);
        if not MainViewport.Items.WorldSegmentCollision(Mon.Center,
          Mon.Center + Dir * (150 + PlayerRadius)) then
          Break;
      end;
      PlaceCamera(Mon.Position + Dir * 150, 0);
      Dir := Mon.Center - Camera.Translation;
      Dir.Y := 0;
      Camera.SetWorldView(Camera.Translation, Dir.Normalize, Vector3(0, 1, 0));
    end;
  end else
  if Action = 'O' then
    HandleConsoleCommand(LowerCase(Trim(Copy(Param, 1, Pos(' ', Param + ' ') - 1))),
      Trim(Copy(Param, Pos(' ', Param + ' ') + 1, MaxInt)))
  else
  if Action = 'L' then
    LoadLevel(Param)
  else
  if Action = 'Q' then
  begin
    WaitScreenshotSaved;
    FQuitting := True;
    Application.Terminate;
    Exit;
  end else
    WritelnWarning('AutoTest', 'Unknown demo command "%s"', [Cmd]);
  Inc(FDemoIndex);
end;

{ Console "perf": adds the frame that just ended (from the last Update to
  this one; its parts were measured by that Update) and logs the averages
  when the time is up. The rest of a frame (frame minus update) is the
  rendering, the map's own Update (animations, GUIs) and the swap. }
procedure TViewPlay.PerfFrame(const SecondsPassed: Single);
var
  Frame: Double;
  I: Integer;
  Parts: String;
begin
  if not FLastUpdateValid then
    Exit;
  Frame := TimerSeconds(Timer, FLastUpdate);
  Inc(FPerfFrames);
  FPerfFrame := FPerfFrame + Frame;
  if Frame > FPerfWorst then
    FPerfWorst := Frame;
  FPerfUpdate := FPerfUpdate + FPartUpdate;
  FPerfGame := FPerfGame + FPartGame;
  FPerfVisibility := FPerfVisibility + FPartVisibility;
  FPerfHud := FPerfHud + FPartHud;
  for I := 0 to UpdatePartCount - 1 do
    FPerfParts[I] := FPerfParts[I] + FGame.UpdatePartTime(I);
  FPerfLeft := FPerfLeft - SecondsPassed;
  if FPerfLeft > 0 then
    Exit;
  Parts := '';
  for I := 0 to UpdatePartCount - 1 do
    if FPerfParts[I] / FPerfFrames >= 0.0001 then
      Parts := Parts + Format(' %s %.1f', [UpdatePartName[I], FPerfParts[I] / FPerfFrames * 1000]);
  WritelnLog('Perf', 'Perf: CPU a frame: update %.2f ms, then CGE before rendering %.2f ms, the view''s rendering %.2f ms (main thread CPU %.2f ms, with the driver''s waits)',
    [FPerfUpdate / FPerfFrames * 1000, FPerfPreRender / Max(1, FPerfRenderFrames) * 1000,
     FPerfRenderCpu / Max(1, FPerfRenderFrames) * 1000, (MainThreadCpuSeconds - FPerfCpuStart) / FPerfFrames * 1000]);
  WritelnLog('Perf', 'Perf: %d frames, %.2f ms a frame (%.1f FPS, worst %.1f ms); update %.2f ms (game %.2f, visibility %.2f, hud %.2f), rest %.2f ms; GPU %.2f ms (the view, %d frames); game parts, ms:%s (eye %s, yaw %.0f, area %d, visible areas %d, shapes %d of %d)',
    [FPerfFrames, FPerfFrame / FPerfFrames * 1000, FPerfFrames / FPerfFrame, FPerfWorst * 1000,
     FPerfUpdate / FPerfFrames * 1000, FPerfGame / FPerfFrames * 1000,
     FPerfVisibility / FPerfFrames * 1000, FPerfHud / FPerfFrames * 1000,
     (FPerfFrame - FPerfUpdate) / FPerfFrames * 1000,
     FPerfGpu / Max(1, FPerfGpuFrames) * 1000, FPerfGpuFrames, Parts,
     CgeToD3(Camera.Translation).ToString, CameraYaw, Map.AreaAt(Camera.Translation),
     Map.VisibleAreaCount, MainViewport.Statistics.ShapesRendered, MainViewport.Statistics.ShapesVisible]);
  Console.Print(Format('%.2f ms a frame', [FPerfFrame / FPerfFrames * 1000]));
end;

procedure TViewPlay.Update(const SecondsPassed: Single; var HandleInput: Boolean);
var
  Firing: Boolean;
  PartTimer: TTimerResult;
begin
  inherited Update(SecondsPassed, HandleInput);
  if FGame = nil then
    Exit;
  if FSampleLeft > 0 then
  begin
    FSampleLeft := FSampleLeft - SecondsPassed;
    if FSampleLeft <= 0 then
    begin
      SamplerStopAndReport('Sample of ' + MapName);
      WritelnLog('GameViewPlay', 'Samples written (samples.txt)');
    end;
  end;
  if FPaused then
  begin
    { a demo script goes on under the menu (console "menu") }
    if AutoTestPrefix <> '' then
      RunDemoStep(SecondsPassed);
    Exit;
  end;
  if FPendingAutosave then
  begin
    FPendingAutosave := False;
    if not FGame.PlayerDead then
      SaveGame('autosave');
  end;
  if FPendingMap <> '' then
  begin
    FPendingMapIn := FPendingMapIn - SecondsPassed;
    if FPendingMapIn <= 0 then
    begin
      WritelnLog('GameViewPlay', 'Next map "%s"', [FPendingMap]);
      Hud.ShowMessage('', 0);
      FCarryInfo := FGame.PersistentInfo;
      if GetEnvironmentVariable('CD3_CARRY_INVENTORY') <> '' then
        try
          StringToFile(FilenameToUriSafe(GetEnvironmentVariable('CD3_CARRY_INVENTORY')), FCarryInfo);
          WritelnLog('GameViewPlay', 'Inventory for the next map written to "%s"',
            [GetEnvironmentVariable('CD3_CARRY_INVENTORY')]);
        except
          on E: Exception do
            WritelnWarning('GameViewPlay', 'Cannot write the inventory: %s', [E.Message]);
        end;
      LoadLevel(FPendingMap);
      FPendingMap := '';
      Exit;
    end;
  end;
  UpdatePdaGui(SecondsPassed);
  if FPerfLeft > 0 then
    PerfFrame(SecondsPassed);
  if (FProfileFrames = 0) and FLastUpdateValid and
     (TimerSeconds(Timer, FLastUpdate) > LongFrameSeconds) then
    { the parts are of the frame's own Update (the one before this); the
      rest is the rendering, the map's Update (animations, GUIs) and the
      buffer swap }
    WritelnLog('Profile', 'Long frame: %.2f s (eye %s, yaw %.0f, area %d, visible areas %d; update %.2f: game %.2f, visibility %.2f, hud %.2f, demo %.2f; game:%s; loaded: %d file reads %.2f s, %d image programs %.2f s, %d shader programs)',
      [TimerSeconds(Timer, FLastUpdate), CgeToD3(Camera.Translation).ToString, CameraYaw,
       Map.AreaAt(Camera.Translation), Map.VisibleAreaCount,
       FPartUpdate, FPartGame, FPartVisibility, FPartHud, FPartDemo, FPartGameParts,
       ProfileReadCount - FLastReads, ProfileReadSeconds - FLastReadSeconds,
       ProfileImageCount - FLastImages, ProfileImageSeconds - FLastImageSeconds,
       InternalProgramsLinked - FLastPrograms]);
  { env CD3_CGE_PROFILE: CGE's profile of a long frame (octrees, shadow
    volume edges, scene loads...); every frame starts a new one }
  if (FProfileFrames = 0) and Profiler.Enabled then
  begin
    if FLastUpdateValid and (TimerSeconds(Timer, FLastUpdate) > LongFrameSeconds) then
      WritelnLogMultiline('Time Profile', Profiler.Summary);
    {$warnings off} // Clear is deprecated: fine between frames, nothing is started
    Profiler.Clear;
    {$warnings on}
  end;
  FLastReads := ProfileReadCount;
  FLastReadSeconds := ProfileReadSeconds;
  FLastImages := ProfileImageCount;
  FLastImageSeconds := ProfileImageSeconds;
  FLastPrograms := InternalProgramsLinked;
  FLastUpdate := Timer;
  FLastUpdateValid := True;
  if FProfileFrames > 0 then
  begin
    { the time since the last step: the previous frame (its render) }
    LoadProfileStep('frame ' + IntToStr(FProfileFrames));
    Inc(FProfileFrames);
    if FProfileFrames > 5 then
    begin
      FProfileFrames := 0;
      LoadProfileLog(Format('Map "%s"', [MapName]));
      FLastReads := 0;
      FLastReadSeconds := 0;
      FLastImages := 0;
      FLastImageSeconds := 0;
      ProfileLogReads := True;
      LogMemory(Format('Map "%s" (load %d)', [MapName, FMapLoads]));
      if Profiler.Enabled then
        WritelnLogMultiline('Time Profile', Profiler.Summary);
{ a timed sample (console "sample start <seconds>") goes on }
      if FSampleLeft <= 0 then
        SamplerStopAndReport(Format('Map "%s"', [MapName]));
    end;
  end;
  LabelFps.Caption := 'FPS: ' + Container.Fps.ToString;

  WalkNavigation.Exists := not Console.IsOpen and not FGame.PlayerDead and not FInCinematic and not FPdaOpen;

  if (AutoTestPrefix = '') and not Console.IsOpen then
  begin
    Firing := (buttonLeft in Container.MousePressed) or Container.Pressed[keyCtrl];
    { a scripted weapon reads the held button (WEAPON_ATTACK) }
    FGame.Attack := Firing and not FGame.PlayerDead;
    if Firing then
    begin
      if FGame.PlayerDead then
      begin
        if FGame.DeadTime > 1 then
          LoadLevel(MapName);
      end else
        Fire(False);
    end;
  end;
  FGame.PlayerViewDir := Camera.Direction;
  FGame.PlayerJumping := WalkNavigation.IsJumping;
  FGame.PlayerFlying := FNoclip;
  { berserk runs faster (idPlayer::PowerUpModifier( SPEED )); running
    is as fast as the stamina lets it (idPlayer::AdjustSpeed) }
  WalkNavigation.MoveSpeed := FBaseMoveSpeed * FGame.SpeedModifier;
  FGame.PlayerRunning := WalkNavigation.Input_Run.IsPressed(Container);
  FGame.PlayerMoving := WalkNavigation.Input_Forward.IsPressed(Container) or
    WalkNavigation.Input_Backward.IsPressed(Container) or
    WalkNavigation.Input_LeftStrafe.IsPressed(Container) or
    WalkNavigation.Input_RightStrafe.IsPressed(Container);
  WalkNavigation.RunMultiplier := FGame.RunMultiplier;
  UpdateCrouch(SecondsPassed);
  { thrown up by a knockback: its own arc, no navigation gravity }
  WalkNavigation.Gravity := not FNoclip and not FGame.KnockbackAirborne;
  UpdateFallSpeed(SecondsPassed);
  ApplyKnockback(SecondsPassed);

  { during cinematics the player stays where the camera was }
  PartTimer := Timer;
  FGame.SetFlashlightBeam(Flashlight.Exists and not FInCinematic, Camera.Direction);
  if FInCinematic then
    FGame.Update(SecondsPassed, FPlayerEye)
  else
    FGame.Update(SecondsPassed, Camera.Translation);
  FPartGame := TimerSeconds(Timer, PartTimer);
  FPartGameParts := FGame.UpdateParts;
  UpdateCinematic;
  if FGame.Skipping then
    RunSkippedCinematic;
  PartTimer := Timer;
  Map.UpdateVisibility(Camera);
  UpdatePortalSky;
  FPartVisibility := TimerSeconds(Timer, PartTimer);
  UpdateReverb;
  UpdateMuzzleFlash;
  if FGame.MountedFlashlight then
  begin
    Flashlight.Exists := FGame.MountedFlashlightLit;
    Flashlight.Intensity := FFlashlightIntensity * FGame.FlashlightIntensity;
  end;
  UpdateFlashlight;

  Hud.Health := FGame.Health;
  Hud.Armor := FGame.Armor;
  Hud.Stamina := FGame.StaminaPercent;
  Hud.Dead := FGame.PlayerDead;
  UpdateDamageView;
  UpdateRemoteViews(SecondsPassed);
  if FGame.MountedFlashlight then
  begin
    Hud.FlashlightOn := FGame.MountedFlashlightOn;
    Hud.FlashlightBattery := Round(FGame.FlashlightBattery * 100);
  end else
  begin
    Hud.FlashlightOn := Flashlight.Exists;
    Hud.FlashlightBattery := -1;
  end;
  Hud.AmmoText := Format('%s    KILLS %d', [FGame.WeaponHudText, FGame.Kills]);
  PartTimer := Timer;
  UpdateHudGui(SecondsPassed);
  FPartHud := TimerSeconds(Timer, PartTimer);

  PartTimer := Timer;
  { a demo script waits for a skipped cinematic to end }
  if (AutoTestPrefix <> '') and not FGame.Skipping then
    RunDemoStep(SecondsPassed);
  FPartDemo := TimerSeconds(Timer, PartTimer);
  FPartUpdate := TimerSeconds(Timer, FLastUpdate);
end;

{ A key to a GUI: backspace 8, enter 13, escape 27, else the character. }
function GuiKey(const Gui: TD3Gui; const Event: TInputPressRelease): Boolean;
var
  Code: Integer;
  Ch: Char;
begin
  Code := 0;
  Ch := #0;
  if Event.Key = keyBackSpace then
    Code := 8
  else
  if Event.Key = keyEnter then
    Code := 13
  else
  if Event.Key = keyEscape then
    Code := 27
  else
  if (Length(Event.KeyString) = 1) and (Event.KeyString[1] >= ' ') then
    Ch := Event.KeyString[1];
  if (Code = 0) and (Ch = #0) then
    Exit(False);
  { only an edit takes letters; escape goes to the GUI (onEsc) }
  if (Code <> 27) and (Gui.Focus = nil) then
    Exit(False);
  Result := Gui.KeyDown(Code, Ch);
end;

function TViewPlay.Press(const Event: TInputPressRelease): Boolean;
begin
  Result := inherited Press(Event);
  if Result then
    Exit;

  if Console.Press(Event) then
    Exit(True);

  { GUI keys (idUserInterface::HandleEvent): the PDA GUI while open (an
    edit types, Escape its onEsc), a world GUI while one of its edits has
    the focus }
  if (Event.EventType = itKey) and (Event.Key <> keyTab) then
  begin
    if FPdaOpen and (FPdaGui <> nil) and GuiKey(FPdaGui, Event) then
      Exit(True);
    if (FGame.GuiFocus <> nil) and (FGame.GuiFocus.Gui.Focus <> nil) and GuiKey(FGame.GuiFocus.Gui, Event) then
      Exit(True);
  end;

  if Event.IsKey(keyEscape) then
  begin
    { Escape skips a cinematic, like in Doom 3 }
    if FInCinematic then
      FGame.SkipCinematic
    else
    begin
      { Doom 3's in-game menu: over the paused game, "close" comes back }
      ViewMenu.InGame := True;
      Container.PushView(ViewMenu);
    end;
    Exit(True);
  end;
  if Event.IsKey(keyF) then
  begin
    ToggleFlashlight;
    Exit(True);
  end;
  if Event.IsKey(keyTab) then
  begin
    SetPdaOpen(not FPdaOpen);
    Exit(True);
  end;
  if FPdaOpen and (Event.IsKey('[') or Event.IsKey(']')) then
  begin
    if Event.IsKey('[') then
      Dec(FPdaIndex)
    else
      Inc(FPdaIndex);
    UpdatePdaText;
    Exit(True);
  end;
  if Event.IsKey(keyE) then
  begin
    FGame.Use(Camera.Translation, Camera.Direction);
    Exit(True);
  end;
  { weapons: 1..0 select slots 0..9 (Doom 3's _impulse0..9), the wheel
    cycles, R reloads }
  if (Event.EventType = itKey) and (Event.Key in [key0..key9]) then
  begin
    if Event.Key = key0 then
      FGame.SelectWeapon(9)
    else
      FGame.SelectWeapon(Ord(Event.Key) - Ord(key1));
    Exit(True);
  end;
  if Event.EventType = itMouseWheel then
  begin
    if Event.MouseWheel in [mwUp, mwLeft] then
      FGame.NextWeapon(-1)
    else
      FGame.NextWeapon(1);
    Exit(True);
  end;
  if Event.IsKey(keyR) then
  begin
    FGame.ReloadWeapon;
    Exit(True);
  end;
  if Event.IsKey(keyF5) then
  begin
    LabelFps.Exists := not LabelFps.Exists;
    Exit(True);
  end;
  { quick save and quick load }
  if Event.IsKey(keyF6) then
  begin
    SaveGame('');
    Exit(True);
  end;
  if Event.IsKey(keyF9) then
  begin
    LoadGame('');
    Exit(True);
  end;
  if Event.IsKey(keyF12) then
  begin
    CaptureScreenshot;
    Exit(True);
  end;
end;

finalization
  WaitScreenshotSaved;
end.
