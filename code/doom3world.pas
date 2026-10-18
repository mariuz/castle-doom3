{ Doom 3 gameplay on top of TDoom3Map: doors that open when you come near
  (idDoor), func_rotating, speakers playing sound shaders, md5 creatures
  that chase and claw the player (a tiny idAI), the player's pistol, health,
  flashlight and death.

  Entity activation (idEntity::ActivateTargets / Event_Activate): triggers
  touched by the player (trigger_once / trigger_multiple / trigger_hurt,
  their volumes from the .cm models) and trigger_relay / trigger_count fire
  the entities named by their "target", "target1"... keys: lights switch
  on / off, speakers start / stop, hidden entities show, doors unlock or
  open, hidden monsters appear and dormant ones wake up, func_remove removes
  its targets. Firings wait in a queue (their "delay"), processed in Update,
  so chains of relays can't recurse.

  Scripts (Doom3Script): script/doom_main.script and maps/<map>.script are
  compiled when the map spawns; the map script's main, worldspawn's "call"
  keys and triggers' "call" keys start script threads. Their events reach
  the game through TD3GameScriptHost: sys.trigger, lights on / off and
  colors, doors, hide / show, entity keys, bind / unbind, and idMover's
  moves and rotations (TD3ScriptMover) that sys.waitFor waits for.

  Cinematics: activating an idCameraAnim entity plays its .md5camera
  (Doom3Camera) as the view, then fires its targets; idCameraView shows the
  view from an entity; trigger_fade and sys.fadeIn / fadeOut / fadeTo fade
  the screen; info_player_teleport moves the player. TViewPlay applies
  them (CinematicActive, CinematicView, FadeColor, TakeTeleport).
  idAnimated models (ships, props of cinematics) play their "anim" when
  activated and then fire their targets (TD3Animated); cinematic
  characters ("cinematic" "1") play theirs once.

  Actors (TD3Actor): idAI entities whose script object is a "character"
  (Mars City's people) run their AI script like idAI: the object's init,
  then state functions (setState) in the main thread, and animation states
  (animState) in a thread per channel; the game moves and turns them
  (moveToEntity, turnTo), plays their animations and keeps their AI_*
  flags up to date. Monsters whose script object the game supports
  (ScriptedMonsterObjects: zombies) run theirs too, with the player as
  their enemy: checkForEnemy, moveToEnemy, testMeleeAttack and the melee
  frame commands of their animations; shots set AI_PAIN, death starts
  state_Killed. launch_missile frame commands and attackMissile fire
  projectiles (TD3Projectile: the monster's def_projectile, homing for
  idGuidedProjectile, bouncing without detonate_on_world) at the player;
  create_missile holds one in the hand until then.

  Everything here is in CGE coordinates (Y up); Doom 3 units are kept
  (1 unit = 1 inch), so speeds and sizes are Doom 3's numbers. }
unit Doom3World;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleVectors, CastleTransform, CastleScene, CastleSoundEngine, CastleBoxes, CastleBehaviors,
  CastleRenderOptions,
  Doom3Level, Doom3MapFile, Doom3Decls, Doom3Script, Doom3Camera, Doom3Md5, Doom3Aas;

type
  { A monster's route through the AAS (the path between the areas it was
    computed for). }
  TD3Route = record
    FromArea, ToArea: Integer;
    Found: Boolean;
    { found with the flying travel flags }
    Fly: Boolean;
    Path: TD3AasPath;
  end;

  TD3MessageEvent = procedure (const Msg: String) of object;

  TD3MoverKind = (mkDoor, mkRotating);
  TD3DoorState = (dsClosed, dsOpening, dsOpen, dsClosing);

  TD3Mover = class
    Brush: TD3BrushEntity;
    Kind: TD3MoverKind;
    State: TD3DoorState;
    { doors }
    ClosedPos, MoveDir: TVector3;
    Distance, Speed, Wait, Timer, Progress: Single;
    TriggerBox: TBox3D;
    Locked, NoTouch: Boolean;
    SoundOpen, SoundClose: TCastleSound;
    Sounds: TCastleSoundSource;
    { portals this door closes when it is shut }
    Portals: array of Integer;
    { "team": doors that open and close together (double doors) }
    Team: String;
    { rotating }
    RotAxis: TVector3;
    RotSpeed, Angle: Single;
    { func_rotating turning ("start_on", toggled by activation) }
    Running: Boolean;
    procedure Update(const SecondsPassed: Single);
    procedure Open;
    procedure Close;
  end;

  TD3MonsterState = (msIdle, msChase, msAttack, msDead);

  TD3Actor = class;
  TD3Projectile = class;

  TD3Monster = class
    Model: TD3ModelEntity;
    { set when its AI script runs it (the simple AI is off) }
    Actor: TD3Actor;
    State: TD3MonsterState;
    Health: Integer;
    Yaw: Single;
    AttackTimer, StateTime, PainTime: Single;
    Radius, Height: Single;
    { "trigger" "1": doesn't wake up on sight, only when triggered (no
      triggers yet) or hurt }
    Dormant: Boolean;
    Route: TD3Route;
    { a flying monster killed in the air falls (FallSpeed, units per
      second, CGE down) before it sinks }
    Falling: Boolean;
    FallSpeed: Single;
    function Position: TVector3;
    function Center: TVector3;
  end;

  TD3Speaker = class
    Entity: TD3MapEntity;
    Transform: TCastleTransform;
    Source: TCastleSoundSource;
    Sound: TCastleSound;
    Looping: Boolean;
    destructor Destroy; override;
  end;

  TD3TriggerKind = (tkOnce, tkMultiple, tkHurt);

  { A trigger volume touched by the player (idTrigger_Multiple,
    idTrigger_Hurt; trigger_once is a trigger_multiple firing once). }
  TD3Trigger = class
    Entity: TD3MapEntity;
    Kind: TD3TriggerKind;
    { Volume in CGE coordinates. }
    Box: TBox3D;
    { Seconds before firing the targets ("delay"), between firings ("wait",
      trigger_multiple) or damages (trigger_hurt). }
    Delay, Wait: Single;
    { Game time when it can fire again. }
    NextTime: Single;
    { "triggerFirst": touching does nothing until it was activated once. }
    WaitingForActivation: Boolean;
    { "noTouch": only activation fires it. }
    NoTouch: Boolean;
    { trigger_once already fired, or trigger_hurt switched off ("on" "0"). }
    Disabled: Boolean;
    { trigger_hurt damage per hit }
    Damage: Integer;
  end;

  { An entity bound to a mover ("bind"): it keeps its placement relative
    to the parent (idEntity::Bind). }
  TD3Binding = class
    Child, Parent: TCastleTransform;
    { Child's transformation relative to the parent's (set at bind time,
      changed by script moves of the child). }
    ChildInParent: TMatrix4;
    { Number of bound ancestors (parents are updated before children). }
    Depth: Integer;
  end;

  { An entity moved by script events (idMover's move, moveTo, rotateOnce,
    rotate...). Origin and Angles (pitch, yaw, roll) are Doom 3 ones,
    relative to the master when the entity is bound. }
  TD3ScriptMover = class
    Handle: Integer;
    Transform: TCastleTransform;
    Origin, Angles: TVector3;
    { idMover settings: "time" (seconds), "speed" (units per second, wins
      over time for moves when > 0), "accelTime", "decelTime" }
    MoveTime, MoveSpeed, AccelTime, DecelTime: Single;
    Moving: Boolean;
    MoveFrom, MoveTo: TVector3;
    MoveStart, MoveDuration: Single;
    { rotateOnce / rotateTo (to RotTo) or rotate (RotSpeed per second) }
    Rotating, RotContinuous: Boolean;
    RotFrom, RotTo, RotSpeed: TVector3;
    RotStart, RotDuration: Single;
    { startSpline: moving along a curve (control points, Doom 3
      coordinates) instead of a line, turning with its direction }
    Spline: array of TVector3;
    SplineYaw0, SplineAngleYaw0: Single;
    { sys.waitFor waits while a move or a single rotation goes on }
    function Busy: Boolean;
  end;

  { An idAnimated entity: an md5 model playing animations when activated
    (func_animate, cin_base...). }
  TD3Animated = class
    Model: TD3ModelEntity;
    { "num_anims": anim1, anim2... played one per activation; 0: "anim" }
    NumAnims, AnimIndex: Integer;
    Activated: Boolean;
    { game time of the current animation's end (-1: none or looping),
      of the "wait" activation (-1: none) }
    DoneTime, ActivateTime: Single;
  end;

  { An animation channel of an actor (ANIMCHANNEL_TORSO, LEGS, HEAD...):
    its animation state (a script function in its own thread) and the
    animation it plays. }
  TD3ActorChannel = class
    Thread: TD3ScriptThread;
    StateName: String;
    PendingFunction: TD3ScriptFunction;
    PendingName: String;
    HasPending: Boolean;
    AnimName: String;
    AnimStart, AnimLength: Single;
    AnimLoop: Boolean;
  end;

  { An idAI entity running its script object (TD3Game.SpawnActors). }
  TD3Actor = class
    Model: TD3ModelEntity;
    Handle: Integer;
    Obj: TD3ScriptObject;
    { the main thread runs init, then the state functions }
    Main: TD3ScriptThread;
    StateName, IdealName: String;
    IdealFunction: TD3ScriptFunction;
    HasIdeal: Boolean;
    { [1..4]: ANIMCHANNEL_TORSO, LEGS, HEAD, EYELIDS (ALL means LEGS) }
    Channels: array [1..4] of TD3ActorChannel;
    { waitAction: the threads waiting until finishAction(name) }
    WaitAction: String;
    { the monster (health, shots) of a scripted monster, nil for characters }
    Monster: TD3Monster;
    { stopThinking: its threads stopped }
    Thinking: Boolean;
    { the player is its enemy; moving to it }
    HasEnemy, ChaseEnemy: Boolean;
    MeleeRange: Single;
    { frames left before AI_PAIN goes back to false }
    PainFrames: Integer;
    { setTalkState (TALK_OK = 2: the player can talk to it) and the one it
      talks to (setTalkTarget; AI_TALK while there's one) }
    TalkState, TalkTarget: Integer;
    { head looks (idAI::UpdateAnimationControllers): lookAt / lookAtEnemy
      focus on an entity until FocusUntil; LookAngles (pitch down, yaw
      left, from its facing) ease towards it within LookMin / LookMax and
      turn the look_joint joints by their share }
    FocusTarget: Integer;
    FocusUntil: Single;
    LookAngles, LookMin, LookMax: TVector2;
    LookJoints: array of record
      Joint: Integer;
      Scale: TVector2; { pitch, yaw }
    end;
    HeadFocusRate: Single;
    { the body animation applied last (channel:name:start time) }
    BodyKey: String;
    { movement, Doom 3 coordinates }
    Moving: Boolean;
    Goal, SavedGoal: TVector3;
    SavedMoving: Boolean;
    Yaw, IdealYaw, TurnRate: Single;
    { its way to Goal through the AAS }
    Route: TD3Route;
    { the projectile it holds (create_missile / createMissile) until it
      launches it, nil when none }
    Missile: TD3Projectile;
    { a multiframe melee attack (attack_begin <damage def>,
      chargeAttack): while set, touching the player hurts it once
      (idAI::DirectDamage ends the attack); '' when none }
    Attack: String;
    { idAI's move.moveType (setMoveType): MoveTypeAnim walks,
      MoveTypeFly flies (FlyMove), MoveTypeStatic stays, MoveTypeDead }
    MoveType: Integer;
    { flying: the velocity (Doom 3 coordinates); MoveDirect flies
      straight on with it (MOVE_TO_POSITION_DIRECT: charges) }
    Velocity: TVector3;
    MoveDirect: Boolean;
    { waitMove: its thread waits until the move is done }
    WaitMove: Boolean;
    { fly_speed, fly_offset (above the enemy's eyes), fly_bob_*,
      fly_seek_scale, fly_roll_* / fly_pitch_* (leaning into turns) }
    FlySpeed, FlyOffset, FlyBobStrength, FlyBobHorz, FlyBobVert, FlySeekScale: Single;
    FlyRollScale, FlyRollMax, FlyPitchScale, FlyPitchMax, FlyRoll, FlyPitch: Single;
    constructor Create;
    destructor Destroy; override;
    procedure SetFlag(const AName: String; const Value: Single);
  end;

  { A projectile (idProjectile): fired by a monster (launch_missile and
    the other missile frame commands and script events), it hurts the
    player it reaches and detonates on the world, or bounces. CGE
    coordinates. }
  TD3Projectile = class
    Position, Velocity: TVector3;
    { created (create_missile, createMissile) and not launched yet: it
      stays at HeldJoint of HeldBy, harmless }
    HeldBy: TD3Actor;
    HeldJoint: String;
    { detonate_on_world / detonate_on_actor (idProjectile reads them as
      bools, missing = false): without them it bounces off (Bounce is the
      speed kept) instead of exploding }
    DetonateOnWorld, DetonateOnActor: Boolean;
    Bounce: Single;
    { idGuidedProjectile (revenant rockets): turns towards the player's
      eyes (when its owner had the player as enemy) by up to TurnMax
      degrees a second, wobbling by RandomScale (pitch, yaw) degrees that
      fade within ClampDist; burstMode stops guiding within BurstDist and
      speeds up by BurstVelocity }
    Guided, SeeksPlayer, BurstMode, UnGuided: Boolean;
    Speed, TurnMax, ClampDist, BurstDist, BurstVelocity: Single;
    { Doom 3 pitch (down), yaw of the flight }
    Pitch, Yaw: Single;
    RandomScale, RandomAngles: TVector2;
    RandomTime: Single;
    { the speed it launches at (its def's velocity) }
    LaunchSpeed: Single;
    { a bouncing one lying on a floor }
    Resting: Boolean;
    { downwards, units per second per second }
    Gravity: Single;
    Fuse, Radius: Single;
    Damage: Integer;
    { def_splash_damage (idGameLocal::RadiusDamage): damage at the
      explosion, falling to 0 at SplashRadius }
    SplashDamage: Integer;
    SplashRadius: Single;
    { detonate_on_fuse: explode when the fuse ends, else just vanish }
    DetonateOnFuse: Boolean;
    Owner: String;
    { fired by the player's weapon: hits monsters, not the player }
    FromPlayer: Boolean;
    { def_damage, def_splash_damage }
    DamageDefName, SplashDefName: String;
    ExplodeSound: String;
    { a glowing ball (fireballs), nil for bullets }
    Visual: TCastleTransform;
    destructor Destroy; override;
  end;

  { A combat node (idCombatNode, ai_attackcone): a spot a monster that
    targets it can attack from, when its enemy is in the node's cone:
    from MinDist to MaxDist along its facing, within fov, between
    MinHeight and MaxHeight. Doom 3 coordinates. }
  TD3CombatNode = class
    Entity: TD3MapEntity;
    { origin + offset }
    Origin, Forward, ConeLeft, ConeRight: TVector3;
    MinDist, MaxDist, MinHeight, MaxHeight: Single;
    { start_off; activation toggles it; markUsed with use_once sets it }
    Disabled, UseOnce: Boolean;
    { idCombatNode::EntityInView for the player with its feet at Feet }
    function PlayerInView(const Feet: TVector3): Boolean;
  end;

  { A moveable (idMoveable: moveable_* entities): a brush entity or static
    model with simple rigid body physics, no spin: it falls (Doom 3's
    gravity), bounces (bouncyness) and comes to rest. Thrown (the vagary,
    throwMoveable, setLinearVelocity) it hurts the player it hits
    (def_damage, scaled by the speed between minDamageVelocity and
    maxDamageVelocity, once a second) while its damage is on. Doom 3
    coordinates. }
  TD3Moveable = class
    Brush: TD3BrushEntity;
    Velocity: TVector3;
    AtRest, WasBound: Boolean;
    Bounce, MinDamageVelocity, MaxDamageVelocity: Single;
    DamageDef: String;
    { damage on (not with damageWhenActive until enabled); DamageUntil > 0
      turns it off then (enableDamage: 2.5 s) }
    CanDamage: Boolean;
    DamageUntil, NextDamageTime: Single;
    { half its bounds, and their center from its origin (local, unrotated) }
    HalfSize, CenterOffset: TVector3;
    function Origin: TVector3;
  end;

  { An item (idItem, idMoveableItem, idItemPowerup, idPDAItem...): touched
    by the player, it gives its inv_* keys (health, armor, ammo_*,
    weapon...) and disappears. Its model is a static model or brush entity
    (Brush, nil without one). }
  TD3Item = class
    Entity: TD3MapEntity;
    Brush: TD3BrushEntity;
    { the box touching picks it up (Doom 3 coordinates, world) }
    Box: TBox3D;
    PickedUp: Boolean;
    { triggerFirst / no_touch: not until triggered }
    CanPickUp: Boolean;
    Spin: Boolean;
    { where it was placed (spinning items bob around it), Doom 3 }
    SpawnOrigin: TVector3;
    { the entity number (idItem::Think's bob speed) }
    Number: Integer;
  end;

  { A light fading in or out (idLight::FadeIn / FadeOut). }
  TD3LightFade = record
    Light: Integer;
    From, Target, Start, Duration: Single;
  end;

  TD3PendingTargets = record
    Time: Single;
    { activate the targets of this entity }
    Entity: TD3MapEntity;
  end;

  { A damage def's screen blob (idPlayerView's screenBlob_t): a material
    drawn on the 640 x 480 screen, fading out from Start to Finish. }
  TD3ScreenBlob = record
    Material: String;
    X, Y, W, H: Single;
    Start, Finish: Single;
  end;

  TD3WeaponStatus = (wsHolstered, wsRising, wsLowering, wsReady, wsOutOfAmmo, wsReload);

  { The player's weapon (idWeapon): its entityDef (def_weaponN of the
    player def) runs its script object (weapon_pistol...) with the idWeapon
    events, its view model (model_view) follows the view. Without a script
    object it fires the built-in pistol (TD3Game.Fire). }
  TD3Weapon = class
    Slot: Integer;
    DefName: String;
    Def: TStringList;
    Obj: TD3ScriptObject;
    { owned by the script VM }
    Thread: TD3ScriptThread;
    StateName, IdealName: String;
    IdealFunction: TD3ScriptFunction;
    HasIdeal: Boolean;
    Status: TD3WeaponStatus;
    { ammoType ('' = none: fists), ammoRequired per shot (0: no ammo
      needed), clipSize (0: no clip) }
    AmmoType: String;
    AmmoRequired, ClipSize: Integer;
    ProjectileDef, MeleeDef: String;
    MeleeDistance: Single;
    { the view model (nil without model_view): at the player's eye, turned
      with the view }
    Holder: TCastleTransform;
    View: TD3Md5Instance;
    { game time when the playing anim ends (animDone), 0 for cycles }
    AnimDoneTime: Single;
    BlendFrames: Integer;
    Shots: Integer;
    { muzzle kick (idWeapon::MuzzleRise): each shot pushes KickEndTime by
      KickTime, up to KickMaxTime ahead; the view model turns by
      KickAngles (pitch, yaw, roll) and moves back by KickOffset, scaled
      by the time left }
    KickEndTime, KickTime, KickMaxTime: Single;
    KickAngles, KickOffset: TVector3;
    { the muzzle flash light (flashColor, flashRadius: 0 = none,
      flashTime) at the view model's "flash" joint; FlashStart is the
      game time of the last shot (its materials' parm4 is -FlashStart) }
    FlashColor: TVector3;
    FlashRadius, FlashTime, FlashStart: Single;
    { the view model's lag behind turns and moves
      (weaponAngleOffsetAverages / Scale / Max, weaponOffsetTime / Scale) }
    AngleOffsetAverages, AngleOffsetScale, AngleOffsetMax: Single;
    OffsetTime, OffsetScale: Single;
    destructor Destroy; override;
    procedure SetFlag(const AName: String; const Value: Boolean);
    function Flag(const AName: String): Boolean;
    { the script runs it (else the built-in pistol) }
    function Scripted: Boolean;
  end;

  TD3Game = class
  strict private
    FMap: TDoom3Map;
    FMovers: specialize TObjectList<TD3Mover>;
    FMonsters: specialize TObjectList<TD3Monster>;
    FSpeakers: specialize TObjectList<TD3Speaker>;
    FSounds: specialize TObjectDictionary<String, TCastleSound>;
    FTriggers: specialize TObjectList<TD3Trigger>;
    { map entities by lowercase name }
    FEntities: specialize TDictionary<String, TD3MapEntity>;
    FPending: specialize TList<TD3PendingTargets>;
    FBindings: specialize TObjectList<TD3Binding>;
    FBindingsSorted: Boolean;
    FScript: TD3ScriptVM;
    FScriptHost: TD3ScriptHost;
    { entity handles of scripts: index in FMap.MapFile.Entities + 1 }
    FHandles: specialize TDictionary<String, Integer>;
    FScriptMovers: specialize TObjectDictionary<Integer, TD3ScriptMover>;
    { cinematics: the playing camera anim (idCameraAnim) or camera view
      (idCameraView) }
    FCameraAnims: specialize TObjectDictionary<String, TD3CameraAnim>;
    FCameraEntity: TD3MapEntity;
    FCameraAnim: TD3CameraAnim;
    FCameraStart: Single;
    FCameraOffset: TVector3;
    FCameraCycles: Integer;
    { skipping a cinematic also skips the cameras started by it until then }
    FSkipUntil: Single;
    { screen fade (idPlayerView::Fade) }
    FFadeFrom, FFadeTo: TVector4;
    FFadeStart, FFadeTime: Single;
    FTeleportPending: Boolean;
    FTeleportPos: TVector3;
    FTeleportYaw: Single;
    FLightFades: specialize TList<TD3LightFade>;
    FAnimated: specialize TObjectList<TD3Animated>;
    FActors: specialize TObjectList<TD3Actor>;
    FProjectiles: specialize TObjectList<TD3Projectile>;
    { the map's AAS for monsters of the player's size (maps/<map>.aas48),
      nil when the map has none: then monsters walk straight }
    FAas: TD3AasFile;
    { per portal area: the "location" of the info_location spread there
      ('' = none), see SpreadLocations }
    FLocations: array of String;
    FCombatNodes: specialize TObjectList<TD3CombatNode>;
    FMoveables: specialize TObjectList<TD3Moveable>;
    FItems: specialize TObjectList<TD3Item>;
    { the player's inventory (idInventory): weapons by slot (def_weaponN of
      the player def), ammo by ammo class, each weapon's clip (-1: full
      when first used) }
    FPlayerDef: TStringList;
    FAmmo: specialize TDictionary<String, Integer>;
    FCarried: TStringList;
    FWeapon: TD3Weapon;
    FIdealSlot: Integer;
    { the player's movement for the view weapon (idPlayer::BobCycle):
      velocity (Doom 3), horizontal speed, bob cycle (0..256), its sine,
      the view angles smoothed (gun lag), movement changes (view space) }
    FPrevEye: TVector3;
    FHasPrevEye: Boolean;
    FPlayerVelocity: TVector3;
    FXYSpeed, FBobCycle, FBobFracSin: Single;
    FSmoothedView: TVector2;
    FHasSmoothedView: Boolean;
    FAccelTimes: array [0..15] of Single;
    FAccelDirs: array [0..15] of TVector3;
    FAccelCount: Integer;
    FMuzzleFlashPos: TVector3;
    FLastPresentTime: Single;
    { the view's bob (Doom 3 offset, angles: pitch, yaw, roll) and the last
      landing (idPlayer's landChange, landTime) }
    FViewBob, FViewBobAngles: TVector3;
    FLandChange, FLandTime, FWeaponLand: Single;
    { the last step up (idPlayer's stepUpDelta, stepUpTime) and the fall
      going on (from FFallStartZ, Doom 3 z of the eye) }
    FStepUpDelta, FStepUpTime: Single;
    { damage feedback (idPlayerView): the head kick, blobs, the last damage
      and pain times }
    FKickAngles: TVector3;
    FKickFinish, FLastDamageTime, FPainDebounce, FLastArmorPulse: Single;
    { double vision's end (idPlayerView's dvFinishTime) and the knockback
      (Doom 3 velocity, horizontal) }
    FDvFinish: Single;
    FKnockVel: TVector3;
    FBlobs: array of TD3ScreenBlob;
    FFalling: Boolean;
    FFallStartZ: Single;
    FAttackPulse: Single;
    FReloadRequested: Boolean;
    { script sounds: sound sources by entity handle, playing sounds by
      "handle:channel" }
    FSoundSources: specialize TDictionary<Integer, TCastleSoundSource>;
    FSoundTransforms: specialize TObjectList<TCastleTransform>;
    FScriptSounds: specialize TObjectDictionary<String, TCastlePlayingSoundSource>;
    { trigger_count activations so far, by lowercase name }
    FCounts: specialize TDictionary<String, Integer>;
    { classes whose activation is not supported yet (logged once) }
    FUnsupported: TStringList;
    FTime: Single;
    FPlayerEye: TVector3;
    FOnMessage: TD3MessageEvent;
    FFireCooldown: Single;
    FDeadTime: Single;
    procedure Message(const S: String);
    function SoundFromShader(const ShaderName: String): TCastleSound;
    procedure SpawnMover(const B: TD3BrushEntity);
    procedure SpawnSpeaker(const E: TD3MapEntity);
    procedure SpawnTrigger(const E: TD3MapEntity);
    function SpawnMonster(const ME: TD3ModelEntity): TD3Monster;
    procedure FireTrigger(const T: TD3Trigger);
    procedure ActivateTargetsNow(const E: TD3MapEntity);
    procedure Unsupported(const What: String);
    { func_remove: remove (hide) an entity for good }
    procedure RemoveEntity(const E: TD3MapEntity);
    procedure UpdateTriggers(const Feet: TVector3);
    procedure SpawnBindings;
    procedure SpreadLocations;
    procedure SpawnCombatNode(const E: TD3MapEntity);
    procedure SpawnMoveable(const B: TD3BrushEntity);
    procedure SpawnItem(const E: TD3MapEntity);
    function ItemOf(const E: TD3MapEntity): TD3Item;
    procedure UpdateItems;
    procedure InitInventory;
    function SpawnWeapon(const Slot: Integer): TD3Weapon;
    procedure UpdateWeapon(const SecondsPassed: Single);
    { the player's speed, bob cycle and movement changes }
    procedure UpdatePlayerMotion(const SecondsPassed: Single);
    { idPlayer::CrashLand after a fall: the view's dip, falling damage }
    procedure CrashLand(const FallHeight: Single);
    procedure PlayerSound(const Key: String);
    { place the view model: bob, lag, idle drift, muzzle kick
      (idPlayer::CalculateViewWeaponPos, idWeapon::MuzzleRise); its flash
      surfaces and light }
    procedure PresentWeapon(const W: TD3Weapon);
    procedure UpdateWeaponView(const SecondsPassed: Single);
    function WeaponEvent(const W: TD3Weapon; const Thread: TD3ScriptThread; const N: String;
      const Args: TD3ValueArray; var EventResult: TD3Value): Boolean;
    procedure WeaponFrameCommand(const Sender: TD3Md5Instance; const Command: String);
    { idInventory::HasAmmo: shots of AmmoRequired, -1 when unlimited }
    function HasAmmo(const AmmoClass: String; const Required: Integer): Integer;
    procedure UseAmmo(const AmmoClass: String; const Amount: Integer);
    { idWeapon::Event_LaunchProjectiles }
    procedure LaunchPlayerProjectiles(const W: TD3Weapon; const Count: Integer;
      const Spread, FuseOffset, LaunchPower, DamagePower: Single);
    { idWeapon::Event_Melee: True when it hit a monster }
    function WeaponMelee(const W: TD3Weapon): Boolean;
    { the nearest living monster on the ray, closer than MaxDist (CGE) }
    function RayMonster(const Origin, Dir: TVector3; const MaxDist: Single;
      out Dist: Single): TD3Monster;
    procedure DamageMonster(const Mon: TD3Monster; const Amount: Integer);
    procedure MonsterSplash(const Position: TVector3; const Damage: Integer; const Radius: Single);
    { the player's view axes (Doom 3 rows: forward, left, up) }
    function PlayerViewAxis: TMatrix3;
    procedure UpdateMoveables(const SecondsPassed: Single);
    function CombatNodeOf(const E: TD3MapEntity): TD3CombatNode;
    procedure UpdateBindings;
    function TransformOf(const AName: String): TCastleTransform;
    function FindBinding(const Child: TCastleTransform): TD3Binding;
    procedure Bind(const Child, Parent: TCastleTransform);
    procedure Unbind(const Child: TCastleTransform);
    procedure StartScripts;
    procedure CallScript(const FunctionName: String; const Who: String);
    function ScriptMover(const Handle: Integer): TD3ScriptMover;
    procedure ApplyScriptMover(const M: TD3ScriptMover);
    procedure UpdateScriptMovers;
    function HandleEntity(const Handle: Integer): TD3MapEntity;
    procedure SpawnActors;
    function FindActor(const Handle: Integer): TD3Actor;
    function ActorChannel(const A: TD3Actor; const Channel: Single): TD3ActorChannel;
    procedure ActorAnim(const A: TD3Actor; const Channel: Single; const AnimName: String; const Loop: Boolean);
    function ActorEvent(const A: TD3Actor; const Thread: TD3ScriptThread; const N: String;
      const Args: TD3ValueArray; var EventResult: TD3Value): Boolean;
    procedure UpdateActors(const SecondsPassed: Single);
    procedure ActorFrameCommand(const Sender: TD3Md5Instance; const Command: String);
    procedure UpdateLook(const A: TD3Actor; const SecondsPassed: Single);
    { where a monster's joint is (CGE), its chest when it has no such joint }
    function MuzzlePosition(const A: TD3Actor; const JointName: String): TVector3;
    procedure LaunchProjectile(const P: TD3Projectile; const From, Dir: TVector3);
    { idAI::TestMelee: the player within melee_range of its box }
    function ActorTestMelee(const A: TD3Actor): Boolean;
    { idAI::DirectDamage: hurt the player by the damage def; ends a
      multiframe attack }
    procedure ActorDirectDamage(const A: TD3Actor; const DamageDefName: String);
    { idAI::AttackMelee: hit the player in reach, True when hit }
    function ActorAttackMelee(const A: TD3Actor; const DamageDefName: String): Boolean;
    procedure UpdateProjectiles(const SecondsPassed: Single);
    { splash damage of a projectile exploding at P.Position }
    procedure SplashDamage(const P: TD3Projectile);
    { idGameLocal::RadiusDamage on the player: Damage at Position, falling
      to 0 at Radius, if nothing solid is between (rays start at Back,
      just off the surface) }
    procedure RadiusDamage(const Position, Back: TVector3; const Damage: Integer;
      const Radius: Single; const Owner: String; const SplashDefName: String = '');
    procedure PlaySoundAt(const ShaderName: String; const Position: TVector3);
    procedure ActorDamaged(const A: TD3Actor; const Killed: Boolean);
    function ActorCanSeePlayer(const A: TD3Actor; const UseFov: Boolean): Boolean;
    function StepTowards(const From, Step: TVector3; const Radius, Height: Single): TVector3;
    { a flying move (no floor following): each axis of Step that isn't
      blocked; Blocked when one was. CGE coordinates, From is the feet. }
    function FlyStep(const From, Step: TVector3; const Radius, Height: Single;
      out Blocked: Boolean): TVector3;
    { idAI::FlyMove: seek the goal, bob, keep above the enemy's eyes,
      damp and approach fly_speed, collide, lean into turns }
    procedure UpdateFlying(const A: TD3Actor; const SecondsPassed: Single);
    procedure SpawnAnimated(const ME: TD3ModelEntity);
    function FindAnimated(const E: TD3MapEntity): TD3Animated;
    procedure ActivateAnimated(const A: TD3Animated);
    procedure PlayAnimatedAnim(const A: TD3Animated; const AnimName: String);
    procedure PlayNextAnim(const A: TD3Animated);
    procedure AnimatedDone(const A: TD3Animated);
    procedure UpdateAnimated;
    procedure StartCamera(const E: TD3MapEntity);
    procedure StopCamera;
    procedure UpdateCamera;
    procedure StartFade(const Target: TVector4; const Seconds: Single);
    procedure FadeLight(const Light: Integer; const Target, Seconds: Single);
    procedure UpdateLightFades;
    function ScriptSoundSource(const Handle: Integer): TCastleSoundSource;
    function StartScriptSound(const Handle: Integer; const ShaderName: String;
      const Channel: Integer): Single;
    procedure StopScriptSound(const Handle, Channel: Integer);
    procedure ClearScriptSounds;
    function EntityHandle(const E: TD3MapEntity): Integer;
    { Doors of the same team as Door (Door itself too). }
    procedure OpenTeam(const Door: TD3Mover);
    procedure CloseTeam(const Door: TD3Mover);
    procedure LockTeam(const Door: TD3Mover; const Value: Boolean);
    procedure UpdateMonster(const M: TD3Monster; const SecondsPassed: Single;
      const PlayerPos: TVector3);
    procedure SetMonsterYaw(const M: TD3Monster; const YawDeg: Single);
    function CanSee(const A, B: TVector3): Boolean;
  public
    { Player state }
    Health, Armor: Integer;
    God, NoTarget: Boolean;
    Kills: Integer;
    { Seconds since the last pistol shot (for the muzzle flash) }
    SinceFire: Single;
    { Entities activated since the map was spawned (statistics, tests). }
    ActivationCount: Integer;
    { Projectiles launched since the map was spawned (statistics, tests). }
    ProjectilesLaunched: Integer;
    { Script threads and the entities they move stand still (g_stopTime). }
    ScriptsPaused: Boolean;
    { the inventory (idInventory): max health / armor of the player def,
      weapons by slot (def_weaponN) and each one's clip (-1: full when
      first used) }
    MaxHealth, MaxArmor: Integer;
    WeaponBits: Cardinal;
    WeaponDefs: array [0..15] of String;
    Clip: array [0..15] of Integer;
    { The player's view direction (CGE), set by the view each frame: weapons
      aim and their view models turn with it. }
    PlayerViewDir: TVector3;
    { pm_bob: the view bobs (the view model always does) }
    ViewBobEnabled: Boolean;
    { set by the view each frame: the player is jumping (going up), or
      flying (noclip: no steps, no falls) }
    PlayerJumping, PlayerFlying: Boolean;
    { the last landing's delta (Doom 3: speed squared / 10000), for tests }
    LastFallDelta: Single;
    { the player def's sound key last played (snd_pain_small...), for tests }
    LastPlayerSound: String;
    { The attack button is held (idPlayer: WEAPON_ATTACK). }
    Attack: Boolean;
    constructor Create(const AMap: TDoom3Map);
    destructor Destroy; override;
    { Create movers, monsters, speakers for the loaded map. }
    procedure Spawn;
    procedure Clear;
    { Per frame. PlayerEye is the camera position. }
    procedure Update(const SecondsPassed: Single; const PlayerEye: TVector3);
    { Fire the pistol. True if a shot was fired. }
    function Fire(const Origin, Dir: TVector3): Boolean;
    { Use: open a door in front of the player, or talk to a character
      (idAI::TalkTo) there. }
    procedure Use(const Origin, Dir: TVector3);
    procedure DamagePlayer(const Amount: Integer); overload;
    { idPlayer::Damage with a damage def (its kick_time, kick_amplitude,
      blob_*, mtr_blob) and the direction of the force (CGE, from the
      attacker; zero: none): the view kicks, blobs and the tunnel vision
      show, the player cries out (pain_delay apart) }
    procedure DamagePlayer(const Amount: Integer; const DamageDefName: String;
      const Direction: TVector3); overload;
    { Doom 3's falling speed (gravity 1066) after Seconds of falling, at
      least FallSpeedMin (stepping down stays quick) }
    class function FallSpeed(const Seconds: Single): Single; static;
    { The screen blobs still showing (idPlayerView's screenBlobs). }
    function ScreenBlobs: specialize TArray<TD3ScreenBlob>;
    { Seconds since the player was last hurt (large when never). }
    function SinceDamage: Single;
    { idPlayerView::DoubleVision's shift (0..0.5 of the screen's width; 0:
      no double vision) }
    function DoubleVisionShift: Single;
    { The armor's screen effect (armorViewEffect) after armor took a hit:
      1 fading to 0 in 0.25 s }
    function ArmorPulse: Single;
    { The knockback's move for this frame (CGE), its velocity slowed by
      Doom 3's ground friction; the view moves the camera by it. }
    function KnockbackMove(const SecondsPassed: Single): TVector3;
    property KnockbackVelocity: TVector3 read FKnockVel;

    function PlayerDead: Boolean;
    { Fire the targets of E after Delay seconds (idEntity::ActivateTargets). }
    procedure ActivateTargets(const E: TD3MapEntity; const Delay: Single = 0);
    { Activate one entity (its Event_Activate), as if a trigger targeted it. }
    procedure Activate(const E: TD3MapEntity);
    { The map entity with this name, nil if none. }
    function FindEntity(const AName: String): TD3MapEntity;
    { For TD3GameScriptHost: scripts' entity handles and events. }
    function ScriptFindEntity(const AName: String): Integer;
    function ScriptEntityName(const Handle: Integer): String;
    function ScriptEntityBusy(const Handle: Integer): Boolean;
    function ScriptEvent(const Thread: TD3ScriptThread; const Target: Integer; const Event: TD3ScriptEvent;
      const Args: TD3ValueArray; var EventResult: TD3Value): Boolean;
    function ScriptEntityObject(const Handle: Integer): TD3ScriptObject;
    { One line: script threads, moving entities. }
    function ScriptStatus: String;
    { One line per actor: state, legs state, animation, position. }
    function ActorStatus: String;
    { A cinematic camera (idCameraAnim, idCameraView) sets the view. }
    function CinematicActive: Boolean;
    { The cinematic camera's view in CGE coordinates, its horizontal field
      of view in degrees. }
    procedure CinematicView(out Position, Direction, Up: TVector3; out FovDeg: Single);
    { Stop the cinematic camera (its targets fire), like Escape in Doom 3. }
    procedure SkipCinematic;
    { Color over the screen (alpha 0: nothing), from trigger_fade and the
      scripts' fades. }
    function FadeColor: TVector4;
    { info_player_teleport asked to move the player: where (feet). }
    function TakeTeleport(out FeetPos: TVector3; out YawDeg: Single): Boolean;
    { The name of the playing cinematic camera entity, '' if none. }
    function CinematicName: String;
    { The compiled scripts of the map (nil: none, or they don't compile). }
    property Script: TD3ScriptVM read FScript;
    { Seconds the player has been dead. }
    property DeadTime: Single read FDeadTime;
    property Movers: specialize TObjectList<TD3Mover> read FMovers;
    property Monsters: specialize TObjectList<TD3Monster> read FMonsters;
    property Triggers: specialize TObjectList<TD3Trigger> read FTriggers;
    property Animated: specialize TObjectList<TD3Animated> read FAnimated;
    property Actors: specialize TObjectList<TD3Actor> read FActors;
    property Projectiles: specialize TObjectList<TD3Projectile> read FProjectiles;
    property Aas: TD3AasFile read FAas;
    property CombatNodes: specialize TObjectList<TD3CombatNode> read FCombatNodes;
    property Moveables: specialize TObjectList<TD3Moveable> read FMoveables;
    property Items: specialize TObjectList<TD3Item> read FItems;
    { inventory (idInventory, idPlayer::Give) }
    { the player's entityDef: player_doommarine, else the test level's
      player_test (nil without one) }
    property PlayerDef: TStringList read FPlayerDef;
    { idPlayer::Give / idInventory::Give: one stat ("health", "armor",
      "ammo_bullets", "weapon", "inclip_<ammo>", "item"...); False when it
      took nothing (full) }
    function Give(const Stat, Value: String): Boolean;
    { an item's pickup (idItem::Pickup): True when the player took it }
    function PickupItem(const Item: TD3Item): Boolean;
    function AmmoCount(const AmmoClass: String): Integer;
    procedure SetAmmo(const AmmoClass: String; const Count: Integer);
    { max_<ammo class> of the player def (0: none can be carried) }
    function MaxAmmo(const AmmoClass: String): Integer;
    { the slot of a weapon entityDef name (def_weaponN), -1 if none }
    function WeaponSlot(const WeaponName: String): Integer;
    function HasWeapon(const Slot: Integer): Boolean;
    { carried items (inv_carry: keys, PDAs) by inv_name }
    property Carried: TStringList read FCarried;
    { inventory as text, for the console }
    function InventoryStatus: String;
    { "give all": full health and armor, every weapon, full ammo }
    procedure GiveAll;
    { Attack once (a demo script's fire): holds WEAPON_ATTACK until the
      weapon fires, or a second passes. }
    procedure AttackOnce;
    { idPlayer::SelectWeapon: switch to the weapon in a slot (if carried),
      lowering the current one first. }
    procedure SelectWeapon(const Slot: Integer);
    { The next (Delta 1) or previous (-1) carried weapon. }
    procedure NextWeapon(const Delta: Integer);
    { WEAPON_RELOAD for a frame }
    procedure ReloadWeapon;
    { The current weapon, nil before the first update or without a
      player def. }
    property Weapon: TD3Weapon read FWeapon;
    { The slot being switched to (or the current one). }
    property IdealSlot: Integer read FIdealSlot;
    { "PISTOL  12 / 24" for the HUD }
    function WeaponHudText: String;
    { The weapon's muzzle flash light while it shows (flashTime after a
      shot): where (CGE, world), its color and radius. False when there's
      none (then the built-in pistol's flash may show, SinceFire). }
    function MuzzleFlash(out Position, Color: TVector3; out Radius: Single): Boolean;
    { The player's horizontal speed and the bob's sine (0..1), for tests }
    property PlayerSpeed: Single read FXYSpeed;
    { The view's bob (idPlayer::GetViewPos): add the offset (CGE) to the
      eye and the angles (Doom 3 pitch, yaw, roll) to the view angles.
      Zero when ViewBobEnabled is false or the player is dead. }
    function ViewBobOffset: TVector3;
    function ViewBobAngles: TVector3;
    { the view axis with the bob (Doom 3 rows) }
    function BobbedViewAxis: TMatrix3;
    property BobFracSin: Single read FBobFracSin;
    function MoveableOf(const E: TD3MapEntity): TD3Moveable;
    { Throw a moveable at Velocity (Doom 3), its damage on for 2.5 s
      (idAI_Vagary::Event_ThrowObjectAtEnemy, idMoveable::EnableDamage) }
    procedure ThrowMoveable(const M: TD3Moveable; const Velocity: TVector3);
    { idAI::PredictTrajectory without the collision checks: the direction
      to launch at Speed from From to hit Target with Gravity (the lower
      arc), False when out of reach (then straight at it). Doom 3. }
    function BallisticDir(const From, Target: TVector3; const Speed, Gravity: Single;
      out Dir: TVector3): Boolean;
    { The location (an info_location's "location" key, lowercase; '' when
      none) of a portal area, or of a point in CGE coordinates, like
      idGameLocal::LocationForPoint. Locations spread from their area
      through portals, but not through closed doors or
      info_locationSeparator portals (idGameLocal::SpreadLocations). }
    function LocationOfArea(const Area: Integer): String;
    function LocationAt(const P: TVector3): String;
    { Where a monster at Pos (feet, Doom 3 coordinates) heads for to get to
      Goal: the next reachability of its AAS route (idAI::PathToGoal), or
      Goal itself (same area, no AAS, no route). }
    function RouteWaypoint(var Route: TD3Route; const Pos, Goal: TVector3): TVector3;
    { The point a flyer at Pos (Doom 3 coordinates) heads for to get to
      Goal (idAASLocal::FlyPathToGoal): along its AAS route (walk, air
      and fly reachabilities) the furthest point it can fly straight to,
      Goal itself in the same area or without an AAS. }
    function FlyRouteWaypoint(var Route: TD3Route; const Pos, Goal: TVector3;
      const Radius, Height: Single): TVector3;
    { Room for a box of that radius and height to fly straight from From to
      Dest (Doom 3 coordinates, origins at the box's bottom) }
    function FlyPathClear(const From, Dest: TVector3; const Radius, Height: Single): Boolean;
    { The AAS route from an entity to the player, for the console "aas". }
    function RouteStatus(const EntityName: String): String;
    { A projectile of an entityDef (idProjectile: def_damage,
      def_splash_damage, fuse...) flying from From (CGE coordinates) with
      Velocity; nil if there's no such def. }
    function SpawnProjectile(const DefName, Owner: String; const From, Velocity: TVector3): TD3Projectile;
    { idAI::Event_TestAnimMove: room for the anim's movement (turned to
      Yaw) from where it stands: nothing in the way, no ledge }
    function AnimMoveClear(const A: TD3Actor; const AnimName: String; const Yaw: Single): Boolean;
    { the script's kill: dies like from a shot (not counted as a kill) }
    procedure KillActor(const A: TD3Actor);
    { its collision size: the monster's, else the entity's "size" (idAI:
      width and height, default 32 x 72) }
    function ActorRadius(const A: TD3Actor): Single;
    function ActorHeight(const A: TD3Actor): Single;
    { idAI::CreateProjectile: the monster's def_projectile, held at the
      joint until launched (nil without a def_projectile) }
    function CreateMissile(const A: TD3Actor; const JointName: String): TD3Projectile;
    { idAI::LaunchProjectile: num_projectiles of its def_projectile from
      the joint (the held one first) at the target (the player's chest
      when AtPlayer, else TargetPos when HasTarget, else straight ahead),
      wobbling by attack_accuracy, the yaw kept within attack_cone of its
      facing when ClampToCone, each spread by projectile_spread }
    function LaunchMissile(const A: TD3Actor; const JointName: String;
      const AtPlayer, HasTarget: Boolean; const TargetPos: TVector3;
      const ClampToCone: Boolean): TD3Projectile;
    { idAI::Event_LaunchMissile: one projectile from Origin along Angles
      (Doom 3 coordinates and pitch, yaw, roll) }
    function LaunchMissileFrom(const A: TD3Actor; const Origin, Angles: TVector3): TD3Projectile;
    { Game time (seconds since Spawn). }
    property Time: Single read FTime;
    property Map: TDoom3Map read FMap;
    property OnMessage: TD3MessageEvent read FOnMessage write FOnMessage;
  end;

const
  { Doom 3 player: eye at 68 above the feet, bounding box 32 wide }
  PlayerEyeHeight = 68;
  PlayerRadius = 16;
  { the player's entity handle for scripts (it's not a map entity) }
  PlayerHandle = $7FFFFF00;
  { the player's weapon's handle (its script object's self) }
  WeaponHandle = $7FFFFF01;
  { idAI's moveType_t }
  MoveTypeDead = 0;
  MoveTypeAnim = 1;
  MoveTypeSlide = 2;
  MoveTypeFly = 3;
  MoveTypeStatic = 4;

var
  { Script objects of monsters that run their AI script (the others use the
    game's simple AI): the object or one it derives from. }
  ScriptedMonsterObjects: array of String;

{ Doom 3 angles (pitch down, yaw) of a direction in Doom 3 coordinates. }
function D3DirPitch(const D: TVector3): Single;
function D3DirYaw(const D: TVector3): Single;

implementation

uses
  Math,
  CastleLog, CastleUtils,
  Generics.Defaults,
  Doom3Files, Doom3Collision, Doom3Portals, Doom3Lexer, Doom3Expressions;

const
  MonsterWalkSpeed = 90;
  MonsterSightRange = 1200;
  MonsterMeleeRange = 64;
  MonsterAttackDelay = 1.1;
  MonsterDamage = 10;
  PistolDamage = 14;
  PistolDelay = 0.35;

{ TD3Mover }

{ Doom 3 angles (pitch down, yaw) of a direction in Doom 3 coordinates,
  and back (idVec3::ToAngles, idAngles::ToForward). }
function D3DirPitch(const D: TVector3): Single;
begin
  Result := -RadToDeg(ArcTan2(D.Z, Sqrt(Sqr(D.X) + Sqr(D.Y))));
end;

function D3DirYaw(const D: TVector3): Single;
begin
  Result := RadToDeg(ArcTan2(D.Y, D.X));
end;

function D3Forward(const Pitch, Yaw: Single): TVector3;
var
  SP, CP, SY, CY: Single;
begin
  SinCos(DegToRad(Pitch), SP, CP);
  SinCos(DegToRad(Yaw), SY, CY);
  Result := Vector3(CP * CY, CP * SY, -SP);
end;

function Normalize180(const A: Single): Single;
begin
  Result := A - 360 * Floor((A + 180) / 360);
end;

{ The distance from segment A..B to the player's axis (Feet to Eye),
  sampled at 9 points; CGE coordinates. }
function SegmentToPlayerDistance(const A, B, Feet, Eye: TVector3): Single;
var
  K: Integer;
  Q, Closest: TVector3;
begin
  Result := MaxSingle;
  for K := 0 to 8 do
  begin
    Q := A + (B - A) * (K / 8);
    Closest := Vector3(Eye.X, EnsureRange(Q.Y, Feet.Y, Eye.Y), Eye.Z);
    Result := Min(Result, (Q - Closest).Length);
  end;
end;

procedure TD3Mover.Open;
begin
  if Locked or (Kind <> mkDoor) then
    Exit;
  if State in [dsClosed, dsClosing] then
  begin
    State := dsOpening;
    if (Sounds <> nil) and (SoundOpen <> nil) then
      Sounds.Play(SoundOpen);
  end;
  Timer := 0;
end;

procedure TD3Mover.Close;
begin
  if State in [dsOpen, dsOpening] then
  begin
    State := dsClosing;
    if (Sounds <> nil) and (SoundClose <> nil) then
      Sounds.Play(SoundClose);
  end;
end;

procedure TD3Mover.Update(const SecondsPassed: Single);
var
  Step: Single;
begin
  case Kind of
    mkRotating:
      if Running then
      begin
        Angle := Angle + RotSpeed * SecondsPassed;
        Brush.Scene.Rotation := Vector4(RotAxis, DegToRad(Angle));
      end;
    mkDoor:
      begin
        if Distance <= 0 then
          Exit;
        Step := Speed * SecondsPassed / Distance;
        case State of
          dsOpening:
            begin
              Progress := Min(1, Progress + Step);
              if Progress >= 1 then
              begin
                State := dsOpen;
                Timer := 0;
              end;
            end;
          dsOpen:
            if Wait >= 0 then
            begin
              Timer := Timer + SecondsPassed;
              if Timer >= Wait then
                Close;
            end;
          dsClosing:
            begin
              Progress := Max(0, Progress - Step);
              if Progress <= 0 then
                State := dsClosed;
            end;
          else ;
        end;
        Brush.Scene.Translation := ClosedPos + MoveDir * (Distance * Progress);
      end;
  end;
end;

{ TD3Monster }

function TD3Monster.Position: TVector3;
begin
  Result := Model.Holder.Translation;
end;

function TD3Monster.Center: TVector3;
begin
  Result := Model.Holder.Translation + Vector3(0, Height / 2, 0);
end;

{ TD3Speaker }

destructor TD3Speaker.Destroy;
begin
  { the transform owns the sound source behavior }
  FreeAndNil(Transform);
  inherited Destroy;
end;

{ TD3Game }

type
  { Scripts' view of the game: forwards to TD3Game. }
  TD3GameScriptHost = class(TD3ScriptHost)
    Game: TD3Game;
    constructor Create(const AGame: TD3Game);
    function FindEntity(const AName: String): Integer; override;
    function EntityName(const E: Integer): String; override;
    function EntityBusy(const E: Integer): Boolean; override;
    function EntityObject(const E: Integer): TD3ScriptObject; override;
    function CallEvent(const Thread: TD3ScriptThread; const Target: Integer;
      const Event: TD3ScriptEvent; const Args: TD3ValueArray;
      var EventResult: TD3Value): Boolean; override;
  end;

constructor TD3GameScriptHost.Create(const AGame: TD3Game);
begin
  inherited Create;
  Game := AGame;
end;

function TD3GameScriptHost.FindEntity(const AName: String): Integer;
begin
  Result := Game.ScriptFindEntity(AName);
end;

function TD3GameScriptHost.EntityName(const E: Integer): String;
begin
  Result := Game.ScriptEntityName(E);
end;

function TD3GameScriptHost.EntityBusy(const E: Integer): Boolean;
begin
  Result := Game.ScriptEntityBusy(E);
end;

function TD3GameScriptHost.EntityObject(const E: Integer): TD3ScriptObject;
begin
  Result := Game.ScriptEntityObject(E);
end;

function TD3GameScriptHost.CallEvent(const Thread: TD3ScriptThread; const Target: Integer;
  const Event: TD3ScriptEvent; const Args: TD3ValueArray; var EventResult: TD3Value): Boolean;
begin
  Result := Game.ScriptEvent(Thread, Target, Event, Args, EventResult);
end;

constructor TD3Game.Create(const AMap: TDoom3Map);
begin
  inherited Create;
  FMap := AMap;
  FMovers := specialize TObjectList<TD3Mover>.Create(True);
  FMonsters := specialize TObjectList<TD3Monster>.Create(True);
  FSpeakers := specialize TObjectList<TD3Speaker>.Create(True);
  FSounds := specialize TObjectDictionary<String, TCastleSound>.Create([doOwnsValues]);
  FTriggers := specialize TObjectList<TD3Trigger>.Create(True);
  FEntities := specialize TDictionary<String, TD3MapEntity>.Create;
  FPending := specialize TList<TD3PendingTargets>.Create;
  FBindings := specialize TObjectList<TD3Binding>.Create(True);
  FHandles := specialize TDictionary<String, Integer>.Create;
  FScriptMovers := specialize TObjectDictionary<Integer, TD3ScriptMover>.Create([doOwnsValues]);
  FScriptHost := TD3GameScriptHost.Create(Self);
  FCameraAnims := specialize TObjectDictionary<String, TD3CameraAnim>.Create([doOwnsValues]);
  FLightFades := specialize TList<TD3LightFade>.Create;
  FAnimated := specialize TObjectList<TD3Animated>.Create(True);
  FActors := specialize TObjectList<TD3Actor>.Create(True);
  FProjectiles := specialize TObjectList<TD3Projectile>.Create(True);
  FCombatNodes := specialize TObjectList<TD3CombatNode>.Create(True);
  FMoveables := specialize TObjectList<TD3Moveable>.Create(True);
  FItems := specialize TObjectList<TD3Item>.Create(True);
  FAmmo := specialize TDictionary<String, Integer>.Create;
  FCarried := TStringList.Create;
  FSoundSources := specialize TDictionary<Integer, TCastleSoundSource>.Create;
  FSoundTransforms := specialize TObjectList<TCastleTransform>.Create(True);
  FScriptSounds := specialize TObjectDictionary<String, TCastlePlayingSoundSource>.Create([doOwnsValues]);
  FCounts := specialize TDictionary<String, Integer>.Create;
  FUnsupported := TStringList.Create;
  FUnsupported.Sorted := True;
  Health := 100;
  FIdealSlot := -1;
  ViewBobEnabled := True;
  FLandTime := -1000;
  FLastDamageTime := -1000;
  FPainDebounce := -1000;
  FLastArmorPulse := -1000;
  FDvFinish := -1000;
  FStepUpTime := -1000;
end;

destructor TD3Game.Destroy;
begin
  Clear;
  FMovers.Free;
  FMonsters.Free;
  FSpeakers.Free;
  FSounds.Free;
  FTriggers.Free;
  FEntities.Free;
  FPending.Free;
  FBindings.Free;
  FCounts.Free;
  FUnsupported.Free;
  FreeAndNil(FScript);
  FScriptHost.Free;
  FHandles.Free;
  FScriptMovers.Free;
  FCameraAnims.Free;
  FLightFades.Free;
  FAnimated.Free;
  FActors.Free;
  FProjectiles.Free;
  FCombatNodes.Free;
  FMoveables.Free;
  FItems.Free;
  FAmmo.Free;
  FCarried.Free;
  FScriptSounds.Free;
  FSoundSources.Free;
  FSoundTransforms.Free;
  inherited Destroy;
end;

procedure TD3Game.Message(const S: String);
begin
  WritelnLog('Doom3World', 'Message: ' + S);
  if Assigned(FOnMessage) then
    FOnMessage(S);
end;

procedure TD3Game.Clear;
begin
  FreeAndNil(FAas);
  FLocations := nil;
  FCombatNodes.Clear;
  FMoveables.Clear;
  FItems.Clear;
  FMovers.Clear;
  FMonsters.Clear;
  FSpeakers.Clear;
  FTriggers.Clear;
  FEntities.Clear;
  FPending.Clear;
  FBindings.Clear;
  FCounts.Clear;
  FUnsupported.Clear;
  FActors.Clear;
  { before the VM (it owns the weapon's thread) and the map }
  FreeAndNil(FWeapon);
  FreeAndNil(FScript);
  FHandles.Clear;
  FScriptMovers.Clear;
  FCameraEntity := nil;
  FCameraAnim := nil;
  FSkipUntil := 0;
  FFadeFrom := Vector4(0, 0, 0, 0);
  FFadeTo := Vector4(0, 0, 0, 0);
  FFadeTime := 0;
  FTeleportPending := False;
  FLightFades.Clear;
  FAnimated.Clear;
  { before the VM goes (it owns the actors' threads) }
  FActors.Clear;
  FProjectiles.Clear;
  ProjectilesLaunched := 0;
  ClearScriptSounds;
  FTime := 0;
  ActivationCount := 0;
end;

function TD3Game.SoundFromShader(const ShaderName: String): TCastleSound;
const
  { Doom 3 sound shader distances are in meters, the world in inches }
  MetersToUnits = 39.37;
var
  Shader: TD3SoundShader;
begin
  Result := nil;
  if ShaderName = '' then
    Exit;
  if FSounds.TryGetValue(LowerCase(ShaderName), Result) then
    Exit;
  Shader := Decls.SoundShader(ShaderName);
  if (Shader <> nil) and (Shader.Files.Count > 0) and D3Fs.FileExists(Shader.Files[0]) then
  begin
    Result := TCastleSound.Create(nil);
    Result.Url := D3FsUrl(Shader.Files[0]);
    Result.ReferenceDistance := Max(1, Shader.MinDistance) * MetersToUnits;
    Result.MaxDistance := Max(Shader.MinDistance + 1, Shader.MaxDistance) * MetersToUnits;
    { volume is in dB }
    Result.Volume := Min(1, Power(10, Shader.Volume / 20));
  end else
    WritelnLog('Doom3World', 'Sound shader "%s" not found', [ShaderName]);
  FSounds.Add(LowerCase(ShaderName), Result);
end;

procedure TD3Game.SpawnMover(const B: TD3BrushEntity);
var
  E: TD3MapEntity;
  M: TD3Mover;
  Cls: String;
  MoveAngle: Single;
  Dir, Size: TVector3;
  TriggerSize: Single;
  Box: TBox3D;
begin
  E := B.Entity;
  Cls := LowerCase(E.ClassName_);
  if Cls = 'func_door' then
  begin
    M := TD3Mover.Create;
    M.Brush := B;
    M.Kind := mkDoor;
    M.ClosedPos := B.Scene.Translation;
    MoveAngle := E.FloatValue('movedir', E.FloatValue('angle', 0));
    if Abs(MoveAngle + 1) < 0.01 then
      Dir := Vector3(0, 0, 1) { up }
    else
    if Abs(MoveAngle + 2) < 0.01 then
      Dir := Vector3(0, 0, -1) { down }
    else
      Dir := Vector3(Cos(DegToRad(MoveAngle)), Sin(DegToRad(MoveAngle)), 0);
    { like idDoor: the size of the door's world bounds along the move
      direction (doors are often rotated: "rotation" on 137 of the demo's
      155 doors), minus "lip" }
    Box := B.Scene.BoundingBox;
    Size := CgeToD3(Box.Size);
    Size := Vector3(Abs(Size.X), Abs(Size.Y), Abs(Size.Z));
    M.Distance := Abs(Dir.X) * Size.X + Abs(Dir.Y) * Size.Y + Abs(Dir.Z) * Size.Z -
      E.FloatValue('lip', 8);
    M.MoveDir := D3ToCge(Dir);
    { defaults of Doom 3's func_door entityDef (used when the data has none) }
    M.Speed := E.FloatValue('speed', 100);
    if E.HasKey('time') and (E.FloatValue('time') > 0) then
      M.Speed := Max(1, M.Distance) / E.FloatValue('time');
    M.Wait := E.FloatValue('wait', 3);
    M.Locked := E.BoolValue('locked');
    M.NoTouch := E.BoolValue('no_touch');
    M.Team := LowerCase(E.Value('team'));
    { Doom 3 doors open when you enter a trigger around them }
    TriggerSize := E.FloatValue('triggersize', 60);
    M.TriggerBox := Box.Grow(TriggerSize);
    M.SoundOpen := SoundFromShader(E.Value('snd_open'));
    M.SoundClose := SoundFromShader(E.Value('snd_close'));
    if (M.SoundOpen <> nil) or (M.SoundClose <> nil) then
    begin
      M.Sounds := TCastleSoundSource.Create(B.Scene);
      M.Sounds.Spatial := True;
      B.Scene.AddBehavior(M.Sounds);
    end;
    if FMap.Portals <> nil then
      M.Portals := FMap.Portals.PortalsInBox(B.Scene.BoundingBox.Grow(16));
    FMovers.Add(M);
  end else
  if (Cls = 'func_rotating') or (Cls = 'func_fx_rotating') then
  begin
    M := TD3Mover.Create;
    M.Brush := B;
    M.Kind := mkRotating;
    M.RotSpeed := E.FloatValue('speed', 100);
    if E.BoolValue('x_axis') then
      M.RotAxis := D3ToCge(Vector3(1, 0, 0))
    else
    if E.BoolValue('y_axis') then
      M.RotAxis := D3ToCge(Vector3(0, 1, 0))
    else
      M.RotAxis := D3ToCge(Vector3(0, 0, 1));
    M.Angle := E.Angle;
    M.Running := E.BoolValue('start_on', True);
    FMovers.Add(M);
  end;
end;

procedure TD3Game.SpawnSpeaker(const E: TD3MapEntity);
var
  S: TD3Speaker;
  Snd: TCastleSound;
  Shader: TD3SoundShader;
begin
  Snd := SoundFromShader(E.Value('s_shader'));
  if Snd = nil then
    Exit;
  S := TD3Speaker.Create;
  S.Entity := E;
  S.Sound := Snd;
  S.Transform := TCastleTransform.Create(nil);
  S.Transform.Name := 'Speaker_' + IntToStr(FSpeakers.Count);
  S.Transform.Translation := D3ToCge(E.Origin);
  S.Source := TCastleSoundSource.Create(S.Transform);
  S.Source.Spatial := not E.BoolValue('s_global');
  S.Transform.AddBehavior(S.Source);
  FMap.Add(S.Transform);
  Shader := Decls.SoundShader(E.Value('s_shader'));
  S.Looping := (Shader <> nil) and (Shader.Looping or E.BoolValue('s_looping'));
  if S.Looping then
  begin
    if not E.BoolValue('s_waitfortrigger') then
      S.Source.Sound := Snd;
  end else
  if not E.BoolValue('s_waitfortrigger') then
    S.Source.Play(Snd);
  FSpeakers.Add(S);
end;

function TD3Game.RouteWaypoint(var Route: TD3Route; const Pos, Goal: TVector3): TVector3;
const
  { a reachability point this close (horizontally) is passed }
  Reached = 12;
var
  FromArea, ToArea, I: Integer;
  P: TVector3;
begin
  Result := Goal;
  if FAas = nil then
    Exit;
  FromArea := FAas.OriginAreaNum(Pos);
  ToArea := FAas.OriginAreaNum(Goal);
  if (FromArea = 0) or (ToArea = 0) or (FromArea = ToArea) then
    Exit;
  if (Route.FromArea <> FromArea) or (Route.ToArea <> ToArea) or Route.Fly then
  begin
    Route.FromArea := FromArea;
    Route.ToArea := ToArea;
    Route.Fly := False;
    Route.Found := FAas.FindPath(FromArea, ToArea, WalkingTravelFlags, Route.Path);
  end;
  if not Route.Found then
    Exit;
  { the first reachability end not reached yet (an origin on an area's
    edge can still be in the area it's leaving) }
  for I := 0 to High(Route.Path) do
  begin
    P := FAas.Areas[Route.Path[I].Area].Reach[Route.Path[I].Reach].Stop;
    if Sqr(P.X - Pos.X) + Sqr(P.Y - Pos.Y) > Sqr(Reached) then
      Exit(P);
  end;
end;

function TD3Game.FlyPathClear(const From, Dest: TVector3; const Radius, Height: Single): Boolean;
var
  A, B, Side: TVector3;
begin
  { its center line, and both sides of it (CGE coordinates) }
  A := D3ToCge(From) + Vector3(0, Height / 2, 0);
  B := D3ToCge(Dest) + Vector3(0, Height / 2, 0);
  Side := TVector3.CrossProduct(B - A, Vector3(0, 1, 0));
  if Side.IsZero then
    Side := Vector3(1, 0, 0);
  Side := Side.Normalize * Radius;
  Result := not FMap.World.WorldSegmentCollision(A, B) and
    not FMap.World.WorldSegmentCollision(A + Side, B + Side) and
    not FMap.World.WorldSegmentCollision(A - Side, B - Side);
end;

function TD3Game.FlyRouteWaypoint(var Route: TD3Route; const Pos, Goal: TVector3;
  const Radius, Height: Single): TVector3;

  function AreaOf(const P: TVector3): Integer;
  begin
    { a flyer's origin is in the air: the area it's in, else the one below }
    Result := FAas.PointAreaNum(P + Vector3(0, 0, 1));
    if Result = 0 then
      Result := FAas.OriginAreaNum(P);
  end;

var
  FromArea, ToArea, I: Integer;
  R: TD3AasReach;
begin
  Result := Goal;
  if FAas = nil then
    Exit;
  FromArea := AreaOf(Pos);
  ToArea := AreaOf(Goal);
  if (FromArea = 0) or (ToArea = 0) or (FromArea = ToArea) then
    Exit;
  if (Route.FromArea <> FromArea) or (Route.ToArea <> ToArea) or not Route.Fly then
  begin
    Route.FromArea := FromArea;
    Route.ToArea := ToArea;
    Route.Fly := True;
    Route.Found := FAas.FindPath(FromArea, ToArea, WalkingTravelFlags or TFL_FLY, Route.Path);
  end;
  if not Route.Found or (Length(Route.Path) = 0) then
    Exit;
  { idAASLocal::FlyPathToGoal: along the route, the furthest reachability
    start or end it can fly straight to; the goal when it sees it }
  Result := Pos;
  for I := 0 to High(Route.Path) do
  begin
    R := FAas.Areas[Route.Path[I].Area].Reach[Route.Path[I].Reach];
    if not FlyPathClear(Pos, R.Start, Radius, Height) then
    begin
      if I = 0 then
        Result := R.Start;
      Exit;
    end;
    Result := R.Start;
    if not FlyPathClear(Pos, R.Stop, Radius, Height) then
      Exit;
    Result := R.Stop;
  end;
  if FlyPathClear(Pos, Goal, Radius, Height) then
    Result := Goal;
end;

function TD3Moveable.Origin: TVector3;
begin
  Result := CgeToD3(Brush.Scene.Translation);
end;

procedure TD3Game.SpawnMoveable(const B: TD3BrushEntity);
var
  M: TD3Moveable;
  E: TD3MapEntity;
begin
  { idMoveable::Spawn }
  E := B.Entity;
  M := TD3Moveable.Create;
  M.Brush := B;
  M.AtRest := True;
  M.Bounce := EnsureRange(E.FloatValue('bouncyness', 0.6), 0, 1);
  M.DamageDef := E.Value('def_damage');
  M.CanDamage := not E.BoolValue('damageWhenActive');
  M.MinDamageVelocity := E.FloatValue('minDamageVelocity', 100);
  M.MaxDamageVelocity := E.FloatValue('maxDamageVelocity', 200);
  M.HalfSize := (B.LocalMax - B.LocalMin) * 0.5;
  M.CenterOffset := (B.LocalMax + B.LocalMin) * 0.5;
  FMoveables.Add(M);
end;

function TD3Game.MoveableOf(const E: TD3MapEntity): TD3Moveable;
begin
  for Result in FMoveables do
    if Result.Brush.Entity = E then
      Exit;
  Result := nil;
end;

{ Items and the inventory ---------------------------------------------------- }

var
  LangStrings: TStringList;

{ "#str_01234" through strings/english.lang (idLangDict), else as is }
function LangString(const S: String): String;
var
  L: TDoom3Lexer;
  Key: String;
begin
  if Copy(S, 1, 5) <> '#str_' then
    Exit(S);
  if LangStrings = nil then
  begin
    LangStrings := TStringList.Create;
    LangStrings.CaseSensitive := False;
    if D3Fs.FileExists('strings/english.lang') then
    begin
      L := TDoom3Lexer.Create(D3Fs.ReadText('strings/english.lang'));
      try
        L.Expect('{');
        while L.Next(Key) and (Key <> '}') do
          LangStrings.Values[Key] := L.NextStr;
      finally
        L.Free;
      end;
    end;
  end;
  Result := LangStrings.Values[S];
  if Result = '' then
    Result := S;
end;

procedure TD3Game.SpawnItem(const E: TD3MapEntity);
var
  It: TD3Item;
  Size: Single;
  Lo, Hi: TVector3;
begin
  { idItem::Spawn }
  It := TD3Item.Create;
  It.Entity := E;
  if E.Name <> '' then
    It.Brush := FMap.FindBrush(E.Name);
  It.SpawnOrigin := E.Origin;
  It.Number := FMap.MapFile.Entities.IndexOf(E);
  It.Spin := E.BoolValue('spin');
  It.CanPickUp := not (E.BoolValue('triggerFirst') or E.BoolValue('no_touch'));
  { touched within triggersize of its origin, else its model's bounds
    (idMoveableItem: expanded by triggersize, 16 by default) }
  if (E.Value('spawnclass') <> 'idMoveableItem') and E.HasKey('triggersize') then
  begin
    Size := E.FloatValue('triggersize');
    It.Box := Box3D(It.SpawnOrigin - Vector3(Size, Size, Size), It.SpawnOrigin + Vector3(Size, Size, Size));
  end else
  begin
    if It.Brush <> nil then
    begin
      Lo := It.Brush.LocalMin;
      Hi := It.Brush.LocalMax;
    end else
    begin
      Lo := Vector3(-16, -16, 0);
      Hi := Vector3(16, 16, 16);
    end;
    if E.Value('spawnclass') = 'idMoveableItem' then
    begin
      Size := E.FloatValue('triggersize', 16);
      Lo := Lo - Vector3(Size, Size, Size);
      Hi := Hi + Vector3(Size, Size, Size);
    end;
    { rotation ignored: items are small }
    It.Box := Box3D(It.SpawnOrigin + Lo, It.SpawnOrigin + Hi);
  end;
  if E.BoolValue('start_off') and (It.Brush <> nil) then
    It.Brush.SetHidden(True);
  FItems.Add(It);
end;

function TD3Game.ItemOf(const E: TD3MapEntity): TD3Item;
begin
  for Result in FItems do
    if Result.Entity = E then
      Exit;
  Result := nil;
end;

procedure TD3Game.InitInventory;
var
  Def: TStringList;
  I: Integer;
  K: String;
begin
  { the damage effects of the last map end }
  FDvFinish := -1000;
  FKnockVel := TVector3.Zero;
  FKickFinish := 0;
  FBlobs := nil;
  FLastDamageTime := -1000;
  FLastArmorPulse := -1000;
  FPainDebounce := -1000;
  { idInventory::RestoreInventory with the player's spawnArgs }
  FAmmo.Clear;
  FCarried.Clear;
  FreeAndNil(FWeapon);
  FIdealSlot := -1;
  FAttackPulse := 0;
  WeaponBits := 0;
  for I := 0 to High(WeaponDefs) do
  begin
    WeaponDefs[I] := '';
    Clip[I] := -1;
  end;
  MaxHealth := 100;
  MaxArmor := 100;
  Def := Decls.EntityDef('player_doommarine');
  if Def = nil then
    Def := Decls.EntityDef('player_test');
  FPlayerDef := Def;
  if Def = nil then
    Exit;
  MaxHealth := StrToIntDef(Def.Values['maxhealth'], 100);
  MaxArmor := StrToIntDef(Def.Values['maxarmor'], 100);
  Armor := StrToIntDef(Def.Values['armor'], 50);
  for I := 0 to High(WeaponDefs) do
    WeaponDefs[I] := Def.Values['def_weapon' + IntToStr(I)];
  for I := 0 to Def.Count - 1 do
  begin
    K := LowerCase(Def.Names[I]);
    if Copy(K, 1, 5) = 'ammo_' then
      FAmmo.AddOrSetValue(K, StrToIntDef(Def.ValueFromIndex[I], 0));
  end;
  if Def.Values['weapon'] <> '' then
    Give('weapon', Def.Values['weapon']);
end;

function TD3Game.AmmoCount(const AmmoClass: String): Integer;
begin
  if not FAmmo.TryGetValue(LowerCase(AmmoClass), Result) then
    Result := 0;
end;

procedure TD3Game.SetAmmo(const AmmoClass: String; const Count: Integer);
begin
  FAmmo.AddOrSetValue(LowerCase(AmmoClass), Count);
end;

function TD3Game.MaxAmmo(const AmmoClass: String): Integer;
begin
  Result := 0;
  if FPlayerDef <> nil then
    Result := StrToIntDef(FPlayerDef.Values['max_' + LowerCase(AmmoClass)], 0);
end;

function TD3Game.WeaponSlot(const WeaponName: String): Integer;
var
  I: Integer;
begin
  for I := 0 to High(WeaponDefs) do
    if (WeaponDefs[I] <> '') and SameText(WeaponDefs[I], Trim(WeaponName)) then
      Exit(I);
  Result := -1;
end;

function TD3Game.HasWeapon(const Slot: Integer): Boolean;
begin
  Result := (Slot >= 0) and (Slot <= High(WeaponDefs)) and ((WeaponBits and (Cardinal(1) shl Slot)) <> 0);
end;

function TD3Game.Give(const Stat, Value: String): Boolean;
var
  S, AmmoClass: String;
  Amount, Have, Limit, I: Integer;
  Names: TStringArray;
  WeaponDef: TStringList;
begin
  { idPlayer::Give, idInventory::Give }
  Result := True;
  S := LowerCase(Stat);
  Amount := StrToIntDef(Trim(Value), 0);
  if S = 'health' then
  begin
    if Health >= MaxHealth then
      Exit(False);
    Health := Min(Health + Amount, MaxHealth);
  end else
  if Copy(S, 1, 5) = 'ammo_' then
  begin
    Have := AmmoCount(S);
    Limit := MaxAmmo(S);
    if Have >= Limit then
      Exit(False);
    Inc(Have, Amount);
    if (Limit > 0) and (Have > Limit) then
      Have := Limit;
    SetAmmo(S, Have);
  end else
  if S = 'armor' then
  begin
    if Armor >= MaxArmor then
      Exit(False);
    Armor := Min(Armor + Amount, MaxArmor);
  end else
  if Copy(S, 1, 7) = 'inclip_' then
  begin
    { the clip of the weapon using this ammo: set, not added }
    AmmoClass := Copy(S, 8, MaxInt);
    for I := 0 to High(WeaponDefs) do
      if WeaponDefs[I] <> '' then
      begin
        WeaponDef := Decls.EntityDef(WeaponDefs[I]);
        if (WeaponDef <> nil) and SameText(WeaponDef.Values['ammoType'], AmmoClass) then
        begin
          Clip[I] := Amount;
          Break;
        end;
      end;
  end else
  if S = 'weapon' then
  begin
    Result := False;
    Names := Value.Split([',']);
    for I := 0 to High(Names) do
    begin
      Amount := WeaponSlot(Names[I]);
      if Amount < 0 then
      begin
        WritelnWarning('Doom3World', 'Unknown weapon "%s"', [Trim(Names[I])]);
        Continue;
      end;
      if not HasWeapon(Amount) then
      begin
        WeaponBits := WeaponBits or (Cardinal(1) shl Amount);
        Result := True;
      end;
    end;
  end else
  if (S = 'item') or (S = 'icon') or (S = 'name') then
    Result := False
  else
  if (S = 'stamina') or (S = 'air') or (S = 'heartrate') or (S = 'berserk') or (S = 'mega') then
    { no stamina, air, powerups yet: taken, nothing happens }
    Result := True
  else
  begin
    Unsupported('inventory stat ' + S);
    Result := False;
  end;
end;

function TD3Game.PickupItem(const Item: TD3Item): Boolean;
var
  E: TD3MapEntity;
  I: Integer;
  K, ItemName: String;
begin
  Result := False;
  if Item.PickedUp or PlayerDead then
    Exit;
  E := Item.Entity;
  ItemName := LangString(E.Value('inv_name', E.Name));
  { idItem::GiveToPlayer: carried items (keys, PDAs, video discs) go to
    the inventory, the others give their inv_ keys }
  if E.BoolValue('inv_carry') or (E.Value('spawnclass') = 'idPDAItem') or
     (E.Value('spawnclass') = 'idMoveablePDAItem') or (E.Value('spawnclass') = 'idVideoCDItem') then
  begin
    FCarried.Add(ItemName);
    Result := True;
  end else
    for I := 0 to E.Pairs.Count - 1 do
    begin
      K := LowerCase(E.Pairs.Names[I]);
      if (Copy(K, 1, 4) = 'inv_') and (K <> 'inv_carry') then
        if Give(Copy(K, 5, MaxInt), E.Pairs.ValueFromIndex[I]) then
          Result := True;
    end;
  if not Result then
    Exit;
  { idItem::Pickup }
  Item.PickedUp := True;
  if Item.Brush <> nil then
    Item.Brush.SetHidden(True);
  PlaySoundAt(E.Value('snd_acquire'), D3ToCge(Item.SpawnOrigin));
  WritelnLog('Doom3World', 'Picked up %s (%s)', [E.Name, ItemName]);
  Message(ItemName);
  ActivateTargets(E);
end;

procedure TD3Game.UpdateItems;
var
  It: TD3Item;
  Feet, Org: TVector3;
  PlayerBox: TBox3D;
  Ms: Int64;
begin
  if FItems.Count = 0 then
    Exit;
  Feet := CgeToD3(FPlayerEye - Vector3(0, PlayerEyeHeight, 0));
  { the player's bounds, pm_bboxwidth 32, pm_normalheight 74 }
  PlayerBox := Box3D(Feet + Vector3(-16, -16, 0), Feet + Vector3(16, 16, 74));
  Ms := Round(FTime * 1000);
  for It in FItems do
  begin
    if It.PickedUp then
      Continue;
    if It.Spin and (It.Brush <> nil) and (It.Brush.Scene <> nil) then
    begin
      { idItem::Think }
      Org := It.SpawnOrigin;
      Org.Z := Org.Z + 4 + Cos((Ms + 2000) * (0.005 + It.Number * 0.00001)) * 4;
      It.Brush.Scene.Translation := D3ToCge(Org);
      SetD3Rotation(It.Brush.Scene, YawMatrix((Ms and 4095) * 360 / -4096));
    end;
    if It.CanPickUp and not PlayerDead and ((It.Brush = nil) or not It.Brush.Hidden) and
       It.Box.Collision(PlayerBox) then
      PickupItem(It);
  end;
end;

function TD3Game.InventoryStatus: String;
var
  I: Integer;
  Pair: specialize TPair<String, Integer>;
  Keys: TStringList;
begin
  Result := Format('health %d/%d, armor %d/%d', [Health, MaxHealth, Armor, MaxArmor]);
  if FPlayerDef = nil then
    Result := Result + ', no player def';
  Result := Result + LineEnding + 'weapons:';
  for I := 0 to High(WeaponDefs) do
    if HasWeapon(I) then
      Result := Result + Format(' %d %s (clip %d)', [I, WeaponDefs[I], Clip[I]]);
  Keys := TStringList.Create;
  try
    Keys.Sorted := True;
    for Pair in FAmmo do
      Keys.Add(Format('%s %d/%d', [Pair.Key, Pair.Value, MaxAmmo(Pair.Key)]));
    Keys.Delimiter := ',';
    Keys.StrictDelimiter := True;
    Result := Result + LineEnding + 'ammo: ' + StringReplace(Keys.DelimitedText, ',', ', ', [rfReplaceAll]);
  finally
    Keys.Free;
  end;
  FCarried.Delimiter := ',';
  FCarried.StrictDelimiter := True;
  Result := Result + LineEnding + 'items: ' + StringReplace(FCarried.DelimitedText, ',', ', ', [rfReplaceAll]);
end;

procedure TD3Game.GiveAll;
var
  I: Integer;
  K: String;
begin
  Health := Max(Health, MaxHealth);
  Armor := Max(Armor, MaxArmor);
  for I := 0 to High(WeaponDefs) do
    if WeaponDefs[I] <> '' then
      WeaponBits := WeaponBits or (Cardinal(1) shl I);
  if FPlayerDef <> nil then
    for I := 0 to FPlayerDef.Count - 1 do
    begin
      K := LowerCase(FPlayerDef.Names[I]);
      if Copy(K, 1, 9) = 'max_ammo_' then
        SetAmmo(Copy(K, 5, MaxInt), StrToIntDef(FPlayerDef.ValueFromIndex[I], 0));
    end;
end;

{ Weapons ------------------------------------------------------------------- }

destructor TD3Weapon.Destroy;
begin
  if (View <> nil) and (Holder <> nil) then
    Holder.Remove(View.Scene);
  FreeAndNil(View);
  FreeAndNil(Holder);
  FreeAndNil(Obj);
  inherited Destroy;
end;

procedure TD3Weapon.SetFlag(const AName: String; const Value: Boolean);
var
  I: Integer;
begin
  if (Obj <> nil) and Obj.Typ.FindField(AName, I) then
    Obj.Fields[I] := D3FloatValue(Ord(Value));
end;

function TD3Weapon.Flag(const AName: String): Boolean;
var
  I: Integer;
begin
  Result := (Obj <> nil) and Obj.Typ.FindField(AName, I) and (D3ValueToFloat(Obj.Fields[I]) <> 0);
end;

function TD3Weapon.Scripted: Boolean;
begin
  Result := (Obj <> nil) and (Thread <> nil);
end;

function TD3Game.HasAmmo(const AmmoClass: String; const Required: Integer): Integer;
begin
  if (AmmoClass = '') or (Required <= 0) then
    Exit(-1);
  Result := AmmoCount(AmmoClass);
  if Result < 0 then
    Exit(-1);
  Result := Result div Required;
end;

procedure TD3Game.UseAmmo(const AmmoClass: String; const Amount: Integer);
begin
  if (HasAmmo(AmmoClass, Amount) <= 0) or (AmmoCount(AmmoClass) < 0) then
    Exit;
  SetAmmo(AmmoClass, AmmoCount(AmmoClass) - Amount);
end;

function TD3Game.PlayerViewAxis: TMatrix3;
var
  D: TVector3;
begin
  if PlayerViewDir.IsZero then
    D := Vector3(1, 0, 0)
  else
    D := CgeToD3(PlayerViewDir);
  Result := AnglesMatrix(Vector3(D3DirPitch(D), D3DirYaw(D), 0));
end;

function TD3Game.SpawnWeapon(const Slot: Integer): TD3Weapon;
var
  W: TD3Weapon;
  T: TD3ScriptType;
  Decl: TD3ModelDecl;
  Md5: TD3Md5Model;
  Avail: Integer;
begin
  { idWeapon::GetWeaponDef }
  W := TD3Weapon.Create;
  Result := W;
  W.Slot := Slot;
  W.DefName := WeaponDefs[Slot];
  W.Def := Decls.EntityDef(W.DefName);
  W.Status := wsReady;
  if W.Def = nil then
  begin
    WritelnWarning('Doom3World', 'No weapon def "%s"', [W.DefName]);
    Exit;
  end;
  W.AmmoType := W.Def.Values['ammoType'];
  W.AmmoRequired := StrToIntDef(W.Def.Values['ammoRequired'], 0);
  W.ClipSize := StrToIntDef(W.Def.Values['clipSize'], 0);
  W.ProjectileDef := W.Def.Values['def_projectile'];
  W.MeleeDef := W.Def.Values['def_melee'];
  W.MeleeDistance := StrToFloatDef(W.Def.Values['melee_distance'], 64, DefaultFormatSettings);
  W.KickTime := StrToFloatDef(W.Def.Values['muzzle_kick_time'], 0, DefaultFormatSettings);
  W.KickMaxTime := StrToFloatDef(W.Def.Values['muzzle_kick_maxtime'], 0, DefaultFormatSettings);
  W.KickAngles := ParseVector3(W.Def.Values['muzzle_kick_angles'], TVector3.Zero);
  W.KickOffset := ParseVector3(W.Def.Values['muzzle_kick_offset'], TVector3.Zero);
  W.FlashColor := ParseVector3(W.Def.Values['flashColor'], TVector3.Zero);
  W.FlashRadius := StrToFloatDef(W.Def.Values['flashRadius'], 0, DefaultFormatSettings);
  W.FlashTime := StrToFloatDef(W.Def.Values['flashTime'], 0.25, DefaultFormatSettings);
  W.FlashStart := -1000;
  W.AngleOffsetAverages := StrToFloatDef(W.Def.Values['weaponAngleOffsetAverages'], 10, DefaultFormatSettings);
  W.AngleOffsetScale := StrToFloatDef(W.Def.Values['weaponAngleOffsetScale'], 0.25, DefaultFormatSettings);
  W.AngleOffsetMax := StrToFloatDef(W.Def.Values['weaponAngleOffsetMax'], 10, DefaultFormatSettings);
  W.OffsetTime := StrToFloatDef(W.Def.Values['weaponOffsetTime'], 400, DefaultFormatSettings) / 1000;
  W.OffsetScale := StrToFloatDef(W.Def.Values['weaponOffsetScale'], 0.005, DefaultFormatSettings);
  { the clip: full the first time (Clip -1), within the ammo carried }
  if (Clip[Slot] < 0) or (Clip[Slot] > W.ClipSize) then
  begin
    Clip[Slot] := W.ClipSize;
    Avail := HasAmmo(W.AmmoType, W.AmmoRequired);
    if (Avail >= 0) and (Clip[Slot] > Avail) then
      Clip[Slot] := Avail;
  end;
  { the view model }
  Decl := Decls.ModelDecl(W.Def.Values['model_view']);
  if Decl <> nil then
  begin
    Md5 := Md5Cache.Model(Decl.Mesh);
    if Md5 <> nil then
    begin
      W.View := TD3Md5Instance.Create(Md5, Decl.Anims, Decl.Skin);
      W.View.FrameCommands := Decl.FrameCommands;
      W.View.OnFrameCommand := @WeaponFrameCommand;
      W.View.Scene.Collides := False;
      W.View.Scene.Pickable := False;
      W.View.Scene.CastShadows := False;
      W.View.Scene.Translation := D3ToCge(Decl.Offset);
      W.Holder := TCastleTransform.Create(nil);
      W.Holder.SetTransient;
      W.Holder.Name := 'ViewWeapon';
      W.Holder.Collides := False;
      W.Holder.Pickable := False;
      { Doom 3's weaponDepthHack: drawn in front of the world (depth range
        0..0.1), so it never pokes into walls }
      W.Holder.RenderLayer := rlFront;
      W.Holder.Add(W.View.Scene);
      { hidden until it plays an anim (idWeapon::Event_PlayAnim shows it) }
      W.Holder.Exists := False;
      FMap.Add(W.Holder);
    end;
  end;
  { the script object, its init in its thread (idWeapon's thread) }
  T := nil;
  if FScript <> nil then
    T := FScript.FindType(W.Def.Values['scriptobject']);
  if T <> nil then
  begin
    W.Obj := TD3ScriptObject.Create(T);
    W.Thread := FScript.NewPersistentThread('weapon ' + W.DefName);
    W.Thread.Tag := WeaponHandle;
    W.Status := wsHolstered;
    FScript.RestartThread(W.Thread, T.FindMethodToRun('init'), WeaponHandle);
    { idWeapon::Raise }
    W.SetFlag('WEAPON_RAISEWEAPON', True);
  end;
  WritelnLog('Doom3World', 'Weapon %d: %s (%s, clip %d)', [Slot, W.DefName,
    BoolToStr(W.Scripted, 'script ' + W.Def.Values['scriptobject'], 'built-in pistol'), Clip[Slot]]);
end;

procedure TD3Game.SelectWeapon(const Slot: Integer);
begin
  if HasWeapon(Slot) then
    FIdealSlot := Slot;
end;

procedure TD3Game.NextWeapon(const Delta: Integer);
var
  I, Slot: Integer;
begin
  Slot := FIdealSlot;
  for I := 1 to Length(WeaponDefs) do
  begin
    Slot := (Slot + Delta + Length(WeaponDefs)) mod Length(WeaponDefs);
    if HasWeapon(Slot) then
    begin
      FIdealSlot := Slot;
      Exit;
    end;
  end;
end;

procedure TD3Game.ReloadWeapon;
begin
  FReloadRequested := True;
end;

procedure TD3Game.AttackOnce;
begin
  FAttackPulse := 1;
end;

procedure TD3Game.UpdateWeapon(const SecondsPassed: Single);
var
  W: TD3Weapon;
  Axis: TMatrix3;
  Source: TCastleSoundSource;
begin
  UpdatePlayerMotion(SecondsPassed);
  if FPlayerDef = nil then
    Exit;
  { the weapon to start with: current_weapon (the pistol), else the first }
  if (FIdealSlot < 0) or not HasWeapon(FIdealSlot) then
  begin
    FIdealSlot := -1;
    SelectWeapon(StrToIntDef(FPlayerDef.Values['current_weapon'], 1));
    if FIdealSlot < 0 then
      NextWeapon(1);
    if FIdealSlot < 0 then
      Exit;
  end;
  { idPlayer::UpdateWeapon: lower the weapon, switch once it's holstered }
  if not PlayerDead and ((FWeapon = nil) or (FWeapon.Slot <> FIdealSlot)) then
  begin
    if (FWeapon = nil) or not FWeapon.Scripted or (FWeapon.Status = wsHolstered) then
    begin
      if FWeapon <> nil then
      begin
        if (FScript <> nil) and (FWeapon.Thread <> nil) then
          FScript.FreeThread(FWeapon.Thread);
        FreeAndNil(FWeapon);
      end;
      FWeapon := SpawnWeapon(FIdealSlot);
    end else
    if FWeapon.Status in [wsReady, wsOutOfAmmo, wsReload] then
      FWeapon.SetFlag('WEAPON_LOWERWEAPON', True);
  end;
  W := FWeapon;
  if W = nil then
    Exit;
  if W.Scripted then
  begin
    { a state asked last frame (idWeapon::SetState) }
    if W.HasIdeal then
    begin
      W.HasIdeal := False;
      W.StateName := W.IdealName;
      FScript.RestartThread(W.Thread, W.IdealFunction, WeaponHandle);
    end;
    W.SetFlag('WEAPON_ATTACK', (Attack or (FAttackPulse > 0)) and not PlayerDead);
    W.SetFlag('WEAPON_RELOAD', FReloadRequested);
  end;
  FReloadRequested := False;
  FAttackPulse := Max(0, FAttackPulse - SecondsPassed);

  { its sounds follow the player }
  if FSoundSources.TryGetValue(WeaponHandle, Source) and (Source.Parent <> nil) then
    Source.Parent.Translation := FPlayerEye;
end;

{ Doom 3 matrix helpers (rows are the axes): A * B, and V * M (the sum of
  V's components times M's rows: local to world) }
function D3MatMul(const A, B: TMatrix3): TMatrix3;
var
  I, J, K: Integer;
  Sum: Single;
begin
  for I := 0 to 2 do
    for K := 0 to 2 do
    begin
      Sum := 0;
      for J := 0 to 2 do
        Sum := Sum + A.Data[I, J] * B.Data[J, K];
      Result.Data[I, K] := Sum;
    end;
end;

function D3VecMat(const V: TVector3; const M: TMatrix3): TVector3;
var
  K: Integer;
begin
  for K := 0 to 2 do
    Result.Data[K] := V.X * M.Data[0, K] + V.Y * M.Data[1, K] + V.Z * M.Data[2, K];
end;

procedure TD3Game.UpdatePlayerMotion(const SecondsPassed: Single);
const
  MinBobSpeed = 5;
  LandDeflectTime = 0.15;
  LandReturnTime = 0.3;
  { idPlayer's STEPUP_TIME, pm_stepsize }
  StepUpTime = 0.2;
  StepSize = 16;
var
  Vel, DV, Local: TVector3;
  Axis: TMatrix3;
  BobMove, Delta, Speed, F, DZ, T: Single;
  Stepped, Airborne: Boolean;

  procedure LogAccel(const Dir: TVector3);
  begin
    FAccelTimes[FAccelCount and High(FAccelTimes)] := FTime;
    FAccelDirs[FAccelCount and High(FAccelDirs)] := Dir;
    Inc(FAccelCount);
  end;

begin
  if SecondsPassed <= 0 then
    Exit;
  Vel := TVector3.Zero;
  if FHasPrevEye then
    Vel := CgeToD3(FPlayerEye - FPrevEye) / SecondsPassed;
  FPrevEye := FPlayerEye;
  FHasPrevEye := True;
  { a teleport isn't a move (nor a fall) }
  if Vel.Length > 2000 then
  begin
    Vel := TVector3.Zero;
    FFalling := False;
  end;
  DZ := Vel.Z * SecondsPassed;
  Airborne := PlayerJumping or FFalling;

  { a step up (idPhysics_Player's step, then idPlayer::BobCycle): the body
    is up at once, the view follows within 200 ms; steps in a row add up,
    to 2 steps at most }
  Stepped := not PlayerFlying and not Airborne and (DZ > 1) and (DZ <= 2 * StepSize + 1) and
    (Vector2(Vel.X, Vel.Y).Length > MinBobSpeed);
  if Stepped then
  begin
    T := FTime - FStepUpTime;
    if T < StepUpTime then
      FStepUpDelta := FStepUpDelta * (StepUpTime - T) / StepUpTime + DZ
    else
      FStepUpDelta := DZ;
    FStepUpDelta := Min(FStepUpDelta, 2 * StepSize);
    FStepUpTime := FTime;
    { not a vertical move for the view's angles and the bob }
    Vel.Z := 0;
  end;

  { falls: from where the descent started (the top of a jump) to where it
    stops, with Doom 3's gravity (idPlayer::CrashLand) }
  if PlayerFlying then
    FFalling := False
  else
  if not FFalling and (DZ < -0.5) and (Vel.Z < -40) then
  begin
    FFalling := True;
    FFallStartZ := CgeToD3(FPlayerEye).Z - DZ;
  end else
  if FFalling and (Vel.Z > -40) then
  begin
    FFalling := False;
    CrashLand(FFallStartZ - CgeToD3(FPlayerEye).Z);
  end;
  Airborne := PlayerJumping or FFalling;
  { movement changes (idPlayer logs the move keys' changes, in view space:
    forward, right; a jump bounces the weapon) }
  DV := Vel - FPlayerVelocity;
  Axis := PlayerViewAxis;
  Local := Vector3(TVector3.DotProduct(DV, Vector3(Axis.Data[0, 0], Axis.Data[0, 1], 0)),
    -TVector3.DotProduct(DV, Vector3(Axis.Data[1, 0], Axis.Data[1, 1], 0)), 0);
  if Vector2(Local.X, Local.Y).Length > 30 then
    LogAccel(Local * (127 / 140));
  if PlayerJumping and (DV.Z > 150) then
    LogAccel(Vector3(0, 0, 200));
  FPlayerVelocity := Vel;
  FXYSpeed := Vector2(Vel.X, Vel.Y).Length;
  { idPlayer::BobCycle: on the ground and moving }
  if Airborne or (FXYSpeed <= MinBobSpeed) then
  begin
    FBobCycle := 0;
    FBobFracSin := 0;
  end else
  begin
    { pm_walkbob 0.3 at walking speed (140), pm_runbob 0.4 running (220) }
    BobMove := 0.3 + 0.1 * EnsureRange((FXYSpeed - 140) / 80, 0, 1);
    FBobCycle := FBobCycle + BobMove * SecondsPassed * 1000;
    FBobCycle := FBobCycle - 256 * Floor(FBobCycle / 256);
    FBobFracSin := Abs(Sin((Trunc(FBobCycle) and 127) / 127 * Pi));
  end;

  { the view's bob (idPlayer::BobCycle): pitch and roll from the velocity
    (pm_runpitch 0.002, pm_runroll 0.005) and the bob (pm_bobpitch,
    pm_bobroll 0.002 at 200 units a second at least), the roll the other
    way on every other step; up to 6 units up (pm_bobup 0.005); the dip
    of a landing, 150 ms down and 300 ms back }
  FViewBobAngles := TVector3.Zero;
  FViewBobAngles.X := TVector3.DotProduct(Vel, Vector3(Axis.Data[0, 0], Axis.Data[0, 1], Axis.Data[0, 2])) * 0.002;
  FViewBobAngles.Z := -TVector3.DotProduct(Vel, Vector3(Axis.Data[1, 0], Axis.Data[1, 1], Axis.Data[1, 2])) * 0.005;
  Speed := Max(FXYSpeed, 200);
  FViewBobAngles.X := FViewBobAngles.X + FBobFracSin * 0.002 * Speed;
  if (Trunc(FBobCycle) and 128) <> 0 then
    FViewBobAngles.Z := FViewBobAngles.Z - FBobFracSin * 0.002 * Speed
  else
    FViewBobAngles.Z := FViewBobAngles.Z + FBobFracSin * 0.002 * Speed;
  FViewBob := Vector3(0, 0, Min(6, FBobFracSin * FXYSpeed * 0.005));
  { below the body just after a step up }
  T := FTime - FStepUpTime;
  if T < StepUpTime then
    FViewBob.Z := FViewBob.Z - FStepUpDelta * (StepUpTime - T) / StepUpTime;
  Delta := FTime - FLandTime;
  if Delta < LandDeflectTime then
    F := Delta / LandDeflectTime
  else
  if Delta < LandDeflectTime + LandReturnTime then
    F := 1 - (Delta - LandDeflectTime) / LandReturnTime
  else
    F := 0;
  FViewBob.Z := FViewBob.Z + FLandChange * F;
  FWeaponLand := FLandChange * 0.25 * F;
end;

procedure TD3Game.CrashLand(const FallHeight: Single);
const
  Gravity = 1066;
var
  Delta: Single;
  DamageName: String;
  Fallback, Amount: Integer;
  Def: TStringList;
begin
  { idPlayer::CrashLand: delta is the landing speed squared / 10000 }
  if FallHeight <= 0 then
    Exit;
  Delta := 2 * Gravity * FallHeight * 0.0001;
  LastFallDelta := Delta;
  DamageName := '';
  Fallback := 0;
  if Delta > 65 then
  begin
    FLandChange := -32;
    DamageName := 'damage_fatalfall';
    Fallback := 1000;
  end else
  if Delta > 45 then
  begin
    FLandChange := -24;
    DamageName := 'damage_hardfall';
    Fallback := 25;
  end else
  if Delta > 30 then
  begin
    FLandChange := -16;
    DamageName := 'damage_softfall';
    Fallback := 10;
  end else
  if Delta > 7 then
    FLandChange := -8
  else
    Exit;
  FLandTime := FTime;
  if DamageName = '' then
    Exit;
  { the game's damage defs, else Doom 3's values }
  Amount := Fallback;
  Def := Decls.EntityDef(DamageName);
  if Def <> nil then
    Amount := StrToIntDef(Def.Values['damage'], Fallback);
  WritelnLog('Doom3World', 'Fall of %.0f units: %s (%d)', [FallHeight, DamageName, Amount]);
  { no pain cry: the landing sound instead (idPlayer::CrashLand sets
    pain_debounce_time for its landing anim) }
  FPainDebounce := FTime + 1;
  PlayerSound('snd_land_hard');
  DamagePlayer(Amount, DamageName, Vector3(0, -1, 0));
end;

function TD3Game.ViewBobOffset: TVector3;
begin
  if ViewBobEnabled and not PlayerDead then
    Result := D3ToCge(FViewBob)
  else
    Result := TVector3.Zero;
end;

function TD3Game.ViewBobAngles: TVector3;
var
  Offset: Single;
  I: Integer;
begin
  if ViewBobEnabled and not PlayerDead then
    Result := FViewBobAngles
  else
    Result := TVector3.Zero;
  { the damage kick (idPlayerView::AngleOffset: the kick times the time
    left squared, in ms, times g_kickAmplitude 0.0001, within 70 degrees) }
  if not PlayerDead and (FTime < FKickFinish) then
  begin
    Offset := (FKickFinish - FTime) * 1000;
    for I := 0 to 2 do
      Result.Data[I] := Result.Data[I] + EnsureRange(FKickAngles.Data[I] * Sqr(Offset) * 0.0001, -70, 70);
  end;
end;

function TD3Game.BobbedViewAxis: TMatrix3;
var
  D: TVector3;
begin
  if PlayerViewDir.IsZero then
    D := Vector3(1, 0, 0)
  else
    D := CgeToD3(PlayerViewDir);
  Result := AnglesMatrix(Vector3(D3DirPitch(D), D3DirYaw(D), 0) + ViewBobAngles);
end;

procedure TD3Game.PresentWeapon(const W: TD3Weapon);
var
  ViewAxis, Axis: TMatrix3;
  D, Origin, GunOfs, Fwd, Start: TVector3;
  Angles, Current, Lag: TVector3;
  Scale, FracSin, T, F, Left, Amount, Dist, Tau, K: Single;
  I: Integer;
  Ctx: TD3ExprContext;
  Mat: TD3Material;
  JointPos: TVector3;
begin
  ViewAxis := BobbedViewAxis;
  if PlayerViewDir.IsZero then
    D := Vector3(1, 0, 0)
  else
    D := CgeToD3(PlayerViewDir);
  Current := Vector3(D3DirPitch(D), D3DirYaw(D), 0);
  { the view weapon lags behind turns (idPlayer::GunTurningOffset: the
    view angles averaged over weaponAngleOffsetAverages frames at 60 a
    second; here smoothed over that time) }
  if not FHasSmoothedView then
  begin
    FSmoothedView := Vector2(Current.X, Current.Y);
    FHasSmoothedView := True;
  end;
  Tau := Max(1, W.AngleOffsetAverages) / 60 / 2;
  K := 1 - Exp(-Max(0, FTime - FLastPresentTime) / Tau);
  FLastPresentTime := FTime;
  FSmoothedView.X := FSmoothedView.X + Normalize180(Current.X - FSmoothedView.X) * K;
  FSmoothedView.Y := FSmoothedView.Y + Normalize180(Current.Y - FSmoothedView.Y) * K;
  Lag := Vector3(Normalize180(FSmoothedView.X - Current.X), Normalize180(FSmoothedView.Y - Current.Y), 0) *
    W.AngleOffsetScale;
  for I := 0 to 2 do
    Lag.Data[I] := EnsureRange(Lag.Data[I], -W.AngleOffsetMax, W.AngleOffsetMax);
  { and behind moves (idPlayer::GunAcceleratingOffset) }
  GunOfs := TVector3.Zero;
  for I := Max(0, FAccelCount - Length(FAccelTimes)) to FAccelCount - 1 do
  begin
    T := FTime - FAccelTimes[I and High(FAccelTimes)];
    if (T < 0) or (T >= W.OffsetTime) then
      Continue;
    F := (Cos(T / W.OffsetTime * 2 * Pi) - 1) * 0.5;
    GunOfs := GunOfs + FAccelDirs[I and High(FAccelDirs)] * (F * W.OffsetScale);
  end;
  { the bob (idPlayer::CalculateViewWeaponPos): angles, on odd steps the
    other way; the view's bob up and down (idPlayer::BobCycle) }
  if (Trunc(FBobCycle) and 128) <> 0 then
    Scale := -FXYSpeed
  else
    Scale := FXYSpeed;
  Angles.X := FXYSpeed * FBobFracSin * 0.005;
  Angles.Y := Scale * FBobFracSin * 0.01;
  Angles.Z := Scale * FBobFracSin * 0.005;
  Angles := Angles + Lag;
  { a speed sensitive idle drift }
  FracSin := (FXYSpeed + 40) * Sin(FTime) * 0.01;
  Angles := Angles + Vector3(FracSin, FracSin, FracSin);
  { at the bobbing eye; a landing drops it a quarter more }
  Origin := CgeToD3(FPlayerEye + ViewBobOffset) + Vector3(0, 0, FWeaponLand) + D3VecMat(GunOfs, ViewAxis);
  Axis := D3MatMul(AnglesMatrix(Angles), ViewAxis);
  { muzzle kick (idWeapon::MuzzleRise) }
  Left := W.KickEndTime - FTime;
  if (Left > 0) and (W.KickMaxTime > 0) then
  begin
    Amount := Min(Left, W.KickMaxTime) / W.KickMaxTime;
    Origin := Origin - D3VecMat(W.KickOffset * Amount, Axis);
    Axis := D3MatMul(AnglesMatrix(W.KickAngles * Amount), Axis);
  end;
  W.Holder.Translation := D3ToCge(Origin);
  SetD3Rotation(W.Holder, Axis);

  { flash surfaces: materials whose stage shows "if ( time + parm4 ) ..."
    (parm4 = -the time of the shot) }
  FillChar(Ctx, SizeOf(Ctx), 0);
  Ctx.Time := FTime;
  for I := 0 to 3 do
    Ctx.Parms[I] := 1;
  Ctx.Parms[4] := -W.FlashStart;
  for I := 0 to High(W.View.MeshShapes) do
  begin
    Mat := Decls.Material(W.View.MeshMaterials[I]);
    if Mat.StageCondition <> nil then
      W.View.MeshShapes[I].Visible := Mat.StageCondition.Eval(Ctx) <> 0;
  end;

  { the flash light at the "flash" joint, backed up from walls to at least
    8 units away (idWeapon::UpdateFlashPosition) }
  if (W.FlashRadius > 0) and (FTime < W.FlashStart + W.FlashTime) then
  begin
    Fwd := D3ToCge(Vector3(ViewAxis.Data[0, 0], ViewAxis.Data[0, 1], ViewAxis.Data[0, 2]));
    if W.View.JointPosition('flash', JointPos) then
      FMuzzleFlashPos := W.View.Scene.LocalToWorld(JointPos)
    else
      FMuzzleFlashPos := FPlayerEye + Fwd * 24;
    Start := FMuzzleFlashPos - Fwd * 16;
    if FMap.World.WorldRayCast(Start, Fwd, Dist) = nil then
      Dist := 24;
    FMuzzleFlashPos := Start + Fwd * (Min(Dist, 24) - 8);
  end;
end;

function TD3Game.MuzzleFlash(out Position, Color: TVector3; out Radius: Single): Boolean;
var
  W: TD3Weapon;
begin
  W := FWeapon;
  Result := (W <> nil) and W.Scripted and (W.View <> nil) and W.Holder.Exists and
    (W.FlashRadius > 0) and (FTime < W.FlashStart + W.FlashTime);
  if not Result then
    Exit;
  Position := FMuzzleFlashPos;
  Color := W.FlashColor;
  Radius := W.FlashRadius;
end;

procedure TD3Game.WeaponFrameCommand(const Sender: TD3Md5Instance; const Command: String);
var
  Cmd, Arg, Shader: String;
begin
  if (FWeapon = nil) or (FWeapon.View <> Sender) then
    Exit;
  Cmd := LowerCase(Copy(Command, 1, Pos(' ', Command + ' ') - 1));
  Arg := Trim(Copy(Command, Length(Cmd) + 2, MaxInt));
  if Copy(Cmd, 1, 5) = 'sound' then
  begin
    { sound, sound_weapon, sound_item...: a key of the weapon def, or a
      shader }
    Shader := FWeapon.Def.Values[Arg];
    if Shader = '' then
      Shader := Arg;
    StartScriptSound(WeaponHandle, Shader, 0);
  end;
end;

function TD3Game.WeaponEvent(const W: TD3Weapon; const Thread: TD3ScriptThread; const N: String;
  const Args: TD3ValueArray; var EventResult: TD3Value): Boolean;
var
  Anim: String;
  Amount, Avail: Integer;

  function ArgF(const Index: Integer): Single;
  begin
    Result := D3ValueToFloat(Args[Index]);
  end;

  function ArgStr(const Index: Integer): String;
  begin
    Result := D3ValueToString(Args[Index]);
  end;

  procedure PlayViewAnim(const Loop: Boolean);
  begin
    W.AnimDoneTime := 0;
    if W.View = nil then
      Exit;
    Anim := W.View.ResolveAnim(ArgStr(1));
    if (Anim = '') or not W.View.PlayAnim(Anim, Loop) then
    begin
      Unsupported(Format('weapon anim %s of %s', [ArgStr(1), W.DefName]));
      Exit;
    end;
    W.Holder.Exists := True;
    if not Loop then
      W.AnimDoneTime := FTime + W.View.AnimDurationOf(Anim);
  end;

begin
  Result := True;
  case N of
    'weaponState':
      begin
        { idWeapon::Event_WeaponState: the thread switches next frame }
        W.IdealFunction := W.Obj.Typ.FindMethodToRun(ArgStr(0));
        W.IdealName := ArgStr(0);
        W.HasIdeal := True;
        W.BlendFrames := Round(ArgF(1));
        if Thread = W.Thread then
          Thread.Yield;
      end;
    'weaponReady':
      begin
        W.Status := wsReady;
        W.SetFlag('WEAPON_RAISEWEAPON', False);
      end;
    'weaponOutOfAmmo':
      begin
        W.Status := wsOutOfAmmo;
        W.SetFlag('WEAPON_RAISEWEAPON', False);
      end;
    'weaponReloading': W.Status := wsReload;
    'weaponHolstered':
      begin
        W.Status := wsHolstered;
        W.SetFlag('WEAPON_LOWERWEAPON', False);
        if W.Holder <> nil then
          W.Holder.Exists := False;
      end;
    'weaponRising':
      begin
        W.Status := wsRising;
        W.SetFlag('WEAPON_LOWERWEAPON', False);
      end;
    'weaponLowering':
      begin
        W.Status := wsLowering;
        W.SetFlag('WEAPON_RAISEWEAPON', False);
      end;
    'useAmmo':
      begin
        Amount := Round(ArgF(0)) * W.AmmoRequired;
        UseAmmo(W.AmmoType, Amount);
        if (W.ClipSize > 0) and (W.AmmoRequired > 0) then
          Clip[W.Slot] := Max(0, Clip[W.Slot] - Amount);
      end;
    'addToClip':
      begin
        Clip[W.Slot] := Min(Clip[W.Slot] + Round(ArgF(0)), W.ClipSize);
        Avail := HasAmmo(W.AmmoType, W.AmmoRequired);
        if (Avail >= 0) and (Clip[W.Slot] > Avail) then
          Clip[W.Slot] := Avail;
      end;
    'ammoInClip': EventResult := D3FloatValue(Clip[W.Slot]);
    'ammoAvailable': EventResult := D3FloatValue(HasAmmo(W.AmmoType, W.AmmoRequired));
    'totalAmmoCount': EventResult := D3FloatValue(HasAmmo(W.AmmoType, 1));
    'clipSize': EventResult := D3FloatValue(W.ClipSize);
    'playAnim': PlayViewAnim(False);
    'playCycle': PlayViewAnim(True);
    'animDone':
      { blend frames are game frames (60 a second) }
      EventResult := D3FloatValue(Ord(W.AnimDoneTime - ArgF(1) / 60 <= FTime));
    'setBlendFrames': W.BlendFrames := Round(ArgF(1));
    'getBlendFrames': EventResult := D3FloatValue(W.BlendFrames);
    'launchProjectiles':
      LaunchPlayerProjectiles(W, Round(ArgF(0)), ArgF(1), ArgF(2), ArgF(3), ArgF(4));
    'melee': EventResult := D3FloatValue(Ord(WeaponMelee(W)));
    'getOwner': EventResult := D3EntityValue(PlayerHandle);
    'nextWeapon': NextWeapon(1);
    'autoReload': EventResult := D3FloatValue(1);
    'isInvisible': EventResult := D3FloatValue(0);
    'getLightParm': EventResult := D3FloatValue(1);
    'getName': EventResult := D3StringValue(W.DefName);
    'createProjectile', 'getWorldModel': EventResult := D3EntityValue(0);
    'flashlight', 'ejectBrass', 'allowDrop', 'netReload', 'netEndReload', 'setSkin',
    'setLightParm', 'setLightParms', 'setShaderParm', 'setShaderParms', 'setColor':
      ; { no effect here yet }
    'hide':
      if W.Holder <> nil then
        W.Holder.Exists := False;
    'show':
      if W.Holder <> nil then
        W.Holder.Exists := True;
    'getKey': EventResult := D3StringValue(W.Def.Values[ArgStr(0)]);
    'getFloatKey', 'getIntKey', 'getBoolKey':
      EventResult := D3FloatValue(StrToFloatDef(W.Def.Values[ArgStr(0)], 0, DefaultFormatSettings));
    'getVectorKey': EventResult := D3VectorValue(ParseVector3(W.Def.Values[ArgStr(0)], TVector3.Zero));
    'startSound':
      EventResult := D3FloatValue(StartScriptSound(WeaponHandle, W.Def.Values[ArgStr(0)], Round(ArgF(1))));
    'startSoundShader':
      EventResult := D3FloatValue(StartScriptSound(WeaponHandle, ArgStr(0), Round(ArgF(1))));
    'stopSound': StopScriptSound(WeaponHandle, Round(ArgF(0)));
    else
      Result := False;
  end;
end;

function TD3Game.RayMonster(const Origin, Dir: TVector3; const MaxDist: Single;
  out Dist: Single): TD3Monster;
var
  Mon: TD3Monster;
  D, ToCenter, Closest: TVector3;
  T: Single;
begin
  { monsters as vertical cylinders }
  Result := nil;
  Dist := MaxDist;
  D := Dir.Normalize;
  for Mon in FMonsters do
  begin
    if (Mon.State = msDead) or not Mon.Model.Holder.Exists then
      Continue;
    ToCenter := Mon.Center - Origin;
    T := TVector3.DotProduct(ToCenter, D);
    if (T <= 0) or (T >= Dist) then
      Continue;
    Closest := Origin + D * T;
    if (Sqr(Closest.X - Mon.Center.X) + Sqr(Closest.Z - Mon.Center.Z) < Sqr(Mon.Radius)) and
       (Abs(Closest.Y - Mon.Center.Y) < Mon.Height / 2) then
    begin
      Result := Mon;
      Dist := T;
    end;
  end;
end;

procedure TD3Game.DamageMonster(const Mon: TD3Monster; const Amount: Integer);
begin
  if Mon.State = msDead then
    Exit;
  Dec(Mon.Health, Amount);
  Mon.PainTime := 0.2;
  Mon.Dormant := False;
  if (Mon.State = msIdle) and (Mon.Actor = nil) then
  begin
    Mon.State := msChase;
    Mon.Model.Instance.PlayAnim('walk');
  end;
  if Mon.Health <= 0 then
  begin
    Mon.State := msDead;
    Mon.StateTime := 0;
    if Mon.Actor = nil then
      Mon.Model.Instance.PlayAnim('idle', False);
    Inc(Kills);
    Message('Killed ' + Mon.Model.Entity.Name);
  end;
  if Mon.Actor <> nil then
    ActorDamaged(Mon.Actor, Mon.Health <= 0);
end;

procedure TD3Game.LaunchPlayerProjectiles(const W: TD3Weapon; const Count: Integer;
  const Spread, FuseOffset, LaunchPower, DamagePower: Single);
var
  Def: TStringList;
  Axis: TMatrix3;
  Fwd, Left, Up, Dir: TVector3;
  Ang, Spin, Speed: Single;
  I, Avail: Integer;
  P: TD3Projectile;
begin
  if W.ProjectileDef = '' then
  begin
    Unsupported('weapon without def_projectile: ' + W.DefName);
    Exit;
  end;
  { out of ammo, or the clip is empty }
  Avail := HasAmmo(W.AmmoType, W.AmmoRequired);
  if (Avail = 0) or ((W.ClipSize <> 0) and (Clip[W.Slot] <= 0)) then
    Exit;
  UseAmmo(W.AmmoType, W.AmmoRequired);
  if (W.ClipSize > 0) and (W.AmmoRequired > 0) then
    Dec(Clip[W.Slot]);
  FAttackPulse := 0;
  SinceFire := 0;
  Inc(W.Shots);
  { the muzzle kick adds up for repeated shots, the flash shows }
  if W.KickEndTime < FTime then
    W.KickEndTime := FTime;
  W.KickEndTime := Min(W.KickEndTime + W.KickTime, FTime + W.KickMaxTime);
  W.FlashStart := FTime;
  Def := Decls.EntityDef(W.ProjectileDef);
  Speed := 1000;
  if Def <> nil then
    Speed := ParseVector3(Def.Values['velocity'], Vector3(1000, 0, 0)).Length;
  Speed := Speed * LaunchPower;
  Axis := PlayerViewAxis;
  Fwd := Vector3(Axis.Data[0, 0], Axis.Data[0, 1], Axis.Data[0, 2]);
  Left := Vector3(Axis.Data[1, 0], Axis.Data[1, 1], Axis.Data[1, 2]);
  Up := Vector3(Axis.Data[2, 0], Axis.Data[2, 1], Axis.Data[2, 2]);
  for I := 1 to Max(1, Count) do
  begin
    { spread: a random direction within the cone }
    Ang := Sin(DegToRad(Spread) * Random);
    Spin := 2 * Pi * Random;
    Dir := (Fwd + Up * (Ang * Sin(Spin)) - Left * (Ang * Cos(Spin))).Normalize;
    P := SpawnProjectile(W.ProjectileDef, 'player', FPlayerEye + D3ToCge(Fwd) * 2, D3ToCge(Dir) * Speed);
    if P = nil then
      Continue;
    P.FromPlayer := True;
    P.Damage := Round(P.Damage * DamagePower);
    P.Fuse := P.Fuse - FuseOffset;
  end;
  WritelnLog('Doom3World', 'Weapon %s fires %d (clip %d, ammo %d)',
    [W.DefName, Max(1, Count), Clip[W.Slot], AmmoCount(W.AmmoType)]);
end;

function TD3Game.WeaponMelee(const W: TD3Weapon): Boolean;
var
  Def: TStringList;
  Dir: TVector3;
  WallDist, MonDist: Single;
  Mon: TD3Monster;
  Damage: Integer;
begin
  Result := False;
  FAttackPulse := 0;
  Def := Decls.EntityDef(W.MeleeDef);
  if Def = nil then
  begin
    Unsupported('weapon without def_melee: ' + W.DefName);
    Exit;
  end;
  Inc(W.Shots);
  Dir := D3ToCge(Vector3(PlayerViewAxis.Data[0, 0], PlayerViewAxis.Data[0, 1], PlayerViewAxis.Data[0, 2]));
  if FMap.World.WorldRayCast(FPlayerEye, Dir, WallDist) = nil then
    WallDist := W.MeleeDistance;
  Mon := RayMonster(FPlayerEye, Dir, Min(WallDist, W.MeleeDistance), MonDist);
  if Mon <> nil then
  begin
    Damage := StrToIntDef(Def.Values['damage'], 10);
    WritelnLog('Doom3World', 'Weapon %s hits %s (%d)', [W.DefName, Mon.Model.Entity.Name, Damage]);
    DamageMonster(Mon, Damage);
    PlaySoundAt(Def.Values['snd_flesh'], FPlayerEye + Dir * MonDist);
    Result := True;
  end else
  if WallDist < W.MeleeDistance then
    PlaySoundAt(Def.Values['snd_hit'], FPlayerEye + Dir * WallDist)
  else
    PlaySoundAt(Def.Values['snd_miss'], FPlayerEye);
end;

function TD3Game.WeaponHudText: String;
var
  Name: String;
  W: TD3Weapon;
begin
  W := FWeapon;
  if (W = nil) or not W.Scripted then
    Exit('PISTOL');
  Name := UpperCase(LangString(W.Def.Values['inv_name']));
  if Name = '' then
    Name := UpperCase(W.DefName);
  if W.AmmoType = '' then
    Result := Name
  else
  if W.ClipSize > 0 then
    Result := Format('%s  %d / %d', [Name, Clip[W.Slot], Max(0, AmmoCount(W.AmmoType) - Clip[W.Slot])])
  else
    Result := Format('%s  %d', [Name, AmmoCount(W.AmmoType)]);
end;

procedure TD3Game.ThrowMoveable(const M: TD3Moveable; const Velocity: TVector3);
begin
  M.Velocity := Velocity;
  M.AtRest := False;
  M.CanDamage := True;
  M.DamageUntil := FTime + 2.5;
end;

function TD3Game.BallisticDir(const From, Target: TVector3; const Speed, Gravity: Single;
  out Dir: TVector3): Boolean;
var
  Horiz: TVector3;
  D, H, V2, Root, Angle: Single;
begin
  Dir := Target - From;
  if Dir.IsZero then
  begin
    Dir := Vector3(1, 0, 0);
    Exit(True);
  end;
  Dir := Dir.Normalize;
  if Gravity <= 0 then
    Exit(True);
  Horiz := Vector3(Target.X - From.X, Target.Y - From.Y, 0);
  D := Horiz.Length;
  H := Target.Z - From.Z;
  V2 := Sqr(Speed);
  Root := Sqr(V2) - Gravity * (Gravity * Sqr(D) + 2 * H * V2);
  if (Root < 0) or (D < 1) then
    Exit(False);
  Angle := ArcTan((V2 - Sqrt(Root)) / (Gravity * D));
  Dir := Horiz / D * Cos(Angle) + Vector3(0, 0, Sin(Angle));
  Result := True;
end;

procedure TD3Game.UpdateMoveables(const SecondsPassed: Single);
const
  Gravity = 1066;
var
  M: TD3Moveable;
  Center, Step, Dir, Feet, ToPlayer: TVector3;
  Len, Extent, HitDist, Speed, F, Radius, D, CornerDist: Single;
  Offset: TVector3;
  DamageDef: TStringList;
  Damage, Axis, Corner: Integer;
  WasPickable, OnFloor: Boolean;
begin
  Feet := CgeToD3(FPlayerEye - Vector3(0, PlayerEyeHeight, 0));
  for M in FMoveables do
  begin
    if M.Brush.Hidden or (M.Brush.Scene = nil) then
      Continue;
    { bound (carried): it follows its master; let go, it falls }
    if FindBinding(M.Brush.Scene) <> nil then
    begin
      M.WasBound := True;
      Continue;
    end;
    if M.WasBound then
    begin
      M.WasBound := False;
      M.AtRest := False;
    end;
    if (M.DamageUntil > 0) and (FTime >= M.DamageUntil) then
    begin
      M.CanDamage := False;
      M.DamageUntil := 0;
    end;
    if M.AtRest then
      Continue;
    M.Velocity.Z := M.Velocity.Z - Gravity * SecondsPassed;
    Center := M.Origin + M.CenterOffset;
    Step := M.Velocity * SecondsPassed;
    Len := Step.Length;
    if Len < 0.0001 then
      Continue;
    Speed := M.Velocity.Length;
    Radius := Max(M.HalfSize.X, M.HalfSize.Y);
    { the player, anywhere along the step (idMoveable::Collide: damage
      scaled by the speed) }
    ToPlayer := Vector3(Feet.X - Center.X, Feet.Y - Center.Y, 0);
    if not PlayerDead and (TVector3.DotProduct(M.Velocity, ToPlayer) > 0) and
       (SegmentToPlayerDistance(D3ToCge(Center), D3ToCge(Center + Step), FPlayerEye - Vector3(0, PlayerEyeHeight, 0),
          FPlayerEye) <= Radius + PlayerRadius) then
    begin
      if M.CanDamage and (M.DamageDef <> '') and (Speed > M.MinDamageVelocity) and
         (FTime >= M.NextDamageTime) then
      begin
        F := 1;
        if Speed < M.MaxDamageVelocity then
          F := Sqrt(Speed - M.MinDamageVelocity) / Sqrt(M.MaxDamageVelocity - M.MinDamageVelocity);
        DamageDef := Decls.EntityDef(M.DamageDef);
        if DamageDef <> nil then
        begin
          Damage := Max(1, Round(StrToIntDef(DamageDef.Values['damage'], 10) * F));
          DamagePlayer(Damage, M.DamageDef, M.Velocity);
          WritelnLog('Doom3World', '%s hits the player (%s, %d)', [M.Brush.Entity.Name, M.DamageDef, Damage]);
        end;
        M.NextDamageTime := FTime + 1;
      end;
      { it bounces off }
      M.Velocity := Vector3(-M.Velocity.X * M.Bounce, -M.Velocity.Y * M.Bounce, M.Velocity.Z);
      Continue;
    end;
    { the world, one axis at a time (not its own scene): stopped at the
      surface, that axis bounces (bouncyness); on a floor, friction, and
      slow enough it rests }
    OnFloor := False;
    WasPickable := M.Brush.Scene.Pickable;
    M.Brush.Scene.Pickable := False;
    try
      for Axis := 0 to 2 do
      begin
        D := Step.Data[Axis];
        if D = 0 then
          Continue;
        Dir := TVector3.Zero;
        Dir.Data[Axis] := Sign(D);
        Extent := M.HalfSize.Data[Axis];
        { from its center and near the corners of its side }
        HitDist := MaxSingle;
        for Corner := 0 to 4 do
        begin
          Offset := TVector3.Zero;
          if Corner > 0 then
          begin
            Offset.Data[(Axis + 1) mod 3] := M.HalfSize.Data[(Axis + 1) mod 3] * 0.9 * (1 - 2 * ((Corner - 1) and 1));
            Offset.Data[(Axis + 2) mod 3] := M.HalfSize.Data[(Axis + 2) mod 3] * 0.9 * (1 - 2 * ((Corner - 1) shr 1));
          end;
          if (FMap.World.WorldRayCast(D3ToCge(Center + Offset), D3ToCge(Dir), CornerDist) <> nil) and
             (CornerDist < HitDist) then
            HitDist := CornerDist;
        end;
        if HitDist <= Abs(D) + Extent then
        begin
          D := Sign(D) * Max(0, HitDist - Extent);
          M.Velocity.Data[Axis] := -M.Velocity.Data[Axis] * M.Bounce;
          if (Axis = 2) and (Dir.Z < 0) then
            OnFloor := True;
        end;
        Center.Data[Axis] := Center.Data[Axis] + D;
      end;
    finally
      M.Brush.Scene.Pickable := WasPickable;
    end;
    M.Brush.Scene.Translation := D3ToCge(Center - M.CenterOffset);
    if OnFloor then
    begin
      { a bounce that is only this frame's gravity is lying on the floor }
      if Abs(M.Velocity.Z) <= Gravity * SecondsPassed * M.Bounce + 40 then
        M.Velocity.Z := 0;
      M.Velocity.X := M.Velocity.X * 0.8;
      M.Velocity.Y := M.Velocity.Y * 0.8;
      if M.Velocity.Length < 30 then
      begin
        M.Velocity := TVector3.Zero;
        M.AtRest := True;
      end;
    end;
  end;
end;

function TD3CombatNode.PlayerInView(const Feet: TVector3): Boolean;
var
  Dir: TVector3;
  Dist: Single;
begin
  { the player's box is 74 high on its feet }
  if (Feet.Z + 74 < MinHeight) or (Feet.Z >= MaxHeight) then
    Exit(False);
  Dir := Feet - Origin;
  Dist := TVector3.DotProduct(Dir, Forward);
  Result := (Dist >= MinDist) and (Dist <= MaxDist) and
    (TVector3.DotProduct(Dir, ConeLeft) >= 0) and (TVector3.DotProduct(Dir, ConeRight) >= 0);
end;

procedure TD3Game.SpawnCombatNode(const E: TD3MapEntity);
var
  N: TD3CombatNode;
  Fov, Yaw, Height: Single;

  function YawDir(const Deg: Single): TVector3;
  begin
    Result := Vector3(Cos(DegToRad(Deg)), Sin(DegToRad(Deg)), 0);
  end;

begin
  { idCombatNode::Spawn }
  N := TD3CombatNode.Create;
  N.Entity := E;
  N.MinDist := E.FloatValue('min', 0);
  N.MaxDist := E.FloatValue('max', 0);
  Height := E.FloatValue('height', 0);
  Fov := E.FloatValue('fov', 60);
  N.Origin := E.Origin + E.VectorValue('offset', TVector3.Zero);
  N.MinHeight := N.Origin.Z - Height * 0.5;
  N.MaxHeight := N.MinHeight + Height;
  Yaw := E.Angle;
  N.Forward := YawDir(Yaw);
  N.ConeLeft := YawDir(Yaw + Fov * 0.5 - 90);
  N.ConeRight := YawDir(Yaw - Fov * 0.5 + 90);
  N.Disabled := E.BoolValue('start_off');
  N.UseOnce := E.BoolValue('use_once');
  FCombatNodes.Add(N);
end;

function TD3Game.CombatNodeOf(const E: TD3MapEntity): TD3CombatNode;
begin
  for Result in FCombatNodes do
    if Result.Entity = E then
      Exit;
  Result := nil;
end;

function TD3Game.AnimMoveClear(const A: TD3Actor; const AnimName: String; const Yaw: Single): Boolean;
var
  Delta, Move, From, Center, Dir, FloorStart: TVector3;
  Radius, Height, Len, FloorDist: Single;
begin
  if not A.Model.Instance.HasAnim(AnimName) then
    Exit(False);
  Delta := A.Model.Instance.AnimMovementDelta(A.Model.Instance.ResolveAnim(AnimName));
  { model space (x forward) turned to Yaw, Doom 3 coordinates }
  Move := Vector3(Delta.X * Cos(DegToRad(Yaw)) - Delta.Y * Sin(DegToRad(Yaw)),
    Delta.X * Sin(DegToRad(Yaw)) + Delta.Y * Cos(DegToRad(Yaw)), 0);
  Len := Move.Length;
  if Len < 0.5 then
    Exit(True);
  Radius := ActorRadius(A);
  Height := ActorHeight(A);
  { idAI::PredictPath: blocked (SE_BLOCKED) or off a ledge
    (SE_ENTER_LEDGE_AREA: the floor drops more than a step) }
  From := A.Model.Holder.Translation;
  Center := From + Vector3(0, Height / 2, 0);
  Dir := D3ToCge(Move / Len);
  if FMap.World.WorldSegmentCollision(Center, Center + D3ToCge(Move) + Dir * Radius) then
    Exit(False);
  if A.MoveType <> MoveTypeFly then
  begin
    FloorStart := From + D3ToCge(Move) + Vector3(0, 24, 0);
    if (FMap.World.WorldRayCast(FloorStart, Vector3(0, -1, 0), FloorDist) = nil) or
       (FloorDist > 24 + 18) then
      Exit(False);
  end;
  Result := True;
end;

procedure TD3Game.SpreadLocations;
var
  Count, I, P, A, Area, Other: Integer;
  Blocked: array of Boolean;
  Seen: array of Boolean;
  Queue: array of Integer;
  QueueHead: Integer;
  Assigned_: array of Boolean;
  E: TD3MapEntity;
  Mover: TD3Mover;
  Name: String;
  Portals: TD3PortalVisibility;
begin
  FLocations := nil;
  if (FMap.MapFile = nil) or (FMap.Portals = nil) then
    Exit;
  Portals := FMap.Portals;
  Count := Portals.AreaCount;
  SetLength(FLocations, Count);
  SetLength(Assigned_, Count);
  { idGameLocal::SpreadLocations runs after spawning: closed doors
    (PS_BLOCK_ALL) and info_locationSeparator (PS_BLOCK_LOCATION) block }
  SetLength(Blocked, Portals.PortalCount);
  for Mover in FMovers do
    if (Mover.Kind = mkDoor) and (Mover.State = dsClosed) then
      for P in Mover.Portals do
        Blocked[P] := True;
  for E in FMap.MapFile.Entities do
    if SameText(E.ClassName_, 'info_locationSeparator') then
    begin
      P := Portals.FindPortal(Box3DAroundPoint(D3ToCge(E.Origin), 32));
      if P >= 0 then
        Blocked[P] := True
      else
        WritelnWarning('Doom3World', 'LocationSeparator "%s" didn''t contact a portal', [E.Name]);
    end;
  for E in FMap.MapFile.Entities do
  begin
    if not SameText(E.ClassName_, 'info_location') then
      Continue;
    { idLocationEntity: "location" defaults to the entity name }
    Name := LowerCase(E.Value('location', E.Name));
    Area := FMap.AreaAt(D3ToCge(E.Origin));
    if (Area < 0) or (Area >= Count) then
    begin
      WritelnLog('Doom3World', 'Location "%s" is not in a valid area', [E.Name]);
      Continue;
    end;
    { like Doom 3: an area an earlier location reached is an overlap }
    if Assigned_[Area] then
    begin
      WritelnWarning('Doom3World', 'Location "%s" overlaps "%s"', [E.Name, FLocations[Area]]);
      Continue;
    end;
    Assigned_[Area] := True;
    FLocations[Area] := Name;
    { flood through the open portals, overwriting what earlier locations
      reached (like Doom 3) }
    Seen := nil;
    SetLength(Seen, Count);
    Seen[Area] := True;
    Queue := [Area];
    QueueHead := 0;
    while QueueHead < Length(Queue) do
    begin
      A := Queue[QueueHead];
      Inc(QueueHead);
      for P := 0 to Portals.PortalCount - 1 do
      begin
        if Blocked[P] then
          Continue;
        if Portals.PortalArea(P, 0) = A then
          Other := Portals.PortalArea(P, 1)
        else
        if Portals.PortalArea(P, 1) = A then
          Other := Portals.PortalArea(P, 0)
        else
          Continue;
        if (Other < 0) or (Other >= Count) or Seen[Other] then
          Continue;
        Seen[Other] := True;
        Queue := Concat(Queue, [Other]);
        Assigned_[Other] := True;
        FLocations[Other] := Name;
      end;
    end;
  end;
  I := 0;
  for A := 0 to Count - 1 do
    if FLocations[A] <> '' then
      Inc(I);
  if I > 0 then
    WritelnLog('Doom3World', 'Locations: %d of %d areas', [I, Count]);
end;

function TD3Game.LocationOfArea(const Area: Integer): String;
begin
  if (Area >= 0) and (Area < Length(FLocations)) then
    Result := FLocations[Area]
  else
    Result := '';
end;

function TD3Game.LocationAt(const P: TVector3): String;
begin
  Result := LocationOfArea(FMap.AreaAt(P));
end;

function TD3Game.RouteStatus(const EntityName: String): String;
var
  E: TD3MapEntity;
  Route: TD3Route;
  Feet, Pos: TVector3;
  I: Integer;
  R: TD3AasReach;
begin
  if FAas = nil then
    Exit('No AAS for this map');
  Feet := CgeToD3(FPlayerEye - Vector3(0, PlayerEyeHeight, 0));
  Result := Format('AAS "%s": the player is in area %d', [FAas.Name, FAas.OriginAreaNum(Feet)]);
  if EntityName = '' then
    Exit;
  E := FindEntity(EntityName);
  if E = nil then
    Exit(Result + ', no entity ' + EntityName);
  Pos := E.Origin;
  for I := 0 to FActors.Count - 1 do
    if FActors[I].Model.Entity = E then
      Pos := CgeToD3(FActors[I].Model.Holder.Translation);
  FillChar(Route, SizeOf(Route), 0);
  Result := Result + Format(', %s in area %d', [EntityName, FAas.OriginAreaNum(Pos)]);
  if FAas.OriginAreaNum(Pos) = FAas.OriginAreaNum(Feet) then
    Exit(Result + ', the same area');
  RouteWaypoint(Route, Pos, Feet);
  if not Route.Found then
    Exit(Result + ', no route');
  Result := Result + Format(', route of %d steps:', [Length(Route.Path)]);
  for I := 0 to High(Route.Path) do
  begin
    R := FAas.Areas[Route.Path[I].Area].Reach[Route.Path[I].Reach];
    Result := Result + Format(' %d->%d (type %d) at %s;', [Route.Path[I].Area, R.ToArea, R.TravelType,
      R.Stop.ToString]);
  end;
end;

function TD3Game.StepTowards(const From, Step: TVector3; const Radius, Height: Single): TVector3;
var
  NewPos, Center, FloorStart: TVector3;
  FloorDist: Single;
  Hit: TCastleTransform;
begin
  { CGE coordinates: From is the feet }
  if Step.IsZero then
    Exit(From);
  Center := From + Vector3(0, Height / 2, 0);
  NewPos := From + Step;
  { blocked by a wall or a closed door? try sliding along one axis }
  if FMap.World.WorldSegmentCollision(Center, NewPos + Vector3(0, Height / 2, 0) +
    Step.Normalize * Radius) then
  begin
    NewPos := From + Vector3(Step.X, 0, 0);
    if FMap.World.WorldSegmentCollision(Center, NewPos + Vector3(0, Height / 2, 0) +
      Vector3(Sign(Step.X) * Radius, 0, 0)) then
    begin
      NewPos := From + Vector3(0, 0, Step.Z);
      if FMap.World.WorldSegmentCollision(Center, NewPos + Vector3(0, Height / 2, 0) +
        Vector3(0, 0, Sign(Step.Z) * Radius)) then
        NewPos := From;
    end;
  end;
  { follow the floor (steps up to 18, falls) }
  FloorStart := NewPos + Vector3(0, 24, 0);
  Hit := FMap.World.WorldRayCast(FloorStart, Vector3(0, -1, 0), FloorDist);
  if (Hit <> nil) and (FloorDist < 24 + 400) then
    NewPos.Y := FloorStart.Y - FloorDist;
  Result := NewPos;
end;

function TD3Game.FlyStep(const From, Step: TVector3; const Radius, Height: Single;
  out Blocked: Boolean): TVector3;
var
  Axis: Integer;
  S, Center, Reach: TVector3;
begin
  { CGE coordinates: From is the feet; each axis slides on its own }
  Blocked := False;
  Result := From;
  for Axis := 0 to 2 do
  begin
    if Step.Data[Axis] = 0 then
      Continue;
    S := TVector3.Zero;
    S.Data[Axis] := Step.Data[Axis];
    Center := Result + Vector3(0, Height / 2, 0);
    { the side it moves to: its radius, or half its height up and down }
    Reach := TVector3.Zero;
    if Axis = 1 then
      Reach.Data[Axis] := Sign(S.Data[Axis]) * Height / 2
    else
      Reach.Data[Axis] := Sign(S.Data[Axis]) * Radius;
    if FMap.World.WorldSegmentCollision(Center, Center + S + Reach) then
      Blocked := True
    else
      Result := Result + S;
  end;
end;

procedure TD3Game.UpdateFlying(const A: TD3Actor; const SecondsPassed: Single);
const
  { idAI: AI_SEEK_PREDICTION, AI_FLY_DAMPENING }
  SeekPrediction = 0.3;
  FlyDampening = 0.15;
var
  Pos, Feet, Goal, Vel, Dir, Target, Left, Up, Center: TVector3;
  Radius, Height, Speed, S, T, Roll, Pitch, HitDist: Single;
  Reached, Blocked: Boolean;
  Axis: TMatrix3;

  { idAI's Seek: towards Goal, from where it will be soon }
  function Seek(const Goal: TVector3): TVector3;
  begin
    Result := (Goal - (Pos + Vel * SeekPrediction)) * SecondsPassed;
  end;

  procedure Stop;
  begin
    A.Moving := False;
    A.ChaseEnemy := False;
    A.MoveDirect := False;
  end;

begin
  Pos := CgeToD3(A.Model.Holder.Translation);
  Feet := CgeToD3(FPlayerEye - Vector3(0, PlayerEyeHeight, 0));
  Radius := ActorRadius(A);
  Height := ActorHeight(A);
  { idAI::ReachedPos }
  if A.Moving then
  begin
    if A.ChaseEnemy then
      Reached := not A.HasEnemy or
        (Sqrt(Sqr(Feet.X - Pos.X) + Sqr(Feet.Y - Pos.Y)) <= A.MeleeRange)
    else
      Reached := (Sqrt(Sqr(A.Goal.X - Pos.X) + Sqr(A.Goal.Y - Pos.Y)) <= 16) and
        (A.Goal.Z >= Pos.Z - 16) and (A.Goal.Z <= Pos.Z + Height);
    if Reached then
      Stop;
  end;
  if A.Moving then
    Speed := A.FlySpeed
  else
    Speed := 0;
  Vel := A.Velocity;
  Axis := AnglesMatrix(Vector3(0, A.Yaw, 0));
  Left := Vector3(Axis.Data[1, 0], Axis.Data[1, 1], Axis.Data[1, 2]);
  Up := Vector3(0, 0, 1);
  if not A.MoveDirect then
  begin
    if A.Moving and A.ChaseEnemy then
      Goal := Feet
    else
    if A.Moving then
      Goal := A.Goal
    else
      Goal := Pos;
    { around walls: along its AAS route }
    if A.Moving then
      Goal := FlyRouteWaypoint(A.Route, Pos, Goal, Radius, Height);
    if Speed > 0 then
      Vel := Vel + Seek(Goal) * A.FlySeekScale;
    { idAI::AddFlyBob }
    if A.FlyBobStrength <> 0 then
    begin
      T := FTime + A.Handle * 0.497;
      Vel := Vel + (Left * Sin(T * A.FlyBobHorz) + Up * Sin(T * A.FlyBobVert)) *
        (A.FlyBobStrength * SecondsPassed);
    end;
    { idAI::AdjustFlyHeight: up to the enemy's eyes plus fly_offset (not
      when flying to a position), as far as the ceiling lets it }
    if A.HasEnemy and not (A.Moving and not A.ChaseEnemy) then
    begin
      Target := Vector3(Pos.X, Pos.Y, Feet.Z + PlayerEyeHeight + A.FlyOffset);
      Center := D3ToCge(Pos) + Vector3(0, Height / 2, 0);
      S := Target.Z - Pos.Z;
      if (Abs(S) > 0.01) and
         (FMap.World.WorldRayCast(Center, Vector3(0, Sign(S), 0), HitDist) <> nil) and
         (HitDist < Abs(S) + Height / 2) then
        Target.Z := Pos.Z + Sign(S) * Max(0, HitDist - Height / 2);
      Vel := Vel + Seek(Target);
    end;
    { idAI::AdjustFlySpeed: damp, then ease towards the move's speed }
    Vel := Vel - Vel * (FlyDampening * SecondsPassed);
    S := Vel.Length;
    if S > 0.0001 then
      Dir := Vel / S
    else
      Dir := TVector3.Zero;
    S := S + (Speed - S) * SecondsPassed;
    if S < 0 then
      S := 0
    else
    if (Speed > 0) and (S > Speed) then
      S := Speed;
    Vel := Dir * S;
  end;
  { idAI::FlyTurn: moving, it faces where it flies }
  if A.Moving and not A.MoveDirect and (Sqr(Vel.X) + Sqr(Vel.Y) > 0.1) then
    A.IdealYaw := RadToDeg(ArcTan2(Vel.Y, Vel.X));
  A.Model.Holder.Translation := FlyStep(A.Model.Holder.Translation, D3ToCge(Vel * SecondsPassed),
    Radius, Height, Blocked);
  if Blocked and A.MoveDirect then
  begin
    { a charge stops at the wall }
    Stop;
    Vel := TVector3.Zero;
  end;
  A.Velocity := Vel;
  { idAI::AdjustFlyingAngles: lean into turns }
  if Vel.Length < 5 then
  begin
    Roll := 0;
    Pitch := 0;
  end else
  begin
    Roll := EnsureRange(TVector3.DotProduct(Vel, Left) * -A.FlyRollScale / Max(1, A.FlySpeed),
      -A.FlyRollMax, A.FlyRollMax);
    Pitch := EnsureRange(TVector3.DotProduct(Vel, Up) * -A.FlyPitchScale / Max(1, A.FlySpeed),
      -A.FlyPitchMax, A.FlyPitchMax);
  end;
  { idAI eases them by 5% a tick (60 a second) }
  T := 1 - Power(0.95, SecondsPassed * 60);
  A.FlyRoll := A.FlyRoll + (Roll - A.FlyRoll) * T;
  A.FlyPitch := A.FlyPitch + (Pitch - A.FlyPitch) * T;
end;

function TD3Game.ActorRadius(const A: TD3Actor): Single;
begin
  if A.Monster <> nil then
    Result := A.Monster.Radius
  else
    Result := ParseVector3(A.Model.Entity.Value('size'), Vector3(32, 32, 72)).X / 2;
end;

function TD3Game.ActorHeight(const A: TD3Actor): Single;
begin
  if A.Monster <> nil then
    Result := A.Monster.Height
  else
    Result := ParseVector3(A.Model.Entity.Value('size'), Vector3(32, 32, 72)).Z;
end;

procedure TD3Game.KillActor(const A: TD3Actor);
begin
  if (A.Monster = nil) or (A.Monster.State = msDead) then
    Exit;
  A.Monster.Health := 0;
  A.Monster.State := msDead;
  A.Monster.StateTime := 0;
  ActorDamaged(A, True);
end;

procedure TD3Game.SetMonsterYaw(const M: TD3Monster; const YawDeg: Single);
begin
  M.Yaw := YawDeg;
  SetD3Rotation(M.Model.Holder, YawMatrix(YawDeg));
end;

procedure TD3Game.Spawn;
var
  B: TD3BrushEntity;
  ME: TD3ModelEntity;
  E: TD3MapEntity;
  Hidden, Dormant: Integer;
  Mon: TD3Monster;
  Cls: String;
begin
  Clear;
  FDeadTime := 0;
  if FMap.MapName <> '' then
  begin
    FAas := TD3AasFile.Create;
    if not FAas.LoadFromVfs(TDoom3Map.MapBasePath(FMap.MapName) + '.aas48') then
      FreeAndNil(FAas);
  end;
  for B in FMap.Brushes do
  begin
    SpawnMover(B);
    if B.Entity.Value('spawnclass') = 'idMoveable' then
      SpawnMoveable(B);
  end;
  for ME in FMap.Models do
  begin
    if ME.Entity.Value('spawnclass') = 'idAnimated' then
    begin
      SpawnAnimated(ME);
      Continue;
    end;
    Cls := LowerCase(ME.Entity.ClassName_);
    if (Copy(Cls, 1, 8) <> 'monster_') or ME.Hidden then
      Continue;
    SpawnMonster(ME);
  end;
  if FMap.MapFile <> nil then
    for E in FMap.MapFile.Entities do
    begin
      if E.Name <> '' then
        FEntities.AddOrSetValue(LowerCase(E.Name), E);
      Cls := LowerCase(E.ClassName_);
      if Cls = 'speaker' then
        SpawnSpeaker(E)
      else
      if (Cls = 'trigger_once') or (Cls = 'trigger_multiple') or (Cls = 'trigger_hurt') then
        SpawnTrigger(E)
      else
      if E.Value('spawnclass') = 'idCombatNode' then
        SpawnCombatNode(E)
      else
      if (E.Value('spawnclass') = 'idItem') or (E.Value('spawnclass') = 'idMoveableItem') or
         (E.Value('spawnclass') = 'idItemPowerup') or (E.Value('spawnclass') = 'idPDAItem') or
         (E.Value('spawnclass') = 'idMoveablePDAItem') or (E.Value('spawnclass') = 'idVideoCDItem') then
        SpawnItem(E);
    end;
  InitInventory;
  SpreadLocations;
  SpawnBindings;
  LoadProfileStep('spawn');
  StartScripts;
  LoadProfileStep('scripts');
  SpawnActors;
  LoadProfileStep('actors');
  Hidden := 0;
  Dormant := 0;
  for ME in FMap.Models do
    if ME.Hidden and (Copy(LowerCase(ME.Entity.ClassName_), 1, 8) = 'monster_') then
      Inc(Hidden);
  for Mon in FMonsters do
    if Mon.Dormant then
      Inc(Dormant);
  WritelnLog('Doom3World', 'Spawned %d movers, %d monsters (%d dormant until triggered, %d hidden), %d speakers, %d triggers, %d bound entities',
    [FMovers.Count, FMonsters.Count, Dormant, Hidden, FSpeakers.Count, FTriggers.Count, FBindings.Count]);
end;

function TD3Game.SpawnMonster(const ME: TD3ModelEntity): TD3Monster;
begin
  Result := TD3Monster.Create;
  Result.Model := ME;
  Result.Health := 50;
  if ME.EntityDef <> nil then
    Result.Health := StrToIntDef(ME.EntityDef.Values['health'], 50);
  Result.Health := ME.Entity.IntValue('health', Result.Health);
  Result.Radius := 20;
  Result.Height := 72;
  Result.Yaw := ME.Entity.Angle;
  Result.Dormant := ME.Entity.BoolValue('trigger');
  if ME.Entity.Value('anim') <> '' then
    ME.Instance.PlayAnim(ME.Entity.Value('anim'));
  FMonsters.Add(Result);
end;

procedure TD3Game.SpawnTrigger(const E: TD3MapEntity);
var
  T: TD3Trigger;
  Model: TD3CollisionModel;
  Rot: TMatrix3;
  V, W, BoxMin, BoxMax: TVector3;
  I, J: Integer;
  DamageDef: TStringList;
begin
  { the volume: the entity's collision model (brush triggers), placed at
    its origin and rotated }
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
    { rows of Rot are the rotated axes }
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

  T := TD3Trigger.Create;
  T.Entity := E;
  T.Box := Box3D(BoxMin, BoxMax);
  if SameText(E.ClassName_, 'trigger_once') then
    T.Kind := tkOnce
  else
  if SameText(E.ClassName_, 'trigger_hurt') then
    T.Kind := tkHurt
  else
    T.Kind := tkMultiple;
  if T.Kind = tkHurt then
  begin
    { idTrigger_Hurt: damage every "delay" seconds while touched }
    T.Wait := E.FloatValue('delay', 1);
    T.Disabled := not E.BoolValue('on', True);
    T.Damage := 10;
    DamageDef := Decls.EntityDef(E.Value('def_damage', 'damage_painTrigger'));
    if DamageDef <> nil then
      T.Damage := StrToIntDef(DamageDef.Values['damage'], T.Damage);
  end else
  begin
    T.Delay := E.FloatValue('delay', 0);
    T.Wait := E.FloatValue('wait', 0.5);
  end;
  T.WaitingForActivation := E.BoolValue('triggerFirst');
  T.NoTouch := E.BoolValue('noTouch');
  FTriggers.Add(T);
end;

function TD3Game.FindEntity(const AName: String): TD3MapEntity;
begin
  if not FEntities.TryGetValue(LowerCase(AName), Result) then
    Result := nil;
end;

procedure TD3Game.Unsupported(const What: String);
begin
  if FUnsupported.IndexOf(What) < 0 then
  begin
    FUnsupported.Add(What);
    WritelnLog('Doom3World', 'Not supported yet: %s', [What]);
  end;
end;

procedure TD3Game.ActivateTargets(const E: TD3MapEntity; const Delay: Single);
var
  P: TD3PendingTargets;
begin
  P.Time := FTime + Max(0, Delay);
  P.Entity := E;
  FPending.Add(P);
end;

procedure TD3Game.ActivateTargetsNow(const E: TD3MapEntity);
var
  I: Integer;
  Key: String;
  Target: TD3MapEntity;
begin
  { idTrigger::CallScript: the "call" function, in a new script thread }
  if E.HasKey('call') then
    CallScript(E.Value('call'), E.Name);
  for I := 0 to E.Pairs.Count - 1 do
  begin
    Key := LowerCase(E.Pairs.Names[I]);
    { "target", "target1", "target2"... (not "targetname" etc.) }
    if (Copy(Key, 1, 6) <> 'target') or
       ((Length(Key) > 6) and not CharInSet(Key[7], ['0'..'9'])) then
      Continue;
    Target := FindEntity(E.Pairs.ValueFromIndex[I]);
    if Target <> nil then
      Activate(Target);
  end;
end;

procedure TD3Game.FireTrigger(const T: TD3Trigger);
begin
  if T.Disabled then
    Exit;
  if T.Kind = tkOnce then
    T.Disabled := True;
  T.NextTime := FTime + T.Wait;
  WritelnLog('Doom3World', 'Trigger %s fired', [T.Entity.Name]);
  ActivateTargets(T.Entity, T.Delay);
end;

procedure TD3Game.RemoveEntity(const E: TD3MapEntity);
var
  I: Integer;
  B: TD3BrushEntity;
  ME: TD3ModelEntity;
  Mon: TD3Monster;
  S: TD3Speaker;
begin
  I := FMap.FindLight(E.Name);
  if I >= 0 then
    FMap.SetLightOn(I, False);
  B := FMap.FindBrush(E.Name);
  if B <> nil then
    B.SetHidden(True);
  ME := FMap.FindModelEntity(E.Name);
  if ME <> nil then
  begin
    ME.Hidden := True;
    ME.Holder.Exists := False;
    for Mon in FMonsters do
      if Mon.Model = ME then
      begin
        Mon.State := msDead;
        Mon.StateTime := 1000;
      end;
  end;
  for S in FSpeakers do
    if S.Entity = E then
    begin
      S.Source.Sound := nil;
    end;
end;

procedure TD3Game.Activate(const E: TD3MapEntity);
var
  Cls: String;
  I, Count: Integer;
  Trig: TD3Trigger;
  Mover: TD3Mover;
  B: TD3BrushEntity;
  ME: TD3ModelEntity;
  Mon: TD3Monster;
  S: TD3Speaker;
  Handled: Boolean;
  SpawnClass: String;
begin
  Inc(ActivationCount);
  Cls := LowerCase(E.ClassName_);
  Handled := False;

  if Cls = 'light' then
  begin
    { idLight::Event_ToggleOnOff }
    I := FMap.FindLight(E.Name);
    if I >= 0 then
    begin
      FMap.SetLightOn(I, not FMap.Light(I).StartOn);
      WritelnLog('Doom3World', 'Light %s %s', [E.Name, BoolToStr(FMap.Light(I).StartOn, 'on', 'off')]);
    end;
    Exit;
  end;

  { by the entityDef's game class }
  SpawnClass := E.Value('spawnclass');
  if (SpawnClass = 'idCameraAnim') or (SpawnClass = 'idCameraView') then
  begin
    { start, or stop when it plays (idCameraAnim::Event_Activate) }
    if FCameraEntity = E then
      StopCamera
    else
      StartCamera(E);
    Exit;
  end;
  if (SpawnClass = 'idMoveable') and (MoveableOf(E) <> nil) then
  begin
    { idMoveable::Event_Activate: starts moving at init_velocity }
    MoveableOf(E).Velocity := E.VectorValue('init_velocity', TVector3.Zero);
    MoveableOf(E).AtRest := False;
    Exit;
  end;
  if ItemOf(E) <> nil then
  begin
    { idItem::Event_Trigger: a triggerFirst item can be picked up from
      now on, otherwise the player (the activator) picks it up }
    if not ItemOf(E).CanPickUp and E.BoolValue('triggerFirst') then
      ItemOf(E).CanPickUp := True
    else
      PickupItem(ItemOf(E));
    Exit;
  end;
  if SpawnClass = 'idCombatNode' then
  begin
    { idCombatNode::Event_Activate toggles it }
    if CombatNodeOf(E) <> nil then
      CombatNodeOf(E).Disabled := not CombatNodeOf(E).Disabled;
    Exit;
  end;
  if SpawnClass = 'idTrigger_Fade' then
  begin
    StartFade(E.Vector4Value('fadeColor', Vector4(0, 0, 0, 1)), E.FloatValue('fadeTime', 1));
    Exit;
  end;
  if SpawnClass = 'idPlayerStart' then
  begin
    { idPlayerStart::Event_TeleportPlayer }
    FTeleportPending := True;
    FTeleportPos := D3ToCge(E.Origin);
    FTeleportYaw := E.Angle;
    WritelnLog('Doom3World', 'Teleport to %s', [E.Name]);
    Exit;
  end;

  if Cls = 'trigger_relay' then
  begin
    ActivateTargets(E, E.FloatValue('delay', 0));
    Exit;
  end;

  if Cls = 'trigger_count' then
  begin
    { fires its targets every "count" activations }
    if not FCounts.TryGetValue(LowerCase(E.Name), Count) then
      Count := 0;
    Inc(Count);
    if Count >= Max(1, E.IntValue('count', 1)) then
    begin
      Count := 0;
      ActivateTargets(E, E.FloatValue('delay', 0));
    end;
    FCounts.AddOrSetValue(LowerCase(E.Name), Count);
    Exit;
  end;

  if (Cls = 'trigger_once') or (Cls = 'trigger_multiple') or (Cls = 'trigger_hurt') then
  begin
    for Trig in FTriggers do
      if Trig.Entity = E then
      begin
        if Trig.Kind = tkHurt then
          Trig.Disabled := not Trig.Disabled { switched on / off }
        else
        if Trig.WaitingForActivation then
          Trig.WaitingForActivation := False { now it can be touched }
        else
          FireTrigger(Trig);
        Exit;
      end;
    { a trigger without a volume still relays }
    ActivateTargets(E, E.FloatValue('delay', 0));
    Exit;
  end;

  if Cls = 'func_remove' then
  begin
    { removes its targets }
    for I := 0 to E.Pairs.Count - 1 do
      if Copy(LowerCase(E.Pairs.Names[I]), 1, 6) = 'target' then
        if FindEntity(E.Pairs.ValueFromIndex[I]) <> nil then
          RemoveEntity(FindEntity(E.Pairs.ValueFromIndex[I]));
    Exit;
  end;

  if (Cls = 'target_null') or (Copy(Cls, 1, 5) = 'path_') then
    Exit;

  { a speaker whose sound didn't load: nothing to start or stop }
  Handled := Cls = 'speaker';

  for S in FSpeakers do
    if S.Entity = E then
    begin
      { idSound::Event_Trigger: start / stop }
      if S.Looping then
      begin
        if S.Source.Sound <> nil then
          S.Source.Sound := nil
        else
          S.Source.Sound := S.Sound;
      end else
        S.Source.Play(S.Sound);
      Exit;
    end;

  if Cls = 'target_lock' then
  begin
    { idTarget_LockDoor: "locked" 1 locks its target doors, 0 unlocks }
    for I := 0 to E.Pairs.Count - 1 do
      if Copy(LowerCase(E.Pairs.Names[I]), 1, 6) = 'target' then
        for Mover in FMovers do
          if (Mover.Kind = mkDoor) and
             SameText(Mover.Brush.Entity.Name, E.Pairs.ValueFromIndex[I]) then
            LockTeam(Mover, E.IntValue('locked', 1) <> 0);
    Exit;
  end;

  for Mover in FMovers do
    if Mover.Brush.Entity = E then
    begin
      if Mover.Kind = mkDoor then
      begin
        { idDoor::Event_Activate: unlock, else open / close (the team) }
        if Mover.Locked then
          LockTeam(Mover, False)
        else
        if Mover.State in [dsClosed, dsClosing] then
          OpenTeam(Mover)
        else
          CloseTeam(Mover);
      end else
        { idRotater: start / stop }
        Mover.Running := not Mover.Running;
      Exit;
    end;

  if FindAnimated(E) <> nil then
  begin
    ActivateAnimated(FindAnimated(E));
    Exit;
  end;
  if FindActor(EntityHandle(E)) <> nil then
  begin
    { idAI::Event_Activate: the script sees AI_ACTIVATED }
    FindActor(EntityHandle(E)).SetFlag('AI_ACTIVATED', 1);
    Exit;
  end;

  ME := FMap.FindModelEntity(E.Name);
  { a cinematic character (idAI with "cinematic"): shows up and plays its
    "anim" once, holding the last frame (its AI script's cinematic state) }
  if (ME <> nil) and E.BoolValue('cinematic') and (Copy(Cls, 1, 8) <> 'monster_') then
  begin
    ME.Hidden := False;
    ME.Holder.Exists := True;
    if (E.Value('anim') <> '') and ME.Instance.PlayAnim(E.Value('anim'), False) then
    begin
      { the head plays its own animation of the same name (lip sync) }
      if ME.HeadInstance <> nil then
        ME.HeadInstance.PlayAnim(E.Value('anim'), False);
      WritelnLog('Doom3World', 'Cinematic %s plays "%s"', [E.Name, E.Value('anim')]);
    end;
    Exit;
  end;
  if (ME <> nil) and (Copy(Cls, 1, 8) = 'monster_') then
  begin
    if ME.Hidden then
    begin
      { a hidden monster appears (and is awake) }
      ME.Hidden := False;
      ME.Holder.Exists := True;
      Mon := SpawnMonster(ME);
      Mon.Dormant := False;
    end else
      for Mon in FMonsters do
        if Mon.Model = ME then
          Mon.Dormant := False;
    WritelnLog('Doom3World', 'Monster %s activated', [E.Name]);
    Exit;
  end;

  { func_static, func_animate...: "hide" entities toggle (idStaticEntity) }
  if E.HasKey('hide') then
  begin
    B := FMap.FindBrush(E.Name);
    if B <> nil then
    begin
      B.SetHidden(not B.Hidden);
      Handled := True;
    end;
    if ME <> nil then
    begin
      ME.Hidden := not ME.Hidden;
      ME.Holder.Exists := not ME.Hidden;
      Handled := True;
    end;
  end;
  { func_static without "hide": idStaticEntity only toggles its "active"
    state (for its materials' shader parameters), nothing visible here }
  if Cls = 'func_static' then
    Handled := True;
  if not Handled then
    Unsupported('activating ' + Cls);
end;

procedure TD3Game.UpdateTriggers(const Feet: TVector3);
var
  PlayerBox: TBox3D;
  T: TD3Trigger;
  Steps: Integer;
  P: TD3PendingTargets;
  I: Integer;
begin
  { touches }
  if not PlayerDead then
  begin
    PlayerBox := Box3D(
      Feet - Vector3(PlayerRadius, 0, PlayerRadius),
      Feet + Vector3(PlayerRadius, PlayerEyeHeight + 6, PlayerRadius));
    for T in FTriggers do
      if (not T.Disabled) and (not T.NoTouch) and (not T.WaitingForActivation) and
         (FTime >= T.NextTime) and T.Box.Collision(PlayerBox) then
      begin
        if T.Kind = tkHurt then
        begin
          T.NextTime := FTime + T.Wait;
          DamagePlayer(T.Damage);
        end else
          FireTrigger(T);
      end;
  end;

  { delayed target firings; a bounded number per frame, so a loop of relays
    can't hang the game }
  Steps := 0;
  I := 0;
  while (I < FPending.Count) and (Steps < 1000) do
  begin
    if FPending[I].Time <= FTime then
    begin
      P := FPending[I];
      FPending.Delete(I);
      Inc(Steps);
      ActivateTargetsNow(P.Entity);
      I := 0; // activations may have added (or removed) items
    end else
      Inc(I);
  end;
end;

function TD3Game.CanSee(const A, B: TVector3): Boolean;
var
  Dist, HitDist: Single;
begin
  { sight is a trace against opaque geometry (MASK_OPAQUE): the pickable
    render geometry and brush entities, not the playerclip / monsterclip
    brushes of the collision model }
  Dist := (B - A).Length;
  if Dist < 1 then
    Exit(True);
  Result := (FMap.World.WorldRayCast(A, (B - A) / Dist, HitDist) = nil) or (HitDist >= Dist);
end;

procedure TD3Game.UpdateMonster(const M: TD3Monster; const SecondsPassed: Single;
  const PlayerPos: TVector3);
var
  ToPlayer, Step, NewPos, Eye, FloorStart, Waypoint: TVector3;
  Dist, FloorDist: Single;
  Hit: TCastleTransform;
begin
  M.StateTime := M.StateTime + SecondsPassed;
  if (M.Actor <> nil) and (M.State <> msDead) then
    Exit;
  if M.State = msDead then
  begin
    { a flying one falls to the floor first (Doom 3's gravity, 1066) }
    if M.Falling then
    begin
      M.StateTime := 0;
      M.FallSpeed := M.FallSpeed + 1066 * SecondsPassed;
      FloorStart := M.Model.Holder.Translation + Vector3(0, 1, 0);
      Hit := FMap.World.WorldRayCast(FloorStart, Vector3(0, -1, 0), FloorDist);
      if Hit = nil then
        { nothing below: stays }
        M.Falling := False
      else
      if FloorDist - 1 <= M.FallSpeed * SecondsPassed then
      begin
        M.Model.Holder.Translation := FloorStart - Vector3(0, FloorDist, 0);
        M.Falling := False;
      end else
        M.Model.Holder.Translation := M.Model.Holder.Translation - Vector3(0, M.FallSpeed * SecondsPassed, 0);
      Exit;
    end;
    { sink into the floor, then disappear }
    if M.StateTime > 1.5 then
      M.Model.Holder.Translation := M.Model.Holder.Translation - Vector3(0, 30 * SecondsPassed, 0);
    if M.StateTime > 4 then
      M.Model.Holder.Exists := False;
    Exit;
  end;
  if M.PainTime > 0 then
    M.PainTime := M.PainTime - SecondsPassed;

  Eye := M.Position + Vector3(0, M.Height * 0.8, 0);
  ToPlayer := PlayerPos - M.Position;
  ToPlayer.Y := 0;
  Dist := ToPlayer.Length;

  case M.State of
    msIdle:
      if (not M.Dormant) and (not NoTarget) and not PlayerDead and (Dist < MonsterSightRange) and
         CanSee(Eye, PlayerPos + Vector3(0, PlayerEyeHeight, 0)) then
      begin
        M.State := msChase;
        M.StateTime := 0;
        M.Model.Instance.PlayAnim('walk');
      end;
    msChase:
      begin
        if NoTarget or PlayerDead then
        begin
          M.State := msIdle;
          M.Model.Instance.PlayAnim('idle');
          Exit;
        end;
        if Dist > 0.1 then
          SetMonsterYaw(M, RadToDeg(ArcTan2(-ToPlayer.Z, ToPlayer.X)));
        if Dist <= MonsterMeleeRange then
        begin
          M.State := msAttack;
          M.StateTime := 0;
          M.Model.Instance.PlayAnim('idle');
          Exit;
        end;
        { around walls: towards the next point of the AAS route }
        Waypoint := D3ToCge(RouteWaypoint(M.Route, CgeToD3(M.Position), CgeToD3(PlayerPos)));
        Step := Waypoint - M.Position;
        Step.Y := 0;
        if Step.Length < 0.5 then
          Step := ToPlayer;
        Step := Step.Normalize * (MonsterWalkSpeed * SecondsPassed);
        if not Step.IsZero then
          SetMonsterYaw(M, RadToDeg(ArcTan2(-Step.Z, Step.X)));
        M.Model.Holder.Translation := StepTowards(M.Position, Step, M.Radius, M.Height);
      end;
    msAttack:
      begin
        if NoTarget or PlayerDead then
        begin
          M.State := msIdle;
          M.Model.Instance.PlayAnim('idle');
          Exit;
        end;
        if Dist > MonsterMeleeRange * 1.3 then
        begin
          M.State := msChase;
          M.Model.Instance.PlayAnim('walk');
          Exit;
        end;
        if Dist > 0.1 then
          SetMonsterYaw(M, RadToDeg(ArcTan2(-ToPlayer.Z, ToPlayer.X)));
        M.AttackTimer := M.AttackTimer - SecondsPassed;
        if M.AttackTimer <= 0 then
        begin
          M.AttackTimer := MonsterAttackDelay;
          DamagePlayer(MonsterDamage, '', FPlayerEye - M.Center);
        end;
      end;
    else ;
  end;
end;

procedure TD3Game.Update(const SecondsPassed: Single; const PlayerEye: TVector3);
var
  P: Integer;
  Mover: TD3Mover;
  Mon: TD3Monster;
  Feet: TVector3;
begin
  FFireCooldown := Max(0, FFireCooldown - SecondsPassed);
  SinceFire := SinceFire + SecondsPassed;
  FTime := FTime + SecondsPassed;
  FPlayerEye := PlayerEye;
  if PlayerDead then
    FDeadTime := FDeadTime + SecondsPassed;
  Feet := PlayerEye - Vector3(0, PlayerEyeHeight, 0);
  for Mover in FMovers do
  begin
    if (Mover.Kind = mkDoor) and not Mover.NoTouch and not PlayerDead and
       Mover.TriggerBox.Contains(PlayerEye) then
      OpenTeam(Mover);
    { monsters open doors too (idDoor's trigger touched by an actor): the
      AAS routes them through doorways }
    if (Mover.Kind = mkDoor) and not Mover.NoTouch and (Mover.State <> dsOpen) then
      for Mon in FMonsters do
        if (Mon.State <> msDead) and Mon.Model.Holder.Exists and
           Mover.TriggerBox.Contains(Mon.Center) then
        begin
          OpenTeam(Mover);
          Break;
        end;
    Mover.Update(SecondsPassed);
    { a shut door closes its area portal (like idDoor) }
    if FMap.Portals <> nil then
      for P in Mover.Portals do
        FMap.Portals.PortalClosed[P] := Mover.State = dsClosed;
  end;
  if not ScriptsPaused then
    UpdateScriptMovers;
  UpdateBindings;
  UpdateMoveables(SecondsPassed);
  UpdateItems;
  UpdateCamera;
  UpdateLightFades;
  UpdateAnimated;
  UpdateProjectiles(SecondsPassed);
  for Mon in FMonsters do
    UpdateMonster(Mon, SecondsPassed, Feet);
  UpdateTriggers(Feet);
  if (FScript <> nil) and not ScriptsPaused then
    UpdateActors(SecondsPassed);
  UpdateWeapon(SecondsPassed);
  if (FScript <> nil) and not ScriptsPaused then
    FScript.Update(FTime);
  { after its script: a shot of this frame shows its flash now }
  UpdateWeaponView(SecondsPassed);
end;

procedure TD3Game.UpdateWeaponView(const SecondsPassed: Single);
begin
  if (FWeapon = nil) or (FWeapon.View = nil) then
    Exit;
  PresentWeapon(FWeapon);
  FWeapon.View.Shown := FWeapon.Holder.Exists;
  FWeapon.View.Update(SecondsPassed);
end;

constructor TD3Actor.Create;
var
  C: Integer;
begin
  inherited Create;
  for C := Low(Channels) to High(Channels) do
    Channels[C] := TD3ActorChannel.Create;
end;

destructor TD3Actor.Destroy;
var
  C: Integer;
begin
  for C := Low(Channels) to High(Channels) do
    Channels[C].Free;
  Obj.Free;
  inherited Destroy;
end;

procedure TD3Actor.SetFlag(const AName: String; const Value: Single);
var
  I: Integer;
begin
  if Obj.Typ.FindField(AName, I) then
    Obj.Fields[I] := D3FloatValue(Value);
end;

function TD3Game.ScriptEntityObject(const Handle: Integer): TD3ScriptObject;
var
  A: TD3Actor;
begin
  if Handle = WeaponHandle then
  begin
    if FWeapon <> nil then
      Result := FWeapon.Obj
    else
      Result := nil;
    Exit;
  end;
  A := FindActor(Handle);
  if A <> nil then
    Result := A.Obj
  else
    Result := nil;
end;

function TD3Game.FindActor(const Handle: Integer): TD3Actor;
begin
  if Handle <= 0 then
    Exit(nil);
  for Result in FActors do
    if Result.Handle = Handle then
      Exit;
  Result := nil;
end;

procedure TD3Game.SpawnActors;
var
  ME: TD3ModelEntity;
  E: TD3MapEntity;
  T, Character: TD3ScriptType;
  A: TD3Actor;
  C, MonsterCount, I, J: Integer;
  LookScale: TVector3;
  IsMonster, Supported: Boolean;
  SName: String;
  Mon, M: TD3Monster;
begin
  if FScript = nil then
    Exit;
  Character := FScript.FindType('character');
  MonsterCount := 0;
  for ME in FMap.Models do
  begin
    E := ME.Entity;
    { characters, and monsters whose script object is supported; cinematic
      characters just play their anim (Activate) }
    if (E.Value('spawnclass') <> 'idAI') or E.BoolValue('cinematic') then
      Continue;
    T := FScript.FindType(E.Value('scriptobject'));
    if T = nil then
      Continue;
    IsMonster := Copy(LowerCase(E.ClassName_), 1, 8) = 'monster_';
    if IsMonster then
    begin
      Supported := False;
      for SName in ScriptedMonsterObjects do
        if (FScript.FindType(SName) <> nil) and T.IsA(FScript.FindType(SName)) then
          Supported := True;
      if not Supported then
        Continue;
    end else
    if (Character = nil) or not T.IsA(Character) then
      Continue;
    A := TD3Actor.Create;
    A.Model := ME;
    A.Handle := EntityHandle(E);
    A.Obj := TD3ScriptObject.Create(T);
    A.Thinking := True;
    A.MeleeRange := E.FloatValue('melee_range', 64);
    { idAI::Spawn's flying settings (it reads fly_bob_vert into the
      horizontal bob and fly_bob_horz into the vertical one) }
    A.MoveType := MoveTypeAnim;
    A.FlySpeed := E.FloatValue('fly_speed', 100);
    A.FlyOffset := E.FloatValue('fly_offset', 0);
    A.FlyBobStrength := E.FloatValue('fly_bob_strength', 50);
    A.FlyBobHorz := E.FloatValue('fly_bob_vert', 2);
    A.FlyBobVert := E.FloatValue('fly_bob_horz', 2.7);
    A.FlySeekScale := E.FloatValue('fly_seek_scale', 4);
    A.FlyRollScale := E.FloatValue('fly_roll_scale', 90);
    A.FlyRollMax := E.FloatValue('fly_roll_max', 60);
    A.FlyPitchScale := E.FloatValue('fly_pitch_scale', 45);
    A.FlyPitchMax := E.FloatValue('fly_pitch_max', 30);
    { look_joint <joint> = pitch yaw roll shares of the look angles }
    for I := 0 to E.Pairs.Count - 1 do
      if SameText(Copy(E.Pairs.Names[I], 1, 11), 'look_joint ') then
      begin
        J := ME.Instance.Model.JointIndex(Trim(Copy(E.Pairs.Names[I], 12, MaxInt)));
        if J < 0 then
          Continue;
        LookScale := ParseVector3(E.Pairs.ValueFromIndex[I], TVector3.Zero);
        SetLength(A.LookJoints, Length(A.LookJoints) + 1);
        A.LookJoints[High(A.LookJoints)].Joint := J;
        A.LookJoints[High(A.LookJoints)].Scale := Vector2(LookScale.X, LookScale.Y);
      end;
    LookScale := ParseVector3(E.Value('look_min'), Vector3(-80, -180, 0));
    A.LookMin := Vector2(LookScale.X, LookScale.Y);
    LookScale := ParseVector3(E.Value('look_max'), Vector3(80, 180, 0));
    A.LookMax := Vector2(LookScale.X, LookScale.Y);
    A.HeadFocusRate := E.FloatValue('head_focus_rate', 0.1);
    ME.Instance.OnFrameCommand := @ActorFrameCommand;
    if ME.HeadInstance <> nil then
      ME.HeadInstance.OnFrameCommand := @ActorFrameCommand;
    if IsMonster then
    begin
      { health and shots: the game's monster, its simple AI off }
      Mon := nil;
      for M in FMonsters do
        if M.Model = ME then
          Mon := M;
      if Mon = nil then
        Mon := SpawnMonster(ME);
      Mon.Actor := A;
      Mon.Dormant := False;
      A.Monster := Mon;
      Inc(MonsterCount);
    end;
    A.Yaw := E.Angle;
    A.IdealYaw := A.Yaw;
    A.TurnRate := E.FloatValue('turn_rate', 360);
    A.Main := FScript.NewPersistentThread(E.Name + ' state');
    A.Main.Tag := A.Handle;
    for C := Low(A.Channels) to High(A.Channels) do
    begin
      A.Channels[C].Thread := FScript.NewPersistentThread(E.Name + ' anim ' + IntToStr(C));
      A.Channels[C].Thread.Tag := A.Handle;
      A.Channels[C].Thread.Channel := C;
    end;
    { idActor::ConstructScriptObject: the object's init in the main thread }
    FScript.RestartThread(A.Main, T.FindMethodToRun('init'), A.Handle);
    FActors.Add(A);
  end;
  if FActors.Count > 0 then
    WritelnLog('Doom3World', 'Actors: %d run their AI scripts (%d monsters)', [FActors.Count, MonsterCount]);
end;

function TD3Game.ActorChannel(const A: TD3Actor; const Channel: Single): TD3ActorChannel;
var
  C: Integer;
begin
  { ANIMCHANNEL_ALL = 0 plays on the body: the legs channel here }
  C := Round(Channel);
  if (C < Low(A.Channels)) or (C > High(A.Channels)) then
    C := 2;
  Result := A.Channels[C];
end;

procedure TD3Game.ActorAnim(const A: TD3Actor; const Channel: Single; const AnimName: String; const Loop: Boolean);
var
  C: TD3ActorChannel;
  Instance: TD3Md5Instance;
begin
  C := ActorChannel(A, Channel);
  { the head channel plays on the head model, the others on the body }
  if Round(Channel) = 3 then
    Instance := A.Model.HeadInstance
  else
    Instance := A.Model.Instance;
  C.AnimStart := FTime;
  C.AnimLoop := Loop;
  C.AnimLength := 0;
  C.AnimName := '';
  if Instance = nil then
    Exit;
  { name1, name2... chosen now, so its length is the one played }
  C.AnimName := Instance.ResolveAnim(AnimName);
  C.AnimLength := Instance.AnimDurationOf(C.AnimName);
  { the head plays its channel at once; the body's anim is chosen in
    UpdateActors from the torso and legs channels }
  if Round(Channel) = 3 then
    Instance.PlayAnim(C.AnimName, Loop);
end;

function TD3Game.ActorEvent(const A: TD3Actor; const Thread: TD3ScriptThread; const N: String;
  const Args: TD3ValueArray; var EventResult: TD3Value): Boolean;
var
  C: TD3ActorChannel;
  F: TD3ScriptFunction;
  Other: TD3MapEntity;
  D: Single;
  Pos: TVector3;
  S: String;
  DamageDef: TStringList;
  I: Integer;
  Targets: array of Integer;
  Node: TD3CombatNode;
  Mov: TD3Moveable;
  Eye, Other3, Dir: TVector3;
  J: Integer;

  function ArgF(const Index: Integer): Single;
  begin
    Result := D3ValueToFloat(Args[Index]);
  end;

  function NormalizeYaw(const Y: Single): Single;
  begin
    Result := Y - 360 * Floor((Y + 180) / 360);
  end;

  procedure MoveTo(const P: TVector3);
  begin
    A.Goal := P;
    A.Moving := True;
    A.ChaseEnemy := False;
    A.MoveDirect := False;
    { the script sees the move started at once (idAI::MoveToPosition) }
    A.SetFlag('AI_MOVE_DONE', 0);
    A.SetFlag('AI_FORWARD', 1);
  end;

  procedure MoveDone;
  begin
    A.Moving := False;
    A.ChaseEnemy := False;
    A.MoveDirect := False;
    A.SetFlag('AI_MOVE_DONE', 1);
    A.SetFlag('AI_FORWARD', 0);
  end;

begin
  Result := True;
  case N of
    'setState', 'setNextState':
      begin
        { the main thread switches to the state function next frame
          (idActor::SetState; setState stops the current one now) }
        F := A.Obj.Typ.FindMethodToRun(D3ValueToString(Args[0]));
        A.IdealFunction := F;
        A.IdealName := D3ValueToString(Args[0]);
        A.HasIdeal := True;
        if (N = 'setState') and (Thread = A.Main) then
          Thread.Yield;
      end;
    'getState': EventResult := D3StringValue(A.StateName);
    'animState':
      begin
        C := ActorChannel(A, ArgF(0));
        C.PendingFunction := A.Obj.Typ.FindMethodToRun(D3ValueToString(Args[1]));
        C.PendingName := D3ValueToString(Args[1]);
        C.HasPending := True;
        if Thread = C.Thread then
          Thread.Yield;
      end;
    'inAnimState':
      begin
        C := ActorChannel(A, ArgF(0));
        if C.HasPending then
          EventResult := D3FloatValue(Ord(SameText(C.PendingName, D3ValueToString(Args[1]))))
        else
          EventResult := D3FloatValue(Ord(SameText(C.StateName, D3ValueToString(Args[1]))));
      end;
    'playAnim':
      begin
        ActorAnim(A, ArgF(0), D3ValueToString(Args[1]), False);
        EventResult := D3FloatValue(1);
      end;
    'playCycle', 'idleAnim':
      begin
        ActorAnim(A, ArgF(0), D3ValueToString(Args[1]), True);
        EventResult := D3FloatValue(1);
      end;
    'animDone':
      begin
        { a played animation (not a cycle) at its end, minus the blend
          frames (24 per second) }
        C := ActorChannel(A, ArgF(0));
        EventResult := D3FloatValue(Ord(not C.AnimLoop and
          (FTime - C.AnimStart >= C.AnimLength - ArgF(1) / 24)));
      end;
    'stopAnim': ActorChannel(A, ArgF(0)).AnimName := '';
    'hasAnim':
      if Round(ArgF(0)) = 3 then
        EventResult := D3FloatValue(Ord((A.Model.HeadInstance <> nil) and
          A.Model.HeadInstance.HasAnim(D3ValueToString(Args[1]))))
      else
        EventResult := D3FloatValue(Ord(A.Model.Instance.HasAnim(D3ValueToString(Args[1]))));
    'chooseAnim':
      if A.Model.Instance.HasAnim(D3ValueToString(Args[1])) then
        EventResult := D3StringValue(D3ValueToString(Args[1]));
    'waitAction':
      begin
        A.WaitAction := D3ValueToString(Args[0]);
        Thread.WaitFor(A.Handle);
      end;
    'finishAction':
      if SameText(A.WaitAction, D3ValueToString(Args[0])) then
        A.WaitAction := '';
    'getEnemy':
      if A.HasEnemy then
        EventResult := D3EntityValue(PlayerHandle)
      else
        EventResult := D3EntityValue(0);
    'setEnemy', 'locateEnemy':
      { the player is the only enemy there is }
      if not NoTarget and not PlayerDead then
        A.HasEnemy := True;
    'clearEnemy':
      begin
        A.HasEnemy := False;
        A.ChaseEnemy := False;
      end;
    'checkForEnemy', 'findEnemy':
      if ActorCanSeePlayer(A, (N = 'checkForEnemy') and (ArgF(0) <> 0)) then
      begin
        A.HasEnemy := True;
        EventResult := D3EntityValue(PlayerHandle);
      end;
    'faceEnemy':
      if A.HasEnemy then
      begin
        Pos := CgeToD3(FPlayerEye) - CgeToD3(A.Model.Holder.Translation);
        if Sqr(Pos.X) + Sqr(Pos.Y) > 0.01 then
          A.IdealYaw := RadToDeg(ArcTan2(Pos.Y, Pos.X));
      end;
    'moveToEnemy':
      if A.HasEnemy then
      begin
        Pos := CgeToD3(FPlayerEye) - CgeToD3(A.Model.Holder.Translation);
        if Sqrt(Sqr(Pos.X) + Sqr(Pos.Y)) <= A.MeleeRange then
          { already there }
          MoveDone
        else
        begin
          A.ChaseEnemy := True;
          A.Moving := True;
          A.MoveDirect := False;
          A.SetFlag('AI_MOVE_DONE', 0);
          A.SetFlag('AI_FORWARD', 1);
        end;
      end else
        MoveDone;
    'enemyRange', 'enemyRange2D':
      begin
        Pos := CgeToD3(FPlayerEye) - CgeToD3(A.Model.Holder.Translation);
        if N = 'enemyRange2D' then
          Pos.Z := 0;
        EventResult := D3FloatValue(Pos.Length);
      end;
    'enemyPosition': EventResult := D3VectorValue(CgeToD3(FPlayerEye - Vector3(0, PlayerEyeHeight, 0)));
    'testMeleeAttack', 'canHitEnemy':
      begin
        Pos := CgeToD3(FPlayerEye) - CgeToD3(A.Model.Holder.Translation);
        D := Sqrt(Sqr(Pos.X) + Sqr(Pos.Y));
        if N = 'testMeleeAttack' then
          EventResult := D3FloatValue(Ord(A.HasEnemy and not PlayerDead and
            (D <= A.MeleeRange + PlayerRadius)))
        else
          EventResult := D3FloatValue(Ord(A.HasEnemy and ActorCanSeePlayer(A, False)));
      end;
    'canReachEnemy', 'canSee': EventResult := D3FloatValue(1);
    'canHitEnemyFromAnim':
      EventResult := D3FloatValue(Ord(A.HasEnemy and ActorCanSeePlayer(A, False)));
    'entityInAttackCone':
      begin
        { within attack_cone degrees of its facing }
        Pos := CgeToD3(FPlayerEye) - CgeToD3(A.Model.Holder.Translation);
        D := RadToDeg(ArcTan2(Pos.Y, Pos.X)) - A.Yaw;
        D := D - 360 * Floor((D + 180) / 360);
        EventResult := D3FloatValue(Ord((Args[0].E = PlayerHandle) and
          (Abs(D) <= A.Model.Entity.FloatValue('attack_cone', 70) / 2)));
      end;
    'predictEnemyPos': EventResult := D3VectorValue(CgeToD3(FPlayerEye - Vector3(0, PlayerEyeHeight, 0)));
    'animLength':
      EventResult := D3FloatValue(A.Model.Instance.AnimDurationOf(
        A.Model.Instance.ResolveAnim(D3ValueToString(Args[1]))));
    { no dodging, leaping, combat nodes or touching yet }
    'touches': EventResult := D3FloatValue(0);
    'getClosestHiddenTarget': EventResult := D3EntityValue(0);
    { dodges: room for an anim's movement (evade_left...), turned to the
      ideal yaw, or towards the enemy }
    'testAnimMove':
      EventResult := D3FloatValue(Ord(AnimMoveClear(A, D3ValueToString(Args[0]), A.IdealYaw)));
    'testAnimMoveTowardEnemy':
      if A.HasEnemy then
      begin
        Pos := CgeToD3(FPlayerEye) - CgeToD3(A.Model.Holder.Translation);
        EventResult := D3FloatValue(Ord(AnimMoveClear(A, D3ValueToString(Args[0]),
          RadToDeg(ArcTan2(Pos.Y, Pos.X)))));
      end else
        EventResult := D3FloatValue(0);
    { combat nodes (idCombatNode) among its targets }
    'getCombatNode':
      begin
        { the closest one closer than the enemy, with the enemy in its cone }
        EventResult := D3EntityValue(0);
        if A.HasEnemy and not PlayerDead then
        begin
          Pos := CgeToD3(A.Model.Holder.Translation);
          D := (Pos - CgeToD3(FPlayerEye - Vector3(0, PlayerEyeHeight, 0))).Length;
          for I := 0 to A.Model.Entity.Pairs.Count - 1 do
            if SameText(Copy(A.Model.Entity.Pairs.Names[I], 1, 6), 'target') then
            begin
              Node := CombatNodeOf(FindEntity(A.Model.Entity.Pairs.ValueFromIndex[I]));
              if (Node <> nil) and not Node.Disabled and
                 Node.PlayerInView(CgeToD3(FPlayerEye - Vector3(0, PlayerEyeHeight, 0))) and
                 ((Pos - Node.Entity.Origin).Length < D) then
              begin
                D := (Pos - Node.Entity.Origin).Length;
                EventResult := D3EntityValue(EntityHandle(Node.Entity));
              end;
            end;
        end;
      end;
    'findEnemyInCombatNodes':
      begin
        EventResult := D3EntityValue(0);
        if not NoTarget and not PlayerDead then
          for I := 0 to A.Model.Entity.Pairs.Count - 1 do
            if SameText(Copy(A.Model.Entity.Pairs.Names[I], 1, 6), 'target') then
            begin
              Node := CombatNodeOf(FindEntity(A.Model.Entity.Pairs.ValueFromIndex[I]));
              if (Node <> nil) and not Node.Disabled and
                 Node.PlayerInView(CgeToD3(FPlayerEye - Vector3(0, PlayerEyeHeight, 0))) then
              begin
                EventResult := D3EntityValue(PlayerHandle);
                Break;
              end;
            end;
      end;
    'enemyInCombatCone':
      begin
        Node := CombatNodeOf(HandleEntity(Args[0].E));
        EventResult := D3FloatValue(Ord(A.HasEnemy and not PlayerDead and (Node <> nil) and
          Node.PlayerInView(CgeToD3(FPlayerEye - Vector3(0, PlayerEyeHeight, 0)))));
      end;
    'getJumpVelocity': EventResult := D3VectorValue(TVector3.Zero);
    'setLinearVelocity':
      ;
    'getPainAnim': EventResult := D3StringValue('pain');
    'stopThinking':
      begin
        A.Thinking := False;
        A.Moving := False;
        Thread.Yield;
      end;
    'getHealth':
      if A.Monster <> nil then
        EventResult := D3FloatValue(A.Monster.Health);
    'getHead':
      { its head is no entity here: the actor stands for it (the head
        channel plays on the head model) }
      if A.Model.HeadInstance <> nil then
        EventResult := D3EntityValue(A.Handle)
      else
        EventResult := D3EntityValue(0);
    'setTalkState': A.TalkState := Round(ArgF(0));
    'lookAt', 'lookAtEntity':
      begin
        { idAI::Event_LookAtEntity: $null_entity or no time stops looking }
        A.FocusTarget := Args[0].E;
        A.FocusUntil := FTime + ArgF(1);
        if (A.FocusTarget = 0) or (ArgF(1) <= 0) then
          A.FocusUntil := 0;
      end;
    'lookAtEnemy':
      if A.HasEnemy then
      begin
        A.FocusTarget := PlayerHandle;
        A.FocusUntil := FTime + ArgF(0);
      end;
    'setTalkTarget':
      begin
        A.TalkTarget := Args[0].E;
        { the script sees it at once (it tests AI_TALK right after) }
        A.SetFlag('AI_TALK', Ord(A.TalkTarget <> 0));
      end;
    'getTalkTarget': EventResult := D3EntityValue(A.TalkTarget);
    'heardSound', 'getObstacle', 'closestEnemyToPoint':
      EventResult := D3EntityValue(0);
    'canBecomeSolid': EventResult := D3FloatValue(1);
    'getTurnDelta': EventResult := D3FloatValue(NormalizeYaw(A.IdealYaw - A.Yaw));
    'facingIdeal': EventResult := D3FloatValue(Ord(Abs(NormalizeYaw(A.IdealYaw - A.Yaw)) < 1));
    'getCurrentYaw': EventResult := D3FloatValue(A.Yaw);
    'turnTo': A.IdealYaw := ArgF(0);
    'turnToPos':
      begin
        Pos := Args[0].V - CgeToD3(A.Model.Holder.Translation);
        if Sqr(Pos.X) + Sqr(Pos.Y) > 0.01 then
          A.IdealYaw := RadToDeg(ArcTan2(Pos.Y, Pos.X));
      end;
    'turnToEntity', 'faceEntity':
      begin
        Other := HandleEntity(Args[0].E);
        if Args[0].E = PlayerHandle then
          Pos := CgeToD3(FPlayerEye) - CgeToD3(A.Model.Holder.Translation)
        else
        if Other <> nil then
          Pos := Other.Origin - CgeToD3(A.Model.Holder.Translation)
        else
          Pos := TVector3.Zero;
        if Sqr(Pos.X) + Sqr(Pos.Y) > 0.01 then
          A.IdealYaw := RadToDeg(ArcTan2(Pos.Y, Pos.X));
      end;
    'moveToEntity':
      begin
        Other := HandleEntity(Args[0].E);
        if Other <> nil then
          MoveTo(Other.Origin);
      end;
    'moveToPosition': MoveTo(Args[0].V);
    'stopMove', 'moveToCover': MoveDone;
    'moveStatus': EventResult := D3FloatValue(Ord(A.Moving)); // MOVE_STATUS_DONE, MOVE_STATUS_MOVING
    'saveMove':
      begin
        A.SavedGoal := A.Goal;
        A.SavedMoving := A.Moving;
      end;
    'restoreMove':
      begin
        A.Goal := A.SavedGoal;
        A.Moving := A.SavedMoving;
      end;
    'getOrigin': EventResult := D3VectorValue(CgeToD3(A.Model.Holder.Translation));
    'getAngles': EventResult := D3VectorValue(Vector3(0, A.Yaw, 0));
    'setAngles':
      begin
        A.Yaw := Args[0].V.Y;
        A.IdealYaw := A.Yaw;
      end;
    'distanceTo':
      begin
        Other := HandleEntity(Args[0].E);
        if Args[0].E = PlayerHandle then
          EventResult := D3FloatValue((CgeToD3(FPlayerEye - Vector3(0, PlayerEyeHeight, 0)) -
            CgeToD3(A.Model.Holder.Translation)).Length)
        else
        if Other <> nil then
        begin
          D := (Other.Origin - CgeToD3(A.Model.Holder.Translation)).Length;
          EventResult := D3FloatValue(D);
        end;
      end;
    { what the game doesn't do (yet): nothing happens }
    'setBoneMod', 'setNeverDormant', 'allowMovement',
    'allowDamage', 'ignoreDamage', 'disablePain', 'enablePain',
    'animTurn', 'becomeSolid', 'becomeNonSolid',
    'kickObstacles', 'preventPain', 'overrideAnim',
    'setBlendFrames', 'checkAnim', 'setAnimPrefix', 'wakeOnFlashlight',
    'setSmokeVisibility', 'clearBurn', 'markUsed', 'muzzleFlash':
      ;
    { attacks (idAI's events); projectiles are no entities here: the
      missile events return $null_entity }
    'attackMissile':
      LaunchMissile(A, D3ValueToString(Args[0]), True, False, TVector3.Zero, True);
    'createMissile':
      CreateMissile(A, D3ValueToString(Args[0]));
    'launchMissile':
      LaunchMissileFrom(A, Args[0].V, Args[1].V);
    'fireMissileAtTarget':
      begin
        S := D3ValueToString(Args[1]);
        Other := FindEntity(S);
        if SameText(S, 'player1') then
          LaunchMissile(A, D3ValueToString(Args[0]), False, True, FPlayerEye - Vector3(0, 20, 0), False)
        else
        if Other <> nil then
          LaunchMissile(A, D3ValueToString(Args[0]), False, True, D3ToCge(Other.Origin), False)
        else
          LaunchMissile(A, D3ValueToString(Args[0]), False, False, TVector3.Zero, False);
      end;
    'attackMelee':
      EventResult := D3FloatValue(Ord(ActorAttackMelee(A, D3ValueToString(Args[0]))));
    'directDamage':
      if Args[0].E = PlayerHandle then
        ActorDirectDamage(A, D3ValueToString(Args[1]));
    'meleeAttackToJoint':
      begin
        { idAI::Event_MeleeAttackToJoint: a trace from its eyes to the
          joint hits the player }
        Pos := MuzzlePosition(A, D3ValueToString(Args[0]));
        if A.HasEnemy and not PlayerDead and
           (SegmentToPlayerDistance(A.Model.Holder.Translation + Vector3(0, 64, 0), Pos,
              FPlayerEye - Vector3(0, PlayerEyeHeight, 0), FPlayerEye) <= PlayerRadius) then
          ActorDirectDamage(A, D3ValueToString(Args[1]));
      end;
    'radiusDamageFromJoint':
      begin
        DamageDef := Decls.EntityDef(D3ValueToString(Args[1]));
        if DamageDef <> nil then
        begin
          if D3ValueToString(Args[0]) = '' then
            Pos := A.Model.Holder.Translation
          else
            Pos := MuzzlePosition(A, D3ValueToString(Args[0]));
          RadiusDamage(Pos, Pos, StrToIntDef(DamageDef.Values['damage'], 0),
            StrToFloatDef(DamageDef.Values['radius'], 0, DefaultFormatSettings), A.Model.Entity.Name,
            D3ValueToString(Args[1]));
        end;
      end;
    'attackBegin': A.Attack := D3ValueToString(Args[0]);
    'attackEnd': A.Attack := '';
    'chargeAttack':
      if A.HasEnemy then
      begin
        { idAI::Event_ChargeAttack: straight at the player, hurting it once
          on touch }
        A.Attack := D3ValueToString(Args[0]);
        if A.MoveType = MoveTypeFly then
        begin
          { straight at the enemy's eyes plus fly_offset, at fly_speed
            (DirectMoveToPosition: no steering) }
          Pos := CgeToD3(FPlayerEye) + Vector3(0, 0, A.FlyOffset);
          MoveTo(Pos);
          A.MoveDirect := True;
          A.Velocity := (Pos - CgeToD3(A.Model.Holder.Translation)).Normalize * A.FlySpeed;
        end else
          MoveTo(CgeToD3(FPlayerEye - Vector3(0, PlayerEyeHeight, 0)));
        Pos := CgeToD3(FPlayerEye) - CgeToD3(A.Model.Holder.Translation);
        if Sqr(Pos.X) + Sqr(Pos.Y) > 0.01 then
          A.IdealYaw := RadToDeg(ArcTan2(Pos.Y, Pos.X));
      end;
    'testChargeAttack':
      { the distance to charge, 0 when it can't (idAI: a clear path) }
      if A.HasEnemy and not PlayerDead and ActorCanSeePlayer(A, False) then
        EventResult := D3FloatValue((CgeToD3(FPlayerEye - Vector3(0, PlayerEyeHeight, 0)) -
          CgeToD3(A.Model.Holder.Translation)).Length)
      else
        EventResult := D3FloatValue(0);
    'canHitEnemyFromJoint':
      EventResult := D3FloatValue(Ord(A.HasEnemy and ActorCanSeePlayer(A, False)));
    'getBlendFrames': EventResult := D3FloatValue(0);
    { movement types and flying (idAI) }
    'setMoveType':
      begin
        A.MoveType := Round(ArgF(0));
        A.Velocity := TVector3.Zero;
        A.MoveDirect := False;
      end;
    'getMoveType': EventResult := D3FloatValue(A.MoveType);
    'setFlySpeed': A.FlySpeed := ArgF(0);
    'setFlyOffset': A.FlyOffset := ArgF(0);
    'clearFlyOffset': A.FlyOffset := A.Model.Entity.FloatValue('fly_offset', 0);
    'moveToEnemyHeight':
      { flying: up or down to the enemy's eyes plus fly_offset, here }
      if (A.MoveType = MoveTypeFly) and A.HasEnemy then
        MoveTo(Vector3(CgeToD3(A.Model.Holder.Translation).X, CgeToD3(A.Model.Holder.Translation).Y,
          CgeToD3(FPlayerEye).Z + A.FlyOffset))
      else
        MoveDone;
    'waitMove':
      if A.Moving then
      begin
        A.WaitMove := True;
        A.WaitAction := '<move>';
        Thread.WaitFor(A.Handle);
      end;
    'slideTo': MoveTo(Args[0].V);
    'wander', 'moveToAttackPosition': MoveDone;
    'moveOutOfRange':
      begin
        { away from the entity until Range away }
        Other := HandleEntity(Args[0].E);
        if Args[0].E = PlayerHandle then
          Pos := CgeToD3(FPlayerEye - Vector3(0, PlayerEyeHeight, 0))
        else
        if Other <> nil then
          Pos := Other.Origin
        else
          Pos := CgeToD3(A.Model.Holder.Translation);
        Pos := CgeToD3(A.Model.Holder.Translation) - Pos;
        Pos.Z := 0;
        D := Pos.Length;
        if (D < ArgF(1)) and (D > 0.01) then
          MoveTo(CgeToD3(A.Model.Holder.Translation) + Pos / D * (ArgF(1) - D))
        else
          MoveDone;
      end;
    'getEnemyPos': EventResult := D3VectorValue(CgeToD3(FPlayerEye - Vector3(0, PlayerEyeHeight, 0)));
    'getEnemyEyePos': EventResult := D3VectorValue(CgeToD3(FPlayerEye));
    'enemyPositionValid': EventResult := D3FloatValue(Ord(A.HasEnemy));
    'findEnemyAI', 'closestReachableEnemyOfEntity':
      if not NoTarget and not PlayerDead and ActorCanSeePlayer(A, False) then
        EventResult := D3EntityValue(PlayerHandle)
      else
        EventResult := D3EntityValue(0);
    'testMoveToPosition', 'canReachPosition', 'canReachEntity': EventResult := D3FloatValue(1);
    'testAnimAttack': EventResult := D3FloatValue(Ord(A.HasEnemy and ActorCanSeePlayer(A, False)));
    'pushPointIntoAAS': EventResult := D3VectorValue(Args[0].V);
    'getReachableEntityPosition':
      if Args[0].E = PlayerHandle then
        EventResult := D3VectorValue(CgeToD3(FPlayerEye - Vector3(0, PlayerEyeHeight, 0)))
      else
      if HandleEntity(Args[0].E) <> nil then
        EventResult := D3VectorValue(HandleEntity(Args[0].E).Origin);
    'travelDistanceToPoint':
      EventResult := D3FloatValue((Args[0].V - CgeToD3(A.Model.Holder.Translation)).Length);
    'travelDistanceToEntity', 'travelDistanceBetweenEntities', 'travelDistanceBetweenPoints':
      begin
        { straight distances (no AAS travel times) }
        if N = 'travelDistanceBetweenPoints' then
          D := (Args[1].V - Args[0].V).Length
        else
        begin
          if N = 'travelDistanceToEntity' then
            Pos := CgeToD3(A.Model.Holder.Translation)
          else
          if Args[0].E = PlayerHandle then
            Pos := CgeToD3(FPlayerEye - Vector3(0, PlayerEyeHeight, 0))
          else
          if HandleEntity(Args[0].E) <> nil then
            Pos := HandleEntity(Args[0].E).Origin
          else
            Pos := TVector3.Zero;
          if N = 'travelDistanceToEntity' then
            I := 0
          else
            I := 1;
          if Args[I].E = PlayerHandle then
            D := (CgeToD3(FPlayerEye - Vector3(0, PlayerEyeHeight, 0)) - Pos).Length
          else
          if HandleEntity(Args[I].E) <> nil then
            D := (HandleEntity(Args[I].E).Origin - Pos).Length
          else
            D := 0;
        end;
        EventResult := D3FloatValue(D);
      end;
    'getTurnRate': EventResult := D3FloatValue(A.TurnRate);
    'setTurnRate': A.TurnRate := ArgF(0);
    'setHealth':
      if A.Monster <> nil then
        A.Monster.Health := Round(ArgF(0));
    'kill': KillActor(A);
    'findActorsInBounds':
      begin
        { the player, when its feet are in the box (Doom 3 coordinates) }
        Pos := CgeToD3(FPlayerEye - Vector3(0, PlayerEyeHeight, 0));
        if not PlayerDead and (Pos.X >= Args[0].V.X) and (Pos.Y >= Args[0].V.Y) and (Pos.Z >= Args[0].V.Z) and
           (Pos.X <= Args[1].V.X) and (Pos.Y <= Args[1].V.Y) and (Pos.Z <= Args[1].V.Z) then
          EventResult := D3EntityValue(PlayerHandle)
        else
          EventResult := D3EntityValue(0);
      end;
    'getRandomTarget':
      begin
        { one of its targets of that class, at random }
        Targets := nil;
        for I := 0 to A.Model.Entity.Pairs.Count - 1 do
          if SameText(Copy(A.Model.Entity.Pairs.Names[I], 1, 6), 'target') then
          begin
            Other := FindEntity(A.Model.Entity.Pairs.ValueFromIndex[I]);
            if (Other <> nil) and SameText(Other.ClassName_, D3ValueToString(Args[0])) then
              Targets := Concat(Targets, [EntityHandle(Other)]);
          end;
        if Length(Targets) > 0 then
          EventResult := D3EntityValue(Targets[Random(Length(Targets))])
        else
          EventResult := D3EntityValue(0);
      end;
    { no physics objects or ragdolls: nothing to throw }
    'throwMoveable':
      { idAI::Event_ThrowMoveable: lets go of a moveable bound to it }
      for Mov in FMoveables do
        if (FindBinding(Mov.Brush.Scene) <> nil) and
           (FindBinding(Mov.Brush.Scene).Parent = A.Model.Holder) then
        begin
          Unbind(Mov.Brush.Scene);
          Break;
        end;
    'throwAF', 'becomeRagdoll': EventResult := D3EntityValue(0);
    'chooseObjectToThrow':
      begin
        { idAI_Vagary::Event_ChooseObjectToThrow( mins, maxs, speed,
          minDist, offset ): a moveable in the box around it, far enough
          from the enemy's eyes, not behind it, that it can throw there }
        EventResult := D3EntityValue(0);
        if A.HasEnemy and (FMoveables.Count > 0) then
        begin
          Pos := CgeToD3(A.Model.Holder.Translation);
          Eye := CgeToD3(FPlayerEye);
          J := Random(FMoveables.Count);
          for I := 0 to FMoveables.Count - 1 do
          begin
            Mov := FMoveables[(J + I) mod FMoveables.Count];
            if Mov.Brush.Hidden then
              Continue;
            Other3 := Mov.Origin;
            if (Other3.X < Pos.X + Args[0].V.X) or (Other3.Y < Pos.Y + Args[0].V.Y) or
               (Other3.Z < Pos.Z + Args[0].V.Z) or (Other3.X > Pos.X + Args[1].V.X) or
               (Other3.Y > Pos.Y + Args[1].V.Y) or (Other3.Z > Pos.Z + Args[1].V.Z) then
              Continue;
            if (Other3 - Eye).Length < ArgF(3) then
              Continue;
            { behind it: the throw would go through it }
            if SegmentToPlayerDistance(D3ToCge(Other3), D3ToCge(Eye), A.Model.Holder.Translation,
                 A.Model.Holder.Translation + Vector3(0, 72, 0)) <
               (16 + Max(Mov.HalfSize.X, Mov.HalfSize.Y)) then
              Continue;
            if BallisticDir(Other3 + Vector3(0, 0, ArgF(4)), Eye, ArgF(2), 1066, Dir) then
            begin
              EventResult := D3EntityValue(EntityHandle(Mov.Brush.Entity));
              Break;
            end;
          end;
        end;
      end;
    'throwObjectAtEnemy':
      begin
        { idAI_Vagary::Event_ThrowObjectAtEnemy( entity, speed ) }
        Mov := MoveableOf(HandleEntity(Args[0].E));
        if Mov <> nil then
        begin
          if A.HasEnemy then
            BallisticDir(Mov.Origin, CgeToD3(FPlayerEye), ArgF(1), 1066, Dir)
          else
            Dir := D3Forward(0, A.Yaw);
          ThrowMoveable(Mov, Dir * ArgF(1));
          WritelnLog('Doom3World', '%s throws %s', [A.Model.Entity.Name, Mov.Brush.Entity.Name]);
        end;
      end;
    'numSmokeEmitters': EventResult := D3FloatValue(0);
    'enableClip', 'disableClip', 'enableGravity', 'disableGravity', 'enableAFPush',
    'disableAFPush', 'allowHiddenMovement', 'triggerParticles', 'shrivel', 'burn', 'preBurn',
    'stopRagdoll':
      ;
    'getSize': EventResult := D3VectorValue(Vector3(32, 32, 72));
    else
      Result := False;
  end;
end;

procedure TD3Game.UpdateLook(const A: TD3Actor; const SecondsPassed: Single);
var
  Origin, Eye, Focus, Dir: TVector3;
  Target, Ease: TVector2;
  Other: TD3MapEntity;
  Other2: TD3Actor;
  HasFocus: Boolean;
  I: Integer;
begin
  if Length(A.LookJoints) = 0 then
    Exit;
  if (A.Monster <> nil) and (A.Monster.State = msDead) then
  begin
    A.Model.Instance.ClearJointMods;
    Exit;
  end;
  { where it looks: its focus while it lasts, else straight ahead }
  Origin := CgeToD3(A.Model.Holder.Translation);
  Eye := Origin + Vector3(0, 0, 64);
  { scripts renew short looks (lookAt( talkTo, 0.1 )) every frame: one
    lasts through the frame it ends in, also when frames are long }
  HasFocus := (A.FocusTarget <> 0) and (FTime < A.FocusUntil + SecondsPassed);
  if HasFocus then
  begin
    if A.FocusTarget = PlayerHandle then
      { a little under the player's eyes (eye_verticle_offset) }
      Focus := CgeToD3(FPlayerEye) - Vector3(0, 0, 5)
    else
    begin
      Other2 := nil;
      for I := 0 to FActors.Count - 1 do
        if FActors[I].Handle = A.FocusTarget then
          Other2 := FActors[I];
      if Other2 <> nil then
        Focus := CgeToD3(Other2.Model.Holder.Translation) + Vector3(0, 0, 64)
      else
      begin
        Other := HandleEntity(A.FocusTarget);
        if Other <> nil then
          Focus := Other.Origin
        else
          HasFocus := False;
      end;
    end;
  end;
  if HasFocus then
  begin
    { yaw from the origin, pitch from the eyes }
    Dir := Focus - Origin;
    Target.Y := RadToDeg(ArcTan2(Dir.Y, Dir.X)) - A.Yaw;
    Target.Y := Target.Y - 360 * Floor((Target.Y + 180) / 360);
    Dir := Focus - Eye;
    Target.X := -RadToDeg(ArcTan2(Dir.Z, Sqrt(Sqr(Dir.X) + Sqr(Dir.Y))));
    Target.X := EnsureRange(Target.X, A.LookMin.X, A.LookMax.X);
    Target.Y := EnsureRange(Target.Y, A.LookMin.Y, A.LookMax.Y);
  end else
    Target := TVector2.Zero;
  { head_focus_rate is per game frame (60 a second) }
  Ease := Vector2(1, 1) * (1 - Power(1 - EnsureRange(A.HeadFocusRate, 0, 1), SecondsPassed * 60));
  A.LookAngles := A.LookAngles + (Target - A.LookAngles) * Ease.X;
  if (Abs(A.LookAngles.X) < 0.05) and (Abs(A.LookAngles.Y) < 0.05) and not HasFocus then
  begin
    A.LookAngles := TVector2.Zero;
    A.Model.Instance.ClearJointMods;
    Exit;
  end;
  for I := 0 to High(A.LookJoints) do
    A.Model.Instance.SetJointMod(A.LookJoints[I].Joint, QuatFromAngles(
      A.LookAngles.X * A.LookJoints[I].Scale.X, A.LookAngles.Y * A.LookJoints[I].Scale.Y, 0));
end;

procedure TD3Game.UpdateActors(const SecondsPassed: Single);
var
  A: TD3Actor;
  Ch: Integer;
  C, Torso, Legs, Body: TD3ActorChannel;
  Pos, Dir, Waypoint, SteerDir: TVector3;
  Dist, Step, Speed, Delta, Turn, Arrive: Single;
  BodyKey: String;
begin
  for A in FActors do
  begin
    { state switches asked last frame }
    if A.HasIdeal then
    begin
      A.HasIdeal := False;
      A.StateName := A.IdealName;
      FScript.RestartThread(A.Main, A.IdealFunction, A.Handle);
    end;
    for Ch := Low(A.Channels) to High(A.Channels) do
    begin
      C := A.Channels[Ch];
      if C.HasPending then
      begin
        C.HasPending := False;
        C.StateName := C.PendingName;
        FScript.RestartThread(C.Thread, C.PendingFunction, A.Handle);
      end;
    end;

    if not A.Thinking then
    begin
      { stopThinking: its threads end; its anims play in place again }
      A.Model.Instance.LockOrigin := False;
      A.Main.State := tsDone;
      for Ch := Low(A.Channels) to High(A.Channels) do
        A.Channels[Ch].Thread.State := tsDone;
      Continue;
    end;

    { the body plays a torso action (playAnim, until done), else the legs'
      anim, else the torso's (idle) }
    Torso := A.Channels[1];
    Legs := A.Channels[2];
    if (Torso.AnimName <> '') and not Torso.AnimLoop and
       (FTime - Torso.AnimStart < Torso.AnimLength) then
      Body := Torso
    else
    if Legs.AnimName <> '' then
      Body := Legs
    else
      Body := Torso;
    BodyKey := Body.AnimName + ':' + FloatToStr(Body.AnimStart);
    if (Body.AnimName <> '') and (BodyKey <> A.BodyKey) then
    begin
      A.BodyKey := BodyKey;
      A.Model.Instance.PlayAnim(Body.AnimName, Body.AnimLoop);
    end;

    { AI_PAIN lasts the frame of the hit }
    if A.PainFrames > 0 then
      Dec(A.PainFrames)
    else
      A.SetFlag('AI_PAIN', 0);

    { chasing the player: the goal follows it, done within melee range }
    if A.ChaseEnemy then
    begin
      if not A.HasEnemy or NoTarget or PlayerDead then
      begin
        A.ChaseEnemy := False;
        A.Moving := False;
      end else
      begin
        A.Goal := CgeToD3(FPlayerEye - Vector3(0, PlayerEyeHeight, 0));
        A.Moving := True;
      end;
    end;

    { walking to the goal at the speed of the walk animation (its origin
      joint stays put: the entity moves instead); flying (idAI::FlyMove);
      static and dead ones stay }
    Pos := CgeToD3(A.Model.Holder.Translation);
    { actors standing still move by their animation (dodges, characters'
      path anims; idAI's AnimMove): the mesh's origin stays, the entity
      moves by its delta }
    A.Model.Instance.LockOrigin := True;
    if A.MoveType = MoveTypeFly then
      UpdateFlying(A, SecondsPassed)
    else
    if A.MoveType in [MoveTypeDead, MoveTypeStatic] then
    begin
      A.Moving := False;
      A.ChaseEnemy := False;
    end else
    if not A.Moving and not A.Model.Instance.LastOriginDelta.IsZero then
    begin
      Dir := A.Model.Instance.LastOriginDelta;
      Dir := Vector3(Dir.X * Cos(DegToRad(A.Yaw)) - Dir.Y * Sin(DegToRad(A.Yaw)),
        Dir.X * Sin(DegToRad(A.Yaw)) + Dir.Y * Cos(DegToRad(A.Yaw)), 0);
      A.Model.Holder.Translation := StepTowards(A.Model.Holder.Translation, D3ToCge(Dir),
        ActorRadius(A), ActorHeight(A));
    end else
    if A.Moving then
    begin
      Dir := Vector3(A.Goal.X - Pos.X, A.Goal.Y - Pos.Y, 0);
      Dist := Dir.Length;
      { around walls: towards the next point of the AAS route }
      Waypoint := RouteWaypoint(A.Route, Pos, A.Goal);
      SteerDir := Vector3(Waypoint.X - Pos.X, Waypoint.Y - Pos.Y, 0);
      if SteerDir.Length < 0.5 then
        SteerDir := Dir;
      Speed := A.Model.Instance.AnimSpeed;
      if Speed < 10 then
        Speed := 80;
      Step := Speed * SecondsPassed;
      if A.ChaseEnemy then
        Arrive := A.MeleeRange
      else
        Arrive := Max(Step, 4);
      if Dist <= Arrive then
      begin
        if not A.ChaseEnemy then
          Pos := Vector3(A.Goal.X, A.Goal.Y, Pos.Z);
        A.Moving := False;
        A.ChaseEnemy := False;
      end else
      begin
        A.IdealYaw := RadToDeg(ArcTan2(SteerDir.Y, SteerDir.X));
        SteerDir := SteerDir.Normalize;
        if A.Monster <> nil then
          { monsters collide with the world }
          Pos := CgeToD3(StepTowards(A.Model.Holder.Translation,
            D3ToCge(SteerDir * Step), A.Monster.Radius, A.Monster.Height))
        else
          Pos := Pos + SteerDir * Min(Step, Dist);
      end;
      A.Model.Holder.Translation := D3ToCge(Pos);
    end;

    { what it knows of its enemy }
    if A.HasEnemy then
    begin
      A.SetFlag('AI_ENEMY_VISIBLE', Ord(ActorCanSeePlayer(A, False)));
      A.SetFlag('AI_ENEMY_IN_FOV', Ord(ActorCanSeePlayer(A, True)));
      A.SetFlag('AI_ENEMY_DEAD', Ord(PlayerDead));
    end else
    begin
      A.SetFlag('AI_ENEMY_VISIBLE', 0);
      A.SetFlag('AI_ENEMY_IN_FOV', 0);
    end;

    { turning at turn_rate }
    Delta := A.IdealYaw - A.Yaw;
    Delta := Delta - 360 * Floor((Delta + 180) / 360);
    Turn := A.TurnRate * SecondsPassed;
    if Abs(Delta) <= Turn then
      A.Yaw := A.IdealYaw
    else
      A.Yaw := A.Yaw + Sign(Delta) * Turn;
    { each anim delta moves it once }
    A.Model.Instance.LastOriginDelta := TVector3.Zero;
    if A.MoveType = MoveTypeFly then
      SetD3Rotation(A.Model.Holder, AnglesMatrix(Vector3(A.FlyPitch, A.Yaw, A.FlyRoll)))
    else
      SetD3Rotation(A.Model.Holder, YawMatrix(A.Yaw));
    { waitMove ends with the move }
    if A.WaitMove and not A.Moving then
    begin
      A.WaitMove := False;
      if A.WaitAction = '<move>' then
        A.WaitAction := '';
    end;

    { the flags idAI keeps for the script }
    A.SetFlag('AI_FORWARD', Ord(A.Moving));
    A.SetFlag('AI_MOVE_DONE', Ord(not A.Moving));
    A.SetFlag('AI_ONGROUND', 1);
    A.SetFlag('AI_DEST_UNREACHABLE', 0);
    A.SetFlag('AI_TALK', Ord(A.TalkTarget <> 0));
    { a multiframe attack (attack_begin, chargeAttack) hurts on touch }
    if (A.Attack <> '') and ActorTestMelee(A) then
      ActorDirectDamage(A, A.Attack);
    UpdateLook(A, SecondsPassed);
  end;
end;

destructor TD3Projectile.Destroy;
begin
  FreeAndNil(Visual);
  inherited Destroy;
end;

procedure TD3Game.PlaySoundAt(const ShaderName: String; const Position: TVector3);
var
  Snd: TCastleSound;
  T: TCastleTransform;
  Source: TCastleSoundSource;
  Playing: TCastlePlayingSoundSource;
begin
  Snd := SoundFromShader(ShaderName);
  if Snd = nil then
    Exit;
  { a transform kept with the script sounds' ones (freed with the map) }
  T := TCastleTransform.Create(nil);
  T.Translation := Position;
  FMap.Add(T);
  FSoundTransforms.Add(T);
  Source := TCastleSoundSource.Create(T);
  T.AddBehavior(Source);
  Playing := TCastlePlayingSoundSource.Create(nil);
  Playing.Sound := Snd;
  Playing.FreeOnStop := True;
  Source.Play(Playing);
end;

function TD3Game.MuzzlePosition(const A: TD3Actor; const JointName: String): TVector3;
begin
  { from the joint (the gun, the hand), else the chest }
  if (JointName <> '') and A.Model.Instance.JointPosition(JointName, Result) then
    Result := A.Model.Instance.Scene.LocalToWorld(Result)
  else
    Result := A.Model.Holder.Translation + Vector3(0, 48, 0);
end;

function TD3Game.CreateMissile(const A: TD3Actor; const JointName: String): TD3Projectile;
begin
  { idAI::CreateProjectile keeps the one it holds }
  if A.Missile <> nil then
  begin
    A.Missile.HeldJoint := JointName;
    Exit(A.Missile);
  end;
  Result := SpawnProjectile(A.Model.Entity.Value('def_projectile'), A.Model.Entity.Name,
    MuzzlePosition(A, JointName), TVector3.Zero);
  if Result = nil then
    Exit;
  Result.HeldBy := A;
  Result.HeldJoint := JointName;
  A.Missile := Result;
end;

procedure TD3Game.LaunchProjectile(const P: TD3Projectile; const From, Dir: TVector3);
var
  D: TVector3;
begin
  P.HeldBy := nil;
  P.Position := From;
  P.Speed := P.LaunchSpeed;
  P.Velocity := Dir.Normalize * P.Speed;
  D := CgeToD3(Dir);
  P.Pitch := D3DirPitch(D);
  P.Yaw := D3DirYaw(D);
  if P.Visual <> nil then
    P.Visual.Translation := From;
  Inc(ProjectilesLaunched);
end;

function TD3Game.LaunchMissile(const A: TD3Actor; const JointName: String;
  const AtPlayer, HasTarget: Boolean; const TargetPos: TVector3;
  const ClampToCone: Boolean): TD3Projectile;
var
  E: TD3MapEntity;
  Def: TStringList;
  DefName: String;
  From, Target, Dir, Fwd, Right, Up, D: TVector3;
  Speed, Gravity, Accuracy, Cone, SpreadRad, Dist, H, V2, Root, Angle, Pitch, Yaw, T, Spin: Single;
  Count, I: Integer;
  Aim: Boolean;
begin
  Result := nil;
  E := A.Model.Entity;
  DefName := E.Value('def_projectile');
  Def := Decls.EntityDef(DefName);
  if Def = nil then
    Exit;
  From := MuzzlePosition(A, JointName);
  Aim := True;
  if AtPlayer and A.HasEnemy and not PlayerDead then
    Target := FPlayerEye - Vector3(0, 20, 0)
  else
  if HasTarget then
    Target := TargetPos
  else
    Aim := False;
  { idProjectile's speed is the length of its velocity }
  Speed := ParseVector3(Def.Values['velocity'], Vector3(500, 0, 0)).Length;
  if Speed <= 0 then
    Speed := 500;
  Gravity := StrToFloatDef(Def.Values['gravity'], 0, DefaultFormatSettings);
  if Aim then
  begin
    Dir := (Target - From).Normalize;
    if Gravity > 0 then
    begin
      { the lower arc that reaches the target, if there's one }
      Dist := Sqrt(Sqr(Target.X - From.X) + Sqr(Target.Z - From.Z));
      H := Target.Y - From.Y;
      V2 := Sqr(Speed);
      Root := Sqr(V2) - Gravity * (Gravity * Sqr(Dist) + 2 * H * V2);
      if (Root >= 0) and (Dist > 1) then
      begin
        Angle := ArcTan((V2 - Sqrt(Root)) / (Gravity * Dist));
        Dir := Vector3(Target.X - From.X, 0, Target.Z - From.Z).Normalize * Cos(Angle) +
          Vector3(0, Sin(Angle), 0);
      end;
    end;
    D := CgeToD3(Dir);
    Pitch := D3DirPitch(D);
    Yaw := D3DirYaw(D);
  end else
  begin
    Pitch := 0;
    Yaw := A.Yaw;
  end;
  { idAI::LaunchProjectile: the aim wobbles (sine based, so tracers look
    less random), the yaw kept within attack_cone of its facing }
  Accuracy := E.FloatValue('attack_accuracy', 7);
  T := FTime + A.Handle * 0.497;
  Pitch := Pitch + Sin(T * 5.1) * Accuracy;
  Yaw := Yaw + Sin(T * 6.7) * Accuracy;
  if ClampToCone then
  begin
    Cone := E.FloatValue('attack_cone', 70);
    Yaw := A.Yaw + EnsureRange(Normalize180(Yaw - A.Yaw), -Cone, Cone);
  end;
  Fwd := D3Forward(Pitch, Yaw);
  Right := D3Forward(0, Yaw - 90);
  Up := TVector3.CrossProduct(Right, Fwd).Normalize;
  SpreadRad := DegToRad(E.FloatValue('projectile_spread', 0));
  Count := Max(1, E.IntValue('num_projectiles', 1));
  for I := 1 to Count do
  begin
    { each one spread within projectile_spread degrees }
    Angle := Sin(SpreadRad * Random);
    Spin := 2 * Pi * Random;
    D := (Fwd + Up * (Angle * Sin(Spin)) - Right * (Angle * Cos(Spin))).Normalize;
    { the one it holds goes first }
    if A.Missile <> nil then
    begin
      Result := A.Missile;
      A.Missile := nil;
    end else
      Result := SpawnProjectile(DefName, E.Name, From, TVector3.Zero);
    if Result = nil then
      Exit;
    Result.SeeksPlayer := A.HasEnemy;
    LaunchProjectile(Result, From, D3ToCge(D));
  end;
end;

function TD3Game.LaunchMissileFrom(const A: TD3Actor; const Origin, Angles: TVector3): TD3Projectile;
begin
  if A.Missile <> nil then
  begin
    Result := A.Missile;
    A.Missile := nil;
  end else
    Result := SpawnProjectile(A.Model.Entity.Value('def_projectile'), A.Model.Entity.Name,
      D3ToCge(Origin), TVector3.Zero);
  if Result = nil then
    Exit;
  Result.SeeksPlayer := A.HasEnemy;
  LaunchProjectile(Result, D3ToCge(Origin), D3ToCge(D3Forward(Angles.X, Angles.Y)));
end;

function TD3Game.ActorTestMelee(const A: TD3Actor): Boolean;
var
  Pos, Feet: TVector3;
  Height: Single;
begin
  Result := False;
  if not A.HasEnemy or PlayerDead or (A.MeleeRange <= 0) then
    Exit;
  { its box grown by melee_range touches the player's box }
  Height := 72;
  if A.Monster <> nil then
    Height := A.Monster.Height;
  Pos := CgeToD3(A.Model.Holder.Translation);
  Feet := CgeToD3(FPlayerEye - Vector3(0, PlayerEyeHeight, 0));
  if (Abs(Feet.X - Pos.X) > A.MeleeRange + PlayerRadius) or
     (Abs(Feet.Y - Pos.Y) > A.MeleeRange + PlayerRadius) or
     (Feet.Z > Pos.Z + Height + 4) or (Feet.Z + 74 < Pos.Z - 4) then
    Exit;
  Result := ActorCanSeePlayer(A, False);
end;

procedure TD3Game.ActorDirectDamage(const A: TD3Actor; const DamageDefName: String);
var
  Def: TStringList;
  Damage: Integer;
begin
  { idAI::DirectDamage ends a multiframe attack }
  A.Attack := '';
  Def := Decls.EntityDef(DamageDefName);
  if (Def = nil) or PlayerDead then
    Exit;
  Damage := StrToIntDef(Def.Values['damage'], 10);
  if Def.Values['snd_hit'] <> '' then
    PlaySoundAt(Def.Values['snd_hit'], FPlayerEye);
  DamagePlayer(Damage, DamageDefName, FPlayerEye - A.Model.Holder.Translation);
  WritelnLog('Doom3World', '%s hits the player (%s, %d)', [A.Model.Entity.Name, DamageDefName, Damage]);
end;

function TD3Game.ActorAttackMelee(const A: TD3Actor; const DamageDefName: String): Boolean;
var
  ToPlayer: TVector3;
begin
  { idAI::AttackMelee: hits the player in reach (a bit more than the
    melee range, the swing reaches) }
  ToPlayer := CgeToD3(FPlayerEye) - CgeToD3(A.Model.Holder.Translation);
  Result := A.HasEnemy and not PlayerDead and
    (Sqrt(Sqr(ToPlayer.X) + Sqr(ToPlayer.Y)) <= (A.MeleeRange + PlayerRadius) * 1.5);
  if Result then
    ActorDirectDamage(A, DamageDefName);
end;

function TD3Game.SpawnProjectile(const DefName, Owner: String; const From, Velocity: TVector3): TD3Projectile;
var
  Def, DamageDef: TStringList;
  Ball: TCastleSphere;
  D, Rnd: TVector3;

  function DefBool(const Key: String): Boolean;
  begin
    { idProjectile reads them as bools: a missing key is false }
    Result := StrToIntDef(Def.Values[Key], 0) <> 0;
  end;

  function DefFloat(const Key: String; const Default: Single): Single;
  begin
    Result := StrToFloatDef(Def.Values[Key], Default, DefaultFormatSettings);
  end;

begin
  Result := nil;
  Def := Decls.EntityDef(DefName);
  if Def = nil then
    Exit;
  Result := TD3Projectile.Create;
  Result.Position := From;
  Result.Velocity := Velocity;
  Result.LaunchSpeed := ParseVector3(Def.Values['velocity'], Vector3(500, 0, 0)).Length;
  Result.Speed := Velocity.Length;
  D := CgeToD3(Velocity);
  Result.Pitch := D3DirPitch(D);
  Result.Yaw := D3DirYaw(D);
  Result.Gravity := DefFloat('gravity', 0);
  Result.Fuse := DefFloat('fuse', 4);
  Result.DetonateOnFuse := DefBool('detonate_on_fuse');
  Result.DetonateOnWorld := DefBool('detonate_on_world');
  Result.DetonateOnActor := DefBool('detonate_on_actor');
  Result.Bounce := DefFloat('bounce', 0);
  { idGuidedProjectile::Launch }
  Result.Guided := SameText(Def.Values['spawnclass'], 'idGuidedProjectile');
  Result.TurnMax := DefFloat('turn_max', 180);
  Result.ClampDist := Max(1, DefFloat('clamp_dist', 256));
  Rnd := ParseVector3(Def.Values['random'], Vector3(15, 15, 0));
  Result.RandomScale := Vector2(Rnd.X, Rnd.Y);
  Result.BurstMode := DefBool('burstMode');
  Result.BurstDist := DefFloat('burstDist', 64);
  Result.BurstVelocity := DefFloat('burstVelocity', 1.25);
  Result.Radius := Max(2, ParseVector3(Def.Values['maxs'], Vector3(1, 1, 1)).X);
  Result.Damage := 10;
  Result.DamageDefName := Def.Values['def_damage'];
  Result.SplashDefName := Def.Values['def_splash_damage'];
  DamageDef := Decls.EntityDef(Def.Values['def_damage']);
  if DamageDef <> nil then
    Result.Damage := StrToIntDef(DamageDef.Values['damage'], Result.Damage);
  DamageDef := Decls.EntityDef(Def.Values['def_splash_damage']);
  if DamageDef <> nil then
  begin
    Result.SplashDamage := StrToIntDef(DamageDef.Values['damage'], 0);
    Result.SplashRadius := StrToFloatDef(DamageDef.Values['radius'], 0, DefaultFormatSettings);
  end;
  Result.Owner := Owner;
  Result.ExplodeSound := Def.Values['snd_explode'];
  if DefFloat('light_radius', 0) > 0 then
  begin
    { a glowing ball in the light's color (the particles are item 7) }
    Ball := TCastleSphere.Create(nil);
    Ball.Radius := Result.Radius * 1.5;
    Ball.Material := pmUnlit;
    Ball.Color := Vector4(ParseVector3(Def.Values['light_color'], Vector3(1, 0.7, 0.2)), 1);
    Ball.Collides := False;
    Ball.Pickable := False;
    Ball.CastShadows := False;
    Ball.Translation := From;
    FMap.Add(Ball);
    Result.Visual := Ball;
  end;
  FProjectiles.Add(Result);
end;

procedure TD3Game.SplashDamage(const P: TD3Projectile);
var
  Back: TVector3;
begin
  Back := P.Position;
  if not P.Velocity.IsZero then
    Back := Back - P.Velocity.Normalize * 2;
  RadiusDamage(P.Position, Back, P.SplashDamage, P.SplashRadius, P.Owner, P.SplashDefName);
  if P.FromPlayer and (P.SplashDamage > 0) and (P.SplashRadius > 0) then
    MonsterSplash(P.Position, P.SplashDamage, P.SplashRadius);
end;

procedure TD3Game.MonsterSplash(const Position: TVector3; const Damage: Integer; const Radius: Single);
var
  Mon: TD3Monster;
  Dist: Single;
  Amount: Integer;
begin
  { idGameLocal::RadiusDamage on monsters: by the distance to their box,
    seen from the explosion }
  for Mon in FMonsters do
  begin
    if (Mon.State = msDead) or not Mon.Model.Holder.Exists then
      Continue;
    Dist := Max(0, (Mon.Center - Position).Length - Mon.Radius);
    if (Dist >= Radius) or not CanSee(Position, Mon.Center) then
      Continue;
    Amount := Round(Damage * (1 - Dist / Radius));
    if Amount > 0 then
    begin
      WritelnLog('Doom3World', 'Splash of the player hits %s (%d)', [Mon.Model.Entity.Name, Amount]);
      DamageMonster(Mon, Amount);
    end;
  end;
end;

procedure TD3Game.RadiusDamage(const Position, Back: TVector3; const Damage: Integer;
  const Radius: Single; const Owner: String; const SplashDefName: String);
const
  { the player's box (idPlayer's bounds: 32 wide, 74 high on its feet) }
  PlayerHalfWidth = 16;
  PlayerHeight = 74;
var
  Feet, Closest, Center, ToPlayer: TVector3;
  Dist, HitDist: Single;
  Amount: Integer;
begin
  if (Damage <= 0) or (Radius <= 0) or PlayerDead then
    Exit;
  { the distance to the player's box (zero inside it) }
  Feet := FPlayerEye - Vector3(0, PlayerEyeHeight, 0);
  Closest := Vector3(
    EnsureRange(Position.X, Feet.X - PlayerHalfWidth, Feet.X + PlayerHalfWidth),
    EnsureRange(Position.Y, Feet.Y, Feet.Y + PlayerHeight),
    EnsureRange(Position.Z, Feet.Z - PlayerHalfWidth, Feet.Z + PlayerHalfWidth));
  Dist := (Closest - Position).Length;
  if Dist >= Radius then
    Exit;
  { idEntity::CanDamage: nothing solid in between (from just off the
    surface it hit, to the player's center) }
  Center := Feet + Vector3(0, PlayerHeight / 2, 0);
  ToPlayer := Center - Back;
  if (ToPlayer.Length > 1) and
    (FMap.World.WorldRayCast(Back, ToPlayer.Normalize, HitDist) <> nil) and
    (HitDist < ToPlayer.Length - PlayerHalfWidth) then
    Exit;
  Amount := Round(Damage * (1 - Dist / Radius));
  if Amount <= 0 then
    Exit;
  DamagePlayer(Amount, SplashDefName, Center - Position);
  WritelnLog('Doom3World', 'Splash of %s hits the player (%d)', [Owner, Amount]);
end;

procedure TD3Game.UpdateProjectiles(const SecondsPassed: Single);
var
  I: Integer;
  P: TD3Projectile;
  NewPos, Step, Feet, Normal, Pos, Seek, Nose, Dir, Vel: TVector3;
  Len, HitDist, Dist, Frac, DPitch, DYaw, MaxTurn: Single;
  Detonate, HitPlayer, Bounced: Boolean;
  HitMonster: TD3Monster;

  procedure Remove;
  begin
    if (P.HeldBy <> nil) and (P.HeldBy.Missile = P) then
      P.HeldBy.Missile := nil;
    FProjectiles.Delete(I);
  end;

  { the world along the step: distance and surface normal (facing the
    projectile) }
  function WorldHit(const From, Dir: TVector3; const MaxDist: Single;
    out Distance: Single; out N: TVector3): Boolean;
  var
    R: TRayCollision;
    Node: TRayCollisionNode;
  begin
    Result := False;
    N := -Dir;
    R := FMap.World.WorldRay(From, Dir);
    if R = nil then
      Exit;
    try
      Distance := R.Distance;
      Result := Distance <= MaxDist;
      if Result and R.Info(Node) and (Node.Triangle <> nil) and (Node.Item <> nil) then
      begin
        N := Node.Item.LocalToWorldDirection(Node.Triangle^.SceneSpace.Normal);
        if N.IsZero then
          N := -Dir
        else
        begin
          N := N.Normalize;
          if TVector3.DotProduct(N, Dir) > 0 then
            N := -N;
        end;
      end;
    finally
      R.Free;
    end;
  end;

begin
  Feet := FPlayerEye - Vector3(0, PlayerEyeHeight, 0);
  for I := FProjectiles.Count - 1 downto 0 do
  begin
    P := FProjectiles[I];
    { held in a monster's hand (create_missile) until launched }
    if P.HeldBy <> nil then
    begin
      if not P.HeldBy.Thinking or not P.HeldBy.Model.Holder.Exists or
         ((P.HeldBy.Monster <> nil) and (P.HeldBy.Monster.State = msDead)) then
        Remove
      else
      begin
        P.Position := MuzzlePosition(P.HeldBy, P.HeldJoint);
        if P.Visual <> nil then
          P.Visual.Translation := P.Position;
      end;
      Continue;
    end;
    P.Fuse := P.Fuse - SecondsPassed;
    if P.Fuse <= 0 then
    begin
      if P.DetonateOnFuse then
      begin
        if P.ExplodeSound <> '' then
          PlaySoundAt(P.ExplodeSound, P.Position);
        SplashDamage(P);
      end;
      Remove;
      Continue;
    end;
    { idGuidedProjectile::Think: turn towards the player's eyes }
    if P.Guided and not P.UnGuided and (P.Speed > 0) then
    begin
      Pos := CgeToD3(P.Position);
      if P.SeeksPlayer and not PlayerDead then
        Seek := CgeToD3(FPlayerEye) - Vector3(0, 0, 12)
      else
        Seek := Pos + CgeToD3(P.Velocity) * 2;
      if FTime >= P.RandomTime then
      begin
        P.RandomAngles := Vector2(P.RandomScale.X * (Random * 2 - 1), P.RandomScale.Y * (Random * 2 - 1));
        P.RandomTime := FTime + 0.2;
      end;
      Nose := Pos + D3Forward(P.Pitch, P.Yaw) * 10;
      Dir := Seek - Nose;
      Dist := Dir.Length;
      if Dist > 0.01 then
      begin
        { more accurate as it gets closer }
        Frac := Min(1, Dist / P.ClampDist);
        DPitch := Normalize180(D3DirPitch(Dir) - P.Pitch + P.RandomAngles.X * Frac);
        DYaw := Normalize180(D3DirYaw(Dir) - P.Yaw + P.RandomAngles.Y * Frac);
        { turn_max is per second (idGuidedProjectile: per 1/60 s tick) }
        MaxTurn := P.TurnMax * SecondsPassed;
        P.Pitch := P.Pitch + EnsureRange(DPitch, -MaxTurn, MaxTurn);
        P.Yaw := P.Yaw + EnsureRange(DYaw, -MaxTurn, MaxTurn);
        Vel := D3Forward(P.Pitch, P.Yaw) * P.Speed;
        if P.BurstMode and (Dist < P.BurstDist) then
        begin
          P.UnGuided := True;
          Vel := Vel * P.BurstVelocity;
        end;
        P.Velocity := D3ToCge(Vel);
      end;
    end;
    if not P.Resting then
      P.Velocity.Y := P.Velocity.Y - P.Gravity * SecondsPassed;
    Step := P.Velocity * SecondsPassed;
    NewPos := P.Position + Step;
    Len := Step.Length;
    Detonate := False;
    HitPlayer := False;
    Bounced := False;
    { a monster (the player's projectiles) }
    if P.FromPlayer and (Len > 0) then
    begin
      HitMonster := RayMonster(P.Position, Step, Len + P.Radius, Dist);
      { not through walls }
      if (HitMonster <> nil) and WorldHit(P.Position, Step / Len, Min(Dist, Len), HitDist, Normal) then
        HitMonster := nil;
      if HitMonster <> nil then
      begin
        WritelnLog('Doom3World', 'Projectile of the player hits %s (%d)', [HitMonster.Model.Entity.Name, P.Damage]);
        DamageMonster(HitMonster, P.Damage);
        NewPos := P.Position + Step * (Min(Dist, Len) / Len);
        Detonate := True;
        HitPlayer := True;
      end;
    end;
    { the player }
    if not P.FromPlayer and not PlayerDead and (Len > 0) and
       (SegmentToPlayerDistance(P.Position, NewPos, Feet, FPlayerEye) <= P.Radius + PlayerRadius) then
    begin
      if P.DetonateOnActor then
      begin
        DamagePlayer(P.Damage, P.DamageDefName, P.Velocity);
        WritelnLog('Doom3World', 'Projectile of %s hits the player (%d)', [P.Owner, P.Damage]);
        Detonate := True;
        HitPlayer := True;
      end else
      begin
        { bounces off (grenades): away from the player's axis }
        Normal := P.Position - Vector3(FPlayerEye.X, EnsureRange(P.Position.Y, Feet.Y, FPlayerEye.Y), FPlayerEye.Z);
        if Normal.IsZero then
          Normal := -Step;
        Normal := Normal.Normalize;
        if TVector3.DotProduct(P.Velocity, Normal) < 0 then
          P.Velocity := (P.Velocity - Normal * (2 * TVector3.DotProduct(P.Velocity, Normal))) * P.Bounce;
        NewPos := P.Position;
        Bounced := True;
      end;
    end;
    { the world }
    if not Detonate and not Bounced and (Len > 0) and WorldHit(P.Position, Step / Len, Len, HitDist, Normal) then
    begin
      NewPos := P.Position + Step * (HitDist / Len);
      if P.DetonateOnWorld then
        Detonate := True
      else
      begin
        { idPhysics_RigidBody bounce: reflected, keeping Bounce of the speed }
        P.Velocity := (P.Velocity - Normal * (2 * TVector3.DotProduct(P.Velocity, Normal))) * P.Bounce;
        NewPos := NewPos + Normal * 0.5;
        { at rest on a floor: no more falling through it }
        P.Resting := (P.Velocity.Length < 20) and (Normal.Y > 0.7);
        if P.Resting then
          P.Velocity := TVector3.Zero;
      end;
    end;
    P.Position := NewPos;
    if P.Visual <> nil then
      P.Visual.Translation := NewPos;
    if Detonate then
    begin
      if P.ExplodeSound <> '' then
        PlaySoundAt(P.ExplodeSound, P.Position);
      { RadiusDamage ignores the one hit directly }
      if not HitPlayer then
        SplashDamage(P);
      Remove;
    end;
  end;
end;

function TD3Game.ActorCanSeePlayer(const A: TD3Actor; const UseFov: Boolean): Boolean;
var
  Eye, ToPlayer: TVector3;
  Angle: Single;
begin
  Result := False;
  if NoTarget or PlayerDead or not A.Model.Holder.Exists then
    Exit;
  Eye := A.Model.Holder.Translation + Vector3(0, 64, 0);
  ToPlayer := FPlayerEye - Eye;
  if ToPlayer.Length > MonsterSightRange then
    Exit;
  if UseFov then
  begin
    { in front of it (a 180 degree field of view, idAI's default fov) }
    Angle := RadToDeg(ArcTan2(-ToPlayer.Z, ToPlayer.X)) - A.Yaw;
    Angle := Angle - 360 * Floor((Angle + 180) / 360);
    if Abs(Angle) > 90 then
      Exit;
  end;
  Result := CanSee(Eye, FPlayerEye);
end;

procedure TD3Game.ActorDamaged(const A: TD3Actor; const Killed: Boolean);
begin
  if not A.Thinking then
    Exit;
  { the attacker becomes its enemy }
  A.HasEnemy := not NoTarget;
  A.SetFlag('AI_PAIN', 1);
  A.PainFrames := 1;
  if Killed then
  begin
    { idAI::Killed: AI_DEAD, then the state_Killed state }
    A.SetFlag('AI_DEAD', 1);
    A.Moving := False;
    A.ChaseEnemy := False;
    A.MoveDirect := False;
    { idAI::Killed: MOVETYPE_DEAD; one that flew falls }
    if (A.MoveType = MoveTypeFly) and (A.Monster <> nil) then
    begin
      A.Monster.Falling := True;
      A.Monster.FallSpeed := 0;
    end;
    A.MoveType := MoveTypeDead;
    A.Velocity := TVector3.Zero;
    A.IdealFunction := A.Obj.Typ.FindMethodToRun('state_Killed');
    A.IdealName := 'state_Killed';
    A.HasIdeal := True;
  end;
end;

procedure TD3Game.ActorFrameCommand(const Sender: TD3Md5Instance; const Command: String);
var
  A, Found: TD3Actor;
  Cmd, Arg, Shader: String;
  Target: TD3MapEntity;
  F: TD3ScriptFunction;
begin
  Found := nil;
  for A in FActors do
    if (A.Model.Instance = Sender) or (A.Model.HeadInstance = Sender) then
      Found := A;
  if (Found = nil) or not Found.Thinking then
    Exit;
  A := Found;
  Cmd := LowerCase(Copy(Command, 1, Pos(' ', Command + ' ') - 1));
  Arg := Trim(Copy(Command, Length(Cmd) + 2, MaxInt));
  if Copy(Cmd, 1, 5) = 'sound' then
  begin
    { sound, sound_voice, sound_body...: a snd_ key of the entity, or a
      sound shader }
    Shader := A.Model.Entity.Value(Arg);
    if Shader = '' then
      Shader := Arg;
    StartScriptSound(A.Handle, Shader, 0);
  end else
  if Cmd = 'create_missile' then
    { a projectile in its hand until launch_missile (hell knights) }
    CreateMissile(A, Arg)
  else
  if Cmd = 'launch_missile' then
    { idAI::Event_AttackMissile: at the enemy, within the attack cone }
    LaunchMissile(A, Arg, True, False, TVector3.Zero, True)
  else
  if Cmd = 'fire_missile_at_target' then
  begin
    { <joint> <entity>: at that entity, not clamped to the attack cone }
    Target := FindEntity(Trim(Copy(Arg, Pos(' ', Arg + ' ') + 1, MaxInt)));
    Arg := Copy(Arg, 1, Pos(' ', Arg + ' ') - 1);
    if Target <> nil then
      LaunchMissile(A, Arg, False, True, D3ToCge(Target.Origin), False)
    else
      LaunchMissile(A, Arg, False, False, TVector3.Zero, False);
  end else
  if Cmd = 'attack_begin' then
    { a multiframe melee attack: touching the player hurts it once }
    A.Attack := Arg
  else
  if Cmd = 'attack_end' then
    A.Attack := ''
  else
  if Cmd = 'direct_damage' then
  begin
    { the enemy, when in melee reach }
    if ActorTestMelee(A) then
      ActorDirectDamage(A, Arg);
  end else
  if Cmd = 'call' then
  begin
    { a method of its script object, in a thread of its own }
    F := A.Obj.Typ.FindMethodToRun(Arg);
    if F <> nil then
      FScript.StartThread(F, A.Handle);
  end else
  if Cmd = 'trigger' then
  begin
    if FindEntity(Arg) <> nil then
      Activate(FindEntity(Arg));
  end else
  if Cmd = 'melee' then
    ActorAttackMelee(A, Arg);
end;

procedure TD3Game.SpawnAnimated(const ME: TD3ModelEntity);
var
  A: TD3Animated;
  E: TD3MapEntity;
  Wait: Single;
begin
  E := ME.Entity;
  A := TD3Animated.Create;
  A.Model := ME;
  A.NumAnims := E.IntValue('num_anims', 0);
  A.DoneTime := -1;
  A.ActivateTime := -1;
  { idAnimated::Spawn: "start_anim" loops, else the first frame of the anim }
  if E.Value('start_anim') <> '' then
    ME.Instance.PlayAnim(E.Value('start_anim'), True)
  else
  if A.NumAnims > 0 then
    ME.Instance.SetFrame(E.Value('anim1'), 1)
  else
  if E.Value('anim') <> '' then
    ME.Instance.SetFrame(E.Value('anim'), 1);
  Wait := E.FloatValue('wait', -1);
  if Wait >= 0 then
    A.ActivateTime := Wait;
  FAnimated.Add(A);
end;

function TD3Game.FindAnimated(const E: TD3MapEntity): TD3Animated;
begin
  for Result in FAnimated do
    if Result.Model.Entity = E then
      Exit;
  Result := nil;
end;

procedure TD3Game.PlayAnimatedAnim(const A: TD3Animated; const AnimName: String);
var
  Cycle: Integer;
begin
  { "cycle": plays (-1: forever) }
  Cycle := A.Model.Entity.IntValue('cycle', 1);
  if (A.NumAnims > 0) and (A.AnimIndex >= A.NumAnims) and
     A.Model.Entity.BoolValue('loop_last_anim') then
    Cycle := -1;
  if not A.Model.Instance.PlayAnim(AnimName, Cycle <> 1) then
  begin
    A.DoneTime := FTime;
    Exit;
  end;
  if Cycle < 0 then
    A.DoneTime := -1
  else
    A.DoneTime := FTime + A.Model.Instance.AnimLength * Max(1, Cycle);
  WritelnLog('Doom3World', 'Animated %s plays "%s"', [A.Model.Entity.Name, AnimName]);
end;

procedure TD3Game.PlayNextAnim(const A: TD3Animated);
var
  E: TD3MapEntity;
begin
  E := A.Model.Entity;
  if A.AnimIndex >= A.NumAnims then
  begin
    { the sequence is over: hide (and remove), or start again }
    A.Model.Hidden := True;
    A.Model.Holder.Exists := False;
    A.AnimIndex := 0;
    A.DoneTime := -1;
    Exit;
  end;
  A.Model.Hidden := False;
  A.Model.Holder.Exists := True;
  Inc(A.AnimIndex);
  PlayAnimatedAnim(A, E.Value('anim' + IntToStr(A.AnimIndex)));
end;

procedure TD3Game.ActivateAnimated(const A: TD3Animated);
begin
  { idAnimated::Event_Activate / Event_Start }
  if A.NumAnims > 0 then
  begin
    PlayNextAnim(A);
    Exit;
  end;
  if A.Activated then
    Exit;
  A.Activated := True;
  A.Model.Hidden := False;
  A.Model.Holder.Exists := True;
  PlayAnimatedAnim(A, A.Model.Entity.Value('anim'));
end;

procedure TD3Game.AnimatedDone(const A: TD3Animated);
var
  E: TD3MapEntity;
  Index: Integer;
begin
  { idAnimated::Event_AnimDone }
  E := A.Model.Entity;
  A.DoneTime := -1;
  Index := Max(1, A.AnimIndex);
  if (Index >= A.NumAnims) and E.BoolValue('remove') then
    RemoveEntity(E)
  else
  if E.BoolValue('auto_advance') then
    PlayNextAnim(A)
  else
    A.Activated := False;
  ActivateTargets(E);
end;

procedure TD3Game.UpdateAnimated;
var
  A: TD3Animated;
begin
  for A in FAnimated do
  begin
    if (A.ActivateTime >= 0) and (FTime >= A.ActivateTime) then
    begin
      A.ActivateTime := -1;
      ActivateAnimated(A);
    end;
    if (A.DoneTime >= 0) and (FTime >= A.DoneTime) then
      AnimatedDone(A);
  end;
end;

procedure TD3Game.StartCamera(const E: TD3MapEntity);
var
  Path: String;
  Anim: TD3CameraAnim;
begin
  FCameraAnim := nil;
  if E.Value('spawnclass') = 'idCameraAnim' then
  begin
    { "anim x" key of the entityDef: the file (x.camera = x.md5camera) }
    Path := D3CameraAnimPath(E.Value('anim ' + E.Value('anim')));
    if not FCameraAnims.TryGetValue(Path, Anim) then
    begin
      Anim := TD3CameraAnim.Create;
      if not Anim.LoadFromVfs(Path) then
      begin
        WritelnWarning('Doom3World', 'Camera anim "%s" of %s not found', [Path, E.Name]);
        FreeAndNil(Anim);
      end;
      FCameraAnims.Add(Path, Anim);
    end;
    if Anim = nil then
    begin
      { nothing to show: go on with what follows it }
      ActivateTargets(E);
      Exit;
    end;
    FCameraAnim := Anim;
    { the anim is in the map's space, moved by origin - old_origin }
    if E.HasKey('old_origin') then
      FCameraOffset := E.Origin - E.VectorValue('old_origin', TVector3.Zero)
    else
      FCameraOffset := TVector3.Zero;
    FCameraCycles := Max(1, E.IntValue('cycle', 1));
  end;
  FCameraEntity := E;
  FCameraStart := FTime;
  WritelnLog('Doom3World', 'Cinematic camera %s', [E.Name]);
  if FTime < FSkipUntil then
  begin
    { the cinematic goes on with this camera: skip it too }
    FSkipUntil := FTime + 1;
    StopCamera;
  end;
end;

procedure TD3Game.StopCamera;
var
  E: TD3MapEntity;
begin
  E := FCameraEntity;
  FCameraEntity := nil;
  FCameraAnim := nil;
  { idCameraAnim::Stop activates its targets }
  if (E <> nil) and (E.Value('spawnclass') = 'idCameraAnim') then
  begin
    WritelnLog('Doom3World', 'Cinematic camera %s done', [E.Name]);
    ActivateTargets(E);
  end;
end;

procedure TD3Game.UpdateCamera;
begin
  if (FCameraAnim = nil) or (FTime - FCameraStart < FCameraAnim.Duration) then
    Exit;
  Dec(FCameraCycles);
  if FCameraCycles > 0 then
    FCameraStart := FCameraStart + FCameraAnim.Duration
  else
    StopCamera;
end;

procedure TD3Game.SkipCinematic;
begin
  if FCameraEntity <> nil then
  begin
    { like gameLocal.SkipCinematic: the cameras the cinematic starts next
      (a chain of shots) are skipped too }
    FSkipUntil := FTime + 1;
    StopCamera;
  end;
end;

function TD3Game.CinematicActive: Boolean;
begin
  Result := FCameraEntity <> nil;
end;

function TD3Game.CinematicName: String;
begin
  if FCameraEntity <> nil then
    Result := FCameraEntity.Name
  else
    Result := '';
end;

procedure TD3Game.CinematicView(out Position, Direction, Up: TVector3; out FovDeg: Single);
var
  Origin, Fwd, U: TVector3;
  M: TMatrix3;
  Target: TD3MapEntity;
begin
  if FCameraAnim <> nil then
  begin
    FCameraAnim.Sample(FTime - FCameraStart, Origin, Fwd, U, FovDeg);
    Origin := Origin + FCameraOffset;
  end else
  if FCameraEntity <> nil then
  begin
    { idCameraView: from the entity, along its axis or at "cameraTarget" }
    Origin := FCameraEntity.Origin;
    M := FCameraEntity.Rotation;
    Fwd := Vector3(M.Data[0, 0], M.Data[0, 1], M.Data[0, 2]);
    U := Vector3(M.Data[2, 0], M.Data[2, 1], M.Data[2, 2]);
    Target := FindEntity(FCameraEntity.Value('cameraTarget'));
    if (Target <> nil) and (Target <> FCameraEntity) and
       not (Target.Origin - Origin).IsZero then
    begin
      Fwd := (Target.Origin - Origin).Normalize;
      U := Vector3(0, 0, 1);
    end;
    FovDeg := FCameraEntity.FloatValue('fov', 90);
  end else
  begin
    Origin := TVector3.Zero;
    Fwd := Vector3(1, 0, 0);
    U := Vector3(0, 0, 1);
    FovDeg := 90;
  end;
  Position := D3ToCge(Origin);
  Direction := D3ToCge(Fwd);
  Up := D3ToCge(U);
end;

procedure TD3Game.StartFade(const Target: TVector4; const Seconds: Single);
begin
  FFadeFrom := FadeColor;
  FFadeTo := Target;
  FFadeStart := FTime;
  FFadeTime := Max(0, Seconds);
end;

function TD3Game.FadeColor: TVector4;
var
  F: Single;
begin
  if FFadeTime <= 0 then
    Exit(FFadeTo);
  F := EnsureRange((FTime - FFadeStart) / FFadeTime, 0, 1);
  Result := FFadeFrom + (FFadeTo - FFadeFrom) * F;
end;

function TD3Game.TakeTeleport(out FeetPos: TVector3; out YawDeg: Single): Boolean;
begin
  Result := FTeleportPending;
  FeetPos := FTeleportPos;
  YawDeg := FTeleportYaw;
  FTeleportPending := False;
end;

procedure TD3Game.FadeLight(const Light: Integer; const Target, Seconds: Single);
var
  F: TD3LightFade;
  I: Integer;
begin
  for I := FLightFades.Count - 1 downto 0 do
    if FLightFades[I].Light = Light then
      FLightFades.Delete(I);
  if Seconds <= 0 then
  begin
    FMap.SetLightFade(Light, Target);
    Exit;
  end;
  F.Light := Light;
  F.From := FMap.Light(Light).Fade;
  F.Target := Target;
  F.Start := FTime;
  F.Duration := Seconds;
  FLightFades.Add(F);
end;

procedure TD3Game.UpdateLightFades;
var
  I: Integer;
  F: TD3LightFade;
  T: Single;
begin
  for I := FLightFades.Count - 1 downto 0 do
  begin
    F := FLightFades[I];
    T := EnsureRange((FTime - F.Start) / F.Duration, 0, 1);
    FMap.SetLightFade(F.Light, F.From + (F.Target - F.From) * T);
    if T >= 1 then
      FLightFades.Delete(I);
  end;
end;

function TD3Game.ScriptSoundSource(const Handle: Integer): TCastleSoundSource;
var
  E: TD3MapEntity;
  T: TCastleTransform;
begin
  if FSoundSources.TryGetValue(Handle, Result) then
    Exit;
  Result := nil;
  if Handle = WeaponHandle then
  begin
    { the weapon's sounds: at the player's eye (UpdateWeapon moves it) }
    T := TCastleTransform.Create(nil);
    T.Translation := FPlayerEye;
    FMap.Add(T);
    FSoundTransforms.Add(T);
    Result := TCastleSoundSource.Create(T);
    T.AddBehavior(Result);
    FSoundSources.Add(Handle, Result);
    Exit;
  end;
  E := HandleEntity(Handle);
  if E = nil then
    Exit;
  { the sound follows the entity's scene, or stays at its origin }
  T := TransformOf(E.Name);
  if T = nil then
  begin
    T := TCastleTransform.Create(nil);
    T.Translation := D3ToCge(E.Origin);
    FMap.Add(T);
    FSoundTransforms.Add(T);
  end;
  Result := TCastleSoundSource.Create(T);
  T.AddBehavior(Result);
  FSoundSources.Add(Handle, Result);
end;

function TD3Game.StartScriptSound(const Handle: Integer; const ShaderName: String;
  const Channel: Integer): Single;
var
  Snd: TCastleSound;
  Source: TCastleSoundSource;
  Playing: TCastlePlayingSoundSource;
begin
  Result := 0;
  Snd := SoundFromShader(ShaderName);
  if Snd = nil then
    Exit;
  Source := ScriptSoundSource(Handle);
  if Source = nil then
    Exit;
  { a new sound on a channel replaces the old one (channel 0: any) }
  if Channel <> 0 then
    StopScriptSound(Handle, Channel);
  Playing := TCastlePlayingSoundSource.Create(nil);
  Playing.Sound := Snd;
  { channel 0 sounds free themselves (set before playing) }
  Playing.FreeOnStop := Channel = 0;
  Source.Play(Playing);
  if Channel <> 0 then
    FScriptSounds.AddOrSetValue(IntToStr(Handle) + ':' + IntToStr(Channel), Playing);
  Result := Snd.Duration;
end;

procedure TD3Game.StopScriptSound(const Handle, Channel: Integer);
var
  Key: String;
  Playing: TCastlePlayingSoundSource;
begin
  Key := IntToStr(Handle) + ':' + IntToStr(Channel);
  if FScriptSounds.TryGetValue(Key, Playing) then
  begin
    Playing.Stop;
    FScriptSounds.Remove(Key);
  end;
end;

procedure TD3Game.ClearScriptSounds;
var
  Playing: TCastlePlayingSoundSource;
begin
  for Playing in FScriptSounds.Values do
    Playing.Stop;
  FScriptSounds.Clear;
  FSoundSources.Clear;
  FSoundTransforms.Clear;
end;

function TD3Game.ActorStatus: String;
var
  A: TD3Actor;
begin
  Result := '';
  for A in FActors do
  begin
    Result := Result + Format('%s: %s, legs %s (%s), at %s%s', [A.Model.Entity.Name, A.StateName,
      A.Channels[2].StateName, A.Channels[2].AnimName, CgeToD3(A.Model.Holder.Translation).ToString,
      BoolToStr(A.Moving, ', moving', '')]);
    if not A.LookAngles.IsZero then
      Result := Result + Format(', yaw %.0f, looks %.0f %.0f (focus %d for %.2f s)',
        [A.Yaw, A.LookAngles.X, A.LookAngles.Y, A.FocusTarget, A.FocusUntil - FTime]);
    Result := Result + LineEnding;
  end;
end;

function TD3Game.ScriptStatus: String;
var
  M: TD3ScriptMover;
  Moving, Turning: Integer;
begin
  if FScript = nil then
    Exit('No scripts');
  Moving := 0;
  Turning := 0;
  for M in FScriptMovers.Values do
  begin
    if M.Moving then
      Inc(Moving);
    if M.Rotating then
      Inc(Turning);
  end;
  Result := Format('%d script threads, %d script movers (%d moving, %d rotating), %d bound entities%s',
    [FScript.ThreadCount, FScriptMovers.Count, Moving, Turning, FBindings.Count,
     BoolToStr(ScriptsPaused, ', paused', '')]);
end;

procedure TD3Game.OpenTeam(const Door: TD3Mover);
var
  M: TD3Mover;
begin
  if Door.Locked then
    Exit;
  if Door.Team = '' then
    Door.Open
  else
    for M in FMovers do
      if (M.Kind = mkDoor) and (M.Team = Door.Team) then
        M.Open;
end;

procedure TD3Game.CloseTeam(const Door: TD3Mover);
var
  M: TD3Mover;
begin
  if Door.Team = '' then
    Door.Close
  else
    for M in FMovers do
      if (M.Kind = mkDoor) and (M.Team = Door.Team) then
        M.Close;
end;

procedure TD3Game.LockTeam(const Door: TD3Mover; const Value: Boolean);
var
  M: TD3Mover;
begin
  if Door.Team = '' then
    Door.Locked := Value
  else
    for M in FMovers do
      if (M.Kind = mkDoor) and (M.Team = Door.Team) then
        M.Locked := Value;
end;

function TD3Game.TransformOf(const AName: String): TCastleTransform;
var
  B: TD3BrushEntity;
  ME: TD3ModelEntity;
begin
  B := FMap.FindBrush(AName);
  if B <> nil then
    Exit(B.Scene);
  ME := FMap.FindModelEntity(AName);
  if ME <> nil then
    Exit(ME.Holder);
  Result := nil;
end;

function TD3Game.FindBinding(const Child: TCastleTransform): TD3Binding;
begin
  for Result in FBindings do
    if Result.Child = Child then
      Exit;
  Result := nil;
end;

procedure TD3Game.Bind(const Child, Parent: TCastleTransform);
var
  Bnd: TD3Binding;
  P: TCastleTransform;
  Guard: Integer;
begin
  if (Child = nil) or (Parent = nil) or (Child = Parent) then
    Exit;
  { no loops: the parent must not be bound to the child }
  P := Parent;
  Guard := 0;
  while (P <> nil) and (Guard < 100) do
  begin
    if P = Child then
      Exit;
    Bnd := FindBinding(P);
    if Bnd = nil then
      Break;
    P := Bnd.Parent;
    Inc(Guard);
  end;
  Bnd := FindBinding(Child);
  if Bnd = nil then
  begin
    Bnd := TD3Binding.Create;
    Bnd.Child := Child;
    FBindings.Add(Bnd);
  end;
  Bnd.Parent := Parent;
  { both are children of the map (world space): child = parent * relative }
  Bnd.ChildInParent := Parent.InverseTransform * Child.Transform;
  FBindingsSorted := False;
end;

procedure TD3Game.Unbind(const Child: TCastleTransform);
var
  Bnd: TD3Binding;
begin
  Bnd := FindBinding(Child);
  if Bnd <> nil then
    FBindings.Remove(Bnd);
  FBindingsSorted := False;
end;

procedure TD3Game.SpawnBindings;
var
  E: TD3MapEntity;
begin
  if FMap.MapFile = nil then
    Exit;
  { lights and other entities are not bound yet }
  for E in FMap.MapFile.Entities do
    if E.Value('bind') <> '' then
      Bind(TransformOf(E.Name), TransformOf(E.Value('bind')));
end;

function CompareBindingDepth(constref A, B: TD3Binding): Integer;
begin
  Result := A.Depth - B.Depth;
end;

procedure TD3Game.UpdateBindings;
var
  Bnd, P: TD3Binding;
  M: TMatrix4;
  T, Scale: TVector3;
  R: TVector4;
begin
  { parents before their children, so chains (a crane's arm on its
    carrier) follow in the same frame }
  if not FBindingsSorted then
  begin
    for Bnd in FBindings do
    begin
      Bnd.Depth := 0;
      P := FindBinding(Bnd.Parent);
      while (P <> nil) and (Bnd.Depth < 100) do
      begin
        Inc(Bnd.Depth);
        P := FindBinding(P.Parent);
      end;
    end;
    FBindings.Sort(specialize TComparer<TD3Binding>.Construct(@CompareBindingDepth));
    FBindingsSorted := True;
  end;
  for Bnd in FBindings do
  begin
    M := Bnd.Parent.Transform * Bnd.ChildInParent;
    { most parents don't move: don't touch their children's scenes }
    if TMatrix4.Equals(M, Bnd.Child.Transform, 0.01) then
      Continue;
    MatrixDecompose(M, T, R, Scale);
    Bnd.Child.Translation := T;
    Bnd.Child.Rotation := R;
  end;
end;

{ Scripts -------------------------------------------------------------------- }

{ CGE transformation of a Doom 3 origin and idMat3 (rows = axes). }
function D3PlacementMatrix(const Origin: TVector3; const M: TMatrix3): TMatrix4;
var
  C: Integer;
  U, W, Col: TVector3;
begin
  Result := TMatrix4.Identity;
  for C := 0 to 2 do
  begin
    U := CgeToD3(TVector3.One[C]);
    W := Vector3(
      U.X * M.Data[0, 0] + U.Y * M.Data[1, 0] + U.Z * M.Data[2, 0],
      U.X * M.Data[0, 1] + U.Y * M.Data[1, 1] + U.Z * M.Data[2, 1],
      U.X * M.Data[0, 2] + U.Y * M.Data[1, 2] + U.Z * M.Data[2, 2]);
    Col := D3ToCge(W);
    Result.Data[C, 0] := Col.X;
    Result.Data[C, 1] := Col.Y;
    Result.Data[C, 2] := Col.Z;
  end;
  Col := D3ToCge(Origin);
  Result.Data[3, 0] := Col.X;
  Result.Data[3, 1] := Col.Y;
  Result.Data[3, 2] := Col.Z;
end;

{ The Doom 3 origin and angles of a CGE transformation. }
procedure D3PlacementFromMatrix(const T: TMatrix4; out Origin, Angles: TVector3);
var
  M: TMatrix3;
  I: Integer;
  Axis, V: TVector3;
begin
  Origin := CgeToD3(Vector3(T.Data[3, 0], T.Data[3, 1], T.Data[3, 2]));
  for I := 0 to 2 do
  begin
    { the image of Doom 3 local axis I }
    Axis := D3ToCge(TVector3.One[I]);
    V := Vector3(
      T.Data[0, 0] * Axis.X + T.Data[1, 0] * Axis.Y + T.Data[2, 0] * Axis.Z,
      T.Data[0, 1] * Axis.X + T.Data[1, 1] * Axis.Y + T.Data[2, 1] * Axis.Z,
      T.Data[0, 2] * Axis.X + T.Data[1, 2] * Axis.Y + T.Data[2, 2] * Axis.Z);
    V := CgeToD3(V);
    M.Data[I, 0] := V.X;
    M.Data[I, 1] := V.Y;
    M.Data[I, 2] := V.Z;
  end;
  Angles := MatrixAngles(M);
end;

{ A point of a clamped uniform B-spline (degree 3, less with fewer points)
  at T in 0..1, like idCurve_NURBS with equal weights. }
function SplinePoint(const P: array of TVector3; const T: Single): TVector3;
var
  N, Degree, K, I, J, R: Integer;
  Knots: array of Single;
  D: array of TVector3;
  U, A: Single;
begin
  N := Length(P);
  if N = 0 then
    Exit(TVector3.Zero);
  if N = 1 then
    Exit(P[0]);
  Degree := Min(3, N - 1);
  { clamped knots: Degree + 1 zeros, uniform inside, Degree + 1 ones }
  SetLength(Knots, N + Degree + 1);
  for I := 0 to High(Knots) do
    if I <= Degree then
      Knots[I] := 0
    else
    if I >= N then
      Knots[I] := 1
    else
      Knots[I] := (I - Degree) / (N - Degree);
  U := EnsureRange(T, 0, 1);
  { the knot span holding U }
  K := Degree;
  while (K < N - 1) and (U >= Knots[K + 1]) do
    Inc(K);
  { de Boor }
  SetLength(D, Degree + 1);
  for J := 0 to Degree do
    D[J] := P[J + K - Degree];
  for R := 1 to Degree do
    for J := Degree downto R do
    begin
      I := J + K - Degree;
      if Knots[I + Degree - R + 1] - Knots[I] <= 0 then
        A := 0
      else
        A := (U - Knots[I]) / (Knots[I + Degree - R + 1] - Knots[I]);
      D[J] := D[J - 1] * (1 - A) + D[J] * A;
    end;
  Result := D[Degree];
end;

{ Yaw (degrees) of the curve's direction at T. }
function SplineYaw(const P: array of TVector3; const T: Single): Single;
var
  D: TVector3;
begin
  D := SplinePoint(P, Min(1, T + 0.01)) - SplinePoint(P, Max(0, T - 0.01));
  if Sqr(D.X) + Sqr(D.Y) < 1e-6 then
    Exit(0);
  Result := RadToDeg(ArcTan2(D.Y, D.X));
end;

{ The control points of a curve key: "N ( x y z x y z ... )". }
function ParseCurve(const S: String): specialize TArray<TVector3>;
var
  Parts: TStringArray;
  N, I: Integer;
begin
  Result := nil;
  Parts := StringReplace(StringReplace(S, '(', ' ', [rfReplaceAll]), ')', ' ', [rfReplaceAll]).
    Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
  if Length(Parts) < 1 then
    Exit;
  N := StrToIntDef(Parts[0], 0);
  N := Min(N, (Length(Parts) - 1) div 3);
  SetLength(Result, N);
  for I := 0 to N - 1 do
    Result[I] := Vector3(StrToFloatDef(Parts[1 + I * 3], 0, DefaultFormatSettings),
      StrToFloatDef(Parts[2 + I * 3], 0, DefaultFormatSettings),
      StrToFloatDef(Parts[3 + I * 3], 0, DefaultFormatSettings));
end;

{ Fraction of a move done after T of Total seconds, accelerating for
  Accel and decelerating for Decel seconds (idExtrapolate's
  EXTRAPOLATION_ACCELLINEAR / DECELLINEAR, a trapezoid of speed). }
function MoveFraction(const T, Total, Accel, Decel: Single): Single;
var
  A, D, V: Single;
begin
  if (Total <= 0) or (T >= Total) then
    Exit(1);
  if T <= 0 then
    Exit(0);
  A := Max(0, Accel);
  D := Max(0, Decel);
  if A + D > Total then
  begin
    A := Total * A / (A + D);
    D := Total - A;
  end;
  { top speed so that the whole move covers 1 }
  V := 1 / (Total - A / 2 - D / 2);
  if T < A then
    Result := 0.5 * V * Sqr(T) / A
  else
  if T <= Total - D then
    Result := 0.5 * V * A + V * (T - A)
  else
    Result := 1 - 0.5 * V * Sqr(Total - T) / D;
  Result := EnsureRange(Result, 0, 1);
end;

function TD3ScriptMover.Busy: Boolean;
begin
  Result := Moving or (Rotating and not RotContinuous);
end;

function TD3Game.HandleEntity(const Handle: Integer): TD3MapEntity;
begin
  if (FMap.MapFile = nil) or (Handle < 1) or (Handle > FMap.MapFile.Entities.Count) then
    Exit(nil);
  Result := FMap.MapFile.Entities[Handle - 1];
end;

function TD3Game.EntityHandle(const E: TD3MapEntity): Integer;
begin
  if (E = nil) or not FHandles.TryGetValue(LowerCase(E.Name), Result) then
    Result := 0;
end;

function TD3Game.ScriptFindEntity(const AName: String): Integer;
begin
  if SameText(AName, 'player1') then
    Exit(PlayerHandle);
  if not FHandles.TryGetValue(LowerCase(AName), Result) then
    Result := 0;
end;

function TD3Game.ScriptEntityName(const Handle: Integer): String;
var
  E: TD3MapEntity;
begin
  E := HandleEntity(Handle);
  if E <> nil then
    Result := E.Name
  else
    Result := '';
end;

function TD3Game.ScriptEntityBusy(const Handle: Integer): Boolean;
var
  Actor: TD3Actor;
  M: TD3ScriptMover;
  Door: TD3Mover;
  E: TD3MapEntity;
begin
  if FScriptMovers.TryGetValue(Handle, M) and M.Busy then
    Exit(True);
  Actor := FindActor(Handle);
  if (Actor <> nil) and (Actor.WaitAction <> '') then
    Exit(True);
  E := HandleEntity(Handle);
  if E <> nil then
    for Door in FMovers do
      if (Door.Brush.Entity = E) and (Door.Kind = mkDoor) and
         (Door.State in [dsOpening, dsClosing]) then
        Exit(True);
  Result := False;
end;

function TD3Game.ScriptMover(const Handle: Integer): TD3ScriptMover;
var
  E: TD3MapEntity;
  T: TCastleTransform;
  Bnd: TD3Binding;
  Local: TMatrix4;
begin
  if FScriptMovers.TryGetValue(Handle, Result) then
    Exit;
  Result := nil;
  E := HandleEntity(Handle);
  if E = nil then
    Exit;
  T := TransformOf(E.Name);
  if T = nil then
    Exit;
  Result := TD3ScriptMover.Create;
  Result.Handle := Handle;
  Result.Transform := T;
  Bnd := FindBinding(T);
  if Bnd <> nil then
    Local := Bnd.ChildInParent
  else
    Local := T.Transform;
  D3PlacementFromMatrix(Local, Result.Origin, Result.Angles);
  { idMover spawn args: "move_time" (default 1), "move_speed", "accel_time",
    "decel_time" }
  Result.MoveTime := E.FloatValue('move_time', 1);
  Result.MoveSpeed := E.FloatValue('move_speed', 0);
  Result.AccelTime := E.FloatValue('accel_time', 0);
  Result.DecelTime := E.FloatValue('decel_time', 0);
  FScriptMovers.Add(Handle, Result);
end;

procedure TD3Game.ApplyScriptMover(const M: TD3ScriptMover);
var
  Local: TMatrix4;
  Bnd: TD3Binding;
  T, Scale: TVector3;
  R: TVector4;
begin
  Local := D3PlacementMatrix(M.Origin, AnglesMatrix(M.Angles));
  Bnd := FindBinding(M.Transform);
  if Bnd <> nil then
  begin
    { UpdateBindings places it }
    Bnd.ChildInParent := Local;
    Exit;
  end;
  MatrixDecompose(Local, T, R, Scale);
  M.Transform.Translation := T;
  M.Transform.Rotation := R;
end;

procedure TD3Game.UpdateScriptMovers;
var
  M: TD3ScriptMover;
  F: Single;
  Changed: Boolean;
begin
  for M in FScriptMovers.Values do
  begin
    Changed := False;
    if M.Moving then
    begin
      F := MoveFraction(FTime - M.MoveStart, M.MoveDuration, M.AccelTime, M.DecelTime);
      if Length(M.Spline) > 0 then
      begin
        { along the curve, turning with it from the angles it had }
        M.Origin := SplinePoint(M.Spline, F);
        M.Angles.Y := M.SplineAngleYaw0 + SplineYaw(M.Spline, F) - M.SplineYaw0;
      end else
        M.Origin := M.MoveFrom + (M.MoveTo - M.MoveFrom) * F;
      if F >= 1 then
      begin
        M.Moving := False;
        M.Spline := nil;
      end;
      Changed := True;
    end;
    if M.Rotating then
    begin
      if M.RotContinuous then
        M.Angles := M.RotFrom + M.RotSpeed * (FTime - M.RotStart)
      else
      begin
        F := MoveFraction(FTime - M.RotStart, M.RotDuration, M.AccelTime, M.DecelTime);
        M.Angles := M.RotFrom + (M.RotTo - M.RotFrom) * F;
        if F >= 1 then
          M.Rotating := False;
      end;
      Changed := True;
    end;
    if Changed then
      ApplyScriptMover(M);
  end;
end;

procedure TD3Game.StartScripts;
var
  Base, Key: String;
  Start: QWord;
  I: Integer;
  E: TD3MapEntity;
  F: TD3ScriptFunction;
begin
  FHandles.Clear;
  if FMap.MapFile = nil then
    Exit;
  for I := 0 to FMap.MapFile.Entities.Count - 1 do
    if FMap.MapFile.Entities[I].Name <> '' then
      FHandles.AddOrSetValue(LowerCase(FMap.MapFile.Entities[I].Name), I + 1);
  { like idGameLocal: the game's scripts, then the map's own }
  Base := TDoom3Map.MapBasePath(FMap.MapName);
  if not D3Fs.FileExists('script/doom_main.script') and not D3Fs.FileExists(Base + '.script') then
    Exit;
  Start := GetTickCount64;
  FScript := TD3ScriptVM.Create;
  FScript.Host := FScriptHost;
  try
    if D3Fs.FileExists('script/doom_main.script') then
      FScript.CompileFile('script/doom_main.script');
    if D3Fs.FileExists(Base + '.script') then
      FScript.CompileFile(Base + '.script');
  except
    on Ex: ED3ScriptError do
    begin
      WritelnWarning('Doom3World', 'Script error, scripts are off: %s', [Ex.Message]);
      FreeAndNil(FScript);
      Exit;
    end;
  end;
  WritelnLog('Doom3World', 'Scripts: %d functions from %d files compiled in %.2f s',
    [FScript.FunctionCount, FScript.FileCount, (GetTickCount64 - Start) / 1000]);
  { idWorldspawn: the map script's main, then worldspawn's "call" keys,
    all on the first frame }
  F := FScript.FindFunction('main');
  if F <> nil then
    FScript.QueueThread(F);
  E := FMap.MapFile.Entities[0];
  for I := 0 to E.Pairs.Count - 1 do
  begin
    Key := LowerCase(E.Pairs.Names[I]);
    if Copy(Key, 1, 4) = 'call' then
      CallScript(E.Pairs.ValueFromIndex[I], E.Name);
  end;
end;

procedure TD3Game.CallScript(const FunctionName: String; const Who: String);
var
  F: TD3ScriptFunction;
begin
  if FScript = nil then
  begin
    Unsupported('script function calls without scripts ("call" of ' + Who + ')');
    Exit;
  end;
  F := FScript.FindFunction(FunctionName);
  if F = nil then
  begin
    WritelnWarning('Doom3World', 'Script function "%s" (called by %s) not found', [FunctionName, Who]);
    Exit;
  end;
  FScript.QueueThread(F);
end;

{ idMover::VectorForDir }
function MoveDirVector(const Dir: Single; const Angles: TVector3): TVector3;
var
  Axis: TMatrix3;
  D: Integer;
begin
  D := Round(Dir);
  Axis := AnglesMatrix(Angles);
  case D of
    -1: Result := Vector3(0, 0, 1);   // UP
    -2: Result := Vector3(0, 0, -1);  // DOWN
    -3: Result := Vector3(Axis.Data[1, 0], Axis.Data[1, 1], Axis.Data[1, 2]);   // LEFT
    -4: Result := -Vector3(Axis.Data[1, 0], Axis.Data[1, 1], Axis.Data[1, 2]);  // RIGHT
    -5: Result := Vector3(Axis.Data[0, 0], Axis.Data[0, 1], Axis.Data[0, 2]);   // FORWARD
    -6: Result := -Vector3(Axis.Data[0, 0], Axis.Data[0, 1], Axis.Data[0, 2]);  // BACK
    -7: Result := Vector3(Axis.Data[2, 0], Axis.Data[2, 1], Axis.Data[2, 2]);   // REL_UP
    -8: Result := -Vector3(Axis.Data[2, 0], Axis.Data[2, 1], Axis.Data[2, 2]);  // REL_DOWN
    -9: Result := Vector3(Axis.Data[1, 0], Axis.Data[1, 1], Axis.Data[1, 2]);   // REL_LEFT
    -10: Result := -Vector3(Axis.Data[1, 0], Axis.Data[1, 1], Axis.Data[1, 2]); // REL_RIGHT
    -11: Result := Vector3(Axis.Data[0, 0], Axis.Data[0, 1], Axis.Data[0, 2]);  // REL_FORWARD
    -12: Result := -Vector3(Axis.Data[0, 0], Axis.Data[0, 1], Axis.Data[0, 2]); // REL_BACK
    else
      Result := Vector3(Cos(DegToRad(Dir)), Sin(DegToRad(Dir)), 0);
  end;
end;

function TD3Game.ScriptEvent(const Thread: TD3ScriptThread; const Target: Integer; const Event: TD3ScriptEvent;
  const Args: TD3ValueArray; var EventResult: TD3Value): Boolean;
var
  N, Key: String;
  E, Other: TD3MapEntity;
  M: TD3ScriptMover;
  Light, I, Count: Integer;
  B: TD3BrushEntity;
  ME: TD3ModelEntity;
  Door: TD3Mover;
  Dist: Single;

  function ArgF(const Index: Integer): Single;
  begin
    Result := D3ValueToFloat(Args[Index]);
  end;

  procedure StartMove(const Dest: TVector3);
  begin
    M.MoveFrom := M.Origin;
    M.MoveTo := Dest;
    M.MoveStart := FTime;
    Dist := (Dest - M.Origin).Length;
    if M.MoveSpeed > 0 then
      M.MoveDuration := Dist / M.MoveSpeed
    else
      M.MoveDuration := M.MoveTime;
    M.Moving := True;
  end;

  procedure StartRotation(const Dest: TVector3);
  begin
    M.RotFrom := M.Angles;
    M.RotTo := Dest;
    M.RotStart := FTime;
    M.RotDuration := M.MoveTime;
    M.Rotating := True;
    M.RotContinuous := False;
  end;

  function DoorOf(const AE: TD3MapEntity): TD3Mover;
  begin
    for Result in FMovers do
      if (Result.Brush.Entity = AE) and (Result.Kind = mkDoor) then
        Exit;
    Result := nil;
  end;

begin
  Result := True;
  N := Event.Name;

  { sys events }
  if Target = 0 then
  begin
    if N = 'trigger' then
    begin
      E := HandleEntity(Args[0].E);
      if E <> nil then
        Activate(E);
    end else
    if N = 'getEntity' then
      EventResult := D3EntityValue(ScriptFindEntity(Args[0].S))
    else
    if (N = 'setcvar') or (N = 'getcvar') then
      // cvars are not shared with scripts: getcvar returns ""
    else
    if N = 'fadeIn' then
      StartFade(Vector4(Args[0].V, 0), ArgF(1))
    else
    if N = 'fadeOut' then
      StartFade(Vector4(Args[0].V, 1), ArgF(1))
    else
    if N = 'fadeTo' then
      StartFade(Vector4(Args[0].V, ArgF(1)), ArgF(2))
    else
    if N = 'setCamera' then
    begin
      E := HandleEntity(Args[0].E);
      if E <> nil then
        StartCamera(E);
    end else
    if N = 'influenceActive' then
      EventResult := D3FloatValue(0)
    else
    if N = 'firstPerson' then
    begin
      FCameraEntity := nil;
      FCameraAnim := nil;
    end else
      Result := False;
    Exit;
  end;

  if Target = WeaponHandle then
  begin
    if (FWeapon = nil) or not FWeapon.Scripted then
      Exit(False);
    Exit(WeaponEvent(FWeapon, Thread, N, Args, EventResult));
  end;

  if Target = PlayerHandle then
  begin
    case N of
      'getOrigin', 'getWorldOrigin':
        EventResult := D3VectorValue(CgeToD3(FPlayerEye - Vector3(0, PlayerEyeHeight, 0)));
      'getName': EventResult := D3StringValue('player1');
      'getHealth': EventResult := D3FloatValue(Health);
      else
        Result := False;
    end;
    Exit;
  end;
  E := HandleEntity(Target);
  if E = nil then
    Exit(False);
  if (FindActor(Target) <> nil) and ActorEvent(FindActor(Target), Thread, N, Args, EventResult) then
    Exit(True);
  if MoveableOf(E) <> nil then
  begin
    { idMoveable / idEntity physics events }
    if N = 'setLinearVelocity' then
    begin
      MoveableOf(E).Velocity := Args[0].V;
      MoveableOf(E).AtRest := MoveableOf(E).Velocity.IsZero;
      Exit(True);
    end;
    if N = 'getLinearVelocity' then
    begin
      EventResult := D3VectorValue(MoveableOf(E).Velocity);
      Exit(True);
    end;
    if N = 'enableDamage' then
    begin
      { idMoveable::Event_EnableDamage: on (or off) for 2.5 s }
      MoveableOf(E).CanDamage := ArgF(0) <> 0;
      MoveableOf(E).DamageUntil := FTime + 2.5;
      Exit(True);
    end;
    if N = 'isAtRest' then
    begin
      EventResult := D3FloatValue(Ord(MoveableOf(E).AtRest));
      Exit(True);
    end;
  end;
  if (N = 'markUsed') and (CombatNodeOf(E) <> nil) then
  begin
    { idCombatNode::Event_MarkUsed: use_once nodes turn off }
    if CombatNodeOf(E).UseOnce then
      CombatNodeOf(E).Disabled := True;
    Exit(True);
  end;
  if N = 'randomPath' then
  begin
    { idEntity::Event_RandomPath: one of its targets that is a path_* }
    Count := 0;
    for I := 0 to E.Pairs.Count - 1 do
    begin
      Key := LowerCase(E.Pairs.Names[I]);
      if (Copy(Key, 1, 6) <> 'target') or
         ((Length(Key) > 6) and not CharInSet(Key[7], ['0'..'9'])) then
        Continue;
      Other := FindEntity(E.Pairs.ValueFromIndex[I]);
      if (Other <> nil) and (Copy(LowerCase(Other.ClassName_), 1, 5) = 'path_') then
      begin
        Inc(Count);
        { reservoir choice among them }
        if Random(Count) = 0 then
          EventResult := D3EntityValue(EntityHandle(Other));
      end;
    end;
    Exit;
  end;
  Light := -1;
  if SameText(E.ClassName_, 'light') then
    Light := FMap.FindLight(E.Name);

  { all entities }
  if N = 'getName' then
    EventResult := D3StringValue(E.Name)
  else
  if N = 'activate' then
    Activate(E)
  else
  if (N = 'getKey') or (N = 'getFloatKey') or (N = 'getIntKey') or
     (N = 'getBoolKey') or (N = 'getVectorKey') or (N = 'getEntityKey') then
  begin
    Key := Args[0].S;
    case N of
      'getKey': EventResult := D3StringValue(E.Value(Key));
      'getFloatKey': EventResult := D3FloatValue(E.FloatValue(Key));
      'getIntKey': EventResult := D3FloatValue(Trunc(E.FloatValue(Key)));
      'getBoolKey': EventResult := D3FloatValue(Ord(E.FloatValue(Key) <> 0));
      'getVectorKey': EventResult := D3VectorValue(E.VectorValue(Key, TVector3.Zero));
      else EventResult := D3EntityValue(ScriptFindEntity(E.Value(Key)));
    end;
  end else
  if N = 'setKey' then
    E.SetValue(Args[0].S, Args[1].S)
  else
  if N = 'getNextKey' then
  begin
    { the first key starting with Args[0] after the key Args[1] ('' = from
      the start), '' when there's no more }
    Count := -1;
    if Args[1].S <> '' then
      Count := E.Pairs.IndexOfName(Args[1].S);
    EventResult := D3StringValue('');
    for I := Count + 1 to E.Pairs.Count - 1 do
      if SameText(Copy(E.Pairs.Names[I], 1, Length(Args[0].S)), Args[0].S) then
      begin
        EventResult := D3StringValue(E.Pairs.Names[I]);
        Break;
      end;
  end else
  if N = 'setGuiParm' then
    FMap.SetGuiParm(E, Args[0].S, D3ValueToString(Args[1]))
  else
  if (N = 'numTargets') or (N = 'getTarget') then
  begin
    Count := 0;
    for I := 0 to E.Pairs.Count - 1 do
    begin
      Key := LowerCase(E.Pairs.Names[I]);
      if (Copy(Key, 1, 6) <> 'target') or
         ((Length(Key) > 6) and not CharInSet(Key[7], ['0'..'9'])) then
        Continue;
      Other := FindEntity(E.Pairs.ValueFromIndex[I]);
      if Other = nil then
        Continue;
      if (N = 'getTarget') and (Count = Round(ArgF(0))) then
      begin
        EventResult := D3EntityValue(EntityHandle(Other));
        Exit;
      end;
      Inc(Count);
    end;
    if N = 'numTargets' then
      EventResult := D3FloatValue(Count);
  end else
  if (N = 'hide') or (N = 'show') or (N = 'isHidden') or (N = 'remove') then
  begin
    if N = 'remove' then
    begin
      RemoveEntity(E);
      Exit;
    end;
    if Light >= 0 then
    begin
      if N = 'isHidden' then
        EventResult := D3FloatValue(Ord(not FMap.Light(Light).StartOn))
      else
        FMap.SetLightOn(Light, N = 'show');
      Exit;
    end;
    B := FMap.FindBrush(E.Name);
    ME := FMap.FindModelEntity(E.Name);
    if N = 'isHidden' then
    begin
      if B <> nil then
        EventResult := D3FloatValue(Ord(B.Hidden))
      else
      if ME <> nil then
        EventResult := D3FloatValue(Ord(ME.Hidden));
      Exit;
    end;
    if B <> nil then
      B.SetHidden(N = 'hide');
    if ME <> nil then
    begin
      ME.Hidden := N = 'hide';
      ME.Holder.Exists := not ME.Hidden;
    end;
  end else

  { lights }
  if (Light >= 0) and ((N = 'On') or (N = 'Off')) then
    FMap.SetLightOn(Light, N = 'On')
  else
  if (Light >= 0) and (N = 'fadeOutLight') then
    FadeLight(Light, 0, ArgF(0))
  else
  if (Light >= 0) and (N = 'fadeInLight') then
  begin
    { an off light comes on dark, then brightens }
    if not FMap.Light(Light).StartOn then
    begin
      FMap.SetLightFade(Light, 0);
      FMap.SetLightOn(Light, True);
    end;
    FadeLight(Light, 1, ArgF(0));
  end else
  if (N = 'startSoundShader') or (N = 'startSound') then
  begin
    { startSound names an entity key holding the shader (snd_...) }
    if N = 'startSound' then
      Key := E.Value(Args[0].S)
    else
      Key := Args[0].S;
    EventResult := D3FloatValue(StartScriptSound(Target, Key, Round(ArgF(1))));
  end else
  if N = 'stopSound' then
    StopScriptSound(Target, Round(ArgF(0)))
  else
  if (Light >= 0) and (N = 'setColor') then
  begin
    FMap.SetLightParm(Light, 0, ArgF(0));
    FMap.SetLightParm(Light, 1, ArgF(1));
    FMap.SetLightParm(Light, 2, ArgF(2));
  end else
  if (Light >= 0) and ((N = 'setShaderParm') or (N = 'setLightParm')) then
    FMap.SetLightParm(Light, Round(ArgF(0)), ArgF(1))
  else

  { doors (idDoor) }
  if (DoorOf(E) <> nil) and ((N = 'open') or (N = 'close') or (N = 'lock') or
     (N = 'isOpen') or (N = 'isLocked')) then
  begin
    Door := DoorOf(E);
    case N of
      'open': OpenTeam(Door);
      'close': CloseTeam(Door);
      'lock': LockTeam(Door, ArgF(0) <> 0);
      'isOpen': EventResult := D3FloatValue(Ord(Door.State <> dsClosed));
      else EventResult := D3FloatValue(Ord(Door.Locked));
    end;
  end else

  { binding }
  if (N = 'bind') or (N = 'bindPosition') then
  begin
    Other := HandleEntity(Args[0].E);
    if Other <> nil then
    begin
      Bind(TransformOf(E.Name), TransformOf(Other.Name));
      { a script mover's origin and angles become relative to the master }
      if FScriptMovers.TryGetValue(Target, M) and (FindBinding(M.Transform) <> nil) then
        D3PlacementFromMatrix(FindBinding(M.Transform).ChildInParent, M.Origin, M.Angles);
    end;
  end else
  if (N = 'unbind') or (N = 'removeBinds') then
  begin
    if N = 'unbind' then
    begin
      Unbind(TransformOf(E.Name));
      if FScriptMovers.TryGetValue(Target, M) then
        D3PlacementFromMatrix(M.Transform.Transform, M.Origin, M.Angles);
    end;
  end else

  { idMover }
  begin
    M := ScriptMover(Target);
    if M = nil then
      Exit(False);
    case N of
      'time': M.MoveTime := ArgF(0);
      'speed': M.MoveSpeed := ArgF(0);
      'accelTime': M.AccelTime := ArgF(0);
      'decelTime': M.DecelTime := ArgF(0);
      'move': StartMove(M.Origin + MoveDirVector(ArgF(0), M.Angles) * ArgF(1));
      'moveTo':
        begin
          Other := HandleEntity(Args[0].E);
          if Other <> nil then
            StartMove(Other.Origin);
        end;
      'moveToPos': StartMove(Args[0].V);
      'rotateOnce': StartRotation(M.Angles + Args[0].V);
      'rotateTo': StartRotation(Args[0].V);
      'rotateUpTo', 'rotateDownTo':
        begin
          M.RotTo := M.Angles;
          M.RotTo.Data[EnsureRange(Round(ArgF(0)), 0, 2)] := ArgF(1);
          StartRotation(M.RotTo);
        end;
      'rotate':
        begin
          { degrees per second around each axis, until stopped }
          M.RotFrom := M.Angles;
          M.RotSpeed := Args[0].V;
          M.RotStart := FTime;
          M.Rotating := True;
          M.RotContinuous := True;
        end;
      'stopMoving', 'stopSpline':
        begin
          M.Moving := False;
          M.Spline := nil;
        end;
      'startSpline':
        begin
          Other := HandleEntity(Args[0].E);
          if Other <> nil then
          begin
            { the curve_* key of the spline entity (idCurve_NURBS,
              CatmullRomSpline...), in map coordinates }
            M.Spline := nil;
            for I := 0 to Other.Pairs.Count - 1 do
              if Copy(LowerCase(Other.Pairs.Names[I]), 1, 6) = 'curve_' then
                M.Spline := ParseCurve(Other.Pairs.ValueFromIndex[I]);
            if Length(M.Spline) > 1 then
            begin
              Dist := 0;
              for I := 1 to High(M.Spline) do
                Dist := Dist + (M.Spline[I] - M.Spline[I - 1]).Length;
              M.MoveStart := FTime;
              if M.MoveSpeed > 0 then
                M.MoveDuration := Dist / M.MoveSpeed
              else
                M.MoveDuration := M.MoveTime;
              M.SplineYaw0 := SplineYaw(M.Spline, 0);
              M.SplineAngleYaw0 := M.Angles.Y;
              M.Moving := True;
            end else
              M.Spline := nil;
          end;
        end;
      'removeInitialSplineAngles':
        { the mover keeps its own angles plus the curve's turn }
        ;
      'stopRotating': M.Rotating := False;
      'isMoving': EventResult := D3FloatValue(Ord(M.Moving));
      'isRotating': EventResult := D3FloatValue(Ord(M.Rotating));
      'getOrigin': EventResult := D3VectorValue(M.Origin);
      'getWorldOrigin': EventResult := D3VectorValue(CgeToD3(M.Transform.WorldTranslation));
      'getAngles': EventResult := D3VectorValue(M.Angles);
      'setOrigin':
        begin
          M.Moving := False;
          M.Origin := Args[0].V;
          ApplyScriptMover(M);
        end;
      'setAngles':
        begin
          M.Rotating := False;
          M.Angles := Args[0].V;
          ApplyScriptMover(M);
        end;
      else
        Result := False;
    end;
  end;
end;

function TD3Game.Fire(const Origin, Dir: TVector3): Boolean;
var
  WallDist, BestDist: Single;
  Best: TD3Monster;
  Hit: TCastleTransform;
  D: TVector3;
  HitName: String;
begin
  { the built-in pistol: hitscan, PistolDamage every PistolDelay }
  Result := False;
  if (FFireCooldown > 0) or PlayerDead then
    Exit;
  FFireCooldown := PistolDelay;
  SinceFire := 0;
  Result := True;
  D := Dir.Normalize;
  Hit := FMap.World.WorldRayCast(Origin, D, WallDist);
  if Hit = nil then
    WallDist := MaxSingle;
  Best := RayMonster(Origin, D, WallDist, BestDist);
  if Best <> nil then
    HitName := 'hit ' + Best.Model.Entity.Name
  else
    HitName := 'missed';
  if Hit <> nil then
    WritelnLog('Doom3World', 'Shot: wall %.0f (%s), monster %s', [WallDist, Hit.Name, HitName])
  else
    WritelnLog('Doom3World', 'Shot: no wall, monster %s', [HitName]);
  if Best <> nil then
    DamageMonster(Best, PistolDamage);
end;

procedure TD3Game.Use(const Origin, Dir: TVector3);
const
  TalkDistance = 128;
var
  Mover: TD3Mover;
  Ray: TBox3D;
  A, Best: TD3Actor;
  ToActor: TVector3;
  T, BestT: Single;
begin
  { a character in front of the player, within reach, ready to talk }
  Best := nil;
  BestT := TalkDistance;
  for A in FActors do
  begin
    if (A.Monster <> nil) or not A.Thinking or not A.Model.Holder.Exists or (A.TalkState <> 2) then
      Continue;
    ToActor := A.Model.Holder.Translation + Vector3(0, 48, 0) - Origin;
    T := TVector3.DotProduct(ToActor, Dir.Normalize);
    if (T > 0) and (T < BestT) and ((ToActor - Dir.Normalize * T).Length < 32) then
    begin
      Best := A;
      BestT := T;
    end;
  end;
  if Best <> nil then
  begin
    { idAI::TalkTo: its script sees AI_TALK }
    Best.TalkTarget := PlayerHandle;
    Best.SetFlag('AI_TALK', 1);
    WritelnLog('Doom3World', 'Talking to %s', [Best.Model.Entity.Name]);
    Exit;
  end;
  Ray := TBox3D.Empty;
  Ray.Include(Origin);
  Ray.Include(Origin + Dir.Normalize * 96);
  for Mover in FMovers do
    if (Mover.Kind = mkDoor) and Mover.Brush.Scene.WorldBoundingBox.Collision(Ray) then
    begin
      if Mover.Locked then
        Message('Locked')
      else
        Mover.Open;
    end;
end;

procedure TD3Game.DamagePlayer(const Amount: Integer);
begin
  DamagePlayer(Amount, '', TVector3.Zero);
end;

procedure TD3Game.PlayerSound(const Key: String);
begin
  if (FPlayerDef = nil) or (FPlayerDef.Values[Key] = '') then
    Exit;
  LastPlayerSound := Key;
  WritelnLog('Doom3World', 'Player sound %s (%s)', [Key, FPlayerDef.Values[Key]]);
  PlaySoundAt(FPlayerDef.Values[Key], FPlayerEye);
end;

procedure TD3Game.DamagePlayer(const Amount: Integer; const DamageDefName: String;
  const Direction: TVector3);
const
  { idPlayerView's IMPULSE_DELAY: hits closer than this make no new
    effects (the shotgun's pellets) }
  ImpulseDelay = 0.15;
var
  Absorbed, I: Integer;
  Def: TStringList;
  Axis: TMatrix3;
  Local, D: TVector3;
  KickTime, Amp, BlobTime, Scale, DvTime, Knockback: Single;
  Blob: TD3ScreenBlob;
begin
  if God or PlayerDead then
    Exit;
  Def := nil;
  if DamageDefName <> '' then
    Def := Decls.EntityDef(DamageDefName);
  { Doom 3 armor absorbs 1/3 of the damage }
  Absorbed := Min(Armor, Amount div 3);
  Dec(Armor, Absorbed);
  if (Absorbed > 0) and (FTime > FLastArmorPulse + 0.2) then
    PlayerSound('snd_hitArmor');
  if Absorbed > 0 then
    FLastArmorPulse := FTime;

  { idPlayerView::DamageImpulse }
  if (Def <> nil) and (FTime >= FLastDamageTime + ImpulseDelay) then
  begin
    { the head kick: forward / back and up / down pitch, sideways yaws
      (half) and rolls; the direction in the player's (yaw only) axes }
    KickTime := StrToFloatDef(Def.Values['kick_time'], 0, DefaultFormatSettings);
    if KickTime > 0 then
    begin
      FKickFinish := FTime + KickTime / 1000;
      Local := TVector3.Zero;
      if not Direction.IsZero then
      begin
        D := CgeToD3(Direction).Normalize;
        Axis := AnglesMatrix(Vector3(0, D3DirYaw(CgeToD3(PlayerViewDir)), 0));
        Local := Vector3(
          TVector3.DotProduct(D, Vector3(Axis.Data[0, 0], Axis.Data[0, 1], Axis.Data[0, 2])),
          TVector3.DotProduct(D, Vector3(Axis.Data[1, 0], Axis.Data[1, 1], Axis.Data[1, 2])),
          TVector3.DotProduct(D, Vector3(Axis.Data[2, 0], Axis.Data[2, 1], Axis.Data[2, 2])));
      end;
      FKickAngles := Vector3(Local.X + Local.Z, Local.Y * 0.5, Local.Y);
      Amp := StrToFloatDef(Def.Values['kick_amplitude'], 0, DefaultFormatSettings);
      if Amp <> 0 then
        FKickAngles := FKickAngles * Amp;
    end;
    { double vision: dv_time (ms) adds up, to 5 s ahead at most }
    DvTime := StrToFloatDef(Def.Values['dv_time'], 0, DefaultFormatSettings);
    if DvTime > 0 then
    begin
      if FDvFinish < FTime then
        FDvFinish := FTime;
      FDvFinish := Min(FDvFinish + DvTime / 1000, FTime + 5);
    end;
    { a screen blob }
    BlobTime := StrToFloatDef(Def.Values['blob_time'], 0, DefaultFormatSettings);
    if (BlobTime > 0) and (Def.Values['mtr_blob'] <> '') then
    begin
      Blob.Material := Def.Values['mtr_blob'];
      Blob.X := StrToFloatDef(Def.Values['blob_x'], 0, DefaultFormatSettings) + Random(64) - 32;
      Blob.Y := StrToFloatDef(Def.Values['blob_y'], 0, DefaultFormatSettings) + Random(64) - 32;
      Scale := (256 + Random(64) - 32) / 256;
      Blob.W := StrToFloatDef(Def.Values['blob_width'], 0, DefaultFormatSettings) * Scale;
      Blob.H := StrToFloatDef(Def.Values['blob_height'], 0, DefaultFormatSettings) * Scale;
      Blob.Start := FTime;
      Blob.Finish := FTime + BlobTime / 1000;
      { idPlayerView has 8 blobs, the oldest is reused }
      for I := High(FBlobs) downto 0 do
        if FBlobs[I].Finish <= FTime then
          Delete(FBlobs, I, 1);
      if Length(FBlobs) >= 8 then
        Delete(FBlobs, 0, 1);
      FBlobs := Concat(FBlobs, [Blob]);
    end;
  end;
  if FTime >= FLastDamageTime + ImpulseDelay then
    FLastDamageTime := FTime;

  { knockback (idPlayer::Damage): the def's "knockback" (20 by default)
    pushes along the force, g_knockback 1000 * knockback / 200 units a
    second; only sideways here (the camera's height is navigation's) }
  if not Direction.IsZero then
  begin
    Knockback := 20;
    if Def <> nil then
      Knockback := StrToFloatDef(Def.Values['knockback'], 20, DefaultFormatSettings);
    D := CgeToD3(Direction);
    D.Z := 0;
    if (Knockback <> 0) and not D.IsZero then
      FKnockVel := FKnockVel + D.Normalize * (1000 * Knockback / 200);
  end;

  Dec(Health, Amount - Absorbed);
  if Health <= 0 then
  begin
    Health := 0;
    FDeadTime := 0;
    PlayerSound('snd_death');
    Message('You died');
    Exit;
  end;
  { idActor::Pain: a cry by how much health is left, pain_delay apart }
  if FTime >= FPainDebounce then
  begin
    if Health > 75 then
      PlayerSound('snd_pain_small')
    else
    if Health > 50 then
      PlayerSound('snd_pain_medium')
    else
    if Health > 25 then
      PlayerSound('snd_pain_large')
    else
      PlayerSound('snd_pain_huge');
    FPainDebounce := FTime + 0.5;
    if FPlayerDef <> nil then
      FPainDebounce := FTime + StrToFloatDef(FPlayerDef.Values['pain_delay'], 0.5, DefaultFormatSettings);
  end;
end;

class function TD3Game.FallSpeed(const Seconds: Single): Single;
const
  Gravity = 1066;
  FallSpeedMin = 120;
begin
  Result := Max(FallSpeedMin, Gravity * Seconds);
end;

function TD3Game.ScreenBlobs: specialize TArray<TD3ScreenBlob>;
var
  B: TD3ScreenBlob;
begin
  Result := nil;
  for B in FBlobs do
    if B.Finish > FTime then
      Result := Concat(Result, [B]);
end;

function TD3Game.SinceDamage: Single;
begin
  Result := FTime - FLastDamageTime;
end;

function TD3Game.DoubleVisionShift: Single;
var
  Offset, Scale: Single;
begin
  { idPlayerView::DoubleVision with g_dvAmplitude 0.001, g_dvFrequency 0.5:
    the ms left times the amplitude (half the screen at most), wobbling }
  Result := 0;
  if PlayerDead or (FTime >= FDvFinish) then
    Exit;
  Offset := (FDvFinish - FTime) * 1000;
  Scale := Min(0.5, Offset * 0.001);
  Result := Abs(Scale * Sin(Sqrt(Offset) * 0.5));
end;

function TD3Game.ArmorPulse: Single;
var
  T: Single;
begin
  T := (FTime - FLastArmorPulse) / 0.25;
  if (T >= 0) and (T < 1) then
    Result := 1 - T
  else
    Result := 0;
end;

function TD3Game.KnockbackMove(const SecondsPassed: Single): TVector3;
const
  { pm_friction, pm_stopspeed }
  Friction = 6;
  StopSpeed = 100;
var
  Speed, NewSpeed, Left, Dt: Single;
begin
  Result := TVector3.Zero;
  Speed := FKnockVel.Length;
  if (Speed < 0.5) or (SecondsPassed <= 0) then
  begin
    FKnockVel := TVector3.Zero;
    Exit;
  end;
  { idPhysics_Player::Friction, in Doom 3's 60 Hz steps (a long frame
    would stop it at once, or overshoot) }
  Left := SecondsPassed;
  while (Left > 0) and not FKnockVel.IsZero do
  begin
    Dt := Min(Left, 1 / 60);
    Left := Left - Dt;
    Result := Result + D3ToCge(FKnockVel * Dt);
    Speed := FKnockVel.Length;
    NewSpeed := Max(0, Speed - Max(Speed, StopSpeed) * Friction * Dt);
    if NewSpeed < 0.5 then
      FKnockVel := TVector3.Zero
    else
      FKnockVel := FKnockVel * (NewSpeed / Speed);
  end;
end;

function TD3Game.PlayerDead: Boolean;
begin
  Result := Health <= 0;
end;

initialization
  ScriptedMonsterObjects := ['monster_zombie', 'monster_zombie_bernie', 'monster_zombie_security_pistol',
    'monster_demon_imp', 'monster_test',
    { the full game's walking monsters (not in the demo, so not checked
      against their scripts): their projectiles, held missiles, charges
      and melee events are done }
    'monster_demon_hellknight', 'monster_demon_mancubus', 'monster_demon_revenant',
    'monster_demon_maggot', 'monster_demon_pinky', 'monster_demon_trite', 'monster_demon_tick',
    'monster_demon_cherub', 'monster_demon_wraith', 'monster_demon_archvile',
    'monster_zombie_commando', 'monster_zombie_commando_cgun',
    { flying monsters (setMoveType( MOVETYPE_FLY ) in their scripts) and
      bosses, unchecked too }
    'monster_flying_cacodemon', 'monster_flying_lostsoul',
    'monster_boss_cyberdemon', 'monster_boss_guardian', 'monster_boss_guardian_seeker',
    'monster_boss_sabaoth', 'monster_boss_vagary'];
finalization
  FreeAndNil(LangStrings);
end.
