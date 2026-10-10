# Doom 3 comparison and roadmap

Status of version 0.10.0. "Done" items are tested against the bundled test level; real Doom 3 data has not been tested yet (it can't be bundled), so expect fixes when the first retail maps are loaded.

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
- Material stages: texture matrices (`scroll`, `translate`, `scale`, `centerScale`, `shear`, `rotate`) and animated colors on surfaces; `cameraCubeMap` / `cubeMap` skies as a skybox.
- Stencil shadows (CGE shadow volumes) for the strongest light at the player, from brush entities, static models, small md5 models and the level's `.cm` brushes (walls, pillars); `noshadows` materials and lights.
- Light volumes: Doom 3's box / frustum lights without distance attenuation, `light_start` / `light_end`, projection and falloff shapes (analytic stand-ins for the images), `shaderParm4` time offsets.
- Light shaders: animated stage color registers with expressions and tables (strobes, flickers, pulses), `colored`, `shaderParm`s.
- Portal visibility: areas, entities, models and lights hidden when not visible through the portals; doors close portals.
- `func_door` (proximity trigger, `movedir`, `lip`, `speed`, `time`, `wait`, `locked`, `no_touch`, sounds), `func_static`, `func_rotating`.
- Speakers with looping and one-shot sound shaders.
- Player movement, flashlight, pistol, health / armor, death and restart; simple melee monsters.
- Editor component `TDoom3Map`, HUD, console, menu with the map list, autotest harness, parser unit tests, CI.

## Next steps

1. **Load the retail maps** (`game/mars_city1`, `game/admin` ...) and fix what breaks; record load times; add a CI-independent smoke test script for people who own the game.
2. **Shadows from several lights**: CGE's shadow volumes use one main light; several lights need shadow maps (CGE supports them for spot / directional lights) or more stencil passes in CGE; larger md5 casters without the quadratic edge search.
3. **More material stages**: several blended stages per material (only the first plain stage is drawn), `vertexColor`, `mirrorRenderMap`, glass and heat haze (`fragmentProgram heatHaze`), `deform` (sprites, tubes, flares), `texgen` reflections.
4. **Interactive GUIs**: the GUI script (`onTime` transitions, `onAction`, `set` / `transition` / `resetTime` / `runScript`), the cursor where the player looks, Doom 3's fonts, re-rendering when the state changes.
5. **Gameplay**: lights switched by triggers, monsters blocked by `monsterclip` instead of `playerclip`, brush entity `.cm` models for movers, weapons with view models (`models/md5/weapons/`), ammo and items (`item_*`, `ammo_*`), triggers (`trigger_once` / `multiple`, `target` chains, `func_elevator`, `func_plat`, `func_mover` with scripts), PDAs, the real AI (`ai/*.script`, animation events, `af` ragdolls as a later step), monster `def_head` and attachments.
6. **Sound**: `.ogg` music, `s_shader` choice of random files, shakes, occlusion through portals, `sound_body` / `sound_voice` frame commands.
7. **Particles and FX** (`.prt`, `.fx`): sparks, smoke, blood, muzzle flashes.
8. **Doom 3 BFG** binary formats (`.bimage`, `.bproc`), Resurrection of Evil (`d3xp`).
9. **Web build** (WebAssembly), as castle-doom and castle-quake2 have.
10. **Exact light images**: bind the projection / falloff textures in light effects (needs CGE to load textures referenced only by light effects, or an atlas through a material effect), `nodiffuse` / `nospecular`.
