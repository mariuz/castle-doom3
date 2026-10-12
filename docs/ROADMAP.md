# Doom 3 comparison and roadmap

Status of version 0.12.0 plus the unreleased changes in `docs/CHANGELOG.md`. "Done" items are tested against the bundled test level, and since the unreleased changes also against the free Doom 3 demo's three maps (item 1); the full game's maps are not tested yet.

**Priority**: item 1 now depends mostly on item 5 (triggers and scripts switch the lights on and show the monsters of retail maps), then on the shader compile stalls of item 1. Items 2, 3 and 10 wait for CGE changes (A to J below), most of them proposed as pull requests.

## Done

- PK4 / loose-file virtual file system with override order, `-basepath`, `-game`, `-pk4`.
- Declarations: materials, entityDefs (with `inherit`), model decls (`mesh`, `anim`, `offset`, `skin`, `inherit`, frame commands skipped), skins, sound shaders, tables (indexed).
- Materials: diffuse / bump / specular maps, stage forms, image programs `heightmap`, `addnormals`, others approximated by their source image; alpha test; translucent; two-sided; non-solid; additive / alpha / filter blended stages.
- `.proc` areas, brush models, portals and area BSP (`PointInArea`); `.map` entities.
- Point, projected (spot) and ambient lights with colour, `start_off`.
- md5mesh / md5anim with interpolated playback and skins.
- Static models: LWO2 and ASE (props, `func_static`, light fixtures, items, LWO doors), with skins, collision for `func_*` unless `noclipmodel`.
- Collision models (`.cm`): the world's player-blocking polygons (solid and `playerclip`) collide instead of the render geometry.
- GUIs: `.gui` windowDef trees rendered (software) onto `guisurf` surfaces with the entity's `gui_*` state.
- Material stages: texture matrices (`scroll`, `translate`, `scale`, `centerScale`, `shear`, `rotate`) and animated colors on surfaces; `cameraCubeMap` / `cubeMap` skies as a skybox; every plain stage drawn (overlays), `deform sprite` billboards, glass stand-ins.
- Stencil shadows (CGE shadow volumes) for the strongest light at the player, from brush entities, static models, md5 models (big ones through a box per joint) and the level's `.cm` brushes (walls, pillars); `noshadows` materials and lights.
- Light volumes: Doom 3's box / frustum lights without distance attenuation, `light_start` / `light_end`, projection and falloff shapes (analytic stand-ins for the images), `shaderParm4` time offsets.
- Light shaders: animated stage color registers with expressions and tables (strobes, flickers, pulses), `colored`, `shaderParm`s.
- Portal visibility: areas, entities, models and lights hidden when not visible through the portals; doors close portals.
- `func_door` (proximity trigger, `movedir`, `lip`, `speed`, `time`, `wait`, `locked`, `no_touch`, sounds), `func_static`, `func_rotating`.
- Speakers with looping and one-shot sound shaders.
- Player movement, flashlight, pistol, health / armor, death and restart; simple melee monsters.
- Editor component `TDoom3Map`, HUD, console, menu with the map list, autotest harness, parser unit tests, CI.
- Retail data (unreleased): the Doom 3 demo's `demo/` directory; lights and entities in all areas their bounds touch (BSP); monsters' `hide` / `trigger` / skill flags; undefined `textures/common/entitygui*` as GUI screens; `tools/smoke_maps.ps1`; debug console commands `lightsat`, `ent`, `guidump`.

## Next steps

1. **Load the retail maps** (`game/mars_city1`, `game/admin` ...) and fix what breaks. Started with the free Doom 3 demo data (see README): its three maps load without exceptions and spawn everything (`tools/smoke_maps.ps1` reports, per map):

    | Map | Areas | Triangles | Lights | Brush entities | Static models | md5 models | Monsters | Load + 2 screenshots |
    |---|---|---|---|---|---|---|---|---|
    | `game/demo_mars_city1` | 56 | 54,496 | 463 | 420 | 486 | 71 | 0 | 58 s |
    | `game/demo_mc_underground` | 58 | 125,706 | 614 | 720 | 490 | 81 | 31 | 55 s |
    | `game/demo_mars_city2` | 104 | 105,567 | 639 | 569 | 654 | 116 | 58 | 64 s |

    Compared with dhewm3 on the same data and view (`game/demo_mc_underground`'s elevator), brightness is within ~5%: the light math is right. Mars City 1's start is dark because its main lights are `start_off`, switched on by the intro's scripts and triggers (and dhewm3 shows a cinematic there).

    To fix next:
    - **Triggers and scripts** (item 5): `start_off` lights turned on by `trigger_relay`s, hidden monsters shown, the intro's script; until then many areas are darker than in the game.
    - **Shader compiles**: each light has its own Effect (light volume, uniform named after the light), so every set of lights on a shape is a new GLSL program: the first view of an area stalls (12 to below 1 FPS while turning in a fresh run), later runs use the driver's cache. Share the effect between lights (needs CGE change K) or prepare shaders at load. CGE change J (PR #743) is needed for correctness first, and makes more programs.
    - **Frame rate** in steady state is GPU-bound and shadow volumes cost about half (`r_shadows 0`: 22 -> 43 FPS at Mars City's start).
    - **String tables**: GUIs show `#str_04006`: load `strings/*.lang`.
    - The elevator's back wall in `demo_mc_underground` is black (lit in dhewm3), cause not found yet (`ent func_static_4843`: built and visible; its GUI renders).
    - Load time (about a minute per map), missing sound shader `guisounds_error`.

    Then the full game's maps with `smoke_maps.ps1`.
2. **Shadows from several lights** (needs CGE change A, PR #740, or B below): then `UpdateShadowLight` marks the few strongest lights of the visible areas.
3. **Exact material stages** (partly needs CGE changes D and E below): `vertexColor`, `mirrorRenderMap`, real reflections (`texgen reflect` with the cube map) and heat haze (`fragmentProgram heatHaze`) instead of the glass tint, `deform tube` / `flare` / `turbulent`, stage `if` conditions, `polygonOffset` decals.
4. **Interactive GUIs**: the GUI script (`onTime` transitions, `onAction`, `set` / `transition` / `resetTime` / `runScript`), the cursor where the player looks, Doom 3's fonts, re-rendering when the state changes.
5. **Gameplay**, in subtasks (in the order to do them; counts are from the demo's three maps):
    - **5a. Entity activation and triggers** (done, unreleased; what's missing is in the other subtasks): `target` chains (`target`, `target1`...) firing `trigger_relay` (318 in the demo maps, `delay`), `trigger_once` (187) / `trigger_multiple` (8) touched by the player (volumes from their `.cm` models; `wait`, `delay`, `triggerFirst`, `noTouch`), `trigger_count` (9), `trigger_hurt` (12, `def_damage`); activating lights (on / off: 455 targeted), speakers (203), hidden `func_static` and models (`hide`, 121), doors (lock / open), monsters (show the hidden, wake the dormant), `func_remove` (64), `target_null`. Unsupported classes are logged. In `demo_mc_underground`, 89 trigger volumes; walking through fires them, and the first unsupported targets are `func_emitter` (item 7), `target_lock` (5b), characters (5d) and `call` script functions (5c).
    - **5b. Movers**: done (unreleased): entityDef spawn arguments, door travel from the rotated bounds and Doom 3's defaults, door teams, `target_lock`, `func_rotating` `start_on` / toggled, `bind` for brush entities and models. Still missing: `func_mover` (129) and `func_elevator` / `func_plat` moving along their paths (driven by scripts, 5c), `bindToJoint`, bound lights, keys (`requires`), brush entity `.cm` models for movers' collision.
    - **5c. Script interpreter** (done, unreleased): Doom 3's script language (`script/*.script`, `maps/<map>.script`): compiler and virtual machine, `call` keys of triggers (27), the map scripts that switch lights and play the intro (`func_cameraview` cinematics), `sys` and entity events. Done (unreleased): the compiler (the demo's whole program compiles) and VM with threads and waits, the map's `main`, `call` keys, events for triggers, lights, doors, hide / show, keys, `bind`, idMover moves and rotations. Cinematics done too (unreleased): camera anims and views, screen fades, teleports, light fades, script sounds; Mars City 1's intro plays its cameras. Animated models done too (unreleased): `idAnimated`, cinematic characters playing their `anim`, heads (`def_head`). GUI parameters (`setGuiParm`) and `func_splinemover` curves done too. Left for later: `setColor` / `setShaderParm` on brush entities and models, `fadeSound`; `path_anim` paths and script objects on entities are 5d.
    - **5d. AI** (started, unreleased: characters, zombies, imps and security zombies run their AI scripts, the player talks to characters, splash damage, see ARCHITECTURE.md "Actors"; next: the full game's other monsters, heads looking at the player, dodges and combat nodes, AAS): the monsters' `ai/*.script` states, animation events (frame commands), `path_*` entities (`path_corner`, `path_anim`, `path_conversation`...), `monsterclip` blocking monsters instead of `playerclip`, `def_head` and attachments, AAS navigation, `af` ragdolls later.
    - **5e. Weapons and items**: weapons with view models (`models/md5/weapons/`), ammo and items (`item_*`, `ammo_*`, `moveable_*`), the player's inventory.
    - **5f. Player information**: PDAs, objectives (`target_primaryobjective`), tips (`target_tip`), location names (`info_location`), radio chatter (`func_radiochatter`), `target_*` effects (`target_entity_setcolor`, `target_setshaderparm`, `target_entity_fadeout`, fades).
    - **5g. Damage and death**: `def_damage` decls, pain / gib effects, the MD5 "shrivel" death effect, `trigger_hurt` kinds.
6. **Sound**: `.ogg` music, `s_shader` choice of random files, shakes, occlusion through portals, `sound_body` / `sound_voice` frame commands.
7. **Particles and FX** (`.prt`, `.fx`): sparks, smoke, blood, muzzle flashes.
8. **Doom 3 BFG** binary formats (`.bimage`, `.bproc`), Resurrection of Evil (`d3xp`).
9. **Web build** (WebAssembly), as castle-doom and castle-quake2 have.
10. **Exact light images** (needs CGE change C below, PRs #741 and #742 for colored images): the light shader's projection image and `lightFalloffImage` as textures of the light effect, instead of the analytic shapes; `nodiffuse` / `nospecular` (don't need CGE changes).
11. **Classic Doom 3** (see below): the first episode of the original Doom remade in Doom 3, a mod with its own game code.
12. **Features from dhewm3** (see below): the parts of the maintained Doom 3 source port that players expect and this port doesn't have yet.

## Classic Doom 3

[Classic Doom 3](https://dhewm3.org/mods.html#classic-doom-3) (Flaming Sheep Software, 2007, version 1.3.1) remakes episode 1 of the original Doom (Knee-Deep in the Dead) in Doom 3. It needs the full Doom 3 data. Its data is a zip from [ModDB](https://www.moddb.com/downloads/classic-doom-3-131), extracted into the Doom 3 directory (a `cdoom/` mod directory); dhewm3 starts it with `+set fs_game cdoom`. Its game code was released under the GPL and lives in the [`cdoom` branch of dhewm3-sdk](https://github.com/dhewm/dhewm3-sdk/tree/cdoom) (commit "Import Classic Doom 3"), which tells what this port must do beyond the base game:

- **Mod directory**: `-game cdoom` already mounts `<basepath>/cdoom` over `base`; also accept dhewm3's `+set fs_game cdoom` (and `fs_game_base`), list the mods found next to `base/` in the main menu, and check that the mod's decls override base ones (we keep the first definition of a decl: the mod's pk4s must be searched first).
- **Secrets** (`idSecret` in `Misc.cpp`): an entity that marks a secret area when the player touches it (or when triggered), counted per map, with a "secret found" message.
- **End of level and intermission** (`idTarget_EndLevelCdoom` in `Target.cpp`, `idPlayer::OpenStats` / `StatsProceed`): stops the sounds, shows the statistics GUI (kills, items, secrets and time, as percentages like Doom) and loads the next map, keeping the player's health, armor, weapons and ammo between maps.
- **Doom pickups** (`Item.cpp`, `Player.cpp`): health bonus (`type` 4, up to the player's `maxbonushealth`), armor bonus and mega armor (`type` 5 / 6, up to `maxbonusarmor`), counting picked items (`inv_name` set) for the statistics.
- **Kills counted** for the statistics (`AI.cpp`), **autorun** (`ui_autoRun`), **music speakers** (`s_music` key) with their own volume (`s_music_vol`).
- Its weapons, monsters and level logic are entity defs and Doom 3 scripts: they need the gameplay of item 5 (weapons with view models, items, triggers and movers, the script interpreter and the real AI).
- Multiplayer parts (`cdoomDM`, player skins) are out of scope.

Steps: load its maps like the retail maps (item 1), implement the entities above in `Doom3World`, give `tools/smoke_maps.ps1` a `-Game cdoom` parameter (its map names are to be read from the mod's `maps/`, they are not known here), and check that each map can be finished (the mod's data can't be bundled either).

## Features from dhewm3

[dhewm3](https://github.com/dhewm/dhewm3) is the maintained Doom 3 GPL source port (it doesn't support Doom 3 BFG). Many of its changes are about the C++ code base (64-bit, SDL, CMake, compilers, tools) and come with Castle Game Engine here. These are the ones this port needs too:

| dhewm3 feature | Here |
|---|---|
| Game data: patched 1.3.1 data, Resurrection of Evil (`d3xp`, `fs_game_base`), the free **Doom 3 demo** data | The demo is loaded (`demo/`, item 1); the full game with `-basepath`; Resurrection of Evil is item 8. |
| Mods menu, `fs_game` | See Classic Doom 3 above. |
| Widescreen and any resolution; aspect-ratio-independent GUIs (HUD and menus), 4:3 crosshair scaling | Doom 3 GUIs are 640 x 480: render them 4:3 (pillarboxed) or scale by their anchors; CGE UI scaling for our own HUD. |
| Gamepad support (with ducking and jumping on triggers) | CGE's `Controllers` (game controllers) API. |
| OpenAL EFX reverb (EAX-like effects from the maps' `efxs/*.efx` files) | Parse `.efx` per area; needs reverb in CGE's sound engine (CGE change L). |
| Advanced settings menu (graphics, audio, controls, key bindings) | A CGE UI view: resolution, fullscreen, vsync, gamma / brightness, volume, bindings. |
| Gamma and brightness applied in shaders | A CGE screen effect. |
| Soft particles (fading where they meet geometry) | With particles (item 7), needs the depth buffer in the particle shader. |
| DDS textures, BC7 (BPTC) compressed | The retail data ships DDS (`dds/` directory): check CGE loads its DXT1 / DXT5 / RXGB normal maps; BC7 for newer texture packs (hidef2k). |
| Savegames, quicksave slots, autosave at level start (`com_disableAutoSaves`) | Save the world state (entities, movers, monsters, player, scripts). |
| `nospecular` light parameter (`allow_nospecular`) | Item 10. |
| MD3 models (used by mods) | A loader like the md5 one. |
| MD5 "shrivel" effect (`SHADERPARM_MD5_SKINSCALE`, creatures burning away) | With the creature death effects (item 5). |
| Mouse: inverted look (`m_invertLook`), High-DPI mice, always run (`in_allowAlwaysRunInSP`) | Options of our player navigation. |
| Timedemos, `r_screenshotFormat`, the `map` command printing the current map | Our `--autotest` demo scripts already cover timedemos; small console additions. |
| Mod support through game DLLs (Sikkmod, Denton's, Perfected Doom 3, The Lost Mission...) | Not possible as such: their C++ game code would be ported to Pascal mod by mod, like Classic Doom 3. Pure data mods work with `-game`. |

## Changes needed in Castle Game Engine

Things this port works around because Castle Game Engine (7.0-alpha.3) can't do them yet. Each is a change to propose upstream (https://github.com/castle-engine/castle-engine); the workaround stays until it lands in a CGE release (CI builds against `cge-unstable`).

| | Change | Status | Unblocks |
|---|---|---|---|
| A | Shadow volumes from several lights | Draft PR [#740](https://github.com/castle-engine/castle-engine/pull/740) | Roadmap item 2 |
| B | Shadow maps for point lights | Not started | Item 2 (alternative to A) |
| C | Textures in light source effects | Draft PR [#741](https://github.com/castle-engine/castle-engine/pull/741); colored images: follow-up draft PR [#742](https://github.com/castle-engine/castle-engine/pull/742) | Item 10 |
| D | Depth function / polygon offset per appearance | Not started | Items 3, decals |
| E | Screen and environment textures in materials | Not started | Item 3 (glass, heat haze) |
| F | Silhouette edges kept across animation | Not started | Removes md5 shadow hulls |
| G | Shadow casters that aren't drawn | Not started | Removes hidden caster geometry |
| H | Light attenuation to zero at the radius | Not started | Exact light falloff |
| I | Light passes added in linear color space | Not started (found while doing A) | A with PBR materials |
| J | Light effects in the shader code hash (bug) | PR [#743](https://github.com/castle-engine/castle-engine/pull/743) | Correct light volumes with many lights |
| K | Per-light data in a shared light effect | Not started | Fewer shader programs with many lights (item 1) |
| L | Reverb (OpenAL EFX) in the sound engine | Not started | dhewm3's EAX-like map reverb |

A, B, C, D, F and J were checked against the CGE source; the others come from building this port.

**A. Shadow volumes from several lights.** `TCastleViewport` takes one main light for shadow volumes (`MainLightForShadowVolumes`, the light with `shadowVolumesMain`), and `RenderFromView3D` runs the stencil pass (`RenderShadowVolume`) once for it. Doom 3 shadows every light: one stencil clear + shadow volume pass + additive lit pass per shadow casting light that reaches the view.

Workaround: `TDoom3Map.UpdateShadowLight` picks the strongest light at the player every frame.

Proposed upstream: [castle-engine/castle-engine#740](https://github.com/castle-engine/castle-engine/pull/740) (draft) adds `TCastleViewport.ShadowVolumesMaxLights` (default 1 = unchanged):
- the receivers are rendered once with the casting lights off (ambient, emissive, other lights, depth buffer);
- per light: stencil clear, its shadow volumes, then an additive (`one, one`) pass of only that light where the stencil is 0, with shaders built with `CASTLE_LIGHT_CONTRIBUTION_ONLY` (no emissive, ambient or fog color, unlit shapes black);
- an example (`examples/viewport_and_scenes/shadow_volumes_several_lights`), API docs, and a rendering test in CGE's suite.

It was checked with this port's test level (up to 8 lights, Phong materials with light volume effects, no artefacts). Still missing after it:
- a scissor rectangle / depth bounds per light, so each pass only covers the light's screen area, as Doom 3 does: every pass now covers all the receivers;
- the gamma issue (change I);
- the cge-www manual page `shadow_volumes.adoc` still says one light (to update if the PR is accepted);
- here: once it is in a CGE release, `UpdateShadowLight` marks the few strongest lights of the visible areas (`shadowVolumes` and `shadowVolumesMain`) and sets `ShadowVolumesMaxLights`; tested locally with a temporary patch, not committed because CI builds against released CGE.

**B. Shadow maps for point lights.** `CastleInternalShadowMaps` computes projections only for spot and directional lights (`AutoCalculateProjectionForDirectionalLight`, spot cut-off angles): a point light needs a cube shadow map (6 faces, or a dual paraboloid map) and the shader lookup for it. Also, shadow map receivers are the shapes of the same scene as the light (`ProcessShadowMapsReceivers` per scene); the map's areas and lights are separate scenes here, so receivers in other scenes (or global lights casting into every scene) are needed too. Either A or B gives several shadow casting lights.

**C. Textures in light source effects.** A sampler declared in an `Effect` on a light (`PLUG_light_scale`) is never bound, because CGE loads textures only for shapes' appearances. Doom 3 lights are a projection image times a falloff image, both textures. Needed: load and bind `ImageTexture` fields of light effects (as for material effects). Workaround: `Doom3LightEffects` uses analytic shapes (round, square, the default falloff), not the light's images.

Cause (found while fixing it): shapes prepare the textures of the lights of their own scene (`TShape.EnumerateTextures` over `State.Lights`), but our lights are global lights in a separate scene (`TDoom3Map.LightScene`, `CastGlobalLights`), so nothing prepared them and `TTextureResources.Bind` failed. Proposed upstream: [castle-engine/castle-engine#741](https://github.com/castle-engine/castle-engine/pull/741) (draft): `TCastleScene.PrepareGlobalLightsTextures` prepares the textures of its global lights' effects (and `EnvironmentLight` textures) every frame in `LocalRender`, before frustum culling (a scene with only lights has an empty bounding box), and in `PrepareResources`; example `examples/shaders/shader_effects_on_light` (a light projecting an image), and a test that fails on master. Once it is in a CGE release, `CreateLightEffect` can take the light shader's projection image and the `lightFalloffImage` as `SFNode` fields (`sampler2D`), replacing the analytic shapes.

Follow-up, colored light images: `PLUG_light_scale` multiplies the light by a float, so with #741 alone the images are grayscale masks, while many Doom 3 light images are colored. [castle-engine/castle-engine#742](https://github.com/castle-engine/castle-engine/pull/742) (draft, stacked on #741, to merge after #740 and #741) adds `PLUG_light_color_scale(inout vec3 color_scale, normal_eye, light_dir)` to the Phong and physical lighting models (the light's contribution is multiplied by `scale * color_scale`), extends the `shader_effects_on_light` example with a colored stained glass image and documents both plugs in its README, with a test (Phong and physical materials) that fails without the plug. Here, once both are released: `CreateLightEffect` passes the projection image and the `lightFalloffImage` as `sampler2D` fields and the effect uses `PLUG_light_color_scale` with `projection.rgb * falloff.rgb` (Doom 3 multiplies the light color by both).

**D. Depth offset for coplanar layers.** CGE renders with `DepthFunc = less` and uses `glPolygonOffset` only for wireframe. Doom 3 draws every material stage on the same triangles (`depthFunc equal` / `lequal`) and decals with `polygonOffset`. Needed: a per-appearance depth function (`lequal` / `equal`) and polygon offset (factor, units), for example an Appearance field or a `DepthMode` node like InstantReality's (`depthFunc`, `polygonOffset`). Workaround: overlay stages are copies moved 0.25 units along the normals (`OverlayOffset`), which can show at grazing angles.

**E. Screen and environment textures in materials.** Doom 3 glass and heat haze read the rendered screen (`_currentRender`) and cube maps with `texgen reflect`. Needed: a "screen color" texture available to shader effects of transparent shapes (a copy of the opaque pass), and reflection texture coordinates from cube maps working together with the unlit material. Workaround: `GlassAppearance`, a faint additive tint.

**F. Silhouette edges kept across animation.** CGE finds a caster's manifold edges by comparing every edge with every other one (`TShapeShadowVolumes.CalculateIfNeededManifoldAndBorderEdges`), and again whenever the coordinates change, so an animated (skinned) md5 mesh repeats the quadratic search every frame. The topology (triangle indexes) doesn't change, only positions: CGE could keep the edge pairs (vertex index pairs) while the index list stays the same, and build them with a hash map instead of a linear search. Workaround: md5 meshes over 1500 triangles cast with boxes per joint (`BuildShadowHulls`).

**G. Casters that aren't drawn.** Shadow volumes are rendered only for visible scenes and shapes. Doom 3 has shadow-only geometry (`shadowModel`s in `.proc`, the closed solids of the map). Needed: a scene or shape that casts shadow volumes without being drawn (for example `Appearance.shadowCaster` with a "render" flag, or a `TCastleScene.Visible := False` that still casts). Workaround: the `.cm` brush casters are real black geometry 1 unit inside the walls, and md5 joint boxes are drawn inside the body.

**H. Light attenuation to zero at the radius.** CGE cuts a light off hard at its `radius` and its attenuation never reaches zero, so a Doom 3 light box needs a radius twice its size and a low attenuation to hide the edge (`BuildLights`). Needed: an optional smooth falloff to zero at the radius (as glTF `KHR_lights_punctual` range).

**I. Light passes added in linear color space.** The additive passes of A blend in the color buffer after the shader has applied gamma correction or tone mapping, and gamma(a) + gamma(b) > gamma(a + b): shapes rendered with gamma correction (`ColorSpace = csLinear`, or the default `csLinearWhenPhysicalMaterial` with PBR materials) come out too bright where several lights overlap. Needed: render the shadowed passes to a linear framebuffer (sRGB framebuffer with `GL_FRAMEBUFFER_SRGB`, or a floating point one) and convert once at the end. This port uses Phong materials without gamma correction, so A is exact here.

**J. Light effects in the shader code hash (a CGE bug).** Effects on materials, groups and textures are added to the shader program's hash by node reference (`TShaderCodeHash.AddEffects`), because effects with the same code can have different uniform values, set when the program is linked. Effects on lights are not (`TLightShader.Prepare`): shapes lit by different lights of the same type share one program, with the first shape's light effects and their uniforms. With this port's per-light volume effects, most shapes of a retail map used other lights' volumes. The fix adds `Hash.AddEffects(Node.FdEffects)` in `TLightShader.Prepare`: [castle-engine/castle-engine#743](https://github.com/castle-engine/castle-engine/pull/743), with a test that fails without it and the example `examples/shaders/shader_effects_on_several_lights` (three lamps, same effect code, different uniforms; before the fix two tiles show the first lamp's rings); with it Mars City 1's start gets a little brighter (mean luma 11.4 -> 13.7). It means more shader programs (one per set of light effects), so the shader compile item above matters more.

**K. Per-light data in a shared light effect.** A light effect's uniforms are fields of its `Effect` node, so lights that need different values (every Doom 3 light has its own volume matrix) need their own `Effect` nodes, and since J every set of light effect nodes on a shape is its own shader program. Doom 3 levels have hundreds of lights: hundreds of programs, compiled when an area first comes into view. Needed: a way for one `Effect` node to be shared by many lights while reading values per light, for example custom fields on the light node passed as `<Light>`-indexed uniforms (`castle_LightSource<Light>...` like the built-in ones), with the light number substituted in the effect code. Workaround: none yet (the driver's shader cache hides the stalls after the first run).

**L. Reverb in the sound engine.** The full game has `efxs/*.efx` files with EAX reverb settings for its maps (not in the demo data, so their format is not checked here), which dhewm3 plays with OpenAL EFX. CGE's sound engine has no reverb or effect slots. Needed: OpenAL EFX auxiliary effect slots (reverb parameters) on the sound engine, chosen per listener position. Workaround: none (no reverb).
