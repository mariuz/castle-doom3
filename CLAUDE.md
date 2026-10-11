# CLAUDE.md

Working notes for developers and AI agents on Castle Doom 3: a Doom 3 (id Tech 4) port to Castle Game Engine (CGE) in Object Pascal (FPC). Sibling of `castle-quake1`, `castle-quake2` and `castle-doom`. Read `docs/ARCHITECTURE.md` for how the code works.

## What this is

- Doom 3 data (`.proc`, `.map`, `.mtr`, `.def`, `.skin`, `.sndshd`, `.md5mesh`, `.md5anim`, `.lwo`, `.ase`, `.cm`, TGA / DDS images, WAV / OGG sounds) is read at runtime from PK4 archives and served to CGE through the `d3fs:` and `d3img:` URL protocols.
- Bundled data is only the generated test level `data/base/castle_doom3_test.pk4` (map `testmap`), written by `tools/make_test_pk4.py`. **Never commit id Software data**; a Doom 3 install is loaded with `-basepath` or a `base/` directory next to the exe (gitignored).
- Debugging retail maps (console, or `O:` in demo scripts): `lightsat` logs the lights reaching the player (strength at the floor and eye, Doom 3 texture coordinates, on/off), `ent <name>` the state of a brush entity or static model (exists, visible, areas, box), `guidump <file.gui>` renders a GUI to `<screenshot prefix>_gui.png`.
- Reference renders: dhewm3 1.5.5 (Windows build) is in `E:\Work\dhewm3\dhewm3\` (outside the repo). Run it on the demo with `+set fs_basepath E:\Work\doom3-demo +set fs_savepath <dir> +set r_mode -1 +set r_customWidth 1600 +set r_customHeight 900 +set r_screenshotFormat 2 +map <map> +exec refshots.cfg`, where `E:\Work\doom3-demo\demo\refshots.cfg` is a console script (`wait <frames>`, `setviewpos x y eyeZ yaw` puts the *eye* there, `screenshot`, `quit`); screenshots land in `<dir>\demo\screenshots`. Mars City 1 starts with a cinematic of several minutes (no console skip): compare in `game/demo_mc_underground` (the elevator at (3848, -1216), eye 299). Compare brightness with mean luma of the same view; port and dhewm3 are within ~5% there.
- Frame rates on this machine vary a lot between runs when other programs use the GPU (the same view measured 10 and 58 FPS): compare settings within one run (`O:r_shadows 0` etc.), not across runs. The first frames that show new shapes / light sets compile shaders (NVIDIA caches them on disk, so later runs are faster).
- Retail data on this machine: the free **Doom 3 demo** in `E:\Work\doom3-demo\demo\demo00.pk4` (outside the repo; `-basepath E:\Work\doom3-demo`). Maps `game/demo_mars_city1`, `game/demo_mc_underground`, `game/demo_mars_city2` each load in about a minute; `tools/smoke_maps.ps1 -BasePath E:\Work\doom3-demo` loads all three and reports time, map statistics, warnings and exceptions (logs and screenshots in `smoke_output/`, gitignored).
- Units: `Doom3Files`, `Doom3Lexer`, `Doom3Script`, `Doom3Camera`, `Doom3Decls`, `Doom3Images`, `Doom3Materials`, `Doom3Proc`, `Doom3MapFile`, `Doom3Md5`, `Doom3StaticModels`, `Doom3Collision`, `Doom3Portals`, `Doom3Expressions`, `Doom3LightEffects`, `Doom3Gui`, `Doom3Level` (`TDoom3Map`), `Doom3World` (`TD3Game`), `Doom3Hud`, `Doom3Console`, `Game*` views.

## Build and run (Windows)

CGE 7.0-alpha.3 snapshot with bundled FPC 3.2.2 is installed at `C:\castle-engine` (not on PATH):

```powershell
$env:PATH = "C:\castle-engine\bin;C:\castle-engine\tools\contrib\fpc\bin;" + $env:PATH
castle-engine compile --mode=release      # or --mode=debug
.\castle-doom3.exe
```

Keep the project at a short path (`E:\Work\castle-doom3`): long paths break FPC builds. Audio needs `OpenAL32.dll` next to the exe (gitignored). The log goes to `%LOCALAPPDATA%\castle-doom3\castle-doom3.log`.

## Testing without watching the window

```powershell
.\castle-doom3.exe --autotest testmap C:\TMP\cd3\s --demo "W:2,S,G:200 0 0,A:0,W:2,S,G:420 -250 0,A:20,F,W:0.4,S,N:0,Y,X,W:0.4,X,S,Q"
.\castle-doom3.exe --autotest MENU C:\TMP\cd3\s
```

Pass the whole `--demo` value as one argument (from PowerShell `Start-Process`, quote it inside `-ArgumentList`, or the spaces in `G:x y z` split it). Script commands are listed in the README; grep the log for `Warning|Exception|Screenshot|Message|Shot:`. Screenshot log lines show the FPS, eye position (Doom 3 coordinates), yaw, area and visible areas (portal visibility: 1 in room A with the door shut, 2 at (200, 0) yaw 0 once the door opened, 1 from there at yaw 180). Useful test map spots: start (-160, -160) yaw 45; LWO barrels at (-60, 190) and (-12, 206); ASE terminals at (200, 200) (`noclipmodel`, faces yaw -135) and on the balcony (820, -280, 96) (see its screen from (740, -200, 96) yaw -45); in front of the door (200, 0) yaw 0 (it opens within ~1 s); the invisible playerclip wall is y = 0 for x < -120 (from (-200, -100) yaw 90, `GO:1 0 1.5` stops at y = -20.7); the monster clip strip at x = -40 lets the player through; climbing to the balcony: `G:560 0 0,A:0,GO:1 0 2.5` ends with eye z 163.5; room B (420, -250); creatures are monsters 0 and 1 (`N:0`). `blob_1` has 80 health, the pistol does 14 per shot every 0.35 s (6 hits kill it).

Unit tests: `cd tests; castle-engine compile; .\castle-doom3-tests.exe` (413 checks; run from `tests/`). When the generator changes, update the expected counts there.

## CGE editor integration

- `editor_units="Doom3Level, Doom3Hud, Doom3Console"`; these call `RegisterSerializableComponent`. Children created by a component must call `SetTransient`.
- `TDoom3Map` builds the map in the editor (`Loaded` + `CastleDesignMode`); in the game `TViewPlay` calls `LoadMap`. Keep it at identity transform: gameplay uses its local space as world space. `TDoom3Map.EnsureData` adds the test PK4 and loads decls when the editor runs without `GameInitialize`.
- Light shaders: console `lights` logs every light's current color (`Lights:` lines); in the test map `light_2` flickers (room A), `light_4` pulses and `light_5` strobes (room B). Lights in hidden areas are off and don't animate.
- GUIs: the panel is on room A's west wall (look from (-150, -60) yaw 180 `P:10`), the status screen on room B's north wall (from (385, 200) yaw 90 `P:22`). The log says `Doom3Gui: Rendered "guis/..." (N windows)`. GUI rendering is software (no GL), so `tests/` checks pixels.
- More stages: the log says `Material stages: 1 overlays, 1 sprites, 1 glass surfaces` for the test level. The door's orange glow strips (an overlay) show from (120, 0) yaw 0; the flare billboard under light_1 from (-150, 0) yaw 0 `P:25`; the glass pane at y = -220 from (10, -120) yaw -90. `tests/` fails if a `rgb` line in an inline material body isn't followed by a newline (`RestOfLine`).
- Material stages: the terminal screens scroll and the ceiling panels pulse (two screenshots a second apart from (740, -200, 96) yaw -45 differ); room B's skylight is at (640, 0), look up from (640, -150) with `P:45`. The log says `Sky "textures/test/sky"` when the skybox is set up.
- Shadow casting brushes: the log says `Shadow casters: N brushes` (20 in the test level). A caster shape with any open edge is silently skipped by CGE: `tests/` checks every brush polyhedron is closed. The room A pillar's shadow from light_1 shows on the north-west corner from (-230, 20) yaw 80.
- md5 shadow hulls: `O:r_md5ShadowTris 0` (reloads the map) makes the test blob cast with its 6 joint boxes; the log says `Shadow hulls: "models/md5/test/blob.md5mesh" has 72 triangles, casts with 6 joint boxes`. Compare shadows by diffing `r_shadows 1` / `0` screenshots of the same view (creatures move between map reloads; use `notarget`).
- Triggers: in the test map, walking to (330, 0) fires `trigger_once_1` (log `Trigger trigger_once_1 fired`), whose `trigger_relay_1` switches the red `light_trig` in room B's north-east corner on 0.5 s later (`Light light_trig on`; see it from (700, 200, 96) yaw 30). Unsupported activations and `call` keys are logged once as `Not supported yet: ...`. `tests/` steps a `TD3Game` on `testmap` (the map must be in a `TCastleRootTransform`: speakers' sound sources need a world).
- Movers: `door_1` and `door_2` (a bar above the doorway on room B's side, rotated 90 degrees, slides +x by 40) are team `tunnel`; the glowing `door_light_1` is bound to `door_1` and rides up with it (see it from (150, 60) yaw -20 `P:10`). The spawn log line ends with `N bound entities` (95 in `demo_mc_underground`).
- Scripts: the test PK4 has `script/doom_main.script` (its own small set of `scriptEvent`s and defines) and `maps/testmap.script`: `lift_1` in room B at (380, 300) goes up 64 and down every few seconds (watch it from (300, 240) yaw 30), `bar_1` at (600, -300, 150) turns from east to north in the first second, and `trigger_once_1`'s `call` key runs `test_trigger_called`, which makes `light_trig` green. Script prints are logged as `Script: ...`. Console: `scripts` logs threads and moving entities, `g_stopTime [0|1]` freezes them. The demo's whole program (1713 functions, 80 files) compiles in ~0.2 s; `demo_mc_underground` runs ~19 threads moving ~60 entities. Compare script movers with dhewm3 on poses that stay still (the crane after its 80 degree turn: `setviewpos 2920 -1250 700 -90`).
- Cinematics: in the test map, walking to (340, -340) (room B's south-west corner) fades to black (0.3 s), plays the camera `test_cam_1` (`models/md5/cameras/test_flyby.md5camera`: a dolly looking north, a cut, a shot from the balcony at the door; about 3 s) while fading in, then teleports the player to (500, 200) yaw 180. The relay also shows the idAnimated `animated_blob_1` at (650, 150) (seen in the balcony shot), with a second blob as its `def_head` on the `head` joint; it walks twice, switches `light_5` and is removed. Screenshot log lines end with `cinematic <camera>` during one. Console `skipcinematic` (or _Escape_) skips. Mars City 1 starts with ~3 minutes of cameras (`marscity_cinematic_cam_2`, the window, then the hangar shots); `skipcinematic` early in a demo script gets to the game. When comparing camera views with dhewm3, remember that dhewm3's `wait` counts frames, and that many shots hold still for a long time (the window shot for 28 s).
- Shadows: screenshot log lines end with `shadows <light name>`; `r_shadows 0` compares. A good view of the crate shadow: `G:250 -40 0,A:-125,P:-30` (light_1). Only one light casts (CGE's shadow volumes); areas don't cast.
- Light volumes (`Doom3LightEffects`): every scene built for the map must call `AddLightLibrary` on its root, or map lights add nothing to it (black). Samplers in light effects don't work in CGE (unbound textures): light images are analytic. `r_lightVolumes 0` compares with plain spheres. A brush entity that looks black or missing is more likely hidden by portal visibility (check its `Areas`) than unlit.
- Don't `git checkout -- <file>` to undo a scripted edit while other uncommitted work is in that file; keep `.bak` copies.
- FPC objfpc: inside a parameterless function, its bare name means its **result variable**; call it recursively as `ParseTerm()`.
- There is no single world scene: areas are `AreaScene(i)` / `AreaNonSolidScene(i)`, lights are `LightScene`. For world queries use the root, `Map.World.WorldRayCast` / `WorldSegmentCollision` (`TCastleTransform.World`).
- With a `.cm`, the area scenes don't collide (`WorldCollision` does) but stay pickable: shots / ray casts use `Pickable`, player and segment collisions use `Collides`.
- Portal visibility hides scenes with `Visible := False` (they still collide). `TViewPlay.Update` calls `Map.UpdateVisibility(Camera)`; the editor never does, so it draws everything.
- Call `TD3Game.Clear` before `TDoom3Map.LoadMap` (movers and speakers reference the map's scenes).

## Conventions and pitfalls

- 2-space indent, `begin` / `end` on their own lines, PascalCase, no `with`.
- Coordinates: `D3ToCge(v) = (v.x, v.z, -v.y)`; Doom 3 front faces are clockwise → `Ccw := False`; `v = 1 - t`; normal maps get their green flipped (see ARCHITECTURE.md).
- Pascal `{ }` comments end at the first `}`: don't write braces inside them (use words or `//`).
- Orient transforms with `SetD3Rotation`, never `SetView(..., -Z ...)` by hand: CGE's default `TCastleTransform.Orientation` is `otUpYDirectionZ` (direction = local +Z). Symmetric test models hide a 180° error; the terminal's screen and `TestEntityRotation` catch it.
- The bash tool mangles backslashes in heredocs (a backslash before `t` becomes a tab): write Windows paths into Pascal sources with the file editor or a script file.
- Locals named like `TCastleTransform` properties (`Center`, `Up`, `Direction`, `World`...) clash inside `TDoom3Map` methods.
- `TCastleSoundSource` lives in `CastleBehaviors`; `Container.Pressed.KeyUp` has an `out` key string.
- CGE cuts a light off hard at its `Radius`; keep attenuation low there (see `BuildLights`).
- One X3D node must not be in two scenes: `MaterialAppearance` creates fresh nodes each call, textures are shared by URL.
- Doom 3 decls: the first definition wins; names are lowercase with `/`. `ReadImageProgram` normalizes programs without spaces (they are also the `d3img:` URL paths).
