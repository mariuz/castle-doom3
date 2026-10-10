# Doom 3 comparison and roadmap

Status of version 0.3.0. "Done" items are tested against the bundled test level; real Doom 3 data has not been tested yet (it can't be bundled), so expect fixes when the first retail maps are loaded.

## Done

- PK4 / loose-file virtual file system with override order, `-basepath`, `-game`, `-pk4`.
- Declarations: materials, entityDefs (with `inherit`), model decls (`mesh`, `anim`, `offset`, `skin`, `inherit`, frame commands skipped), skins, sound shaders, tables (indexed).
- Materials: diffuse / bump / specular maps, stage forms, image programs `heightmap`, `addnormals`, others approximated by their source image; alpha test; translucent; two-sided; non-solid; additive / alpha / filter blended stages.
- `.proc` areas, brush models, portals and area BSP (`PointInArea`); `.map` entities.
- Point, projected (spot) and ambient lights with colour, `start_off`.
- md5mesh / md5anim with interpolated playback and skins.
- Static models: LWO2 and ASE (props, `func_static`, light fixtures, items, LWO doors), with skins, collision for `func_*` unless `noclipmodel`.
- Collision models (`.cm`): the world's player-blocking polygons (solid and `playerclip`) collide instead of the render geometry.
- `func_door` (proximity trigger, `movedir`, `lip`, `speed`, `time`, `wait`, `locked`, `no_touch`, sounds), `func_static`, `func_rotating`.
- Speakers with looping and one-shot sound shaders.
- Player movement, flashlight, pistol, health / armor, death and restart; simple melee monsters.
- Editor component `TDoom3Map`, HUD, console, menu with the map list, autotest harness, parser unit tests, CI.

## Next steps

1. **Load the retail maps** (`game/mars_city1`, `game/admin` ...) and fix what breaks; record load times; add a CI-independent smoke test script for people who own the game.
2. **Portal visibility**: walk `interAreaPortals` from the camera's area (closed doors close portals) and set area shapes' `Exists`/visibility; cull lights by area.
3. **Light shaders**: animated `lights/` materials (strobe, flicker tables, `parm` colour expressions), light projection / falloff textures, `light_center` per-axis boxes (Doom 3 lights are boxes, not spheres), `nodiffuse` / `nospecular`.
4. **Shadows**: CGE shadow volumes for the main light or shadow maps for a few nearby lights (Doom 3's stencil shadows are its signature look).
5. **Material stages**: texture `scroll` / `rotate` / `scale` / `translate`, `rgb` / `alpha` expressions with tables and `time`, `vertexColor`, `cubeMap` / `cameraCubeMap` skies, `mirrorRenderMap`, glass (`fragmentProgram heatHaze`).
6. **GUIs**: `.gui` files on `guisurf` surfaces (wall screens, doors' keypads) rendered to textures, with the cursor.
7. **Gameplay**: monsters blocked by `monsterclip` instead of `playerclip`, brush entity `.cm` models for movers, weapons with view models (`models/md5/weapons/`), ammo and items (`item_*`, `ammo_*`), triggers (`trigger_once` / `multiple`, `target` chains, `func_elevator`, `func_plat`, `func_mover` with scripts), PDAs, the real AI (`ai/*.script`, animation events, `af` ragdolls as a later step), monster `def_head` and attachments.
8. **Sound**: `.ogg` music, `s_shader` choice of random files, shakes, occlusion through portals, `sound_body` / `sound_voice` frame commands.
9. **Particles and FX** (`.prt`, `.fx`): sparks, smoke, blood, muzzle flashes.
10. **Doom 3 BFG** binary formats (`.bimage`, `.bproc`), Resurrection of Evil (`d3xp`).
11. **Web build** (WebAssembly), as castle-doom and castle-quake2 have.
