# Doom 3 comparison and roadmap

Status of version 0.12.0. "Done" items are tested against the bundled test level; real Doom 3 data has not been tested yet (it can't be bundled), so expect fixes when the first retail maps are loaded.

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

## Next steps

1. **Load the retail maps** (`game/mars_city1`, `game/admin` ...) and fix what breaks; record load times; add a CI-independent smoke test script for people who own the game.
2. **Shadows from several lights** (needs CGE changes A or B below).
3. **Exact material stages** (partly needs CGE changes D and E below): `vertexColor`, `mirrorRenderMap`, real reflections (`texgen reflect` with the cube map) and heat haze (`fragmentProgram heatHaze`) instead of the glass tint, `deform tube` / `flare` / `turbulent`, stage `if` conditions, `polygonOffset` decals.
4. **Interactive GUIs**: the GUI script (`onTime` transitions, `onAction`, `set` / `transition` / `resetTime` / `runScript`), the cursor where the player looks, Doom 3's fonts, re-rendering when the state changes.
5. **Gameplay**: lights switched by triggers, monsters blocked by `monsterclip` instead of `playerclip`, brush entity `.cm` models for movers, weapons with view models (`models/md5/weapons/`), ammo and items (`item_*`, `ammo_*`), triggers (`trigger_once` / `multiple`, `target` chains, `func_elevator`, `func_plat`, `func_mover` with scripts), PDAs, the real AI (`ai/*.script`, animation events, `af` ragdolls as a later step), monster `def_head` and attachments.
6. **Sound**: `.ogg` music, `s_shader` choice of random files, shakes, occlusion through portals, `sound_body` / `sound_voice` frame commands.
7. **Particles and FX** (`.prt`, `.fx`): sparks, smoke, blood, muzzle flashes.
8. **Doom 3 BFG** binary formats (`.bimage`, `.bproc`), Resurrection of Evil (`d3xp`).
9. **Web build** (WebAssembly), as castle-doom and castle-quake2 have.
10. **Exact light images** (needs CGE change C below): bind the projection / falloff textures in light effects, `nodiffuse` / `nospecular`.

## Changes needed in Castle Game Engine

Things this port works around because Castle Game Engine (7.0-alpha.3) can't do them yet. Each is a change to propose upstream (https://github.com/castle-engine/castle-engine); the workaround stays until it lands.

**A. Shadow volumes from several lights.** `TCastleViewport` takes one main light for shadow volumes (`MainLightForShadowVolumes`, the light with `shadowVolumesMain`), and `RenderFromView3D` runs the stencil pass (`RenderShadowVolume`) once for it. Doom 3 shadows every light: one stencil clear + shadow volume pass + additive lit pass per shadow casting light that reaches the view. Needed in CGE:
- a list of shadow volume lights (for example every light with `shadowVolumes TRUE`, or a limit like 4 chosen by the application) instead of one main light;
- per light: clear the stencil, render the casters' volumes for that light, render the receivers lit only by that light where the stencil is 0, additively;
- the light's scissor rectangle / depth bounds to keep each pass small, as Doom 3 does.

Workaround: `TDoom3Map.UpdateShadowLight` picks the strongest light at the player every frame.

**B. Shadow maps for point lights.** `CastleInternalShadowMaps` computes projections only for spot and directional lights (`AutoCalculateProjectionForDirectionalLight`, spot cut-off angles): a point light needs a cube shadow map (6 faces, or a dual paraboloid map) and the shader lookup for it. Also, shadow map receivers are the shapes of the same scene as the light (`ProcessShadowMapsReceivers` per scene); the map's areas and lights are separate scenes here, so receivers in other scenes (or global lights casting into every scene) are needed too. Either A or B gives several shadow casting lights.

**C. Textures in light source effects.** A sampler declared in an `Effect` on a light (`PLUG_light_scale`) is never bound, because CGE loads textures only for shapes' appearances. Doom 3 lights are a projection image times a falloff image, both textures. Needed: load and bind `ImageTexture` fields of light effects (as for material effects). Workaround: `Doom3LightEffects` uses analytic shapes (round, square, the default falloff), not the light's images.

**D. Depth offset for coplanar layers.** CGE renders with `DepthFunc = less` and uses `glPolygonOffset` only for wireframe. Doom 3 draws every material stage on the same triangles (`depthFunc equal` / `lequal`) and decals with `polygonOffset`. Needed: a per-appearance depth function (`lequal` / `equal`) and polygon offset (factor, units), for example an Appearance field or a `DepthMode` node like InstantReality's (`depthFunc`, `polygonOffset`). Workaround: overlay stages are copies moved 0.25 units along the normals (`OverlayOffset`), which can show at grazing angles.

**E. Screen and environment textures in materials.** Doom 3 glass and heat haze read the rendered screen (`_currentRender`) and cube maps with `texgen reflect`. Needed: a "screen color" texture available to shader effects of transparent shapes (a copy of the opaque pass), and reflection texture coordinates from cube maps working together with the unlit material. Workaround: `GlassAppearance`, a faint additive tint.

**F. Silhouette edges kept across animation.** CGE finds a caster's manifold edges by comparing every edge with every other one (`TShapeShadowVolumes.CalculateIfNeededManifoldAndBorderEdges`), and again whenever the coordinates change, so an animated (skinned) md5 mesh repeats the quadratic search every frame. The topology (triangle indexes) doesn't change, only positions: CGE could keep the edge pairs (vertex index pairs) while the index list stays the same, and build them with a hash map instead of a linear search. Workaround: md5 meshes over 1500 triangles cast with boxes per joint (`BuildShadowHulls`).

**G. Casters that aren't drawn.** Shadow volumes are rendered only for visible scenes and shapes. Doom 3 has shadow-only geometry (`shadowModel`s in `.proc`, the closed solids of the map). Needed: a scene or shape that casts shadow volumes without being drawn (for example `Appearance.shadowCaster` with a "render" flag, or a `TCastleScene.Visible := False` that still casts). Workaround: the `.cm` brush casters are real black geometry 1 unit inside the walls, and md5 joint boxes are drawn inside the body.

**H. Light attenuation to zero at the radius.** CGE cuts a light off hard at its `radius` and its attenuation never reaches zero, so a Doom 3 light box needs a radius twice its size and a low attenuation to hide the edge (`BuildLights`). Needed: an optional smooth falloff to zero at the radius (as glTF `KHR_lights_punctual` range).

