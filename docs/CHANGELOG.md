# Changelog

## Unreleased

- **Characters' AI scripts** (roadmap 5d, first part): Mars City's people (33 in Mars City 1) run their `character` script objects: state functions, animation states per channel, path commands (`path_corner`, `path_anim`, `path_cycleanim`...), walking and turning; they sit, work at computers, drink, read PDAs and walk their rounds. Console `actors`.
- Script VM: persistent threads restarted with another function, `callFunction` / `hasFunction`, `sys.warning` / `sys.error`.
- Test level: `test_walker_1` walks to its `path_corner` when the trigger's script activates it; 431 checks; CI checks it.
- Scripts: `setGuiParm` redraws the entity's GUI screens with the new parameter (Mars City Underground's airlock, crane and bridge panels); `startSpline` moves a mover along a `func_splinemover` curve (Mars City's mouse). Roadmap 5c is done.
- Test level: `bar_1` follows `spline_1`, the trigger's script writes on room A's panel; 420 checks.
- **Animated models** (roadmap 5c): `idAnimated` entities (Mars City's ships and hangar, props) hold the first frame of their `anim`, play it when activated (`cycle`, `num_anims`, `auto_advance`, `wait`, `remove`) and fire their targets at the end; cinematic characters appear and play their `anim`; md5 characters and monsters get their heads (`def_head` at `head_joint`; 52 in Mars City 1).
- Test level: the cinematic shows an idAnimated blob with a head, which walks twice, switches `light_5` and goes; 413 checks.
- **Cinematics** (roadmap 5c): camera anims (`.md5camera`, `Doom3Camera`) with cuts and the `old_origin` offset take over the view and fire their targets at the end; `func_cameraview`; `trigger_fade` and the scripts' screen fades; `info_player_teleport`; _Escape_ / `skipcinematic` skips a cinematic and the shots it chains to. Mars City 1's intro plays its cameras (checked against dhewm3: the first one looks at the console screen).
- Scripts: lights fade in and out over time, `startSoundShader` / `startSound` / `stopSound` play sounds on entities.
- Test level: `trigger_once_cin` fades out, plays a two-shot camera and teleports the player; the lift plays a sound, `light_trig` fades out; 404 checks; CI runs the cinematic.
- **Scripts** (roadmap 5c): a compiler and virtual machine for Doom 3's script language (`Doom3Script`). The demo's whole program (`script/doom_main.script`, 80 files, 1713 functions) compiles in about 0.2 s; the map's `main`, worldspawn's and triggers' `call` keys run as script threads that wait for time, frames, movers and other threads. Events: triggering, lights on / off and colors, doors (open, close, lock), hide / show / remove, entity keys and targets, `bind` / `unbind`, and idMover's moves and rotations with acceleration, so Mars City Underground's machines (cranes, arms, howitzers, pistons) move. Unsupported events are logged once.
- Console: `scripts` (threads, moving entities), `g_stopTime` (freeze them).
- Test level: `maps/testmap.script` moves `lift_1` up and down, turns `bar_1`, and `trigger_once_1` calls a script function; 376 checks.
- **Movers** (roadmap 5b): entities get their entityDef's keys as defaults; doors travel the size of their rotated bounds (most retail doors are rotated) with Doom 3's defaults (speed 100, `triggersize` 60); door `team`s open, close and lock together; `target_lock`; `func_rotating` honors `start_on` and is toggled by activation; `bind` makes brush entities and models follow their parent.
- Test level: `door_2` in `door_1`'s team, `door_light_1` bound to `door_1`; 330 checks.
- **Triggers and entity activation** (roadmap 5a): `trigger_once` / `trigger_multiple` / `trigger_hurt` volumes (from the `.cm`) touched by the player, `trigger_relay` and `trigger_count`, `target` chains with `delay` / `wait` / `triggerFirst` / `noTouch`: lights switch on / off, speakers start / stop, hidden entities and monsters appear, dormant monsters wake, doors unlock or open, `func_remove` removes. Unsupported activations are logged once.
- Test level: `trigger_once_1` in room B fires `trigger_relay_1`, which switches the red `light_trig` on 0.5 s later; 311 checks (a `TD3Game` stepped on the test map), CI walks into it.
- **Doom 3 demo data**: a `demo/` directory (`demo00.pk4` of the free 2004 demo) is loaded like `base/`, next to the exe or under `-basepath`. Its three maps (`game/demo_mars_city1`, `game/demo_mc_underground`, `game/demo_mars_city2`) load and spawn everything, without exceptions; they are dark and slow so far.
- Lights and entities belong to all areas their bounds touch, through the `.proc` BSP (`TD3ProcFile.BoxAreas`), not only the area of their origin: retail lights sit inside their fixtures.
- Monsters honor `hide` (hidden until triggered), `trigger` (dormant until triggered or hurt) and the skill flags `not_easy` / `not_medium` / `not_hard` (medium, Doom 3's default): no more invisible monsters attacking at the start of `demo_mc_underground`.
- `textures/common/entitygui` / `entitygui2` / `entitygui3` without a material (the demo data) are the entity's GUI screens.
- Console commands `lightsat`, `ent <name>`, `guidump <file.gui>` for debugging retail maps.
- `tools/smoke_maps.ps1`: loads maps one by one from a Doom 3 install or the demo and reports load time, map statistics, warnings and exceptions, with logs and screenshots.

## 0.12.0

Shadows from big md5 models.

- **md5 shadow hulls**: md5 meshes over 1500 triangles (retail monsters) used not to cast at all, because CGE searches silhouette edges quadratically and again on every animation frame. They now cast with one closed box per joint, around the vertexes the joint moves, shrunk to stay inside the body and moved by a per-joint matrix transform, so their edges never change.
- Console `r_md5ShadowTris <n>`: the triangle limit (reloads the map; 0 makes every md5 model cast with boxes).
- Shots log which monster they hit.
- 296 checks (joint matrices match skinning, boxes are closed and face out, box counts); CI checks the boxes are built.

Still one shadow casting light: more need shadow volume or cube shadow map support for several point lights in CGE (roadmap item 2).

## 0.11.0

More material stages.

- **Every plain stage is drawn**: stages after the first one (and the first plain stage of lit materials) are overlays, copies of the surface a little in front of it with their own unlit, blended appearance, texture matrix and animated color. Glowing strips on lit walls and doors now show.
- **`deform sprite`**: each quad becomes a camera facing billboard of the same size.
- **Glass**: materials whose only stages are reflections, heat haze, mirrors or videos are drawn as a faint additive tint instead of disappearing.
- A `cubeMap` is a sky only with `texgen skybox` / `wobblesky` (glass reflects cube maps too).
- Test level: the door has pulsing glow strips over its lit metal, a glass pane and a flare in room A.
- 289 checks (extra stages, overlays, glass, sprites); CI checks the stage counts in the log.

## 0.10.0

More shadows.

- **Walls and pillars cast shadows**: the level's `.cm` brushes (solid / opaque contents) are rebuilt as closed convex shadow casters 1 unit inside the walls (the render geometry of areas is open and can't cast). They also stop the shadow light from shining through walls. Grouped per area, enabled for visible areas and the areas the shadow light reaches.
- **`noshadows`**: materials with it don't cast (X3D `shadowCaster`), lights or light shaders with it are never the shadow casting light.
- Test level: solid brushes for walls, floors, ceilings, pillars and the balcony in its `.cm`.
- 269 checks (brush polyhedra are closed, insets, casters of the test level, `noshadows`); CI checks the casters are built.

Still one shadow casting light at a time (CGE's shadow volumes).

## 0.9.0

GUIs.

- **Doom 3 GUIs** (`.gui`) on `guisurf` surfaces: windowDef trees with `rect`, `backcolor`, `matcolor`, `background`, borders, `text` (also `gui::` state from the entity's `gui_*` keys, `\n` line breaks), `textscale`, `textalign`, `forecolor`, `visible`, drawn in software into a 640 x 480 image with CGE's built-in font and shown on the surface. `guisurf entity` / `entity2` / `entity3` use the entity's `gui` / `gui2` / `gui3` keys, `guisurf <path>` names the GUI.
- Brush entities and static models (LWO / ASE screens) pass their entity to their GUI surfaces.
- Test level: a door panel GUI with the entity's text and a status screen.
- 257 checks (parsing, rendered pixels, state, caching); CI checks both GUIs are rendered.

Not yet: GUI events and scripts, the cursor, Doom 3's own fonts.

## 0.8.0

Material stages.

- **Texture matrices**: `scroll` / `translate`, `scale`, `centerScale`, `shear` and `rotate` with expressions, composed like Doom 3's `MultiplyTextureMatrix`, as CGE `TextureTransformMatrix3D` nodes: scrolling screens, moving fluids, rotating fans.
- **Animated surface colors**: `rgb` / `red` / ... / `alpha` registers on glow and blend stages (pulsing panels, fading decals), updated every frame.
- **Skies**: `cameraCubeMap` / `cubeMap` sky materials become a CGE skybox (`TCastleBackground`); the sky surfaces themselves aren't drawn.
- Test level: scrolling terminal screens, pulsing ceiling panels, a skylight in room B.
- 231 checks (texture matrices, stage parsing, skies); CI checks the sky is set up.

## 0.7.0

Shadows.

- **Stencil shadows** with CGE's shadow volumes: every frame the strongest light at the player (lights in the player's area first, ambient lights never) casts shadows of brush entities (doors, crates, movers), static models and md5 models (up to 1500 triangles). Area geometry receives shadows.
- Console `r_shadows [0|1]`; screenshot log lines name the shadow casting light.
- 213 checks; CI checks the shadow light is chosen.

Known limitation: one shadow casting light at a time (CGE's shadow volumes), and walls don't cast shadows.

## 0.6.0

Light volumes.

- **Doom 3 light volumes**: lights don't fade with distance any more; like Doom 3 each lights a box (point lights, `light_radius`, `rotation`) or a frustum (projected lights, `light_target` / `light_right` / `light_up`, `light_start` / `light_end`), mapped to the light's texture space like `lightProject`, shaped by projection and falloff curves. Implemented as a per-light CGE shader effect (`PLUG_light_scale`) reading the fragment's world position.
- Lights without a `texture` use Doom 3's `lights/defaultPointLight` / `lights/defaultProjectedLight` when the game data declares them.
- `shaderParm4` is the light shader's time offset, like Doom 3.
- Console `r_lightVolumes [0|1]` reloads the map with plain spherical lights for comparison.
- **Fixed**: a shut door was hidden by portal visibility when seen from the room on its other side (it now belongs to the areas on both sides of its portal).
- Test level: a projected window light, Doom 3-style default light shaders and light images.
- 210 checks (light texture space, projected lights, shapes).

Known limitation: projection and falloff images are approximated by analytic shapes chosen from the image name (CGE doesn't bind textures referenced only by light effects).

## 0.5.0

Light shaders.

- **Material expressions and tables** (`Doom3Expressions`): `time`, `parm0-11`, `global0-7`, `table[...]` lookups (`snap`, `clamp`, wrapping and interpolation like Doom 3), arithmetic, comparisons, `&&` / `||`, with Doom 3's operator priorities.
- **Animated lights**: light shaders' color registers (`red`, `green`, `blue`, `rgb`, `rgba`, `color`, `colored`) are evaluated every frame with the light's `_color` and `shaderParm`s, so strobes, flickers and pulses work. A declared shader without color registers is white, an undeclared one uses `_color`, like Doom 3.
- Console `lights` lists every light's current color.
- Test level: a flickering (snap table), a pulsing (sine table) and a strobing light.
- 193 checks (expressions, tables, light shaders); CI checks that the pulsing light changes.

## 0.4.0

Portal visibility.

- **Portal visibility** like Doom 3's renderer: from the camera's area through the inter-area portals, each portal clipped by the view volume and narrowing it. Areas (now one scene each), brush entities, static and md5 models of hidden areas aren't drawn.
- **Doors close portals** while they are shut, so nothing behind a closed door is drawn.
- **Lights** are switched off while none of the areas they reach is visible (a flood through the portals within the light's radius).
- Console: `r_usePortals [0|1]`, `portals`; screenshot log lines show the visible areas. `TDoom3Map.PortalCulling`.
- Fixed: `notarget` didn't stop a monster that was already attacking.
- 162 parser and visibility checks; CI checks the visible areas through the door.

## 0.3.0

Static models and collision models.

- **Collision models (`.cm`)**: maps collide with Doom 3's collision geometry, including its invisible `playerclip` brushes, instead of the render geometry. Material contents follow Doom 3's surface parameters (`playerclip`, `monsterclip`, `nonsolid`, `water`, `trigger`...). `TDoom3Map.UseCollisionModel` (default on).
- **Static models**: LightWave `.lwo` (LWO2) and 3ds Max `.ase` loaders for `func_static`, props, light fixtures, items and LWO doors, with skins; `func_*` models collide unless `noclipmodel`.
- **Fixed**: every rotated entity (brush entities, static models, creatures) faced backwards. CGE's default `TCastleTransform` orientation points along local +Z; `SetD3Rotation` now orients them.
- Test level: LWO barrels, ASE terminals with glowing screens, a `.cm` with an invisible clip wall and a monster clip strip.
- 147 parser checks (from 102); CI checks that static and collision models load.

## 0.1.0

First version: PK4 file system, declarations, materials with diffuse / normal / specular maps and image programs, `.proc` / `.map` levels, lights, md5 models, doors, speakers, simple monsters, pistol, flashlight, HUD, console, menu, the `TDoom3Map` editor component, autotest harness, unit tests and CI.
